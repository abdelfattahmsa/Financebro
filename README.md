# Financebro — Personal Intelligence & Decision-Support OS

Collect → Organize → Analyze → Connect → Surface Insights → Support Decisions → Track Outcomes

Answers three questions: **INVEST** (markets → my portfolio), **BUILD** (problems/trends → products),
**UNDERSTAND** (what happened in the world that matters to me). It supports decisions; it never makes them.

| Doc | Purpose |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design: principles, pipeline, free-tier budget, fact/interpretation model, risks |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Phased build plan with exit criteria |
| [supabase/migrations/0001_core.sql](supabase/migrations/0001_core.sql) | Core Postgres schema (RLS on) |
| [packages/core](packages/core) | Shared `InformationItem` contract + deterministic normalize/dedupe |
