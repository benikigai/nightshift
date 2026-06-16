#!/usr/bin/env bash
# nightshift/adapters/antigravity.sh — Antigravity (agy) build adapter.
#
# Drives `agy -p --sandbox` headless, SUBSCRIPTION-FIRST (Google AI Ultra OAuth; provider keys
# stripped by ns_run_subscription). Light-touch by design: the ~200 req/24h OAuth cap is bounded
# by the guard rate limiter (hourly_call_cap), and ANY agy failure — not installed, rate-capped,
# auth error, or non-zero exit — falls back to the claude.sh adapter (documented).
#
# Contract: antigravity.sh build --features <shift.json> --workdir <dir> [--prompt <file>]
# Test override: NIGHTSHIFT_AGY_BIN.
set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUP_DIR="$(cd "$ADAPTER_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"
AGY_BIN="${NIGHTSHIFT_AGY_BIN:-agy}"

log_ag() { printf '[antigravity] %s\n' "$*" >&2; }

SUB="${1:-}"; [ $# -gt 0 ] && shift
PROMPT=""; FEATURES=""; WORKDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)   PROMPT="${2:-}"; shift 2 ;;
        --features) FEATURES="${2:-}"; shift 2 ;;
        --workdir)  WORKDIR="${2:-}"; shift 2 ;;
        *) echo "antigravity.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ "$SUB" = "build" ] || { echo "usage: antigravity.sh build --features <f> --workdir <d> [--prompt <f>]" >&2; exit 2; }
[ -n "$FEATURES" ] && [ -n "$WORKDIR" ] || { echo "antigravity.sh: --features and --workdir required" >&2; exit 2; }

fallback_to_claude() {
    log_ag "falling back to claude adapter: $1"
    if [ -n "$PROMPT" ]; then
        exec bash "$ADAPTER_DIR/claude.sh" build --features "$FEATURES" --workdir "$WORKDIR" --prompt "$PROMPT"
    fi
    exec bash "$ADAPTER_DIR/claude.sh" build --features "$FEATURES" --workdir "$WORKDIR"
}

command -v "$AGY_BIN" >/dev/null 2>&1 || fallback_to_claude "agy not on PATH"

tasks="$(cat "$FEATURES" 2>/dev/null)"
extra="$(cat "$PROMPT" 2>/dev/null || true)"
mem="$(cat "$WORKDIR/nightshift-memory.md" 2>/dev/null || true)"
full="You are building one shift. Implement every task whose passes=false in this JSON array of {id,category,description,verify}. Write complete code — no TODOs/stubs — and make it build.

## Shift tasks
${tasks}

${extra}

${mem}"

out="$(cd "$WORKDIR" && ns_run_subscription "$AGY_BIN" -p --sandbox "$full" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    fallback_to_claude "agy exited rc=$rc (capped / auth / error)"
fi

NS_OUT="$WORKDIR/telemetry.json" python3 <<'PY'
import json, os
json.dump({"adapter": "antigravity", "status": "ok", "exit_code": 0, "auth_path": "subscription",
           "tokens": 0, "cost_usd": 0.0, "note": "agy -p; token/cost not reported by the CLI"},
          open(os.environ["NS_OUT"], "w"), indent=2)
PY
exit 0
