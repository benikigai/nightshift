# CHANGELOG

## 2026-05 -- LLM Resilience

- feat: triple-fallback `extract_json()` helper for Sonnet evaluator responses. Replaces inline `re.search(r'\{[\s\S]*\}')` in `evaluate.py` with helper that handles direct `json.loads` → ```` ```json``` ```` fences → first/last-brace span. Pattern lifted from NatSec 2026 hackathon-winners corpus (`argus-oracle/src/components/oracle/lib/claude.ts:13-39`). AST parse OK + 5 manual cases pass.

## 2026-04 -- Harness Portability & Architecture Page

- `9e235d7` feat: make ralph-loop.sh accept external paths for spec-driven integration
- `bfe7935` copy: rewrite hero -- observability + reusable harness
- `afc325e` copy: reframe AI Application as agent observability
- `d5852d2` feat: judging criteria cards on architecture page
- `fbe5c78` copy: replace braggy line with harness explanation
- `3622836` copy: tone down hero text
- `c7c5955` feat: elevator pitch hero copy
- `06996f0` feat: hero elevator pitch on architecture page
- `8ae475b` feat: architecture page with failure recovery + build time cards on overview
- `9abf75f` feat: architecture page + enhanced tokens page with model details

## 2026-03 -- Data Backfill & Polish

- `ebd4938` data: add real lines_added from git stats (~4056 total)
- `83afb80` data: add realistic multi-attempt iteration data for demo
- `190ed4d` data: use real git timestamps for feature durations
- `e987a45` fix: sparkline type error for Vercel build
- `49e9926` data: backfill metrics.json from git history (30 features)

## 2026-03-28 -- Feature Build (29/30 passed, 1 skipped, ~76 minutes)

- `43483ca` feat(#30): Auto-refresh -- polls metrics.json every 30s (9/10, 1 attempt)
- `60d5cbf` feat(#29): Responsive layout, hamburger nav on mobile (10/10, 1 attempt)
- `6016520` feat(#28): Loading skeletons with pulse animation (9/10, 3 attempts)
- `7884044` feat(#27): Code volume sparkline in commit feed (10/10, 1 attempt)
- `2b8bdf5` feat(#26): Commit log feed with score badges (10/10, 1 attempt)
- `d240056` feat(#25): Running total cost + projection chart (10/10, 1 attempt)
- `4e98553` feat(#24): Cost per feature line chart (10/10, 1 attempt)
- `55ddf23` feat(#23): Token spend pie chart (10/10, 1 attempt)
- `e9914fa` feat(#22): Feature timeline Gantt chart (10/10, 1 attempt)
- `a22c1bf` feat(#21): Search + category filter for feature table (10/10, 1 attempt)
- `41778b3` feat(#20): Expandable detail panel in feature table (10/10, 1 attempt)
- `4ef4c79` feat(#19): Sortable feature data table (10/10, 1 attempt)
- `ecc8a0b` feat(#18): Skipped features panel (10/10, 1 attempt)
- `cbf8d61` feat(#17): Improvement trend scatter + regression line (10/10, 1 attempt)
- `da394a1` feat(#16): Category average score bar chart (10/10, 1 attempt)
- `5a9b188` feat(#15): First-vs-final score scatter plot (10/10, 1 attempt)
- `abe7492` feat(#14): Score distribution histogram (9/10, 1 attempt)
- `59e4e30` feat(#13): Dual-axis quality + iterations combo chart (8/10, 2 attempts)
- `91a699d` feat(#12): Iterations stacked bar chart (10/10, 1 attempt)
- `1b048d6` feat(#11): Feature duration area chart (10/10, 1 attempt)
- `bc714b1` feat(#10): Quality score per feature bar chart (10/10, 1 attempt)
- `7a92bad` feat(#9): Cumulative completion line chart (10/10, 1 attempt)
- `70c6af3` feat(#8): Total tokens + cost stat card (10/10, 1 attempt)
- `72c8769` feat(#7): Total iterations stat card (10/10, 1 attempt)
- `e47765c` feat(#6): Average quality score + trend card (9/10, 2 attempts)
- `7bc6369` feat(#5): Feature completion progress card (9/10, 2 attempts)
- `20345f9` feat(#4): Typed useMetrics hook + TS interfaces (10/10, 1 attempt)
- `536d7d9` skip(#3): dark mode toggle -- 3 attempts, best 3/10 (harness revert bug)
- `74c6ebe` feat(#2): App shell + sidebar nav (9/10, 2 attempts)
- `b5460df` feat(#1): Next.js scaffold + dark theme (9/10, 2 attempts)

## Pre-Build

- `7d79bb5` clean slate: demo run 12:48
- `e9ef3c1` fix: harness overhaul -- stop nuking code on build failure
- `9caf2c7` harness: complete rewrite for self-referential metrics dashboard
- `d852075` init: existing harness files

Earlier entries: `archive/CHANGELOG_ARCHIVE.md`

## Renamed to Nightshift — 2026-06-15
- AgentForge → **Graveyard** (the overnight build loop of the Nightshift stack).
- Path: ~/code/forge/agentforge → ~/code/nightshift/graveyard. GitHub: benikigai/AgentForge → benikigai/nightshift-graveyard.
- Renamed ralph-loop.sh → graveyard.sh (git mv). Usage strings updated. AGENTFORGE_HOME var retained (self-resolving).
- Spec: ../brief/docs/specs/nightshift-v2.md (Task 1).
