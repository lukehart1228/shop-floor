-- =====================================================================
-- Shop Floor — Arrow and QC (whole-floor build, step 8)
--
-- HOW TO USE: run problems.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. Safe to run
-- more than once.
--
-- Arrow (powdercoat and paint) — an outside stage. Pick the job from a
-- list, then tick the sheets that went OR describe what went (hardware
-- has no sheet), or both. Metal, Assembly/QC and Delivery can send and
-- return. "At Arrow now" shows days out as a plain number; the office
-- sets when an item needs attention on the TV (14 days to start).
-- Sheets are stored by sheet number, so a revised work order doesn't
-- orphan a record. No delete — "Entered by mistake" instead.
--
-- QC — Assembly/QC records a sheet as passed or failed. A failure needs
-- a note, and logs a "Failed QC" defect on that sheet, so every
-- department sees it on the piece.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('arrow_qc.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.sees_lane(boolean)') is null then
    raise exception 'Run problems.sql first (step 4). This file builds on it.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- Settings the office can change (the TV link lives here too, step 9)
-- ---------------------------------------------------------------------

create table if not exists app_settings (
  key             text primary key,
  value           jsonb       not null,
  updated_by_name text,
  updated_at      timestamptz not null default now()
);
insert into app_settings (key, value) values ('arrow_alert_days', '14') on conflict (key) do nothing;
alter table app_settings enable row level security;
drop policy if exists read_app_settings on app_settings;
create policy read_app_settings on app_settings for select to authenticated using (key not like 'secret_%');
revoke insert, update, delete on app_settings from anon, authenticated;

create or replace function set_arrow_alert_days(p_days int) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can change this.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_days, 0) not between 1 and 90 then raise exception 'Pick a number of days from 1 to 90.'; end if;
  insert into app_settings (key, value, updated_by_name, updated_at) values ('arrow_alert_days', to_jsonb(p_days), my_name(), now())
  on conflict (key) do update set value = excluded.value, updated_by_name = excluded.updated_by_name, updated_at = now();
  return format('The TV now shows anything at Arrow for more than %s days.', p_days);
end $$;
revoke all on function set_arrow_alert_days(int) from public, anon;
grant execute on function set_arrow_alert_days(int) to authenticated;


-- ---------------------------------------------------------------------
-- Arrow
-- ---------------------------------------------------------------------

create table if not exists outside_jobs (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid unique,
  job_id           uuid        not null references jobs(id) on delete cascade,
  sheet_numbers    int[]       not null default '{}',
  description      text,
  vendor           text        not null default 'Arrow',
  service          text        not null check (service in ('powdercoat', 'paint')),
  department       text        not null references departments(key),   -- the sender's
  is_test          boolean     not null default false,
  sent_on          date        not null,
  sent_by          uuid        references profiles(id),
  sent_by_name     text,
  sent_at          timestamptz not null default now(),
  returned_on      date,
  returned_by_name text,
  returned_at      timestamptz,
  voided_at        timestamptz,
  voided_by_name   text,
  void_reason      text,
  check (cardinality(sheet_numbers) > 0 or length(trim(coalesce(description, ''))) > 0)
);
create index if not exists outside_jobs_open_idx on outside_jobs (returned_on, voided_at);
alter table outside_jobs enable row level security;
drop policy if exists read_outside_jobs on outside_jobs;
create policy read_outside_jobs on outside_jobs for select to authenticated using (sees_lane(is_test));
revoke insert, update, delete on outside_jobs from anon, authenticated;

create or replace function arrow_departments() returns text[]
language sql immutable as $$ select array['metal', 'assembly_qc', 'delivery'] $$;
grant execute on function arrow_departments() to authenticated;

