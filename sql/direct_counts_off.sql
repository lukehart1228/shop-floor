-- =====================================================================
-- direct_counts_off.sql — the old direct count route is closed (21 Oct 2026)
--
-- Finishes review finding R-4. Since 6 Oct every tablet page sends counts
-- through set_count(), which finds the current work order itself. The
-- older route — a signed-in login writing sheet_progress.qty_done
-- straight into the table — was kept until every device had the new
-- page. On 20 Oct devices() showed every device on 2026-10-06.1 or
-- later, so this file takes that grant away: no login can change a
-- count except through set_count() (and managers through Advance).
--
-- Four checks wrote or expected that direct route, so this file carries
-- them whole, rewritten (it is their one current copy now; the files they
-- came from stop if run again):
--   verify_setup()        (verify_setup.sql)  step 3 counts through set_count()
--   check_test_lane()     (test_lane.sql)     steps 3 and 9 count through set_count()
--   check_counts_safety() (counts_safety.sql) step 6 expects the direct route refused
--   check_tv_photos()     (tv_photos.sql)     looks only at its own practice jobs; since
--                         20 Oct a real job (PROJ-00437) has a picture on the TV, which
--                         made it fail on the live database though the TV was right
--
-- Nothing a supervisor sees or does changes: no page on the floor has
-- used the direct route since 6 Oct. The policy write_progress stays as
-- it is; without the grant it can't let anything through.
--
-- Run order 45. Safe to run twice. Registers itself: one paste, no need
-- to run install_log.sql after it (install_log.sql must be its 21 Oct
-- version, or this file is catalogued the old way and install_log.sql is
-- run once after it). Ends with check_direct_counts_off(): every row
-- should say PASS.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('direct_counts_off.sql', 45, 'check_direct_counts_off', 'check_direct_counts_off', '{verify_setup.sql,test_lane.sql,counts_safety.sql,tv_photos.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('direct_counts_off.sql', '{verify_setup.sql,test_lane.sql,counts_safety.sql,tv_photos.sql}'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.set_count(uuid,integer)') is null then
    raise exception 'Run counts_safety.sql first. This file comes after it.';
  end if;
  if to_regprocedure('public.tv_photo(text,uuid)') is null then
    raise exception 'Run tv_photos.sql first. This file comes after it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The grant comes off (R-4)
-- ---------------------------------------------------------------------

-- schema.sql granted update (qty_done) on sheet_progress to authenticated,
-- the column the old tablet page wrote directly. Both the column grant and
-- any table-level update go. Reading is unchanged (the TV shows counts to
-- the whole floor). set_count() and advance_sheet() run as the owner, so
-- they are unaffected.
revoke update (qty_done) on sheet_progress from anon, authenticated;
revoke update on sheet_progress from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. verify_setup(): step 3 counts the way the tablet does
-- ---------------------------------------------------------------------

create or replace function verify_setup()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql
set search_path = public
as $$
declare
  sup      uuid;
  mgr      uuid;
  v_job    uuid;
  v_wo     uuid;
  s1       uuid;
  s2       uuid;
  n        int;
  r1       int;
  r2       int;
  ok       boolean;
  msg      text;
