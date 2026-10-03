# Financebro — Personal Intelligence & Decision-Support OS

Collect → Organize → Analyze → Connect → Surface Insights → Support Decisions → Track Outcomes

Answers three questions: **INVEST** (markets → my portfolio), **BUILD** (problems/trends → products),
**UNDERSTAND** (what happened in the world that matters to me). It supports decisions; it never makes them.

| Doc | Purpose |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design: principles, pipeline, free-tier budget, fact/interpretation model, risks |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Phased build plan with exit criteria |
| [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) | Free sources for metals, crypto and congressional trades, with caveats |
| [supabase/migrations/0001_core.sql](supabase/migrations/0001_core.sql) | Core Postgres schema (RLS on) |
| [supabase/migrations/0002_metals_crypto_congress.sql](supabase/migrations/0002_metals_crypto_congress.sql) | Politicians and disclosed trades |
| [packages/core](packages/core) | Shared `InformationItem` contract + deterministic normalize/dedupe |
