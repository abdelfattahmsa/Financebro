-- Financebro core schema. Supabase Postgres. User-owned tables: user_id + RLS.
-- Shared reference/intel tables (sources, items, entities, clusters, instruments, prices) are
-- readable by any authenticated user and written only by the service role (Workers).

create extension if not exists pg_trgm;
create extension if not exists vector;

-- ───────────── enums ─────────────
create type source_type as enum ('rss','atom','jsonfeed','api','scraper','rsshub','gov','company','social','manual');
create type entity_type as enum ('company','person','country','region','industry','technology','asset','organization','other');
create type insight_kind as enum ('fact','interpretation','implication','question');
create type insight_scope as enum ('daily_pulse','cluster','trend','opportunity','portfolio','theme','adhoc');
create type asset_class as enum ('equity','etf','bond','treasury','crypto','commodity','gold','fx','reit','real_estate','private_company','startup','private_equity','fund','cash','other');
create type theme_status as enum ('emerging','active','fading','archived');
create type tx_type as enum ('buy','sell','dividend','interest','deposit','withdrawal','fee','split','transfer');
create type decision_status as enum ('considering','decided','executed','abandoned','reviewed');

-- ───────────── helpers ─────────────
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ───────────── sources & information items ─────────────
create table sources (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) on delete cascade,   -- null = shared/global source
  name text not null,
  domain text,
  source_type source_type not null,
  endpoint text,                       -- feed URL / API URL / scraper id
  config jsonb not null default '{}',  -- adapter-specific
  country text, language text,
  category text,
  authority smallint not null default 50 check (authority between 0 and 100),
  poll_minutes int not null default 60,
  etag text, last_modified text,
  last_fetched_at timestamptz, last_status text, consecutive_failures int not null default 0,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_sources_upd before update on sources for each row execute function set_updated_at();

-- Scraper credentials for POST /ingest (store only the hash).
create table ingest_keys (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  label text not null,
  key_hash text not null unique,
  source_id uuid references sources(id) on delete set null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table items (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references sources(id) on delete cascade,
  source_type source_type not null,
  source_domain text,
  title text not null,
  url text not null,                    -- canonical
  url_hash text not null,               -- sha256(canonical url)
  content_hash text,                    -- sha256(normalized title+content)
  published_at timestamptz,
  fetched_at timestamptz not null default now(),
  author text,
  content text,                         -- truncated plain text (~8KB)
  summary text,
  image_url text,
  raw_ref text,                         -- R2 key of raw snapshot, if kept
  country text, language text,
  significance real not null default 0,
  cluster_id uuid,                      -- fk added below
  fts tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(title,'')), 'A') ||
    setweight(to_tsvector('simple', coalesce(content,'')), 'C')
  ) stored,
  unique (url_hash)
);
create index items_published_idx on items (published_at desc);
create index items_source_idx on items (source_id, published_at desc);
create index items_cluster_idx on items (cluster_id);
create index items_content_hash_idx on items (content_hash);
create index items_fts_idx on items using gin (fts);
create index items_title_trgm_idx on items using gin (title gin_trgm_ops);

-- ───────────── entities, topics, graph ─────────────
create table entities (
  id uuid primary key default gen_random_uuid(),
  type entity_type not null,
  name text not null,
  slug text not null,
  ticker text, country text,
  attrs jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (type, slug)
);
create table entity_aliases (
  entity_id uuid not null references entities(id) on delete cascade,
  alias text not null,
  ambiguous boolean not null default false,   -- needs context rules / review
  primary key (entity_id, alias)
);
create index entity_aliases_alias_idx on entity_aliases (lower(alias));

-- Edges: company→industry, company→instrument(asset entity), industry→theme-ish, etc.
create table entity_links (
  from_id uuid not null references entities(id) on delete cascade,
  to_id uuid not null references entities(id) on delete cascade,
  relation text not null,                     -- 'operates_in','issues','supplies','competes_with','exposed_to'
  weight real not null default 1,
  primary key (from_id, to_id, relation)
);
create index entity_links_to_idx on entity_links (to_id);

