-- =====================================================================
-- Shop Floor — the whole-floor check (steps 4–9)
--
-- HOW TO USE: run the six step files first (problems, flags,
-- routine_tasks, supplies, arrow_qc, tv). Then paste this whole file
-- into a NEW, empty query in the Supabase SQL Editor and click Run.
-- A table appears. Every row should say PASS.
--
-- It builds a throwaway job and a test copy of it, tries each function
-- as your supervisor, the Test Supervisor, a manager and someone with no
-- login — some things that must work, some that must be refused — and
-- then UNDOES EVERYTHING it did. Nothing real is touched, and your TV
-- link keeps working.
--
-- If more than one row says FAIL, look at the FIRST one.
-- Run it again any time with just:   select * from check_floor();
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('check_floor.sql'); end if;
end $$;

create or replace function check_row(p_step int, p_name text, p_ok boolean, p_msg text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_array(jsonb_build_object('step', p_step, 'name', p_name,
         'result', case when p_ok then 'PASS' else 'FAIL' end, 'msg', case when p_ok then null else p_msg end))
$$;
revoke all on function check_row(int, text, boolean, text) from public, anon, authenticated;

create or replace function check_floor()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res        jsonb := '[]';
  sup        uuid;  sup_name text;  sup_dept text;  other_dept text;  arrow_other text;
  tst        uuid;
  mgr        uuid;
  v_real     uuid;  v_wo uuid;  s1 uuid;  s2 uuid;
  v_test     uuid;
  v_type     uuid;  v_tst_type uuid;
  v          jsonb;
  n          int;
  ok         boolean;
  msg        text;
  v_prob     uuid;
  v_task     uuid;
  v_req      uuid;
  v_arrow    uuid;
  v_key      text;
  v_live     boolean;
  v_wd       int;
begin
  -- ---- who to test as ---------------------------------------------------
  select p.id, p.full_name, coalesce((select d from unnest(p.departments) d where d = 'sanding'), p.departments[1])
    into sup, sup_name, sup_dept
    from profiles p
   where p.role = 'supervisor' and p.active and not p.is_test and array_length(p.departments, 1) > 0
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by ('sanding' = any(p.departments)) desc limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  if sup is null or tst is null or mgr is null then
    res := res || check_row(1, 'A supervisor, the Test Supervisor and a manager all have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end,
                     case when tst is null then 'No Test Supervisor (Walkthrough 5, optional section).' end,
                     case when mgr is null then 'No manager.' end));
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;

  select key into other_dept from departments d
   where not d.log_only and not exists (select 1 from profiles p where p.id = sup and d.key = any(p.departments))
   order by sort_order limit 1;
  select a into arrow_other from unnest(arrow_departments()) a
   where not exists (select 1 from profiles p where p.id = sup and a = any(p.departments)) limit 1;
  select is_live into v_live from departments where key = sup_dept;

  -- everything below is undone at the end, whatever happens
  begin
    -- ---- 1. Delivery ------------------------------------------------------
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, materials_ordered)
      values (-999996, 'FLOORCHECK', 'Floor check - undone automatically', true, 'In Production', local_today() + 5, false)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 1, 3, 'CHK-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 2, 2, 'CHK-2') returning id into s2;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      select s1, d, 3, 0 from unnest(array['metal', 'assembly_qc', sup_dept]) d on conflict do nothing;
    insert into sheet_progress (sheet_id, department, qty_required) values (s2, sup_dept, 2) on conflict do nothing;

    ok := exists (select 1 from departments where key = 'delivery' and log_only);
    begin
      insert into sheet_progress (sheet_id, department, qty_required) values (s2, 'delivery', 2);
      ok := false; msg := 'A Delivery sheet count was accepted — Delivery should be log-only.';
    exception when others then
      msg := case when ok then null else 'There''s no Delivery department marked log-only. Run problems.sql again.' end;
    end;
    res := res || check_row(1, 'Delivery is a log-only department (no sheet counts)', ok, msg);

    -- ---- 2. defect lists -------------------------------------------------
    select count(*) into n from departments d where exists (select 1 from defect_types t where t.department = d.key and t.active);
    res := res || check_row(2, 'Every department has a defect list', n = (select count(*) from departments),
      format('%s of %s departments have one. Run problems.sql again.', n, (select count(*) from departments)));

    select id into v_type from defect_types where department = sup_dept and active order by sort_order limit 1;
    v := make_test_job('FLOORCHECK');
    select id into v_test from jobs where project_id = v->>'project_id';
    select id into v_tst_type from defect_types where department = 'metal' and active order by sort_order limit 1;

    -- ---- as the supervisor -----------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);

    begin
      execute 'set local role authenticated';
      v := log_defect(v_real, sup_dept, v_type, 1, 'floor check', gen_random_uuid());
      execute 'reset role';
      ok := (v->>'ok')::boolean; msg := null;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A supervisor can log a defect in their own department', ok, msg);

    ok := exists (select 1 from defects where job_id = v_real and logged_by = sup and logged_by_name = sup_name and not is_test);
    res := res || check_row(4, 'The defect is recorded under the supervisor''s name', ok, 'It''s missing, or has the wrong name on it.');

    begin
      execute 'set local role authenticated';
      v := log_defect(v_real, coalesce(other_dept, 'metal'), v_tst_type, 1, null, null);
      execute 'reset role';
      ok := other_dept is null; msg := format('%s logged a defect for %s, which isn''t theirs. Do not go further.', sup_name, other_dept);
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A supervisor can''t log for another department', ok, msg);

    begin
      execute 'set local role authenticated';
      insert into defects (job_id, department, defect_type_id, defect_type) values (v_real, sup_dept, v_type, 'x');
      execute 'reset role';
      ok := false; msg := 'A supervisor wrote to the defects table directly, around the checks.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Nobody can write to the log tables directly', ok, msg);

    begin
      execute 'set local role authenticated';
      v := flag_problem(v_real, sup_dept, 'Floor check: is this reaching the office?', 1, true, gen_random_uuid());
      execute 'reset role';
      v_prob := (v->>'id')::uuid; ok := v_prob is not null; msg := null;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    if ok then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) into n from v_problems where id = v_prob and work_stopped and status = 'open';
        execute 'reset role';
        ok := n = 1; msg := 'The office can''t see the problem.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(7, 'A flagged problem, with work stopped, reaches the office', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := answer_problem(v_prob, 'I shouldn''t be able to answer this');
      execute 'reset role';
      ok := false; msg := 'A supervisor answered a problem. Only the office should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Only the office can answer a problem', ok, msg);

    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := answer_problem(v_prob, 'Floor check answer', true);
      execute 'reset role';
      ok := (select status = 'answered' from problems where id = v_prob);
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := reply_problem(v_prob, 'Floor check: still not settled', null, gen_random_uuid());
      execute 'reset role';
      ok := ok and (select status = 'open' and came_back from problems where id = v_prob);
      msg := 'The answer didn''t close it, or the reply didn''t bring it back tagged Came back.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'An answer closes a problem; a reply brings it back as "Came back"', ok, msg);

    -- ---- the lanes -------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := log_defect(v_test, 'metal', v_tst_type, 1, 'floor check, test lane', null);
      execute 'reset role';
      ok := true;
      begin
        execute 'set local role authenticated';
        v := log_defect(v_real, 'metal', v_tst_type, 1, null, null);
        execute 'reset role';
        ok := false; msg := 'The Test Supervisor logged against a REAL job. Do not go further.';
      exception when insufficient_privilege then execute 'reset role';
      end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    if ok then
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select (select count(*) from v_defects where is_test) + (select count(*) from v_pick_jobs where is_test) into n;
        execute 'reset role';
        ok := n = 0; msg := 'A real supervisor can see test-lane entries.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(10, 'Test entries stay on test jobs, out of real supervisors'' sight', ok, msg);

    -- ---- flags -----------------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := set_flag(v_real, 'critical', 'I shouldn''t be able to set this');
      execute 'reset role';
      ok := false; msg := 'A supervisor set a flag. Only managers should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    if ok then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := set_flag(v_real, 'critical', 'Floor check: customer on site Thursday');
        v := set_flag(v_real, 'priority', 'Floor check: replaces the critical one');
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into n from v_flags where job_id = v_real and is_open and level = 'priority';
        execute 'reset role';
        ok := n = 1 and (select count(*) from flags where job_id = v_real) = 2;
        msg := 'The supervisor doesn''t see exactly one open flag, or the replaced flag wasn''t kept in history.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(11, 'Only managers set flags; a new flag replaces the old; the floor sees it', ok, msg);

    -- ---- routine tasks ---------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := add_routine_task('__floor check__', sup_dept, 'weekly', 1);
      execute 'reset role';
      ok := false; msg := 'A supervisor added a routine task. Only managers should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    if ok then
      v_wd := greatest(1, least(4, extract(dow from local_today())::int));
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := add_routine_task('__floor check__', sup_dept, 'weekly', v_wd, 1, null, local_today() - 21);
        execute 'reset role';
        v_task := (v->>'id')::uuid;
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select days_until into n from v_routine_tasks where id = v_task;
        ok := n is not null and n <= 0;                         -- overdue or due today: never done
        v := complete_routine_task(v_task, gen_random_uuid());
        select days_until into n from v_routine_tasks where id = v_task;
        ok := ok and n > 0;                                     -- done today: due again later
        v := complete_routine_task(v_task, gen_random_uuid());
        ok := ok and coalesce((v->>'already')::boolean, false);  -- twice in a day counts once
        execute 'reset role';
        msg := 'The task wasn''t due, didn''t move on when done, or counted twice in one day.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(12, 'Routine tasks: managers add, the floor completes, the next due date moves on', ok, msg);

    -- ---- supplies --------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := request_supply(sup_dept, '__floor check__', 2, null, gen_random_uuid());
      v_req := (v->>'id')::uuid;
      v := set_supply_qty(v_req, 3);
      begin
        v := order_supplies(array[v_req]);
        ok := false; msg := 'A supervisor marked supplies ordered. Only the office should.';
      exception when insufficient_privilege then ok := true;
      end;
      execute 'reset role';
      if ok then
        perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        v := order_supplies(array[v_req]);
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        v := receive_supply(v_req);
        execute 'reset role';
        ok := (select state = 'received' and qty = 3 from supply_requests where id = v_req);
        msg := 'The request didn''t go requested → ordered → received with the changed quantity.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Supplies: the floor asks, only the office orders, the floor receives', ok, msg);

    -- ---- Arrow and QC (as the Test Supervisor, on the test copy) ----------
    perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_to_arrow(v_test, 'metal', 'powdercoat', array[1], 'floor check brackets', local_today() - 3, gen_random_uuid());
      v_arrow := (v->>'id')::uuid;
      select days_out into n from v_outside_jobs where id = v_arrow and at_vendor;
      ok := n = 3;
      v := return_from_arrow(v_arrow);
      ok := ok and (select not at_vendor and days_out = 3 from v_outside_jobs where id = v_arrow);
      execute 'reset role';
      msg := 'The item didn''t show 3 days out, or didn''t come back with a 3-day turnaround.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    if ok and arrow_other is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := send_to_arrow(v_real, arrow_other, 'paint', '{}', 'shouldn''t work');
        execute 'reset role';
        ok := false; msg := format('%s sent an Arrow item for %s, which isn''t theirs.', sup_name, arrow_other);
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(14, 'Arrow: send, days out, return with turnaround — Arrow departments only', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := record_qc(v_test, 1, 'pass', null, gen_random_uuid());
      v := record_qc(v_test, 1, 'fail', 'floor check: finish scuffed', gen_random_uuid());
      select count(*) into n from v_defects where job_id = v_test and sheet_number = 1 and defect_type = 'Failed QC' and not voided;
      execute 'reset role';
      ok := n = 1; msg := 'A failed QC didn''t log a "Failed QC" defect on the sheet.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'QC: a failure is logged as a defect on that sheet', ok, msg);

    -- ---- the TV ----------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      v := tv_snapshot('not-the-key');
      execute 'reset role';
      ok := not (v->>'ok')::boolean;
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v_key := new_tv_link()->>'key';
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      ok := ok and (v->>'ok')::boolean
            and v::text not like '%TEST-FLOORCHECK%'
            and not exists (select 1 from jsonb_array_elements(v->'live') l where l->>'key' = 'delivery')
            and (not v_live or v::text like '%FLOORCHECK%');
      msg := 'The TV showed numbers without its link, showed a test job, showed Delivery, or left out a live department''s job.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(16, 'The TV shows nothing without its link, and never test jobs', ok, msg);

    -- ---- no login --------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select (select count(*) from defects) + (select count(*) from problems) + (select count(*) from flags)
           + (select count(*) from supply_requests) + (select count(*) from outside_jobs) + (select count(*) from routine_tasks)
           + (select count(*) from qc_entries) into n;
      execute 'reset role';
      ok := n = 0; msg := n || ' log entries are visible without logging in. Do not go further.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(17, 'Someone with no login sees none of it', ok, msg);

    -- ---- ready for the bench ----------------------------------------------
    ok := exists (select 1 from profiles where id = tst and 'delivery' = any(departments));
    res := res || check_row(18, 'The Test Supervisor can open Delivery too (for the bench run)', ok,
      'Run: select set_person(''<test login email>'', ''Test Supervisor'', ''supervisor'', ''{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}'', true);');

    raise exception using errcode = 'P0001', message = '__check_floor_undo__';
  exception when others then
    if sqlerrm <> '__check_floor_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_floor() from public, anon, authenticated;

select * from check_floor();
