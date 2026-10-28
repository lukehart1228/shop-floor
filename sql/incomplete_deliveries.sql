-- =====================================================================
-- incomplete_deliveries.sql — when not everything goes (26 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 46. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE the new pages go on GitHub. The pages there now keep
-- working with it: nothing they read changes for any trip they know.
--
-- WHAT IT DOES (design: the Incomplete deliveries tab, 26 Oct)
-- When a trip doesn't all go, Delivery still finishes it (signed, or why
-- not), says which tables went and which didn't, and why (Damaged, Site
-- not ready, Wouldn't fit, Customer asked to wait, or Other with a few
-- words). In the same step the database makes a new trip for the rest:
-- same job and kind, only the tables still owed, the ticket and site
-- files going with it. A white glove or dock to dock rest waits for the
-- office to give it a day and time; a pickup's rest goes straight back
-- on Ready for pickup.
-- 1. trip_parts: one row per trip finished part-way: which tables went,
--    which didn't, why, and the rest's trip. part_extras: how many of
--    each extra went on it (absolute numbers), readable by Delivery and
--    managers only, like the extras themselves.
-- 2. complete_trip_part(): finishes the trip part-way and makes the
--    rest's trip, in one step, so a phone with no signal can't leave it
--    half done. A resend changes nothing.
-- 3. schedule_rest() and cancel_rest(): the delivery manager (or a
--    manager) gives the rest a day and time or changes how it goes, or
--    takes it off. Once it has a day it's a trip like any other.
-- 4. v_rest_waiting: the rests waiting for a day. v_deliveries and
--    v_loadouts gain three columns at the end (owed, rest, part), and a
--    rest trip's ticket and site files are its own plus those of the trip
--    it's the rest of. v_loadouts leaves out a rest still waiting for a
--    day. v_loadout_extras gains how many went.
-- Replaces v_deliveries (trip_types.sql), v_loadouts (delivery_types.sql)
-- and v_loadout_extras (delivery_extras.sql), so those files now stop if
-- run again. Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('incomplete_deliveries.sql', 46, 'check_incomplete_deliveries', 'check_incomplete_deliveries', '{trip_types.sql,delivery_types.sql,delivery_extras.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('incomplete_deliveries.sql', '{trip_types.sql,delivery_types.sql,delivery_extras.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.check_trip_types()') is null then raise exception 'Run trip_types.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_delivery_extras()') is null then raise exception 'Run delivery_extras.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_counts_safety()') is null then raise exception 'Run counts_safety.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The tables. Row-level security on. No login writes either; only
--    the functions below do. trip_parts is read through the views by
--    Delivery, the delivery manager and managers, in their own lane.
--    part_extras (names of extras) only through v_loadout_extras.
-- ---------------------------------------------------------------------

create table if not exists trip_parts (
  loadout_id   uuid primary key references loadouts(id) on delete cascade,   -- the trip finished part-way
  rest_id      uuid not null unique references loadouts(id) on delete cascade, -- the trip made for the rest
  is_test      boolean not null default false,
  reason       text not null check (reason in ('Damaged', 'Site not ready', 'Wouldn''t fit', 'Customer asked to wait', 'Other')),
  reason_note  text check (char_length(reason_note) <= 500),
  went_pieces  text[] not null default '{}',     -- 'sheet:table', as v_loadouts writes them
  left_pieces  text[] not null default '{}',     -- the rest trip's own tables
  extras_left  int  not null default 0 check (extras_left >= 0),   -- extras still owed on the job, a number only
  by_id        uuid references profiles(id),
  by_name      text,
  at           timestamptz not null default now()
);

create table if not exists part_extras (
  loadout_id   uuid not null references loadouts(id) on delete cascade,
  sheet_number int  not null,
  name         text not null,
  loaded       int  not null check (loaded >= 0),
  went         int  not null check (went >= 0 and went <= loaded),
  primary key (loadout_id, sheet_number, name)
);

alter table trip_parts  enable row level security;
alter table part_extras enable row level security;
revoke all on trip_parts, part_extras from anon, authenticated;
grant select on trip_parts to authenticated;
drop policy if exists read_trip_parts on trip_parts;
create policy read_trip_parts on trip_parts for select to authenticated using (sees_lane(is_test) and sees_deliveries());


-- ---------------------------------------------------------------------
-- 2. trip_chain(trip): the trip, then the trip it's the rest of, and so
--    on back to the first (depth 0, 1, 2...). Runs as the reader, so it
--    only follows what they may see. The views use it for a rest trip's
--    ticket and site files.
-- ---------------------------------------------------------------------

create or replace function trip_chain(p_loadout uuid) returns table (id uuid, depth int)
language sql stable set search_path = public as $$
  with recursive up(id, depth) as (
    select p_loadout, 0
    union all
    select tp.loadout_id, up.depth + 1 from trip_parts tp join up on tp.rest_id = up.id where up.depth < 20)
  select up.id, up.depth from up;
$$;
revoke all on function trip_chain(uuid) from public, anon;
grant execute on function trip_chain(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 3. complete_trip_part(): a trip finished part-way, and its rest made,
--    in one step. p_went and p_left are the trip's tables as the phone
--    showed them ('sheet:table'): every table on a rest trip is in one or
--    the other; on any other trip, the job's tables that hadn't gone
--    before. p_extras: [{"sheet": 2, "name": "Data port", "went": 3}],
--    absolute numbers; an extra loaded on this trip and not sent went as
--    loaded. The signature (or why not) is exactly as for a full one:
--    complete_delivery() or complete_pickup() finishes it, in the same
--    step, so if they refuse, nothing at all is saved.
-- ---------------------------------------------------------------------

create or replace function complete_trip_part(
  p_client_id uuid, p_loadout uuid, p_rest_client_id uuid,
  p_went text[], p_left text[], p_extras jsonb, p_reason text, p_reason_note text default null,
  p_signed_name text default null, p_customer_note text default null, p_no_sign_reason text default null,
  p_no_sign_note text default null, p_signed_at timestamptz default null,
  p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text; v_all text[]; v_owed text[]; v_rest uuid; v_res jsonb; v_x record; v_went int;
        v_left_x int := 0; v_reason text := trim(coalesce(p_reason, '')); v_note text := nullif(trim(coalesce(p_reason_note, '')), '');
        v_pk boolean; v_w text[] := coalesce(p_went, '{}'); v_l text[] := coalesce(p_left, '{}');
begin
  if p_client_id is null or p_rest_client_id is null then raise exception 'This has no id. Try again.'; end if;
  select l.* into v from loadouts l where l.completion_client_id = p_client_id;
  if v.id is not null then                                            -- a resend: already done this way
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked done.',
                              'rest_id', (select tp.rest_id from trip_parts tp where tp.loadout_id = v.id));
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  v := delivery_lookup(p_loadout);
  if v.id is null then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The trip hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That trip was marked entered by mistake.'; end if;
  if v.completed_at is not null then
    raise exception 'That trip was already marked done by % (%).', coalesce(v.completed_by_name, 'someone'), local_when(v.completed_at);
  end if;
  v_pk := v.kind not in ('delivery', 'dock');
  if v_pk and not v.pickup_steps then
    raise exception 'That shipment was started before pickups had their own steps, so it can''t be finished part-way.';
  end if;
  if v_reason not in ('Damaged', 'Site not ready', 'Wouldn''t fit', 'Customer asked to wait', 'Other') then
    raise exception 'Pick why it didn''t all go: Damaged, Site not ready, Wouldn''t fit, Customer asked to wait, or Other.';
  end if;
  if v_reason = 'Other' and v_note is null then raise exception 'Say in a few words why it didn''t all go.'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'Keep the note for the office to 500 letters.'; end if;
  select project_id into v_pid from jobs where id = v.job_id;

  -- the tables: each one on the list went or didn't, none twice, none from somewhere else
  select tp.left_pieces into v_owed from trip_parts tp where tp.rest_id = v.id;
  select coalesce(array_agg(s.sheet_number || ':' || g), '{}') into v_all
    from work_orders w join sheets s on s.work_order_id = w.id cross join generate_series(1, s.qty) g
   where w.job_id = v.job_id and w.is_current;
  if exists (select 1 from unnest(v_w || v_l) x group by x having count(*) > 1) then
    raise exception 'A table was on the list twice. Open the trip again and try again.';
  end if;
  if exists (select 1 from unnest(v_w || v_l) x where not (x = any (coalesce(v_owed, v_all)))) then
    raise exception 'A table on the list isn''t on this trip now (a change order?). Open the trip again.';
  end if;
  if v_owed is not null and cardinality(v_w || v_l) <> cardinality(v_owed) then
    raise exception 'Each table on this trip has to be ticked as gone or not. Open the trip again.';
  end if;

  -- extras on this trip: how many went, from 0 to what was loaded
  for v_x in select x.sheet_number, x.name, x.loaded from loadout_extras x where x.loadout_id = v.id order by 1, 2 loop
    v_went := null;
    select (e->>'went')::int into v_went from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) e
     where (e->>'sheet')::int = v_x.sheet_number and lower(trim(e->>'name')) = lower(v_x.name) limit 1;
    v_went := coalesce(v_went, v_x.loaded);
    if v_went < 0 or v_went > v_x.loaded then
      raise exception 'Sheet %, %: how many went must be from 0 to the % loaded.', v_x.sheet_number, v_x.name, v_x.loaded;
    end if;
    insert into part_extras (loadout_id, sheet_number, name, loaded, went) values (v.id, v_x.sheet_number, v_x.name, v_x.loaded, v_went)
    on conflict (loadout_id, sheet_number, name) do update set loaded = excluded.loaded, went = excluded.went;
  end loop;
  -- extras still owed on the job after this trip: each one's quantity less what went on finished trips and this one
  select coalesce(sum(greatest(e.qty - coalesce((
           select sum(coalesce(pe.went, lx.loaded))
             from loadout_extras lx
             join loadouts l2 on l2.id = lx.loadout_id
             left join part_extras pe on pe.loadout_id = lx.loadout_id and pe.sheet_number = lx.sheet_number and lower(pe.name) = lower(lx.name)
            where l2.job_id = v.job_id and l2.voided_at is null and (l2.completed_at is not null or l2.id = v.id)
              and lx.sheet_number = s.sheet_number and lower(lx.name) = lower(e.name)), 0), 0)), 0)
    into v_left_x
    from work_orders w join sheets s on s.work_order_id = w.id join sheet_extras e on e.sheet_id = s.id
   where w.job_id = v.job_id and w.is_current;
  if cardinality(v_l) = 0 and v_left_x = 0 then
    raise exception 'Everything went, so this isn''t a part %: mark it % instead.',
      case when v_pk then 'pickup' else 'delivery' end, case when v_pk then 'picked up' else 'delivered' end;
  end if;

  -- the rest's trip: same job and kind; a pickup is ready at once, a delivery waits for a day
  insert into loadouts (client_id, job_id, is_test, started_by, started_by_name, kind, site_steps, pickup_steps,
                        ready_at, scheduled_by, scheduled_by_name, scheduled_at)
  values (p_rest_client_id, v.job_id, v.is_test, auth.uid(), my_name(), v.kind, v.site_steps, v.pickup_steps,
          case when v_pk then now() end,
          case when v_pk then coalesce(v.scheduled_by, auth.uid()) end,
          case when v_pk then coalesce(v.scheduled_by_name, my_name()) end,
          case when v_pk then now() end)
  returning id into v_rest;
  insert into trip_parts (loadout_id, rest_id, is_test, reason, reason_note, went_pieces, left_pieces, extras_left, by_id, by_name)
  values (v.id, v_rest, v.is_test, v_reason, v_note, v_w, v_l, v_left_x, auth.uid(), my_name());

  -- and the trip itself, finished exactly as a full one is
  if v_pk then
    v_res := complete_pickup(p_client_id, v.id, p_signed_name, p_customer_note, p_no_sign_reason, p_no_sign_note, p_signed_at);
  else
    v_res := complete_delivery(p_client_id, v.id, p_signed_name, p_customer_note, p_no_sign_reason, p_no_sign_note, p_signed_at, p_lat, p_lng, p_accuracy);
  end if;
  if not coalesce((v_res->>'ok')::boolean, false) or coalesce((v_res->>'already')::boolean, false) then
    raise exception '%', coalesce(v_res->>'summary', 'The trip couldn''t be marked done. Try again.');
  end if;
  return jsonb_build_object('ok', true, 'rest_id', v_rest, 'rest_client_id', p_rest_client_id,
    'summary', format('%s %s of %s table%s went. %s', v_res->>'summary', cardinality(v_w), cardinality(v_w) + cardinality(v_l),
                      case when cardinality(v_w) + cardinality(v_l) = 1 then '' else 's' end,
                      case when v_pk then 'The rest is back on Ready for pickup.' else 'The rest waits for the office to give it a day and time.' end));
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked done.');
end $$;
revoke all on function complete_trip_part(uuid, uuid, uuid, text[], text[], jsonb, text, text, text, text, text, text, timestamptz, double precision, double precision, double precision) from public, anon;
grant execute on function complete_trip_part(uuid, uuid, uuid, text[], text[], jsonb, text, text, text, text, text, text, timestamptz, double precision, double precision, double precision) to authenticated;


-- ---------------------------------------------------------------------
-- 4. schedule_rest() and cancel_rest(): the delivery manager or a
--    manager. A rest that Delivery hasn't started on can change kind:
--    white glove or dock to dock with a day and time, or a pickup (on
--    Ready for pickup at once). cancel_rest() takes off a rest still
--    waiting for a day; once it has one it's cancelled like any trip.
-- ---------------------------------------------------------------------

create or replace function schedule_rest(p_loadout uuid, p_kind text, p_when timestamptz default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v loadouts; v_kind text := lower(trim(coalesce(p_kind, ''))); v_pid text; v_pk boolean;
begin
  v := delivery_scheduler_check(p_loadout);        -- the scheduler, this lane, still there
  if not exists (select 1 from trip_parts where rest_id = v.id) then
    raise exception 'That trip isn''t the rest of a part delivery. Change it the usual way.';
  end if;
  if v.completed_at is not null then raise exception 'That trip is already done, so it can''t change.'; end if;
  if v.finished_at is not null or exists (select 1 from photos where loadout_id = v.id and voided_at is null) then
    raise exception 'Delivery has started on it, so how it goes can''t change now.';
  end if;
  if v_kind not in ('delivery', 'dock', 'shipping', 'customer_pickup') then
    raise exception 'Pick how the rest goes: white glove, dock to dock, customer pickup or BOL pickup.';
  end if;
  v_pk := v_kind not in ('delivery', 'dock');
  if not v_pk then
    if p_when is null then raise exception 'Pick the date and time of the delivery.'; end if;
    if p_when < now() - interval '14 days' or p_when > now() + interval '400 days' then
      raise exception 'That date doesn''t look right. Pick the day the delivery happens.';
    end if;
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'Keep the note to 500 letters.'; end if;
  update loadouts set kind = v_kind,
                      scheduled_for = case when v_pk then null else p_when end,
                      ready_at = case when v_pk then coalesce(ready_at, now()) end,
                      site_steps = not v_pk, pickup_steps = true,
                      schedule_note = nullif(trim(p_note), ''),
                      scheduled_by = coalesce(scheduled_by, auth.uid()), scheduled_by_name = coalesce(scheduled_by_name, my_name()),
                      scheduled_at = coalesce(scheduled_at, now())
   where id = v.id returning * into v;
  select project_id into v_pid from jobs where id = v.job_id;
  return jsonb_build_object('ok', true, 'id', v.id, 'client_id', v.client_id, 'summary',
    case when v_pk then format('%s: the rest is on Ready for pickup (%s).', v_pid, lower(trip_kind_name(v_kind)))
         else format('%s: the rest goes %s, %s.', v_pid, lower(trip_kind_name(v_kind)), local_when(p_when)) end);
end $$;
revoke all on function schedule_rest(uuid, text, timestamptz, text) from public, anon;
grant execute on function schedule_rest(uuid, text, timestamptz, text) to authenticated;

create or replace function cancel_rest(p_loadout uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text;
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can take the rest off.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is not null and v.voided_at is not null and sees_lane(v.is_test) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already taken off. It''s kept in history.');
  end if;
  v := delivery_scheduler_check(p_loadout);
  if not exists (select 1 from trip_parts where rest_id = v.id) then raise exception 'That trip isn''t the rest of a part delivery.'; end if;
  if v.completed_at is not null then raise exception 'That trip is already done.'; end if;
  if v.scheduled_for is not null or v.ready_at is not null then
    raise exception 'It has a day now (or it''s on Ready for pickup), so it''s cancelled like any trip.';
  end if;
  update loadouts set voided_at = now(), voided_by_name = my_name(), void_reason = coalesce(nullif(trim(p_reason), ''), 'Not needed')
   where id = v.id;
  select project_id into v_pid from jobs where id = v.job_id;
  return jsonb_build_object('ok', true, 'summary', format('%s: the rest is taken off. It''s kept in history.', v_pid));
end $$;
revoke all on function cancel_rest(uuid, text) from public, anon;
grant execute on function cancel_rest(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 5. The views. v_deliveries, v_loadouts and v_loadout_extras are as
--    before with columns added at the end (older pages ignore them);
--    v_loadouts leaves out a rest still waiting for a day, and a rest
--    trip's ticket and site files include those of the trip it's the
--    rest of (marked "inherited"). v_rest_waiting: the rests waiting
--    for a day, for Delivery and the delivery manager.
-- ---------------------------------------------------------------------

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
    ( SELECT jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes, 'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at IS NULL)
                || CASE WHEN c.depth > 0 THEN '{"inherited": true}'::jsonb ELSE '{}'::jsonb END AS jsonb_build_object
           FROM trip_chain(l.id) c
             JOIN delivery_docs d ON d.loadout_id = c.id
          WHERE d.kind = 'ticket'::text AND d.retired_at IS NULL
          ORDER BY c.depth, d.added_at DESC
         LIMIT 1) AS ticket,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes, 'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at IS NULL)
                || CASE WHEN c.depth > 0 THEN '{"inherited": true}'::jsonb ELSE '{}'::jsonb END ORDER BY c.depth DESC, d.added_at, d.id) AS jsonb_agg
           FROM trip_chain(l.id) c
             JOIN delivery_docs d ON d.loadout_id = c.id
          WHERE d.kind = 'site_file'::text AND d.retired_at IS NULL), '[]'::jsonb) AS files,
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
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.stage = 'bol'::text), '[]'::jsonb) AS bol_photos,
    ( SELECT tp.left_pieces
           FROM trip_parts tp
          WHERE tp.rest_id = l.id) AS owed,
    ( SELECT jsonb_build_object('of', o.id, 'of_client_id', o.client_id, 'of_kind', o.kind, 'of_at', o.completed_at, 'reason', tp.reason, 'note', tp.reason_note, 'went', cardinality(tp.went_pieces), 'count', cardinality(tp.left_pieces), 'extras', tp.extras_left) AS jsonb_build_object
           FROM trip_parts tp
             JOIN loadouts o ON o.id = tp.loadout_id
          WHERE tp.rest_id = l.id) AS rest,
    ( SELECT jsonb_build_object('reason', tp.reason, 'note', tp.reason_note, 'went', cardinality(tp.went_pieces), 'left', cardinality(tp.left_pieces), 'went_pieces', to_jsonb(tp.went_pieces), 'left_pieces', to_jsonb(tp.left_pieces), 'extras_left', tp.extras_left, 'by', tp.by_name, 'rest_id', r.id, 'rest_client_id', r.client_id, 'rest_kind', r.kind, 'rest_when', r.scheduled_for, 'rest_ready', r.ready_at, 'rest_done', r.completed_at, 'rest_off', r.voided_at IS NOT NULL) AS jsonb_build_object
           FROM trip_parts tp
             JOIN loadouts r ON r.id = tp.rest_id
          WHERE tp.loadout_id = l.id) AS part
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
  WHERE l.voided_at IS NULL AND ((l.kind = ANY (ARRAY['delivery'::text, 'dock'::text])) AND (l.scheduled_for IS NOT NULL OR l.completed_at IS NOT NULL) OR (l.kind <> ALL (ARRAY['delivery'::text, 'dock'::text])) AND l.pickup_steps AND (l.ready_at IS NOT NULL OR l.completed_at IS NOT NULL));

