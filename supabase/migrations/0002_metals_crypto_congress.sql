-- Metals, crypto and congressional trade disclosures.
-- Metals/crypto reuse instruments + prices_daily from 0001; only congress needs new tables.

create type member_chamber as enum ('house','senate');
create type trade_owner as enum ('self','spouse','dependent','joint','unknown');

create table politicians (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  chamber member_chamber not null,
  party text, state text, district text,
  bioguide_id text unique,            -- stable id from the congress.gov bioguide
  entity_id uuid references entities(id) on delete set null,
  active boolean not null default true,
  unique (chamber, full_name, state)
);

-- One row per transaction line of a Periodic Transaction Report (PTR).
-- Amounts are DISCLOSED RANGES, never exact values. Filing lags the trade (up to ~45 days).
create table disclosed_trades (
  id uuid primary key default gen_random_uuid(),
  politician_id uuid not null references politicians(id) on delete cascade,
  owner trade_owner not null default 'unknown',
  asset_name text not null,
  ticker text,
  asset_type text,                              -- as reported: stock, option, bond, fund, crypto...
  instrument_id uuid references instruments(id) on delete set null,
  entity_id uuid references entities(id) on delete set null,   -- company, for news linkage
  tx_type text not null check (tx_type in ('purchase','sale','sale_partial','exchange','other')),
  tx_date date not null,
  filed_date date not null,                     -- disclosure lag = filed_date - tx_date
  amount_min numeric,
  amount_max numeric,
  source_url text not null,                     -- link to the official filing
  source_doc_id text not null,                  -- Clerk DocID / Senate report id
  line_no int not null default 0,
  parser text not null default 'manual',        -- 'house_pdf' | 'senate_efd' | 'aggregator' | 'manual'
  parse_confidence real not null default 1,     -- low = needs review (PDF extraction)
  created_at timestamptz not null default now(),
  unique (source_doc_id, line_no)
);
create index disclosed_trades_pol_idx on disclosed_trades (politician_id, tx_date desc);
create index disclosed_trades_ticker_idx on disclosed_trades (ticker, tx_date desc);
create index disclosed_trades_filed_idx on disclosed_trades (filed_date desc);

-- Disclosed trades can be cited as evidence for insights (kept traceable like items).
alter table insight_evidence drop constraint insight_evidence_check;
alter table insight_evidence add column disclosed_trade_id uuid references disclosed_trades(id) on delete set null;
alter table insight_evidence add constraint insight_evidence_one_ref
  check (num_nonnulls(item_id, cluster_id, instrument_id, indicator_id, disclosed_trade_id) = 1);

alter table politicians enable row level security;
create policy politicians_read on politicians for select to authenticated using (true);
alter table disclosed_trades enable row level security;
create policy disclosed_trades_read on disclosed_trades for select to authenticated using (true);

-- Disclosure-lag helper for the UI ("filed 38 days after trade").
create view disclosed_trades_enriched with (security_invoker = true) as
select t.*, p.full_name, p.chamber, p.party, p.state, (t.filed_date - t.tx_date) as lag_days
from disclosed_trades t join politicians p on p.id = t.politician_id;
