#!/bin/bash
# AgentForge — Environment Setup
# Run once at hackathon start to bootstrap the project
set -euo pipefail

echo "=== AgentForge Init ==="
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
command -v node >/dev/null 2>&1 || { echo "FAIL: Node.js required (brew install node)"; exit 1; }
command -v codex >/dev/null 2>&1 || { echo "FAIL: Codex CLI required (npm install -g @openai/codex)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: Python 3 required"; exit 1; }
command -v gtimeout >/dev/null 2>&1 || { echo "FAIL: gtimeout required (brew install coreutils)"; exit 1; }
echo "  node $(node --version)"
echo "  codex $(codex --version 2>/dev/null || echo 'unknown')"
echo "  python3 $(python3 --version 2>&1 | awk '{print $2}')"

# --- API Keys ---
echo ""
echo "Checking API keys..."
[ -n "${OPENAI_API_KEY:-}" ] && echo "  OPENAI_API_KEY: set" || { echo "  FAIL: OPENAI_API_KEY not set"; exit 1; }
[ -n "${ANTHROPIC_API_KEY:-}" ] && echo "  ANTHROPIC_API_KEY: set" || { echo "  FAIL: ANTHROPIC_API_KEY not set"; exit 1; }

# --- W&B ---
echo ""
echo "Checking W&B..."
python3 -c "import weave; print('  weave %s' % weave.__version__)" 2>/dev/null || {
    echo "  Installing weave..."
    pip3 install --user weave 2>/dev/null
}
[ -f ~/.netrc ] && grep -q "api.wandb.ai" ~/.netrc && echo "  W&B: authenticated" || echo "  WARNING: W&B not authenticated. Run: python3 -m wandb login"

# --- Anthropic SDK ---
python3 -c "import anthropic; print('  anthropic %s' % anthropic.__version__)" 2>/dev/null || {
    echo "  Installing anthropic..."
    pip3 install --user anthropic 2>/dev/null
}

# --- Scaffold Next.js app (if not already scaffolded) ---
echo ""
if [ ! -f package.json ]; then
    echo "Scaffolding Next.js app..."
    npx create-next-app@latest . --typescript --tailwind --eslint --app --src-dir --no-import-alias --yes
    echo "Installing additional deps..."
    npm install recharts
    npm install -D vitest @testing-library/react @testing-library/jest-dom jsdom
else
    echo "package.json exists, skipping scaffold."
    echo "Installing deps..."
    npm install
fi

# --- Vitest config ---
if [ ! -f vitest.config.ts ]; then
    echo "Creating vitest.config.ts..."
    cat > vitest.config.ts << 'VITEST'
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
  },
})
VITEST
fi

# --- Add test script if missing ---
if ! grep -q '"test"' package.json 2>/dev/null; then
    python3 -c "
import json
with open('package.json') as f:
    pkg = json.load(f)
pkg.setdefault('scripts', {})['test'] = 'vitest run'
with open('package.json', 'w') as f:
    json.dump(pkg, f, indent=2)
    f.write('\n')
"
    echo "Added test script to package.json"
fi

# --- Ensure public/metrics.json exists ---
mkdir -p public
if [ ! -f public/metrics.json ]; then
    cp public/metrics.json public/metrics.json 2>/dev/null || cat > public/metrics.json << 'METRICS'
{
  "project": "AgentForge",
  "started_at": null,
  "features": [],
  "totals": {
    "tokens_coder": 0,
    "tokens_evaluator": 0,
    "cost_usd": 0.0,
    "elapsed_sec": 0
  }
}
METRICS
fi
echo "public/metrics.json ready"

# --- Create .ralph-logs ---
mkdir -p .ralph-logs
touch .ralph-logs/feedback.md

# --- Verify Vercel ---
echo ""
if [ -d .vercel ]; then
    echo "Vercel: linked ($(cat .vercel/project.json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('projectId','unknown'))" 2>/dev/null || echo "unknown"))"
else
    echo "WARNING: Vercel not linked. Run: vercel link"
fi

# --- Git state ---
echo ""
echo "Git status:"
echo "  Remote: $(git remote get-url origin 2>/dev/null || echo 'none')"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "  Commits: $(git rev-list --count HEAD 2>/dev/null || echo '0')"

# --- Initial commit if there are changes ---
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo ""
    echo "Committing scaffold..."
    git add -A
    git commit -m "init: Next.js scaffold + AgentForge harness"
    git push origin main 2>/dev/null || echo "WARNING: push failed"
fi

# --- Build test ---
echo ""
echo "Testing build..."
if npm run build --silent > /dev/null 2>&1; then
    echo "  Build: PASSING"
else
    echo "  Build: FAILING (check errors above)"
fi

# --- Start dev server ---
echo ""
echo "Starting dev server..."
# Kill any existing dev server
[ -f .dev-pid ] && kill "$(cat .dev-pid)" 2>/dev/null || true
npm run dev > .ralph-logs/dev-server.log 2>&1 &
DEV_PID=$!
echo $DEV_PID > .dev-pid
echo "  Dev server PID: $DEV_PID"

# Wait and verify
sleep 5
if curl -s --max-time 3 http://localhost:3000 > /dev/null 2>&1; then
    echo "  Dev server: RUNNING at http://localhost:3000"
else
    echo "  Dev server: NOT READY (may need more time)"
fi

# --- Summary ---
echo ""
echo "=== AgentForge Init Complete ==="
echo ""
echo "Next steps:"
echo "  1. Quick test: codex exec \"\$(cat PROMPT_build.md)\" --full-auto -m gpt-5.3-codex"
echo "  2. Verify feature #1 was built correctly"
echo "  3. At 12:30: tmux new -s ralph && caffeinate -s && ./graveyard.sh"
echo ""
echo "Make scripts executable:"
echo "  chmod +x graveyard.sh init.sh"