create or replace view v_loadouts with (security_invoker = true) as
SELECT l.id,
    l.client_id,
    l.job_id,
    j.project_id,
    j.name AS job_name,
    j.phase,
    j.delivery_date,
    l.is_test,
    l.started_by,
    l.started_by_name,
    l.started_at,
    l.finished_at,
    l.finished_by_name,
    l.note,
    l.finished_at IS NULL AS is_open,
    ( SELECT count(*)::integer AS count
           FROM sheets s
             JOIN work_orders w ON w.id = s.work_order_id AND w.is_current
          WHERE w.job_id = l.job_id) AS sheets_total,
    COALESCE(( SELECT array_agg(DISTINCT p.sheet_number ORDER BY p.sheet_number) AS array_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.sheet_number IS NOT NULL AND p.stage IS DISTINCT FROM 'site'::text), '{}'::integer[]) AS sheets_here,
    COALESCE(( SELECT array_agg(DISTINCT p.sheet_number ORDER BY p.sheet_number) AS array_agg
           FROM photos p
             JOIN loadouts l2 ON l2.id = p.loadout_id
          WHERE l2.job_id = l.job_id AND l2.id <> l.id AND l2.voided_at IS NULL AND l2.started_at < l.started_at AND p.voided_at IS NULL AND p.sheet_number IS NOT NULL AND p.stage IS DISTINCT FROM 'site'::text), '{}'::integer[]) AS sheets_earlier,
    ( SELECT count(*)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.sheet_number IS NULL AND p.pallet IS NULL AND p.truck IS NULL AND p.stage IS DISTINCT FROM 'bol'::text) AS other_items,
    ( SELECT count(*)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL) AS photo_count,
    l.kind,
    l.carrier,
    l.tracking,
    ( SELECT COALESCE(sum(s.qty), 0::bigint)::integer AS "coalesce"
           FROM sheets s
             JOIN work_orders w ON w.id = s.work_order_id AND w.is_current
          WHERE w.job_id = l.job_id) AS pieces_total,
    COALESCE(( SELECT array_agg(DISTINCT (p.sheet_number || ':'::text) || COALESCE(p.piece, 1)) AS array_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.sheet_number IS NOT NULL AND p.stage IS DISTINCT FROM 'site'::text), '{}'::text[]) AS pieces_here,
    COALESCE(( SELECT array_agg(DISTINCT (p.sheet_number || ':'::text) || COALESCE(p.piece, 1)) AS array_agg
           FROM photos p
             JOIN loadouts l2 ON l2.id = p.loadout_id
          WHERE l2.job_id = l.job_id AND l2.id <> l.id AND l2.voided_at IS NULL AND l2.started_at < l.started_at AND p.voided_at IS NULL AND p.sheet_number IS NOT NULL AND p.stage IS DISTINCT FROM 'site'::text), '{}'::text[]) AS pieces_earlier,
    COALESCE(( SELECT array_agg(DISTINCT p.pallet ORDER BY p.pallet) AS array_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.pallet IS NOT NULL), '{}'::integer[]) AS pallets_here,
    l.site_steps,
    l.scheduled_for,
    l.schedule_note,
    l.scheduled_by_name,
    l.completed_at,
    l.completed_by_name,
    l.signed_name,
    l.signed_at,
    l.no_sign_reason,
    COALESCE(( SELECT array_agg(DISTINCT p.truck ORDER BY p.truck) AS array_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.truck IS NOT NULL), '{}'::integer[]) AS trucks_here,
    COALESCE(( SELECT array_agg(DISTINCT (p.sheet_number || ':'::text) || p.piece) AS array_agg
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.stage = 'site'::text), '{}'::text[]) AS site_here,
    COALESCE(( SELECT array_agg(DISTINCT (p.sheet_number || ':'::text) || p.piece) AS array_agg
           FROM photos p
             JOIN loadouts l2 ON l2.id = p.loadout_id
          WHERE l2.job_id = l.job_id AND l2.id <> l.id AND l2.voided_at IS NULL AND l2.completed_at IS NOT NULL AND (l.completed_at IS NULL OR l2.completed_at < l.completed_at) AND p.voided_at IS NULL AND p.stage = 'site'::text), '{}'::text[]) AS site_earlier,
    l.ready_at,
    l.pickup_steps,
    ( SELECT count(*)::integer AS count
           FROM photos p
          WHERE p.loadout_id = l.id AND p.voided_at IS NULL AND p.stage = 'bol'::text) AS bol_here,
    ( SELECT tp.left_pieces
           FROM trip_parts tp
          WHERE tp.rest_id = l.id) AS owed,
    ( SELECT jsonb_build_object('of', o.id, 'of_client_id', o.client_id, 'of_kind', o.kind, 'of_at', o.completed_at, 'reason', tp.reason, 'note', tp.reason_note, 'went', cardinality(tp.went_pieces), 'count', cardinality(tp.left_pieces), 'extras', tp.extras_left) AS jsonb_build_object
           FROM trip_parts tp
             JOIN loadouts o ON o.id = tp.loadout_id
          WHERE tp.rest_id = l.id) AS rest,
    ( SELECT jsonb_build_object('reason', tp.reason, 'note', tp.reason_note, 'went', cardinality(tp.went_pieces), 'left', cardinality(tp.left_pieces), 'went_pieces', to_jsonb(tp.went_pieces), 'left_pieces', to_jsonb(tp.left_pieces), 'extras_left', tp.extras_left, 'by', tp.by_name, 'rest_id', r.id, 'rest_client_id', r.client_id, 'rest_kind', r.kind, 'rest_when', r.scheduled_for, 'rest_ready', r.ready_at, 'rest_done', r.completed_at, 'rest_off', r.voided_at IS NOT NULL) AS jsonb_build_object
           FROM trip_parts tp
             JOIN loadouts r ON r.id = tp.rest_id
          WHERE tp.loadout_id = l.id) AS part
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
  WHERE l.voided_at IS NULL AND NOT ((l.kind = ANY (ARRAY['delivery'::text, 'dock'::text])) AND l.scheduled_for IS NULL AND l.completed_at IS NULL AND (EXISTS ( SELECT 1
           FROM trip_parts tp
          WHERE tp.rest_id = l.id)));

