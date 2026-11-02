-- =====================================================================
-- off_supabase.sql — saved files come off Supabase (31 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 48. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE the new office page goes on GitHub. The pages there now
-- keep working with it: nothing they read changes.
--
-- WHAT IT DOES (design: the OneDrive saving tab, 5 Oct, and the Outputs
-- zip & OneDrive filing tab, 31 Oct)
-- A photo or delivery file leaves Supabase once its job has been past
-- Delivery for 60 days (and the file itself is 60 days old), and the
-- office's save has found it, at the same size, in both the job's
-- OneDrive folder and the backup folder within the last day. A trip's
-- ticket and signature also wait until its signed ticket is in both
-- places. Every record stays for good; only the file's bytes leave
-- Supabase. This takes over from the monthly photo archive, which the
-- office page stops offering.
-- 1. filed_copies: what the save found where (file, place, size, when).
--    Managers read it; no login writes it directly.
-- 2. record_filed_copies(): the save reports what it found.
-- 3. save_due_jobs(): the jobs with files due off Supabase, so the save
--    looks at them even when nothing on them has changed.
-- 4. filed_removable() and a storage rule: a manager may remove a photo
--    or delivery file from Supabase only when all of the above holds.
-- 5. files_ready_to_remove() and mark_filed_removed(): the list the
--    page removes through Supabase's storage, and the record of it
--    (only files really gone are marked).
-- 6. off_supabase_status(): space used, how many files have come off,
--    how many are due now, and when the next ones are.
-- Nothing existing changes, and nothing is deleted from the database.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('off_supabase.sql', 48, 'check_off_supabase', 'check_off_supabase', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('off_supabase.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regclass('public.photos') is null then raise exception 'Run photos.sql first. This file builds on it.'; end if;
  if to_regclass('public.delivery_docs') is null then raise exception 'Run deliveries.sql first. This file builds on it.'; end if;
  if to_regclass('public.save_runs') is null then raise exception 'Run onedrive_save.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. What the save found where. One row per file and place, replaced
--    each time the save looks again. Row-level security on; managers
--    read it; only record_filed_copies() writes it.
--    source: photo (photos), doc (delivery_docs: a ticket, signature or
--    site file) or signed (a trip's signed ticket, made by the page;
--    file_id is the trip's id). place: onedrive or backup.
-- ---------------------------------------------------------------------

create table if not exists filed_copies (
  source     text        not null,
  file_id    uuid        not null,
  place      text        not null,
  bytes      bigint      not null,
  checked_at timestamptz not null default now(),
  checked_by uuid        references profiles(id),
  primary key (source, file_id, place),
  constraint filed_copies_source check (source in ('photo', 'doc', 'signed')),
  constraint filed_copies_place  check (place in ('onedrive', 'backup')),
  constraint filed_copies_bytes  check (bytes > 0)
);

alter table filed_copies enable row level security;
revoke all on filed_copies from anon, authenticated;
grant select on filed_copies to authenticated;                 -- which rows: the policy below
drop policy if exists filed_copies_office_reads on filed_copies;
create policy filed_copies_office_reads on filed_copies for select to authenticated using (is_manager());


-- ---------------------------------------------------------------------
-- 2. When is a file due off Supabase? Its job is a real job, off the
--    floor (past Delivery) for 60 days or more, and the file is 60 days
--    old or more. The same rule the monthly archive used (photos.sql).
-- ---------------------------------------------------------------------

create or replace function off_due(p_job uuid, p_at timestamptz, p_test boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce(p_test, true)
     and p_at <= now() - interval '60 days'
     and exists (select 1 from jobs j
                  where j.id = p_job and not j.is_test
                    and not job_on_floor(j.is_active, j.is_test, j.phase)
                    and j.floor_left_at <= now() - interval '60 days');
$$;
revoke all on function off_due(uuid, timestamptz, boolean) from public, anon, authenticated;

-- every file due off Supabase and still there
create or replace function off_due_files()
returns table (source text, id uuid, job_id uuid, bucket text, path text, loadout_id uuid, kind text)
language sql stable security definer set search_path = public as $$
  select 'photo'::text, p.id, p.job_id, 'photos'::text, p.storage_path, p.loadout_id, p.kind
    from photos p
   where p.file_removed_at is null and off_due(p.job_id, p.taken_at, p.is_test)
  union all
  select 'doc'::text, d.id, d.job_id, 'deliveries'::text, d.storage_path, d.loadout_id, d.kind
    from delivery_docs d
   where d.file_removed_at is null and off_due(d.job_id, d.added_at, d.is_test);
$$;
revoke all on function off_due_files() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. The save reports what it found: [{source, id, place, bytes}, ...]
--    Unknown files and nonsense are left out. Managers only.
-- ---------------------------------------------------------------------

create or replace function record_filed_copies(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not office_ok() or auth.uid() is null then
    raise exception 'Only a manager''s office page reports saved copies.' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p) is distinct from 'array' then raise exception 'Send a list of copies.'; end if;
  if jsonb_array_length(p) > 2000 then raise exception 'Send 2,000 copies or fewer at a time.'; end if;
  insert into filed_copies (source, file_id, place, bytes, checked_at, checked_by)
  select distinct on (x.source, x.id, x.place) x.source, x.id, x.place, x.bytes, now(), auth.uid()
    from jsonb_to_recordset(p) as x(source text, id uuid, place text, bytes bigint)
   where x.source in ('photo', 'doc', 'signed') and x.place in ('onedrive', 'backup') and x.bytes > 0
     and ((x.source = 'photo'  and exists (select 1 from photos t where t.id = x.id))
       or (x.source = 'doc'    and exists (select 1 from delivery_docs t where t.id = x.id))
       or (x.source = 'signed' and exists (select 1 from loadouts t where t.id = x.id)))
   order by x.source, x.id, x.place, x.bytes desc
  on conflict (source, file_id, place) do update
    set bytes = excluded.bytes, checked_at = excluded.checked_at, checked_by = excluded.checked_by;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function record_filed_copies(jsonb) from public, anon;
grant execute on function record_filed_copies(jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 4. The jobs with files due off Supabase (at most 200 a time), so the
--    save checks them in both places even when nothing on them changed.
-- ---------------------------------------------------------------------

create or replace function save_due_jobs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can save the shop floor''s files.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('job_id', x.id, 'project_id', x.project_id, 'name', x.name) order by x.project_id)
      from (select jb.id, jb.project_id, jb.name from jobs jb
             where jb.project_id is not null and not jb.is_test
               and jb.id in (select f.job_id from off_due_files() f)
             order by jb.project_id limit 200) x), '[]'::jsonb);
end $$;
revoke all on function save_due_jobs() from public, anon;
grant execute on function save_due_jobs() to authenticated;


-- ---------------------------------------------------------------------
-- 5. May this file come off Supabase? (The storage rule below asks.)
--    Due (section 2), and the save found it in both places within the
--    last day at exactly its size in Supabase. A trip's ticket or
--    signature also needs the trip's signed ticket found in both places.
-- ---------------------------------------------------------------------

create or replace function filed_removable(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_size bigint;
  v_src text; v_id uuid; v_job uuid; v_lo uuid; v_kind text; v_at timestamptz; v_test boolean;
  n int;
begin
  if p_bucket is null or p_bucket not in ('photos', 'deliveries') or p_name is null then return false; end if;
  select (o.metadata ->> 'size')::bigint into v_size from storage.objects o where o.bucket_id = p_bucket and o.name = p_name;
  if coalesce(v_size, 0) <= 0 then return false; end if;
  if p_bucket = 'photos' then
    select 'photo', p.id, p.job_id, p.loadout_id, p.kind, p.taken_at, p.is_test
      into v_src, v_id, v_job, v_lo, v_kind, v_at, v_test
      from photos p where p.storage_path = p_name and p.file_removed_at is null;
  else
    select 'doc', d.id, d.job_id, d.loadout_id, d.kind, d.added_at, d.is_test
      into v_src, v_id, v_job, v_lo, v_kind, v_at, v_test
      from delivery_docs d where d.storage_path = p_name and d.file_removed_at is null;
  end if;
  if v_id is null or not off_due(v_job, v_at, v_test) then return false; end if;
  select count(*) into n from filed_copies c
   where c.source = v_src and c.file_id = v_id and c.bytes = v_size and c.checked_at > now() - interval '1 day';
  if n < 2 then return false; end if;
  if v_src = 'doc' and v_kind in ('ticket', 'signature')
     and exists (select 1 from loadouts l where l.id = v_lo and l.completed_at is not null and l.voided_at is null and l.kind <> 'shipping') then
    select count(*) into n from filed_copies c
     where c.source = 'signed' and c.file_id = v_lo and c.checked_at > now() - interval '1 day';
    if n < 2 then return false; end if;
  end if;
  return true;
end $$;
revoke all on function filed_removable(text, text) from public, anon;
grant execute on function filed_removable(text, text) to authenticated;   -- the storage rule runs as the login

-- only a manager removes a file, and only one this says may go (the archive's own rules stay as they were)
drop policy if exists "shop floor: remove saved files" on storage.objects;
create policy "shop floor: remove saved files" on storage.objects for delete to authenticated
  using (bucket_id in ('photos', 'deliveries') and public.is_manager() and public.filed_removable(bucket_id, name));


-- ---------------------------------------------------------------------
-- 6. The list the page removes, and the record of it
-- ---------------------------------------------------------------------

create or replace function files_ready_to_remove(p_limit int default 500) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can take files off Supabase.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('source', x.source, 'id', x.id, 'bucket', x.bucket, 'path', x.path) order by x.bucket, x.path)
      from (select f.source, f.id, f.bucket, f.path from off_due_files() f
             where filed_removable(f.bucket, f.path)
             order by f.bucket, f.path
             limit least(greatest(coalesce(p_limit, 500), 1), 1000)) x), '[]'::jsonb);
end $$;
revoke all on function files_ready_to_remove(int) from public, anon;
grant execute on function files_ready_to_remove(int) to authenticated;

-- after the page has removed files through Supabase's storage: [{source, id}, ...]
-- Marked only if the file was due, was found in both places, and really is gone.
create or replace function mark_filed_removed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n1 int; n2 int;
begin
  if not office_ok() then
    raise exception 'Only a manager can take files off Supabase.' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p) is distinct from 'array' then raise exception 'Send a list of files.'; end if;
  if jsonb_array_length(p) > 1000 then raise exception 'Mark 1,000 files or fewer at a time.'; end if;
  update photos ph set file_removed_at = now()
    from (select (x ->> 'id')::uuid as id from jsonb_array_elements(p) x where x ->> 'source' = 'photo') ids
   where ph.id = ids.id and ph.file_removed_at is null
     and off_due(ph.job_id, ph.taken_at, ph.is_test)
     and (select count(*) from filed_copies c where c.source = 'photo' and c.file_id = ph.id) = 2
     and not exists (select 1 from storage.objects o where o.bucket_id = 'photos' and o.name = ph.storage_path);
  get diagnostics n1 = row_count;
  update delivery_docs d set file_removed_at = now()
    from (select (x ->> 'id')::uuid as id from jsonb_array_elements(p) x where x ->> 'source' = 'doc') ids
   where d.id = ids.id and d.file_removed_at is null
     and off_due(d.job_id, d.added_at, d.is_test)
     and (select count(*) from filed_copies c where c.source = 'doc' and c.file_id = d.id) = 2
     and not exists (select 1 from storage.objects o where o.bucket_id = 'deliveries' and o.name = d.storage_path);
  get diagnostics n2 = row_count;
  return jsonb_build_object('ok', true, 'photos', n1, 'files', n2);
end $$;
revoke all on function mark_filed_removed(jsonb) from public, anon;
grant execute on function mark_filed_removed(jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 7. For the office's Photos tab: space used, how many have come off,
--    how many are due now, and when the next ones are due.
-- ---------------------------------------------------------------------

create or replace function off_supabase_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_next timestamptz;
begin
  if not office_ok() then
    raise exception 'Only a manager can see this.' using errcode = 'insufficient_privilege';
  end if;
  select min(greatest(j.floor_left_at, x.at) + interval '60 days') into v_next
    from (select p.job_id, p.taken_at as at from photos p where p.file_removed_at is null and not p.is_test
          union all
          select d.job_id, d.added_at from delivery_docs d where d.file_removed_at is null and not d.is_test) x
    join jobs j on j.id = x.job_id
   where not j.is_test and not job_on_floor(j.is_active, j.is_test, j.phase) and j.floor_left_at is not null
     and greatest(j.floor_left_at, x.at) > now() - interval '60 days';
  return jsonb_build_object(
    'bytes_all',         (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o),
    'bytes_photos',      (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o where o.bucket_id = 'photos'),
    'bytes_deliveries',  (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o where o.bucket_id = 'deliveries'),
    'bytes_work_orders', (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o where o.bucket_id = 'work-orders'),
    'free_plan_bytes',   1073741824,
    'off_so_far',        (select count(*) from photos where file_removed_at is not null and archive_batch is null)
                       + (select count(*) from delivery_docs where file_removed_at is not null and archive_batch is null),
    'due',               (select count(*) from off_due_files()),
    'next_due_at',       v_next);
end $$;
revoke all on function off_supabase_status() from public, anon;
grant execute on function off_supabase_status() to authenticated;


-- ---------------------------------------------------------------------
-- 8. The check. It practises on its own jobs, files and trip, as a
--    manager and a supervisor signed in, and undoes all of it at the end.
-- ---------------------------------------------------------------------

create or replace function check_off_supabase()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  mgr      uuid;  sup uuid;
  as_mgr   text;  as_sup text;
  v_off    uuid;  v_on uuid;  v_lo uuid;  v_lo2 uuid;
  ph_old   uuid := gen_random_uuid();     -- a photo on the job that left the floor 61 days ago, 61 days old
  ph_new   uuid := gen_random_uuid();     -- the same job, but 30 days old
  ph_on    uuid := gen_random_uuid();     -- a 61-day-old photo on a job still on the floor
  ph_x     uuid := gen_random_uuid();     -- another 61-day-old photo on the job that left: never found by a save
  dc_tkt   uuid := gen_random_uuid();     -- the trip's ticket
  dc_site  uuid := gen_random_uuid();     -- a site file on the same trip
  p_old text; p_new text; p_on text; p_tkt text; p_site text; p_x text;
  v        jsonb;
  n        int;
  ok       boolean;
  msg      text;
  t        record;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test limit 1;
  if mgr is null or sup is null then
    res := res || check_row(1, 'A manager and a supervisor have logins to test with', false, 'Set up the logins first.');
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;

  -- ---- 1. the table and who may do what ---------------------------------
  ok := to_regclass('public.filed_copies') is not null
        and (select relrowsecurity from pg_class where oid = 'public.filed_copies'::regclass)
        and not has_table_privilege('authenticated', 'public.filed_copies', 'insert')
        and not has_table_privilege('authenticated', 'public.filed_copies', 'update')
        and not has_table_privilege('authenticated', 'public.filed_copies', 'delete')
        and not has_table_privilege('anon', 'public.filed_copies', 'select');
  res := res || check_row(1, 'The saved-copies table is there, with row-level security; no login writes it directly', ok,
    'The table is missing, has no row-level security, or a login can write it. Run off_supabase.sql again.');

  ok := true; msg := null;
  for t in select x.f from unnest(array['record_filed_copies(jsonb)', 'save_due_jobs()', 'filed_removable(text,text)',
                                        'files_ready_to_remove(integer)', 'mark_filed_removed(jsonb)', 'off_supabase_status()']) as x(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then
      ok := false; msg := concat_ws(' ', msg, t.f);
    end if;
  end loop;
  ok := ok and not has_function_privilege('authenticated', 'public.off_due_files()', 'execute')
           and not has_function_privilege('authenticated', 'public.off_due(uuid,timestamp with time zone,boolean)', 'execute')
           and exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                         and policyname = 'shop floor: remove saved files' and cmd = 'DELETE');
  res := res || check_row(2, 'Its functions need a login, and storage has the rule for removing saved files', ok,
    coalesce('Missing, or open to no login: ' || msg, 'The storage rule is missing, or an inside helper is open to logins. Run off_supabase.sql again.'));

  -- everything below is undone at the end, whatever happens
  begin
    insert into jobs (monday_item_id, project_id, name, is_active, phase, floor_left_at)
      values (-999981, 'OFFCHECK', 'Off Supabase check - undone automatically', false, 'Complete', now() - interval '61 days')
      returning id into v_off;
    insert into jobs (monday_item_id, project_id, name, is_active, phase)
      values (-999982, 'OFFCHECKFLOOR', 'Off Supabase check, on the floor - undone automatically', true, 'In Production')
      returning id into v_on;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_off;   -- the trigger stamps today on insert otherwise
    update jobs set floor_left_at = now() - interval '61 days' where id = v_on;    -- a stale stamp on a job back on the floor: it must still count as on the floor
    insert into loadouts (job_id, kind, scheduled_for, started_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
      values (v_off, 'delivery', now() - interval '62 days', now() - interval '62 days', now() - interval '61 days', 'Check',
              'Check Customer', now() - interval '61 days', now() - interval '61 days')
      returning id into v_lo;
    p_old := 'OFFCHECK/' || ph_old || '.jpg';  p_new := 'OFFCHECK/' || ph_new || '.jpg';  p_on := 'OFFCHECKFLOOR/' || ph_on || '.jpg';  p_x := 'OFFCHECK/' || ph_x || '.jpg';
    p_tkt := 'OFFCHECK/' || v_lo || '/' || dc_tkt || '.pdf';  p_site := 'OFFCHECK/' || v_lo || '/' || dc_site || '.pdf';

    -- the files, put there as the manager (as the office would)
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, metadata) values
      ('photos', p_old, '{"size": 300000, "mimetype": "image/jpeg"}'), ('photos', p_new, '{"size": 300000, "mimetype": "image/jpeg"}'),
      ('photos', p_on, '{"size": 300000, "mimetype": "image/jpeg"}'), ('photos', p_x, '{"size": 300000, "mimetype": "image/jpeg"}'),
      ('deliveries', p_tkt, '{"size": 90000, "mimetype": "application/pdf"}'), ('deliveries', p_site, '{"size": 50000, "mimetype": "application/pdf"}');
    execute 'reset role';
    insert into photos (id, client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes, taken_at) values
      (ph_old, gen_random_uuid(), v_off, 'delivery', 'loadout', v_lo, 1, 1, 'site', p_old, 'Check', 300000, now() - interval '61 days'),
      (ph_new, gen_random_uuid(), v_off, 'delivery', 'loadout', v_lo, 1, 2, 'site', p_new, 'Check', 300000, now() - interval '30 days'),
      (ph_x, gen_random_uuid(), v_off, 'delivery', 'loadout', v_lo, 1, 3, 'site', p_x, 'Check', 300000, now() - interval '61 days');
    insert into loadouts (job_id, kind) values (v_on, 'delivery') returning id into v_lo2;
    insert into photos (id, client_id, job_id, department, kind, loadout_id, sheet_number, piece, storage_path, taken_by_name, bytes, taken_at) values
      (ph_on, gen_random_uuid(), v_on, 'delivery', 'loadout', v_lo2, 1, 1, p_on, 'Check', 300000, now() - interval '61 days');
    insert into delivery_docs (id, client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, added_by_name, added_at) values
      (dc_tkt, gen_random_uuid(), v_lo, v_off, 'ticket', 'ticket.pdf', p_tkt, 'application/pdf', 90000, 'Check', now() - interval '61 days'),
      (dc_site, gen_random_uuid(), v_lo, v_off, 'site_file', 'plan.pdf', p_site, 'application/pdf', 50000, 'Check', now() - interval '61 days');

    -- ---- 3. a supervisor can't report copies --------------------------------
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', ph_old, 'place', 'onedrive', 'bytes', 300000)));
      execute 'reset role';
      ok := false; msg := 'A supervisor reported a saved copy.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Only a manager''s office page reports saved copies', ok, msg);

    -- ---- 4. not before the save has found it in both places ----------------
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'photo', 'id', ph_old, 'place', 'onedrive', 'bytes', 300000),
             jsonb_build_object('source', 'photo', 'id', ph_old, 'place', 'backup', 'bytes', 299999)));   -- the backup copy is the wrong size
      ok := not filed_removable('photos', p_old);
      v := record_filed_copies(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', gen_random_uuid(), 'place', 'backup', 'bytes', 5)));
      ok := ok and (v ->> 'recorded')::int = 0;                                                     -- a file that isn't there is left out
      execute 'reset role';
      msg := 'A photo found in one place only (the other copy a different size) could come off Supabase, or an unknown file was recorded.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A file found in one place only, or at a different size, stays on Supabase', ok, msg);

    -- ---- 5. found in both: it may go; newer files and jobs on the floor may not --------
    begin
      execute 'set local role authenticated';
      v := record_filed_copies((select jsonb_agg(jsonb_build_object('source', 'photo', 'id', a.id, 'place', b.pl, 'bytes', 300000))
                                  from unnest(array[ph_old, ph_new, ph_on]) as a(id), unnest(array['onedrive', 'backup']) as b(pl)));
      ok := filed_removable('photos', p_old) and not filed_removable('photos', p_new) and not filed_removable('photos', p_on);
      v := save_due_jobs();
      ok := ok and v @> jsonb_build_array(jsonb_build_object('project_id', 'OFFCHECK')) and not v @> jsonb_build_array(jsonb_build_object('project_id', 'OFFCHECKFLOOR'));
      execute 'reset role';
      msg := 'The 61-day-old photo found in both places can''t go, or a 30-day-old one or one on a job still on the floor could.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Found in both places at its size: it may go — but not a newer file, nor one on a job still on the floor', ok, msg);

    -- ---- 6. a ticket waits for the signed ticket ------------------------------
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'doc', 'id', dc_tkt, 'place', 'onedrive', 'bytes', 90000),
             jsonb_build_object('source', 'doc', 'id', dc_tkt, 'place', 'backup', 'bytes', 90000),
             jsonb_build_object('source', 'doc', 'id', dc_site, 'place', 'onedrive', 'bytes', 50000),
             jsonb_build_object('source', 'doc', 'id', dc_site, 'place', 'backup', 'bytes', 50000)));
      ok := not filed_removable('deliveries', p_tkt) and filed_removable('deliveries', p_site);
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'signed', 'id', v_lo, 'place', 'onedrive', 'bytes', 120000),
             jsonb_build_object('source', 'signed', 'id', v_lo, 'place', 'backup', 'bytes', 120000)));
      ok := ok and filed_removable('deliveries', p_tkt);
      execute 'reset role';
      msg := 'A trip''s ticket could go before its signed ticket was saved, or a site file found in both places couldn''t.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A trip''s ticket waits until its signed ticket is saved in both places too', ok, msg);

    -- ---- 7. a copy checked more than a day ago doesn't count ----------------
    update filed_copies set checked_at = now() - interval '25 hours' where source = 'doc' and file_id = dc_site and place = 'backup';
    ok := not filed_removable('deliveries', p_site);
    update filed_copies set checked_at = now() where source = 'doc' and file_id = dc_site and place = 'backup';
    ok := ok and filed_removable('deliveries', p_site);
    res := res || check_row(7, 'A copy found more than a day ago doesn''t count: the save looks again first', ok,
      'A file could come off Supabase on the strength of an old look in a folder.');

    -- ---- 8. the list the page removes ---------------------------------------
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := files_ready_to_remove(1000);
      execute 'reset role';
      ok := v @> jsonb_build_array(jsonb_build_object('path', p_old), jsonb_build_object('path', p_tkt), jsonb_build_object('path', p_site))
            and not v @> jsonb_build_array(jsonb_build_object('path', p_new)) and not v @> jsonb_build_array(jsonb_build_object('path', p_on))
            and not v @> jsonb_build_array(jsonb_build_object('path', p_x));                -- due, but never found by a save
      msg := 'The list of files to remove is wrong: ' || left(v::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'The office''s list holds exactly the files that may go', ok, msg);

    -- ---- 9. removing: a supervisor can't; a manager can; the record stays, marked ----------
    begin
      perform set_config('storage.allow_delete_query', 'true', true);         -- as Supabase's storage does for its own deletes
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin
        delete from storage.objects where bucket_id = 'photos' and name = p_old;
        get diagnostics n = row_count;
      exception when insufficient_privilege then n := 0;
      end;
      execute 'reset role';
      ok := n = 0;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      begin
        v := mark_filed_removed(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', ph_old)));
        ok := ok and (v ->> 'photos')::int = 0;                                 -- still in storage: not marked
        delete from storage.objects where bucket_id = 'photos' and name in (p_old, p_new);
        get diagnostics n = row_count;
        ok := ok and n = 1;                                                     -- the one that may go, not the newer one
        v := mark_filed_removed(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', ph_old), jsonb_build_object('source', 'photo', 'id', ph_new)));
        ok := ok and (v ->> 'photos')::int = 1;
      exception when others then
        -- this Supabase stops file deletes from SQL altogether; the rule itself was checked above
        if sqlerrm not ilike '%direct deletion%' then raise; end if;
      end;
      execute 'reset role';
      ok := ok and exists (select 1 from photos where id = ph_old) and exists (select 1 from photos where id = ph_new and file_removed_at is null);
      msg := 'A supervisor could remove a saved file, the wrong file could be removed, or a file still there was marked as gone.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'A manager removes it through storage; a supervisor can''t; the record stays', ok, msg);

    -- ---- 10. no login sees any of it ----------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select count(*) into n from filed_copies;
      execute 'reset role';
      ok := n = 0; msg := n || ' saved-copy rows are visible without logging in.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Someone with no login sees none of it', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_off_supabase_undo__';
  exception when others then
    if sqlerrm <> '__check_off_supabase_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('storage.allow_delete_query', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_off_supabase() from public, anon, authenticated;

select * from check_off_supabase();
