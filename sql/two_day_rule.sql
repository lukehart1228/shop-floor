-- =====================================================================
-- two_day_rule.sql — a file leaves Supabase only after its outside copy
-- has been seen on two different days (12 Nov 2026; review finding R-26)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 61. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table:
-- every row should say PASS. Run it BEFORE the new office page goes on
-- GitHub; the office page there now keeps working with it.
--
-- WHY
-- A photo, delivery file or zip file came off Supabase the moment the
-- office's save found it in the job's OneDrive folder and in the backup
-- folder, at its size. Both are folders on the office PC. The page can
-- see a file is in the OneDrive folder; it can't see whether OneDrive
-- has sent it to the cloud. If OneDrive were paused, signed out or full,
-- the save would find both copies, take the file off Supabase in the
-- same run, and the only copies would sit on one disk.
--
-- WHAT IT DOES
-- A file now leaves Supabase only when the save FIRST found each of its
-- copies at least a full day (24 hours) ago, and has found them again,
-- at the same size, within the last day. So a copy is always seen on two
-- different days, and a OneDrive problem has a day to show before
-- anything leaves. A copy whose size changes starts its day again.
-- 1. filed_copies.first_seen: when the save first found that copy at
--    that size. Rows already there start their day from the last time
--    they were found.
-- 2. parked_files.onedrive_first_at and backup_first_at: the same, for
--    files from dropped zips.
-- 3. record_filed_copies(), filed_removable() (from off_supabase.sql) and
--    record_parked_filed(), parked_removable() (from zip_drop.sql) keep
--    and use those times. Nothing else about them changes.
-- 4. check_off_supabase() and check_zip_drop() practise the two days.
-- Nothing on a tablet, the Delivery phone or the TV changes. In the
-- office, a zip's files now stay on Supabase one day longer, and nothing
-- is deleted: every record stays, as before.
--
-- Replaces pieces of off_supabase.sql, zip_drop.sql and short_names.sql
-- (check_zip_drop), so those files now stop if run again.
-- Ends with check_two_day_rule().
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('two_day_rule.sql', 61, 'check_two_day_rule', 'check_two_day_rule', '{off_supabase.sql,zip_drop.sql,short_names.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('two_day_rule.sql', '{off_supabase.sql,zip_drop.sql,short_names.sql}'); end if;
end $$;

do $$ begin
  if to_regclass('public.filed_copies') is null then raise exception 'Run off_supabase.sql first. This file builds on it.'; end if;
  if to_regclass('public.parked_files') is null then raise exception 'Run zip_drop.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_short_names()') is null then raise exception 'Run short_names.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. When each copy was first found
-- ---------------------------------------------------------------------

-- a photo's, delivery file's or signed ticket's copy: first found (at this size)
alter table filed_copies add column if not exists first_seen timestamptz;
update filed_copies set first_seen = checked_at where first_seen is null;      -- rows from before today: the day starts at their last look
alter table filed_copies alter column first_seen set default now();
alter table filed_copies alter column first_seen set not null;

-- a zip's file: first found in each place (at the size it is there now)
alter table parked_files add column if not exists onedrive_first_at timestamptz;
alter table parked_files add column if not exists backup_first_at   timestamptz;
update parked_files set onedrive_first_at = onedrive_at where onedrive_first_at is null and onedrive_at is not null;
update parked_files set backup_first_at   = backup_at   where backup_first_at   is null and backup_at   is not null;


-- ---------------------------------------------------------------------
-- 2. The save reports what it found (as before); the first time a copy
--    is found at a size is kept, and a different size starts again.
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
  insert into filed_copies (source, file_id, place, bytes, checked_at, checked_by, first_seen)
  select distinct on (x.source, x.id, x.place) x.source, x.id, x.place, x.bytes, now(), auth.uid(), now()
    from jsonb_to_recordset(p) as x(source text, id uuid, place text, bytes bigint)
   where x.source in ('photo', 'doc', 'signed') and x.place in ('onedrive', 'backup') and x.bytes > 0
     and ((x.source = 'photo'  and exists (select 1 from photos t where t.id = x.id))
       or (x.source = 'doc'    and exists (select 1 from delivery_docs t where t.id = x.id))
       or (x.source = 'signed' and exists (select 1 from loadouts t where t.id = x.id)))
   order by x.source, x.id, x.place, x.bytes desc
  on conflict (source, file_id, place) do update
    set bytes = excluded.bytes, checked_at = excluded.checked_at, checked_by = excluded.checked_by,
        first_seen = case when filed_copies.bytes = excluded.bytes then filed_copies.first_seen else excluded.checked_at end;   -- R-26
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function record_filed_copies(jsonb) from public, anon;
grant execute on function record_filed_copies(jsonb) to authenticated;

