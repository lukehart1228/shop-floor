-- =====================================================================
-- purchasing_log.sql — Log a purchase, and a Purchases file that asks nothing (10 Nov 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 59. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table.
-- Needs purchasing.sql (57). Replaces nothing, so no earlier file stops:
-- purchases_drop() stays as it is, and the page before this one keeps
-- working.
--
-- LOG A PURCHASE (Luke, 10 Nov: "every time David orders something he
-- can use it to log what was purchased. This is how the data will come
-- in from now on. The previous data was just a way to get a baseline.")
--   purchase_logs, purchase_log_lines   a buy with no PO, logged when it's
--                         ordered: where from, the date, an order or
--                         receipt number, and each item with its quantity
--                         and price. A PO already logs its own buy.
--   purchase_log_save()   logs one, or changes it. An item is picked from
--                         the shop's list, or made there and then (its
--                         category and unit picked once). A supplier the
--                         shop doesn't know yet is added by its name. A
--                         tablet's supply request on a line is marked
--                         ordered, naming where it was bought; taken off
--                         again, it's to be ordered again, as a PO does.
--   purchase_log_cancel() "It was a mistake": kept, marked, not counted;
--                         its requests go back to be ordered.
--   purchase_logs_list()  every log, for the page: Prices and Savings count
--                         them beside the POs and the Purchases file.
--
-- A PURCHASES FILE (Luke, 10 Nov: matching line by line is clunky; work it
-- out beforehand). Kept for loading past buys. The first Purchases file named 28 items the shop didn't
-- have yet, and each had to be reviewed before anything was filed. Now:
--   purchases_add()       takes a file in. A name the file uses that
--                         isn't an item yet becomes one, from the file's
--                         own name, category and unit (lumber: its
--                         thickness in quarters, read from "6/4 …"). A
--                         name the page recognised as an item the shop
--                         already has ("8/4 QS Red Oak" for 8/4 QS RO)
--                         becomes another name for that item. Then the
--                         lines go in through purchases_drop(), unchanged:
--                         already-in lines skipped, a bad row stops the
--                         whole file. A name with no category the shop
--                         knows, or lumber with no thickness in its name,
--                         is left alone and its lines wait for a match.
--   purchase_file_items   what each file made or took as another name,
--                         so the page can say so afterwards.
--   purchase_item_split() "Not the same": the other name comes off and
--                         becomes an item of its own, with its lines.
--   purchase_item_fold()  "Same as another": one item's bought lines, PO
--                         lines and remembered matches move to another,
--                         its name becomes another name for that one,
--                         and it's retired (kept, renamed "… (now …)").
-- Managers only. Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('purchasing_log.sql', 59, 'check_purchasing_log', 'check_purchasing_log', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('purchasing_log.sql', '{}'); end if;
end $$;
do $$ begin
  if to_regprocedure('public.purchases_drop(uuid,jsonb,jsonb)') is null then raise exception 'Run purchasing.sql first. This file builds on it.'; end if;
end $$;

create table if not exists purchase_file_items (
  file_id        uuid not null references purchase_files(id),
  item_id        uuid not null references purchase_items(id),
  file_name      text not null check (length(file_name) between 1 and 80),   -- the name the file used
  how            text not null check (how in ('made', 'same_as')),           -- made a new item, or took it as another name for one
  undone_at      timestamptz,                                                -- "Not the same": split off again
  undone_by_name text,
  primary key (file_id, item_id, file_name)
);
alter table purchase_file_items enable row level security;
revoke all on purchase_file_items from anon, authenticated;

-- what one file made or took as another name, as the page lists it
create or replace function purchase_file_report(p_file uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_id', x.item_id, 'name', x.file_name, 'how', x.how, 'undone', x.undone_at is not null,
                                               'item', i.name, 'category_key', i.category_key, 'unit', i.unit, 'retired', i.retired)
                            order by x.how, x.file_name), '[]'::jsonb)
    from purchase_file_items x join purchase_items i on i.id = x.item_id where x.file_id = p_file;
$$;
revoke all on function purchase_file_report(uuid) from public, anon, authenticated;

-- p_names: the item names the file uses that aren't items yet, as the page read them:
--          [{name, category (a category's key or name), unit, quarters, same_as (an item's id, or null)}]
create or replace function purchases_add(p_client_id uuid, p_file jsonb, p_lines jsonb, p_names jsonb default '[]') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  nm jsonb; v_name text; v_same uuid; v_cat text; v_q int; v_unit text; v_item uuid; v_notes jsonb := '[]'::jsonb; r jsonb; v_file uuid;
  n_made int := 0; n_same int := 0;
