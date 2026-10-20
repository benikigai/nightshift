# AgentForge — Operational Guide

## Project
Self-referential metrics dashboard that visualizes its own autonomous build process. A Ralph Loop builds this app feature by feature. Each completed feature adds data to `public/metrics.json`. The dashboard charts, cards, and tables display that data — showing the agent's progress, quality scores, token spend, and git history in real-time.

The app IS the demo. Every chart is evidence of the process that created it.

## Tech Stack
- **Framework**: Next.js 15 (App Router, `src/` directory)
- **Language**: TypeScript (strict mode)
- **Styling**: Tailwind CSS v4 with dark mode (class strategy)
- **Charts**: recharts (ALL visualizations — Line, Bar, Area, Pie, Scatter, etc.)
- **Tests**: vitest
- **Deploy**: Vercel (auto-deploy on git push to main)

## Data Architecture
- **Single data source**: `public/metrics.json`
- This file is written by the harness (`ralph-loop.sh`), NOT by the coding agent
- Read via `useMetrics()` hook in `src/hooks/useMetrics.ts`
- Data grows as features complete — early features render with partial data
- Handle empty/missing data gracefully: 0 features = empty state message, NOT an error
- No database. No SQLite. No external services. Just one JSON file.

## Page Structure (maps to sidebar nav)
- `/` — Overview: stat cards (features 5-8)
- `/timeline` — Build Timeline: charts showing progress over time (features 9-13)
- `/quality` — Quality Analysis: score distributions and trends (features 14-18)
- `/features` — Feature Table: detailed list with drill-down (features 19-22)
- `/tokens` — Token Economics: cost analysis (features 23-25)
- `/git` — Git Visualization: commit feed and code volume (features 26-27)

## Code Style
- `'use client'` directive ONLY on components that need interactivity (charts, toggles, search inputs)
- Server components by default
- Tailwind classes for all styling — no CSS files
- recharts for all charts — import from 'recharts'
- One component per file in `src/components/`
- Types in `src/types/` or co-located with components

## Feedback Loops (run before finishing)
```bash
npm run build    # Must succeed — no TypeScript errors
npm run lint     # Must pass — no lint warnings
```

## Commit Convention (harness applies this, not the agent)
```
feat(#ID): description (score: X/10, N attempts)
```

## Key Files
- `feature_list.json` — 30 features, source of truth for what to build
- `public/metrics.json` — build metrics, source of truth for dashboard data
- `claude-progress.txt` — session log, read at start of each iteration
- `PROMPT_build.md` — instructions for the coding agent (you)
- `.ralph-logs/feedback.md` — evaluator feedback for revision attempts