create or replace function record_parked_filed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0; v_name text;
begin
  if not office_ok() or auth.uid() is null then
    raise exception 'Only a manager''s office page reports filed files.' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p) is distinct from 'array' then raise exception 'Send a list of filed files.'; end if;
  if jsonb_array_length(p) > 2000 then raise exception 'Send 2,000 or fewer at a time.'; end if;
  for x in select * from jsonb_array_elements(p) loop
    if x ->> 'place' not in ('onedrive', 'backup') or coalesce((x ->> 'bytes')::bigint, 0) <= 0 then continue; end if;
    v_name := nullif(btrim(coalesce(x ->> 'name', '')), '');
    update parked_files f set
        filed_name     = coalesce(f.filed_name, v_name),
        onedrive_bytes = case when x ->> 'place' = 'onedrive' then (x ->> 'bytes')::bigint else f.onedrive_bytes end,
        onedrive_at    = case when x ->> 'place' = 'onedrive' then now() else f.onedrive_at end,
        onedrive_first_at = case when x ->> 'place' = 'onedrive' and (f.onedrive_first_at is null or f.onedrive_bytes is distinct from (x ->> 'bytes')::bigint)
                                 then now() else f.onedrive_first_at end,                         -- R-26: first found at this size
        backup_bytes   = case when x ->> 'place' = 'backup' then (x ->> 'bytes')::bigint else f.backup_bytes end,
        backup_at      = case when x ->> 'place' = 'backup' then now() else f.backup_at end,
        backup_first_at   = case when x ->> 'place' = 'backup' and (f.backup_first_at is null or f.backup_bytes is distinct from (x ->> 'bytes')::bigint)
                                 then now() else f.backup_first_at end,
        held           = null
     where f.id = (x ->> 'id')::uuid and f.stored_at is not null and f.removed_at is null and f.same_as is null
       and (f.filed_name is null or v_name is null or f.filed_name = v_name);   -- one name in both places
    if found then n := n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function record_parked_filed(jsonb) from public, anon;
