-- =====================================================================
-- Shop Floor — Finish-by dates (designed 24 Sep, built 25 Sep)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_finish_by();
--
-- What it adds (nothing existing is changed):
--   1. finish_by_days — how many days before Monday's delivery date each
--      department's last piece must be done. One row per change; the
--      newest row for a department is the number in use, and every
--      older row stays as the history. Starting numbers:
--        Milling 21 · CNC 18 · Metal 18 (to paint / powdercoat) ·
--        Full Custom 16 · Sanding 14 · Finishing 10 · Assembly / QC 3
--      Delivery isn't in the table: it keeps the delivery date.
--   2. v_finish_by_days — the numbers in use, with who set them.
--   3. v_finish_by — each job's date per department: the delivery date
--      minus that department's days, in plain calendar days (a date on
--      a weekend stays on the weekend). No delivery date on Monday means
--      no finish-by date. It also says whether the department has every
--      piece on the job done, so a card can say "Done".
--   4. set_finish_by_days() — the only way to change a number. Managers
--      only; office → Setup → Finish-by days calls it.
--
-- Everyone signed in can read the numbers and the dates (the tablets
-- need them). Test jobs and real jobs stay in their own lanes, as on the
-- rest of the floor. Nobody can write to the table directly.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('finish_by.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.defect_messages') is null
     or to_regprocedure('public.check_row(integer,text,boolean,text)') is null
     or to_regprocedure('public.sees_lane(boolean)') is null then
    raise exception 'Run the earlier files first (up to ready_issues.sql). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The numbers, with every change kept
-- ---------------------------------------------------------------------

create table if not exists finish_by_days (
  id          bigint generated always as identity primary key,
  department  text        not null references departments(key),
  days        int         not null check (days between 0 and 90),
  set_by      uuid        references profiles(id),
  set_by_name text        not null,
  set_at      timestamptz not null default clock_timestamp()
);
create index if not exists finish_by_days_dept_idx on finish_by_days (department, set_at desc, id desc);

-- the starting numbers, only for a department that has none yet (so a
-- second run never puts back a number a manager has since changed)
insert into finish_by_days (department, days, set_by_name)
select v.department, v.days, 'Starting number'
  from (values ('milling', 21), ('cnc', 18), ('metal', 18), ('full_custom', 16),
               ('sanding', 14), ('finishing', 10), ('assembly_qc', 3)) v(department, days)
  join departments d on d.key = v.department
 where not exists (select 1 from finish_by_days f where f.department = v.department);

alter table finish_by_days enable row level security;
drop policy if exists read_finish_by_days on finish_by_days;
create policy read_finish_by_days on finish_by_days for select to authenticated using (true);
revoke insert, update, delete, truncate on finish_by_days from anon, authenticated;
revoke all on finish_by_days from anon;
grant select on finish_by_days to authenticated;


-- ---------------------------------------------------------------------
-- 2. The numbers in use
-- ---------------------------------------------------------------------

create or replace view v_finish_by_days with (security_invoker = true) as
select distinct on (f.department)
  f.department,
  d.name        as department_name,
  d.sort_order,
  f.days,
  case when f.department = 'metal' then 'To paint / PC by' else 'Done by' end as label,
  f.set_by_name,
  f.set_at,
  (select count(*) from finish_by_days h where h.department = f.department) - 1 as changes
from finish_by_days f
join departments d on d.key = f.department
order by f.department, f.set_at desc, f.id desc;

revoke all on v_finish_by_days from anon;
grant select on v_finish_by_days to authenticated;


-- ---------------------------------------------------------------------
-- 3. Each job's date per department
-- ---------------------------------------------------------------------

create or replace view v_finish_by with (security_invoker = true) as
select
  j.id              as job_id,
  j.project_id,
  j.is_test,
  j.is_active,
  n.department,
  n.department_name,
  n.days,
  n.label,
  j.delivery_date,
  j.delivery_date - n.days                       as finish_by,
  (j.delivery_date - n.days) - local_today()     as days_left,
  coalesce(p.pieces_done, 0)                     as pieces_done,
  coalesce(p.pieces_required, 0)                 as pieces_required,
  (coalesce(p.pieces_required, 0) > 0
     and coalesce(p.pieces_done, 0) >= p.pieces_required) as all_done
from jobs j
cross join v_finish_by_days n
left join lateral (
  select sum(least(sp.qty_done, sp.qty_required))::int as pieces_done,
         sum(sp.qty_required)::int                     as pieces_required
    from work_orders w
    join sheets s          on s.work_order_id = w.id
    join sheet_progress sp on sp.sheet_id = s.id and sp.department = n.department
   where w.job_id = j.id and w.is_current
) p on true
where sees_lane(j.is_test);

revoke all on v_finish_by from anon;
grant select on v_finish_by to authenticated;


-- ---------------------------------------------------------------------
-- 4. Changing a number (managers only)
-- ---------------------------------------------------------------------

