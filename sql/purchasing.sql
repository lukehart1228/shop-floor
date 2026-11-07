-- =====================================================================
-- purchasing.sql — Purchasing: suppliers, items, POs, prices (7 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 57. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Needs inventory.sql (25), supplies.sql and arrow_pos.sql (51): a PO
-- prints the same PO details (issuer, phone, e-mail, address, tax-exempt
-- line) as the Arrow POs, and a supply request can go onto a PO.
-- Replaces nothing, so no earlier file stops. Nothing that's running
-- changes: only purchasing.html calls any of it.
--
-- Then paste purchasing_history.sql (kept on Luke's computer, never on
-- GitHub: it holds the suppliers' prices and contacts) to load 2026's
-- lumber POs 1-23 and 2025's lumber averages.
--
-- WHAT IT DOES (design: the Purchasing tab, "First release: standalone",
-- and the Lumber buying & POs tab). Managers only, through these functions.
-- 1. purchase_categories (lumber, sheet goods, hardware, finishing, tube
--    and steel, abrasives, other), purchase_suppliers, purchase_items: each
--    item has a category and a unit; lumber items also a thickness in
--    quarters, and may be compared as another (7/4 Ash against 8/4 Ash at
--    the same square feet) and tied to an Inventory lumber item.
-- 2. purchase_baselines: an item's price for a year (lumber's 2025
--    averages). A buy is measured against the year before's: a typed one
--    if there is one, else that year's average paid (from 2027). In 2026,
--    items with no typed baseline are measured against their first price
--    paid in 2026. The page works this out from purchasing_data().
-- 3. POs: two series kept by the database, never reused. Lumber PO 24 on
--    ("Lumber PO 24.pdf") and PO 00001 on ("PO 00001.pdf"). Every PO kept
--    as printed, every earlier version whole (r2, r3); cancel, never
--    delete. A line can be a tablet's supply request: making the PO marks
--    it ordered, as Operations' tick does. Lumber lines take their delivery
--    slips (Inventory's lumber slips) on the Purchasing page.
-- 4. What's entered is the truth (Luke, 7 Nov); bills are checked against
--    it once a year outside the app, from the page's export. Prices adds
--    up the POs' lines and the buys with no PO (card, Amazon, a store run)
--    from the Purchases file (from the Purchases project). A file line
--    that's for a PO (its PO column: "Lumber PO 17", "PO 00001") is kept
--    on record against that PO and not counted again. A line already in
--    (same supplier, bill or receipt number and line) is skipped; a line
--    naming a known item, or one matched before, is filed under it; the
--    rest wait in Match these.
-- 5. lumber_year_totals and lumber_scrap_history: lumber's earlier years
--    and the months before Inventory's own scrap rate.
-- 6. purchasing_data(): everything the page needs in one call.
-- Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('purchasing.sql', 57, 'check_purchasing', 'check_purchasing', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('purchasing.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.add_inventory_receipt(text,date,text,uuid,numeric,integer,text,uuid)') is null then raise exception 'Run inventory.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.arrow_po_settings_get()') is null then raise exception 'Run arrow_pos.sql first. A PO prints the same PO details.'; end if;
  if to_regclass('public.supply_requests') is null then raise exception 'Run supplies.sql first. A supply request can go onto a PO.'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Categories, suppliers and items
-- ---------------------------------------------------------------------

create table if not exists purchase_categories (
  key          text primary key check (key ~ '^[a-z][a-z0-9_]{0,30}$'),
  name         text not null unique check (length(name) between 1 and 60),
  sort_order   int  not null default 100,
  retired      boolean not null default false
);
insert into purchase_categories (key, name, sort_order) values
  ('lumber', 'Lumber', 10), ('sheet_goods', 'Sheet goods', 20), ('hardware', 'Hardware', 30), ('finishing', 'Finishing', 40),
  ('tube_steel', 'Tube and steel', 50), ('abrasives', 'Abrasives', 60), ('other', 'Other', 90)
on conflict (key) do nothing;

create table if not exists purchase_suppliers (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,          -- as the app shows it: Smith Lumber
  company      text,                          -- as the PO prints it (blank = the name)
  contact      text,
  street       text,
  city         text,                          -- city, state, zip
  phone        text,
  email        text,
  aliases      text[] not null default '{}',  -- other names a Purchases file uses for it (Amazon.com, AMZN Mktp US)
  retired      boolean not null default false,
  changed_at   timestamptz not null default now(),
  changed_by_name text,
  constraint purchase_suppliers_len check (length(name) between 1 and 80 and length(coalesce(company, '')) <= 120
         and length(coalesce(contact, '')) <= 80 and length(coalesce(street, '')) <= 120 and length(coalesce(city, '')) <= 120
         and length(coalesce(phone, '')) <= 40 and length(coalesce(email, '')) <= 120 and cardinality(aliases) <= 20)
);

create table if not exists purchase_items (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,          -- 6/4 Maple; 3/4 Maple Plywood; 120 grit disc
  category_key text not null default 'lumber' references purchase_categories(key),
  unit         text not null default 'bd ft', -- bd ft, sheet, each, gallon, box, ft …
  quarters     int  check (quarters between 4 and 16),                -- lumber: 6 for 6/4
  compare_as   uuid references purchase_items(id),                     -- 7/4 Ash: against 8/4 Ash at the same square feet
  inv_item_id  uuid references inv_items(id),                          -- what a lumber slip of it is entered as on Inventory
  aliases      text[] not null default '{}',                           -- other names a Purchases file uses for it (8/4 QS Red Oak)
  retired      boolean not null default false,
  changed_at   timestamptz not null default now(),
  changed_by_name text,
  constraint purchase_items_len check (length(name) between 1 and 80 and length(unit) between 1 and 20 and cardinality(aliases) <= 30),
  constraint purchase_items_not_self check (compare_as is null or compare_as <> id),
  constraint purchase_items_lumber check ((category_key = 'lumber') = (quarters is not null)
                                          and (category_key = 'lumber' or (compare_as is null and inv_item_id is null))
                                          and (category_key <> 'lumber' or unit = 'bd ft'))
);

-- an item's price for a year, typed (lumber's 2025 averages); the year after is measured against it
create table if not exists purchase_baselines (
  item_id      uuid not null references purchase_items(id),
  year         int  not null check (year between 2000 and 2100),
  price        numeric(12,4) not null check (price > 0),
  note         text check (length(coalesce(note, '')) <= 200),
  changed_at   timestamptz not null default now(),
  changed_by_name text,
  primary key (item_id, year)
);

-- the typed price a buy in p_year is measured against: the year before's, or for a compare-as item the
-- other item's scaled to the same square feet (a board foot of 7/4 covers 8/7 of what one of 8/4 does).
-- Null: no typed baseline; the page then uses the year before's average paid, or in 2026 the first price paid.
create or replace function purchase_benchmark(p_item uuid, p_year int) returns numeric
language sql stable security definer set search_path = public as $$
  select case when i.compare_as is null then (select price from purchase_baselines where item_id = i.id and year = p_year - 1)
              else round((select price from purchase_baselines where item_id = c.id and year = p_year - 1) * c.quarters / i.quarters, 4) end
    from purchase_items i left join purchase_items c on c.id = i.compare_as
   where i.id = p_item;
$$;
revoke all on function purchase_benchmark(uuid, int) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. The POs
-- ---------------------------------------------------------------------

create table if not exists purchase_po_settings (
  id            boolean primary key default true check (id),
  next_lumber   int not null default 24 check (next_lumber between 1 and 999999),
  next_po       int not null default 1  check (next_po between 1 and 99999),
  updated_at    timestamptz,
  updated_by_name text
);
insert into purchase_po_settings (id) values (true) on conflict (id) do nothing;

create table if not exists purchase_pos (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid unique,                   -- made on the page, so a resend is one PO
  series         text not null check (series in ('lumber', 'po')),
  po_number      int  not null,
  name           text not null,                 -- Lumber PO 24 / PO 00001
  file_name      text,                          -- Lumber PO 24.pdf, PO 00001 r2.pdf; null = from the workbook, no PDF
  from_history   boolean not null default false,
  vendor_id      uuid not null references purchase_suppliers(id),
  ordered_on     date not null,                 -- the PO's Date Issued
  header         jsonb not null default '{}',   -- what it printed: vendor box, issuer, ship to, the date row
  printed        jsonb not null default '[]',   -- the lines as printed, in order
  revision       int  not null default 1,
  earlier        jsonb not null default '[]',   -- every earlier version whole: {revision, file_name, header, printed, lines, at, by}
  made_at        timestamptz not null default now(),
  made_by        uuid references profiles(id),
  made_by_name   text,
  changed_at     timestamptz,
  changed_by_name text,
  cancelled_at   timestamptz,
  cancelled_by_name text,
  cancel_reason  text,
  filed_at       timestamptz,                   -- the PDF of this revision in PD - POs
  filed_bytes    bigint,
  filed_by_name  text,
  constraint purchase_pos_reason check (length(coalesce(cancel_reason, '')) <= 200),
  constraint purchase_pos_number unique (series, po_number)
);

create table if not exists purchase_po_lines (
  id            uuid primary key default gen_random_uuid(),
  po_id         uuid not null references purchase_pos(id),
  position      int  not null check (position between 1 and 200),  -- printed 1 to 22 (the template's rows); a change moves them past 100 for a moment
  qty           numeric not null check (qty > 0),
  unit          text not null default '',      -- blank = board feet (a lumber line); "Sheets" for plywood
  description   text not null,
  job_number    text not null default '',
  unit_price    numeric(12,4) check (unit_price is null or unit_price >= 0),
  item_id       uuid references purchase_items(id),     -- null = printed, not tracked
  supply_request_id uuid references supply_requests(id), -- a tablet's request this line orders
  history_in_bf numeric check (history_in_bf is null or history_in_bf > 0),   -- lumber received, from the workbook
  measured_bf   numeric check (measured_bf is null or measured_bf > 0),       -- lumber measured after SLR
  measured_by_name text,
  removed_at    timestamptz,                    -- taken off the PO by a change; kept
  constraint purchase_po_lines_len check (length(description) between 1 and 200 and length(unit) <= 20 and length(job_number) <= 40)
);
create unique index if not exists purchase_po_lines_pos_idx on purchase_po_lines (po_id, position) where removed_at is null;

-- a lumber delivery slip (Inventory, Deliveries in) and the PO line it fills
create table if not exists purchase_receipts (
  receipt_id    uuid primary key references inv_receipts(id),
  line_id       uuid not null references purchase_po_lines(id),
  linked_at     timestamptz not null default now(),
  linked_by_name text
);
create index if not exists purchase_receipts_line_idx on purchase_receipts (line_id);

create table if not exists lumber_year_totals (
  year       int  not null check (year between 2000 and 2100),
  vendor_id  uuid not null references purchase_suppliers(id),
  bf         numeric not null check (bf >= 0),
  dollars    numeric not null check (dollars >= 0),
  primary key (year, vendor_id)
);

create table if not exists lumber_scrap_history (
  month_end  date primary key,
  zero_bf    numeric not null check (zero_bf > 0),
  used_bf    numeric not null check (used_bf > 0)
);


-- ---------------------------------------------------------------------
-- 3. The Purchases file: every buy as billed or paid
-- ---------------------------------------------------------------------

create table if not exists purchase_files (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null unique,           -- the page's own id: a resend is one file
  file_name    text not null check (length(file_name) between 1 and 200),
  sha256       text check (sha256 ~ '^[0-9a-f]{64}$'),
  lines_in     int  not null default 0,        -- lines in the file
  lines_new    int  not null default 0,        -- added
  lines_skipped int not null default 0,        -- already in
  dropped_at   timestamptz not null default now(),
  dropped_by_name text
);

create table if not exists purchase_buys (
  id           uuid primary key default gen_random_uuid(),
  file_id      uuid not null references purchase_files(id),
  supplier_id  uuid references purchase_suppliers(id),   -- the supplier it names, when known
  supplier_name text not null,                 -- as the file has it
  doc_number   text not null default '',       -- bill, receipt or order number
  line_key     text not null,                  -- its line on that document (the file's, or its place in it)
  bought_on    date not null,
  how          text not null default '',       -- Bill, Card, Credit …
  description  text not null,
  category_key text references purchase_categories(key),
  item_id      uuid references purchase_items(id),   -- null and not ignored: waiting in Match these
  item_text    text not null default '',       -- the item the file named, as it named it
  qty          numeric,
  unit         text not null default '',
  amount       numeric(14,2) not null,         -- what was paid (a credit is below 0)
  in_baseline  boolean not null default true,  -- counts towards its item's average paid
  po_ref       text not null default '',       -- the PO it's for ("Lumber PO 17"): on record, not counted again
  note         text not null default '',
  matched_by_name text,
  matched_at   timestamptz,
  ignored_at   timestamptz,                    -- not a production buy, or not one to price (kept)
  ignored_by_name text,
  ignore_reason text,
  constraint purchase_buys_len check (length(supplier_name) between 1 and 120 and length(doc_number) <= 80 and length(line_key) between 1 and 40
         and length(how) <= 40 and length(description) between 1 and 400 and length(unit) <= 20 and length(note) <= 400
         and length(coalesce(ignore_reason, '')) <= 200 and length(po_ref) <= 40 and length(item_text) <= 80),
  constraint purchase_buys_qty check (qty is null or qty <> 0)
);
create unique index if not exists purchase_buys_once on purchase_buys (lower(btrim(supplier_name)), lower(btrim(doc_number)), lower(line_key));
create index if not exists purchase_buys_item_idx on purchase_buys (item_id, bought_on);

-- what a line was matched to, so the next file's same line files itself
create table if not exists purchase_match_rules (
  supplier_key text not null,                  -- the supplier's id when it's known, else lower(its name as in the file)
  description_key text not null,               -- lower(description), spaces squeezed
  item_id      uuid not null references purchase_items(id),
  made_at      timestamptz not null default now(),
  made_by_name text,
  primary key (supplier_key, description_key)
);

-- only managers, and only through the functions below: no login reads or writes a table directly
do $$ declare t text; begin
  foreach t in array array['purchase_categories', 'purchase_suppliers', 'purchase_items', 'purchase_baselines', 'purchase_po_settings',
                           'purchase_pos', 'purchase_po_lines', 'purchase_receipts', 'lumber_year_totals', 'lumber_scrap_history',
                           'purchase_files', 'purchase_buys', 'purchase_match_rules'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- a description as matched: lower case, spaces squeezed
create or replace function purchase_key(p text) returns text
language sql immutable set search_path = public as $$
  select lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'));
$$;
revoke all on function purchase_key(text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. Reading: everything the Purchasing page needs
-- ---------------------------------------------------------------------

-- PO lines with what they count: a lumber line counts its slips' board feet once they come, else the
-- workbook's figure, else what was ordered; its benchmark is its item's typed baseline for the PO's year
create or replace function purchase_line_rows() returns table (
  id uuid, po_id uuid, "position" int, qty numeric, unit text, description text, job_number text, unit_price numeric,
  item_id uuid, supply_request_id uuid, history_in_bf numeric, measured_bf numeric, slips_bf numeric, slips int, received_bf numeric,
  bf numeric, benchmark numeric, lumber boolean)
language sql stable security definer set search_path = public as $$
  select l.id, l.po_id, l.position, l.qty, l.unit, l.description, l.job_number, l.unit_price, l.item_id, l.supply_request_id,
         l.history_in_bf, l.measured_bf,
         s.bf, coalesce(s.n, 0)::int,
         coalesce(s.bf, l.history_in_bf),
         case when i.category_key = 'lumber' then coalesce(s.bf, l.history_in_bf, l.qty) end,
         case when i.id is not null then purchase_benchmark(i.id, extract(year from p.ordered_on)::int) end,
         coalesce(i.category_key = 'lumber', false)
    from purchase_po_lines l
    join purchase_pos p on p.id = l.po_id
    left join purchase_items i on i.id = l.item_id
    left join lateral (select sum(r.board_feet) bf, count(*) n from purchase_receipts x join inv_receipts r on r.id = x.receipt_id
                        where x.line_id = l.id and r.mistake_at is null) s on true
   where l.removed_at is null;
$$;
revoke all on function purchase_line_rows() from public, anon, authenticated;

create or replace function purchasing_data() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_issuer jsonb;
begin
  if not office_ok() then raise exception 'Only a manager sees purchasing.' using errcode = 'insufficient_privilege'; end if;
  select jsonb_build_object('issued_by', issued_by, 'phone', phone, 'email', email, 'address', address, 'tax_line', tax_line,
                            'ready', nullif(btrim(coalesce(issued_by, '')), '') is not null)
    into v_issuer from arrow_po_settings;
  return jsonb_build_object(
    'today', local_today(),
    'issuer', coalesce(v_issuer, '{}'::jsonb),
    'next_lumber', (select next_lumber from purchase_po_settings),
    'next_po', (select next_po from purchase_po_settings),
    'last_lumber', (select max(po_number) from purchase_pos where series = 'lumber'),
    'last_po', (select max(po_number) from purchase_pos where series = 'po'),
    'categories', coalesce((select jsonb_agg(to_jsonb(c) order by c.retired, c.sort_order, c.name) from purchase_categories c), '[]'),
    'suppliers', coalesce((select jsonb_agg(to_jsonb(v) order by v.retired, v.name) from purchase_suppliers v), '[]'),
    'items', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object(
                         'benchmark', purchase_benchmark(i.id, extract(year from local_today())::int),
                         'inv_name', (select name from inv_items where id = i.inv_item_id)) order by i.retired, i.category_key, i.name)
                       from purchase_items i), '[]'),
    'baselines', coalesce((select jsonb_agg(jsonb_build_object('item_id', b.item_id, 'year', b.year, 'price', b.price, 'note', b.note)
                                            order by b.year, b.item_id) from purchase_baselines b), '[]'),
    'inv_items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                             from inv_items where list_key = 'lumber' and not retired), '[]'),
    'pos', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object(
                       'vendor', (select name from purchase_suppliers where id = p.vendor_id),
                       'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.position) from purchase_line_rows() l where l.po_id = p.id), '[]'))
                     order by p.ordered_on desc, p.series, p.po_number desc) from purchase_pos p), '[]'),
    'buys', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'file_id', b.file_id, 'supplier_id', b.supplier_id, 'supplier', b.supplier_name,
                       'doc', b.doc_number, 'line', b.line_key, 'on', b.bought_on, 'how', b.how, 'description', b.description, 'item_text', b.item_text,
                       'category', b.category_key, 'item_id', b.item_id, 'qty', b.qty, 'unit', b.unit, 'amount', b.amount,
                       'in_baseline', b.in_baseline, 'note', b.note, 'matched_by', b.matched_by_name, 'ignored', b.ignored_at is not null,
                       'po', nullif(b.po_ref, ''), 'po_id', (select p.id from purchase_pos p where lower(p.name) = lower(b.po_ref) and b.po_ref <> ''),
                       'ignore_reason', b.ignore_reason) order by b.bought_on, b.supplier_name, b.doc_number, b.line_key) from purchase_buys b), '[]'),
    'files', coalesce((select jsonb_agg(to_jsonb(f) order by f.dropped_at desc) from purchase_files f), '[]'),
    'year_totals', coalesce((select jsonb_agg(jsonb_build_object('year', t.year, 'vendor_id', t.vendor_id, 'bf', t.bf, 'dollars', t.dollars)) from lumber_year_totals t), '[]'),
    'scrap_history', coalesce((select jsonb_agg(jsonb_build_object('month_end', month_end, 'zero_bf', zero_bf, 'used_bf', used_bf) order by month_end)
                                 from lumber_scrap_history), '[]'),
    -- Inventory's own months: closed months only, every species and thickness with a rate
    'scrap_inventory', coalesce((select jsonb_agg(jsonb_build_object('month_end', month_end, 'zero_bf', z, 'used_bf', u) order by month_end) from (
                                   select month_end, sum(zero_bf) z, sum(used_bf) u from v_inv_scrap
                                    where month_status = 'closed' and verdict = 'rate' group by month_end) m), '[]'));
