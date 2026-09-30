-- =====================================================================
-- Shop Floor — management flags (whole-floor build, step 5)
--
-- HOW TO USE: run problems.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. Safe to run
-- more than once.
--
-- A flag puts something in front of the floor without walking out and
-- telling six people. It points at a whole job or one department's part
-- of it, carries a level and a note, and shows wherever the job shows:
--   Watch    — a marker on the job card
--   Priority — pinned to the top of the queue, in colour
--   Critical — top of every affected queue, and its own band on the TV
--
-- Only managers set and clear flags. Every set and clear is kept with a
-- name. A job (or a job's department) has at most one open flag: setting
-- a new one replaces the old, and both stay in history.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('flags.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.sees_lane(boolean)') is null then
    raise exception 'Run problems.sql first (step 4). This file builds on it.';
  end if;
end $$;

create table if not exists flags (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid        not null references jobs(id) on delete cascade,
  department      text        references departments(key),   -- blank = the whole job
  level           text        not null check (level in ('watch', 'priority', 'critical')),
  note            text        not null check (length(trim(note)) > 0),
  is_test         boolean     not null default false,
  set_by          uuid        references profiles(id),
  set_by_name     text,
  set_at          timestamptz not null default now(),
  cleared_at      timestamptz,
  cleared_by      uuid        references profiles(id),
  cleared_by_name text,
  clear_note      text
);
create unique index if not exists flags_one_open_per_scope on flags (job_id, coalesce(department, '')) where cleared_at is null;
create index if not exists flags_open_idx on flags (cleared_at, job_id);
alter table flags enable row level security;
drop policy if exists read_flags on flags;
create policy read_flags on flags for select to authenticated using (sees_lane(is_test));
revoke insert, update, delete on flags from anon, authenticated;

create or replace function set_flag(p_job uuid, p_level text, p_note text, p_department text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_dept departments; v_id uuid; v_old uuid;
begin
  if not office_ok() then
    raise exception 'Only a manager can set flags.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null then raise exception 'That job isn''t in the system.'; end if;
  if p_level not in ('watch', 'priority', 'critical') then
    raise exception 'The level must be watch, priority or critical.';
  end if;
  if nullif(trim(p_note), '') is null then
    raise exception 'Write a note — "Priority" alone invites guessing. Say what has to happen by when.';
  end if;
  if p_department is not null then
    select * into v_dept from departments where key = p_department;
    if v_dept.key is null then raise exception '"%" is not a department.', p_department; end if;
    if v_dept.log_only then
      raise exception '% has no queue, so a flag there would show nowhere. Flag the whole job instead.', v_dept.name;
    end if;
  end if;

  update flags set cleared_at = now(), cleared_by = auth.uid(), cleared_by_name = my_name(), clear_note = 'Replaced by a new flag'
   where job_id = p_job and coalesce(department, '') = coalesce(p_department, '') and cleared_at is null
  returning id into v_old;

  insert into flags (job_id, department, level, note, is_test, set_by, set_by_name)
  values (p_job, p_department, p_level, trim(p_note), v_job.is_test, auth.uid(), my_name())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'replaced', v_old is not null,
    'summary', format('%s flag on %s%s%s.', initcap(p_level), v_job.project_id,
                      coalesce(' (' || v_dept.name || ' only)', ''),
                      case when v_old is not null then ', replacing the one before' else '' end));
end $$;
revoke all on function set_flag(uuid, text, text, text) from public, anon;
grant execute on function set_flag(uuid, text, text, text) to authenticated;

create or replace function clear_flag(p_flag uuid, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v flags;
begin
  if not office_ok() then
    raise exception 'Only a manager can clear flags.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from flags where id = p_flag;
  if v.id is null then raise exception 'That flag isn''t there.'; end if;
  if v.cleared_at is null then
    update flags set cleared_at = now(), cleared_by = auth.uid(), cleared_by_name = my_name(),
                     clear_note = nullif(trim(p_note), '')
     where id = p_flag;
  end if;
  return 'Flag cleared. It''s kept in the history.';
end $$;
revoke all on function clear_flag(uuid, text) from public, anon;
grant execute on function clear_flag(uuid, text) to authenticated;

drop view if exists v_flags;
create view v_flags with (security_invoker = true) as
select f.id, f.job_id, j.project_id, j.name as job_name, j.delivery_date, j.is_active as job_active,
       f.department, d.name as department_name, f.level, f.note, f.is_test,
       f.set_by_name, f.set_at, (local_today() - (f.set_at at time zone 'America/Indiana/Indianapolis')::date) as age_days,
       (f.cleared_at is null) as is_open, f.cleared_at, f.cleared_by_name, f.clear_note
from flags f
join jobs j on j.id = f.job_id
left join departments d on d.key = f.department;
revoke all on v_flags from anon;
grant select on v_flags to authenticated;
