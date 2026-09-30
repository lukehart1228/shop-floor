-- =====================================================================
-- Shop Floor — problems and defects (whole-floor build, step 4)
--
-- HOW TO USE: run office.sql, test_lane.sql and catch_up.sql first.
-- Then paste this whole file into a NEW, empty query in the Supabase
-- SQL Editor and click Run. Safe to run more than once.
--
-- What it adds:
--   1. Delivery — an eighth department, marked log-only: no sheet
--      counts, no queue, no catch-up, not on the TV. It still logs
--      defects and problems.
--   2. Each department's defect list, from the old supervisor app
--      (Glue Up / Wide Belt folded into Milling)
--   3. Log a defect — one tap, counted, interrupts nobody
--   4. Flag a problem — goes to the office and stays open until it's
--      answered. Problems are threads: a supervisor's reply brings an
--      answered problem back to the office, tagged "Came back".
--      "Work is stopped" is a tick box on a problem.
--   5. Both are keyed by (job, sheet number), so a revised work order
--      keeps a sheet's history. The sheet may be blank for job-level
--      entries, such as Delivery's "Missing product on site".
--
-- Nothing is deleted. A wrong entry is marked "Entered by mistake",
-- which hides it and keeps it in history. Every change goes through a
-- database function that checks the login; nobody writes to these
-- tables directly.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('problems.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.monday_stage_map') is null or to_regprocedure('public.am_test()') is null then
    raise exception 'Run office.sql, test_lane.sql and catch_up.sql first (steps 1–3). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Log-only departments, and Delivery
-- ---------------------------------------------------------------------

alter table departments add column if not exists log_only boolean not null default false;

insert into departments (key, name, sort_order, monday_column, predecessor, is_live, log_only)
values ('delivery', 'Delivery', 8, null, null, false, true)
on conflict (key) do nothing;

-- A log-only department never gets sheet counts. If a work order ever
-- names one, the upload stops with this message and nothing is saved.
create or replace function sheet_progress_not_log_only() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  select name into v_name from departments where key = new.department and log_only;
  if v_name is not null then
    raise exception '% is a log-only department, so it has no sheet counts. Take it off this sheet''s department list.', v_name;
  end if;
  return new;
end $$;
drop trigger if exists sheet_progress_not_log_only_trg on sheet_progress;
create trigger sheet_progress_not_log_only_trg before insert or update of department on sheet_progress
  for each row execute function sheet_progress_not_log_only();


-- ---------------------------------------------------------------------
-- 2. Small helpers used by every step from here on
-- ---------------------------------------------------------------------

-- today, on the shop floor's clock (the database runs on UTC)
create or replace function local_today() returns date
language sql stable as $$ select (now() at time zone 'America/Indiana/Indianapolis')::date $$;

create or replace function is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role()::text, '') in ('manager', 'admin');
$$;

-- may the person signed in SEE a row in this lane?
-- test logins see test rows only; real supervisors real rows only; managers both
create or replace function sees_lane(p_is_test boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_is_test, false) = am_test() or is_manager();
$$;

-- a manager signed in, or the SQL Editor when it isn't pretending to be
-- someone (the checks do that, and must then hit the same walls)
create or replace function office_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select is_manager()
      or (session_user in ('postgres', 'supabase_admin')
          and (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub') is null);
$$;

-- the name of the person signed in, stored beside each entry so every
-- supervisor's tablet can show who did what
create or replace function my_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from profiles where id = auth.uid()),
                  case when session_user in ('postgres', 'supabase_admin') then 'SQL Editor' end, 'Someone');
$$;

revoke all on function is_manager()        from public, anon;
revoke all on function sees_lane(boolean)  from public, anon;
revoke all on function my_name()           from public, anon;
revoke all on function office_ok()         from public, anon;
grant execute on function is_manager()       to authenticated;
grant execute on function sees_lane(boolean) to authenticated;
grant execute on function my_name()          to authenticated;
grant execute on function office_ok()        to authenticated;
grant execute on function local_today()      to authenticated;

