-- =====================================================================
-- Shop Floor — Pace and time in stage (designed and built 25 Sep)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_pace();
--
-- What it adds (nothing existing is changed; nothing on the tablets):
--   1. pace_schedules — each department's working days, for "wait to
--      start" and "working time". One row per change; the newest is in
--      use. Starting schedule: Mon–Thu, except Finishing every day
--      (Jim comes in on his own schedule, weekends included).
--   2. How a sheet is measured in each department:
--        Milling, CNC, Sanding, Finishing: square feet of top — the full
--          rectangle, a round is diameter × diameter (as the scrap rate).
--        Sanding and Finishing also count cabinets: a sheet with Full
--          Custom on it that goes to Sanding or Finishing. A cabinet sheet
--          with no readable top size is a cabinet only.
--        Assembly / QC: square feet when the sheet has a top (it goes
--          through a wood stage); otherwise its pieces are counted as
--          "pieces without a top" (bases).
--        Metal and Full Custom: pieces.
--   3. Pace: what the tablets counted each week (Monday to Sunday), in
--      those units. Only tablet counts — Advance, catch-up, uploads and
--      test jobs are left out. Counts are absolute, so a correction down
--      takes back what it should.
--   4. Time in stage, per sheet: wait to start (first pieces cleared by
--      the stage before → this department's first tablet count; Milling,
--      Metal and Full Custom from the upload) and working time (first
--      count → every piece done, only for sheets counted in more than
--      one go), in the department's working days.
--      Sheets started by anything but a tablet count are left out.
--   5. pace_report() — everything the office Pace page shows, in one
--      call. Managers only.
--   6. set_pace_schedule() — the only way to change a schedule. Managers.
--
-- Security lives here: the working views can't be read by any login at
-- all; the report checks for a manager; nobody writes to the table
-- directly; someone with no login gets nothing.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('pace.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.defect_messages') is null
     or to_regclass('public.v_ready_to_work') is null
     or to_regprocedure('public.check_row(integer,text,boolean,text)') is null
     or to_regprocedure('public.office_ok()') is null then
    raise exception 'Run the earlier files first (up to ready_issues.sql). This file builds on them.';
  end if;
  if to_regprocedure('public.inv_inches(text)') is null then
    raise exception 'Run inventory.sql first: the square feet use its size reader, so both agree.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Working days per department, with every change kept
--    days: 1 = Monday … 7 = Sunday
-- ---------------------------------------------------------------------

create table if not exists pace_schedules (
  id          bigint generated always as identity primary key,
  department  text        not null references departments(key),
  days        int[]       not null,
  set_by      uuid        references profiles(id),
  set_by_name text        not null,
  set_at      timestamptz not null default clock_timestamp(),
  check (cardinality(days) between 1 and 7 and days <@ array[1,2,3,4,5,6,7])
);
create index if not exists pace_schedules_dept_idx on pace_schedules (department, set_at desc, id desc);

-- starting schedules, only for a department that has none yet (a second
-- run never puts back a schedule a manager has changed)
insert into pace_schedules (department, days, set_by_name)
select d.key, case when d.key = 'finishing' then array[1,2,3,4,5,6,7] else array[1,2,3,4] end, 'Starting schedule'
  from departments d
 where not d.log_only
   and not exists (select 1 from pace_schedules p where p.department = d.key);

alter table pace_schedules enable row level security;
revoke all on pace_schedules from anon, authenticated;

create or replace view v_pace_schedules as
select distinct on (p.department)
  p.department, d.name as department_name, d.sort_order, p.days, p.set_by_name, p.set_at,
  (select count(*) from pace_schedules h where h.department = p.department) - 1 as changes
from pace_schedules p
join departments d on d.key = p.department
order by p.department, p.set_at desc, p.id desc;
revoke all on v_pace_schedules from anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- working days between two moments, counting only the given weekdays,
-- in Indianapolis time. Thursday 3 pm → Monday 9 am on a Mon–Thu
-- schedule is 9 hours + 9 hours = 0.75 of a day.
create or replace function pace_workdays(p_from timestamptz, p_to timestamptz, p_days int[])
returns numeric language plpgsql stable set search_path = public as $$
declare
  tz    constant text := 'America/Indiana/Indianapolis';
  d     date;
  d_end date;
  s     timestamptz;
  e     timestamptz;
  total numeric := 0;