create or replace function send_to_arrow(p_job uuid, p_department text, p_service text,
                                         p_sheets int[] default '{}', p_description text default null,
                                         p_sent_on date default null, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_id uuid; s int; v_sheets int[];
begin
  if p_client_id is not null then
    select id into v_id from outside_jobs where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.'); end if;
  end if;
  if not (p_department = any(arrow_departments())) then
    raise exception 'Arrow items are sent from Metal, Assembly / QC or Delivery.';
  end if;
  v_job := floor_entry_check(p_department, p_job);
  if p_service not in ('powdercoat', 'paint') then raise exception 'Powdercoat or paint?'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_sheets from unnest(coalesce(p_sheets, '{}')) x;
  foreach s in array v_sheets loop perform check_job_sheet(p_job, s); end loop;
  if cardinality(v_sheets) = 0 and nullif(trim(p_description), '') is null then
    raise exception 'Tick the sheets that went, or describe what went (or both).';
  end if;
  if coalesce(p_sent_on, local_today()) > local_today() then raise exception 'The date sent can''t be in the future.'; end if;
  insert into outside_jobs (client_id, job_id, sheet_numbers, description, service, department, is_test, sent_on, sent_by, sent_by_name)
  values (p_client_id, p_job, v_sheets, nullif(trim(p_description), ''), p_service, p_department, v_job.is_test,
          coalesce(p_sent_on, local_today()), auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Sent to Arrow: %s.', v_job.project_id));
exception when unique_violation then
  select id into v_id from outside_jobs where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.');
end $$;
revoke all on function send_to_arrow(uuid, text, text, int[], text, date, uuid) from public, anon;
grant execute on function send_to_arrow(uuid, text, text, int[], text, date, uuid) to authenticated;

-- anyone who works an Arrow department (or a manager) can mark an item back
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
  if v_on < v.sent_on then raise exception 'It can''t come back before it went (%).', to_char(v.sent_on, 'Mon FMDD'); end if;
  if v_on > local_today() then raise exception 'The date returned can''t be in the future.'; end if;
  update outside_jobs set returned_on = v_on, returned_by_name = my_name(), returned_at = now() where id = p_item;
  return jsonb_build_object('ok', true, 'summary', format('%s back from Arrow after %s day%s.', v_pid, v_on - v.sent_on,
                                                         case when v_on - v.sent_on = 1 then '' else 's' end));
end $$;
revoke all on function return_from_arrow(uuid, date) from public, anon;
grant execute on function return_from_arrow(uuid, date) to authenticated;

-- the sender's department or a manager
create or replace function void_arrow(p_item uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v outside_jobs;
begin
  select * into v from outside_jobs where id = p_item;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That Arrow item isn''t there.'; end if;
  if not (office_ok() or (owns_dept(v.department) and v.is_test = am_test())) then
    raise exception 'Only % (who sent it) or a manager can mark this entered by mistake.', (select name from departments where key = v.department)
      using errcode = 'insufficient_privilege';
  end if;
  update outside_jobs set voided_at = coalesce(voided_at, now()), voided_by_name = coalesce(voided_by_name, my_name()),
                          void_reason = coalesce(void_reason, nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = p_item;
  return 'Marked as entered by mistake. It''s kept in history but off the lists.';
end $$;
revoke all on function void_arrow(uuid, text) from public, anon;
grant execute on function void_arrow(uuid, text) to authenticated;

drop view if exists v_outside_jobs;
create view v_outside_jobs with (security_invoker = true) as
select o.id, o.job_id, j.project_id, j.name as job_name, o.sheet_numbers, o.description, o.vendor, o.service,
       o.department, d.name as department_name, o.is_test, o.sent_on, o.sent_by, o.sent_by_name,
       o.returned_on, o.returned_by_name, (o.voided_at is not null) as voided, o.void_reason,
       (o.returned_on is null and o.voided_at is null) as at_vendor,
       coalesce(o.returned_on, local_today()) - o.sent_on as days_out
from outside_jobs o
join jobs j        on j.id = o.job_id
join departments d on d.key = o.department;
revoke all on v_outside_jobs from anon;
grant select on v_outside_jobs to authenticated;


-- ---------------------------------------------------------------------
-- QC
-- ---------------------------------------------------------------------

insert into defect_types (department, label, sort_order) values ('assembly_qc', 'Failed QC', 50)
on conflict (department, label) do nothing;

create table if not exists qc_entries (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid unique,
  job_id          uuid        not null references jobs(id) on delete cascade,
  sheet_number    int         not null,
  result          text        not null check (result in ('pass', 'fail')),
  note            text,
  defect_id       uuid        references defects(id),
  is_test         boolean     not null default false,
  checked_by      uuid        references profiles(id),
  checked_by_name text,
  checked_at      timestamptz not null default now(),
  voided_at       timestamptz,
  voided_by_name  text,
  void_reason     text,
  check (result = 'pass' or length(trim(coalesce(note, ''))) > 0)
);
create index if not exists qc_entries_job_idx on qc_entries (job_id, sheet_number, checked_at desc);
alter table qc_entries enable row level security;
drop policy if exists read_qc_entries on qc_entries;
create policy read_qc_entries on qc_entries for select to authenticated using (sees_lane(is_test));
revoke insert, update, delete on qc_entries from anon, authenticated;

create or replace function record_qc(p_job uuid, p_sheet int, p_result text, p_note text default null,
                                     p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_id uuid; v_defect jsonb; v_type uuid;
begin
  if p_client_id is not null then
    select id into v_id from qc_entries where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already recorded.'); end if;
  end if;
  v_job := floor_entry_check('assembly_qc', p_job);
  if p_sheet is null then raise exception 'Pick the sheet that was checked.'; end if;
  perform check_job_sheet(p_job, p_sheet);
  if p_result not in ('pass', 'fail') then raise exception 'Passed or failed?'; end if;
  if p_result = 'fail' and nullif(trim(p_note), '') is null then raise exception 'Say what failed.'; end if;
  if p_result = 'fail' then
    select id into v_type from defect_types where department = 'assembly_qc' and label = 'Failed QC';
    if v_type is null then
      insert into defect_types (department, label, sort_order) values ('assembly_qc', 'Failed QC', 50) returning id into v_type;
    end if;
    update defect_types set active = true where id = v_type and not active;
    v_defect := log_defect(p_job, 'assembly_qc', v_type, p_sheet, p_note, null);
  end if;
  insert into qc_entries (client_id, job_id, sheet_number, result, note, defect_id, is_test, checked_by, checked_by_name)
  values (p_client_id, p_job, p_sheet, p_result, nullif(trim(p_note), ''), (v_defect->>'id')::uuid, v_job.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('QC %s: %s sheet %s%s.', case when p_result = 'pass' then 'passed' else 'failed' end, v_job.project_id, p_sheet,
                      case when p_result = 'fail' then ' — logged as a defect on the sheet' else '' end));
exception when unique_violation then
  select id into v_id from qc_entries where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already recorded.');
end $$;
revoke all on function record_qc(uuid, int, text, text, uuid) from public, anon;
grant execute on function record_qc(uuid, int, text, text, uuid) to authenticated;

create or replace function void_qc(p_entry uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v qc_entries;
begin
  select * into v from qc_entries where id = p_entry;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That QC entry isn''t there.'; end if;
  if not (v.checked_by = auth.uid() or office_ok()) then
    raise exception 'Only the person who recorded it, or a manager, can undo it.' using errcode = 'insufficient_privilege';
  end if;
  update qc_entries set voided_at = coalesce(voided_at, now()), voided_by_name = coalesce(voided_by_name, my_name()),
                        void_reason = coalesce(void_reason, nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = p_entry;
  if v.defect_id is not null then
    update defects set voided_at = coalesce(voided_at, now()), voided_by = coalesce(voided_by, auth.uid()),
                       voided_by_name = coalesce(voided_by_name, my_name()), void_reason = coalesce(void_reason, 'QC entry entered by mistake')
     where id = v.defect_id;
  end if;
  return 'Marked as entered by mistake.';
end $$;
revoke all on function void_qc(uuid, text) from public, anon;
grant execute on function void_qc(uuid, text) to authenticated;

drop view if exists v_qc_entries;
create view v_qc_entries with (security_invoker = true) as
select q.id, q.job_id, j.project_id, j.name as job_name, q.sheet_number, q.result, q.note, q.is_test,
       q.checked_by, q.checked_by_name, q.checked_at, (q.voided_at is not null) as voided
from qc_entries q
join jobs j on j.id = q.job_id;
revoke all on v_qc_entries from anon;
grant select on v_qc_entries to authenticated;