-- The checks every floor entry goes through: signed in, owns the
-- department, and the job is in the same lane as the login.
create or replace function floor_entry_check(p_department text, p_job uuid) returns jobs
language plpgsql stable security definer set search_path = public as $$
declare v_job jobs; v_dept departments;
begin
  if my_role() is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_dept from departments where key = p_department;
  if v_dept.key is null then
    raise exception '"%" is not a department.', p_department;
  end if;
  if not owns_dept(p_department) then
    raise exception 'This login can''t make entries for %.', v_dept.name using errcode = 'insufficient_privilege';
  end if;
  if p_job is null then
    raise exception 'Pick a job first.';
  end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null then
    raise exception 'That job isn''t in the system.';
  end if;
  if v_job.is_test <> am_test() then
    raise exception '%', case when am_test()
      then 'A test login can only make entries on test jobs.'
      else v_job.project_id || ' is a test job. Only the Test Supervisor makes entries on test jobs.' end
      using errcode = 'insufficient_privilege';
  end if;
  return v_job;
end $$;
revoke all on function floor_entry_check(text, uuid) from public, anon, authenticated;

-- A sheet number must be on the job's current work order. Blank is fine
-- (a job-level entry).
create or replace function check_job_sheet(p_job uuid, p_sheet int) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_wo uuid; v_pid text;
begin
  if p_sheet is null then return; end if;
  select project_id into v_pid from jobs where id = p_job;
  select id into v_wo from work_orders where job_id = p_job and is_current;
  if v_wo is null then
    raise exception '% has no work order uploaded, so leave the sheet blank.', v_pid;
  end if;
  if not exists (select 1 from sheets where work_order_id = v_wo and sheet_number = p_sheet) then
    raise exception 'Sheet % isn''t on %''s current work order.', p_sheet, v_pid;
  end if;
end $$;
revoke all on function check_job_sheet(uuid, int) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. The job and sheet pickers the tablet uses
--
-- Jobs on the floor, plus jobs in Delivery or Closeout (Delivery logs
-- against those). Lane-aware: a test login sees test jobs only, and
-- everyone else real jobs only.
-- ---------------------------------------------------------------------

drop view if exists v_pick_jobs;
create view v_pick_jobs with (security_invoker = true) as
select
  j.id            as job_id,
  j.project_id,
  j.name          as job_name,
  j.delivery_date,
  j.phase,
  j.is_active,
  j.is_test,
  exists (select 1 from work_orders w where w.job_id = j.id and w.is_current) as has_work_order
from jobs j
where (j.monday_item_id is not null or j.is_test)
  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')))
  and j.is_test = am_test();
revoke all on v_pick_jobs from anon;
grant select on v_pick_jobs to authenticated;

drop view if exists v_pick_sheets;
create view v_pick_sheets with (security_invoker = true) as
select
  w.job_id,
  s.sheet_number,
  s.item_code,
  s.qty,
  s.species,
  s.shape,
  coalesce((select array_agg(sp.department order by sp.department) from sheet_progress sp where sp.sheet_id = s.id), '{}') as departments
from work_orders w
join sheets s on s.work_order_id = w.id
join jobs j   on j.id = w.job_id
where w.is_current
  and (j.monday_item_id is not null or j.is_test)
  and j.is_test = am_test();
revoke all on v_pick_sheets from anon;
grant select on v_pick_sheets to authenticated;


-- ---------------------------------------------------------------------
-- 4. Defect lists — one per department, editable by managers
-- ---------------------------------------------------------------------

create table if not exists defect_types (
  id          uuid primary key default gen_random_uuid(),
  department  text        not null references departments(key),
  label       text        not null,
  sort_order  int         not null default 100,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  unique (department, label)
);
alter table defect_types enable row level security;
drop policy if exists read_defect_types on defect_types;
create policy read_defect_types on defect_types for select to authenticated using (true);
revoke insert, update, delete on defect_types from anon, authenticated;

