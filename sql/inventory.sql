-- =====================================================================
-- Shop Floor — Inventory and scrap rate (designed and built 25 Sep 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_inventory();
--
-- What it adds (nothing existing is changed):
--   * Five count lists, each owned by whoever counts it:
--       Lumber  — the office, monthly (rows of each bundle, by length)
--       Plywood — Full Custom, monthly
--       Metal   — Metal, monthly (steel as full sticks + loose feet)
--       Finish  — Finishing, every three months
--       Other   — Assembly / QC, every three months
--     Items, prices and GL accounts come from the 31 Aug 2026 workbooks,
--     and the 31 Aug counts are loaded as the starting count.
--   * Lumber and plywood deliveries, one line per packing slip.
--   * The month-end roll-over: sheets whose lumber hasn't been pulled
--     move to next month's list.
--   * 0-scrap board feet for every top started in the month: full
--     rectangle (a round is diameter x diameter) x stock thickness.
--   * The scrap rate by species and thickness:
--       used    = last month's count + received - this month's count
--       scrap   = used - 0-scrap
--       rate    = scrap / used
--   * Closing a month freezes its numbers and prices.
--
-- Who can do what (decided by the database, not by the pages):
--   * Managers: everything on the office Inventory page.
--   * A supervisor: reads and sends their own department's list only,
--     never prices. Test logins can't send counts (there are no test
--     lane counts).
--   * Nobody writes to these tables directly; every change goes through
--     a function that checks who is asking.
--   * Nothing is deleted. A wrong delivery slip is marked "Entered by
--     mistake"; a retired item keeps its history.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Small helpers
-- ---------------------------------------------------------------------

-- the last day of the month a moment falls in, on the shop's clock

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('inventory.sql'); end if;
end $$;

create or replace function inv_month_end(p timestamptz) returns date
language sql stable as $$
  select (date_trunc('month', p at time zone 'America/Indiana/Indianapolis') + interval '1 month' - interval '1 day')::date
$$;
create or replace function inv_month_end_d(p date) returns date
language sql immutable as $$
  select (date_trunc('month', p::timestamp) + interval '1 month' - interval '1 day')::date
$$;

-- '6/4' -> 1.5 inches (the stock thickness used for board feet)
create or replace function inv_stock_in(p text) returns numeric
language sql immutable as $$
  select case when p ~ '^\d+/4$' then split_part(p, '/', 1)::numeric / 4 end
$$;

-- a size written on a work order, in inches: 36"  36  30 1/2"  30-1/2"  1.25"  1 1/4"  3/4"
create or replace function inv_inches(p text) returns numeric
language plpgsql immutable as $$
declare s text; m text[];
begin
  if p is null then return null; end if;
  s := lower(trim(p));
  s := replace(replace(replace(s, '″', ''), '"', ''), 'in', '');
  s := regexp_replace(s, '(\d)\s*-\s*(\d+/\d+)', '\1 \2');
  s := trim(regexp_replace(s, '\s+', ' ', 'g'));
  if s ~ '^\d+(\.\d+)?$' then return s::numeric; end if;
  if s ~ '^\.\d+$' then return s::numeric; end if;
  m := regexp_match(s, '^(\d+) (\d+)/(\d+)$');
  if m is not null and m[3]::numeric > 0 then return m[1]::numeric + m[2]::numeric / m[3]::numeric; end if;
  m := regexp_match(s, '^(\d+)/(\d+)$');
  if m is not null and m[2]::numeric > 0 then return m[1]::numeric / m[2]::numeric; end if;
  return null;
end $$;

-- species written the same way whatever the spacing, case or hyphens
create or replace function inv_norm(p text) returns text
language sql immutable as $$
  select nullif(trim(regexp_replace(lower(coalesce(p, '')), '[\s\-_]+', ' ', 'g')), '')
$$;

grant execute on function inv_month_end(timestamptz), inv_month_end_d(date), inv_stock_in(text), inv_inches(text), inv_norm(text) to authenticated;


-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

create table if not exists inv_settings (
  id              int  primary key default 1 check (id = 1),
  first_month_end date not null            -- the first month with a scrap rate
);
insert into inv_settings (id, first_month_end) values (1, '2026-09-30') on conflict (id) do nothing;

create table if not exists inv_lists (
  key          text primary key,
  name         text not null,
  department   text references departments(key),     -- null = the office
  every_months int  not null check (every_months in (1, 3)),
  sort_order   int  not null
);
insert into inv_lists (key, name, department, every_months, sort_order) values
  ('lumber',  'Lumber',  null,          1, 1),
  ('plywood', 'Plywood', 'full_custom', 1, 2),
  ('metal',   'Metal',   'metal',       1, 3),
  ('finish',  'Finish',  'finishing',   3, 4),
  ('other',   'Other',   'assembly_qc', 3, 5)
on conflict (key) do nothing;

create table if not exists inv_items (
  id            uuid primary key default gen_random_uuid(),
  list_key      text not null references inv_lists(key),
  section       text not null default '',
  name          text not null,
  unit          text not null default 'each',
  std_length_ft numeric check (std_length_ft is null or std_length_ft > 0),   -- steel: counted as sticks + loose feet
  gl_account    text,                                  -- null = no dollar value (shop supplies)
  species       text,                                  -- lumber only
  stock         text check (stock is null or stock ~ '^\d+/4$'),
  sort_order    int  not null default 0,
  retired       boolean not null default false,
  changed_by_name text,
  changed_at    timestamptz not null default now(),
  unique (list_key, name),
  check (list_key <> 'lumber' or (species is not null and stock is not null))
);
create unique index if not exists inv_items_lumber_idx on inv_items (inv_norm(species), stock) where list_key = 'lumber';

create table if not exists inv_prices (
  id          bigint generated always as identity primary key,
  item_id     uuid not null references inv_items(id),
  price       numeric(12,4) not null check (price >= 0),
  set_by      uuid references profiles(id),
  set_by_name text not null,
  set_at      timestamptz not null default clock_timestamp()
);
create index if not exists inv_prices_item_idx on inv_prices (item_id, set_at desc, id desc);

create table if not exists inv_months (
  month_end         date primary key check (month_end = inv_month_end_d(month_end)),
  kind              text not null default 'count' check (kind in ('count', 'starting')),
  status            text not null default 'open'  check (status in ('open', 'closed')),
  lumber_done_at    timestamptz,
  lumber_done_by    text,
  rollover_done_at  timestamptz,
  rollover_done_by  text,
  closed_at         timestamptz,
  closed_by         uuid references profiles(id),
  closed_by_name    text
);

create table if not exists inv_lumber_lines (
  id          uuid primary key default gen_random_uuid(),
  month_end   date not null references inv_months(month_end),
  item_id     uuid not null references inv_items(id),
  length_in   numeric not null check (length_in > 0 and length_in <= 480),
  width_in    numeric not null default 42 check (width_in > 0 and width_in <= 120),
  bundles     numeric[] not null default '{}',             -- rows in each bundle; blank = not counted yet
  updated_by_name text,
  updated_at  timestamptz not null default now(),
  unique (month_end, item_id, length_in)
);

create table if not exists inv_counts (
  month_end   date not null references inv_months(month_end),
  item_id     uuid not null references inv_items(id),
  qty         numeric not null check (qty >= 0),           -- in the item's unit (steel: feet)
  sticks      int check (sticks is null or sticks >= 0),
  loose_ft    numeric check (loose_ft is null or loose_ft >= 0),
  counted_by  uuid references profiles(id),
  counted_by_name text not null,
  counted_at  timestamptz not null default now(),
  primary key (month_end, item_id)
);

create table if not exists inv_sends (
  id          bigint generated always as identity primary key,
  month_end   date not null references inv_months(month_end),
  list_key    text not null references inv_lists(key),
  client_id   uuid unique,
  sent_by     uuid references profiles(id),
  sent_by_name text not null,
  sent_at     timestamptz not null default now(),
  items       int not null default 0,
  withdrawn_at timestamptz,
  withdrawn_by_name text
);
create index if not exists inv_sends_idx on inv_sends (month_end, list_key, sent_at desc);

create table if not exists inv_receipts (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid unique,
  kind        text not null check (kind in ('lumber', 'plywood')),
  received_on date not null,
  month_end   date generated always as ((date_trunc('month', received_on::timestamp) + interval '1 month' - interval '1 day')::date) stored,
  supplier    text,
  item_id     uuid references inv_items(id),
  board_feet  numeric check (board_feet is null or board_feet > 0),
  sheets      int check (sheets is null or sheets > 0),
  note        text,
  entered_by  uuid references profiles(id),
  entered_by_name text not null,
  entered_at  timestamptz not null default now(),
  mistake_at  timestamptz,
  mistake_by_name text,
  check ((kind = 'lumber' and item_id is not null and board_feet is not null and sheets is null)
      or (kind = 'plywood' and sheets is not null and board_feet is null))
);
create index if not exists inv_receipts_month_idx on inv_receipts (month_end, kind);

-- a sheet is (job, sheet number): it keeps its place when a change order makes a new version
create table if not exists inv_rollovers (
  month_end    date not null references inv_months(month_end),
  job_id       uuid not null references jobs(id),
  sheet_number int  not null,
  rolled       boolean not null,
  set_by_name  text not null,
  set_at       timestamptz not null default now(),
  primary key (month_end, job_id, sheet_number)
);

create table if not exists inv_thickness_rules (
  id          bigint generated always as identity primary key,
  from_in     numeric not null check (from_in > 0),
  to_in       numeric not null,
  stock       text not null check (stock ~ '^\d+/4$'),
  set_by_name text not null,
  set_at      timestamptz not null default now(),
  retired_at  timestamptz,
  retired_by_name text,
  check (to_in >= from_in)
);
insert into inv_thickness_rules (from_in, to_in, stock, set_by_name)
select v.f, v.t, v.s, 'Starting rule'
  from (values (1.0, 1.0, '5/4'), (1.18, 1.25, '6/4'), (1.5, 1.5, '8/4')) v(f, t, s)
 where not exists (select 1 from inv_thickness_rules);

-- work order species -> inventory species; the newest row for a name is the one in use
create table if not exists inv_species_matches (
  id          bigint generated always as identity primary key,
  wo_norm     text not null,
  wo_species  text not null,
  inventory_species text,                   -- null with leave_out = not lumber, left out
  leave_out   boolean not null default false,
  set_by_name text not null,
  set_at      timestamptz not null default clock_timestamp(),
  check (leave_out or inventory_species is not null)
);
create index if not exists inv_species_matches_idx on inv_species_matches (wo_norm, set_at desc, id desc);

-- what a closed month counted: frozen
create table if not exists inv_close_sheets (
  month_end    date not null references inv_months(month_end),
  job_id       uuid not null references jobs(id),
  sheet_number int  not null,
  sheet_id     uuid,
  project_id   text,
  item_code    text,
  species      text,
  inventory_species text,
  stock        text,
  width_in     numeric,
  length_in    numeric,
  thickness_in numeric,
  qty          int,
  board_feet   numeric,                     -- null = left out (not lumber)
  primary key (month_end, job_id, sheet_number),
  unique (job_id, sheet_number)             -- a sheet counts in one month only
);
create table if not exists inv_close_values (
  month_end  date not null references inv_months(month_end),
  item_id    uuid not null references inv_items(id),
  qty        numeric not null,
  price      numeric(12,4),
  primary key (month_end, item_id)
);


