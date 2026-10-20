# AGENT.md -- AgentForge Operational Rules

## Identity

You are a coding agent in the Ralph Loop. You build dashboard features one at
a time. The harness (ralph-loop.sh) orchestrates everything: picking features,
running quality gates, scoring, committing, pushing. You write code and exit.

## Workflow

1. Read `.ralph-logs/feedback.md` -- if non-empty, this is a revision. Fix only
   the listed issues; do not restart the feature.
2. Read `feature_list.json` -- find the first entry where `passes` is false and
   `skipped` is not true. That is your ONE task.
3. Read `claude-progress.txt` for context on prior iterations.
4. Implement the feature.
5. Run quality gates (below).
6. Exit. Do NOT commit, push, or modify feature_list.json.

## Quality Gates

Only `npm run build` is enforced by the harness. Lint and test are self-check only --
ralph-loop.sh does NOT run them.

```bash
npm run build    # ENFORCED by harness (node scripts/build.mjs -> next build)
npm run lint     # self-check only -- eslint 9 + eslint-config-next
npm run test     # self-check only -- vitest run
```

If `npm run build` fails, the harness feeds compiler errors into feedback.md
and you get another attempt. Do NOT revert files -- fix the specific errors.

## Data Contract

### metrics.json (harness-owned, read-only to agent)

Written by `metrics_writer.py`. Raw JSON schema (NOT the TypeScript interface):

```
{
  project: string,
  started_at: ISO timestamp,
  features: [{
    id, description, category, status,
    attempts: [{ iteration, score, feedback, tokens_coder, tokens_evaluator, duration_sec }],
    final_score, started_at, completed_at, lines_added, commit_sha, skip_reason
  }],
  totals: {
    tokens_coder: number,        // NOT total_tokens_coder
    tokens_evaluator: number,    // NOT total_tokens_evaluator
    cost_usd: number,
    elapsed_sec: number          // NO features_completed or total_iterations
  }
}
```

> useMetrics.ts normalizes these fields -- the TypeScript types differ from the raw JSON.
> It checks for both `tokens_coder` and `total_tokens_coder` with fallback.

### feature_list.json (spec, immutable)

Array of 30 features. Each has: id, category, description, verify, passes.
8 categories: scaffold (4), cards (4), timeline (5), quality (5),
features (4), tokens (3), git (2), polish (3).
json_guard.py enforces immutability -- only `passes` and `skipped` may flip.

Reference the file for full specs. Do not inline all 30 here.

## Commit Convention

The harness applies this format automatically:

```
feat(#ID): description (score: X/10, N attempts)
skip(#ID): best score X/10 after N attempts
```

Do NOT commit yourself. The harness owns git operations.

## Component Patterns

### Client vs Server Components
- Default is server component (no directive needed).
- Add `"use client"` only when the component uses hooks, event handlers,
  or browser APIs. All chart components and interactive components need it.
- Layout (`layout.tsx`) is a server component. AppShell is a client component.
- Exception: `tokens/page.tsx` has "use client" -- only page with the directive.

### Recharts Usage
- recharts is the only chart library. Import from `"recharts"`.
- Chart types used: LineChart, BarChart, AreaChart, PieChart, ScatterChart,
  ComposedChart (dual-axis).
- All charts wrapped in `<ResponsiveContainer width="100%" height="100%">`.
- Tooltip contentStyle uses zinc-900 dark theme colors.
- Use `any` for recharts callback props when their types are problematic.

### useMetrics Hook
- Single data access pattern. Every data component calls `useMetrics()`.
- Returns `{ data: MetricsData, isLoading: boolean, error: string | null }`.
- Polls every 30 seconds (METRICS_POLL_INTERVAL_MS = 30000).
- Robust parsing: handles missing fields, wrong types, partial data.
- EMPTY_METRICS_DATA provides safe defaults for zero-state.

### Skeleton Loading
- `MetricsSectionSkeleton` with variants: card, chart, table, feed, panel.
- Every component shows skeleton while isLoading is true.

### Empty Data Handling
- 0 completed features = descriptive empty-state message, NEVER a crash.
- Every component handles undefined, [], and 0 gracefully.
- Components derive data from features array, not just totals, so they work
  with partial data during the build.

## Styling

- Tailwind v4 classes for all styling. globals.css has Tailwind import + `color-scheme: dark`, `box-sizing`, `body margin: 0`.
- Dark theme: bg-zinc-950 base, zinc-900/50 card backgrounds, zinc-800 borders.
- Emerald for pass/positive, rose/red for fail, amber for warnings/skipped.
- Cards: rounded-xl border border-zinc-800 bg-zinc-900/50 p-5.

## Deploy

Vercel auto-deploys on push to main. No manual deploy step.
Build must pass locally -- Vercel rejects TypeScript errors.
No .env files or external services required. Single static JSON data source.

## Known Issues from Code Inspection

1. Architecture page hardcodes "Next.js 16" in StackItem -- actual dep is Next 15.
2. Architecture page stats hardcode "29 / 30" -- not derived from metrics.json.
3. Tokens page hardcodes model names/costs as static JSX, not from data.
4. metrics.json totals use `tokens_coder`/`tokens_evaluator` as field names;
   useMetrics also checks for `total_tokens_coder`/`total_tokens_evaluator`
   with fallback, so both shapes work.
5. Feature #3 (dark mode toggle) is permanently skipped.

## Evaluator Scoring

Three dimensions, weighted:
- Completeness (40%): Feature fully implements the spec.
- Visual Quality (30%): Professional look, dark mode, responsive.
- No Placeholders (30%): Zero TODOs, stubs, lorem ipsum.

Thresholds (ralph-loop.sh actual values):
- scaffold: 4/10
- git, polish: 5/10
- all others (default): 5/10

> EVALUATOR.md recommends higher thresholds (scaffold 5, content 7, polish 6)
> but ralph-loop.sh uses lower ones shown above.

The evaluator (evaluate.py) calls Claude Sonnet 4 via the Anthropic API.
Falls back to auto-pass (score 5) if the API client is unavailable.

## Gotchas

- Dev server port: init.sh uses 3000, ralph-loop.sh uses 3001.
- `gtimeout` (GNU timeout via coreutils) required on macOS for ralph-loop.sh.
- Inner loop has stagnation detection and diminishing returns logic beyond MAX_ATTEMPTS.

## Harness Configuration (ralph-loop.sh)

| Parameter | Value |
|-----------|-------|
| MAX_ATTEMPTS | 3 |
| PLAN_INTERVAL | Every 10 iterations |
| PUSH_INTERVAL | Every 2 completed features |
| CODEX_TIMEOUT | 420s (7 minutes) |
| CODEX_MODEL | gpt-5.3-codex |

Accepts flags: --features, --prompt, --plan-prompt, --project-dir.

## Pre-Flight Checklist

Before starting any feature:
- [ ] Read `.ralph-logs/feedback.md` (revision context)
- [ ] Read the feature spec from `feature_list.json`
- [ ] Read `claude-progress.txt` (session history)
- [ ] Confirm `npm run build && npm run lint && npm run test` pass
- [ ] Check that useMetrics hook exists at `src/hooks/useMetrics.ts`
- [ ] One component per file in `src/components/`
- [ ] Handle empty/partial metrics data in every new component