create table item_entities (
  item_id uuid not null references items(id) on delete cascade,
  entity_id uuid not null references entities(id) on delete cascade,
  method text not null default 'gazetteer',   -- gazetteer | llm | manual
  confidence real not null default 1,
  primary key (item_id, entity_id)
);
create index item_entities_entity_idx on item_entities (entity_id);

create table topics (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  keywords text[] not null default '{}'
);
create table item_topics (
  item_id uuid not null references items(id) on delete cascade,
  topic_id uuid not null references topics(id) on delete cascade,
  primary key (item_id, topic_id)
);
create index item_topics_topic_idx on item_topics (topic_id);

-- ───────────── clusters (one real-world event/story) ─────────────
create table clusters (
  id uuid primary key default gen_random_uuid(),
  headline text not null,
  summary text,                          -- model-generated -> labelled in UI
  summary_insight_id uuid,               -- traceable insight, fk below
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  item_count int not null default 0,
  source_count int not null default 0,
  significance real not null default 0,
  embedding vector(384),
  updated_at timestamptz not null default now()
);
create index clusters_sig_idx on clusters (last_seen_at desc, significance desc);
create index clusters_embedding_idx on clusters using hnsw (embedding vector_cosine_ops);
alter table items add constraint items_cluster_fk foreign key (cluster_id) references clusters(id) on delete set null;

-- ───────────── themes & trends (dynamic) ─────────────
create table themes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) on delete cascade,  -- null = system-detected
  name text not null,
  description text,
  status theme_status not null default 'emerging',
  origin text not null default 'detected',                     -- detected | user
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table theme_members (
  theme_id uuid not null references themes(id) on delete cascade,
  entity_id uuid references entities(id) on delete cascade,
  topic_id uuid references topics(id) on delete cascade,
  keyword text,
  weight real not null default 1,
  check (num_nonnulls(entity_id, topic_id, keyword) = 1)
);
create index theme_members_theme_idx on theme_members (theme_id);

create table trend_points (               -- daily counts feeding z-score trend detection
  subject_type text not null check (subject_type in ('entity','topic','theme','keyword','problem')),
  subject_id text not null,
  day date not null,
  item_count int not null default 0,
  source_count int not null default 0,
  primary key (subject_type, subject_id, day)
);

-- ───────────── markets ─────────────
create table instruments (
  id uuid primary key default gen_random_uuid(),
  symbol text not null,
  provider text not null,                -- 'yahoo','stooq','fred','coingecko','manual'
  provider_symbol text,
  name text not null,
  asset_class asset_class not null,
  currency text,
  country text, region text, sector text,
  entity_id uuid references entities(id) on delete set null,   -- links to company/asset entity
  active boolean not null default true,
  unique (provider, symbol)
);
-- Hierarchy for the Market Map: region → country → asset class → sector
create table instrument_groups (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references instrument_groups(id) on delete cascade,
  level text not null check (level in ('global','region','country','asset_class','sector')),
  name text not null,
  code text
);
create table instrument_group_members (
  group_id uuid not null references instrument_groups(id) on delete cascade,
  instrument_id uuid not null references instruments(id) on delete cascade,
  weight real not null default 1,
  primary key (group_id, instrument_id)
);
create table prices_daily (
  instrument_id uuid not null references instruments(id) on delete cascade,
  day date not null,
  open numeric, high numeric, low numeric,
  close numeric not null,
  volume numeric,
  primary key (instrument_id, day)
);
create table indicators (                  -- CPI, GDP, policy rate, PMI, unemployment…
  id uuid primary key default gen_random_uuid(),
  code text not null,
  provider text not null,
  name text not null,
  country text,
  unit text, frequency text,
  unique (provider, code)
);
create table indicator_points (
  indicator_id uuid not null references indicators(id) on delete cascade,
  period date not null,
  value numeric not null,
  primary key (indicator_id, period)
);