end $$;
revoke all on function purchasing_data() from public, anon;
grant execute on function purchasing_data() to authenticated;


-- ---------------------------------------------------------------------
-- 5. Setup: categories, suppliers, items, baselines, the next numbers, earlier years
-- ---------------------------------------------------------------------

create or replace function purchase_category_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_key text := nullif(btrim(coalesce(p ->> 'key', '')), ''); v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
begin
  if not office_ok() then raise exception 'Only a manager changes the categories.' using errcode = 'insufficient_privilege'; end if;
  if v_name is null then raise exception 'Give the category a name.'; end if;
  if v_key is null then
    v_key := left(regexp_replace(regexp_replace(lower(v_name), '[^a-z0-9]+', '_', 'g'), '^_+|_+$', '', 'g'), 30);
    if v_key !~ '^[a-z]' then v_key := 'c_' || left(v_key, 28); end if;
    insert into purchase_categories (key, name, sort_order) values (v_key, v_name, coalesce((select max(sort_order) from purchase_categories where key <> 'other'), 0) + 10);
  else
    update purchase_categories set name = v_name, retired = coalesce((p ->> 'retired')::boolean, retired) where key = v_key;
    if not found then raise exception 'That category wasn''t found.'; end if;
    if v_key = 'lumber' and (select retired from purchase_categories where key = 'lumber') then
      raise exception 'Lumber can''t be retired: the lumber POs and results depend on it.';
    end if;
  end if;
  return jsonb_build_object('ok', true, 'key', v_key);
exception
  when unique_violation then raise exception 'There''s already a category called %.', v_name;
  when check_violation then raise exception 'The category''s name is too long.';
end $$;
revoke all on function purchase_category_save(jsonb) from public, anon;
grant execute on function purchase_category_save(jsonb) to authenticated;