begin
  -- clear anything left over from an earlier run that was interrupted
  delete from jobs where project_id = 'TEST-VERIFY';

  -- 1. people ---------------------------------------------------------
  select id into sup from profiles
   where role = 'supervisor' and 'sanding' = any(departments) and active
   limit 1;
  step := 1; check_name := 'A sanding supervisor account exists';
  if sup is null then
    result := 'FAIL';
    if_it_failed := 'No supervisor owns sanding yet. Add Mike''s profile (walkthrough step 8), then run this again.';
    return next;
    return;                                   -- nothing else can be tested without one
  end if;
  result := 'PASS'; if_it_failed := null; return next;

  select id into mgr from profiles where role in ('manager','admin') and active limit 1;
  step := 2; check_name := 'A manager account exists';
  result := case when mgr is null then 'FAIL' else 'PASS' end;
  if_it_failed := case when mgr is null then 'Add your own profile as manager (walkthrough step 8).' end;
  return next;

  -- a small fake job: sheet 1 goes milling -> CNC -> sanding and has metal;
  -- sheet 2 skips CNC, which is the case the ready-to-work count has to get right
  insert into jobs (monday_item_id, project_id, name, is_active)
    values (-999999, 'TEST-VERIFY', 'Setup check - safe to delete', true) returning id into v_job;
  insert into work_orders (job_id) values (v_job) returning id into v_wo;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 4) returning id into s1;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 2, 3) returning id into s2;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
    (s1,'milling',4,4), (s1,'cnc',4,3), (s1,'sanding',4,0), (s1,'metal',4,0),
    (s2,'milling',3,2), (s2,'sanding',3,0);

  -- from here on, act as the sanding supervisor would from the tablet
  perform set_config('request.jwt.claims',
    json_build_object('sub', sup, 'role', 'authenticated')::text, true);

  -- 3. the one thing the tablet must be able to do -------------------
  begin
    execute 'set local role authenticated';
    -- through set_count(), as the tablet does (21 Oct: the direct route is closed)
    perform set_count((select id from sheet_progress where sheet_id = s1 and department = 'sanding'), 1);
    select count(*) into n from sheet_progress where sheet_id = s1 and department = 'sanding' and qty_done = 1;
    execute 'reset role';
    ok := (n = 1); msg := case when n = 1 then null else 'The count was not saved.' end;
  exception when others then
    ok := false; msg := 'Error: ' || sqlerrm;
  end;
  step := 3; check_name := 'Supervisor can enter a count in their own department';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 4. and it's recorded, under the right name -----------------------
  select exists (
    select 1 from progress_events
     where sheet_id = s1 and department = 'sanding' and qty_to = 1 and actor = sup
  ) into ok;
  step := 4; check_name := 'The count is recorded in history under the supervisor''s name';
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'History is missing or has the wrong name on it.' end;
  return next;

  -- 5. can't touch another department --------------------------------
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_done = 4 where sheet_id = s1 and department = 'metal';
    get diagnostics n = row_count;
    execute 'reset role';
    ok := (n = 0);
    msg := case when n = 0 then null else 'A sanding login changed a metal count. Do not go further.' end;
  exception when insufficient_privilege then
    ok := true; msg := null;
  when others then
    ok := false; msg := 'Error: ' || sqlerrm;
  end;
  step := 5; check_name := 'Supervisor cannot change another department''s counts';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 6. can't change how many pieces a sheet needs --------------------
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_required = 1 where sheet_id = s1 and department = 'sanding';
    execute 'reset role';
    ok := false; msg := 'A supervisor was able to change the required quantity.';
  exception when insufficient_privilege then
    ok := true; msg := null;
  when others then
    ok := false; msg := 'Unexpected error: ' || sqlerrm;
  end;
  step := 6; check_name := 'Supervisor cannot change how many pieces a sheet needs';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 7. can't put someone else's name on the work ---------------------
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_done = 2, updated_by = coalesce(mgr, sup)
     where sheet_id = s1 and department = 'sanding';
    execute 'reset role';
    ok := false; msg := 'A supervisor was able to record work under another name.';
  exception when insufficient_privilege then
    ok := true; msg := null;
  when others then
    ok := false; msg := 'Unexpected error: ' || sqlerrm;
  end;
  step := 7; check_name := 'Supervisor cannot record work under someone else''s name';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 8. can't rewrite history -----------------------------------------
  begin
    execute 'set local role authenticated';
    insert into progress_events (sheet_id, department, qty_to) values (s1, 'sanding', 99);
    execute 'reset role';
    ok := false; msg := 'A supervisor was able to write to the history directly.';
  exception when insufficient_privilege then
    ok := true; msg := null;
  when others then
    ok := false; msg := 'Unexpected error: ' || sqlerrm;
  end;
  step := 8; check_name := 'Supervisor cannot write or edit history directly';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 9. the ready-to-work number is right, including the skipped stage -
  begin
    execute 'set local role authenticated';
    select v.ready into r1 from v_ready_to_work v where v.sheet_id = s1 and v.department = 'sanding';
    select v.ready into r2 from v_ready_to_work v where v.sheet_id = s2 and v.department = 'sanding';
    execute 'reset role';
    -- sheet 1: CNC has done 3, sanding 1  -> 2 ready
    -- sheet 2: no CNC, milling has done 2 -> 2 ready
    ok := (r1 = 2 and r2 = 2);
    msg := case when ok then null
           else format('Expected 2 and 2 pieces ready, got %s and %s.', r1, r2) end;
  exception when others then
    ok := false; msg := 'Error: ' || sqlerrm;
  end;
  step := 9; check_name := 'Ready-to-work count is correct, including a sheet that skips CNC';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- 10. someone with no login sees nothing ---------------------------
  perform set_config('request.jwt.claims', '', true);
  begin
    execute 'set local role anon';
    select count(*) into n from jobs;
    execute 'reset role';
    ok := (n = 0);
    msg := case when n = 0 then null
           else n || ' jobs are visible without logging in. Do not go further.' end;
  exception when insufficient_privilege then
    ok := true; msg := null;
  when others then
    ok := false; msg := 'Error: ' || sqlerrm;
  end;
  step := 10; check_name := 'Someone with no login sees no jobs';
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- tidy up: removing the test job removes its sheets, counts and history
  delete from jobs where project_id = 'TEST-VERIFY';
