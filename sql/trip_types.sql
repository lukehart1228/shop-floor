-- =====================================================================
-- Shop Floor — two more kinds of trip: Dock to dock, and Tasks (5 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- 1. DOCK TO DOCK (kind 'dock'). Like a white glove delivery in every way
--    the database cares about: a job, a date and time, the ticket, truck
--    photos, a signature (or why not). The difference is on the phone:
--    a photo of each table before it leaves our dock, then a few photos
--    of the drop at their dock (add_delivery_photo now takes a site photo
--    with no table for a dock to dock trip, noted "At their dock"). Everywhere the database treated white
--    glove specially ("a dated trip on our truck, signed for at the other
--    end"), dock to dock is now treated the same; pickups are unchanged.
--    schedule_delivery() takes a new, optional p_kind ('delivery' or
--    'dock'); older pages that don't send it keep working, and moving an
--    existing trip keeps its kind unless p_kind says otherwise.
-- 2. TASKS (new tables delivery_tasks and task_photos). A job for Delivery
--    that isn't a delivery: "pick up a damaged chair", say. A date and
--    time, what to do, where, and either a PROJ number (any job, even a
--    finished one) or a few words saying what it's for, or neither. A PROJ
--    can be added later. Delivery taps Done; a note and photos are
--    optional. Julia (or a manager) schedules, changes and cancels them;
--    Delivery and the scheduler see them; test logins see test ones.
--    Upcoming tasks show on the floor TV's going-out list.
--
-- Replaces pieces of deliveries.sql, deliveries_v2.sql (check_deliveries
-- now accepts the new schedule_delivery), delivery_types.sql and
-- tv_pace.sql, so those now stop if run again. Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('trip_types.sql', '{deliveries.sql,deliveries_v2.sql,delivery_types.sql,tv_pace.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.tv_snapshot(text)') is null and to_regproc('public.tv_snapshot') is null then raise exception 'Run tv_pace.sql first. This file builds on it.'; end if;
  if to_regclass('public.v_filing') is null or to_regprocedure('public.complete_pickup(uuid,uuid,text,text,text,text,timestamptz,double precision,double precision,double precision)') is null and to_regproc('public.complete_pickup') is null then
    raise exception 'Run delivery_types.sql first. This file builds on it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Dock to dock
-- ---------------------------------------------------------------------
alter table loadouts drop constraint if exists loadouts_kind_check;
alter table loadouts add constraint loadouts_kind_check check (kind in ('delivery', 'dock', 'shipping', 'customer_pickup'));
alter table loadouts drop constraint if exists loadouts_date_or_ready_check;
alter table loadouts add constraint loadouts_date_or_ready_check
  check ((scheduled_for is null or kind in ('delivery', 'dock')) and (ready_at is null or kind not in ('delivery', 'dock'))) not valid;

create or replace function trip_kind_name(p_kind text) returns text language sql immutable as $$
  select case p_kind when 'shipping' then 'BOL pickup' when 'customer_pickup' then 'Customer pickup' when 'dock' then 'Dock to dock delivery'
                     else 'White glove delivery' end
$$;

drop function if exists schedule_delivery(uuid, timestamptz, text, uuid, uuid);
create or replace function schedule_delivery(p_job uuid, p_when timestamptz, p_note text default null,
                                             p_loadout uuid default null, p_client_id uuid default null,
                                             p_kind text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_id uuid; v_cid uuid := coalesce(p_client_id, gen_random_uuid());
        v_kind text := nullif(lower(trim(coalesce(p_kind, ''))), '');
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can schedule deliveries.' using errcode = 'insufficient_privilege';
  end if;
  if v_kind is not null and v_kind not in ('delivery', 'dock') then raise exception 'A dated delivery is white glove or dock to dock.'; end if;
  if p_when is null then raise exception 'Pick the date and time of the delivery.'; end if;
  if p_when < now() - interval '14 days' or p_when > now() + interval '400 days' then
    raise exception 'That date doesn''t look right. Pick the day the delivery happens.';
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'Keep the note to 500 letters.'; end if;

  if p_loadout is not null then
    v := delivery_scheduler_check(p_loadout);
    if v.kind not in ('delivery', 'dock') then
      raise exception 'That''s a % — pickups have no date. To make it a delivery, cancel it and schedule a delivery.', lower(trip_kind_name(v.kind));
    end if;
    if v.completed_at is not null then raise exception 'That delivery is already done, so it can''t be moved.'; end if;
    update loadouts set scheduled_for = p_when, schedule_note = nullif(trim(p_note), ''), kind = coalesce(v_kind, kind),
                        scheduled_by = coalesce(scheduled_by, auth.uid()), scheduled_by_name = coalesce(scheduled_by_name, my_name()),
                        scheduled_at = coalesce(scheduled_at, now())
     where id = v.id returning * into v;
    return jsonb_build_object('ok', true, 'id', v.id, 'client_id', v.client_id,
      'summary', format('%s: %s set for %s.', (select project_id from jobs where id = v.job_id), lower(trip_kind_name(v.kind)), local_when(p_when)));
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
  values (v_cid, v_job.id, v_job.is_test, auth.uid(), my_name(), coalesce(v_kind, 'delivery'), true,
          p_when, auth.uid(), my_name(), now(), nullif(trim(p_note), ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid,
    'summary', format('%s: %s scheduled for %s.', v_job.project_id, lower(trip_kind_name(coalesce(v_kind, 'delivery'))), local_when(p_when)));
exception when unique_violation then
  select id into v_id from loadouts where client_id = v_cid;
  return jsonb_build_object('ok', true, 'id', v_id, 'client_id', v_cid, 'already', true, 'summary', 'Already scheduled.');
end $$;
revoke all on function schedule_delivery(uuid, timestamptz, text, uuid, uuid, text) from public, anon;
grant execute on function schedule_delivery(uuid, timestamptz, text, uuid, uuid, text) to authenticated;

-- the rest: the same as before, with dock to dock treated like white glove

CREATE OR REPLACE FUNCTION public.delivery_scheduler_check(p_loadout uuid)
 RETURNS loadouts
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if v.kind not in ('delivery', 'dock') and not v.pickup_steps then raise exception 'That load-out is an old-style shipment, not a delivery.'; end if;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.add_delivery_photo(p_client_id uuid, p_loadout uuid, p_stage text, p_sheet integer DEFAULT NULL::integer, p_piece integer DEFAULT NULL::integer, p_truck integer DEFAULT NULL::integer, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_accuracy double precision DEFAULT NULL::double precision, p_shot_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_width integer DEFAULT NULL::integer, p_height integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if v.kind not in ('delivery', 'dock') then raise exception 'Truck and site photos are for deliveries. This load-out is a shipment.'; end if;
  if v.completed_at is not null and v.completed_at < now() - interval '1 day' then
    raise exception 'That delivery was finished on %. The photo wasn''t added.', local_when(v.completed_at);
  end if;
  if p_stage = 'dock' then
    if p_truck is null or p_truck < 1 or p_truck > 20 then raise exception 'Trucks are numbered 1 to 20.'; end if;
    if p_sheet is not null or p_piece is not null then raise exception 'A truck photo isn''t of one sheet.'; end if;
  elsif p_stage = 'site' then
    if p_truck is not null then raise exception 'A site photo is of a table, not a truck.'; end if;
    if p_sheet is null and p_piece is null and v.kind = 'dock' then
      null;   -- dock to dock (trip_types.sql): a photo of the drop at their dock, not of one table
    else
    if p_sheet is null or p_piece is null then raise exception 'Say which sheet and table this is.'; end if;
    select s.qty into v_qty from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
     where w.job_id = v.job_id and s.sheet_number = p_sheet;
    if v_qty is null then raise exception 'Sheet % isn''t on this job''s work order.', p_sheet; end if;
    if p_piece < 1 or p_piece > v_qty then
      raise exception 'Sheet % has % table%, so there''s no table %.', p_sheet, v_qty, case when v_qty = 1 then '' else 's' end, p_piece;
    end if;
    end if;
  else
    raise exception 'A delivery photo is of the truck (dock) or a table at the site.';
  end if;

  v_res := add_photo(p_client_id, 'loadout', v.id, p_sheet, case when p_stage = 'dock' then 'Truck ' || p_truck when p_sheet is null then 'At their dock' end, p_width, p_height);
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
end $function$;

CREATE OR REPLACE FUNCTION public.complete_delivery(p_client_id uuid, p_loadout uuid, p_signed_name text DEFAULT NULL::text, p_customer_note text DEFAULT NULL::text, p_no_sign_reason text DEFAULT NULL::text, p_no_sign_note text DEFAULT NULL::text, p_signed_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_accuracy double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if v.kind not in ('delivery', 'dock') then raise exception 'Only a delivery is signed for. This load-out is a shipment.'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.void_loadout(p_loadout uuid, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      case when v.kind in ('delivery', 'dock') then 'delivery was already delivered' else 'pickup was already picked up' end, local_when(v.completed_at);
  end if;
  if v_set_up and not can_schedule_deliveries() then
    raise exception 'This % was set up by %, so it''s cancelled on the Deliveries page, not here. A wrong photo can be marked entered by mistake on its own.',
      case when v.kind in ('delivery', 'dock') then 'delivery' else 'pickup' end,
      coalesce(v.scheduled_by_name, 'the delivery manager') using errcode = 'insufficient_privilege';
  end if;
  if not (v.started_by = auth.uid() or office_ok() or (v_set_up and can_schedule_deliveries())) then
    raise exception 'Only the person who started it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  update loadouts set voided_at = now(), voided_by_name = my_name(),
                      void_reason = coalesce(nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = v.id;
  return 'Marked as entered by mistake. It''s kept in history, with its photos.';
end $function$;

CREATE OR REPLACE FUNCTION public.restore_delivery(p_loadout uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if not ((v.kind in ('delivery', 'dock') and v.scheduled_for is not null) or (v.kind not in ('delivery', 'dock') and v.ready_at is not null)) then
    raise exception 'Only a delivery or pickup set up on the Deliveries page can be put back here.';
  end if;
  select project_id into v_pid from jobs where id = v.job_id;
  if v.voided_at is null then                                            -- a resend, or already back
    return jsonb_build_object('ok', true, 'summary',
      case when v.kind in ('delivery', 'dock') then format('The %s delivery of %s is on the list.', local_when(v.scheduled_for), v_pid)
           else format('%s is on Ready for pickup.', v_pid) end);
  end if;
  update loadouts
     set void_history = void_history || jsonb_build_array(jsonb_build_object(
           'voided_at', v.voided_at, 'voided_by_name', v.voided_by_name, 'void_reason', v.void_reason,
           'restored_at', now(), 'restored_by_name', my_name())),
         voided_at = null, voided_by_name = null, void_reason = null
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    case when v.kind not in ('delivery', 'dock') then format('%s is back on Ready for pickup, on Delivery''s phone too.', v_pid)
         else format('The %s delivery of %s is back, on Delivery''s phone too.%s', local_when(v.scheduled_for), v_pid,
                     case when v.scheduled_for < now() then ' Its date has passed: change it if the delivery is still to come.' else '' end) end);
end $function$;

CREATE OR REPLACE FUNCTION public.tv_snapshot(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  tbl as (
    select o.*, (o.delivery_date - v_today) as days,
           (select case max(case level when 'critical' then 3 when 'priority' then 2 else 1 end)
                   when 3 then 'critical' when 2 then 'priority' when 1 then 'watch' end
              from open_flags f where f.job_id = o.job_id) as flag
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
    'kpis', jsonb_build_object(
       'jobs',  (select count(*) from on_floor),
       'left',  (select coalesce(sum(left_n), 0) from on_floor),
       'ready', (select coalesce(sum(ready_n), 0) from per_dept),
       'due14', (select count(*) from on_floor where delivery_date - v_today <= 14)),
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'table', coalesce((select jsonb_agg(jsonb_build_object(
                 'project_id', t.project_id, 'job_name', t.job_name, 'delivery_date', t.delivery_date, 'days', t.days,
                 'flag', t.flag,
                 'depts', (select jsonb_agg(jsonb_build_object('key', l.key,
                                   'done', coalesce((select sum(qty_done) from r where r.job_id = t.job_id and r.department = l.key), 0),
                                   'total', coalesce((select sum(qty_required) from r where r.job_id = t.job_id and r.department = l.key), 0))
                                   order by l.sort_order) from live l))
               order by t.delivery_date nulls last, t.project_id) from tbl t), '[]'::jsonb),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;

  -- ---- added by tv_pace.sql: everything above is unchanged, so an older TV page still works ----

  -- pace: this week so far, and a usual week = the average of the last 4 finished weeks
  -- (the same numbers as the Pace page's 4-week view: tablet counts only, never test jobs)
  v_week := pace_week(now());
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0
                 else least(4, greatest((v_week - greatest(v_first, v_week - 28)) / 7, 0)) end;

  v_out := v_out || jsonb_build_object(
    'version', 2,
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

    -- work stopped: open issues ticked "work stopped", real jobs, live departments
    'stopped', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', j.project_id, 'job_name', j.name, 'sheet_number', p.sheet_number,
                                          'department', d.name, 'body', left(p.body, 200)) order by p.raised_at)
        from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
       where p.status = 'open' and p.work_stopped and not p.is_test and not j.is_test and j.is_active
         and d.is_live and not d.log_only), '[]'::jsonb),

    -- going out: white glove trips in the next 7 days, pickups waiting to be collected, and today's finished trips
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
               limit 12) t), '[]'::jsonb)
  );
  return v_out;
end $function$;

create or replace view v_deliveries with (security_invoker = true) as
SELECT l.id,
    l.client_id,
    l.job_id,
    j.project_id,
    j.name AS job_name,
    j.phase,
    j.delivery_date,
    l.is_test,
    l.scheduled_for,
    l.schedule_note,
    l.scheduled_by_name,
    l.scheduled_at,
    l.started_at,
    l.started_by_name,
    l.finished_at,
    l.finished_by_name,
    l.completed_at,
    l.completed_by_name,
    l.signed_name,
    l.signed_at,
    l.customer_note,
    l.no_sign_reason,
    l.no_sign_note,
    l.complete_lat,
    l.complete_lng,
    l.complete_accuracy,
    l.downloaded_at,
    l.downloaded_by_name,
    l.completed_at IS NOT NULL AS is_done,
    ( SELECT jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes, 'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at IS NULL) AS jsonb_build_object
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.kind = 'ticket'::text AND d.retired_at IS NULL
          ORDER BY d.added_at DESC
         LIMIT 1) AS ticket,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes, 'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at IS NULL) ORDER BY d.added_at, d.id) AS jsonb_agg
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.kind = 'site_file'::text AND d.retired_at IS NULL), '[]'::jsonb) AS files,
    ( SELECT d.storage_path
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.kind = 'signature'::text
          ORDER BY d.added_at DESC
         LIMIT 1) AS signature_path,
    ( SELECT COALESCE(sum(s.qty), 0::bigint)::integer AS "coalesce"
           FROM sheets s
             JOIN work_orders w ON w.id = s.work_order_id AND w.is_current
          WHERE w.job_id = l.job_id) AS pieces_total,
    ( SELECT count(DISTINCT (p.sheet_number || ':'::text) || p.piece)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.stage = 'site'::text) AS site_photographed,
    ( SELECT count(*)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.truck IS NOT NULL) AS truck_photos,
    l.kind,
    l.ready_at,
    l.carrier,
    l.tracking,
    ( SELECT count(DISTINCT (p.sheet_number || ':'::text) || COALESCE(p.piece, 1))::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.sheet_number IS NOT NULL AND p.stage IS NULL) AS tables_photographed,
    ( SELECT count(DISTINCT p.pallet)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.pallet IS NOT NULL) AS pallets_photographed,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', p.id, 'path', p.storage_path, 'shot_at', p.shot_at, 'in_cloud', p.file_removed_at IS NULL) ORDER BY p.taken_at, p.id) AS jsonb_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.stage = 'bol'::text), '[]'::jsonb) AS bol_photos
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
  WHERE l.voided_at IS NULL AND (l.kind in ('delivery', 'dock') AND (l.scheduled_for IS NOT NULL OR l.completed_at IS NOT NULL) OR l.kind not in ('delivery', 'dock') AND l.pickup_steps AND (l.ready_at IS NOT NULL OR l.completed_at IS NOT NULL));

create or replace view v_filing with (security_invoker = true) as
WITH sh AS (
         SELECT w.job_id,
            s.sheet_number,
            s.qty,
            COALESCE(NULLIF(TRIM(BOTH '-'::text FROM regexp_replace(TRIM(BOTH FROM COALESCE(s.item_code, ''::text)), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Sheet-'::text || lpad(s.sheet_number::text, 2, '0'::text)) AS item
           FROM work_orders w
             JOIN sheets s ON s.work_order_id = w.id
          WHERE w.is_current
        ), sh2 AS (
         SELECT sh.job_id,
            sh.sheet_number,
            sh.qty,
            sh.item,
            COALESCE(sum(sh.qty) OVER (PARTITION BY sh.job_id, sh.item ORDER BY sh.sheet_number ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::bigint)::integer AS unit_offset
           FROM sh
        ), ph AS (
         SELECT p.id,
            p.job_id,
            j.project_id,
            j.name AS job_name,
            p.is_test,
            p.storage_path,
            p.sheet_number,
            p.kind,
            p.stage,
            p.truck,
            p.pallet,
            p.note,
            p.taken_at AS at,
            p.taken_by_name AS by_name,
            p.voided_at IS NOT NULL AS mistake,
            p.department,
            p.loadout_id,
            p.lat,
            p.lng,
            p.gps_accuracy,
            p.shot_at,
            p.archive_batch,
            p.file_removed_at,
            p.bytes,
                CASE
                    WHEN p.sheet_number IS NOT NULL THEN COALESCE(s.item, 'Sheet-'::text || lpad(p.sheet_number::text, 2, '0'::text))
                    WHEN p.truck IS NOT NULL THEN 'Truck'::text
                    WHEN p.pallet IS NOT NULL THEN 'Pallets'::text
                    WHEN p.stage = 'bol'::text THEN 'BOL'::text
                    WHEN p.kind = 'loadout'::text THEN 'Other'::text
                    ELSE 'Job'::text
                END AS folder,
                CASE
                    WHEN p.kind = 'loadout'::text AND p.sheet_number IS NOT NULL THEN COALESCE(s.unit_offset, 0) + COALESCE(p.piece, 1)
                    ELSE NULL::integer
                END AS table_no,
                CASE p.kind
                    WHEN 'defect'::text THEN 'Defect'::text
                    WHEN 'problem'::text THEN 'Problem'::text
                    ELSE
                    CASE
                        WHEN p.truck IS NOT NULL THEN 'Truck'::text
                        WHEN p.pallet IS NOT NULL THEN 'Pallet'::text
                        WHEN p.stage = 'bol'::text THEN 'BOL'::text
                        WHEN p.stage = 'site'::text THEN 'Delivery Picture'::text
                        WHEN l.kind = 'shipping'::text THEN 'Before Wrap'::text
                        WHEN l.kind = 'customer_pickup'::text THEN 'Pickup Picture'::text
                        ELSE 'Load-out Picture'::text
                    END
                END AS what
           FROM photos p
             JOIN jobs j ON j.id = p.job_id
             LEFT JOIN sh2 s ON s.job_id = p.job_id AND s.sheet_number = p.sheet_number
             LEFT JOIN loadouts l ON l.id = p.loadout_id
        ), ph2 AS (
         SELECT ph.id,
            ph.job_id,
            ph.project_id,
            ph.job_name,
            ph.is_test,
            ph.storage_path,
            ph.sheet_number,
            ph.kind,
            ph.stage,
            ph.truck,
            ph.pallet,
            ph.note,
            ph.at,
            ph.by_name,
            ph.mistake,
            ph.department,
            ph.loadout_id,
            ph.lat,
            ph.lng,
            ph.gps_accuracy,
            ph.shot_at,
            ph.archive_batch,
            ph.file_removed_at,
            ph.bytes,
            ph.folder,
            ph.table_no,
            ph.what,
                CASE
                    WHEN ph.stage = 'bol'::text THEN NULL::text
                    WHEN ph.truck IS NOT NULL THEN 'Truck-'::text || ph.truck
                    WHEN ph.pallet IS NOT NULL THEN 'Pallet-'::text || ph.pallet
                    WHEN ph.table_no IS NOT NULL THEN (((ph.folder || '-'::text) || ph.table_no) || ' '::text) || ph.what
                    WHEN ph.kind = 'loadout'::text THEN "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(COALESCE(ph.note, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Item'::text), 60)
                    ELSE NULL::text
                END AS fixed,
            row_number() OVER (PARTITION BY ph.job_id, ph.folder, ph.what, (ph.kind <> 'loadout'::text) ORDER BY ph.at, ph.id) AS counted
           FROM ph
        ), ph3 AS (
         SELECT ph2.id,
            ph2.job_id,
            ph2.project_id,
            ph2.job_name,
            ph2.is_test,
            ph2.storage_path,
            ph2.sheet_number,
            ph2.kind,
            ph2.stage,
            ph2.truck,
            ph2.pallet,
            ph2.note,
            ph2.at,
            ph2.by_name,
            ph2.mistake,
            ph2.department,
            ph2.loadout_id,
            ph2.lat,
            ph2.lng,
            ph2.gps_accuracy,
            ph2.shot_at,
            ph2.archive_batch,
            ph2.file_removed_at,
            ph2.bytes,
            ph2.folder,
            ph2.table_no,
            ph2.what,
            ph2.fixed,
            ph2.counted,
                CASE
                    WHEN ph2.stage = 'bol'::text THEN 'BOL-'::text || ph2.counted
                    ELSE COALESCE(ph2.fixed, (((ph2.folder || ' '::text) || ph2.what) || ' '::text) || ph2.counted)
                END AS base
           FROM ph2
        ), ph4 AS (
         SELECT ph3.id,
            ph3.job_id,
            ph3.project_id,
            ph3.job_name,
            ph3.is_test,
            ph3.storage_path,
            ph3.sheet_number,
            ph3.kind,
            ph3.stage,
            ph3.truck,
            ph3.pallet,
            ph3.note,
            ph3.at,
            ph3.by_name,
            ph3.mistake,
            ph3.department,
            ph3.loadout_id,
            ph3.lat,
            ph3.lng,
            ph3.gps_accuracy,
            ph3.shot_at,
            ph3.archive_batch,
            ph3.file_removed_at,
            ph3.bytes,
            ph3.folder,
            ph3.table_no,
            ph3.what,
            ph3.fixed,
            ph3.counted,
            ph3.base,
            row_number() OVER (PARTITION BY ph3.job_id, ph3.folder, ph3.base ORDER BY ph3.at, ph3.id) AS dup
           FROM ph3
        ), trips0 AS (
         SELECT l.id AS loadout_id,
            l.job_id,
                CASE
                    WHEN l.kind = 'dock'::text THEN 'Dock to dock '::text
                    WHEN l.kind in ('delivery', 'dock') THEN 'Delivery '::text
                    ELSE 'Pickup '::text
                END AS label,
                CASE
                    WHEN l.kind in ('delivery', 'dock') THEN COALESCE(l.scheduled_for, l.started_at)
                    ELSE COALESCE(l.completed_at, l.ready_at, l.started_at)
                END AS day_at
           FROM loadouts l
        ), trips AS (
         SELECT t.loadout_id,
            t.job_id,
            t.label || to_char((t.day_at AT TIME ZONE 'America/Indiana/Indianapolis'::text), 'YYYY-MM-DD'::text) AS day,
            row_number() OVER (PARTITION BY t.job_id, t.label, ((t.day_at AT TIME ZONE 'America/Indiana/Indianapolis'::text)::date) ORDER BY t.day_at, t.loadout_id) AS n
           FROM trips0 t
        ), docs AS (
         SELECT d.id,
            d.job_id,
            j.project_id,
            j.name AS job_name,
            d.is_test,
            d.storage_path,
            d.kind,
            d.added_at AS at,
            d.added_by_name AS by_name,
            d.loadout_id,
            d.archive_batch,
            d.file_removed_at,
            d.bytes,
            d.file_name,
            t.day ||
                CASE
                    WHEN t.n > 1 THEN (' ('::text || t.n) || ')'::text
                    ELSE ''::text
                END AS folder,
            lower(COALESCE("substring"(d.storage_path, '\.([a-z]+)$'::text), 'pdf'::text)) AS ext,
                CASE d.kind
                    WHEN 'ticket'::text THEN 'Delivery ticket'::text ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (replaced)'::text
                        ELSE ''::text
                    END
                    WHEN 'signature'::text THEN 'Signature'::text
                    ELSE "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(regexp_replace(d.file_name, '\.[A-Za-z0-9]{1,5}$'::text, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Site file'::text), 80) ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (taken off)'::text
                        ELSE ''::text
                    END
                END AS base
           FROM delivery_docs d
             JOIN jobs j ON j.id = d.job_id
             JOIN trips t ON t.loadout_id = d.loadout_id
        ), docs2 AS (
         SELECT docs.id,
            docs.job_id,
            docs.project_id,
            docs.job_name,
            docs.is_test,
            docs.storage_path,
            docs.kind,
            docs.at,
            docs.by_name,
            docs.loadout_id,
            docs.archive_batch,
            docs.file_removed_at,
            docs.bytes,
            docs.file_name,
            docs.folder,
            docs.ext,
            docs.base,
            row_number() OVER (PARTITION BY docs.job_id, docs.folder, docs.base, docs.ext ORDER BY docs.at, docs.id) AS dup
           FROM docs
        )
 SELECT 'photo'::text AS source,
    p.id,
    p.job_id,
    p.project_id,
    p.job_name,
    p.is_test,
    'photos'::text AS bucket,
    p.storage_path,
    p.folder,
    ((p.base ||
        CASE
            WHEN p.dup > 1 THEN (' ('::text || p.dup) || ')'::text
            ELSE ''::text
        END) ||
        CASE
            WHEN p.mistake THEN ' (entered by mistake)'::text
            ELSE ''::text
        END) || '.jpg'::text AS file_name,
    p.sheet_number,
    p.table_no,
    p.kind,
    p.what,
    p.note,
    p.at,
    p.by_name,
    p.mistake,
    p.department,
    p.lat,
    p.lng,
    p.gps_accuracy,
    p.shot_at,
    p.loadout_id,
    p.archive_batch,
    p.file_removed_at IS NULL AS in_cloud,
    p.bytes
   FROM ph4 p
UNION ALL
 SELECT 'doc'::text AS source,
    d.id,
    d.job_id,
    d.project_id,
    d.job_name,
    d.is_test,
    'deliveries'::text AS bucket,
    d.storage_path,
    d.folder,
    ((d.base ||
        CASE
            WHEN d.dup > 1 THEN (' ('::text || d.dup) || ')'::text
            ELSE ''::text
        END) || '.'::text) || d.ext AS file_name,
    NULL::integer AS sheet_number,
    NULL::integer AS table_no,
    d.kind,
        CASE d.kind
            WHEN 'ticket'::text THEN 'Delivery ticket'::text
            WHEN 'signature'::text THEN 'Customer signature'::text
            ELSE 'Site file'::text
        END AS what,
        CASE
            WHEN d.kind = 'site_file'::text THEN d.file_name
            ELSE NULL::text
        END AS note,
    d.at,
    d.by_name,
    false AS mistake,
    'delivery'::text AS department,
    NULL::double precision AS lat,
    NULL::double precision AS lng,
    NULL::double precision AS gps_accuracy,
    NULL::timestamp with time zone AS shot_at,
    d.loadout_id,
    d.archive_batch,
    d.file_removed_at IS NULL AS in_cloud,
    d.bytes
   FROM docs2 d
UNION ALL
 SELECT 'signed'::text AS source,
    l.id,
    l.job_id,
    j.project_id,
    j.name AS job_name,
    l.is_test,
    NULL::text AS bucket,
    NULL::text AS storage_path,
    t.day ||
        CASE
            WHEN t.n > 1 THEN (' ('::text || t.n) || ')'::text
            ELSE ''::text
        END AS folder,
    'Signed ticket.pdf'::text AS file_name,
    NULL::integer AS sheet_number,
    NULL::integer AS table_no,
    'signed_ticket'::text AS kind,
        CASE
            WHEN l.signed_name IS NOT NULL THEN 'Signed by '::text || l.signed_name
            ELSE 'Not signed: '::text || COALESCE(l.no_sign_reason, ''::text)
        END AS what,
    l.customer_note AS note,
    l.completed_at AS at,
    l.completed_by_name AS by_name,
    false AS mistake,
    'delivery'::text AS department,
    l.complete_lat AS lat,
    l.complete_lng AS lng,
    l.complete_accuracy AS gps_accuracy,
    l.signed_at AS shot_at,
    l.id AS loadout_id,
    ( SELECT min(d.archive_batch) AS min
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.archive_batch IS NOT NULL) AS archive_batch,
    NOT (EXISTS ( SELECT 1
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.file_removed_at IS NOT NULL)) AS in_cloud,
    NULL::bigint AS bytes
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
     JOIN trips t ON t.loadout_id = l.id
  WHERE l.completed_at IS NOT NULL AND l.voided_at IS NULL AND l.kind <> 'shipping'::text;

create or replace view v_cancelled_deliveries with (security_invoker = true) as
SELECT l.id,
    l.client_id,
    l.job_id,
    j.project_id,
    j.name AS job_name,
    l.is_test,
    l.scheduled_for,
    l.schedule_note,
    l.scheduled_by_name,
    l.voided_at,
    l.voided_by_name,
    l.void_reason,
    (EXISTS ( SELECT 1
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.kind = 'ticket'::text AND d.retired_at IS NULL)) AS has_ticket,
    ( SELECT count(*)::integer AS count
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.kind = 'site_file'::text AND d.retired_at IS NULL) AS site_files,
    l.kind,
    l.ready_at
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
  WHERE l.voided_at IS NOT NULL AND l.voided_at > (now() - '60 days'::interval) AND l.completed_at IS NULL AND (l.kind in ('delivery', 'dock') AND l.scheduled_for IS NOT NULL OR l.kind not in ('delivery', 'dock') AND l.ready_at IS NOT NULL) AND sees_deliveries();

-- check_deliveries (deliveries_v2.sql), word for word, except that it accepts schedule_delivery with p_kind
CREATE OR REPLACE FUNCTION public.check_deliveries()
 RETURNS TABLE(step integer, check_name text, result text, if_it_failed text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$   -- not security definer: it switches role to test as each login
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
          and (to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid)') is not null
               or to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid,text)') is not null)   -- trip_types.sql adds p_kind
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
$function$;

-- ---------------------------------------------------------------------
-- 2. Tasks
-- ---------------------------------------------------------------------
create table if not exists delivery_tasks (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null unique,                    -- made on Julia's computer; a resend can't double it
  job_id            uuid references jobs(id),                -- optional: any job, even a finished one; can be added later
  for_text          text,                                    -- what it's for, when there's no PROJ (or as well)
  what              text not null,                           -- what to do
  where_text        text,
  scheduled_for     timestamptz not null,
  is_test           boolean not null default false,
  scheduled_by      uuid references profiles(id),
  scheduled_by_name text,
  scheduled_at      timestamptz not null default now(),
  changed_at        timestamptz,
  done_at           timestamptz,
  done_by           uuid references profiles(id),
  done_by_name      text,
  done_client_id    uuid unique,
  done_note         text,
  done_lat          double precision,
  done_lng          double precision,
  voided_at         timestamptz,
  voided_by_name    text,
  void_reason       text,
  void_history      jsonb not null default '[]'::jsonb,
  constraint delivery_tasks_sizes check (length(btrim(what)) between 1 and 500 and length(coalesce(for_text, '')) <= 200
                                         and length(coalesce(where_text, '')) <= 300 and length(coalesce(done_note, '')) <= 1000)
);
create index if not exists delivery_tasks_when on delivery_tasks (scheduled_for);

create table if not exists task_photos (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null unique,
  task_id       uuid not null references delivery_tasks(id),
  storage_path  text not null unique,                        -- photos bucket: TASKS/<client_id>.jpg, TEST-TASKS/… for test logins
  is_test       boolean not null,
  taken_by      uuid references profiles(id),
  taken_by_name text,
  taken_at      timestamptz not null default now(),
  shot_at       timestamptz,
  lat           double precision,
  lng           double precision,
  gps_accuracy  double precision
);

alter table delivery_tasks enable row level security;
alter table task_photos enable row level security;
revoke all on delivery_tasks, task_photos from anon, authenticated;
grant select on delivery_tasks, task_photos to authenticated;
drop policy if exists read_delivery_tasks on delivery_tasks;
create policy read_delivery_tasks on delivery_tasks for select to authenticated using (sees_deliveries() and sees_lane(is_test));
drop policy if exists read_task_photos on task_photos;
create policy read_task_photos on task_photos for select to authenticated using (sees_deliveries() and sees_lane(is_test));

-- schedule a task, or change one (p_task): when, what, where, the job, what it's for
create or replace function schedule_task(p_client_id uuid, p_when timestamptz, p_what text, p_where text default null,
                                         p_job uuid default null, p_for text default null, p_task uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v delivery_tasks; v_job jobs; v_test boolean; v_id uuid;
        v_what text := nullif(btrim(coalesce(p_what, '')), ''); v_where text := nullif(btrim(coalesce(p_where, '')), '');
        v_for text := nullif(btrim(coalesce(p_for, '')), '');
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can schedule tasks.' using errcode = 'insufficient_privilege';
  end if;
  if p_task is null and p_client_id is not null then
    select id into v_id from delivery_tasks where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already scheduled.'); end if;
  end if;
  if v_what is null then raise exception 'Say what the task is.'; end if;
  if length(v_what) > 500 then raise exception 'Keep what the task is to 500 letters.'; end if;
  if length(coalesce(v_where, '')) > 300 then raise exception 'Keep where to 300 letters.'; end if;
  if length(coalesce(v_for, '')) > 200 then raise exception 'Keep what it''s for to 200 letters.'; end if;
  if p_when is null then raise exception 'Pick the date and time of the task.'; end if;
  if p_when < now() - interval '14 days' or p_when > now() + interval '400 days' then
    raise exception 'That date doesn''t look right. Pick the day the task happens.';
  end if;
  if p_job is not null then
    select * into v_job from jobs where id = p_job;
    if v_job.id is null then raise exception 'That job isn''t there.'; end if;
    if v_job.is_test and not (is_manager() or am_test()) then
      raise exception '% is a test job. Only a manager or the Test Supervisor uses test jobs.', v_job.project_id using errcode = 'insufficient_privilege';
    end if;
    if not v_job.is_test and am_test() then raise exception 'A test login can only use test jobs.' using errcode = 'insufficient_privilege'; end if;
    v_test := v_job.is_test;
  else
    v_test := am_test();
  end if;

  if p_task is not null then
    select * into v from delivery_tasks where id = p_task or client_id = p_task;
    if v.id is null or not sees_lane(v.is_test) then raise exception 'That task isn''t there.'; end if;
    if v.voided_at is not null then raise exception 'That task was cancelled. Put it back first.'; end if;
    if v.done_at is not null then raise exception 'That task is already done, so it can''t be changed.'; end if;
    if v_test <> v.is_test then raise exception 'A test task stays a test task, and a real one stays real.'; end if;
    update delivery_tasks set scheduled_for = p_when, what = v_what, where_text = v_where, job_id = p_job, for_text = v_for, changed_at = now()
     where id = v.id;
    return jsonb_build_object('ok', true, 'id', v.id, 'summary', format('Task changed: %s, %s.', left(v_what, 60), local_when(p_when)));
  end if;

  if p_client_id is null then raise exception 'This task has no id. Try again.'; end if;
  insert into delivery_tasks (client_id, job_id, for_text, what, where_text, scheduled_for, is_test, scheduled_by, scheduled_by_name)
  values (p_client_id, p_job, v_for, v_what, v_where, p_when, v_test, auth.uid(), my_name())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Task scheduled for %s: %s.', local_when(p_when), left(v_what, 60)));
exception when unique_violation then
  select id into v_id from delivery_tasks where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already scheduled.');
end $$;
revoke all on function schedule_task(uuid, timestamptz, text, text, uuid, text, uuid) from public, anon;
grant execute on function schedule_task(uuid, timestamptz, text, text, uuid, text, uuid) to authenticated;

-- cancel a task (kept, with why), or put it back
create or replace function cancel_task(p_task uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v delivery_tasks;
begin
  if not can_schedule_deliveries() then raise exception 'Only the delivery manager or a manager can cancel tasks.' using errcode = 'insufficient_privilege'; end if;
  select * into v from delivery_tasks where id = p_task or client_id = p_task;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That task isn''t there.'; end if;
  if v.done_at is not null then raise exception 'That task was already done by % (%).', coalesce(v.done_by_name, 'someone'), local_when(v.done_at); end if;
  if v.voided_at is not null then return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already cancelled.'); end if;
  update delivery_tasks set voided_at = now(), voided_by_name = my_name(), void_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300) where id = v.id;
  return jsonb_build_object('ok', true, 'summary', format('Task cancelled: %s.', left(v.what, 60)));
end $$;
revoke all on function cancel_task(uuid, text) from public, anon;
grant execute on function cancel_task(uuid, text) to authenticated;

create or replace function restore_task(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v delivery_tasks;
begin
  if not can_schedule_deliveries() then raise exception 'Only the delivery manager or a manager can put tasks back.' using errcode = 'insufficient_privilege'; end if;
  select * into v from delivery_tasks where id = p_task or client_id = p_task;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That task isn''t there.'; end if;
  if v.voided_at is null then return jsonb_build_object('ok', true, 'already', true, 'summary', 'That task is already on the list.'); end if;
  update delivery_tasks set void_history = void_history || jsonb_build_array(jsonb_build_object('voided_at', voided_at, 'by', voided_by_name, 'reason', void_reason, 'restored_at', now(), 'restored_by', my_name())),
                            voided_at = null, voided_by_name = null, void_reason = null
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary', format('Task back on the list: %s.', left(v.what, 60)));
end $$;
revoke all on function restore_task(uuid) from public, anon;
grant execute on function restore_task(uuid) to authenticated;

-- who works a task: Delivery, the scheduler, a manager — in their own lane
create or replace function task_entry_check(p_task uuid) returns delivery_tasks
language plpgsql stable security definer set search_path = public as $$
declare v delivery_tasks;
begin
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  if not sees_deliveries() then raise exception 'This login can''t work Delivery''s tasks.' using errcode = 'insufficient_privilege'; end if;
  select * into v from delivery_tasks where id = p_task or client_id = p_task;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That task isn''t there.'; end if;
  if v.is_test <> am_test() and not is_manager() then raise exception 'That task is in the other lane (test or real).' using errcode = 'insufficient_privilege'; end if;
  return v;
end $$;
revoke all on function task_entry_check(uuid) from public, anon, authenticated;

-- done: a note and GPS optional; sent twice, kept once
create or replace function complete_task(p_client_id uuid, p_task uuid, p_note text default null,
                                         p_lat double precision default null, p_lng double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v delivery_tasks; v_ok_gps boolean := p_lat between -90 and 90 and p_lng between -180 and 180;
begin
  if p_client_id is null then raise exception 'This has no id. Try again.'; end if;
  if exists (select 1 from delivery_tasks where done_client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked done.');
  end if;
  v := task_entry_check(p_task);
  if v.voided_at is not null then raise exception 'That task was cancelled, so it wasn''t marked done.'; end if;
  if v.done_at is not null then raise exception 'That task was already done by % (%).', coalesce(v.done_by_name, 'someone'), local_when(v.done_at); end if;
  if length(coalesce(p_note, '')) > 1000 then raise exception 'Keep the note to 1,000 letters.'; end if;
  update delivery_tasks set done_at = now(), done_by = auth.uid(), done_by_name = my_name(), done_client_id = p_client_id,
                            done_note = nullif(btrim(coalesce(p_note, '')), ''),
                            done_lat = case when v_ok_gps then p_lat end, done_lng = case when v_ok_gps then p_lng end
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary', format('Task done: %s.', left(v.what, 60)));
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked done.');
end $$;
revoke all on function complete_task(uuid, uuid, text, double precision, double precision) from public, anon;
grant execute on function complete_task(uuid, uuid, text, double precision, double precision) to authenticated;

-- a photo on a task: the file goes up first (photos bucket, TASKS/ or TEST-TASKS/), then this records it
create or replace function add_task_photo(p_client_id uuid, p_task uuid, p_shot_at timestamptz default null,
                                          p_lat double precision default null, p_lng double precision default null,
                                          p_accuracy double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v delivery_tasks; v_path text; v_ok_gps boolean := p_lat between -90 and 90 and p_lng between -180 and 180;
begin
  if p_client_id is null then raise exception 'This photo has no id. Try again.'; end if;
  if exists (select 1 from task_photos where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Photo already saved.');
  end if;
  v := task_entry_check(p_task);
  if v.voided_at is not null then raise exception 'That task was cancelled.'; end if;
  if v.done_at is not null and v.done_at < now() - interval '3 days' then raise exception 'That task was done more than three days ago.'; end if;
  v_path := case when v.is_test then 'TEST-TASKS' else 'TASKS' end || '/' || p_client_id || '.jpg';
  if not exists (select 1 from storage.objects o where o.bucket_id = 'photos' and o.name = v_path) then
    raise exception 'The photo hasn''t arrived yet. It will try again.';
  end if;
  insert into task_photos (client_id, task_id, storage_path, is_test, taken_by, taken_by_name, shot_at, lat, lng, gps_accuracy)
  values (p_client_id, v.id, v_path, v.is_test, auth.uid(), my_name(), least(now(), coalesce(p_shot_at, now())),
          case when v_ok_gps then p_lat end, case when v_ok_gps then p_lng end, case when v_ok_gps and p_accuracy >= 0 then p_accuracy end);
  return jsonb_build_object('ok', true, 'summary', 'Task photo saved.');
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Photo already saved.');
end $$;
revoke all on function add_task_photo(uuid, uuid, timestamptz, double precision, double precision, double precision) from public, anon;
grant execute on function add_task_photo(uuid, uuid, timestamptz, double precision, double precision, double precision) to authenticated;

-- what the pages read: each task with its job (if any) and its photos
create or replace view v_delivery_tasks with (security_invoker = true) as
  select t.id, t.client_id, t.job_id, j.project_id, j.name as job_name, t.for_text, t.what, t.where_text, t.scheduled_for, t.is_test,
         t.scheduled_by_name, t.scheduled_at, t.changed_at, t.done_at, t.done_by_name, t.done_note, t.voided_at, t.voided_by_name, t.void_reason,
         coalesce((select jsonb_agg(jsonb_build_object('path', p.storage_path, 'by', p.taken_by_name, 'at', coalesce(p.shot_at, p.taken_at)) order by p.taken_at)
                     from task_photos p where p.task_id = t.id), '[]'::jsonb) as photos
    from delivery_tasks t left join jobs j on j.id = t.job_id;
grant select on v_delivery_tasks to authenticated;

-- ---------------------------------------------------------------------
-- 3. The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_trip_types()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sch uuid; dlv uuid; oth uuid; tst uuid;
  ja uuid; jf uuid; jt uuid; c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid();
  t3 uuid := gen_random_uuid(); d1 uuid := gen_random_uuid(); p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); p3 uuid := gen_random_uuid();
  r jsonb; n int; m int; ok boolean; msg text; k text; v_lo loadouts; v_t delivery_tasks;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where schedules_deliveries and active and not is_test and role = 'supervisor' limit 1), mgr) into sch;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) limit 1), mgr) into dlv;
  select id into oth from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments)) and not schedules_deliveries limit 1;
  select id into tst from profiles where is_test and active limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999971, 'TTCHECK-A', 'Trip types check - undone automatically', true, 'In Production') returning id into ja;
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999972, 'TTCHECK-F', 'Trip types check - undone automatically', false, 'Complete') returning id into jf;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, is_test) values (null, 'TEST-TTCHECK', 'Trip types check - undone automatically', true, 'In Production', true) returning id into jt;

    -- ---- 1: a dock to dock delivery, scheduled ----------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := schedule_delivery(ja, now() + interval '2 days', 'Check', null, c1, 'dock');
      execute 'reset role';
      select * into v_lo from loadouts where client_id = c1;
      ok := v_lo.kind = 'dock' and v_lo.scheduled_for is not null and v_lo.site_steps; msg := 'Got: ' || coalesce(v_lo.kind, 'nothing') || ' / ' || coalesce(r->>'summary', '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'The scheduler can schedule a dock to dock delivery, with a date and time', ok, msg);

    -- ---- 2: Delivery sees it on its list, as a dated trip -------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_deliveries where client_id = c1 and kind = 'dock' and scheduled_for is not null;
      execute 'reset role';
      ok := n = 1; msg := format('%s rows', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Delivery sees the dock to dock trip on its list, like a white glove delivery', ok, msg);

    -- ---- 3: older pages still schedule white glove; moving keeps the kind; p_kind can switch it ----------------
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform schedule_delivery(p_job => ja, p_when => now() + interval '3 days', p_note => null, p_loadout => null, p_client_id => c2);
      perform schedule_delivery(p_job => ja, p_when => now() + interval '4 days', p_note => 'moved', p_loadout => c1, p_client_id => null);
      execute 'reset role';
      select string_agg(kind, ',' order by client_id = c1) into msg from loadouts where client_id in (c1, c2);
      ok := msg = 'delivery,dock';
      execute 'set local role authenticated';
      perform schedule_delivery(ja, now() + interval '4 days', null, c1, null, 'delivery');
      execute 'reset role';
      select kind into k from loadouts where client_id = c1;
      ok := ok and k = 'delivery'; msg := msg || ' then ' || k;
      execute 'set local role authenticated';
      perform schedule_delivery(ja, now() + interval '4 days', null, c1, null, 'dock');
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A call without a kind (older pages) makes white glove; moving a trip keeps its kind unless told to switch', ok, msg);

    -- ---- 4: Delivery finishes it like a white glove delivery; it can be cancelled and put back -------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', '', true);
      execute 'reset role';
      insert into storage.objects (bucket_id, name, metadata) values ('photos', 'TTCHECK-A/' || p2 || '.jpg', '{"size": 1}');
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(p_client_id => p2, p_loadout => c1, p_stage => 'site', p_sheet => null, p_piece => null, p_truck => null);
      execute 'reset role';
      select count(*) into n from photos where client_id = p2 and stage = 'site' and sheet_number is null and note = 'At their dock';
      execute 'set local role authenticated';
      r := complete_delivery(d1, c1, null, 'left at the dock', 'Nobody on site', null, now(), null, null, null);
      execute 'reset role';
      select * into v_lo from loadouts where client_id = c1;
      ok := v_lo.completed_at is not null and v_lo.no_sign_reason = 'Nobody on site' and n = 1; msg := coalesce(r->>'summary', 'nothing') || format(' · drop photos %s', n);
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform void_loadout(c2, 'Check');
      select count(*) into n from v_cancelled_deliveries where client_id = c2;
      perform restore_delivery(c2);
      select count(*) into m from v_cancelled_deliveries where client_id = c2;
      execute 'reset role';
      ok := ok and n = 1 and m = 0; msg := msg || format(' · cancelled list %s then %s', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Delivery photographs the drop at their dock (no table needed) and completes it like white glove; cancelling and putting back work', ok, msg);

    -- ---- 5: a task with no job, and one on a finished job --------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform schedule_task(t1, now() + interval '1 day', 'Pick up a damaged chair', '12 Main St', null, 'Smith dining set (quote 1123)');
      perform schedule_task(t2, now() + interval '1 day', 'Collect the spare legs', null, jf, null);
      perform schedule_task(t1, now() + interval '1 day', 'Pick up a damaged chair', '12 Main St', null, 'again');   -- resend
      execute 'reset role';
      select count(*) into n from delivery_tasks where client_id in (t1, t2) and not is_test;
      select for_text into msg from delivery_tasks where client_id = t1;
      ok := n = 2 and msg = 'Smith dining set (quote 1123)'; msg := format('%s tasks; for: %s', n, msg);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'The scheduler can schedule a task with no job, or on a finished job; a resend is kept once', ok, msg);

    -- ---- 6: a PROJ added later -------------------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      perform schedule_task(null, now() + interval '2 days', 'Pick up a damaged chair', '12 Main St', ja, 'Smith dining set (quote 1123)', t1);
      execute 'reset role';
      select * into v_t from delivery_tasks where client_id = t1;
      ok := v_t.job_id = ja and v_t.changed_at is not null; msg := case when ok then null else 'The PROJ wasn''t added' end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A PROJ number can be added to a task later', ok, msg);

    -- ---- 7: Delivery sees the tasks, and does one ------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_delivery_tasks where client_id in (t1, t2);
      r := complete_task(p1, t1, 'Chair is in the shop', null, null);
      r := complete_task(p1, t1, 'again', null, null);
      execute 'reset role';
      select * into v_t from delivery_tasks where client_id = t1;
      ok := n = 2 and v_t.done_at is not null and v_t.done_note = 'Chair is in the shop'; msg := format('saw %s; done %s', n, v_t.done_at is not null);
      begin
        execute 'set local role authenticated';
        perform complete_task(gen_random_uuid(), t1, null, null, null);
        execute 'reset role'; ok := false; msg := msg || '; a second Done was accepted';
      exception when others then execute 'reset role'; end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Delivery sees the tasks and marks one done with a note; sent twice it counts once', ok, msg);

    -- ---- 8: a task photo, once the file is there ---------------------------------------------------------------
    begin
      begin
        execute 'set local role authenticated';
        perform add_task_photo(p3, t2, null, null, null, null);
        execute 'reset role'; ok := false; msg := 'A photo was recorded with no file';
      exception when others then execute 'reset role'; ok := true; end;
      insert into storage.objects (bucket_id, name, metadata) values ('photos', 'TASKS/' || p3 || '.jpg', '{"size": 1}');
      execute 'set local role authenticated';
      perform add_task_photo(p3, t2, now(), 39.7, -86.1, 5);
      select jsonb_array_length(photos) into n from v_delivery_tasks where client_id = t2;
      execute 'reset role';
      ok := ok and n = 1; msg := coalesce(msg, format('%s photo', n));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A task photo is kept once its file has arrived, and not before', ok, msg);

    -- ---- 9: who can't -----------------------------------------------------------------------------------
    n := 0; msg := null;
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    if dlv <> mgr and dlv <> sch then
      begin execute 'set local role authenticated'; perform schedule_task(gen_random_uuid(), now() + interval '1 day', 'x');
        execute 'reset role'; msg := 'Delivery scheduled a task';
      exception when others then execute 'reset role'; n := n + 1; end;
    else n := n + 1; end if;
    if oth is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; select count(*) into m from v_delivery_tasks where client_id in (t1, t2);
        execute 'reset role'; if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, format('another department saw %s tasks', m)); end if;
      exception when others then execute 'reset role'; n := n + 1; end;
      begin execute 'set local role authenticated'; perform complete_task(gen_random_uuid(), t2, null, null, null);
        execute 'reset role'; msg := concat_ws(', ', msg, 'another department marked a task done');
      exception when others then execute 'reset role'; n := n + 1; end;
    else n := n + 2; end if;
    begin execute 'set local role authenticated'; update delivery_tasks set what = 'changed' where client_id = t2; get diagnostics m = row_count;
      execute 'reset role'; if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, 'changed a task directly'); end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(9, 'Only the scheduler schedules; other departments neither see nor do tasks; nobody changes the table directly', n = 4, msg);

    -- ---- 10: test lane --------------------------------------------------------------------------------
    if true then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        perform schedule_task(t3, now() + interval '1 day', 'Practice task', null, jt, null);   -- on a test job, so a test task
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into n from v_delivery_tasks where client_id = t3;
        execute 'reset role';
        select is_test into ok from delivery_tasks where client_id = t3;
        ok := ok and (n = 0 or dlv = mgr); msg := format('test task; Delivery saw %s', n);
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(10, 'A task on a test job is a test task, out of sight of the real Delivery login', coalesce(ok, false), msg);
    else
      res := res || check_row(10, 'Test tasks (no test login, so skipped)', true, null);
    end if;

    -- ---- 11: cancel and put back -----------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform cancel_task(t2, 'Check');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; perform complete_task(gen_random_uuid(), t2, null, null, null);
        execute 'reset role'; ok := false; msg := 'A cancelled task was marked done';
      exception when others then execute 'reset role'; ok := true; end;
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform restore_task(t2);
      execute 'reset role';
      select ok and voided_at is null and jsonb_array_length(void_history) = 1 into ok from delivery_tasks where client_id = t2;
      msg := coalesce(msg, case when ok then null else 'It didn''t come back with its history' end);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'A cancelled task can''t be done; putting it back keeps the history', ok, msg);

    -- ---- 12: no login ---------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin execute 'set local role anon'; select count(*) into m from v_delivery_tasks; execute 'reset role';
      if m > 0 then msg := format('read %s tasks', m); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role anon'; perform schedule_task(gen_random_uuid(), now() + interval '1 day', 'x'); execute 'reset role';
      msg := concat_ws(', ', msg, 'scheduled a task');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(12, 'Someone with no login can''t see or schedule tasks', n = 2, coalesce(msg, '') || '. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_trip_types_undo__';
  exception when others then
    if sqlerrm <> '__check_trip_types_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_trip_types() from public, anon, authenticated;

select * from check_trip_types();
