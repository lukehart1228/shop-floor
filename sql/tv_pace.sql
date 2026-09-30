-- =====================================================================
-- Shop Floor — the floor TV, with pace (1 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it changes: only tv_snapshot, the one thing the TV reads. It
-- keeps every number the old TV page reads, so the TV keeps working
-- whichever page it has. It adds:
--   · pace per live department: this week so far, and a usual week
--     (the Pace page's 4-week average). Decided 1 Oct: pace is shown
--     on the floor TV.
--   · work-stopped issues on their own
--   · going out: white glove trips in the next 7 days, pickups ready
--     to collect, and today's finished trips
-- and one fix: "at Arrow too long" only counts items that have gone.
--
-- Still true: no login sees anything without the TV link; test jobs
-- never appear; no project values, no per-person numbers.
--
-- Replaces tv.sql's tv_snapshot, so tv.sql now stops if run again.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('tv_pace.sql', '{tv.sql}'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.tv_snapshot(text)') is null or to_regclass('public.v_pace_done') is null
     or not exists (select 1 from information_schema.columns where table_name = 'loadouts' and column_name = 'pickup_steps')
     or not exists (select 1 from information_schema.columns where table_name = 'outside_jobs' and column_name = 'waiting') then
    raise exception 'Run tv.sql, pace.sql, arrow_pickup.sql and delivery_types.sql first. This file builds on them.';
  end if;
end $$;

create or replace function tv_snapshot(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_hash  text;
  v_today date := local_today();
  v_alert int;
  v_out   jsonb;
  tz      constant text := 'America/Indiana/Indianapolis';
  v_week  date;
  v_first date;
  v_used  int;
begin
  select value #>> '{}' into v_hash from app_settings where key = 'secret_tv_key_hash';
  if v_hash is null or nullif(p_key, '') is null or encode(sha256(convert_to(p_key, 'UTF8')), 'hex') <> v_hash then
    return jsonb_build_object('ok', false,
      'reason', 'This TV link isn''t valid any more. Make a new one on the office page (Setup → TV link) and open it on this screen.');
  end if;
  select coalesce((select (value #>> '{}')::int from app_settings where key = 'arrow_alert_days'), 14) into v_alert;

  with live as (
    select key, name, sort_order from departments where is_live and not log_only
  ),
  r as (      -- every live-department count on real, active, linked jobs
    select j.id as job_id, j.project_id, j.name as job_name, j.delivery_date, j.materials_ordered,
           sp.department, sp.qty_done, sp.qty_required, coalesce(rw.ready, 0) as ready
      from sheet_progress sp
      join live l        on l.key = sp.department
      join sheets s      on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id and w.is_current
      join jobs j        on j.id = w.job_id and j.is_active and not j.is_test and j.monday_item_id is not null
      left join v_ready_to_work rw on rw.sheet_id = sp.sheet_id and rw.department = sp.department
  ),
  per_job as (
    select job_id, project_id, job_name, delivery_date, materials_ordered,
           sum(qty_required - qty_done) as left_n, sum(qty_done) as done_n, sum(qty_required) as total_n
      from r group by job_id, project_id, job_name, delivery_date, materials_ordered
  ),
  on_floor as (select * from per_job where left_n > 0),
  per_dept as (
    select l.key, l.name, l.sort_order,
           coalesce(sum(r.qty_required - r.qty_done), 0) as left_n,
           coalesce(sum(r.ready), 0) as ready_n,
           count(distinct r.job_id) filter (where r.qty_done < r.qty_required) as jobs_n
      from live l left join r on r.department = l.key
     group by l.key, l.name, l.sort_order
  ),
  open_flags as (
    select f.job_id, f.level, f.note, f.department, d.name as department_name, j.project_id, j.name as job_name
      from flags f join jobs j on j.id = f.job_id
      left join departments d on d.key = f.department
     where f.cleared_at is null and not f.is_test and j.is_active
       and (f.department is null or f.department in (select key from live))
  ),
  tbl as (
    select o.*, (o.delivery_date - v_today) as days,
           (select case max(case level when 'critical' then 3 when 'priority' then 2 else 1 end)
                   when 3 then 'critical' when 2 then 'priority' when 1 then 'watch' end
              from open_flags f where f.job_id = o.job_id) as flag
      from on_floor o
     order by o.delivery_date nulls last, o.project_id
     limit 15
  ),
  attention as (
    select 1 as ord, p.raised_at as at,
           left(format('%s%s · %s: %s', j.project_id, coalesce(' sheet ' || p.sheet_number, ''), d.name, p.body), 160) as text,
           'stopped' as kind
      from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
     where p.status = 'open' and p.work_stopped and not p.is_test and j.is_active
       and p.department in (select key from live)
    union all
    select 2, o.sent_at,
           format('%s at Arrow %s days — %s', j.project_id, v_today - o.sent_on,
                  coalesce(o.description, 'sheet' || case when cardinality(o.sheet_numbers) = 1 then ' ' else 's ' end
                                          || array_to_string(o.sheet_numbers, ', '))),
           'arrow'
      from outside_jobs o join jobs j on j.id = o.job_id
     where o.returned_on is null and o.voided_at is null and not o.is_test and not coalesce(o.waiting, false)
       and v_today - o.sent_on > v_alert
    union all
    select 3, null, format('%s — materials not marked ordered in Monday, due in %s days', t.project_id, t.days), 'materials'
      from tbl t where not t.materials_ordered and t.days <= 14
  )
  select jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'today', v_today,
    'arrow_alert_days', v_alert,
    'live', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'name', name, 'left', left_n, 'ready', ready_n, 'jobs', jobs_n)
                                       order by sort_order) from per_dept), '[]'::jsonb),
    'kpis', jsonb_build_object(
       'jobs',  (select count(*) from on_floor),
       'left',  (select coalesce(sum(left_n), 0) from on_floor),
       'ready', (select coalesce(sum(ready_n), 0) from per_dept),
       'due14', (select count(*) from on_floor where delivery_date - v_today <= 14)),
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'table', coalesce((select jsonb_agg(jsonb_build_object(
                 'project_id', t.project_id, 'job_name', t.job_name, 'delivery_date', t.delivery_date, 'days', t.days,
                 'flag', t.flag,
                 'depts', (select jsonb_agg(jsonb_build_object('key', l.key,
                                   'done', coalesce((select sum(qty_done) from r where r.job_id = t.job_id and r.department = l.key), 0),
                                   'total', coalesce((select sum(qty_required) from r where r.job_id = t.job_id and r.department = l.key), 0))
                                   order by l.sort_order) from live l))
               order by t.delivery_date nulls last, t.project_id) from tbl t), '[]'::jsonb),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;

  -- ---- added by tv_pace.sql: everything above is unchanged, so an older TV page still works ----

  -- pace: this week so far, and a usual week = the average of the last 4 finished weeks
  -- (the same numbers as the Pace page's 4-week view: tablet counts only, never test jobs)
  v_week := pace_week(now());
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0
                 else least(4, greatest((v_week - greatest(v_first, v_week - 28)) / 7, 0)) end;

  v_out := v_out || jsonb_build_object(
    'version', 2,
    'pace_weeks', v_used,
    'pace', coalesce((
      with done as (
        select department,
               sum(main) filter (where week_start = v_week) as this_week,
               sum(main) filter (where week_start >= v_week - 7 * v_used and week_start < v_week) as before
          from v_pace_done where week_start >= v_week - 28
         group by department)
      select jsonb_agg(jsonb_build_object(
               'key', d.key, 'name', d.name,
               'measure', case when d.key in ('metal', 'full_custom', 'metal_paint') then 'pieces' else 'sqft' end,
               'this_week', round(coalesce(x.this_week, 0), 1),
               'usual', case when v_used > 0 then round(coalesce(x.before, 0) / v_used, 1) end,
               'days', to_jsonb(s.days)) order by d.sort_order)
        from departments d
        left join done x on x.department = d.key
        left join v_pace_schedules s on s.department = d.key
       where d.is_live and not d.log_only), '[]'::jsonb),

    -- work stopped: open issues ticked "work stopped", real jobs, live departments
    'stopped', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', j.project_id, 'job_name', j.name, 'sheet_number', p.sheet_number,
                                          'department', d.name, 'body', left(p.body, 200)) order by p.raised_at)
        from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
       where p.status = 'open' and p.work_stopped and not p.is_test and not j.is_test and j.is_active
         and d.is_live and not d.log_only), '[]'::jsonb),

    -- going out: white glove trips in the next 7 days, pickups waiting to be collected, and today's finished trips
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object('kind', t.kind, 'project_id', t.project_id, 'job_name', t.job_name,
                                          'date', t.on_day, 'time', t.at_time, 'ready', t.grp = 2, 'done_at', t.done_at)
                       order by t.on_day, t.grp, t.sort_at)
        from (select l.kind, j.project_id, j.name as job_name,
                     case when l.completed_at is not null then 0 when l.kind = 'delivery' then 1 else 2 end as grp,
                     case when l.completed_at is not null then (l.completed_at at time zone tz)::date
                          when l.kind = 'delivery' then (l.scheduled_for at time zone tz)::date
                          else v_today end as on_day,
                     case when l.completed_at is null and l.kind = 'delivery' then to_char(l.scheduled_for at time zone tz, 'FMHH12:MI') end as at_time,
                     case when l.completed_at is not null then to_char(l.completed_at at time zone tz, 'FMHH12:MI') end as done_at,
                     coalesce(l.completed_at, l.scheduled_for, l.ready_at) as sort_at
                from loadouts l join jobs j on j.id = l.job_id
               where l.voided_at is null and not l.is_test and not j.is_test
                 and (   (l.completed_at is not null and (l.completed_at at time zone tz)::date = v_today)
                      or (l.completed_at is null and l.kind = 'delivery' and l.scheduled_for is not null
                          and (l.scheduled_for at time zone tz)::date between v_today and v_today + 6)
                      or (l.completed_at is null and l.kind <> 'delivery' and l.pickup_steps and l.ready_at is not null))
               order by on_day, grp, sort_at
               limit 12) t), '[]'::jsonb)
  );
  return v_out;
