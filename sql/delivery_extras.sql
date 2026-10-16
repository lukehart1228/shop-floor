-- =====================================================================
-- Shop Floor — extras on Delivery's trips (16 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table. Run this BEFORE the new phone page goes on GitHub.
--
-- WHAT IT DOES
-- A work order's EXTRAS are the small loose items that ship with a job and
-- are easy to leave behind (cabinet shelves, data ports, grommets...). The
-- generator writes them into the upload file, per sheet, with the total
-- to load. Nobody types them into the app. This is the one exception to
-- "never restate work order content" (design: the Delivery work order &
-- extras tab), so they are readable only by the Delivery login and managers.
-- 1. sheet_extras: each sheet's extras (name, quantity), saved by the
--    upload. work_order_extras: which versions listed their extras at all,
--    so the phone can tell "none" from "uploaded before extras existed".
-- 2. upload_work_order() saves them, and refuses a malformed list in plain
--    words (nothing saved, the old version stays current). Extras are not
--    part of a sheet's drawing fingerprint: a change of extras alone keeps
--    every count. Everything else in the function is exactly as before.
-- 3. loadout_extras: how many of each extra each trip loaded, an absolute
--    number, set through set_extra_loaded() by the Delivery login or a
--    manager, only while the trip is open and only from 0 to the quantity.
-- 4. v_sheet_extras, v_extras_listed and v_loadout_extras: what the phone
--    reads. Nobody can read or write the three tables directly.
-- Replaces upload_work_order() from upload_function.sql, so that file now
-- stops if run again. Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('delivery_extras.sql', '{upload_function.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.can_upload_work_orders()') is null then raise exception 'Run upload_function.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_trip_types()') is null then raise exception 'Run trip_types.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_counts_safety()') is null then raise exception 'Run counts_safety.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The tables. Row-level security on with no policy, and every
--    privilege taken from anon and authenticated (select included): only
--    the functions and views below reach them.
-- ---------------------------------------------------------------------

create table if not exists sheet_extras (
  id        uuid primary key default gen_random_uuid(),
  sheet_id  uuid not null references sheets(id) on delete cascade,
  position  int  not null,
  name      text not null check (char_length(name) between 1 and 80),
  qty       int  not null check (qty >= 1),
  unique (sheet_id, position)
);
create index if not exists sheet_extras_sheet_idx on sheet_extras (sheet_id);

create table if not exists work_order_extras (
  work_order_id uuid primary key references work_orders(id) on delete cascade,
  extras        int not null default 0,
  at            timestamptz not null default now()
);

create table if not exists loadout_extras (
  id            uuid primary key default gen_random_uuid(),
  loadout_id    uuid not null references loadouts(id) on delete cascade,
  sheet_number  int  not null,
  name          text not null,
  loaded        int  not null check (loaded >= 0),
  by_id         uuid references profiles(id),
  by_name       text,
  at            timestamptz not null default now(),
  client_id     uuid,
  unique (loadout_id, sheet_number, name)
);

alter table sheet_extras      enable row level security;
alter table work_order_extras enable row level security;
alter table loadout_extras    enable row level security;
revoke all on sheet_extras, work_order_extras, loadout_extras from anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. upload_work_order(payload): as in upload_function.sql, plus each
--    sheet's optional "extras": [{"name": "Data port", "qty": 4}, ...]
--    The lines marked delivery_extras.sql are the only changes.
-- ---------------------------------------------------------------------

