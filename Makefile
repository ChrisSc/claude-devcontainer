# Shortcuts for the Claude sandbox. Compose lives in .devcontainer/.
COMPOSE  := docker compose -f .devcontainer/compose.yaml
COMPOSEDB := $(COMPOSE) --profile db
ENV_FILE := .devcontainer/.env

.PHONY: up shell rebuild logs stop down nuke firewall doctor cp-skill \
        cron-reload cron-log lint smoke boot-check \
        env allowlist db-up db-down db-psql db-logs db-create db-dump db-reset

# Shell scripts that ARE the deliverable (the same set CI shellchecks).
SHELL_SCRIPTS := $(wildcard .devcontainer/*.sh) \
                 .devcontainer/crontab-edit .devcontainer/crontab-reload

up: env allowlist   ## Build (if needed) and start the container
	$(COMPOSE) up -d --build

shell:     ## Interactive login shell as `claude`
	docker exec -it claude-code zsh -l

rebuild: env allowlist  ## Rebuild the image from scratch and restart
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

logs:      ## Follow container logs (firewall + startup output)
	$(COMPOSE) logs -f

stop:      ## Stop the container + db sidecar (volumes + data preserved)
	$(COMPOSEDB) stop

down:      ## Remove the container + db sidecar (named volumes preserved)
	$(COMPOSEDB) down

nuke:      ## Remove the container + db sidecar AND all named volumes (destroys data)
	$(COMPOSEDB) down -v

firewall:  ## Re-apply the egress firewall (e.g. after editing extra-allowlist.txt)
	docker exec claude-code sudo /usr/local/bin/init-firewall.sh

doctor:    ## Run claude doctor inside the container
	docker exec -it claude-code claude doctor

cron-reload: ## Re-install the persisted crontab into cron (after editing ~/.claude/cron/crontab)
	docker exec claude-code crontab-reload

cron-log:  ## Follow scheduled-agent job logs (~/.claude/cron/logs)
	docker exec -it claude-code bash -c 'tail -n 100 -F ~/.claude/cron/logs/* 2>/dev/null || echo "no cron logs yet (~/.claude/cron/logs is empty)"'

cp-skill:  ## Copy a skill folder into ~/.claude/skills owned by claude: make cp-skill SRC=~/dev/my-skill
	@test -n "$(SRC)" || { echo "usage: make cp-skill SRC=<path-to-skill-folder>"; exit 1; }
	@test -d "$(SRC)" || { echo "error: $(SRC) is not a directory"; exit 1; }
	tar -C "$(dir $(SRC:/=))" -cf - "$(notdir $(SRC:/=))" | \
	  docker exec -i -u claude claude-code tar -C /home/claude/.claude/skills -xf -
	@echo "copied $(notdir $(SRC:/=)) -> ~/.claude/skills (owned by claude)"

allowlist: ## Seed config/extra-allowlist.txt from the template (if missing)
	@bash .devcontainer/gen-allowlist.sh

# --- Static gates (mirror .github/workflows/ci.yaml) ----------------------

lint:      ## Run the static gates locally: shellcheck + hadolint + yamllint + compose config
	shellcheck $(SHELL_SCRIPTS)
	hadolint --config .hadolint.yaml .devcontainer/Dockerfile
	yamllint .devcontainer/compose.yaml .github/workflows/ci.yaml
	$(COMPOSE) config -q

smoke: env allowlist ## Build + boot the image (permissive firewall) and assert its wiring
	$(COMPOSE) build
	FIREWALL_MODE=permissive $(COMPOSE) up -d
	@# Wait for the boot pipeline to FINISH, not just to reach seeding. The order is
	@# firewall -> seed -> claude update -> aws-toolkit -> cron -> exec, so
	@# ENVIRONMENT.md (step 2 of 6) lands well before the update/AWS/cron steps —
	@# asserting on it races the rest of boot. cron is the last step before `exec`,
	@# and the process table is fresh on a recreated container, so it is an exact
	@# "boot complete" signal (the compose healthcheck uses the same proxy).
	@for i in $$(seq 1 180); do \
	  docker exec claude-code pgrep -x cron >/dev/null 2>&1 && break; \
	  sleep 1; \
	done
	docker exec claude-code claude --version
	docker exec claude-code bash -lc 'command -v python3 | grep -q "^/home/claude/.local/bin/"'
	docker exec claude-code bash -lc 'python3 --version | grep -q "3.14"'
	docker exec claude-code bash -lc 'command -v rg fd bat jq yq aws lazygit mcp-proxy-for-aws'
	docker exec claude-code bash -lc 'java -version 2>&1 | grep -q "Temurin-11.0.31"'
	docker exec claude-code bash -lc '[ "$$JAVA_HOME" = /usr/lib/jvm/jdk-11.0.31+11 ]'
	docker exec claude-code test -f /home/claude/.claude/ENVIRONMENT.md
	@# AWS MCP server registration, asserted via the boot journal rather than
	@# `claude mcp list`/`get` — those health-check the server, which would spawn
	@# the proxy and can hang when no AWS credentials are configured.
	@# `jq -se any(...)` not `jq -e select(...)`: with -e the exit status reflects
	@# the LAST input line only, so a `select` probe passes solely when the event
	@# happens to be the final line of the journal. Slurp + `any` tests membership.
	docker exec claude-code bash -lc 'jq -se "any(.[]; .event==\"aws.mcp.registered\")" ~/.claude/logs/boot-events.jsonl >/dev/null'
	@echo "smoke OK"

boot-check: ## Event-completeness gate: assert the boot pipeline emitted its lifecycle events in order
	@docker inspect -f '{{.State.Running}}' claude-code 2>/dev/null | grep -q true || \
	  { echo "claude-code is not running (make up / make smoke)"; exit 1; }
	@# Wait for the journal to exist + carry a terminal entrypoint.ready (the boot
	@# may still be running just after `up`). Then assert the required events are
	@# present and correctly ordered for the LATEST boot_id. jq is baked in.
	@# Membership test via slurp + `any`, NOT `jq -e select(...)`: with -e the exit
	@# status reflects only the LAST input line, so a select probe would pass here
	@# purely because entrypoint.ready happens to be the journal's final event.
	@for i in $$(seq 1 60); do \
	  docker exec claude-code bash -lc 'jq -se "any(.[]; .event==\"entrypoint.ready\")" ~/.claude/logs/boot-events.jsonl >/dev/null 2>&1' && break; \
	  sleep 1; \
	done
	@docker exec claude-code bash -lc '\
	  set -euo pipefail; \
	  J=~/.claude/logs/boot-events.jsonl; \
	  [ -f "$$J" ] || { echo "boot-check FAIL: no boot-events.jsonl"; exit 1; }; \
	  bid=$$(jq -rs "[.[]|select(.event==\"entrypoint.ready\")]|last|.boot_id // empty" "$$J"); \
	  [ -n "$$bid" ] || bid=$$(jq -rs "last|.boot_id // empty" "$$J"); \
	  [ -n "$$bid" ] || { echo "boot-check FAIL: empty journal"; exit 1; }; \
	  echo "boot-check: auditing boot_id=$$bid"; \
	  events=$$(jq -r --arg b "$$bid" "select(.boot_id==\$$b)|.event" "$$J"); \
	  required="firewall.apply.start firewall.complete seed.aws.linked seed.ssh.linked seed.environment.regenerated aws.mcp.registered aws.toolkit.ready cron.installed cron.daemon.started entrypoint.ready"; \
	  idx=0; \
	  ok=1; \
	  for need in $$required; do \
	    found=0; \
	    n=0; \
	    while IFS= read -r ev; do \
	      n=$$((n+1)); \
	      [ "$$n" -le "$$idx" ] && continue; \
	      case "$$need" in \
	        firewall.complete) \
	          case "$$ev" in firewall.complete.strict|firewall.complete.permissive|firewall.degraded) found=1; idx=$$n;; esac;; \
	        *) [ "$$ev" = "$$need" ] && { found=1; idx=$$n; };; \
	      esac; \
	      [ "$$found" = 1 ] && break; \
	    done <<< "$$events"; \
	    if [ "$$found" = 1 ]; then echo "  ok   $$need"; \
	    else echo "  MISS $$need (missing or out of order)"; ok=0; break; fi; \
	  done; \
	  [ "$$ok" = 1 ] && echo "boot-check OK" || { echo "boot-check FAIL"; exit 1; }'

# --- Database (Postgres + pgvector sidecar) -------------------------------

env:       ## Generate .devcontainer/.env with a strong DB password (if missing)
	@bash .devcontainer/gen-env.sh

db-up: env  ## Start the Postgres + pgvector sidecar (claude-db)
	$(COMPOSEDB) up -d db
	@echo "db up -> claude-code reaches it as db:5432; host at 127.0.0.1:5432"

db-down:   ## Stop & remove the db container (data volume preserved)
	$(COMPOSEDB) rm -sf db

db-psql:   ## Interactive psql in the db (optional: make db-psql DB=myproject)
	docker exec -it claude-code psql $(if $(DB),-d $(DB),)

db-logs:   ## Follow the db container logs
	docker logs -f claude-db

db-create: ## Create a project database (pgvector inherited from template1): make db-create DB=myproject
	@test -n "$(DB)" || { echo "usage: make db-create DB=<name>"; exit 1; }
	docker exec claude-code createdb "$(DB)"
	@# vector is in template1 so new DBs inherit it; this is a harmless safety net.
	docker exec claude-code psql -d "$(DB)" -c "CREATE EXTENSION IF NOT EXISTS vector;"
	@echo "created database '$(DB)' (pgvector enabled)"

db-dump:   ## Dump ALL databases to ./db-backups on the host (survives `make nuke`)
	@docker inspect -f '{{.State.Running}}' claude-code 2>/dev/null | grep -q true || \
	  { echo "claude-code is not running (make up)"; exit 1; }
	@docker inspect -f '{{.State.Running}}' claude-db 2>/dev/null | grep -q true || \
	  { echo "claude-db is not running (make db-up)"; exit 1; }
	@mkdir -p db-backups
	@ts=$$(date +%Y%m%d-%H%M%S); \
	  out="db-backups/all-$$ts.sql"; \
	  tmp="$$out.tmp"; \
	  docker exec claude-code pg_dumpall --clean --if-exists > "$$tmp" && \
	    mv "$$tmp" "$$out" || { rm -f "$$tmp"; echo 'dump failed (is the db sidecar up? make db-up)'; exit 1; }; \
	  echo "dumped all databases -> $$out ($$(wc -c < "$$out") bytes)"

db-reset:  ## DESTROY the db data volume and re-init (e.g. after rotating the password)
	@printf 'This deletes ALL database data (volume claude-pgdata). Continue? [y/N] '; \
	  read ans; [ "$$ans" = "y" ] || { echo aborted; exit 1; }
	$(COMPOSEDB) rm -sf db
	docker volume rm claude-pgdata
	$(COMPOSEDB) up -d db
	@echo "db reset — fresh data volume initialized with the current .env password"