-- ---------------------------------------------------------------------
-- 3. Security: read as below; nobody writes directly
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['inv_settings','inv_lists','inv_items','inv_prices','inv_months','inv_lumber_lines','inv_counts',
                           'inv_sends','inv_receipts','inv_rollovers','inv_thickness_rules','inv_species_matches',
                           'inv_close_sheets','inv_close_values'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon', t);
    execute format('revoke insert, update, delete, truncate on %I from authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('drop policy if exists inv_read on %I', t);
  end loop;
end $$;

-- everyone signed in (the tablets need these)
create policy inv_read on inv_settings for select to authenticated using (true);
create policy inv_read on inv_lists    for select to authenticated using (true);
create policy inv_read on inv_months   for select to authenticated using (true);
-- a department's own list; managers all of it
create policy inv_read on inv_items  for select to authenticated
  using (is_manager() or exists (select 1 from inv_lists l where l.key = list_key and l.department is not null and owns_dept(l.department)));
create policy inv_read on inv_counts for select to authenticated
  using (is_manager() or exists (select 1 from inv_items i join inv_lists l on l.key = i.list_key
                                  where i.id = item_id and l.department is not null and owns_dept(l.department)));
create policy inv_read on inv_sends  for select to authenticated
  using (is_manager() or exists (select 1 from inv_lists l where l.key = list_key and l.department is not null and owns_dept(l.department)));
-- managers only
create policy inv_read on inv_prices          for select to authenticated using (is_manager());
create policy inv_read on inv_lumber_lines    for select to authenticated using (is_manager());
create policy inv_read on inv_receipts        for select to authenticated using (is_manager());
create policy inv_read on inv_rollovers       for select to authenticated using (is_manager());
create policy inv_read on inv_thickness_rules for select to authenticated using (is_manager());
create policy inv_read on inv_species_matches for select to authenticated using (is_manager());
create policy inv_read on inv_close_sheets    for select to authenticated using (is_manager());
create policy inv_read on inv_close_values    for select to authenticated using (is_manager());


-- ---------------------------------------------------------------------
-- 4. Starting lists, prices and the 31 Aug 2026 count (from the workbooks)
--    Only added where missing: a second run never puts back something
--    a manager has since changed.
-- ---------------------------------------------------------------------

drop table if exists inv_seed_items;
create temp table inv_seed_items (list_key text, section text, name text, unit text, std_length_ft numeric, gl_account text,
                                  species text, stock text, sort_order int, price numeric, aug_qty numeric);
insert into inv_seed_items values
('finish','Finishing materials','Krystal High Build Sealer - 5 gal','5 Gallon Containers',null,'1208',null,null,10,219,null),
  ('finish','Finishing materials','Klearvar - 5 gal','5 Gallon Containers',null,'1208',null,null,20,245,null),
  ('finish','Finishing materials','Catalyst (for Polarion) - 1 quart','1 Quart Cans',null,'1208',null,null,30,35,null),
  ('finish','Finishing materials','Polarion - 1 gal','1 Gallon Cans',null,'1208',null,null,40,85,null),
  ('finish','Finishing materials','Polarion - 5 gal','5 Gallon Containers',null,'1208',null,null,50,320,null),
  ('finish','Finishing materials','Lacquer Thinner - 55 gal','55 gallon drums',null,'1208',null,null,60,625,null),
  ('finish','Finishing materials','Stain - 1 gal','1 Gallon Cans',null,'1208',null,null,70,30,null),
  ('finish','Finishing materials','Care Catalyst - 1 gal','1 Gallon Cans',null,'1208',null,null,80,55,null),
  ('finish','Finishing materials','Paint - 1 gal','1 Gallon Cans',null,'1208',null,null,90,100,null),
  ('other','Hardware','Levelers','each',null,'1207',null,null,10,0.5,null),
  ('other','Hardware','Hinges','each',null,'1207',null,null,20,4,null),
  ('other','Hardware','Grommet(s)','each',null,'1207',null,null,30,2,null),
  ('other','Hardware','Flip Top Mechanism - Pizza Box','each',null,'1207',null,null,40,59,null),
  ('other','Hardware','Flip Top Mechanism - 2 Hand Cable Flip','each',null,'1207',null,null,50,91,null),
  ('other','Hardware','End Caps','each',null,'1207',null,null,60,1,null),
  ('other','Hardware','Drawer slides','each',null,'1207',null,null,70,40,null),
  ('other','Hardware','Data port(s)','each',null,'1207',null,null,80,100,null),
  ('other','Hardware','Casters','each',null,'1207',null,null,90,4.5,null),
  ('lumber','Lumber','African Mahogany 8/4','bd ft',null,'1201','African Mahogany','8/4',10,0,null),
  ('lumber','Lumber','Ash 4/4','bd ft',null,'1201','Ash','4/4',20,2.44,null),
  ('lumber','Lumber','Ash 5/4','bd ft',null,'1201','Ash','5/4',30,4.14,null),
  ('lumber','Lumber','Ash 6/4','bd ft',null,'1201','Ash','6/4',40,2.95,null),
  ('lumber','Lumber','Ash 8/4','bd ft',null,'1201','Ash','8/4',50,3.45,null),
  ('lumber','Lumber','Cherry 4/4','bd ft',null,'1201','Cherry','4/4',60,2.36,null),
  ('lumber','Lumber','Cherry 5/4','bd ft',null,'1201','Cherry','5/4',70,5.04,null),
  ('lumber','Lumber','Cherry 6/4','bd ft',null,'1201','Cherry','6/4',80,3.1,null),
  ('lumber','Lumber','Cherry 8/4','bd ft',null,'1201','Cherry','8/4',90,3.25,null),
  ('lumber','Lumber','Flat-sawn Red Oak 8/4','bd ft',null,'1201','Flat-sawn Red Oak','8/4',100,4,null),
  ('lumber','Lumber','Flat-sawn White Oak 5/4','bd ft',null,'1201','Flat-sawn White Oak','5/4',110,7.5,null),
  ('lumber','Lumber','Flat-sawn White Oak 6/4','bd ft',null,'1201','Flat-sawn White Oak','6/4',120,6.14,null),
  ('lumber','Lumber','Flat-sawn White Oak 8/4','bd ft',null,'1201','Flat-sawn White Oak','8/4',130,7.31,null),
  ('lumber','Lumber','Flat-sawn white oak 4/4','bd ft',null,'1201','Flat-sawn white oak','4/4',140,7.85,null),
  ('lumber','Lumber','Hickory 8/4','bd ft',null,'1201','Hickory','8/4',150,0,null),
  ('lumber','Lumber','Maple (soft) 4/4 1C','bd ft',null,'1201','Maple (soft) 1C','4/4',160,1.98,null),
  ('lumber','Lumber','Maple 5/4','bd ft',null,'1201','Maple','5/4',170,4.08,null),
  ('lumber','Lumber','Maple 6/4','bd ft',null,'1201','Maple','6/4',180,3.72,null),
  ('lumber','Lumber','Maple 8/4','bd ft',null,'1201','Maple','8/4',190,3.76,null),
  ('lumber','Lumber','Quarter-sawn Red Oak 5/4','bd ft',null,'1201','Quarter-sawn Red Oak','5/4',200,3.77,null),
  ('lumber','Lumber','Quarter-sawn Red Oak 6/4','bd ft',null,'1201','Quarter-sawn Red Oak','6/4',210,5.2,null),
  ('lumber','Lumber','Quarter-sawn Red Oak 8/4','bd ft',null,'1201','Quarter-sawn Red Oak','8/4',220,5.73,null),
  ('lumber','Lumber','Rift cut White Oak 6/4','bd ft',null,'1201','Rift cut White Oak','6/4',230,0,null),
  ('lumber','Lumber','Thermally Modified RO 4/4','bd ft',null,'1201','Thermally Modified RO','4/4',240,0,null),
  ('lumber','Lumber','Thermally Modified RO 6/4','bd ft',null,'1201','Thermally Modified RO','6/4',250,0,null),
  ('lumber','Lumber','Walnut 4/4 SB','bd ft',null,'1201','Walnut SB','4/4',260,4.45,null),
  ('lumber','Lumber','Walnut 5/4','bd ft',null,'1201','Walnut','5/4',270,7.62,null),
  ('lumber','Lumber','Walnut 6/4','bd ft',null,'1201','Walnut','6/4',280,6.97,null),
  ('lumber','Lumber','Walnut 8/4','bd ft',null,'1201','Walnut','8/4',290,7.89,null),
  ('plywood','Plywood rack','Birch 1/2 UV1S','sheets',null,'1201',null,null,10,69,58),
  ('plywood','Plywood rack','Ash 3/4 VC','sheets',null,'1201',null,null,20,151,9),
  ('plywood','Plywood rack','Maple 3/4 VC','sheets',null,'1201',null,null,30,105,14),
  ('plywood','Plywood rack','Ash 1/2 VC','sheets',null,'1201',null,null,40,95,4),
  ('plywood','Plywood rack','Maple 3/4 MDF','sheets',null,'1201',null,null,50,160,2),
  ('plywood','Plywood rack','Birch 3/4 UV1S','sheets',null,'1201',null,null,60,78,32),
  ('plywood','Plywood rack','Walnut 1/4 Pluma','sheets',null,'1201',null,null,70,140,2),
  ('plywood','Plywood rack','Maple 1/2 VC','sheets',null,'1201',null,null,80,104,14),
  ('plywood','Plywood rack','White Oak 3/4 Pluma','sheets',null,'1201',null,null,90,145,39),
  ('plywood','Plywood rack','Ash 1/4 MDF','sheets',null,'1201',null,null,100,90,9),
  ('plywood','Plywood rack','Walnut 3/4 Pluma','sheets',null,'1201',null,null,110,180,4),
  ('plywood','Plywood rack','Maple 1/4 VC','sheets',null,'1201',null,null,120,107,7),
  ('plywood','Plywood rack','Birch 3/4 UV2S','sheets',null,'1201',null,null,130,110,5),
  ('plywood','Plywood rack','Ash 3/4 MDF','sheets',null,'1201',null,null,140,145,0),
  ('plywood','Plywood rack','Bending Ply','sheets',null,'1201',null,null,150,50,2),
  ('plywood','Plywood rack','Cherry 1/2 Pluma','sheets',null,'1201',null,null,160,185,0),
  ('plywood','Plywood rack','Cherry 1/4 VC','sheets',null,'1201',null,null,170,105,0),
  ('plywood','Plywood rack','Cherry 3/4 Pluma','sheets',null,'1201',null,null,180,220,1),
  ('plywood','Plywood rack','Maple 1/2 Pluma','sheets',null,'1201',null,null,190,180,0),
  ('plywood','Plywood rack','Maple 1/4 Pluma','sheets',null,'1201',null,null,200,115,0),
  ('plywood','Plywood rack','Maple 3/4 Pluma','sheets',null,'1201',null,null,210,190,0),
  ('plywood','Plywood rack','Maple UV1S 1/2 VC','sheets',null,'1201',null,null,220,110,0),
  ('plywood','Plywood rack','Maple UV1S 3/4 VC','sheets',null,'1201',null,null,230,130,0),
  ('plywood','Plywood rack','Walnut 1/2 VC','sheets',null,'1201',null,null,240,135,1),
  ('plywood','Plywood rack','White Oak 1/2 Pluma','sheets',null,'1201',null,null,250,175,1),
  ('plywood','Plywood rack','White Oak 1/4 VC','sheets',null,'1201',null,null,260,105,3),
  ('metal','Shop supplies','Cutting Oil - 3.5 gallons for Band Saw','each',null,null,null,null,10,110,0),
  ('metal','Shop supplies','MS 70S6 .030 12#','each',null,null,null,null,20,129.96,4),
  ('metal','Shop supplies','MS 70S6 .035 12#','each',null,null,null,null,30,135,0),
  ('metal','Shop supplies','4.5" flapper disks with 5/8 nut - 80grit','each',null,null,null,null,40,4.7,200),
  ('metal','Shop supplies','4.5" flapper disks with 7/8 - 80grit T-29','each',null,null,null,null,50,3.4,5),
  ('metal','Shop supplies','4.5" grinding wheels','each',null,null,null,null,60,2.6,26),
  ('metal','Shop supplies','4.5" x 7/8" cutoff wheels','each',null,null,null,null,70,1.85,24),
  ('metal','Shop supplies','3.5" cutoff wheels','each',null,null,null,null,80,null,0),
  ('metal','Shop supplies','150'' abrasive cloth - medium grit','each',null,null,null,null,90,null,0),
  ('metal','Shop supplies','C-125 gas tank (mig welder gas)','each',null,null,null,null,100,78.5,3),
  ('metal','Shop supplies','Partial tanks (on the welders)','each',null,null,null,null,110,78.5,3),
  ('metal','Shop supplies','Chop saw blade - 72 Teeth','each',null,null,null,null,120,null,2),
  ('metal','Shop supplies','Chop saw blade - 90 Teeth','each',null,null,null,null,130,null,4),
  ('metal','Shop supplies','Mkmorse 12'' x 1" x .035 8/12 TPI - #6YPC3','each',null,null,null,null,140,56.08,0),
  ('metal','Shop supplies','Ellis 12'' x 1" x .035','each',null,null,null,null,150,65.5,2),
  ('metal','Other','3/8-16 flange nuts','each',null,'1207',null,null,160,0.09,300),
  ('metal','Other','3/8-16 rivet nuts','each',null,'1207',null,null,170,0.17,0),
  ('metal','Other','Leveler insert for 1" tube - 14/16 gauge','each',null,'1207',null,null,180,1.5,623),
  ('metal','Other','Leveler insert for 1.5" tube - 14/16 gauge','each',null,'1207',null,null,190,1.5,284),
  ('metal','Other','Leveler insert for 2" tube - 14/16 gauge','each',null,'1207',null,null,200,1.5,975),
  ('metal','Other','Solid metal box with latch (pizza box)','each',null,'1207',null,null,210,70,0),
  ('metal','Black pipe','Black Pipe - 10''','each',null,'1204-01',null,null,220,67.89,0),
  ('metal','Black pipe','Black Pipe - T-Fittings','each',null,'1204-01',null,null,230,9,0),
  ('metal','Black pipe','Black Pipe - Flanges','each',null,'1204-01',null,null,240,9.5,0),
  ('metal','Black pipe','Black Pipe - Couplings','each',null,'1204-01',null,null,250,16,0),
  ('metal','Black pipe','Black Pipe - 1" 90s','each',null,'1204-01',null,null,260,5.5,0),
  ('metal','Black pipe','Black Pipe - 1" end caps','each',null,'1204-01',null,null,270,2,0),
  ('metal','Black pipe','Black Pipe - 1" 4-way cross','each',null,'1204-01',null,null,280,20.39,0),
  ('metal','Black pipe','Black Pipe - nipples','each',null,'1204-01',null,null,290,4,0),
  ('metal','Angle Iron','Angle Iron, 3"x3" x 3/16"','ft',20,'1204-01',null,null,300,4.09,45),
  ('metal','Angle Iron','Angle Iron, 4"x4"x.25"','ft',20,'1204-01',null,null,310,7.26,6),
  ('metal','Angle Iron','Angle Iron, 1.25" X 1.25" X .25','ft',20,'1204-01',null,null,320,2.45,270),
  ('metal','Angle Iron','Angle Iron, 1-1/2” X 1-1/2”','ft',20,'1204-01',null,null,330,2.82,0),
  ('metal','Angle Iron','Angle Iron, ¾” X ¾”','ft',20,'1204-01',null,null,340,1.05,0),
  ('metal','Angle Iron','Angle Iron, 1” X 1” X .125','ft',20,'1204-01',null,null,350,1.04,48),
  ('metal','Angle Iron','Angle Iron, 1-1/2” X 1-1/2” x.125"','ft',20,'1204-01',null,null,360,1.75,0),
  ('metal','End Caps','End Caps, 2" plasma cut end caps','each',null,'1204-01',null,null,370,1.25,604),
  ('metal','End Caps','End Caps, 1.5" plasma cut end caps','each',null,'1204-01',null,null,380,1.25,462),
  ('metal','Flat Stock','Flat Stock, 6” wide X ¼” thk.','ft',20,'1204-01',null,null,390,5.61,152),
  ('metal','Flat Stock','Flat Stock, 3” wide X ¼” thk.','ft',20,'1204-01',null,null,400,3.35,120),
  ('metal','Flat Stock','Flat Stock, 4” wide X 3/8" thk.','ft',20,'1204-01',null,null,410,6.63,27),
  ('metal','Flat Stock','Flat Stock, 4” wide X ¼” thk.','ft',20,'1204-01',null,null,420,3.75,210),
  ('metal','Flat Stock','Flat Stock, 1.5” wide X ¼” thk. CR','ft',12,'1204-01',null,null,430,4.5,60),
  ('metal','Flat Stock','Flat Stock, 4” wide X ½” thk.','ft',20,'1204-01',null,null,440,7.48,8),
  ('metal','Flat Stock','Flat Stock, 5” wide X ¼” thk.','ft',20,'1204-01',null,null,450,4.68,193),
  ('metal','Flat Stock','Flat Stock, 3” wide X 3/8" thk.','ft',20,'1204-01',null,null,460,3.83,39),
  ('metal','Flat Stock','Flat Stock, 3.625” wide X 11 ga HR','ft',10,'1204-01',null,null,470,2,122),
  ('metal','Flat Stock','Flat Stock, 8" wide X ¼” thk.','ft',20,'1204-01',null,null,480,8.5,142),
  ('metal','Flat Stock','Flat Stock, 2” wide X ¼” thk.','ft',20,'1204-01',null,null,490,2.25,44),
  ('metal','Flat Stock','Flat Stock, 3” wide X 1/2” thk.','ft',20,'1204-01',null,null,500,5.61,35),
  ('metal','Flat Stock','Flat Stock, 10” wide X ¼” thk.','ft',20,'1204-01',null,null,510,9.35,8),
  ('metal','Flat Stock','Flat Stock, 2" wide X 18 GA thk. (cut from sheet)','ft',10,'1204-01',null,null,520,1.2,0),
  ('metal','Flat Stock','Flat Stock, 2” wide X 1/8” thk.','ft',20,'1204-01',null,null,530,1.4,42),
  ('metal','Flat Stock','Flat Stock, 6” wide X 1/8” thk.','ft',20,'1204-01',null,null,540,4.21,0),
  ('metal','Flat Stock','Flat Stock, 6” wide X 3/8” thk.','ft',20,'1204-01',null,null,550,8.42,0),
  ('metal','Flat Stock','Flat Stock, 3” wide X 14ga. thk.','ft',10,'1204-01',null,null,560,1.81,0),
  ('metal','Flat Stock','Flat Stock, 3” wide X 1/8 thk.','ft',20,'1204-01',null,null,570,2.6,0),
  ('metal','Flat Stock','Flat Stock, 5” wide X 3/8” thk.','ft',20,'1204-01',null,null,580,9.56,0),
  ('metal','Flat Stock','Flat Stock, 5” wide X 1/2” thk.','ft',20,'1204-01',null,null,590,9.35,0),
  ('metal','Flat Stock','Flat Stock, 2” wide X 3/8" thk.','ft',20,'1204-01',null,null,600,2.75,0),
  ('metal','Flat Stock','Flat Stock, 10” wide X 3/8" thk.','ft',20,'1204-01',null,null,610,10,14),
  ('metal','Flat Stock','Flat Stock, 1.5” wide X ¼” thk. HR','ft',20,'1204-01',null,null,620,1.76,0),
  ('metal','Flat Stock','Flat Stock, 4" wide x 1/4" thk. Cold rolled','ft',20,'1204-01',null,null,630,0,0),
  ('metal','LEG - Custom','LEG - Custom, Custom - Contemporary legs (5"x1") plasma cut','each',null,'1204-01',null,null,640,126.57,0),
  ('metal','Pipe','Pipe, 1 3/4" OD','ft',21,'1204-01',null,null,650,4.76,0),
  ('metal','Pipe','Pipe, 1.5” Dia. X 1/8” wall','ft',21,'1204-01',null,null,660,4.25,21),
  ('metal','Pipe','Pipe, 1” Dia. X 1/8” wall','ft',20,'1204-01',null,null,670,2.38,0),
  ('metal','Pipe','Pipe, 2" O.D.x14ga','ft',20,'1204-01',null,null,680,3.4,56),
  ('metal','Pipe','Pipe, 2.375" O.D.x 3/16" W.','ft',21,'1204-01',null,null,690,4.76,60),
  ('metal','Pipe','Pipe, 3" SCH 40 (3.50 OD X .216 wall)','ft',21,'1204-01',null,null,700,15.14,70),
  ('metal','Pipe','Pipe, 3” Dia. X 1/8” wall','ft',21,'1204-01',null,null,710,6.06,0),
  ('metal','Pipe','Pipe, 4" X 3-1/2” ID','ft',21,'1204-01',null,null,720,9.17,0),
  ('metal','Pipe','Pipe, 4" SCH 40 (4.50 OD X .237 wall)','ft',21,'1204-01',null,null,730,14.62,0),
  ('metal','Pipe','Pipe, 8” Dia. X ga wall','ft',7,'1204-01',null,null,740,27.71,0),
  ('metal','Rectangular Tube','Rectangular Tube, 6"x 2" 14 GA','ft',24,'1204-01',null,null,750,6.25,0),
  ('metal','Rectangular Tube','Rectangular Tube, 4"x 3" 11 GA','ft',24,'1204-01',null,null,760,7.4,0),
  ('metal','Rectangular Tube','Rectangular Tube, 4"x 2" 14 GA','ft',24,'1204-01',null,null,770,5.42,0),
  ('metal','Rectangular Tube','Rectangular Tube, 4"x 2" 11 GA','ft',24,'1204-01',null,null,780,9.17,109),
  ('metal','Rectangular Tube','Rectangular Tube, 4"x 1.5" 11 GA','ft',24,'1204-01',null,null,790,10.51,0),
  ('metal','Rectangular Tube','Rectangular Tube, 3" X 1” 11 GA','ft',24,'1204-01',null,null,800,6.48,243),
  ('metal','Rectangular Tube','Rectangular Tube, 3" X 1- 1/2" 11 GA','ft',24,'1204-01',null,null,810,5.63,208),
  ('metal','Rectangular Tube','Rectangular Tube, 2" X 3" 14 GA','ft',24,'1204-01',null,null,820,5.6,56),
  ('metal','Rectangular Tube','Rectangular Tube, 2" X 3" 11 GA','ft',24,'1204-01',null,null,830,8.18,0),
  ('metal','Rectangular Tube','Rectangular Tube, 2" X 1.5" 11GA','ft',24,'1204-01',null,null,840,5.73,0),
  ('metal','Rectangular Tube','Rectangular Tube, 2" X 1" 14GA','ft',24,'1204-01',null,null,850,3.37,62),
  ('metal','Rectangular Tube','Rectangular Tube, 1.5" x 3/4"','ft',24,'1204-01',null,null,860,3.75,0),
  ('metal','Rectangular Tube','Rectangular Tube, 1"x1.5"x 11ga','ft',24,'1204-01',null,null,870,3.85,0),
  ('metal','Rectangular Tube','Rectangular Tube, 1"x0.75"x 14ga','ft',24,'1204-01',null,null,880,0.14,0),
  ('metal','Round Bar','Round Bar, 1/2" CR','ft',12,'1204-01',null,null,890,1.57,200),
  ('metal','Round Bar','Round Bar, 5/8 Rebar','ft',20,'1204-01',null,null,900,1.21,0),
  ('metal','Round Bar','Round Bar, 1.5" HR','ft',20,'1204-01',null,null,910,7.12,0),
  ('metal','Round Bar','Round Bar, 3/8" CR','ft',12,'1204-01',null,null,920,0.88,0),
  ('metal','Round Bar','Round Bar, 1/2" HR','ft',20,'1204-01',null,null,930,0.88,0),
  ('metal','Round Bar','Round Bar, 1/2" 16 GA','ft',20,'1204-01',null,null,940,1.47,0),
  ('metal','Round Bar','Round Bar, 1/4" HR','ft',20,'1204-01',null,null,950,0.29,0),
  ('metal','Round Bar','Round Bar, 2" ID','ft',20,'1204-01',null,null,960,3.57,0),
  ('metal','Round Plates','Round Plates, 6" X 1/4" Steel disc.','each',null,'1204-01',null,null,970,4.21,0),
  ('metal','Round Plates','Round Plates, 48" X 3/8" HR Plate Steel - Custom','each',null,'1204-01',null,null,980,389.57,0),
  ('metal','Round Plates','Round Plates, 36" X 3/8" HR Plate Steel - Custom','each',null,'1204-01',null,null,990,250,1),
  ('metal','Round Plates','Round Plates, 30" X 3/8" HR Plate Steel','each',null,'1204-01',null,null,1000,198.89,1),
  ('metal','Round Plates','Round Plates, 26" X 3/8" HR Plate Steel - custom','each',null,'1204-01',null,null,1010,89.5,0),
  ('metal','Round Plates','Round Plates, 24" X 3/8" HR Plate Steel','each',null,'1204-01',null,null,1020,104,2),
  ('metal','Round Plates','Round Plates, 22" X 3/8" HR Plate Steel - custom','each',null,'1204-01',null,null,1030,127,0),
  ('metal','Round Plates','Round Plates, 20" X 3/8" HR Plate Steel','each',null,'1204-01',null,null,1040,81.18,1),
  ('metal','Round Plates','Round Plates, 25"x 45" x 3/8" oval - Custom','each',null,'1204-01',null,null,1050,307,0),
  ('metal','Sheet Goods','Sheet Goods, 11ga HR Per sq./ft','ft',8,'1204-01',null,null,1060,9.75,0),
  ('metal','Sheet Goods','Sheet Goods, 14ga HR Per sq./ft','ft',8,'1204-01',null,null,1070,7.31,0),
  ('metal','Sheet Goods','Sheet Goods, .75" - 9ga HR expanded metal','ft',16,'1204-01',null,null,1080,4.22,0),
  ('metal','Square Plates','Square Plates, 11.875 X 11.875" X 1/4" Square Plates','each',null,'1204-01',null,null,1090,18.76,131),
  ('metal','Square Plates','Square Plates, 6” X 6” X 1/4" Square Plates','each',null,'1204-01',null,null,1100,9.69,0),
  ('metal','Square Plates','Square Plates, 8"x8"x 1/4" Square Plate','each',null,'1204-01',null,null,1110,0,0),
  ('metal','Square Plates','Square Plates, 18"x18"x1/4" Square Plate','each',null,'1204-01',null,null,1120,27.72,1),
  ('metal','Square Plates','Square Plates, 18"x18"x3/8" Square Plate','each',null,'1204-01',null,null,1130,47.5,0),
  ('metal','Square Plates','Square Plates, 20"x20"x1/4" Square Plate','each',null,'1204-01',null,null,1140,29.89,0),
  ('metal','Square Plates','Square Plates, 20"x20"x3/8" Square Plate','each',null,'1204-01',null,null,1150,86,0),
  ('metal','Square Plates','Square Plates, 20"x34"x3/8" HRPO Square Plate','each',null,'1204-01',null,null,1160,151,0),
  ('metal','Square Tube','Square Tube, 4” X 4” X 11ga','ft',24,'1204-01',null,null,1170,11.96,73),
  ('metal','Square Tube','Square Tube, 3” X 3” X 14ga','ft',24,'1204-01',null,null,1180,8.06,120),
  ('metal','Square Tube','Square Tube, 3” X 3” X 11ga','ft',24,'1204-01',null,null,1190,9.98,0),
  ('metal','Square Tube','Square Tube, 3” X 3” X 1/4”','ft',24,'1204-01',null,null,1200,14.33,22),
  ('metal','Square Tube','Square Tube, 3/4" X 3/4" X 14ga','ft',24,'1204-01',null,null,1210,1.58,7),
  ('metal','Square Tube','Square Tube, 2”- ½” X 2”- ½” x 11ga','ft',24,'1204-01',null,null,1220,3.95,22),
  ('metal','Square Tube','Square Tube, 2.5"x2.5"x.230 - telescoping tube','ft',24,'1204-01',null,null,1230,4.17,4),
  ('metal','Square Tube','Square Tube, 2" x 2" 16 ga','ft',24,'1204-01',null,null,1240,2.5,0),
  ('metal','Square Tube','Square Tube, 2" x 2" 14 ga','ft',24,'1204-01',null,null,1250,4.21,0),
  ('metal','Square Tube','Square Tube, 2" x 2" 11 ga','ft',24,'1204-01',null,null,1260,6.27,864),
  ('metal','Square Tube','Square Tube, 1-1/2” X 1-1/2” x 14ga','ft',24,'1204-01',null,null,1270,3.04,325),
  ('metal','Square Tube','Square Tube, 1-1/2” X 1-1/2” x 11ga','ft',24,'1204-01',null,null,1280,4.5,0),
  ('metal','Square Tube','Square Tube, 1-1/2” X 1-1/2” x .25"','ft',24,'1204-01',null,null,1290,8.66,0),
  ('metal','Square Tube','Square Tube, 1/2"x1/2"x14ga','ft',24,'1204-01',null,null,1300,0.62,0),
  ('metal','Square Tube','Square Tube, 1" X 1" X 14ga','ft',24,'1204-01',null,null,1310,1.92,0),
  ('metal','Square Tube','Square Tube, 1" X 1" X 11ga','ft',24,'1204-01',null,null,1320,3.63,160),
  ('metal','Tabs','Tabs, Weld on tabs','each',null,'1204-01',null,null,1330,1,1406),
  ('metal','Tabs','Tabs, Weld on tabs (corners)','each',null,'1204-01',null,null,1340,1,372),
  ('metal','U-Channel','U-Channel, 3” - 4.1lbs U – Channel','ft',20,'1204-01',null,null,1350,5.01,0),
  ('metal','U-Channel','U-Channel, 4" Hat – Channel - wire management','ft',8,'1204-01',null,null,1360,3.13,16),
  ('metal','U-Channel','U-Channel, 5” - 6.7lbs U – Channel','ft',20,'1204-01',null,null,1370,7.37,0),
  ('metal','U-Channel','U-Channel, 3" Hat – Channel - wire management','ft',8,'1204-01',null,null,1380,4,0),
  ('metal','U-Channel','U-Channel, 1.5" Hat – Channel - wire management','ft',8,'1204-01',null,null,1390,3.13,0),
  ('metal','U-Channel','U-Channel, 3.5" Hat – Channel - wire management','ft',8,'1204-01',null,null,1400,3.13,23);

insert into inv_items (list_key, section, name, unit, std_length_ft, gl_account, species, stock, sort_order, changed_by_name)
select s.list_key, s.section, s.name, s.unit, s.std_length_ft, s.gl_account, s.species, s.stock, s.sort_order, 'From the 31 Aug 2026 workbook'
  from inv_seed_items s
 where not exists (select 1 from inv_items i where i.list_key = s.list_key and i.name = s.name);

insert into inv_prices (item_id, price, set_by_name)
select i.id, s.price, 'From the 31 Aug 2026 workbook'
  from inv_seed_items s join inv_items i on i.list_key = s.list_key and i.name = s.name
 where s.price is not null and not exists (select 1 from inv_prices p where p.item_id = i.id);

-- the starting count: closed, so September's opening numbers are the 31 Aug count
insert into inv_months (month_end, kind, status, closed_at, closed_by_name)
values ('2026-08-31', 'starting', 'closed', now(), 'From the 31 Aug 2026 workbook')
on conflict (month_end) do nothing;
insert into inv_months (month_end) values ('2026-09-30') on conflict (month_end) do nothing;

drop table if exists inv_seed_lines;
create temp table inv_seed_lines (name text, length_in numeric, width_in numeric, rows_ numeric);
insert into inv_seed_lines values
('Ash 8/4',90,42,1.5),
  ('Ash 8/4',114,42,24.5),
  ('Ash 8/4',138,42,8.25),
  ('Ash 8/4',186,42,8),
  ('Ash 6/4',114,42,25.5),
  ('Ash 6/4',138,42,13.5),
  ('Ash 6/4',162,42,2.25),
  ('Maple 8/4',114,42,33.25),
  ('Maple 8/4',138,42,15),
  ('Maple 8/4',162,42,7.5),
  ('Maple 8/4',186,42,15.75),
  ('Maple 6/4',96,42,19),
  ('Maple 6/4',114,42,94.75),
  ('Maple 6/4',138,42,43.75),
  ('Walnut 8/4',90,42,0.25),
  ('Walnut 8/4',96,42,14),
  ('Walnut 8/4',114,42,16.75),
  ('Walnut 8/4',138,42,6.75),
  ('Walnut 8/4',162,42,1),
  ('Walnut 8/4',186,42,2.25),
  ('Walnut 6/4',72,42,2.5),
  ('Walnut 6/4',84,42,19),
  ('Walnut 6/4',96,42,21),
  ('Walnut 6/4',114,42,20.5),
  ('Walnut 6/4',138,42,22.5),
  ('Flat-sawn White Oak 8/4',114,42,18.5),
  ('Flat-sawn White Oak 8/4',138,42,21.25),
  ('Flat-sawn White Oak 6/4',114,42,31),
  ('Flat-sawn White Oak 6/4',138,42,6.25),
  ('Quarter-sawn Red Oak 8/4',90,42,2.25),
  ('Maple (soft) 4/4 1C',90,42,12.25),
  ('Maple (soft) 4/4 1C',114,42,7),
  ('Cherry 4/4',96,42,28),
  ('Cherry 4/4',120,42,10),
  ('Cherry 8/4',114,42,3),
  ('Walnut 4/4 SB',138,42,10),
  ('Quarter-sawn Red Oak 5/4',114,42,3.125),
  ('Quarter-sawn Red Oak 8/4',114,42,1),
  ('Quarter-sawn Red Oak 6/4',114,42,5.25),
  ('African Mahogany 8/4',120,42,5),
  ('Rift cut White Oak 6/4',84,42,11.25),
  ('Rift cut White Oak 6/4',96,42,20.75),
  ('Hickory 8/4',120,42,7.5),
  ('Thermally Modified RO 4/4',114,42,3.5),
  ('Thermally Modified RO 6/4',114,42,2.25);

-- one bundle per line: the spreadsheet kept the total rows for each length
insert into inv_lumber_lines (month_end, item_id, length_in, width_in, bundles, updated_by_name)
select '2026-08-31', i.id, l.length_in, l.width_in, array[l.rows_], 'From the 31 Aug 2026 workbook'
  from inv_seed_lines l join inv_items i on i.list_key = 'lumber' and i.name = l.name
 where not exists (select 1 from inv_lumber_lines x where x.month_end = '2026-08-31')
on conflict (month_end, item_id, length_in) do nothing;

-- plywood on the rack at 31 Aug; metal's last count (the sheet's "prior month" column)
insert into inv_counts (month_end, item_id, qty, counted_by_name)
select '2026-08-31', i.id, s.aug_qty, 'From the 31 Aug 2026 workbook'
  from inv_seed_items s join inv_items i on i.list_key = s.list_key and i.name = s.name
 where s.aug_qty is not null and s.list_key in ('plywood', 'metal')
   and not exists (select 1 from inv_counts c join inv_items ci on ci.id = c.item_id
                    where c.month_end = '2026-08-31' and ci.list_key = s.list_key)
on conflict do nothing;

-- work order names that differ from the inventory's (the rest match by themselves)
insert into inv_species_matches (wo_norm, wo_species, inventory_species, set_by_name)
select inv_norm(v.wo), v.wo, v.inv, 'Starting match'
  from (values ('Rift White Oak', 'Rift cut White Oak'), ('Rift Sawn White Oak', 'Rift cut White Oak'),
               ('Quartersawn Red Oak', 'Quarter-sawn Red Oak'), ('Quarter Sawn Red Oak', 'Quarter-sawn Red Oak'),
               ('Quartersawn White Oak', 'Quarter-sawn White Oak')) v(wo, inv)
 where exists (select 1 from inv_items i where i.list_key = 'lumber' and inv_norm(i.species) = inv_norm(v.inv))
   and not exists (select 1 from inv_species_matches m where m.wo_norm = inv_norm(v.wo));
drop table if exists inv_seed_items; drop table if exists inv_seed_lines;


-- ---------------------------------------------------------------------
-- 5. The month being counted, and which lists are due in it
-- ---------------------------------------------------------------------

create or replace function inv_current_month() returns date
language sql stable security definer set search_path = public as $$
  select coalesce((select min(month_end) from inv_months where status = 'open'),
                  inv_month_end_d((select max(month_end) from inv_months where status = 'closed') + 1),
                  (select first_month_end from inv_settings where id = 1));
$$;

-- monthly lists every month; three-monthly lists in March, June, September and December
create or replace function inv_list_due(p_list text, p_month date) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select l.every_months = 1 or extract(month from p_month)::int % 3 = 0 from inv_lists l where l.key = p_list), false);
$$;

