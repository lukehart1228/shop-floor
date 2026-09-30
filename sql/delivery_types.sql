-- =====================================================================
-- delivery_types.sql — White glove, BOL pickup, Customer pickup (30 Sep 2026)
--
-- Julia picks what kind of trip it is. White glove keeps its date and
-- time. The two pickups have no date: they wait on "Ready for pickup"
-- until someone on Delivery or in the office records them.
--   BOL pickup      (kind 'shipping', its old name): every table before
--                   it's wrapped, each wrapped pallet, a photo of the BOL.
--                   Needs at least one BOL photo and one pallet photo.
--   Customer pickup (kind 'customer_pickup'): each table as it's handed
--                   over, then the customer's name and signature.
--
-- Run after deliveries_v2.sql. Safe to run twice. Changes nothing anyone
-- sees until the new pages are on GitHub. Ends with its own check:
-- every row should say PASS.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('delivery_types.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.v_cancelled_deliveries') is null or to_regprocedure('public.restore_delivery(uuid)') is null then
    raise exception 'Run deliveries_v2.sql first. This file builds on it.';
  end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run check_floor.sql first. This file''s check uses it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The new kind, "ready for pickup", and the BOL photo
-- ---------------------------------------------------------------------

alter table loadouts add column if not exists ready_at timestamptz;          -- a pickup Julia set up: when it went on the list
-- Shipments from before this file keep the old screen (no BOL step).
-- Every pickup started from now on has the new steps.
alter table loadouts add column if not exists pickup_steps boolean not null default false;
alter table loadouts alter column pickup_steps set default true;

alter table loadouts drop constraint if exists loadouts_kind_check;
alter table loadouts add constraint loadouts_kind_check check (kind in ('delivery', 'shipping', 'customer_pickup'));

-- a date is for a white glove delivery; "ready for pickup" is for a pickup (checked from now on, not on old rows)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'loadouts_date_or_ready_check') then
    alter table loadouts add constraint loadouts_date_or_ready_check
      check ((scheduled_for is null or kind = 'delivery') and (ready_at is null or kind <> 'delivery')) not valid;
  end if;
end $$;

create index if not exists loadouts_ready_idx on loadouts (ready_at) where ready_at is not null;

alter table photos drop constraint if exists photos_stage_check;
alter table photos add constraint photos_stage_check
  check (stage is null or (stage in ('dock', 'site', 'bol') and kind = 'loadout'));

