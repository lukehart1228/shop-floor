-- =====================================================================
-- Shop Floor — machine files: programs and STEP files to the machines
-- (Prototype lab, 18 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table. Needs lab.sql (run order 40) first.
--
-- What it adds (nothing existing changes; the floor sees none of it yet):
--   1. machine_logins: the Homag router's and the Bend-Tech's own logins.
--      Added only from the SQL Editor with machine_allow(email, machine).
--      A machine login is not a person: it has no profile, so it can't
--      change anything, sees no people and nothing of the lab, and of the
--      machine files only its own. (Like any signed-in login, it can read
--      the floor's job and sheet lists: Review finding to follow.)
--   2. A private storage bucket, machine-files, for the files themselves.
--   3. machine_files: one row per file and revision: the job, item and
--      part, which machine, who uploaded it and why, its fingerprint, when
--      the machine picked it up, and when the file was cleared from
--      storage. A new upload of the same part is the next revision.
--   4. Five functions, the only way to change those rows: register a file,
--      mark it stored, mark it picked up (the fingerprint must match), mark
--      it cleared, and machine_allow(). my_machine() says which machine a
--      login is.
--   5. Once a machine has picked a file up, the file itself is removed from
--      storage; its row stays forever (Luke, 18 Oct: the third exception to
--      nothing is deleted, after the TV photo copies).
--   6. check_machine_files(): the PASS/FAIL check.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('machine_files.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.lab_allowed()') is null then
    raise exception 'Run lab.sql (run order 40) first. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The machines' logins
-- ---------------------------------------------------------------------
create table if not exists machine_logins (
  user_id  uuid primary key references auth.users(id),
  machine  text not null,
  added_at timestamptz not null default now(),
  added_by text not null default current_user,
  constraint machine_logins_known check (machine in ('homag', 'bendtech'))
);
alter table machine_logins enable row level security;
revoke all on machine_logins from anon, authenticated;
grant select on machine_logins to authenticated;
drop policy if exists machine_logins_self on machine_logins;
create policy machine_logins_self on machine_logins for select to authenticated using (user_id = auth.uid() or lab_allowed());

-- which machine this login is; never a person's login
create or replace function my_machine() returns text
language sql stable security definer set search_path = public as $$
  select m.machine from machine_logins m
  where m.user_id = auth.uid() and not exists (select 1 from profiles p where p.id = m.user_id);
$$;
revoke all on function my_machine() from public, anon;
grant execute on function my_machine() to authenticated;

-- SQL Editor only
create or replace function machine_allow(p_email text, p_machine text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid; v_m text := lower(btrim(coalesce(p_machine, '')));
begin
  if v_m not in ('homag', 'bendtech') then return 'The machine is ''homag'' or ''bendtech''.'; end if;
  select id into v_id from auth.users where lower(email) = lower(btrim(coalesce(p_email, '')));
  if v_id is null then return 'No login with that email. Make it first under Authentication → Users (Add user, Auto Confirm ticked).'; end if;
  if exists (select 1 from profiles where id = v_id) then
    return 'That login belongs to a person (it has a profile). Make a separate login just for the machine.';
  end if;
  insert into machine_logins (user_id, machine) values (v_id, v_m)
  on conflict (user_id) do update set machine = excluded.machine;
  return p_email || ' is now the ' || case v_m when 'homag' then 'Homag router' else 'Bend-Tech (Dragon)' end || '''s login.';
end;
$$;
revoke all on function machine_allow(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. The bucket
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('machine-files', 'machine-files', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- ---------------------------------------------------------------------
-- 3. The files
-- ---------------------------------------------------------------------
create table if not exists machine_files (
  id           uuid primary key default gen_random_uuid(),
  project_id   text not null,
  item_id      text not null,
  part         text not null,
  machine      text not null,
  rev          int  not null,
  file_name    text not null,
  path         text not null unique,
  size_bytes   bigint not null,
  sha256       text not null,
  note         text,
  uploaded_by  uuid not null references profiles(id),
  uploaded_at  timestamptz not null default now(),
  stored_at    timestamptz,
  replaced_by  uuid references machine_files(id),
  replaced_at  timestamptz,
  picked_up_at timestamptz,
  picked_up_by uuid references auth.users(id),
  cleared_at   timestamptz,
  constraint machine_files_project check (project_id ~ '^(PROJ|TEST)-[0-9]{5}$'),   -- TEST- for the test lane
  constraint machine_files_machine check (machine in ('homag', 'bendtech')),
  constraint machine_files_sha check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint machine_files_size check (size_bytes between 1 and 52428800),
  constraint machine_files_note check (note is null or length(note) <= 2000),
  constraint machine_files_one_rev unique (project_id, item_id, part, machine, rev)
);
create index if not exists machine_files_queue on machine_files (machine, picked_up_at, uploaded_at desc);

alter table machine_files enable row level security;
revoke all on machine_files from anon, authenticated;
grant select on machine_files to authenticated;
drop policy if exists machine_files_read on machine_files;
create policy machine_files_read on machine_files for select to authenticated
  using (lab_allowed() or machine = my_machine());

-- what a file is called on the machine: PROJ-00451_TA-02_V-Arm_r2.step
create or replace function machine_file_name(p_project text, p_item text, p_part text, p_rev int, p_ext text) returns text
language sql immutable set search_path = public as $$
  select left(array_to_string(array(select btrim(regexp_replace(regexp_replace(x, '[^A-Za-z0-9.-]+', '-', 'g'), '-{2,}', '-', 'g'), '-.')
                                     from unnest(array[p_project, p_item, p_part]) x), '_'), 150)
         || '_r' || p_rev || '.' || p_ext;
$$;
revoke all on function machine_file_name(text, text, text, int, text) from public, anon;

-- 4a. register a file before uploading it (lab users only). Returns where to put it.
create or replace function machine_file_new(p_project text, p_item text, p_part text, p_machine text, p_original_name text,
                                            p_size bigint, p_sha256 text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_m text := lower(btrim(coalesce(p_machine, ''))); v_item text := btrim(coalesce(p_item, '')); v_part text := btrim(coalesce(p_part, ''));
  v_ext text := lower(substring(coalesce(p_original_name, '') from '\.([A-Za-z0-9]+)$'));
  v_rev int; v_id uuid := gen_random_uuid(); v_name text; v_path text;
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can send files to the machines.' using errcode = 'insufficient_privilege'; end if;
  if coalesce(p_project, '') !~ '^(PROJ|TEST)-[0-9]{5}$' then raise exception 'The job should look like PROJ-00451 (or TEST-00451 on the test lane).'; end if;
  if length(v_item) not between 1 and 80 then raise exception 'Say which item it''s for (the work order''s Item ID).'; end if;
  if length(v_part) not between 1 and 60 then raise exception 'Say which part it is (a few words, like Leg Long, or Program).'; end if;
  if v_m not in ('homag', 'bendtech') then raise exception 'Choose the machine: the Homag router or the Bend-Tech.'; end if;
  if v_m = 'homag' and coalesce(v_ext, '') not in ('mprx', 'mpr') then raise exception 'The Homag router takes .mprx or .mpr programs; this file is .%.', coalesce(v_ext, '?'); end if;
  if v_m = 'bendtech' and coalesce(v_ext, '') not in ('step', 'stp', 'dxf') then raise exception 'The Bend-Tech takes .step, .stp or .dxf files; this file is .%.', coalesce(v_ext, '?'); end if;
  if coalesce(p_size, 0) not between 1 and 52428800 then raise exception 'The file is empty or over 50 MB.'; end if;
  if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'The file''s fingerprint is missing. Try again.'; end if;
  perform pg_advisory_xact_lock(hashtext(p_project || v_item || v_part || v_m));
  select coalesce(max(rev), 0) + 1 into v_rev from machine_files
   where project_id = p_project and item_id = v_item and part = v_part and machine = v_m;
  v_name := machine_file_name(p_project, v_item, v_part, v_rev, v_ext);
  v_path := v_m || '/' || v_id || '/' || v_name;
  insert into machine_files (id, project_id, item_id, part, machine, rev, file_name, path, size_bytes, sha256, note, uploaded_by)
  values (v_id, p_project, v_item, v_part, v_m, v_rev, v_name, v_path, p_size, p_sha256, nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  return jsonb_build_object('id', v_id, 'rev', v_rev, 'file_name', v_name, 'path', v_path);
end;
$$;
revoke all on function machine_file_new(text, text, text, text, text, bigint, text, text) from public, anon;
grant execute on function machine_file_new(text, text, text, text, text, bigint, text, text) to authenticated;

-- 4b. the bytes are in storage: show it to the machine, and replace older revisions
create or replace function machine_file_stored(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f machine_files; v_clear text[];
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab can do that.' using errcode = 'insufficient_privilege'; end if;
  select * into f from machine_files where id = p_id;
  if f.id is null then raise exception 'There''s no such file.'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'machine-files' and name = f.path) then
    raise exception 'The file hasn''t arrived in storage yet. Upload it again.';
  end if;
  update machine_files set stored_at = coalesce(stored_at, now()) where id = p_id;
  -- older revisions of the same part are replaced; ones the machine never got are cleared from storage by the page
  select coalesce(array_agg(path), '{}') into v_clear from machine_files
   where project_id = f.project_id and item_id = f.item_id and part = f.part and machine = f.machine and rev < f.rev
     and replaced_by is null and picked_up_at is null and cleared_at is null;
  update machine_files set replaced_by = p_id, replaced_at = now()
   where project_id = f.project_id and item_id = f.item_id and part = f.part and machine = f.machine and rev < f.rev and replaced_by is null;
  return jsonb_build_object('ok', true, 'clear', to_jsonb(v_clear));
end;
$$;
revoke all on function machine_file_stored(uuid) from public, anon;
grant execute on function machine_file_stored(uuid) to authenticated;

-- 4c. the machine has the file on its computer: the fingerprint must match what was uploaded
create or replace function machine_file_picked_up(p_id uuid, p_sha256 text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f machine_files; v_m text := my_machine();
begin
  if v_m is null then raise exception 'Only a machine''s login can pick up files.' using errcode = 'insufficient_privilege'; end if;
  select * into f from machine_files where id = p_id;
  if f.id is null or f.machine <> v_m then raise exception 'That file isn''t for this machine.' using errcode = 'insufficient_privilege'; end if;
  if f.picked_up_at is not null then return jsonb_build_object('ok', true, 'already', true, 'path', f.path); end if;
  if f.stored_at is null or f.replaced_by is not null then raise exception 'That file isn''t waiting for this machine any more.'; end if;
  if coalesce(p_sha256, '') <> f.sha256 then
    raise exception 'The file arrived different from the one uploaded, so it wasn''t counted as picked up. Try again.';
  end if;
  update machine_files set picked_up_at = now(), picked_up_by = auth.uid() where id = p_id;
  return jsonb_build_object('ok', true, 'path', f.path);
end;
$$;
revoke all on function machine_file_picked_up(uuid, text) from public, anon;
grant execute on function machine_file_picked_up(uuid, text) to authenticated;

-- 4d. the file is gone from storage (checked, not taken on trust); its row stays
create or replace function machine_file_cleared(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f machine_files;
begin
  select * into f from machine_files where id = p_id;
  if f.id is null or not (lab_allowed() or (f.machine = my_machine() and f.picked_up_at is not null)) then
    raise exception 'That file isn''t yours to clear.' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'machine-files' and name = f.path) then
    return jsonb_build_object('ok', false, 'summary', 'The file is still in storage.');
  end if;
  update machine_files set cleared_at = coalesce(cleared_at, now()) where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function machine_file_cleared(uuid) from public, anon;
grant execute on function machine_file_cleared(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Storage: lab users put files in and can take them out; a machine reads only
-- its own waiting files and removes only ones it has picked up. Nobody changes one.
-- ---------------------------------------------------------------------
drop policy if exists "machine files: lab adds" on storage.objects;
create policy "machine files: lab adds" on storage.objects for insert to authenticated
  with check (bucket_id = 'machine-files' and lab_allowed()
              and exists (select 1 from public.machine_files f where f.path = name and f.stored_at is null and f.uploaded_by = auth.uid()));
drop policy if exists "machine files: read" on storage.objects;
create policy "machine files: read" on storage.objects for select to authenticated
  using (bucket_id = 'machine-files' and (public.lab_allowed()
         or exists (select 1 from public.machine_files f where f.path = name and f.machine = public.my_machine()
                    and f.stored_at is not null and f.replaced_by is null and f.cleared_at is null)));
drop policy if exists "machine files: remove" on storage.objects;
create policy "machine files: remove" on storage.objects for delete to authenticated
  using (bucket_id = 'machine-files' and (public.lab_allowed()
         or exists (select 1 from public.machine_files f where f.path = name and f.machine = public.my_machine() and f.picked_up_at is not null)));

-- ---------------------------------------------------------------------
-- 6. The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_machine_files()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  labu uuid; mgr uuid; sup uuid; hom uuid := gen_random_uuid(); bt uuid := gen_random_uuid();
  sha text := repeat('ab', 32); r jsonb; r2 jsonb; f1 uuid; f2 uuid; f3 uuid; p1 text; p2 text; p3 text;
  n int; m int; ok boolean; msg text; txt text;
begin
  -- ---- 1: tables locked, bucket private ---------------------------------------------------------------
  select count(*) into n from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('machine_logins', 'machine_files') and c.relrowsecurity;
  select count(*) into m from storage.buckets where id = 'machine-files' and not public;
  res := res || check_row(1, 'The two tables have row-level security on, and the machine-files bucket is private', n = 2 and m = 1, format('%s of 2 tables, bucket private: %s. Run machine_files.sql again.', n, m = 1));

  -- ---- 2: no login writes the tables directly; only the SQL Editor adds a machine --------------------
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('machine_logins', 'machine_files') and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  select count(*) into m from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'machine_allow' and grantee in ('anon', 'authenticated', 'PUBLIC');
  res := res || check_row(2, 'No login can write the file records directly or make itself a machine', n = 0 and m = 0, format('%s table grants, %s on machine_allow', n, m));

  select u.user_id into labu from lab_users u join profiles p on p.id = u.user_id where p.active order by u.added_at limit 1;
  if labu is null then select id into labu from profiles where role in ('manager', 'admin') and active and not coalesce(is_test, false) order by full_name limit 1; end if;
  select id into mgr from profiles p where role in ('manager', 'admin') and active and not coalesce(is_test, false) and id <> labu
    and not exists (select 1 from lab_users u where u.user_id = p.id) order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not coalesce(is_test, false) order by full_name limit 1;
  if labu is null or sup is null then
    res := res || check_row(3, 'A manager and a supervisor login exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x; return;
  end if;

  begin    -- everything below is undone at the end
    insert into lab_users (user_id) values (labu) on conflict do nothing;
    insert into auth.users (id, email) values (hom, 'check-homag-' || hom || '@example.com'), (bt, 'check-bendtech-' || bt || '@example.com');
    insert into machine_logins (user_id, machine) values (hom, 'homag'), (bt, 'bendtech');

    -- ---- 3: the lab registers a file, then a second revision ----------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', labu, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := machine_file_new('PROJ-00000', 'CHECK-01', 'Leg Long', 'bendtech', 'leg.STEP', 1000, sha, 'Check file - undone automatically');
      execute 'reset role';
      f1 := (r->>'id')::uuid; p1 := r->>'path';
      insert into storage.objects (bucket_id, name, metadata) values ('machine-files', p1, '{"size": 1000}');
      execute 'set local role authenticated';
      perform machine_file_stored(f1);
      r2 := machine_file_new('PROJ-00000', 'CHECK-01', 'Leg Long', 'bendtech', 'leg2.step', 1000, sha, 'Revision 2');
      execute 'reset role';
      f2 := (r2->>'id')::uuid; p2 := r2->>'path';
      ok := r->>'file_name' = 'PROJ-00000_CHECK-01_Leg-Long_r1.step' and (r2->>'rev')::int = 2 and p1 like 'bendtech/%';
      msg := format('%s, then rev %s', r->>'file_name', r2->>'rev');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A lab user registers a file (named PROJ_item_part_r1) and a new upload of the same part is revision 2', ok, msg);

    -- ---- 4: wrong file types and bad jobs are refused ---------------------------------------------------
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      perform machine_file_new('PROJ-00000', 'CHECK-01', 'Program', 'homag', 'part.step', 10, sha); execute 'reset role'; msg := 'a STEP file was queued for the router';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_new('PROJ-00000', 'CHECK-01', 'Leg', 'bendtech', 'prog.mprx', 10, sha); execute 'reset role'; msg := concat_ws(', ', msg, 'a program was queued for the Bend-Tech');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_new('451', 'CHECK-01', 'Leg', 'bendtech', 'a.step', 10, sha); execute 'reset role'; msg := concat_ws(', ', msg, 'a bad job number was kept');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(4, 'The router takes only programs, the Bend-Tech only STEP or DXF, and the job must be a PROJ number', n = 3, msg);

    -- ---- 5: revision 2 stored replaces revision 1 -----------------------------------------------------
    insert into storage.objects (bucket_id, name, metadata) values ('machine-files', p2, '{"size": 1000}');
    begin execute 'set local role authenticated';
      r := machine_file_stored(f2); execute 'reset role';
      select replaced_by = f2 into ok from machine_files where id = f1;
      ok := coalesce(ok, false) and r->'clear' ? p1; msg := r::text;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Storing revision 2 marks revision 1 replaced, and says to clear revision 1 (the machine never got it)', ok, msg);

    -- ---- 6: the Bend-Tech sees only its own waiting files, and nothing else in the app -----------------
    perform set_config('request.jwt.claims', json_build_object('sub', bt, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      txt := my_machine();
      select count(*) into n from machine_files where project_id = 'PROJ-00000';
      select count(*) into m from storage.objects where bucket_id = 'machine-files' and name in (p1, p2);
      select n * 100 + m * 10 + (select count(*) from profiles) + (select count(*) from lab_rules) + (select count(*) from lab_users) into n;
      execute 'reset role';
      ok := txt = 'bendtech' and n = 210; msg := format('machine %s, code %s (want 210: 2 rows, 1 readable file, nothing else)', txt, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'The Bend-Tech login sees its own files, can read only the newest waiting one, and sees no people and nothing of the lab', ok, msg);

    -- ---- 6b: and it can't change anything on the floor (a count, as a check) ---------------------------------
    begin execute 'set local role authenticated';
      perform set_count((select id from sheet_progress limit 1), 1); execute 'reset role';
      txt := case when exists (select 1 from sheet_progress) then 'set a count' else null end;
    exception when others then execute 'reset role'; txt := null; end;
    if txt is not null then res := res || check_row(6, 'A machine login can''t change the floor', false, 'It could ' || txt || '. Do not go further.'); end if;

    -- ---- 7: picking up: the fingerprint must match; then it may remove the file, and only then ----------
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      delete from storage.objects where bucket_id = 'machine-files' and name = p2; get diagnostics m = row_count; execute 'reset role';
      if m > 0 then msg := 'removed a file before picking it up'; else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_picked_up(f2, repeat('cd', 32)); execute 'reset role'; msg := concat_ws(', ', msg, 'a changed file counted as picked up');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_picked_up(f1, sha); execute 'reset role'; msg := concat_ws(', ', msg, 'picked up a replaced revision');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_picked_up(f2, sha);
      delete from storage.objects where bucket_id = 'machine-files' and name = p2; get diagnostics m = row_count;
      r := machine_file_cleared(f2); execute 'reset role';
      if m = 1 and (r->>'ok')::boolean and exists (select 1 from machine_files where id = f2 and picked_up_at is not null and cleared_at is not null and picked_up_by = bt)
        then n := n + 1; else msg := concat_ws(', ', msg, format('pick up and clear: removed %s, %s', m, r)); end if;
    exception when others then execute 'reset role'; msg := concat_ws(', ', msg, 'Error: ' || sqlerrm); end;
    res := res || check_row(7, 'The machine can''t remove a file it hasn''t picked up, a changed file or a replaced one isn''t counted; the right one is, then it''s removed and the row kept', n = 4, msg);

    -- ---- 8: the router sees none of the Bend-Tech's files ------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', hom, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      select count(*) into m from machine_files where project_id = 'PROJ-00000'; execute 'reset role';
      if m > 0 then msg := format('saw %s Bend-Tech rows', m); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_picked_up(f2, sha); execute 'reset role'; msg := concat_ws(', ', msg, 'picked up the Bend-Tech''s file');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      perform machine_file_new('PROJ-00000', 'CHECK-01', 'Program', 'homag', 'p.mprx', 10, sha); execute 'reset role'; msg := concat_ws(', ', msg, 'a machine queued a file');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(8, 'The router sees none of the Bend-Tech''s files, can''t pick them up, and no machine can queue a file', n = 3, msg);

    -- ---- 9: people outside the lab: nothing --------------------------------------------------------------
    n := 0; msg := null;
    foreach txt in array array[coalesce(mgr::text, ''), sup::text] loop
      if txt = '' then n := n + 2; continue; end if;
      perform set_config('request.jwt.claims', json_build_object('sub', txt, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated';
        select count(*) into m from machine_files; select m + count(*) into m from storage.objects where bucket_id = 'machine-files'; execute 'reset role';
        if m > 0 then msg := concat_ws(', ', msg, format('a %s saw %s', case when txt = sup::text then 'supervisor' else 'manager' end, m)); else n := n + 1; end if;
      exception when others then execute 'reset role'; n := n + 1; end;
      begin execute 'set local role authenticated';
        perform machine_file_new('PROJ-00000', 'CHECK-01', 'Program', 'homag', 'p.mprx', 10, sha); execute 'reset role';
        msg := concat_ws(', ', msg, 'someone outside the lab queued a file');
      exception when others then execute 'reset role'; n := n + 1; end;
    end loop;
    perform set_config('request.jwt.claims', '', true);
    begin execute 'set local role anon';
      select count(*) into m from machine_files; execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'no login saw files'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(9, 'A manager not in the lab, a supervisor and no login see no files and can''t queue one', n = 5, msg);

    -- ---- 10: a person's login can't be made a machine ----------------------------------------------------
    txt := machine_allow((select email from auth.users where id = sup), 'homag');
    ok := txt like 'That login belongs to a person%' and not exists (select 1 from machine_logins where user_id = sup);
    msg := txt;
    -- and even if a person's login were put in the table by hand, it still isn't treated as a machine
    insert into machine_logins (user_id, machine) values (sup, 'homag');
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      txt := my_machine(); select count(*) into m from machine_files; execute 'reset role';
      if txt is not null or m > 0 then ok := false; msg := format('a supervisor put in by hand counts as the %s and sees %s files', txt, m); end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(10, 'A person''s login can''t be made a machine, and isn''t treated as one even if put in by hand', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_machine_files_undo__';
  exception when others then
    if sqlerrm <> '__check_machine_files_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  select string_agg(case m.machine when 'homag' then 'Homag router' else 'Bend-Tech' end || ': ' || u.email, ', ' order by m.machine) into txt
  from machine_logins m join auth.users u on u.id = m.user_id;
  res := res || check_row(11, coalesce('Machine logins: ' || txt, 'No machine logins yet. Next: make them in Authentication → Users, then select machine_allow(''email'', ''homag'');'), true, null);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_machine_files() from public, anon, authenticated;

select * from check_machine_files();