create or replace function upload_work_order(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_project     text := nullif(trim(payload->>'project_id'), '');
  v_job         uuid;
  v_placeholder boolean := false;
  v_prev_wo     uuid;
  v_prev_ver    int;
  v_wo          uuid;
  v_version     int;
  s             jsonb;
  d             text;
  v_num         int;
  v_qty         int;
  v_hash        text;
  v_sheet       uuid;
  v_prev_sheet  uuid;
  v_prev_hash   text;
  v_done        int;
  v_sum         int := 0;
  v_valid       text[];
  v_seen        int[] := '{}';
  v_carried     int[] := '{}';
  v_reset       int[] := '{}';
  v_clamped     int[] := '{}';
  v_removed     int[] := '{}';
  v_warnings    text[] := '{}';
  e             jsonb;                 -- delivery_extras.sql: one extra
  v_names       text[];                --   the extras' names on this sheet, to refuse a repeat
  v_listed      boolean := false;      --   did the upload file list extras at all?
  v_extras      int := 0;              --   how many extras were saved
begin
  if not can_upload_work_orders() then
    raise exception 'Only a manager login or the secret key can upload work orders.'
      using errcode = 'insufficient_privilege';
  end if;

  -- ---- check the whole payload before touching anything -----------
  if v_project is null then
    raise exception 'project_id is missing.';
  end if;
  if jsonb_typeof(payload->'sheets') is distinct from 'array'
     or jsonb_array_length(payload->'sheets') = 0 then
    raise exception 'sheets must be a list with at least one sheet.';
  end if;

  select array_agg(key) into v_valid from departments;

  for s in select * from jsonb_array_elements(payload->'sheets') loop
    if jsonb_typeof(s->'sheet_number') is distinct from 'number'
       or (s->>'sheet_number')::numeric <> floor((s->>'sheet_number')::numeric)
       or (s->>'sheet_number')::int < 1 then
      raise exception 'Every sheet needs a whole-number sheet_number of 1 or more (got %).', s->'sheet_number';
    end if;
    v_num := (s->>'sheet_number')::int;
    if v_num = any(v_seen) then
      raise exception 'Sheet % appears twice.', v_num;
    end if;
    v_seen := v_seen || v_num;

    if jsonb_typeof(s->'qty') is distinct from 'number' or (s->>'qty')::int < 1 then
      raise exception 'Sheet %: qty must be 1 or more.', v_num;
    end if;
    if jsonb_typeof(s->'departments') is distinct from 'array'
       or jsonb_array_length(s->'departments') = 0 then
      raise exception 'Sheet %: departments list is missing.', v_num;
    end if;
    -- a typo here would silently hide a sheet from a department, so refuse loudly
    for d in select jsonb_array_elements_text(s->'departments') loop
      if not (d = any(v_valid)) then
        raise exception 'Sheet %: "%" is not a department. Valid: %.',
          v_num, d, array_to_string(v_valid, ', ');
      end if;
    end loop;

    -- delivery_extras.sql: the sheet's extras (small loose items the Delivery
    -- crew ticks off as they load). Optional: a file without them uploads as before.
    if s ? 'extras' and jsonb_typeof(s->'extras') <> 'null' then
      if jsonb_typeof(s->'extras') <> 'array' then
        raise exception 'Sheet %: extras must be a list. Make the upload file again in the generator.', v_num;
      end if;
      if jsonb_array_length(s->'extras') > 50 then
        raise exception 'Sheet %: more than 50 extras. Check the upload file in the generator.', v_num;
      end if;
      v_names := '{}';
      for e in select * from jsonb_array_elements(s->'extras') loop
        if jsonb_typeof(e) is distinct from 'object' or jsonb_typeof(e->'name') is distinct from 'string'
           or trim(e->>'name') = '' then
          raise exception 'Sheet %: an extra has no name. Make the upload file again in the generator.', v_num;
        end if;
        if char_length(trim(e->>'name')) > 80 then
          raise exception 'Sheet %: the extra "%" has a name longer than 80 letters.', v_num, left(trim(e->>'name'), 40);
        end if;
        if jsonb_typeof(e->'qty') is distinct from 'number'
           or (e->>'qty')::numeric <> floor((e->>'qty')::numeric) or (e->>'qty')::numeric < 1 then
          raise exception 'Sheet %: the extra "%" needs a whole-number quantity of 1 or more.', v_num, trim(e->>'name');
        end if;
        if lower(trim(e->>'name')) = any(v_names) then
          raise exception 'Sheet %: the extra "%" is listed twice. Give it once, with the total.', v_num, trim(e->>'name');
        end if;
        v_names := v_names || lower(trim(e->>'name'));
      end loop;
    end if;
  end loop;

  -- ---- the job -------------------------------------------------------
  -- prefer the real Monday row if there's both a placeholder and a real one
  select id into v_job from jobs
   where project_id = v_project
   order by (monday_item_id is not null) desc, created_at
   limit 1;

  if v_job is null then
    insert into jobs (monday_item_id, project_id, name, is_active)
    values (null, v_project, coalesce(nullif(payload->>'project_name',''), v_project), true)
    returning id into v_job;
    v_placeholder := true;
  end if;

  -- ---- new version ----------------------------------------------------
  select id, version into v_prev_wo, v_prev_ver
    from work_orders where job_id = v_job and is_current;

  if v_prev_wo is not null then
    update work_orders set is_current = false, superseded_at = now() where id = v_prev_wo;
  end if;

  v_version := coalesce(v_prev_ver, 0) + 1;
  insert into work_orders (job_id, version, is_current, total_items, source_file)
  values (v_job, v_version, true,
          nullif(payload->>'total_items','')::int,
          nullif(payload->>'source_file',''))
  returning id into v_wo;

  -- ---- sheets and their counts -----------------------------------------
  for s in select * from jsonb_array_elements(payload->'sheets') loop
    v_num := (s->>'sheet_number')::int;
    v_qty := (s->>'qty')::int;
    v_sum := v_sum + v_qty;

    -- The physical spec only. Quantity and the department list are left out
    -- on purpose: going from 3 tables to 4 doesn't undo the 3 already sanded.
    v_hash := md5(jsonb_build_object(
      'item_code',    s->'item_code',
      'species',      s->'species',
      'shape',        s->'shape',
      'width',        s->'width',
      'length',       s->'length',
      'thickness',    s->'thickness',
      'total_height', s->'total_height',
      'top_spec',     coalesce(s->'top_spec',    '{}'::jsonb),
      'base_spec',    coalesce(s->'base_spec',   '{}'::jsonb),
      'finish_spec',  coalesce(s->'finish_spec', '{}'::jsonb),
      'cnc_program',  s->'cnc_program',
      'glue_up_notes',s->'glue_up_notes'
    )::text);

    v_prev_sheet := null; v_prev_hash := null;
    if v_prev_wo is not null then
      select id, spec_hash into v_prev_sheet, v_prev_hash
        from sheets where work_order_id = v_prev_wo and sheet_number = v_num;
    end if;

    insert into sheets (work_order_id, sheet_number, item_code, qty, species, shape,
                        width, length, thickness, total_height,
                        top_spec, base_spec, finish_spec,
                        cnc_program, glue_up_notes, floor_notes, spec_hash)
    values (v_wo, v_num, s->>'item_code', v_qty, s->>'species', s->>'shape',
            s->>'width', s->>'length', s->>'thickness', s->>'total_height',
            coalesce(s->'top_spec',    '{}'::jsonb),
            coalesce(s->'base_spec',   '{}'::jsonb),
            coalesce(s->'finish_spec', '{}'::jsonb),
            s->>'cnc_program', s->>'glue_up_notes', nullif(s->>'floor_notes',''), v_hash)
    returning id into v_sheet;

    -- delivery_extras.sql: save the sheet's extras. They are not part of the
    -- drawing fingerprint (v_hash), so a change of extras alone keeps every count.
    if s ? 'extras' then v_listed := true; end if;
    if jsonb_typeof(s->'extras') = 'array' then
      insert into sheet_extras (sheet_id, position, name, qty)
      select v_sheet, x.ord, trim(x.e->>'name'), (x.e->>'qty')::int
        from jsonb_array_elements(s->'extras') with ordinality as x(e, ord);
      v_extras := v_extras + jsonb_array_length(s->'extras');
    end if;

    for d in select jsonb_array_elements_text(s->'departments') loop
      v_done := 0;
      -- carry work forward only if the drawing it was done to still applies
      if v_prev_sheet is not null and v_prev_hash = v_hash then
        select least(qty_done, v_qty) into v_done
          from sheet_progress where sheet_id = v_prev_sheet and department = d;
        v_done := coalesce(v_done, 0);
      end if;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      values (v_sheet, d, v_qty, v_done);
    end loop;

    if v_prev_sheet is not null then
      if v_prev_hash = v_hash then
        v_carried := v_carried || v_num;
        if exists (select 1 from sheet_progress
                    where sheet_id = v_prev_sheet and qty_done > v_qty) then
          v_clamped := v_clamped || v_num;
        end if;
      else
        v_reset := v_reset || v_num;
      end if;
    end if;
  end loop;

  -- delivery_extras.sql: remember that this version listed its extras (even none),
  -- so the phone can tell "no extras" from "uploaded before extras existed"
  if v_listed then
    insert into work_order_extras (work_order_id, extras) values (v_wo, v_extras)
    on conflict (work_order_id) do nothing;
  end if;

  -- sheets on the old version that aren't on the new one
  if v_prev_wo is not null then
    select coalesce(array_agg(sheet_number order by sheet_number), '{}') into v_removed
      from sheets
     where work_order_id = v_prev_wo
       and not (sheet_number = any(v_seen));
  end if;

  -- ---- warnings, not errors --------------------------------------------
  if nullif(payload->>'total_items','') is not null
     and (payload->>'total_items')::int <> v_sum then
    v_warnings := v_warnings || format(
      'The sheets add up to %s pieces, but the work order says %s in total.',
      v_sum, payload->>'total_items');
  end if;
  if v_placeholder then
    v_warnings := v_warnings || format(
      '%s isn''t in the Monday sync yet. Saved anyway; it links up when Monday catches up.',
      v_project);
  end if;

  return jsonb_build_object(
    'ok',                 true,
    'project_id',         v_project,
    'job_id',             v_job,
    'work_order_id',      v_wo,
    'version',            v_version,
    'file_folder',        format('%s/v%s', v_project, v_version),
    'sheets',             jsonb_array_length(payload->'sheets'),
    'pieces',             v_sum,
    'carried_forward',    to_jsonb(v_carried),
    'reset_by_change',    to_jsonb(v_reset),
    'clamped_to_new_qty', to_jsonb(v_clamped),
    'removed',            to_jsonb(v_removed),
    'warnings',           to_jsonb(v_warnings),
    'extras',             v_extras,
    'extras_listed',      v_listed
  );
