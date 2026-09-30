-- =====================================================================
-- Shop Floor — work order upload (Phase 1, step 2)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- Afterwards, run verify_setup.sql again — it should still say PASS.
--
-- What it adds:
--   1. A private storage bucket for the sheet files (PDF + PNG per sheet)
--   2. Two columns on sheets for the display image
--   3. upload_work_order() — takes one work order and saves it in a
--      single all-or-nothing step
--   4. mark_sheet_files() — records that a sheet's files arrived
--
-- Who can call the two functions: a MANAGER login, or anything using the
-- secret key. Supervisors cannot. Both routes are allowed on purpose, so
-- the upload can come either from a script with the secret key or from
-- an upload page that you sign in to.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Placeholder jobs
--
-- When a work order arrives before Monday knows the job, the job row is
-- created without a Monday id (null). The Monday sync later finds it by
-- PROJ number and fills the id in, instead of creating a duplicate.
-- ---------------------------------------------------------------------

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('upload_function.sql'); end if;
end $$;

alter table jobs alter column monday_item_id drop not null;

-- One row per PROJ number, enforced. Without this, a mistake in the sync
-- could create a second row for the same job, and the floor's counts
-- would stay stranded on the first. With it, that mistake fails loudly.
create unique index if not exists jobs_one_row_per_project
  on jobs (project_id) where project_id is not null;


-- ---------------------------------------------------------------------
-- 2. Sheet files
-- ---------------------------------------------------------------------

alter table sheets add column if not exists png_path text;   -- what the tablet displays
-- pdf_path and pdf_uploaded_at already exist from schema.sql


-- ---------------------------------------------------------------------
-- 3. Storage bucket — private, so only signed-in users can read files
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('work-orders', 'work-orders', false)
on conflict (id) do nothing;

-- anyone signed in can view sheet pages (the tablets need to)
drop policy if exists "shop floor: read sheet files" on storage.objects;
create policy "shop floor: read sheet files" on storage.objects
  for select to authenticated
  using (bucket_id = 'work-orders');

-- only managers can add or replace sheet files
-- (the secret key skips these rules entirely, which is why it stays secret)
drop policy if exists "shop floor: managers add sheet files" on storage.objects;
create policy "shop floor: managers add sheet files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'work-orders' and public.my_role() in ('manager','admin'));

drop policy if exists "shop floor: managers replace sheet files" on storage.objects;
create policy "shop floor: managers replace sheet files" on storage.objects
  for update to authenticated
  using (bucket_id = 'work-orders' and public.my_role() in ('manager','admin'));


-- ---------------------------------------------------------------------
-- 4. Who may upload
-- ---------------------------------------------------------------------

create or replace function can_upload_work_orders() returns boolean
language sql stable security definer set search_path = public as $$
  select
    -- the SQL Editor, for testing by hand
    session_user in ('postgres', 'supabase_admin')
    -- a script using the secret key
    or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
    -- a manager signed in
    or coalesce(my_role()::text, '') in ('manager', 'admin');
$$;


-- ---------------------------------------------------------------------
-- 5. upload_work_order(payload)
--
-- The payload is the JSON built by wo_upload.py:
--   { project_id, project_name, total_items, source_file,
--     sheets: [ { sheet_number, item_code, qty, species, ...,
--                 departments: ["milling", ...] } ] }
--
-- Everything happens in one step. If anything is wrong — a bad
-- department name, a duplicate sheet number — nothing is saved at all,
-- and the old version of the work order stays current.
-- ---------------------------------------------------------------------

