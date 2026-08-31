#!/usr/bin/env bash
#
# init-aws-toolkit.sh — wire the Agent Toolkit for AWS into Claude Code. Runs as
# `claude`, after the firewall is up (it needs egress) and after `claude update`
# (so it drives the updated CLI). Two independent halves:
#
#   1. AWS MCP Server — registers the `aws-mcp` stdio server pointing at the
#      build-pinned `mcp-proxy-for-aws` binary, which SigV4-signs requests to the
#      remote endpoint https://aws-mcp.<region>.api.aws/mcp.
#   2. AWS skills     — installs the pinned set in seed/aws-skills.txt into
#      ~/.claude/skills via the AWS CLI's `aws agent-toolkit` command group.
#
# Non-fatal by construction: every failure path still emits aws.toolkit.ready and
# exits 0, so a network blip or a missing AWS account can never brick the boot.
# `make boot-check` requires that terminal event, which is why it is unconditional.
set -euo pipefail

# Structured boot-event journal (fire-and-forget JSONL; the echo lines are the dev
# mirror). BOOT_ID is inherited from the entrypoint env — this runs as `claude`
# with no sudo, so there is no env_reset to defeat. See log-event.sh.
# shellcheck source=/dev/null
. /usr/local/bin/log-event.sh 2>/dev/null || true
command -v log_event >/dev/null 2>&1 || log_event() { :; }

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MANIFEST="${AWS_SKILLS_MANIFEST:-/usr/local/share/claude-seed/aws-skills.txt}"
STATE_DIR="$CONFIG_DIR/aws"
STAMP="$STATE_DIR/.skills-stamp"

# Region drives BOTH the MCP endpoint host and the `aws agent-toolkit` calls. The
# latter is load-bearing: the toolkit catalog is unauthenticated, but botocore
# still refuses to build a request without a region, so a container with no
# ~/.claude/aws/config would fail every skill install with `NoRegion`. Never drop
# the explicit --region.
AWS_MCP_REGION="${AWS_MCP_REGION:-us-east-1}"
# Read-only is the default posture: the MCP server runs with whatever IAM identity
# is in ~/.claude/aws/credentials, and this sandbox should not mutate real AWS
# infrastructure unless asked. Set AWS_MCP_READ_ONLY=0 (compose env) to allow writes.
AWS_MCP_READ_ONLY="${AWS_MCP_READ_ONLY:-1}"
# Whole-step wall-clock budget for skill downloads, so a degraded network can't
# stretch boot by 23 sequential timeouts. An unfinished pass simply retries next boot.
AWS_SKILLS_BUDGET="${AWS_SKILLS_BUDGET:-180}"

MCP_NAME="aws-mcp"
MCP_ENDPOINT="https://aws-mcp.${AWS_MCP_REGION}.api.aws/mcp"

status="ok"

# Single exit point: always leaves the terminal event in the journal.
finish() {
    log_event aws aws.toolkit.ready status "$1"
    exit 0
}

if ! command -v claude >/dev/null 2>&1 || ! command -v mcp-proxy-for-aws >/dev/null 2>&1; then
    echo "[aws-toolkit] WARN: claude or mcp-proxy-for-aws not on PATH — skipping" >&2
    finish "skipped"
fi

install -d -m 700 "$STATE_DIR"

# ---------------------------------------------------------------------------
# 1. MCP server registration — REGENERATED every boot, not copy-if-missing.
# ---------------------------------------------------------------------------
# ~/.claude is a persistent named volume, so a seed-once entry would freeze the
# FIRST boot's proxy version and flags forever: bumping MCP_PROXY_FOR_AWS_VER or
# flipping AWS_MCP_READ_ONLY would rebuild the image and still leave the old
# server config in place. Remove-then-add makes the container's declared config
# authoritative on every start (same model as ENVIRONMENT.md, not CLAUDE.md).
# This is local config I/O only — no network, and deliberately NOT `claude mcp
# list`/`get`, which health-check the server and would spawn the proxy here.
proxy_args=("$MCP_ENDPOINT")
if [ "$AWS_MCP_READ_ONLY" != "0" ]; then
    proxy_args+=(--read-only)
fi
proxy_args+=(--metadata "AWS_REGION=${AWS_MCP_REGION}")

