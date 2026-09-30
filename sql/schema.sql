-- =====================================================================
-- Shop Floor Production System — Phase 1 schema
-- Run this whole file in the Supabase SQL editor, once, on a new project.
-- Safe to re-run: everything is IF NOT EXISTS / ON CONFLICT DO NOTHING.
--
-- Phase 1 scope: jobs mirrored from Monday, work orders and sheets pushed
-- by the generator, and per-department piece counts.
-- Defects, problems, flags, materials, supplies and the Monday write-back
-- queue are specified but deliberately NOT here. They land in Phase 2/3.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('schema.sql'); end if;
end $$;

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. People
-- ---------------------------------------------------------------------

do $$ begin
  create type app_role as enum ('supervisor', 'manager', 'admin');
exception when duplicate_object then null; end $$;

-- One row per person, hanging off Supabase's auth.users.
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text        not null,
  role        app_role    not null default 'supervisor',
  -- department keys this person owns; a supervisor may own more than one
  -- (milling and CNC are one person)
  departments text[]      not null default '{}',
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Departments (fixed lookup)
-- ---------------------------------------------------------------------

create table if not exists departments (
  key           text primary key,
  name          text    not null,
  sort_order    int     not null,
  -- which Monday column this department rolls up into
  monday_column text,
  -- the department whose work must be finished before this one can start.
  -- null means it can start as soon as the job exists (metal, full custom).
  predecessor   text references departments(key)
);

insert into departments (key, name, sort_order, monday_column, predecessor) values
  ('milling',     'Milling',       1, 'wood_status',        null),
  ('cnc',         'CNC',           2, 'wood_status',        'milling'),
  ('sanding',     'Sanding',       3, 'wood_status',        'cnc'),
  ('finishing',   'Finishing',     4, 'wood_status',        'sanding'),
  ('full_custom', 'Full Custom',   5, 'full_custom_status', null),
  ('metal',       'Metal',         6, 'metal_status',       null),
  ('assembly_qc', 'Assembly / QC', 7, 'assembly_qc_status', 'finishing')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 3. Jobs — mirrored from Monday, never edited here
-- ---------------------------------------------------------------------