create or replace view v_loadout_extras as
SELECT l.id AS loadout_id,
    l.client_id,
    l.job_id,
    x.sheet_number,
    x.name,
    x.loaded,
    x.by_name,
    x.at,
    l.finished_at,
    l.completed_at,
    ( SELECT pe.went
           FROM part_extras pe
          WHERE pe.loadout_id = x.loadout_id AND pe.sheet_number = x.sheet_number AND lower(pe.name) = lower(x.name)) AS went
   FROM loadout_extras x
     JOIN loadouts l ON l.id = x.loadout_id
  WHERE l.voided_at IS NULL AND sees_lane(l.is_test) AND owns_dept('delivery'::text);

create or replace view v_rest_waiting with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, j.phase, l.is_test, l.kind,
       l.started_at as made_at, l.started_by_name as made_by_name,
       tp.left_pieces as owed, cardinality(tp.left_pieces) as owed_count, tp.extras_left,
       tp.reason, tp.reason_note, cardinality(tp.went_pieces) as went_count,
       o.id as rest_of, o.client_id as rest_of_client_id, o.kind as rest_of_kind, o.completed_at as rest_of_at,
       o.signed_name as rest_of_signed_name, o.no_sign_reason as rest_of_no_sign_reason,
       ( select jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes,
                                  'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at is null)
                || case when c.depth > 0 then '{"inherited": true}'::jsonb else '{}'::jsonb end
           from trip_chain(l.id) c join delivery_docs d on d.loadout_id = c.id
          where d.kind = 'ticket' and d.retired_at is null
          order by c.depth, d.added_at desc limit 1) as ticket,
       coalesce(( select jsonb_agg(jsonb_build_object('id', d.id, 'path', d.storage_path, 'name', d.file_name, 'mime', d.mime, 'bytes', d.bytes,
                                                      'added_by', d.added_by_name, 'added_at', d.added_at, 'in_cloud', d.file_removed_at is null)
                                   || case when c.depth > 0 then '{"inherited": true}'::jsonb else '{}'::jsonb end order by c.depth desc, d.added_at, d.id)
                    from trip_chain(l.id) c join delivery_docs d on d.loadout_id = c.id
                   where d.kind = 'site_file' and d.retired_at is null), '[]'::jsonb) as files
  from loadouts l
  join jobs j        on j.id = l.job_id
  join trip_parts tp on tp.rest_id = l.id
  join loadouts o    on o.id = tp.loadout_id
 where l.voided_at is null and l.completed_at is null and l.scheduled_for is null
   and l.kind in ('delivery', 'dock')
   and sees_deliveries();