begin
  if not office_ok() then raise exception 'Only a manager adds a Purchases file.' using errcode = 'insufficient_privilege'; end if;
  if p_client_id is null then raise exception 'This file has no id. Choose the file again.'; end if;
  select id into v_file from purchase_files where client_id = p_client_id;
  if v_file is not null then                                   -- sent twice: one file, nothing made again
    return purchases_drop(p_client_id, p_file, p_lines) || jsonb_build_object('items', purchase_file_report(v_file));
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'The file has no lines to add.'; end if;
  if jsonb_typeof(coalesce(p_names, '[]'::jsonb)) is distinct from 'array' then raise exception 'The file''s item names didn''t come through. Choose the file again.'; end if;
  if jsonb_array_length(coalesce(p_names, '[]'::jsonb)) > 500 then raise exception 'The file names more than 500 new items. Check it''s the right file.'; end if;

  for nm in select * from jsonb_array_elements(coalesce(p_names, '[]'::jsonb)) loop
    v_name := btrim(coalesce(nm ->> 'name', ''));
    continue when v_name = '' or length(v_name) > 80;
    -- already an item, or another name for one: nothing to make
    continue when exists (select 1 from purchase_items i, unnest(i.name || i.aliases) x where lower(x) = lower(v_name));
    -- only a name a line of this file really uses
    continue when not exists (select 1 from jsonb_array_elements(p_lines) l where lower(btrim(coalesce(l ->> 'item', ''))) = lower(v_name));
    v_same := case when coalesce(nm ->> 'same_as', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (nm ->> 'same_as')::uuid end;
    if v_same is not null then
      update purchase_items set aliases = aliases || v_name, changed_at = now(), changed_by_name = my_name()
       where id = v_same and not retired and cardinality(aliases) < 30;
      if found then
        v_notes := v_notes || jsonb_build_object('item_id', v_same, 'name', v_name, 'how', 'same_as'); n_same := n_same + 1;
        continue;
      end if;
    end if;
    select key into v_cat from purchase_categories
     where not retired and (lower(key) = lower(btrim(coalesce(nm ->> 'category', ''))) or lower(name) = lower(btrim(coalesce(nm ->> 'category', '')))) limit 1;
    continue when v_cat is null;                               -- no category the shop knows: its lines wait
    if v_cat = 'lumber' then
      v_q := case when coalesce(nm ->> 'quarters', '') ~ '^\d{1,2}$' then (nm ->> 'quarters')::int end;
      continue when v_q is null or v_q < 4 or v_q > 16;        -- lumber with no thickness in its name: its lines wait
      insert into purchase_items (name, category_key, unit, quarters, changed_by_name) values (v_name, 'lumber', 'bd ft', v_q, my_name()) returning id into v_item;
    else
      v_unit := left(coalesce(nullif(btrim(coalesce(nm ->> 'unit', '')), ''), 'each'), 20);
      insert into purchase_items (name, category_key, unit, changed_by_name) values (v_name, v_cat, v_unit, my_name()) returning id into v_item;
    end if;
    v_notes := v_notes || jsonb_build_object('item_id', v_item, 'name', v_name, 'how', 'made'); n_made := n_made + 1;
  end loop;

  r := purchases_drop(p_client_id, p_file, p_lines);            -- the lines, as ever: a bad row raises, and nothing above is kept
  v_file := (r ->> 'id')::uuid;
  insert into purchase_file_items (file_id, item_id, file_name, how)
  select v_file, (x ->> 'item_id')::uuid, x ->> 'name', x ->> 'how' from jsonb_array_elements(v_notes) x
  on conflict do nothing;
  return r || jsonb_build_object('made', n_made, 'same_as', n_same, 'items', purchase_file_report(v_file));
exception when unique_violation then
  raise exception 'Two names in the file are the same item spelled two ways. Choose the file again.';
end $$;
revoke all on function purchases_add(uuid, jsonb, jsonb, jsonb) from public, anon;
grant execute on function purchases_add(uuid, jsonb, jsonb, jsonb) to authenticated;

-- what the files of the last 120 days made or took as another name
create or replace function purchase_file_items_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager sees purchasing.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('file_id', f.id, 'file_name', f.file_name, 'dropped_at', f.dropped_at, 'lines_new', f.lines_new,
                                                       'lines_skipped', f.lines_skipped, 'items', purchase_file_report(f.id)) order by f.dropped_at desc)
                     from purchase_files f where f.dropped_at > now() - interval '120 days'), '[]'::jsonb);
end $$;
revoke all on function purchase_file_items_list() from public, anon;
grant execute on function purchase_file_items_list() to authenticated;

