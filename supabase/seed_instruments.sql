-- Starter instruments for metals and crypto. Provider symbols are examples; confirm each against the provider before first sync.
insert into instruments (symbol, provider, provider_symbol, name, asset_class, currency) values
  ('XAUUSD','stooq','xauusd','Gold spot (USD/oz)','gold','USD'),
  ('XAGUSD','stooq','xagusd','Silver spot (USD/oz)','commodity','USD'),
  ('XPTUSD','stooq','xptusd','Platinum spot (USD/oz)','commodity','USD'),
  ('XPDUSD','stooq','xpdusd','Palladium spot (USD/oz)','commodity','USD'),
  ('HG.F','stooq','hg.f','Copper futures (USD/lb)','commodity','USD'),
  ('BTC','coingecko','bitcoin','Bitcoin','crypto','USD'),
  ('ETH','coingecko','ethereum','Ethereum','crypto','USD'),
  ('SOL','coingecko','solana','Solana','crypto','USD')
on conflict (provider, symbol) do nothing;