-- the old app's lists. A label a manager retires stays retired: running
-- this file again adds only what's missing.
insert into defect_types (department, label, sort_order)
select d, l, o from (values
  ('milling', 'Wrong species', 1), ('milling', 'Not hitting width spec after SLR', 2), ('milling', 'Cut wrong length', 3),
  ('milling', 'Unusable lumber after SLR', 4), ('milling', 'Wrong thickness', 5),
  ('milling', 'Open glue seam', 6), ('milling', 'Not able to hit thickness', 7), ('milling', 'Under width after glue', 8),
  ('milling', 'Large snipe', 9), ('milling', 'Excessive pressure marks', 10),
  ('cnc', 'Failed table', 1), ('cnc', 'Table requires fixing', 2),
  ('sanding', 'Missed defect — caught after finish', 1), ('sanding', 'Caused defect — caught before finish', 2),
  ('sanding', 'Caused defect — caught after finish', 3),
  ('finishing', 'Didn''t meet color spec', 1), ('finishing', 'Junk in finish', 2), ('finishing', 'Sheen issue', 3),
  ('finishing', 'Runs', 4), ('finishing', 'Stained wrong color', 5),
  ('full_custom', 'Item had to be redone', 1), ('full_custom', 'Item had to be reworked', 2),
  ('metal', 'Item had to be scrapped', 1), ('metal', 'Item had to be reworked', 2),
  ('assembly_qc', 'Damaged before assembly', 1), ('assembly_qc', 'Damaged during assembly', 2),
  ('assembly_qc', 'Damaged after assembly', 3), ('assembly_qc', 'Damaged in long-term storage', 4),
  ('assembly_qc', 'Assembled incorrectly', 5),
  ('delivery', 'Product damaged by PD', 1), ('delivery', 'Missing product on site', 2), ('delivery', 'No site contact', 3),
  ('delivery', 'Customer requested out-of-scope work', 4), ('delivery', 'Damaged by third-party help', 5),
  ('delivery', 'Damaged during loading', 6), ('delivery', 'Damaged during transit', 7)
) v(d, l, o)
on conflict (department, label) do nothing;

-- add a label, or retire / bring back one. Managers only.
create or replace function set_defect_type(p_department text, p_label text, p_active boolean default true) returns text
language plpgsql security definer set search_path = public as $$
declare v_label text := nullif(trim(p_label), ''); v_name text;
begin
  if not office_ok() then
    raise exception 'Only a manager can change the defect lists.' using errcode = 'insufficient_privilege';
  end if;
  select name into v_name from departments where key = p_department;
  if v_name is null then raise exception '"%" is not a department.', p_department; end if;
  if v_label is null then raise exception 'Type the defect first.'; end if;
  insert into defect_types (department, label, sort_order, active)
  values (p_department, v_label,
          coalesce((select max(sort_order) + 1 from defect_types where department = p_department), 1), p_active)
  on conflict (department, label) do update set active = excluded.active;
  return format('%s: "%s" %s.', v_name, v_label, case when p_active then 'is on the list' else 'is retired — old entries keep it' end);
end $$;
revoke all on function set_defect_type(text, text, boolean) from public, anon;
grant execute on function set_defect_type(text, text, boolean) to authenticated;


-- ---------------------------------------------------------------------
-- 5. Defects
-- ---------------------------------------------------------------------

create table if not exists defects (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid unique,                         -- the tablet's own id, so a resend can't log it twice
  job_id          uuid        not null references jobs(id) on delete cascade,
  sheet_number    int,                                 -- blank = the whole job
  department      text        not null references departments(key),
  defect_type_id  uuid        not null references defect_types(id),
  defect_type     text        not null,                -- the label as it read when logged
  note            text,
  is_test         boolean     not null default false,
  logged_by       uuid        references profiles(id),
  logged_by_name  text,
  logged_at       timestamptz not null default now(),
  voided_at       timestamptz,                         -- "Entered by mistake"
  voided_by       uuid        references profiles(id),
  voided_by_name  text,
  void_reason     text
);
create index if not exists defects_job_idx  on defects (job_id, sheet_number);
create index if not exists defects_dept_idx on defects (department, logged_at desc);
alter table defects enable row level security;
drop policy if exists read_defects on defects;
create policy read_defects on defects for select to authenticated using (sees_lane(is_test));
revoke insert, update, delete on defects from anon, authenticated;

