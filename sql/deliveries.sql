-- =====================================================================
-- Shop Floor — deliveries (24 Sep 2026)
--
-- HOW TO USE: run loadouts_v2.sql first (Walkthrough 10). Then paste
-- this whole file into a NEW, empty query in the Supabase SQL Editor and
-- click Run. Safe to run more than once. The last thing it does is run
-- check_deliveries(), so the Results show 16 rows that should all say
-- PASS.
--
-- What it adds:
--   * Julia's scheduling. A login marked "schedules deliveries" (and any
--     manager) picks a job, sets the date and time, and attaches the
--     delivery ticket and site files (site maps, photos of the spot).
--     That makes the delivery: it's the load-out, one record per trip.
--     Give the permission with set_delivery_scheduler() (SQL Editor only).
--   * A private bucket, "deliveries", for tickets, site files and
--     customer signatures. PDF, JPEG or PNG, 10 MB at most.
--   * At the dock, a white-glove delivery takes one photo per truck.
--   * At the site, a photo of each table where it ended up, taken with
--     the app's camera, with the phone's time and GPS location.
--   * The customer signs on the screen (or the driver says why not), with
--     an optional note from the customer. The signature is kept as an
--     image; the signed ticket is put together (the ticket, then a
--     signature page) when someone downloads it, so it's always the same.
--   * Julia's Completed list: Download, and "New" until it's downloaded.
--   * v_filing: every photo and delivery file, named the way they're
--     filed — PROJ-00418/TB-03/TB-03-2 Delivery Picture.jpg — for the
--     office's "Download this job's photos" and the monthly archive.
--   * Delivery files join the monthly photo archive, on the same rule
--     (60+ days past Delivery), and leave Supabase the same way.
--
-- What it doesn't change: every existing function stays as it is.
-- v_loadouts and v_photos are rebuilt with their old columns first, in
-- the same order, and the new ones at the end. Shipments are unchanged.
-- Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('deliveries.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.add_loadout_photo(uuid,uuid,integer,integer,integer,text,integer,integer)') is null then
    raise exception 'Run loadouts_v2.sql first (Walkthrough 10). This file builds on it.';
  end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run check_floor.sql first. This file''s check uses it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Who schedules deliveries
-- ---------------------------------------------------------------------

alter table profiles add column if not exists schedules_deliveries boolean not null default false;

create or replace function can_schedule_deliveries() returns boolean
language sql stable security definer set search_path = public as $$
  select is_manager()
      or coalesce((select p.schedules_deliveries and p.active from profiles p where p.id = auth.uid()), false);
$$;
revoke all on function can_schedule_deliveries() from public, anon;
grant execute on function can_schedule_deliveries() to authenticated;

-- delivery records are for Delivery, the scheduler and managers
create or replace function sees_deliveries() returns boolean
language sql stable security definer set search_path = public as $$
  select owns_dept('delivery') or can_schedule_deliveries();
$$;
revoke all on function sees_deliveries() from public, anon;
grant execute on function sees_deliveries() to authenticated;

-- In the SQL Editor:  select set_delivery_scheduler('someone@pdindy.com', true);
create or replace function set_delivery_scheduler(p_email text, p_on boolean default true) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text;
begin
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'No login with the email %. Create it first: Authentication → Users → Add user (tick Auto Confirm).', p_email;
  end if;
  select full_name into v_name from profiles where id = v_id;
  if v_name is null then
    raise exception 'That login has no profile yet. Run set_person() for it first (Walkthrough 11, step 3).';
  end if;
  update profiles set schedules_deliveries = coalesce(p_on, false), updated_at = now() where id = v_id;
  return format('%s %s schedule deliveries (delivery.html).', v_name, case when p_on then 'can now' else 'can no longer' end);
end $$;
revoke all on function set_delivery_scheduler(text, boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. A delivery is a load-out with a date, a ticket and a signature
-- ---------------------------------------------------------------------

alter table loadouts add column if not exists scheduled_for        timestamptz;
alter table loadouts add column if not exists scheduled_by         uuid references profiles(id);
alter table loadouts add column if not exists scheduled_by_name    text;
alter table loadouts add column if not exists scheduled_at         timestamptz;
alter table loadouts add column if not exists schedule_note        text;
alter table loadouts add column if not exists completed_at         timestamptz;   -- delivered: signed, or not signed with a reason
alter table loadouts add column if not exists completed_by         uuid references profiles(id);
alter table loadouts add column if not exists completed_by_name    text;
alter table loadouts add column if not exists completion_client_id uuid;
alter table loadouts add column if not exists signed_name          text;
alter table loadouts add column if not exists signed_at            timestamptz;
alter table loadouts add column if not exists customer_note        text;
alter table loadouts add column if not exists no_sign_reason       text;
alter table loadouts add column if not exists no_sign_note         text;
alter table loadouts add column if not exists complete_lat         double precision;
alter table loadouts add column if not exists complete_lng         double precision;
alter table loadouts add column if not exists complete_accuracy    double precision;
alter table loadouts add column if not exists downloaded_at        timestamptz;
alter table loadouts add column if not exists downloaded_by_name   text;
-- Load-outs from before this file keep the old way (photos at the dock only).
-- Every one started from now on has the dock, site and signature steps.
alter table loadouts add column if not exists site_steps boolean not null default false;
alter table loadouts alter column site_steps set default true;

create unique index if not exists loadouts_completion_client_idx on loadouts (completion_client_id) where completion_client_id is not null;
create index if not exists loadouts_scheduled_idx on loadouts (scheduled_for) where scheduled_for is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'loadouts_no_sign_reason_check') then
    alter table loadouts add constraint loadouts_no_sign_reason_check
      check (no_sign_reason is null or no_sign_reason in ('Nobody on site', 'Customer refused', 'Other'));
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 3. Delivery files: the ticket, site files, the customer's signature
-- ---------------------------------------------------------------------

create table if not exists delivery_docs (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid        not null unique,          -- made by the page; also the file's name
  loadout_id       uuid        not null references loadouts(id) on delete cascade,
  job_id           uuid        not null references jobs(id) on delete cascade,
  kind             text        not null check (kind in ('ticket', 'site_file', 'signature')),
  file_name        text        not null,                 -- as it was called on Julia's computer
  storage_path     text        not null unique,
  mime             text,
  bytes            bigint,
  is_test          boolean     not null default false,
  added_by         uuid        references profiles(id),
  added_by_name    text,
  added_at         timestamptz not null default now(),
  retired_at       timestamptz,                          -- replaced or taken off; kept
  retired_by_name  text,
  retire_reason    text,
  archive_batch    text        references photo_archive_batches(id),
  archive_name     text,
  file_removed_at  timestamptz
);
create index if not exists delivery_docs_loadout_idx on delivery_docs (loadout_id, kind);
create index if not exists delivery_docs_batch_idx on delivery_docs (archive_batch);

alter table delivery_docs enable row level security;
drop policy if exists read_delivery_docs on delivery_docs;
create policy read_delivery_docs on delivery_docs for select to authenticated using (sees_lane(is_test) and sees_deliveries());
revoke insert, update, delete, truncate on delivery_docs from anon, authenticated;
revoke select on delivery_docs from anon;
grant select on delivery_docs to authenticated;

