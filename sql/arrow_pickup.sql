-- =====================================================================
-- Shop Floor — Arrow pick-up list (30 Sep 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_arrow_pickup();
--
-- What it does:
--   1. When Metal taps "Send to Arrow" on a finished sheet, the Arrow item
--      now starts as WAITING TO GO: it's on every Arrow tab's pick-up
--      list (Metal, Assembly / QC, Delivery), not yet "At Arrow".
--   2. arrow_gone() — whoever takes it over taps "Gone to Arrow". The item
--      moves to "At Arrow now" and its days-out clock starts that day.
--      Metal, Assembly / QC, Delivery or the office can do it.
--   3. An item can't be marked returned before it has gone.
--   4. v_outside_jobs gains the waiting columns (nothing is removed).
--   5. "Failed QC" is on Assembly / QC's defect list (it's how a failure
--      is reported now that the QC tab is gone). Added only if missing.
--
-- Unchanged: anything sent with "Send something to Arrow" goes straight
-- to At Arrow, as before. Items already at Arrow stay at Arrow. Assembly
-- / QC waits for a sheet until it's back, as before — waiting to go
-- counts as not back. Undo on Metal's sheet still takes it off the lists.
-- Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('arrow_pickup.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.outside_jobs') is null
     or to_regclass('public.sheet_sends') is null
     or to_regprocedure('public.send_sheet(uuid,text,text,uuid)') is null
     or to_regprocedure('public.return_from_arrow(uuid,date)') is null
     or to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run the earlier files first (up to send_routes.sql). This file builds on them.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Waiting to go: new columns (existing items are at Arrow, as before)
-- ---------------------------------------------------------------------
alter table outside_jobs add column if not exists waiting        boolean not null default false;
alter table outside_jobs add column if not exists queued_on      date;          -- the day Metal sent it on
alter table outside_jobs add column if not exists queued_by_name text;
alter table outside_jobs add column if not exists gone_by_name   text;          -- who took it over
alter table outside_jobs add column if not exists gone_at        timestamptz;

-- Metal's "Send to Arrow" (send_sheet with the Arrow route) makes the Arrow
-- item; this marks it waiting. Sends counted at go-live are left alone.
create or replace function arrow_send_waits()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.route = 'arrow' and new.outside_job_id is not null
     and coalesce(new.source, '') in ('Tablet', 'Manager adjustment') then
    update outside_jobs
       set waiting = true, queued_on = sent_on, queued_by_name = sent_by_name
     where id = new.outside_job_id and returned_on is null and voided_at is null and gone_at is null;
  end if;
  return null;
end $$;
revoke all on function arrow_send_waits() from public, anon, authenticated;
drop trigger if exists arrow_send_waits_trg on sheet_sends;
create trigger arrow_send_waits_trg after insert on sheet_sends
  for each row execute function arrow_send_waits();

