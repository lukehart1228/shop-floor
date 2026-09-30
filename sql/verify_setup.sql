-- =====================================================================
-- Shop Floor — setup check
--
-- HOW TO USE: paste this whole file into the Supabase SQL Editor and
-- click Run. A table appears at the bottom. Every row should say PASS.
--
-- It makes a throwaway test job, tries things as your sanding supervisor
-- (some that should work, some that must be refused), then deletes the
-- test job. Nothing real is touched.
--
-- If more than one row says FAIL, look at the FIRST one. Later failures
-- are usually knock-on effects of it — if a count can't be saved, its
-- history can't exist either.
--
-- Run it again any time with just:   select * from verify_setup();
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('verify_setup.sql'); end if;
end $$;

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
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'sanding';
    get diagnostics n = row_count;
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

-- only you can run this from the dashboard; the tablet app cannot
revoke execute on function verify_setup() from public, anon, authenticated;

select * from verify_setup();