begin
  if p_from is null or p_to is null or p_to <= p_from or p_days is null then return 0; end if;
  d := (p_from at time zone tz)::date;
  d_end := (p_to at time zone tz)::date;
  if d_end - d > 1500 then d := d_end - 1500; end if;
  while d <= d_end loop
    if extract(isodow from d)::int = any(p_days) then
      s := greatest(p_from, d::timestamp at time zone tz);
      e := least(p_to, (d + 1)::timestamp at time zone tz);
      if e > s then total := total + extract(epoch from e - s) / 86400; end if;
    end if;
    d := d + 1;
  end loop;
  return round(total, 3);
end $$;

-- the middle value, each value counted by its weight (square feet)
create or replace function pace_wmedian(p_vals numeric[], p_weights numeric[])
returns numeric language sql immutable as $$
  with x as (
    select v, w, sum(w) over (order by v, i) as run, sum(w) over () as tot
      from unnest(p_vals, p_weights) with ordinality as u(v, w, i)
     where v is not null and coalesce(w, 0) > 0
  )
  select round(min(v), 2) from x where run >= tot / 2;
$$;

-- the day a queue clears at a weekly pace (calendar days, like the tablets)
create or replace function pace_clears_on(p_amount numeric, p_per_week numeric)
returns date language sql stable set search_path = public as $$
  select case when coalesce(p_per_week, 0) > 0 and p_amount is not null
              then local_today() + ceil(greatest(p_amount, 0) / p_per_week * 7)::int end;
$$;

-- the Monday a moment falls in, Indianapolis time
create or replace function pace_week(p_at timestamptz)
returns date language sql stable as $$
  select date_trunc('week', (p_at at time zone 'America/Indiana/Indianapolis'))::date;
$$;

revoke all on function pace_workdays(timestamptz, timestamptz, int[]), pace_wmedian(numeric[], numeric[]),
                       pace_clears_on(numeric, numeric), pace_week(timestamptz) from public, anon;
grant execute on function pace_workdays(timestamptz, timestamptz, int[]), pace_wmedian(numeric[], numeric[]),
                          pace_clears_on(numeric, numeric), pace_week(timestamptz) to authenticated;


-- ---------------------------------------------------------------------
-- 3. How each sheet is measured in each department (real jobs only)
-- ---------------------------------------------------------------------

create or replace view v_pace_units as
select
  sp.id           as progress_id,
  sp.sheet_id,
  sp.department,
  sp.qty_required,
  sp.qty_done,
  s.sheet_number,
  s.item_code,
  s.created_at    as sheet_created_at,
  w.job_id,
  w.is_current,
  j.project_id,
  j.is_active,
  j.delivery_date,
  case when sp.department in ('metal', 'full_custom', 'metal_paint') then 'pieces' else 'sqft' end as measure,
  sz.sqft_each,
  -- the main measure for one piece: square feet, or 1 for a piece
  case
    when sp.department in ('metal', 'full_custom', 'metal_paint') then 1
    when sp.department = 'assembly_qc' and not f.has_wood then 0
    else coalesce(sz.sqft_each, 0)
  end::numeric as main_each,
  -- the second number beside it: cabinets (Sanding, Finishing) or pieces without a top (Assembly / QC)
  case
    when sp.department in ('sanding', 'finishing') and f.has_fc then 1
    when sp.department = 'assembly_qc' and not f.has_wood then 1
    else 0
  end as extra_each,
  (sp.department in ('milling', 'cnc', 'sanding', 'finishing', 'assembly_qc')
     and not (sp.department = 'assembly_qc' and not f.has_wood)
     and not (sp.department in ('sanding', 'finishing') and f.has_fc)
     and sz.sqft_each is null) as no_size
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id
join jobs j        on j.id = w.job_id and not j.is_test
join departments d on d.key = sp.department and not d.log_only
cross join lateral (
  select exists (select 1 from sheet_progress x where x.sheet_id = sp.sheet_id
                  and x.department in ('milling', 'cnc', 'sanding', 'finishing')) as has_wood,
         exists (select 1 from sheet_progress x where x.sheet_id = sp.sheet_id
                  and x.department = 'full_custom') as has_fc
) f
cross join lateral (
  select case when inv_inches(s.width) > 0 and coalesce(inv_inches(s.length), inv_inches(s.width)) > 0
              then round(inv_inches(s.width) * coalesce(inv_inches(s.length), inv_inches(s.width)) / 144, 3) end as sqft_each
) sz;
revoke all on v_pace_units from anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. What the tablets counted, one row per count, in those units
--    A count is "Tablet" if it says so; rows from before counts were
--    labelled count too when they changed an existing number.
-- ---------------------------------------------------------------------

