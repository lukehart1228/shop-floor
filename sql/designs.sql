-- =====================================================================
-- designs.sql — the STEP viewer test's storage (31 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 49. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Nothing on the floor reads it; only step.html (the test page) does.
--
-- WHAT IT DOES (design: the 3D design viewer tab, 31 Oct)
-- step.html turns a STEP file into a light "view file" on the PC that
-- converts it, and saves it here for the tablets to open, turn and
-- measure. This is the test: it tells us conversion time, file size and
-- accuracy on real designs and real tablets before the viewer joins the
-- zip drop.
-- 1. A private bucket, designs, for view files (gzip, 20 MB at most).
-- 2. sees_designs(): a signed-in shop login (a manager, or a supervisor
--    that isn't a look-up login). Machine logins and look-up logins
--    aren't. Works whether or not job_status.sql (look-up logins) has run.
-- 3. Who may do what: shop logins read; managers add test files (named
--    test/<date>-<time>-<name>.view.json.gz) and may clear them again.
--    Nobody changes a file in place. Test view files have no record
--    anywhere, so clearing one loses nothing.
-- Nothing existing changes.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('designs.sql', 49, 'check_designs', 'check_designs', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('designs.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.is_manager()') is null then raise exception 'Run schema.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The bucket: private, gzip view files only, 20 MB at most
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('designs', 'designs', false, 20971520, array['application/gzip'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;


-- ---------------------------------------------------------------------
-- 2. Who counts as a shop login here
-- ---------------------------------------------------------------------

-- look_up is read through to_jsonb so this works before job_status.sql (run order 47) adds that column
create or replace function sees_designs() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p
                  where p.id = auth.uid() and p.active and p.role in ('manager', 'admin', 'supervisor')
                    and not coalesce((to_jsonb(p) ->> 'look_up')::boolean, false));
$$;
revoke all on function sees_designs() from public, anon;
grant execute on function sees_designs() to authenticated;     -- the storage rules run as the login


-- ---------------------------------------------------------------------
-- 3. The rules
-- ---------------------------------------------------------------------

drop policy if exists "shop floor: read designs" on storage.objects;
create policy "shop floor: read designs" on storage.objects for select to authenticated
  using (bucket_id = 'designs' and public.sees_designs());

drop policy if exists "shop floor: add test designs" on storage.objects;
create policy "shop floor: add test designs" on storage.objects for insert to authenticated
  with check (bucket_id = 'designs' and public.is_manager()
              and name ~ '^test/[0-9]{8}-[0-9]{6}-[A-Za-z0-9._-]{1,80}\.view\.json\.gz$');

drop policy if exists "shop floor: clear test designs" on storage.objects;
create policy "shop floor: clear test designs" on storage.objects for delete to authenticated
  using (bucket_id = 'designs' and public.is_manager() and name like 'test/%');


-- ---------------------------------------------------------------------
-- 4. The check. It practises as a manager, a supervisor and a look-up
--    login signed in, and undoes all of it at the end.
-- ---------------------------------------------------------------------

create or replace function check_designs()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res    jsonb := '[]';
  mgr    uuid;  sup uuid;  look uuid;
  b      storage.buckets;
  ok     boolean;
  msg    text;
  n      int;
  good   text := 'test/20261031-120000-check-table.view.json.gz';
begin
  select id into mgr from profiles p where role in ('manager', 'admin') and active and not is_test
     and not coalesce((to_jsonb(p) ->> 'look_up')::boolean, false) limit 1;
  select id into sup from profiles p where role = 'supervisor' and active and not is_test
     and not coalesce((to_jsonb(p) ->> 'look_up')::boolean, false) limit 1;
  select id into look from profiles p where coalesce((to_jsonb(p) ->> 'look_up')::boolean, false) and active limit 1;
  if mgr is null or sup is null then
    res := res || check_row(1, 'A manager and a supervisor have logins to test with', false, 'Set up the logins first.');
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;

  -- ---- 1. the bucket and its rules -----------------------------------------
  select * into b from storage.buckets where id = 'designs';
  ok := b.id is not null and not b.public and b.file_size_limit = 20971520 and b.allowed_mime_types = array['application/gzip']
        and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname in ('shop floor: read designs', 'shop floor: add test designs', 'shop floor: clear test designs')) = 3
        and not has_function_privilege('anon', 'public.sees_designs()', 'execute');
  res := res || check_row(1, 'The designs bucket is private, gzip only, 20 MB at most, with its three rules', ok,
    'The bucket or a rule is missing or wrong. Run designs.sql again.');

  begin
    -- ---- 2. a manager adds a test view file, and only under test/ ------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      insert into storage.objects (bucket_id, name, metadata) values ('designs', good, '{"size": 1200, "mimetype": "application/gzip"}');
      ok := true;
    exception when others then ok := false; msg := 'A manager couldn''t add a test view file: ' || sqlerrm;
    end;
    begin
      insert into storage.objects (bucket_id, name, metadata) values ('designs', 'PROJ-00418/table.view.json.gz', '{"size": 1200}');
      ok := false; msg := 'A view file outside test/ was let in.';
    exception when insufficient_privilege then null;
    when others then if sqlerrm !~* 'row-level security|violates' then ok := false; msg := 'Error: ' || sqlerrm; end if;
    end;
    execute 'reset role';
    res := res || check_row(2, 'A manager adds a test view file, named test/…, and nothing else', ok, msg);

    -- ---- 3. a supervisor reads it, and can't add one ---------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from storage.objects where bucket_id = 'designs' and name = good;
    ok := n = 1; msg := 'A supervisor can''t see the view file.';
    begin
      insert into storage.objects (bucket_id, name, metadata) values ('designs', 'test/20261031-120001-sup.view.json.gz', '{"size": 10}');
      ok := false; msg := 'A supervisor could add a view file.';
    exception when others then if sqlerrm !~* 'row-level security|violates|permission' then ok := false; msg := 'Error: ' || sqlerrm; end if;
    end;
    execute 'reset role';
    res := res || check_row(3, 'A supervisor (a tablet) opens view files but can''t add them', ok, msg);

    -- ---- 4. a look-up login and no login see nothing --------------------------
    ok := true; msg := null;
    if look is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', look, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from storage.objects where bucket_id = 'designs';
      execute 'reset role';
      if n <> 0 then ok := false; msg := 'A look-up login sees ' || n || ' view files.'; end if;
    end if;
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select count(*) into n from storage.objects where bucket_id = 'designs';
      execute 'reset role';
      if n <> 0 then ok := false; msg := concat_ws(' ', msg, 'Someone with no login sees ' || n || ' view files.'); end if;
    exception when insufficient_privilege then execute 'reset role';
    end;
    res := res || check_row(4, 'A look-up login (sales) and someone with no login see none of them', ok, msg);

    -- ---- 5. clearing: a supervisor can't; a manager can, test files only ---------
    perform set_config('storage.allow_delete_query', 'true', true);         -- as Supabase's storage does for its own deletes
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      delete from storage.objects where bucket_id = 'designs' and name = good;
      get diagnostics n = row_count;
    exception when insufficient_privilege then n := 0;
    end;
    execute 'reset role';
    ok := n = 0; msg := 'A supervisor could clear a view file.';
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      delete from storage.objects where bucket_id = 'designs' and name = good;
      get diagnostics n = row_count;
      ok := ok and n = 1; if n <> 1 then msg := 'A manager couldn''t clear a test view file.'; end if;
    exception when others then
      if sqlerrm not ilike '%direct deletion%' then raise; end if;    -- this Supabase stops file deletes from SQL; the rule is checked above
    end;
    execute 'reset role';
    res := res || check_row(5, 'A manager can clear a test view file; a supervisor can''t', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_designs_undo__';
  exception when others then
    if sqlerrm <> '__check_designs_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('storage.allow_delete_query', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_designs() from public, anon, authenticated;

select * from check_designs();