create or replace function purchase_supplier_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_alias text[];
begin
  if not office_ok() then raise exception 'Only a manager changes the suppliers.' using errcode = 'insufficient_privilege'; end if;
  if nullif(btrim(coalesce(p ->> 'name', '')), '') is null then raise exception 'Give the supplier a name.'; end if;
  select coalesce(array_agg(distinct btrim(a)) filter (where btrim(a) <> ''), '{}') into v_alias
    from jsonb_array_elements_text(coalesce(p -> 'aliases', '[]')) a;
  if v_id is null then
    insert into purchase_suppliers (name, company, contact, street, city, phone, email, aliases, changed_by_name)
    values (btrim(p ->> 'name'), nullif(btrim(p ->> 'company'), ''), nullif(btrim(p ->> 'contact'), ''), nullif(btrim(p ->> 'street'), ''),
            nullif(btrim(p ->> 'city'), ''), nullif(btrim(p ->> 'phone'), ''), nullif(btrim(p ->> 'email'), ''), v_alias, my_name())
    returning id into v_id;
  else
    update purchase_suppliers set name = btrim(p ->> 'name'), company = nullif(btrim(p ->> 'company'), ''), contact = nullif(btrim(p ->> 'contact'), ''),
           street = nullif(btrim(p ->> 'street'), ''), city = nullif(btrim(p ->> 'city'), ''), phone = nullif(btrim(p ->> 'phone'), ''),
           email = nullif(btrim(p ->> 'email'), ''), aliases = case when p ? 'aliases' then v_alias else aliases end,
           retired = coalesce((p ->> 'retired')::boolean, retired), changed_at = now(), changed_by_name = my_name()
     where id = v_id;
    if not found then raise exception 'That supplier wasn''t found.'; end if;
  end if;
  -- buys whose supplier name is one of this supplier's names now point at it
  update purchase_buys b set supplier_id = v_id
   where b.supplier_id is null
     and lower(btrim(b.supplier_name)) in (select lower(btrim(n)) from purchase_suppliers s, unnest(s.name || s.aliases) n where s.id = v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then raise exception 'There''s already a supplier called %.', btrim(p ->> 'name');
  when check_violation then raise exception 'One of the supplier''s details is too long, or it has more than 20 other names.';
end $$;
revoke all on function purchase_supplier_save(jsonb) from public, anon;
grant execute on function purchase_supplier_save(jsonb) to authenticated;

-- p: {id?, name, category_key, unit, quarters (lumber), compare_as (lumber), inv_item_id (lumber), aliases?, retired?}
create or replace function purchase_item_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_q int; v_ca uuid; v_inv uuid; v_name text; v_cat text; v_unit text; v_alias text[];
begin
  if not office_ok() then raise exception 'Only a manager changes the items.' using errcode = 'insufficient_privilege'; end if;
  v_name := nullif(btrim(coalesce(p ->> 'name', '')), '');
  if v_name is null then raise exception 'Give the item a name, like 6/4 Maple.'; end if;
  v_cat := coalesce(nullif(p ->> 'category_key', ''), 'lumber');
  if not exists (select 1 from purchase_categories where key = v_cat) then raise exception 'That category wasn''t found.'; end if;
  if v_cat = 'lumber' then
    v_q := nullif(p ->> 'quarters', '')::int;
    if v_q is null or v_q < 4 or v_q > 16 then raise exception 'Give the lumber''s thickness in quarters: 6 for 6/4.'; end if;
    v_unit := 'bd ft';
    v_ca := nullif(p ->> 'compare_as', '')::uuid;
    v_inv := nullif(p ->> 'inv_item_id', '')::uuid;
  else
    v_unit := nullif(btrim(coalesce(p ->> 'unit', '')), '');
    if v_unit is null then raise exception 'Give the unit it''s bought in: sheet, each, gallon, box, ft…'; end if;
    if nullif(p ->> 'compare_as', '') is not null or nullif(p ->> 'inv_item_id', '') is not null then
      raise exception 'Only lumber is compared as another item or tied to Inventory.';
    end if;
  end if;
  if v_ca is not null then
    if v_ca = v_id then raise exception 'An item can''t be compared with itself.'; end if;
    if not exists (select 1 from purchase_items where id = v_ca and category_key = 'lumber') then raise exception 'That lumber item to compare with wasn''t found.'; end if;
    if exists (select 1 from purchase_items where id = v_ca and compare_as is not null) then
      raise exception 'Compare it with an item that has its own baseline.';
    end if;
    if v_id is not null and exists (select 1 from purchase_items where compare_as = v_id) then
      raise exception 'Other items are compared with this one, so it needs its own baseline.';
    end if;
  end if;
  if v_inv is not null and not exists (select 1 from inv_items where id = v_inv and list_key = 'lumber') then
    raise exception 'That Inventory item isn''t on the lumber list.';
  end if;
  select coalesce(array_agg(distinct btrim(a)) filter (where btrim(a) <> '' and lower(btrim(a)) <> lower(v_name)), '{}') into v_alias
    from jsonb_array_elements_text(coalesce(p -> 'aliases', '[]')) a;
  if exists (select 1 from purchase_items i, unnest(i.name || i.aliases) n
              where i.id is distinct from v_id and lower(n) in (select lower(x) from unnest(v_name || v_alias) x)) then
    raise exception 'Another item already has that name, or one of these other names.';
  end if;
  if v_id is null then
    insert into purchase_items (name, category_key, unit, quarters, compare_as, inv_item_id, aliases, changed_by_name)
    values (v_name, v_cat, v_unit, v_q, v_ca, v_inv, v_alias, my_name()) returning id into v_id;
  else
    if v_cat <> 'lumber' and exists (select 1 from purchase_items where compare_as = v_id) then
      raise exception 'Lumber items are compared with this one, so it stays lumber.';
    end if;
    update purchase_items set name = v_name, category_key = v_cat, unit = v_unit, quarters = v_q, compare_as = v_ca, inv_item_id = v_inv,
           aliases = case when p ? 'aliases' then v_alias else aliases end,
           retired = coalesce((p ->> 'retired')::boolean, retired), changed_at = now(), changed_by_name = my_name()
     where id = v_id;
    if not found then raise exception 'That item wasn''t found.'; end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'benchmark', purchase_benchmark(v_id, extract(year from local_today())::int));
exception
  when unique_violation then raise exception 'There''s already an item called %.', v_name;
  when check_violation then raise exception 'The item''s name or unit is too long, or it has more than 30 other names.';
end $$;
revoke all on function purchase_item_save(jsonb) from public, anon;
grant execute on function purchase_item_save(jsonb) to authenticated;