create or replace view v_pace_done as
select
  u.job_id, u.project_id, u.sheet_id, u.department, e.id as event_id, e.occurred_at,
  pace_week(e.occurred_at)                             as week_start,
  (e.qty_to - coalesce(e.qty_from, 0))                 as pieces,
  (e.qty_to - coalesce(e.qty_from, 0)) * u.main_each   as main,
  (e.qty_to - coalesce(e.qty_from, 0)) * u.extra_each  as extra,
  case when u.no_size then e.qty_to - coalesce(e.qty_from, 0) else 0 end as no_size_pieces
from progress_events e
join v_pace_units u on u.sheet_id = e.sheet_id and u.department = e.department
where e.source = 'Tablet' or (e.source is null and e.qty_from is not null);
revoke all on v_pace_done from anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. Time in stage, per sheet per department
-- ---------------------------------------------------------------------

create or replace view v_pace_times as
with recursive ancestors as (
  select key as dept, predecessor as anc, 1 as depth from departments where predecessor is not null
  union all
  select a.dept, d.predecessor, a.depth + 1 from ancestors a join departments d on d.key = a.anc where d.predecessor is not null
),
base as (
  select u.*,
         sch.days as schedule,
         g.gates,
         -- when the stages before it first had a piece done (all of them, when two gate it)
         case when g.gates = 0 then u.sheet_created_at
              when g.missing > 0 then null
              else g.ready_at end as ready_at,
         t.first_at, t.done_at,
         t.started_outside
    from v_pace_units u
    left join v_pace_schedules sch on sch.department = u.department
    cross join lateral (
      select count(*) as gates,
             count(*) filter (where gr.first_one is null) as missing,
             max(gr.first_one) as ready_at
        from (
          select up.id as gate_id
            from (select pre.id from ancestors a
                    join sheet_progress pre on pre.sheet_id = u.sheet_id and pre.department = a.anc
                   where a.dept = u.department order by a.depth limit 1) up
          union all
          select m.id from sheet_progress m
           where u.department = 'assembly_qc' and m.sheet_id = u.sheet_id and m.department = 'metal'
        ) gate
        cross join lateral (
          select min(e.occurred_at) as first_one from progress_events e
            join sheet_progress gp on gp.id = gate.gate_id
           where e.sheet_id = gp.sheet_id and e.department = gp.department and e.qty_to >= 1
        ) gr
    ) g
    cross join lateral (
      select
        min(e.occurred_at) filter (where (e.source = 'Tablet' or (e.source is null and e.qty_from is not null))
                                     and e.qty_to > coalesce(e.qty_from, 0)) as first_at,
        min(e.occurred_at) filter (where e.qty_to >= u.qty_required) as done_at,
        coalesce(bool_or(e.qty_to > 0 and not (e.source = 'Tablet' or (e.source is null and e.qty_from is not null))
                         and e.occurred_at <= coalesce(
                               (select min(e2.occurred_at) from progress_events e2
                                 where e2.sheet_id = u.sheet_id and e2.department = u.department
                                   and (e2.source = 'Tablet' or (e2.source is null and e2.qty_from is not null))
                                   and e2.qty_to > coalesce(e2.qty_from, 0)), 'infinity')), false) as started_outside
        from progress_events e
       where e.sheet_id = u.sheet_id and e.department = u.department
    ) t
)
select
  b.progress_id, b.sheet_id, b.department, b.job_id, b.project_id, b.sheet_number, b.item_code,
  b.is_active, b.is_current, b.qty_required, b.qty_done, b.main_each, b.extra_each,
  b.ready_at, b.first_at, b.done_at, b.started_outside,
  case when b.ready_at is not null and b.first_at is not null and not b.started_outside
       then pace_workdays(b.ready_at, b.first_at, b.schedule) end as wait_days,
  case when b.first_at is not null and b.done_at is not null and not b.started_outside and b.done_at > b.first_at
       then pace_workdays(b.first_at, b.done_at, b.schedule) end as work_days,
  b.qty_required * case when b.main_each > 0 then b.main_each else 1 end as weight,
  b.schedule
from base b;
revoke all on v_pace_times from anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. What's left, job by job, in each department — the queue order is
--    the delivery date (no date last), then the PROJ number. "ahead"
--    is everything up to and including this job.
-- ---------------------------------------------------------------------

create or replace view v_pace_backlog as
with j as (
  select u.job_id, u.project_id, u.delivery_date, u.department,
         sum((u.qty_required - u.qty_done) * u.main_each)  as left_main,
         sum((u.qty_required - u.qty_done) * u.extra_each) as left_extra
    from v_pace_units u
   where u.is_active and u.is_current and u.qty_done < u.qty_required
   group by 1, 2, 3, 4
)
select j.*,
       sum(j.left_main) over (partition by j.department order by j.delivery_date nulls last, j.project_id, j.job_id) as ahead_main
  from j;
