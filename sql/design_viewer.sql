-- =====================================================================
-- design_viewer.sql — the 3D design viewer (1 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 52. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Needs zip_drop.sql (run order 50) first. Run it BEFORE the new pages
-- go on GitHub; today's pages never read anything it adds.
--
-- WHAT IT DOES (design: the 3D design viewer tab, 31 Oct – 1 Nov)
-- A job's zip can carry one whole-piece STEP per item in Design/
-- (11_SHOP_FLOOR_ZIP.md v2). When Luke drops it, the drop page turns each
-- one into a light view file on his PC (Fine detail, Z up to start: the shop's setting) and saves it
-- here. Full Custom's tablet and the office open it, turn it and measure.
-- 1. item_designs: one row per item's 3D model, from the zip that brought
--    it. The newest one for a job's item is the one shown; older ones are
--    kept (superseded_at). Nothing is deleted.
-- 2. A private design-views bucket for the view files (gzip, 20 MB at
--    most). The test page's designs bucket (designs.sql) is untouched.
-- 3. Who sees them: managers, and supervisors who work in a department on
--    a list, Full Custom to start. Widen it from the SQL Editor, e.g.
--        select set_design_departments('{full_custom,assembly_qc}');
--    Look-up logins (sales), machine logins and no login see nothing.
-- 4. design_register(), design_view_stored(), design_view_failed(): the
--    drop page (lab logins). set_design_up(): turn a design upright (lab
--    logins and managers). A view file goes in only at the place its row
--    names, and nobody changes or removes one.
-- 5. While a 3D model's STEP file is still parked on Supabase, the people
--    who see designs may read it, so a tablet can make a missing view
--    itself. Nothing else parked becomes readable.
-- Nothing existing changes.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('design_viewer.sql', 52, 'check_design_viewer', 'check_design_viewer', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('design_viewer.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regclass('public.parked_files') is null or to_regprocedure('public.lab_allowed()') is null then
    raise exception 'Run zip_drop.sql first (run order 50). This file builds on it.';
  end if;
  if to_regclass('public.app_settings') is null then raise exception 'Run arrow_qc.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.sees_lane(boolean)') is null or to_regprocedure('public.is_manager()') is null then
    raise exception 'Run problems.sql first. This file builds on it.';
  end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Who sees 3D designs: a setting, Full Custom to start
-- ---------------------------------------------------------------------

-- kept if it's already there, so running this file again never undoes a widened list
insert into app_settings (key, value, updated_by_name) values ('design_departments', '["full_custom"]', 'design_viewer.sql')
on conflict (key) do nothing;

-- Which way is up when a design is first made (Luke, 1 Nov: his Fusion designs are drawn Z up as standard). Kept if it's
-- already there; change it in the SQL Editor with:  select set_design_default_up('y');
insert into app_settings (key, value, updated_by_name) values ('design_default_up', '"z"', 'design_viewer.sql')
on conflict (key) do nothing;

create or replace function design_default_up() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select s.value #>> '{}' from app_settings s where s.key = 'design_default_up' and s.value #>> '{}' in ('y', 'z', 'x')), 'z');
$$;
revoke all on function design_default_up() from public, anon;
grant execute on function design_default_up() to authenticated;

create or replace function design_departments() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select array(select jsonb_array_elements_text(s.value)) from app_settings s
                    where s.key = 'design_departments' and jsonb_typeof(s.value) = 'array'), '{}'::text[]);
$$;
revoke all on function design_departments() from public, anon;
grant execute on function design_departments() to authenticated;

-- a manager, or a supervisor who works in one of those departments; never a look-up login
-- (look_up is read through to_jsonb so this works whether or not job_status.sql has run)
create or replace function design_viewer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p
                  where p.id = auth.uid() and p.active
                    and not coalesce((to_jsonb(p) ->> 'look_up')::boolean, false)
                    and (p.role in ('manager', 'admin')
                         or (p.role = 'supervisor' and p.departments && design_departments())));
$$;
revoke all on function design_viewer() from public, anon;
grant execute on function design_viewer() to authenticated;