-- ---------------------------------------------------------------------
-- 2. Gone to Arrow — one item or several (a trip). The date it went
--    defaults to today; the tablet sends its own date so a tap made
--    offline keeps the right day.
-- ---------------------------------------------------------------------
create or replace function arrow_gone(p_items uuid[], p_gone_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v outside_jobs; v_on date := coalesce(p_gone_on, local_today()); n int := 0; k int := 0; v_pids text[] := '{}';
begin
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  if not is_manager() and not exists (select 1 from unnest(arrow_departments()) d where owns_dept(d)) then
    raise exception 'Only Metal, Assembly / QC, Delivery or the office can mark Arrow items gone.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(cardinality(p_items), 0) = 0 then raise exception 'Pick what went to Arrow.'; end if;
  if v_on > local_today() then raise exception 'The day it went can''t be in the future.'; end if;
  for v in select * from outside_jobs where id = any(p_items) order by sent_at loop
    if not sees_lane(v.is_test) then raise exception 'That Arrow item isn''t there.'; end if;
    if not is_manager() and v.is_test <> am_test() then
      raise exception 'That item is in the other lane.' using errcode = 'insufficient_privilege';
    end if;
    if v.voided_at is not null then raise exception 'That item was taken off the list (entered by mistake, or its send was undone).'; end if;
    if not v.waiting then k := k + 1; continue; end if;           -- already gone: a resend changes nothing
    if v_on < coalesce(v.queued_on, v.sent_on) then
      raise exception 'It can''t go before Metal sent it on (%).', to_char(coalesce(v.queued_on, v.sent_on), 'Mon FMDD');
    end if;
    update outside_jobs set waiting = false, sent_on = v_on, gone_by_name = my_name(), gone_at = now() where id = v.id;
    n := n + 1;
    v_pids := v_pids || (select project_id from jobs where id = v.job_id);
  end loop;
  if n + k < (select count(distinct x) from unnest(p_items) x) then raise exception 'That Arrow item isn''t there.'; end if;
  return jsonb_build_object('ok', true, 'gone', n, 'already', n = 0,
    'summary', case when n = 0 then 'Already marked gone.'
                    else format('Gone to Arrow: %s. The days-out count starts %s.',
                                (select string_agg(distinct x, ', ') from unnest(v_pids) x),
                                case when v_on = local_today() then 'today' else to_char(v_on, 'Mon FMDD') end) end);
end $$;
revoke all on function arrow_gone(uuid[], date) from public, anon;
grant execute on function arrow_gone(uuid[], date) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Returned — as before, plus: not before it has gone
-- ---------------------------------------------------------------------
create or replace function return_from_arrow(p_item uuid, p_returned_on date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v outside_jobs; v_on date := coalesce(p_returned_on, local_today()); v_pid text;
begin
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v from outside_jobs where id = p_item;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That Arrow item isn''t there.'; end if;
  if not is_manager() and not exists (select 1 from unnest(arrow_departments()) d where owns_dept(d)) then
    raise exception 'Only Metal, Assembly / QC, Delivery or the office can mark Arrow items returned.' using errcode = 'insufficient_privilege';
  end if;
  if not is_manager() and v.is_test <> am_test() then
    raise exception 'That item is in the other lane.' using errcode = 'insufficient_privilege';
  end if;
  if v.voided_at is not null then raise exception 'That item was marked entered by mistake.'; end if;
  select project_id into v_pid from jobs where id = v.job_id;
  if v.returned_on is not null then return jsonb_build_object('ok', true, 'summary', 'Already marked returned.'); end if;
  if v.waiting then raise exception 'That hasn''t gone to Arrow yet. Tap Gone to Arrow first, on the day it goes.'; end if;
  if v_on < v.sent_on then raise exception 'It can''t come back before it went (%).', to_char(v.sent_on, 'Mon FMDD'); end if;
  if v_on > local_today() then raise exception 'The date returned can''t be in the future.'; end if;
  update outside_jobs set returned_on = v_on, returned_by_name = my_name(), returned_at = now() where id = p_item;
  return jsonb_build_object('ok', true, 'summary', format('%s back from Arrow after %s day%s.', v_pid, v_on - v.sent_on,
                                                         case when v_on - v.sent_on = 1 then '' else 's' end));
end $$;
revoke all on function return_from_arrow(uuid, date) from public, anon;
grant execute on function return_from_arrow(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The Arrow list, with the waiting columns added at the end.
--    at_vendor still means "not back yet" (waiting included), so pages
--    that haven't been updated keep working; the new pages split it.
--    While waiting, days_out counts days since Metal sent it on.
-- ---------------------------------------------------------------------
create or replace view v_outside_jobs with (security_invoker = true) as
select o.id, o.job_id, j.project_id, j.name as job_name, o.sheet_numbers, o.description, o.vendor, o.service,
       o.department, d.name as department_name, o.is_test, o.sent_on, o.sent_by, o.sent_by_name,
       o.returned_on, o.returned_by_name, (o.voided_at is not null) as voided, o.void_reason,
       (o.returned_on is null and o.voided_at is null) as at_vendor,
       coalesce(o.returned_on, local_today()) - o.sent_on as days_out,
       o.waiting and o.returned_on is null and o.voided_at is null as waiting,
       o.queued_on, o.queued_by_name, o.gone_by_name, o.gone_at,
       exists (select 1 from sheet_sends ss where ss.outside_job_id = o.id and ss.undone_at is null) as from_send
from outside_jobs o
join jobs j        on j.id = o.job_id
join departments d on d.key = o.department;
revoke all on v_outside_jobs from anon;
grant select on v_outside_jobs to authenticated;

-- ---------------------------------------------------------------------
-- 5. QC: marking a sheet done in Assembly / QC is the QC pass. A failure
--    is reported as a defect — "Failed QC" on Assembly / QC's list.
--    Added only if it isn't there (a manager's choice to retire it stands).
-- ---------------------------------------------------------------------
insert into defect_types (department, label, sort_order) values ('assembly_qc', 'Failed QC', 50)
on conflict (department, label) do nothing;

-- ---------------------------------------------------------------------
-- 6. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_arrow_pickup()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mt_u uuid; take_u uuid; take_name text; noarrow_u uuid; tst uuid; mgr uuid;
  v_job uuid; w1 uuid; s1 uuid; s2 uuid; s3 uuid; v_test uuid;
  x1 uuid; x2 uuid; a1 uuid; a2 uuid; a3 uuid; v_form uuid;
  v jsonb; n int; m int; ok boolean; msg text; t text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'metal' = any(departments) limit 1), mgr) into mt_u;
  -- whoever takes things over: Delivery first, then Assembly / QC, else a manager
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) limit 1),
                  (select id from profiles where role = 'supervisor' and active and not is_test and 'assembly_qc' = any(departments) limit 1), mgr) into take_u;
  select full_name into take_name from profiles where id = take_u;
  select id into noarrow_u from profiles p where p.role = 'supervisor' and p.active and not p.is_test and cardinality(p.departments) > 0
     and not (p.departments && arrow_departments()) limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;

  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999969, 'PICKUPCHECK', 'Arrow pick-up check - undone automatically', true, 'In Production', local_today() + 20)
      returning id into v_job;
    insert into work_orders (job_id, version) values (v_job, 1) returning id into w1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 1, 2, 'PU-1', 'p1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 2, 1, 'PU-2', 'p2') returning id into s2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 3, 1, 'PU-3', 'p3') returning id into s3;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'metal', 2, 2), (s1, 'assembly_qc', 2, 0),
      (s2, 'metal', 1, 1), (s2, 'assembly_qc', 1, 0),
      (s3, 'metal', 1, 1), (s3, 'assembly_qc', 1, 0);

    -- ---- 1: Send to Arrow puts it on the pick-up list, not at Arrow ------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mt_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_sheet(s1, 'metal', 'arrow'); x1 := (v->>'id')::uuid;
      v := send_sheet(s2, 'metal', 'arrow'); x2 := (v->>'id')::uuid;
      select outside_job_id into a1 from sheet_sends where id = x1;
      select outside_job_id into a2 from sheet_sends where id = x2;
      execute 'reset role';
      update outside_jobs set sent_on = local_today() - 2, queued_on = local_today() - 2 where id in (a1, a2);   -- as if sent on two days ago
      execute 'set local role authenticated';
      select count(*) into n from v_outside_jobs where id in (a1, a2) and waiting and at_vendor and from_send and queued_by_name is not null;
      select at_arrow and ready = 0 into ok from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc';
      execute 'reset role';
      ok := coalesce(ok, false) and n = 2;
      msg := format('Expected both sends to make an Arrow item waiting to go (got %s of 2), and Assembly / QC to hold the sheet.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'Metal''s Send to Arrow puts the sheet on the pick-up list (waiting to go); Assembly / QC waits for it', ok, msg);

    -- ---- 2: it can't come back before it has gone -------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', take_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := return_from_arrow(a1);
      execute 'reset role';
      ok := false; msg := 'An item waiting to go was marked returned.';
    exception when others then execute 'reset role'; ok := sqlerrm like 'That hasn''t gone to Arrow yet%'; msg := 'Unexpected refusal: ' || sqlerrm;
    end;
    res := res || check_row(2, 'An item can''t be marked returned before it has gone', ok, msg);

    -- ---- 3: who and when ---------------------------------------------------------------------
    ok := true; msg := null;
    if noarrow_u is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', noarrow_u, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := arrow_gone(array[a1]);
        execute 'reset role';
        ok := false; msg := 'A login outside Metal, Assembly / QC and Delivery marked an item gone.';
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', take_u, 'role', 'authenticated')::text, true);
    if ok then
      begin
        execute 'set local role authenticated';
        v := arrow_gone(array[a1], local_today() + 1);
        execute 'reset role';
        ok := false; msg := 'A day in the future was accepted.';
      exception when others then execute 'reset role'; ok := sqlerrm like '%can''t be in the future%'; msg := 'Unexpected refusal: ' || sqlerrm;
      end;
    end if;
    if ok then
      begin
        execute 'set local role authenticated';
        v := arrow_gone(array[a1], local_today() - 3);
        execute 'reset role';
        ok := false; msg := 'A day before Metal sent it on was accepted.';
      exception when others then execute 'reset role'; ok := sqlerrm like 'It can''t go before%'; msg := 'Unexpected refusal: ' || sqlerrm;
      end;
    end if;
    if ok then
      begin
        execute 'set local role authenticated';
        update outside_jobs set waiting = false where id = a1;
        execute 'reset role';
        ok := false; msg := 'A login changed an Arrow item directly, around the checks.';
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(3, 'Only Metal, Assembly / QC, Delivery or the office mark it gone — not in the future, not before it was sent, not around the checks', ok, msg);

    -- ---- 4: Gone to Arrow: at Arrow, clock starts, name kept; twice changes nothing --------------
    begin
      execute 'set local role authenticated';
      select count(*) into m from v_outside_jobs where id in (a1, a2) and waiting and days_out = 2;
      v := arrow_gone(array[a1, a2]);
      select count(*) into n from v_outside_jobs where id in (a1, a2) and not waiting and at_vendor and days_out = 0 and sent_on = local_today()
                                                   and queued_on = local_today() - 2;
      v := arrow_gone(array[a1, a2]);
      execute 'reset role';
      ok := m = 2 and n = 2 and coalesce((v->>'already')::boolean, false)
            and (select count(*) from outside_jobs where id in (a1, a2) and gone_by_name = take_name and queued_on is not null) = 2;
      msg := format('Expected both items waiting 2 days, then at Arrow 0 days out from today (the send day kept), under %s''s name, and a second tap to change nothing; got %s and %s of 2.', take_name, m, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Gone to Arrow moves it to At Arrow, starts the days-out count that day, and keeps who took it', ok, msg);

    -- ---- 5: back from Arrow: Assembly / QC gets it ----------------------------------------------
    begin
      execute 'set local role authenticated';
      v := return_from_arrow(a1);
      select ready into n from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc';
      execute 'reset role';
      ok := n = 2; msg := format('Expected 2 ready for Assembly / QC once it was back; got %s.', coalesce(n::text, 'nothing'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Once it''s back, Assembly / QC sees it, as before', coalesce(ok, false), msg);

    -- ---- 6: the Send something to Arrow form is unchanged ------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mt_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_to_arrow(v_job, 'metal', 'paint', '{}', 'pick-up check brackets', local_today() - 2, gen_random_uuid());
      v_form := (v->>'id')::uuid;
      execute 'reset role';
      -- a send counted at go-live (finished before send routes) never makes an item wait
      insert into sheet_sends (job_id, sheet_id, sheet_number, from_dept, route, outside_job_id, source, sent_by_name)
        values (v_job, s3, 3, 'metal', 'arrow', v_form, 'Before send routes', 'Pick-up check');
      execute 'set local role authenticated';
      select count(*) into n from v_outside_jobs where id = v_form and at_vendor and not waiting and days_out = 2;
      execute 'reset role';
      update sheet_sends set undone_at = now() where outside_job_id = v_form;
      ok := n = 1; msg := 'An item sent with the form should go straight to At Arrow, 2 days out.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Something sent with "Send something to Arrow" goes straight to At Arrow, as before', ok, msg);

    -- ---- 7: Undo on Metal's sheet takes a waiting item off the list ----------------------------------
    begin
      execute 'set local role authenticated';
      v := send_sheet(s3, 'metal', 'arrow');
      select outside_job_id into a3 from sheet_sends where id = (v->>'id')::uuid;
      v := undo_sheet_send((select id from sheet_sends where outside_job_id = a3));
      select count(*) into n from v_outside_jobs where id = a3 and not voided;
      execute 'reset role';
      ok := n = 0 and exists (select 1 from outside_jobs where id = a3 and voided_at is not null);
      msg := 'After Undo the waiting item should be off the lists (kept in history, marked).';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Undo on Metal''s sheet takes a waiting item off the pick-up list', ok, msg);

    -- ---- 8: lanes ----------------------------------------------------------------------------------
    if tst is null then
      res := res || check_row(8, 'Test and real Arrow items stay in their own lanes', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('PICKUPCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      update sheet_progress sp set qty_done = sp.qty_required from sheets s, work_orders w
       where s.id = sp.sheet_id and w.id = s.work_order_id and w.job_id = v_test and w.is_current and sp.department = 'metal';
      begin
        execute 'set local role authenticated';
        v := send_sheet((select s.id from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
                          where w.job_id = v_test and s.sheet_number = 2), 'metal', 'arrow');
        select count(*) into n from v_outside_jobs where job_id = v_test and waiting;
        select count(*) into m from v_outside_jobs where job_id = v_job;
        begin
          v := arrow_gone(array[a2]);
          msg := 'The Test Supervisor marked a real item gone.'; n := -1;
        exception when insufficient_privilege then null;
        when others then if sqlerrm not like 'That Arrow item isn''t there%' then raise; end if;
        end;
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', take_u, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into t from v_outside_jobs where job_id = v_test;
        execute 'reset role';
        ok := n = 1 and m = 0 and (t = '0' or take_u = mgr);
        msg := coalesce(msg, format('The Test Supervisor saw %s waiting test items (1) and %s real ones (0); a real login saw %s test items (0).', n, m, t));
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(8, 'Test and real Arrow items stay in their own lanes', ok, msg);
    end if;

    -- ---- 9: no login ---------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin
      execute 'set local role anon';
      select count(*) into m from v_outside_jobs;
      execute 'reset role';
      if m > 0 then n := m; msg := m || ' Arrow items visible'; end if;
    exception when insufficient_privilege then execute 'reset role';
    end;
    begin
      execute 'set local role anon';
      v := arrow_gone(array[a2]);
      execute 'reset role';
      n := n + 1; msg := concat_ws(', ', msg, 'an item was marked gone with no login');
    exception when others then execute 'reset role';
    end;
    res := res || check_row(9, 'Someone with no login sees nothing and marks nothing gone', n = 0, coalesce(msg, '') || '. Do not go further.');

    -- ---- 10: QC failures have a place on Assembly / QC's defect list -----------------------------------
    res := res || check_row(10, '"Failed QC" is on Assembly / QC''s defect list (how a failed check is reported now)',
      exists (select 1 from defect_types where department = 'assembly_qc' and label = 'Failed QC' and active),
      'It''s missing or retired. In the office: Setup → Defect lists → Assembly / QC → add "Failed QC".');

    raise exception using errcode = 'P0001', message = '__check_arrow_pickup_undo__';
  exception when others then
    if sqlerrm <> '__check_arrow_pickup_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_arrow_pickup() from public, anon, authenticated;

select * from check_arrow_pickup();