-- the latest send of a list for a month that hasn't been taken back
create or replace function inv_sent(p_list text, p_month date) returns inv_sends
language sql stable security definer set search_path = public as $$
  select * from inv_sends where list_key = p_list and month_end = p_month and withdrawn_at is null order by sent_at desc, id desc limit 1;
$$;

revoke all on function inv_current_month(), inv_list_due(text, date), inv_sent(text, date) from public, anon;
grant execute on function inv_current_month(), inv_list_due(text, date), inv_sent(text, date) to authenticated;


-- ---------------------------------------------------------------------
-- 6. A top's 0-scrap board feet
-- ---------------------------------------------------------------------

create or replace function inv_stock_for(p_thickness numeric) returns text
language sql stable security definer set search_path = public as $$
  select stock from inv_thickness_rules
   where retired_at is null and p_thickness between from_in - 0.001 and to_in + 0.001
   order by id limit 1;
$$;

-- work order species -> (inventory species, left out?)
create or replace function inv_species_for(p_species text, out inventory_species text, out leave_out boolean)
language plpgsql stable security definer set search_path = public as $$
declare m inv_species_matches;
begin
  leave_out := false;
  select * into m from inv_species_matches where wo_norm = inv_norm(p_species) order by set_at desc, id desc limit 1;
  if m.id is not null then inventory_species := m.inventory_species; leave_out := m.leave_out; return; end if;
  select i.species into inventory_species from inv_items i
   where i.list_key = 'lumber' and inv_norm(i.species) = inv_norm(p_species) limit 1;
