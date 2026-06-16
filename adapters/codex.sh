#!/usr/bin/env bash
# nightshift/adapters/codex.sh — Codex build adapter (the default).
#
# Wraps graveyard.sh (the Ralph build loop), resolving auth SUBSCRIPTION-FIRST: codex
# authenticates via ChatGPT login, so OPENAI_API_KEY (and the other provider keys) are
# stripped from the environment by ns_run_subscription.
#
# Nightshift adapter contract:
#   codex.sh build --features <shift.json> --workdir <dir> [--prompt <file>]
#     - runs the build over <shift.json> inside <dir>
#     - writes <dir>/telemetry.json {adapter,status,exit_code,auth_path,tokens,cost_usd}
#     - returns the build's exit code
set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../nightshift/adapters
SUP_DIR="$(cd "$ADAPTER_DIR/.." && pwd)"                       # .../nightshift
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"

# graveyard.sh location (config-driven; NIGHTSHIFT_GRAVEYARD_BIN overrides for testing)
GRAVEYARD="${NIGHTSHIFT_GRAVEYARD_BIN:-$(ns_cfg paths.graveyard "$SUP_DIR/../graveyard")/graveyard.sh}"

# --- parse the adapter contract ---
SUB="${1:-}"; [ $# -gt 0 ] && shift
PROMPT=""; FEATURES=""; WORKDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)   PROMPT="${2:-}"; shift 2 ;;
        --features) FEATURES="${2:-}"; shift 2 ;;
        --workdir)  WORKDIR="${2:-}"; shift 2 ;;
        *) echo "codex.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
if [ "$SUB" != "build" ]; then
    echo "usage: codex.sh build --features <shift.json> --workdir <dir> [--prompt <file>]" >&2
    exit 2
fi
[ -n "$FEATURES" ] && [ -n "$WORKDIR" ] || { echo "codex.sh: --features and --workdir are required" >&2; exit 2; }
[ -f "$GRAVEYARD" ] || { echo "codex.sh: graveyard build loop not found at $GRAVEYARD" >&2; exit 2; }

[ -d "$WORKDIR" ] || { echo "codex.sh: workdir '$WORKDIR' does not exist" >&2; exit 2; }

# --- isolate a mutable copy of the shift: graveyard.sh marks passes=true IN PLACE, so never let
#     it mutate the canonical queue file (a review-requeue would otherwise become a no-op) ---
SHIFT_COPY="$WORKDIR/shift.json"
cp "$FEATURES" "$SHIFT_COPY" 2>/dev/null || { echo "codex.sh: cannot copy shift into workdir" >&2; exit 2; }

# --- build prompt = base instructions + Nightshift memory (graveyard blanks .ralph-logs/feedback.md,
#     so cross-attempt hints must ride the prompt instead) ---
GVDIR="$(dirname "$GRAVEYARD")"
BASE_PROMPT="${PROMPT:-$GVDIR/PROMPT_build.md}"
COMBINED="$WORKDIR/.nightshift-build-prompt.md"
{ cat "$BASE_PROMPT" 2>/dev/null || true
  if [ -f "$WORKDIR/nightshift-memory.md" ]; then echo; echo "---"; cat "$WORKDIR/nightshift-memory.md"; fi
} > "$COMBINED"

# --- run the build loop, subscription-first (OPENAI_API_KEY stripped -> ChatGPT login);
#     NIGHTSHIFT_NO_PUSH keeps unreviewed code local until the review gate approves ---
AUTH_PATH="subscription"
NIGHTSHIFT_NO_PUSH=1 ns_run_subscription bash "$GRAVEYARD" \
    --features "$SHIFT_COPY" --project-dir "$WORKDIR" --prompt "$COMBINED"
EXIT=$?

# --- telemetry (token/cost are best-effort from the project's metrics.json totals) ---
python3 - "$WORKDIR/public/metrics.json" "$AUTH_PATH" "$EXIT" "$WORKDIR/telemetry.json" <<'PY'
import json, sys
metrics, auth_path, exit_code, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
tokens, cost = 0, 0.0
try:
    t = json.load(open(metrics)).get("totals", {})
    tokens = (t.get("tokens_coder", 0) or 0) + (t.get("tokens_evaluator", 0) or 0)
    cost = t.get("cost_usd", 0.0) or 0.0
except Exception:
    pass
json.dump({
    "adapter": "codex",
    "status": "ok" if exit_code == 0 else "failed",
    "exit_code": exit_code,
    "auth_path": auth_path,
    "tokens": tokens,
    "cost_usd": cost,
}, open(out, "w"), indent=2)
PY

exit "$EXIT"