revoke all on v_rest_waiting from public, anon, authenticated;
grant select on v_rest_waiting to authenticated;


-- ---------------------------------------------------------------------
-- 6. check_incomplete_deliveries(): the PASS/FAIL table. It tests as
--    each login (Delivery, the delivery manager, another supervisor),
--    the way the pages reach the database. Everything it does is undone
--    at the end.
-- ---------------------------------------------------------------------

create or replace function check_incomplete_deliveries()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sch uuid; dlv uuid; oth uuid;
  ja uuid; wo uuid; s1 uuid; s2 uuid;
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid();
  f1 uuid := gen_random_uuid(); f2 uuid := gen_random_uuid(); f3 uuid := gen_random_uuid(); f4 uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r3 uuid := gen_random_uuid(); r4 uuid := gen_random_uuid(); tk uuid := gen_random_uuid();
  r jsonb; n int; m int; k int; ok boolean; msg text; v_lo loadouts; v_rs loadouts; v_tp trip_parts; j jsonb; t1 text; t2 text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where schedules_deliveries and active and not is_test and role = 'supervisor' order by full_name limit 1), mgr) into sch;
  select id into dlv from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) and not schedules_deliveries order by full_name limit 1;
  select id into oth from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments)) and not schedules_deliveries order by full_name limit 1;
  if mgr is null or dlv is null or oth is null then
    res := res || check_row(1, 'A manager, a Delivery login and another supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  -- ---- 1: the tables are locked down; the new functions need a login ----------------------------------------
  ok := has_table_privilege('authenticated', 'public.trip_parts', 'select')
        and not has_table_privilege('authenticated', 'public.trip_parts', 'insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('anon', 'public.trip_parts', 'select,insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('authenticated', 'public.part_extras', 'select,insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('anon', 'public.part_extras', 'select,insert,update,delete,truncate,references,trigger')
        and (select relrowsecurity from pg_class where oid = 'public.trip_parts'::regclass)
        and (select relrowsecurity from pg_class where oid = 'public.part_extras'::regclass)
        and not has_function_privilege('anon', 'public.complete_trip_part(uuid,uuid,uuid,text[],text[],jsonb,text,text,text,text,text,text,timestamptz,double precision,double precision,double precision)', 'execute')
        and not has_function_privilege('anon', 'public.schedule_rest(uuid,text,timestamptz,text)', 'execute')
        and not has_function_privilege('anon', 'public.cancel_rest(uuid,text)', 'execute')
        and not has_function_privilege('anon', 'public.trip_chain(uuid)', 'execute')
        and not has_table_privilege('anon', 'public.v_rest_waiting', 'select');
  res := res || check_row(1, 'No login writes trip_parts or part_extras, nobody without a login reads them, and the new functions need a login', ok,
                          case when ok then null else 'A grant is wrong. Run incomplete_deliveries.sql again.' end);

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999461, 'IDCHECK-A', 'Incomplete deliveries check - undone automatically', true, 'In Production') returning id into ja;
    insert into work_orders (job_id, version, is_current) values (ja, 1, true) returning id into wo;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (wo, 1, 2, 'idcheck-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (wo, 2, 3, 'idcheck-2') returning id into s2;
    insert into sheet_extras (sheet_id, position, name, qty) values (s2, 1, 'Data port', 4);
    set constraints all immediate;

    -- a white glove delivery set up by the delivery manager, with a ticket; Delivery loads all 4 data ports
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform schedule_delivery(ja, now() + interval '1 day', 'Check', null, c1, 'delivery');
    perform schedule_delivery(ja, now() + interval '2 days', 'Check', null, c2, 'delivery');
    perform schedule_pickup(ja, 'customer_pickup', null, null, c3);
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, is_test, added_by_name)
    select tk, l.id, ja, 'ticket', 'Ticket.pdf', 'IDCHECK-A/' || c1 || '/' || tk || '.pdf', 'application/pdf', 10, false, 'Check'
      from loadouts l where l.client_id = c1;
    insert into storage.objects (bucket_id, name, metadata) values ('deliveries', 'IDCHECK-A/' || c1 || '/' || f1 || '.png', '{"size": "10", "mimetype": "image/png"}');
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform set_extra_loaded(c1, 2, 'Data port', 4, null);
    execute 'reset role';

    -- ---- 2: Delivery finishes it part-way, signed: the rest is a new trip waiting for a day --------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f1, c1, r1, '{1:1,1:2,2:1}', '{2:2,2:3}', '[{"sheet": 2, "name": "Data port", "went": 3}]',
                              'Site not ready', 'Reading room not carpeted', 'Pat Lee', null, null, null, now(), null, null, null);
      execute 'reset role';
      select * into v_lo from loadouts where client_id = c1;
      select * into v_rs from loadouts where client_id = r1;
      select * into v_tp from trip_parts where loadout_id = v_lo.id;
      select went into n from part_extras where loadout_id = v_lo.id and name = 'Data port';
      ok := v_lo.completed_at is not null and v_lo.signed_name = 'Pat Lee'
            and v_tp.rest_id = v_rs.id and v_tp.went_pieces = '{1:1,1:2,2:1}' and v_tp.left_pieces = '{2:2,2:3}'
            and v_tp.reason = 'Site not ready' and v_tp.extras_left = 1 and n = 3
            and v_rs.kind = 'delivery' and v_rs.job_id = ja and v_rs.scheduled_for is null and v_rs.ready_at is null
            and v_rs.completed_at is null and v_rs.voided_at is null;
      msg := coalesce(r->>'summary', 'nothing') || format(' · rest kind %s, extras left %s, data ports went %s', v_rs.kind, v_tp.extras_left, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Delivery finishes a trip part-way, signed: what went, what didn''t and why are kept, and the rest is a new trip waiting for a day', ok, msg);

    -- ---- 3: a resend changes nothing ---------------------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f1, c1, gen_random_uuid(), '{1:1,1:2,2:1}', '{2:2,2:3}', '[]', 'Site not ready', null, 'Pat Lee');
      execute 'reset role';
      select count(*) into n from loadouts where job_id = ja;
      ok := coalesce((r->>'already')::boolean, false) and n = 4 and (r->>'rest_id')::uuid = v_rs.id;
      msg := format('already %s, %s trips on the job (4 expected)', r->>'already', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Sending it again (no signal, then signal) changes nothing and makes no second rest', ok, msg);

    -- ---- 4: what each login sees while the rest waits ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      select count(*), min(owed::text), min(ticket->>'inherited') into n, msg, t1 from v_rest_waiting where client_id = r1;
      select count(*) into m from v_loadouts where client_id = r1;
      select count(*) into k from v_deliveries where client_id = r1;
      select part into j from v_deliveries where client_id = c1;
      execute 'reset role';
      ok := n = 1 and msg = '{2:2,2:3}' and t1 = 'true' and m = 0 and k = 0
            and (j->>'went')::int = 3 and (j->>'left')::int = 2 and (j->>'rest_client_id')::uuid = r1 and j->>'reason' = 'Site not ready';
      msg := format('Delivery: waiting %s (owed %s, ticket inherited %s), on the trip list %s, on the delivery list %s, the trip says went %s left %s',
                    n, msg, t1, m, k, j->>'went', j->>'left');
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from v_rest_waiting where client_id = r1;
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into m from v_rest_waiting;
      select count(*) into k from trip_parts;
      execute 'reset role';
      ok := ok and n = 1 and m = 0 and k = 0;
      msg := msg || format(' · the delivery manager sees it %s; another supervisor sees %s waiting and %s trip_parts rows', n, m, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The rest waits for a day where Delivery and the delivery manager see it, off the trip lists, with the ticket; nobody else sees it', ok, msg);

    -- ---- 5: what's refused, with nothing saved -------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform set_extra_loaded(c2, 2, 'Data port', 1, null);
    execute 'reset role';
    n := 0; msg := '';
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Too busy', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a reason not on the list was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Other', '  ', null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'Other with no words was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{3:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a table not on the job was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a table both gone and not was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1,1:2,2:1,2:2,2:3}', '{}', '[{"sheet": 2, "name": "Data port", "went": 1}]',
                              'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a part delivery with nothing left was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[{"sheet": 2, "name": "Data port", "went": 2}]',
                              'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'more data ports went than were loaded; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'another department''s supervisor finished it; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    select count(*) into m from loadouts where job_id = ja;
    select count(*) into k from trip_parts tp join loadouts l on l.id = tp.loadout_id where l.client_id = c2;
    ok := n = 7 and m = 4 and k = 0 and (select completed_at is null from loadouts where client_id = c2);
    res := res || check_row(5, 'Refused, with nothing saved: a reason not on the list, Other with no words, a table not on the trip or on it twice, nothing left, more extras than loaded, another department', ok,
                            case when ok then null else msg || format('%s of 7 refused, %s trips (4 expected), %s parts on the second trip', n, m, k) end);

    -- ---- 6: the delivery manager gives the rest a day (and changes how it goes); Delivery can't -------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    n := 0;
    begin execute 'set local role authenticated'; r := schedule_rest(r1, 'delivery', now() + interval '3 days', null); execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; r := cancel_rest(r1, null); execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := schedule_rest(r1, 'dock', now() + interval '3 days', 'The rest');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into m from v_rest_waiting where client_id = r1;
      select owed::text, rest->>'of_client_id', ticket->>'inherited' into msg, t1, t2 from v_deliveries where client_id = r1 and kind = 'dock' and scheduled_for is not null;
      select count(*) into k from v_loadouts where client_id = r1 and owed = '{2:2,2:3}';
      execute 'reset role';
      ok := n = 2 and m = 0 and msg = '{2:2,2:3}' and t1::uuid = c1 and t2 = 'true' and k = 1;
      msg := format('Delivery refused %s of 2; waiting now %s; on the delivery list with owed %s, the rest of %s, ticket inherited %s; on the trip list %s',
                    n, m, msg, case when t1::uuid = c1 then 'the first trip' else coalesce(t1, 'nothing') end, t2, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'The delivery manager gives the rest a day and can make it dock to dock; then it''s on the lists with only its own tables and the ticket; Delivery can''t', ok, msg);

    -- ---- 7: a rest finished part-way: only its own tables, every one of them --------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    n := 0;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, gen_random_uuid(), '{2:2}', '{}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, gen_random_uuid(), '{2:2}', '{1:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, r3, '{2:2}', '{2:3}', '[]', 'Damaged', 'Scratched top', null, null, 'Nobody on site', 'Left at the dock');
      select count(*), min(owed::text), min(ticket->>'name') into m, msg, t1 from v_rest_waiting where client_id = r3 and kind = 'dock';
      execute 'reset role';
      ok := n = 2 and m = 1 and msg = '{2:3}' and t1 = 'Ticket.pdf' and (select completed_at is not null from loadouts where client_id = r1);
      msg := format('refused %s of 2; the rest of the rest waiting %s with owed %s and ticket %s', n, m, msg, coalesce(t1, 'none'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A rest finished part-way again: every table on it, and only those, gone or not; its rest keeps the first trip''s ticket', ok, msg);

    -- ---- 8: a pickup's rest goes straight back on Ready for pickup ----------------------------------------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f4, c3, r4, '{1:1}', '{1:2}', '[]', 'Wouldn''t fit', null, null, null, 'Customer refused');
      select count(*) into n from v_deliveries where client_id = r4 and kind = 'customer_pickup' and ready_at is not null and owed = '{1:2}';
      select count(*) into m from v_rest_waiting where client_id = r4;
      execute 'reset role';
      ok := n = 1 and m = 0 and (select completed_at is not null from loadouts where client_id = c3);
      msg := coalesce(r->>'summary', 'nothing') || format(' · on Ready for pickup %s, waiting for a day %s', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A customer pickup finished part-way: its rest is back on Ready for pickup at once, no day needed', ok, msg);

    -- ---- 9: the delivery manager takes a waiting rest off; it's kept ----------------------------------------------------
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := cancel_rest(r3, null);
      j := cancel_rest(r3, null);
      select count(*) into n from v_rest_waiting where client_id = r3;
      execute 'reset role';
      ok := n = 0 and coalesce((j->>'already')::boolean, false) and (select voided_at is not null and void_reason = 'Not needed' from loadouts where client_id = r3);
      msg := coalesce(r->>'summary', 'nothing') || format(' · still waiting %s; again: %s', n, j->>'summary');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'The delivery manager takes a rest off; it''s kept in history, and doing it twice is fine', ok, msg);

    -- ---- 10: extras: Delivery reads how many went; nobody reads part_extras itself --------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select went, loaded into n, m from v_loadout_extras where client_id = c1 and name = 'Data port';
      execute 'reset role';
      ok := n = 3 and m = 4; msg := format('went %s of %s loaded', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    begin
      execute 'set local role authenticated';
      select count(*) into k from part_extras;
      execute 'reset role';
      ok := false; msg := msg || ' · part_extras was readable directly';
    exception when others then execute 'reset role';
    end;
    res := res || check_row(10, 'Delivery sees how many of each extra went; the table itself can''t be read directly', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_incomplete_deliveries_undo__';
  exception when others then
    if sqlerrm <> '__check_incomplete_deliveries_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_incomplete_deliveries() from public, anon, authenticated;

select * from check_incomplete_deliveries();