-- the bucket: files are named <PROJ>/<the delivery's id>/<the file's id>.pdf|jpg|png
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('deliveries', 'deliveries', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- may this file be removed from Supabase? Only once its archive batch is released (its photos may already be off: "removed").
create or replace function delivery_doc_released(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from delivery_docs d join photo_archive_batches b on b.id = d.archive_batch
                  where d.storage_path = p_name and b.state in ('released', 'removed'));
$$;
revoke all on function delivery_doc_released(text) from public, anon;
grant execute on function delivery_doc_released(text) to authenticated;

drop policy if exists "shop floor: read delivery files" on storage.objects;
create policy "shop floor: read delivery files" on storage.objects for select to authenticated
  using (bucket_id = 'deliveries' and public.sees_lane(name like 'TEST-%') and public.sees_deliveries());

drop policy if exists "shop floor: add delivery files" on storage.objects;
create policy "shop floor: add delivery files" on storage.objects for insert to authenticated
  with check (bucket_id = 'deliveries'
              and public.sees_deliveries()
              and name ~ '^[A-Za-z0-9-]+/[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|jpg|png)$'
              and ((name like 'TEST-%') = public.am_test() or public.is_manager()));

drop policy if exists "shop floor: remove archived delivery files" on storage.objects;
create policy "shop floor: remove archived delivery files" on storage.objects for delete to authenticated
  using (bucket_id = 'deliveries' and public.is_manager() and public.delivery_doc_released(name));


-- ---------------------------------------------------------------------
-- 4. Photos: the truck at the dock, the tables at the site
-- ---------------------------------------------------------------------

alter table photos add column if not exists stage        text;              -- 'dock' (the truck) or 'site' (where it ended up)
alter table photos add column if not exists truck        int;               -- which truck, at the dock
alter table photos add column if not exists shot_at      timestamptz;       -- when the phone took it
alter table photos add column if not exists lat          double precision;  -- where the phone was (GPS works with no signal)
alter table photos add column if not exists lng          double precision;
alter table photos add column if not exists gps_accuracy double precision;  -- metres

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'photos_stage_check') then
    alter table photos add constraint photos_stage_check check (stage is null or (stage in ('dock', 'site') and kind = 'loadout'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'photos_truck_check') then
    alter table photos add constraint photos_truck_check
      check (truck is null or (truck between 1 and 20 and sheet_number is null and piece is null and pallet is null and kind = 'loadout'));
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 5. Scheduling (Julia and managers)
-- ---------------------------------------------------------------------

-- the delivery, by its id or the page's own id for it, if this login may see it
create or replace function delivery_lookup(p_loadout uuid) returns loadouts
language sql stable security definer set search_path = public as $$
  select l.* from loadouts l where (l.id = p_loadout or l.client_id = p_loadout) and sees_lane(l.is_test) limit 1;
$$;
revoke all on function delivery_lookup(uuid) from public, anon, authenticated;

-- the scheduler's checks on an existing delivery
create or replace function delivery_scheduler_check(p_loadout uuid) returns loadouts
language plpgsql stable security definer set search_path = public as $$
declare v loadouts;
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can change deliveries.' using errcode = 'insufficient_privilege';
  end if;
  v := delivery_lookup(p_loadout);
  if v.id is null or v.voided_at is not null then raise exception 'That delivery isn''t there any more. Reload the page.'; end if;
  if not is_manager() and v.is_test <> am_test() then
    raise exception 'That delivery is in the other lane.' using errcode = 'insufficient_privilege';
  end if;
  if v.kind <> 'delivery' then raise exception 'That load-out is a shipment, not a delivery.'; end if;
  return v;
end $$;
revoke all on function delivery_scheduler_check(uuid) from public, anon, authenticated;

create or replace function local_when(p timestamptz) returns text
language sql stable as $$ select to_char(p at time zone 'America/Indiana/Indianapolis', 'Dy Mon FMDD, FMHH12:MI am') $$;
grant execute on function local_when(timestamptz) to authenticated;

-- a new delivery (p_loadout null), or a new date and time for one
create or replace function schedule_delivery(p_job uuid, p_when timestamptz, p_note text default null,
                                             p_loadout uuid default null, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_id uuid; v_cid uuid := coalesce(p_client_id, gen_random_uuid());
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can schedule deliveries.' using errcode = 'insufficient_privilege';
  end if;
  if p_when is null then raise exception 'Pick the date and time of the delivery.'; end if;
  if p_when < now() - interval '14 days' or p_when > now() + interval '400 days' then
    raise exception 'That date doesn''t look right. Pick the day the delivery happens.';
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'Keep the note to 500 letters.'; end if;

  if p_loadout is not null then
    v := delivery_scheduler_check(p_loadout);
    if v.completed_at is not null then raise exception 'That delivery is already done, so it can''t be moved.'; end if;
    update loadouts set scheduled_for = p_when, schedule_note = nullif(trim(p_note), ''),
                        scheduled_by = coalesce(scheduled_by, auth.uid()), scheduled_by_name = coalesce(scheduled_by_name, my_name()),
                        scheduled_at = coalesce(scheduled_at, now())
     where id = v.id;
    return jsonb_build_object('ok', true, 'id', v.id, 'client_id', v.client_id,
      'summary', format('%s: delivery set for %s.', (select project_id from jobs where id = v.job_id), local_when(p_when)));
  end if;

  select id into v_id from loadouts where client_id = v_cid;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid, 'already', true, 'summary', 'Already scheduled.'); end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null then raise exception 'Pick a job first.'; end if;
  if v_job.is_test and not (is_manager() or am_test()) then
    raise exception '% is a test job. Only a manager or the Test Supervisor schedules test jobs.', v_job.project_id using errcode = 'insufficient_privilege';
  end if;
  if not v_job.is_test and am_test() then
    raise exception 'A test login can only schedule test jobs.' using errcode = 'insufficient_privilege';
  end if;
  if not (v_job.is_active or coalesce(v_job.phase, '') in ('Delivery', 'Project Closeout')) then
    raise exception '% isn''t in production or delivery, so it can''t be scheduled.', v_job.project_id;
  end if;
  insert into loadouts (client_id, job_id, is_test, started_by, started_by_name, kind, site_steps,
                        scheduled_for, scheduled_by, scheduled_by_name, scheduled_at, schedule_note)
  values (v_cid, v_job.id, v_job.is_test, auth.uid(), my_name(), 'delivery', true,
          p_when, auth.uid(), my_name(), now(), nullif(trim(p_note), ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid,
    'summary', format('%s: delivery scheduled for %s.', v_job.project_id, local_when(p_when)));
exception when unique_violation then
  select id into v_id from loadouts where client_id = v_cid;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid, 'already', true, 'summary', 'Already scheduled.');
end $$;
revoke all on function schedule_delivery(uuid, timestamptz, text, uuid, uuid) from public, anon;
grant execute on function schedule_delivery(uuid, timestamptz, text, uuid, uuid) to authenticated;

-- the page uploads the file first, then records it here. A new ticket replaces the old one (kept).
create or replace function add_delivery_doc(p_client_id uuid, p_loadout uuid, p_kind text, p_file_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text; v_obj record; v_id uuid; v_name text; n int;
begin
  if p_client_id is null then raise exception 'This file has no id. Add it again.'; end if;
  select id into v_id from delivery_docs where client_id = p_client_id;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already added.'); end if;
  v := delivery_scheduler_check(p_loadout);
  if p_kind not in ('ticket', 'site_file') then raise exception 'A file is the delivery ticket or a site file.'; end if;
  if v.completed_at is not null then
    raise exception 'That delivery is already done, so its % can''t change.', case when p_kind = 'ticket' then 'ticket' else 'files' end;
  end if;
  select project_id into v_pid from jobs where id = v.job_id;
  select o.name, o.metadata into v_obj from storage.objects o
   where o.bucket_id = 'deliveries' and o.name like v_pid || '/' || coalesce(v.client_id, v.id) || '/' || p_client_id || '.%' limit 1;
  if v_obj.name is null then raise exception 'The file hasn''t arrived, so it wasn''t saved. Add it again.'; end if;
  if p_kind = 'site_file' then
    select count(*) into n from delivery_docs where loadout_id = v.id and kind = 'site_file' and retired_at is null;
    if n >= 20 then raise exception 'Twenty site files is the most on one delivery.'; end if;
  end if;
  v_name := left(coalesce(nullif(regexp_replace(trim(coalesce(p_file_name, '')), '\s+', ' ', 'g'), ''),
                          case when p_kind = 'ticket' then 'Delivery ticket' else 'Site file' end), 120);
  if p_kind = 'ticket' then
    update delivery_docs set retired_at = now(), retired_by_name = my_name(), retire_reason = 'Replaced by a newer ticket'
     where loadout_id = v.id and kind = 'ticket' and retired_at is null;
  end if;
  insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, is_test, added_by, added_by_name)
  values (p_client_id, v.id, v.job_id, p_kind, v_name, v_obj.name, v_obj.metadata ->> 'mimetype',
          nullif(v_obj.metadata ->> 'size', '')::bigint, v.is_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id,
    'summary', format('%s: %s added.', v_pid, case when p_kind = 'ticket' then 'delivery ticket' else '"' || v_name || '"' end));
exception when unique_violation then
  select id into v_id from delivery_docs where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already added.');
end $$;
revoke all on function add_delivery_doc(uuid, uuid, text, text) from public, anon;
grant execute on function add_delivery_doc(uuid, uuid, text, text) to authenticated;

-- take a site file (or the ticket) off a delivery. Kept, like everything else.
create or replace function retire_delivery_doc(p_doc uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d delivery_docs; v loadouts;
begin
  select * into d from delivery_docs where id = p_doc;
  if d.id is null then raise exception 'That file isn''t there. Reload the page.'; end if;
  v := delivery_scheduler_check(d.loadout_id);
  if d.kind = 'signature' then raise exception 'The customer''s signature can''t be taken off.'; end if;
  if v.completed_at is not null then raise exception 'That delivery is already done, so its files can''t change.'; end if;
  if d.retired_at is null then
    update delivery_docs set retired_at = now(), retired_by_name = my_name(), retire_reason = 'Taken off' where id = p_doc;
  end if;
  return jsonb_build_object('ok', true, 'summary', format('"%s" taken off the delivery. It''s kept in history.', d.file_name));
end $$;
revoke all on function retire_delivery_doc(uuid) from public, anon;
grant execute on function retire_delivery_doc(uuid) to authenticated;

-- Julia has downloaded the signed ticket (the first time is kept)
create or replace function mark_ticket_downloaded(p_loadout uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts;
begin
  v := delivery_scheduler_check(p_loadout);
  if v.completed_at is null then raise exception 'That delivery hasn''t been done yet.'; end if;
  update loadouts set downloaded_at = coalesce(downloaded_at, now()), downloaded_by_name = coalesce(downloaded_by_name, my_name())
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary', 'Marked downloaded.');
end $$;
revoke all on function mark_ticket_downloaded(uuid) from public, anon;
grant execute on function mark_ticket_downloaded(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 6. On the road (Delivery)
-- ---------------------------------------------------------------------

-- A truck photo at the dock, or a table in its final spot. Same rules as
-- every photo (the file first; a resend counts once; a delivery that
-- hasn't arrived yet answers "waiting"), plus the phone's time and place.
create or replace function add_delivery_photo(p_client_id uuid, p_loadout uuid, p_stage text,
                                              p_sheet int default null, p_piece int default null, p_truck int default null,
                                              p_lat double precision default null, p_lng double precision default null,
                                              p_accuracy double precision default null, p_shot_at timestamptz default null,
                                              p_width int default null, p_height int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_qty int; v_res jsonb; v_pid text; v_ok_gps boolean;
begin
  if p_client_id is null then raise exception 'This photo has no id. Take it again.'; end if;
  if exists (select 1 from photos where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Photo already saved.',
                              'id', (select id from photos where client_id = p_client_id));
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  v := delivery_lookup(p_loadout);
  if v.id is null then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The delivery this photo belongs to hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That delivery was marked entered by mistake, so the photo wasn''t added.'; end if;
  if v.kind <> 'delivery' then raise exception 'Truck and site photos are for deliveries. This load-out is a shipment.'; end if;
  if v.completed_at is not null and v.completed_at < now() - interval '1 day' then
    raise exception 'That delivery was finished on %. The photo wasn''t added.', local_when(v.completed_at);
  end if;
  if p_stage = 'dock' then
    if p_truck is null or p_truck < 1 or p_truck > 20 then raise exception 'Trucks are numbered 1 to 20.'; end if;
    if p_sheet is not null or p_piece is not null then raise exception 'A truck photo isn''t of one sheet.'; end if;
  elsif p_stage = 'site' then
    if p_truck is not null then raise exception 'A site photo is of a table, not a truck.'; end if;
    if p_sheet is null or p_piece is null then raise exception 'Say which sheet and table this is.'; end if;
    select s.qty into v_qty from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
     where w.job_id = v.job_id and s.sheet_number = p_sheet;
    if v_qty is null then raise exception 'Sheet % isn''t on this job''s work order.', p_sheet; end if;
    if p_piece < 1 or p_piece > v_qty then
      raise exception 'Sheet % has % table%, so there''s no table %.', p_sheet, v_qty, case when v_qty = 1 then '' else 's' end, p_piece;
    end if;
  else
    raise exception 'A delivery photo is of the truck (dock) or a table at the site.';
  end if;

  v_res := add_photo(p_client_id, 'loadout', v.id, p_sheet, case when p_stage = 'dock' then 'Truck ' || p_truck end, p_width, p_height);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
  v_ok_gps := p_lat between -90 and 90 and p_lng between -180 and 180;
  update photos set stage = p_stage, truck = p_truck, piece = p_piece, shot_at = coalesce(p_shot_at, now()),
                    lat = case when v_ok_gps then p_lat end, lng = case when v_ok_gps then p_lng end,
                    gps_accuracy = case when v_ok_gps and p_accuracy >= 0 then p_accuracy end
   where client_id = p_client_id;
  select project_id into v_pid from jobs where id = v.job_id;
  return v_res || jsonb_build_object('summary',
    case when p_stage = 'dock' then format('Photo of truck %s saved on %s.', p_truck, v_pid)
         else format('Photo saved on %s sheet %s, table %s, at the site.', v_pid, p_sheet, p_piece) end);
end $$;
revoke all on function add_delivery_photo(uuid, uuid, text, int, int, int, double precision, double precision, double precision, timestamptz, int, int) from public, anon;
grant execute on function add_delivery_photo(uuid, uuid, text, int, int, int, double precision, double precision, double precision, timestamptz, int, int) to authenticated;

-- Delivered. Signed: the signature image goes up first (as <PROJ>/<delivery>/<p_client_id>.png).
-- Not signed: a reason, and a note for "Other". Also finishes the load-out if "the truck is leaving" was never pressed.
create or replace function complete_delivery(p_client_id uuid, p_loadout uuid, p_signed_name text default null,
                                             p_customer_note text default null, p_no_sign_reason text default null,
                                             p_no_sign_note text default null, p_signed_at timestamptz default null,
                                             p_lat double precision default null, p_lng double precision default null,
                                             p_accuracy double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text; v_path text; v_obj record; v_signed boolean := p_no_sign_reason is null;
        v_name text := nullif(regexp_replace(trim(coalesce(p_signed_name, '')), '\s+', ' ', 'g'), '');
        v_ok_gps boolean := p_lat between -90 and 90 and p_lng between -180 and 180;
begin
  if p_client_id is null then raise exception 'This has no id. Try again.'; end if;
  if exists (select 1 from loadouts where completion_client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked delivered.');
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  v := delivery_lookup(p_loadout);
  if v.id is null then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The delivery hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That delivery was marked entered by mistake.'; end if;
  if v.kind <> 'delivery' then raise exception 'Only a delivery is signed for. This load-out is a shipment.'; end if;
  if v.completed_at is not null then
    raise exception 'That delivery was already marked delivered by % (%).', coalesce(v.completed_by_name, 'someone'), local_when(v.completed_at);
  end if;
  if length(coalesce(p_customer_note, '')) > 1000 or length(coalesce(p_no_sign_note, '')) > 1000 then
    raise exception 'Keep each note to 1,000 letters.';
  end if;
  select project_id into v_pid from jobs where id = v.job_id;
  if v_signed then
    if v_name is null then raise exception 'Type the name of the person who signed.'; end if;
    if length(v_name) > 80 then raise exception 'Keep the name to 80 letters.'; end if;
    v_path := v_pid || '/' || coalesce(v.client_id, v.id) || '/' || p_client_id || '.png';
    select o.name, o.metadata into v_obj from storage.objects o where o.bucket_id = 'deliveries' and o.name = v_path;
    if v_obj.name is null then raise exception 'The signature hasn''t arrived, so the delivery wasn''t marked done. Try again.'; end if;
    insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, is_test, added_by, added_by_name)
    values (p_client_id, v.id, v.job_id, 'signature', 'Signature.png', v_path, v_obj.metadata ->> 'mimetype',
            nullif(v_obj.metadata ->> 'size', '')::bigint, v.is_test, auth.uid(), my_name());
  else
    if p_no_sign_reason not in ('Nobody on site', 'Customer refused', 'Other') then
      raise exception 'Pick why there''s no signature: Nobody on site, Customer refused, or Other.';
    end if;
    if p_no_sign_reason = 'Other' and nullif(trim(p_no_sign_note), '') is null then
      raise exception 'Say why there''s no signature.';
    end if;
  end if;
  update loadouts set completed_at = now(), completed_by = auth.uid(), completed_by_name = my_name(), completion_client_id = p_client_id,
                      signed_name = case when v_signed then v_name end,
                      signed_at = case when v_signed then least(now(), greatest(coalesce(p_signed_at, now()), now() - interval '7 days')) end,
                      customer_note = nullif(trim(p_customer_note), ''),
                      no_sign_reason = case when not v_signed then p_no_sign_reason end,
                      no_sign_note = case when not v_signed then nullif(trim(p_no_sign_note), '') end,
                      complete_lat = case when v_ok_gps then p_lat end, complete_lng = case when v_ok_gps then p_lng end,
                      complete_accuracy = case when v_ok_gps and p_accuracy >= 0 then p_accuracy end,
                      finished_at = coalesce(finished_at, now()), finished_by_name = coalesce(finished_by_name, my_name())
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    case when v_signed then format('%s delivered — signed by %s.', v_pid, v_name)
         else format('%s delivered — not signed (%s).', v_pid, lower(p_no_sign_reason)) end);
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked delivered.');
end $$;
revoke all on function complete_delivery(uuid, uuid, text, text, text, text, timestamptz, double precision, double precision, double precision) from public, anon;
grant execute on function complete_delivery(uuid, uuid, text, text, text, text, timestamptz, double precision, double precision, double precision) to authenticated;


-- ---------------------------------------------------------------------
-- 7. What the pages read
-- ---------------------------------------------------------------------

drop view if exists v_filing;
drop view if exists v_deliveries;

-- v_loadouts: every column it had, in the same place; the delivery columns at the end.
-- Truck photos aren't "other items"; site photos aren't dock photos.
drop view if exists v_loadouts;
create view v_loadouts with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, j.phase, j.delivery_date, l.is_test,
       l.started_by, l.started_by_name, l.started_at, l.finished_at, l.finished_by_name, l.note,
       (l.finished_at is null) as is_open,
       (select count(*)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as sheets_total,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as sheets_here,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as sheets_earlier,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is null
           and p.pallet is null and p.truck is null) as other_items,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null) as photo_count,
       -- version 2
       l.kind, l.carrier, l.tracking,
       (select coalesce(sum(s.qty), 0)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as pieces_total,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as pieces_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as pieces_earlier,
       coalesce((select array_agg(distinct p.pallet order by p.pallet) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.pallet is not null), '{}') as pallets_here,
       -- deliveries
       l.site_steps, l.scheduled_for, l.schedule_note, l.scheduled_by_name,
       l.completed_at, l.completed_by_name, l.signed_name, l.signed_at, l.no_sign_reason,
       coalesce((select array_agg(distinct p.truck order by p.truck) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.truck is not null), '{}') as trucks_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || p.piece) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.stage = 'site'), '{}') as site_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || p.piece) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null
                    and l2.completed_at is not null and (l.completed_at is null or l2.completed_at < l.completed_at)
                    and p.voided_at is null and p.stage = 'site'), '{}') as site_earlier
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null;
revoke all on v_loadouts from anon;
grant select on v_loadouts to authenticated;

