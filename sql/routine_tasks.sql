-- =====================================================================
-- Shop Floor — routine tasks (whole-floor build, step 6)
--
-- HOW TO USE: run problems.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. Safe to run
-- more than once.
--
-- The old app's routine tasks, unchanged in behaviour: weekly (every N
-- weeks) or monthly (1st/2nd/3rd/4th/last weekday), Monday–Thursday only,
-- one-tap complete, full history. Only managers add or remove them.
-- What changes: each task belongs to a department and sits in that
-- department's Log tab, and a person's due tasks are pinned to the top
-- of their tablet.
--
-- Two changes from the old app, because nothing is ever deleted here:
--   * removing a task retires it; its history stays
--   * a mistaken "Done" is marked "Entered by mistake", not deleted
-- A task can be assigned to one person, or left to anyone in the
-- department (useful until that department's login exists).
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('routine_tasks.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.sees_lane(boolean)') is null then
    raise exception 'Run problems.sql first (step 4). This file builds on it.';
  end if;
end $$;

create table if not exists routine_tasks (
  id                 uuid primary key default gen_random_uuid(),
  name               text        not null check (length(trim(name)) > 0),
  department         text        not null references departments(key),
  assigned_to        uuid        references profiles(id),     -- blank = anyone in the department
  assigned_to_name   text,
  schedule_type      text        not null check (schedule_type in ('weekly', 'monthly')),
  weekday            int         not null check (weekday between 1 and 4),   -- 1 Monday … 4 Thursday
  week_interval      int         check (week_interval between 1 and 12),
  monthly_occurrence int         check (monthly_occurrence in (1, 2, 3, 4, -1)),  -- -1 = last
  start_date         date        not null,
  is_test            boolean     not null default false,
  active             boolean     not null default true,
  created_by         uuid        references profiles(id),
  created_by_name    text,
  created_at         timestamptz not null default now(),
  retired_at         timestamptz,
  retired_by_name    text,
  check ((schedule_type = 'weekly'  and week_interval is not null)
      or (schedule_type = 'monthly' and monthly_occurrence is not null))
);

create table if not exists routine_task_logs (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid unique,
  task_id           uuid        not null references routine_tasks(id) on delete cascade,
  completed_on      date        not null,
  completed_by      uuid        references profiles(id),
  completed_by_name text,
  completed_at      timestamptz not null default now(),
  voided_at         timestamptz,
  voided_by_name    text,
  void_reason       text
);
create unique index if not exists routine_task_logs_once_a_day on routine_task_logs (task_id, completed_on) where voided_at is null;

alter table routine_tasks enable row level security;
alter table routine_task_logs enable row level security;
drop policy if exists read_routine_tasks on routine_tasks;
create policy read_routine_tasks on routine_tasks for select to authenticated using (sees_lane(is_test));
drop policy if exists read_routine_task_logs on routine_task_logs;
create policy read_routine_task_logs on routine_task_logs for select to authenticated
  using (exists (select 1 from routine_tasks t where t.id = task_id));
revoke insert, update, delete on routine_tasks, routine_task_logs from anon, authenticated;


-- ---------------------------------------------------------------------
-- When a task is next due — the old app's rule, exactly
--   never done: the first matching day on or after the start date
--   done:       the first matching day after the last completion
-- Doing a task early doesn't skip its next due day, as before.
-- ---------------------------------------------------------------------

create or replace function nth_weekday(p_year int, p_month int, p_weekday int, p_occ int) returns date
language plpgsql immutable as $$
declare d date := make_date(p_year, p_month, 1);
begin
  if p_occ = -1 then
    d := (d + interval '1 month' - interval '1 day')::date;
    return d - ((extract(dow from d)::int - p_weekday + 7) % 7);
  end if;
  d := d + ((p_weekday - extract(dow from d)::int + 7) % 7) + (p_occ - 1) * 7;
  return case when extract(month from d)::int = p_month then d end;
end $$;

create or replace function routine_next_due(p_type text, p_weekday int, p_interval int, p_occ int,
                                            p_start date, p_last date) returns date
language plpgsql immutable as $$
declare
  v_from   date := coalesce(p_last + 1, p_start);
  v_anchor date;
  d        date;
  occ      date;
  i        int;
begin
  if p_type = 'weekly' then
    v_anchor := p_start + ((p_weekday - extract(dow from p_start)::int + 7) % 7);
    d := greatest(v_from, v_anchor);
    d := d + ((p_weekday - extract(dow from d)::int + 7) % 7);
    while ((d - v_anchor) / 7) % greatest(p_interval, 1) <> 0 loop
      d := d + 7;
    end loop;
    return d;
  end if;
  d := date_trunc('month', v_from)::date;
  for i in 0..24 loop
    occ := nth_weekday(extract(year from d)::int, extract(month from d)::int, p_weekday, p_occ);
    if occ is not null and occ >= v_from then return occ; end if;
    d := (d + interval '1 month')::date;
  end loop;
  return v_from;
end $$;
grant execute on function nth_weekday(int, int, int, int) to authenticated;
grant execute on function routine_next_due(text, int, int, int, date, date) to authenticated;

drop view if exists v_routine_tasks;
create view v_routine_tasks with (security_invoker = true) as
with last as (
  select task_id, max(completed_on) as last_on
    from routine_task_logs where voided_at is null group by task_id
)
select t.id, t.name, t.department, d.name as department_name, t.assigned_to, t.assigned_to_name,
       t.schedule_type, t.weekday, t.week_interval, t.monthly_occurrence, t.start_date, t.is_test,
       case when t.schedule_type = 'weekly'
            then case when t.week_interval = 1 then 'Every ' || to_char(date '2026-01-04' + t.weekday, 'FMDay')
                      else format('Every %s weeks (%s)', t.week_interval, to_char(date '2026-01-04' + t.weekday, 'FMDay')) end
            else format('%s %s of every month',
                        case t.monthly_occurrence when 1 then '1st' when 2 then '2nd' when 3 then '3rd' when 4 then '4th' else 'Last' end,
                        to_char(date '2026-01-04' + t.weekday, 'FMDay')) end as schedule_text,
       l.last_on as last_done_on,
       (select completed_by_name from routine_task_logs x where x.task_id = t.id and x.voided_at is null
         order by completed_on desc, completed_at desc limit 1) as last_done_by,
       routine_next_due(t.schedule_type, t.weekday, t.week_interval, t.monthly_occurrence, t.start_date, l.last_on) as next_due,
       routine_next_due(t.schedule_type, t.weekday, t.week_interval, t.monthly_occurrence, t.start_date, l.last_on) - local_today() as days_until,
       (l.last_on = local_today()) as done_today,
       coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'on', x.completed_on, 'by', x.completed_by_name,
                                                     'by_id', x.completed_by) order by x.completed_on desc)
                   from (select * from routine_task_logs x where x.task_id = t.id and x.voided_at is null
                          order by completed_on desc limit 12) x), '[]'::jsonb) as history
