-- =====================================================================
-- Shop Floor — supply lists (24 Sep 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once. The
-- last thing it does is run check_supply_lists(), so the Results show
-- 10 rows that should all say PASS.
--
-- What it adds:
--   * supply_items — each department's list of things it orders often.
--     An item can have up to two sets of choices (Plywood: the wood, and
--     the thickness). The tablet shows the list as buttons on Supplies;
--     the typed box stays for anything not on it.
--   * The office edits the lists (office page -> Setup -> Supply lists):
--     set_supply_item(), move_supply_item(), retire_supply_item().
--     Managers only. Retiring takes an item off the tablets; nothing is
--     deleted.
--   * Luke's starting lists for Milling, Sanding, Full Custom and
--     Assembly / QC. Loaded once per department: running this file
--     again never adds them twice, and never brings back one you've
--     retired or changed.
--
-- What it doesn't change: asking for supplies. A pick from the list
-- goes to the office through the same request_supply() as before, as
-- its full wording ("Plywood — White Oak, 3/4 MDF"), so Needs you, the
-- ordering and the history work exactly as they do now.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('supply_lists.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.request_supply(text,text,integer,text,uuid)') is null then
    raise exception 'Run supplies.sql first (step 7). This file builds on it.';
  end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run check_floor.sql first. This file''s check uses it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The lists
-- ---------------------------------------------------------------------

create table if not exists supply_items (
  id               uuid primary key default gen_random_uuid(),
  department       text        not null references departments(key),
  name             text        not null check (length(trim(name)) > 0),
  -- [] or [{"label": "Wood", "options": ["Ash", "Maple"]}, ...] — at most two sets
  choices          jsonb       not null default '[]' check (jsonb_typeof(choices) = 'array'),
  sort_order       int         not null default 0,
  retired          boolean     not null default false,
  retired_at       timestamptz,
  retired_by_name  text,
  added_by_name    text,
  added_at         timestamptz not null default now(),
  updated_by_name  text,
  updated_at       timestamptz not null default now()
);
create index if not exists supply_items_dept_idx on supply_items (department, retired, sort_order);
-- one live item of a name per department (a retired one can share it)
create unique index if not exists supply_items_live_name on supply_items (department, lower(name)) where not retired;

alter table supply_items enable row level security;
drop policy if exists read_supply_items on supply_items;
create policy read_supply_items on supply_items for select to authenticated using (true);
revoke insert, update, delete on supply_items from anon, authenticated;
revoke select on supply_items from anon;
grant select on supply_items to authenticated;

-- ---------------------------------------------------------------------
-- 2. Tidy and check a set of choices: [] up to two sets, each with a
--    name and at least one option. Returns the tidied version.
-- ---------------------------------------------------------------------

create or replace function supply_choices_clean(p jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  out    jsonb := '[]';
  g      jsonb;
  lbl    text;
  opts   jsonb;
  o      text;
  seen   text[];
begin
  if p is null or p = 'null'::jsonb then return '[]'; end if;
  if jsonb_typeof(p) <> 'array' then raise exception 'The choices didn''t come through properly. Try again.'; end if;
  if jsonb_array_length(p) > 2 then
    raise exception 'An item can have at most two sets of choices (for example the wood, and the thickness).';
  end if;
  for g in select * from jsonb_array_elements(p) loop
    lbl := nullif(trim(g->>'label'), '');
    if lbl is null then raise exception 'Give each set of choices a name (for example "Thickness").'; end if;
    if length(lbl) > 30 then raise exception 'Keep "%" to 30 letters or fewer.', lbl; end if;
    opts := '[]'; seen := '{}';
    for o in select trim(x) from jsonb_array_elements_text(coalesce(g->'options', '[]')) x loop
      continue when o = '';
      if length(o) > 30 then raise exception 'Keep "%" to 30 letters or fewer.', o; end if;
      if lower(o) = any(seen) then raise exception '"%" is in the % choices twice.', o, lbl; end if;
      seen := seen || lower(o);
      opts := opts || to_jsonb(o);
    end loop;
    if jsonb_array_length(opts) = 0 then raise exception 'List at least one choice under "%".', lbl; end if;
    if jsonb_array_length(opts) > 15 then raise exception '"%" has more than 15 choices. Split it into two items.', lbl; end if;
    out := out || jsonb_build_array(jsonb_build_object('label', lbl, 'options', opts));
  end loop;
  return out;
end $$;
revoke all on function supply_choices_clean(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Luke's starting lists — once per department, never again
-- ---------------------------------------------------------------------

do $$
declare
  start jsonb := '{
    "milling":     [["Glue"], ["Glue rollers"], ["Glue bottles"], ["Boxes of biscuits"]],
    "sanding":     [["Sandpaper", [{"label": "Grit", "options": ["80 grit", "100 grit", "120 grit", "150 grit"]}]],
                    ["Hand sandpaper"], ["Epoxy"], ["Dye"], ["Cups"], ["Stir sticks"], ["Gloves"]],
    "full_custom": [["Plywood", [{"label": "Wood", "options": ["Ash", "Maple", "White Oak", "Walnut", "Cherry"]},
                                 {"label": "Thickness", "options": ["1/4", "1/2", "3/4", "3/4 MDF"]}]]],
    "assembly_qc": [["1 1/4 screws"], ["1 screws"]]
  }';
  d text; items jsonb; i int;
begin
  for d, items in select * from jsonb_each(start) loop
    continue when not exists (select 1 from departments where key = d);
    continue when exists (select 1 from supply_items where department = d);   -- this department has had a list before
    for i in 0 .. jsonb_array_length(items) - 1 loop
      insert into supply_items (department, name, choices, sort_order, added_by_name, updated_by_name)
      values (d, items->i->>0, supply_choices_clean(coalesce(items->i->1, '[]')), i + 1, 'Starting list', 'Starting list');
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. The office's changes
-- ---------------------------------------------------------------------

-- add an item (p_id null) or change one (its name, or its choices)
create or replace function set_supply_item(p_id uuid, p_department text, p_name text, p_choices jsonb default '[]')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name    text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_dept    departments;
  v_old     supply_items;
  v_choices jsonb;
  v_id      uuid;
begin
  if not office_ok() then
    raise exception 'Only a manager can change the supply lists.' using errcode = 'insufficient_privilege';
  end if;
  if p_id is not null then
    select * into v_old from supply_items where id = p_id;
    if v_old.id is null then raise exception 'That item isn''t on the list any more. Reload the page.'; end if;
    p_department := v_old.department;          -- an item stays in its department
  end if;
  select * into v_dept from departments where key = p_department;
  if v_dept.key is null then raise exception '"%" is not a department.', p_department; end if;
  if v_dept.log_only then
    raise exception '% has no Supplies area on its tablet, so it has no supply list.', v_dept.name;
  end if;
  if v_name is null then raise exception 'Type the item''s name first.'; end if;
  if length(v_name) > 60 then raise exception 'Keep the name to 60 letters or fewer.'; end if;
  v_choices := supply_choices_clean(p_choices);
  if exists (select 1 from supply_items where department = v_dept.key and not retired
                and lower(name) = lower(v_name) and id is distinct from p_id) then
    raise exception '"%" is already on %''s list.', v_name, v_dept.name;
  end if;

  if p_id is null then
    insert into supply_items (department, name, choices, sort_order, added_by_name, updated_by_name)
    values (v_dept.key, v_name, v_choices,
            coalesce((select max(sort_order) + 1 from supply_items where department = v_dept.key), 1), my_name(), my_name())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('%s: "%s" added to the list.', v_dept.name, v_name));
  end if;
  update supply_items set name = v_name, choices = v_choices, updated_by_name = my_name(), updated_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id, 'summary', format('%s: "%s" saved.', v_dept.name, v_name));
