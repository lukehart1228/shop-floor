-- =====================================================================
-- Shop Floor — photos (Walkthrough 7)
--
-- HOW TO USE: run the step 4–9 files first (problems.sql … tv.sql).
-- Then paste this whole file into a NEW, empty query in the Supabase
-- SQL Editor and click Run. Safe to run more than once. Then run
-- check_photos.sql, which should say PASS on every row.
--
-- What it adds:
--   1. A private storage bucket, "photos". JPEG only, 2 MB at most (the
--      tablet shrinks each photo to about 300–500 KB before sending).
--   2. Photos on defects and problems — optional, up to six per entry,
--      shown on the piece, in the problem thread and in the office.
--   3. Delivery load-outs — Shawn photographs each item or pallet
--      against its sheet before the truck leaves ("3 of 4 sheets
--      photographed"); items with no sheet get a photo and a few words.
--   4. The photo archive — old photos move off Supabase to Luke's own
--      storage as a zip, one month at a time, with a one-month overlap.
--
-- Security lives here, not in the pages:
--   * everyone signed in can see photos, lane by lane (test photos stay
--     in the test lane, exactly like every other log entry)
--   * a photo can only be added under your own login, to an entry your
--     department can make, and only after its file has arrived
--   * nobody edits or deletes a photo. A wrong one is marked "Entered by
--     mistake": hidden, kept.
--   * the one deliberate exception to "nothing is deleted": once a batch
--     has been downloaded AND the next month's batch has been downloaded
--     too, a manager may remove that first batch's image FILES from
--     Supabase. The database row of every photo stays for good, saying
--     which zip holds it.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('photos.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.qc_entries') is null or to_regprocedure('public.office_ok()') is null then
    raise exception 'Run the step 4–9 files first (problems.sql, flags.sql, routine_tasks.sql, supplies.sql, arrow_qc.sql, tv.sql). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. When a job left the floor
--
-- The archive waits until a job has been off the floor for 60 days.
-- "On the floor" = In Production or Delivery (Delivery photos are the
-- ones damage claims need). A test job is on the floor until retired.
-- A trigger stamps the date; the Monday sync itself is not touched.
-- ---------------------------------------------------------------------

alter table jobs add column if not exists floor_left_at timestamptz;

create or replace function job_on_floor(p_active boolean, p_test boolean, p_phase text) returns boolean
language sql immutable as $$
  select coalesce(p_active, false) or (not coalesce(p_test, false) and coalesce(p_phase, '') in ('In Production', 'Delivery'));
$$;
grant execute on function job_on_floor(boolean, boolean, text) to authenticated;

create or replace function jobs_floor_left_stamp() returns trigger
language plpgsql as $$
begin
  if job_on_floor(new.is_active, new.is_test, new.phase) then
    new.floor_left_at := null;                                   -- on the floor (again)
  elsif tg_op = 'INSERT' then
    new.floor_left_at := coalesce(new.floor_left_at, now());
  elsif job_on_floor(old.is_active, old.is_test, old.phase) then
    new.floor_left_at := now();                                  -- it has just left
  end if;
  return new;
end $$;
drop trigger if exists jobs_floor_left_trg on jobs;
create trigger jobs_floor_left_trg before insert or update of is_active, phase, is_test on jobs
  for each row execute function jobs_floor_left_stamp();

-- jobs already off the floor start their clock today (none has photos yet)
update jobs set floor_left_at = now()
 where floor_left_at is null and not job_on_floor(is_active, is_test, phase);


-- ---------------------------------------------------------------------
-- 2. The bucket
--
-- Files are named  <PROJ number>/<the tablet's own id>.jpg
-- e.g. PROJ-00418/5f0c…e1.jpg. Test jobs' folders start TEST-, which is
-- how the storage rules keep the lanes apart.
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;


-- ---------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------

create table if not exists loadouts (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid unique,                        -- the tablet's own id, so it works with no Wi-Fi
  job_id            uuid        not null references jobs(id) on delete cascade,
  is_test           boolean     not null default false,
  started_by        uuid        references profiles(id),
  started_by_name   text,
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,                        -- "the truck left"
  finished_by_name  text,
  note              text,
  voided_at         timestamptz,
  voided_by_name    text,
  void_reason       text
);
create index if not exists loadouts_job_idx on loadouts (job_id, started_at);

create table if not exists photo_archive_batches (
  id            text primary key,                       -- '2026-10', or '2026-10-2' for a second one that month
  state         text        not null default 'building'
                  check (state in ('building', 'saved', 'released', 'removed')),
  made_by_name  text,
  made_at       timestamptz not null default clock_timestamp(),
  saved_at      timestamptz,                            -- the zip was downloaded
  released_at   timestamptz,                            -- the next batch was downloaded: these files may now go
  removed_at    timestamptz,                            -- every file is off Supabase
  photos        int         not null default 0,
  bytes         bigint      not null default 0
);

create table if not exists photos (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid        not null unique,          -- the tablet's own id: a resend can't add it twice
  job_id          uuid        not null references jobs(id) on delete cascade,
  sheet_number    int,                                  -- blank = the whole job, or an item with no sheet
  department      text        not null references departments(key),
  kind            text        not null check (kind in ('defect', 'problem', 'loadout')),
  defect_id       uuid        references defects(id),
  problem_id      uuid        references problems(id),
  loadout_id      uuid        references loadouts(id),
  note            text,
  storage_path    text        not null unique,
  bytes           bigint,
  width           int,
  height          int,
  is_test         boolean     not null default false,
  taken_by        uuid        references profiles(id),
  taken_by_name   text,
  taken_at        timestamptz not null default now(),
  voided_at       timestamptz,
  voided_by_name  text,
  void_reason     text,
  archive_batch   text        references photo_archive_batches(id),
  archive_name    text,                                 -- its name inside the zip: PROJ-00418/sheet-03_delivery_2026-10-14.jpg
  file_removed_at timestamptz,                          -- the image file has left Supabase; this row stays
  check ((kind = 'defect') = (defect_id is not null)
     and (kind = 'problem') = (problem_id is not null)
     and (kind = 'loadout') = (loadout_id is not null)),
  check (kind <> 'loadout' or sheet_number is not null or length(trim(coalesce(note, ''))) > 0)
);
create index if not exists photos_job_idx     on photos (job_id, sheet_number);
create index if not exists photos_defect_idx  on photos (defect_id)  where defect_id is not null;
create index if not exists photos_problem_idx on photos (problem_id) where problem_id is not null;
create index if not exists photos_loadout_idx on photos (loadout_id) where loadout_id is not null;
create index if not exists photos_batch_idx   on photos (archive_batch);

alter table loadouts enable row level security;
alter table photos enable row level security;
alter table photo_archive_batches enable row level security;
drop policy if exists read_loadouts on loadouts;
create policy read_loadouts on loadouts for select to authenticated using (sees_lane(is_test));
drop policy if exists read_photos on photos;
create policy read_photos on photos for select to authenticated using (sees_lane(is_test));
drop policy if exists read_photo_batches on photo_archive_batches;
create policy read_photo_batches on photo_archive_batches for select to authenticated using (is_manager());
revoke insert, update, delete on loadouts, photos, photo_archive_batches from anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. Storage rules for the photos bucket
-- ---------------------------------------------------------------------

-- may this file be removed from Supabase? Only once its batch is released.
create or replace function photo_file_released(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from photos p join photo_archive_batches b on b.id = p.archive_batch
                  where p.storage_path = p_name and b.state = 'released');
$$;
revoke all on function photo_file_released(text) from public, anon;
grant execute on function photo_file_released(text) to authenticated;

drop policy if exists "shop floor: read photos" on storage.objects;
create policy "shop floor: read photos" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.sees_lane(name like 'TEST-%'));

