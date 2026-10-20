-- =====================================================================
-- Shop Floor — "Coming up" on the floor TV (20 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table. Run this BEFORE tv.html goes on GitHub (either order works, but
-- the TV only shows Coming up once this has run).
--
-- WHAT IT DOES
-- The floor TV's right-hand panel becomes Coming up: the next 10 jobs on
-- the floor (Monday's Phase is In Production) by Monday's delivery date,
-- today or later, with the job's PROJ number, name and delivery date.
-- tv_snapshot sends them as 'coming' (version 4). Nothing else it sends
-- changes: the pace and pieces-ready numbers are still sent, so the TV
-- page from before keeps working; the new page just doesn't draw them.
-- No new table, no new function a login or the TV can call.
--
-- Replaces tv_snapshot from tv_photos.sql, so that file now stops if run
-- again. Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('tv_coming.sql', '{tv_photos.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.check_tv_photos()') is null then raise exception 'Run tv_photos.sql first. This file builds on it.'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The TV's snapshot: everything tv_photos.sql gave it, plus 'coming'.
-- ---------------------------------------------------------------------
create or replace function public.tv_snapshot(p_key text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
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
  tbl as (      -- still worked out: the attention list's materials line comes from it
    select o.*, (o.delivery_date - v_today) as days
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
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;

  -- ---- tv_pace.sql: pace, work stopped, going out ----
  v_week := pace_week(now());
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0
                 else least(4, greatest((v_week - greatest(v_first, v_week - 28)) / 7, 0)) end;

  v_out := v_out || jsonb_build_object(
    'version', 4,
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

    'stopped', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', j.project_id, 'job_name', j.name, 'sheet_number', p.sheet_number,
                                          'department', d.name, 'body', left(p.body, 200)) order by p.raised_at)
        from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
       where p.status = 'open' and p.work_stopped and not p.is_test and not j.is_test and j.is_active
         and d.is_live and not d.log_only), '[]'::jsonb),

    'trips', coalesce((
      select jsonb_agg(jsonb_build_object('kind', t.kind, 'project_id', t.project_id, 'job_name', t.job_name,
                                          'date', t.on_day, 'time', t.at_time, 'ready', t.grp = 2, 'done_at', t.done_at)
                       order by t.on_day, t.grp, t.sort_at)
        from (select * from (select l.kind, j.project_id, j.name as job_name,
                     case when l.completed_at is not null then 0 when l.kind in ('delivery', 'dock') then 1 else 2 end as grp,
                     case when l.completed_at is not null then (l.completed_at at time zone tz)::date
                          when l.kind in ('delivery', 'dock') then (l.scheduled_for at time zone tz)::date
                          else v_today end as on_day,
                     case when l.completed_at is null and l.kind in ('delivery', 'dock') then to_char(l.scheduled_for at time zone tz, 'FMHH12:MI') end as at_time,
                     case when l.completed_at is not null then to_char(l.completed_at at time zone tz, 'FMHH12:MI') end as done_at,
                     coalesce(l.completed_at, l.scheduled_for, l.ready_at) as sort_at
                from loadouts l join jobs j on j.id = l.job_id
               where l.voided_at is null and not l.is_test and not j.is_test
                 and (   (l.completed_at is not null and (l.completed_at at time zone tz)::date = v_today)
                      or (l.completed_at is null and l.kind in ('delivery', 'dock') and l.scheduled_for is not null
                          and (l.scheduled_for at time zone tz)::date between v_today and v_today + 6)
                      or (l.completed_at is null and l.kind not in ('delivery', 'dock') and l.pickup_steps and l.ready_at is not null))

               union all
               select 'delivery', coalesce(j.project_id, 'Task'), left(coalesce(nullif(k.for_text, '') || ': ', '') || k.what, 80),
                      1, (k.scheduled_for at time zone tz)::date, to_char(k.scheduled_for at time zone tz, 'FMHH12:MI'), null, k.scheduled_for
                 from delivery_tasks k left join jobs j on j.id = k.job_id
                where k.voided_at is null and k.done_at is null and not k.is_test and not coalesce(j.is_test, false)
                  and (k.scheduled_for at time zone tz)::date between v_today and v_today + 6) u
               order by on_day, grp, sort_at
               limit 12) t), '[]'::jsonb),

    -- tv_photos.sql: in its new home. The gate's rows in round order; no image data here.
    'home', coalesce((
      select jsonb_agg(jsonb_build_object('id', h.photo_id, 'project_id', h.project_id, 'delivered_on', h.delivered_on,
                                          'tables', h.tables) order by h.ord)
        from tv_home_pictures() h), '[]'::jsonb),

    -- tv_coming.sql: coming up. The next 10 jobs on the floor by Monday's delivery date,
    -- today or later: the PROJ number, the job's name and the date, nothing else.
    'coming', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', c.project_id, 'job_name', c.name, 'delivery_date', c.delivery_date)
                       order by c.delivery_date, c.project_id)
        from (select j.project_id, j.name, j.delivery_date
                from jobs j
               where j.is_active and not j.is_test and j.monday_item_id is not null
                 and j.delivery_date is not null and j.delivery_date >= v_today
               order by j.delivery_date, j.project_id
               limit 10) c), '[]'::jsonb)
  );
  return v_out;