end $$;
revoke all on function tv_snapshot(text) from public;
grant execute on function tv_snapshot(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- The check: select * from check_tv();   (undoes itself)
-- ---------------------------------------------------------------------
create or replace function check_tv()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the TV and a manager
declare
  res     jsonb := '[]';
  mgr     uuid;  as_mgr text;
  v_key   text;
  v       jsonb;  v0 jsonb;  r jsonb;
  v_job   uuid;  v_wo uuid;  s1 uuid;  v_test uuid;
  v_dept  text;  v_each numeric;
  tz      constant text := 'America/Indiana/Indianapolis';
  ok      boolean;  msg text;  n int;  a numeric;  b numeric;  tbl text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager has a login', false, 'No manager login found.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  select key into v_dept from departments where is_live and not log_only order by sort_order limit 1;

  begin    -- everything below is undone at the end, whatever happens
    -- a TV link, made the way the office makes one (undone at the end: the real TV link keeps working)
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v_key := new_tv_link()->>'key';
    execute 'reset role';

    -- a throwaway real job and a test job, both undone at the end
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999961, 'TVCHECK', 'TV check - undone automatically', true, 'In Production', local_today() + 5) returning id into v_job;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test)
      values (-999962, 'TEST-TVCHECK', 'TV check test job - undone automatically', true, 'In Production', local_today() + 5, true) returning id into v_test;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length)
      values (v_wo, 1, 2, 'TV-1', '36"', null) returning id into s1;          -- a 36" round: 9 sq ft each
    if v_dept is not null then
      insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1, v_dept, 2, 0);
    end if;

    -- the TV's view before the new things below
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v0 := tv_snapshot(v_key);
    execute 'reset role';

    -- trips on the real job: one in 2 days at 8:00, one cancelled, one too far off, a pickup waiting, one delivered today
    insert into loadouts (job_id, kind, scheduled_for) values
      (v_job, 'delivery', ((local_today() + 2)::timestamp + interval '8 hours') at time zone tz);
    insert into loadouts (job_id, kind, scheduled_for, voided_at, void_reason) values
      (v_job, 'delivery', ((local_today() + 1)::timestamp + interval '9 hours 15 minutes') at time zone tz, now(), 'TV check');
    insert into loadouts (job_id, kind, scheduled_for) values
      (v_job, 'delivery', ((local_today() + 10)::timestamp + interval '9 hours 45 minutes') at time zone tz);
    insert into loadouts (job_id, kind, pickup_steps, ready_at) values (v_job, 'customer_pickup', true, now());
    insert into loadouts (job_id, kind, scheduled_for, completed_at) values
      (v_job, 'delivery', (local_today()::timestamp + interval '7 hours') at time zone tz, now());
    -- and one on the test job
    insert into loadouts (job_id, kind, scheduled_for, is_test) values
      (v_test, 'delivery', ((local_today() + 1)::timestamp + interval '10 hours') at time zone tz, true);

    if v_dept is not null then
      -- work stopped (and an ordinary issue that isn't), plus a stopped issue on the test job
      insert into problems (job_id, sheet_number, department, body, work_stopped, status)
        values (v_job, 1, v_dept, 'TV check: stopped, undone automatically', true, 'open');
      insert into problems (job_id, sheet_number, department, body, work_stopped, status)
        values (v_job, 1, v_dept, 'TV check: not stopped, undone automatically', false, 'open');
      insert into problems (job_id, sheet_number, department, body, work_stopped, status, is_test)
        values (v_test, 1, v_dept, 'TV check: test lane, undone automatically', true, 'open', true);
      -- a tablet count this week: 2 pieces
      perform set_config('shopfloor.source', '', true);
      update sheet_progress set qty_done = 2 where sheet_id = s1 and department = v_dept;
      select main_each into v_each from v_pace_units where sheet_id = s1 and department = v_dept;
    end if;

    -- Arrow: one still waiting to go, one gone 30 days ago
    insert into outside_jobs (job_id, sheet_numbers, description, service, department, sent_on, waiting)
      values (v_job, '{1}', 'TVCHECK waiting', 'powdercoat', 'metal', local_today() - 30, true),
             (v_job, '{1}', 'TVCHECK gone', 'powdercoat', 'metal', local_today() - 30, false);

    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v := tv_snapshot(v_key);
    execute 'reset role';

    -- ---- 1. old and new parts ---------------------------------------------------
    ok := (v->>'ok')::boolean and (v->>'version')::int = 2
          and v ?& array['live', 'kpis', 'donut', 'table', 'critical', 'attention', 'pace', 'stopped', 'trips']
          and jsonb_array_length(v->'pace') = jsonb_array_length(v->'live');
    res := res || check_row(1, 'The TV gets pace, work stopped and going out, and still everything an older TV page reads', coalesce(ok, false),
      'Something is missing from the TV''s numbers. Run tv_pace.sql again from the top.');

    -- ---- 2. no link, nothing -------------------------------------------------------
    begin
      execute 'set local role anon';
      r := tv_snapshot('not-the-key');
      execute 'reset role';
      ok := not (r->>'ok')::boolean and not (r ?| array['live', 'pace', 'trips', 'stopped', 'donut']);
      msg := 'The TV handed out numbers without its link. Do not go further; bring this to Claude.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Without the TV link, it shows nothing', ok, msg);

    -- ---- 3. pace matches the Pace page ----------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := pace_report(4);
      execute 'reset role';
      select count(*) into n
        from jsonb_array_elements(v->'pace') t
        join jsonb_array_elements(r->'departments') p on p->>'key' = t->>'key'
       where (t->>'this_week')::numeric = (p->>'this_week')::numeric
         and (t->>'usual') is not distinct from (p->>'pace')
         and t->>'measure' = p->>'measure';
      ok := n = jsonb_array_length(v->'pace') and (v->>'pace_weeks')::int = (r->>'weeks_used')::int;
      msg := format('Only %s of %s departments matched the Pace page''s 4-week numbers.', n, jsonb_array_length(v->'pace'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Each department''s pace is the Pace page''s: this week so far, and the 4-week average', ok, msg);

    -- ---- 4. a tablet count shows up this week -------------------------------------------
    if v_dept is null then
      res := res || check_row(4, 'A tablet count adds to this week''s pace', true);
    else
      select (x->>'this_week')::numeric into a from jsonb_array_elements(v0->'pace') x where x->>'key' = v_dept;
      select (x->>'this_week')::numeric into b from jsonb_array_elements(v->'pace') x where x->>'key' = v_dept;
      ok := b - a = 2 * v_each;
      res := res || check_row(4, 'A tablet count adds to this week''s pace', coalesce(ok, false),
        format('Counting 2 pieces (%s each) in %s changed this week from %s to %s.', v_each, v_dept, a, b));
    end if;

    -- ---- 5. going out -------------------------------------------------------------------
    select count(*),
           count(*) filter (where x->>'time' = '8:00' and (x->>'date')::date = local_today() + 2)
         + count(*) filter (where (x->>'ready')::boolean and x->>'kind' = 'customer_pickup')
         + count(*) filter (where x->>'done_at' is not null and (x->>'date')::date = local_today())
      into n, a
      from jsonb_array_elements(v->'trips') x where x->>'project_id' = 'TVCHECK';
    ok := n = 3 and a = 3;
    res := res || check_row(5, 'Going out: trips in the next 7 days, pickups ready, today''s delivered; never a cancelled or far-off trip', coalesce(ok, false),
      format('Expected 3 of the check''s 5 trips (in 2 days at 8:00, the pickup, today''s delivered). Got %s.', n));

    -- ---- 6. work stopped ----------------------------------------------------------------
    if v_dept is null then
      res := res || check_row(6, 'A work-stopped issue shows; an ordinary one doesn''t', true);
    else
      ok := v->'stopped' @> '[{"project_id": "TVCHECK", "body": "TV check: stopped, undone automatically"}]'::jsonb
            and (v->'stopped')::text not like '%not stopped, undone%';
      res := res || check_row(6, 'A work-stopped issue shows; an ordinary one doesn''t', coalesce(ok, false),
        'The stopped issue was missing, or an issue without "work stopped" showed.');
    end if;

    -- ---- 7. test jobs --------------------------------------------------------------------
    ok := v::text not like '%TEST-TVCHECK%' and v::text not like '%test lane, undone%';
    res := res || check_row(7, 'Test jobs never reach the TV (trips and issues included)', ok,
      'A test job''s trip or issue showed on the TV. Do not go further; bring this to Claude.');

    -- ---- 8. Arrow ------------------------------------------------------------------------
    ok := (v->'attention')::text like '%TVCHECK gone%' and (v->'attention')::text not like '%TVCHECK waiting%';
    res := res || check_row(8, '"At Arrow too long" counts only items that have gone', ok,
      'An item still waiting to go counted as at Arrow, or a long-gone one was missing.');

    -- ---- 9. no login --------------------------------------------------------------------
    -- tried the way Supabase does it: as no login, row by row (the check's own trips, issues and count exist right now)
    ok := has_function_privilege('anon', 'public.tv_snapshot(text)', 'execute')
          and not has_function_privilege('anon', 'public.pace_report(integer)', 'execute');
    msg := case when ok then null else 'The TV couldn''t read its numbers, or anyone could read the Pace page.' end;
    perform set_config('request.jwt.claims', '', true);
    foreach tbl in array array['loadouts', 'problems', 'outside_jobs', 'v_pace_done', 'pace_schedules'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', tbl) into n;
        execute 'reset role';
        if n > 0 then ok := false; msg := concat_ws(' ', msg, format('%s rows of %s visible.', n, tbl)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := concat_ws(' ', msg, format('%s: %s', tbl, sqlerrm));
      end;
    end loop;
    res := res || check_row(9, 'With no login, only the TV''s own numbers can be read, and only with the link', ok,
      coalesce(msg, '') || ' Do not go further; bring this to Claude.');

    raise exception using errcode = 'P0001', message = '__check_tv_undo__';
  exception when others then
    if sqlerrm <> '__check_tv_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('shopfloor.source', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_tv() from public, anon, authenticated;

select * from check_tv();