revoke all on v_pace_backlog from anon, authenticated;


-- ---------------------------------------------------------------------
-- 7. The report for the office page (managers only)
-- ---------------------------------------------------------------------

create or replace function pace_report(p_weeks int default 4)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_this   date := pace_week(now());
  v_from   date;
  v_first  date;
  v_used   int;
  v_fb     boolean := to_regclass('public.v_finish_by_days') is not null;
  v_fbdays jsonb := '{}';
  d        record;
  v_depts  jsonb := '[]';
  v_pace   numeric; v_pace_x numeric;
  v_one    jsonb;
begin
  if not office_ok() then
    raise exception 'Only a manager can see pace.' using errcode = 'insufficient_privilege';
  end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 26 then
    raise exception 'Weeks must be from 1 to 26.';
  end if;
  v_from := v_this - 7 * p_weeks;

  -- weeks with tablet counts to go on: not before the first week anything was counted
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0 else least(p_weeks, greatest((v_this - greatest(v_first, v_from)) / 7, 0)) end;

  if v_fb then
    execute 'select coalesce(jsonb_object_agg(department, days), ''{}'') from v_finish_by_days' into v_fbdays;
  end if;

  for d in
    select dp.key, dp.name, dp.sort_order, s.days as schedule, s.set_by_name, s.set_at, s.changes
      from departments dp
      left join v_pace_schedules s on s.department = dp.key
     where not dp.log_only
     order by dp.sort_order
  loop
    select case when v_used > 0 then round(coalesce(sum(main), 0) / v_used, 1) end,
           case when v_used > 0 then round(coalesce(sum(extra), 0)::numeric / v_used, 1) end
      into v_pace, v_pace_x
      from v_pace_done where department = d.key and week_start >= v_this - 7 * v_used and week_start < v_this;

    select jsonb_build_object(
      'key', d.key,
      'name', d.name,
      'measure', case when d.key in ('metal', 'full_custom', 'metal_paint') then 'pieces' else 'sqft' end,
      'extra_label', case when d.key in ('sanding', 'finishing') then 'cabinets'
                          when d.key = 'assembly_qc' then 'pieces without a top' end,
      'schedule', to_jsonb(d.schedule),
      'schedule_set_by', d.set_by_name,
      'schedule_set_at', d.set_at,
      'schedule_changes', d.changes,
      'pace', v_pace,
      'pace_extra', v_pace_x,
      'this_week', (select round(coalesce(sum(main), 0), 1) from v_pace_done where department = d.key and week_start = v_this),
      'this_week_extra', (select coalesce(sum(extra), 0) from v_pace_done where department = d.key and week_start = v_this),
      'weekly', (select jsonb_agg(jsonb_build_object('week', wk, 'main', round(coalesce(x.main, 0), 1), 'extra', coalesce(x.extra, 0)) order by wk)
                   from generate_series(v_this - 56, v_this, interval '7 days') g(wkt)
                   cross join lateral (select g.wkt::date as wk) w
                   left join lateral (select sum(main) as main, sum(extra) as extra from v_pace_done
                                       where department = d.key and week_start = w.wk) x on true),
      'ready', (select round(coalesce(sum(r.ready * u.main_each), 0), 1) from v_ready_to_work r
                  join v_pace_units u on u.sheet_id = r.sheet_id and u.department = r.department
                 where r.department = d.key and u.is_active and u.is_current),
      'ready_extra', (select coalesce(sum(r.ready * u.extra_each), 0) from v_ready_to_work r
                  join v_pace_units u on u.sheet_id = r.sheet_id and u.department = r.department
                 where r.department = d.key and u.is_active and u.is_current),
      'ready_sheets', (select count(*) from v_ready_to_work r
                  join v_pace_units u on u.sheet_id = r.sheet_id and u.department = r.department
                 where r.department = d.key and u.is_active and u.is_current and r.ready > 0),
      'backlog', (select round(coalesce(sum(left_main), 0), 1) from v_pace_backlog where department = d.key),
      'backlog_extra', (select coalesce(sum(left_extra), 0) from v_pace_backlog where department = d.key),
      'no_size_sheets', (select count(*) from v_pace_units u
                          where u.department = d.key and u.is_active and u.is_current and u.no_size and u.qty_done < u.qty_required),
      'wait_days', (select pace_wmedian(array_agg(wait_days), array_agg(weight)) from v_pace_times
                     where department = d.key and wait_days is not null and first_at >= (v_from::timestamp at time zone 'America/Indiana/Indianapolis')),
      'wait_sheets', (select count(*) from v_pace_times
                     where department = d.key and wait_days is not null and first_at >= (v_from::timestamp at time zone 'America/Indiana/Indianapolis')),
      'work_days', (select pace_wmedian(array_agg(work_days), array_agg(weight)) from v_pace_times
                     where department = d.key and work_days is not null and done_at >= (v_from::timestamp at time zone 'America/Indiana/Indianapolis')),
      'work_sheets', (select count(*) from v_pace_times
                     where department = d.key and work_days is not null and done_at >= (v_from::timestamp at time zone 'America/Indiana/Indianapolis')),
      'waiting', coalesce((select jsonb_agg(x order by x->>'ready_at') from (
                   select jsonb_build_object('job_id', t.job_id, 'project_id', t.project_id, 'sheet_number', t.sheet_number,
                            'item_code', t.item_code, 'ready_at', t.ready_at,
                            'main', round(r.ready * t.main_each, 1), 'extra', r.ready * t.extra_each,
                            'ready_days', pace_workdays(t.ready_at, now(), t.schedule)) as x
                     from v_pace_times t
                     join v_ready_to_work r on r.sheet_id = t.sheet_id and r.department = t.department
                    where t.department = d.key and t.is_active and t.is_current and r.ready > 0 and t.qty_done = 0
                      and t.ready_at is not null
                    order by t.ready_at limit 5) q), '[]'),
      'late', case when not v_fb or coalesce(v_pace, 0) <= 0 or not (v_fbdays ? d.key) then '[]'::jsonb else
                coalesce((select jsonb_agg(x order by x->>'finish_by') from (
                   select jsonb_build_object('job_id', b.job_id, 'project_id', b.project_id,
                            'finish_by', b.delivery_date - (v_fbdays->>d.key)::int,
                            'clears_on', pace_clears_on(b.ahead_main, v_pace),
                            'left_extra', b.left_extra) as x
                     from v_pace_backlog b
                    where b.department = d.key and b.delivery_date is not null
                      and pace_clears_on(b.ahead_main, v_pace) > b.delivery_date - (v_fbdays->>d.key)::int) q), '[]') end
    ) into v_one;
    v_depts := v_depts || v_one;
  end loop;

  return jsonb_build_object(
    'today', local_today(),
    'this_week', v_this,
    'weeks', p_weeks,
    'weeks_used', v_used,
    'first_week', v_first,
    'finish_by_ready', v_fb,
    'departments', v_depts);