end $$;

-- a top at full rectangle (round = diameter x diameter) x stock thickness x how many
create or replace function inv_top(p_species text, p_width text, p_length text, p_thickness text, p_qty int,
  out width_in numeric, out length_in numeric, out thickness_in numeric, out stock text,
  out inventory_species text, out leave_out boolean, out board_feet numeric, out problem text)
language plpgsql stable security definer set search_path = public as $$
begin
  width_in := inv_inches(p_width);
  length_in := coalesce(inv_inches(p_length), width_in);
  thickness_in := inv_inches(p_thickness);
  select s.inventory_species, s.leave_out into inventory_species, leave_out from inv_species_for(p_species) s;
  if leave_out then return; end if;
  if width_in is null or length_in is null or thickness_in is null or width_in <= 0 or length_in <= 0 then
    problem := format('Can''t read the size (%s × %s × %s)', coalesce(p_width, '?'), coalesce(p_length, '?'), coalesce(p_thickness, '?'));
    return;
  end if;
  stock := inv_stock_for(thickness_in);
  if stock is null then problem := format('No stock size for %s"', trim(to_char(thickness_in, 'FM990.999'))); return; end if;
  if inventory_species is null then problem := format('"%s" isn''t matched to an inventory species', coalesce(nullif(trim(p_species), ''), '(no species)')); return; end if;
  board_feet := round(width_in * length_in * inv_stock_in(stock) * coalesce(p_qty, 0) / 144, 3);
end $$;

revoke all on function inv_stock_for(numeric), inv_species_for(text), inv_top(text, text, text, text, int) from public, anon;
grant execute on function inv_stock_for(numeric), inv_species_for(text), inv_top(text, text, text, text, int) to authenticated;


-- ---------------------------------------------------------------------
-- 7. The month's list of sheets (managers)
--    Every sheet that goes through Milling and isn't a test job:
--      uploaded in this month, or rolled over from an earlier one
--      (not yet counted in a closed month). Sheets uploaded before the
--      first month join it only if Milling hadn't started them by then.
-- ---------------------------------------------------------------------

create or replace view v_inv_pool with (security_invoker = true) as
with m as (
  select inv_current_month() as month_end,
         (select first_month_end from inv_settings where id = 1) as first_end
), cur as (
  select j.id as job_id, j.project_id, j.name as job_name, j.is_active,
         s.id as sheet_id, s.sheet_number, s.item_code, s.species, s.shape, s.width, s.length, s.thickness, s.qty,
         (select min(w2.created_at) from work_orders w2 join sheets s2 on s2.work_order_id = w2.id
           where w2.job_id = j.id and s2.sheet_number = s.sheet_number) as first_at,
         sp.qty_done as mill_done, sp.qty_required as mill_required, sp.started_at as mill_started
    from jobs j
    join work_orders w     on w.job_id = j.id and w.is_current
    join sheets s          on s.work_order_id = w.id
    join sheet_progress sp on sp.sheet_id = s.id and sp.department = 'milling'
   where not j.is_test
)
select m.month_end, c.job_id, c.project_id, c.job_name, c.is_active, c.sheet_id, c.sheet_number, c.item_code,
       c.species, c.shape, c.width, c.length, c.thickness, c.qty,
       c.mill_done, c.mill_required, (c.mill_done >= c.mill_required) as mill_finished,
       inv_month_end(c.first_at) as upload_month,
       (inv_month_end(c.first_at) < m.month_end) as carried_over,
       coalesce(r.rolled, false) as rolled,
       t.width_in, t.length_in, t.thickness_in, t.stock, t.inventory_species, t.leave_out, t.board_feet, t.problem,
       case when t.inventory_species is not null and t.stock is not null then t.inventory_species || ' ' || t.stock end as lumber_name
  from cur c
  cross join m
  left join inv_rollovers r on r.month_end = m.month_end and r.job_id = c.job_id and r.sheet_number = c.sheet_number
  cross join lateral inv_top(c.species, c.width, c.length, c.thickness, c.qty) t
 where office_ok()
   and not exists (select 1 from inv_close_sheets x where x.job_id = c.job_id and x.sheet_number = c.sheet_number)
   and inv_month_end(c.first_at) <= m.month_end
   and (inv_month_end(c.first_at) >= m.first_end
        or c.mill_started is null
        or c.mill_started >= (m.first_end - extract(day from m.first_end)::int + 1)::timestamp at time zone 'America/Indiana/Indianapolis');

