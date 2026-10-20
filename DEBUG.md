# DEBUG.md -- AgentForge Runtime State

## Current Objective

Post-build polish. Copy refinements on architecture page.
Harness portability: ralph-loop.sh now accepts --features, --prompt, --project-dir.

## Deploy Status

- **Vercel**: Live, auto-deploys from main (repo: benikigai/AgentForge)
- **Build**: Passing (next build via scripts/build.mjs)
- **Branch**: main

## Feature Completion: 29/30

| Status | Count | Details |
|--------|-------|---------|
| Passed | 29 | #1-2, #4-30 |
| Skipped | 1 | #3 (dark mode toggle -- git checkout bug wiped code on each retry) |
| Pending | 0 | -- |

Score distribution: 21 features scored 10/10, 7 scored 9/10, 1 scored 8/10 (#13).
Average final score: 9.7/10 across 29 passed features.
Total build time: ~76 minutes, ~4056 lines added.

## Active Anomalies

1. **Architecture page says "Next.js 16"** -- package.json has next ^15.0.0.
   File: `src/app/architecture/page.tsx`, StackItem title "App Framework".
2. **Architecture page stats hardcoded** -- "29 / 30", "9.5 / 10", "78 min"
   are static strings, not derived from metrics.json.
3. **Tokens page model cards are static** -- GPT-5.3 Codex and Sonnet 4
   details hardcoded as JSX, not from metrics data.
4. **metrics.json totals missing standard fields** -- Uses `tokens_coder` /
   `tokens_evaluator` instead of `total_tokens_coder` / `total_tokens_evaluator`.
   The useMetrics hook handles both shapes via fallback, so no runtime error.
5. **No .nvmrc or engines field** -- Node version not pinned anywhere.
6. **Sidebar has 7 nav links, not 6** -- Architecture page added post-build,
   feature spec not updated.
7. **Dev server port inconsistency** -- init.sh uses 3000, ralph-loop.sh uses 3001.

## Recent Changes

- ralph-loop.sh refactored to accept external feature/prompt/project paths
- Architecture page: hero copy, judging criteria, failure recovery section
- metrics.json backfilled from git history with real timestamps and line counts

## Infrastructure

| Component | Detail |
|-----------|--------|
| Repo | benikigai/AgentForge |
| Host | Vercel (auto-deploy) |
| Branch | main |
| Framework | Next.js 15, React 19, Tailwind v4 |
| Charts | recharts 2.15.4 |
| Test | vitest 2.x |
| CI | Vercel build only (no separate pipeline) |