grant execute on function record_parked_filed(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 3. May this file come off Supabase? As before (due, found in both
--    places at exactly its size within the last day), and now also: each
--    of those copies was first found at least a full day ago.
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
   where c.source = v_src and c.file_id = v_id and c.bytes = v_size and c.checked_at > now() - interval '1 day'
     and c.first_seen <= now() - interval '1 day';                                  -- R-26: seen on two different days
  if n < 2 then return false; end if;
  if v_src = 'doc' and v_kind in ('ticket', 'signature')
     and exists (select 1 from loadouts l where l.id = v_lo and l.completed_at is not null and l.voided_at is null and l.kind <> 'shipping') then
    select count(*) into n from filed_copies c
     where c.source = 'signed' and c.file_id = v_lo and c.checked_at > now() - interval '1 day'
       and c.first_seen <= now() - interval '1 day';
    if n < 2 then return false; end if;
  end if;
  return true;
end $$;
revoke all on function filed_removable(text, text) from public, anon;
grant execute on function filed_removable(text, text) to authenticated;   -- the storage rule runs as the login

-- may this file come off Supabase? Filed in OneDrive and the backup folder, both found at exactly
-- its size within the last day, and both first found there at least a full day ago.
create or replace function parked_removable(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from parked_files f
      join storage.objects o on o.bucket_id = 'parked-files' and o.name = f.storage_path
     where f.storage_path = p_name and f.stored_at is not null and f.removed_at is null
       and (o.metadata ->> 'size')::bigint = f.size_bytes
       and f.onedrive_bytes = f.size_bytes and f.backup_bytes = f.size_bytes
       and f.onedrive_at > now() - interval '1 day' and f.backup_at > now() - interval '1 day'
       and f.onedrive_first_at <= now() - interval '1 day' and f.backup_first_at <= now() - interval '1 day');   -- R-26: seen on two different days
$$;
revoke all on function parked_removable(text) from public, anon;
grant execute on function parked_removable(text) to authenticated;    -- the storage rule runs as the login

-- ---------------------------------------------------------------------
-- 4. The two older checks, practising the two days (the rest of each is
--    as it was: check_off_supabase() from off_supabase.sql,
--    check_zip_drop() from short_names.sql).
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
    'The table is missing, has no row-level security, or a login can write it. Bring this line to Claude in a chat.');

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
    coalesce('Missing, or open to no login: ' || msg, 'The storage rule is missing, or an inside helper is open to logins. Bring this line to Claude in a chat.'));

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
      ok := not filed_removable('photos', p_old);                              -- found in both places only today: it waits a day (R-26)
      execute 'reset role';
      update filed_copies set first_seen = now() - interval '25 hours' where source = 'photo' and file_id in (ph_old, ph_new, ph_on);
      execute 'set local role authenticated';
      ok := ok and filed_removable('photos', p_old) and not filed_removable('photos', p_new) and not filed_removable('photos', p_on);
      v := save_due_jobs();
      ok := ok and v @> jsonb_build_array(jsonb_build_object('project_id', 'OFFCHECK')) and not v @> jsonb_build_array(jsonb_build_object('project_id', 'OFFCHECKFLOOR'));
      execute 'reset role';
      msg := 'The 61-day-old photo could go the day it was first found, can''t go a day later, or a 30-day-old one or one on a job still on the floor could.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Found in both places at its size on two different days: it may go — not on the first day, not a newer file, nor one on a job still on the floor', ok, msg);

    -- ---- 6. a ticket waits for the signed ticket ------------------------------
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'doc', 'id', dc_tkt, 'place', 'onedrive', 'bytes', 90000),
             jsonb_build_object('source', 'doc', 'id', dc_tkt, 'place', 'backup', 'bytes', 90000),
             jsonb_build_object('source', 'doc', 'id', dc_site, 'place', 'onedrive', 'bytes', 50000),
             jsonb_build_object('source', 'doc', 'id', dc_site, 'place', 'backup', 'bytes', 50000)));
      execute 'reset role';
      update filed_copies set first_seen = now() - interval '25 hours' where source = 'doc' and file_id in (dc_tkt, dc_site);
      execute 'set local role authenticated';
      ok := not filed_removable('deliveries', p_tkt) and filed_removable('deliveries', p_site);
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'signed', 'id', v_lo, 'place', 'onedrive', 'bytes', 120000),
             jsonb_build_object('source', 'signed', 'id', v_lo, 'place', 'backup', 'bytes', 120000)));
      ok := ok and not filed_removable('deliveries', p_tkt);                    -- the signed ticket was found only today
      execute 'reset role';
      update filed_copies set first_seen = now() - interval '25 hours' where source = 'signed' and file_id = v_lo;
      ok := ok and filed_removable('deliveries', p_tkt);
      msg := 'A trip''s ticket could go before its signed ticket had been saved for a day, or a site file found in both places couldn''t.';
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

create or replace function check_zip_drop()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  lab uuid; mgr uuid; sup uuid;
  as_lab text; as_mgr text; as_sup text;
  had_lab boolean := false;
  v jsonb; v2 jsonb; drp uuid; f1 uuid; f2 uuid; f3 uuid; p1 text; p2 text;
  sha1 text := repeat('a', 64); sha2 text := repeat('b', 64); sha3 text := repeat('c', 64);
  cont jsonb; files jsonb;
  n int; ok boolean; msg text; t record;