create or replace function trip_kind_name(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'shipping' then 'BOL pickup' when 'customer_pickup' then 'Customer pickup' else 'White glove delivery' end
$$;
grant execute on function trip_kind_name(text) to authenticated;


-- ---------------------------------------------------------------------
-- 2. The scheduler's checks: pickups Julia set up are hers too
--    (unchanged except the last line: a pickup is allowed, not only a delivery)
-- ---------------------------------------------------------------------
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
  if v.kind <> 'delivery' and not v.pickup_steps then raise exception 'That load-out is an old-style shipment, not a delivery.'; end if;
  return v;
end $$;
revoke all on function delivery_scheduler_check(uuid) from public, anon, authenticated;

-- schedule_delivery: unchanged, except that a pickup can't be given a date
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
    if v.kind <> 'delivery' then
      raise exception 'That''s a % — pickups have no date. To make it a white glove delivery, cancel it and schedule a delivery.', lower(trip_kind_name(v.kind));
    end if;
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


-- ---------------------------------------------------------------------
-- 3. Julia puts a job on "Ready for pickup" (p_loadout null), or changes
--    its note. p_kind: 'shipping' (BOL pickup) or 'customer_pickup'.
-- ---------------------------------------------------------------------
create or replace function schedule_pickup(p_job uuid, p_kind text, p_note text default null,
                                           p_loadout uuid default null, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_id uuid; v_cid uuid := coalesce(p_client_id, gen_random_uuid());
        v_kind text := nullif(trim(lower(coalesce(p_kind, ''))), '');
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can set up pickups.' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'Keep the note to 500 letters.'; end if;

  if p_loadout is not null then                                         -- a new note on one already set up
    v := delivery_scheduler_check(p_loadout);
    if v.kind = 'delivery' then raise exception 'That''s a white glove delivery. Change its date and time instead.'; end if;
    if v.completed_at is not null then raise exception 'That pickup is already done, so it can''t change.'; end if;
    update loadouts set schedule_note = nullif(trim(p_note), '') where id = v.id;
    return jsonb_build_object('ok', true, 'id', v.id, 'client_id', v.client_id,
      'summary', format('%s: note saved.', (select project_id from jobs where id = v.job_id)));
  end if;

  if v_kind is null or v_kind not in ('shipping', 'customer_pickup') then
    raise exception 'A pickup is a BOL pickup or a customer pickup.';
  end if;
  select id into v_id from loadouts where client_id = v_cid;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid, 'already', true, 'summary', 'Already on the list.'); end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null then raise exception 'Pick a job first.'; end if;
  if v_job.is_test and not (is_manager() or am_test()) then
    raise exception '% is a test job. Only a manager or the Test Supervisor sets up test pickups.', v_job.project_id using errcode = 'insufficient_privilege';
  end if;
  if not v_job.is_test and am_test() then
    raise exception 'A test login can only set up test jobs.' using errcode = 'insufficient_privilege';
  end if;
  if not (v_job.is_active or coalesce(v_job.phase, '') in ('Delivery', 'Project Closeout')) then
    raise exception '% isn''t in production or delivery, so it can''t be set up for pickup.', v_job.project_id;
  end if;
  insert into loadouts (client_id, job_id, is_test, started_by, started_by_name, kind, site_steps, pickup_steps,
                        ready_at, scheduled_by, scheduled_by_name, scheduled_at, schedule_note)
  values (v_cid, v_job.id, v_job.is_test, auth.uid(), my_name(), v_kind, false, true,
          now(), auth.uid(), my_name(), now(), nullif(trim(p_note), ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid,
    'summary', format('%s: ready for %s.', v_job.project_id, lower(trip_kind_name(v_kind))));
exception when unique_violation then
  select id into v_id from loadouts where client_id = v_cid;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid, 'already', true, 'summary', 'Already on the list.');
end $$;
revoke all on function schedule_pickup(uuid, text, text, uuid, uuid) from public, anon;
grant execute on function schedule_pickup(uuid, text, text, uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 4. The phone's kind buttons: three kinds now, and a trip set up on the
--    Deliveries page keeps its kind. (Otherwise unchanged.)
-- ---------------------------------------------------------------------
create or replace function set_loadout_details(p_loadout uuid, p_kind text default null,
                                               p_carrier text default null, p_tracking text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_kind text := nullif(trim(lower(coalesce(p_kind, ''))), '');
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  v_job := floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That load-out was marked entered by mistake.'; end if;
  if v.finished_at is not null and v.finished_at < now() - interval '3 days' then
    raise exception 'That load-out finished more than three days ago, so it can''t be changed.';
  end if;
  if v_kind is not null and v_kind not in ('delivery', 'shipping', 'customer_pickup') then
    raise exception 'A load-out is a white glove delivery, a BOL pickup or a customer pickup.';
  end if;
  if v_kind is not null and v_kind <> v.kind then
    if v.scheduled_for is not null or v.ready_at is not null then
      raise exception 'This was set up on the Deliveries page as a %, so its kind is changed there (cancel it and set up the other).',
        lower(trip_kind_name(v.kind)) using errcode = 'insufficient_privilege';
    end if;
    if v.completed_at is not null then raise exception 'That trip is already done, so its kind can''t change.'; end if;
  end if;
  if length(coalesce(p_carrier, '')) > 80 or length(coalesce(p_tracking, '')) > 80 then
    raise exception 'Keep the carrier and tracking number to 80 letters each.';
  end if;
  update loadouts set kind     = coalesce(v_kind, kind),
                      carrier  = case when p_carrier  is null then carrier  else nullif(trim(p_carrier), '')  end,
                      tracking = case when p_tracking is null then tracking else nullif(trim(p_tracking), '') end
   where id = v.id
  returning * into v;
  return jsonb_build_object('ok', true, 'summary',
    format('%s: %s%s%s.', v_job.project_id, case v.kind when 'shipping' then 'a BOL pickup' when 'customer_pickup' then 'a customer pickup' else 'a delivery' end,
           coalesce(', ' || v.carrier, ''), coalesce(', tracking ' || v.tracking, '')));
end $$;
revoke all on function set_loadout_details(uuid, text, text, text) from public, anon;
grant execute on function set_loadout_details(uuid, text, text, text) to authenticated;


-- ---------------------------------------------------------------------
-- 5. A photo of the BOL (a page each). Same rules as the other trip
--    photos: the file first; a resend counts once; a pickup that hasn't
--    arrived yet answers "waiting".
-- ---------------------------------------------------------------------
create or replace function add_bol_photo(p_client_id uuid, p_loadout uuid, p_shot_at timestamptz default null,
                                         p_width int default null, p_height int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_res jsonb; n int;
begin
  if p_client_id is null then raise exception 'This photo has no id. Take it again.'; end if;
  if exists (select 1 from photos where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Photo already saved.',
                              'id', (select id from photos where client_id = p_client_id));
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  v := delivery_lookup(p_loadout);
  if v.id is null then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The pickup this photo belongs to hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That pickup was marked entered by mistake, so the photo wasn''t added.'; end if;
  if v.kind <> 'shipping' or not v.pickup_steps then raise exception 'A BOL photo is for a BOL pickup.'; end if;
  if v.completed_at is not null and v.completed_at < now() - interval '1 day' then
    raise exception 'That pickup was finished on %. The photo wasn''t added.', local_when(v.completed_at);
  end if;
  select count(*) into n from photos where loadout_id = v.id and stage = 'bol';
  v_res := add_photo(p_client_id, 'loadout', v.id, null, 'BOL page ' || (n + 1), p_width, p_height);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
  update photos set stage = 'bol', shot_at = least(now(), coalesce(p_shot_at, now())) where client_id = p_client_id;
  return v_res || jsonb_build_object('summary', format('BOL photo saved on %s.', (select project_id from jobs where id = v.job_id)));
end $$;
revoke all on function add_bol_photo(uuid, uuid, timestamptz, int, int) from public, anon;
grant execute on function add_bol_photo(uuid, uuid, timestamptz, int, int) to authenticated;


-- ---------------------------------------------------------------------
-- 6. Picked up. Anyone on Delivery or in the office (floor_entry_check).
--    BOL pickup: needs a BOL photo and a wrapped-pallet photo; no signature.
--    Customer pickup: the signature image goes up first (as
--    <PROJ>/<pickup>/<p_client_id>.png), or a reason: Customer refused,
--    or Other with a note. Also finishes the load-out.
-- ---------------------------------------------------------------------
create or replace function complete_pickup(p_client_id uuid, p_loadout uuid, p_signed_name text default null,
                                           p_customer_note text default null, p_no_sign_reason text default null,
                                           p_no_sign_note text default null, p_signed_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text; v_path text; v_obj record; v_signed boolean := p_no_sign_reason is null;
        v_name text := nullif(regexp_replace(trim(coalesce(p_signed_name, '')), '\s+', ' ', 'g'), '');
begin
  if p_client_id is null then raise exception 'This has no id. Try again.'; end if;
  if exists (select 1 from loadouts where completion_client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked picked up.');
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  v := delivery_lookup(p_loadout);
  if v.id is null then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The pickup hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That pickup was marked entered by mistake.'; end if;
  if v.kind = 'delivery' then raise exception 'That''s a white glove delivery: it''s marked delivered, not picked up.'; end if;
  if not v.pickup_steps then raise exception 'That shipment was started before pickups had their own steps. Finish it with "Picked up — finish this shipment".'; end if;
  if v.completed_at is not null then
    raise exception 'That was already marked picked up by % (%).', coalesce(v.completed_by_name, 'someone'), local_when(v.completed_at);
  end if;
  if length(coalesce(p_customer_note, '')) > 1000 or length(coalesce(p_no_sign_note, '')) > 1000 then
    raise exception 'Keep each note to 1,000 letters.';
  end if;
  select project_id into v_pid from jobs where id = v.job_id;

  if v.kind = 'shipping' then
    if not exists (select 1 from photos where loadout_id = v.id and stage = 'bol' and voided_at is null) then
      raise exception 'Photograph the BOL first. A BOL pickup isn''t done without it.';
    end if;
    if not exists (select 1 from photos where loadout_id = v.id and pallet is not null and voided_at is null) then
      raise exception 'Photograph each pallet once it''s wrapped first.';
    end if;
    update loadouts set completed_at = now(), completed_by = auth.uid(), completed_by_name = my_name(), completion_client_id = p_client_id,
                        customer_note = nullif(trim(p_customer_note), ''),
                        finished_at = coalesce(finished_at, now()), finished_by_name = coalesce(finished_by_name, my_name())
     where id = v.id;
    return jsonb_build_object('ok', true, 'summary',
      format('%s picked up%s.', v_pid, coalesce(' by ' || v.carrier, '') || coalesce(', BOL ' || v.tracking, '')));
  end if;

  -- a customer pickup
  if v_signed then
    if v_name is null then raise exception 'Type the name of the person who signed.'; end if;
    if length(v_name) > 80 then raise exception 'Keep the name to 80 letters.'; end if;
    v_path := v_pid || '/' || coalesce(v.client_id, v.id) || '/' || p_client_id || '.png';
    select o.name, o.metadata into v_obj from storage.objects o where o.bucket_id = 'deliveries' and o.name = v_path;
    if v_obj.name is null then raise exception 'The signature hasn''t arrived, so the pickup wasn''t marked done. Try again.'; end if;
    insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, is_test, added_by, added_by_name)
    values (p_client_id, v.id, v.job_id, 'signature', 'Signature.png', v_path, v_obj.metadata ->> 'mimetype',
            nullif(v_obj.metadata ->> 'size', '')::bigint, v.is_test, auth.uid(), my_name());
  else
    if p_no_sign_reason not in ('Customer refused', 'Other') then
      raise exception 'Pick why there''s no signature: Customer refused, or Other.';
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
                      finished_at = coalesce(finished_at, now()), finished_by_name = coalesce(finished_by_name, my_name())
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    case when v_signed then format('%s picked up — signed by %s.', v_pid, v_name)
         else format('%s picked up — not signed (%s).', v_pid, lower(p_no_sign_reason)) end);
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked picked up.');
end $$;
revoke all on function complete_pickup(uuid, uuid, text, text, text, text, timestamptz) from public, anon;
grant execute on function complete_pickup(uuid, uuid, text, text, text, text, timestamptz) to authenticated;


-- ---------------------------------------------------------------------
-- 7. Cancel and put back: a pickup Julia set up is hers to cancel, like
--    a scheduled delivery. (Otherwise unchanged from deliveries_v2.sql.)
-- ---------------------------------------------------------------------
create or replace function void_loadout(p_loadout uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_set_up boolean;
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  if v.voided_at is not null then
    return 'Marked as entered by mistake. It''s kept in history, with its photos.';      -- a resend: nothing changes
  end if;
  v_set_up := v.scheduled_for is not null or v.ready_at is not null;
  if v.completed_at is not null then
    raise exception 'That % (%), so it can''t be cancelled.',
      case when v.kind = 'delivery' then 'delivery was already delivered' else 'pickup was already picked up' end, local_when(v.completed_at);
  end if;
  if v_set_up and not can_schedule_deliveries() then
    raise exception 'This % was set up by %, so it''s cancelled on the Deliveries page, not here. A wrong photo can be marked entered by mistake on its own.',
      case when v.kind = 'delivery' then 'delivery' else 'pickup' end,
      coalesce(v.scheduled_by_name, 'the delivery manager') using errcode = 'insufficient_privilege';
  end if;
  if not (v.started_by = auth.uid() or office_ok() or (v_set_up and can_schedule_deliveries())) then
    raise exception 'Only the person who started it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  update loadouts set voided_at = now(), voided_by_name = my_name(),
                      void_reason = coalesce(nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = v.id;
  return 'Marked as entered by mistake. It''s kept in history, with its photos.';
end $$;
revoke all on function void_loadout(uuid, text) from public, anon;
grant execute on function void_loadout(uuid, text) to authenticated;

create or replace function restore_delivery(p_loadout uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text;
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can put a delivery back.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That delivery isn''t there.'; end if;
  if v.is_test and not (is_manager() or am_test()) then
    raise exception 'That''s a test delivery. Only a manager or the Test Supervisor puts it back.' using errcode = 'insufficient_privilege';
  end if;
  if not v.is_test and am_test() then
    raise exception 'A test login can only put back test deliveries.' using errcode = 'insufficient_privilege';
  end if;
  if not ((v.kind = 'delivery' and v.scheduled_for is not null) or (v.kind <> 'delivery' and v.ready_at is not null)) then
    raise exception 'Only a delivery or pickup set up on the Deliveries page can be put back here.';
  end if;
  select project_id into v_pid from jobs where id = v.job_id;
  if v.voided_at is null then                                            -- a resend, or already back
    return jsonb_build_object('ok', true, 'summary',
      case when v.kind = 'delivery' then format('The %s delivery of %s is on the list.', local_when(v.scheduled_for), v_pid)
           else format('%s is on Ready for pickup.', v_pid) end);
  end if;
  update loadouts
     set void_history = void_history || jsonb_build_array(jsonb_build_object(
           'voided_at', v.voided_at, 'voided_by_name', v.voided_by_name, 'void_reason', v.void_reason,
           'restored_at', now(), 'restored_by_name', my_name())),
         voided_at = null, voided_by_name = null, void_reason = null
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    case when v.kind <> 'delivery' then format('%s is back on Ready for pickup, on Delivery''s phone too.', v_pid)
         else format('The %s delivery of %s is back, on Delivery''s phone too.%s', local_when(v.scheduled_for), v_pid,
                     case when v.scheduled_for < now() then ' Its date has passed: change it if the delivery is still to come.' else '' end) end);
end $$;
revoke all on function restore_delivery(uuid) from public, anon;
grant execute on function restore_delivery(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 8. What the pages read. Every column each view had stays, in the same
--    place; the new ones are at the end.
-- ---------------------------------------------------------------------

-- v_loadouts: BOL photos aren't "other items"; plus ready_at, pickup_steps, the BOL count
create or replace view v_loadouts with (security_invoker = true) as
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
           and p.pallet is null and p.truck is null and p.stage is distinct from 'bol') as other_items,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null) as photo_count,
       l.kind, l.carrier, l.tracking,
       (select coalesce(sum(s.qty), 0)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as pieces_total,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as pieces_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null and p.stage is distinct from 'site'), '{}') as pieces_earlier,
       coalesce((select array_agg(distinct p.pallet order by p.pallet) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.pallet is not null), '{}') as pallets_here,
       l.site_steps, l.scheduled_for, l.schedule_note, l.scheduled_by_name,
       l.completed_at, l.completed_by_name, l.signed_name, l.signed_at, l.no_sign_reason,
       coalesce((select array_agg(distinct p.truck order by p.truck) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.truck is not null), '{}') as trucks_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || p.piece) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.stage = 'site'), '{}') as site_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || p.piece) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null
                    and l2.completed_at is not null and (l.completed_at is null or l2.completed_at < l.completed_at)
                    and p.voided_at is null and p.stage = 'site'), '{}') as site_earlier,
       -- delivery types
       l.ready_at, l.pickup_steps,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.stage = 'bol') as bol_here
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null;
revoke all on v_loadouts from anon;
grant select on v_loadouts to authenticated;