create or replace function log_defect(p_job uuid, p_department text, p_type uuid,
                                      p_sheet int default null, p_note text default null, p_client_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_type defect_types; v_id uuid;
begin
  if p_client_id is not null then
    select id into v_id from defects where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already logged.'); end if;
  end if;
  v_job := floor_entry_check(p_department, p_job);
  select * into v_type from defect_types where id = p_type;
  if v_type.id is null or v_type.department <> p_department then
    raise exception 'That defect isn''t on %''s list.', (select name from departments where key = p_department);
  end if;
  if not v_type.active then
    raise exception '"%" has been taken off the list. Pick another.', v_type.label;
  end if;
  perform check_job_sheet(p_job, p_sheet);

  insert into defects (client_id, job_id, sheet_number, department, defect_type_id, defect_type, note, is_test, logged_by, logged_by_name)
  values (p_client_id, p_job, p_sheet, p_department, v_type.id, v_type.label, nullif(trim(p_note), ''), v_job.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('Logged %s on %s%s.', v_type.label, v_job.project_id, coalesce(' sheet ' || p_sheet, '')));
exception when unique_violation then
  select id into v_id from defects where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already logged.');
end $$;
revoke all on function log_defect(uuid, text, uuid, int, text, uuid) from public, anon;
grant execute on function log_defect(uuid, text, uuid, int, text, uuid) to authenticated;

-- "Entered by mistake": hides it from counts and lists, keeps it in history.
-- The person who logged it, or a manager.
create or replace function void_defect(p_defect uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v defects;
begin
  select * into v from defects where id = p_defect;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That entry isn''t there.'; end if;
  if not (v.logged_by = auth.uid() or office_ok()) then
    raise exception 'Only the person who logged it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  if v.voided_at is null then
    update defects set voided_at = now(), voided_by = auth.uid(), voided_by_name = my_name(),
                       void_reason = coalesce(nullif(trim(p_reason), ''), 'Entered by mistake')
     where id = p_defect;
  end if;
  return 'Marked as entered by mistake. It''s kept in history but no longer counted.';
end $$;
revoke all on function void_defect(uuid, text) from public, anon;
grant execute on function void_defect(uuid, text) to authenticated;

drop view if exists v_defects;
create view v_defects with (security_invoker = true) as
select d.id, d.job_id, j.project_id, j.name as job_name, d.sheet_number, d.department, dp.name as department_name,
       d.defect_type_id, d.defect_type, d.note, d.is_test, d.logged_by, d.logged_by_name, d.logged_at,
       (d.voided_at is not null) as voided, d.voided_at, d.voided_by_name, d.void_reason
from defects d
join jobs j         on j.id = d.job_id
join departments dp on dp.key = d.department;
revoke all on v_defects from anon;
grant select on v_defects to authenticated;


-- ---------------------------------------------------------------------
-- 6. Problems — threads between the floor and the office
--
-- open      → waiting on the office (or the office replied but kept it open)
-- answered  → the office answered and closed it
-- A supervisor's reply to an answered problem opens it again, tagged
-- "Came back". Work stopped is part of the problem: one thing to clear.
-- ---------------------------------------------------------------------

create table if not exists problems (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid unique,
  job_id           uuid        not null references jobs(id) on delete cascade,
  sheet_number     int,
  department       text        not null references departments(key),
  body             text        not null check (length(trim(body)) > 0),
  work_stopped     boolean     not null default false,
  status           text        not null default 'open' check (status in ('open', 'answered')),
  came_back        boolean     not null default false,
  is_test          boolean     not null default false,
  raised_by        uuid        references profiles(id),
  raised_by_name   text,
  raised_at        timestamptz not null default now(),
  answered_by      uuid        references profiles(id),
  answered_by_name text,
  answered_at      timestamptz,
  last_activity_at timestamptz not null default now()
);
create index if not exists problems_job_idx    on problems (job_id, sheet_number);
create index if not exists problems_status_idx on problems (status, last_activity_at);

create table if not exists problem_messages (
  id              bigserial primary key,
  client_id       uuid unique,
  problem_id      uuid        not null references problems(id) on delete cascade,
  kind            text        not null check (kind in ('answer', 'office_note', 'reply')),
  body            text        not null check (length(trim(body)) > 0),
  written_by      uuid        references profiles(id),
  written_by_name text,
  written_at      timestamptz not null default now()
);
create index if not exists problem_messages_problem_idx on problem_messages (problem_id, written_at);

alter table problems enable row level security;
alter table problem_messages enable row level security;
drop policy if exists read_problems on problems;
create policy read_problems on problems for select to authenticated using (sees_lane(is_test));
drop policy if exists read_problem_messages on problem_messages;
create policy read_problem_messages on problem_messages for select to authenticated
  using (exists (select 1 from problems p where p.id = problem_id));   -- problems' own rule decides
revoke insert, update, delete on problems, problem_messages from anon, authenticated;

create or replace function flag_problem(p_job uuid, p_department text, p_body text,
                                        p_sheet int default null, p_work_stopped boolean default false, p_client_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_id uuid;
begin
  if p_client_id is not null then
    select id into v_id from problems where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.'); end if;
  end if;
  v_job := floor_entry_check(p_department, p_job);
  if nullif(trim(p_body), '') is null then raise exception 'Say what''s wrong first.'; end if;
  perform check_job_sheet(p_job, p_sheet);
  insert into problems (client_id, job_id, sheet_number, department, body, work_stopped, is_test, raised_by, raised_by_name)
  values (p_client_id, p_job, p_sheet, p_department, trim(p_body), coalesce(p_work_stopped, false), v_job.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('Sent to the office: %s%s%s.', v_job.project_id, coalesce(' sheet ' || p_sheet, ''),
                      case when p_work_stopped then ', work stopped' else '' end));
exception when unique_violation then
  select id into v_id from problems where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.');
end $$;
revoke all on function flag_problem(uuid, text, text, int, boolean, uuid) from public, anon;
grant execute on function flag_problem(uuid, text, text, int, boolean, uuid) to authenticated;

-- the floor adds to a problem. On an answered one, it goes back to the office tagged "Came back".
-- p_work_stopped: leave null to keep it as it is.
create or replace function reply_problem(p_problem uuid, p_body text, p_work_stopped boolean default null, p_client_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v problems; v_came boolean;
begin
  if p_client_id is not null and exists (select 1 from problem_messages where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
  end if;
  select * into v from problems where id = p_problem;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That problem isn''t there.'; end if;
  perform floor_entry_check(v.department, v.job_id);
  if nullif(trim(p_body), '') is null then raise exception 'Say what still needs sorting first.'; end if;
  v_came := v.status = 'answered';
  insert into problem_messages (client_id, problem_id, kind, body, written_by, written_by_name)
  values (p_client_id, p_problem, 'reply', trim(p_body), auth.uid(), my_name());
  update problems set status = 'open', came_back = came_back or v_came,
                      work_stopped = coalesce(p_work_stopped, work_stopped), last_activity_at = now()
   where id = p_problem;
  return jsonb_build_object('ok', true, 'summary', case when v_came then 'Sent back to the office.' else 'Added to the problem.' end);
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
end $$;
revoke all on function reply_problem(uuid, text, boolean, uuid) from public, anon;
grant execute on function reply_problem(uuid, text, boolean, uuid) to authenticated;

-- the office answers. p_close true = answered and closed; false = a reply that keeps it open.
create or replace function answer_problem(p_problem uuid, p_body text, p_close boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v problems;
begin
  if not office_ok() then
    raise exception 'Only the office (a manager login) can answer problems.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from problems where id = p_problem;
  if v.id is null then raise exception 'That problem isn''t there.'; end if;
  if nullif(trim(p_body), '') is null then raise exception 'Write the answer first.'; end if;
  insert into problem_messages (problem_id, kind, body, written_by, written_by_name)
  values (p_problem, case when p_close then 'answer' else 'office_note' end, trim(p_body), auth.uid(), my_name());
  if p_close then
    update problems set status = 'answered', came_back = false, answered_by = auth.uid(), answered_by_name = my_name(),
                        answered_at = now(), last_activity_at = now()
     where id = p_problem;
  else
    update problems set last_activity_at = now() where id = p_problem;
  end if;
  return jsonb_build_object('ok', true, 'summary', case when p_close then 'Answered and closed.' else 'Reply sent; it stays open.' end);
end $$;
revoke all on function answer_problem(uuid, text, boolean) from public, anon;
grant execute on function answer_problem(uuid, text, boolean) to authenticated;

drop view if exists v_problems;
create view v_problems with (security_invoker = true) as
select p.id, p.job_id, j.project_id, j.name as job_name, j.is_active as job_active, j.phase, j.delivery_date,
       p.sheet_number, p.department, dp.name as department_name,
       p.body, p.work_stopped, p.status, p.came_back, p.is_test,
       p.raised_by, p.raised_by_name, p.raised_at, p.answered_by_name, p.answered_at, p.last_activity_at,
       coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'body', m.body, 'by', m.written_by_name, 'at', m.written_at)
                                  order by m.written_at, m.id)
                   from problem_messages m where m.problem_id = p.id), '[]'::jsonb) as thread
from problems p
join jobs j         on j.id = p.job_id
join departments dp on dp.key = p.department;
revoke all on v_problems from anon;
grant select on v_problems to authenticated;