end;
$$;
revoke all on function pace_report(int) from public, anon;
grant execute on function pace_report(int) to authenticated;


-- ---------------------------------------------------------------------
-- 8. Changing a department's working days (managers only)
-- ---------------------------------------------------------------------

create or replace function set_pace_schedule(p_department text, p_days int[])
returns text
language plpgsql security definer set search_path = public as $$
declare v_dept departments; v_old int[]; v_new int[];
        names text[] := array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
begin
  if not office_ok() then
    raise exception 'Only a manager can change working days.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_dept from departments where key = p_department;
  if v_dept.key is null then
    raise exception '"%" is not a department.', p_department;
  end if;
  if v_dept.log_only then
    raise exception '% isn''t counted, so it has no pace.', v_dept.name;
  end if;
  if p_days is null or cardinality(p_days) = 0 or not (p_days <@ array[1,2,3,4,5,6,7]) or array_position(p_days, null) is not null then
    raise exception 'Pick at least one day for %, Monday to Sunday.', v_dept.name;
  end if;
  select array_agg(distinct x order by x) into v_new from unnest(p_days) x;
  select days into v_old from v_pace_schedules where department = p_department;
  if v_old = v_new then
    return format('%s already works %s. Nothing changed.', v_dept.name,
                  (select string_agg(names[x], ' ' order by x) from unnest(v_new) x));
  end if;
  insert into pace_schedules (department, days, set_by, set_by_name) values (p_department, v_new, auth.uid(), my_name());
  return format('%s now works %s.', v_dept.name, (select string_agg(names[x], ' ' order by x) from unnest(v_new) x));
end;
$$;
revoke all on function set_pace_schedule(text, int[]) from public, anon;
grant execute on function set_pace_schedule(text, int[]) to authenticated;


-- ---------------------------------------------------------------------
-- 9. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------

create or replace function check_pace()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  tst uuid;  mgr uuid;
  v_job   uuid;  v_job2 uuid;  v_wo uuid;  v_wo2 uuid;  v_test uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid;
  tz      constant text := 'America/Indiana/Indianapolis';
  v_thu   timestamptz;  v_mon timestamptz;
  n       numeric;  m numeric;  k int;
  ok      boolean;
  msg     text;
  v       jsonb;
  t       text;