-- "Not the same": p_name stops being another name for p_item and becomes an item of its own, with the lines that named it
create or replace function purchase_item_split(p_item uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare it purchase_items; v_alias text; v_new uuid; n int;
begin
  if not office_ok() then raise exception 'Only a manager changes the items.' using errcode = 'insufficient_privilege'; end if;
  select * into it from purchase_items where id = p_item;
  if it.id is null then raise exception 'That item wasn''t found.'; end if;
  select a into v_alias from unnest(it.aliases) a where lower(a) = lower(btrim(coalesce(p_name, ''))) limit 1;
  if v_alias is null then raise exception '% isn''t another name for %.', coalesce(nullif(btrim(p_name), ''), 'That'), it.name; end if;
  update purchase_items set aliases = array(select a from unnest(aliases) a where lower(a) <> lower(v_alias)), changed_at = now(), changed_by_name = my_name()
   where id = p_item;
  insert into purchase_items (name, category_key, unit, quarters, changed_by_name) values (v_alias, it.category_key, it.unit, it.quarters, my_name())
  returning id into v_new;
  update purchase_buys set item_id = v_new, matched_by_name = my_name(), matched_at = now() where item_id = p_item and lower(item_text) = lower(v_alias);
  get diagnostics n = row_count;
  update purchase_file_items set undone_at = now(), undone_by_name = my_name() where item_id = p_item and lower(file_name) = lower(v_alias) and how = 'same_as' and undone_at is null;
  return jsonb_build_object('ok', true, 'id', v_new, 'moved', n,
    'summary', format('%s is its own item now, with %s line%s. It''s no longer another name for %s.', v_alias, n, case when n = 1 then '' else 's' end, it.name));
exception when unique_violation then raise exception 'There''s already an item called %.', v_alias;
end $$;
revoke all on function purchase_item_split(uuid, text) from public, anon;
grant execute on function purchase_item_split(uuid, text) to authenticated;

-- "Same as another": everything bought as p_from counts as p_into from now on. p_from is kept, retired, renamed "… (now …)".
create or replace function purchase_item_fold(p_from uuid, p_into uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a purchase_items; b purchase_items; n_buys int; n_lines int; v_names text[]; v_new text; k int := 1;
begin
  if not office_ok() then raise exception 'Only a manager changes the items.' using errcode = 'insufficient_privilege'; end if;
  select * into a from purchase_items where id = p_from;
  select * into b from purchase_items where id = p_into;
  if a.id is null or b.id is null then raise exception 'That item wasn''t found.'; end if;
  if a.id = b.id then raise exception 'Pick a different item: that''s the same one.'; end if;
  if a.retired then raise exception '% is already retired.', a.name; end if;
  if b.retired then raise exception '% is retired. Pick an item that''s in use.', b.name; end if;
  if a.category_key <> b.category_key then raise exception '% and % are in different categories, so they aren''t the same thing.', a.name, b.name; end if;
  if lower(a.unit) <> lower(b.unit) then raise exception '% is bought by the % and % by the %, so their prices can''t be put together.', a.name, a.unit, b.name, b.unit; end if;
  if b.compare_as = a.id then raise exception '% is compared as %. Change that in Setup first.', b.name, a.name; end if;
  select array_agg(distinct x) into v_names from unnest(b.aliases || a.name || a.aliases) x where lower(x) <> lower(b.name);
  if coalesce(cardinality(v_names), 0) > 30 then raise exception '% would have more than 30 other names.', b.name; end if;

  update purchase_buys set item_id = b.id where item_id = a.id;
  get diagnostics n_buys = row_count;
  update purchase_po_lines set item_id = b.id where item_id = a.id;
  get diagnostics n_lines = row_count;
  update purchase_match_rules set item_id = b.id where item_id = a.id;
  update purchase_baselines x set item_id = b.id where x.item_id = a.id and b.compare_as is null
     and not exists (select 1 from purchase_baselines y where y.item_id = b.id and y.year = x.year);
  update purchase_items set compare_as = b.id where compare_as = a.id and id <> b.id and b.compare_as is null;
  update purchase_items set compare_as = null where compare_as = a.id;

  v_new := left(a.name, 80 - length(' (now ' || left(b.name, 30) || ')')) || ' (now ' || left(b.name, 30) || ')';
  while exists (select 1 from purchase_items where lower(name) = lower(v_new) and id <> a.id) loop
    k := k + 1; v_new := left(a.name, 70 - length(left(b.name, 30))) || ' (now ' || left(b.name, 30) || ') ' || k;
  end loop;
  update purchase_items set name = v_new, aliases = '{}', retired = true, compare_as = null, inv_item_id = null, changed_at = now(), changed_by_name = my_name() where id = a.id;
  update purchase_items set aliases = coalesce(v_names, '{}'), changed_at = now(), changed_by_name = my_name() where id = b.id;
  return jsonb_build_object('ok', true, 'moved', n_buys, 'po_lines', n_lines,
    'summary', format('%s is %s now: %s bought line%s and %s PO line%s moved over.', a.name, b.name, n_buys, case when n_buys = 1 then '' else 's' end,
                      n_lines, case when n_lines = 1 then '' else 's' end));
end $$;
revoke all on function purchase_item_fold(uuid, uuid) from public, anon;
grant execute on function purchase_item_fold(uuid, uuid) to authenticated;




-- =====================================================================
-- Log a purchase
-- =====================================================================
create table if not exists purchase_logs (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null unique,                        -- the page's id for this log: sent twice, logged once
  supplier_id       uuid not null references purchase_suppliers(id),
  bought_on         date not null,
  doc_number        text not null default '' check (length(doc_number) <= 80),   -- an order or receipt number, if there is one
  logged_at         timestamptz not null default now(),
  logged_by_name    text,
  changed_at        timestamptz,
  changed_by_name   text,
  cancelled_at      timestamptz,                                 -- "It was a mistake": kept, not counted
  cancelled_by_name text,
  cancel_reason     text check (length(coalesce(cancel_reason, '')) <= 200)
);
create table if not exists purchase_log_lines (
  id                uuid primary key default gen_random_uuid(),
  log_id            uuid not null references purchase_logs(id),
  position          int not null check (position between 1 and 40),
  item_id           uuid not null references purchase_items(id),
  qty               numeric not null check (qty > 0 and qty <= 10000000),
  unit_price        numeric(14,4) not null check (unit_price >= 0 and unit_price <= 1000000),
  amount            numeric(14,2) not null,
  supply_request_id uuid references supply_requests(id),      -- a tablet's request this line orders
  removed_at        timestamptz,                                 -- taken off by a change: kept, not counted
  removed_by_name   text
);
create index if not exists purchase_log_lines_log on purchase_log_lines (log_id);
create index if not exists purchase_log_lines_req on purchase_log_lines (supply_request_id) where supply_request_id is not null;
alter table purchase_logs enable row level security;
alter table purchase_log_lines enable row level security;
revoke all on purchase_logs, purchase_log_lines from anon, authenticated;

-- p: { id (to change one), supplier (a name, or one of a supplier's other names), bought_on, doc,
--      lines: [{ item_id | new_item: { name, category_key, unit, quarters }, qty, unit_price, supply_request_id }] }
create or replace function purchase_log_save(p_client_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  lg purchase_logs; v_sup uuid; v_sup_name text; v_new_sup boolean := false; v_on date; v_doc text; l jsonb; i int := 0;
  v_item uuid; v_ni jsonb; v_name text; v_cat text; v_q int; v_unit text; v_qty numeric; v_price numeric; v_req uuid;
  v_reqs uuid[] := '{}'; v_items text[] := '{}'; v_made text[] := '{}'; v_total numeric := 0; v_rows jsonb := '[]'::jsonb; v_label text;
  n_back int := 0; n_ord int := 0;
begin
  if not office_ok() then raise exception 'Only a manager logs a purchase.' using errcode = 'insufficient_privilege'; end if;
  if p_client_id is null then raise exception 'This purchase has no id. Close it and log it again.'; end if;
  if nullif(p ->> 'id', '') is not null then
    select * into lg from purchase_logs where id = (p ->> 'id')::uuid;
    if lg.id is null then raise exception 'That logged purchase wasn''t found.'; end if;
    if lg.cancelled_at is not null then raise exception 'That purchase was marked a mistake. Log it again instead.'; end if;
  else
    select * into lg from purchase_logs where client_id = p_client_id;
    if lg.id is not null then                               -- sent twice: logged once
      return jsonb_build_object('ok', true, 'id', lg.id, 'already', true, 'summary', 'Already logged.');
    end if;
  end if;

  -- where from: a supplier the shop knows, by its name or another name; otherwise a new one, by the name typed
  v_sup_name := btrim(coalesce(p ->> 'supplier', ''));
  if v_sup_name = '' then raise exception 'Say where it was bought.'; end if;
  if length(v_sup_name) > 80 then raise exception 'Keep the supplier''s name under 80 letters.'; end if;
  select id, name into v_sup, v_sup_name from purchase_suppliers
   where lower(name) = lower(v_sup_name) or exists (select 1 from unnest(aliases) a where lower(a) = lower(btrim(p ->> 'supplier')))
   order by retired, (lower(name) = lower(btrim(p ->> 'supplier'))) desc limit 1;
  if v_sup is null then
    v_sup_name := btrim(p ->> 'supplier');
    insert into purchase_suppliers (name, changed_by_name) values (v_sup_name, my_name()) returning id into v_sup;
    v_new_sup := true;
  end if;

  begin v_on := (p ->> 'bought_on')::date; exception when others then raise exception 'The date isn''t a date.'; end;
  if v_on is null then raise exception 'Say when it was bought.'; end if;
  if v_on > local_today() + 1 then raise exception 'The date is in the future.'; end if;
  if v_on < local_today() - 400 then raise exception 'That''s more than a year ago. Load past purchases from a file instead.'; end if;
  v_doc := btrim(coalesce(p ->> 'doc', ''));
  if length(v_doc) > 80 then raise exception 'Keep the order or receipt number under 80 letters.'; end if;

  if jsonb_typeof(p -> 'lines') is distinct from 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'Add at least one item.'; end if;
  if jsonb_array_length(p -> 'lines') > 40 then raise exception 'Keep it to 40 lines; log the rest as a second purchase.'; end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    i := i + 1;
    -- the item: one from the list, or a new one made here
    v_item := nullif(l ->> 'item_id', '')::uuid;
    if v_item is not null then
      if not exists (select 1 from purchase_items where id = v_item and not retired) then raise exception 'Line %: that item wasn''t found, or it''s no longer used.', i; end if;
    else
      v_ni := l -> 'new_item'; v_name := btrim(coalesce(v_ni ->> 'name', ''));
      if v_name = '' then raise exception 'Line %: pick the item, or type its name.', i; end if;
      if length(v_name) > 80 then raise exception 'Line %: keep the item''s name under 80 letters.', i; end if;
      select id into v_item from purchase_items i2, unnest(i2.name || i2.aliases) x where lower(x) = lower(v_name) and not i2.retired limit 1;
      if v_item is null then
        select key into v_cat from purchase_categories where key = v_ni ->> 'category_key' and not retired;
        if v_cat is null then raise exception 'Line %: pick a category for %.', i, v_name; end if;
        if v_cat = 'lumber' then
          v_q := case when coalesce(v_ni ->> 'quarters', '') ~ '^\d{1,2}$' then (v_ni ->> 'quarters')::int end;
          if v_q is null or v_q < 4 or v_q > 16 then raise exception 'Line %: say how thick % is, in quarters (6 for 6/4).', i, v_name; end if;
          insert into purchase_items (name, category_key, unit, quarters, changed_by_name) values (v_name, 'lumber', 'bd ft', v_q, my_name()) returning id into v_item;
        else
          v_unit := btrim(coalesce(v_ni ->> 'unit', ''));
          if v_unit = '' then raise exception 'Line %: say what % is bought by (each, box, gallon, sheet…).', i, v_name; end if;
          if length(v_unit) > 20 then raise exception 'Line %: keep the unit short (each, box, gallon…).', i; end if;
          insert into purchase_items (name, category_key, unit, changed_by_name) values (v_name, v_cat, v_unit, my_name()) returning id into v_item;
        end if;
        v_made := v_made || v_name;
      end if;
    end if;
    begin v_qty := (l ->> 'qty')::numeric; v_price := (l ->> 'unit_price')::numeric;
    exception when others then raise exception 'Line %: the quantity and the price each must be numbers.', i; end;
    if v_qty is null or v_qty <= 0 then raise exception 'Line %: say how many.', i; end if;
    if v_qty > 10000000 then raise exception 'Line %: that quantity is too big.', i; end if;
    if v_price is null or v_price < 0 then raise exception 'Line %: say the price each.', i; end if;
    if v_price > 1000000 then raise exception 'Line %: that price is too big.', i; end if;
    -- a tablet's request: waiting, or already on this purchase; not on another live PO or purchase
    v_req := nullif(l ->> 'supply_request_id', '')::uuid;
    if v_req is not null then
      if not exists (select 1 from supply_requests where id = v_req and sees_lane(is_test)) then raise exception 'Line %: that supply request wasn''t found.', i; end if;
      if v_req = any(v_reqs) then raise exception 'Line %: that supply request is on two lines.', i; end if;
      if exists (select 1 from purchase_po_lines x join purchase_pos y on y.id = x.po_id where x.supply_request_id = v_req and x.removed_at is null and y.cancelled_at is null)
         or exists (select 1 from purchase_log_lines x join purchase_logs y on y.id = x.log_id where x.supply_request_id = v_req and x.removed_at is null and y.cancelled_at is null and y.id is distinct from lg.id) then
        raise exception 'Line %: that request is already ordered on another PO or purchase.', i;
      end if;
      if (select state from supply_requests where id = v_req) not in ('requested', 'ordered') then raise exception 'Line %: that request is closed already.', i; end if;
      v_reqs := v_reqs || v_req;
    end if;
    v_rows := v_rows || jsonb_build_object('pos', i, 'item', v_item, 'qty', v_qty, 'price', v_price, 'amount', round(v_qty * v_price, 2), 'req', v_req);
    v_total := v_total + round(v_qty * v_price, 2);
  end loop;

  if lg.id is null then
    insert into purchase_logs (client_id, supplier_id, bought_on, doc_number, logged_by_name) values (p_client_id, v_sup, v_on, v_doc, my_name()) returning * into lg;
  else
    update purchase_logs set supplier_id = v_sup, bought_on = v_on, doc_number = v_doc, changed_at = now(), changed_by_name = my_name() where id = lg.id returning * into lg;
    -- requests no longer on it go back to be ordered, as a PO's do
    with back as (
      update supply_requests r set state = 'requested', ordered_by_name = null, ordered_at = null, updated_at = now()
        from purchase_log_lines x where x.log_id = lg.id and x.removed_at is null and r.id = x.supply_request_id and r.state = 'ordered' and not r.id = any(v_reqs)
      returning r.id)
    insert into supply_request_events (request_id, what, by_name) select id, 'Taken off the purchase from ' || v_sup_name || ': to be ordered again', my_name() from back;
    get diagnostics n_back = row_count;
    update purchase_log_lines set removed_at = now(), removed_by_name = my_name() where log_id = lg.id and removed_at is null;
  end if;
  insert into purchase_log_lines (log_id, position, item_id, qty, unit_price, amount, supply_request_id)
  select lg.id, (r ->> 'pos')::int, (r ->> 'item')::uuid, (r ->> 'qty')::numeric, (r ->> 'price')::numeric, (r ->> 'amount')::numeric, nullif(r ->> 'req', '')::uuid
    from jsonb_array_elements(v_rows) r;
  with done as (
    update supply_requests set state = 'ordered', ordered_by_name = my_name(), ordered_at = now(), updated_at = now()
     where id = any(v_reqs) and state = 'requested' returning id)
  insert into supply_request_events (request_id, what, by_name) select id, 'Ordered: bought from ' || v_sup_name, my_name() from done;
  get diagnostics n_ord = row_count;

  v_label := format('%s from %s', to_char(v_total, 'FM$999,999,990.00'), v_sup_name);
  return jsonb_build_object('ok', true, 'id', lg.id, 'total', v_total, 'new_supplier', v_new_sup, 'made', to_jsonb(v_made),
    'summary', concat_ws(' ', case when nullif(p ->> 'id', '') is null then 'Logged: ' else 'Changed: ' end || v_label || '.',
      case when n_ord > 0 then format('%s supply request%s marked ordered.', n_ord, case when n_ord = 1 then ' is' else 's are' end) end,
      case when n_back > 0 then format('%s request%s back to be ordered.', n_back, case when n_back = 1 then ' is' else 's are' end) end,
      case when cardinality(v_made) > 0 then format('New item%s: %s.', case when cardinality(v_made) = 1 then '' else 's' end, array_to_string(v_made, ', ')) end,
      case when v_new_sup then format('%s is a new supplier.', v_sup_name) end));
exception when unique_violation then raise exception 'Two lines make the same new item. Make it on one line and pick it on the other.';
end $$;
revoke all on function purchase_log_save(uuid, jsonb) from public, anon;
grant execute on function purchase_log_save(uuid, jsonb) to authenticated;

-- "It was a mistake": kept, marked, no longer counted; its requests go back to be ordered
create or replace function purchase_log_cancel(p_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg purchase_logs; v_name text; n int := 0;
begin
  if not office_ok() then raise exception 'Only a manager changes a logged purchase.' using errcode = 'insufficient_privilege'; end if;
  select * into lg from purchase_logs where id = p_id;
  if lg.id is null then raise exception 'That logged purchase wasn''t found.'; end if;
  if lg.cancelled_at is not null then return jsonb_build_object('ok', true, 'summary', 'It was already marked a mistake.'); end if;
  select name into v_name from purchase_suppliers where id = lg.supplier_id;
  update purchase_logs set cancelled_at = now(), cancelled_by_name = my_name(), cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 200) where id = p_id;
  with back as (
    update supply_requests r set state = 'requested', ordered_by_name = null, ordered_at = null, updated_at = now()
      from purchase_log_lines x where x.log_id = p_id and x.removed_at is null and r.id = x.supply_request_id and r.state = 'ordered'
    returning r.id)
  insert into supply_request_events (request_id, what, by_name) select id, 'The purchase from ' || v_name || ' was a mistake: to be ordered again', my_name() from back;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'summary', concat_ws(' ', format('The purchase from %s is marked a mistake. It stays on record and isn''t counted.', v_name),
    case when n > 0 then format('%s supply request%s back to be ordered.', n, case when n = 1 then ' is' else 's are' end) end));
end $$;
revoke all on function purchase_log_cancel(uuid, text) from public, anon;
grant execute on function purchase_log_cancel(uuid, text) to authenticated;

-- every logged purchase with its current lines, newest first (the page counts the ones not marked a mistake)
create or replace function purchase_logs_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager sees purchasing.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'supplier_id', g.supplier_id, 'supplier', v.name, 'on', g.bought_on, 'doc', g.doc_number,
      'logged_by_name', g.logged_by_name, 'logged_at', g.logged_at, 'changed_by_name', g.changed_by_name, 'changed_at', g.changed_at,
      'cancelled', g.cancelled_at is not null, 'cancelled_by_name', g.cancelled_by_name, 'cancel_reason', g.cancel_reason,
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'position', x.position, 'item_id', x.item_id, 'item', i.name, 'unit', i.unit,
                  'qty', x.qty, 'unit_price', x.unit_price, 'amount', x.amount, 'supply_request_id', x.supply_request_id) order by x.position), '[]'::jsonb)
                from purchase_log_lines x join purchase_items i on i.id = x.item_id where x.log_id = g.id and x.removed_at is null))
      order by g.bought_on desc, g.logged_at desc)
    from purchase_logs g join purchase_suppliers v on v.id = g.supplier_id), '[]'::jsonb);
