-- =====================================================================
-- delivery_photos_open.sql — Delivery photos aren't turned away, and the office sees what a phone couldn't send (11 Nov 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 60. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table.
-- Replaces add_photo() from photos.sql (16), so photos.sql run after
-- this stops with "Stop — nothing was changed".
--
-- WHY (10 Nov): part orders go out on one white glove trip kept open
-- and moved to a later day. add_photo() turned a load-out photo away
-- once the truck had left more than 3 days before, so site photos
-- taken after day 3 were refused: 7 on PROJ-00099 on 10 Nov, 1 on
-- PROJ-00472 on 22 Oct. The files reached Supabase; the phone kept
-- each one on its Couldn't send list.
--
--   add_photo()            A trip takes photos until it's marked done,
--                          however long ago its truck left. A trip
--                          marked done locks a day later (as before);
--                          a cancelled one refuses (as before). Only an
--                          old-style load-out, never marked done, still
--                          closes 3 days after it finished.
--   device_unsent,         The Delivery phone reports how many things
--   report_unsent()        are on its Couldn't send list (index.html
--                          from 2026-11-11.1). Nothing on the phone is
--                          sent here except the count, the oldest's
--                          time and the PROJ numbers.
--   unsent_on_phones()     Julia's Deliveries page: which Delivery
--                          phones are holding things they couldn't
--                          send. For Delivery, the delivery scheduler
--                          and managers.
--   v_trips_out            Each open trip's first and last photo, so
--                          the pages can say "Out since Tue Oct 27" and
--                          the phone's trip bar shows only today's trip.
--   clear_empty_trips()    The 3 load-outs started on the phone and
--                          never used are marked entered by mistake
--                          (kept, with their history), once, below.
--   put_back_stray_photos()  For Luke in the SQL Editor: a photo file
--                          that reached Supabase but was turned away is
--                          put on its job's trip, with no table, once
--                          the phone can't send it any more. Run with
--                          no PROJ number it only lists them.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('delivery_photos_open.sql', 60, 'unsent_on_phones', 'check_delivery_photos_open', '{photos.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('delivery_photos_open.sql', '{photos.sql}'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. add_photo(): a trip takes photos until it's marked done
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
    -- 11 Nov: a trip takes photos until it's marked done, however long ago its truck left (the 3-day rule
    -- turned away site photos on trips kept open over several days). A trip marked done locks a day later,
    -- as add_delivery_photo() and add_bol_photo() already do. Only an old-style load-out, which is never
    -- marked done (no site or pickup steps), still closes 3 days after it finished.
    if v_lo.completed_at is not null and v_lo.completed_at < now() - interval '1 day' then
      raise exception 'That trip was marked done on %, so the photo wasn''t added.', to_char(v_lo.completed_at at time zone 'America/Indiana/Indianapolis', 'Mon FMDD');
    end if;
    if v_lo.completed_at is null and not (v_lo.site_steps or v_lo.pickup_steps)
       and v_lo.finished_at is not null and v_lo.finished_at < now() - interval '3 days' then
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

-- ---------------------------------------------------------------------
-- 2. What a phone couldn't send: the count, reported by the phone
-- ---------------------------------------------------------------------
create table if not exists device_unsent (
  device_id   text primary key,
  user_id     uuid not null,
  items       int not null default 0,
  photos      int not null default 0,
  oldest_at   timestamptz,
  jobs        text[] not null default '{}',
  reported_at timestamptz not null default now()
);
alter table device_unsent enable row level security;
revoke all on table device_unsent from public, anon, authenticated;