create table if not exists jobs (
  id                uuid primary key default gen_random_uuid(),
  -- the join key. Monday's internal item id, which never changes.
  -- NOT the PROJ number: that is blank on some rows and lives in the name.
  monday_item_id    bigint      not null unique,
  project_id        text,                      -- 'PROJ-00418'
  name              text        not null,
  delivery_date     date,                      -- date, not timestamp
  phase             text,
  is_active         boolean     not null default true,
  materials_ordered boolean     not null default false,
  last_synced_at    timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists jobs_active_due_idx on jobs (is_active, delivery_date);
create index if not exists jobs_project_idx    on jobs (project_id);

-- ---------------------------------------------------------------------
-- 4. Work orders and sheets
-- ---------------------------------------------------------------------

create table if not exists work_orders (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid        not null references jobs(id) on delete cascade,
  version      int         not null default 1,
  is_current   boolean     not null default true,
  total_items  int,                             -- for reconciliation
  source_file  text,
  superseded_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (job_id, version)
);

-- exactly one current version per job
create unique index if not exists work_orders_one_current_idx
  on work_orders (job_id) where is_current;

create table if not exists sheets (
  id              uuid primary key default gen_random_uuid(),
  work_order_id   uuid        not null references work_orders(id) on delete cascade,
  sheet_number    int         not null,         -- the real key within a work order
  item_code       text,                         -- 'TB-03' — display only, repeats
  qty             int         not null check (qty > 0),
  species         text,
  shape           text,
  width           text,
  length          text,
  thickness       text,
  total_height    text,
  top_spec        jsonb       not null default '{}',
  base_spec       jsonb       not null default '{}',
  finish_spec     jsonb       not null default '{}',
  cnc_program     text,
  glue_up_notes   text,
  floor_notes     text,                         -- 'NO BISCUITS!'
  spec_hash       text,                         -- drives change-order carry-forward
  pdf_path        text,                         -- storage path to this sheet's page
  pdf_uploaded_at timestamptz,
  created_at      timestamptz not null default now(),
  unique (work_order_id, sheet_number)
);

-- ---------------------------------------------------------------------
-- 5. Progress — the heart of the system
-- ---------------------------------------------------------------------

do $$ begin
  create type progress_state as enum ('not_started', 'in_progress', 'complete', 'blocked');
exception when duplicate_object then null; end $$;

create table if not exists sheet_progress (
  id            uuid primary key default gen_random_uuid(),
  sheet_id      uuid        not null references sheets(id) on delete cascade,
  department    text        not null references departments(key),
  qty_required  int         not null check (qty_required > 0),
  qty_done      int         not null default 0 check (qty_done >= 0),
  state         progress_state not null default 'not_started',
  started_at    timestamptz,
  completed_at  timestamptz,
  updated_by    uuid references profiles(id),
  updated_at    timestamptz not null default now(),
  unique (sheet_id, department),
  check (qty_done <= qty_required)
);

create index if not exists sheet_progress_dept_idx  on sheet_progress (department, state);
create index if not exists sheet_progress_sheet_idx on sheet_progress (sheet_id);

-- Append-only. Never updated, never deleted.
-- Feeds the audit trail, throughput numbers and "who marked this done".
create table if not exists progress_events (
  id           bigserial primary key,
  sheet_id     uuid        not null references sheets(id) on delete cascade,
  department   text        not null references departments(key),
  qty_from     int,
  qty_to       int,
  state_from   progress_state,
  state_to     progress_state,
  actor        uuid references profiles(id),
  occurred_at  timestamptz not null default now()
);

create index if not exists progress_events_time_idx on progress_events (occurred_at desc);
create index if not exists progress_events_dept_idx on progress_events (department, occurred_at desc);

-- ---------------------------------------------------------------------
-- 6. Triggers — state is derived, never typed
-- ---------------------------------------------------------------------

create or replace function sheet_progress_derive() returns trigger as $$
begin
  -- 'blocked' is set deliberately elsewhere; otherwise state follows the counts
  if new.state is distinct from 'blocked' then
    if    new.qty_done = 0                then new.state := 'not_started';
    elsif new.qty_done < new.qty_required then new.state := 'in_progress';
    else                                       new.state := 'complete';
    end if;
  end if;

  if new.qty_done > 0 and new.started_at is null then
    new.started_at := now();
  end if;

  new.completed_at := case when new.state = 'complete' then coalesce(new.completed_at, now()) end;
  new.updated_at := now();
  -- who did it comes from the login, never from the request body.
  -- service-key writes (uploads, sync) have no auth.uid() and keep what they sent.
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$ language plpgsql;

drop trigger if exists sheet_progress_derive_trg on sheet_progress;
create trigger sheet_progress_derive_trg
  before insert or update on sheet_progress
  for each row execute function sheet_progress_derive();

create or replace function sheet_progress_log() returns trigger as $$
begin
  if tg_op = 'UPDATE'
     and new.qty_done is not distinct from old.qty_done
     and new.state    is not distinct from old.state then
    return new;                      -- nothing worth recording
  end if;

  insert into progress_events (sheet_id, department, qty_from, qty_to, state_from, state_to, actor)
  values (new.sheet_id, new.department,
          case when tg_op = 'UPDATE' then old.qty_done end, new.qty_done,
          case when tg_op = 'UPDATE' then old.state    end, new.state,
          new.updated_by);
  return new;
end $$ language plpgsql
   -- runs as the owner so it can write history that no user can write directly.
   -- without this the first count a supervisor enters fails on RLS.
   security definer set search_path = public;

drop trigger if exists sheet_progress_log_trg on sheet_progress;
create trigger sheet_progress_log_trg
  after insert or update on sheet_progress
  for each row execute function sheet_progress_log();

-- ---------------------------------------------------------------------
-- 7. Views
-- ---------------------------------------------------------------------

-- Pieces a department can pick up right now: cleared by the nearest earlier
-- stage this sheet actually has, not yet done here. The number for the TV.
--
-- security_invoker: the view applies the caller's RLS. Without it a view runs
-- as its owner and hands every department's rows to anyone who asks.
drop view if exists v_ready_to_work;
create view v_ready_to_work with (security_invoker = true) as
with recursive ancestors as (
  -- every stage upstream of each department, nearest first
  select key as dept, predecessor as anc, 1 as depth
    from departments where predecessor is not null
  union all
  select a.dept, d.predecessor, a.depth + 1
    from ancestors a join departments d on d.key = a.anc
   where d.predecessor is not null
)
select
  sp.department,
  s.id as sheet_id,
  j.id as job_id,
  -- no upstream stage on this sheet means the whole quantity is available.
  -- assembly also waits on metal in reality; that joins in Phase 2.
  greatest(coalesce(up.qty_done, sp.qty_required) - sp.qty_done, 0) as ready
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id and j.is_active
left join lateral (
  -- nearest upstream stage that exists on THIS sheet — so a sheet with no
  -- CNC work reads sanding's supply from milling rather than from nothing
  select pre.qty_done
    from ancestors a
    join sheet_progress pre on pre.sheet_id = sp.sheet_id and pre.department = a.anc
   where a.dept = sp.department
   order by a.depth
   limit 1
) up on true;

-- Per job, per department: done vs total.
drop view if exists v_job_department_progress;
create view v_job_department_progress with (security_invoker = true) as
select
  j.id as job_id, j.project_id, j.name, j.delivery_date,
  sp.department,
  sum(sp.qty_done)     as done,
  sum(sp.qty_required) as total
from jobs j
join work_orders w     on w.job_id = j.id and w.is_current
join sheets s          on s.work_order_id = w.id
join sheet_progress sp on sp.sheet_id = s.id
where j.is_active
group by j.id, j.project_id, j.name, j.delivery_date, sp.department;

-- ---------------------------------------------------------------------
-- 8. Row-level security
--
-- This is the real access control. The interface hiding a tab is not.
-- A supervisor cannot reach another department's rows even by hand.
-- ---------------------------------------------------------------------

create or replace function my_role() returns app_role as $$
  select role from profiles where id = auth.uid();
$$ language sql stable security definer set search_path = public;

create or replace function owns_dept(dept text) returns boolean as $$
  select exists (
    select 1 from profiles
     where id = auth.uid()
       and (role in ('manager','admin') or dept = any(departments))
  );
$$ language sql stable security definer set search_path = public;

alter table profiles        enable row level security;
alter table departments     enable row level security;
alter table jobs            enable row level security;
alter table work_orders     enable row level security;
alter table sheets          enable row level security;
alter table sheet_progress  enable row level security;
alter table progress_events enable row level security;

-- Everyone signed in reads the shared reference data.
-- Jobs and sheets are not secret; what you may CHANGE is the point.
drop policy if exists read_departments on departments;
create policy read_departments on departments for select to authenticated using (true);

drop policy if exists read_jobs on jobs;
create policy read_jobs on jobs for select to authenticated using (true);

drop policy if exists read_work_orders on work_orders;
create policy read_work_orders on work_orders for select to authenticated using (true);

drop policy if exists read_sheets on sheets;
create policy read_sheets on sheets for select to authenticated using (true);

-- Profiles: your own, plus managers see everyone.
drop policy if exists read_profiles on profiles;
create policy read_profiles on profiles for select to authenticated
  using (id = auth.uid() or my_role() in ('manager','admin'));

-- Progress: everyone signed in can READ every department's counts.
-- They aren't secret (the TV shows them to the whole floor), and a
-- department needs to see its upstream stage to know what's ready.
drop policy if exists read_progress on sheet_progress;
create policy read_progress on sheet_progress for select to authenticated
  using (true);

-- Progress: CHANGE only your own departments...
drop policy if exists write_progress on sheet_progress;
create policy write_progress on sheet_progress for update to authenticated
  using (owns_dept(department))
  with check (owns_dept(department));

-- ...and only the count. Policies decide which ROWS; grants decide which
-- COLUMNS. Without this a supervisor could rewrite qty_required, the
-- department, or who the change is attributed to. The trigger still sets
-- state, timestamps and updated_by — grants don't restrict triggers.
revoke insert, update, delete on sheet_progress from anon, authenticated;
grant  update (qty_done)      on sheet_progress to authenticated;

-- Nothing user-facing writes these directly, ever.
revoke insert, update, delete on jobs, work_orders, sheets, departments,
                                 profiles, progress_events
  from anon, authenticated;

-- History is readable by whoever owns the department, and writable by nobody.
-- Rows arrive only through the trigger, which is security definer (above).
drop policy if exists read_events on progress_events;
create policy read_events on progress_events for select to authenticated
  using (owns_dept(department));

-- Jobs, work orders, sheets and progress rows are created by the upload
-- endpoint and the Monday sync, both of which use the service key and
-- bypass RLS. No user-facing insert policy is wanted here.

-- ---------------------------------------------------------------------
-- 9. After running this
--
--   0. Authentication -> Sign In / Providers -> turn OFF "Allow new users
--      to sign up". The tablet app's code will be public on GitHub Pages,
--      including the project URL and anon key — that's how Supabase is
--      designed, but it means anyone could otherwise create an account
--      and read every job name. Create users by invite only.
--   1. Create the two auth users in the Supabase dashboard.
--   2. Insert their profiles, e.g.
--
--      insert into profiles (id, full_name, role, departments) values
--        ('<luke-uuid>',   'Luke H',  'manager',    '{}'),
--        ('<mike-uuid>',   'Mike B',  'supervisor', '{sanding}');
--
--   3. Signed in as Mike, confirm:
--        - updating qty_done on a sanding row works, and writes a
--          progress_events row with Mike as the actor
--        - updating qty_done on a metal row changes nothing
--        - updating qty_required on his own row is refused
--      If any of those fail, stop: nothing else is trustworthy until they pass.
-- ---------------------------------------------------------------------