end;
$$;
revoke all on function verify_setup() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. check_test_lane(): steps 3 and 9 count the way the tablet does
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
    -- through set_count(), as the tablet does (21 Oct: the direct route is closed)
    perform set_count((select sp.id from sheet_progress sp
                        where sp.department = 'milling' and sp.sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test)
                        limit 1), 2);
    select count(*) into n from sheet_progress sp
     where sp.department = 'milling' and sp.qty_done = 2
       and sp.sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test);
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
      perform set_count((select id from sheet_progress where sheet_id = s1 and department = sup_dept), 1);   -- 21 Oct: through set_count()
      select count(*) into n from sheet_progress where sheet_id = s1 and department = sup_dept and qty_done = 1;
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

-- ---------------------------------------------------------------------
-- 4. check_counts_safety(): step 6 now expects the refusal
-- ---------------------------------------------------------------------

create or replace function check_counts_safety()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sup uuid; tst uuid;
  v_job uuid; v_wo1 uuid; v_wo2 uuid;
  s1 uuid; s2 uuid; s1b uuid; s2b uuid;
  p1 uuid; p2 uuid; p1b uuid; p2b uuid;
  r jsonb; n int; m int; ok boolean; msg text; e progress_events;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('sanding' = any (departments))
                                     and not ('delivery' = any (departments)) and cardinality(departments) > 0 order by full_name limit 1;
  select id into tst from profiles where is_test and active limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  -- ---- 1: the pieces are in place ---------------------------------------------------------------
  ok := to_regprocedure('public.set_count(uuid,integer)') is not null
        and has_function_privilege('authenticated', 'public.set_count(uuid,integer)', 'execute')
        and not has_function_privilege('anon', 'public.set_count(uuid,integer)', 'execute')
        and exists (select 1 from pg_trigger where tgname = 'sheet_progress_current_only_trg' and not tgisinternal);
  res := res || check_row(1, 'set_count() is there for signed-in logins only, and the replaced-version guard is on sheet_progress', ok,
                          case when ok then null else 'Run counts_safety.sql again.' end);

  -- ---- 2: no table can be emptied, or given triggers or references, without the secret key ----------
  select count(*), string_agg(distinct c.relname, ', ')
    into n, msg
    from pg_class c
    cross join (values ('anon'), ('authenticated')) g(who)
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and (has_table_privilege(g.who, c.oid, 'truncate') or has_table_privilege(g.who, c.oid, 'trigger')
          or has_table_privilege(g.who, c.oid, 'references'));
  res := res || check_row(2, 'No-login and signed-in users can''t empty any table (TRUNCATE) or add triggers or references to one', n = 0,
                          case when n = 0 then null else 'Granted again on: ' || left(msg, 300) || '. Run counts_safety.sql again.' end);

  begin    -- everything below is undone at the end, whatever happens
    -- a job with a work order of two sheets (Sanding on both), then a change order:
    -- sheet 1's drawing the same, sheet 2's changed
    insert into jobs (monday_item_id, project_id, name, phase, is_active, is_test)
    values (-60601, 'PROJ-CHECKCOUNTS', 'Count check — undone automatically', 'In Production', true, false)
    returning id into v_job;
    insert into work_orders (job_id, version, is_current) values (v_job, 1, true) returning id into v_wo1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo1, 1, 3, 'same') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo1, 2, 2, 'old')  returning id into s2;
    insert into sheet_progress (sheet_id, department, qty_required) values (s1, 'sanding', 3) returning id into p1;
    insert into sheet_progress (sheet_id, department, qty_required) values (s2, 'sanding', 2) returning id into p2;
    set constraints all immediate;

    -- ---- 3: a count on the current work order saves, recorded as a Tablet count by that login ----------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := set_count(p1, 1);
      execute 'reset role';
      select * into e from progress_events where sheet_id = s1 and department = 'sanding' order by occurred_at desc, id desc limit 1;
      ok := (r->>'qty_done')::int = 1 and not (r->>'moved')::boolean and e.qty_to = 1 and e.actor = mgr and e.source = 'Tablet';
      msg := case when ok then null else 'Got ' || coalesce(r::text, 'nothing') || ', history ' || coalesce(row_to_json(e)::text, 'none') end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A count sent through set_count() saves, and the history says Tablet and who', ok, msg);

    -- the change order: version 2 is current; sheet 1 carried forward (same drawing), sheet 2 changed
    update work_orders set is_current = false, superseded_at = now() where id = v_wo1;
    insert into work_orders (job_id, version, is_current) values (v_job, 2, true) returning id into v_wo2;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo2, 1, 3, 'same') returning id into s1b;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo2, 2, 2, 'new')  returning id into s2b;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1b, 'sanding', 3, 1) returning id into p1b;
    insert into sheet_progress (sheet_id, department, qty_required) values (s2b, 'sanding', 2) returning id into p2b;
    set constraints all immediate;

    -- ---- 4: a count sent to the replaced version lands on the current one when the drawing is the same ---
    begin
      execute 'set local role authenticated';
      r := set_count(p1, 3);
      execute 'reset role';
      select qty_done into n from sheet_progress where id = p1b;
      select qty_done into m from sheet_progress where id = p1;
      ok := (r->>'moved')::boolean and (r->>'id')::uuid = p1b and n = 3 and m = 1;
      msg := case when ok then null else format('current version %s/3, replaced version %s (should stay 1); reply %s', n, m, r) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'After a change order, a count the tablet sends for an unchanged sheet lands on the current version', ok, msg);

    -- ---- 5: …and is refused, in plain words, when that sheet's drawing changed ---------------------------
    begin
      execute 'set local role authenticated';
      r := set_count(p2, 2);
      execute 'reset role';
      ok := false; msg := 'It was accepted: ' || r::text;
    exception when others then execute 'reset role';
      ok := sqlerrm like '%new work order%sheet 2 changed%'; msg := case when ok then null else 'Wrong refusal: ' || sqlerrm end;
    end;
    select count(*) into n from sheet_progress where id in (p2, p2b) and qty_done > 0;
    res := res || check_row(5, 'A count for a sheet whose drawing changed on the new work order is refused and saved nowhere', ok and n = 0,
                            coalesce(msg, case when n > 0 then 'It was saved somewhere' end));

    -- ---- 6: the old direct route is closed (R-4 finished 21 Oct): a direct write is refused on both versions ----
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 2 where id = p1;
      execute 'reset role'; msg := 'a direct write to the replaced version was saved';
    exception when others then execute 'reset role'; n := n + 1;
    end;
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 2 where id = p1b;
      execute 'reset role'; msg := concat_ws(', ', msg, 'a direct write to the current version was saved');
    exception when others then execute 'reset role'; n := n + 1;
    end;
    res := res || check_row(6, 'The old direct count route is closed: a direct write is refused on the replaced and the current work order alike (counts go through set_count())', n = 2, msg);

    -- ---- 7: the department, the test lane, the range and no login are all checked ------------------------
    n := 0; m := 0; msg := null;
    if sup is not null then
      m := m + 1;
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; perform set_count(p1b, 2); execute 'reset role'; msg := 'another department''s supervisor counted Sanding';
      exception when others then execute 'reset role'; n := n + 1; end;
    end if;
    if tst is not null then
      m := m + 1;
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; perform set_count(p1b, 2); execute 'reset role'; msg := concat_ws(', ', msg, 'the Test Supervisor counted a real job');
      exception when others then execute 'reset role'; n := n + 1; end;
    end if;
    m := m + 1;
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated'; perform set_count(p1b, 4); execute 'reset role'; msg := concat_ws(', ', msg, '4 of 3 was accepted');
    exception when others then execute 'reset role'; n := n + 1; end;
    m := m + 1;
    perform set_config('request.jwt.claims', '', true);
    begin execute 'set local role anon'; perform set_count(p1b, 2); execute 'reset role'; msg := concat_ws(', ', msg, 'no login counted');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(7, 'set_count() refuses another department, the other lane, a number past the sheet''s quantity, and no login', n = m, msg);

    raise exception using errcode = 'P0001', message = '__check_counts_safety_undo__';
  exception when others then
    if sqlerrm <> '__check_counts_safety_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_counts_safety() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. check_tv_photos(): looking only at its own practice jobs