end $$;
revoke all on function set_supply_item(uuid, text, text, jsonb) from public, anon;
grant execute on function set_supply_item(uuid, text, text, jsonb) to authenticated;

-- move an item one place up (or down) its department's list
create or replace function move_supply_item(p_id uuid, p_up boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_items; w supply_items; i int := 0; r record;
begin
  if not office_ok() then
    raise exception 'Only a manager can change the supply lists.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from supply_items where id = p_id;
  if v.id is null or v.retired then raise exception 'That item isn''t on the list. Reload the page.'; end if;
  -- number the live list 1, 2, 3 … first, so gaps and ties can't stop a move
  for r in select id from supply_items where department = v.department and not retired order by sort_order, added_at, id loop
    i := i + 1;
    update supply_items set sort_order = i where id = r.id;
  end loop;
  select * into v from supply_items where id = p_id;
  select * into w from supply_items
   where department = v.department and not retired
     and sort_order = v.sort_order + case when p_up then -1 else 1 end;
  if w.id is null then
    return jsonb_build_object('ok', true, 'summary', format('"%s" is already at the %s.', v.name, case when p_up then 'top' else 'bottom' end));
  end if;
  update supply_items set sort_order = w.sort_order where id = v.id;
  update supply_items set sort_order = v.sort_order where id = w.id;
  return jsonb_build_object('ok', true, 'summary', format('"%s" moved %s.', v.name, case when p_up then 'up' else 'down' end));
end $$;
revoke all on function move_supply_item(uuid, boolean) from public, anon;
grant execute on function move_supply_item(uuid, boolean) to authenticated;

-- retire an item (off the tablets, kept here), or bring it back
create or replace function retire_supply_item(p_id uuid, p_retire boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_items; v_dept text;
begin
  if not office_ok() then
    raise exception 'Only a manager can change the supply lists.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from supply_items where id = p_id;
  if v.id is null then raise exception 'That item isn''t there. Reload the page.'; end if;
  select name into v_dept from departments where key = v.department;
  if p_retire then
    if not v.retired then
      update supply_items set retired = true, retired_at = now(), retired_by_name = my_name(), updated_at = now() where id = p_id;
    end if;
    return jsonb_build_object('ok', true, 'summary', format('%s: "%s" retired. It''s off the tablets; past requests keep it.', v_dept, v.name));
  end if;
  if v.retired then
    if exists (select 1 from supply_items where department = v.department and not retired and lower(name) = lower(v.name)) then
      raise exception '"%" is already on %''s list.', v.name, v_dept;
    end if;
    update supply_items set retired = false, retired_at = null, retired_by_name = null, updated_by_name = my_name(), updated_at = now(),
                            sort_order = coalesce((select max(sort_order) + 1 from supply_items where department = v.department and not retired), 1)
     where id = p_id;
  end if;
  return jsonb_build_object('ok', true, 'summary', format('%s: "%s" is back on the list.', v_dept, v.name));
end $$;
revoke all on function retire_supply_item(uuid, boolean) from public, anon;
grant execute on function retire_supply_item(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 5. check_supply_lists() — PASS/FAIL, undoes everything it does
-- ---------------------------------------------------------------------

create or replace function check_supply_lists()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  sup_dept text;  mgr uuid;
  v       jsonb;
  v_id    uuid;  v_id2 uuid;  v_req uuid;
  n       int;
  ok      boolean;
  msg     text;
  bad     text;
begin
  select id, (select d.key from departments d where d.key = any(p.departments) and not d.log_only order by d.sort_order limit 1)
    into sup, sup_dept
    from profiles p where role = 'supervisor' and active and not is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by ('sanding' = any(departments)) desc limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;

  if sup is null or mgr is null then
    res := res || check_row(1, 'A supervisor and a manager both have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;

  begin
    -- ---- 1. the parts exist ------------------------------------------------
    ok := exists (select 1 from pg_tables where tablename = 'supply_items' and rowsecurity)
          and to_regprocedure('public.set_supply_item(uuid,text,text,jsonb)') is not null
          and to_regprocedure('public.move_supply_item(uuid,boolean)') is not null
          and to_regprocedure('public.retire_supply_item(uuid,boolean)') is not null;
    res := res || check_row(1, 'Supply lists are set up (the table with security on, and the office''s three changes)', ok,
      'Something is missing. Run supply_lists.sql again from the top.');

    -- ---- 2. the starting lists ---------------------------------------------
    select string_agg(d.name, ', ') into bad from departments d
     where d.key in ('milling', 'sanding', 'full_custom', 'assembly_qc')
       and not exists (select 1 from supply_items i where i.department = d.key);
    res := res || check_row(2, 'The starting lists are loaded (Milling, Sanding, Full Custom, Assembly / QC)', bad is null,
      'No list for: ' || coalesce(bad, '') || '. Run supply_lists.sql again from the top.');

    -- ---- 3. a supervisor can read them ----------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from supply_items where not retired;
      execute 'reset role';
      ok := n = (select count(*) from supply_items where not retired) and n > 0;
      msg := format('A supervisor sees %s items; there are %s.', n, (select count(*) from supply_items where not retired));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A supervisor''s tablet can read the lists', ok, msg);

    -- ---- 4. …but can't change them -------------------------------------------
    select id into v_id from supply_items where not retired order by department, sort_order limit 1;
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := set_supply_item(null, sup_dept, 'CHECK — should be refused', '[]'); ok := false; msg := 'A supervisor added an item.';
      exception when insufficient_privilege then null; end;
      begin v := set_supply_item(v_id, null, 'CHECK — should be refused', '[]'); ok := false; msg := 'A supervisor renamed an item.';
      exception when insufficient_privilege then null; end;
      begin v := move_supply_item(v_id, false); ok := false; msg := 'A supervisor moved an item.';
      exception when insufficient_privilege then null; end;
      begin v := retire_supply_item(v_id, true); ok := false; msg := 'A supervisor retired an item.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A supervisor can''t add, change, move or retire an item', ok, msg);

    -- ---- 5. nobody writes to the table directly --------------------------------
    begin
      execute 'set local role authenticated';
      begin
        insert into supply_items (department, name) values (sup_dept, 'CHECK — direct');
        ok := false; msg := 'A login wrote to supply_items directly.';
      exception when insufficient_privilege then ok := true;
      end;
      begin
        update supply_items set name = name where id = v_id;
        get diagnostics n = row_count;
        if n > 0 then ok := false; msg := 'A login changed supply_items directly.'; end if;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Nobody writes to the lists directly — only through the office''s changes', ok, msg);

    -- ---- 6. someone with no login ----------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      ok := true; msg := null;
      begin
        select count(*) into n from supply_items;
        if n > 0 then ok := false; msg := 'The lists can be read without logging in.'; end if;
      exception when insufficient_privilege then null;
      end;
      begin v := set_supply_item(null, sup_dept, 'CHECK — anon', '[]'); ok := false; msg := 'Someone with no login added an item.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Someone with no login can''t see or change the lists', ok, msg);

    -- ---- 7. the office: add with two sets of choices, change, move --------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := set_supply_item(null, sup_dept, '  CHECK   item ',
             '[{"label": "Size", "options": ["Small", " Large ", ""]}, {"label": "Colour", "options": ["Black"]}]');
      v_id := (v->>'id')::uuid;
      ok := (select name from supply_items where id = v_id) = 'CHECK item'
            and (select choices from supply_items where id = v_id)
                = '[{"label": "Size", "options": ["Small", "Large"]}, {"label": "Colour", "options": ["Black"]}]'::jsonb
            and (select added_by_name from supply_items where id = v_id) is not null;
      msg := 'The new item wasn''t saved tidily (name and choices as typed, spaces trimmed, blanks dropped).';
      if ok then
        v := set_supply_item(v_id, null, 'CHECK item renamed', '[]');
        ok := (select name from supply_items where id = v_id) = 'CHECK item renamed'
              and (select choices from supply_items where id = v_id) = '[]'::jsonb;
        msg := 'Changing the item''s name and choices didn''t take.';
      end if;
      if ok then
        select id into v_id2 from supply_items where department = sup_dept and not retired and id <> v_id
         order by sort_order desc limit 1;
        v := move_supply_item(v_id, true);
        ok := v_id2 is null or (select sort_order from supply_items where id = v_id) < (select sort_order from supply_items where id = v_id2);
        msg := 'Moving the item up didn''t put it above the one before it.';
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'The office can add an item with two sets of choices, change it, and move it', ok, msg);

    -- ---- 8. retiring keeps it; bringing it back works ------------------------------
    begin
      execute 'set local role authenticated';
      v := retire_supply_item(v_id, true);
      ok := exists (select 1 from supply_items where id = v_id and retired and retired_by_name is not null);
      msg := 'Retiring didn''t mark the item retired (or it vanished — nothing should be deleted).';
      if ok then
        v := retire_supply_item(v_id, false);
        ok := exists (select 1 from supply_items where id = v_id and not retired);
        msg := 'Bringing a retired item back didn''t work.';
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Retiring takes an item off the tablets but keeps it; it can be brought back', ok, msg);

    -- ---- 9. bad items are refused -------------------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := set_supply_item(null, sup_dept, '   ', '[]'); ok := false; msg := 'An item with no name was accepted.';
      exception when others then null; end;
      begin v := set_supply_item(null, sup_dept, 'CHECK three', '[{"label":"A","options":["1"]},{"label":"B","options":["1"]},{"label":"C","options":["1"]}]');
        ok := false; msg := 'An item with three sets of choices was accepted.';
      exception when others then null; end;
      begin v := set_supply_item(null, sup_dept, 'CHECK empty', '[{"label":"Size","options":["", " "]}]');
        ok := false; msg := 'A set of choices with no options was accepted.';
      exception when others then null; end;
      begin v := set_supply_item(null, sup_dept, 'check ITEM renamed', '[]'); ok := false; msg := 'The same name was added to a department twice.';
      exception when others then null; end;
      begin v := set_supply_item(null, 'delivery', 'CHECK delivery', '[]'); ok := false; msg := 'Delivery (no Supplies area) got a list item.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Bad items are refused (no name, three sets, empty choices, a duplicate, Delivery)', ok, msg);

    -- ---- 10. a pick reaches the office as its full wording --------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := request_supply(sup_dept, 'CHECK item renamed — Small, Black', 2, null, gen_random_uuid());
      v_req := (v->>'id')::uuid;
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from v_supply_requests where id = v_req and item = 'CHECK item renamed — Small, Black' and qty = 2 and state = 'requested';
      execute 'reset role';
      ok := n = 1;
      msg := 'A request picked from the list didn''t reach the office''s ordering list as sent.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'A pick from the list reaches the office as its full wording, like a typed request', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_supply_lists_undo__';
  exception when others then
    if sqlerrm <> '__check_supply_lists_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_supply_lists() from public, anon, authenticated;

select * from check_supply_lists();
