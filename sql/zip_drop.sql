-- =====================================================================
-- zip_drop.sql — a job's zip, dropped on the office (1 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 50. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE drop.html and the new office page go on GitHub. The
-- pages there now keep working with it: nothing they read changes.
--
-- WHAT IT DOES (design: the Outputs zip & OneDrive filing tab, 31 Oct)
-- The Outputs project hands over each job as one zip (11_SHOP_FLOOR_ZIP.md,
-- format 1 or 2). Luke drops it on the office's "Drop a job's zip"
-- section (drop.html). The page loads the floor from the upload file (as
-- Upload did), sends Router/ and Bend-Tech/ files through Machine files,
-- and parks every file in the zip here until the office's save has filed
-- it in OneDrive and the backup folder: the job's Production › Files, or
-- the shop's library (Claudes Shop System Folder › Database). Then it
-- comes off Supabase; its record stays.
-- 1. zip_drops: one row per zip dropped (who, when, its contents.json).
-- 2. parked_files: one row per file in it: where it's filed, its size and
--    fingerprint, where the save found it, and when it left Supabase. A
--    file the same as one already parked for that job (or the library)
--    isn't stored again ("unchanged").
-- 3. A private parked-files bucket (50 MB a file).
-- 4. zip_drop_new(), parked_file_stored(), zip_drop_finished(): the drop
--    page (lab users only, the same logins that send machine files).
-- 5. parked_to_file(), record_parked_filed(), hold_parked(),
--    parked_removable() and a storage rule, parked_ready_to_remove(),
--    mark_parked_removed(): the office's save (managers).
-- 6. parked_replace_ok(): Luke says a library file may replace the one
--    already there.
-- Nothing existing changes, and nothing is deleted from the database.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('zip_drop.sql', 50, 'check_zip_drop', 'check_zip_drop', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('zip_drop.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.lab_allowed()') is null then raise exception 'Run lab.sql first. This file builds on it.'; end if;
  if to_regclass('public.machine_files') is null then raise exception 'Run machine_files.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.office_ok()') is null then raise exception 'Run problems.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The zips
-- ---------------------------------------------------------------------

create table if not exists zip_drops (
  id          uuid primary key default gen_random_uuid(),
  project_id  text,                                   -- null: a library-only zip (Database YYYY-MM-DD.zip)
  zip_name    text        not null,
  format      int         not null,
  made_at     timestamptz,
  contents    jsonb       not null,
  dropped_by  uuid        not null references profiles(id),
  dropped_at  timestamptz not null default now(),
  finished_at timestamptz,
  summary     jsonb,
  constraint zip_drops_project check (project_id is null or project_id ~ '^(PROJ|TEST)-[0-9]{5}$'),
  constraint zip_drops_format  check (format in (1, 2)),
  constraint zip_drops_name    check (length(zip_name) between 1 and 200)
);

alter table zip_drops enable row level security;
revoke all on zip_drops from anon, authenticated;
grant select on zip_drops to authenticated;            -- which rows: the policy below
drop policy if exists zip_drops_read on zip_drops;
create policy zip_drops_read on zip_drops for select to authenticated using (lab_allowed() or is_manager());


