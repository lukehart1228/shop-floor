-- =====================================================================
-- Shop Floor — the test lane (trial build, step 2)
--
-- HOW TO USE: run office.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. Safe to run
-- more than once. Then follow the walkthrough to create the Test
-- Supervisor login, and finish with:
--     select * from check_test_lane();
--
-- What it adds:
--   1. Test logins — a profile marked is_test
--   2. make_test_job('PROJ-00418') — copies a real job's current work
--      order into TEST-00418: same sheets, same page images, zero counts.
--      retire_test_job('TEST-00418') takes one off the tablets.
--   3. The lanes can't cross, and the database enforces it:
--        * a test login changes counts only on test jobs
--        * everyone else changes counts only on real jobs
--        * real supervisors can't see test jobs at all
--        * test jobs never reach Monday, the handoff list, or catch-up
--   4. set_person() — create or change a profile by email, for the Test
--      Supervisor now and each supervisor as their department goes live
--   5. v_uploaded_jobs — every job with a work order, for the office
--   6. check_test_lane() — the PASS / FAIL check
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('test_lane.sql'); end if;
end $$;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'jobs' and column_name = 'is_test') then
    raise exception 'Run office.sql first (step 1). This file builds on it.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Test logins
-- ---------------------------------------------------------------------

alter table profiles add column if not exists is_test boolean not null default false;

-- is the person signed in a test login?
create or replace function am_test() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_test from profiles where id = auth.uid()), false);
$$;

-- does this sheet belong to the same lane as the person signed in?
create or replace function lane_ok(p_sheet uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select j.is_test = am_test()
      from sheets s
      join work_orders w on w.id = s.work_order_id
      join jobs j        on j.id = w.job_id
     where s.id = p_sheet), false);
$$;