claude mcp remove "$MCP_NAME" --scope user >/dev/null 2>&1 || true
if claude mcp add --scope user "$MCP_NAME" -- \
        mcp-proxy-for-aws "${proxy_args[@]}" >/dev/null 2>&1; then
    echo "[aws-toolkit] registered MCP server '${MCP_NAME}' -> ${MCP_ENDPOINT} (read_only=${AWS_MCP_READ_ONLY})"
    log_event aws aws.mcp.registered name "$MCP_NAME" region "$AWS_MCP_REGION" \
        read_only "$AWS_MCP_READ_ONLY" endpoint "$MCP_ENDPOINT"
else
    echo "[aws-toolkit] WARN: failed to register MCP server '${MCP_NAME}'" >&2
    log_event aws aws.mcp.failed name "$MCP_NAME" region "$AWS_MCP_REGION"
    status="degraded"
fi

# Credential probe. The proxy SigV4-signs EVERY request including `initialize`,
# so with no resolvable credentials the server does not merely lose its AWS API
# tools — it fails to connect at all, and Claude Code surfaces that as an opaque
# `-32602: Invalid request parameters`. Detect it here and say the useful thing
# instead. Absent credentials are a normal, user-fixable state, NOT a degraded
# boot, so this never changes `status`; it is one bounded, read-only API call.
if timeout 15 aws sts get-caller-identity --region "$AWS_MCP_REGION" \
        --no-cli-pager >/dev/null 2>&1; then
    log_event aws aws.credentials.ok region "$AWS_MCP_REGION"
else
    echo "[aws-toolkit] NOTE: no usable AWS credentials — '${MCP_NAME}' will show as" >&2
    echo "[aws-toolkit]       'Failed to connect' until you run \`aws sso login\` or" >&2
    echo "[aws-toolkit]       \`aws configure\`. Skills below work regardless." >&2
    log_event aws aws.credentials.absent region "$AWS_MCP_REGION"
fi

# ---------------------------------------------------------------------------
# 2. Skills — reconciled only when the pinned manifest changes.
# ---------------------------------------------------------------------------
# The stamp holds the manifest's SHA-256. A hit short-circuits the whole step, so
# steady-state boots cost nothing and a skill the user deliberately removed stays
# removed. Editing seed/aws-skills.txt is what triggers the next reconcile.
if [ ! -f "$MANIFEST" ]; then
    echo "[aws-toolkit] WARN: skill manifest ${MANIFEST} missing — skipping skills" >&2
    log_event aws aws.skills.skipped reason "manifest-missing"
    finish "degraded"
fi

want="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
have="$(cat "$STAMP" 2>/dev/null || true)"

if [ "$want" = "$have" ]; then
    echo "[aws-toolkit] skills already current (manifest unchanged)"
    log_event aws aws.skills.current stamp "$want"
    finish "$status"
fi

echo "[aws-toolkit] reconciling AWS skills from ${MANIFEST}"
installed=0
failed=0
incomplete=0
SECONDS=0

while read -r name version _rest; do
    case "$name" in
        ''|\#*) continue ;;
    esac
    if [ -z "$version" ]; then
        echo "[aws-toolkit] WARN: manifest entry '${name}' has no version — skipping" >&2
        failed=$((failed + 1))
        continue
    fi
    if [ "$SECONDS" -ge "$AWS_SKILLS_BUDGET" ]; then
        echo "[aws-toolkit] WARN: ${AWS_SKILLS_BUDGET}s skill budget exhausted — deferring the rest to next boot" >&2
        log_event aws aws.skills.budget_exceeded budget "$AWS_SKILLS_BUDGET" installed "$installed"
        incomplete=1
        break
    fi
    if timeout 30 aws agent-toolkit add-skill \
            --skill-name "$name" \
            --skill-version "$version" \
            --agent claude-code \
            --region "$AWS_MCP_REGION" \
            --no-cli-pager >/dev/null 2>&1; then
        installed=$((installed + 1))
    else
        echo "[aws-toolkit] WARN: skill ${name}@${version} failed to install" >&2
        failed=$((failed + 1))
    fi
done < "$MANIFEST"

# Stamp ONLY on a clean, complete pass — anything else retries on the next boot.
if [ "$failed" -eq 0 ] && [ "$incomplete" -eq 0 ]; then
    printf '%s\n' "$want" > "$STAMP"
    echo "[aws-toolkit] installed ${installed} AWS skills"
else
    status="degraded"
    echo "[aws-toolkit] WARN: ${installed} installed, ${failed} failed — retrying next boot" >&2
fi
log_event aws aws.skills.installed count "$installed" failed "$failed" incomplete "$incomplete"

finish "$status"