end $$;
revoke all on function purchase_logs_list() from public, anon;
grant execute on function purchase_logs_list() to authenticated;

-- ---------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------
create or replace function check_purchasing_log()
returns table(step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  res jsonb := '[]'::jsonb; ok boolean; msg text; n int; r jsonb; r2 jsonb;
  mgr uuid := '00000000-0000-4000-8000-00000000c591'; sup uuid := '00000000-0000-4000-8000-00000000c592';
  qs uuid; glue uuid; ven uuid; ia uuid; ib uuid; ic uuid; ih uuid; po uuid; v_new uuid; rq1 uuid; rq2 uuid; lg uuid; lcid uuid := '00000000-0000-4000-8000-0000000c5902';
  cid uuid := '00000000-0000-4000-8000-0000000c5901';
  lines jsonb := '[
    {"row": 2, "date": "2026-01-06", "supplier": "Check Files Supply", "doc": "F-1", "description": "TITEBOND 1 GAL", "item": "Check Files Glue", "category": "Hardware", "qty": 4, "unit": "gallon", "amount": 150},
    {"row": 3, "date": "2026-01-06", "supplier": "Check Files Supply", "doc": "F-1", "description": "8/4 QSRO 200 BF", "item": "Check Files 8/4 QS Red Oak", "category": "Lumber", "qty": 200, "unit": "bd ft", "amount": 1800},
    {"row": 4, "date": "2026-01-07", "supplier": "Check Files Supply", "doc": "F-2", "description": "LIVE EDGE SLAB", "item": "Check Files Slab", "category": "Slabs", "qty": 1, "unit": "each", "amount": 900},
    {"row": 5, "date": "2026-01-07", "supplier": "Check Files Supply", "doc": "F-2", "description": "CHERRY 15/16", "item": "Check Files Cherry thin", "category": "Lumber", "qty": 50, "unit": "bd ft", "amount": 300},
    {"row": 6, "date": "2026-01-08", "supplier": "Check Files Supply", "doc": "F-3", "description": "shop rags", "amount": 12}]';
  names jsonb;