create or replace function upload_work_order(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_project     text := nullif(trim(payload->>'project_id'), '');
  v_job         uuid;
  v_placeholder boolean := false;
  v_prev_wo     uuid;
  v_prev_ver    int;
  v_wo          uuid;
  v_version     int;
  s             jsonb;
  d             text;
  v_num         int;
  v_qty         int;
  v_hash        text;
  v_sheet       uuid;
  v_prev_sheet  uuid;
  v_prev_hash   text;
  v_done        int;
  v_sum         int := 0;
  v_valid       text[];
  v_seen        int[] := '{}';
  v_carried     int[] := '{}';
  v_reset       int[] := '{}';
  v_clamped     int[] := '{}';
  v_removed     int[] := '{}';
  v_warnings    text[] := '{}';
begin
  if not can_upload_work_orders() then
    raise exception 'Only a manager login or the secret key can upload work orders.'
      using errcode = 'insufficient_privilege';
  end if;

  -- ---- check the whole payload before touching anything -----------
  if v_project is null then
    raise exception 'project_id is missing.';
  end if;
  if jsonb_typeof(payload->'sheets') is distinct from 'array'
     or jsonb_array_length(payload->'sheets') = 0 then
    raise exception 'sheets must be a list with at least one sheet.';
  end if;

  select array_agg(key) into v_valid from departments;

  for s in select * from jsonb_array_elements(payload->'sheets') loop
    if jsonb_typeof(s->'sheet_number') is distinct from 'number'
       or (s->>'sheet_number')::numeric <> floor((s->>'sheet_number')::numeric)
       or (s->>'sheet_number')::int < 1 then
      raise exception 'Every sheet needs a whole-number sheet_number of 1 or more (got %).', s->'sheet_number';
    end if;
    v_num := (s->>'sheet_number')::int;
    if v_num = any(v_seen) then
      raise exception 'Sheet % appears twice.', v_num;
    end if;
    v_seen := v_seen || v_num;

    if jsonb_typeof(s->'qty') is distinct from 'number' or (s->>'qty')::int < 1 then
      raise exception 'Sheet %: qty must be 1 or more.', v_num;
    end if;
    if jsonb_typeof(s->'departments') is distinct from 'array'
       or jsonb_array_length(s->'departments') = 0 then
      raise exception 'Sheet %: departments list is missing.', v_num;
    end if;
    -- a typo here would silently hide a sheet from a department, so refuse loudly
    for d in select jsonb_array_elements_text(s->'departments') loop
      if not (d = any(v_valid)) then
        raise exception 'Sheet %: "%" is not a department. Valid: %.',
          v_num, d, array_to_string(v_valid, ', ');
      end if;
    end loop;
  end loop;

  -- ---- the job -------------------------------------------------------
  -- prefer the real Monday row if there's both a placeholder and a real one
  select id into v_job from jobs
   where project_id = v_project
   order by (monday_item_id is not null) desc, created_at
   limit 1;

  if v_job is null then
    insert into jobs (monday_item_id, project_id, name, is_active)
    values (null, v_project, coalesce(nullif(payload->>'project_name',''), v_project), true)
    returning id into v_job;
    v_placeholder := true;
  end if;

  -- ---- new version ----------------------------------------------------
  select id, version into v_prev_wo, v_prev_ver
    from work_orders where job_id = v_job and is_current;

  if v_prev_wo is not null then
    update work_orders set is_current = false, superseded_at = now() where id = v_prev_wo;
  end if;

  v_version := coalesce(v_prev_ver, 0) + 1;
  insert into work_orders (job_id, version, is_current, total_items, source_file)
  values (v_job, v_version, true,
          nullif(payload->>'total_items','')::int,
          nullif(payload->>'source_file',''))
  returning id into v_wo;

  -- ---- sheets and their counts -----------------------------------------
  for s in select * from jsonb_array_elements(payload->'sheets') loop
    v_num := (s->>'sheet_number')::int;
    v_qty := (s->>'qty')::int;
    v_sum := v_sum + v_qty;

    -- The physical spec only. Quantity and the department list are left out
    -- on purpose: going from 3 tables to 4 doesn't undo the 3 already sanded.
    v_hash := md5(jsonb_build_object(
      'item_code',    s->'item_code',
      'species',      s->'species',
      'shape',        s->'shape',
      'width',        s->'width',
      'length',       s->'length',
      'thickness',    s->'thickness',
      'total_height', s->'total_height',
      'top_spec',     coalesce(s->'top_spec',    '{}'::jsonb),
      'base_spec',    coalesce(s->'base_spec',   '{}'::jsonb),
      'finish_spec',  coalesce(s->'finish_spec', '{}'::jsonb),
      'cnc_program',  s->'cnc_program',
      'glue_up_notes',s->'glue_up_notes'
    )::text);

    v_prev_sheet := null; v_prev_hash := null;
    if v_prev_wo is not null then
      select id, spec_hash into v_prev_sheet, v_prev_hash
        from sheets where work_order_id = v_prev_wo and sheet_number = v_num;
    end if;

    insert into sheets (work_order_id, sheet_number, item_code, qty, species, shape,
                        width, length, thickness, total_height,
                        top_spec, base_spec, finish_spec,
                        cnc_program, glue_up_notes, floor_notes, spec_hash)
    values (v_wo, v_num, s->>'item_code', v_qty, s->>'species', s->>'shape',
            s->>'width', s->>'length', s->>'thickness', s->>'total_height',
            coalesce(s->'top_spec',    '{}'::jsonb),
            coalesce(s->'base_spec',   '{}'::jsonb),
            coalesce(s->'finish_spec', '{}'::jsonb),
            s->>'cnc_program', s->>'glue_up_notes', nullif(s->>'floor_notes',''), v_hash)
    returning id into v_sheet;

    for d in select jsonb_array_elements_text(s->'departments') loop
      v_done := 0;
      -- carry work forward only if the drawing it was done to still applies
      if v_prev_sheet is not null and v_prev_hash = v_hash then
        select least(qty_done, v_qty) into v_done
          from sheet_progress where sheet_id = v_prev_sheet and department = d;
        v_done := coalesce(v_done, 0);
      end if;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      values (v_sheet, d, v_qty, v_done);
    end loop;

    if v_prev_sheet is not null then
      if v_prev_hash = v_hash then
        v_carried := v_carried || v_num;
        if exists (select 1 from sheet_progress
                    where sheet_id = v_prev_sheet and qty_done > v_qty) then
          v_clamped := v_clamped || v_num;
        end if;
      else
        v_reset := v_reset || v_num;
      end if;
    end if;
  end loop;

  -- sheets on the old version that aren't on the new one
  if v_prev_wo is not null then
    select coalesce(array_agg(sheet_number order by sheet_number), '{}') into v_removed
      from sheets
     where work_order_id = v_prev_wo
       and not (sheet_number = any(v_seen));
  end if;

  -- ---- warnings, not errors --------------------------------------------
  if nullif(payload->>'total_items','') is not null
     and (payload->>'total_items')::int <> v_sum then
    v_warnings := v_warnings || format(
      'The sheets add up to %s pieces, but the work order says %s in total.',
      v_sum, payload->>'total_items');
  end if;
  if v_placeholder then
    v_warnings := v_warnings || format(
      '%s isn''t in the Monday sync yet. Saved anyway; it links up when Monday catches up.',
      v_project);
  end if;

  return jsonb_build_object(
    'ok',                 true,
    'project_id',         v_project,
    'job_id',             v_job,
    'work_order_id',      v_wo,
    'version',            v_version,
    'file_folder',        format('%s/v%s', v_project, v_version),
    'sheets',             jsonb_array_length(payload->'sheets'),
    'pieces',             v_sum,
    'carried_forward',    to_jsonb(v_carried),
    'reset_by_change',    to_jsonb(v_reset),
    'clamped_to_new_qty', to_jsonb(v_clamped),
    'removed',            to_jsonb(v_removed),
    'warnings',           to_jsonb(v_warnings)
  );
end;
$$;


-- ---------------------------------------------------------------------
-- 6. mark_sheet_files(work_order_id, files)
--
-- Called after the files are safely in storage. Until then a sheet's
-- paths stay empty, so the tablet can say "page not uploaded yet"
-- instead of showing a broken image.
--   files: [ { "sheet_number": 1, "pdf_path": "...", "png_path": "..." }, ... ]
-- ---------------------------------------------------------------------

create or replace function mark_sheet_files(p_work_order uuid, files jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not can_upload_work_orders() then
    raise exception 'Only a manager login or the secret key can record sheet files.'
      using errcode = 'insufficient_privilege';
  end if;

  update sheets s
     set pdf_path        = f->>'pdf_path',
         png_path        = f->>'png_path',
         pdf_uploaded_at = now()
    from jsonb_array_elements(files) f
   where s.work_order_id = p_work_order
     and s.sheet_number  = (f->>'sheet_number')::int;
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Permissions on the functions themselves
-- ---------------------------------------------------------------------

revoke all on function can_upload_work_orders()       from public, anon;
revoke all on function upload_work_order(jsonb)       from public, anon;
revoke all on function mark_sheet_files(uuid, jsonb)  from public, anon;
grant execute on function can_upload_work_orders()      to authenticated, service_role;
grant execute on function upload_work_order(jsonb)      to authenticated, service_role;
grant execute on function mark_sheet_files(uuid, jsonb) to authenticated, service_role;
-- authenticated is allowed to CALL them, but the check inside refuses
-- anyone who isn't a manager — so supervisors get a clear "no".