-- SQL Editor only: who sees 3D designs (managers always do)
create or replace function set_design_departments(p_departments text[]) returns text
language plpgsql set search_path = public as $$
declare v_bad text; v_keep text[];
begin
  select string_agg(d, ', ') into v_bad from unnest(coalesce(p_departments, '{}')) d
   where not exists (select 1 from departments x where x.key = d);
  if v_bad is not null then
    raise exception 'Not a department: %. Use the department keys (milling, cnc, sanding, finishing, full_custom, metal, assembly_qc).', v_bad;
  end if;
  select coalesce(array_agg(distinct d order by d), '{}') into v_keep from unnest(coalesce(p_departments, '{}')) d;
  insert into app_settings (key, value, updated_by_name, updated_at) values ('design_departments', to_jsonb(v_keep), 'SQL Editor', now())
  on conflict (key) do update set value = excluded.value, updated_by_name = excluded.updated_by_name, updated_at = now();
  return case when cardinality(v_keep) = 0 then 'Only managers see 3D designs now.'
              else format('3D designs are now seen by managers and %s.',
                          (select string_agg(x.name, ', ' order by x.sort_order) from departments x where x.key = any(v_keep))) end;
end $$;
revoke all on function set_design_departments(text[]) from public, anon, authenticated;

-- SQL Editor only: which way is up for designs made from now on (one already made keeps its own)
create or replace function set_design_default_up(p_up text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_up is null or lower(btrim(p_up)) not in ('y', 'z', 'x') then raise exception 'Up is y, z or x.'; end if;
  insert into app_settings (key, value, updated_by_name, updated_at) values ('design_default_up', to_jsonb(lower(btrim(p_up))), 'SQL Editor', now())
  on conflict (key) do update set value = excluded.value, updated_by_name = excluded.updated_by_name, updated_at = now();
  return format('New 3D designs start with %s up. Ones already made keep theirs.', upper(lower(btrim(p_up))));
end $$;
revoke all on function set_design_default_up(text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. The 3D models
--    view_path: <job>/<the STEP's fingerprint>.<detail>.view.json.gz in
--    the design-views bucket, so the same STEP is never made twice.
--    step_path: where the STEP is parked (parked-files), while it is.
-- ---------------------------------------------------------------------

create table if not exists item_designs (
  id             uuid primary key default gen_random_uuid(),
  parked_file_id uuid        not null unique references parked_files(id),
  project_id     text        not null,
  is_test        boolean     not null default false,
  item           text        not null,
  step_name      text        not null,
  step_bytes     bigint      not null,
  step_sha256    text        not null,
  step_path      text,
  detail         text        not null default 'fine',
  view_path      text        not null,
  status         text        not null default 'waiting',
  failed_why     text,
  up             text        not null default 'z',
  view_bytes     bigint,
  size_in        numeric[],
  parts          int,
  triangles      int,
  convert_ms     int,
  registered_by  uuid        not null references profiles(id),
  registered_at  timestamptz not null default now(),
  made_by        uuid        references profiles(id),
  made_at        timestamptz,
  up_by          uuid        references profiles(id),
  up_at          timestamptz,
  superseded_at  timestamptz,
  constraint item_designs_project check (project_id ~ '^(PROJ|TEST)-[0-9]{5}$' and is_test = (project_id like 'TEST-%')),
  constraint item_designs_item    check (length(btrim(item)) between 1 and 80),
  constraint item_designs_sha     check (step_sha256 ~ '^[0-9a-f]{64}$'),
  constraint item_designs_detail  check (detail in ('normal', 'fine', 'veryfine')),
  constraint item_designs_status  check (status in ('waiting', 'ready', 'failed')),
  constraint item_designs_up      check (up in ('y', 'z', 'x')),
  constraint item_designs_path    check (view_path = project_id || '/' || step_sha256 || '.' || detail || '.view.json.gz'),
  constraint item_designs_ready   check (status <> 'ready' or (view_bytes > 0 and cardinality(size_in) = 3 and parts > 0))
);
create index if not exists item_designs_job on item_designs (project_id, item) where superseded_at is null;
create index if not exists item_designs_view on item_designs (view_path);

alter table item_designs enable row level security;
revoke all on item_designs from anon, authenticated;
grant select on item_designs to authenticated;              -- which rows: the policy below
drop policy if exists item_designs_read on item_designs;
create policy item_designs_read on item_designs for select to authenticated
  using ((design_viewer() or lab_allowed()) and sees_lane(is_test));


-- ---------------------------------------------------------------------
-- 3. The bucket
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('design-views', 'design-views', false, 20971520, array['application/gzip'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;


-- ---------------------------------------------------------------------
-- 4. The drop page (lab logins): register a Design/ file, then say its
--    view is stored, or why it couldn't be made
-- ---------------------------------------------------------------------

create or replace function design_json(d item_designs) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('id', d.id, 'project_id', d.project_id, 'item', d.item, 'status', d.status, 'view_path', d.view_path,
           'step_path', d.step_path, 'step_name', d.step_name, 'step_bytes', d.step_bytes, 'up', d.up, 'detail', d.detail,
           'failed_why', d.failed_why, 'size_in', d.size_in, 'parts', d.parts, 'needs_view', d.status <> 'ready');
$$;
revoke all on function design_json(item_designs) from public, anon;

alter table item_designs alter column up set default 'z';   -- the same start as design_default_up()

create or replace function design_register(p_parked uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f parked_files; src parked_files; cur item_designs; prev item_designs; d item_designs; v_path text;
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab makes 3D views.' using errcode = 'insufficient_privilege'; end if;
  select p.* into f from parked_files p join zip_drops z on z.id = p.drop_id
   where p.id = p_parked and p.place = 'job' and p.rel_path like 'Design/%' and z.dropped_by = auth.uid();
  if f.id is null then raise exception 'That isn''t a 3D model from a zip you dropped.'; end if;
  if coalesce(btrim(f.item), '') = '' then raise exception '% doesn''t say which item it''s the 3D model of.', f.zip_path; end if;
  select * into d from item_designs where parked_file_id = f.id;
  if d.id is not null then return design_json(d) || jsonb_build_object('unchanged', false); end if;     -- asked twice: the same answer
  src := f;
  if f.same_as is not null then select * into src from parked_files where id = f.same_as; end if;      -- unchanged since an earlier zip
  if src.stored_at is null then raise exception '% hasn''t arrived in storage yet. Drop the zip again.', f.zip_path; end if;

  -- the same STEP is already this item's design: nothing to do
  select * into cur from item_designs where project_id = f.project_id and item = btrim(f.item) and superseded_at is null
   order by registered_at desc limit 1;
  if cur.id is not null and cur.step_sha256 = f.sha256 and cur.detail = 'fine' then
    return design_json(cur) || jsonb_build_object('unchanged', true);
  end if;

  v_path := f.project_id || '/' || f.sha256 || '.fine.view.json.gz';
  select * into prev from item_designs where view_path = v_path and status = 'ready' order by made_at desc limit 1;   -- made before: used again
  update item_designs set superseded_at = now() where project_id = f.project_id and item = btrim(f.item) and superseded_at is null;
  insert into item_designs (parked_file_id, project_id, is_test, item, step_name, step_bytes, step_sha256, step_path, detail, view_path,
                            status, up, view_bytes, size_in, parts, triangles, convert_ms, registered_by, made_by, made_at)
  values (f.id, f.project_id, f.project_id like 'TEST-%', btrim(f.item), split_part(f.rel_path, '/', 2), f.size_bytes, f.sha256,
          case when src.removed_at is null then src.storage_path end, 'fine', v_path,
          case when prev.id is null then 'waiting' else 'ready' end, coalesce(prev.up, design_default_up()),
          prev.view_bytes, prev.size_in, prev.parts, prev.triangles, prev.convert_ms, auth.uid(), prev.made_by, prev.made_at)
  returning * into d;
  return design_json(d) || jsonb_build_object('unchanged', false);
end $$;
revoke all on function design_register(uuid) from public, anon;
grant execute on function design_register(uuid) to authenticated;

-- the view file is in storage: the facts the page worked out, checked; every row waiting on that file is ready
create or replace function design_view_stored(p_id uuid, p_facts jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d item_designs; v_bytes bigint; v_size numeric[]; v_up text; n int;
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab makes 3D views.' using errcode = 'insufficient_privilege'; end if;
  select * into d from item_designs where id = p_id;
  if d.id is null then raise exception 'There''s no such 3D model.'; end if;
  select (o.metadata ->> 'size')::bigint into v_bytes from storage.objects o where o.bucket_id = 'design-views' and o.name = d.view_path;
  if coalesce(v_bytes, 0) <= 0 then raise exception 'The view file for % hasn''t arrived in storage. Make it again.', d.item; end if;
  if jsonb_typeof(p_facts) is distinct from 'object' or jsonb_typeof(p_facts -> 'size_in') is distinct from 'array'
     or jsonb_array_length(p_facts -> 'size_in') <> 3 then
    raise exception 'The page sent no overall size (three numbers, in inches).';
  end if;
  select array_agg(x::numeric) into v_size from jsonb_array_elements_text(p_facts -> 'size_in') x;
  if exists (select 1 from unnest(v_size) s where s < 0 or s > 100000) then raise exception 'The overall size isn''t believable.'; end if;
  if coalesce((p_facts ->> 'parts')::numeric, 0) not between 1 and 100000 or coalesce((p_facts ->> 'triangles')::numeric, -1) < 1
     or coalesce((p_facts ->> 'convert_ms')::numeric, -1) < 0 then
    raise exception 'The page sent no parts, triangles or time.';
  end if;
  v_up := coalesce(p_facts ->> 'up', d.up);
  if v_up not in ('y', 'z', 'x') then raise exception 'Up is y, z or x.'; end if;
  update item_designs set status = 'ready', failed_why = null, view_bytes = v_bytes, size_in = v_size,
         parts = (p_facts ->> 'parts')::numeric::int, triangles = (p_facts ->> 'triangles')::numeric::int,
         convert_ms = (p_facts ->> 'convert_ms')::numeric::int, made_by = auth.uid(), made_at = now(),
         up = case when id = p_id then v_up else up end
   where view_path = d.view_path and status <> 'ready';
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'ready', n);
end $$;
revoke all on function design_view_stored(uuid, jsonb) from public, anon;
grant execute on function design_view_stored(uuid, jsonb) to authenticated;

create or replace function design_view_failed(p_id uuid, p_why text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not lab_allowed() then raise exception 'Only a login let into the lab makes 3D views.' using errcode = 'insufficient_privilege'; end if;
  update item_designs set status = 'failed', failed_why = left(coalesce(nullif(btrim(p_why), ''), 'No reason given.'), 500)
   where id = p_id and status <> 'ready';
  return jsonb_build_object('ok', true, 'failed', found);
end $$;
revoke all on function design_view_failed(uuid, text) from public, anon;
grant execute on function design_view_failed(uuid, text) to authenticated;

-- turn a design upright: lab logins (the drop page) and managers (the office)
create or replace function set_design_up(p_id uuid, p_up text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (lab_allowed() or is_manager()) then raise exception 'Only a manager turns a design.' using errcode = 'insufficient_privilege'; end if;
  if p_up is null or p_up not in ('y', 'z', 'x') then raise exception 'Up is y, z or x.'; end if;
  update item_designs set up = p_up, up_by = auth.uid(), up_at = now() where id = p_id;
  if not found then raise exception 'There''s no such 3D model.'; end if;
  return jsonb_build_object('ok', true, 'up', p_up);
end $$;
revoke all on function set_design_up(uuid, text) from public, anon;
grant execute on function set_design_up(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 5. Storage rules. A view file: read by those who see designs, once
--    ready; put in by a lab login only where a row still waits for it;
--    never changed or removed (no rule allows it). A 3D model's parked
--    STEP: read by those who see designs while it's parked.
-- ---------------------------------------------------------------------

create or replace function design_view_readable(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select (design_viewer() or lab_allowed())
     and exists (select 1 from item_designs d where d.view_path = p_name and d.status = 'ready' and sees_lane(d.is_test));
$$;
create or replace function design_view_addable(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select lab_allowed() and exists (select 1 from item_designs d where d.view_path = p_name and d.status <> 'ready');
$$;
create or replace function design_step_readable(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select design_viewer()
     and exists (select 1 from parked_files f where f.storage_path = p_name and f.place = 'job' and f.rel_path like 'Design/%'
                    and f.removed_at is null and sees_lane(f.project_id like 'TEST-%'));
$$;
revoke all on function design_view_readable(text), design_view_addable(text), design_step_readable(text) from public, anon;
grant execute on function design_view_readable(text), design_view_addable(text), design_step_readable(text) to authenticated;   -- the storage rules run as the login

drop policy if exists "design views: read" on storage.objects;
create policy "design views: read" on storage.objects for select to authenticated
  using (bucket_id = 'design-views' and public.design_view_readable(name));
drop policy if exists "design views: lab adds" on storage.objects;
create policy "design views: lab adds" on storage.objects for insert to authenticated
  with check (bucket_id = 'design-views' and public.design_view_addable(name));
drop policy if exists "parked files: 3D models for those who see designs" on storage.objects;
create policy "parked files: 3D models for those who see designs" on storage.objects for select to authenticated
  using (bucket_id = 'parked-files' and public.design_step_readable(name));


-- ---------------------------------------------------------------------
-- 6. The check. It practises with made-up logins (a lab login, a Full
--    Custom supervisor, a Sanding supervisor, a look-up login) and a
--    made-up job's zip, signed in the way Supabase does it, and undoes
--    all of it at the end.
-- ---------------------------------------------------------------------

create or replace function check_design_viewer()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  lab uuid := gen_random_uuid(); fc uuid := gen_random_uuid(); oth uuid := gen_random_uuid(); look uuid := gen_random_uuid();
  drp uuid := gen_random_uuid(); drp2 uuid := gen_random_uuid();
  pf1 uuid := gen_random_uuid(); pf2 uuid := gen_random_uuid(); pf3 uuid := gen_random_uuid(); pf4 uuid := gen_random_uuid();
  sha1 text := repeat('d1', 32); sha2 text := repeat('d2', 32);
  p1 text; p2 text; p3 text; p4 text;
  v jsonb; v2 jsonb; d1 uuid; d4 uuid; vp text; b storage.buckets;
  n int; m int; k int; ok boolean; msg text; t record;
  has_look boolean := exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'look_up');
  nu int := 0;
  as_lab text := json_build_object('sub', lab, 'role', 'authenticated')::text;
  as_fc text := json_build_object('sub', fc, 'role', 'authenticated')::text;
  as_oth text := json_build_object('sub', oth, 'role', 'authenticated')::text;
  as_look text := json_build_object('sub', look, 'role', 'authenticated')::text;
begin
  -- ---- 1. the table, the bucket and the storage rules -----------------------------------------------
  select * into b from storage.buckets where id = 'design-views';
  ok := b.id is not null and not b.public and b.file_size_limit = 20971520 and b.allowed_mime_types = array['application/gzip']
        and coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.item_designs')), false)
        and not has_table_privilege('authenticated', 'public.item_designs', 'insert') and not has_table_privilege('authenticated', 'public.item_designs', 'update')
        and not has_table_privilege('authenticated', 'public.item_designs', 'delete') and not has_table_privilege('authenticated', 'public.item_designs', 'truncate')
        and not has_table_privilege('anon', 'public.item_designs', 'select')
        and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname in ('design views: read', 'design views: lab adds', 'parked files: 3D models for those who see designs')) = 3
        and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                         and cmd in ('UPDATE', 'DELETE', 'ALL') and coalesce(qual, '') || coalesce(with_check, '') like '%design-views%');
  res := res || check_row(1, 'The 3D designs table has row-level security and no login writes it; the design-views bucket is private, gzip only, 20 MB at most, with its rules and none that changes or removes a file', ok,
    'The table, the bucket or a rule is missing or wrong. Run design_viewer.sql again.');

  -- ---- 2. functions need a login; the setting is the SQL Editor's ------------------------------------
  ok := true; msg := null;
  for t in select y.f from unnest(array['design_register(uuid)', 'design_view_stored(uuid,jsonb)', 'design_view_failed(uuid,text)',
         'set_design_up(uuid,text)', 'design_viewer()', 'design_departments()', 'design_default_up()', 'design_view_readable(text)', 'design_view_addable(text)',
         'design_step_readable(text)']) y(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then ok := false; msg := concat_ws(' ', msg, t.f); end if;
  end loop;
  if to_regprocedure('public.set_design_departments(text[])') is null
     or has_function_privilege('authenticated', 'public.set_design_departments(text[])', 'execute')
     or has_function_privilege('anon', 'public.set_design_departments(text[])', 'execute') then
    ok := false; msg := concat_ws(' ', msg, 'set_design_departments(text[]) (should be the SQL Editor''s only)');
  end if;
  if has_function_privilege('authenticated', 'public.set_design_default_up(text)', 'execute')
     or has_function_privilege('anon', 'public.set_design_default_up(text)', 'execute') then
    ok := false; msg := concat_ws(' ', msg, 'set_design_default_up(text) (should be the SQL Editor''s only)');
  end if;
  res := res || check_row(2, 'Its functions need a login, and only the SQL Editor sets who sees designs and which way is up to start', ok,
    coalesce('Missing, or open to the wrong logins: ' || msg, ''));

  -- ---- 3. the setting: a list of real departments -------------------------------------------------------
  select count(*) into n from app_settings where key = 'design_departments' and jsonb_typeof(value) = 'array';
  select count(*) into m from unnest(design_departments()) d where not exists (select 1 from departments x where x.key = d);
  select count(*) into nu from app_settings where key = 'design_default_up' and value #>> '{}' in ('y', 'z', 'x');
  res := res || check_row(3, 'Who sees 3D designs (Full Custom to start) and which way is up to start (Z, as Luke''s Fusion designs are drawn) are settings, and they hold real values',
    n = 1 and m = 0 and nu = 1,
    case when n = 0 then 'The setting is missing. Run design_viewer.sql again.' when m > 0 then m || ' name(s) in it aren''t departments. Set it again with set_design_departments().'
         else 'The starting Up is missing or isn''t y, z or x. Set it with: select set_design_default_up(''z'');' end);

  begin    -- everything below is undone at the end
    update app_settings set value = '["full_custom"]' where key = 'design_departments';      -- the practice uses the starting list
    insert into auth.users (id, email) values (lab, 'check-design-lab-' || lab || '@example.com'), (fc, 'check-design-fc-' || fc || '@example.com'),
                                              (oth, 'check-design-oth-' || oth || '@example.com'), (look, 'check-design-look-' || look || '@example.com');
    insert into profiles (id, full_name, role, departments) values (lab, 'Design check (lab)', 'manager', '{}'),
      (fc, 'Design check (Full Custom)', 'supervisor', '{full_custom}'), (oth, 'Design check (Sanding)', 'supervisor', '{sanding}'),
      (look, 'Design check (look-up)', 'supervisor', '{}');
    if has_look then execute 'update profiles set look_up = true where id = $1' using look; end if;
    insert into lab_users (user_id) values (lab);
    insert into zip_drops (id, project_id, zip_name, format, made_at, contents, dropped_by)
    values (drp, 'PROJ-99973', 'PROJ-99973.zip', 2, now(), '{}', lab), (drp2, 'PROJ-99973', 'PROJ-99973 r2.zip', 2, now(), '{}', lab);
    p1 := 'PROJ-99973/' || drp || '/' || pf1 || '/Table.step';  p2 := 'PROJ-99973/' || drp || '/' || pf2 || '/Base.step';
    p3 := 'PROJ-99973/' || drp || '/' || pf3 || '/notes.pdf';   p4 := 'PROJ-99973/' || drp2 || '/' || pf4 || '/Table.step';
    insert into parked_files (id, drop_id, project_id, zip_path, place, rel_path, what, item, size_bytes, sha256, storage_path, stored_at) values
      (pf1, drp, 'PROJ-99973', 'Design/Table.step', 'job', 'Design/Table.step', '3D model', 'DV-1', 5000, sha1, p1, now()),
      (pf2, drp, 'PROJ-99973', 'Design/Base.step', 'job', 'Design/Base.step', '3D model', 'DV-2', 6000, repeat('d3', 32), p2, now()),
      (pf3, drp, 'PROJ-99973', 'Files/Other/notes.pdf', 'job', 'Other/notes.pdf', 'notes', null, 700, repeat('d4', 32), p3, now()),
      (pf4, drp2, 'PROJ-99973', 'Design/Table.step', 'job', 'Design/Table.step', '3D model', 'DV-1', 5100, sha2, p4, now());
    insert into storage.objects (bucket_id, name, metadata) values ('parked-files', p1, '{"size": 5000}'), ('parked-files', p2, '{"size": 6000}'),
      ('parked-files', p3, '{"size": 700}'), ('parked-files', p4, '{"size": 5100}');

    -- ---- 4. a lab login registers a 3D model from its own drop; nobody else can --------------------------
    ok := true; msg := null;
    perform set_config('request.jwt.claims', as_lab, true);
    begin
      execute 'set local role authenticated';
      v := design_register(pf1); v2 := design_register(pf1);
      execute 'reset role';
      d1 := (v ->> 'id')::uuid; vp := v ->> 'view_path';
      if v ->> 'status' <> 'waiting' or vp <> 'PROJ-99973/' || sha1 || '.fine.view.json.gz' or (v2 ->> 'id')::uuid <> d1 or v ->> 'step_path' <> p1 then
        ok := false; msg := 'It came back as ' || v::text;
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', as_oth, true);
    begin
      execute 'set local role authenticated';
      perform design_register(pf2);
      execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'A Sanding supervisor registered a 3D model.');
    exception when insufficient_privilege then execute 'reset role';
    when others then execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'Error: ' || sqlerrm);
    end;
    res := res || check_row(4, 'A lab login registers a 3D model from its own drop (asking twice gives the same answer); a supervisor can''t', ok, msg);

    -- ---- 5. the view file goes in only where its row waits for it, from a lab login; then it's ready ------
    ok := true; msg := null;
    perform set_config('request.jwt.claims', as_fc, true);
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('design-views', vp, '{"size": 1200}');
      execute 'reset role'; ok := false; msg := 'A Full Custom supervisor put a view file in.';
    exception when others then execute 'reset role';
      if sqlerrm !~* 'row-level security|violates|permission' then ok := false; msg := 'Error: ' || sqlerrm; end if;
    end;
    perform set_config('request.jwt.claims', as_lab, true);
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('design-views', 'PROJ-99973/somewhere-else.view.json.gz', '{"size": 1200}');
      execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'A view file went in at a place no row names.');
    exception when others then execute 'reset role';
      if sqlerrm !~* 'row-level security|violates|permission' then ok := false; msg := concat_ws('; ', msg, 'Error: ' || sqlerrm); end if;
    end;
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('design-views', vp, '{"size": 1200, "mimetype": "application/gzip"}');
      begin
        perform design_view_stored(d1, '{"size_in": [48, 29.5], "parts": 3, "triangles": 100, "convert_ms": 900}');
        ok := false; msg := concat_ws('; ', msg, 'An overall size of two numbers was taken.');
      exception when others then null;
      end;
      v := design_view_stored(d1, '{"size_in": [48, 29.5, 30], "parts": 3, "triangles": 100, "convert_ms": 900, "up": "y"}');
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'Error: ' || sqlerrm);
    end;
    select count(*) into n from item_designs where id = d1 and status = 'ready' and view_bytes = 1200 and size_in = array[48, 29.5, 30]::numeric[] and parts = 3 and made_by = lab;
    ok := ok and n = 1; if n <> 1 then msg := concat_ws('; ', msg, 'The 3D model isn''t ready with its facts.'); end if;
    res := res || check_row(5, 'A view file goes in only where its row waits for it, and only from a lab login; then the model is ready with its size, parts and time', ok, msg);

    -- ---- 6. Full Custom reads it; Sanding, a look-up login and no login don't ----------------------------
    ok := true; msg := null;
    for t in select * from (values ('Full Custom', as_fc, 1), ('Sanding', as_oth, 0), ('a look-up login', as_look, case when has_look then 0 else -1 end)) y(who, claims, want) loop
      if t.want < 0 then continue; end if;
      perform set_config('request.jwt.claims', t.claims, true);
      begin
        execute 'set local role authenticated';
        select count(*) into n from item_designs where project_id = 'PROJ-99973';
        select count(*) into m from storage.objects where bucket_id = 'design-views' and name = vp;
        execute 'reset role';
        if n <> t.want or m <> t.want then ok := false; msg := concat_ws('; ', msg, format('%s sees %s rows and %s view files', t.who, n, m)); end if;
      exception when others then execute 'reset role'; ok := false; msg := concat_ws('; ', msg, t.who || ': ' || sqlerrm);
      end;
    end loop;
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select count(*) into n from storage.objects where bucket_id = 'design-views';
      execute 'reset role';
      if n <> 0 then ok := false; msg := concat_ws('; ', msg, 'Someone with no login sees ' || n || ' view files.'); end if;
    exception when insufficient_privilege then execute 'reset role';
    end;
    begin
      execute 'set local role anon';
      select count(*) into n from item_designs;
      execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'Someone with no login reads the 3D models table.');
    exception when insufficient_privilege then execute 'reset role';
    end;
    res := res || check_row(6, 'Full Custom''s supervisor reads the model and its view file; Sanding, a look-up login (sales) and no login see neither', ok, msg);

    -- ---- 7. a 3D model's parked STEP: readable by Full Custom while it's parked; nothing else parked is ----
    perform set_config('request.jwt.claims', as_fc, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where name = p1), count(*) filter (where name = p3) into n, m from storage.objects where bucket_id = 'parked-files';
      execute 'reset role';
      ok := n = 1 and m = 0; msg := format('Full Custom sees the STEP %s time(s) and the parked PDF %s time(s).', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', as_oth, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from storage.objects where bucket_id = 'parked-files' and name = p1;
      execute 'reset role';
      if n <> 0 then ok := false; msg := msg || ' Sanding sees the STEP too.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := msg || ' Error: ' || sqlerrm;
    end;
    update parked_files set removed_at = now() where id = pf2;          -- once a STEP has left Supabase, its rule ends
    perform set_config('request.jwt.claims', as_fc, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from storage.objects where bucket_id = 'parked-files' and name = p2;
      execute 'reset role';
      if n <> 0 then ok := false; msg := msg || ' A STEP marked off Supabase is still readable.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := msg || ' Error: ' || sqlerrm;
    end;
    update parked_files set removed_at = null where id = pf2;
    res := res || check_row(7, 'While a 3D model''s STEP is parked, Full Custom can read it (to make a missing view on the tablet); Sanding can''t, and nothing else parked opens up', ok, msg);

    -- ---- 8. a newer model for the same item takes over; the older is kept --------------------------------
    ok := true; msg := null;
    perform set_config('request.jwt.claims', as_lab, true);
    begin
      execute 'set local role authenticated';
      v := design_register(pf4); d4 := (v ->> 'id')::uuid;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    select count(*), count(*) filter (where superseded_at is null and id = d4), count(*) filter (where superseded_at is not null and id = d1)
      into n, m, k from item_designs where project_id = 'PROJ-99973' and item = 'DV-1';
    ok := ok and n = 2 and m = 1 and k = 1 and v ->> 'status' = 'waiting';
    if not ok then msg := concat_ws('; ', msg, format('%s rows for the item, %s current new one, %s old one kept as superseded', n, m, k)); end if;
    res := res || check_row(8, 'A newer 3D model for the same item becomes the one shown; the older one is kept', ok, msg);

    -- ---- 9. a view that can't be made keeps its reason; turning a design: lab and managers, not supervisors -
    ok := true; msg := null;
    perform set_config('request.jwt.claims', as_lab, true);
    begin
      execute 'set local role authenticated';
      perform design_view_failed(d4, 'The engine couldn''t read it (a practice reason).');
      perform set_design_up(d1, 'z');
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    select count(*) into n from item_designs where (id = d4 and status = 'failed' and failed_why like 'The engine%' and up = design_default_up()) or (id = d1 and up = 'z' and up_by = lab);
    if n <> 2 then ok := false; msg := concat_ws('; ', msg, 'The reason, the starting Up (the shop''s setting) or the turn wasn''t kept.'); end if;
    perform set_config('request.jwt.claims', as_fc, true);
    begin
      execute 'set local role authenticated';
      perform set_design_up(d1, 'x');
      execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'A supervisor turned a design.');
    exception when insufficient_privilege then execute 'reset role';
    when others then execute 'reset role'; ok := false; msg := concat_ws('; ', msg, 'Error: ' || sqlerrm);
    end;
    res := res || check_row(9, 'A view that couldn''t be made keeps its reason in words; a lab login turns a design upright, a supervisor can''t', ok, msg);

    -- ---- 10. nobody changes or removes a view file ---------------------------------------------------------
    perform set_config('storage.allow_delete_query', 'true', true);         -- as Supabase's storage does for its own deletes
    perform set_config('request.jwt.claims', as_lab, true);
    begin
      execute 'set local role authenticated';
      update storage.objects set metadata = '{"size": 1}' where bucket_id = 'design-views' and name = vp;
      get diagnostics n = row_count;
      delete from storage.objects where bucket_id = 'design-views' and name = vp;
      get diagnostics m = row_count;
      execute 'reset role';
      ok := n = 0 and m = 0; msg := format('A lab login changed %s and removed %s view files.', n, m);
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    perform set_config('storage.allow_delete_query', '', true);
    res := res || check_row(10, 'Nobody changes or removes a view file, not even a lab login', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_design_viewer_undo__';
  exception when others then
    if sqlerrm <> '__check_design_viewer_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('storage.allow_delete_query', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_design_viewer() from public, anon, authenticated;

select * from check_design_viewer();