revoke all on v_inv_pool from anon;
grant select on v_inv_pool to authenticated;


-- ---------------------------------------------------------------------
-- 8. Lumber by species and thickness, each month: count, deliveries,
--    tops, scrap (managers)
-- ---------------------------------------------------------------------

create or replace view v_inv_lumber_close with (security_invoker = true) as
select l.month_end, i.id as item_id, i.name, i.species, i.stock,
       round(sum(l.length_in * l.width_in * (select coalesce(sum(b), 0) from unnest(l.bundles) b) * inv_stock_in(i.stock) / 144), 3) as board_feet,
       count(*) filter (where cardinality(l.bundles) > 0) as lines
  from inv_lumber_lines l join inv_items i on i.id = l.item_id
 group by l.month_end, i.id, i.name, i.species, i.stock;
revoke all on v_inv_lumber_close from anon;
grant select on v_inv_lumber_close to authenticated;

create or replace view v_inv_scrap with (security_invoker = true) as
with months as (
  select month_end, kind, status from inv_months
  union select inv_current_month(), 'count', 'open' where not exists (select 1 from inv_months where month_end = inv_current_month())
), closing as (
  select month_end, inv_norm(species) as sp, stock, max(species) as species, sum(board_feet) as bf from v_inv_lumber_close group by 1, 2, 3
), rec as (
  select r.month_end, inv_norm(i.species) as sp, i.stock, max(i.species) as species, sum(r.board_feet) as bf
    from inv_receipts r join inv_items i on i.id = r.item_id
   where r.kind = 'lumber' and r.mistake_at is null group by 1, 2, 3
), tops as (
  select month_end, inv_norm(inventory_species) as sp, stock, max(inventory_species) as species, sum(board_feet) as bf, count(*) as sheets
    from inv_close_sheets where board_feet is not null group by 1, 2, 3
  union all
  select month_end, inv_norm(inventory_species), stock, max(inventory_species), sum(board_feet), count(*)
    from v_inv_pool where not rolled and problem is null and board_feet is not null
     and not exists (select 1 from inv_months x where x.month_end = v_inv_pool.month_end and x.status = 'closed')
   group by 1, 2, 3
), keys as (
  select month_end, sp, stock, species from closing
  union select month_end, sp, stock, species from rec
  union select month_end, sp, stock, species from tops
  union select inv_month_end_d(month_end + 1), sp, stock, species from closing     -- last month's count is this month's opening
)
select k.month_end, mo.status as month_status, max(k.species) as species, k.stock, max(k.species) || ' ' || k.stock as name,
       o.bf as opening_bf, coalesce(rc.bf, 0) as received_bf, coalesce(c.bf, 0) as closing_bf,
       case when o.bf is null then null else o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0) end as used_bf,
       coalesce(t.bf, 0) as zero_bf, coalesce(t.sheets, 0) as tops_sheets,
       case when o.bf is null then null else o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0) - coalesce(t.bf, 0) end as scrap_bf,
       case when o.bf is null or coalesce(t.bf, 0) = 0 or o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0) <= 0 then null
            else round((o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0) - t.bf) / (o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0)), 4) end as scrap_rate,
       case when o.bf is null then 'starting count'
            when coalesce(t.bf, 0) > o.bf + coalesce(rc.bf, 0) - coalesce(c.bf, 0) + 0.5 then 'check'
            when coalesce(t.bf, 0) = 0 then 'no tops'
            else 'rate' end as verdict
  from (select distinct month_end, sp, stock, species from keys) k
  join months mo on mo.month_end = k.month_end and mo.kind = 'count'
  left join closing c  on c.month_end = k.month_end and c.sp = k.sp and c.stock = k.stock
  left join closing o  on o.month_end = (date_trunc('month', k.month_end::timestamp) - interval '1 day')::date and o.sp = k.sp and o.stock = k.stock
                      and exists (select 1 from inv_months pm where pm.month_end = o.month_end and pm.status = 'closed')
  left join rec rc     on rc.month_end = k.month_end and rc.sp = k.sp and rc.stock = k.stock
  left join tops t     on t.month_end = k.month_end and t.sp = k.sp and t.stock = k.stock
 where office_ok()
 group by k.month_end, mo.status, k.sp, k.stock, o.bf, rc.bf, c.bf, t.bf, t.sheets;
revoke all on v_inv_scrap from anon;
grant select on v_inv_scrap to authenticated;


-- ---------------------------------------------------------------------
-- 9. Values by item and GL account (managers). A closed month keeps the
--    prices it closed with; the open month uses today's prices.
-- ---------------------------------------------------------------------

create or replace view v_inv_prices with (security_invoker = true) as
select distinct on (p.item_id) p.item_id, p.price, p.set_by_name, p.set_at
  from inv_prices p order by p.item_id, p.set_at desc, p.id desc;
revoke all on v_inv_prices from anon;
grant select on v_inv_prices to authenticated;

create or replace view v_inv_values with (security_invoker = true) as
with months as (
  select month_end, status from inv_months
  union select inv_current_month(), 'open' where not exists (select 1 from inv_months where month_end = inv_current_month())
), qty as (
  select c.month_end, c.item_id, c.qty from inv_counts c
  union all
  select month_end, item_id, board_feet from v_inv_lumber_close
)
select q.month_end, mo.status as month_status, i.list_key, i.section, i.name, i.unit, i.gl_account, i.id as item_id, q.qty,
       case when mo.status = 'closed' then cv.price else pr.price end as price,
       round(q.qty * coalesce(case when mo.status = 'closed' then cv.price else pr.price end, 0), 2) as value
  from qty q
  join months mo on mo.month_end = q.month_end
  join inv_items i on i.id = q.item_id
  left join v_inv_prices pr on pr.item_id = i.id
  left join inv_close_values cv on cv.month_end = q.month_end and cv.item_id = i.id
 where office_ok();
revoke all on v_inv_values from anon;
grant select on v_inv_values to authenticated;


-- ---------------------------------------------------------------------
-- 10. Where each list stands this month (managers), and what a tablet
--     sees (its own lists, never prices)
-- ---------------------------------------------------------------------

create or replace view v_inv_status with (security_invoker = true) as
with m as (select inv_current_month() as month_end)
select m.month_end, l.key as list_key, l.name, l.department, d.name as department_name, l.every_months,
       inv_list_due(l.key, m.month_end) as due,
       case when l.key = 'lumber' then mo.lumber_done_at is not null else (inv_sent(l.key, m.month_end)).id is not null end as done,
       case when l.key = 'lumber' then mo.lumber_done_at else (inv_sent(l.key, m.month_end)).sent_at end as done_at,
       case when l.key = 'lumber' then mo.lumber_done_by else (inv_sent(l.key, m.month_end)).sent_by_name end as done_by,
       coalesce(mo.status, 'open') as month_status, mo.rollover_done_at, mo.rollover_done_by, mo.closed_at, mo.closed_by_name,
       (local_today() >= m.month_end) as count_day_reached
  from inv_lists l
  cross join m
  left join departments d on d.key = l.department
  left join inv_months mo on mo.month_end = m.month_end
 where office_ok();
revoke all on v_inv_status from anon;
grant select on v_inv_status to authenticated;

-- a supervisor's lists: shown on the tablet from the last day of the month until the month closes
create or replace view v_inv_tablet_lists with (security_invoker = true) as
with m as (select inv_current_month() as month_end)
select m.month_end, l.key as list_key, l.name, l.department, l.every_months,
       (local_today() >= m.month_end and inv_list_due(l.key, m.month_end)) as open_now,
       s.sent_at, s.sent_by_name, s.items as sent_items
  from inv_lists l
  cross join m
  left join lateral (select * from inv_sent(l.key, m.month_end)) s on true
 where l.department is not null and owns_dept(l.department) and not am_test();
revoke all on v_inv_tablet_lists from anon;
grant select on v_inv_tablet_lists to authenticated;

create or replace view v_inv_tablet_items with (security_invoker = true) as
with m as (select inv_current_month() as month_end)
select i.id as item_id, i.list_key, i.section, i.name, i.unit, i.std_length_ft, i.sort_order,
       (i.gl_account is null) as no_value,
       last.qty as last_qty, last.month_end as last_month,
       cur.qty as qty, cur.sticks, cur.loose_ft
  from inv_items i
  join inv_lists l on l.key = i.list_key
  cross join m
  left join lateral (select c.qty, c.month_end from inv_counts c where c.item_id = i.id and c.month_end < m.month_end
                      order by c.month_end desc limit 1) last on true
  left join inv_counts cur on cur.item_id = i.id and cur.month_end = m.month_end
 where not i.retired and l.department is not null and owns_dept(l.department) and not am_test();
revoke all on v_inv_tablet_items from anon;
grant select on v_inv_tablet_items to authenticated;