-- an item's price for a year (null price: take it away)
create or replace function purchase_baseline_save(p_item uuid, p_year int, p_price numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager changes a baseline.' using errcode = 'insufficient_privilege'; end if;
  if not exists (select 1 from purchase_items where id = p_item) then raise exception 'That item wasn''t found.'; end if;
  if p_year is null or p_year < 2000 or p_year > extract(year from local_today())::int then raise exception 'Give the year the price is for (this year or earlier).'; end if;
  if p_price is null then
    delete from purchase_baselines where item_id = p_item and year = p_year;
    return jsonb_build_object('ok', true, 'removed', found);
  end if;
  if p_price <= 0 then raise exception 'The price should be more than $0.'; end if;
  if exists (select 1 from purchase_items where id = p_item and compare_as is not null) then
    raise exception 'This item is compared as another, so it takes that item''s price.';
  end if;
  insert into purchase_baselines (item_id, year, price, note, changed_by_name) values (p_item, p_year, p_price, nullif(btrim(coalesce(p_note, '')), ''), my_name())
  on conflict (item_id, year) do update set price = excluded.price, note = excluded.note, changed_at = now(), changed_by_name = excluded.changed_by_name;
  return jsonb_build_object('ok', true);
exception when check_violation then raise exception 'Keep the note under 200 letters.';
end $$;
revoke all on function purchase_baseline_save(uuid, int, numeric, text) from public, anon;
grant execute on function purchase_baseline_save(uuid, int, numeric, text) to authenticated;

create or replace function purchase_next_number_save(p_series text, p_next int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_max int;
begin
  if not office_ok() then raise exception 'Only a manager sets the next PO number.' using errcode = 'insufficient_privilege'; end if;
  if p_series not in ('lumber', 'po') then raise exception 'Say which numbers: lumber POs or POs.'; end if;
  select max(po_number) into v_max from purchase_pos where series = p_series;
  if p_next is null or p_next < 1 or p_next > (case p_series when 'po' then 99999 else 999999 end) then raise exception 'The next PO number should be a whole number.'; end if;
  if p_next <= coalesce(v_max, 0) then
    raise exception '% is already used. The next number has to be higher.', (case p_series when 'lumber' then 'Lumber PO ' || v_max else 'PO ' || lpad(v_max::text, 5, '0') end);
  end if;
  if p_series = 'lumber' then
    update purchase_po_settings set next_lumber = p_next, updated_at = now(), updated_by_name = my_name() where id;
  else
    update purchase_po_settings set next_po = p_next, updated_at = now(), updated_by_name = my_name() where id;
  end if;
  return jsonb_build_object('ok', true, 'series', p_series, 'next', p_next);
end $$;
revoke all on function purchase_next_number_save(text, int) from public, anon;
grant execute on function purchase_next_number_save(text, int) to authenticated;

create or replace function lumber_year_total_save(p_year int, p_vendor uuid, p_bf numeric, p_dollars numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager changes earlier years.' using errcode = 'insufficient_privilege'; end if;
  if p_year is null or p_year >= extract(year from local_today()) then raise exception 'Earlier years only: this year adds itself up from the POs.'; end if;
  if not exists (select 1 from purchase_suppliers where id = p_vendor) then raise exception 'That supplier wasn''t found.'; end if;
  if coalesce(p_bf, -1) < 0 or coalesce(p_dollars, -1) < 0 then raise exception 'Type the board feet and the dollars (0 for none).'; end if;
  insert into lumber_year_totals (year, vendor_id, bf, dollars) values (p_year, p_vendor, p_bf, p_dollars)
  on conflict (year, vendor_id) do update set bf = excluded.bf, dollars = excluded.dollars;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function lumber_year_total_save(int, uuid, numeric, numeric) from public, anon;
grant execute on function lumber_year_total_save(int, uuid, numeric, numeric) to authenticated;


-- ---------------------------------------------------------------------
-- 6. Making and changing a PO
-- ---------------------------------------------------------------------
-- p: { id?            (a change to this PO)
--      series ('lumber' or 'po', for a new PO), vendor_id, ordered_on, date_required, terms, method, po_job,
--      lines: [{ id?, qty, unit, description, job_number, unit_price, item_id, supply_request_id }] }   in print order, 1 to 22
-- A line with a supply request orders it: the request is marked ordered (as Operations' tick does), naming the PO.
-- A new PO takes the next number. A change keeps the number; when what it prints changes it becomes r2, r3...
-- with the earlier version kept whole, and its PDF is filed again under the new name. A PO from the workbook
-- has no PDF: a change corrects it, nothing else.
create or replace function purchase_po_save(p_client_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid; po purchase_pos; v purchase_suppliers; st arrow_po_settings;
  v_lines jsonb := coalesce(p -> 'lines', '[]'); l jsonb; i int := 0; v_num int; v_header jsonb; v_printed jsonb := '[]';
  v_addr text[]; v_qty numeric; v_price numeric; v_item uuid; v_unit text; v_line uuid; v_keep uuid[] := '{}'; v_date date;
  v_old jsonb; v_name text; v_series text; v_req uuid; v_reqs uuid[] := '{}'; n_req int;
begin
  if not office_ok() then raise exception 'Only a manager makes a PO.' using errcode = 'insufficient_privilege'; end if;
  if p_client_id is not null and v_id is null then
    select * into po from purchase_pos where client_id = p_client_id;
    if po.id is not null then return jsonb_build_object('ok', true, 'id', po.id, 'name', po.name, 'already', true); end if;
  end if;
  if v_id is not null then
    select * into po from purchase_pos where id = v_id for update;
    if po.id is null then raise exception 'That PO wasn''t found.'; end if;
    if po.cancelled_at is not null then raise exception '% is cancelled. Put it back before changing it.', po.name; end if;
  end if;
  v_series := coalesce(po.series, nullif(p ->> 'series', ''));
  if v_series is null or v_series not in ('lumber', 'po') then raise exception 'Say which kind of PO: a lumber PO or a PO.'; end if;
  select * into v from purchase_suppliers where id = nullif(p ->> 'vendor_id', '')::uuid;
  if v.id is null then raise exception 'Choose the supplier.'; end if;
  v_date := coalesce(nullif(p ->> 'ordered_on', '')::date, local_today());
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) = 0 then raise exception 'Add at least one line.'; end if;
  if jsonb_array_length(v_lines) > 22 then raise exception 'A PO has room for 22 lines. Split it into two POs.'; end if;
  select * into st from arrow_po_settings;
  if po.id is null or not po.from_history then
    if nullif(btrim(coalesce(st.issued_by, '')), '') is null then
      raise exception 'Fill in the PO details first (Setup: who issues it, phone, e-mail, address, the tax-exempt line).';
    end if;
  end if;

  -- check every line before anything is written
  for l in select * from jsonb_array_elements(v_lines) loop
    i := i + 1;
    v_qty := nullif(l ->> 'qty', '')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Line %: type the quantity.', i; end if;
    if nullif(btrim(coalesce(l ->> 'description', '')), '') is null then raise exception 'Line %: type the description.', i; end if;
    v_price := nullif(l ->> 'unit_price', '')::numeric;
    if v_price is not null and v_price < 0 then raise exception 'Line %: the unit price can''t be below $0.', i; end if;
    v_item := nullif(l ->> 'item_id', '')::uuid;
    v_unit := btrim(coalesce(l ->> 'unit', ''));
    if v_item is not null and not exists (select 1 from purchase_items where id = v_item) then raise exception 'Line %: that item wasn''t found.', i; end if;
    if v_item is not null and v_unit <> '' and (select category_key = 'lumber' from purchase_items where id = v_item) then
      raise exception 'Line %: a lumber line is in board feet, so leave its unit blank.', i;
    end if;
    v_req := nullif(l ->> 'supply_request_id', '')::uuid;
    if v_req is not null then
      if not exists (select 1 from supply_requests where id = v_req and sees_lane(is_test)) then raise exception 'Line %: that supply request wasn''t found.', i; end if;
      if v_req = any(v_reqs) then raise exception 'Line %: that supply request is on the PO twice.', i; end if;
      if exists (select 1 from purchase_po_lines x join purchase_pos y on y.id = x.po_id
                  where x.supply_request_id = v_req and x.removed_at is null and y.cancelled_at is null and y.id is distinct from po.id) then
        raise exception 'Line %: that supply request is already on another PO.', i;
      end if;
      if (select state from supply_requests where id = v_req) not in ('requested', 'ordered') then
        raise exception 'Line %: that supply request is closed.', i;
      end if;
      v_reqs := v_reqs || v_req;
    end if;
    if nullif(l ->> 'id', '') is not null and (po.id is null or not exists (select 1 from purchase_po_lines where id = (l ->> 'id')::uuid and po_id = po.id and removed_at is null)) then
      raise exception 'Line % isn''t on this PO.', i;
    end if;
  end loop;

  -- what it prints about the vendor, the issuer and the ship-to (the PO details' address, one line each: company, street, city)
  v_addr := regexp_split_to_array(btrim(coalesce(st.address, '')), E'\\s*\\n\\s*');
  v_header := jsonb_build_object(
    'vendor', jsonb_build_object('name', v.contact, 'company', coalesce(v.company, v.name), 'street', v.street, 'city', v.city, 'phone', v.phone, 'email', v.email),
    'issued_by', st.issued_by, 'phone', st.phone, 'email', st.email, 'tax_line', st.tax_line,
    'ship_to', jsonb_build_object('company', v_addr[1], 'street', v_addr[2], 'city', v_addr[3]),
    'date_issued', v_date, 'date', nullif(p ->> 'date', ''), 'date_required', nullif(p ->> 'date_required', ''),
    'terms', nullif(btrim(coalesce(p ->> 'terms', '')), ''), 'method', nullif(btrim(coalesce(p ->> 'method', '')), ''),
    'po_job', nullif(btrim(coalesce(p ->> 'po_job', '')), ''));
  i := 0;
  for l in select * from jsonb_array_elements(v_lines) loop
    i := i + 1;
    v_qty := (l ->> 'qty')::numeric; v_price := nullif(l ->> 'unit_price', '')::numeric;
    v_printed := v_printed || jsonb_build_object('qty', v_qty, 'unit', btrim(coalesce(l ->> 'unit', '')), 'description', btrim(l ->> 'description'),
                   'job_number', btrim(coalesce(l ->> 'job_number', '')), 'unit_price', v_price,
                   'amount', case when v_price is null then null else round(v_qty * v_price, 2) end);
  end loop;

  if po.id is null then
    select case v_series when 'lumber' then next_lumber else next_po end into v_num from purchase_po_settings where id for update;
    while exists (select 1 from purchase_pos where series = v_series and po_number = v_num) loop v_num := v_num + 1; end loop;
    v_name := case v_series when 'lumber' then 'Lumber PO ' || v_num else 'PO ' || lpad(v_num::text, 5, '0') end;
    insert into purchase_pos (client_id, series, po_number, name, file_name, vendor_id, ordered_on, header, printed, made_by, made_by_name)
    values (p_client_id, v_series, v_num, v_name, v_name || '.pdf', v.id, v_date, v_header, v_printed, auth.uid(), my_name())
    returning * into po;
    if v_series = 'lumber' then update purchase_po_settings set next_lumber = v_num + 1 where id;
    else update purchase_po_settings set next_po = v_num + 1 where id; end if;
  else
    v_old := jsonb_build_object('revision', po.revision, 'file_name', po.file_name, 'vendor_id', po.vendor_id, 'ordered_on', po.ordered_on,
               'header', po.header, 'printed', po.printed,
               'lines', coalesce((select jsonb_agg(to_jsonb(x) order by x.position) from purchase_po_lines x where x.po_id = po.id and x.removed_at is null), '[]'),
               'at', coalesce(po.changed_at, po.made_at), 'by', coalesce(po.changed_by_name, po.made_by_name));
    if po.from_history then v_header := po.header; v_printed := po.printed; end if;
    if po.vendor_id = v.id and po.ordered_on = v_date and po.header = v_header and po.printed = v_printed
       and (select jsonb_agg(jsonb_build_object('id', x.id, 'item', x.item_id, 'unit', x.unit, 'req', x.supply_request_id) order by x.position) from purchase_po_lines x where x.po_id = po.id and x.removed_at is null)
         = (select jsonb_agg(jsonb_build_object('id', nullif(e ->> 'id', '')::uuid, 'item', nullif(e ->> 'item_id', '')::uuid, 'unit', btrim(coalesce(e ->> 'unit', '')),
                                                'req', nullif(e ->> 'supply_request_id', '')::uuid) order by o)
              from jsonb_array_elements(v_lines) with ordinality t(e, o))
       and (not po.from_history or (select jsonb_agg(jsonb_build_object('q', x.qty, 'p', x.unit_price, 'd', x.description) order by x.position) from purchase_po_lines x where x.po_id = po.id and x.removed_at is null)
         = (select jsonb_agg(jsonb_build_object('q', (e ->> 'qty')::numeric, 'p', nullif(e ->> 'unit_price', '')::numeric, 'd', btrim(e ->> 'description')) order by o)
              from jsonb_array_elements(v_lines) with ordinality t(e, o))) then
      return jsonb_build_object('ok', true, 'id', po.id, 'name', po.name, 'unchanged', true);
    end if;
    update purchase_pos set vendor_id = v.id, ordered_on = v_date, header = v_header, printed = v_printed,
           revision = revision + 1, earlier = earlier || v_old,
           file_name = case when from_history then null else name || ' r' || (revision + 1) || '.pdf' end,
           filed_at = null, filed_bytes = null, filed_by_name = null, changed_at = now(), changed_by_name = my_name()
     where id = po.id returning * into po;
  end if;

  -- the lines: kept by id where the page sent one, new ones added, the rest taken off (kept, marked removed)
  for l in select * from jsonb_array_elements(v_lines) loop
    v_line := nullif(l ->> 'id', '')::uuid;
    if v_line is not null then v_keep := v_keep || v_line; end if;
  end loop;
  if exists (select 1 from purchase_po_lines x join purchase_receipts r on r.line_id = x.id
              where x.po_id = po.id and x.removed_at is null and not x.id = any(v_keep)) then
    raise exception 'A line with delivery slips can''t come off the PO. Change its quantity instead, or move its slips first.';
  end if;
  with gone as (
    update purchase_po_lines set removed_at = now() where po_id = po.id and removed_at is null and not id = any(v_keep)
    returning supply_request_id),
  back as (
    update supply_requests r set state = 'requested', ordered_by_name = null, ordered_at = null, updated_at = now()
      from gone where r.id = gone.supply_request_id and r.state = 'ordered' and not r.id = any(v_reqs)
    returning r.id)
  insert into supply_request_events (request_id, what, by_name) select id, 'Taken off ' || po.name || ': to be ordered again', my_name() from back;
  update purchase_po_lines set position = position + 100 where po_id = po.id and removed_at is null;   -- free the positions
  i := 0;
  for l in select * from jsonb_array_elements(v_lines) loop
    i := i + 1;
    v_line := nullif(l ->> 'id', '')::uuid;
    if v_line is null then
      insert into purchase_po_lines (po_id, position, qty, unit, description, job_number, unit_price, item_id, supply_request_id)
      values (po.id, i, (l ->> 'qty')::numeric, btrim(coalesce(l ->> 'unit', '')), btrim(l ->> 'description'), btrim(coalesce(l ->> 'job_number', '')),
              nullif(l ->> 'unit_price', '')::numeric, nullif(l ->> 'item_id', '')::uuid, nullif(l ->> 'supply_request_id', '')::uuid);
    else
      update purchase_po_lines set position = i, qty = (l ->> 'qty')::numeric, unit = btrim(coalesce(l ->> 'unit', '')), description = btrim(l ->> 'description'),
             job_number = btrim(coalesce(l ->> 'job_number', '')), unit_price = nullif(l ->> 'unit_price', '')::numeric, item_id = nullif(l ->> 'item_id', '')::uuid,
             supply_request_id = nullif(l ->> 'supply_request_id', '')::uuid
       where id = v_line and po_id = po.id;
    end if;
  end loop;
  -- the supply requests on it are ordered now (Operations sees the same)
  with done as (
    update supply_requests set state = 'ordered', ordered_by_name = my_name(), ordered_at = now(), updated_at = now()
     where id = any(v_reqs) and state = 'requested'
    returning id)
  insert into supply_request_events (request_id, what, by_name) select id, 'Ordered on ' || po.name, my_name() from done;
  get diagnostics n_req = row_count;
  return jsonb_build_object('ok', true, 'id', po.id, 'name', po.name, 'revision', po.revision, 'file_name', po.file_name, 'requests_ordered', n_req);
exception
  when check_violation then raise exception 'A line''s description, unit or job number is too long, or a number is out of range.';
  when invalid_text_representation then raise exception 'A number or date on the PO isn''t readable. Check the lines.';
end $$;
revoke all on function purchase_po_save(uuid, jsonb) from public, anon;
grant execute on function purchase_po_save(uuid, jsonb) to authenticated;

-- cancel a PO (it stays on record and stops counting), or put it back
create or replace function purchase_po_cancel(p_id uuid, p_cancel boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare po purchase_pos;
begin
  if not office_ok() then raise exception 'Only a manager cancels a PO.' using errcode = 'insufficient_privilege'; end if;
  select * into po from purchase_pos where id = p_id;
  if po.id is null then raise exception 'That PO wasn''t found.'; end if;
  if p_cancel then
    if po.cancelled_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
    if exists (select 1 from purchase_po_lines x join purchase_receipts r on r.line_id = x.id where x.po_id = p_id) then
      raise exception '% has delivery slips on it, so it can''t be cancelled.', po.name;
    end if;
    update purchase_pos set cancelled_at = now(), cancelled_by_name = my_name(), cancel_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = p_id;
    with back as (
      update supply_requests r set state = 'requested', ordered_by_name = null, ordered_at = null, updated_at = now()
        from purchase_po_lines x where x.po_id = p_id and x.removed_at is null and r.id = x.supply_request_id and r.state = 'ordered'
      returning r.id)
    insert into supply_request_events (request_id, what, by_name) select id, po.name || ' cancelled: to be ordered again', my_name() from back;
  else
    if exists (select 1 from purchase_po_lines x join purchase_po_lines y on y.supply_request_id = x.supply_request_id and y.id <> x.id
                 join purchase_pos q on q.id = y.po_id
                where x.po_id = p_id and x.removed_at is null and y.removed_at is null and q.cancelled_at is null) then
      raise exception 'A supply request on % is on another PO now, so it can''t be put back.', po.name;
    end if;
    update purchase_pos set cancelled_at = null, cancelled_by_name = null, cancel_reason = null where id = p_id;
    with again as (
      update supply_requests r set state = 'ordered', ordered_by_name = my_name(), ordered_at = now(), updated_at = now()
        from purchase_po_lines x where x.po_id = p_id and x.removed_at is null and r.id = x.supply_request_id and r.state = 'requested'
      returning r.id)
    insert into supply_request_events (request_id, what, by_name) select id, 'Ordered on ' || po.name || ' (put back)', my_name() from again;
  end if;
  return jsonb_build_object('ok', true);
exception when check_violation then raise exception 'Keep the reason under 200 letters.';
end $$;
revoke all on function purchase_po_cancel(uuid, boolean, text) from public, anon;
grant execute on function purchase_po_cancel(uuid, boolean, text) to authenticated;

-- the PDF of this revision is in PD - POs (the Purchasing page files it on Luke's computer)
create or replace function purchase_po_filed(p_id uuid, p_revision int, p_bytes bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() or auth.uid() is null then raise exception 'Only a manager''s Purchasing page reports a filed PO.' using errcode = 'insufficient_privilege'; end if;
  if coalesce(p_bytes, 0) <= 0 then raise exception 'Send the size of the filed PDF.'; end if;
  update purchase_pos set filed_at = now(), filed_bytes = p_bytes, filed_by_name = my_name()
   where id = p_id and revision = p_revision and file_name is not null;
  return jsonb_build_object('ok', true, 'recorded', found);
end $$;
revoke all on function purchase_po_filed(uuid, int, bigint) from public, anon;
grant execute on function purchase_po_filed(uuid, int, bigint) to authenticated;

-- what a line measured after SLR (blank clears it)
create or replace function purchase_measured_save(p_line uuid, p_bf numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager records what was measured.' using errcode = 'insufficient_privilege'; end if;
  if p_bf is not null and p_bf <= 0 then raise exception 'Type the board feet measured, or leave it blank.'; end if;
  update purchase_po_lines set measured_bf = p_bf, measured_by_name = case when p_bf is null then null else my_name() end
   where id = p_line and removed_at is null and item_id in (select id from purchase_items where category_key = 'lumber');
  if not found then raise exception 'That line wasn''t found, or it isn''t lumber.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function purchase_measured_save(uuid, numeric) from public, anon;
grant execute on function purchase_measured_save(uuid, numeric) to authenticated;


-- ---------------------------------------------------------------------
-- 7. Lumber delivery slips and PO lines (picked on the Purchasing page from Inventory's slips)
-- ---------------------------------------------------------------------

-- the open lines a slip can fill, and which slips already fill a line
create or replace function purchase_slip_lines() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager sees the lumber POs.' using errcode = 'insufficient_privilege'; end if;
  return jsonb_build_object(
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'po', p.name, 'po_number', p.po_number, 'position', l.position,
                                         'vendor', v.name, 'item', i.name, 'inv_item_id', i.inv_item_id, 'qty', l.qty,
                                         'in_bf', coalesce(l.slips_bf, 0), 'ordered_on', p.ordered_on,
                                         'open', coalesce(l.slips_bf, 0) < l.qty and l.history_in_bf is null)
                                       order by p.po_number desc, l.position)
                         from purchase_line_rows() l join purchase_pos p on p.id = l.po_id join purchase_suppliers v on v.id = p.vendor_id
                         join purchase_items i on i.id = l.item_id
                        where p.cancelled_at is null and l.lumber), '[]'),
    'links', coalesce((select jsonb_agg(jsonb_build_object('receipt_id', x.receipt_id, 'line_id', x.line_id)) from purchase_receipts x), '[]'));
end $$;
revoke all on function purchase_slip_lines() from public, anon;
grant execute on function purchase_slip_lines() to authenticated;

-- a slip fills this line (p_line null: it fills none). A slip in a closed month stays as it is.
create or replace function purchase_slip_link(p_receipt uuid, p_line uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r inv_receipts; v_line purchase_po_lines; v_po purchase_pos;
begin
  if not office_ok() then raise exception 'Only a manager links a slip to a PO.' using errcode = 'insufficient_privilege'; end if;
  select * into r from inv_receipts where id = p_receipt;
  if r.id is null then raise exception 'That delivery slip wasn''t found.'; end if;
  if r.kind <> 'lumber' then raise exception 'Only a lumber slip fills a lumber PO line.'; end if;
  if exists (select 1 from inv_months where month_end = r.month_end and status = 'closed') then
    raise exception '% is closed; its slips can''t change.', to_char(r.month_end, 'FMMonth YYYY');
  end if;
  if p_line is null then
    delete from purchase_receipts where receipt_id = p_receipt;
    return jsonb_build_object('ok', true, 'summary', 'The slip no longer fills a PO line.');
  end if;
  select * into v_line from purchase_po_lines where id = p_line and removed_at is null;
  if v_line.id is null or not exists (select 1 from purchase_items where id = v_line.item_id and category_key = 'lumber') then
    raise exception 'That PO line wasn''t found, or it isn''t lumber.';
  end if;
  select * into v_po from purchase_pos where id = v_line.po_id;
  if v_po.cancelled_at is not null then raise exception '% is cancelled.', v_po.name; end if;
  insert into purchase_receipts (receipt_id, line_id, linked_by_name) values (p_receipt, p_line, my_name())
  on conflict (receipt_id) do update set line_id = excluded.line_id, linked_at = now(), linked_by_name = excluded.linked_by_name;
  return jsonb_build_object('ok', true, 'summary', format('The slip fills %s, line %s.', v_po.name, v_line.position));
end $$;
revoke all on function purchase_slip_link(uuid, uuid) from public, anon;
grant execute on function purchase_slip_link(uuid, uuid) to authenticated;




-- ---------------------------------------------------------------------
-- 8. The Purchases file: drop it, and match what it doesn't know
-- ---------------------------------------------------------------------
-- p_file:  {name, sha256}
-- p_lines: the file's lines in order, each {row, date (YYYY-MM-DD), supplier, doc, line?, how, description, category,
--          item, qty, unit, amount, in_baseline (true/false), note, po (the PO it's for, "Lumber PO 17"; blank: none)}. The page reads the file (the Lines tab's shape) and
--          sends them; nothing is written unless every line reads.
-- A line already in (same supplier, document number and line) is skipped. Its supplier is found by name or other
-- name; its item by the item column (an item's name) or by what that line was matched to before; the rest wait.
create or replace function purchases_drop(p_client_id uuid, p_file jsonb, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f purchase_files; l jsonb; i int := 0; v_row text; v_date date; v_sup text; v_doc text; v_desc text; v_amt numeric; v_qty numeric;
  v_line text; v_cat text; v_item uuid; v_sid uuid; v_by text; v_base boolean; seen jsonb := '{}'; v_k text; n_new int := 0; n_skip int := 0;
  n_matched int := 0; n_wait int := 0; v_ord jsonb := '{}'; v_id uuid;
begin
  if not office_ok() then raise exception 'Only a manager drops a Purchases file.' using errcode = 'insufficient_privilege'; end if;
  if p_client_id is null then raise exception 'This drop has no id. Drop the file again.'; end if;
  select * into f from purchase_files where client_id = p_client_id;
  if f.id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'new', f.lines_new, 'skipped', f.lines_skipped,
      'summary', format('Already dropped: %s new line%s, %s already in.', f.lines_new, case when f.lines_new = 1 then '' else 's' end, f.lines_skipped));
  end if;
  if nullif(btrim(coalesce(p_file ->> 'name', '')), '') is null then raise exception 'The file has no name.'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'The file has no lines to add.'; end if;
  if jsonb_array_length(p_lines) > 5000 then raise exception 'The file has % lines; 5,000 is the most at once. Split it.', jsonb_array_length(p_lines); end if;

  -- read every line before writing any
  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_row := coalesce(nullif(l ->> 'row', ''), i::text);
    begin v_date := (l ->> 'date')::date; exception when others then v_date := null; end;
    if v_date is null then raise exception 'Row %: the date isn''t readable.', v_row; end if;
    if v_date > local_today() then raise exception 'Row %: the date % is in the future.', v_row, v_date; end if;
    if nullif(btrim(coalesce(l ->> 'supplier', '')), '') is null then raise exception 'Row %: the supplier is blank.', v_row; end if;
    if nullif(btrim(coalesce(l ->> 'description', '')), '') is null then raise exception 'Row %: the description is blank.', v_row; end if;
    begin v_amt := (l ->> 'amount')::numeric; exception when others then v_amt := null; end;
    if v_amt is null then raise exception 'Row %: the amount isn''t a number.', v_row; end if;
    if nullif(l ->> 'qty', '') is not null then
      begin v_qty := (l ->> 'qty')::numeric; exception when others then raise exception 'Row %: the quantity isn''t a number.', v_row; end;
      if v_qty = 0 then raise exception 'Row %: the quantity is 0. Leave it blank if it isn''t known.', v_row; end if;
    end if;
    if length(l ->> 'description') > 400 or length(coalesce(l ->> 'note', '')) > 400 or length(l ->> 'supplier') > 120
       or length(coalesce(l ->> 'doc', '')) > 80 or length(coalesce(l ->> 'unit', '')) > 20 or length(coalesce(l ->> 'how', '')) > 40
       or length(coalesce(l ->> 'line', '')) > 40 or length(coalesce(l ->> 'po', '')) > 40 or length(coalesce(l ->> 'item', '')) > 80 then
      raise exception 'Row %: something on it is too long.', v_row;
    end if;
  end loop;

  insert into purchase_files (client_id, file_name, sha256, lines_in, dropped_by_name)
  values (p_client_id, left(btrim(p_file ->> 'name'), 200), nullif(lower(p_file ->> 'sha256'), ''), jsonb_array_length(p_lines), my_name())
  returning * into f;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_sup := btrim(l ->> 'supplier'); v_doc := btrim(coalesce(l ->> 'doc', '')); v_desc := btrim(l ->> 'description');
    -- its line on the document: the file's, or its place among that document's lines in this file. A line with no
    -- bill or receipt number (a card buy at a store) is told apart by its date and words instead, so another day's
    -- or another thing's line from the same store is never taken for it.
    v_k := lower(v_sup) || '|' || case when v_doc = '' then (l ->> 'date') || '|' || left(md5(purchase_key(v_desc)), 8) else lower(v_doc) end;
    v_ord := jsonb_set(v_ord, array[v_k], to_jsonb(coalesce((v_ord ->> v_k)::int, 0) + 1));
    v_line := coalesce(nullif(btrim(coalesce(l ->> 'line', '')), ''),
                       case when v_doc = '' then (l ->> 'date') || '|' || left(md5(purchase_key(v_desc)), 8) || '#' || (v_ord ->> v_k) else (v_ord ->> v_k) end);
    if seen ? (v_k || '|' || lower(v_line))
       or exists (select 1 from purchase_buys where lower(btrim(supplier_name)) = lower(v_sup) and lower(btrim(doc_number)) = lower(v_doc) and lower(line_key) = lower(v_line)) then
      n_skip := n_skip + 1; continue;
    end if;
    seen := seen || jsonb_build_object(v_k || '|' || lower(v_line), true);
    select id into v_sid from purchase_suppliers s
     where lower(v_sup) = lower(s.name) or lower(v_sup) in (select lower(btrim(a)) from unnest(s.aliases) a) limit 1;
    v_item := null; v_by := null;
    if nullif(btrim(coalesce(l ->> 'item', '')), '') is not null then
      select id into v_item from purchase_items i
       where lower(btrim(l ->> 'item')) in (select lower(n) from unnest(i.name || i.aliases) n) and not i.retired limit 1;
      if v_item is not null then v_by := 'The file'; end if;
    end if;
    if v_item is null then
      select item_id into v_item from purchase_match_rules
       where supplier_key in (lower(v_sup), coalesce(v_sid::text, '-')) and description_key = purchase_key(v_desc) limit 1;
      if v_item is not null then v_by := 'Matched before'; end if;
    end if;
    if v_item is not null then
      select category_key into v_cat from purchase_items where id = v_item;
      n_matched := n_matched + 1;
    else
      select key into v_cat from purchase_categories where lower(key) = lower(btrim(coalesce(l ->> 'category', ''))) or lower(name) = lower(btrim(coalesce(l ->> 'category', ''))) limit 1;
      if btrim(coalesce(l ->> 'po', '')) = '' then n_wait := n_wait + 1; end if;   -- a line for a PO isn't counted, so it needs no match
    end if;
    v_base := case lower(btrim(coalesce(l ->> 'in_baseline', ''))) when 'no' then false when 'false' then false when 'n' then false else true end;
    insert into purchase_buys (file_id, supplier_id, supplier_name, doc_number, line_key, bought_on, how, description, category_key, item_id, item_text,
                               qty, unit, amount, in_baseline, note, po_ref, matched_by_name, matched_at)
    values (f.id, v_sid, v_sup, v_doc, v_line, (l ->> 'date')::date, btrim(coalesce(l ->> 'how', '')), v_desc, v_cat, v_item, left(btrim(coalesce(l ->> 'item', '')), 80),
            nullif(l ->> 'qty', '')::numeric, btrim(coalesce(l ->> 'unit', '')), (l ->> 'amount')::numeric, v_base, btrim(coalesce(l ->> 'note', '')),
            btrim(coalesce(l ->> 'po', '')), v_by, case when v_by is not null then now() end);
    n_new := n_new + 1;
  end loop;
  update purchase_files set lines_new = n_new, lines_skipped = n_skip where id = f.id;
  return jsonb_build_object('ok', true, 'id', f.id, 'new', n_new, 'skipped', n_skip, 'matched', n_matched, 'to_match', n_wait,
    'summary', format('%s new line%s (%s filed under an item, %s to match), %s already in.',
                      n_new, case when n_new = 1 then '' else 's' end, n_matched, n_wait, n_skip));
exception
  when unique_violation then
    if exists (select 1 from purchase_files where client_id = p_client_id) then
      return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already dropped.');
    end if;
    raise exception 'Two lines in the file are the same bill line. Check the file and drop it again.';
  when check_violation then raise exception 'A line has something too long, or a quantity of 0.';
end $$;
revoke all on function purchases_drop(uuid, jsonb, jsonb) from public, anon;
grant execute on function purchases_drop(uuid, jsonb, jsonb) to authenticated;

-- Match these: file lines under an item. p_remember: the next file's line with the same supplier and
-- description files itself, and every waiting line like it is filed now too.
create or replace function purchase_buys_match(p_ids uuid[], p_item uuid, p_remember boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cat text; n int; n_more int := 0; n2 int;
begin
  if not office_ok() then raise exception 'Only a manager matches purchases.' using errcode = 'insufficient_privilege'; end if;
  select category_key into v_cat from purchase_items where id = p_item;
  if v_cat is null then raise exception 'That item wasn''t found.'; end if;
  if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Pick the lines to match.'; end if;
  update purchase_buys set item_id = p_item, category_key = v_cat, matched_by_name = my_name(), matched_at = now()
   where id = any(p_ids);
  get diagnostics n = row_count;
  if coalesce(p_remember, true) then
    insert into purchase_match_rules (supplier_key, description_key, item_id, made_by_name)
    select distinct coalesce(supplier_id::text, lower(btrim(supplier_name))), purchase_key(description), p_item, my_name() from purchase_buys where id = any(p_ids)
    on conflict (supplier_key, description_key) do update set item_id = excluded.item_id, made_at = now(), made_by_name = excluded.made_by_name;
    update purchase_buys b set item_id = p_item, category_key = v_cat, matched_by_name = 'Matched before', matched_at = now()
      from purchase_match_rules r
     where b.item_id is null and b.ignored_at is null and r.item_id = p_item
       and r.supplier_key in (lower(btrim(b.supplier_name)), coalesce(b.supplier_id::text, '-')) and r.description_key = purchase_key(b.description);
    get diagnostics n_more = row_count;
    -- the file's own name for it becomes one of the item's other names, so lines naming it file themselves
    update purchase_items i set aliases = (select array_agg(distinct a) from unnest(i.aliases || array(
             select distinct b.item_text from purchase_buys b where b.id = any(p_ids) and b.item_text <> '' and lower(b.item_text) <> lower(i.name)
                and not exists (select 1 from purchase_items o, unnest(o.name || o.aliases) nm where o.id <> i.id and lower(nm) = lower(b.item_text)))) a)
     where i.id = p_item and exists (select 1 from purchase_buys b where b.id = any(p_ids) and b.item_text <> '' and lower(b.item_text) <> lower(i.name));
    update purchase_buys b set item_id = p_item, category_key = v_cat, matched_by_name = 'Matched before', matched_at = now()
      from purchase_items i
     where i.id = p_item and b.item_id is null and b.ignored_at is null and b.item_text <> ''
       and lower(b.item_text) in (select lower(nm) from unnest(i.aliases) nm);
    get diagnostics n2 = row_count;
    n_more := n_more + n2;
  end if;
  return jsonb_build_object('ok', true, 'matched', n, 'also', n_more,
    'summary', format('%s line%s matched%s.', n, case when n = 1 then '' else 's' end,
                      case when n_more > 0 then format(', and %s more like %s', n_more, case when n = 1 then 'it' else 'them' end) else '' end));
end $$;
revoke all on function purchase_buys_match(uuid[], uuid, boolean) from public, anon;
grant execute on function purchase_buys_match(uuid[], uuid, boolean) to authenticated;

-- not a production buy, or not one to price: kept, left out of Prices and Match these (p_ignore false: back in)
create or replace function purchase_buy_ignore(p_id uuid, p_ignore boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager changes a purchase line.' using errcode = 'insufficient_privilege'; end if;
  if p_ignore and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Say why it''s left out.'; end if;
  update purchase_buys set ignored_at = case when p_ignore then now() end, ignored_by_name = case when p_ignore then my_name() end,
         ignore_reason = case when p_ignore then left(btrim(p_reason), 200) end
   where id = p_id;
  if not found then raise exception 'That purchase line wasn''t found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function purchase_buy_ignore(uuid, boolean, text) from public, anon;
grant execute on function purchase_buy_ignore(uuid, boolean, text) to authenticated;

-- a file line is for a PO (p_po: "Lumber PO 17", "PO 00001"; blank: it isn't): kept against that PO, not counted again
create or replace function purchase_buy_po(p_id uuid, p_po text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_po text := btrim(coalesce(p_po, ''));
begin
  if not office_ok() then raise exception 'Only a manager changes a purchase line.' using errcode = 'insufficient_privilege'; end if;
  if length(v_po) > 40 then raise exception 'That PO name is too long.'; end if;
  if v_po <> '' and not exists (select 1 from purchase_pos where lower(name) = lower(v_po)) then
    raise exception 'There''s no % yet. Type it as it''s named, like Lumber PO 17 or PO 00001.', v_po;
  end if;
  update purchase_buys set po_ref = (select coalesce((select name from purchase_pos where lower(name) = lower(v_po)), '')) where id = p_id;
  if not found then raise exception 'That purchase line wasn''t found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function purchase_buy_po(uuid, text) from public, anon;
grant execute on function purchase_buy_po(uuid, text) to authenticated;

-- whether a line counts towards its item's average paid (a one-off, a job-specific buy: not)
create or replace function purchase_buy_baseline(p_id uuid, p_in boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager changes a purchase line.' using errcode = 'insufficient_privilege'; end if;
  update purchase_buys set in_baseline = coalesce(p_in, true) where id = p_id;
  if not found then raise exception 'That purchase line wasn''t found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function purchase_buy_baseline(uuid, boolean) from public, anon;
grant execute on function purchase_buy_baseline(uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------
-- 9. The check
-- ---------------------------------------------------------------------
create or replace function check_purchasing()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]'; mgr uuid; sup uuid; as_mgr text; as_sup text; ok boolean; msg text; t record; v jsonb; v2 jsonb; n int;
  ven uuid; i8 uuid; i7 uuid; inv uuid; po1 uuid; l1 uuid; l2 uuid; rc uuid; cid uuid := gen_random_uuid(); st arrow_po_settings; nx int; num int;
  ply uuid; po2 uuid; req uuid; f1 uuid; b1 uuid; ven2 uuid; itm uuid; bc uuid; r jsonb;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test limit 1;
  if mgr is null or sup is null then
    res := res || check_row(1, 'A manager and a supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;

  -- ---- 1. tables locked -----------------------------------------------------
  ok := true; msg := null;
  for t in select x.tb from unnest(array['purchase_categories', 'purchase_suppliers', 'purchase_items', 'purchase_baselines', 'purchase_po_settings',
                                         'purchase_pos', 'purchase_po_lines', 'purchase_receipts', 'lumber_year_totals', 'lumber_scrap_history',
                                         'purchase_files', 'purchase_buys', 'purchase_match_rules']) x(tb) loop
    if to_regclass('public.' || t.tb) is null or not (select relrowsecurity from pg_class where oid = ('public.' || t.tb)::regclass)
       or has_table_privilege('authenticated', 'public.' || t.tb, 'select') or has_table_privilege('authenticated', 'public.' || t.tb, 'insert')
       or has_table_privilege('authenticated', 'public.' || t.tb, 'update') or has_table_privilege('authenticated', 'public.' || t.tb, 'delete')
       or has_table_privilege('anon', 'public.' || t.tb, 'select') then ok := false; msg := concat_ws(' ', msg, t.tb); end if;
  end loop;
  res := res || check_row(1, 'The thirteen purchasing tables have row-level security; no login reads or writes them except through the functions', ok,
    'Open to a login: ' || coalesce(msg, '') || '. Run purchasing.sql again.');

  -- ---- 2. functions need a login; the inside helpers none --------------------
  ok := true; msg := null;
  for t in select x.f from unnest(array['purchasing_data()', 'purchase_category_save(jsonb)', 'purchase_supplier_save(jsonb)', 'purchase_item_save(jsonb)',
         'purchase_baseline_save(uuid,integer,numeric,text)', 'purchase_next_number_save(text,integer)',
         'lumber_year_total_save(integer,uuid,numeric,numeric)', 'purchase_po_save(uuid,jsonb)', 'purchase_po_cancel(uuid,boolean,text)',
         'purchase_po_filed(uuid,integer,bigint)', 'purchase_measured_save(uuid,numeric)', 'purchase_slip_lines()', 'purchase_slip_link(uuid,uuid)',
         'purchases_drop(uuid,jsonb,jsonb)', 'purchase_buys_match(uuid[],uuid,boolean)', 'purchase_buy_ignore(uuid,boolean,text)', 'purchase_buy_po(uuid,text)',
         'purchase_buy_baseline(uuid,boolean)']) x(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then ok := false; msg := concat_ws(' ', msg, t.f); end if;
  end loop;
  ok := ok and not has_function_privilege('authenticated', 'public.purchase_benchmark(uuid,integer)', 'execute')
           and not has_function_privilege('authenticated', 'public.purchase_line_rows()', 'execute')
           and not has_function_privilege('authenticated', 'public.purchase_key(text)', 'execute');
  res := res || check_row(2, 'Its functions need a login; the three inside helpers are closed to logins', ok,
    coalesce('Missing, or open to no login: ' || msg, 'purchase_benchmark, purchase_line_rows or purchase_key is open to logins.'));

  select * into st from arrow_po_settings;
  select next_lumber into nx from purchase_po_settings;
  begin
    update arrow_po_settings set issued_by = 'Check Issuer', phone = '317-000-0000', email = 'check@example.com',
           address = E'Check Company\n1 Check Street\nCheckville, IN 46000', tax_line = 'Check tax line' where id;
    select id into inv from inv_items where list_key = 'lumber' and not retired order by sort_order limit 1;

    -- ---- 3. a supervisor is turned away from all of it ------------------------
    ok := true; msg := null; n := 0;
    perform set_config('request.jwt.claims', as_sup, true);
    execute 'set local role authenticated';
    begin v := purchasing_data(); msg := concat_ws(', ', msg, 'read purchasing_data'); exception when insufficient_privilege then n := n + 1; end;
    begin v := purchase_supplier_save('{"name": "Check"}'); msg := concat_ws(', ', msg, 'added a supplier'); exception when insufficient_privilege then n := n + 1; end;
    begin v := purchase_po_save(gen_random_uuid(), '{}'); msg := concat_ws(', ', msg, 'made a PO'); exception when insufficient_privilege then n := n + 1; end;
    begin v := purchase_slip_lines(); msg := concat_ws(', ', msg, 'read the PO lines'); exception when insufficient_privilege then n := n + 1; end;
    begin v := purchase_next_number_save('lumber', 999990); msg := concat_ws(', ', msg, 'set the number'); exception when insufficient_privilege then n := n + 1; end;
    begin v := purchases_drop(gen_random_uuid(), '{"name": "x"}', '[]'); msg := concat_ws(', ', msg, 'dropped a Purchases file');
    exception when insufficient_privilege then n := n + 1; when others then msg := concat_ws(', ', msg, 'reached the Purchases file drop (' || sqlerrm || ')'); end;
    execute 'reset role';
    res := res || check_row(3, 'A supervisor can''t see prices, make a PO, drop a Purchases file or change the setup', msg is null and n = 6, 'A supervisor ' || coalesce(msg, 'got an unexpected answer') || '.');

    -- ---- 4. setup: a supplier, 8/4 and 7/4 compared at the same square feet ----
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      ven := (purchase_supplier_save('{"name": "Check Lumber Co", "contact": "Pat Check", "street": "2 Mill Road", "city": "Woodville, OH 45000"}') ->> 'id')::uuid;
      i8 := (purchase_item_save(jsonb_build_object('name', 'Check 8/4 Ash', 'category_key', 'lumber', 'quarters', 8, 'inv_item_id', inv)) ->> 'id')::uuid;
      v := purchase_baseline_save(i8, 2025, 4.42, '2025 average');
      i7 := (purchase_item_save(jsonb_build_object('name', 'Check 7/4 Ash', 'category_key', 'lumber', 'quarters', 7, 'compare_as', i8)) ->> 'id')::uuid;
      ok := true;
      begin v := purchase_item_save(jsonb_build_object('id', i8, 'name', 'Check 8/4 Ash', 'category_key', 'lumber', 'quarters', 8, 'compare_as', i7));
        ok := false; msg := 'An item others are compared with was given a compare-as rule.';
      exception when others then null; end;
      begin v := purchase_baseline_save(i7, 2025, 5.00); ok := false; msg := 'A compare-as item was given its own baseline.'; exception when others then null; end;
      if not ok then execute 'reset role'; raise exception '%', msg; end if;
      ply := (purchase_item_save(jsonb_build_object('name', 'Check 3/4 Maple Plywood', 'category_key', 'sheet_goods', 'unit', 'sheet')) ->> 'id')::uuid;
      begin v := purchase_item_save(jsonb_build_object('name', 'Check bad', 'category_key', 'hardware', 'unit', 'each', 'quarters', 8, 'compare_as', i8));
        ok := false; msg := 'A hardware item was compared as lumber.'; exception when others then null; end;
      execute 'reset role';
      if ok then
        ok := purchase_benchmark(i7, 2026) = 5.0514 and purchase_benchmark(i8, 2026) = 4.42 and purchase_benchmark(i8, 2027) is null;
        msg := '7/4 against 8/4 in 2026 should be $4.42 x 8/7 = $5.0514 (and 8/4 itself $4.42, 2027 none yet); got '
               || coalesce(purchase_benchmark(i7, 2026)::text, 'nothing') || ' / ' || coalesce(purchase_benchmark(i8, 2026)::text, 'nothing');
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'Setup: a 7/4 item compared as 8/4 at the same square feet is worth 8/4''s 2025 baseline x 8/7 in 2026; no chains; only lumber is compared or tied to Inventory', ok, msg);

    -- ---- 5. a PO: the next number, what it prints, a resend is one PO ----------
    update purchase_po_settings set next_lumber = 990001, next_po = 99001 where id;
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchase_po_save(cid, jsonb_build_object('series', 'lumber', 'vendor_id', ven, 'ordered_on', '2026-11-04', 'lines', jsonb_build_array(
             jsonb_build_object('qty', 6500, 'description', '7/4 Natural Ash SB SLR S2S 1 11/16', 'job_number', 'Stock', 'unit_price', 3.015, 'item_id', i7),
             jsonb_build_object('qty', 3, 'unit', 'Sheets', 'description', '3/4 A1 PS WO Veneer Core'))));
      v2 := purchase_po_save(cid, jsonb_build_object('vendor_id', ven, 'lines', '[{"qty": 1, "description": "x"}]'::jsonb));
      execute 'reset role';
      po1 := (v ->> 'id')::uuid;
      select id into l1 from purchase_po_lines where po_id = po1 and position = 1;
      select id into l2 from purchase_po_lines where po_id = po1 and position = 2;
      select po_number into num from purchase_pos where id = po1;
      ok := v ->> 'name' = 'Lumber PO 990001' and (v2 ->> 'already')::boolean and (v2 ->> 'id')::uuid = po1
            and (select next_lumber from purchase_po_settings) = 990002 and (select next_po from purchase_po_settings) = 99001
            and (select count(*) from purchase_pos where client_id = cid) = 1
            and (select file_name from purchase_pos where id = po1) = 'Lumber PO 990001.pdf'
            and (select header -> 'vendor' ->> 'name' = 'Pat Check' and header -> 'ship_to' ->> 'street' = '1 Check Street'
                        and header ->> 'issued_by' = 'Check Issuer' and printed -> 0 ->> 'amount' = '19597.50' and printed -> 1 ->> 'unit' = 'Sheets'
                        and printed -> 1 -> 'amount' = 'null'::jsonb from purchase_pos where id = po1);
      msg := 'The PO wasn''t made once with the next number, or it doesn''t print what was given: ' || coalesce(v::text, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'A PO takes the next number once (a resend is the same PO) and prints the supplier, the PO details and the lines as given', ok, msg);

    -- ---- 6. what counts: ordered until a slip comes, then the slips ------------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchasing_data();
      ok := (select (x ->> 'bf')::numeric = 6500 and (x ->> 'benchmark')::numeric = 5.0514 from jsonb_array_elements(v -> 'pos') p, jsonb_array_elements(p -> 'lines') x
              where (x ->> 'id')::uuid = l1)
        and (select x -> 'bf' = 'null'::jsonb from jsonb_array_elements(v -> 'pos') p, jsonb_array_elements(p -> 'lines') x where (x ->> 'id')::uuid = l2);
      msg := 'Before any slip the line should count its 6,500 ordered board feet; plywood none.';
      rc := (add_inventory_receipt('lumber', least(local_today(), inv_current_month()), 'Check Lumber Co', inv, 6200, null, null, null) ->> 'id')::uuid;
      v2 := purchase_slip_link(rc, l1);
      begin v2 := purchase_slip_link(rc, l2); ok := false; msg := 'A slip filled a plywood line.'; exception when others then null; end;
      if not ok then raise exception '%', msg; end if;
      v := purchasing_data();
      ok := ok and (select (x ->> 'bf')::numeric = 6200 and (x ->> 'received_bf')::numeric = 6200 from jsonb_array_elements(v -> 'pos') p, jsonb_array_elements(p -> 'lines') x
                     where (x ->> 'id')::uuid = l1);
      if ok then msg := 'After a 6,200 bd ft slip the line should count 6,200.'; end if;
      v2 := mark_receipt_mistake(rc);
      v := purchasing_data();
      ok := ok and (select (x ->> 'bf')::numeric = 6500 from jsonb_array_elements(v -> 'pos') p, jsonb_array_elements(p -> 'lines') x where (x ->> 'id')::uuid = l1);
      if ok then msg := null; else msg := coalesce(msg, 'A slip entered by mistake still counted.'); end if;
      v2 := purchase_slip_link((add_inventory_receipt('lumber', least(local_today(), inv_current_month()), 'Check Lumber Co', inv, 3000, null, null, null) ->> 'id')::uuid, l1);
      v := purchase_slip_lines();
      ok := ok and (select (x ->> 'in_bf')::numeric = 3000 and (x ->> 'open')::boolean from jsonb_array_elements(v -> 'lines') x where (x ->> 'id')::uuid = l1);
      execute 'reset role';
      if not ok and msg is null then msg := 'The Inventory page''s list of open lines is wrong.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(6, 'A line counts what was ordered until its slips come, then what they bring; a slip entered by mistake stops counting', ok, msg);

    -- ---- 7. a change: r2, the earlier version kept, filed again ---------------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v2 := purchase_po_filed(po1, 1, 1000);
      v := purchase_po_save(null, jsonb_build_object('id', po1, 'vendor_id', ven, 'ordered_on', '2026-11-04', 'lines', jsonb_build_array(
             jsonb_build_object('id', l1, 'qty', 6500, 'description', '7/4 Natural Ash SB SLR S2S 1 11/16', 'job_number', 'Stock', 'unit_price', 3.015, 'item_id', i7),
             jsonb_build_object('id', l2, 'qty', 3, 'unit', 'Sheets', 'description', '3/4 A1 PS WO Veneer Core'))));
      ok := (v ->> 'unchanged')::boolean;
      msg := 'Saving a PO with nothing changed made a new version.';
      v := purchase_po_save(null, jsonb_build_object('id', po1, 'vendor_id', ven, 'ordered_on', '2026-11-04', 'lines', jsonb_build_array(
             jsonb_build_object('id', l1, 'qty', 6500, 'description', '7/4 Natural Ash SB SLR S2S 1 11/16', 'job_number', 'Stock', 'unit_price', 2.995, 'item_id', i7))));
      execute 'reset role';
      ok := ok and v ->> 'file_name' = 'Lumber PO 990001 r2.pdf'
            and (select revision = 2 and filed_at is null and jsonb_array_length(earlier) = 1 and earlier -> 0 ->> 'file_name' = 'Lumber PO 990001.pdf'
                        and jsonb_array_length(earlier -> 0 -> 'lines') = 2 and jsonb_array_length(printed) = 1 from purchase_pos where id = po1)
            and (select removed_at is not null from purchase_po_lines where id = l2)
            and (select position = 1 and unit_price = 2.995 from purchase_po_lines where id = l1);
      if ok then msg := null; elsif msg is null or (v ->> 'unchanged') is null then msg := 'The change didn''t make r2 with the first version kept: ' || v::text; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'Changing a PO makes r2 (to be filed again) and keeps the first version whole; a line taken off stays on record; no change, no new version', ok, msg);

    -- ---- 8. refusals: a line with slips stays, a used number, a cancelled PO --
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    ok := true; msg := null;
    begin v := purchase_po_save(null, jsonb_build_object('id', po1, 'vendor_id', ven, 'lines', '[{"qty": 1, "description": "x"}]'::jsonb));
      msg := 'A line with slips came off the PO.'; exception when others then null; end;
    begin v := purchase_next_number_save('lumber', num); msg := concat_ws(' ', msg, 'The next number was set to one already used.'); exception when others then null; end;
    begin v := purchase_po_save(gen_random_uuid(), jsonb_build_object('vendor_id', ven, 'lines', '[{"qty": 1, "description": "x"}]'::jsonb));
      msg := concat_ws(' ', msg, 'A PO was made without saying which kind.'); exception when others then null; end;
    begin v := purchase_po_cancel(po1, true, 'check'); msg := concat_ws(' ', msg, 'A PO with slips was cancelled.'); exception when others then null; end;
    begin v := purchase_po_save(gen_random_uuid(), jsonb_build_object('series', 'lumber', 'vendor_id', ven, 'lines', '[]'::jsonb)); msg := concat_ws(' ', msg, 'A PO with no lines was made.'); exception when others then null; end;
    begin v := purchase_po_save(gen_random_uuid(), jsonb_build_object('series', 'lumber', 'vendor_id', ven, 'lines', jsonb_build_array(jsonb_build_object('qty', 5, 'unit', 'Sheets', 'description', 'x', 'item_id', i8))));
      msg := concat_ws(' ', msg, 'A tracked line was given a unit other than board feet.'); exception when others then null; end;
    execute 'reset role';
    res := res || check_row(8, 'Refused: taking off a line with slips, a used number, a PO of no kind, cancelling a PO with slips, a PO with no lines, a lumber line not in board feet', msg is null, msg);

    -- ---- 9. no PO until the PO details are filled in --------------------------
    update arrow_po_settings set issued_by = null where id;
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchase_po_save(gen_random_uuid(), jsonb_build_object('series', 'po', 'vendor_id', ven, 'lines', '[{"qty": 1, "description": "x"}]'::jsonb));
      execute 'reset role'; ok := false; msg := 'A PO was made with no one to issue it.';
    exception when others then execute 'reset role'; ok := sqlerrm like 'Fill in the PO details%'; msg := 'Unexpected: ' || sqlerrm; end;
    res := res || check_row(9, 'No PO until the PO details are filled in', ok, msg);
    update arrow_po_settings set issued_by = 'Check Issuer' where id;

    -- ---- 11. a PO in the other series, with a supply request on it -------------
    perform set_config('request.jwt.claims', as_mgr, true);
    insert into supply_requests (department, item, qty, requested_by_name) values ('assembly_qc', 'Check wood glue', 2, 'Check') returning id into req;
    execute 'set local role authenticated';
    begin
      v := purchase_po_save(gen_random_uuid(), jsonb_build_object('series', 'po', 'vendor_id', ven, 'ordered_on', '2026-11-05', 'lines', jsonb_build_array(
             jsonb_build_object('qty', 2, 'unit', 'Gallon', 'description', 'Titebond III', 'unit_price', 38.5, 'supply_request_id', req),
             jsonb_build_object('qty', 4, 'unit', 'Sheets', 'description', '3/4 Maple Plywood', 'unit_price', 61.25, 'item_id', ply))));
      po2 := (v ->> 'id')::uuid;
      execute 'reset role';
      ok := v ->> 'name' = 'PO 99001' and (v ->> 'file_name') = 'PO 99001.pdf' and (v ->> 'requests_ordered')::int = 1
            and (select state from supply_requests where id = req) = 'ordered'
            and exists (select 1 from supply_request_events where request_id = req and what = 'Ordered on PO 99001')
            and (select next_po from purchase_po_settings) = 99002 and (select next_lumber from purchase_po_settings) = 990002;
      msg := 'The PO wasn''t PO 99001 in its own series, or its supply request wasn''t marked ordered: ' || coalesce(v::text, '');
      execute 'set local role authenticated';
      begin v2 := purchase_po_save(gen_random_uuid(), jsonb_build_object('series', 'po', 'vendor_id', ven, 'lines', jsonb_build_array(
                    jsonb_build_object('qty', 2, 'description', 'again', 'supply_request_id', req))));
        ok := false; msg := 'A supply request went onto a second PO.'; exception when others then null; end;
      v2 := purchase_po_cancel(po2, true, 'check');
      execute 'reset role';
      ok := ok and (select state from supply_requests where id = req) = 'requested';
      if not ok and msg is null then msg := 'Cancelling the PO didn''t put its supply request back to be ordered.'; end if;
      execute 'set local role authenticated';
      v2 := purchase_po_cancel(po2, false);
      execute 'reset role';
      ok := ok and (select state from supply_requests where id = req) = 'ordered';
      if ok then msg := null; elsif msg is null then msg := 'Putting the PO back didn''t order its supply request again.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(11, 'A PO in the PO 00001 series numbers apart from lumber; its supply request is marked ordered; cancelled, it''s to be ordered again; one request, one PO', ok, msg);

    -- ---- 12. the Purchases file: known items filed, the rest to match, nothing twice ------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      ven2 := (purchase_supplier_save('{"name": "Check Supply Co", "aliases": ["CHECK SUPPLY CO INC"]}') ->> 'id')::uuid;
      v := purchases_drop('00000000-0000-4000-8000-00000000c571', '{"name": "check-purchases.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-01-06', 'supplier', 'Check supply co inc', 'doc', 'B-1', 'description', '3/4 MAPLE PLY', 'item', 'Check 3/4 Maple Plywood', 'qty', 10, 'unit', 'sheet', 'amount', 612.50, 'in_baseline', 'Yes'),
             jsonb_build_object('row', 3, 'date', '2026-01-06', 'supplier', 'Check supply co inc', 'doc', 'B-1', 'description', 'Edge banding, maple 7/8in', 'qty', 2, 'unit', 'roll', 'amount', 88, 'category', 'Hardware'),
             jsonb_build_object('row', 4, 'date', '2026-01-07', 'supplier', 'Somewhere Else', 'doc', '', 'description', 'Shop rags', 'amount', 19.99),
             jsonb_build_object('row', 5, 'date', '2026-11-04', 'supplier', 'Check Lumber Co', 'doc', 'L-5', 'description', '7/4 ASH 6,200 BF', 'amount', 18693, 'po', 'lumber po 990001')));
      v2 := purchases_drop('00000000-0000-4000-8000-00000000c571', '{"name": "check-purchases.xlsx"}', '[]');
      execute 'reset role';
      select id into b1 from purchase_buys where doc_number = 'B-1' and line_key = '2';
      ok := (v ->> 'new')::int = 4 and (v ->> 'matched')::int = 1 and (v ->> 'to_match')::int = 2 and (v2 ->> 'already')::boolean
            and (select po_ref = 'lumber po 990001' from purchase_buys where doc_number = 'L-5')
            and (select item_id = ply and supplier_id = ven2 and category_key = 'sheet_goods' from purchase_buys where doc_number = 'B-1' and line_key = '1')
            and (select item_id is null and category_key = 'hardware' from purchase_buys where id = b1)
            and (select supplier_id is null from purchase_buys where supplier_name = 'Somewhere Else');
      msg := 'The first drop didn''t file the known item, leave two to match and find the supplier by its other name: ' || coalesce(v::text, '');
      execute 'set local role authenticated';
      v := purchases_drop(gen_random_uuid(), '{"name": "check-purchases again.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-01-06', 'supplier', 'Check Supply Co Inc', 'doc', 'b-1', 'description', '3/4 MAPLE PLY', 'amount', 612.50),
             jsonb_build_object('row', 3, 'date', '2026-01-06', 'supplier', 'Check supply co inc', 'doc', 'B-1', 'description', 'Edge banding, maple 7/8in', 'amount', 88)));
      begin v2 := purchases_drop(gen_random_uuid(), '{"name": "bad.xlsx"}', jsonb_build_array(
                    jsonb_build_object('row', 2, 'date', '2026-01-08', 'supplier', 'X', 'description', 'fine', 'amount', 1),
                    jsonb_build_object('row', 3, 'date', '6th of Jan', 'supplier', 'X', 'description', 'bad date', 'amount', 1)));
        ok := false; msg := 'A file with an unreadable date was taken.'; exception when others then
        if sqlerrm not like 'Row 3:%' then ok := false; msg := 'The refusal didn''t name row 3: ' || sqlerrm; end if; end;
      execute 'reset role';
      v2 := purchases_drop(gen_random_uuid(), '{"name": "check-cash.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-01-09', 'supplier', 'Corner Store', 'doc', '', 'description', 'Shop rags', 'amount', 19.99),
             jsonb_build_object('row', 3, 'date', '2026-01-09', 'supplier', 'Corner Store', 'doc', '', 'description', 'Tape', 'amount', 5)));
      r := purchases_drop(gen_random_uuid(), '{"name": "check-cash-again.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-01-09', 'supplier', 'Corner Store', 'doc', '', 'description', 'Tape', 'amount', 5),
             jsonb_build_object('row', 3, 'date', '2026-01-09', 'supplier', 'Corner Store', 'doc', '', 'description', 'Wood glue', 'amount', 9)));
      ok := ok and (v ->> 'new')::int = 0 and (v ->> 'skipped')::int = 2
            and not exists (select 1 from purchase_buys where description = 'fine')
            and (v2 ->> 'new')::int = 2 and (r ->> 'new')::int = 1 and (r ->> 'skipped')::int = 1;
      if ok then msg := null; else msg := coalesce(msg, format('receipts with no number: %s then %s', v2, r)); end if;
      if not ok and msg is null then msg := 'The same lines dropped again weren''t all skipped: ' || coalesce(v::text, ''); end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(12, 'A Purchases file: the line naming an item is filed under it, the rest wait to match, a supplier''s other name is found; the same lines again are skipped; receipts with no number are told apart by day and words; a bad row stops the file before anything is added, naming the row', ok, msg);

    -- ---- 13. Match these: remembered for the next file; left out stays on record --------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchase_item_save(jsonb_build_object('name', 'Check maple edge banding', 'category_key', 'hardware', 'unit', 'roll'));
      v := purchase_buys_match(array[b1], (v ->> 'id')::uuid, true);
      v2 := purchases_drop(gen_random_uuid(), '{"name": "check-february.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-02-02', 'supplier', 'Check Supply Co', 'doc', 'B-9', 'description', 'Edge  banding, MAPLE 7/8in', 'qty', 3, 'amount', 132)));
      -- the file's own item name: a line naming it files itself once matched
      v := purchases_drop(gen_random_uuid(), '{"name": "check-march.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-03-02', 'supplier', 'Somewhere Else', 'doc', 'C-1', 'description', 'BANDING MPL', 'item', 'Maple edgeband 7/8', 'qty', 1, 'amount', 40),
             jsonb_build_object('row', 3, 'date', '2026-03-03', 'supplier', 'Third Store', 'doc', 'C-2', 'description', 'edge tape', 'item', 'maple edgeband 7/8', 'qty', 1, 'amount', 41)));
      execute 'reset role';
      select id into bc from purchase_buys where doc_number = 'C-1'; select id into itm from purchase_items where name = 'Check maple edge banding';
      execute 'set local role authenticated';
      v := purchase_buys_match(array[bc], itm, true);
      v := purchases_drop(gen_random_uuid(), '{"name": "check-april.xlsx"}', jsonb_build_array(
             jsonb_build_object('row', 2, 'date', '2026-04-02', 'supplier', 'Another Store', 'doc', 'D-1', 'description', 'something else entirely', 'item', 'MAPLE EDGEBAND 7/8', 'qty', 2, 'amount', 80)));
      execute 'reset role'; select id into b1 from purchase_buys where description = 'Shop rags' and supplier_name = 'Somewhere Else'; execute 'set local role authenticated';
      v := purchase_buy_ignore(b1, true, 'Not production');
      execute 'reset role';
      ok := (v2 ->> 'matched')::int = 1
            and (select item_id is not null and matched_by_name = 'Matched before' from purchase_buys where doc_number = 'B-9')
            and (select item_id is not null and matched_by_name = 'The file' from purchase_buys where doc_number = 'D-1')
            and (select item_id is not null and matched_by_name = 'Matched before' from purchase_buys where doc_number = 'C-2')
            and (select 'Maple edgeband 7/8' = any(aliases) from purchase_items where name = 'Check maple edge banding')
            and (select ignored_at is not null from purchase_buys where id = b1);
      msg := 'The next file''s same line wasn''t filed by itself, or a line left out vanished: ' || coalesce(v2::text, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(13, 'A line matched once files itself in the next file (same supplier, by any of its names, and the same words in any case or spacing), and so does any line naming the file''s item name it carried; a line left out stays, marked', ok, msg);

    -- ---- 14. everything comes back in one call, no PO line counted as a buy ------------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchasing_data();
      execute 'reset role';
      ok := jsonb_array_length(v -> 'categories') >= 7 and (v ->> 'next_po')::int = 99002
            and exists (select 1 from jsonb_array_elements(v -> 'buys') b where b ->> 'doc' = 'B-9')
            and exists (select 1 from jsonb_array_elements(v -> 'buys') b where b ->> 'doc' = 'L-5' and (b ->> 'po_id')::uuid = po1)
            and exists (select 1 from jsonb_array_elements(v -> 'pos') p where p ->> 'name' = 'PO 99001' and jsonb_array_length(p -> 'lines') = 2)
            and exists (select 1 from jsonb_array_elements(v -> 'baselines') b where (b ->> 'item_id')::uuid = i8 and (b ->> 'year')::int = 2025)
            and (select count(*) from purchase_buys) = (select jsonb_array_length(v -> 'buys'));
      msg := 'purchasing_data() is missing something: ' || left(coalesce(v::text, ''), 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(14, 'purchasing_data() returns the categories, both next numbers, the POs with their lines, the baselines and every bought line, a line for a PO tied to that PO', ok, msg);

    -- ---- 15. a category of its own; lumber can''t be retired --------------------------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    begin
      v := purchase_category_save('{"name": "Check Packaging"}');
      ok := v ->> 'key' = 'check_packaging';
      msg := 'A new category got the key ' || coalesce(v ->> 'key', 'nothing');
      begin v2 := purchase_category_save('{"key": "lumber", "name": "Lumber", "retired": true}'); ok := false; msg := 'Lumber was retired.'; exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(15, 'A new category gets a key from its name; lumber can''t be retired', ok, msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ---- 10. every update and delete names its rows ------------------------------
  select string_agg(distinct fn, ', ') into msg from (
    select p.oid::regprocedure::text fn, m[1] stmt
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace,
           regexp_matches(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'),
             '(\mupdate\s+[\w.]+(\s+(as\s+)?\w+)?\s+set\s[^;]*;|\mdelete\s+from\s+[\w.]+[^;]*;)', 'gi') m
     where ns.nspname = 'public' and (p.proname like 'purchase%' or p.proname like 'lumber%')) x
   where stmt !~* '\mwhere\M';
  res := res || check_row(10, 'Every purchasing function''s update and delete says which rows (Supabase''s API refuses one that doesn''t)',
                          msg is null, 'These would stop with "UPDATE requires a WHERE clause" from a page: ' || msg);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x order by (x->>'step')::int;
end $$;
revoke all on function check_purchasing() from public, anon, authenticated;


select * from check_purchasing();