end $function$;
revoke all on function tv_snapshot(text) from public;
grant execute on function tv_snapshot(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. The check: select * from check_tv_coming();   (undoes itself)
-- ---------------------------------------------------------------------
create or replace function check_tv_coming()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the TV and a manager
declare
  res    jsonb := '[]';
  mgr    uuid;  as_mgr text;
  v_key  text;
  v      jsonb;  r jsonb;
  t0     date := local_today();
  ok     boolean;  msg text;  n int;  got text;
  i      int;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin    -- everything below is undone at the end, whatever happens; the real TV link keeps working
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v_key := new_tv_link()->>'key';
    execute 'reset role';

    -- jobs that sort first ('0TVC…' before 'PROJ-…') so the check sees them whatever is on the floor
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values
      (-999901, '0TVC-A', 'Coming check A - undone automatically', true, 'In Production', t0),
      (-999902, '0TVC-B', 'Coming check B - undone automatically', true, 'In Production', t0 + 1);
    -- and ones that must never show, dated today so they would come first if they did
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values
      (-999903, '0TVC-0PAST',  'Coming check past - undone automatically', true, 'In Production', t0 - 1),
      (-999904, '0TVC-0NODATE', 'Coming check no date - undone automatically', true, 'In Production', null),
      (-999905, '0TVC-0DONE',  'Coming check not in production - undone automatically', false, 'Delivered', t0);
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test) values
      (-999906, '0TVC-0TEST', 'Coming check test job - undone automatically', true, 'In Production', t0, true);

    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v := tv_snapshot(v_key);
    execute 'reset role';

    -- ---- 1. the TV gets Coming up, and everything it had --------------------------------
    ok := (v->>'ok')::boolean and (v->>'version')::int >= 4
          and jsonb_typeof(v->'coming') = 'array'
          and v ?& array['live', 'donut', 'critical', 'attention', 'pace', 'stopped', 'trips', 'home']
          and not (v ?| array['table', 'kpis']);
    res := res || check_row(1, 'The TV gets Coming up, and still gets its numbers, going out and the pictures list (and not the job table it never showed)', coalesce(ok, false),
      'Coming up is missing, or something the TV had is gone. Run tv_coming.sql again from the top.');

    -- ---- 2. earliest delivery first, today or later ---------------------------------------
    select string_agg(x->>'project_id', ',' order by o) into got from jsonb_array_elements(v->'coming') with ordinality t(x, o) where o <= 2;
    select count(*) into n from jsonb_array_elements(v->'coming') with ordinality a(x, o)
      join jsonb_array_elements(v->'coming') with ordinality b(y, p) on p = o + 1
     where (x->>'delivery_date')::date > (y->>'delivery_date')::date
        or ((x->>'delivery_date')::date = (y->>'delivery_date')::date and x->>'project_id' > y->>'project_id');
    ok := got like '0TVC-A,%' and n = 0
          and not exists (select 1 from jsonb_array_elements(v->'coming') x where (x->>'delivery_date')::date < t0);
    res := res || check_row(2, 'Jobs come in delivery-date order, earliest first, from today on', coalesce(ok, false),
      format('The order is wrong or an earlier date shows (first two: %s). Bring this to Claude.', coalesce(got, 'none')));

    -- ---- 3. never: past dates, no date, not In Production, test jobs ----------------------
    select string_agg(x->>'project_id', ', ') into got from jsonb_array_elements(v->'coming') x
     where x->>'project_id' in ('0TVC-0PAST', '0TVC-0NODATE', '0TVC-0DONE', '0TVC-0TEST');
    ok := got is null;
    res := res || check_row(3, 'A job past its date, with no date, not In Production, or in the test lane never shows', ok,
      format('These showed: %s. Bring this to Claude.', got));

    -- ---- 4. only the PROJ number, the name and the date ------------------------------------
    select count(*) into n from jsonb_array_elements(v->'coming') x
     where (select array_agg(k order by k) from jsonb_object_keys(x) k) <> array['delivery_date', 'job_name', 'project_id'];
    ok := n = 0 and exists (select 1 from jsonb_array_elements(v->'coming') x
                             where x->>'project_id' = '0TVC-A' and x->>'job_name' = 'Coming check A - undone automatically' and (x->>'delivery_date')::date = t0);
    res := res || check_row(4, 'Each job shows only its PROJ number, its name from Monday and its delivery date', ok,
      'A row carries something else, or the wrong name or date. Bring this to Claude.');

    -- ---- 5. at most 10 ----------------------------------------------------------------------
    for i in 1..11 loop
      insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
        values (-999910 - i, format('0TVC-%s', lpad(i::text, 2, '0')), 'Coming check - undone automatically', true, 'In Production', t0);
    end loop;
    execute 'set local role anon';
    v := tv_snapshot(v_key);
    execute 'reset role';
    select string_agg(x->>'project_id', ',' order by o) into got from jsonb_array_elements(v->'coming') with ordinality t(x, o);
    ok := jsonb_array_length(v->'coming') = 10
          and got = '0TVC-01,0TVC-02,0TVC-03,0TVC-04,0TVC-05,0TVC-06,0TVC-07,0TVC-08,0TVC-09,0TVC-10';
    res := res || check_row(5, 'Never more than the next 10', coalesce(ok, false),
      format('%s jobs came, expected the first 10. Bring this to Claude.', jsonb_array_length(v->'coming')));

    -- ---- 6. no link, nothing; and nothing new runs without a login --------------------------
    begin
      execute 'set local role anon';
      r := tv_snapshot('not-the-key');
      execute 'reset role';
      ok := not (r->>'ok')::boolean and not (r ? 'coming');
      msg := 'The TV handed out its list without its link.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    select count(*) into n from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prosecdef
       and has_function_privilege('anon', p.oid, 'execute')
       and p.proname not in ('my_role', 'owns_dept', 'tv_snapshot', 'tv_photo');
    ok := ok and n = 0 and has_function_privilege('anon', 'public.tv_snapshot(text)', 'execute')
          and not has_function_privilege('anon', 'public.check_tv_coming()', 'execute');
    res := res || check_row(6, 'Without the TV link it shows nothing, and nothing new runs without a login', ok,
      coalesce(msg, '') || format(' %s other functions run with no login.', n) || ' Do not go further; bring this to Claude.');

    raise exception using errcode = 'P0001', message = '__check_tv_coming_undo__';
  exception when others then
    execute 'reset role';
    if sqlerrm <> '__check_tv_coming_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_tv_coming() from public, anon, authenticated;

select * from check_tv_coming();
