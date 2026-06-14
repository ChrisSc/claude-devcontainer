# Shortcuts for the Claude sandbox. Compose lives in .devcontainer/.
COMPOSE  := docker compose -f .devcontainer/compose.yaml
COMPOSEDB := $(COMPOSE) --profile db
ENV_FILE := .devcontainer/.env

.PHONY: up shell rebuild logs stop down nuke firewall doctor cp-skill \
        cron-reload cron-log \
        env allowlist db-up db-down db-psql db-logs db-create db-dump db-reset

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
