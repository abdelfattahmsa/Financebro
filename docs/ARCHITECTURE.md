# Architecture

## 1. Principles (in priority order)
1. **$0 until there are users.** Every component has a free tier; costs scale with usage.
2. **One contract:** everything becomes an `InformationItem` (RSS, API, your scrapers, gov sites, Reddit later).
3. **Deterministic first, AI last.** Ingest/normalize/dedupe/classify/entity-match without LLMs. LLMs only for
   cluster summaries, Daily Pulse, trend/opportunity narratives, personalized insights — and only over *pre-filtered* input.
4. **Traceability.** No insight exists without links to the items/data points it came from.
5. **Facts ≠ interpretation.** Enforced in the schema, not just the prompt (see §4).
6. **Single-user-first, multi-tenant-ready.** `user_id` + RLS on every user-owned table from day one.
7. **Modular adapters.** New source type = one adapter file; no pipeline changes.

## 2. System shape

```
Expo app (iOS/Android/Web) ── Supabase Auth JWT ──► Cloudflare Worker "api" (Hono)
                                                        │ reads (KV-cached)   │ writes
Your scrapers (GitHub Actions / VPS / local) ─POST /ingest (API key)─►        ▼
Cloudflare Cron ► Worker "pipeline" ► Queue ► consumers  ──►  Supabase Postgres (+pgvector, FTS)
                                                               R2 (images, raw snapshots)
Scheduled "analyze" jobs (clusters → trends → pulse) ──► LLM (budgeted) ──► insights (+evidence links)
```

Two Worker deployables from one monorepo: `api` (user-facing, thin) and `pipeline` (cron + queue consumers).
The app uses the API for anything needing joins/compute/caching, and may read simple user tables directly via the
Supabase client under RLS (watchlists, dashboards) to avoid writing CRUD endpoints.

### Why a Queue between ingest and process
Free-plan Workers have tight limits (≈10 ms CPU, ≈50 subrequests per invocation, few cron triggers). One cron
invocation cannot fetch 200 feeds. Pattern: cron enqueues "fetch source X" messages (Cloudflare Queues has a free tier);
each consumer fetches one source using conditional GET (`ETag`/`If-Modified-Since`), so most fetches are near-free.
Heavy or Worker-unfriendly work (headless scraping, backfills) runs in **GitHub Actions cron** and pushes to `/ingest`.
*Verify current free-tier numbers before committing; they change.*

## 3. Pipeline (stages, cost, where it runs)

| # | Stage | Method | AI? |
|---|---|---|---|
| 1 | Collect | adapters: rss/atom/jsonfeed/api/scraper/rsshub/gov | no |
| 2 | Normalize | → `InformationItem`; canonical URL, strip tracking params, HTML→text, language detect | no |
| 3 | Dedupe (exact) | `url_hash`, `content_hash` unique keys | no |
| 4 | Entities | gazetteer match (companies/tickers/countries/tech) from `entities` + `entity_aliases`; ambiguous cases flagged | no (LLM only for unresolved, batched, cached) |
| 5 | Categorize/topics | keyword + source-category rules → `topics`; later a small classifier | no |
| 6 | Event significance | source authority × cluster size × recency × entity weight × user relevance | no |
| 7 | Cluster | v1: title trigram + shared entities within 48h. v2: embeddings (pgvector) | v2 embeddings only |
| 8 | Trends | z-score of daily entity/topic/cluster counts vs 30-day baseline | no |
| 9 | Asset linking | entity → company → instrument → holding; industry/theme edges | no |
| 10 | Personalize | rank by user interests, holdings, watchlists | no |
| 11 | Synthesize | cluster summaries, Daily Pulse, opportunity narratives | **yes**, budgeted |

**AI budget guard:** `ai_usage` table + daily token cap per job. Pulse input is top-N clusters (~30–50), never raw articles.
Cache by `(prompt_version, input_hash)` so reruns are free.

## 4. Facts vs interpretation (enforced)
Chain: **FACT → SOURCE → INTERPRETATION → IMPLICATION → MY ASSESSMENT**

- `insights.kind ∈ {fact, interpretation, implication, question}`.
- `insight_evidence` links an insight to items / clusters / market data points. A DB trigger rejects `fact` insights
  with zero evidence; interpretations must reference ≥1 `fact` insight via `based_on`.