begin
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'purchase_file_items' and grantee in ('anon', 'authenticated');
  ok := n = 0 and (select relrowsecurity from pg_class where oid = 'public.purchase_file_items'::regclass);
  res := res || check_row(1, 'The table of what each file made has its security rule on, and no login reads or writes it directly', ok,
                          format('%s grants found, or the rule is off. Run purchasing_log.sql again.', n));
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('purchase_logs', 'purchase_log_lines') and grantee in ('anon', 'authenticated');
  res := res || check_row(8, 'The logged-purchase tables have their security rule on, and no login reads or writes them directly', n = 0
    and (select bool_and(relrowsecurity) from pg_class where oid in ('public.purchase_logs'::regclass, 'public.purchase_log_lines'::regclass)), format('%s grants found, or a rule is off. Run purchasing_log.sql again.', n));
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and grantee in ('anon', 'PUBLIC')
     and routine_name in ('purchases_add', 'purchase_file_items_list', 'purchase_item_split', 'purchase_item_fold', 'purchase_file_report', 'purchase_log_save', 'purchase_log_cancel', 'purchase_logs_list');
  select n + count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and grantee = 'authenticated' and routine_name = 'purchase_file_report';
  res := res || check_row(2, 'Its functions need a login, and the inside helper runs for nobody', n = 0, format('%s grants too many. Run purchasing_log.sql again.', n));

  begin   -- everything below is undone at the end
    insert into auth.users (id, email) values (mgr, 'check-files-mgr@example.com'), (sup, 'check-files-sup@example.com');
    insert into profiles (id, full_name, role, departments) values (mgr, 'Files check (manager)', 'manager', '{}'), (sup, 'Files check (supervisor)', 'supervisor', '{milling}');
    insert into purchase_items (name, category_key, unit, quarters) values ('Check Files 8/4 QS RO', 'lumber', 'bd ft', 8) returning id into qs;
    names := jsonb_build_array(
      jsonb_build_object('name', 'Check Files Glue', 'category', 'Hardware', 'unit', 'gallon'),
      jsonb_build_object('name', 'Check Files 8/4 QS Red Oak', 'category', 'Lumber', 'unit', 'bd ft', 'quarters', 8, 'same_as', qs),
      jsonb_build_object('name', 'Check Files Slab', 'category', 'Slabs', 'unit', 'each'),
      jsonb_build_object('name', 'Check Files Cherry thin', 'category', 'Lumber', 'unit', 'bd ft'),
      jsonb_build_object('name', 'Check Files Never Used', 'category', 'Hardware', 'unit', 'each'));

    -- ---- 3: a supervisor is turned away from all four ----
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated'; n := 0; msg := null;
      begin perform purchases_add(gen_random_uuid(), '{"name": "x"}', lines, names); msg := concat_ws(', ', msg, 'added a file'); exception when insufficient_privilege then n := n + 1; end;
      begin perform purchase_file_items_list(); msg := concat_ws(', ', msg, 'read the list'); exception when insufficient_privilege then n := n + 1; end;
      begin perform purchase_item_split(qs, 'x'); msg := concat_ws(', ', msg, 'split an item'); exception when insufficient_privilege then n := n + 1; end;
      begin perform purchase_item_fold(qs, qs); msg := concat_ws(', ', msg, 'folded an item'); exception when insufficient_privilege then n := n + 1; end;
      execute 'reset role';
    exception when others then execute 'reset role'; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'A supervisor can''t add a Purchases file, read what files made, split an item or fold one', msg is null and n = 4, 'A supervisor ' || coalesce(msg, 'got an unexpected answer') || '.');

    -- ---- 4: a file that asks nothing ----
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := purchases_add(cid, '{"name": "check-files.xlsx"}', lines, names);
      r2 := purchases_add(cid, '{"name": "check-files.xlsx"}', lines, names);
      execute 'reset role';
      select id into glue from purchase_items where name = 'Check Files Glue';
      ok := (r ->> 'new')::int = 5 and (r ->> 'made')::int = 1 and (r ->> 'same_as')::int = 1 and (r ->> 'to_match')::int = 3 and (r2 ->> 'already')::boolean
            and (select category_key = 'hardware' and unit = 'gallon' from purchase_items where id = glue)
            and (select item_id = glue from purchase_buys where doc_number = 'F-1' and description = 'TITEBOND 1 GAL')
            and (select item_id = qs from purchase_buys where description = '8/4 QSRO 200 BF')
            and (select 'Check Files 8/4 QS Red Oak' = any(aliases) from purchase_items where id = qs)
            and not exists (select 1 from purchase_items where name in ('Check Files Slab', 'Check Files Cherry thin', 'Check Files Never Used'))
            and (select count(*) from purchase_buys where supplier_name = 'Check Files Supply' and item_id is null) = 3
            and jsonb_array_length(r -> 'items') = 2 and (select count(*) from purchase_items where name = 'Check Files Glue') = 1;
      msg := format('first %s; again %s', left(r::text, 400), left(r2::text, 120));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'A file is added without a question: a new name becomes an item with the file''s category and unit, a look-alike becomes another name for the item the shop has, a name with no known category, lumber with no thickness and a name no line uses make nothing, and the file sent twice makes nothing twice', ok, msg);

    -- ---- 5: a bad row: nothing added, and no item made on the way ----
    begin execute 'set local role authenticated';
      begin perform purchases_add(gen_random_uuid(), '{"name": "check-bad.xlsx"}',
              '[{"row": 2, "date": "2026-02-01", "supplier": "Check Files Supply", "doc": "G-1", "description": "ok", "item": "Check Files Ghost", "category": "Hardware", "amount": 5},
                {"row": 3, "date": "not a date", "supplier": "Check Files Supply", "doc": "G-1", "description": "bad", "amount": 5}]',
              '[{"name": "Check Files Ghost", "category": "Hardware", "unit": "each"}]');
        ok := false; msg := 'A file with an unreadable date was taken.';
      exception when others then ok := sqlerrm like 'Row 3:%'; msg := sqlerrm; end;
      execute 'reset role';
      ok := ok and not exists (select 1 from purchase_items where name = 'Check Files Ghost') and not exists (select 1 from purchase_buys where doc_number = 'G-1');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'A row that can''t be read stops the whole file, naming the row: no line is added and no item is made', ok, msg);

    -- ---- 6: the page's list, and "Not the same" ----
    begin execute 'set local role authenticated';
      r := purchase_file_items_list();
      r2 := purchase_item_split(qs, 'check files 8/4 qs red oak');
      begin perform purchase_item_split(qs, 'Check Files 8/4 QS Red Oak'); ok := false; msg := 'It was split a second time.'; exception when others then ok := true; msg := null; end;
      execute 'reset role';
      v_new := (r2 ->> 'id')::uuid;
      ok := ok and exists (select 1 from jsonb_array_elements(r) f where f ->> 'file_name' = 'check-files.xlsx' and jsonb_array_length(f -> 'items') = 2)
            and (select name = 'Check Files 8/4 QS Red Oak' and category_key = 'lumber' and quarters = 8 from purchase_items where id = v_new)
            and (select item_id = v_new from purchase_buys where description = '8/4 QSRO 200 BF')
            and (select cardinality(aliases) = 0 from purchase_items where id = qs)
            and (select undone_at is not null from purchase_file_items where item_id = qs and how = 'same_as');
      msg := coalesce(msg, r2::text);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(6, 'The page can list what a file made; "Not the same" makes the other name an item of its own with its line, once', ok, msg);

    -- ---- 7: "Same as another": one item folded into another ----
    insert into purchase_suppliers (name) values ('Check Files Lumber Co') returning id into ven;
    insert into purchase_items (name, category_key, unit, aliases) values ('Check Files Ply A', 'sheet_goods', 'sheet', '{Check Files Ply A-alt}') returning id into ia;
    insert into purchase_items (name, category_key, unit) values ('Check Files Ply B', 'sheet_goods', 'sheet') returning id into ib;
    insert into purchase_items (name, category_key, unit) values ('Check Files Ply C', 'sheet_goods', 'each') returning id into ic;
    insert into purchase_items (name, category_key, unit) values ('Check Files Hardboard', 'hardware', 'sheet') returning id into ih;   -- the same unit, another category
    insert into purchase_baselines (item_id, year, price) values (ia, 2025, 61.25);
    insert into purchase_pos (series, po_number, name, vendor_id, ordered_on) values ('po', 98991, 'PO 98991', ven, '2026-03-01') returning id into po;
    insert into purchase_po_lines (po_id, position, qty, unit, description, unit_price, item_id) values (po, 1, 10, 'Sheets', 'ply', 60, ia);
    insert into purchase_buys (file_id, supplier_name, doc_number, line_key, bought_on, description, item_id, item_text, qty, amount)
      values ((select id from purchase_files where client_id = cid), 'Check Files Supply', 'F-9', '1', '2026-03-02', 'ply a', ia, 'Check Files Ply A', 4, 250);
    begin execute 'set local role authenticated';
      msg := '';
      begin perform purchase_item_fold(ia, ia); msg := msg || 'folded into itself; '; exception when others then null; end;
      begin perform purchase_item_fold(ia, ih); msg := msg || 'folded across categories; '; exception when others then null; end;
      begin perform purchase_item_fold(ia, ic); msg := msg || 'folded across units; '; exception when others then null; end;
      r := purchase_item_fold(ia, ib);
      begin perform purchase_item_fold(ia, ib); msg := msg || 'folded twice; '; exception when others then null; end;
      r2 := purchases_add(gen_random_uuid(), '{"name": "check-files-later.xlsx"}',
              '[{"row": 2, "date": "2026-04-01", "supplier": "Check Files Supply", "doc": "F-20", "description": "more ply", "item": "check files ply a", "category": "Sheet goods", "qty": 2, "unit": "sheet", "amount": 120}]',
              '[{"name": "check files ply a", "category": "Sheet goods", "unit": "sheet"}]');
      execute 'reset role';
      ok := msg = '' and (r ->> 'moved')::int = 1 and (r ->> 'po_lines')::int = 1
            and (select item_id = ib from purchase_buys where doc_number = 'F-9') and (select item_id = ib from purchase_po_lines where po_id = po)
            and (select retired and name = 'Check Files Ply A (now Check Files Ply B)' and cardinality(aliases) = 0 from purchase_items where id = ia)
            and (select aliases @> array['Check Files Ply A', 'Check Files Ply A-alt'] from purchase_items where id = ib)
            and (select item_id = ib from purchase_baselines where year = 2025 and price = 61.25)
            and (select item_id = ib from purchase_buys where doc_number = 'F-20') and (r2 ->> 'made')::int = 0;
      msg := nullif(msg, '') || '' ; if not ok and msg is null then msg := format('fold %s; later file %s', r, left(r2::text, 200)); end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'Folding one item into another moves its bought line, its PO line and its baseline, keeps its names as other names so a later file files itself, and retires it (kept, renamed); into itself, across categories, across units or twice is refused', ok, msg);


    -- ---- 9: a supervisor can't log a purchase or read them ----
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated'; n := 0; msg := null;
      begin perform purchase_log_save(gen_random_uuid(), '{"supplier": "x"}'); msg := concat_ws(', ', msg, 'logged a purchase'); exception when insufficient_privilege then n := n + 1; end;
      begin perform purchase_log_cancel(gen_random_uuid()); msg := concat_ws(', ', msg, 'marked one a mistake'); exception when insufficient_privilege then n := n + 1; end;
      begin perform purchase_logs_list(); msg := concat_ws(', ', msg, 'read them'); exception when insufficient_privilege then n := n + 1; end;
      execute 'reset role';
    exception when others then execute 'reset role'; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(9, 'A supervisor can''t log a purchase, mark one a mistake or read them', msg is null and n = 3, 'A supervisor ' || coalesce(msg, 'got an unexpected answer') || '.');

    -- ---- 10: a purchase logged with two tablet requests on it ----
    insert into purchase_suppliers (name, aliases) values ('Check Log Store Co', '{CLS}');
    insert into supply_requests (department, item, qty, requested_by_name) values ('assembly_qc', 'Check Log glue', 2, 'Check') returning id into rq1;
    insert into supply_requests (department, item, qty, requested_by_name) values ('metal', 'Check Log brushes', 3, 'Check') returning id into rq2;
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      msg := '';
      begin perform purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'Check Log Store', 'bought_on', local_today(), 'lines', '[]'::jsonb)); msg := msg || 'no lines; '; exception when others then null; end;
      begin perform purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'Check Log Store', 'bought_on', local_today() + 5,
              'lines', jsonb_build_array(jsonb_build_object('item_id', glue, 'qty', 1, 'unit_price', 1)))); msg := msg || 'a future date; '; exception when others then null; end;
      begin perform purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'Check Log Store', 'bought_on', local_today(),
              'lines', jsonb_build_array(jsonb_build_object('new_item', jsonb_build_object('name', 'Check Log Thing', 'category_key', 'lumber'), 'qty', 1, 'unit_price', 1)))); msg := msg || 'lumber with no thickness; '; exception when others then null; end;
      begin perform purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'Check Log Store', 'bought_on', local_today(),
              'lines', jsonb_build_array(jsonb_build_object('item_id', glue, 'qty', 0, 'unit_price', 1)))); msg := msg || 'a quantity of 0; '; exception when others then null; end;
      r := purchase_log_save(lcid, jsonb_build_object('supplier', 'cls', 'bought_on', local_today(), 'doc', 'R-77', 'lines', jsonb_build_array(
             jsonb_build_object('item_id', glue, 'qty', 2, 'unit_price', 31.49, 'supply_request_id', rq1),
             jsonb_build_object('new_item', jsonb_build_object('name', 'Check Log brushes', 'category_key', 'hardware', 'unit', 'each'), 'qty', 3, 'unit_price', 6.98, 'supply_request_id', rq2))));
      r2 := purchase_log_save(lcid, jsonb_build_object('supplier', 'cls', 'bought_on', local_today(), 'lines', '[]'::jsonb));
      execute 'reset role';
      lg := (r ->> 'id')::uuid;
      ok := msg = '' and (r ->> 'total')::numeric = 83.92 and (r2 ->> 'already')::boolean
            and (select count(*) from purchase_log_lines where log_id = lg and removed_at is null) = 2
            and (select state from supply_requests where id = rq1) = 'ordered' and (select state from supply_requests where id = rq2) = 'ordered'
            and exists (select 1 from supply_request_events where request_id = rq1 and what = 'Ordered: bought from Check Log Store Co')
            and (select supplier_id from purchase_logs where client_id = lcid) = (select id from purchase_suppliers where name = 'Check Log Store Co')
            and exists (select 1 from purchase_items where name = 'Check Log brushes' and category_key = 'hardware' and unit = 'each')
            and (select count(*) from purchase_logs where client_id = lcid) = 1 and not (r ->> 'new_supplier')::boolean;
      msg := coalesce(nullif(msg, ''), left(r::text, 400));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(10, 'A purchase is logged with an item from the list and one made there and then ($83.92), the store found by its other name, its two tablet requests marked ordered naming where it was bought, and sent twice it''s logged once; no lines, a future date, lumber with no thickness or a quantity of 0 are refused', ok, msg);

    -- ---- 11: changed, then a mistake; the list ----
    begin execute 'set local role authenticated';
      begin perform purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'Somewhere New', 'bought_on', local_today(),
              'lines', jsonb_build_array(jsonb_build_object('item_id', glue, 'qty', 1, 'unit_price', 30, 'supply_request_id', rq1)))); msg := 'a request on two purchases'; ok := false;
      exception when others then ok := true; msg := null; end;
      r := purchase_log_save(gen_random_uuid(), jsonb_build_object('id', lg, 'supplier', 'Check Log Store Co', 'bought_on', local_today(), 'doc', 'R-77',
             'lines', jsonb_build_array(jsonb_build_object('item_id', glue, 'qty', 2, 'unit_price', 30.99, 'supply_request_id', rq1))));
      r2 := purchase_logs_list();
      execute 'reset role';
      ok := ok and (select state from supply_requests where id = rq2) = 'requested'
            and exists (select 1 from supply_request_events where request_id = rq2 and what like 'Taken off the purchase from Check Log Store Co%')
            and (select count(*) from purchase_log_lines where log_id = lg and removed_at is null) = 1 and (select count(*) from purchase_log_lines where log_id = lg) = 3
            and exists (select 1 from jsonb_array_elements(r2) x where (x ->> 'id')::uuid = lg and jsonb_array_length(x -> 'lines') = 1 and (x -> 'lines' -> 0 ->> 'amount')::numeric = 61.98);
      execute 'set local role authenticated';
      r := purchase_log_cancel(lg, 'Logged twice');
      execute 'reset role';
      ok := ok and (select state from supply_requests where id = rq1) = 'requested'
            and exists (select 1 from supply_request_events where request_id = rq1 and what like '%was a mistake: to be ordered again');
      execute 'set local role authenticated';
      r2 := purchase_log_save(gen_random_uuid(), jsonb_build_object('supplier', 'A Brand New Store', 'bought_on', local_today(),
              'lines', jsonb_build_array(jsonb_build_object('item_id', glue, 'qty', 1, 'unit_price', 30, 'supply_request_id', rq1))));
      execute 'reset role';
      ok := ok and (select cancelled_at is not null from purchase_logs where id = lg) and (r2 ->> 'new_supplier')::boolean
            and exists (select 1 from purchase_suppliers where name = 'A Brand New Store') and (select state from supply_requests where id = rq1) = 'ordered';
      msg := coalesce(msg, format('cancel %s; again %s', left(r::text, 160), left(r2::text, 160)));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(11, 'Changed: the line taken off goes and its request is to be ordered again, the old lines kept; a request already on a purchase can''t go on another; marked a mistake, it''s kept and its request can be bought again, from a supplier the shop didn''t know, who is added', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_purchasing_log_undo__';
  exception when others then
    begin execute 'reset role'; exception when others then null; end;
    if sqlerrm <> '__check_purchasing_log_undo__' then res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x order by (x->>'step')::int;
end $$;
revoke all on function check_purchasing_log() from public, anon, authenticated;

select * from check_purchasing_log();