-- ---------------------------------------------------------------------

create or replace function check_tv_photos()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the TV, Delivery and a manager
declare
  res     jsonb := '[]';
  mgr uuid; dlv uuid; as_mgr text; as_dlv text;
  v_key text; v jsonb; r jsonb;
  ja uuid; jb uuid; jt uuid; wa uuid; wb uuid; wt uuid; la uuid; lb uuid; lt uuid;
  pa1 uuid := gen_random_uuid(); pa2 uuid := gen_random_uuid(); pa3 uuid := gen_random_uuid(); pb1 uuid := gen_random_uuid();
  pdock uuid := gen_random_uuid(); pbad uuid := gen_random_uuid(); pbig uuid := gen_random_uuid(); pt uuid := gen_random_uuid();
  ida1 uuid; ida2 uuid; ida3 uuid; idb1 uuid; iddock uuid; idbad uuid; idbig uuid; idt uuid;
  -- a real 2×2 JPEG (632 bytes) and a PNG, for the copies
  jpg constant text := '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwAooorwT6U//9k=';
  png constant text := 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNk2LKJgYGBiYGBgYGBAQAQQAFqlmjkSwAAAABJRU5ErkJggg==';
  big text;
  ok boolean; msg text; n int; m int; k text; sz bigint;
  home jsonb;
  own  int;   -- pictures on the home list from this check's own jobs (21 Oct: a real job's picture may be there too)
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) limit 1), mgr) into dlv;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_dlv := json_build_object('sub', dlv, 'role', 'authenticated')::text;

  -- ---- 1. the tables are locked -------------------------------------------------------------
  ok := true; msg := '';
  foreach k in array array['tv_photo_copies', 'tv_hides'] loop
    if has_table_privilege('anon', 'public.' || k, 'select') or has_table_privilege('authenticated', 'public.' || k, 'select')
       or has_table_privilege('anon', 'public.' || k, 'insert,update,delete,truncate')
       or has_table_privilege('authenticated', 'public.' || k, 'insert,update,delete,truncate')
       or not (select relrowsecurity from pg_class where oid = ('public.' || k)::regclass) then
      ok := false; msg := msg || k || ' is readable or writable by a login. ';
    end if;
  end loop;
  if has_function_privilege('anon', 'public.tv_home_pictures()', 'execute') or has_function_privilege('authenticated', 'public.tv_home_pictures()', 'execute')
     or has_function_privilege('anon', 'public.hide_from_tv(uuid,uuid,boolean)', 'execute')
     or has_function_privilege('anon', 'public.tv_job_pictures(uuid)', 'execute')
     or has_function_privilege('anon', 'public.clear_tv_photo_copies()', 'execute') or has_function_privilege('authenticated', 'public.clear_tv_photo_copies()', 'execute')
     or not has_function_privilege('anon', 'public.tv_photo(text,uuid)', 'execute') then
    ok := false; msg := msg || 'A TV function is open to the wrong role. ';
  end if;
  res := res || check_row(1, 'Nobody signed in, and nobody without a login, can read or write the TV''s copies or hides; only the TV''s two functions reach them', ok,
    msg || 'Do not go further; bring this to Claude.');

  -- ---- 2. one add_delivery_photo ---------------------------------------------------------
  select count(*) into n from pg_proc where proname = 'add_delivery_photo' and pronamespace = 'public'::regnamespace;
  res := res || check_row(2, 'There is exactly one add_delivery_photo, so the phone''s photos are never refused as ambiguous', n = 1,
    format('%s functions named add_delivery_photo. Two would make every phone photo wait (PGRST203). Bring this to Claude.', n));

  begin    -- everything below is undone at the end, whatever happens
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v_key := new_tv_link()->>'key';
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    -- two real jobs and a test job, each with a work order; A has two kinds of table (3 of one, 1 of another)
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values (-999981, 'TVPHOTO-A', 'TV photos check - undone automatically', true, 'In Production', local_today()) returning id into ja;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values (-999982, 'TVPHOTO-B', 'TV photos check - undone automatically', true, 'In Production', local_today()) returning id into jb;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test) values (null, 'TEST-TVPHOTO', 'TV photos check - undone automatically', true, 'In Production', local_today(), true) returning id into jt;
    insert into work_orders (job_id) values (ja) returning id into wa;
    insert into work_orders (job_id) values (jb) returning id into wb;
    insert into work_orders (job_id) values (jt) returning id into wt;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (wa, 1, 3, 'TVP-ROUND'), (wa, 2, 1, 'TVP-RECT'), (wb, 1, 1, 'TVP-LIVE'), (wt, 1, 1, 'TVP-TEST');
    -- white glove trips, finished (signed) today; the test one too
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at) values (ja, 'delivery', now() - interval '3 hours', now() - interval '20 minutes', 'A Customer', now() - interval '20 minutes') returning id into la;
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at) values (jb, 'delivery', now() - interval '2 hours', now() - interval '10 minutes', 'B Customer', now() - interval '10 minutes') returning id into lb;
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at, is_test) values (jt, 'delivery', now() - interval '2 hours', now() - interval '10 minutes', 'T Customer', now() - interval '10 minutes', true) returning id into lt;
    -- the files the phone uploads first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', 'TVPHOTO-A/' || x || '.jpg', '{"size": 1}' from unnest(array[pa1, pa2, pa3, pdock, pbad]) x;
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', 'TVPHOTO-B/' || x || '.jpg', '{"size": 1}' from unnest(array[pb1, pbig]) x;

    -- ---- 3. the phone sends site photos with copies; a dock photo, a PNG and an oversize copy keep the photo and drop the copy
    begin
      big := rpad(substr(jpg, 1, 4), 280000, 'A');     -- starts like a JPEG, about 210 KB decoded: over the 200 KB limit
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(pa1, la, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '50 minutes', 800, 600, jpg);  ida1 := (r->>'id')::uuid;
      r := add_delivery_photo(pa2, la, 'site', 1, 2, null, 39.77, -86.16, 8, now() - interval '45 minutes', 800, 600, jpg);  ida2 := (r->>'id')::uuid;
      r := add_delivery_photo(pa3, la, 'site', 1, 3, null, 39.77, -86.16, 8, now() - interval '40 minutes', 800, 600, jpg);  ida3 := (r->>'id')::uuid;
      r := add_delivery_photo(pdock, la, 'dock', null, null, 1, 39.77, -86.16, 8, now() - interval '3 hours', 800, 600, jpg); iddock := (r->>'id')::uuid;
      r := add_delivery_photo(pbad, la, 'site', 2, 1, null, 39.77, -86.16, 8, now() - interval '35 minutes', 800, 600, png);  idbad := (r->>'id')::uuid;
      ok := (r->>'ok')::boolean and not (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pbig, lb, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '30 minutes', 800, 600, big);  idbig := (r->>'id')::uuid;
      ok := ok and (r->>'ok')::boolean and not (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pb1, lb, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '25 minutes', 800, 600, jpg);  idb1 := (r->>'id')::uuid;
      ok := ok and (r->>'ok')::boolean and (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pa1, la, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '50 minutes', 800, 600, jpg);
      ok := ok and (r->>'already')::boolean;   -- the same photo sent twice: already saved, as before
      execute 'reset role';
      -- a copy for the test job, put straight into the table: the gate must never list it
      insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, storage_path, is_test, taken_by_name, stage, piece)
        values (pt, jt, 1, 'delivery', 'loadout', lt, 'TEST-TVPHOTO/' || pt || '.jpg', true, 'check', 'site', 1) returning id into idt;
      insert into tv_photo_copies (photo_id, jpeg, bytes) values (idt, decode(jpg, 'base64'), 632);
      select count(*) into n from tv_photo_copies where photo_id in (ida1, ida2, ida3, idb1) and jpeg is not null;
      select count(*) into m from tv_photo_copies where photo_id in (iddock, idbad, idbig);
      select count(*) into k from photos where id in (ida1, ida2, ida3, idb1, iddock, idbad, idbig);
      ok := coalesce(ok, false) and n = 4 and m = 0 and k::int = 7;
      msg := format('Copies kept for the 4 good site photos: %s of 4; copies wrongly kept for the truck, the PNG and the oversize one: %s; photos saved: %s of 7.', n, m, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A white glove site photo''s copy is kept; a truck photo''s, a non-JPEG and an oversize copy are dropped and the photo still saves', ok, msg);

    -- ---- 4. the home list: one per kind, the newest, jobs taking turns, never the test job ------
    begin
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      home := v->'home';
      select count(*) into n from jsonb_array_elements(home) x where x->>'project_id' = 'TVPHOTO-A';
      -- A's first kind is TVP-RECT (sheet 2) but it has no copy (the PNG), so A shows one picture: the newest of TVP-ROUND = table 3
      ok := n = 1 and home @> jsonb_build_array(jsonb_build_object('id', ida3, 'project_id', 'TVPHOTO-A', 'tables', 4))
            and not (home::text like '%' || ida1 || '%') and not (home::text like '%' || ida2 || '%')
            and not (home::text like '%' || iddock || '%') and not (home::text like '%' || idbad || '%')
            and home::text not like '%TEST-TVPHOTO%' and home::text not like '%' || idt || '%'
            and not (v ?| array['table', 'kpis']);
      msg := format('TVPHOTO-A pictures: %s (expected 1, the newest of its 3 identical tables, saying 4 tables delivered). List: %s', n, left(home::text, 300));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A job with 3 of one table gets 1 picture (the newest); the picture says how many tables went; test jobs never show', ok, msg);

    -- ---- 5. taking turns: a second job with one kind comes before another job's second kind -------
    begin
      -- give A its second kind: a good copy on sheet 2 (the PNG one is already there as a photo; add another table? sheet 2 has qty 1,
      -- so instead replace the bad copy's photo: mark it entered by mistake and add a fresh one on sheet 2 table 1)
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_photo(idbad, 'TV photos check');
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      pbad := gen_random_uuid();
      insert into storage.objects (bucket_id, name, metadata) values ('photos', 'TVPHOTO-A/' || pbad || '.jpg', '{"size": 1}');
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(pbad, la, 'site', 2, 1, null, 39.77, -86.16, 8, now() - interval '34 minutes', 800, 600, jpg);  idbad := (r->>'id')::uuid;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      home := v->'home';
      -- only this check's own jobs: a real job's picture interleaves but doesn't change their order (live, 20 Oct: PROJ-00437)
      select string_agg(x->>'project_id', ',' order by o), count(*) into k, own
        from jsonb_array_elements(home) with ordinality t(x, o) where x->>'project_id' like 'TVPHOTO-%';
      -- round 1: B (delivered most recently) then A; round 2: A's second kind
      ok := k = 'TVPHOTO-B,TVPHOTO-A,TVPHOTO-A' and own = 3;
      msg := format('Order: %s (expected TVPHOTO-B,TVPHOTO-A,TVPHOTO-A: every job''s first kind, newest delivery first, then second kinds).', k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'The jobs take turns: every job''s first kind of table, then the second kinds', ok, msg);

    -- ---- 6. tv_photo hands out a listed copy, and only that --------------------------------------
    begin
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      r := tv_photo(v_key, ida3);
      ok := (r->>'ok')::boolean and decode(r->>'jpeg', 'base64') = decode(jpg, 'base64');
      r := tv_photo(v_key, ida1);          -- a real site photo, but not the one the panel shows (the same kind, older)
      ok := ok and not (r->>'ok')::boolean and not (r ? 'jpeg');
      r := tv_photo(v_key, iddock);        -- the truck
      ok := ok and not (r->>'ok')::boolean and not (r ? 'jpeg');
      r := tv_photo('not-the-key', ida3);  -- wrong key: the same plain answer
      ok := ok and r = jsonb_build_object('ok', false);
      r := tv_photo(v_key, idt);           -- the test job's copy
      ok := ok and r = jsonb_build_object('ok', false);
      execute 'reset role';
      msg := 'tv_photo handed out a copy it shouldn''t, or refused the one the panel shows, or said more than "ok: false" for a wrong key. Do not go further; bring this to Claude.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'The TV gets one copy per listed id, nothing for any other id, and one plain refusal without the link', ok, msg);

    -- ---- 7. the hide switch ----------------------------------------------------------------------
    begin
      msg := '';
      if dlv <> mgr then      -- a Delivery supervisor can't hide (in a sandbox without one, this part is skipped)
        perform set_config('request.jwt.claims', as_dlv, true);
        execute 'set local role authenticated';
        begin perform hide_from_tv(ida3, null, true); msg := msg || 'A Delivery login hid a picture. ';
        exception when insufficient_privilege then null; end;
        execute 'reset role';
      end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(ida3, null, true);
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key); r := tv_photo(v_key, ida3);
      execute 'reset role';
      -- hiding the newest shows the next newest of that kind (table 2), and tv_photo refuses the hidden one
      if (v->'home')::text like '%' || ida3 || '%' then msg := msg || 'The hidden picture still listed. '; end if;
      if (v->'home')::text not like '%' || ida2 || '%' then msg := msg || 'The next picture of that kind did not take its place. '; end if;
      if (r->>'ok')::boolean then msg := msg || 'tv_photo still handed out the hidden picture. '; end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(ida3, null, false);
      perform hide_from_tv(null, ja, true);
      select count(*) into n from tv_job_pictures(ja) t where t.job_hidden;
      select count(*) into m from tv_job_pictures(ja) t where t.showing;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      if (v->'home')::text like '%TVPHOTO-A%' then msg := msg || 'The hidden job still listed. '; end if;
      if (v->'home')::text not like '%TVPHOTO-B%' then msg := msg || 'The other job went too. '; end if;
      if n <> 4 or m <> 0 then msg := msg || format('The office saw %s pictures marked job-hidden (expected 4) and %s showing (expected 0). ', n, m); end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(null, ja, false);
      select count(*) into m from tv_job_pictures(ja) t where t.showing;
      execute 'reset role';
      if m <> 2 then msg := msg || format('After showing the job again, %s pictures showing (expected 2). ', m); end if;
      ok := msg = '';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A manager hides a picture (the next of its kind takes its place) or a whole job, and shows them again; Delivery can''t', ok, msg);

    -- ---- 8. entered by mistake, a cancelled trip, and the 14-day window ---------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_photo(ida3, 'TV photos check');
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      ok := (v->'home')::text not like '%' || ida3 || '%' and (v->'home')::text like '%' || ida2 || '%';
      update loadouts set voided_at = now(), void_reason = 'TV photos check' where id = lb;
      update loadouts set completed_at = now() - interval '15 days' where id = la;
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      select count(*) into own from jsonb_array_elements(v->'home') x where x->>'project_id' like 'TVPHOTO-%';
      ok := ok and own = 0;
      n := clear_tv_photo_copies();
      select count(*), count(*) filter (where jpeg is null and cleared_at is not null) into m, k
        from tv_photo_copies where photo_id in (ida1, ida2, ida3, idbad, idbig, iddock);
      ok := ok and m = 4 and k::int = 4;
      msg := format('After a photo marked entered by mistake, a cancelled trip and a 15-day-old delivery: %s pictures listed (expected 0); clearing emptied %s of %s copies and kept every row.', own, k, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A photo or trip marked entered by mistake leaves the TV; after 14 days a job leaves, its copies are cleared and their rows kept', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_tv_photos_undo__';
  exception when others then
    if sqlerrm <> '__check_tv_photos_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ---- 9. room: the copies table against its ceiling (R-22) ------------------------------------
  sz := pg_total_relation_size('public.tv_photo_copies');
  select count(*) filter (where jpeg is not null), count(*) into n, m from tv_photo_copies;
  res := res || check_row(9, format('The TV copies take %s (%s pictures kept, %s rows); the ceiling is %s', pg_size_pretty(sz), n, m, pg_size_pretty(tv_copies_ceiling_bytes())),
    sz < tv_copies_ceiling_bytes(),
    'The copies are over their ceiling: new copies are skipped (photos still save). Run select clear_tv_photo_copies(); and bring this to Claude.');

  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_tv_photos() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. This file's own check
-- ---------------------------------------------------------------------

create or replace function check_direct_counts_off()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as a login
declare
  res   jsonb := '[]';
  sup   uuid; dept text;
  v_job uuid; v_wo uuid; s1 uuid; p1 uuid;
  r jsonb; n int; ok boolean; msg text;
begin
  -- ---- 1: no update grant on sheet_progress for anon or authenticated, at table or column level ----------
  select count(*), string_agg(g.who || ' on ' || a.attname, ', ') into n, msg
    from (values ('anon'), ('authenticated')) g(who)
    cross join pg_attribute a
   where a.attrelid = 'public.sheet_progress'::regclass and a.attnum > 0 and not a.attisdropped
     and has_column_privilege(g.who, 'public.sheet_progress', a.attname, 'update');
  ok := n = 0 and not has_table_privilege('anon', 'public.sheet_progress', 'update')
        and not has_table_privilege('authenticated', 'public.sheet_progress', 'update');
  res := res || check_row(1, 'Nobody signed in, and nobody without a login, can change a count directly: no update grant on sheet_progress, table or column', ok,
                          case when ok then null else 'Still granted: ' || coalesce(msg, 'table-level update') || '. Run direct_counts_off.sql again.' end);

  select id, departments[1] into sup, dept from profiles
   where role = 'supervisor' and active and not is_test and cardinality(departments) > 0 and not ('delivery' = any (departments))
   order by full_name limit 1;
  if sup is null then
    res := res || check_row(2, 'A supervisor login exists to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, phase, is_active, is_test)
    values (-60602, 'PROJ-CHECKDIRECT', 'Direct count check — undone automatically', 'In Production', true, false)
    returning id into v_job;
    insert into work_orders (job_id, version, is_current) values (v_job, 1, true) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo, 1, 3, 'same') returning id into s1;
    insert into sheet_progress (sheet_id, department, qty_required) values (s1, dept, 3) returning id into p1;
    set constraints all immediate;

    -- ---- 2: the department's own supervisor, writing the table directly: refused -------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 1 where id = p1;
      execute 'reset role'; msg := 'a direct write by the department''s own supervisor was saved';
    exception when others then execute 'reset role'; n := 1;
    end;
    res := res || check_row(2, 'A supervisor''s direct count on their own department is refused (the tablet sends counts through set_count())', n = 1, msg);

    -- ---- 3: the same login, through set_count(): saved ------------------------------------------------
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      r := set_count(p1, 2);
      execute 'reset role';
      select qty_done into n from sheet_progress where id = p1;
    exception when others then execute 'reset role'; msg := 'set_count refused: ' || sqlerrm;
    end;
    res := res || check_row(3, 'The same supervisor''s count through set_count() is saved', n = 2, coalesce(msg, 'qty_done is ' || n));

    raise exception using errcode = 'P0001', message = '__check_direct_counts_off_undo__';
  exception when others then
    if sqlerrm <> '__check_direct_counts_off_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_direct_counts_off() from public, anon, authenticated;

select * from check_direct_counts_off();
