-- =====================================================================
-- Shop Floor — handoff hold and Recently completed (2 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it changes:
--   1. v_ready_to_work (what's ready, for the tablets, the TV and Pace):
--      Milling, Metal and Full Custom don't get a job until Monday's
--      Handed Off says Yes — the same jobs as the office's Handoffs
--      list. Once one of them has counted a piece on a job, it keeps
--      the job until it's done, whatever Monday says. A new column,
--      held_for_handoff, tells the tablet which rows to hide. Every
--      other column is exactly as before, so older pages keep working.
--   2. A new view, v_recent_work, for the tablet's Recently completed
--      tab: jobs a department finished (senders: finished and sent on)
--      in the last 21 days, and actually worked on the tablet — jobs
--      the catch-up from Monday or Advance marked done don't show.
--      v_past_work (the old Past tab) is left as it was.
--
-- Replaces send_routes.sql's v_ready_to_work, so send_routes.sql now
-- stops if run again.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('handoff_recent.sql', '{schema.sql,ready_issues.sql,send_routes.sql}'); end if;
end $$;

do $$
begin
  if to_regclass('public.v_past_work') is null or to_regprocedure('public.current_send(uuid,text)') is null
     or not exists (select 1 from information_schema.columns where table_name = 'jobs' and column_name = 'handed_off')
     or not exists (select 1 from information_schema.columns where table_name = 'progress_events' and column_name = 'source') then
    raise exception 'Run office.sql, catch_up.sql and send_routes.sql first. This file builds on them.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. What's ready: the tablets' Ready lists, the TV and Pace
--    As send_routes.sql, plus the handoff hold (marked 2 Oct).
-- ---------------------------------------------------------------------
create or replace view v_ready_to_work with (security_invoker = true) as
with recursive ancestors as (
  select key as dept, predecessor as anc, 1 as depth
    from departments where predecessor is not null
  union all
  select a.dept, d.predecessor, a.depth + 1
    from ancestors a join departments d on d.key = a.anc
   where d.predecessor is not null
)
select
  sp.department,
  s.id  as sheet_id,
  j.id  as job_id,
  greatest(g.available - sp.qty_done, 0) as ready,
  g.available,
  case when sp.qty_done < sp.qty_required and g.available <= sp.qty_done then
    array_remove(array[
      case when up.department is not null and up.qty_done <= sp.qty_done then up.department end,
      case when fc.present and fc.route is null then 'full_custom' end,
      case when mt.present and not mt.at_arrow and mt.lim <= sp.qty_done then mt.wait end
    ], null)
  else '{}'::text[] end as waiting_on,
  coalesce(mt.at_arrow, false) and sp.qty_done < sp.qty_required as at_arrow,
  coalesce(ho.held, false) as held_for_handoff
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id and j.is_active
left join lateral (
  -- nearest wood stage before this one that the sheet has
  select pre.department, pre.qty_done
    from ancestors a
    join sheet_progress pre on pre.sheet_id = sp.sheet_id and pre.department = a.anc
   where a.dept = sp.department
   order by a.depth
   limit 1
) up on true
left join lateral (
  -- the cabinet: Sanding, Finishing and Assembly / QC wait until Full Custom sends it
  select true as present, (select c.route from current_send(s.id, 'full_custom') c) as route
    from sheet_progress f
   where sp.department in ('sanding', 'finishing', 'assembly_qc')
     and f.sheet_id = sp.sheet_id and f.department = 'full_custom'
) fc on true
left join lateral (
  -- the metal: Assembly / QC waits for paint or Arrow; Metal paint waits for Metal's send
  select true as present, x.route, x.at_arrow,
         case when sp.department = 'metal_paint' then case when x.route = 'paint' then sp.qty_required else 0 end
              when x.at_arrow or x.route is null then 0
              when x.route = 'paint' then coalesce(x.paint_done, 0)
              else x.metal_done end as lim,
         case when sp.department = 'assembly_qc' and x.route = 'paint' then 'metal_paint' else 'metal' end as wait
    from (
      select m.qty_done as metal_done,
             (select c.route from current_send(s.id, 'metal') c) as route,
             (select p.qty_done from sheet_progress p where p.sheet_id = s.id and p.department = 'metal_paint') as paint_done,
             exists (select 1 from outside_jobs o
                      where o.job_id = j.id and o.returned_on is null and o.voided_at is null
                        and s.sheet_number = any (o.sheet_numbers)) as at_arrow
        from sheet_progress m
       where sp.department in ('assembly_qc', 'metal_paint')
         and m.sheet_id = sp.sheet_id and m.department = 'metal'
    ) x
) mt on true
left join lateral (
  -- 2 Oct: Milling, Metal and Full Custom don't see a job until Monday says it's handed off,
  -- unless the department has already counted on it (then it stays until it's done).
  -- Same jobs as the office's Handoffs list. Unknown (null) is never held; test jobs never are.
  select true as held
   where sp.department in ('milling', 'metal', 'full_custom')
     and not j.is_test and j.handed_off is false
     and not exists (select 1 from sheet_progress p2 join sheets s2 on s2.id = p2.sheet_id
                      where s2.work_order_id = w.id and p2.department = sp.department and p2.qty_done > 0)
) ho on true
cross join lateral (
  select least(coalesce(up.qty_done, sp.qty_required),
               case when fc.present and fc.route is null then 0 else sp.qty_required end,
               case when mt.present then mt.lim else sp.qty_required end,
               case when ho.held then 0 else sp.qty_required end,
               sp.qty_required) as available
) g;

revoke all on v_ready_to_work from anon;
grant select on v_ready_to_work to authenticated;

-- ---------------------------------------------------------------------
-- 2. Recently completed: jobs a department finished in the last 21 days
--    One row per sheet, like v_past_work, so the tablet shows it the same way.
-- ---------------------------------------------------------------------
drop view if exists v_recent_work;
create view v_recent_work with (security_invoker = true) as
with finished as (
  select w.job_id, sp.department,
         case when sp.department in ('full_custom', 'metal')
              then max(case when cs.route = 'before' then coalesce(sp.completed_at, cs.sent_at) else cs.sent_at end)
              else coalesce(max(sp.completed_at), max(sp.updated_at)) end as done_at
    from sheet_progress sp
    join sheets s      on s.id = sp.sheet_id
    join work_orders w on w.id = s.work_order_id and w.is_current
    left join lateral (select c.route, c.sent_at from current_send(s.id, sp.department) c
                        where sp.department in ('full_custom', 'metal')) cs on true
   group by w.job_id, sp.department
  having sum(sp.qty_required) > 0
     and bool_and(sp.qty_done >= sp.qty_required)
     and bool_and(sp.department not in ('full_custom', 'metal') or cs.route is not null)
),
worked as (   -- the department counted on this job on a tablet (any version of its work order)
  select distinct w.job_id, e.department
    from progress_events e
    join sheets s      on s.id = e.sheet_id
    join work_orders w on w.id = s.work_order_id
   where (e.source = 'Tablet' or (e.source is null and e.qty_from is not null))
     and e.qty_to > 0
)
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
  s.pdf_uploaded_at is not null    as pages_ready,
  w.id                             as work_order_id,
  w.version,
  j.id                             as job_id,
  j.project_id,
  j.name                           as job_name,
  j.delivery_date,
  j.materials_ordered,
  j.is_test,
  j.phase,
  f.done_at
from finished f
join worked k          on k.job_id = f.job_id and k.department = f.department
join jobs j            on j.id = f.job_id
join work_orders w     on w.job_id = j.id and w.is_current
join sheets s          on s.work_order_id = w.id
join sheet_progress sp on sp.sheet_id = s.id and sp.department = f.department
where (j.monday_item_id is not null or j.is_test)
  and f.done_at >= now() - interval '21 days'
  and j.is_test = am_test();
revoke all on v_recent_work from anon;
grant select on v_recent_work to authenticated;

-- ---------------------------------------------------------------------
-- 3. The check: builds its own jobs, tests as real logins, undoes it all
-- ---------------------------------------------------------------------
create or replace function check_handoff_recent()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; mill_u uuid; mt_u uuid; fc_u uuid; sand_u uuid; tst uuid;
  ja uuid; jb uuid; jc uuid; jt uuid; r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; rt uuid;
  w uuid; sa uuid; sb uuid; sc uuid; st uuid; x1 uuid; x2 uuid; x3 uuid; x4 uuid; x4b uuid; x5 uuid; xt uuid;
  v jsonb; n int; m int; ok boolean; msg text; t text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'milling' = any(departments) limit 1), mgr) into mill_u;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'metal' = any(departments) limit 1), mgr) into mt_u;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'full_custom' = any(departments) limit 1), mgr) into fc_u;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'sanding' = any(departments) limit 1), mgr) into sand_u;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;

  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- A: not handed off · B: handed off · C: Monday's answer unknown · T: a test job, not handed off
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999961, 'HOCHECK-A', 'Handoff check - undone automatically', true, 'In Production', local_today() + 20, false) returning id into ja;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999962, 'HOCHECK-B', 'Handoff check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into jb;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999963, 'HOCHECK-C', 'Handoff check - undone automatically', true, 'In Production', local_today() + 20, null) returning id into jc;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off, is_test)
      values (null, 'TEST-HOCHECK', 'Handoff check - undone automatically', true, 'In Production', local_today() + 20, false, true) returning id into jt;
    insert into work_orders (job_id, version) values (ja, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 2, 'HO-1') returning id into sa;
    insert into work_orders (job_id, version) values (jb, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'HO-2') returning id into sb;
    insert into work_orders (job_id, version) values (jc, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'HO-3') returning id into sc;
    insert into work_orders (job_id, version) values (jt, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'HO-4') returning id into st;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (sa, 'milling', 2, 0), (sa, 'cnc', 2, 0), (sa, 'metal', 2, 0), (sa, 'full_custom', 2, 0),
      (sb, 'milling', 1, 0), (sb, 'metal', 1, 0), (sc, 'milling', 1, 0), (sc, 'full_custom', 1, 0),
      (st, 'milling', 1, 0);

    -- ---- 1: not handed off = held from Milling, Metal and Full Custom ------------------------
    n := 0; msg := null;
    foreach t in array array['milling', 'metal', 'full_custom'] loop
      perform set_config('request.jwt.claims', json_build_object('sub', case t when 'milling' then mill_u when 'metal' then mt_u else fc_u end, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) into m from v_ready_to_work where job_id = ja and department = t and held_for_handoff and ready = 0;
        execute 'reset role';
      exception when others then execute 'reset role'; m := 0; msg := concat_ws(', ', msg, t || ': ' || sqlerrm);
      end;
      if m = 1 then n := n + 1; else msg := concat_ws(', ', msg, t || ' wasn''t held'); end if;
    end loop;
    res := res || check_row(1, 'A job Monday says isn''t handed off is held back from Milling, Metal and Full Custom', n = 3, msg);

    -- ---- 2: handed off, or Monday's answer unknown, is never held ---------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mill_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where not held_for_handoff and ready > 0), count(*) into n, m
        from v_ready_to_work where job_id in (jb, jc);
      execute 'reset role';
      ok := n = m and m >= 2; msg := format('%s of %s rows on the handed-off and unknown jobs were ready', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A handed-off job, or one Monday hasn''t answered for, is never held', ok, msg);

    -- ---- 3: once a department has counted, it keeps the job ------------------------------------------
    update sheet_progress set qty_done = 1 where sheet_id = sa and department = 'milling';
    perform set_config('request.jwt.claims', json_build_object('sub', mill_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select string_agg(format('%s:%s%s', department, ready, case when held_for_handoff then '(held)' else '' end), ' ' order by department) into msg
        from v_ready_to_work where job_id = ja and department in ('milling', 'cnc');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', mt_u, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select msg || ' ' || string_agg(format('%s:%s%s', department, ready, case when held_for_handoff then '(held)' else '' end), ' ') into msg
        from v_ready_to_work where job_id = ja and department = 'metal';
      execute 'reset role';
      ok := msg = 'cnc:1 milling:1 metal:0(held)';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Once Milling has counted a piece it keeps the job; CNC is as before; Metal is still held', ok, 'Got: ' || coalesce(msg, 'nothing'));

    -- ---- 4: test jobs are never held -----------------------------------------------------------------
    if tst is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) into n from v_ready_to_work where job_id = jt and not held_for_handoff and ready = 1;
        execute 'reset role';
        ok := n = 1; msg := 'The test job was held back from the Test Supervisor.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(4, 'Test jobs are never held', ok, msg);
    end if;

    -- ---- 5: older pages keep working ---------------------------------------------------------------
    select string_agg(column_name, ',' order by ordinal_position) into msg from information_schema.columns
     where table_schema = 'public' and table_name = 'v_ready_to_work';
    res := res || check_row(5, 'What''s ready keeps every column older pages read, with the new one last', 
      msg = 'department,sheet_id,job_id,ready,available,waiting_on,at_arrow,held_for_handoff', 'Columns: ' || coalesce(msg, 'none'));

    -- ---- Recently completed ------------------------------------------------------------------------
    -- R1 finished on a tablet today · R2 finished by the catch-up · R3 finished 30 days ago ·
    -- R4 half finished · R5 Full Custom, finished then sent · RT a test job finished on a tablet
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999964, 'RECHECK-1', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into r1;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999965, 'RECHECK-2', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into r2;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999966, 'RECHECK-3', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into r3;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999967, 'RECHECK-4', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into r4;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999968, 'RECHECK-5', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into r5;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test)
      values (null, 'TEST-RECHECK', 'Recent check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into rt;
    insert into work_orders (job_id, version) values (r1, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RC-1') returning id into x1;
    insert into work_orders (job_id, version) values (r2, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RC-2') returning id into x2;
    insert into work_orders (job_id, version) values (r3, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RC-3') returning id into x3;
    insert into work_orders (job_id, version) values (r4, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RC-4') returning id into x4;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 2, 1, 'RC-4') returning id into x4b;
    insert into work_orders (job_id, version) values (r5, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w, 1, 1, 'RC-5', 'rc5') returning id into x5;
    insert into work_orders (job_id, version) values (rt, 1) returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RC-6') returning id into xt;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (x1, 'sanding', 1, 0), (x2, 'sanding', 1, 0), (x3, 'sanding', 1, 0), (x4, 'sanding', 1, 0), (x4b, 'sanding', 1, 0),
      (x5, 'full_custom', 1, 0), (x5, 'finishing', 1, 0), (xt, 'sanding', 1, 0);
    update sheet_progress set qty_done = 1 where sheet_id in (x1, x3, x4, xt) and department = 'sanding';     -- counted on a tablet
    update sheet_progress set qty_done = 1 where sheet_id = x5 and department = 'full_custom';
    perform set_config('shopfloor.source', 'Catch-up from Monday', true);
    update sheet_progress set qty_done = 1 where sheet_id = x2 and department = 'sanding';                    -- marked done by the catch-up
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set completed_at = now() - interval '30 days' where sheet_id = x3 and department = 'sanding';

    -- ---- 6: which finished jobs show -----------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sand_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select string_agg(distinct project_id, ' ' order by project_id) into msg
        from v_recent_work where department = 'sanding' and project_id like 'RECHECK-%';
      execute 'reset role';
      ok := msg = 'RECHECK-1';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Recently completed shows a job finished on the tablet; not one the catch-up marked done, one finished over 3 weeks ago, or one half done', ok,
      'Got: ' || coalesce(msg, 'nothing') || ' (wanted RECHECK-1 only)');

    -- ---- 7: a sender's job shows once it's sent on ---------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', fc_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_recent_work where job_id = r5;
      v := send_sheet(x5, 'full_custom', 'finishing');
      select count(*) into m from v_recent_work where job_id = r5;
      execute 'reset role';
      ok := n = 0 and m = 1; msg := format('Before the send: %s rows (0). After: %s (1).', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'For Full Custom and Metal, a job shows once its sheets are sent on', ok, msg);

    -- ---- 8: lanes ------------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sand_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_recent_work where job_id = rt;
      execute 'reset role';
      m := 1;
      if tst is not null then
        perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) filter (where job_id = rt), count(*) filter (where not is_test) into m, t from v_recent_work;
        execute 'reset role';
      end if;
      ok := n = 0 and m = 1 and coalesce(t, '0') = '0';
      msg := format('A real login saw %s test rows (0); the Test Supervisor saw %s of the test job (1) and %s real rows (0).', n, m, coalesce(t, '0'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Test jobs and real jobs stay in their own lanes', ok, msg);

    -- ---- 9: no login ---------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    foreach t in array array['v_ready_to_work', 'v_recent_work'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        if m > 0 then n := n + m; msg := concat_ws(', ', msg, format('%s rows of %s', m, t)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; n := n + 1; msg := concat_ws(', ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(9, 'Someone with no login sees nothing', n = 0, coalesce(msg, '') || '. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_handoff_recent_undo__';
  exception when others then
    if sqlerrm <> '__check_handoff_recent_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('shopfloor.source', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_handoff_recent() from public, anon, authenticated;

select * from check_handoff_recent();