- `assessments` (yours) is a separate table; AI never writes to it.
- Facts come from an **extractive** pass (claims attributed to items); interpretations from a second pass that receives only
  the facts, is labelled *model-generated*, and carries `confidence` and `assumptions[]`. The UI styles them differently.
- Opportunity Radar outputs **signals + strength + evidence**, never "good investment" language. Prompts forbid recommendations;
  a post-check rejects banned phrasing.

## 5. Data model (see `supabase/migrations/0001_core.sql`)
Domains: **sources/items** → **entities/topics/clusters/themes** → **instruments/prices/indicators** →
**portfolios/holdings/transactions/watchlists** → **insights/evidence/assessments** → **decisions/reviews** → **profiles/dashboards**.

Key choices:
- One `entities` table (company, person, country, technology, industry, asset…) plus `entity_links` edges
  (company→industry, company→instrument, …). This graph powers News → Companies → Industries → Assets → Portfolio with
  plain recursive SQL; no graph DB.
- **Themes are dynamic:** `themes` are created from trend/cluster co-occurrence (or by you); `theme_members` link entities/topics;
  lifecycle `emerging → active → fading`. No fixed taxonomy.
- **Markets:** `instruments` (any priceable thing) + `prices_daily` + `indicators`/`indicator_points`. Intraday lives in KV only (storage budget).
- **Portfolio:** `transactions` are the source of truth; holdings are derived (view). Multi-currency, FX rates are instruments.
- **Storage budget:** Supabase free DB ≈ 500 MB. Truncate item `content` (~8 KB), keep raw snapshots in R2 only when flagged,
  prune low-significance items older than ~90 days (clusters/insights retained).
- **Search:** generated `tsvector` + GIN. **Embeddings:** `vector(384)` on clusters first (far fewer rows than items).

## 6. Market data (free-first; check each provider's ToS)
Equities/ETF/FX/crypto: Yahoo (unofficial), Stooq, Alpha Vantage/Twelve Data (small quotas), CoinGecko.
Rates/macro: **FRED** (US yields, CPI, GDP), ECB/Frankfurter (FX), World Bank/IMF (country macro), central-bank sites (e.g. CBE) via scrapers.
Egyptian data (EGX, EGP rates, CBE) is the weakest free coverage → plan custom scrapers. Put every provider behind a
`MarketProvider` interface so a paid feed can be swapped in. Unofficial endpoints are fine for a personal MVP and a risk for a commercial product.

## 7. Market-at-a-glance logic
Arrows are computed, not AI: breadth-weighted % change over a window (1d/1w/1m) per group, mapped to ↑ → ↓ with a dead-band
(e.g. ±0.3% daily, tuned per asset class). Drill-down is the same rollup at each level of
`region → country → asset class → sector → instrument` via `instrument_groups`. The Market Map (treemap/choropleth) reads that rollup endpoint.

## 8. Personalization & dashboard
`interest_profiles` (topics, countries, entities, languages, weights) feed the ranker. A dashboard is a JSON layout per user
(`dashboards.layout`: `{widget_type, x, y, w, h, config}[]`); widgets are an app-side registry, each declaring its data endpoint.
Web uses a drag grid; mobile a reorderable list from the same layout.

## 9. Frontend
Expo + React Native + TS, Expo Router, NativeWind, Reanimated, TanStack Query (cache/offline), Supabase JS for auth.
Navigation: Overview · Intelligence · Markets · Portfolio · Opportunities · Ideas · Decisions · Watchlists · Settings.
Every card shows *what changed*, *why it matters* (labelled interpretation) and a *Sources* affordance.

## 10. Security & ops
RLS on all user data; service-role key only inside Workers; `/ingest` uses per-scraper API keys (stored hashed) and rate limits;
secrets via Wrangler secrets. Scrapers: honor robots.txt/ToS, identify the UA, cache aggressively.
CI: GitHub Actions (lint, typecheck, tests, migrations, `wrangler deploy`).

## 11. Known risks
- **Supabase free projects pause after ~1 week of inactivity** — cron activity keeps it warm; add a heartbeat as a guard.
- **Free Worker CPU/subrequest limits** shape the queue design.
- **Market-data licensing/rate limits**; EGX availability.
- **LLM cost drift:** enforce caps and caching from the first LLM call.
- **Entity ambiguity** ("Apple", "Meta", "Shell") is the main quality risk of deterministic matching — ticker/context rules + a review queue.
- **Scope:** the roadmap gets a daily-useful loop working in phase 1 rather than building everything at once.
