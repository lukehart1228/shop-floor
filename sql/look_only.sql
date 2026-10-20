-- =====================================================================
-- Shop Floor — look-only departments (20 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it adds (nothing existing changes):
--   1. profiles.look_departments: departments a supervisor can look at
--      but not change. Empty for everyone until set. The tablet page
--      (index.html 2026-10-20.2 or later) shows each one as a tab with the
--      department's Work orders and Recently completed, read only.
--   2. set_look_only(email, departments): sets that list, from the SQL
--      Editor only. '{}' clears it. A department the person already
--      works in is left out (they count it anyway); Delivery can't be
--      looked at this way.
--   3. One read rule: a login can read the count history
--      (progress_events) of a department it looks at, as that department's
--      own login can. Recently completed is built from it. Nothing else
--      about reading changes.
--   4. Nothing about who may count changes. Every count and entry is
--      still checked against the login's own departments (owns_dept), so
--      a looked-at department is refused by the database whatever a page
--      does. check_look_only() proves it as a real login would.
--
-- First use (Luke, 20 Oct): Sam (CNC) looks at Milling:
--     select set_look_only('cnc@pdindy.com', '{milling}');
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('look_only.sql', '{}'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The list on each profile
-- ---------------------------------------------------------------------
alter table profiles add column if not exists look_departments text[] not null default '{}';
comment on column profiles.look_departments is
  'Departments this login can look at on the tablet, read only (look_only.sql). Never used to decide who may change anything.';

-- ---------------------------------------------------------------------
-- 2. Reading a looked-at department's count history
-- ---------------------------------------------------------------------
create or replace function looks_at(dept text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and dept = any(look_departments));
$$;
revoke all on function looks_at(text) from public, anon;
grant execute on function looks_at(text) to authenticated;

drop policy if exists read_events_look on progress_events;
create policy read_events_look on progress_events for select to authenticated
  using (looks_at(department));

-- ---------------------------------------------------------------------
-- 3. set_look_only(): SQL Editor only
-- ---------------------------------------------------------------------
create or replace function set_look_only(p_email text, p_departments text[])
returns text
language plpgsql set search_path = public as $$
declare
  v_id    uuid;
  v_name  text;
  v_own   text[];
  v_bad   text;
  v_keep  text[];
begin
  select u.id, p.full_name, p.departments into v_id, v_name, v_own
    from auth.users u join profiles p on p.id = u.id
   where lower(u.email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'No login with a profile has the address %. Check the spelling, or set the person up first.', p_email;
  end if;

  select string_agg(d, ', ') into v_bad
    from unnest(coalesce(p_departments, '{}')) d
   where not exists (select 1 from departments x where x.key = d and not x.log_only);
  if v_bad is not null then
    raise exception 'Not a department that can be looked at: %. Use the department keys (milling, cnc, sanding, finishing, full_custom, metal, assembly_qc).', v_bad;
  end if;

  select coalesce(array_agg(distinct d order by d), '{}') into v_keep
    from unnest(coalesce(p_departments, '{}')) d
   where not (d = any(coalesce(v_own, '{}')));

  update profiles set look_departments = v_keep where id = v_id;

  return case when cardinality(v_keep) = 0 then format('%s looks at no other department.', v_name)
              else format('%s can now look at %s on the tablet, without changing anything.', v_name,
                          (select string_agg(x.name, ', ' order by x.name) from departments x where x.key = any(v_keep))) end;
end;
$$;
revoke all on function set_look_only(text, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. check_look_only(): the PASS / FAIL check
--
-- Makes a throwaway job and a throwaway login (CNC, looking at Milling),
-- tries things as that login, then undoes everything.
--
--     select * from check_look_only();
-- ---------------------------------------------------------------------
create or replace function check_look_only()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the login
declare
  res jsonb := '[]';
  who uuid := gen_random_uuid();
  v_job uuid; v_wo uuid; v_sheet uuid; p_mill uuid; p_cnc uuid;
  n int; m int; ok boolean; msg text; txt text;
begin
  -- ---- 1: the column is there ------------------------------------------------------------------------
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles' and column_name = 'look_departments';
  res := res || check_row(1, 'Each profile has a look-only list', n = 1, 'Run look_only.sql again.');

  -- ---- 2: nobody signed in can write profiles or set the list ---------------------------------------
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'profiles' and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  select count(*) into m from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'set_look_only' and grantee in ('anon', 'authenticated', 'PUBLIC');
  res := res || check_row(2, 'No login can change a profile or give itself a look-only department; only the SQL Editor can',
                          n = 0 and m = 0, format('%s profile grants, %s on set_look_only. Run look_only.sql again.', n, m));

  begin    -- everything below is undone at the end
    insert into auth.users (id, email) values (who, 'check-look-' || who || '@example.com');
    insert into profiles (id, full_name, role, departments) values (who, 'Look check', 'supervisor', '{cnc}');
    insert into jobs (monday_item_id, project_id, name, is_active)
      values (-999977, 'LOOKCHECK', 'Look-only check - undone automatically', true) returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 3) returning id into v_sheet;
    insert into sheet_progress (sheet_id, department, qty_required) values (v_sheet, 'milling', 3) returning id into p_mill;
    insert into sheet_progress (sheet_id, department, qty_required) values (v_sheet, 'cnc', 3) returning id into p_cnc;
    insert into progress_events (sheet_id, department, qty_from, qty_to, source)
      values (v_sheet, 'milling', 0, 2, 'Tablet'), (v_sheet, 'sanding', 0, 2, 'Tablet');

    -- ---- 3: set_look_only() keeps real departments, drops the person's own, refuses the rest ----------
    ok := true; msg := null;
    begin
      txt := set_look_only('check-look-' || who || '@example.com', '{milling,cnc}');
      select look_departments = '{milling}' into ok from profiles where id = who;
      if not ok then msg := 'it kept ' || (select look_departments::text from profiles where id = who); end if;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm; end;
    n := 0;
    begin perform set_look_only('check-look-' || who || '@example.com', '{delivery}'); exception when others then n := n + 1; end;
    begin perform set_look_only('check-look-' || who || '@example.com', '{nonsense}'); exception when others then n := n + 1; end;
    begin perform set_look_only('nobody-' || who || '@example.com', '{milling}'); exception when others then n := n + 1; end;
    ok := ok and n = 3;
    if n <> 3 then msg := concat_ws(', ', msg, format('%s of 3 bad requests refused', n)); end if;
    res := res || check_row(3, 'set_look_only() adds Milling, leaves out a department the person works in, and refuses Delivery, a made-up department and an unknown address', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', who, 'role', 'authenticated')::text, true);

    -- ---- 4: as that login, Milling's sheet reads exactly as it does for Milling ----------------------
    begin execute 'set local role authenticated';
      select count(*) into n from v_floor_sheets where job_id = v_job and department = 'milling';
      execute 'reset role';
      ok := n = 1; msg := format('%s Milling rows', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'A CNC login that looks at Milling reads Milling''s sheets', ok, msg);

    -- ---- 4b: and Milling's count history (Recently completed), but not another department's ---------
    begin execute 'set local role authenticated';
      select count(*) filter (where department = 'milling'), count(*) filter (where department = 'sanding') into n, m
        from progress_events where sheet_id = v_sheet and source = 'Tablet' and qty_to = 2;
      execute 'reset role';
      ok := n = 1 and m = 0; msg := format('%s Milling and %s Sanding history rows readable', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'It reads Milling''s count history (for Recently completed), and not a department it doesn''t look at', ok, msg);

    -- ---- 5: it can't count Milling, through set_count() or straight at the table ----------------------
    ok := false; msg := 'set_count() saved a Milling count';
    begin execute 'set local role authenticated';
      perform set_count(p_mill, 2); execute 'reset role';
    exception when others then execute 'reset role'; ok := sqlerrm like '%isn''t allowed to change%'; if not ok then msg := 'Refused, but not as expected: ' || sqlerrm; end if; end;
    begin execute 'set local role authenticated';
      update sheet_progress set qty_done = 3 where id = p_mill; execute 'reset role';
    exception when others then execute 'reset role'; end;
    select qty_done into n from sheet_progress where id = p_mill;
    if n <> 0 then ok := false; msg := format('Milling''s count is now %s', n); end if;
    res := res || check_row(6, 'It can''t change a Milling count, through set_count() or straight at the table: the database refuses', ok, msg);

    -- ---- 6: its own department still counts as before -----------------------------------------------
    begin execute 'set local role authenticated';
      perform set_count(p_cnc, 1); execute 'reset role';
      select qty_done = 1 into ok from sheet_progress where id = p_cnc; msg := 'the CNC count didn''t save';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'Its own CNC counts still save as before', ok, msg);

    -- ---- 7: it can't see the list on anyone else's profile, nor change its own -----------------------
    begin execute 'set local role authenticated';
      select count(*) into n from profiles where id <> who;
      begin update profiles set look_departments = '{sanding}' where id = who; exception when others then null; end;
      execute 'reset role';
      select look_departments = '{milling}' into ok from profiles where id = who;
      ok := ok and n = 0; msg := format('%s other profiles readable; own list now %s', n, (select look_departments::text from profiles where id = who));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(8, 'A supervisor sees only its own profile and can''t change its look-only list', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_look_only_undo__';
  exception when others then
    if sqlerrm <> '__check_look_only_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  select string_agg(p.full_name || ' looks at ' ||
           (select string_agg(x.name, ', ' order by x.name) from departments x where x.key = any(p.look_departments)), '; ' order by p.full_name)
    into txt from profiles p where cardinality(p.look_departments) > 0;
  res := res || check_row(9, coalesce(txt, 'Nobody looks at another department yet. For Sam: select set_look_only(''cnc@pdindy.com'', ''{milling}'');'), true, null);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_look_only() from public, anon, authenticated;

select * from check_look_only();
