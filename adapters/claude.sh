#!/usr/bin/env bash
# nightshift/adapters/claude.sh — Claude Code build adapter (alternative builder).
#
# Drives `claude -p` headless in the workdir, SUBSCRIPTION-FIRST: ns_run_subscription strips
# ANTHROPIC_API_KEY so it uses Claude Max (needs CLAUDE_CODE_OAUTH_TOKEN in env; see RUNBOOK).
# Autonomy WITHOUT --dangerously-skip-permissions: a per-run .claude/settings.local.json
# allowlist + --permission-mode acceptEdits.
#
# Contract: claude.sh build --features <shift.json> --workdir <dir> [--prompt <file>]
#   writes <dir>/telemetry.json {adapter,status,exit_code,auth_path,tokens,cost_usd}, returns rc.
# Test override: NIGHTSHIFT_CLAUDE_BIN (stand-in for `claude`).
set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUP_DIR="$(cd "$ADAPTER_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"

CLAUDE_BIN="${NIGHTSHIFT_CLAUDE_BIN:-claude}"
MODEL="$(ns_cfg models.claude_builder "")"   # optional; empty -> claude's configured default

SUB="${1:-}"; [ $# -gt 0 ] && shift
PROMPT=""; FEATURES=""; WORKDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)   PROMPT="${2:-}"; shift 2 ;;
        --features) FEATURES="${2:-}"; shift 2 ;;
        --workdir)  WORKDIR="${2:-}"; shift 2 ;;
        *) echo "claude.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
if [ "$SUB" != "build" ]; then
    echo "usage: claude.sh build --features <shift.json> --workdir <dir> [--prompt <file>]" >&2
    exit 2
fi
[ -n "$FEATURES" ] && [ -n "$WORKDIR" ] || { echo "claude.sh: --features and --workdir required" >&2; exit 2; }
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "claude.sh: '$CLAUDE_BIN' not found on PATH" >&2; exit 2; }

# --- permission allowlist (NO --dangerously-skip-permissions) ---
mkdir -p "$WORKDIR/.claude"
cat > "$WORKDIR/.claude/settings.local.json" <<'JSON'
{ "permissions": { "allow": ["Edit", "Write", "Read", "Glob", "Grep", "Bash"], "deny": [] } }
JSON

# --- build the prompt (incl. Nightshift cross-attempt memory) ---
tasks="$(cat "$FEATURES" 2>/dev/null)"
extra="$(cat "$PROMPT" 2>/dev/null || true)"
mem="$(cat "$WORKDIR/nightshift-memory.md" 2>/dev/null || true)"
full="You are building one shift. Implement every task whose passes=false in this JSON array of {id,category,description,verify}. Write complete code — no TODOs/stubs/placeholders — and make it build.

## Shift tasks
${tasks}

${extra}

${mem}"

# --- run claude -p subscription-first; include --model only if configured (bash 3.2 safe: no empty-array) ---
if [ -n "$MODEL" ]; then
    out="$(cd "$WORKDIR" && ns_run_subscription "$CLAUDE_BIN" -p --output-format json \
            --permission-mode acceptEdits --model "$MODEL" "$full" 2>&1)"
else
    out="$(cd "$WORKDIR" && ns_run_subscription "$CLAUDE_BIN" -p --output-format json \
            --permission-mode acceptEdits "$full" 2>&1)"
fi
rc=$?

# --- telemetry from the claude -p json envelope (data via env, NOT stdin: heredoc owns stdin) ---
NS_RAW="$out" NS_RC="$rc" NS_OUT="$WORKDIR/telemetry.json" python3 <<'PY'
import json, os
rc = int(os.environ["NS_RC"]); out = os.environ["NS_OUT"]
raw = os.environ.get("NS_RAW", "")
status, tokens, cost = ("ok" if rc == 0 else "failed"), 0, 0.0
try:
    e = json.loads(raw)
    if e.get("is_error"):
        status = "failed"
    u = e.get("usage") or {}
    tokens = (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0)
    cost = e.get("total_cost_usd", 0.0) or 0.0
except Exception:
    pass
json.dump({"adapter": "claude", "status": status, "exit_code": rc,
           "auth_path": "subscription", "tokens": tokens, "cost_usd": cost},
          open(out, "w"), indent=2)
PY

# exit reflects build success (is_error or non-zero rc -> failure)
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status')=='ok' else 1)" "$WORKDIR/telemetry.json"
