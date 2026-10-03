# Data sources: metals, crypto, congressional trades

Status key: **verified** = confirmed in research (Oct 2026); **check** = confirm limits/terms before building.

## Metals
| Need | Source | Cost | Granularity | Status |
|---|---|---|---|---|
| Gold, silver, platinum, palladium spot | Stooq CSV (`xauusd`, `xagusd`, ...) | Free | End of day | check symbols |
| Copper, other futures | Stooq (`hg.f`); Yahoo `HG=F` as fallback | Free | End of day | Yahoo is unofficial |
| Monthly benchmark prices | World Bank Pink Sheet; FRED (e.g. global copper) | Free | Monthly | check series |
| Near-live spot | Free-key APIs such as MetalCharts or Metals-API | Free tier, key required | Hourly or slower | check limits, free tiers are small |
| Metals-linked equities/ETFs | Twelve Data / Finnhub (see research) | Free tier | Delayed | verified |

Plan: Stooq as primary, one free-key API as cross-check, `MarketProvider` interface so either can be swapped.

## Crypto
| Need | Source | Cost | Notes | Status |
|---|---|---|---|---|
| Prices, market cap, history | CoinGecko Demo | Free, 100 req/min, 10k credits/month | Cache in KV; sync daily closes to `prices_daily` | verified |
| Exchange prices | Binance / Coinbase public market-data endpoints | Free, no key | Regional access limits | check |
| DeFi, stablecoin, chain TVL | DefiLlama | Free | Good "market health" signal | check |
| Sentiment | Alternative.me Fear & Greed index | Free | Context only | check |

## Congressional trades (STOCK Act disclosures)
| Chamber | Official source | Format | Difficulty |
|---|---|---|---|
| House | Clerk disclosure site, daily ZIP/index of filings | Mostly PDFs; some are scanned paper | Medium: PDF text extraction plus review queue (`parse_confidence`) |
| Senate | eFD search (`efdsearch.senate.gov`) | Structured web forms | Medium: requires accepting the agreement; bot protection, so run from a home IP |
| Either | Free aggregator APIs (e.g. Bargo.ai) | JSON | Easy, but new and unproven: use to bootstrap and cross-check, not as sole source |
| Either | Apify actors, Quiver | Paid | Not needed at $0 |

Plan: official sources are canonical; every `disclosed_trades` row links to its filing (`source_url`).

### How to read this data (and how the app should present it)
- **Delayed**: filings arrive up to about 45 days after the trade. Show `lag_days` on every row.
- **Ranges, not amounts**: only a value range is disclosed. Store `amount_min`/`amount_max`; never show a single number.
- **Includes family**: `owner` marks self, spouse, dependent.
- **Fact vs interpretation**: the disclosure is a FACT. "Politician X may have information advantage" is speculation and must never be generated. Allowed interpretations are limited to pattern descriptions (for example "6 members bought semiconductors in 30 days") with the filings as evidence.
- **Legal**: US law restricts using these reports for commercial purposes, solicitation or fundraising. Personal use is fine; **get this checked before turning the product commercial**.

## Pipeline
`stooq / coingecko adapters` (daily cron, Worker + KV) → `prices_daily`.
`congress adapter` (GitHub Actions or home runner: fetch index → download new filings → parse → upsert on `(source_doc_id, line_no)`) → `disclosed_trades`.
Trades with a ticker link to `instruments`/`entities`, so they surface as "WHY?" context on holdings and in the Daily Pulse.