create or replace function report_unsent(p_device text, p_items int, p_photos int,
                                         p_oldest timestamptz default null, p_jobs text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  if coalesce(length(p_device), 0) not between 8 and 100 or p_items is null or p_items not between 0 and 10000
     or p_photos is null or p_photos not between 0 and p_items or cardinality(coalesce(p_jobs, '{}')) > 50
     or exists (select 1 from unnest(coalesce(p_jobs, '{}')) x where length(x) > 40) then
    raise exception 'That report doesn''t look right.';
  end if;
  insert into device_unsent (device_id, user_id, items, photos, oldest_at, jobs, reported_at)
  values (p_device, auth.uid(), p_items, p_photos, case when p_items > 0 then p_oldest end, coalesce(p_jobs, '{}'), now())
  on conflict (device_id) do update
    set user_id = excluded.user_id, items = excluded.items, photos = excluded.photos,
        oldest_at = excluded.oldest_at, jobs = excluded.jobs, reported_at = now();
end $$;
revoke all on function report_unsent(text, int, int, timestamptz, text[]) from public, anon;
grant execute on function report_unsent(text, int, int, timestamptz, text[]) to authenticated;

-- Julia's page: Delivery logins' phones holding something they couldn't send (reported in the last 14 days)
create or replace function unsent_on_phones()
returns table (person text, items int, photos int, oldest_at timestamptz, jobs text[], reported_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not sees_deliveries() then raise exception 'Only Delivery and whoever schedules deliveries see this.' using errcode = 'insufficient_privilege'; end if;
  return query
    select coalesce(p.full_name, 'A Delivery phone'), u.items, u.photos, u.oldest_at, u.jobs, u.reported_at
      from device_unsent u join profiles p on p.id = u.user_id
     where u.items > 0 and u.reported_at > now() - interval '14 days'
       and 'delivery' = any(p.departments) and p.is_test = (select coalesce(bool_or(me.is_test), false) from profiles me where me.id = auth.uid())
     order by u.oldest_at nulls last;
end $$;
revoke all on function unsent_on_phones() from public, anon;
grant execute on function unsent_on_phones() to authenticated;

-- ---------------------------------------------------------------------
-- 3. v_trips_out: each open trip's first and last photo
-- ---------------------------------------------------------------------
create or replace view v_trips_out with (security_invoker = true) as
select l.id as loadout_id, l.client_id, l.job_id,
       min(coalesce(p.shot_at, p.taken_at)) as first_photo_at,
       max(coalesce(p.shot_at, p.taken_at)) as last_photo_at,
       count(*)::int as photos
  from loadouts l
  join photos p on p.loadout_id = l.id and p.voided_at is null
 where l.voided_at is null and l.completed_at is null
 group by l.id, l.client_id, l.job_id;
revoke all on table v_trips_out from public, anon;
grant select on table v_trips_out to authenticated;

-- ---------------------------------------------------------------------
-- 4. Load-outs started on the phone and never used: marked entered by mistake (kept)
-- ---------------------------------------------------------------------
-- Started before p_before, never scheduled or made ready by the office, never finished, no photo or file
-- at all, and not the rest of another trip waiting for its day.
create or replace function clear_empty_trips(p_before timestamptz) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update loadouts l
     set voided_at = now(), voided_by_name = 'Shop floor system',
         void_reason = 'Empty: started on the phone and never used'
   where l.voided_at is null and l.completed_at is null and l.finished_at is null
     and l.scheduled_for is null and l.ready_at is null and l.started_at < p_before
     and not exists (select 1 from photos p where p.loadout_id = l.id)
     and not exists (select 1 from delivery_docs d where d.loadout_id = l.id)
     and not exists (select 1 from trip_parts t where t.rest_id = l.id or t.loadout_id = l.id);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function clear_empty_trips(timestamptz) from public, anon, authenticated;

select clear_empty_trips('2026-11-11 00:00-05');

-- ---------------------------------------------------------------------
-- 5. put_back_stray_photos(): a turned-away photo file put on its job's trip (Luke, in the SQL Editor)
-- ---------------------------------------------------------------------
-- select * from put_back_stray_photos();              lists them, changes nothing
-- select * from put_back_stray_photos('PROJ-00472');  puts that job's back, with no table
-- Only once the phone can't send them any more: a photo the phone still holds goes back with its table
-- when Shawn taps Try again. One put back here is "already saved" if the phone sends it later.
create or replace function put_back_stray_photos(p_project text default null)
returns table (job text, sent text, sent_by text, result text)
language plpgsql security definer set search_path = public, storage as $$
declare
  o record; v_job jobs; v_lo loadouts; v_cid uuid; v_who profiles; v_size bigint;
begin
  for o in
    select so.name, so.created_at, so.metadata, coalesce(so.owner_id::text, so.owner::text) as owner_txt
      from storage.objects so
     where so.bucket_id = 'photos' and so.created_at < now() - interval '10 minutes'
       and so.name ~ '^[A-Za-z0-9_-]+/[0-9a-f-]{36}\.jpg$'
       and so.name not like 'PHOTOCHECK/%' and so.name not like 'TVPHOTO-%'
       and not exists (select 1 from photos p where p.storage_path = so.name)
       and not exists (select 1 from task_photos t where t.storage_path = so.name)
     order by so.created_at
  loop
    job := split_part(o.name, '/', 1);
    sent := to_char(o.created_at at time zone 'America/Indiana/Indianapolis', 'Mon DD HH24:MI');
    v_who := null;
    begin select * into v_who from profiles where id = o.owner_txt::uuid; exception when others then v_who := null; end;
    sent_by := coalesce(v_who.full_name, 'someone not on the list');
    if p_project is null or upper(trim(p_project)) <> upper(job) then
      result := case when p_project is null then 'Not put back. To put it back: select * from put_back_stray_photos(''' || job || ''');'
                     else 'Left alone (another job)' end;
      return next; continue;
    end if;
    if v_who.id is null or not ('delivery' = any(v_who.departments)) then
      result := 'Left alone: not sent from a Delivery login, so it isn''t a trip photo'; return next; continue;
    end if;
    select * into v_job from jobs where project_id = job;
    if v_job.id is null then result := 'Left alone: no job ' || job; return next; continue; end if;
    select * into v_lo from loadouts l where l.job_id = v_job.id and l.voided_at is null
     order by (l.started_at <= o.created_at) desc, l.started_at desc limit 1;
    if v_lo.id is null then result := 'Left alone: ' || job || ' has no trip to put it on'; return next; continue; end if;
    v_cid := substring(o.name from '([0-9a-f-]{36})\.jpg$')::uuid;
    v_size := coalesce((o.metadata ->> 'size')::bigint, 0);
    insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, note, storage_path, bytes,
                        is_test, taken_by, taken_by_name, taken_at, shot_at)
    values (v_cid, v_job.id, null, 'delivery', 'loadout', v_lo.id,
            format('Put back by hand %s: sent %s by %s; which table it shows isn''t known',
                   to_char(now() at time zone 'America/Indiana/Indianapolis', 'FMMon FMDD'), sent, sent_by),
            o.name, v_size, v_job.is_test, v_who.id, v_who.full_name, o.created_at, o.created_at)
    on conflict (client_id) do nothing;
    result := format('Put back on the %s of %s, with no table', trip_kind_name(v_lo.kind),
                     to_char(coalesce(v_lo.scheduled_for, v_lo.ready_at, v_lo.started_at) at time zone 'America/Indiana/Indianapolis', 'Mon DD'));
    return next;
  end loop;
end $$;
revoke all on function put_back_stray_photos(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. The check (runs as each login; everything it makes is undone)
-- ---------------------------------------------------------------------
create or replace function check_delivery_photos_open()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sch uuid; dlv uuid; oth uuid;
  ja uuid; wo uuid; lo1 uuid; lo2 uuid; lo3 uuid; lo4 uuid; e1 uuid; e2 uuid; e3 uuid; e4 uuid;
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid(); c4 uuid := gen_random_uuid();
  f1 uuid := gen_random_uuid(); f2 uuid := gen_random_uuid(); f3 uuid := gen_random_uuid(); f4 uuid := gen_random_uuid(); f5 uuid := gen_random_uuid();
  r jsonb; n int; m int; ok boolean; msg text; t1 timestamptz; t2 timestamptz;   claims text;
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

  -- ---- 1: locked down ---------------------------------------------------------------------------------------
  ok := not has_table_privilege('authenticated', 'public.device_unsent', 'select,insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('anon', 'public.device_unsent', 'select,insert,update,delete,truncate,references,trigger')
        and (select relrowsecurity from pg_class where oid = 'public.device_unsent'::regclass)
        and not has_function_privilege('anon', 'public.report_unsent(text,integer,integer,timestamp with time zone,text[])', 'execute')
        and not has_function_privilege('anon', 'public.unsent_on_phones()', 'execute')
        and not has_function_privilege('authenticated', 'public.put_back_stray_photos(text)', 'execute')
        and not has_function_privilege('authenticated', 'public.clear_empty_trips(timestamp with time zone)', 'execute')
        and not has_table_privilege('anon', 'public.v_trips_out', 'select')
        and has_table_privilege('authenticated', 'public.v_trips_out', 'select');
  res := res || check_row(1, 'Nobody reads or writes the phones'' reports directly; putting photos back and clearing trips are for the SQL Editor only', ok,
                          case when ok then null else 'A grant is wrong. Run delivery_photos_open.sql again.' end);

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999462, 'DPOCHECK-A', 'Delivery photos check - undone automatically', true, 'In Production') returning id into ja;
    insert into work_orders (job_id, version, is_current) values (ja, 1, true) returning id into wo;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (wo, 1, 3, 'dpocheck-1');
    set constraints all immediate;
    claims := json_build_object('sub', sch, 'role', 'authenticated')::text;
    perform set_config('request.jwt.claims', claims, true);
    execute 'set local role authenticated';
    perform schedule_delivery(ja, now() + interval '1 day', 'Check', null, c1, 'delivery');
    perform schedule_delivery(ja, now() + interval '2 days', 'Check', null, c2, 'delivery');
    perform schedule_delivery(ja, now() + interval '3 days', 'Check', null, c3, 'delivery');
    execute 'reset role';
    select id into lo1 from loadouts where client_id = c1;
    select id into lo2 from loadouts where client_id = c2;
    select id into lo3 from loadouts where client_id = c3;
    -- trip 1: its truck left 4 days ago, still open. trip 2: marked delivered 2 days ago. trip 3: cancelled.
    update loadouts set finished_at = now() - interval '4 days', finished_by_name = 'Check' where id = lo1;
    update loadouts set finished_at = now() - interval '2 days', completed_at = now() - interval '2 days', completed_by_name = 'Check' where id = lo2;
    update loadouts set voided_at = now(), voided_by_name = 'Check', void_reason = 'Check' where id = lo3;
    -- an old-style load-out (no site or pickup steps), finished 4 days ago
    insert into loadouts (client_id, job_id, kind, site_steps, pickup_steps, started_by_name, started_at, finished_at)
    values (c4, ja, 'shipping', false, false, 'Check', now() - interval '5 days', now() - interval '4 days') returning id into lo4;
    insert into storage.objects (bucket_id, name, metadata)
    select 'photos', 'DPOCHECK-A/' || f || '.jpg', '{"size": "10", "mimetype": "image/jpeg"}' from unnest(array[f1, f2, f3, f4]) f;

    -- ---- 2: a trip kept open takes photos, however long ago the truck left ----------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := add_delivery_photo(p_client_id => f1, p_loadout => c1, p_stage => 'site', p_sheet => 1, p_piece => 3);
      execute 'reset role';
      select count(*) into n from photos where client_id = f1 and loadout_id = lo1 and stage = 'site' and sheet_number = 1 and piece = 3;
      ok := (r->>'ok')::boolean and n = 1; msg := coalesce(r->>'summary', '') || format(' (%s saved)', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Refused: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Delivery photographs a table at the site on a trip whose truck left 4 days ago and isn''t marked delivered: it''s saved, with its table', ok, msg);

    -- ---- 3: still turned away: marked delivered 2 days ago, cancelled, an old-style load-out after 3 days -----
    ok := true; msg := '';
    begin execute 'set local role authenticated';
      perform add_delivery_photo(p_client_id => f2, p_loadout => c2, p_stage => 'site', p_sheet => 1, p_piece => 1);
      execute 'reset role'; ok := false; msg := msg || 'a trip delivered 2 days ago took a photo. ';
    exception when others then execute 'reset role'; end;
    begin execute 'set local role authenticated';
      perform add_delivery_photo(p_client_id => f3, p_loadout => c3, p_stage => 'site', p_sheet => 1, p_piece => 1);
      execute 'reset role'; ok := false; msg := msg || 'a cancelled trip took a photo. ';
    exception when others then execute 'reset role'; end;
    begin execute 'set local role authenticated';
      perform add_photo(f4, 'loadout', c4, 1, null, 800, 600);
      execute 'reset role'; ok := false; msg := msg || 'an old-style load-out finished 4 days ago took a photo. ';
    exception when others then execute 'reset role';
      if sqlerrm not like 'That load-out finished on%' then ok := false; msg := msg || 'the old-style load-out said: ' || sqlerrm; end if;
    end;
    select count(*) into n from photos where client_id in (f2, f3, f4);
    if n > 0 then ok := false; msg := msg || n || ' saved anyway.'; end if;
    res := res || check_row(3, 'Still turned away: a trip marked delivered 2 days ago, a cancelled trip, and an old-style load-out 3 days after it finished', ok, msg);

    -- ---- 4: the phone reports what it couldn't send; Julia's page reads it ----------------------------------
    begin
      execute 'set local role authenticated';
      perform report_unsent('DPOCHECK-DEVICE-1', 7, 6, now() - interval '3 hours', '{DPOCHECK-A}');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*), max(u.items) into n, m from unsent_on_phones() u where 'DPOCHECK-A' = any(u.jobs);
      execute 'reset role';
      ok := n = 1 and m = 7; msg := format('the scheduler saw %s report(s), %s things', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform * from unsent_on_phones();
      execute 'reset role'; ok := false; msg := msg || ' · another supervisor could read it';
    exception when others then execute 'reset role';
    end;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform report_unsent('DPOCHECK-DEVICE-1', 0, 0, null, '{}');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from unsent_on_phones() u where 'DPOCHECK-A' = any(u.jobs);
      execute 'reset role';
      if n <> 0 then ok := false; msg := msg || ' · still shown after the phone sent everything'; end if;
    exception when others then execute 'reset role'; ok := false; msg := msg || ' · Error: ' || sqlerrm;
    end;
    begin
      execute 'set local role authenticated';
      perform report_unsent('x', -1, 0, null, '{}');
      execute 'reset role'; ok := false; msg := msg || ' · a nonsense report was taken';
    exception when others then execute 'reset role';
    end;
    res := res || check_row(4, 'Delivery''s phone reports how many things it couldn''t send; the scheduler and managers see it, another supervisor can''t; it goes when the phone has sent everything', ok, msg);

    -- ---- 5: v_trips_out: an open trip's first and last photo; not a done one ----------------------------------
    update photos set shot_at = now() - interval '3 days' where client_id = f1;
    insert into storage.objects (bucket_id, name, metadata) values ('photos', 'DPOCHECK-A/' || f5 || '.jpg', '{"size": "10"}');
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform add_delivery_photo(p_client_id => f5, p_loadout => c1, p_stage => 'site', p_sheet => 1, p_piece => 2, p_shot_at => now() - interval '1 hour');
      select first_photo_at, last_photo_at, photos into t1, t2, n from v_trips_out where client_id = c1;
      select count(*) into m from v_trips_out where client_id in (c2, c3);
      execute 'reset role';
      ok := n = 2 and t1 < now() - interval '2 days' and t2 > now() - interval '2 hours' and m = 0;
      msg := format('photos %s, first %s, last %s, done or cancelled trips listed %s', n, t1, t2, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Each open trip''s first and last photo, for "Out since"; trips done or cancelled aren''t listed', ok, msg);

    -- ---- 6: empty load-outs started on the phone are marked entered by mistake; nothing else is ---------------
    insert into loadouts (client_id, job_id, kind, site_steps, started_by_name, started_at)
      values (gen_random_uuid(), ja, 'delivery', true, 'Check', now() - interval '10 days') returning id into e1;      -- empty: cleared
    insert into loadouts (client_id, job_id, kind, site_steps, started_by_name, started_at)
      values (gen_random_uuid(), ja, 'delivery', true, 'Check', now() - interval '10 days') returning id into e2;      -- the rest of a trip, waiting
    insert into trip_parts (loadout_id, rest_id, reason, went_pieces, left_pieces) values (lo2, e2, 'Site not ready', '{1:1}', '{1:2}');
    insert into loadouts (client_id, job_id, kind, site_steps, started_by_name, started_at)
      values (gen_random_uuid(), ja, 'delivery', true, 'Check', now() - interval '10 days') returning id into e3;      -- has a photo
    insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, storage_path, taken_by_name)
      values (gen_random_uuid(), ja, 1, 'delivery', 'loadout', e3, 'DPOCHECK-A/x.jpg', 'Check');
    insert into loadouts (client_id, job_id, kind, site_steps, started_by_name, started_at)
      values (gen_random_uuid(), ja, 'delivery', true, 'Check', now() - interval '1 hour') returning id into e4;       -- started after the cut-off
    begin
      n := clear_empty_trips(now() - interval '1 day');
      m := clear_empty_trips(now() - interval '1 day');
      ok := (select voided_at is not null from loadouts where id = e1) and (select voided_at is null from loadouts where id = e2)
            and (select voided_at is null from loadouts where id = e3) and (select voided_at is null from loadouts where id = e4)
            and (select voided_at is null from loadouts where id = lo1) and (select voided_at is null from loadouts where id = lo4) and m = 0;
      msg := format('first run cleared %s, the second %s', n, m);
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A load-out started on the phone and never used is marked entered by mistake (kept); a rest waiting for its day, one with a photo, a scheduled one and a new one aren''t; running it again changes nothing', ok, msg);

    -- ---- 7: a turned-away photo file is put back on its job's trip, once, with no table ----------------------
    insert into storage.objects (bucket_id, name, metadata, created_at, owner_id)
      values ('photos', 'DPOCHECK-A/' || c4 || '.jpg', '{"size": "12"}', now() - interval '2 hours', dlv::text);
    begin
      select count(*) into n from put_back_stray_photos() x where x.job = 'DPOCHECK-A';
      select count(*) into m from photos where client_id = c4;
      ok := n >= 1 and m = 0; msg := format('listed %s, put back %s with no PROJ number', n, m);
      select count(*) into n from put_back_stray_photos('DPOCHECK-A') x where x.result like 'Put back%';
      select count(*) into m from photos where client_id = c4 and loadout_id is not null and sheet_number is null and note like 'Put back by hand%';
      if not (n >= 1 and m = 1) then ok := false; msg := msg || format(' · with it: %s said put back, %s saved', n, m); end if;
      select count(*) into n from put_back_stray_photos('DPOCHECK-A') x where x.result like 'Put back%';
      if n <> 0 then ok := false; msg := msg || ' · a second run put it back again'; end if;
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := add_delivery_photo(p_client_id => c4, p_loadout => c1, p_stage => 'site', p_sheet => 1, p_piece => 1);
      execute 'reset role';
      if not coalesce((r->>'already')::boolean, false) then ok := false; msg := msg || ' · the phone sending it later wasn''t "already saved"'; end if;
    exception when others then execute 'reset role'; ok := false; msg := msg || ' · Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A photo file that reached Supabase but was turned away: listed, put on its job''s trip with no table only when asked by PROJ number, once; the phone sending it later is "already saved"', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_delivery_photos_open_undo__';
  exception when others then
    if sqlerrm <> '__check_delivery_photos_open_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_delivery_photos_open() from public, anon, authenticated;

select * from check_delivery_photos_open();