-- anyone signed in adds photo files, in their own lane, named the one way
drop policy if exists "shop floor: add photos" on storage.objects;
create policy "shop floor: add photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos'
              and public.my_role() is not null
              and name ~ '^[A-Za-z0-9-]+/[0-9a-f-]{36}\.jpg$'
              and (name like 'TEST-%') = public.am_test());

-- nobody replaces a photo file; only a manager removes one, and only once archived and released
drop policy if exists "shop floor: remove archived photos" on storage.objects;
create policy "shop floor: remove archived photos" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.is_manager() and public.photo_file_released(name));


-- ---------------------------------------------------------------------
-- 5. Load-outs
-- ---------------------------------------------------------------------

create or replace function start_loadout(p_job uuid, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job jobs; v_id uuid;
begin
  if p_client_id is not null then
    select id into v_id from loadouts where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already started.'); end if;
  end if;
  v_job := floor_entry_check('delivery', p_job);
  insert into loadouts (client_id, job_id, is_test, started_by, started_by_name)
  values (p_client_id, p_job, v_job.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Load-out started for %s.', v_job.project_id));
exception when unique_violation then
  select id into v_id from loadouts where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already started.');
end $$;
revoke all on function start_loadout(uuid, uuid) from public, anon;
grant execute on function start_loadout(uuid, uuid) to authenticated;

-- "the truck is leaving". p_loadout is its id, or the tablet's own id for it.
create or replace function finish_loadout(p_loadout uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; n_here int; n_total int; n_other int;
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  v_job := floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That load-out was marked entered by mistake.'; end if;
  if v.finished_at is null then
    update loadouts set finished_at = now(), finished_by_name = my_name(), note = coalesce(nullif(trim(p_note), ''), note)
     where id = v.id;
  end if;
  select count(distinct sheet_number) filter (where sheet_number is not null), count(*) filter (where sheet_number is null)
    into n_here, n_other from photos where loadout_id = v.id and voided_at is null;
  select count(*) into n_total from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = v.job_id;
  return jsonb_build_object('ok', true, 'summary',
    format('%s load-out finished: %s%s.', v_job.project_id,
           case when n_total > 0 then format('%s of %s sheets photographed on this truck', n_here, n_total)
                else format('%s sheet%s photographed', n_here, case when n_here = 1 then '' else 's' end) end,
           case when n_other > 0 then format(', plus %s other item%s', n_other, case when n_other = 1 then '' else 's' end) else '' end));
end $$;
revoke all on function finish_loadout(uuid, text) from public, anon;
grant execute on function finish_loadout(uuid, text) to authenticated;

create or replace function void_loadout(p_loadout uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v loadouts;
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  if not (v.started_by = auth.uid() or office_ok()) then
    raise exception 'Only the person who started it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  update loadouts set voided_at = coalesce(voided_at, now()), voided_by_name = coalesce(voided_by_name, my_name()),
                      void_reason = coalesce(void_reason, nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = v.id;
  return 'Marked as entered by mistake. It''s kept in history, with its photos.';
end $$;
revoke all on function void_loadout(uuid, text) from public, anon;
grant execute on function void_loadout(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 6. Adding a photo
--
-- The tablet uploads the file first, then calls this. p_parent is the
-- defect, problem or load-out it belongs to — its id, or the tablet's
-- own id for it (so a photo taken with no Wi-Fi can point at an entry
-- that hasn't reached the database yet). If that entry hasn't arrived
-- yet, the answer is "waiting", and the tablet tries again later.
-- ---------------------------------------------------------------------

create or replace function add_photo(p_client_id uuid, p_kind text, p_parent uuid,
                                     p_sheet int default null, p_note text default null,
                                     p_width int default null, p_height int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_job   jobs;
  v_dept  text;
  v_sheet int;
  v_def   defects;
  v_prob  problems;
  v_lo    loadouts;
  v_path  text;
  v_size  bigint;
  n       int;
  waiting constant jsonb := jsonb_build_object('ok', false, 'waiting', true,
                              'summary', 'The entry this photo belongs to hasn''t reached the database yet.');
begin
  if p_client_id is null then raise exception 'This photo has no id. Take it again.'; end if;
  select id into v_id from photos where client_id = p_client_id;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Photo already saved.'); end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;

  if p_kind = 'defect' then
    select * into v_def from defects where id = p_parent or client_id = p_parent;
    if v_def.id is null or not sees_lane(v_def.is_test) then return waiting; end if;
    if v_def.voided_at is not null then raise exception 'That defect was marked entered by mistake, so the photo wasn''t added.'; end if;
    v_job := floor_entry_check(v_def.department, v_def.job_id);
    v_dept := v_def.department; v_sheet := v_def.sheet_number;
    select count(*) into n from photos where defect_id = v_def.id and voided_at is null;
  elsif p_kind = 'problem' then
    select * into v_prob from problems where id = p_parent or client_id = p_parent;
    if v_prob.id is null or not sees_lane(v_prob.is_test) then return waiting; end if;
    v_job := floor_entry_check(v_prob.department, v_prob.job_id);
    v_dept := v_prob.department; v_sheet := v_prob.sheet_number;
    select count(*) into n from photos where problem_id = v_prob.id and voided_at is null;
  elsif p_kind = 'loadout' then
    select * into v_lo from loadouts where id = p_parent or client_id = p_parent;
    if v_lo.id is null or not sees_lane(v_lo.is_test) then return waiting; end if;
    v_job := floor_entry_check('delivery', v_lo.job_id);
    if v_lo.voided_at is not null then raise exception 'That load-out was marked entered by mistake, so the photo wasn''t added.'; end if;
    if v_lo.finished_at is not null and v_lo.finished_at < now() - interval '3 days' then
      raise exception 'That load-out finished on %. Start a new one for this photo.', to_char(v_lo.finished_at at time zone 'America/Indiana/Indianapolis', 'Mon FMDD');
    end if;
    perform check_job_sheet(v_lo.job_id, p_sheet);
    if p_sheet is null and nullif(trim(p_note), '') is null then
      raise exception 'This item has no sheet, so say what it is (for example "hardware box, 2 of 2").';
    end if;
    v_dept := 'delivery'; v_sheet := p_sheet; n := 0;
  else
    raise exception 'A photo belongs to a defect, a problem or a load-out.';
  end if;
  if n >= 6 then raise exception 'Six photos is the most on one entry.'; end if;

  v_path := v_job.project_id || '/' || p_client_id || '.jpg';
  select coalesce((o.metadata ->> 'size')::bigint, 0) into v_size
    from storage.objects o where o.bucket_id = 'photos' and o.name = v_path;
  if not found then
    raise exception 'The photo file hasn''t arrived, so it wasn''t saved. Take it again.';
  end if;

  insert into photos (client_id, job_id, sheet_number, department, kind, defect_id, problem_id, loadout_id, note,
                      storage_path, bytes, width, height, is_test, taken_by, taken_by_name)
  values (p_client_id, v_job.id, v_sheet, v_dept, p_kind, v_def.id, v_prob.id, v_lo.id, nullif(trim(p_note), ''),
          v_path, v_size, p_width, p_height, v_job.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('Photo saved on %s%s.', v_job.project_id, coalesce(' sheet ' || v_sheet, '')));
exception when unique_violation then
  select id into v_id from photos where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Photo already saved.');
end $$;
revoke all on function add_photo(uuid, text, uuid, int, text, int, int) from public, anon;
grant execute on function add_photo(uuid, text, uuid, int, text, int, int) to authenticated;

-- "Entered by mistake": hidden everywhere, kept (and still archived later, marked as such)
create or replace function void_photo(p_photo uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v photos;
begin
  select * into v from photos where id = p_photo;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That photo isn''t there.'; end if;
  if not (v.taken_by = auth.uid() or office_ok()) then
    raise exception 'Only the person who took it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  update photos set voided_at = coalesce(voided_at, now()), voided_by_name = coalesce(voided_by_name, my_name()),
                    void_reason = coalesce(void_reason, nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = p_photo;
  return 'Photo marked as entered by mistake. It''s kept in history but no longer shown.';
end $$;
revoke all on function void_photo(uuid, text) from public, anon;
grant execute on function void_photo(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 7. What the pages read
-- ---------------------------------------------------------------------

drop view if exists v_photos;
create view v_photos with (security_invoker = true) as
select p.id, p.client_id, p.job_id, j.project_id, j.name as job_name, p.sheet_number, p.department, d.name as department_name,
       p.kind, p.defect_id, p.problem_id, p.loadout_id, l.client_id as loadout_client_id,
       df.defect_type, pr.body as problem_body,
       p.note, p.storage_path, p.bytes, p.width, p.height, p.is_test,
       p.taken_by, p.taken_by_name, p.taken_at,
       (p.voided_at is not null) as voided, p.voided_by_name, p.void_reason,
       p.archive_batch, p.archive_name, p.file_removed_at, (p.file_removed_at is null) as in_cloud
from photos p
join jobs j         on j.id = p.job_id
join departments d  on d.key = p.department
left join defects df  on df.id = p.defect_id
left join problems pr on pr.id = p.problem_id
left join loadouts l  on l.id = p.loadout_id;
revoke all on v_photos from anon;
grant select on v_photos to authenticated;

drop view if exists v_loadouts;
create view v_loadouts with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, j.phase, j.delivery_date, l.is_test,
       l.started_by, l.started_by_name, l.started_at, l.finished_at, l.finished_by_name, l.note,
       (l.finished_at is null) as is_open,
       (select count(*)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as sheets_total,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null), '{}') as sheets_here,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null), '{}') as sheets_earlier,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is null) as other_items,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null) as photo_count
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null;
revoke all on v_loadouts from anon;
grant select on v_loadouts to authenticated;


-- ---------------------------------------------------------------------
-- 8. The archive (managers only)
--
--   Download archive → prepare_photo_archive() gathers every photo on a
--     job that has been off the floor 60+ days (and is itself 60+ days
--     old) into this month's batch, names each file, and lists them.
--   The office page builds the zip from that list and saves it.
--   → confirm_photo_archive(batch) marks it saved, and RELEASES the
--     batch saved before it, whose files the page then removes from
--     Supabase → mark_photo_files_removed(batch).
--   So every batch sits in both places for a month before it leaves.
-- ---------------------------------------------------------------------

create or replace function photo_archive_list(p_batch text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'path', p.storage_path, 'name', p.archive_name, 'in_cloud', p.file_removed_at is null,
           'project_id', j.project_id, 'job_name', j.name, 'sheet', p.sheet_number, 'department', d.name,
           'kind', case p.kind when 'defect' then 'Defect' when 'problem' then 'Problem' else 'Load-out' end,
           'what', coalesce(df.defect_type, pr.body, case when p.kind = 'loadout' then 'Load-out started ' ||
                    to_char(l.started_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') end),
           'note', p.note, 'by', p.taken_by_name,
           'at', to_char(p.taken_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD HH24:MI'),
           'mistake', p.voided_at is not null, 'test', p.is_test, 'bytes', p.bytes)
         order by p.archive_name), '[]'::jsonb)
    from photos p
    join jobs j on j.id = p.job_id
    join departments d on d.key = p.department
    left join defects df on df.id = p.defect_id
    left join problems pr on pr.id = p.problem_id
    left join loadouts l on l.id = p.loadout_id
   where p.archive_batch = p_batch;
$$;
revoke all on function photo_archive_list(text) from public, anon, authenticated;

create or replace function photo_archivable_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select p.id from photos p join jobs j on j.id = p.job_id
   where p.archive_batch is null and p.file_removed_at is null
     and not job_on_floor(j.is_active, j.is_test, j.phase)
     and j.floor_left_at <= now() - interval '60 days'
     and p.taken_at <= now() - interval '60 days';
$$;
revoke all on function photo_archivable_ids() from public, anon, authenticated;

create or replace function photo_archive_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_last photo_archive_batches; v_build photo_archive_batches; v_out jsonb;
begin
  if not office_ok() then
    raise exception 'Only a manager can see the photo archive.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_last from photo_archive_batches where state <> 'building' order by made_at desc limit 1;
  select * into v_build from photo_archive_batches where state = 'building' order by made_at desc limit 1;
  select jsonb_build_object(
    'bytes_photos',       (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects where bucket_id = 'photos'),
    'bytes_work_orders',  (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects where bucket_id = 'work-orders'),
    'bytes_all',          (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects),
    'free_plan_bytes',    1073741824,
    'photos_in_cloud',    (select count(*) from photos where file_removed_at is null),
    'photos_total',       (select count(*) from photos),
    'eligible',           (select count(*) from photo_archivable_ids()),
    'eligible_bytes',     (select coalesce(sum(bytes), 0) from photos where id in (select photo_archivable_ids())),
    'last_batch',         v_last.id,
    'last_made_at',       v_last.made_at,
    'days_since_last',    case when v_last.id is null then null else local_today() - (v_last.made_at at time zone 'America/Indiana/Indianapolis')::date end,
    'building',           v_build.id,
    'batches',            coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'state', b.state, 'made_at', b.made_at, 'made_by', b.made_by_name,
                                        'saved_at', b.saved_at, 'released_at', b.released_at, 'removed_at', b.removed_at,
                                        'photos', b.photos, 'bytes', b.bytes,
                                        'files_left', (select count(*) from photos p where p.archive_batch = b.id and p.file_removed_at is null))
                                        order by b.made_at desc) from photo_archive_batches b), '[]'::jsonb),
    'to_remove',          (select count(*) from photos p join photo_archive_batches b on b.id = p.archive_batch
                            where b.state = 'released' and p.file_removed_at is null)
  ) into v_out;
  -- the reminder: something to archive and a month since the last one (or never), or files waiting to be removed
  v_out := v_out || jsonb_build_object('due',
    ((v_out ->> 'eligible')::int > 0 and (v_last.id is null or (v_out ->> 'days_since_last')::int >= 30))
    or (v_out ->> 'to_remove')::int > 0 or v_build.id is not null);
  return v_out;
end $$;
revoke all on function photo_archive_status() from public, anon;
grant execute on function photo_archive_status() to authenticated;

create or replace function prepare_photo_archive() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text; v_base text; n int := 1;
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  select id into v_id from photo_archive_batches where state = 'building' order by made_at desc limit 1;
  if v_id is null then
    if not exists (select 1 from photo_archivable_ids()) then
      raise exception 'Nothing to archive yet. Photos move off Supabase once their job has been off the floor (past Delivery) for 60 days.';
    end if;
    v_base := to_char(local_today(), 'YYYY-MM');
    v_id := v_base;
    while exists (select 1 from photo_archive_batches where id = v_id) loop
      n := n + 1; v_id := v_base || '-' || n;
    end loop;
    insert into photo_archive_batches (id, made_by_name) values (v_id, my_name());
  end if;

  update photos set archive_batch = v_id where id in (select photo_archivable_ids());

  -- names inside the zip: <PROJ>/sheet-03_delivery_2026-10-14.jpg, with _2, _3 … for more the same day
  with named as (
    select p.id, j.project_id || '/' ||
             case when p.sheet_number is null then 'job' else 'sheet-' || lpad(p.sheet_number::text, 2, '0') end
             || '_' || replace(p.department, '_', '-') || '_' || to_char(p.taken_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') as stem,
           row_number() over (partition by p.job_id, p.sheet_number, p.department,
                                           (p.taken_at at time zone 'America/Indiana/Indianapolis')::date
                              order by p.taken_at, p.id) as rn
      from photos p join jobs j on j.id = p.job_id
     where p.archive_batch = v_id)
  update photos p set archive_name = named.stem || case when named.rn > 1 then '_' || named.rn else '' end || '.jpg'
    from named where named.id = p.id;

  update photo_archive_batches b
     set photos = (select count(*) from photos where archive_batch = v_id),
         bytes  = (select coalesce(sum(bytes), 0) from photos where archive_batch = v_id)
   where b.id = v_id;

  return jsonb_build_object('ok', true, 'batch', v_id, 'photos', photo_archive_list(v_id),
                            'summary', format('Batch %s: %s photos ready to download.', v_id,
                                              (select photos from photo_archive_batches where id = v_id)));
end $$;
revoke all on function prepare_photo_archive() from public, anon;
grant execute on function prepare_photo_archive() to authenticated;

-- the list again, to download a batch a second time while its files are still in Supabase
create or replace function photo_archive_files(p_batch text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from photo_archive_batches where id = p_batch) then
    raise exception 'There''s no batch %.', p_batch;
  end if;
  return jsonb_build_object('ok', true, 'batch', p_batch, 'photos', photo_archive_list(p_batch));
end $$;
revoke all on function photo_archive_files(text) from public, anon;
grant execute on function photo_archive_files(text) to authenticated;

-- the zip was saved: mark it, and release the batch saved before it
create or replace function confirm_photo_archive(p_batch text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v photo_archive_batches; v_rel text[];
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from photo_archive_batches where id = p_batch;
  if v.id is null then raise exception 'There''s no batch %.', p_batch; end if;
  if v.state = 'building' then
    update photo_archive_batches set state = 'saved', saved_at = now() where id = p_batch;
  end if;
  with rel as (
    update photo_archive_batches set state = 'released', released_at = now()
     where state = 'saved' and id <> p_batch and made_at < v.made_at
    returning id)
  select coalesce(array_agg(id order by id), '{}') into v_rel from rel;
  return jsonb_build_object('ok', true, 'batch', p_batch, 'released', to_jsonb(v_rel),
    'remove', coalesce((select jsonb_agg(jsonb_build_object('batch', p.archive_batch, 'path', p.storage_path))
                          from photos p join photo_archive_batches b on b.id = p.archive_batch
                         where b.state = 'released' and p.file_removed_at is null), '[]'::jsonb),
    'summary', format('Batch %s is saved. %s', p_batch,
                      case when cardinality(v_rel) = 0 then 'Its files stay in Supabase until next month''s batch is saved too.'
                           else format('Batch %s has now been kept in both places for a month, so its files can come off Supabase.',
                                       array_to_string(v_rel, ', ')) end));
end $$;
revoke all on function confirm_photo_archive(text) from public, anon;
grant execute on function confirm_photo_archive(text) to authenticated;

-- files still to remove (after an interrupted removal)
create or replace function photo_files_to_remove() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('batch', p.archive_batch, 'path', p.storage_path))
                     from photos p join photo_archive_batches b on b.id = p.archive_batch
                    where b.state = 'released' and p.file_removed_at is null), '[]'::jsonb);
end $$;
revoke all on function photo_files_to_remove() from public, anon;
grant execute on function photo_files_to_remove() to authenticated;

-- after the page has removed the files: record it. Only files really gone are marked.
create or replace function mark_photo_files_removed(p_batch text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  update photos p set file_removed_at = now()
   where p.archive_batch = p_batch and p.file_removed_at is null
     and exists (select 1 from photo_archive_batches b where b.id = p_batch and b.state = 'released')
     and not exists (select 1 from storage.objects o where o.bucket_id = 'photos' and o.name = p.storage_path);
  get diagnostics n = row_count;
  select count(*) into m from photos where archive_batch = p_batch and file_removed_at is null;
  if m = 0 then
    update photo_archive_batches set state = 'removed', removed_at = coalesce(removed_at, now())
     where id = p_batch and state = 'released';
  end if;
  return jsonb_build_object('ok', true, 'removed', n, 'left', m,
    'summary', case when m = 0 then format('Batch %s is off Supabase. Every photo''s record stays, saying which zip holds it.', p_batch)
                    else format('%s file%s of batch %s couldn''t be removed yet. Try again.', m, case when m = 1 then '' else 's' end, p_batch) end);
end $$;
revoke all on function mark_photo_files_removed(text) from public, anon;
grant execute on function mark_photo_files_removed(text) to authenticated;