-- ───────────── portfolio (user-owned) ─────────────
create table portfolios (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  base_currency text not null default 'USD',
  created_at timestamptz not null default now()
);
create table accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  portfolio_id uuid not null references portfolios(id) on delete cascade,
  name text not null,                    -- 'Brokerage', 'Bank', 'Wallet'
  kind text
);
-- Holdings are *assets*, which may or may not be priceable (private companies, real estate).
create table assets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  asset_class asset_class not null,
  currency text not null default 'USD',
  instrument_id uuid references instruments(id) on delete set null,  -- null = manually valued
  country text, sector text,
  thesis text,
  tags text[] not null default '{}',
  manual_price numeric, manual_price_at timestamptz,
  created_at timestamptz not null default now()
);
create table transactions (              -- source of truth; holdings derived
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  portfolio_id uuid not null references portfolios(id) on delete cascade,
  account_id uuid references accounts(id) on delete set null,
  asset_id uuid not null references assets(id) on delete cascade,
  type tx_type not null,
  quantity numeric not null default 0,
  price numeric not null default 0,
  fees numeric not null default 0,
  currency text not null,
  occurred_on date not null,
  note text,
  created_at timestamptz not null default now()
);
create index transactions_asset_idx on transactions (asset_id, occurred_on);

create view holdings with (security_invoker = true) as
select t.user_id, t.portfolio_id, t.asset_id,
  sum(case t.type when 'buy' then t.quantity when 'sell' then -t.quantity else 0 end) as quantity,
  sum(case t.type when 'buy' then t.quantity*t.price + t.fees else 0 end)
    / nullif(sum(case t.type when 'buy' then t.quantity else 0 end),0) as avg_cost   -- simple avg-cost basis (v1)
from transactions t
group by t.user_id, t.portfolio_id, t.asset_id
having sum(case t.type when 'buy' then t.quantity when 'sell' then -t.quantity else 0 end) <> 0;

create table watchlists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null
);
create table watchlist_entries (
  watchlist_id uuid not null references watchlists(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  instrument_id uuid references instruments(id) on delete cascade,
  entity_id uuid references entities(id) on delete cascade,
  theme_id uuid references themes(id) on delete cascade,
  note text,
  check (num_nonnulls(instrument_id, entity_id, theme_id) = 1)
);

-- ───────────── insights: facts vs interpretation (traceable) ─────────────
create table insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,   -- null = global
  scope insight_scope not null,
  kind insight_kind not null,
  body text not null,
  based_on uuid[] not null default '{}',     -- insight ids this builds on (interpretation → facts)
  confidence real check (confidence between 0 and 1),
  assumptions text[] not null default '{}',
  generated_by text not null default 'system',   -- 'system' (deterministic) | model id
  prompt_version text, input_hash text,           -- cache key
  period_start timestamptz, period_end timestamptz,
  created_at timestamptz not null default now()
);
create index insights_user_idx on insights (user_id, scope, created_at desc);
alter table clusters add constraint clusters_summary_fk foreign key (summary_insight_id) references insights(id) on delete set null;

create table insight_evidence (
  insight_id uuid not null references insights(id) on delete cascade,
  item_id uuid references items(id) on delete set null,
  cluster_id uuid references clusters(id) on delete set null,
  instrument_id uuid references instruments(id) on delete set null,
  indicator_id uuid references indicators(id) on delete set null,
  quote text,                                   -- extractive snippet supporting the claim
  check (num_nonnulls(item_id, cluster_id, instrument_id, indicator_id) = 1)
);
create index insight_evidence_insight_idx on insight_evidence (insight_id);

-- Enforce traceability at commit time (deferred, so insight + evidence can be inserted in one tx).
create or replace function check_insight_traceable() returns trigger language plpgsql as $$
declare i insights;
begin
  select * into i from insights where id = new.id;
  if not found then return null; end if;
  if i.kind = 'fact' and not exists (select 1 from insight_evidence where insight_id = i.id) then
    raise exception 'fact insight % has no evidence', i.id;
  end if;
  if i.kind in ('interpretation','implication')
     and coalesce(array_length(i.based_on,1),0) = 0
     and not exists (select 1 from insight_evidence where insight_id = i.id) then
    raise exception '% insight % must reference facts (based_on) or evidence', i.kind, i.id;
  end if;
  return null;
end $$;
create constraint trigger trg_insight_traceable after insert on insights
  deferrable initially deferred for each row execute function check_insight_traceable();