create or replace function set_finish_by_days(p_department text, p_days int)
returns text
language plpgsql security definer set search_path = public as $$
declare v_dept departments; v_old int;
begin
  if not office_ok() then
    raise exception 'Only a manager can change the finish-by days.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_dept from departments where key = p_department;
  if v_dept.key is null then
    raise exception '"%" is not a department.', p_department;
  end if;
  if v_dept.log_only then
    raise exception '% keeps the delivery date; it has no finish-by days.', v_dept.name;
  end if;
  if p_days is null or p_days < 0 or p_days > 90 then
    raise exception 'The days for % must be a whole number from 0 to 90.', v_dept.name;
  end if;
  select days into v_old from v_finish_by_days where department = p_department;
  if v_old = p_days then
    return format('%s is already %s day%s before delivery. Nothing changed.', v_dept.name, p_days, case when p_days = 1 then '' else 's' end);
  end if;
  insert into finish_by_days (department, days, set_by, set_by_name)
    values (p_department, p_days, auth.uid(), my_name());
  return format('%s: now %s day%s before delivery%s. Every job''s %s date moves with it.',
                v_dept.name, p_days, case when p_days = 1 then '' else 's' end,
                case when v_old is null then '' else format(' (was %s)', v_old) end, v_dept.name);
end;
$$;
revoke all on function set_finish_by_days(text, int) from public, anon;
grant execute on function set_finish_by_days(text, int) to authenticated;


-- ---------------------------------------------------------------------
-- 5. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------

create or replace function check_finish_by()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  sup_dept text;  tst uuid;  mgr uuid;
  v_job   uuid;  v_nodate uuid;  v_test uuid;  v_wo uuid;  s1 uuid;  s2 uuid;
  v_deliv date;  v_mill int;
  n       int;   m int;
  ok      boolean;
  msg     text;
  v       jsonb;
  t       text;
