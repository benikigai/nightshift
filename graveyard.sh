#!/bin/bash
# AgentForge Ralph Loop — Two-loop architecture with quality backpressure
# Outer loop: one feature per iteration (Ralph pattern)
# Inner loop: up to 3 attempts with evaluator feedback (Autoresearch/GAN pattern)
#
# The harness owns ALL authority: commit, mark passes, push, skip.
# The coding agent (Codex) only builds code and exits.
# The evaluator (Sonnet via evaluate.py) scores and provides feedback.
#
# Usage:
#   ./graveyard.sh                                          # Default: AgentForge project
#   ./graveyard.sh --features path/to/features.json         # Custom feature list
#   ./graveyard.sh --prompt path/to/PROMPT_build.md         # Custom build prompt
#   ./graveyard.sh --project-dir /path/to/project           # Run in different directory
#   ./graveyard.sh --features f.json --prompt p.md --project-dir /proj  # All combined
set -uo pipefail

# --- Locate AgentForge home (where evaluate.py, metrics_writer.py live) ---
AGENTFORGE_HOME="$(cd "$(dirname "$0")" && pwd)"

# --- Nightshift config (model ids etc.); falls back to literals if config absent ---
NIGHTSHIFT_CONFIG="${NIGHTSHIFT_CONFIG:-$AGENTFORGE_HOME/../nightshift/nightshift.config.json}"
ns_cfg() {  # ns_cfg <dotted.key> <default> — prints config value, or default on any failure
    python3 - "$NIGHTSHIFT_CONFIG" "$1" "$2" <<'PY' 2>/dev/null || echo "$2"
import json, sys
cfg, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(cfg))
    for p in [x for x in key.split('.') if x]:
        d = d[p]
    print(d)
except Exception:
    print(default)
PY
}

# --- Argument Parsing (all optional, backward-compatible defaults) ---
FEATURE_FILE=""
BUILD_PROMPT=""
PLAN_PROMPT=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --features)     FEATURE_FILE="$2"; shift 2 ;;
        --prompt)       BUILD_PROMPT="$2"; shift 2 ;;
        --plan-prompt)  PLAN_PROMPT="$2"; shift 2 ;;
        --project-dir)  WORK_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: graveyard.sh [OPTIONS]"
            echo "  --features <path>      Feature list JSON (default: feature_list.json)"
            echo "  --prompt <path>        Build prompt file (default: PROMPT_build.md)"
            echo "  --plan-prompt <path>   Planning prompt file (default: PROMPT_plan.md)"
            echo "  --project-dir <path>   Working directory (default: AgentForge dir)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Resolve paths ---
PROJECT_DIR="${WORK_DIR:-$AGENTFORGE_HOME}"
cd "$PROJECT_DIR" || { echo "graveyard: cannot cd to project dir: $PROJECT_DIR" >&2; exit 1; }

FEATURE_FILE="${FEATURE_FILE:-feature_list.json}"
BUILD_PROMPT="${BUILD_PROMPT:-PROMPT_build.md}"
PLAN_PROMPT="${PLAN_PROMPT:-PROMPT_plan.md}"