-- ---------------------------------------------------------------------
-- 2. The files in them
--    place: job (filed in the job's Production › Files) or library
--    (Claudes Shop System Folder › Database). rel_path is the path inside
--    that folder: Floor/x → x, Files/Metal drawings/x → Metal drawings/x,
--    Router/x → Router/x, Bend-Tech/x → Bend-Tech/x, Design/x → Design/x,
--    Database/Metal/Cut sheets/x → Metal/Cut sheets/x.
-- ---------------------------------------------------------------------

create table if not exists parked_files (
  id             uuid primary key default gen_random_uuid(),
  drop_id        uuid        not null references zip_drops(id),
  project_id     text,
  zip_path       text        not null,
  place          text        not null,
  rel_path       text        not null,
  what           text        not null,
  item           text,
  machine        text,
  part           text,
  revision       int,
  replaces       boolean     not null default false,
  size_bytes     bigint      not null,
  sha256         text        not null,
  same_as        uuid        references parked_files(id),   -- unchanged since an earlier zip: not stored again
  storage_path   text        unique,
  stored_at      timestamptz,
  filed_name     text,                                    -- its name where it was filed (a revised job file gets the date added)
  onedrive_bytes bigint,
  onedrive_at    timestamptz,
  backup_bytes   bigint,
  backup_at      timestamptz,
  held           text,                                    -- why the save hasn't filed it yet, in words
  replace_ok_by  uuid        references profiles(id),
  replace_ok_at  timestamptz,
  removed_at     timestamptz,
  constraint parked_files_place   check (place in ('job', 'library')),
  constraint parked_files_project check (project_id is null or project_id ~ '^(PROJ|TEST)-[0-9]{5}$'),
  constraint parked_files_job     check ((place = 'job') = (project_id is not null)),
  constraint parked_files_size    check (size_bytes between 1 and 52428800),
  constraint parked_files_sha     check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint parked_files_machine check (machine is null or machine in ('homag', 'bendtech')),
  constraint parked_files_what    check (length(what) between 1 and 40),
  constraint parked_files_stored  check (same_as is null or storage_path is null)
);
create index if not exists parked_files_waiting on parked_files (stored_at) where removed_at is null and same_as is null;
create index if not exists parked_files_job on parked_files (project_id, zip_path);

alter table parked_files enable row level security;
revoke all on parked_files from anon, authenticated;
grant select on parked_files to authenticated;
drop policy if exists parked_files_read on parked_files;
create policy parked_files_read on parked_files for select to authenticated using (lab_allowed() or is_manager());


-- ---------------------------------------------------------------------
-- 3. The bucket
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('parked-files', 'parked-files', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;


-- ---------------------------------------------------------------------
-- 4. Where a zip path goes. Returns {place, rel} or raises in words.
--    The folders of 11_SHOP_FLOOR_ZIP.md; Design/ only from format 2.
-- ---------------------------------------------------------------------

create or replace function zip_path_place(p_path text, p_format int) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  segs text[] := string_to_array(coalesce(p_path, ''), '/');
  top text := segs[1]; n int := coalesce(array_length(segs, 1), 0);
  nm text := segs[n]; ext text := lower(substring(coalesce(segs[n], '') from '\.([A-Za-z0-9]+)$'));
  s text; rest text;
begin
  if n < 2 then raise exception '%: every file goes in one of the zip''s folders (Floor, Files, Router, Bend-Tech, Database).', p_path; end if;
  foreach s in array segs loop
    if s = '' or s ~ '[\x01-\x1f\\:*?"<>|]' or s ~ '[. ]$' or s in ('.', '..') or length(s) > 200 then
      raise exception '%: that name isn''t one Windows accepts.', p_path;
    end if;
  end loop;
  if top in ('Floor', 'Router', 'Bend-Tech', 'Design') and n <> 2 then
    raise exception '%: % holds files only, no folders.', p_path, top;
  end if;
  if top = 'Floor' then
    if ext not in ('json', 'pdf') then raise exception '%: Floor holds only the upload file and the work order PDF.', p_path; end if;
    return jsonb_build_object('place', 'job', 'rel', nm);
  elsif top = 'Router' then
    if ext not in ('mprx', 'mpr') then raise exception '%: Router takes .mprx or .mpr only.', p_path; end if;
    return jsonb_build_object('place', 'job', 'rel', 'Router/' || nm);
  elsif top = 'Bend-Tech' then
    if ext not in ('step', 'stp', 'dxf') then raise exception '%: Bend-Tech takes .step, .stp or .dxf only.', p_path; end if;
    return jsonb_build_object('place', 'job', 'rel', 'Bend-Tech/' || nm);
  elsif top = 'Design' then
    if coalesce(p_format, 1) < 2 then raise exception '%: Design is new in format 2, and this zip says format 1.', p_path; end if;
    if ext not in ('step', 'stp') then raise exception '%: Design takes .step or .stp only.', p_path; end if;
    return jsonb_build_object('place', 'job', 'rel', 'Design/' || nm);
  elsif top = 'Files' then
    if n < 3 or segs[2] not in ('Metal drawings', 'KI', 'Arrow', 'Other') then
      raise exception '%: Files holds only the folders Metal drawings, KI, Arrow and Other, and nothing loose.', p_path;
    end if;
    return jsonb_build_object('place', 'job', 'rel', array_to_string(segs[2:n], '/'));
  elsif top = 'Database' then
    rest := array_to_string(segs[2:n], '/');
    if n < 4 or not (rest like 'Metal/Cut sheets/%' or rest like 'Metal/STEP files/%' or rest like 'CNC/KI/%' or rest like 'CNC/Other/%') then
      raise exception '%: library files go in Database/Metal/Cut sheets, Metal/STEP files, CNC/KI or CNC/Other.', p_path;
    end if;
    return jsonb_build_object('place', 'library', 'rel', rest);
  end if;
  raise exception '%: % isn''t one of the zip''s folders (Floor, Files, Router, Bend-Tech, Database%).', p_path, top,
    case when coalesce(p_format, 1) >= 2 then ', Design' else '' end;
end $$;
revoke all on function zip_path_place(text, int) from public, anon;


-- ---------------------------------------------------------------------
-- 5. The drop page: a zip comes in. p_contents is its contents.json;
--    p_files what the page found in the zip: [{path, bytes, sha256}].
--    The whole zip is refused, with the reason, if they don't agree.
--    Returns each file's id and where to upload it (null: unchanged).
-- ---------------------------------------------------------------------

create or replace function zip_drop_new(p_zip_name text, p_contents jsonb, p_files jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_fmt int; v_job text; v_drop uuid := gen_random_uuid(); v_made timestamptz;
  e jsonb; f jsonb; pl jsonb; v_id uuid; v_same uuid; v_path text; v_sp text;
  seen text[] := '{}'; v_items text[] := '{}'; out jsonb := '[]'; n_stored int := 0;
  v_size bigint; v_sha text; v_mach text; v_folder text;
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can drop zips.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p_contents) is distinct from 'object' then raise exception 'contents.json is missing or isn''t a JSON object.'; end if;
  if p_contents ->> 'kind' is distinct from 'shop-floor-zip' then raise exception 'contents.json''s kind isn''t "shop-floor-zip", so this isn''t a shop floor zip.'; end if;
  v_fmt := case when jsonb_typeof(p_contents -> 'format') = 'number' then (p_contents ->> 'format')::numeric::int end;
  if v_fmt is null or v_fmt not in (1, 2) or (p_contents ->> 'format')::numeric <> v_fmt then
    raise exception 'contents.json says format %; this office reads formats 1 and 2. If it''s newer, the office needs updating.', coalesce(p_contents ->> 'format', 'nothing');
  end if;
  v_job := case when jsonb_typeof(p_contents -> 'job') = 'string' then p_contents ->> 'job' end;
  if jsonb_typeof(p_contents -> 'job') not in ('string', 'null') or (v_job is not null and v_job !~ '^(PROJ|TEST)-[0-9]{5}$') then
    raise exception 'contents.json''s job should look like PROJ-00512 (or null for a library-only zip).';
  end if;
  begin v_made := (p_contents ->> 'made_at')::timestamptz;
  exception when others then raise exception 'contents.json''s made_at isn''t a date and time (ISO 8601 with the offset).'; end;
  if v_made is null or (p_contents ->> 'made_at') !~ '(Z|[+-][0-9]{2}:?[0-9]{2})$' then
    raise exception 'contents.json''s made_at needs a date, time and offset, like 2026-11-03T14:05:00-05:00.';
  end if;
  if jsonb_typeof(p_contents -> 'files') is distinct from 'array' or jsonb_array_length(p_contents -> 'files') = 0 then
    raise exception 'contents.json lists no files.';
  end if;
  if jsonb_array_length(p_contents -> 'files') > 500 then raise exception 'A zip holds 500 files at most.'; end if;
  if jsonb_typeof(p_files) is distinct from 'array' then raise exception 'The page sent no file list.'; end if;
  if length(coalesce(p_zip_name, '')) not between 1 and 200 then raise exception 'The zip has no name.'; end if;

  -- every listed file once, every file in the zip listed, sizes as listed
  for e in select * from jsonb_array_elements(p_contents -> 'files') loop
    v_path := e ->> 'path';
    if v_path is null or v_path = 'contents.json' then raise exception 'contents.json lists a file with no path.'; end if;
    if v_path = any(seen) then raise exception '% is listed twice in contents.json.', v_path; end if;
    seen := seen || v_path;
    select x into f from jsonb_array_elements(p_files) x where x ->> 'path' = v_path;
    if f is null then raise exception '% is listed in contents.json but isn''t in the zip.', v_path; end if;
    if jsonb_typeof(e -> 'bytes') is distinct from 'number' or (e ->> 'bytes')::numeric <> (f ->> 'bytes')::numeric then
      raise exception '% is % bytes in the zip, but contents.json says %.', v_path, f ->> 'bytes', coalesce(e ->> 'bytes', 'nothing');
    end if;
    if (f ->> 'bytes')::bigint not between 1 and 52428800 then raise exception '% is empty or over 50 MB.', v_path; end if;
    if coalesce(f ->> 'sha256', '') !~ '^[0-9a-f]{64}$' then raise exception '%: the page couldn''t fingerprint it. Try again.', v_path; end if;
    if length(coalesce(e ->> 'what', '')) not between 1 and 40 then raise exception '%: "what" is missing or over 40 letters.', v_path; end if;
    pl := zip_path_place(v_path, v_fmt);
    v_folder := split_part(v_path, '/', 1);
    if v_job is null and v_folder <> 'Database' then raise exception '%: a zip with no job (job: null) holds only Database files.', v_path; end if;
    v_mach := e ->> 'machine';
    if v_folder in ('Router', 'Bend-Tech') then
      if v_mach is distinct from (case v_folder when 'Router' then 'homag' else 'bendtech' end) then
        raise exception '%: machine should be "%", matching its folder.', v_path, case v_folder when 'Router' then 'homag' else 'bendtech' end;
      end if;
      if length(coalesce(e ->> 'item', '')) not between 1 and 80 then raise exception '%: say which item it''s for (the sheet''s item_code).', v_path; end if;
      if length(coalesce(e ->> 'part', '')) not between 1 and 60 then raise exception '%: say which part it is (a few words, like Top or V-Arm).', v_path; end if;
      if jsonb_typeof(e -> 'revision') is distinct from 'number' or (e ->> 'revision')::numeric < 1 or (e ->> 'revision')::numeric <> floor((e ->> 'revision')::numeric) then
        raise exception '%: revision should be 1 the first time, one more each time after.', v_path;
      end if;
      if (v_mach || '|' || (e ->> 'item') || '|' || (e ->> 'part')) = any(v_items) then
        raise exception '%: two files for the same machine, item and part (%, %).', v_path, e ->> 'item', e ->> 'part';
      end if;
      v_items := v_items || (v_mach || '|' || (e ->> 'item') || '|' || (e ->> 'part'));
    elsif v_mach is not null then
      raise exception '%: only Router and Bend-Tech files name a machine.', v_path;
    end if;
    if v_folder = 'Design' then
      if length(coalesce(e ->> 'item', '')) not between 1 and 80 then raise exception '%: say which item it''s the 3D model of (the sheet''s item_code).', v_path; end if;
      if ('design|' || (e ->> 'item')) = any(v_items) then raise exception '%: there''s already a 3D model for item % in this zip (one per item).', v_path, e ->> 'item'; end if;
      v_items := v_items || ('design|' || (e ->> 'item'));
    end if;
    if e ? 'replaces' and v_folder <> 'Database' then raise exception '%: only Database files say replaces.', v_path; end if;
    if e ? 'replaces' and jsonb_typeof(e -> 'replaces') <> 'boolean' then raise exception '%: replaces is true or false.', v_path; end if;
  end loop;
  for f in select * from jsonb_array_elements(p_files) loop
    if (f ->> 'path') <> 'contents.json' and not (f ->> 'path') = any(seen) then
      raise exception '% is in the zip but not listed in contents.json.', f ->> 'path';
    end if;
  end loop;

  insert into zip_drops (id, project_id, zip_name, format, made_at, contents, dropped_by)
  values (v_drop, v_job, p_zip_name, v_fmt, v_made, p_contents, auth.uid());

  for e in select * from jsonb_array_elements(p_contents -> 'files') loop
    v_path := e ->> 'path';
    select x into f from jsonb_array_elements(p_files) x where x ->> 'path' = v_path;
    v_size := (f ->> 'bytes')::bigint; v_sha := f ->> 'sha256';
    pl := zip_path_place(v_path, v_fmt);
    v_id := gen_random_uuid();
    -- the same file, at the same place, already parked and stored once: not stored again
    select p.id into v_same from parked_files p
     where p.place = pl ->> 'place' and p.rel_path = pl ->> 'rel' and p.sha256 = v_sha and p.size_bytes = v_size
       and p.same_as is null and p.stored_at is not null
       and (case when pl ->> 'place' = 'job' then p.project_id = v_job else p.project_id is null end)
     order by p.stored_at desc limit 1;
    v_sp := case when v_same is null then (case when pl ->> 'place' = 'job' then v_job else 'Database' end) || '/' || v_drop || '/' || v_id || '/' || split_part(v_path, '/', array_length(string_to_array(v_path, '/'), 1)) end;
    insert into parked_files (id, drop_id, project_id, zip_path, place, rel_path, what, item, machine, part, revision, replaces,
                              size_bytes, sha256, same_as, storage_path)
    values (v_id, v_drop, case when pl ->> 'place' = 'job' then v_job end, v_path, pl ->> 'place', pl ->> 'rel', e ->> 'what',
            nullif(btrim(coalesce(e ->> 'item', '')), ''), e ->> 'machine', nullif(btrim(coalesce(e ->> 'part', '')), ''),
            (e ->> 'revision')::numeric::int, coalesce((e ->> 'replaces')::boolean, false), v_size, v_sha, v_same, v_sp);
    if v_same is null then n_stored := n_stored + 1; end if;
    out := out || jsonb_build_object('path', v_path, 'id', v_id, 'storage_path', v_sp, 'unchanged', v_same is not null,
                                     'place', pl ->> 'place', 'rel', pl ->> 'rel');
  end loop;
  return jsonb_build_object('id', v_drop, 'job', v_job, 'format', v_fmt, 'files', out, 'to_store', n_stored);
end $$;
revoke all on function zip_drop_new(text, jsonb, jsonb) from public, anon;
grant execute on function zip_drop_new(text, jsonb, jsonb) to authenticated;

-- the bytes are in storage, at the size the zip said (checked, not taken on trust)
create or replace function parked_file_stored(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f parked_files; v_size bigint;
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can do that.' using errcode = 'insufficient_privilege'; end if;
  select * into f from parked_files where id = p_id;
  if f.id is null or f.storage_path is null then raise exception 'There''s no such file waiting to be stored.'; end if;
  select (o.metadata ->> 'size')::bigint into v_size from storage.objects o where o.bucket_id = 'parked-files' and o.name = f.storage_path;
  if v_size is null then raise exception '% hasn''t arrived in storage yet. Drop the zip again.', f.zip_path; end if;
  if v_size <> f.size_bytes then raise exception '% arrived at % bytes, not %. Drop the zip again.', f.zip_path, v_size, f.size_bytes; end if;
  update parked_files set stored_at = coalesce(stored_at, now()) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function parked_file_stored(uuid) from public, anon;
grant execute on function parked_file_stored(uuid) to authenticated;

-- what the drop did, in words and numbers, for the list of drops
create or replace function zip_drop_finished(p_id uuid, p_summary jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can do that.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p_summary) is distinct from 'object' or length(p_summary::text) > 20000 then raise exception 'The summary should be a short JSON object.'; end if;
  update zip_drops set finished_at = now(), summary = p_summary where id = p_id and dropped_by = auth.uid();
  if not found then raise exception 'That isn''t a zip you dropped.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function zip_drop_finished(uuid, jsonb) from public, anon;
grant execute on function zip_drop_finished(uuid, jsonb) to authenticated;

-- Luke: this library file may replace the one already in the library at its path
create or replace function parked_replace_ok(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can do that.' using errcode = 'insufficient_privilege'; end if;
  update parked_files set replace_ok_by = auth.uid(), replace_ok_at = now(), held = null
   where id = p_id and place = 'library' and removed_at is null and same_as is null;
  if not found then raise exception 'That isn''t a library file waiting to be filed.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function parked_replace_ok(uuid) from public, anon;
grant execute on function parked_replace_ok(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 6. The office's save (managers)
-- ---------------------------------------------------------------------

-- every parked file still on Supabase, with what the save needs to file it
create or replace function parked_to_file() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager can save the shop floor''s files.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'project_id', p.project_id, 'place', p.place, 'rel_path', p.rel_path,
             'storage_path', p.storage_path, 'bytes', p.size_bytes, 'sha256', p.sha256, 'filed_name', p.filed_name,
             'replaces', p.replaces or p.replace_ok_at is not null, 'held', p.held, 'what', p.what,
             'onedrive_bytes', p.onedrive_bytes, 'backup_bytes', p.backup_bytes, 'dropped_at', d.dropped_at)
             order by p.project_id nulls first, p.rel_path, d.dropped_at)
      from parked_files p join zip_drops d on d.id = p.drop_id
     where p.stored_at is not null and p.removed_at is null and p.same_as is null
       and (p.project_id is null or p.project_id like 'PROJ-%')), '[]'::jsonb);
end $$;
revoke all on function parked_to_file() from public, anon;
grant execute on function parked_to_file() to authenticated;

-- the save reports where it filed each file: [{id, place: onedrive|backup, name, bytes}]
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
        backup_bytes   = case when x ->> 'place' = 'backup' then (x ->> 'bytes')::bigint else f.backup_bytes end,
        backup_at      = case when x ->> 'place' = 'backup' then now() else f.backup_at end,
        held           = null
     where f.id = (x ->> 'id')::uuid and f.stored_at is not null and f.removed_at is null and f.same_as is null
       and (f.filed_name is null or v_name is null or f.filed_name = v_name);   -- one name in both places
    if found then n := n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function record_parked_filed(jsonb) from public, anon;
grant execute on function record_parked_filed(jsonb) to authenticated;

-- the save couldn't file it, and says why: [{id, why}] (why null clears it)
create or replace function hold_parked(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not office_ok() or auth.uid() is null then raise exception 'Only a manager''s office page does that.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p) is distinct from 'array' or jsonb_array_length(p) > 2000 then raise exception 'Send a list of 2,000 or fewer.'; end if;
  update parked_files f set held = left(nullif(btrim(x.why), ''), 500)
    from jsonb_to_recordset(p) as x(id uuid, why text)
   where f.id = x.id and f.removed_at is null and f.same_as is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'held', n);
end $$;
revoke all on function hold_parked(jsonb) from public, anon;
grant execute on function hold_parked(jsonb) to authenticated;

-- may this file come off Supabase? Filed in OneDrive and the backup folder,
-- both found at exactly its size within the last day.
create or replace function parked_removable(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from parked_files f
      join storage.objects o on o.bucket_id = 'parked-files' and o.name = f.storage_path
     where f.storage_path = p_name and f.stored_at is not null and f.removed_at is null
       and (o.metadata ->> 'size')::bigint = f.size_bytes
       and f.onedrive_bytes = f.size_bytes and f.backup_bytes = f.size_bytes
       and f.onedrive_at > now() - interval '1 day' and f.backup_at > now() - interval '1 day');
$$;
revoke all on function parked_removable(text) from public, anon;
grant execute on function parked_removable(text) to authenticated;    -- the storage rule runs as the login

create or replace function parked_ready_to_remove() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager can take files off Supabase.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'path', f.storage_path) order by f.storage_path)
                     from parked_files f where f.removed_at is null and parked_removable(f.storage_path)), '[]'::jsonb);