-- v_photos: the same, plus the stage, truck, the phone's time and place
drop view if exists v_photos;
create view v_photos with (security_invoker = true) as
select p.id, p.client_id, p.job_id, j.project_id, j.name as job_name, p.sheet_number, p.department, d.name as department_name,
       p.kind, p.defect_id, p.problem_id, p.loadout_id, l.client_id as loadout_client_id,
       df.defect_type, pr.body as problem_body,
       p.note, p.storage_path, p.bytes, p.width, p.height, p.is_test,
       p.taken_by, p.taken_by_name, p.taken_at,
       (p.voided_at is not null) as voided, p.voided_by_name, p.void_reason,
       p.archive_batch, p.archive_name, p.file_removed_at, (p.file_removed_at is null) as in_cloud,
       p.piece, p.pallet, l.kind as loadout_kind,
       p.stage, p.truck, p.shot_at, p.lat, p.lng, p.gps_accuracy
from photos p
join jobs j         on j.id = p.job_id
join departments d  on d.key = p.department
left join defects df  on df.id = p.defect_id
left join problems pr on pr.id = p.problem_id
left join loadouts l  on l.id = p.loadout_id;
revoke all on v_photos from anon;
grant select on v_photos to authenticated;

-- Julia's list, and the driver's: every scheduled or done delivery, with its ticket and files
create view v_deliveries with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, j.phase, j.delivery_date, l.is_test,
       l.scheduled_for, l.schedule_note, l.scheduled_by_name, l.scheduled_at, l.started_at, l.started_by_name,
       l.finished_at, l.finished_by_name, l.completed_at, l.completed_by_name,
       l.signed_name, l.signed_at, l.customer_note, l.no_sign_reason, l.no_sign_note,
       l.complete_lat, l.complete_lng, l.complete_accuracy, l.downloaded_at, l.downloaded_by_name,
       (l.completed_at is not null) as is_done,
       (select jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes,
                                  'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at is null)
          from delivery_docs d where d.loadout_id = l.id and d.kind = 'ticket' and d.retired_at is null
         order by d.added_at desc limit 1) as ticket,
       coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes,
                                                     'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at is null)
                                  order by d.added_at, d.id)
                   from delivery_docs d where d.loadout_id = l.id and d.kind = 'site_file' and d.retired_at is null), '[]'::jsonb) as files,
       (select d.storage_path from delivery_docs d where d.loadout_id = l.id and d.kind = 'signature' order by d.added_at desc limit 1) as signature_path,
       (select coalesce(sum(s.qty), 0)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as pieces_total,
       (select count(distinct p.sheet_number || ':' || p.piece)::int from photos p
         where p.loadout_id = l.id and p.voided_at is null and p.stage = 'site') as site_photographed,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.truck is not null) as truck_photos
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null and l.kind = 'delivery' and (l.scheduled_for is not null or l.completed_at is not null);
revoke all on v_deliveries from anon;
grant select on v_deliveries to authenticated;