-- v_deliveries: white glove deliveries as before, plus pickups (Julia's, or started on the phone and done)
create or replace view v_deliveries with (security_invoker = true) as
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
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.truck is not null) as truck_photos,
       -- delivery types
       l.kind, l.ready_at, l.carrier, l.tracking,
       (select count(distinct p.sheet_number || ':' || coalesce(p.piece, 1))::int from photos p
         where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null and p.stage is null) as tables_photographed,
       (select count(distinct p.pallet)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.pallet is not null) as pallets_photographed,
       coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'path', p.storage_path, 'shot_at', p.shot_at, 'in_cloud', p.file_removed_at is null)
                                  order by p.taken_at, p.id)
                   from photos p where p.loadout_id = l.id and p.voided_at is null and p.stage = 'bol'), '[]'::jsonb) as bol_photos
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null
  and ((l.kind = 'delivery' and (l.scheduled_for is not null or l.completed_at is not null))
       or (l.kind <> 'delivery' and l.pickup_steps and (l.ready_at is not null or l.completed_at is not null)));
revoke all on v_deliveries from anon;
grant select on v_deliveries to authenticated;

-- the Deliveries page's Cancelled list: pickups too
create or replace view v_cancelled_deliveries with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, l.is_test,
       l.scheduled_for, l.schedule_note, l.scheduled_by_name, l.voided_at, l.voided_by_name, l.void_reason,
       exists (select 1 from delivery_docs d where d.loadout_id = l.id and d.kind = 'ticket' and d.retired_at is null) as has_ticket,
       (select count(*)::int from delivery_docs d where d.loadout_id = l.id and d.kind = 'site_file' and d.retired_at is null) as site_files,
       l.kind, l.ready_at
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is not null and l.voided_at > now() - interval '60 days' and l.completed_at is null
  and ((l.kind = 'delivery' and l.scheduled_for is not null) or (l.kind <> 'delivery' and l.ready_at is not null))
  and sees_deliveries();