revoke all on function am_test() from public, anon;
revoke all on function lane_ok(uuid) from public, anon;
grant execute on function am_test() to authenticated;
grant execute on function lane_ok(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 2. Security: the lanes can't cross
-- ---------------------------------------------------------------------

-- Test jobs are invisible to real supervisors. Managers and test logins see them.
drop policy if exists read_jobs on jobs;
create policy read_jobs on jobs for select to authenticated
  using (not is_test or am_test() or my_role() in ('manager', 'admin'));

-- Change counts only in your own departments AND only in your own lane.
drop policy if exists write_progress on sheet_progress;
create policy write_progress on sheet_progress for update to authenticated
  using      (owns_dept(department) and lane_ok(sheet_id))
  with check (owns_dept(department) and lane_ok(sheet_id));


-- ---------------------------------------------------------------------
-- 3. What the tablet reads — now lane-aware
--
-- A test login sees only test jobs; everyone else sees only real ones.
-- Test jobs have no Monday row, so they're let through on is_test instead.
-- ---------------------------------------------------------------------

drop view if exists v_floor_sheets;
create view v_floor_sheets with (security_invoker = true) as
select
  sp.id                            as progress_id,
  sp.department,
  sp.qty_done,
  sp.qty_required,
  sp.state,
  sp.updated_at                    as progress_updated_at,
  s.id                             as sheet_id,
  s.sheet_number,
  s.item_code,
  s.species,
  s.shape,
  s.width,
  s.length,
  s.thickness,
  s.total_height,
  s.png_path,
  s.pdf_path,
  (s.pdf_uploaded_at is not null)  as pages_ready,
  w.id                             as work_order_id,
  w.version,
  j.id                             as job_id,
  j.project_id,
  j.name                           as job_name,
  j.delivery_date,
  j.materials_ordered,
  j.is_test
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id
                  and j.is_active
                  and (j.monday_item_id is not null or j.is_test)
where j.is_test = am_test();

revoke all on v_floor_sheets from anon;
grant select on v_floor_sheets to authenticated;


-- ---------------------------------------------------------------------
-- 4. Every job with a work order — for the office's test-job and
--    catch-up screens
-- ---------------------------------------------------------------------

drop view if exists v_uploaded_jobs;
create view v_uploaded_jobs with (security_invoker = true) as
select
  j.id                              as job_id,
  j.project_id,
  j.name                            as job_name,
  j.delivery_date,
  j.phase,
  j.is_active,
  j.is_test,
  (j.monday_item_id is not null)    as linked_to_monday,
  j.monday_stages,
  w.version,
  w.created_at                      as uploaded_at,
  (select count(*)           from sheets s where s.work_order_id = w.id) as sheets,
  (select coalesce(sum(qty),0) from sheets s where s.work_order_id = w.id) as pieces
from jobs j
join work_orders w on w.job_id = j.id and w.is_current;

revoke all on v_uploaded_jobs from anon;
grant select on v_uploaded_jobs to authenticated;


-- ---------------------------------------------------------------------
-- 5. make_test_job / retire_test_job
-- ---------------------------------------------------------------------

create or replace function is_manager_or_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select session_user in ('postgres', 'supabase_admin')          -- the SQL Editor
      or coalesce(my_role()::text, '') in ('manager', 'admin');
$$;
revoke all on function is_manager_or_editor() from public, anon;
grant execute on function is_manager_or_editor() to authenticated;

create or replace function make_test_job(p_project text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_src     jobs;
  v_wo      work_orders;
  v_base    text;
  v_name    text;
  v_n       int := 1;
  v_job     uuid;
  v_new_wo  uuid;
  s         sheets;
  v_sheet   uuid;
  n_sheets  int := 0;
  n_pieces  int := 0;
begin
  if not is_manager_or_editor() then
    raise exception 'Only a manager can make test jobs.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_src from jobs where upper(project_id) = upper(trim(p_project)) and not is_test;
  if v_src.id is null then
    raise exception 'There''s no real job called % to copy.', p_project;
  end if;
  select * into v_wo from work_orders where job_id = v_src.id and is_current;
  if v_wo.id is null then
    raise exception '% has no work order uploaded yet, so there''s nothing to copy. Upload it first.', v_src.project_id;
  end if;

  -- TEST-00418, then TEST-00418-2, -3 ... if earlier copies exist (retired ones included)
  v_base := 'TEST-' || regexp_replace(v_src.project_id, '^PROJ-', '', 'i');
  v_name := v_base;
  while exists (select 1 from jobs where project_id = v_name) loop
    v_n := v_n + 1;
    v_name := v_base || '-' || v_n;
  end loop;

  insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, is_test)
  values (null, v_name, v_src.name, v_src.delivery_date, 'In Production', true, v_src.materials_ordered, true)
  returning id into v_job;

  insert into work_orders (job_id, version, is_current, total_items, source_file)
  values (v_job, 1, true, v_wo.total_items, v_wo.source_file)
  returning id into v_new_wo;

  for s in select * from sheets where work_order_id = v_wo.id order by sheet_number loop
    insert into sheets (work_order_id, sheet_number, item_code, qty, species, shape, width, length, thickness,
                        total_height, top_spec, base_spec, finish_spec, cnc_program, glue_up_notes, floor_notes,
                        spec_hash, pdf_path, pdf_uploaded_at, png_path)
    values (v_new_wo, s.sheet_number, s.item_code, s.qty, s.species, s.shape, s.width, s.length, s.thickness,
            s.total_height, s.top_spec, s.base_spec, s.finish_spec, s.cnc_program, s.glue_up_notes, s.floor_notes,
            s.spec_hash, s.pdf_path, s.pdf_uploaded_at, s.png_path)   -- the same page files: read, never changed
    returning id into v_sheet;

    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
    select v_sheet, sp.department, sp.qty_required, 0
      from sheet_progress sp where sp.sheet_id = s.id;

    n_sheets := n_sheets + 1;
    n_pieces := n_pieces + s.qty;
  end loop;

  return jsonb_build_object('ok', true, 'project_id', v_name, 'copied_from', v_src.project_id,
                            'sheets', n_sheets, 'pieces', n_pieces,
                            'summary', format('Made %s — a copy of %s with %s sheets and %s pieces, every count at zero.',
                                              v_name, v_src.project_id, n_sheets, n_pieces));
end;
$$;

create or replace function retire_test_job(p_project text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager_or_editor() then
    raise exception 'Only a manager can retire test jobs.' using errcode = 'insufficient_privilege';
  end if;
  update jobs set is_active = false, updated_at = now()
   where upper(project_id) = upper(trim(p_project)) and is_test;
  if not found then
    raise exception '% isn''t a test job. Only test jobs can be retired here.', p_project;
  end if;
  return format('%s is off the tablets. Its history is kept.', upper(trim(p_project)));
end;
$$;

revoke all on function make_test_job(text)   from public, anon;
revoke all on function retire_test_job(text) from public, anon;
grant execute on function make_test_job(text)   to authenticated;
grant execute on function retire_test_job(text) to authenticated;


-- ---------------------------------------------------------------------
-- 6. set_person — create or change a profile by email
--
-- First create the login in Supabase (Authentication → Users → Add user,
-- with Auto Confirm ticked). Then, in the SQL Editor:
--   select set_person('test-login@pdindy.com', 'Test Supervisor', 'supervisor',
--                     '{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc}', true);
--   select set_person('someone@pdindy.com', 'Jim W', 'supervisor', '{finishing}');
-- ---------------------------------------------------------------------

create or replace function set_person(p_email text, p_name text, p_role text,
                                      p_departments text[] default '{}', p_is_test boolean default false)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  d      text;
begin
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'No login with the email %. Create it first: Authentication → Users → Add user (tick Auto Confirm).', p_email;
  end if;
  if p_role not in ('supervisor', 'manager', 'admin') then
    raise exception 'The role must be supervisor, manager or admin (got %).', p_role;
  end if;
  foreach d in array coalesce(p_departments, '{}') loop
    if not exists (select 1 from departments where key = d) then
      raise exception '"%" is not a department. Valid: %.', d, (select string_agg(key, ', ' order by sort_order) from departments);
    end if;
  end loop;
  if p_role = 'supervisor' and coalesce(array_length(p_departments, 1), 0) = 0 then
    raise exception 'A supervisor needs at least one department.';
  end if;
  if p_is_test and p_role <> 'supervisor' then
    raise exception 'A test login must be a supervisor, so it hits the same walls a real supervisor would.';
  end if;

  insert into profiles (id, full_name, role, departments, is_test, active)
  values (v_id, trim(p_name), p_role::app_role, coalesce(p_departments, '{}'), p_is_test, true)
  on conflict (id) do update
     set full_name = excluded.full_name, role = excluded.role, departments = excluded.departments,
         is_test = excluded.is_test, active = true, updated_at = now();

  return format('%s is set up: %s%s%s.', trim(p_name), p_role,
                case when coalesce(array_length(p_departments, 1), 0) > 0 then ' for ' || array_to_string(p_departments, ', ') else '' end,
                case when p_is_test then ' — a TEST login, which sees and changes test jobs only' else '' end);
end;
$$;
revoke all on function set_person(text, text, text, text[], boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 7. check_test_lane() — the PASS / FAIL check
--
-- Builds a throwaway real job and a test copy of it, tries things as the
-- Test Supervisor and as a real supervisor, then removes both. Nothing
-- real is touched.
--
--     select * from check_test_lane();
-- ---------------------------------------------------------------------

create or replace function check_test_lane()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test
declare
  tst     uuid;
  sup     uuid;
  sup_dept text;
  v_real  uuid;
  v_wo    uuid;
  s1      uuid;
  v_test  uuid;
  v_copy  jsonb;
  n       int;
  ok      boolean;
  msg     text;
  v_all   text[] := array['milling','cnc','sanding','finishing','full_custom','metal','assembly_qc'];
begin
  -- clear anything left by an interrupted earlier run
  delete from jobs where project_id like 'TEST-LANECHECK%' or project_id = 'LANECHECK';

  step := 1; check_name := 'A Test Supervisor login exists and owns all seven departments';
  select id into tst from profiles where is_test and role = 'supervisor' and active and departments @> v_all limit 1;
  if tst is null then
    result := 'FAIL';
    if_it_failed := 'Create the login in Authentication → Users, then run: select set_person(''<its email>'', ''Test Supervisor'', ''supervisor'', ''{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc}'', true);';
    return next; return;
  end if;
  result := 'PASS'; if_it_failed := null; return next;

  select id, departments[1] into sup, sup_dept from profiles
   where role = 'supervisor' and active and not is_test and array_length(departments, 1) > 0 limit 1;

  -- a throwaway real job: two departments on one sheet, one of them the real supervisor's
  insert into jobs (monday_item_id, project_id, name, is_active)
    values (-999998, 'LANECHECK', 'Lane check - safe to delete', true) returning id into v_real;
  insert into work_orders (job_id) values (v_real) returning id into v_wo;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 3) returning id into s1;
  insert into sheet_progress (sheet_id, department, qty_required)
    select s1, d, 3 from unnest(array_remove(array['milling', coalesce(sup_dept,'sanding')], null)) d
    on conflict do nothing;

  step := 2; check_name := 'make_test_job copies a job with every count at zero';
  begin
    v_copy := make_test_job('LANECHECK');
    select id into v_test from jobs where project_id = v_copy->>'project_id';
    select count(*) into n from sheet_progress sp join sheets s on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id where w.job_id = v_test and sp.qty_done = 0;
    ok := v_test is not null and (select is_test from jobs where id = v_test) and n >= 1;
    msg := case when ok then null else 'The copy is missing, not marked as a test job, or has counts.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;
  if not ok then delete from jobs where id in (v_real, v_test); return; end if;

  -- ---- as the Test Supervisor ----
  perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);

  step := 3; check_name := 'The Test Supervisor can count on a test job';
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_done = 2
     where department = 'milling' and sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test);
    get diagnostics n = row_count;
    execute 'reset role';
    ok := (n = 1); msg := case when ok then null else 'The count wasn''t saved.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 4; check_name := 'That count is recorded under the Test Supervisor';
  select exists (select 1 from progress_events e join sheets s on s.id = e.sheet_id join work_orders w on w.id = s.work_order_id
                  where w.job_id = v_test and e.qty_to = 2 and e.actor = tst) into ok;
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'History is missing, or has the wrong name on it.' end; return next;

  step := 5; check_name := 'The Test Supervisor cannot change a real job';
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_done = 3 where sheet_id = s1 and department = 'milling';
    get diagnostics n = row_count;
    execute 'reset role';
    ok := (n = 0); msg := case when ok then null else 'A test login changed a REAL count. Do not go further.' end;
  exception when insufficient_privilege then ok := true; msg := null;
  when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 6; check_name := 'The Test Supervisor''s tablet shows test jobs only';
  begin
    execute 'set local role authenticated';
    select count(*) filter (where not is_test) into n from v_floor_sheets;
    execute 'reset role';
    ok := (n = 0); msg := case when ok then null else n || ' real sheets showed on the test tablet.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- ---- as a real supervisor ----
  step := 7; check_name := 'A real supervisor cannot see test jobs';
  if sup is null then
    result := 'FAIL'; if_it_failed := 'No real supervisor login exists to test with.'; return next;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select (select count(*) from jobs where is_test) + (select count(*) from v_floor_sheets where is_test) into n;
      execute 'reset role';
      ok := (n = 0); msg := case when ok then null else 'A real supervisor can see test jobs.' end;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

    step := 8; check_name := 'A real supervisor cannot change a test job';
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 1
       where sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test);
      get diagnostics n = row_count;
      execute 'reset role';
      ok := (n = 0); msg := case when ok then null else 'A real supervisor changed a test count.' end;
    exception when insufficient_privilege then ok := true; msg := null;
    when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

    step := 9; check_name := 'A real supervisor can still count on a real job';
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 1 where sheet_id = s1 and department = sup_dept;
      get diagnostics n = row_count;
      execute 'reset role';
      ok := (n = 1); msg := case when ok then null else 'The real supervisor''s own count was refused. The tablet would stop working.' end;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;
  end if;

  perform set_config('request.jwt.claims', '', true);

  step := 10; check_name := 'Test jobs are left out of the handoff list and the Monday check';
  select count(*) into n from jobs where is_test and monday_item_id is not null;
  ok := n = 0 and not exists (select 1 from check_monday_sync() c where c.step = 6 and c.detail like '%TEST-LANECHECK%');
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'A test job is being treated as a Monday job.' end; return next;

  delete from jobs where id in (v_real, v_test);
end;
$$;
revoke all on function check_test_lane() from public, anon, authenticated;