begin
  select l.user_id into lab from lab_users l join profiles p on p.id = l.user_id where p.active and not p.is_test limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test
     and (lab is null or id <> lab) and id not in (select user_id from lab_users) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test limit 1;
  if lab is null then           -- nobody let into the lab yet: borrow a manager for the check, undone at the end
    select id into lab from profiles where role in ('manager', 'admin') and active and not is_test and id is distinct from mgr limit 1;
  else had_lab := true;
  end if;
  if lab is null or mgr is null or sup is null then
    res := res || check_row(1, 'A lab login, another manager and a supervisor exist to test with', false, 'Set up the logins first (two managers and a supervisor).');
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;
  as_lab := json_build_object('sub', lab, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;

  -- ---- 1. tables locked, bucket private ------------------------------------
  ok := (select count(*) from pg_class where oid in ('public.zip_drops'::regclass, 'public.parked_files'::regclass) and relrowsecurity) = 2
        and exists (select 1 from storage.buckets where id = 'parked-files' and not public);
  for t in select x.tb from unnest(array['public.zip_drops', 'public.parked_files']) x(tb) loop
    ok := ok and not has_table_privilege('authenticated', t.tb, 'insert') and not has_table_privilege('authenticated', t.tb, 'update')
             and not has_table_privilege('authenticated', t.tb, 'delete') and not has_table_privilege('anon', t.tb, 'select');
  end loop;
  res := res || check_row(1, 'The two tables have row-level security, no login writes them directly, and the parked-files bucket is private', ok,
    'A table is missing its row-level security or can be written directly, or the bucket is public. Run zip_drop.sql again.');

  -- ---- 2. functions need a login ------------------------------------------
  ok := true; msg := null;
  for t in select x.f from unnest(array['zip_drop_new(text,jsonb,jsonb)', 'parked_file_stored(uuid)', 'zip_drop_finished(uuid,jsonb)',
         'parked_replace_ok(uuid)', 'parked_to_file()', 'record_parked_filed(jsonb)', 'hold_parked(jsonb)', 'parked_removable(text)',
         'parked_ready_to_remove()', 'mark_parked_removed(jsonb)']) x(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then ok := false; msg := concat_ws(' ', msg, t.f); end if;
  end loop;
  ok := ok and not has_function_privilege('anon', 'public.zip_path_place(text,integer)', 'execute')
           and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname in ('parked files: lab adds', 'parked files: read', 'parked files: remove when filed')) = 3;
  res := res || check_row(2, 'Its functions need a login, and storage has its three rules', ok,
    coalesce('Missing, or open to no login: ' || msg, 'A storage rule is missing. Run zip_drop.sql again.'));

  begin
    if not had_lab then insert into lab_users (user_id) values (lab); end if;
    cont := jsonb_build_object('kind', 'shop-floor-zip', 'format', 1, 'job', 'PROJ-99971', 'made_at', '2026-11-03T14:05:00-05:00',
      'files', jsonb_build_array(
        jsonb_build_object('path', 'Floor/PROJ-99971_Production_Sheets.pdf', 'what', 'work order', 'bytes', 1000),
        jsonb_build_object('path', 'Router/99971-TA02.mpr', 'what', 'CNC program', 'bytes', 2000, 'machine', 'homag', 'item', 'TA-02', 'part', 'Top', 'revision', 1),
        jsonb_build_object('path', 'Database/Metal/Cut sheets/ZZ check.pdf', 'what', 'cut sheet', 'bytes', 3000, 'replaces', false)));
    files := jsonb_build_array(jsonb_build_object('path', 'Floor/PROJ-99971_Production_Sheets.pdf', 'bytes', 1000, 'sha256', sha1),
                               jsonb_build_object('path', 'Router/99971-TA02.mpr', 'bytes', 2000, 'sha256', sha2),
                               jsonb_build_object('path', 'Database/Metal/Cut sheets/ZZ check.pdf', 'bytes', 3000, 'sha256', sha3));

    -- ---- 3. only a lab login drops a zip ------------------------------------
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := zip_drop_new('PROJ-99971.zip', cont, files);
      execute 'reset role'; ok := false; msg := 'A manager not let into the lab dropped a zip.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Only a login let into the lab drops a zip (another manager is refused)', ok, msg);

    -- ---- 4. a zip that doesn't match its contents.json is refused whole -----
    perform set_config('request.jwt.claims', as_lab, true);
    ok := true; msg := null;
    for t in select * from (values
        ('a file not listed', cont, files || jsonb_build_array(jsonb_build_object('path', 'Files/Other/x.pdf', 'bytes', 5, 'sha256', sha1))),
        ('a listed file missing', cont, files - 0),
        ('a wrong size', cont, jsonb_set(files, '{1,bytes}', '2001')),
        ('format 4', jsonb_set(cont, '{format}', '4'), files),
        ('a loose file in Files', jsonb_set(cont, '{files,0,path}', '"Files/x.pdf"'), jsonb_set(files, '{0,path}', '"Files/x.pdf"')),
        ('Design in a format 1 zip', jsonb_set(jsonb_set(cont, '{files,0,path}', '"Design/x.step"'), '{files,0,item}', '"TA-02"'), jsonb_set(files, '{0,path}', '"Design/x.step"')),
        ('a Router file for the Bend-Tech', jsonb_set(cont, '{files,1,machine}', '"bendtech"'), files),
        ('a name Windows refuses', jsonb_set(cont, '{files,0,path}', '"Floor/a:b.pdf"'), jsonb_set(files, '{0,path}', '"Floor/a:b.pdf"')),
        ('no job with job files', jsonb_set(cont, '{job}', 'null'), files)) as x(why, c, fl) loop
      begin
        execute 'set local role authenticated';
        v := zip_drop_new('PROJ-99971.zip', t.c, t.fl);
        execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'accepted: ' || t.why);
      exception when insufficient_privilege then execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'refused as a permission: ' || t.why);
      when others then execute 'reset role';
      end;
    end loop;
    select count(*) into n from zip_drops where project_id = 'PROJ-99971';
    ok := ok and n = 0;
    res := res || check_row(4, 'A zip that doesn''t match contents.json, or breaks a folder rule, is refused whole and nothing is kept', ok,
      coalesce(msg, n || ' drops were kept from refused zips.'));

    -- ---- 5. a good zip: every file parked, each in the right place ----------
    begin
      execute 'set local role authenticated';
      v := zip_drop_new('PROJ-99971.zip', cont, files);
      drp := (v ->> 'id')::uuid;
      f1 := (v #>> '{files,0,id}')::uuid; f2 := (v #>> '{files,1,id}')::uuid; f3 := (v #>> '{files,2,id}')::uuid;
      p1 := v #>> '{files,0,storage_path}'; p2 := v #>> '{files,2,storage_path}';
      insert into storage.objects (bucket_id, name, metadata) values ('parked-files', p1, '{"size": 1000}'), ('parked-files', p2, '{"size": 3000}'),
                                                                     ('parked-files', v #>> '{files,1,storage_path}', '{"size": 2000}');
      v2 := parked_file_stored(f1); v2 := parked_file_stored(f2); v2 := parked_file_stored(f3);
      execute 'reset role';
      ok := (select count(*) from parked_files where drop_id = drp and stored_at is not null) = 3
        and exists (select 1 from parked_files where id = f1 and place = 'job' and rel_path = 'PROJ-99971_Production_Sheets.pdf')
        and exists (select 1 from parked_files where id = f2 and place = 'job' and rel_path = 'Router/99971-TA02.mpr' and machine = 'homag' and item = 'TA-02')
        and exists (select 1 from parked_files where id = f3 and place = 'library' and project_id is null and rel_path = 'Metal/Cut sheets/ZZ check.pdf');
      msg := 'The files weren''t parked where 11_SHOP_FLOOR_ZIP.md says: ' || left(v::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A good zip: every file parked, the job''s under Files and the library''s under Database', ok, msg);

    -- ---- 6. the same zip again: unchanged files aren't stored again ----------
    begin
      execute 'set local role authenticated';
      v2 := zip_drop_new('PROJ-99971.zip', cont, jsonb_set(files, '{1,sha256}', to_jsonb(repeat('d', 64))));
      insert into storage.objects (bucket_id, name, metadata) values ('parked-files', v2 #>> '{files,1,storage_path}', '{"size": 2000}');
      execute 'reset role';
      ok := (v2 #>> '{files,0,unchanged}')::boolean and not (v2 #>> '{files,1,unchanged}')::boolean and (v2 #>> '{files,2,unchanged}')::boolean
            and (v2 ->> 'to_store')::int = 1 and v2 #>> '{files,0,storage_path}' is null;
      msg := 'A revised zip stored unchanged files again, or skipped a changed one: ' || left(v2::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A revised zip: unchanged files are recognised and skipped; a changed one is parked', ok, msg);

    -- ---- 7. a supervisor sees none of it; another manager reads it (the save) ---
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from parked_files; select n + count(*) into n from zip_drops;
      select n + count(*) into n from storage.objects where bucket_id = 'parked-files';
      begin insert into storage.objects (bucket_id, name, metadata) values ('parked-files', 'PROJ-99971/x/y/z.pdf', '{"size": 5}'); n := n + 1;
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      ok := n = 0; msg := 'A supervisor can see or add ' || n || ' parked rows or files.';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := parked_to_file();
      execute 'reset role';
      ok := ok and v @> jsonb_build_array(jsonb_build_object('id', f1)) and v @> jsonb_build_array(jsonb_build_object('id', f3));
      if not ok and msg is null then msg := 'The office''s save can''t see the parked files.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A supervisor sees none of it and can''t add a file; a manager''s save lists what''s waiting', ok, msg);

    -- ---- 8. filed in one place, or at the wrong size: it stays on Supabase ----
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      v := record_parked_filed(jsonb_build_array(jsonb_build_object('id', f1, 'place', 'onedrive', 'name', 'x.pdf', 'bytes', 1000)));
      execute 'reset role'; ok := false; msg := 'A supervisor reported a filed file.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := record_parked_filed(jsonb_build_array(
             jsonb_build_object('id', f1, 'place', 'onedrive', 'name', 'PROJ-99971_Production_Sheets.pdf', 'bytes', 1000),
             jsonb_build_object('id', f1, 'place', 'backup', 'name', 'PROJ-99971_Production_Sheets 2026-11-03.pdf', 'bytes', 1000),   -- another name: refused
             jsonb_build_object('id', f3, 'place', 'onedrive', 'name', 'ZZ check.pdf', 'bytes', 3000),
             jsonb_build_object('id', f3, 'place', 'backup', 'name', 'ZZ check.pdf', 'bytes', 2999)));                                   -- the wrong size
      ok := ok and not parked_removable(p1) and not parked_removable(p2);
      execute 'reset role';
      if ok is false and msg is null then msg := 'A file filed in one place only, under two names, or at the wrong size could come off Supabase.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Only a manager reports filing; a file in one place, under two names or at another size stays on Supabase', ok, msg);

    -- ---- 9. filed in both: it may go; a look more than a day old doesn't count --
    begin
      execute 'set local role authenticated';
      v := record_parked_filed(jsonb_build_array(
             jsonb_build_object('id', f1, 'place', 'backup', 'name', 'PROJ-99971_Production_Sheets.pdf', 'bytes', 1000),
             jsonb_build_object('id', f3, 'place', 'backup', 'name', 'ZZ check.pdf', 'bytes', 3000)));
      ok := not parked_removable(p1) and not parked_removable(p2);          -- filed in both places only today: they wait a day (R-26)
      execute 'reset role';
      update parked_files set onedrive_first_at = now() - interval '25 hours', backup_first_at = now() - interval '25 hours' where id in (f1, f3);
      execute 'set local role authenticated';
      ok := ok and parked_removable(p1) and parked_removable(p2);
      v := parked_ready_to_remove();
      ok := ok and v @> jsonb_build_array(jsonb_build_object('path', p1)) and v @> jsonb_build_array(jsonb_build_object('path', p2));
      execute 'reset role';
      update parked_files set backup_at = now() - interval '25 hours' where id = f3;
      ok := ok and not parked_removable(p2);
      update parked_files set backup_at = now() where id = f3;
      msg := 'A file could go the day it was first filed, can''t go a day later, or an old look counted.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Filed in both places at its size on two different days: it may come off Supabase, and not on the first day', ok, msg);

    -- ---- 10. removing: a supervisor can't; a manager can; the record stays ----
    begin
      perform set_config('storage.allow_delete_query', 'true', true);
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin delete from storage.objects where bucket_id = 'parked-files' and name = p1; get diagnostics n = row_count;
      exception when insufficient_privilege then n := 0; end;
      execute 'reset role';
      ok := n = 0;
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      begin
        v := mark_parked_removed(jsonb_build_array(f1));
        ok := ok and (v ->> 'removed')::int = 0;                         -- still in storage: not marked
        delete from storage.objects where bucket_id = 'parked-files' and name in (p1, v2 #>> '{files,1,storage_path}');
        get diagnostics n = row_count;
        ok := ok and n = 1;                                               -- only the one filed in both places
        v := mark_parked_removed(jsonb_build_array(f1, f2));
        ok := ok and (v ->> 'removed')::int = 1;
      exception when others then
        if sqlerrm not ilike '%direct deletion%' then raise; end if;      -- this Supabase stops deletes from SQL; the rule was checked above
      end;
      execute 'reset role';
      ok := ok and exists (select 1 from parked_files where id = f1) and exists (select 1 from parked_files where id = f2 and removed_at is null);
      msg := 'A supervisor could remove a parked file, the wrong one could go, or one still there was marked gone.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'A manager removes a filed file through storage; a supervisor can''t; the record stays', ok, msg);

    -- ---- 11. a library file that differs waits until Luke says replace it -----
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := hold_parked(jsonb_build_array(jsonb_build_object('id', f2, 'why', 'check')));
      begin v := parked_replace_ok(f3); ok := false; msg := 'A manager not let into the lab okayed a library replacement.';
      exception when insufficient_privilege then ok := true; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_lab, true);
      execute 'set local role authenticated';
      v := parked_replace_ok(f3);
      execute 'reset role';
      ok := ok and exists (select 1 from parked_files where id = f2 and held = 'check')
               and exists (select 1 from parked_files where id = f3 and replace_ok_at is not null and held is null);
      if not ok and msg is null then msg := 'Holding a file or okaying a replacement didn''t work.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'The save can hold a file with a reason; only a lab login says a library file may replace the one there', ok, msg);

    -- ---- 12. no login sees any of it -----------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select count(*) into n from parked_files;
      execute 'reset role';
      ok := n = 0; msg := n || ' parked rows are visible without logging in.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Someone with no login sees none of it', ok, msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end $$;
revoke all on function check_zip_drop() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. This file's own check. It practises on its own job, photo, trip and
--    zip file, as a manager signed in, and undoes all of it at the end.
-- ---------------------------------------------------------------------

create or replace function check_two_day_rule()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as a manager
declare
  res    jsonb := '[]';
  mgr    uuid;  as_mgr text;
  v_job  uuid;  v_lo uuid;
  ph     uuid := gen_random_uuid();  p_ph text;
  drp    uuid := gen_random_uuid();  pf uuid := gen_random_uuid();  p_pf text;
  t0     timestamptz;
  v      jsonb;  n int;  ok boolean;  msg text;
begin
  -- ---- 1. the columns are there, and no copy is without its first day -------
  ok := exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'filed_copies' and column_name = 'first_seen' and is_nullable = 'NO')
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'parked_files' and column_name = 'onedrive_first_at')
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'parked_files' and column_name = 'backup_first_at');
  select count(*) into n from parked_files
   where removed_at is null and ((onedrive_at is not null and onedrive_first_at is null) or (backup_at is not null and backup_first_at is null));
  res := res || check_row(1, 'Every saved copy has the time it was first found', ok and n = 0,
    case when not ok then 'A column is missing. Run two_day_rule.sql again.'
         else n || ' zip files were found in a folder but have no first-found time. Run two_day_rule.sql again.' end);

  -- ---- 2. the functions that decide are this file's ---------------------------
  ok := (select prosrc like '%first_seen <= now() - interval ''1 day''%' from pg_proc where oid = 'public.filed_removable(text,text)'::regprocedure)
        and (select prosrc like '%onedrive_first_at <= now() - interval ''1 day''%' and prosrc like '%backup_first_at <= now() - interval ''1 day''%'
               from pg_proc where oid = 'public.parked_removable(text)'::regprocedure)
        and (select prosrc like '%first_seen = case when filed_copies.bytes = excluded.bytes%' from pg_proc where oid = 'public.record_filed_copies(jsonb)'::regprocedure)
        and (select prosrc like '%onedrive_first_at = case%' from pg_proc where oid = 'public.record_parked_filed(jsonb)'::regprocedure);
  res := res || check_row(2, 'The rule that lets a file leave Supabase asks for two different days', coalesce(ok, false),
    'An older file put the one-day rule back. Run two_day_rule.sql again; if that stops, bring this line to Claude in a chat.');

  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  if mgr is null then
    res := res || check_row(3, 'A manager has a login to test with', false, 'Set up the logins first.');
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase)
      values (-999961, 'TWODAYCHECK', 'Two-day rule check - undone automatically', false, 'Complete') returning id into v_job;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_job;
    insert into loadouts (job_id, kind, scheduled_for, started_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
      values (v_job, 'delivery', now() - interval '62 days', now() - interval '62 days', now() - interval '61 days', 'Check',
              'Check Customer', now() - interval '61 days', now() - interval '61 days')
      returning id into v_lo;
    p_ph := 'TWODAYCHECK/' || ph || '.jpg';
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, metadata) values ('photos', p_ph, '{"size": 300000, "mimetype": "image/jpeg"}');
    execute 'reset role';
    insert into photos (id, client_id, job_id, department, kind, loadout_id, sheet_number, piece, storage_path, taken_by_name, bytes, taken_at)
      values (ph, gen_random_uuid(), v_job, 'delivery', 'loadout', v_lo, 1, 1, p_ph, 'Check', 300000, now() - interval '61 days');

    -- ---- 3. a photo found in both places today stays today -------------------
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'photo', 'id', ph, 'place', 'onedrive', 'bytes', 300000),
             jsonb_build_object('source', 'photo', 'id', ph, 'place', 'backup', 'bytes', 300000)));
      ok := not filed_removable('photos', p_ph);
      v := files_ready_to_remove(1000);
      ok := ok and not v @> jsonb_build_array(jsonb_build_object('path', p_ph));
      execute 'reset role';
      msg := 'A photo found in both folders for the first time today could come off Supabase today.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A photo found in its OneDrive folder and the backup folder for the first time today stays on Supabase today', ok, msg);

    -- ---- 4. found again a day later: it may go; one copy a day old isn't enough ----
    begin
      update filed_copies set first_seen = now() - interval '25 hours' where source = 'photo' and file_id = ph and place = 'backup';
      ok := not filed_removable('photos', p_ph);                                 -- the OneDrive copy was first found today
      update filed_copies set first_seen = now() - interval '25 hours' where source = 'photo' and file_id = ph;
      select min(first_seen) into t0 from filed_copies where source = 'photo' and file_id = ph;
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(
             jsonb_build_object('source', 'photo', 'id', ph, 'place', 'onedrive', 'bytes', 300000),
             jsonb_build_object('source', 'photo', 'id', ph, 'place', 'backup', 'bytes', 300000)));   -- the next day's save finds them again
      ok := ok and filed_removable('photos', p_ph);
      v := files_ready_to_remove(1000);
      ok := ok and v @> jsonb_build_array(jsonb_build_object('path', p_ph));
      execute 'reset role';
      ok := ok and (select count(*) from filed_copies where source = 'photo' and file_id = ph and first_seen = t0) = 2;   -- finding it again keeps the first day
      msg := 'A photo first found a day ago and found again today can''t go, or it could go with only one copy a day old, or finding it again moved its first day.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Found again a day later, both copies: it may go (one copy a day old is not enough; finding it again keeps its first day)', ok, msg);

    -- ---- 5. a copy that changed size starts its day again -----------------------
    begin
      execute 'set local role authenticated';
      v := record_filed_copies(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', ph, 'place', 'onedrive', 'bytes', 299000)));
      v := record_filed_copies(jsonb_build_array(jsonb_build_object('source', 'photo', 'id', ph, 'place', 'onedrive', 'bytes', 300000)));
      ok := not filed_removable('photos', p_ph);
      execute 'reset role';
      msg := 'A copy that was a different size and is now right again counted as seen a day ago.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A copy whose size changed starts its day again', ok, msg);

    -- ---- 6. a zip's file keeps its first-found times the same way ---------------
    --        (whether it may go is practised through storage by check_zip_drop(), step 9)
    begin
      p_pf := 'TWODAYCHECK/' || pf || '.pdf';
      insert into zip_drops (id, zip_name, format, project_id, contents, dropped_by)
        values (drp, 'two-day-check.zip', 1, null, '{}'::jsonb, mgr);
      insert into parked_files (id, drop_id, project_id, zip_path, place, rel_path, what, size_bytes, sha256, storage_path, stored_at)
        values (pf, drp, null, 'Database/Metal/Cut sheets/Two day check.pdf', 'library', 'Metal/Cut sheets/Two day check.pdf', 'cut sheet', 4000, repeat('d', 64), p_pf, now());
      execute 'set local role authenticated';
      v := record_parked_filed(jsonb_build_array(
             jsonb_build_object('id', pf, 'place', 'onedrive', 'name', 'Two day check.pdf', 'bytes', 4000),
             jsonb_build_object('id', pf, 'place', 'backup', 'name', 'Two day check.pdf', 'bytes', 3999)));
      execute 'reset role';
      ok := (v ->> 'recorded')::int = 2
            and (select onedrive_first_at is not null and backup_first_at is not null from parked_files where id = pf);
      update parked_files set onedrive_first_at = now() - interval '25 hours', backup_first_at = now() - interval '25 hours' where id = pf;
      select onedrive_first_at into t0 from parked_files where id = pf;
      execute 'set local role authenticated';
      v := record_parked_filed(jsonb_build_array(
             jsonb_build_object('id', pf, 'place', 'onedrive', 'name', 'Two day check.pdf', 'bytes', 4000),      -- found again, the same size: its first day is kept
             jsonb_build_object('id', pf, 'place', 'backup', 'name', 'Two day check.pdf', 'bytes', 4000)));       -- now the right size: its day starts again
      execute 'reset role';
      ok := ok and (select onedrive_first_at = t0 and backup_first_at > t0 and not parked_removable(p_pf) from parked_files where id = pf);
      msg := 'A zip file''s first-found time wasn''t kept when it was found again, or didn''t start again when its size changed.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A zip''s file keeps the time it was first found in each folder; a copy whose size changed starts again', coalesce(ok, false), msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end $$;
revoke all on function check_two_day_rule() from public, anon, authenticated;

select * from check_two_day_rule();