revoke all on v_cancelled_deliveries from anon;
grant select on v_cancelled_deliveries to authenticated;

-- v_filing: the same names as before, plus
--   PROJ-00418/BOL/BOL-1.jpg                           (a BOL pickup's BOL, a photo per page)
--   PROJ-00418/TB-03/TB-03-2 Pickup Picture.jpg        (a table as the customer took it)
--   PROJ-00418/Pickup 2026-10-14/Delivery ticket.pdf · Signature.png · Signed ticket.pdf
-- A BOL pickup has no signed ticket (the BOL is its record); Julia's page makes its PDF.
create or replace view v_filing with (security_invoker = true) as
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
              when p.stage = 'bol' then 'BOL'
              when p.kind = 'loadout' then 'Other' else 'Job' end as folder,
         case when p.kind = 'loadout' and p.sheet_number is not null then coalesce(s.unit_offset, 0) + coalesce(p.piece, 1) end as table_no,
         case p.kind when 'defect' then 'Defect' when 'problem' then 'Problem'
              else case when p.truck is not null then 'Truck' when p.pallet is not null then 'Pallet'
                        when p.stage = 'bol' then 'BOL'
                        when p.stage = 'site' then 'Delivery Picture'
                        when l.kind = 'shipping' then 'Before Wrap'
                        when l.kind = 'customer_pickup' then 'Pickup Picture' else 'Load-out Picture' end end as what
    from photos p
    join jobs j on j.id = p.job_id
    left join sh2 s on s.job_id = p.job_id and s.sheet_number = p.sheet_number
    left join loadouts l on l.id = p.loadout_id
), ph2 as (
  select ph.*,
         case when stage = 'bol' then null
              when truck is not null then 'Truck-' || truck
              when pallet is not null then 'Pallet-' || pallet
              when table_no is not null then folder || '-' || table_no || ' ' || what
              when kind = 'loadout' then left(coalesce(nullif(trim(regexp_replace(coalesce(note, ''), '[\\/:*?"<>|]+', '-', 'g')), ''), 'Item'), 60)
         end as fixed,
         row_number() over (partition by job_id, folder, what, (kind <> 'loadout') order by at, id) as counted
    from ph
), ph3 as (
  select ph2.*, case when stage = 'bol' then 'BOL-' || counted else coalesce(fixed, folder || ' ' || what || ' ' || counted) end as base
    from ph2
), ph4 as (
  select ph3.*, row_number() over (partition by job_id, folder, base order by at, id) as dup
    from ph3
), trips0 as (
  select l.id as loadout_id, l.job_id,
         case when l.kind = 'delivery' then 'Delivery ' else 'Pickup ' end as label,
         (case when l.kind = 'delivery' then coalesce(l.scheduled_for, l.started_at)
               else coalesce(l.completed_at, l.ready_at, l.started_at) end) as day_at
    from loadouts l
), trips as (
  select t.loadout_id, t.job_id,
         t.label || to_char(t.day_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') as day,
         row_number() over (partition by t.job_id, t.label, (t.day_at at time zone 'America/Indiana/Indianapolis')::date
                            order by t.day_at, t.loadout_id) as n
    from trips0 t
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
 where l.completed_at is not null and l.voided_at is null and l.kind <> 'shipping';
revoke all on v_filing from anon;
grant select on v_filing to authenticated;


-- ---------------------------------------------------------------------
-- 9. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_delivery_types()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  tst     uuid;  sup uuid;  mgr uuid;  drv uuid;
  as_tst  text;  as_sup text;  as_mgr text;  as_drv text;
  v_real  uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v       jsonb;
  b1      uuid := gen_random_uuid();     -- the page's own ids: a BOL pickup, a customer pickup, a white glove, one started on the phone
  c1      uuid := gen_random_uuid();
  w1      uuid := gen_random_uuid();
  p1      uuid := gen_random_uuid();
  r1      uuid := gen_random_uuid();     -- a pickup to cancel (and the lane test)
  r2      uuid := gen_random_uuid();     -- real-job pickups: the office records one, a supervisor is refused another
  r3      uuid := gen_random_uuid();
  ph      uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sig     uuid := gen_random_uuid();
  ok      boolean;
  msg     text;
  n       int;
  t       text;
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
    -- ---- 1. the parts exist ----------------------------------------------------
    ok := to_regprocedure('public.schedule_pickup(uuid,text,text,uuid,uuid)') is not null
          and to_regprocedure('public.add_bol_photo(uuid,uuid,timestamp with time zone,integer,integer)') is not null
          and to_regprocedure('public.complete_pickup(uuid,uuid,text,text,text,text,timestamp with time zone)') is not null
          and exists (select 1 from information_schema.columns where table_name = 'v_deliveries' and column_name = 'bol_photos')
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'bol_here')
          and exists (select 1 from information_schema.columns where table_name = 'v_cancelled_deliveries' and column_name = 'ready_at')
          and pg_get_constraintdef((select oid from pg_constraint where conname = 'loadouts_kind_check')) like '%customer_pickup%'
          and pg_get_constraintdef((select oid from pg_constraint where conname = 'photos_stage_check')) like '%bol%';
    res := res || check_row(1, 'Delivery types are set up (the new kind, the functions, the columns the pages read)', ok,
      'Something is missing. Run delivery_types.sql again from the top.');

    -- a throwaway real job (3 tables on 2 sheets) and its test copy. The Test Supervisor plays the one handing over;
    -- a manager plays Julia (so the Test Supervisor isn't a scheduler, even if it was made one for practice: undone at the end)
    update profiles set schedules_deliveries = false where id = tst;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999992, 'PICKCHECK', 'Pickup check - undone automatically', true, 'In Production', local_today() + 3)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 2, 'PK-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 1, 'PK-2', 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required) select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('PICKCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 2, "mimetype": "image/jpeg"}' from unnest(ph) x;

    -- ---- 2. Julia's page: two pickups with no date ----------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_test, 'shipping', 'Estes, sometime this week', null, b1);
      v := schedule_pickup(v_test, 'shipping', 'resent', null, b1);                          -- a resend: once
      v := schedule_pickup(v_test, 'customer_pickup', null, null, c1);
      v := schedule_delivery(v_test, now() + interval '2 days', null, null, w1);
      select count(*) into n from v_deliveries
       where (client_id = b1 and kind = 'shipping' and scheduled_for is null and ready_at is not null and schedule_note = 'Estes, sometime this week')
          or (client_id = c1 and kind = 'customer_pickup' and scheduled_for is null and ready_at is not null)
          or (client_id = w1 and kind = 'delivery' and scheduled_for is not null and ready_at is null);
      execute 'reset role';
      ok := n = 3 and (select count(*) from loadouts where client_id = b1) = 1;
      msg := format('Expected a BOL pickup and a customer pickup with no date, and the white glove delivery with its date; found %s of 3.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'The scheduler sets up a BOL pickup and a customer pickup with no date; white glove keeps its date', ok, msg);

    -- ---- 3. only a scheduler sets one up, never across lanes ---------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_real, 'shipping', null, null, gen_random_uuid()); ok := false; msg := 'A supervisor from another department set up a pickup.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_test, 'customer_pickup', null, null, gen_random_uuid()); ok := false; msg := 'Delivery (without the scheduling permission) set up a pickup.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_real, 'shipping', null, null, r1); ok := false; msg := 'A test login set up a pickup on a real job.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = tst;
      ok := ok and not exists (select 1 from loadouts where client_id = r1);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Only the delivery manager (and managers) set up pickups; nobody else, and never across lanes', ok, msg);

    -- ---- 4. a pickup has no date, and keeps its kind --------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_test, now() + interval '1 day', null, b1, null); ok := false; msg := 'A pickup was given a date.';
      exception when others then if sqlerrm not like '%no date%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := set_loadout_details(c1, 'delivery', null, null); ok := false; msg := 'The phone changed a customer pickup into a delivery.';
      exception when insufficient_privilege then null; end;
      v := set_loadout_details(b1, null, 'Estes', 'BOL 44812');                              -- carrier and BOL number: allowed
      execute 'reset role';
      ok := ok and (select kind = 'customer_pickup' from loadouts where client_id = c1)
               and (select carrier = 'Estes' and tracking = 'BOL 44812' and scheduled_for is null from loadouts where client_id = b1);
      msg := coalesce(msg, 'The carrier and BOL number weren''t saved, or a kind changed.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A pickup can''t be given a date, and the phone can''t change its kind (carrier and BOL number still save)', ok, msg);

    -- ---- 5. a BOL pickup needs its BOL photo and a wrapped pallet ---------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), b1); ok := false; msg := 'A BOL pickup was marked picked up with no BOL photo.';
      exception when others then if sqlerrm not like '%BOL first%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      v := add_bol_photo(ph[1], b1, now(), 1600, 1200);
      v := add_bol_photo(ph[1], b1, now(), 1600, 1200);                                      -- a resend: once
      begin v := complete_pickup(gen_random_uuid(), b1); ok := false; msg := 'A BOL pickup was marked picked up with no pallet photo.';
      exception when others then if sqlerrm not like '%pallet%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      v := add_loadout_photo(ph[2], b1, null, null, 1, null, 1600, 1200);                    -- pallet 1, wrapped
      v := add_loadout_photo(ph[3], b1, 1, 1, null, null, 1600, 1200);                       -- sheet 1 table 1, before wrap
      v := complete_pickup(sig, b1, null, 'Two pallets, shrink-wrapped');
      v := complete_pickup(sig, b1);                                                          -- a resend: once
      begin v := add_bol_photo(ph[4], c1, now()); ok := false; msg := 'A BOL photo was accepted on a customer pickup.';
      exception when others then null; end;
      select count(*) into n from v_deliveries where client_id = b1 and is_done and jsonb_array_length(bol_photos) = 1
         and pallets_photographed = 1 and tables_photographed = 1 and completed_by_name is not null;
      execute 'reset role';
      ok := ok and n = 1 and (select finished_at is not null and customer_note = 'Two pallets, shrink-wrapped' from loadouts where client_id = b1)
            and (select stage = 'bol' and note = 'BOL page 1' from photos where client_id = ph[1]);
      msg := coalesce(msg, 'The BOL pickup didn''t come out picked up, with one BOL photo, one pallet and one table.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A BOL pickup is done only with a BOL photo and a wrapped pallet; no signature needed', ok, msg);

    -- ---- 6. a customer pickup needs a signature, or Customer refused / Other ------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[5], c1, 2, 1, null, null, 1600, 1200);                       -- sheet 2's table, handed over
      begin v := complete_pickup(gen_random_uuid(), c1, 'Pat Jones'); ok := false; msg := 'A customer pickup was signed before the signature arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      begin v := complete_pickup(gen_random_uuid(), c1, null, null, 'Nobody on site'); ok := false; msg := '"Nobody on site" was accepted on a pickup.';
      exception when others then null; end;
      begin v := complete_pickup(gen_random_uuid(), c1, null, null, 'Other', ' '); ok := false; msg := '"Other" was accepted with no note.';
      exception when others then null; end;
      execute 'reset role';
      insert into storage.objects (bucket_id, name, metadata)
        values ('deliveries', v_tpid || '/' || c1 || '/' || ph[6] || '.png', '{"size": 900, "mimetype": "image/png"}');
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := complete_pickup(ph[6], c1, 'Pat Jones', 'Took both tables in a van', null, null, now());
      select count(*) into n from v_deliveries where client_id = c1 and is_done and signed_name = 'Pat Jones' and signature_path like '%.png' and tables_photographed = 1;
      execute 'reset role';
      -- the office records one too: a manager, on a real job (managers don't record in the test lane)
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_real, 'customer_pickup', null, null, r2);
      v := complete_pickup(gen_random_uuid(), r2, null, 'Signed the paper ticket instead', 'Other', 'Signed our paper copy');
      execute 'reset role';
      ok := ok and n = 1 and (select completed_by = mgr and no_sign_reason = 'Other' from loadouts where client_id = r2);
      msg := coalesce(msg, 'The customer pickup didn''t come out signed by Pat Jones with its signature and table photo, or the office couldn''t record one.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A customer pickup is signed (or Customer refused / Other with a note); the office can record one too', ok, msg);

    -- ---- 7. nobody outside Delivery and the office records one -------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_real, 'shipping', null, null, r3);
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), r3); ok := false; msg := 'Someone outside Delivery recorded a pickup.';
      exception when insufficient_privilege then null; end;
      begin v := add_bol_photo(gen_random_uuid(), r3, now()); ok := false; msg := 'Someone outside Delivery added a BOL photo.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), w1, null, null, 'Customer refused'); ok := false; msg := 'A white glove delivery was marked picked up.';
      exception when others then if sqlerrm not like '%white glove%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      begin v := complete_delivery(gen_random_uuid(), c1, null, null, 'Nobody on site'); ok := false; msg := 'A customer pickup was marked delivered.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and (select completed_at is null from loadouts where client_id = w1) and (select completed_at is null from loadouts where client_id = r3);
      msg := coalesce(msg, 'Something was recorded that shouldn''t have been.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Only Delivery and the office record a pickup; a delivery and a pickup can''t be finished the other''s way', ok, msg);

    -- ---- 8. started on the phone: the same steps, and it reaches Julia's Completed -------
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := start_loadout(v_test, p1);
      v := set_loadout_details(p1, 'customer_pickup', null, null);
      select count(*) into n from v_loadouts where client_id = p1 and kind = 'customer_pickup' and pickup_steps and ready_at is null;
      v := complete_pickup(gen_random_uuid(), p1, null, 'Picked up at the back door', 'Customer refused', null);
      select n * 10 + count(*) into n from v_deliveries where client_id = p1 and is_done and no_sign_reason = 'Customer refused';
      execute 'reset role';
      ok := n = 11;
      msg := format('A customer pickup started on the phone should have the new steps and reach Completed (expected 1 and 1, got %s and %s).', n / 10, n % 10);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A pickup started on the phone gets the same steps and shows on the Deliveries page once done', ok, msg);

    -- ---- 9. cancel and put back ----------------------------------------------------------
    ok := true; msg := null;
    begin
      -- the Test Supervisor sets it up (so it's "started by" them), then stops being a scheduler:
      -- "started by mistake" on the phone must still be refused
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_test, 'shipping', null, null, r1);
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin perform void_loadout(r1, null); ok := false; msg := 'The phone cancelled a pickup the scheduler set up.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_loadout(r1, 'Delivery cancelled');
      select count(*) into n from v_cancelled_deliveries where client_id = r1 and kind = 'shipping' and ready_at is not null;
      v := restore_delivery(r1);
      select n * 10 + count(*) into n from v_deliveries where client_id = r1;
      begin perform void_loadout(b1, 'Delivery cancelled'); ok := false; msg := 'A pickup already picked up was cancelled.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and n = 11;
      msg := coalesce(msg, format('Cancel should put it under Cancelled, and put back on the list (expected 1 and 1, got %s and %s).', n / 10, n % 10));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'A pickup is cancelled and put back like a delivery; once picked up it can''t be cancelled', ok, msg);

    -- ---- 10. filing ----------------------------------------------------------------------
    begin
      select string_agg(folder || '/' || file_name, ' | ' order by folder, file_name) into t
        from v_filing where job_id = v_test and (loadout_id in (select id from loadouts where client_id in (b1, c1)));
      ok := t like '%BOL/BOL-1.jpg%' and t like '%Pallets/Pallet-1.jpg%' and t like '%PK-1/PK-1-1 Before Wrap.jpg%'
            and t like '%PK-2/PK-2-1 Pickup Picture.jpg%' and t like '%Pickup ____-__-__%/Signature.png%'
            and (select count(*) from v_filing where source = 'signed' and loadout_id = (select id from loadouts where client_id = c1)) = 1
            and (select count(*) from v_filing where source = 'signed' and loadout_id = (select id from loadouts where client_id = b1)) = 0;
      msg := 'The files weren''t named as expected. Got: ' || coalesce(t, 'nothing');
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Pickups are filed: BOL/BOL-1.jpg, "Pickup Picture", a Pickup <date> folder; a customer pickup gets a signed ticket', ok, msg);

    -- ---- 11. no login can read the new parts without signing in -----------------------------
    begin
      ok := not has_function_privilege('anon', 'public.schedule_pickup(uuid,text,text,uuid,uuid)', 'execute')
            and not has_function_privilege('anon', 'public.complete_pickup(uuid,uuid,text,text,text,text,timestamp with time zone)', 'execute')
            and not has_function_privilege('anon', 'public.add_bol_photo(uuid,uuid,timestamp with time zone,integer,integer)', 'execute')
            and not has_table_privilege('anon', 'public.v_deliveries', 'select')
            and not has_table_privilege('anon', 'public.v_loadouts', 'select')
            and not has_table_privilege('anon', 'public.v_cancelled_deliveries', 'select');
      msg := 'Someone with no login could call a pickup function or read the delivery lists. Run delivery_types.sql again.';
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Nobody without a login can set up, record or read pickups', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_delivery_types_undo__';
  exception when others then
    if sqlerrm <> '__check_delivery_types_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_delivery_types() from public, anon, authenticated;

select * from check_delivery_types();