begin
  select id into sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only) limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  -- ---- 1: schedules ----------------------------------------------------------
  select count(*), string_agg(format('%s %s', department, days), ', ' order by sort_order) into k, msg from v_pace_schedules;
  ok := k = (select count(*) from departments where not log_only)
        and not exists (select 1 from v_pace_schedules where department = 'delivery');
  res := res || check_row(1, 'Every counted department has working days (Delivery isn''t counted)', ok,
    format('Found %s: %s.', k, coalesce(msg, 'none')));

  -- ---- 2: working days --------------------------------------------------------
  v_thu := (date_trunc('week', local_today())::date - 11)::timestamp at time zone tz + interval '15 hours';   -- a Thursday, 3 pm
  v_mon := v_thu + interval '3 days 18 hours';                                                             -- the Monday after, 9 am
  n := pace_workdays(v_thu, v_mon, array[1,2,3,4]);
  m := pace_workdays(v_thu, v_mon, array[1,2,3,4,5,6,7]);
  res := res || check_row(2, 'Working days skip days off: Thu 3 pm → Mon 9 am is 0.75 on Mon–Thu, 3.75 every day', n = 0.75 and m = 3.75,
    format('Got %s on Mon–Thu and %s every day.', n, m));

  if sup is null or mgr is null then
    res := res || check_row(3, 'A supervisor and a manager have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor.' end, case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999975, 'PACECHECK', 'Pace check - undone automatically', true, 'In Production', local_today() + 1)
      returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 1, 2, 'PC-1', '36"', null)       returning id into s1;     -- a 36" round: 9 sq ft each
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 2, 3, 'PC-2', '30"', '30"')      returning id into s2;     -- a metal base only
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 3, 1, 'PC-3', '24"', '48"')      returning id into s3;     -- cabinet with a 24 × 48 top: 8 sq ft
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 4, 2, 'PC-4', 'TBD', null)       returning id into s4;     -- a top with no readable size
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 5, 1, 'PC-5', null, null)        returning id into s5;     -- a cabinet, no top
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'milling', 2, 0), (s1, 'sanding', 2, 0), (s1, 'finishing', 2, 0), (s1, 'assembly_qc', 2, 0),
      (s2, 'metal', 3, 0), (s2, 'assembly_qc', 3, 0),
      (s3, 'milling', 1, 0), (s3, 'full_custom', 1, 0), (s3, 'sanding', 1, 0), (s3, 'finishing', 1, 0), (s3, 'assembly_qc', 1, 0),
      (s4, 'milling', 2, 0), (s4, 'sanding', 2, 0),
      (s5, 'full_custom', 1, 0), (s5, 'sanding', 1, 0);

    -- ---- 3: units -----------------------------------------------------------------
    select (select main_each = 9 and extra_each = 0 and not no_size from v_pace_units where sheet_id = s1 and department = 'sanding')
       and (select main_each = 9 from v_pace_units where sheet_id = s1 and department = 'assembly_qc')
       and (select main_each = 0 and extra_each = 1 from v_pace_units where sheet_id = s2 and department = 'assembly_qc')
       and (select main_each = 1 and extra_each = 0 from v_pace_units where sheet_id = s2 and department = 'metal')
       and (select main_each = 8 and extra_each = 1 from v_pace_units where sheet_id = s3 and department = 'finishing')
       and (select main_each = 8 and extra_each = 0 from v_pace_units where sheet_id = s3 and department = 'milling')
       and (select main_each = 1 from v_pace_units where sheet_id = s3 and department = 'full_custom')
       and (select main_each = 0 and no_size from v_pace_units where sheet_id = s4 and department = 'sanding')
       and (select main_each = 0 and extra_each = 1 and not no_size from v_pace_units where sheet_id = s5 and department = 'sanding')
      into ok;
    select string_agg(format('sheet %s %s: %s + %s%s', sheet_number, department, main_each, extra_each, case when no_size then ' (no size)' else '' end), '; ' order by sheet_number, department)
      into msg from v_pace_units where job_id = v_job;
    res := res || check_row(3, 'Square feet of top (a round is diameter²), cabinets in Sanding / Finishing, bases without a top in Assembly, pieces in Metal / Full Custom', coalesce(ok, false),
      'Expected 36" round = 9, 24 × 48 = 8, cabinets and bases counted beside, a top with no size flagged. Got: ' || coalesce(msg, 'nothing'));

    -- ---- 4: tablet counts only ----------------------------------------------------------
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'milling';          -- a tablet count
    perform set_config('shopfloor.source', 'Manager adjustment', true);
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'sanding';          -- Advance
    perform set_config('shopfloor.source', 'Catch-up from Monday', true);
    update sheet_progress set qty_done = 1 where sheet_id = s3 and department = 'milling';          -- catch-up
    perform set_config('shopfloor.source', '', true);
    select coalesce(sum(main) filter (where department = 'milling'), 0), coalesce(sum(main) filter (where department = 'sanding'), 0)
      into n, m from v_pace_done where job_id = v_job;
    res := res || check_row(4, 'Pace counts tablet counts only (not Advance, catch-up or uploads)', n = 18 and m = 0,
      format('Milling should show 18 sq ft (2 × 9, tablet) and Sanding 0 (Advance); got %s and %s. Catch-up on sheet 3 must not count either.', n, m));

    -- ---- 5: absolute counts ------------------------------------------------------------------
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'finishing';
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'finishing';      -- a correction down
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'finishing';
    select coalesce(sum(main), 0), count(*) into n, k from v_pace_done where job_id = v_job and department = 'finishing';
    res := res || check_row(5, 'Counts are absolute: a correction down takes back what it should', n = 18 and k = 3,
      format('2 → 1 → 2 on a 9 sq ft round should total 18 sq ft over 3 counts; got %s over %s.', n, k));

    -- ---- 6: time in stage ---------------------------------------------------------------------
    -- Finishing had its first piece on a Thursday at 3 pm; Assembly started Monday 9 am, finished Monday 9 pm (Mon–Thu)
    update progress_events set occurred_at = v_thu where sheet_id = s1 and department = 'finishing';
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'assembly_qc';
    update progress_events set occurred_at = v_mon where sheet_id = s1 and department = 'assembly_qc' and qty_to = 1;
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'assembly_qc';
    update progress_events set occurred_at = v_mon + interval '12 hours' where sheet_id = s1 and department = 'assembly_qc' and qty_to = 2;
    select wait_days, work_days into n, m from v_pace_times where sheet_id = s1 and department = 'assembly_qc';
    select work_days is null into ok from v_pace_times where sheet_id = s1 and department = 'milling';      -- counted in one go
    res := res || check_row(6, 'Wait to start and working time, in the department''s working days (a sheet counted in one go has no working time)', n = 0.75 and m = 0.5 and coalesce(ok, false),
      format('Expected a wait of 0.75 (Thu 3 pm → Mon 9 am, Mon–Thu) and 0.5 working (Mon 9 am → 9 pm); got %s and %s. Milling, entered all at once, should have no working time: %s.', coalesce(n::text, 'none'), coalesce(m::text, 'none'), case when ok then 'right' else 'it had one' end));

    -- ---- 7: started outside the tablet --------------------------------------------------------
    perform set_config('shopfloor.source', 'Catch-up from Monday', true);
    update sheet_progress set qty_done = 1 where sheet_id = s4 and department = 'milling';
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = 2 where sheet_id = s4 and department = 'milling';
    select started_outside and wait_days is null and work_days is null into ok from v_pace_times where sheet_id = s4 and department = 'milling';
    select ok and (select wait_days is not null from v_pace_times where sheet_id = s1 and department = 'milling') into ok;
    res := res || check_row(7, 'A sheet started by catch-up, Advance or a carried-over count is left out of time in stage', coalesce(ok, false),
      'Sheet 4 (catch-up first) should have no times; sheet 1 (tablet first) should.');

    -- ---- 8: test jobs ------------------------------------------------------------------------------
    if tst is null then
      res := res || check_row(8, 'Test jobs are left out', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('PACECHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      update sheet_progress sp set qty_done = sp.qty_required from sheets s join work_orders w on w.id = s.work_order_id
       where sp.sheet_id = s.id and w.job_id = v_test;
      select (select count(*) from v_pace_done where job_id = v_test) + (select count(*) from v_pace_units where job_id = v_test) into k;
      res := res || check_row(8, 'Test jobs are left out', k = 0, format('%s test-job rows reached pace.', k));
    end if;

    -- ---- 9: the report ------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := pace_report(4);
      execute 'reset role';
      ok := false; msg := 'A supervisor opened the pace report. Only managers should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    if ok then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := pace_report(4);
        execute 'reset role';
        ok := jsonb_array_length(v->'departments') = (select count(*) from departments where not log_only)
              and (select bool_and(x ? 'pace' and x ? 'ready' and x ? 'weekly' and jsonb_array_length(x->'weekly') = 9)
                     from jsonb_array_elements(v->'departments') x)
              and (select (x->>'this_week')::numeric >= 18 from jsonb_array_elements(v->'departments') x where x->>'key' = 'milling');
        msg := 'The manager''s report should list every counted department with pace, ready and 9 weeks of bars, and include this week''s 18 sq ft in Milling.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error for a manager: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(9, 'Managers get the report; supervisors are refused', coalesce(ok, false), msg);

    -- ---- 10: supervisors can't change working days -------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    k := 0; msg := null;
    begin
      execute 'set local role authenticated';
      t := set_pace_schedule('milling', array[1,2,3,4,5]);
      execute 'reset role';
      msg := 'A supervisor changed Milling''s days.';
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := 'Unexpected error: ' || sqlerrm;
    end;
    begin
      execute 'set local role authenticated';
      insert into pace_schedules (department, days, set_by_name) values ('milling', array[1], 'sneaky');
      execute 'reset role';
      msg := concat_ws(' ', msg, 'A supervisor wrote to pace_schedules directly.');
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := concat_ws(' ', msg, 'Unexpected error: ' || sqlerrm);
    end;
    foreach t in array array['v_pace_units', 'v_pace_done', 'v_pace_times', 'v_pace_backlog', 'v_pace_schedules', 'pace_schedules'] loop
      begin
        execute 'set local role authenticated';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        msg := concat_ws(' ', msg, format('A supervisor read %s.', t));
      exception when insufficient_privilege then execute 'reset role'; k := k + 1;
      when others then execute 'reset role'; msg := concat_ws(' ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(10, 'A supervisor can''t change working days, write the table, or read the working views', k = 8,
      coalesce(msg, format('%s of 8 refused.', k)));

    -- ---- 11: a manager changes one; history kept; bad input refused ---------------------------------
    select count(*) into k from pace_schedules where department = 'metal';
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      t := set_pace_schedule('metal', array[4,1,2,3,5]);
      msg := set_pace_schedule('metal', array[1,2,3,4,5]);
      execute 'reset role';
      ok := msg like '%Nothing changed%'
            and (select days from v_pace_schedules where department = 'metal') = array[1,2,3,4,5]
            and (select count(*) from pace_schedules where department = 'metal') = k + 1
            and (select set_by_name from v_pace_schedules where department = 'metal') = (select full_name from profiles where id = mgr);
      msg := 'Metal should now be Mon–Fri, one new row kept with the manager''s name, and the same again should change nothing.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    k := 0;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', '{}');          execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', array[0,1]);    execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', array[8]);      execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', null);          execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('delivery', array[1]);   execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    res := res || check_row(11, 'A manager changes working days (every change kept); no days, bad days and Delivery are refused', coalesce(ok, false) and k = 5,
      concat_ws(' ', case when not coalesce(ok, false) then msg end, case when k < 5 then format('Only %s of 5 bad changes were refused.', k) end));

    -- ---- 12: queue order and when it clears ------------------------------------------------------------
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999974, 'PACECHECK2', 'Pace check - undone automatically', true, 'In Production', local_today() + 2)
      returning id into v_job2;
    insert into work_orders (job_id) values (v_job2) returning id into v_wo2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values (v_wo2, 1, 4, 'PC-6', '30"', '60"') returning id into s6;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s6, 'sanding', 4, 0);
    select (select ahead_main from v_pace_backlog where job_id = v_job2 and department = 'sanding')
         - (select ahead_main from v_pace_backlog where job_id = v_job and department = 'sanding') into n;
    ok := n = 50 and pace_clears_on(100, 50) = local_today() + 14 and pace_clears_on(1, 0) is null;
    res := res || check_row(12, 'The queue runs in delivery-date order, and clears at the weekly pace in calendar days', coalesce(ok, false),
      format('The later job should add its own 50 sq ft (4 × 30 × 60) to the queue ahead of it; it added %s. 100 sq ft at 50 a week should clear in 14 days.', coalesce(n::text, 'nothing')));

    -- ---- 13: no login ------------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    k := 0; msg := null;
    begin
      execute 'set local role anon';
      v := pace_report(4);
      execute 'reset role';
      msg := 'The report opened with no login.';
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := 'Report: ' || sqlerrm;
    end;
    foreach t in array array['pace_schedules', 'v_pace_schedules', 'v_pace_units', 'v_pace_done', 'v_pace_times', 'v_pace_backlog'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        msg := concat_ws(' ', msg, format('%s rows of %s visible.', m, t));
      exception when insufficient_privilege then execute 'reset role'; k := k + 1;
      when others then execute 'reset role'; msg := concat_ws(' ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(13, 'Someone with no login gets none of it', k = 7,
      coalesce(msg, '') || ' Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_pace_undo__';
  exception when others then
    if sqlerrm <> '__check_pace_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('shopfloor.source', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_pace() from public, anon, authenticated;

select * from check_pace();