end;
$$;

revoke all on function upload_work_order(jsonb) from public, anon;
grant execute on function upload_work_order(jsonb) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 3. What the phone reads. Not security_invoker: these views read the
--    locked tables as their owner, and filter themselves: the Delivery
--    login or a manager, in their own lane (sees_lane), real jobs and test
--    jobs only (as v_loadout_sheets). Anyone else gets no rows.
-- ---------------------------------------------------------------------

create or replace view v_sheet_extras as
select w.job_id, w.id as work_order_id, s.sheet_number, e.position, e.name, e.qty
from work_orders w
join jobs j         on j.id = w.job_id
join sheets s       on s.work_order_id = w.id
join sheet_extras e on e.sheet_id = s.id
where w.is_current
  and (j.monday_item_id is not null or j.is_test)
  and sees_lane(j.is_test)
  and owns_dept('delivery');

create or replace view v_extras_listed as
select w.job_id, w.id as work_order_id, x.extras
from work_orders w
join jobs j              on j.id = w.job_id
join work_order_extras x on x.work_order_id = w.id
where w.is_current
  and (j.monday_item_id is not null or j.is_test)
  and sees_lane(j.is_test)
  and owns_dept('delivery');

create or replace view v_loadout_extras as
select l.id as loadout_id, l.client_id, l.job_id, x.sheet_number, x.name, x.loaded, x.by_name, x.at,
       l.finished_at, l.completed_at