-- office Needs you: a count late (from the 2nd day after count day), sheets needing Setup, a month ready to close
create or replace view v_inv_needs with (security_invoker = true) as
select 'late' as kind, s.month_end, s.list_key, s.name,
       format('%s count for %s isn''t in yet%s', s.name, to_char(s.month_end, 'FMMonth'),
              case when s.department_name is not null then ' — ' || s.department_name || '''s tablet' else ' — Lumber count on the Inventory page' end) as text
  from v_inv_status s
 where s.due and not s.done and local_today() >= s.month_end + 2 and s.month_status = 'open'
union all
select 'setup', p.month_end, null, null,
       format('%s sheet%s need%s a stock size or species match before %s can close', count(*), case when count(*) = 1 then '' else 's' end,
              case when count(*) = 1 then 's' else '' end, to_char(p.month_end, 'FMMonth'))
  from v_inv_pool p where p.problem is not null and not p.rolled and local_today() >= p.month_end
 group by p.month_end
union all
select 'close', s.month_end, null, null, format('Every %s count is in — close the month on the Inventory page', to_char(s.month_end, 'FMMonth'))
  from (select month_end, bool_and(done or not due) as all_in, max(month_status) as st, bool_or(count_day_reached) as reached from v_inv_status group by month_end) s
 where s.all_in and s.st = 'open' and s.reached;
revoke all on v_inv_needs from anon;
grant select on v_inv_needs to authenticated;


-- ---------------------------------------------------------------------
-- 11. Writes. Every one checks who is asking.
-- ---------------------------------------------------------------------

create or replace function inv_office_only(p_what text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can %.', p_what using errcode = 'insufficient_privilege';
  end if;
end $$;

-- the month being counted, made if it isn't there yet; refused once closed
create or replace function inv_open_month_row() returns inv_months
language plpgsql security definer set search_path = public as $$
declare v inv_months; d date := inv_current_month();
begin
  insert into inv_months (month_end) values (d) on conflict (month_end) do nothing;
  select * into v from inv_months where month_end = d;
  if v.status = 'closed' then raise exception '% is closed; its numbers can''t change.', to_char(d, 'FMMonth YYYY'); end if;
  return v;
end $$;

-- ---- counts from a tablet (or the office on a department's behalf) ----
-- p_counts: [{"item_id": "...", "qty": 12}] or, for steel, [{"item_id": "...", "sticks": 5, "loose_ft": 7}]
-- The whole list is saved at once as absolute numbers; an item left out counts as 0.
create or replace function send_inventory_count(p_list text, p_counts jsonb, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_list inv_lists; v_month inv_months; v_prev inv_sends; v_id bigint; e jsonb; it inv_items;
  v_qty numeric; v_st int; v_lo numeric; n int := 0;
begin
  if p_client_id is not null and exists (select 1 from inv_sends where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
  end if;
  if my_role() is null and not office_ok() then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v_list from inv_lists where key = p_list;
  if v_list.key is null then raise exception '"%" is not a count list.', p_list; end if;
  if v_list.department is null then raise exception 'The % count is entered on the office Inventory page.', v_list.name; end if;
  if not (office_ok() or owns_dept(v_list.department)) then
    raise exception 'This login can''t send the % count.', v_list.name using errcode = 'insufficient_privilege';
  end if;
  if am_test() then
    raise exception 'Test logins can''t send inventory counts — there are no practice counts.' using errcode = 'insufficient_privilege';
  end if;
  v_month := inv_open_month_row();
  if not inv_list_due(p_list, v_month.month_end) then
    raise exception 'The % count isn''t due in %. It''s counted every three months.', v_list.name, to_char(v_month.month_end, 'FMMonth');
  end if;
  if local_today() < v_month.month_end and not office_ok() then
    raise exception 'The % count opens on %.', v_list.name, to_char(v_month.month_end, 'FMDay FMMonth FMDD');
  end if;
  v_prev := inv_sent(p_list, v_month.month_end);
  if v_prev.id is not null then
    raise exception 'The % count was already sent by % at %. Press "Change the count" first.', v_list.name, v_prev.sent_by_name,
      to_char(v_prev.sent_at at time zone 'America/Indiana/Indianapolis', 'FMHH12:MI AM');
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'array' then raise exception 'No counts were sent.'; end if;

  for e in select * from jsonb_array_elements(p_counts) loop
    select * into it from inv_items where id = (e->>'item_id')::uuid;
    if it.id is null or it.list_key <> p_list then raise exception 'An item in the count isn''t on the % list. Reload and try again.', v_list.name; end if;
    if it.std_length_ft is not null and (e ? 'sticks' or e ? 'loose_ft') then
      v_st := nullif(e->>'sticks', '')::int; v_lo := nullif(e->>'loose_ft', '')::numeric;
      if coalesce(v_st, 0) < 0 or coalesce(v_lo, 0) < 0 then raise exception '% can''t be less than 0.', it.name; end if;
      v_qty := coalesce(v_st, 0) * it.std_length_ft + coalesce(v_lo, 0);
    else
      v_st := null; v_lo := null; v_qty := nullif(e->>'qty', '')::numeric;
      if coalesce(v_qty, 0) < 0 then raise exception '% can''t be less than 0.', it.name; end if;
    end if;
    insert into inv_counts (month_end, item_id, qty, sticks, loose_ft, counted_by, counted_by_name)
    values (v_month.month_end, it.id, coalesce(v_qty, 0), v_st, v_lo, auth.uid(), my_name())
    on conflict (month_end, item_id) do update set qty = excluded.qty, sticks = excluded.sticks, loose_ft = excluded.loose_ft,
      counted_by = excluded.counted_by, counted_by_name = excluded.counted_by_name, counted_at = now();
    n := n + 1;
  end loop;
  -- anything on the list that wasn't sent counts as 0
  insert into inv_counts (month_end, item_id, qty, counted_by, counted_by_name)
  select v_month.month_end, i.id, 0, auth.uid(), my_name() from inv_items i
   where i.list_key = p_list and not i.retired
     and not exists (select 1 from jsonb_array_elements(p_counts) x where (x->>'item_id')::uuid = i.id)
  on conflict (month_end, item_id) do update set qty = 0, sticks = null, loose_ft = null,
    counted_by = excluded.counted_by, counted_by_name = excluded.counted_by_name, counted_at = now();

  insert into inv_sends (month_end, list_key, client_id, sent_by, sent_by_name, items)
  values (v_month.month_end, p_list, p_client_id, auth.uid(), my_name(), n) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('%s count sent — %s item%s.', v_list.name, n, case when n = 1 then '' else 's' end));
exception when unique_violation then
  if p_client_id is not null and exists (select 1 from inv_sends where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
  end if;
  raise;
end $$;

-- "Change the count": takes back the send so the list can be sent again (until the month closes)
create or replace function reopen_inventory_count(p_list text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_list inv_lists; v_month inv_months; v inv_sends;
begin
  select * into v_list from inv_lists where key = p_list;
  if v_list.key is null or v_list.department is null then raise exception '"%" is not a tablet count list.', p_list; end if;
  if not (office_ok() or owns_dept(v_list.department)) or am_test() then
    raise exception 'This login can''t change the % count.', v_list.name using errcode = 'insufficient_privilege';
  end if;
  v_month := inv_open_month_row();
  v := inv_sent(p_list, v_month.month_end);
  if v.id is null then return jsonb_build_object('ok', true, 'summary', 'Not sent yet — nothing to change.'); end if;
  update inv_sends set withdrawn_at = now(), withdrawn_by_name = my_name() where id = v.id;
  return jsonb_build_object('ok', true, 'summary', format('The %s count is open again. Change the numbers and send it.', v_list.name));
end $$;

-- ---- lumber (office) ----
-- p_bundles: the rows in each bundle, absolute; quarters only. An empty list means none at this length.
create or replace function set_lumber_line(p_item uuid, p_length numeric, p_bundles numeric[], p_width numeric default 42) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_month inv_months; it inv_items; b numeric; v_rows numeric := 0;
begin
  perform inv_office_only('enter the lumber count');
  select * into it from inv_items where id = p_item;
  if it.id is null or it.list_key <> 'lumber' then raise exception 'That isn''t a lumber item.'; end if;
  if it.retired then raise exception '% is retired. Bring it back in Setup first.', it.name; end if;
  if p_length is null or p_length <= 0 or p_length > 480 then raise exception 'The row length must be between 1 and 480 inches.'; end if;
  if p_width is null or p_width <= 0 or p_width > 120 then raise exception 'The row width must be between 1 and 120 inches.'; end if;
  foreach b in array coalesce(p_bundles, '{}') loop
    if b is not null and (b < 0 or b * 4 <> trunc(b * 4)) then
      raise exception 'Rows are counted in quarters (like 13 or 19¼); % isn''t.', b;
    end if;
    v_rows := v_rows + coalesce(b, 0);
  end loop;
  v_month := inv_open_month_row();
  insert into inv_lumber_lines (month_end, item_id, length_in, width_in, bundles, updated_by_name)
  values (v_month.month_end, p_item, p_length, p_width, coalesce(p_bundles, '{}'), my_name())
  on conflict (month_end, item_id, length_in) do update set bundles = excluded.bundles, width_in = excluded.width_in,
    updated_by_name = excluded.updated_by_name, updated_at = now();
  return jsonb_build_object('ok', true, 'rows', v_rows,
    'board_feet', round(p_length * p_width * v_rows * inv_stock_in(it.stock) / 144, 3));
end $$;

create or replace function set_lumber_done(p_done boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_month inv_months;
begin
  perform inv_office_only('mark the lumber count done');
  v_month := inv_open_month_row();
  update inv_months set lumber_done_at = case when p_done then now() end, lumber_done_by = case when p_done then my_name() end
   where month_end = v_month.month_end;
  return jsonb_build_object('ok', true, 'summary', case when p_done then 'Lumber count marked done.' else 'Lumber count open again.' end);
end $$;

-- ---- deliveries (office) ----
create or replace function add_inventory_receipt(p_kind text, p_date date, p_supplier text, p_item uuid, p_board_feet numeric,
                                                 p_sheets int, p_note text default null, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_m date; it inv_items;
begin
  perform inv_office_only('add a delivery');
  if p_client_id is not null then
    select id into v_id from inv_receipts where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already added.'); end if;
  end if;
  if p_date is null then raise exception 'Give the date on the packing slip.'; end if;
  if p_date > local_today() then raise exception 'That date is in the future.'; end if;
  v_m := inv_month_end_d(p_date);
  if exists (select 1 from inv_months where month_end = v_m and status = 'closed') then
    raise exception '% is closed. A slip for it can''t be added now.', to_char(v_m, 'FMMonth YYYY');
  end if;
  if v_m > inv_current_month() then raise exception 'That date is after the month being counted.'; end if;
  if p_kind = 'lumber' then
    select * into it from inv_items where id = p_item and list_key = 'lumber';
    if it.id is null then raise exception 'Choose the species and thickness.'; end if;
    if coalesce(p_board_feet, 0) <= 0 then raise exception 'Type the board feet on the slip.'; end if;
    insert into inv_receipts (client_id, kind, received_on, supplier, item_id, board_feet, note, entered_by, entered_by_name)
    values (p_client_id, 'lumber', p_date, nullif(trim(p_supplier), ''), p_item, p_board_feet, nullif(trim(p_note), ''), auth.uid(), my_name())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Added %s bd ft of %s.', trim(to_char(p_board_feet, 'FM999G999D###')), it.name));
  elsif p_kind = 'plywood' then
    if coalesce(p_sheets, 0) <= 0 then raise exception 'Type the number of sheets.'; end if;
    insert into inv_receipts (client_id, kind, received_on, supplier, sheets, note, entered_by, entered_by_name)
    values (p_client_id, 'plywood', p_date, nullif(trim(p_supplier), ''), p_sheets, nullif(trim(p_note), ''), auth.uid(), my_name())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Added %s sheet%s of plywood.', p_sheets, case when p_sheets = 1 then '' else 's' end));
  end if;
  raise exception 'A delivery is lumber or plywood.';
exception when unique_violation then
  select id into v_id from inv_receipts where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already added.');
end $$;

create or replace function mark_receipt_mistake(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r inv_receipts;
begin
  perform inv_office_only('change a delivery');
  select * into r from inv_receipts where id = p_id;
  if r.id is null then raise exception 'That delivery slip wasn''t found.'; end if;
  if exists (select 1 from inv_months where month_end = r.month_end and status = 'closed') then
    raise exception '% is closed; its deliveries can''t change.', to_char(r.month_end, 'FMMonth YYYY');
  end if;
  if r.mistake_at is not null then return jsonb_build_object('ok', true, 'summary', 'Already marked.'); end if;
  update inv_receipts set mistake_at = now(), mistake_by_name = my_name() where id = p_id;
  return jsonb_build_object('ok', true, 'summary', 'Marked as entered by mistake. It stays on record and no longer counts.');
end $$;

-- ---- month-end roll-over (office) ----
create or replace function set_rollover(p_job uuid, p_sheet_number int, p_rolled boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_month inv_months; p record;
begin
  perform inv_office_only('change the roll-over');
  v_month := inv_open_month_row();
  select * into p from v_inv_pool where job_id = p_job and sheet_number = p_sheet_number;
  if p.job_id is null then raise exception 'That sheet isn''t on this month''s list.'; end if;
  if p_rolled and p.mill_done > 0 then
    raise exception 'Milling has counted pieces on % sheet %, so its lumber is out. It counts this month.', p.project_id, p_sheet_number;
  end if;
  insert into inv_rollovers (month_end, job_id, sheet_number, rolled, set_by_name)
  values (v_month.month_end, p_job, p_sheet_number, coalesce(p_rolled, false), my_name())
  on conflict (month_end, job_id, sheet_number) do update set rolled = excluded.rolled, set_by_name = excluded.set_by_name, set_at = now();
  update inv_months set rollover_done_at = null, rollover_done_by = null where month_end = v_month.month_end;   -- review again
  return jsonb_build_object('ok', true, 'summary', case when p_rolled then format('%s sheet %s moves to next month.', p.project_id, p_sheet_number)
                                                        else format('%s sheet %s counts this month.', p.project_id, p_sheet_number) end);
end $$;

create or replace function set_rollover_done(p_done boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_month inv_months;
begin
  perform inv_office_only('finish the roll-over');
  v_month := inv_open_month_row();
  update inv_months set rollover_done_at = case when p_done then now() end, rollover_done_by = case when p_done then my_name() end
   where month_end = v_month.month_end;
  return jsonb_build_object('ok', true, 'summary', case when p_done then 'Roll-over saved.' else 'Roll-over open again.' end);
end $$;

-- ---- Setup (office) ----
create or replace function add_thickness_rule(p_from numeric, p_to numeric, p_stock text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_to numeric := coalesce(p_to, p_from); x inv_thickness_rules;
begin
  perform inv_office_only('change the thickness rules');
  if p_from is null or p_from <= 0 or p_from > 6 or v_to < p_from or v_to > 6 then raise exception 'Give a finished thickness range between 0 and 6 inches, smallest first.'; end if;
  if p_stock is null or p_stock !~ '^\d+/4$' or inv_stock_in(p_stock) > 6 then raise exception 'Stock is written like 6/4 or 8/4.'; end if;
  select * into x from inv_thickness_rules where retired_at is null and p_from <= to_in + 0.0005 and v_to >= from_in - 0.0005 limit 1;
  if x.id is not null then
    raise exception 'That overlaps the rule %"–%" → %. Retire that one first.', trim(to_char(x.from_in, 'FM990.999')), trim(to_char(x.to_in, 'FM990.999')), x.stock;
  end if;
  insert into inv_thickness_rules (from_in, to_in, stock, set_by_name) values (p_from, v_to, p_stock, my_name());
  return jsonb_build_object('ok', true, 'summary', format('Tops from %s" to %s" now count as %s.', trim(to_char(p_from, 'FM990.999')), trim(to_char(v_to, 'FM990.999')), p_stock));
end $$;

create or replace function retire_thickness_rule(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform inv_office_only('change the thickness rules');
  update inv_thickness_rules set retired_at = now(), retired_by_name = my_name() where id = p_id and retired_at is null;
  if not found then raise exception 'That rule wasn''t found (or is already retired).'; end if;
  return jsonb_build_object('ok', true, 'summary', 'Rule retired. It stays in the history.');
end $$;

create or replace function set_species_match(p_wo_species text, p_inventory_species text, p_leave_out boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_inv text;
begin
  perform inv_office_only('match species');
  if inv_norm(p_wo_species) is null then raise exception 'Which work order species?'; end if;
  if not coalesce(p_leave_out, false) then
    select species into v_inv from inv_items where list_key = 'lumber' and inv_norm(species) = inv_norm(p_inventory_species) limit 1;
    if v_inv is null then raise exception '"%" isn''t a lumber species on the inventory list.', p_inventory_species; end if;
  end if;
  insert into inv_species_matches (wo_norm, wo_species, inventory_species, leave_out, set_by_name)
  values (inv_norm(p_wo_species), trim(p_wo_species), v_inv, coalesce(p_leave_out, false), my_name());
  return jsonb_build_object('ok', true, 'summary', case when p_leave_out then format('"%s" is left out — not lumber.', trim(p_wo_species))
                                                        else format('"%s" now counts as %s.', trim(p_wo_species), v_inv) end);
end $$;

create or replace function set_inventory_price(p_item uuid, p_price numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare it inv_items; v_old numeric;
begin
  perform inv_office_only('change prices');
  select * into it from inv_items where id = p_item;
  if it.id is null then raise exception 'That item wasn''t found.'; end if;
  if p_price is null or p_price < 0 or p_price > 100000 then raise exception 'Give a price from 0 to 100,000.'; end if;
  select price into v_old from v_inv_prices where item_id = p_item;
  if v_old = p_price then return jsonb_build_object('ok', true, 'summary', 'Same price. Nothing changed.'); end if;
  insert into inv_prices (item_id, price, set_by, set_by_name) values (p_item, p_price, auth.uid(), my_name());
  return jsonb_build_object('ok', true, 'summary', format('%s: $%s per %s.', it.name, trim(to_char(p_price, 'FM999G990D00##')), it.unit));
end $$;

-- add (p_id null) or change an item; lumber items need species and stock
create or replace function set_inventory_item(p_id uuid, p_list text, p_section text, p_name text, p_unit text,
                                              p_std_length_ft numeric default null, p_gl_account text default null,
                                              p_species text default null, p_stock text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := nullif(trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '');
begin
  perform inv_office_only('change the count lists');
  if not exists (select 1 from inv_lists where key = p_list) then raise exception '"%" is not a count list.', p_list; end if;
  if p_list = 'lumber' then
    if inv_norm(p_species) is null or p_stock is null or p_stock !~ '^\d+/4$' then raise exception 'A lumber item needs a species and a stock thickness like 6/4.'; end if;
    v_name := coalesce(v_name, trim(p_species) || ' ' || p_stock);
  end if;
  if v_name is null then raise exception 'Give the item a name.'; end if;
  if p_std_length_ft is not null and p_std_length_ft <= 0 then raise exception 'A stick length must be more than 0 feet.'; end if;
  if exists (select 1 from inv_items where list_key = p_list and lower(name) = lower(v_name) and id is distinct from p_id) then
    raise exception '"%" is already on the list.', v_name;
  end if;
  if p_id is null then
    insert into inv_items (list_key, section, name, unit, std_length_ft, gl_account, species, stock, sort_order, changed_by_name)
    values (p_list, coalesce(trim(p_section), ''), v_name, coalesce(nullif(trim(p_unit), ''), case when p_list = 'lumber' then 'bd ft' else 'each' end),
            p_std_length_ft, nullif(trim(p_gl_account), ''), case when p_list = 'lumber' then trim(p_species) end,
            case when p_list = 'lumber' then p_stock end,
            coalesce((select max(sort_order) from inv_items where list_key = p_list), 0) + 10, my_name())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Added %s.', v_name));
  end if;
  update inv_items set section = coalesce(trim(p_section), ''), name = v_name,
         unit = coalesce(nullif(trim(p_unit), ''), unit), std_length_ft = p_std_length_ft, gl_account = nullif(trim(p_gl_account), ''),
         species = case when p_list = 'lumber' then trim(p_species) end, stock = case when p_list = 'lumber' then p_stock end,
         changed_by_name = my_name(), changed_at = now()
   where id = p_id and list_key = p_list;
  if not found then raise exception 'That item wasn''t found on the list.'; end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'summary', format('Saved %s.', v_name));
end $$;

create or replace function retire_inventory_item(p_id uuid, p_retired boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform inv_office_only('change the count lists');
  update inv_items set retired = coalesce(p_retired, true), changed_by_name = my_name(), changed_at = now() where id = p_id returning name into v;
  if v is null then raise exception 'That item wasn''t found.'; end if;
  return jsonb_build_object('ok', true, 'summary', case when p_retired then format('%s retired — its history stays.', v) else format('%s is back on the list.', v) end);
end $$;

-- ---- closing the month (office) ----
-- p_skip_date is for the check only (it can close a month early, inside a test that is undone)
create or replace function inv_close_month_now(p_skip_date boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_month inv_months; missing text; n_prob int; n_sheets int; v_next date;
begin
  perform inv_office_only('close the month');
  v_month := inv_open_month_row();
  if not p_skip_date and local_today() < v_month.month_end then
    raise exception '% can''t close before its last day (%).', to_char(v_month.month_end, 'FMMonth'), to_char(v_month.month_end, 'FMMonth FMDD');
  end if;
  select string_agg(name, ', ' order by sort_order) into missing from inv_lists l
   where inv_list_due(l.key, v_month.month_end)
     and case when l.key = 'lumber' then v_month.lumber_done_at is null else (inv_sent(l.key, v_month.month_end)).id is null end;
  if missing is not null then raise exception 'Still to come: %. Every count due this month has to be in first.', missing; end if;
  if v_month.rollover_done_at is null then raise exception 'Review the month-end roll-over first.'; end if;
  select count(*) into n_prob from v_inv_pool where problem is not null and not rolled;
  if n_prob > 0 then raise exception '% sheet% still need% a stock size or species match (Setup).', n_prob,
    case when n_prob = 1 then '' else 's' end, case when n_prob = 1 then 's' else '' end; end if;

  insert into inv_close_sheets (month_end, job_id, sheet_number, sheet_id, project_id, item_code, species, inventory_species, stock,
                                width_in, length_in, thickness_in, qty, board_feet)
  select v_month.month_end, job_id, sheet_number, sheet_id, project_id, item_code, species, inventory_species, stock,
         width_in, length_in, thickness_in, qty, board_feet
    from v_inv_pool where not rolled;
  get diagnostics n_sheets = row_count;

  insert into inv_close_values (month_end, item_id, qty, price)
  select v_month.month_end, item_id, qty, price from v_inv_values where month_end = v_month.month_end
  on conflict (month_end, item_id) do nothing;

  update inv_months set status = 'closed', closed_at = now(), closed_by = auth.uid(), closed_by_name = my_name()
   where month_end = v_month.month_end;
  v_next := inv_month_end_d(v_month.month_end + 1);
  insert into inv_months (month_end) values (v_next) on conflict (month_end) do nothing;
  return jsonb_build_object('ok', true, 'summary', format('%s is closed: %s sheets counted, numbers and prices saved. %s''s list starts with the rolled-over sheets.',
                                                          to_char(v_month.month_end, 'FMMonth YYYY'), n_sheets, to_char(v_next, 'FMMonth')));
end $$;

create or replace function close_inventory_month() returns jsonb
language sql security definer set search_path = public as $$ select inv_close_month_now(false) $$;

-- who may call what
revoke all on function inv_office_only(text), inv_open_month_row(), inv_close_month_now(boolean) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['send_inventory_count(text, jsonb, uuid)', 'reopen_inventory_count(text)',
    'set_lumber_line(uuid, numeric, numeric[], numeric)', 'set_lumber_done(boolean)',
    'add_inventory_receipt(text, date, text, uuid, numeric, int, text, uuid)', 'mark_receipt_mistake(uuid)',
    'set_rollover(uuid, int, boolean)', 'set_rollover_done(boolean)',
    'add_thickness_rule(numeric, numeric, text)', 'retire_thickness_rule(bigint)', 'set_species_match(text, text, boolean)',
    'set_inventory_price(uuid, numeric)', 'set_inventory_item(uuid, text, text, text, text, numeric, text, text, text)',
    'retire_inventory_item(uuid, boolean)', 'close_inventory_month()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 12. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------

create or replace function check_inventory()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  metal_sup uuid; other_sup uuid; tst uuid; mgr uuid;
  v_month date; v_first date; v_job uuid; v_pre uuid; v_wo uuid; v_pwo uuid; v_test uuid;
  s_rnd uuid; s_rect uuid; s_odd uuid; s_new uuid; s_start uuid; s_pre_started uuid; s_pre_new uuid;
  it_maple uuid; it_steel uuid; it_ply uuid; v_rec uuid;
  a numeric; b numeric; c numeric; d numeric;
  n int; m int; ok boolean; msg text; v jsonb; t text; r record;
begin
  select p.id into metal_sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test and 'metal' = any(p.departments) limit 1;
  select p.id into other_sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test
     and not ('full_custom' = any(p.departments)) and not ('metal' = any(p.departments)) and cardinality(p.departments) > 0 limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;
  select first_month_end into v_first from inv_settings where id = 1;

  -- ---- 1: lists and the starting count ---------------------------------------
  select count(*) into n from inv_lists;
  select count(*) into m from inv_items where list_key = 'lumber';
  select coalesce(sum(board_feet), 0) into a from v_inv_lumber_close where month_end = '2026-08-31';
  select coalesce(sum(c.qty), 0) into b from inv_counts c join inv_items i on i.id = c.item_id where c.month_end = '2026-08-31' and i.list_key = 'plywood';
  ok := n = 5 and m >= 20 and abs(a - 36440.2) < 1 and b = 207;
  res := res || check_row(1, 'Five count lists, and the 31 Aug count is loaded (36,440 bd ft of lumber, 207 sheets of plywood)', ok,
    format('Found %s lists, %s lumber items, %s bd ft and %s plywood sheets at 31 Aug. Run inventory.sql again.', n, m, round(a), b));

  -- ---- 2: sizes are read the way work orders write them -------------------------
  ok := inv_inches('36"') = 36 and inv_inches('30 1/2"') = 30.5 and inv_inches('30-1/2"') = 30.5 and inv_inches('1.25"') = 1.25
        and inv_inches('1 1/4') = 1.25 and inv_inches('3/4"') = 0.75 and inv_inches('36 in') = 36 and inv_inches('about 3 ft') is null;
  res := res || check_row(2, 'Sizes are read from the work order: 36"  30 1/2"  30-1/2"  1.25"  1 1/4  3/4"', ok,
    'One of the sizes was read wrongly.');

  if metal_sup is null or mgr is null or other_sup is null then
    res := res || check_row(3, 'A Metal supervisor, another supervisor and a manager have logins', false,
      concat_ws(' ', case when metal_sup is null then 'No real Metal supervisor.' end, case when other_sup is null then 'No other supervisor.' end,
                case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    v_month := inv_current_month();
    insert into inv_months (month_end) values (v_month) on conflict do nothing;
    select id into it_maple from inv_items where list_key = 'lumber' and species = 'Maple' and stock = '6/4';
    select id into it_steel from inv_items where list_key = 'metal' and std_length_ft = 24 and not retired order by sort_order limit 1;

    -- a job uploaded this month: a round, a rectangle, an odd thickness, one not started, one started
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999975, 'INVCHECK', 'Inventory check - undone automatically', true, 'In Production', v_month + 40) returning id into v_job;
    insert into work_orders (job_id, created_at) values (v_job, (v_month - 20)::timestamp at time zone 'America/Indiana/Indianapolis') returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 1, 2, 'IC-1', 'Checkwood Maple', 'Round', '36"', null, '1.25"') returning id into s_rnd;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 2, 3, 'IC-2', 'Checkwood Maple', 'Rectangle', '30"', '60"', '1.5"') returning id into s_rect;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 3, 1, 'IC-3', 'Checkwood Maple', 'Rectangle', '30"', '48"', '1.9"') returning id into s_odd;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 4, 4, 'IC-4', 'Checkwood Maple', 'Rectangle', '24"', '48"', '1.25"') returning id into s_new;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 5, 2, 'IC-5', 'Checkwood Maple', 'Rectangle', '24"', '24"', '1.25"') returning id into s_start;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s_rnd, 'milling', 2, 2), (s_rect, 'milling', 3, 3), (s_odd, 'milling', 1, 1), (s_new, 'milling', 4, 0), (s_start, 'milling', 2, 1);
    -- a job uploaded before the first month: one sheet Milling started back then, one it hadn't
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999974, 'INVCHECK-PRE', 'Inventory check', true, 'In Production', v_month + 40) returning id into v_pre;
    insert into work_orders (job_id, created_at) values (v_pre, (v_first - 70)::timestamp at time zone 'America/Indiana/Indianapolis') returning id into v_pwo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_pwo, 1, 1, 'IP-1', 'Checkwood Maple', 'Rectangle', '30"', '30"', '1.25"') returning id into s_pre_started;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_pwo, 2, 1, 'IP-2', 'Checkwood Maple', 'Rectangle', '30"', '30"', '1.25"') returning id into s_pre_new;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s_pre_started, 'milling', 1, 1), (s_pre_new, 'milling', 1, 0);
    update sheet_progress set started_at = (v_first - 60)::timestamp at time zone 'America/Indiana/Indianapolis' where sheet_id = s_pre_started;

    -- ---- 3: 0-scrap at full rectangle x stock thickness ---------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where problem like '%isn''t matched%') into n from v_inv_pool where job_id = v_job;
      v := set_species_match('Checkwood Maple', 'Maple', false);
      select board_feet, stock into a, t from v_inv_pool where sheet_id = s_rnd;
      select board_feet into b from v_inv_pool where sheet_id = s_rect;
      execute 'reset role';
      ok := n = 4 and a = 27 and t = '6/4' and b = 75;
      msg := format('A 36" round at 1.25" (2 tops) should be 36×36×1.5 = 27 bd ft of 6/4, and 30×60 at 1.5" (3 tops) 75 bd ft of 8/4; got %s (%s) and %s. Unmatched before the match: %s of 4.', a, t, b, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A top''s 0-scrap is its full rectangle × stock thickness (a round is diameter × diameter); unknown species wait for a match', coalesce(ok, false), msg);

    -- ---- 4: a thickness with no rule waits; a rule fixes it; overlaps are refused ----
    begin
      execute 'set local role authenticated';
      select problem into t from v_inv_pool where sheet_id = s_odd;
      v := add_thickness_rule(1.9, 1.9, '8/4');
      select board_feet into a from v_inv_pool where sheet_id = s_odd;
      begin v := add_thickness_rule(1.2, 1.3, '6/4'); n := 0; exception when others then n := 1; end;
      execute 'reset role';
      ok := t like 'No stock size%' and a = 20 and n = 1;
      msg := format('1.9" should first say "No stock size", then count 30×48×2 = 20 bd ft after the rule, and an overlapping rule should be refused. Got "%s", %s, refused %s.', t, a, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A thickness with no rule is flagged, not guessed; adding a rule counts it; overlapping rules are refused', coalesce(ok, false), msg);

    -- ---- 5: which sheets are on the month's list ----------------------------------
    begin
      execute 'set local role authenticated';
      v := make_test_job('INVCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      select count(*) filter (where job_id = v_job), count(*) filter (where sheet_id = s_pre_started), count(*) filter (where sheet_id = s_pre_new),
             count(*) filter (where job_id = v_test)
        into n, m, a, b from v_inv_pool;
      execute 'reset role';
      ok := n = 5 and m = 0 and a = 1 and b = 0;
      msg := format('Expected the 5 sheets uploaded this month, the older sheet Milling hadn''t started, and not the older started one or the test copy; got %s, %s, %s, %s.', n, a, m, b);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'The month''s list: this month''s uploads and rolled-over sheets; not test jobs, not sheets started before the first month', coalesce(ok, false), msg);

    -- ---- 6: roll-over ----------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      select zero_bf into a from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      v := set_rollover(v_job, 4, true);
      select zero_bf into b from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      begin v := set_rollover(v_job, 5, true); n := 0; exception when others then n := 1; end;
      execute 'reset role';
      ok := a - b = 48 and n = 1;
      msg := format('Rolling over the unstarted 24×48 sheet (4 tops, 48 bd ft) should take 48 off 0-scrap (took %s), and a sheet with pieces counted can''t roll (refused: %s).', a - b, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A rolled-over sheet leaves this month''s 0-scrap; a sheet Milling has counted can''t roll over', coalesce(ok, false), msg);

    -- ---- 7: the arithmetic ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      select received_bf, closing_bf, used_bf, zero_bf into a, b, c, d from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      v := add_inventory_receipt('lumber', least(local_today(), v_month), 'Check supplier', it_maple, 100, null, null, null);
      v_rec := (v->>'id')::uuid;
      v := set_lumber_line(it_maple, 479, array[1, 2.25], 42);           -- 3.25 rows × 479 × 42 × 1.5 / 144 = 681.1 bd ft
      select r2.* into r from v_inv_scrap r2 where r2.month_end = v_month and r2.species = 'Maple' and r2.stock = '6/4';
      execute 'reset role';
      ok := r.received_bf = a + 100 and abs(r.closing_bf - b - 681.078) < 0.01 and abs(r.used_bf - (c + 100 - 681.078)) < 0.01
            and r.used_bf = r.opening_bf + r.received_bf - r.closing_bf and r.scrap_bf = r.used_bf - r.zero_bf
            and (r.scrap_rate is null or abs(r.scrap_rate - r.scrap_bf / r.used_bf) < 0.0001);
      msg := format('Maple 6/4: opening %s + received %s − closing %s should be used %s; scrap %s; rate %s.', r.opening_bf, r.received_bf, r.closing_bf, r.used_bf, r.scrap_bf, r.scrap_rate);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Used = last count + received − this count; scrap = used − 0-scrap; rate = scrap ÷ used', coalesce(ok, false), msg);

    -- ---- 8: a slip entered by mistake stops counting and stays on record --------------
    begin
      execute 'set local role authenticated';
      select received_bf into a from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      v := mark_receipt_mistake(v_rec);
      select received_bf into b from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      execute 'reset role';
      ok := a - b = 100 and exists (select 1 from inv_receipts where id = v_rec and mistake_at is not null);
      msg := format('Received went %s → %s; it should drop by 100 and the slip should still be there.', a, b);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A delivery slip marked "Entered by mistake" stops counting but stays on record', coalesce(ok, false), msg);

    -- ---- 9–11: the Metal tablet (on a pretend count day, undone straight after) --------
    begin
      insert into inv_months (month_end) values ('2000-01-31');              -- the earliest open month: its count day has passed
      perform set_config('request.jwt.claims', json_build_object('sub', metal_sup, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) into n from v_inv_tablet_lists where list_key = 'metal' and open_now;
        v := send_inventory_count('metal', jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 5, 'loose_ft', 7)), gen_random_uuid());
        select qty into a from v_inv_tablet_items where item_id = it_steel;
        select count(*) filter (where qty = 0), count(*) into m, c from v_inv_tablet_items where list_key = 'metal';
        begin v := send_inventory_count('metal', '[]', gen_random_uuid()); b := 0; exception when others then b := 1; end;
        v := reopen_inventory_count('metal');
        v := send_inventory_count('metal', jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 1, 'loose_ft', 0)), gen_random_uuid());
        select qty into d from v_inv_tablet_items where item_id = it_steel;
        execute 'reset role';
        ok := n = 1 and a = 5 * 24 + 7 and m = c - 1 and b = 1 and d = 24;
        msg := format('Metal''s list open: %s. 5 sticks + 7 ft of a 24'' item should be 127 ft (got %s); the other %s items 0 (got %s); a second send refused (%s); after "Change the count", 1 stick = 24 (got %s).', n, a, c - 1, m, b, d);
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(9, 'Metal sends its count: sticks become feet, blanks count as 0, one send until "Change the count"', coalesce(ok, false), msg);

      -- 10: another department, prices, direct writes, office functions
      n := 0; msg := null;
      begin
        execute 'set local role authenticated';
        begin v := send_inventory_count('plywood', '[]', null); msg := concat_ws(', ', msg, 'sent Full Custom''s plywood count'); exception when insufficient_privilege then n := n + 1; end;
        select count(*) into m from inv_prices;  if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, format('read %s prices', m)); end if;
        select count(*) into m from v_inv_values; if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, 'read values'); end if;
        begin insert into inv_counts (month_end, item_id, qty, counted_by_name) values ('2000-01-31', it_steel, 1, 'x'); msg := concat_ws(', ', msg, 'wrote a count directly');
        exception when insufficient_privilege then n := n + 1; end;
        begin v := set_lumber_line(it_maple, 100, array[1], 42); msg := concat_ws(', ', msg, 'entered lumber'); exception when insufficient_privilege then n := n + 1; end;
        begin v := add_inventory_receipt('plywood', local_today(), null, null, null, 5, null, null); msg := concat_ws(', ', msg, 'added a delivery'); exception when insufficient_privilege then n := n + 1; end;
        begin v := close_inventory_month(); msg := concat_ws(', ', msg, 'closed the month'); exception when insufficient_privilege then n := n + 1; end;
        begin v := set_inventory_price(it_steel, 1); msg := concat_ws(', ', msg, 'changed a price'); exception when insufficient_privilege then n := n + 1; end;
        execute 'reset role';
      exception when others then execute 'reset role'; msg := concat_ws(', ', msg, 'Error: ' || sqlerrm);
      end;
      res := res || check_row(10, 'A supervisor can''t send another department''s list, see prices, write directly, or use the office''s functions', n = 8,
        format('%s of 8 refused. The Metal supervisor %s.', n, coalesce(msg, '—')));

      -- 11: test logins
      if tst is null then
        res := res || check_row(11, 'A test login sees no inventory list and can''t send a count', false, 'No Test Supervisor login to test with.');
      else
        perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
        begin
          execute 'set local role authenticated';
          select count(*) into n from v_inv_tablet_lists;
          begin v := send_inventory_count('metal', '[]', null); m := 0; exception when insufficient_privilege then m := 1; end;
          execute 'reset role';
          ok := n = 0 and m = 1;
          msg := format('The Test Supervisor saw %s lists (0 expected); sending refused: %s.', n, m);
        exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
        end;
        res := res || check_row(11, 'A test login sees no inventory list and can''t send a count', coalesce(ok, false), msg);
      end if;
      raise exception using errcode = 'P0001', message = '__inv_pretend_day__';
    exception when others then
      if sqlerrm <> '__inv_pretend_day__' then
        res := res || check_row(9, 'The Metal tablet steps ran', false, 'They stopped early: ' || sqlerrm);
      end if;
    end;

    -- ---- 12: another supervisor sees no inventory at all --------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', other_sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_inv_tablet_items where list_key in ('metal', 'plywood');
      select count(*) into m from v_inv_pool;
      execute 'reset role';
      ok := n = 0 and m = 0 and not exists (select 1 from information_schema.columns where table_name = 'v_inv_tablet_items' and column_name ilike '%price%');
      msg := format('Saw %s Metal/Plywood items and %s sheets of the month''s list; the tablet view must have no price column.', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Each tablet sees only its own list, never prices, and not the office''s sheet list', coalesce(ok, false), msg);

    -- ---- 13–15: closing the month ---------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      v := inv_close_month_now(true);                 -- as the manager (not granted to logins; close_inventory_month() calls it)
      ok := false; msg := 'The month closed with counts still missing.';
    exception when others then execute 'reset role'; ok := sqlerrm like 'Still to come%'; msg := 'Refused, but with: ' || sqlerrm;
    end;
    res := res || check_row(13, 'A month won''t close until every count due is in', ok, msg);

    begin
      -- real sheets still needing Setup are left out here (inside the undo), so the close can run
      insert into inv_species_matches (wo_norm, wo_species, inventory_species, leave_out, set_by_name)
      select distinct inv_norm(coalesce(species, '(none)')), coalesce(species, '(none)'), null, true, 'check'
        from v_inv_pool where problem is not null and job_id not in (v_job, v_pre);
      execute 'set local role authenticated';
      v := set_lumber_done(true);
      for t in select key from inv_lists where department is not null and inv_list_due(key, v_month) loop
        if (inv_sent(t, v_month)).id is null then
          v := send_inventory_count(t, case when t = 'metal' then jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 2, 'loose_ft', 0)) else '[]' end, null);
        end if;
      end loop;
      v := set_rollover_done(true);
      select coalesce(sum(value), 0) into a from v_inv_values where month_end = v_month;
      execute 'reset role';
      v := inv_close_month_now(true);
      select count(*) filter (where job_id = v_job), count(*) filter (where job_id = v_job and sheet_number = 4) into n, m from inv_close_sheets where month_end = v_month;
      ok := n = 4 and m = 0 and (select status from inv_months where month_end = v_month) = 'closed'
            and inv_current_month() = inv_month_end_d(v_month + 1)
            and exists (select 1 from v_inv_pool where job_id = v_job and sheet_number = 4);
      msg := format('Expected 4 of the check''s sheets saved with the month and the rolled-over one on next month''s list; got %s saved (rolled one saved: %s). %s', n, m, v->>'summary');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Closing saves the month''s sheets; a rolled-over sheet moves to next month''s list', coalesce(ok, false), msg);

    begin
      execute 'set local role authenticated';
      select item_id into it_ply from inv_close_values where month_end = v_month and qty > 0 order by qty desc limit 1;
      v := set_inventory_price(it_ply, 99999);
      select coalesce(sum(value), 0) into b from v_inv_values where month_end = v_month;
      begin v := add_inventory_receipt('plywood', v_month, null, null, null, 3, null, null); n := 0; exception when others then n := 1; end;
      begin v := mark_receipt_mistake(v_rec); m := 0; exception when others then m := 1; end;
      execute 'reset role';
      ok := it_ply is not null and a = b and n = 1 and m = 1;
      msg := format('After closing: a new price changed the month''s value %s → %s (must not), a slip for it was refused: %s, changing its slips refused: %s.', a, b, n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'A closed month is frozen: its prices, deliveries and counts don''t change', coalesce(ok, false), msg);

    -- ---- 16: no login -----------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    foreach t in array array['inv_items', 'inv_prices', 'inv_counts', 'inv_lumber_lines', 'inv_receipts', 'inv_months', 'inv_close_sheets',
                             'v_inv_pool', 'v_inv_scrap', 'v_inv_values', 'v_inv_status', 'v_inv_tablet_lists', 'v_inv_tablet_items', 'v_inv_needs'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        if m > 0 then n := n + m; msg := concat_ws(', ', msg, format('%s rows of %s', m, t)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; n := n + 1; msg := concat_ws(', ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(16, 'Someone with no login sees none of it', n = 0, coalesce(msg, '') || ' visible without logging in. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_inventory_undo__';
  exception when others then
    if sqlerrm <> '__check_inventory_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x order by (x->>'step')::int;
end;
$$;
revoke all on function check_inventory() from public, anon, authenticated;

select * from check_inventory();
