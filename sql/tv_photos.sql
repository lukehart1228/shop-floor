-- =====================================================================
-- Shop Floor — "In its new home": finished work on the floor TV (7 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table. Run this BEFORE the new pages go on GitHub.
--
-- WHAT IT DOES
-- 1. A small copy of each white glove SITE photo (a table in place at the
--    customer's) rides along from the Delivery phone and is kept in
--    tv_photo_copies: a JPEG under 200 KB, checked here, dropped (never
--    the photo) when it fails the check. Nothing can read that table but
--    the two TV functions below. The copy is a CACHE: 14 days after the
--    delivery its bytes are cleared and the row stays (the same exception
--    as an archived photo's file leaving while its record stays).
-- 2. One gate, tv_home_pictures(), decides what the TV may show: white
--    glove, delivered, real job, site photo of one table, not marked
--    entered by mistake (photo or trip), inside 14 days, the newest
--    picture of each kind of table on the job, not hidden. The jobs take
--    turns: every job's first kind, then every job's second kind, and so on.
-- 3. tv_snapshot gains a 'home' list (the gate's rows, no image data) and
--    tv_photo(key, id) hands the TV one copy at a time, only for an id the
--    gate lists right now. Both need the TV link; both refuse with the
--    same plain answer otherwise. tv_snapshot also stops sending the
--    job table and totals the TV never showed (review finding R-6).
-- 4. Managers hide a picture, or a whole job's pictures, from the office
--    job page: hide_from_tv(). Recorded in tv_hides; reversible; nothing
--    deleted. tv_job_pictures(job) tells the office what's showing.
-- 5. clear_tv_photo_copies() clears bytes that are out of the window; it
--    runs daily (pg_cron) and whenever a new copy arrives.
--
-- Replaces pieces of trip_types.sql (add_delivery_photo, tv_snapshot) and
-- tv_pace.sql (check_tv), so those now stop if run again. Nothing is deleted.
-- Review findings R-6 and R-21 to R-25 are built in.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('tv_photos.sql', '{trip_types.sql,tv_pace.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.check_trip_types()') is null then raise exception 'Run trip_types.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_counts_safety()') is null then raise exception 'Run counts_safety.sql first. This file builds on it.'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The tables
-- ---------------------------------------------------------------------
create table if not exists tv_photo_copies (
  photo_id    uuid primary key references photos(id) on delete cascade,
  jpeg        bytea,                                  -- null once cleared: the row stays
  bytes       int         not null,
  added_at    timestamptz not null default now(),
  cleared_at  timestamptz
);
alter table tv_photo_copies enable row level security;
revoke all on tv_photo_copies from public, anon, authenticated;     -- Supabase's defaults grant select; nobody reads this but tv_photo (R-25)

create table if not exists tv_hides (
  id          uuid primary key default gen_random_uuid(),
  photo_id    uuid references photos(id) on delete cascade,
  job_id      uuid references jobs(id) on delete cascade,
  hidden      boolean     not null,                   -- true = hide from the TV, false = show again; the newest row wins
  set_by      uuid references profiles(id),
  set_by_name text,
  set_at      timestamptz not null default clock_timestamp()   -- not now(): two switches in one transaction must keep their order,
  check ((photo_id is null) <> (job_id is null))
);
create index if not exists tv_hides_photo_idx on tv_hides (photo_id, set_at desc);
create index if not exists tv_hides_job_idx   on tv_hides (job_id, set_at desc);
alter table tv_hides enable row level security;
revoke all on tv_hides from public, anon, authenticated;

-- the ceiling (R-22): above this the table is reported FAIL and new copies are skipped, photos still save
create or replace function tv_copies_ceiling_bytes() returns bigint language sql immutable as $$ select 100::bigint * 1024 * 1024 $$;
revoke all on function tv_copies_ceiling_bytes() from public, anon, authenticated;   -- connector_safety.sql's rule: nothing runs without a login unless meant to

-- ---------------------------------------------------------------------
-- 2. Clearing the cache: bytes go 14 days after the delivery, or when the
--    photo or trip is marked entered by mistake, or the trip never finished
--    (30 days after the photo). Rows stay. Daily by timer, and on each new copy.
-- ---------------------------------------------------------------------
create or replace function clear_tv_photo_copies() returns int
language plpgsql security definer set search_path = public as $$
declare n int; tz constant text := 'America/Indiana/Indianapolis';
begin
  update tv_photo_copies c
     set jpeg = null, cleared_at = now()
    from photos p left join loadouts l on l.id = p.loadout_id
   where c.photo_id = p.id and c.jpeg is not null
     and (   (l.completed_at is not null and (l.completed_at at time zone tz)::date < (now() at time zone tz)::date - 14)
          or p.voided_at is not null or l.voided_at is not null or l.id is null
          or (l.completed_at is null and p.taken_at < now() - interval '30 days'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function clear_tv_photo_copies() from public, anon, authenticated;

do $$ begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('shop-floor-tv-photos', '20 3 * * *', 'select public.clear_tv_photo_copies()');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. The gate: what the TV may show right now (R-23). Not callable by any
--    login; tv_snapshot and tv_photo use it.
-- ---------------------------------------------------------------------
create or replace function tv_home_pictures()
returns table (photo_id uuid, job_id uuid, project_id text, delivered_on date, tables int, item text, ord int)
language sql stable security definer set search_path = public as $$
  with cand as (
    select p.id as photo_id, p.job_id, j.project_id, l.id as loadout_id, l.completed_at,
           (l.completed_at at time zone 'America/Indiana/Indianapolis')::date as delivered_on,
           coalesce(p.shot_at, p.taken_at) as taken_at,      -- when the phone took it: photos sent together share taken_at
           coalesce(nullif(trim(s.item_code), ''), 'sheet ' || p.sheet_number) as item
      from tv_photo_copies c
      join photos p   on p.id = c.photo_id and p.kind = 'loadout' and p.stage = 'site'
                     and p.sheet_number is not null and p.piece is not null
                     and p.voided_at is null and not p.is_test
      join loadouts l on l.id = p.loadout_id and l.kind = 'delivery' and l.completed_at is not null
                     and l.voided_at is null and not l.is_test
      join jobs j     on j.id = p.job_id and not j.is_test and j.monday_item_id is not null
      left join work_orders w on w.job_id = p.job_id and w.is_current
      left join sheets s      on s.work_order_id = w.id and s.sheet_number = p.sheet_number
     where c.jpeg is not null
       and (l.completed_at at time zone 'America/Indiana/Indianapolis')::date >= (now() at time zone 'America/Indiana/Indianapolis')::date - 14
       and not coalesce((select h.hidden from tv_hides h where h.photo_id = p.id order by h.set_at desc limit 1), false)
       and not coalesce((select h.hidden from tv_hides h where h.job_id = p.job_id order by h.set_at desc limit 1), false)
  ),
  one_per_kind as (
    select distinct on (job_id, item) * from cand order by job_id, item, taken_at desc, photo_id
  ),
  ranked as (
    select o.*,
           row_number() over (partition by o.job_id order by o.item) as rk,
           (select count(distinct (p2.sheet_number, p2.piece)) from photos p2
             where p2.loadout_id = o.loadout_id and p2.stage = 'site' and p2.voided_at is null and p2.sheet_number is not null)::int as tables
      from one_per_kind o
  )
  select photo_id, job_id, project_id, delivered_on, tables, item,
         row_number() over (order by rk, completed_at desc, project_id, item)::int as ord
    from ranked
   order by ord
$$;
revoke all on function tv_home_pictures() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. The Delivery phone's photo function, now with the small copy as its
--    last argument (default null, so an older phone page keeps working).
--    The old signature is dropped first: two would make PostgREST refuse
--    every phone photo (PGRST203, R-25).
-- ---------------------------------------------------------------------
drop function if exists public.add_delivery_photo(uuid, uuid, text, integer, integer, integer, double precision, double precision, double precision, timestamp with time zone, integer, integer);

create or replace function public.add_delivery_photo(p_client_id uuid, p_loadout uuid, p_stage text, p_sheet integer default null, p_piece integer default null, p_truck integer default null, p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null, p_shot_at timestamp with time zone default null, p_width integer default null, p_height integer default null, p_tv text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v loadouts; v_qty int; v_res jsonb; v_pid text; v_ok_gps boolean; v_copy bytea; v_copy_ok boolean := false; v_photo uuid;
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
   where client_id = p_client_id
   returning id into v_photo;

  -- tv_photos.sql: the TV's small copy. Only a white glove site photo of one table on a real job; a JPEG under
  -- 200 KB; only while the table is under its ceiling. Anything else is dropped and the photo is still saved.
  if p_tv is not null and p_stage = 'site' and p_sheet is not null and v.kind = 'delivery' and not v.is_test then
    begin
      v_copy := decode(p_tv, 'base64');
      if length(v_copy) between 200 and 204800 and substring(v_copy from 1 for 3) = '\xffd8ff'::bytea
         and pg_total_relation_size('public.tv_photo_copies') < tv_copies_ceiling_bytes() then
        insert into tv_photo_copies (photo_id, jpeg, bytes) values (v_photo, v_copy, length(v_copy)) on conflict (photo_id) do nothing;
        v_copy_ok := true;
      end if;
    exception when others then v_copy_ok := false;     -- not base64, or anything else odd: no copy, the photo stays
    end;
    perform clear_tv_photo_copies();
  end if;

  select project_id into v_pid from jobs where id = v.job_id;
  return v_res || jsonb_build_object('tv_copy', v_copy_ok, 'summary',
    case when p_stage = 'dock' then format('Photo of truck %s saved on %s.', p_truck, v_pid)
         else format('Photo saved on %s sheet %s, table %s, at the site.', v_pid, p_sheet, p_piece) end);
end $function$;
revoke all on function add_delivery_photo(uuid, uuid, text, int, int, int, double precision, double precision, double precision, timestamptz, int, int, text) from public, anon;
grant execute on function add_delivery_photo(uuid, uuid, text, int, int, int, double precision, double precision, double precision, timestamptz, int, int, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The hide switch (managers, from the office job page) and what the
--    office reads
-- ---------------------------------------------------------------------
create or replace function hide_from_tv(p_photo uuid default null, p_job uuid default null, p_hide boolean default true) returns text
language plpgsql security definer set search_path = public as $$
declare v_pid text; n int;
begin
  if not office_ok() then raise exception 'Only a manager can change what the floor TV shows.' using errcode = 'insufficient_privilege'; end if;
  if (p_photo is null) = (p_job is null) then raise exception 'Say which picture, or which job.'; end if;
  if p_photo is not null then
    select j.project_id into v_pid from photos p join jobs j on j.id = p.job_id where p.id = p_photo;
    if v_pid is null then raise exception 'No such photo.'; end if;
  else
    select project_id into v_pid from jobs where id = p_job;
    if v_pid is null then raise exception 'No such job.'; end if;
  end if;
  insert into tv_hides (photo_id, job_id, hidden, set_by, set_by_name) values (p_photo, p_job, p_hide, auth.uid(), my_name());
  select count(*) into n from tv_home_pictures() t where t.job_id = coalesce(p_job, (select job_id from photos where id = p_photo));
  return case when p_photo is not null and p_hide then format('That picture is off the floor TV (within 30 seconds). %s pictures of %s still show.', n, v_pid)
              when p_photo is not null then format('That picture can show on the floor TV again. %s pictures of %s show now.', n, v_pid)
              when p_hide then format('%s''s pictures are off the floor TV (within 30 seconds).', v_pid)
              else format('%s''s pictures can show on the floor TV again: %s show now.', v_pid, n) end;
end $$;
revoke all on function hide_from_tv(uuid, uuid, boolean) from public, anon;
grant execute on function hide_from_tv(uuid, uuid, boolean) to authenticated;

-- the office job page: each white glove site photo of the job, whether it has a copy, whether it's hidden, whether it shows
create or replace function tv_job_pictures(p_job uuid)
returns table (photo_id uuid, sheet_number int, piece int, item text, taken_at timestamptz, delivered_on date,
               has_copy boolean, hidden boolean, job_hidden boolean, showing boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.sheet_number, p.piece,
         coalesce(nullif(trim(s.item_code), ''), 'sheet ' || p.sheet_number),
         p.taken_at,
         (l.completed_at at time zone 'America/Indiana/Indianapolis')::date,
         c.jpeg is not null,
         coalesce((select h.hidden from tv_hides h where h.photo_id = p.id order by h.set_at desc limit 1), false),
         coalesce((select h.hidden from tv_hides h where h.job_id = p.job_id order by h.set_at desc limit 1), false),
         exists (select 1 from tv_home_pictures() t where t.photo_id = p.id)
    from photos p
    join loadouts l on l.id = p.loadout_id and l.kind = 'delivery'
    left join tv_photo_copies c on c.photo_id = p.id
    left join work_orders w on w.job_id = p.job_id and w.is_current
    left join sheets s on s.work_order_id = w.id and s.sheet_number = p.sheet_number
   where office_ok() and p.job_id = p_job and p.kind = 'loadout' and p.stage = 'site'
     and p.sheet_number is not null and p.voided_at is null
   order by l.completed_at desc nulls last, p.sheet_number, p.piece
$$;
revoke all on function tv_job_pictures(uuid) from public, anon;
grant execute on function tv_job_pictures(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. The TV's two functions. tv_snapshot: everything tv_pace.sql and
--    trip_types.sql gave it, minus 'table' and 'kpis' (R-6), plus 'home'.
--    tv_photo: one copy, only for an id the gate lists right now (R-24).
-- ---------------------------------------------------------------------
create or replace function public.tv_snapshot(p_key text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
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
  tbl as (      -- still worked out: the attention list's materials line comes from it
    select o.*, (o.delivery_date - v_today) as days
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
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;

  -- ---- tv_pace.sql: pace, work stopped, going out ----
  v_week := pace_week(now());
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0
                 else least(4, greatest((v_week - greatest(v_first, v_week - 28)) / 7, 0)) end;

  v_out := v_out || jsonb_build_object(
    'version', 3,
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

    'stopped', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', j.project_id, 'job_name', j.name, 'sheet_number', p.sheet_number,
                                          'department', d.name, 'body', left(p.body, 200)) order by p.raised_at)
        from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
       where p.status = 'open' and p.work_stopped and not p.is_test and not j.is_test and j.is_active
         and d.is_live and not d.log_only), '[]'::jsonb),

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
               limit 12) t), '[]'::jsonb),

    -- tv_photos.sql: in its new home. The gate's rows in round order; no image data here.
    'home', coalesce((
      select jsonb_agg(jsonb_build_object('id', h.photo_id, 'project_id', h.project_id, 'delivered_on', h.delivered_on,
                                          'tables', h.tables) order by h.ord)
        from tv_home_pictures() h), '[]'::jsonb)
  );
  return v_out;
end $function$;
revoke all on function tv_snapshot(text) from public;
grant execute on function tv_snapshot(text) to anon, authenticated;

create or replace function tv_photo(p_key text, p_photo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_hash text; v_copy bytea;
begin
  select value #>> '{}' into v_hash from app_settings where key = 'secret_tv_key_hash';
  if v_hash is null or nullif(p_key, '') is null or encode(sha256(convert_to(p_key, 'UTF8')), 'hex') <> v_hash
     or p_photo is null or not exists (select 1 from tv_home_pictures() h where h.photo_id = p_photo) then
    return jsonb_build_object('ok', false);                 -- one answer for everything the TV link doesn't unlock (R-24)
  end if;
  select jpeg into v_copy from tv_photo_copies where photo_id = p_photo and jpeg is not null;
  if v_copy is null then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'id', p_photo, 'jpeg', encode(v_copy, 'base64'));
end $$;
revoke all on function tv_photo(text, uuid) from public;
grant execute on function tv_photo(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. check_tv(): the same nine steps as tv_pace.sql, with step 1 no longer
--    expecting the job table and totals (R-6), and the new tables on the
--    no-login list.
-- ---------------------------------------------------------------------
create or replace function check_tv()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the TV and a manager
declare
  res     jsonb := '[]';
  mgr     uuid;  as_mgr text;
  v_key   text;
  v       jsonb;  v0 jsonb;  r jsonb;
  v_job   uuid;  v_wo uuid;  s1 uuid;  v_test uuid;
  v_dept  text;  v_each numeric;
  tz      constant text := 'America/Indiana/Indianapolis';
  ok      boolean;  msg text;  n int;  a numeric;  b numeric;  tbl text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager has a login', false, 'No manager login found.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  select key into v_dept from departments where is_live and not log_only order by sort_order limit 1;

  begin    -- everything below is undone at the end, whatever happens
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v_key := new_tv_link()->>'key';
    execute 'reset role';

    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999961, 'TVCHECK', 'TV check - undone automatically', true, 'In Production', local_today() + 5) returning id into v_job;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test)
      values (-999962, 'TEST-TVCHECK', 'TV check test job - undone automatically', true, 'In Production', local_today() + 5, true) returning id into v_test;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length)
      values (v_wo, 1, 2, 'TV-1', '36"', null) returning id into s1;
    if v_dept is not null then
      insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1, v_dept, 2, 0);
    end if;

    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v0 := tv_snapshot(v_key);
    execute 'reset role';

    insert into loadouts (job_id, kind, scheduled_for) values
      (v_job, 'delivery', ((local_today() + 2)::timestamp + interval '8 hours') at time zone tz);
    insert into loadouts (job_id, kind, scheduled_for, voided_at, void_reason) values
      (v_job, 'delivery', ((local_today() + 1)::timestamp + interval '9 hours 15 minutes') at time zone tz, now(), 'TV check');
    insert into loadouts (job_id, kind, scheduled_for) values
      (v_job, 'delivery', ((local_today() + 10)::timestamp + interval '9 hours 45 minutes') at time zone tz);
    insert into loadouts (job_id, kind, pickup_steps, ready_at) values (v_job, 'customer_pickup', true, now());
    insert into loadouts (job_id, kind, scheduled_for, completed_at) values
      (v_job, 'delivery', (local_today()::timestamp + interval '7 hours') at time zone tz, now());
    insert into loadouts (job_id, kind, scheduled_for, is_test) values
      (v_test, 'delivery', ((local_today() + 1)::timestamp + interval '10 hours') at time zone tz, true);

    if v_dept is not null then
      insert into problems (job_id, sheet_number, department, body, work_stopped, status)
        values (v_job, 1, v_dept, 'TV check: stopped, undone automatically', true, 'open');
      insert into problems (job_id, sheet_number, department, body, work_stopped, status)
        values (v_job, 1, v_dept, 'TV check: not stopped, undone automatically', false, 'open');
      insert into problems (job_id, sheet_number, department, body, work_stopped, status, is_test)
        values (v_test, 1, v_dept, 'TV check: test lane, undone automatically', true, 'open', true);
      perform set_config('shopfloor.source', '', true);
      update sheet_progress set qty_done = 2 where sheet_id = s1 and department = v_dept;
      select main_each into v_each from v_pace_units where sheet_id = s1 and department = v_dept;
    end if;

    insert into outside_jobs (job_id, sheet_numbers, description, service, department, sent_on, waiting)
      values (v_job, '{1}', 'TVCHECK waiting', 'powdercoat', 'metal', local_today() - 30, true),
             (v_job, '{1}', 'TVCHECK gone', 'powdercoat', 'metal', local_today() - 30, false);

    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v := tv_snapshot(v_key);
    execute 'reset role';

    -- ---- 1. the parts the TV reads, and nothing it doesn't (R-6) ----------------------
    ok := (v->>'ok')::boolean and (v->>'version')::int >= 3
          and v ?& array['live', 'donut', 'critical', 'attention', 'pace', 'stopped', 'trips', 'home']
          and not (v ?| array['table', 'kpis'])
          and jsonb_array_length(v->'pace') = jsonb_array_length(v->'live');
    res := res || check_row(1, 'The TV gets its numbers, pace, work stopped, going out and the pictures list, and no longer the job table it never showed', coalesce(ok, false),
      'Something is missing from the TV''s numbers, or the job table is still sent. Run tv_photos.sql again from the top.');

    -- ---- 2. no link, nothing -------------------------------------------------------
    begin
      execute 'set local role anon';
      r := tv_snapshot('not-the-key');
      execute 'reset role';
      ok := not (r->>'ok')::boolean and not (r ?| array['live', 'pace', 'trips', 'stopped', 'donut', 'home']);
      msg := 'The TV handed out numbers without its link. Do not go further; bring this to Claude.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Without the TV link, it shows nothing', ok, msg);

    -- ---- 3. pace matches the Pace page ----------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := pace_report(4);
      execute 'reset role';
      select count(*) into n
        from jsonb_array_elements(v->'pace') t
        join jsonb_array_elements(r->'departments') p on p->>'key' = t->>'key'
       where (t->>'this_week')::numeric = (p->>'this_week')::numeric
         and (t->>'usual') is not distinct from (p->>'pace')
         and t->>'measure' = p->>'measure';
      ok := n = jsonb_array_length(v->'pace') and (v->>'pace_weeks')::int = (r->>'weeks_used')::int;
      msg := format('Only %s of %s departments matched the Pace page''s 4-week numbers.', n, jsonb_array_length(v->'pace'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Each department''s pace is the Pace page''s: this week so far, and the 4-week average', ok, msg);

    -- ---- 4. a tablet count shows up this week -------------------------------------------
    if v_dept is null then
      res := res || check_row(4, 'A tablet count adds to this week''s pace', true);
    else
      select (x->>'this_week')::numeric into a from jsonb_array_elements(v0->'pace') x where x->>'key' = v_dept;
      select (x->>'this_week')::numeric into b from jsonb_array_elements(v->'pace') x where x->>'key' = v_dept;
      ok := b - a = 2 * v_each;
      res := res || check_row(4, 'A tablet count adds to this week''s pace', coalesce(ok, false),
        format('Counting 2 pieces (%s each) in %s changed this week from %s to %s.', v_each, v_dept, a, b));
    end if;

    -- ---- 5. going out -------------------------------------------------------------------
    select count(*),
           count(*) filter (where x->>'time' = '8:00' and (x->>'date')::date = local_today() + 2)
         + count(*) filter (where (x->>'ready')::boolean and x->>'kind' = 'customer_pickup')
         + count(*) filter (where x->>'done_at' is not null and (x->>'date')::date = local_today())
      into n, a
      from jsonb_array_elements(v->'trips') x where x->>'project_id' = 'TVCHECK';
    ok := n = 3 and a = 3;
    res := res || check_row(5, 'Going out: trips in the next 7 days, pickups ready, today''s delivered; never a cancelled or far-off trip', coalesce(ok, false),
      format('Expected 3 of the check''s 5 trips (in 2 days at 8:00, the pickup, today''s delivered). Got %s.', n));

    -- ---- 6. work stopped ----------------------------------------------------------------
    if v_dept is null then
      res := res || check_row(6, 'A work-stopped issue shows; an ordinary one doesn''t', true);
    else
      ok := v->'stopped' @> '[{"project_id": "TVCHECK", "body": "TV check: stopped, undone automatically"}]'::jsonb
            and (v->'stopped')::text not like '%not stopped, undone%';
      res := res || check_row(6, 'A work-stopped issue shows; an ordinary one doesn''t', coalesce(ok, false),
        'The stopped issue was missing, or an issue without "work stopped" showed.');
    end if;

    -- ---- 7. test jobs --------------------------------------------------------------------
    ok := v::text not like '%TEST-TVCHECK%' and v::text not like '%test lane, undone%';
    res := res || check_row(7, 'Test jobs never reach the TV (trips and issues included)', ok,
      'A test job''s trip or issue showed on the TV. Do not go further; bring this to Claude.');

    -- ---- 8. Arrow ------------------------------------------------------------------------
    ok := (v->'attention')::text like '%TVCHECK gone%' and (v->'attention')::text not like '%TVCHECK waiting%';
    res := res || check_row(8, '"At Arrow too long" counts only items that have gone', ok,
      'An item still waiting to go counted as at Arrow, or a long-gone one was missing.');

    -- ---- 9. no login --------------------------------------------------------------------
    ok := has_function_privilege('anon', 'public.tv_snapshot(text)', 'execute')
          and not has_function_privilege('anon', 'public.pace_report(integer)', 'execute');
    msg := case when ok then null else 'The TV couldn''t read its numbers, or anyone could read the Pace page.' end;
    perform set_config('request.jwt.claims', '', true);
    foreach tbl in array array['loadouts', 'problems', 'outside_jobs', 'v_pace_done', 'pace_schedules', 'tv_photo_copies', 'tv_hides'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', tbl) into n;
        execute 'reset role';
        if n > 0 then ok := false; msg := concat_ws(' ', msg, format('%s rows of %s visible.', n, tbl)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := concat_ws(' ', msg, format('%s: %s', tbl, sqlerrm));
      end;
    end loop;
    res := res || check_row(9, 'With no login, only the TV''s own numbers can be read, and only with the link', ok,
      coalesce(msg, '') || ' Do not go further; bring this to Claude.');

    raise exception using errcode = 'P0001', message = '__check_tv_undo__';
  exception when others then
    if sqlerrm <> '__check_tv_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('shopfloor.source', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_tv() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. The check: select * from check_tv_photos();   (undoes itself)
-- ---------------------------------------------------------------------
create or replace function check_tv_photos()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as the TV, Delivery and a manager
declare
  res     jsonb := '[]';
  mgr uuid; dlv uuid; as_mgr text; as_dlv text;
  v_key text; v jsonb; r jsonb;
  ja uuid; jb uuid; jt uuid; wa uuid; wb uuid; wt uuid; la uuid; lb uuid; lt uuid;
  pa1 uuid := gen_random_uuid(); pa2 uuid := gen_random_uuid(); pa3 uuid := gen_random_uuid(); pb1 uuid := gen_random_uuid();
  pdock uuid := gen_random_uuid(); pbad uuid := gen_random_uuid(); pbig uuid := gen_random_uuid(); pt uuid := gen_random_uuid();
  ida1 uuid; ida2 uuid; ida3 uuid; idb1 uuid; iddock uuid; idbad uuid; idbig uuid; idt uuid;
  -- a real 2×2 JPEG (632 bytes) and a PNG, for the copies
  jpg constant text := '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwAooorwT6U//9k=';
  png constant text := 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNk2LKJgYGBiYGBgYGBAQAQQAFqlmjkSwAAAABJRU5ErkJggg==';
  big text;
  ok boolean; msg text; n int; m int; k text; sz bigint;
  home jsonb;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) limit 1), mgr) into dlv;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_dlv := json_build_object('sub', dlv, 'role', 'authenticated')::text;

  -- ---- 1. the tables are locked -------------------------------------------------------------
  ok := true; msg := '';
  foreach k in array array['tv_photo_copies', 'tv_hides'] loop
    if has_table_privilege('anon', 'public.' || k, 'select') or has_table_privilege('authenticated', 'public.' || k, 'select')
       or has_table_privilege('anon', 'public.' || k, 'insert,update,delete,truncate')
       or has_table_privilege('authenticated', 'public.' || k, 'insert,update,delete,truncate')
       or not (select relrowsecurity from pg_class where oid = ('public.' || k)::regclass) then
      ok := false; msg := msg || k || ' is readable or writable by a login. ';
    end if;
  end loop;
  if has_function_privilege('anon', 'public.tv_home_pictures()', 'execute') or has_function_privilege('authenticated', 'public.tv_home_pictures()', 'execute')
     or has_function_privilege('anon', 'public.hide_from_tv(uuid,uuid,boolean)', 'execute')
     or has_function_privilege('anon', 'public.tv_job_pictures(uuid)', 'execute')
     or has_function_privilege('anon', 'public.clear_tv_photo_copies()', 'execute') or has_function_privilege('authenticated', 'public.clear_tv_photo_copies()', 'execute')
     or not has_function_privilege('anon', 'public.tv_photo(text,uuid)', 'execute') then
    ok := false; msg := msg || 'A TV function is open to the wrong role. ';
  end if;
  res := res || check_row(1, 'Nobody signed in, and nobody without a login, can read or write the TV''s copies or hides; only the TV''s two functions reach them', ok,
    msg || 'Do not go further; bring this to Claude.');

  -- ---- 2. one add_delivery_photo ---------------------------------------------------------
  select count(*) into n from pg_proc where proname = 'add_delivery_photo' and pronamespace = 'public'::regnamespace;
  res := res || check_row(2, 'There is exactly one add_delivery_photo, so the phone''s photos are never refused as ambiguous', n = 1,
    format('%s functions named add_delivery_photo. Two would make every phone photo wait (PGRST203). Bring this to Claude.', n));

  begin    -- everything below is undone at the end, whatever happens
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v_key := new_tv_link()->>'key';
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);

    -- two real jobs and a test job, each with a work order; A has two kinds of table (3 of one, 1 of another)
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values (-999981, 'TVPHOTO-A', 'TV photos check - undone automatically', true, 'In Production', local_today()) returning id into ja;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values (-999982, 'TVPHOTO-B', 'TV photos check - undone automatically', true, 'In Production', local_today()) returning id into jb;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test) values (null, 'TEST-TVPHOTO', 'TV photos check - undone automatically', true, 'In Production', local_today(), true) returning id into jt;
    insert into work_orders (job_id) values (ja) returning id into wa;
    insert into work_orders (job_id) values (jb) returning id into wb;
    insert into work_orders (job_id) values (jt) returning id into wt;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (wa, 1, 3, 'TVP-ROUND'), (wa, 2, 1, 'TVP-RECT'), (wb, 1, 1, 'TVP-LIVE'), (wt, 1, 1, 'TVP-TEST');
    -- white glove trips, finished (signed) today; the test one too
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at) values (ja, 'delivery', now() - interval '3 hours', now() - interval '20 minutes', 'A Customer', now() - interval '20 minutes') returning id into la;
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at) values (jb, 'delivery', now() - interval '2 hours', now() - interval '10 minutes', 'B Customer', now() - interval '10 minutes') returning id into lb;
    insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at, is_test) values (jt, 'delivery', now() - interval '2 hours', now() - interval '10 minutes', 'T Customer', now() - interval '10 minutes', true) returning id into lt;
    -- the files the phone uploads first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', 'TVPHOTO-A/' || x || '.jpg', '{"size": 1}' from unnest(array[pa1, pa2, pa3, pdock, pbad]) x;
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', 'TVPHOTO-B/' || x || '.jpg', '{"size": 1}' from unnest(array[pb1, pbig]) x;

    -- ---- 3. the phone sends site photos with copies; a dock photo, a PNG and an oversize copy keep the photo and drop the copy
    begin
      big := rpad(substr(jpg, 1, 4), 280000, 'A');     -- starts like a JPEG, about 210 KB decoded: over the 200 KB limit
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(pa1, la, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '50 minutes', 800, 600, jpg);  ida1 := (r->>'id')::uuid;
      r := add_delivery_photo(pa2, la, 'site', 1, 2, null, 39.77, -86.16, 8, now() - interval '45 minutes', 800, 600, jpg);  ida2 := (r->>'id')::uuid;
      r := add_delivery_photo(pa3, la, 'site', 1, 3, null, 39.77, -86.16, 8, now() - interval '40 minutes', 800, 600, jpg);  ida3 := (r->>'id')::uuid;
      r := add_delivery_photo(pdock, la, 'dock', null, null, 1, 39.77, -86.16, 8, now() - interval '3 hours', 800, 600, jpg); iddock := (r->>'id')::uuid;
      r := add_delivery_photo(pbad, la, 'site', 2, 1, null, 39.77, -86.16, 8, now() - interval '35 minutes', 800, 600, png);  idbad := (r->>'id')::uuid;
      ok := (r->>'ok')::boolean and not (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pbig, lb, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '30 minutes', 800, 600, big);  idbig := (r->>'id')::uuid;
      ok := ok and (r->>'ok')::boolean and not (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pb1, lb, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '25 minutes', 800, 600, jpg);  idb1 := (r->>'id')::uuid;
      ok := ok and (r->>'ok')::boolean and (r->>'tv_copy')::boolean;
      r := add_delivery_photo(pa1, la, 'site', 1, 1, null, 39.77, -86.16, 8, now() - interval '50 minutes', 800, 600, jpg);
      ok := ok and (r->>'already')::boolean;   -- the same photo sent twice: already saved, as before
      execute 'reset role';
      -- a copy for the test job, put straight into the table: the gate must never list it
      insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, storage_path, is_test, taken_by_name, stage, piece)
        values (pt, jt, 1, 'delivery', 'loadout', lt, 'TEST-TVPHOTO/' || pt || '.jpg', true, 'check', 'site', 1) returning id into idt;
      insert into tv_photo_copies (photo_id, jpeg, bytes) values (idt, decode(jpg, 'base64'), 632);
      select count(*) into n from tv_photo_copies where photo_id in (ida1, ida2, ida3, idb1) and jpeg is not null;
      select count(*) into m from tv_photo_copies where photo_id in (iddock, idbad, idbig);
      select count(*) into k from photos where id in (ida1, ida2, ida3, idb1, iddock, idbad, idbig);
      ok := coalesce(ok, false) and n = 4 and m = 0 and k::int = 7;
      msg := format('Copies kept for the 4 good site photos: %s of 4; copies wrongly kept for the truck, the PNG and the oversize one: %s; photos saved: %s of 7.', n, m, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A white glove site photo''s copy is kept; a truck photo''s, a non-JPEG and an oversize copy are dropped and the photo still saves', ok, msg);

    -- ---- 4. the home list: one per kind, the newest, jobs taking turns, never the test job ------
    begin
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      home := v->'home';
      select count(*) into n from jsonb_array_elements(home) x where x->>'project_id' = 'TVPHOTO-A';
      -- A's first kind is TVP-RECT (sheet 2) but it has no copy (the PNG), so A shows one picture: the newest of TVP-ROUND = table 3
      ok := n = 1 and home @> jsonb_build_array(jsonb_build_object('id', ida3, 'project_id', 'TVPHOTO-A', 'tables', 4))
            and not (home::text like '%' || ida1 || '%') and not (home::text like '%' || ida2 || '%')
            and not (home::text like '%' || iddock || '%') and not (home::text like '%' || idbad || '%')
            and home::text not like '%TEST-TVPHOTO%' and home::text not like '%' || idt || '%'
            and not (v ?| array['table', 'kpis']);
      msg := format('TVPHOTO-A pictures: %s (expected 1, the newest of its 3 identical tables, saying 4 tables delivered). List: %s', n, left(home::text, 300));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A job with 3 of one table gets 1 picture (the newest); the picture says how many tables went; test jobs never show', ok, msg);

    -- ---- 5. taking turns: a second job with one kind comes before another job's second kind -------
    begin
      -- give A its second kind: a good copy on sheet 2 (the PNG one is already there as a photo; add another table? sheet 2 has qty 1,
      -- so instead replace the bad copy's photo: mark it entered by mistake and add a fresh one on sheet 2 table 1)
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_photo(idbad, 'TV photos check');
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      pbad := gen_random_uuid();
      insert into storage.objects (bucket_id, name, metadata) values ('photos', 'TVPHOTO-A/' || pbad || '.jpg', '{"size": 1}');
      perform set_config('request.jwt.claims', as_dlv, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(pbad, la, 'site', 2, 1, null, 39.77, -86.16, 8, now() - interval '34 minutes', 800, 600, jpg);  idbad := (r->>'id')::uuid;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      home := v->'home';
      select string_agg(x->>'project_id', ',' order by o) into k from jsonb_array_elements(home) with ordinality t(x, o);
      -- round 1: B (delivered most recently) then A; round 2: A's second kind
      ok := k = 'TVPHOTO-B,TVPHOTO-A,TVPHOTO-A' and jsonb_array_length(home) = 3;
      msg := format('Order: %s (expected TVPHOTO-B,TVPHOTO-A,TVPHOTO-A: every job''s first kind, newest delivery first, then second kinds).', k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'The jobs take turns: every job''s first kind of table, then the second kinds', ok, msg);

    -- ---- 6. tv_photo hands out a listed copy, and only that --------------------------------------
    begin
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      r := tv_photo(v_key, ida3);
      ok := (r->>'ok')::boolean and decode(r->>'jpeg', 'base64') = decode(jpg, 'base64');
      r := tv_photo(v_key, ida1);          -- a real site photo, but not the one the panel shows (the same kind, older)
      ok := ok and not (r->>'ok')::boolean and not (r ? 'jpeg');
      r := tv_photo(v_key, iddock);        -- the truck
      ok := ok and not (r->>'ok')::boolean and not (r ? 'jpeg');
      r := tv_photo('not-the-key', ida3);  -- wrong key: the same plain answer
      ok := ok and r = jsonb_build_object('ok', false);
      r := tv_photo(v_key, idt);           -- the test job's copy
      ok := ok and r = jsonb_build_object('ok', false);
      execute 'reset role';
      msg := 'tv_photo handed out a copy it shouldn''t, or refused the one the panel shows, or said more than "ok: false" for a wrong key. Do not go further; bring this to Claude.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'The TV gets one copy per listed id, nothing for any other id, and one plain refusal without the link', ok, msg);

    -- ---- 7. the hide switch ----------------------------------------------------------------------
    begin
      msg := '';
      if dlv <> mgr then      -- a Delivery supervisor can't hide (in a sandbox without one, this part is skipped)
        perform set_config('request.jwt.claims', as_dlv, true);
        execute 'set local role authenticated';
        begin perform hide_from_tv(ida3, null, true); msg := msg || 'A Delivery login hid a picture. ';
        exception when insufficient_privilege then null; end;
        execute 'reset role';
      end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(ida3, null, true);
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key); r := tv_photo(v_key, ida3);
      execute 'reset role';
      -- hiding the newest shows the next newest of that kind (table 2), and tv_photo refuses the hidden one
      if (v->'home')::text like '%' || ida3 || '%' then msg := msg || 'The hidden picture still listed. '; end if;
      if (v->'home')::text not like '%' || ida2 || '%' then msg := msg || 'The next picture of that kind did not take its place. '; end if;
      if (r->>'ok')::boolean then msg := msg || 'tv_photo still handed out the hidden picture. '; end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(ida3, null, false);
      perform hide_from_tv(null, ja, true);
      select count(*) into n from tv_job_pictures(ja) t where t.job_hidden;
      select count(*) into m from tv_job_pictures(ja) t where t.showing;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      if (v->'home')::text like '%TVPHOTO-A%' then msg := msg || 'The hidden job still listed. '; end if;
      if (v->'home')::text not like '%TVPHOTO-B%' then msg := msg || 'The other job went too. '; end if;
      if n <> 4 or m <> 0 then msg := msg || format('The office saw %s pictures marked job-hidden (expected 4) and %s showing (expected 0). ', n, m); end if;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform hide_from_tv(null, ja, false);
      select count(*) into m from tv_job_pictures(ja) t where t.showing;
      execute 'reset role';
      if m <> 2 then msg := msg || format('After showing the job again, %s pictures showing (expected 2). ', m); end if;
      ok := msg = '';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A manager hides a picture (the next of its kind takes its place) or a whole job, and shows them again; Delivery can''t', ok, msg);

    -- ---- 8. entered by mistake, a cancelled trip, and the 14-day window ---------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_photo(ida3, 'TV photos check');
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      ok := (v->'home')::text not like '%' || ida3 || '%' and (v->'home')::text like '%' || ida2 || '%';
      update loadouts set voided_at = now(), void_reason = 'TV photos check' where id = lb;
      update loadouts set completed_at = now() - interval '15 days' where id = la;
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      ok := ok and jsonb_array_length(v->'home') = 0;
      n := clear_tv_photo_copies();
      select count(*), count(*) filter (where jpeg is null and cleared_at is not null) into m, k
        from tv_photo_copies where photo_id in (ida1, ida2, ida3, idbad, idbig, iddock);
      ok := ok and m = 4 and k::int = 4;
      msg := format('After a photo marked entered by mistake, a cancelled trip and a 15-day-old delivery: %s pictures listed (expected 0); clearing emptied %s of %s copies and kept every row.', jsonb_array_length(v->'home'), k, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A photo or trip marked entered by mistake leaves the TV; after 14 days a job leaves, its copies are cleared and their rows kept', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_tv_photos_undo__';
  exception when others then
    if sqlerrm <> '__check_tv_photos_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ---- 9. room: the copies table against its ceiling (R-22) ------------------------------------
  sz := pg_total_relation_size('public.tv_photo_copies');
  select count(*) filter (where jpeg is not null), count(*) into n, m from tv_photo_copies;
  res := res || check_row(9, format('The TV copies take %s (%s pictures kept, %s rows); the ceiling is %s', pg_size_pretty(sz), n, m, pg_size_pretty(tv_copies_ceiling_bytes())),
    sz < tv_copies_ceiling_bytes(),
    'The copies are over their ceiling: new copies are skipped (photos still save). Run select clear_tv_photo_copies(); and bring this to Claude.');

  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_tv_photos() from public, anon, authenticated;

select * from check_tv_photos();