from routine_tasks t
join departments d on d.key = t.department
left join last l on l.task_id = t.id
where t.active;
revoke all on v_routine_tasks from anon;
grant select on v_routine_tasks to authenticated;


-- ---------------------------------------------------------------------
-- Managers add and retire tasks
-- ---------------------------------------------------------------------

create or replace function add_routine_task(p_name text, p_department text, p_schedule_type text, p_weekday int,
                                            p_week_interval int default 1, p_monthly_occurrence int default null,
                                            p_start_date date default null, p_assigned_to uuid default null,
                                            p_is_test boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_person profiles; v_dept departments;
begin
  if not office_ok() then
    raise exception 'Only a manager can add routine tasks.' using errcode = 'insufficient_privilege';
  end if;
  if nullif(trim(p_name), '') is null then raise exception 'Give the task a name.'; end if;
  select * into v_dept from departments where key = p_department;
  if v_dept.key is null then raise exception '"%" is not a department.', p_department; end if;
  if p_schedule_type not in ('weekly', 'monthly') then raise exception 'The schedule must be weekly or monthly.'; end if;
  if p_weekday not between 1 and 4 then raise exception 'Routine tasks fall on Monday to Thursday only.'; end if;
  if p_schedule_type = 'weekly' and coalesce(p_week_interval, 0) not between 1 and 12 then
    raise exception 'Every how many weeks? A number from 1 to 12.';
  end if;
  if p_schedule_type = 'monthly' and p_monthly_occurrence not in (1, 2, 3, 4, -1) then
    raise exception 'Which one in the month: 1st, 2nd, 3rd, 4th or last?';
  end if;
  if p_assigned_to is not null then
    select * into v_person from profiles where id = p_assigned_to and active;
    if v_person.id is null then raise exception 'That person isn''t set up.'; end if;
    if v_person.is_test <> coalesce(p_is_test, false) then
      raise exception '%', case when v_person.is_test then 'The Test Supervisor can only be given test tasks. Tick "test task".'
                                else 'A test task can only go to the Test Supervisor, or to nobody.' end;
    end if;
  end if;
  insert into routine_tasks (name, department, assigned_to, assigned_to_name, schedule_type, weekday,
                             week_interval, monthly_occurrence, start_date, is_test, created_by, created_by_name)
  values (trim(p_name), p_department, p_assigned_to, v_person.full_name, p_schedule_type, p_weekday,
          case when p_schedule_type = 'weekly' then p_week_interval end,
          case when p_schedule_type = 'monthly' then p_monthly_occurrence end,
          coalesce(p_start_date, local_today()), coalesce(p_is_test, false), auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('Added "%s" to %s%s.', trim(p_name), v_dept.name, coalesce(', for ' || v_person.full_name, '')));
end $$;
revoke all on function add_routine_task(text, text, text, int, int, int, date, uuid, boolean) from public, anon;
grant execute on function add_routine_task(text, text, text, int, int, int, date, uuid, boolean) to authenticated;

create or replace function retire_routine_task(p_task uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v routine_tasks;
begin
  if not office_ok() then
    raise exception 'Only a manager can remove routine tasks.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from routine_tasks where id = p_task;
  if v.id is null then raise exception 'That task isn''t there.'; end if;
  update routine_tasks set active = false, retired_at = coalesce(retired_at, now()), retired_by_name = coalesce(retired_by_name, my_name())
   where id = p_task;
  return format('"%s" is off the list. Its history is kept.', v.name);
end $$;
revoke all on function retire_routine_task(uuid) from public, anon;
grant execute on function retire_routine_task(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- The floor completes them
-- ---------------------------------------------------------------------

create or replace function complete_routine_task(p_task uuid, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v routine_tasks; v_today date := local_today(); v_next date;
begin
  if p_client_id is not null and exists (select 1 from routine_task_logs where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked done.');
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v from routine_tasks where id = p_task;
  if v.id is null or not v.active or not sees_lane(v.is_test) then raise exception 'That task isn''t on the list any more.'; end if;
  if not is_manager() and v.is_test <> am_test() then
    raise exception 'That task is in the other lane.' using errcode = 'insufficient_privilege';
  end if;
  if not (owns_dept(v.department) or v.assigned_to = auth.uid()) then
    raise exception 'This login can''t complete % tasks.', (select name from departments where key = v.department)
      using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from routine_task_logs where task_id = p_task and completed_on = v_today and voided_at is null) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already done today.');
  end if;
  insert into routine_task_logs (client_id, task_id, completed_on, completed_by, completed_by_name)
  values (p_client_id, p_task, v_today, auth.uid(), my_name());
  v_next := routine_next_due(v.schedule_type, v.weekday, v.week_interval, v.monthly_occurrence, v.start_date, v_today);
  return jsonb_build_object('ok', true, 'next_due', v_next,
    'summary', format('"%s" done. Next due %s.', v.name, to_char(v_next, 'FMDy Mon FMDD')));
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already done today.');
end $$;
revoke all on function complete_routine_task(uuid, uuid) from public, anon;
grant execute on function complete_routine_task(uuid, uuid) to authenticated;

create or replace function void_task_completion(p_log uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v routine_task_logs;
begin
  select l.* into v from routine_task_logs l join routine_tasks t on t.id = l.task_id
   where l.id = p_log and sees_lane(t.is_test);
  if v.id is null then raise exception 'That entry isn''t there.'; end if;
  if not (v.completed_by = auth.uid() or office_ok()) then
    raise exception 'Only the person who marked it, or a manager, can undo it.' using errcode = 'insufficient_privilege';
  end if;
  update routine_task_logs set voided_at = coalesce(voided_at, now()), voided_by_name = coalesce(voided_by_name, my_name()),
                               void_reason = coalesce(void_reason, nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = p_log;
  return 'Marked as entered by mistake. The task is due again as before.';
end $$;
revoke all on function void_task_completion(uuid, text) from public, anon;
grant execute on function void_task_completion(uuid, text) to authenticated;