-- Your own judgement; AI never writes here.
create table assessments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  insight_id uuid not null references insights(id) on delete cascade,
  stance text check (stance in ('agree','disagree','unsure','investigate')),
  note text,
  created_at timestamptz not null default now()
);

-- ───────────── decision journal ─────────────
create table decisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  domain text not null default 'investment' check (domain in ('investment','business','product','other')),
  status decision_status not null default 'considering',
  decided_on date,
  thesis text, expected_outcome text, risks text,
  confidence smallint check (confidence between 0 and 100),
  review_on date,
  asset_id uuid references assets(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_decisions_upd before update on decisions for each row execute function set_updated_at();
create table decision_evidence (          -- snapshot so evidence survives pruning
  id uuid primary key default gen_random_uuid(),
  decision_id uuid not null references decisions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id uuid references items(id) on delete set null,
  insight_id uuid references insights(id) on delete set null,
  title text, url text, note text,
  captured_at timestamptz not null default now()
);
create table decision_reviews (
  id uuid primary key default gen_random_uuid(),
  decision_id uuid not null references decisions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  actual_outcome text, got_right text, missed text, lesson text,
  reviewed_at timestamptz not null default now()
);

-- ───────────── personalization ─────────────
create table interest_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  topics uuid[] not null default '{}',
  entities uuid[] not null default '{}',
  countries text[] not null default '{}',
  languages text[] not null default '{}',
  regions text[] not null default '{}',
  weights jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create table dashboards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default 'Overview',
  layout jsonb not null default '[]',   -- [{widget_type,x,y,w,h,config}]
  is_default boolean not null default false,
  updated_at timestamptz not null default now()
);
create table item_states (                -- read/saved/hidden per user
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id uuid not null references items(id) on delete cascade,
  state text not null check (state in ('read','saved','hidden')),
  at timestamptz not null default now(),
  primary key (user_id, item_id, state)
);

-- ───────────── AI budget guard ─────────────
create table ai_usage (
  id bigint generated always as identity primary key,
  day date not null default current_date,
  job text not null,
  model text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0
);
create index ai_usage_day_idx on ai_usage (day, job);

-- ───────────── Row Level Security ─────────────
-- User-owned: only the owner. (Worker service role bypasses RLS.)
do $$
declare t text;
begin
  foreach t in array array['portfolios','accounts','assets','transactions','watchlists','watchlist_entries',
    'assessments','decisions','decision_evidence','decision_reviews','dashboards','item_states'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %I on %I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t||'_own', t);
  end loop;
end $$;

alter table interest_profiles enable row level security;
create policy interest_profiles_own on interest_profiles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table insights enable row level security;
create policy insights_read on insights for select to authenticated using (user_id is null or user_id = auth.uid());

alter table insight_evidence enable row level security;
create policy insight_evidence_read on insight_evidence for select to authenticated
  using (exists (select 1 from insights i where i.id = insight_id and (i.user_id is null or i.user_id = auth.uid())));

alter table sources enable row level security;
create policy sources_read on sources for select to authenticated using (owner_id is null or owner_id = auth.uid());
create policy sources_write on sources for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

alter table ingest_keys enable row level security;
create policy ingest_keys_own on ingest_keys for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

alter table themes enable row level security;
create policy themes_read on themes for select to authenticated using (owner_id is null or owner_id = auth.uid());
create policy themes_write on themes for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Items inherit visibility from their source (your private scrapers stay private).
alter table items enable row level security;
create policy items_read on items for select to authenticated
  using (exists (select 1 from sources s where s.id = source_id and (s.owner_id is null or s.owner_id = auth.uid())));

-- Shared read-only intel/reference data.
do $$
declare t text;
begin
  foreach t in array array['entities','entity_aliases','entity_links','item_entities','topics','item_topics',
    'clusters','theme_members','trend_points','instruments','instrument_groups','instrument_group_members',
    'prices_daily','indicators','indicator_points'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %I on %I for select to authenticated using (true)', t||'_read', t);
  end loop;
end $$;

alter table ai_usage enable row level security;   -- no policies: service role only