begin
  select p.id, (select d from unnest(p.departments) d where d in (select key from departments where not log_only) limit 1)
    into sup, sup_dept
    from profiles p
   where p.role = 'supervisor' and p.active and not p.is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  -- ---- 1: the numbers are there --------------------------------------------
  select count(*), string_agg(format('%s %s', department, days), ', ' order by sort_order)
    into n, msg from v_finish_by_days;
  ok := n = 7 and not exists (select 1 from v_finish_by_days where department = 'delivery');
  res := res || check_row(1, 'Every counted department has a finish-by number (Delivery keeps the delivery date)', ok,
    format('Expected 7 departments; found %s: %s.', n, coalesce(msg, 'none')));

  if sup is null or mgr is null then
    res := res || check_row(2, 'A supervisor and a manager have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end, case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- a delivery date chosen so that Milling's date falls on a Saturday
    select days into v_mill from v_finish_by_days where department = 'milling';
    v_deliv := local_today() + 30;
    v_deliv := v_deliv + ((6 - extract(dow from v_deliv - v_mill)::int + 7) % 7);
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999985, 'FINISHCHECK', 'Finish-by check - undone automatically', true, 'In Production', v_deliv)
      returning id into v_job;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999984, 'FINISHCHECK-ND', 'Finish-by check', true, 'In Production', null)
      returning id into v_nodate;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 1, 2, 'FC-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 2, 3, 'FC-2') returning id into s2;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'milling', 2, 2), (s2, 'milling', 3, 3),      -- Milling: all 5 done
      (s1, 'sanding', 2, 2), (s2, 'sanding', 3, 1);      -- Sanding: 3 of 5

    -- ---- 2–3: the dates, read as a supervisor -------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*), count(*) filter (where f.finish_by = v_deliv - d.days and f.days_left = f.finish_by - local_today()),
             string_agg(format('%s %s', f.department, f.finish_by), ', ' order by d.sort_order)
        into n, m, msg
        from v_finish_by f join v_finish_by_days d on d.department = f.department where f.job_id = v_job;
      select finish_by into v_deliv from v_finish_by where job_id = v_job and department = 'milling';
      select label into t from v_finish_by where job_id = v_job and department = 'metal';
      execute 'reset role';
      ok := n = 7 and m = 7 and t = 'To paint / PC by';
      msg := format('Expected 7 dates, each the delivery date minus the department''s days; got %s right of %s (%s). Metal''s label: %s.', m, n, coalesce(msg, 'none'), coalesce(t, 'none'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Each department''s date is the delivery date minus its days', ok, msg);

    ok := extract(dow from v_deliv) = 6;
    res := res || check_row(3, 'Plain calendar days: a date on a weekend stays on the weekend', coalesce(ok, false),
      format('Milling''s date should have stayed on a Saturday; it is %s.', coalesce(to_char(v_deliv, 'Dy Mon DD'), 'missing')));

    -- ---- 4: no delivery date ---------------------------------------------------
    select count(*) filter (where finish_by is null), count(*) into n, m from v_finish_by where job_id = v_nodate;
    res := res || check_row(4, 'No delivery date on Monday: no finish-by date', n = 7 and m = 7,
      format('Expected 7 rows with no date; got %s of %s.', n, m));

    -- ---- 5: follows Monday -----------------------------------------------------
    update jobs set delivery_date = delivery_date + 5 where id = v_job;
    select count(*) filter (where f.finish_by = j.delivery_date - f.days) into n
      from v_finish_by f join jobs j on j.id = f.job_id where f.job_id = v_job;
    res := res || check_row(5, 'When Monday''s delivery date moves, every department''s date moves with it', n = 7,
      format('Only %s of 7 dates followed the new delivery date.', n));

    -- ---- 6: Done ---------------------------------------------------------------
    select (select all_done and pieces_done = 5 and pieces_required = 5 from v_finish_by where job_id = v_job and department = 'milling')
       and (select not all_done and pieces_done = 3 and pieces_required = 5 from v_finish_by where job_id = v_job and department = 'sanding')
       and (select not all_done and pieces_required = 0 from v_finish_by where job_id = v_job and department = 'metal')
      into ok;
    res := res || check_row(6, 'It says Done only when the department has every piece on the job done', coalesce(ok, false),
      'Milling (5 of 5) should be done, Sanding (3 of 5) not, and Metal (no pieces) not.');

    -- ---- 7–8: supervisors can't change the numbers ------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      t := set_finish_by_days('milling', 5);
      execute 'reset role';
      ok := false; msg := 'A supervisor changed Milling''s days. Only a manager should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A supervisor can''t change the numbers', ok, msg);

    begin
      execute 'set local role authenticated';
      insert into finish_by_days (department, days, set_by_name) values ('milling', 5, 'sneaky');
      execute 'reset role';
      ok := false; msg := 'A supervisor wrote to finish_by_days directly, around the manager check.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Nobody can write to the table directly', ok, msg);

    -- ---- 9–10: a manager changes one; the history stays -------------------------
    select count(*) into n from finish_by_days where department = 'sanding';
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      t := set_finish_by_days('sanding', 15);
      t := set_finish_by_days('sanding', 13);
      msg := set_finish_by_days('sanding', 13);             -- the same again: nothing changes
      select days into m from v_finish_by_days where department = 'sanding';
      select finish_by = delivery_date - 13 into ok from v_finish_by where job_id = v_job and department = 'sanding';
      execute 'reset role';
      ok := ok and m = 13 and msg like '%Nothing changed%'
            and (select count(*) from finish_by_days where department = 'sanding') = n + 2
            and (select set_by_name from finish_by_days where department = 'sanding' order by set_at desc, id desc limit 1)
                = (select full_name from profiles where id = mgr);
      msg := 'Sanding should now be 13 with two new rows kept (and the name of who changed it), and the dates should follow.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'A manager changes a number: dates follow, and every change is kept with who made it', coalesce(ok, false), msg);

    n := 0;
    begin execute 'set local role authenticated'; t := set_finish_by_days('sanding', -1);   execute 'reset role'; exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; t := set_finish_by_days('sanding', 91);   execute 'reset role'; exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; t := set_finish_by_days('sanding', null); execute 'reset role'; exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; t := set_finish_by_days('delivery', 2);   execute 'reset role'; exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(10, 'Numbers below 0, over 90 or blank are refused, and so is Delivery', n = 4,
      format('%s of the 4 bad changes were refused.', n));

    -- ---- 11: lanes ---------------------------------------------------------------
    if tst is null then
      res := res || check_row(11, 'Test jobs and real jobs stay in their own lanes', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('FINISHCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) filter (where job_id = v_test), count(*) filter (where job_id = v_job) into n, m from v_finish_by;
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into t from v_finish_by where job_id = v_test;
        execute 'reset role';
        ok := n = 7 and m = 0 and t = '0';
        msg := format('The Test Supervisor saw %s test rows (7 expected) and %s real ones (0); a real supervisor saw %s test rows (0).', n, m, t);
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(11, 'Test jobs and real jobs stay in their own lanes', ok, msg);
    end if;

    -- ---- 12: no login --------------------------------------------------------------
    -- each one read on its own, so a refusal on one can't hide rows showing on another
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    foreach t in array array['finish_by_days', 'v_finish_by_days', 'v_finish_by'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        if m > 0 then n := n + m; msg := concat_ws(', ', msg, format('%s rows of %s', m, t)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; n := n + 1; msg := concat_ws(', ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(12, 'Someone with no login sees none of it', n = 0,
      coalesce(msg, '') || ' visible without logging in. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_finish_by_undo__';
  exception when others then
    if sqlerrm <> '__check_finish_by_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_finish_by() from public, anon, authenticated;

select * from check_finish_by();