-- Every photo and delivery file, named the way it's filed:
--   PROJ-00418/TB-03/TB-03-2 Delivery Picture.jpg    (the number is the table)
--   PROJ-00418/TB-03/TB-03 Defect 1.jpg               (no table: counted)
--   PROJ-00418/Truck/Truck-1.jpg · Pallets/Pallet-1.jpg · Job/Job Problem 1.jpg · Other/hardware box.jpg
--   PROJ-00418/Delivery 2026-10-14/Delivery ticket.pdf · Signature.png · Signed ticket.pdf
-- An item code on several sheets numbers its tables straight through, in sheet order
-- (sheet 1 has TB-03-1, sheet 2 TB-03-2 and TB-03-3). No item code: "Sheet-03".
-- "Signed ticket.pdf" is put together by the page from the ticket and the signature.
create view v_filing with (security_invoker = true) as
with sh as (
  select w.job_id, s.sheet_number, s.qty,
         coalesce(nullif(trim(both '-' from regexp_replace(trim(coalesce(s.item_code, '')), '[\\/:*?"<>|]+', '-', 'g')), ''),
                  'Sheet-' || lpad(s.sheet_number::text, 2, '0')) as item
    from work_orders w join sheets s on s.work_order_id = w.id
   where w.is_current
), sh2 as (
  select sh.*, coalesce(sum(qty) over (partition by job_id, item order by sheet_number
                                       rows between unbounded preceding and 1 preceding), 0)::int as unit_offset
    from sh
), ph as (
  select p.id, p.job_id, j.project_id, j.name as job_name, p.is_test, p.storage_path, p.sheet_number, p.kind, p.stage, p.truck,
         p.pallet, p.note, p.taken_at as at, p.taken_by_name as by_name, p.voided_at is not null as mistake,
         p.department, p.loadout_id, p.lat, p.lng, p.gps_accuracy, p.shot_at, p.archive_batch, p.file_removed_at, p.bytes,
         case when p.sheet_number is not null then coalesce(s.item, 'Sheet-' || lpad(p.sheet_number::text, 2, '0'))
              when p.truck is not null then 'Truck' when p.pallet is not null then 'Pallets'
              when p.kind = 'loadout' then 'Other' else 'Job' end as folder,
         case when p.kind = 'loadout' and p.sheet_number is not null then coalesce(s.unit_offset, 0) + coalesce(p.piece, 1) end as table_no,
         case p.kind when 'defect' then 'Defect' when 'problem' then 'Problem'
              else case when p.truck is not null then 'Truck' when p.pallet is not null then 'Pallet'
                        when p.stage = 'site' then 'Delivery Picture'
                        when l.kind = 'shipping' then 'Before Wrap' else 'Load-out Picture' end end as what
    from photos p
    join jobs j on j.id = p.job_id
    left join sh2 s on s.job_id = p.job_id and s.sheet_number = p.sheet_number
    left join loadouts l on l.id = p.loadout_id
), ph2 as (
  select ph.*,
         case when truck is not null then 'Truck-' || truck
              when pallet is not null then 'Pallet-' || pallet
              when table_no is not null then folder || '-' || table_no || ' ' || what
              when kind = 'loadout' then left(coalesce(nullif(trim(regexp_replace(coalesce(note, ''), '[\\/:*?"<>|]+', '-', 'g')), ''), 'Item'), 60)
         end as fixed,
         row_number() over (partition by job_id, folder, what, (kind <> 'loadout') order by at, id) as counted
    from ph
), ph3 as (
  select ph2.*, coalesce(fixed, folder || ' ' || what || ' ' || counted) as base
    from ph2
), ph4 as (
  select ph3.*, row_number() over (partition by job_id, folder, base order by at, id) as dup
    from ph3
), trips as (
  select l.id as loadout_id, l.job_id,
         'Delivery ' || to_char(coalesce(l.scheduled_for, l.started_at) at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') as day,
         row_number() over (partition by l.job_id, (coalesce(l.scheduled_for, l.started_at) at time zone 'America/Indiana/Indianapolis')::date
                            order by coalesce(l.scheduled_for, l.started_at), l.id) as n
    from loadouts l
), docs as (
  select d.id, d.job_id, j.project_id, j.name as job_name, d.is_test, d.storage_path, d.kind, d.added_at as at, d.added_by_name as by_name,
         d.loadout_id, d.archive_batch, d.file_removed_at, d.bytes, d.file_name,
         t.day || case when t.n > 1 then ' (' || t.n || ')' else '' end as folder,
         lower(coalesce(substring(d.storage_path from '\.([a-z]+)$'), 'pdf')) as ext,
         case d.kind when 'ticket' then 'Delivery ticket' || case when d.retired_at is not null then ' (replaced)' else '' end
                     when 'signature' then 'Signature'
                     else left(coalesce(nullif(trim(regexp_replace(regexp_replace(d.file_name, '\.[A-Za-z0-9]{1,5}$', ''), '[\\/:*?"<>|]+', '-', 'g')), ''), 'Site file'), 80)
                          || case when d.retired_at is not null then ' (taken off)' else '' end end as base
    from delivery_docs d
    join jobs j on j.id = d.job_id
    join trips t on t.loadout_id = d.loadout_id
), docs2 as (
  select docs.*, row_number() over (partition by job_id, folder, base, ext order by at, id) as dup from docs
)
select 'photo'::text as source, p.id, p.job_id, p.project_id, p.job_name, p.is_test, 'photos'::text as bucket, p.storage_path,
       p.folder, p.base || case when p.dup > 1 then ' (' || p.dup || ')' else '' end
                        || case when p.mistake then ' (entered by mistake)' else '' end || '.jpg' as file_name,
       p.sheet_number, p.table_no, p.kind, p.what, p.note, p.at, p.by_name, p.mistake, p.department,
       p.lat, p.lng, p.gps_accuracy, p.shot_at, p.loadout_id, p.archive_batch, (p.file_removed_at is null) as in_cloud, p.bytes
  from ph4 p
union all
select 'doc', d.id, d.job_id, d.project_id, d.job_name, d.is_test, 'deliveries', d.storage_path,
       d.folder, d.base || case when d.dup > 1 then ' (' || d.dup || ')' else '' end || '.' || d.ext,
       null, null, d.kind, case d.kind when 'ticket' then 'Delivery ticket' when 'signature' then 'Customer signature' else 'Site file' end,
       case when d.kind = 'site_file' then d.file_name end, d.at, d.by_name, false, 'delivery',
       null, null, null, null, d.loadout_id, d.archive_batch, (d.file_removed_at is null), d.bytes
  from docs2 d
union all
select 'signed', l.id, l.job_id, j.project_id, j.name, l.is_test, null, null,
       t.day || case when t.n > 1 then ' (' || t.n || ')' else '' end, 'Signed ticket.pdf',
       null, null, 'signed_ticket', case when l.signed_name is not null then 'Signed by ' || l.signed_name else 'Not signed: ' || coalesce(l.no_sign_reason, '') end,
       l.customer_note, l.completed_at, l.completed_by_name, false, 'delivery',
       l.complete_lat, l.complete_lng, l.complete_accuracy, l.signed_at, l.id,
       (select min(d.archive_batch) from delivery_docs d where d.loadout_id = l.id and d.archive_batch is not null),
       not exists (select 1 from delivery_docs d where d.loadout_id = l.id and d.file_removed_at is not null), null
  from loadouts l
  join jobs j on j.id = l.job_id
  join trips t on t.loadout_id = l.id
 where l.completed_at is not null and l.voided_at is null;
revoke all on v_filing from anon;
grant select on v_filing to authenticated;


-- ---------------------------------------------------------------------
-- 8. Delivery files in the monthly archive (managers)
--
-- The office page calls file_archive_batch() straight after
-- prepare_photo_archive(): delivery files from the same jobs join the
-- batch, and every photo and file in it is named the filing way. When a
-- batch is released, its delivery files come off Supabase with the photos.
-- ---------------------------------------------------------------------

create or replace function delivery_docs_archivable_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select d.id from delivery_docs d join jobs j on j.id = d.job_id
   where d.archive_batch is null and d.file_removed_at is null
     and not job_on_floor(j.is_active, j.is_test, j.phase)
     and j.floor_left_at <= now() - interval '60 days'
     and d.added_at <= now() - interval '60 days';
$$;
revoke all on function delivery_docs_archivable_ids() from public, anon, authenticated;

create or replace function file_archive_batch(p_batch text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b photo_archive_batches;
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  select * into b from photo_archive_batches where id = p_batch;
  if b.id is null then raise exception 'There''s no batch %.', p_batch; end if;
  if b.state = 'building' then
    update delivery_docs set archive_batch = p_batch where id in (select delivery_docs_archivable_ids());
    update photos p set archive_name = f.project_id || '/' || f.folder || '/' || f.file_name
      from v_filing f where f.source = 'photo' and f.id = p.id and p.archive_batch = p_batch;
    update delivery_docs d set archive_name = f.project_id || '/' || f.folder || '/' || f.file_name
      from v_filing f where f.source = 'doc' and f.id = d.id and d.archive_batch = p_batch;
    update photo_archive_batches x
       set bytes = (select coalesce(sum(bytes), 0) from photos where archive_batch = p_batch)
                 + (select coalesce(sum(bytes), 0) from delivery_docs where archive_batch = p_batch)
     where x.id = p_batch;
  end if;
  return jsonb_build_object('ok', true, 'batch', p_batch, 'files', coalesce((
    select jsonb_agg(jsonb_build_object(
             'source', f.source, 'id', f.id, 'bucket', f.bucket, 'path', f.storage_path, 'in_cloud', f.in_cloud,
             'name', coalesce(p.archive_name, d.archive_name, f.project_id || '/' || f.folder || '/' || f.file_name),
             'project_id', f.project_id, 'job_name', f.job_name, 'sheet', f.sheet_number, 'table', f.table_no,
             'kind', f.what, 'note', f.note, 'by', f.by_name, 'loadout_id', f.loadout_id, 'bytes', f.bytes,
             'at', to_char(f.at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD HH24:MI'),
             'gps', case when f.lat is not null then round(f.lat::numeric, 6) || ', ' || round(f.lng::numeric, 6) end,
             'mistake', f.mistake, 'test', f.is_test)
           order by coalesce(p.archive_name, d.archive_name, f.project_id || '/' || f.folder || '/' || f.file_name))
      from v_filing f
      left join photos p on f.source = 'photo' and p.id = f.id
      left join delivery_docs d on f.source = 'doc' and d.id = f.id
     where (f.source = 'photo' and p.archive_batch = p_batch)
        or (f.source = 'doc' and d.archive_batch = p_batch)
        or (f.source = 'signed' and exists (select 1 from delivery_docs x where x.loadout_id = f.loadout_id and x.archive_batch = p_batch))
  ), '[]'::jsonb));
end $$;
revoke all on function file_archive_batch(text) from public, anon;
grant execute on function file_archive_batch(text) to authenticated;

create or replace function delivery_docs_to_remove() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('batch', d.archive_batch, 'path', d.storage_path))
                     from delivery_docs d join photo_archive_batches b on b.id = d.archive_batch
                    where b.state in ('released', 'removed') and d.file_removed_at is null), '[]'::jsonb);
