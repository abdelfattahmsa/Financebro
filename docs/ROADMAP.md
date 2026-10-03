# Roadmap (each phase ships something you use daily)

**Phase 0 — Foundations (this repo today):** schema, `InformationItem` contract, monorepo, CI.
*Exit:* migration applies cleanly; contract tests pass.

**Phase 1 — Intelligence core (MVP):** RSS/Atom/JSON adapters, `/ingest` for your scrapers, normalize + exact dedupe, FTS,
source management, Expo feed with story clusters (v1 trigram), entity gazetteer.
*Exit:* 30+ sources, no duplicate-story flooding, search works, $0.

**Phase 2 — Portfolio & Markets:** manual holdings/transactions, FRED/Yahoo/CoinGecko providers, P/L, allocation and exposure,
markets glance + watchlists, news↔holding linking ("WHY?").
Includes metals (Stooq) and crypto (CoinGecko) providers.
*Exit:* an "NVDA +4.2%, why?" card with linked stories.

**Phase 2b — Congressional trades:** House PDF and Senate eFD adapters, review queue for low-confidence parses, trades shown on holdings and in the Pulse as disclosed facts with filing lag.
*Exit:* every trade row links to its official filing.

**Phase 3 — Daily Pulse:** significance scoring, extractive-facts → interpretation pipeline, Pulse with evidence links, AI budget guard, push/email delivery.
*Exit:* every Pulse line expands to sources; fact vs interpretation visibly separated.

**Phase 4 — Themes, Trends, Opportunity Radar:** trend z-scores, dynamic themes, embedding clustering, problem-signal mining, radar scoring.

**Phase 5 — Decision Journal & feedback loop:** decisions, evidence snapshots, review reminders, outcome reviews, calibration stats.

**Phase 6 — Customizable dashboard, Market Map, polish; then multi-user hardening and paid data/AI tiers.**

Build order inside a phase: schema → pipeline job → API endpoint → widget.