end $$;
revoke all on function parked_ready_to_remove() from public, anon;
grant execute on function parked_ready_to_remove() to authenticated;

-- after the page removed them through Supabase's storage: [id, ...]. Marked only if really gone and filed in both places.
create or replace function mark_parked_removed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not office_ok() then raise exception 'Only a manager can take files off Supabase.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p) is distinct from 'array' or jsonb_array_length(p) > 1000 then raise exception 'Send a list of 1,000 or fewer.'; end if;
  update parked_files f set removed_at = now()
   where f.id in (select (x #>> '{}')::uuid from jsonb_array_elements(p) x)
     and f.removed_at is null and f.stored_at is not null
     and f.onedrive_bytes = f.size_bytes and f.backup_bytes = f.size_bytes
     and not exists (select 1 from storage.objects o where o.bucket_id = 'parked-files' and o.name = f.storage_path);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removed', n);
end $$;
revoke all on function mark_parked_removed(jsonb) from public, anon;
grant execute on function mark_parked_removed(jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 7. Storage: lab users put files in (only ones registered by them and
--    not yet stored); lab users and managers read; a manager removes a
--    file only once it's filed in both places. Nobody changes one.
-- ---------------------------------------------------------------------

drop policy if exists "parked files: lab adds" on storage.objects;
create policy "parked files: lab adds" on storage.objects for insert to authenticated
  with check (bucket_id = 'parked-files' and public.lab_allowed()
              and exists (select 1 from public.parked_files f join public.zip_drops d on d.id = f.drop_id
                           where f.storage_path = name and f.stored_at is null and d.dropped_by = auth.uid()));
drop policy if exists "parked files: read" on storage.objects;
create policy "parked files: read" on storage.objects for select to authenticated
  using (bucket_id = 'parked-files' and (public.lab_allowed() or public.is_manager()));
drop policy if exists "parked files: remove when filed" on storage.objects;
create policy "parked files: remove when filed" on storage.objects for delete to authenticated
  using (bucket_id = 'parked-files' and public.is_manager() and public.parked_removable(name));


-- ---------------------------------------------------------------------
-- 8. The check. It practises on its own made-up zip, as Luke (lab),
--    another manager and a supervisor signed in, and undoes it all.
-- ---------------------------------------------------------------------

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
        ('format 3', jsonb_set(cont, '{format}', '3'), files),
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
      ok := parked_removable(p1) and parked_removable(p2);
      v := parked_ready_to_remove();
      ok := ok and v @> jsonb_build_array(jsonb_build_object('path', p1)) and v @> jsonb_build_array(jsonb_build_object('path', p2));
      execute 'reset role';
      update parked_files set backup_at = now() - interval '25 hours' where id = f3;
      ok := ok and not parked_removable(p2);
      update parked_files set backup_at = now() where id = f3;
      msg := 'A file filed in both places at its size can''t go, or an old look counted.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Filed in both places at its size within a day: it may come off Supabase', ok, msg);

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

select * from check_zip_drop();