# Make relative paths absolute
[[ "$FEATURE_FILE" != /* ]] && FEATURE_FILE="$PROJECT_DIR/$FEATURE_FILE"
[[ "$BUILD_PROMPT" != /* ]] && BUILD_PROMPT="$PROJECT_DIR/$BUILD_PROMPT"
[[ "$PLAN_PROMPT" != /* ]]  && PLAN_PROMPT="$PROJECT_DIR/$PLAN_PROMPT"

# --- Configuration ---
MAX_ATTEMPTS=3          # Inner loop: max attempts per feature
PLAN_INTERVAL=10        # Run planning pass every N outer iterations
PUSH_INTERVAL=2         # Git push every N completed features (was 5)
CODEX_TIMEOUT=420       # 7 minutes max per codex exec call (was 5)
CODEX_MODEL="${CODEX_MODEL:-$(ns_cfg models.builder gpt-5.3-codex)}"

# --- State ---
LOG_DIR="$PROJECT_DIR/.ralph-logs"
mkdir -p "$LOG_DIR"
ITERATION=0
FEATURES_COMPLETED=0
CONSECUTIVE_SKIPS=0
TOTAL_FEATURES=$(python3 -c "import json; print(len(json.load(open('$FEATURE_FILE'))))")

# --- Helpers ---
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(timestamp)] $*"; }

PROGRESS_FILE="$PROJECT_DIR/claude-progress.txt"
log_progress() {
    [ -f "$PROGRESS_FILE" ] || touch "$PROGRESS_FILE"
    echo "" >> "$PROGRESS_FILE"
    echo "=== $* ===" >> "$PROGRESS_FILE"
}

get_next_feature() {
    python3 -c "
import json
with open('$FEATURE_FILE') as f:
    features = json.load(f)
for feat in features:
    if not feat.get('passes') and not feat.get('skipped'):
        print(json.dumps(feat))
        break
else:
    print('DONE')
"
}

mark_feature() {
    # Usage: mark_feature <id> <field> (passes or skipped)
    local fid="$1"
    local field="$2"
    python3 -c "
import json
with open('$FEATURE_FILE', 'r') as f:
    features = json.load(f)
for feat in features:
    if feat.get('id') == $fid:
        feat['$field'] = True
        break
with open('$FEATURE_FILE', 'w') as f:
    json.dump(features, f, indent=2)
    f.write('\n')
"
}

get_threshold() {
    local category="$1"
    case "$category" in
        scaffold|simple) echo 4 ;;
        git|polish) echo 5 ;;
        complex) echo 6 ;;
        *) echo 5 ;;
    esac
}

check_dev_server() {
    if ! curl -s --max-time 3 http://localhost:3001 > /dev/null 2>&1; then
        log "Dev server down. Restarting..."
        local pid_file="$PROJECT_DIR/.dev-pid"
        if [ -f "$pid_file" ]; then
            kill "$(cat "$pid_file")" 2>/dev/null || true
        fi
        PORT=3001 npm run dev > "$LOG_DIR/dev-server.log" 2>&1 &
        echo $! > "$pid_file"
        sleep 5
    fi
}

# --- Optional tools (may not exist outside AgentForge) ---
run_metrics_writer() {
    local metrics_script="$AGENTFORGE_HOME/metrics_writer.py"
    if [ -f "$metrics_script" ]; then
        python3 "$metrics_script" "$@" || log "WARNING: metrics_writer failed"
    fi
}

run_evaluate() {
    python3 "$AGENTFORGE_HOME/evaluate.py" "$@"
}

# --- Startup ---
log "=== AgentForge Ralph Loop Starting ==="
log "=== Model: $CODEX_MODEL | Max attempts: $MAX_ATTEMPTS | Timeout: ${CODEX_TIMEOUT}s ==="
log "=== Features: $FEATURE_FILE ($TOTAL_FEATURES tasks) ==="
log "=== Project: $PROJECT_DIR ==="
run_metrics_writer --set-started

# Ensure dev server is running (skip if no package.json — non-Node project)
if [ -f "$PROJECT_DIR/package.json" ]; then
    check_dev_server
fi

# ============================================================
# OUTER LOOP — One feature per iteration
# ============================================================
while true; do
    ITERATION=$((ITERATION + 1))
    log "============================================"
    log "=== Outer Iteration $ITERATION ==="
    log "============================================"

    # --- Planning Pass (every PLAN_INTERVAL iterations) ---
    if [ "$ITERATION" -gt 1 ] && (( (ITERATION - 1) % PLAN_INTERVAL == 0 )); then
        if [ -f "$PLAN_PROMPT" ]; then
            log "MODE: Planning pass (gap analysis + regression detection)"
            gtimeout "$CODEX_TIMEOUT" codex exec "$(cat "$PLAN_PROMPT")" \
                --full-auto -m "$CODEX_MODEL" \
                2>&1 | tee "$LOG_DIR/iteration-${ITERATION}-plan.log" || true
            log "Pushing to origin (post-planning)..."
            if [ -n "${NIGHTSHIFT_NO_PUSH:-}" ]; then log "push skipped (NIGHTSHIFT_NO_PUSH set)"; else git push origin HEAD 2>&1 || log "WARNING: git push failed (network?)"; fi
        else
            log "SKIP: No planning prompt found at $PLAN_PROMPT"
        fi
        continue
    fi

    # --- Pick Next Feature ---
    FEATURE_JSON=$(get_next_feature)

    if [ "$FEATURE_JSON" = "DONE" ]; then
        log "ALL FEATURES COMPLETE. AgentForge finished."
        break
    fi

    FEATURE_ID=$(echo "$FEATURE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    FEATURE_DESC=$(echo "$FEATURE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['description'])")
    FEATURE_VERIFY=$(echo "$FEATURE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['verify'])")
    FEATURE_CATEGORY=$(echo "$FEATURE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('category', 'moderate'))")
    THRESHOLD=$(get_threshold "$FEATURE_CATEGORY")

    log "Feature #$FEATURE_ID [$FEATURE_CATEGORY]: ${FEATURE_DESC:0:80}..."
    log "Threshold: $THRESHOLD/10"

    # Track timing
    FEATURE_START=$(date +%s)
    BEST_SCORE=0
    BEST_COMMIT=""
    PREV_SCORE=-1
    ATTEMPT_DATA="[]"
    FINAL_STATUS="skipped"

    # Clear feedback file for fresh feature
    > "$LOG_DIR/feedback.md"

    # ============================================================
    # INNER LOOP — Up to MAX_ATTEMPTS per feature (Autoresearch)
    # ============================================================
    for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
        ATTEMPT_START=$(date +%s)
        log "--- Attempt $ATTEMPT/$MAX_ATTEMPTS for feature #$FEATURE_ID ---"

        # --- Check dev server (Node projects only) ---
        if [ -f "$PROJECT_DIR/package.json" ]; then
            check_dev_server
        fi

        REVERT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

        # --- Run Codex (builder) ---
        log "CODEX: Building feature #$FEATURE_ID (attempt $ATTEMPT)..."
        CODEX_LOG="$LOG_DIR/iter-${ITERATION}-attempt-${ATTEMPT}-codex.log"

        gtimeout "$CODEX_TIMEOUT" codex exec "$(cat "$BUILD_PROMPT")" \
            --full-auto -m "$CODEX_MODEL" \
            2>&1 | tee "$CODEX_LOG" || {
            log "WARNING: Codex timed out or failed"
        }

        # Estimate tokens from log size (rough: ~4 chars per token)
        CODEX_TOKENS=$(( $(wc -c < "$CODEX_LOG" 2>/dev/null || echo 0) / 4 ))

        # --- Mechanical Gate 1: Build ---
        log "GATE: npm run build..."
        if ! npm run build --silent > "$LOG_DIR/build.log" 2>&1; then
            log "GATE FAILED: Build broken."

            # KEY FIX: Feed actual build errors to Codex instead of nuking code
            BUILD_ERRORS=$(tail -30 "$LOG_DIR/build.log" 2>/dev/null || echo "Unknown build error")
            {
                echo "# Build Failed — Feature #$FEATURE_ID, Attempt $ATTEMPT"
                echo ""
                echo "The build (npm run build) failed with these errors:"
                echo ""
                echo '```'
                echo "$BUILD_ERRORS"
                echo '```'
                echo ""
                echo "Fix the TypeScript/compilation errors above. Do NOT delete or revert files."
                echo "Do NOT start over. Fix the specific errors shown."
            } > "$LOG_DIR/feedback.md"

            # KEY FIX: Do NOT revert. Keep the code so next attempt can fix it.
            # Old behavior: git checkout . && git clean -fd  <-- THIS WAS THE BUG

            SCORE=0
            ATTEMPT_END=$(date +%s)
            ATTEMPT_DURATION=$((ATTEMPT_END - ATTEMPT_START))
            ATTEMPT_DATA=$(echo "$ATTEMPT_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({'iteration': $ATTEMPT, 'score': 0, 'feedback': 'Build failed', 'tokens_coder': $CODEX_TOKENS, 'tokens_evaluator': 0, 'duration_sec': $ATTEMPT_DURATION})
print(json.dumps(data))
")
            PREV_SCORE=0
            continue
        fi
        log "GATE PASSED: Build OK"

        # --- Mechanical Gate 2: Localhost responds (Node projects only) ---
        if [ -f "$PROJECT_DIR/package.json" ]; then
            if curl -s --max-time 5 http://localhost:3001 | grep -q '<' 2>/dev/null; then
                log "GATE PASSED: localhost OK"
            else
                log "GATE WARNING: localhost not responding (non-fatal)"
            fi
        fi

        # --- Get diff for evaluator ---
        # Use git diff against HEAD to capture all changes (staged + unstaged + untracked)
        git add -A 2>/dev/null || true
        git diff --cached -- ':!package-lock.json' ':!*.svg' > "$LOG_DIR/diff.txt" 2>/dev/null
        # If empty, try against last commit
        if [ ! -s "$LOG_DIR/diff.txt" ]; then
            git diff HEAD~1 HEAD -- ':!package-lock.json' ':!*.svg' > "$LOG_DIR/diff.txt" 2>/dev/null || true
        fi
        # Unstage so harness controls commits
        git reset HEAD 2>/dev/null || true

        # --- Evaluator (Sonnet via evaluate.py) ---
        log "EVALUATOR: Scoring feature #$FEATURE_ID (attempt $ATTEMPT)..."
        EVAL_JSON=$(run_evaluate eval \
            --feature-id "$FEATURE_ID" \
            --description "$FEATURE_DESC" \
            --verify "$FEATURE_VERIFY" \
            --category "$FEATURE_CATEGORY" \
            --diff-file "$LOG_DIR/diff.txt" \
            --attempt "$ATTEMPT" 2>/dev/null) || EVAL_JSON='{"overall":0,"pass":false,"feedback":[],"summary":"Evaluator failed"}'

        SCORE=$(echo "$EVAL_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('overall', 0))" 2>/dev/null || echo 0)
        EVAL_PASS=$(echo "$EVAL_JSON" | python3 -c "import json,sys; print('true' if json.load(sys.stdin).get('pass') else 'false')" 2>/dev/null || echo "false")
        FEEDBACK=$(echo "$EVAL_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
fb = d.get('feedback', [])
if isinstance(fb, list):
    for item in fb:
        if isinstance(item, dict):
            print('- [%s] %s in %s: %s' % (item.get('dimension',''), item.get('issue',''), item.get('file',''), item.get('fix','')))
        else:
            print('- %s' % item)
elif fb:
    print(str(fb))
" 2>/dev/null || echo "")
        EVAL_TOKENS=$(echo "$EVAL_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tokens_evaluator', 0))" 2>/dev/null || echo 0)
        SUMMARY=$(echo "$EVAL_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('summary', ''))" 2>/dev/null || echo "")

        ATTEMPT_END=$(date +%s)
        ATTEMPT_DURATION=$((ATTEMPT_END - ATTEMPT_START))

        log "SCORE: $SCORE/10 (threshold: $THRESHOLD) — $SUMMARY"

        # Record attempt
        ATTEMPT_DATA=$(echo "$ATTEMPT_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({
    'iteration': $ATTEMPT,
    'score': $SCORE,
    'feedback': '''$FEEDBACK''',
    'tokens_coder': $CODEX_TOKENS,
    'tokens_evaluator': $EVAL_TOKENS,
    'duration_sec': $ATTEMPT_DURATION
})
print(json.dumps(data))
")

        # --- Best Score Tracking ---
        if [ "$SCORE" -gt "$BEST_SCORE" ]; then
            BEST_SCORE=$SCORE
            git add -A 2>/dev/null || true
            BEST_COMMIT=$(git stash create 2>/dev/null || echo "")
            git reset HEAD 2>/dev/null || true
        fi

        # --- Decision Logic ---

        # PASS: score meets threshold
        if [ "$SCORE" -ge "$THRESHOLD" ]; then
            log "DECISION: PASS (score $SCORE >= threshold $THRESHOLD)"
            FINAL_STATUS="passed"
            break
        fi

        # STAGNATION: same score as last attempt — accept if close
        if [ "$SCORE" -eq "$PREV_SCORE" ] && [ "$PREV_SCORE" -ge 0 ]; then
            log "DECISION: STAGNATION (same score $SCORE twice)"
            if [ "$SCORE" -ge $((THRESHOLD - 2)) ]; then
                log "Close enough ($SCORE >= $(($THRESHOLD - 2))). Accepting."
                FINAL_STATUS="passed"
            fi
            break
        fi

        # DIMINISHING RETURNS: score dropped
        if [ "$PREV_SCORE" -ge 0 ] && [ "$ATTEMPT" -gt 1 ]; then
            IMPROVEMENT=$((SCORE - PREV_SCORE))
            if [ "$IMPROVEMENT" -le 0 ]; then
                log "DECISION: DIMINISHING (score: $PREV_SCORE -> $SCORE)"
                if [ -n "$BEST_COMMIT" ] && [ "$SCORE" -lt "$BEST_SCORE" ]; then
                    log "Reverting to best attempt (score $BEST_SCORE)"
                    git stash apply "$BEST_COMMIT" 2>/dev/null || true
                    SCORE=$BEST_SCORE
                fi
                if [ "$BEST_SCORE" -ge $((THRESHOLD - 2)) ]; then
                    FINAL_STATUS="passed"
                fi
                break
            fi
        fi

        PREV_SCORE=$SCORE

        # --- Write feedback for next attempt ---
        log "DECISION: RETRY (score $SCORE < threshold $THRESHOLD)"
        {
            echo "# Evaluator Feedback — Feature #$FEATURE_ID, Attempt $ATTEMPT"
            echo ""
            echo "Score: $SCORE/10 (need $THRESHOLD to pass)"
            echo ""
            echo "## Issues to fix:"
            echo "$FEEDBACK"
            echo ""
            echo "## Summary: $SUMMARY"
            echo ""
            echo "Fix ONLY the issues listed above. Do not start the feature over."
        } > "$LOG_DIR/feedback.md"

    done
    # ============================================================
    # END INNER LOOP
    # ============================================================

    FEATURE_END=$(date +%s)
    FEATURE_DURATION=$((FEATURE_END - FEATURE_START))
    LINES_ADDED=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    [ -z "$LINES_ADDED" ] && LINES_ADDED=0

    # --- Handle Result ---
    if [ "$FINAL_STATUS" = "passed" ]; then
        log "PASS: Feature #$FEATURE_ID scored $SCORE/10 in $ATTEMPT attempt(s)"

        mark_feature "$FEATURE_ID" "passes"

        git add -A
        git commit -m "feat(#$FEATURE_ID): ${FEATURE_DESC:0:60} (score: $SCORE/10, $ATTEMPT attempts)" || log "WARNING: git commit failed"
        COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

        METRICS_ENTRY=$(python3 -c "
import json, time
from datetime import datetime, timezone
entry = {
    'id': $FEATURE_ID,
    'description': '''$FEATURE_DESC''',
    'category': '$FEATURE_CATEGORY',
    'status': 'passed',
    'attempts': $ATTEMPT_DATA,
    'final_score': $SCORE,
    'started_at': datetime.fromtimestamp($FEATURE_START, tz=timezone.utc).isoformat(),
    'completed_at': datetime.fromtimestamp($FEATURE_END, tz=timezone.utc).isoformat(),
    'lines_added': $LINES_ADDED,
    'commit_sha': '$COMMIT_SHA'
}
print(json.dumps(entry))
")
        run_metrics_writer --add "$METRICS_ENTRY"

        run_evaluate log \
            --feature-id "$FEATURE_ID" \
            --score "$SCORE" \
            --duration "$FEATURE_DURATION" \
            --tokens-coder "$CODEX_TOKENS" \
            --tokens-evaluator "$EVAL_TOKENS" \
            --status "passed" 2>/dev/null || true

        log_progress "Feature #$FEATURE_ID PASSED (score: $SCORE/10, $ATTEMPT attempts, ${FEATURE_DURATION}s) — $(timestamp)"

        FEATURES_COMPLETED=$((FEATURES_COMPLETED + 1))
        CONSECUTIVE_SKIPS=0

        # Push frequently for deploys
        if (( FEATURES_COMPLETED % PUSH_INTERVAL == 0 )); then
            log "Pushing to origin ($FEATURES_COMPLETED features done)..."
            if [ -n "${NIGHTSHIFT_NO_PUSH:-}" ]; then log "push skipped (NIGHTSHIFT_NO_PUSH set)"; else git push origin HEAD 2>&1 || log "WARNING: git push failed (network?)"; fi
        fi

    else
        log "SKIP: Feature #$FEATURE_ID best score $BEST_SCORE/10 after $ATTEMPT attempts"

        # Revert uncommitted changes for skipped features
        git checkout . 2>/dev/null || true
        git clean -fd 2>/dev/null || true

        mark_feature "$FEATURE_ID" "skipped"
        git add "$FEATURE_FILE"
        git commit -m "skip(#$FEATURE_ID): best score $BEST_SCORE/10 after $MAX_ATTEMPTS attempts" || true

        METRICS_ENTRY=$(python3 -c "
import json, time
from datetime import datetime, timezone
entry = {
    'id': $FEATURE_ID,
    'description': '''$FEATURE_DESC''',
    'category': '$FEATURE_CATEGORY',
    'status': 'skipped',
    'attempts': $ATTEMPT_DATA,
    'final_score': $BEST_SCORE,
    'started_at': datetime.fromtimestamp($FEATURE_START, tz=timezone.utc).isoformat(),
    'completed_at': datetime.fromtimestamp($(date +%s), tz=timezone.utc).isoformat(),
    'lines_added': 0,
    'commit_sha': ''
}
print(json.dumps(entry))
")
        run_metrics_writer --add "$METRICS_ENTRY"

        log_progress "Feature #$FEATURE_ID SKIPPED (best: $BEST_SCORE/10, $ATTEMPT attempts) — $(timestamp)"

        CONSECUTIVE_SKIPS=$((CONSECUTIVE_SKIPS + 1))

        if [ "$CONSECUTIVE_SKIPS" -ge 3 ]; then
            log "WARNING: 3 consecutive skips. Possible systemic issue."
            log_progress "STAGNATION WARNING: 3 consecutive features skipped at $(timestamp)"
            CONSECUTIVE_SKIPS=0
        fi
    fi

    > "$LOG_DIR/feedback.md"

    PASSING_NOW=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FEATURE_FILE')) if f.get('passes')))")
    SKIPPED_NOW=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FEATURE_FILE')) if f.get('skipped')))")
    PENDING=$((TOTAL_FEATURES - PASSING_NOW - SKIPPED_NOW))

    log ""
    log "--- Status: $PASSING_NOW passed / $SKIPPED_NOW skipped / $PENDING pending ---"
    log ""

    sleep 2
done

# --- Final Push ---
log "Final push to origin..."
if [ -n "${NIGHTSHIFT_NO_PUSH:-}" ]; then log "final push skipped (NIGHTSHIFT_NO_PUSH set)"; else git push origin HEAD 2>&1 || log "WARNING: final push failed"; fi

log ""
log "=== AgentForge Ralph Loop Complete ==="
log "=== $(timestamp) ==="
log "=== Features: $FEATURES_COMPLETED completed out of $TOTAL_FEATURES ==="
run_metrics_writer --summary