from loadout_extras x
join loadouts l on l.id = x.loadout_id
where l.voided_at is null
  and sees_lane(l.is_test)
  and owns_dept('delivery');

revoke all on v_sheet_extras, v_extras_listed, v_loadout_extras from public, anon, authenticated;
grant select on v_sheet_extras, v_extras_listed, v_loadout_extras to authenticated;


-- ---------------------------------------------------------------------
-- 4. set_extra_loaded(trip, sheet, name, loaded, client_id)
--    trip is its id or the phone's own id for it; loaded is the number on
--    the truck now (absolute, never an increment), 0 to the quantity.
--    Only while the trip is open (not delivered, not entered by mistake),
--    and only for an extra on the job's current work order.
-- ---------------------------------------------------------------------

drop function if exists set_extra_loaded(uuid, int, text, int, uuid);
create function set_extra_loaded(p_loadout uuid, p_sheet int, p_name text, p_loaded int, p_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_qty int; v_name text := trim(coalesce(p_name, ''));
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout limit 1;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That trip isn''t there.'; end if;
  v_job := floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That trip was marked entered by mistake, so its extras can''t change.'; end if;
  if v.completed_at is not null then raise exception '% is already delivered, so the extras on that trip can''t change now.', v_job.project_id; end if;
  select e.qty, e.name into v_qty, v_name
    from work_orders w
    join sheets s       on s.work_order_id = w.id
    join sheet_extras e on e.sheet_id = s.id
   where w.job_id = v.job_id and w.is_current and s.sheet_number = p_sheet and lower(e.name) = lower(v_name);
  if v_qty is null then
    raise exception '% sheet %: "%" isn''t on the current work order. Open the trip again to see its extras now.', v_job.project_id, p_sheet, trim(coalesce(p_name, ''));
  end if;
  if p_loaded is null or p_loaded < 0 or p_loaded > v_qty then
    raise exception 'Sheet %, %: loaded must be from 0 to %.', p_sheet, v_name, v_qty;
  end if;
  insert into loadout_extras (loadout_id, sheet_number, name, loaded, by_id, by_name, at, client_id)
  values (v.id, p_sheet, v_name, p_loaded, auth.uid(), my_name(), now(), p_client_id)
  on conflict (loadout_id, sheet_number, name) do update
    set loaded = excluded.loaded, by_id = excluded.by_id, by_name = excluded.by_name, at = excluded.at, client_id = excluded.client_id;
  return jsonb_build_object('ok', true, 'sheet', p_sheet, 'name', v_name, 'loaded', p_loaded, 'of', v_qty);
end $$;
revoke all on function set_extra_loaded(uuid, int, text, int, uuid) from public, anon;
grant execute on function set_extra_loaded(uuid, int, text, int, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 5. check_delivery_extras(): the PASS/FAIL table. Everything it does is
--    undone at the end.
-- ---------------------------------------------------------------------

create or replace function check_delivery_extras()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; dlv uuid; sup uuid; as_mgr text; as_dlv text; as_sup text;
  j uuid; jt uuid; lo uuid; lo2 uuid; r jsonb; ok boolean; msg text; n int; m int; k text; v_ver int; bad jsonb; sp uuid;
  p1 jsonb := '{"project_id": "EXTRAS-CHK", "total_items": 3, "sheets": [
      {"sheet_number": 1, "item_code": "EXC-1", "qty": 2, "width": "36", "length": "72", "departments": ["sanding"],
       "extras": [{"name": "Data port", "qty": 4}, {"name": "Cabinet shelf", "qty": 8}]},
      {"sheet_number": 2, "item_code": "EXC-2", "qty": 1, "width": "30", "length": "60", "departments": ["sanding"], "extras": []}]}';
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) limit 1), mgr) into dlv;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments)) limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_dlv := json_build_object('sub', dlv, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', coalesce(sup, mgr), 'role', 'authenticated')::text;

  -- ---- 1. locked ------------------------------------------------------------------------------
  ok := true; msg := '';
  foreach k in array array['sheet_extras', 'work_order_extras', 'loadout_extras'] loop
    if has_table_privilege('anon', 'public.' || k, 'select,insert,update,delete,truncate')
       or has_table_privilege('authenticated', 'public.' || k, 'select,insert,update,delete,truncate')
       or not (select relrowsecurity from pg_class where oid = ('public.' || k)::regclass) then
      ok := false; msg := msg || k || ' is readable or writable by a login. ';
    end if;
  end loop;
  foreach k in array array['v_sheet_extras', 'v_extras_listed', 'v_loadout_extras'] loop
    if has_table_privilege('anon', 'public.' || k, 'select') or has_table_privilege('authenticated', 'public.' || k, 'insert,update,delete,truncate') then
      ok := false; msg := msg || k || ' is open to the wrong role. ';
    end if;
  end loop;
  if has_function_privilege('anon', 'public.set_extra_loaded(uuid,integer,text,integer,uuid)', 'execute')
     or has_function_privilege('anon', 'public.upload_work_order(jsonb)', 'execute') then
    ok := false; msg := msg || 'A function is open to no-login callers. ';
  end if;
  select count(*) into n from pg_proc where proname in ('upload_work_order', 'set_extra_loaded') and pronamespace = 'public'::regnamespace;
  if n <> 2 then ok := false; msg := msg || format('%s functions named upload_work_order or set_extra_loaded (expected one of each). ', n); end if;
  res := res || check_row(1, 'Nobody can read or write the extras tables directly; no-login callers reach nothing', ok, msg || 'Do not go further; bring this to Claude.');

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999971, 'EXTRAS-CHK', 'Extras check - undone automatically', true, 'In Production', local_today()) returning id into j;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test)
      values (null, 'TEST-EXTRAS-CHK', 'Extras check - undone automatically', true, 'In Production', local_today(), true) returning id into jt;

    -- ---- 2. an upload with extras stores them -------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := upload_work_order(p1);
      execute 'reset role';
      select count(*) into n from v_sheet_extras_all_for_check(j);
      select count(*) into m from work_order_extras x join work_orders w on w.id = x.work_order_id where w.job_id = j and w.is_current and x.extras = 2;
      ok := (r->>'extras')::int = 2 and (r->>'extras_listed')::boolean and n = 2 and m = 1
            and exists (select 1 from v_sheet_extras_all_for_check(j) where sheet_number = 1 and name = 'Data port' and qty = 4 and position = 1)
            and exists (select 1 from v_sheet_extras_all_for_check(j) where sheet_number = 1 and name = 'Cabinet shelf' and qty = 8 and position = 2);
      msg := format('The upload said %s extras (listed: %s); %s saved on the current version (expected 2: Data port 4, Cabinet shelf 8); listed row: %s.', r->>'extras', r->>'extras_listed', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A manager uploads a work order with extras; each sheet''s extras are saved with their quantity', ok, msg);

    -- ---- 3. a malformed list is refused and nothing changes ------------------------------------
    ok := true; msg := '';
    select version into v_ver from work_orders where job_id = j and is_current;
    foreach bad in array array[
        '"two data ports"'::jsonb, '[{"name": "", "qty": 1}]', '[{"name": "Data port", "qty": 0}]', '[{"name": "Data port", "qty": 1.5}]',
        '[{"name": "Data port", "qty": 1}, {"name": "data port", "qty": 2}]', '[{"qty": 2}]',
        (select jsonb_agg(jsonb_build_object('name', 'Item ' || g, 'qty', 1)) from generate_series(1, 51) g),
        jsonb_build_array(jsonb_build_object('name', repeat('x', 81), 'qty', 1))] loop
      begin
        perform set_config('request.jwt.claims', as_mgr, true);
        execute 'set local role authenticated';
        perform upload_work_order(jsonb_set(p1, '{sheets,0,extras}', bad));
        execute 'reset role';
        ok := false; msg := msg || 'Accepted extras ' || left(bad::text, 50) || '. ';
      exception when others then execute 'reset role';
        if sqlerrm not like 'Sheet 1:%' then ok := false; msg := msg || 'Refused, but not in plain words: ' || sqlerrm || '. '; end if;
      end;
    end loop;
    if (select version from work_orders where job_id = j and is_current) <> v_ver then ok := false; msg := msg || 'A refused upload changed the current version. '; end if;
    res := res || check_row(3, 'A bad extras list (not a list, no name, a quantity of 0 or 1.5, a repeat, over 50, a long name) is refused in plain words and nothing changes', ok, msg);

    -- ---- 4. a change of extras alone keeps the counts -------------------------------------------
    begin
      update sheet_progress sp2 set qty_done = 2 from sheets s, work_orders w
       where sp2.sheet_id = s.id and s.work_order_id = w.id and w.job_id = j and w.is_current and s.sheet_number = 1 and sp2.department = 'sanding';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := upload_work_order(jsonb_set(p1, '{sheets,0,extras}', '[{"name": "Data port", "qty": 6}, {"name": "Cabinet shelf", "qty": 8}]'));
      execute 'reset role';
      select sp2.qty_done into n from sheet_progress sp2 join sheets s on s.id = sp2.sheet_id join work_orders w on w.id = s.work_order_id
       where w.job_id = j and w.is_current and s.sheet_number = 1 and sp2.department = 'sanding';
      select qty into m from v_sheet_extras_all_for_check(j) where sheet_number = 1 and name = 'Data port';
      ok := n = 2 and m = 6 and (r->'carried_forward') @> '[1]';
      msg := format('After a change order that only changed the data ports to 6: sanding count %s (expected 2), data ports %s (expected 6).', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A change order that only changes the extras keeps every count, and the new quantities take over', ok, msg);

    -- ---- 5. who reads them ---------------------------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform upload_work_order(jsonb_set(p1, '{project_id}', '"TEST-EXTRAS-CHK"'));
      execute 'reset role';
      ok := true; msg := '';
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      select count(*) into n from v_sheet_extras where job_id = j;
      select count(*) into m from v_sheet_extras where job_id = jt;
      execute 'reset role';
      if n <> 2 then ok := false; msg := msg || format('Delivery sees %s of the job''s extras (expected 2). ', n); end if;
      if dlv <> mgr and m <> 0 then ok := false; msg := msg || format('Delivery sees %s extras on a test job (expected 0). ', m); end if;   -- managers see both lanes
      if sup is not null then
        perform set_config('request.jwt.claims', as_sup, true);
        execute 'set local role authenticated';
        select count(*) into n from v_sheet_extras;
        select count(*) into m from v_extras_listed;
        execute 'reset role';
        if n + m <> 0 then ok := false; msg := msg || format('A supervisor without Delivery sees %s extras rows (expected 0). ', n + m); end if;
      end if;
      perform set_config('request.jwt.claims', '', true);
      begin
        execute 'set local role anon';
        select count(*) into n from v_sheet_extras;
        execute 'reset role';
        ok := false; msg := msg || 'A no-login caller read the extras. ';
      exception when insufficient_privilege then execute 'reset role';
      end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Only the Delivery login and managers see extras, in their own lane: not other supervisors, not the TV link, not anyone without a login', ok, msg);

    -- ---- 6. ticking them off ---------------------------------------------------------------------
    begin
      insert into loadouts (job_id, kind, client_id) values (j, 'delivery', gen_random_uuid()) returning id into lo;
      ok := true; msg := '';
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      perform set_extra_loaded(lo, 1, 'Data port', 3, gen_random_uuid());
      perform set_extra_loaded((select client_id from loadouts where id = lo), 1, 'data port', 6, gen_random_uuid());
      select loaded into n from v_loadout_extras where loadout_id = lo and sheet_number = 1 and name = 'Data port';
      execute 'reset role';
      if n is distinct from 6 then ok := false; msg := msg || format('After 3 then 6 the trip shows %s data ports loaded (expected 6: absolute, not added). ', n); end if;
      foreach k in array array['7', '-1', 'Grommet', 'sheet2'] loop
        begin
          perform set_config('request.jwt.claims', as_dlv, true);
          execute 'set local role authenticated';
          if k = 'Grommet' then perform set_extra_loaded(lo, 1, 'Grommet', 1);
          elsif k = 'sheet2' then perform set_extra_loaded(lo, 2, 'Data port', 1);
          else perform set_extra_loaded(lo, 1, 'Data port', k::int); end if;
          execute 'reset role';
          ok := false; msg := msg || 'Accepted ' || k || '. ';
        exception when others then execute 'reset role';
        end;
      end loop;
      if sup is not null then
        begin
          perform set_config('request.jwt.claims', as_sup, true);
          execute 'set local role authenticated';
          perform set_extra_loaded(lo, 1, 'Data port', 1);
          execute 'reset role';
          ok := false; msg := msg || 'A supervisor without Delivery set an extra. ';
        exception when others then execute 'reset role';
        end;
      end if;
      begin
        perform set_config('request.jwt.claims', as_dlv, true);
        execute 'set local role authenticated';
        insert into loadout_extras (loadout_id, sheet_number, name, loaded) values (lo, 1, 'Data port', 1);
        execute 'reset role';
        ok := false; msg := msg || 'Delivery wrote the table directly. ';
      exception when others then execute 'reset role';
      end;
      insert into loadouts (job_id, kind, client_id, voided_at) values (j, 'delivery', gen_random_uuid(), now()) returning id into lo2;
      update loadouts set completed_at = now() where id = lo;
      foreach sp in array array[lo, lo2] loop
        begin
          perform set_config('request.jwt.claims', as_dlv, true);
          execute 'set local role authenticated';
          perform set_extra_loaded(sp, 1, 'Cabinet shelf', 1);
          execute 'reset role';
          ok := false; msg := msg || 'Set an extra on a delivered or mistaken trip. ';
        exception when others then execute 'reset role';
        end;
      end loop;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Delivery sets how many of an extra are loaded (the number itself, 0 to the quantity); anything else, anyone else, a delivered or mistaken trip, or a direct write is refused', ok, msg);

    -- ---- 7. a file without extras still uploads ---------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := upload_work_order(p1 #- '{sheets,0,extras}' #- '{sheets,1,extras}');
      execute 'reset role';
      select count(*) into n from v_sheet_extras_all_for_check(j);
      select count(*) into m from work_order_extras x join work_orders w on w.id = x.work_order_id where w.job_id = j and w.is_current;
      ok := (r->>'ok')::boolean and not (r->>'extras_listed')::boolean and n = 0 and m = 0;
      msg := format('An upload file with no extras: saved %s, listed %s, %s extras on the new version (expected 0), listed rows %s (expected 0).', r->>'ok', r->>'extras_listed', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'An upload file from before extras uploads exactly as it did, and is marked as not listing them', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_delivery_extras_undo__';
  exception when others then
    if sqlerrm <> '__check_delivery_extras_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_delivery_extras() from public, anon, authenticated;

-- the check's own view of a job's current extras, whoever runs it (never granted to a login)
create or replace function v_sheet_extras_all_for_check(p_job uuid)
returns table (sheet_number int, "position" int, name text, qty int)
language sql stable set search_path = public as $$
  select s.sheet_number, e.position, e.name, e.qty
    from work_orders w join sheets s on s.work_order_id = w.id join sheet_extras e on e.sheet_id = s.id
   where w.job_id = p_job and w.is_current;
$$;
revoke all on function v_sheet_extras_all_for_check(uuid) from public, anon, authenticated;

select * from check_delivery_extras();