end $$;
revoke all on function delivery_docs_to_remove() from public, anon;
grant execute on function delivery_docs_to_remove() to authenticated;

create or replace function mark_delivery_docs_removed(p_batch text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  if not office_ok() then
    raise exception 'Only a manager can archive photos.' using errcode = 'insufficient_privilege';
  end if;
  update delivery_docs d set file_removed_at = now()
   where d.archive_batch = p_batch and d.file_removed_at is null
     and exists (select 1 from photo_archive_batches b where b.id = p_batch and b.state in ('released', 'removed'))
     and not exists (select 1 from storage.objects o where o.bucket_id = 'deliveries' and o.name = d.storage_path);
  get diagnostics n = row_count;
  select count(*) into m from delivery_docs where archive_batch = p_batch and file_removed_at is null;
  return jsonb_build_object('ok', true, 'removed', n, 'left', m,
    'summary', case when n = 0 and m = 0 then ''
                    when m = 0 then format('%s delivery file%s of batch %s are off Supabase too.', n, case when n = 1 then '' else 's' end, p_batch)
                    else format('%s delivery file%s of batch %s couldn''t be removed yet. Try again.', m, case when m = 1 then '' else 's' end, p_batch) end);
end $$;
revoke all on function mark_delivery_docs_removed(text) from public, anon;
grant execute on function mark_delivery_docs_removed(text) to authenticated;


-- ---------------------------------------------------------------------
-- 9. check_deliveries() — PASS/FAIL, undoes everything it does
-- ---------------------------------------------------------------------

create or replace function check_deliveries()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  tst      uuid;  sup uuid;  mgr uuid;
  as_tst   text;  as_sup text;  as_mgr text;
  v_real   uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v        jsonb;
  d1       uuid := gen_random_uuid();     -- the page's own ids
  d2       uuid := gen_random_uuid();
  d3       uuid := gen_random_uuid();
  d_real   uuid := gen_random_uuid();
  f        uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  ph       uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sig      uuid := gen_random_uuid();
  sig2     uuid := gen_random_uuid();
  l1       uuid;  l_id uuid;
  n        int;
  ok       boolean;
  msg      text;
  r        record;
  b        storage.buckets;
  v_batch  text;
  v_day    text;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments))
     and not schedules_deliveries order by ('sanding' = any(departments)) desc limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if tst is null or sup is null or mgr is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery), a supervisor from another department and a manager have logins', false,
      concat_ws(' ', case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when sup is null then 'No real supervisor outside Delivery.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin
    -- the Test Supervisor plays the driver here, so not a scheduler, even if it was made one for practice (undone at the end)
    update profiles set schedules_deliveries = false where id = tst;
    -- ---- 1. the parts exist ------------------------------------------------
    select * into b from storage.buckets where id = 'deliveries';
    ok := b.id is not null and not coalesce(b.public, true) and b.file_size_limit = 10485760
          and b.allowed_mime_types @> array['application/pdf', 'image/jpeg', 'image/png'] and cardinality(b.allowed_mime_types) = 3
          and exists (select 1 from pg_tables where tablename = 'delivery_docs' and rowsecurity)
          and to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid)') is not null
          and to_regprocedure('public.complete_delivery(uuid,uuid,text,text,text,text,timestamp with time zone,double precision,double precision,double precision)') is not null
          and to_regclass('public.v_deliveries') is not null and to_regclass('public.v_filing') is not null
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'site_here');
    res := res || check_row(1, 'Deliveries are set up (the private deliveries bucket, the files table, the functions and views)', ok,
      case when b.id is null then 'There''s no deliveries bucket. Run deliveries.sql again.'
           when b.public then 'The deliveries bucket is PUBLIC — anyone could read the tickets. Run deliveries.sql again, which makes it private.'
           else 'Something is missing. Run deliveries.sql again from the top.' end);

    -- a throwaway job: sheets 1 and 2 are the same item (DC-1, 1 table and 2 tables), sheet 3 has no item code; and a test copy
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999993, 'DELCHECK', 'Delivery check - undone automatically', true, 'In Production', local_today() + 3)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 1, 'DC-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 2, 'DC-1', 'Round', '36"', '36"', '42"'),
             (v_wo, 3, 1, null, 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required) select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('DELCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;

    -- ---- 2. who can schedule --------------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_real, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'A supervisor scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'Delivery (without the scheduling permission) scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      -- the permission Julia gets
      update profiles set schedules_deliveries = true where id = sup;
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_real, now() + interval '2 days', 'Back door, ask for Pat', null, d_real);
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'The scheduler (a real login) scheduled a test job.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = sup;
      ok := ok and exists (select 1 from loadouts where client_id = d_real and scheduled_for is not null and kind = 'delivery' and schedule_note = 'Back door, ask for Pat');
      msg := coalesce(msg, 'A login with the scheduling permission couldn''t schedule a real job.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Only the delivery manager (and managers) schedule; nobody else, and never across lanes', ok, msg);

    -- ---- 3. a manager schedules the test copy; Delivery sees it -------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_test, now() + interval '1 day', 'Loading dock on the north side', null, d1);
      v := schedule_delivery(v_test, now() + interval '1 day', 'resent', null, d1);            -- a resend: once
      v := schedule_delivery(v_test, now() + interval '5 days', null, null, d2);               -- a second trip
      execute 'reset role';
      select id into l1 from loadouts where client_id = d1;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      select count(*) into n from v_loadouts where client_id in (d1, d2) and is_open and scheduled_for is not null and site_steps;
      select n + count(*) into n from v_deliveries where client_id = d1 and schedule_note = 'Loading dock on the north side' and not is_done;
      execute 'reset role';
      ok := n = 3 and (select count(*) from loadouts where client_id = d1) = 1;
      msg := format('Delivery should see both scheduled trips and the note; saw %s of 3.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A scheduled delivery, with its date, time and note, shows on Delivery''s phone', ok, msg);

    -- ---- 4. the ticket ---------------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := add_delivery_doc(f[1], d1, 'ticket', 'ticket.pdf'); ok := false; msg := 'A ticket was recorded before its file arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[1] || '.pdf', '{"size": 40000, "mimetype": "application/pdf"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[2] || '.pdf', '{"size": 41000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[1], d1, 'ticket', 'Ticket 4471.pdf');
      v := add_delivery_doc(f[2], d1, 'ticket', 'Ticket 4471 revised.pdf');
      execute 'reset role';
      ok := ok and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'ticket') = 2
               and exists (select 1 from delivery_docs where client_id = f[1] and retired_at is not null)
               and (select ticket->>'name' from v_deliveries where id = l1) = 'Ticket 4471 revised.pdf';
      msg := coalesce(msg, 'The newer ticket didn''t replace the old one, or the old one wasn''t kept.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The ticket is recorded once its file arrives; a new ticket replaces the old (kept)', ok, msg);

    -- ---- 5. site files ---------------------------------------------------------
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[3] || '.jpg', '{"size": 300000, "mimetype": "image/jpeg"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[4] || '.pdf', '{"size": 90000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[3], d1, 'site_file', 'Where the tables go.jpg');
      v := add_delivery_doc(f[4], d1, 'site_file', 'Site map.pdf');
      v := retire_delivery_doc((select id from delivery_docs where client_id = f[4]));
      execute 'reset role';
      ok := (select jsonb_array_length(files) from v_deliveries where id = l1) = 1
            and exists (select 1 from delivery_docs where client_id = f[4] and retired_at is not null);
      msg := 'The site files didn''t show as added, or a file taken off vanished instead of being kept.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Site files are added, and taking one off keeps it in history', ok, msg);

    -- the photo files, as the phone uploads them first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 2, "mimetype": "image/jpeg"}' from unnest(ph) x;

    -- ---- 6. the truck at the dock ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[1], d1, 'dock', null, null, 1, 39.77, -86.16, 12, now());
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[2], d1, 'dock', null, null, 0); ok := false; msg := 'Truck 0 was accepted.';
      exception when others then null; end;
      v := start_loadout(v_test, d3);
      v := set_loadout_details(d3, 'shipping', null, null);
      begin v := add_delivery_photo(ph[2], d3, 'dock', null, null, 1); ok := false; msg := 'A truck photo was accepted on a shipment.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from v_loadouts where client_id = d1 and trucks_here = array[1] and other_items = 0)
               and exists (select 1 from photos where client_id = ph[1] and stage = 'dock' and truck = 1 and note = 'Truck 1');
      msg := coalesce(msg, 'The truck photo wasn''t recorded as truck 1 (or it counted as an "other item").');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'At the dock, a delivery records one photo per truck (never on a shipment)', ok, msg);

    -- ---- 7. the tables at the site, with the phone's time and place -------------------
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[2], d1, 'site', 2, 1, null, 39.7684, -86.1581, 8, now() - interval '2 minutes');
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[3], d1, 'site', 2, 3); ok := false; msg := 'Table 3 was accepted on a sheet with 2 tables.';
      exception when others then null; end;
      begin v := add_delivery_photo(ph[3], d1, 'site', null, 1); ok := false; msg := 'A site photo with no sheet was accepted.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from photos where client_id = ph[2] and stage = 'site' and sheet_number = 2 and piece = 1
                                                   and lat = 39.7684 and lng = -86.1581 and gps_accuracy = 8 and shot_at is not null)
               and exists (select 1 from v_loadouts where client_id = d1 and site_here = array['2:1'] and not ('2:1' = any(pieces_here)))
               and not exists (select 1 from photos where client_id = ph[3]);
      msg := coalesce(msg, 'The site photo wasn''t saved with its table, time and location, or it counted as a dock photo.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'At the site, each table''s photo keeps its table, the phone''s time and GPS', ok, msg);

    -- ---- 8. signed ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := complete_delivery(sig, d1, '   '); ok := false; msg := 'A signature with no name was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig, d1, 'Pat Jones'); ok := false; msg := 'A signature was accepted before its image arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata)
        values ('deliveries', v_tpid || '/' || d1 || '/' || sig || '.png', '{"size": 9000, "mimetype": "image/png"}');
      v := complete_delivery(sig, d1, 'Pat Jones', 'Table by the window has a scuff', null, null, now() - interval '1 minute', 39.7684, -86.1581, 6);
      v := complete_delivery(sig, d1, 'Pat Jones');                                  -- a resend: once
      execute 'reset role';
      select * into r from loadouts where client_id = d1;
      ok := ok and r.completed_at is not null and r.finished_at is not null and r.signed_name = 'Pat Jones' and r.signed_at is not null
               and r.customer_note = 'Table by the window has a scuff' and r.no_sign_reason is null and r.complete_lat = 39.7684
               and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'signature') = 1
               and (select signature_path from v_deliveries where id = l1) = v_tpid || '/' || d1 || '/' || sig || '.png';
      msg := coalesce(msg, 'The signed delivery wasn''t recorded with its name, note, signature and place (or was recorded twice).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Signed: the name, the customer''s note and the signature are kept; a resend counts once', ok, msg);

    -- ---- 9. once delivered, it stays as signed -------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(gen_random_uuid(), d1, null, null, 'Nobody on site'); ok := false; msg := 'A delivered delivery was marked delivered again, differently.';
      exception when others then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/' || d1 || '/' || f[5] || '.pdf', '{"size": 1, "mimetype": "application/pdf"}');
      begin v := add_delivery_doc(f[5], d1, 'ticket', 'late.pdf'); ok := false; msg := 'The ticket was changed after the customer signed.';
      exception when others then null; end;
      begin v := schedule_delivery(null, now(), null, d1); ok := false; msg := 'A delivered delivery was moved to another date.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Once delivered, the ticket, the date and the signature can''t change', ok, msg);

    -- ---- 10. not signed --------------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(sig2, d2, null, null, 'Too busy'); ok := false; msg := 'A reason not on the list was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig2, d2, null, null, 'Other', '  '); ok := false; msg := '"Other" was accepted with no note.';
      exception when others then null; end;
      v := complete_delivery(sig2, d2, 'nobody', null, 'Nobody on site', 'Left inside the gym, door code from Pat');
      execute 'reset role';
      select * into r from loadouts where client_id = d2;
      ok := ok and r.completed_at is not null and r.no_sign_reason = 'Nobody on site' and r.signed_name is null
               and r.no_sign_note = 'Left inside the gym, door code from Pat'
               and not exists (select 1 from delivery_docs where loadout_id = r.id and kind = 'signature');
      msg := coalesce(msg, 'The unsigned delivery wasn''t recorded with its reason and note.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Not signed: a reason from the list (and a note for Other) is needed, and kept', ok, msg);

    -- ---- 11. Julia's "New" --------------------------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := mark_ticket_downloaded(d1); ok := false; msg := 'Delivery (not the scheduler) marked a ticket downloaded.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      select downloaded_at into r from loadouts where client_id = d1;
      update loadouts set downloaded_at = downloaded_at - interval '1 hour' where client_id = d1;
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      ok := ok and (select downloaded_at < now() - interval '59 minutes' and downloaded_by_name is not null from loadouts where client_id = d1);
      msg := coalesce(msg, 'Downloading didn''t record the first download (or a later one overwrote it).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Downloading a signed ticket is recorded once, by the scheduler or a manager', ok, msg);

    -- ---- 12. who sees delivery files ------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      select (select count(*) from v_deliveries where is_test) + (select count(*) from v_loadouts where job_id = v_test)
           + (select count(*) from delivery_docs) + (select count(*) from storage.objects where bucket_id = 'deliveries') into n;
      execute 'reset role';
      ok := n = 0;
      msg := format('A supervisor outside Delivery can see %s test deliveries or delivery files.', n);
      if ok then
        perform set_config('request.jwt.claims', as_tst, true);
        execute 'set local role authenticated';
        select count(*) into n from delivery_docs where loadout_id = l1;
        select n + count(*) into n from storage.objects where bucket_id = 'deliveries' and name like v_tpid || '/%';
        select n * 100 + count(*) into n from v_deliveries where client_id = d_real;
        execute 'reset role';
        ok := n >= 500 and n % 100 = 0;
        msg := 'Delivery can''t read the test delivery''s files, or can see a real one from the test lane.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Delivery files are for Delivery, the scheduler and managers, lane by lane', ok, msg);

    -- ---- 13. no writing around the functions -------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path) values (gen_random_uuid(), l1, v_test, 'ticket', 'x', 'x');
        ok := false; msg := 'A login wrote to delivery_docs directly.';
      exception when insufficient_privilege then null; end;
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/anything.exe', '{}');
        ok := false; msg := 'A file with the wrong name went into the deliveries bucket.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', 'DELCHECK/' || d_real || '/' || gen_random_uuid() || '.png', '{}');
        ok := false; msg := 'A supervisor outside Delivery uploaded a delivery file.';
      exception when insufficient_privilege then null; end;
      begin v := complete_delivery(gen_random_uuid(), d_real, null, null, 'Other', 'x'); ok := false; msg := 'A supervisor outside Delivery marked a delivery done.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Nobody writes delivery files or marks a delivery done around the checks', ok, msg);

    -- ---- 14. no login ----------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      ok := true; msg := null;
      begin select count(*) into n from delivery_docs; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from v_deliveries; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from storage.objects where bucket_id = 'deliveries'; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin v := schedule_delivery(v_real, now(), null); ok := false; exception when others then null; end;
      execute 'reset role';
      msg := 'Deliveries or their files are visible, or can be scheduled, without logging in. Do not go further.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Someone with no login sees no deliveries or delivery files', ok, msg);

    -- ---- 15. filed the way the shop files ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := log_defect(v_test, 'delivery', (select id from defect_types where department = 'delivery' and active order by sort_order limit 1), 2, 'check', gen_random_uuid());
      v := add_photo(ph[4], 'defect', (v->>'id')::uuid);
      execute 'reset role';
      v_day := 'Delivery ' || to_char((select scheduled_for from loadouts where client_id = d1) at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD');
      select count(*) into n from v_filing where job_id = v_test and (
             (source = 'photo' and folder = 'DC-1' and file_name = 'DC-1-2 Delivery Picture.jpg' and id = (select id from photos where client_id = ph[2]))
          or (source = 'photo' and folder = 'Truck' and file_name = 'Truck-1.jpg')
          or (source = 'photo' and folder = 'DC-1' and file_name = 'DC-1 Defect 1.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Delivery ticket.pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Delivery ticket (replaced).pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Where the tables go.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Signature.png')
          or (source = 'signed' and folder = v_day and file_name = 'Signed ticket.pdf'));
      ok := n = 8;
      msg := format('Expected 8 files named the filing way (DC-1/DC-1-2 Delivery Picture.jpg, Truck/Truck-1.jpg, the ticket, the signature …); found %s.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'Photos and files are named by job, item and table: DC-1/DC-1-2 Delivery Picture.jpg', ok, msg);

    -- ---- 16. the archive takes delivery files too ---------------------------------------
    perform set_config('request.jwt.claims', '', true);
    update jobs set is_active = false, phase = '100% Complete' where id = v_test;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_test;
    update photos set taken_at = now() - interval '61 days' where job_id = v_test;
    update delivery_docs set added_at = now() - interval '61 days' where job_id = v_test;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := prepare_photo_archive();
      v_batch := v->>'batch';
      v := file_archive_batch(v_batch);
      execute 'reset role';
      ok := (select count(*) from delivery_docs where job_id = v_test and archive_batch = v_batch) = 5
            and exists (select 1 from delivery_docs where client_id = f[2] and archive_name = v_tpid || '/' || v_day || '/Delivery ticket.pdf')
            and exists (select 1 from photos where client_id = ph[2] and archive_name = v_tpid || '/DC-1/DC-1-2 Delivery Picture.jpg')
            and exists (select 1 from jsonb_array_elements(v->'files') x where x->>'source' = 'signed' and x->>'name' = v_tpid || '/' || v_day || '/Signed ticket.pdf')
            and not delivery_doc_released(v_tpid || '/' || d1 || '/' || f[2] || '.pdf');
      msg := 'The archive didn''t take the delivery files, named them wrongly, or would let them be removed before the next batch is saved.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(16, 'The monthly archive takes delivery files too, filed the same way', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_deliveries_undo__';
  exception when others then
    if sqlerrm <> '__check_deliveries_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_deliveries() from public, anon, authenticated;

select * from check_deliveries();
