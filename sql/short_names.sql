-- =====================================================================
-- short_names.sql — shorter names for what the save files (3 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 53. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it AFTER the new office page (2026-11-02.2) is on GitHub and open
-- on the office PC: that page renames what's already filed. An office
-- page older than that would file the new names beside the old ones.
--
-- WHY (design: the Short names tab, 2 Nov): Windows can't make a file
-- whose whole path is longer than about 260 characters, and the job
-- folders sit deep in SharePoint. PROJ-00099's delivery photos and
-- PROJ-00333's ticket couldn't be saved. A folder already says the job
-- and the item, so the names inside it no longer repeat them.
-- 1. v_filing: the save's names. In an item's folder a load-out photo is
--    "2 Delivery.jpg" (was "TB-03-2 Delivery Picture.jpg"), a defect
--    photo "Defect 1.jpg" (was "TB-03 Defect 1.jpg"); a trip's ticket is
--    "Ticket.pdf" (was "Delivery ticket.pdf"); a load-out photo's note
--    and a site file's name are cut at 30 and 40 letters (were 60, 80).
--    Folders don't change. The old name stays as old_file_name, so the
--    office's save renames what it already filed instead of filing it
--    twice. check_deliveries() expects the new names.
-- 2. The zip (11_SHOP_FLOOR_ZIP.md format 3): Files › Metal (was Metal
--    drawings), one folder per item in Bend-Tech and inside Files'
--    folders (Bend-Tech/TB-01/Post.step), named for its item, and every
--    job file's path as filed at most 45 characters (60 in the library).
--    Formats 1 and 2 are still read; their Metal drawings now files into
--    Metal too, and files already parked there move with it.
-- Replaces v_filing and check_deliveries() from trip_types.sql,
-- zip_path_place(), zip_drop_new() and check_zip_drop() from
-- zip_drop.sql, and check_delivery_types() from delivery_types.sql, so
-- those files now stop if run again. Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('short_names.sql', 53, 'check_short_names', 'check_short_names', '{trip_types.sql,zip_drop.sql,delivery_types.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('short_names.sql', '{trip_types.sql,zip_drop.sql,delivery_types.sql}'); end if;
end $$;

do $$ begin
  if to_regclass('public.parked_files') is null or to_regprocedure('public.zip_drop_new(text,jsonb,jsonb)') is null then
    raise exception 'Run zip_drop.sql first (run order 50). This file builds on it.';
  end if;
  if to_regclass('public.v_filing') is null or to_regclass('public.delivery_docs') is null then
    raise exception 'Run trip_types.sql first (run order 34). This file builds on it.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The save's names (v_filing). Same rows, same folders; file_name is
--    the short name and old_file_name (new, at the end) the one before.
-- ---------------------------------------------------------------------

create or replace view v_filing with (security_invoker = true) as
WITH sh AS (
         SELECT w.job_id,
            s.sheet_number,
            s.qty,
            COALESCE(NULLIF(TRIM(BOTH '-'::text FROM regexp_replace(TRIM(BOTH FROM COALESCE(s.item_code, ''::text)), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Sheet-'::text || lpad(s.sheet_number::text, 2, '0'::text)) AS item
           FROM work_orders w
             JOIN sheets s ON s.work_order_id = w.id
          WHERE w.is_current
        ), sh2 AS (
         SELECT sh.job_id,
            sh.sheet_number,
            sh.qty,
            sh.item,
            COALESCE(sum(sh.qty) OVER (PARTITION BY sh.job_id, sh.item ORDER BY sh.sheet_number ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::bigint)::integer AS unit_offset
           FROM sh
        ), ph AS (
         SELECT p.id,
            p.job_id,
            j.project_id,
            j.name AS job_name,
            p.is_test,
            p.storage_path,
            p.sheet_number,
            p.kind,
            p.stage,
            p.truck,
            p.pallet,
            p.note,
            p.taken_at AS at,
            p.taken_by_name AS by_name,
            p.voided_at IS NOT NULL AS mistake,
            p.department,
            p.loadout_id,
            p.lat,
            p.lng,
            p.gps_accuracy,
            p.shot_at,
            p.archive_batch,
            p.file_removed_at,
            p.bytes,
                CASE
                    WHEN p.sheet_number IS NOT NULL THEN COALESCE(s.item, 'Sheet-'::text || lpad(p.sheet_number::text, 2, '0'::text))
                    WHEN p.truck IS NOT NULL THEN 'Truck'::text
                    WHEN p.pallet IS NOT NULL THEN 'Pallets'::text
                    WHEN p.stage = 'bol'::text THEN 'BOL'::text
                    WHEN p.kind = 'loadout'::text THEN 'Other'::text
                    ELSE 'Job'::text
                END AS folder,
                CASE
                    WHEN p.kind = 'loadout'::text AND p.sheet_number IS NOT NULL THEN COALESCE(s.unit_offset, 0) + COALESCE(p.piece, 1)
                    ELSE NULL::integer
                END AS table_no,
                CASE p.kind
                    WHEN 'defect'::text THEN 'Defect'::text
                    WHEN 'problem'::text THEN 'Problem'::text
                    ELSE
                    CASE
                        WHEN p.truck IS NOT NULL THEN 'Truck'::text
                        WHEN p.pallet IS NOT NULL THEN 'Pallet'::text
                        WHEN p.stage = 'bol'::text THEN 'BOL'::text
                        WHEN p.stage = 'site'::text THEN 'Delivery Picture'::text
                        WHEN l.kind = 'shipping'::text THEN 'Before Wrap'::text
                        WHEN l.kind = 'customer_pickup'::text THEN 'Pickup Picture'::text
                        ELSE 'Load-out Picture'::text
                    END
                END AS what,
                CASE
                    WHEN p.stage = 'site'::text THEN 'Delivery'::text
                    WHEN l.kind = 'shipping'::text THEN 'Before wrap'::text
                    WHEN l.kind = 'customer_pickup'::text THEN 'Pickup'::text
                    ELSE 'Load-out'::text
                END AS short_what
           FROM photos p
             JOIN jobs j ON j.id = p.job_id
             LEFT JOIN sh2 s ON s.job_id = p.job_id AND s.sheet_number = p.sheet_number
             LEFT JOIN loadouts l ON l.id = p.loadout_id
        ), ph2 AS (
         SELECT ph.id,
            ph.job_id,
            ph.project_id,
            ph.job_name,
            ph.is_test,
            ph.storage_path,
            ph.sheet_number,
            ph.kind,
            ph.stage,
            ph.truck,
            ph.pallet,
            ph.note,
            ph.at,
            ph.by_name,
            ph.mistake,
            ph.department,
            ph.loadout_id,
            ph.lat,
            ph.lng,
            ph.gps_accuracy,
            ph.shot_at,
            ph.archive_batch,
            ph.file_removed_at,
            ph.bytes,
            ph.folder,
            ph.table_no,
            ph.what,
                CASE
                    WHEN ph.stage = 'bol'::text THEN NULL::text
                    WHEN ph.truck IS NOT NULL THEN 'Truck-'::text || ph.truck
                    WHEN ph.pallet IS NOT NULL THEN 'Pallet-'::text || ph.pallet
                    WHEN ph.table_no IS NOT NULL THEN (((ph.folder || '-'::text) || ph.table_no) || ' '::text) || ph.what
                    WHEN ph.kind = 'loadout'::text THEN "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(COALESCE(ph.note, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Item'::text), 60)
                    ELSE NULL::text
                END AS fixed,
                CASE
                    WHEN ph.stage = 'bol'::text THEN NULL::text
                    WHEN ph.truck IS NOT NULL THEN 'Truck-'::text || ph.truck
                    WHEN ph.pallet IS NOT NULL THEN 'Pallet-'::text || ph.pallet
                    WHEN ph.table_no IS NOT NULL THEN (ph.table_no || ' '::text) || ph.short_what
                    WHEN ph.kind = 'loadout'::text THEN "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(COALESCE(ph.note, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Item'::text), 30)
                    ELSE NULL::text
                END AS fixed_new,
            row_number() OVER (PARTITION BY ph.job_id, ph.folder, ph.what, (ph.kind <> 'loadout'::text) ORDER BY ph.at, ph.id) AS counted
           FROM ph
        ), ph3 AS (
         SELECT ph2.id,
            ph2.job_id,
            ph2.project_id,
            ph2.job_name,
            ph2.is_test,
            ph2.storage_path,
            ph2.sheet_number,
            ph2.kind,
            ph2.stage,
            ph2.truck,
            ph2.pallet,
            ph2.note,
            ph2.at,
            ph2.by_name,
            ph2.mistake,
            ph2.department,
            ph2.loadout_id,
            ph2.lat,
            ph2.lng,
            ph2.gps_accuracy,
            ph2.shot_at,
            ph2.archive_batch,
            ph2.file_removed_at,
            ph2.bytes,
            ph2.folder,
            ph2.table_no,
            ph2.what,
            ph2.fixed,
            ph2.fixed_new,
            ph2.counted,
                CASE
                    WHEN ph2.stage = 'bol'::text THEN 'BOL-'::text || ph2.counted
                    ELSE COALESCE(ph2.fixed, (((ph2.folder || ' '::text) || ph2.what) || ' '::text) || ph2.counted)
                END AS base,
                CASE
                    WHEN ph2.stage = 'bol'::text THEN 'BOL-'::text || ph2.counted
                    ELSE COALESCE(ph2.fixed_new, (ph2.what || ' '::text) || ph2.counted)
                END AS base_new
           FROM ph2
        ), ph4 AS (
         SELECT ph3.id,
            ph3.job_id,
            ph3.project_id,
            ph3.job_name,
            ph3.is_test,
            ph3.storage_path,
            ph3.sheet_number,
            ph3.kind,
            ph3.stage,
            ph3.truck,
            ph3.pallet,
            ph3.note,
            ph3.at,
            ph3.by_name,
            ph3.mistake,
            ph3.department,
            ph3.loadout_id,
            ph3.lat,
            ph3.lng,
            ph3.gps_accuracy,
            ph3.shot_at,
            ph3.archive_batch,
            ph3.file_removed_at,
            ph3.bytes,
            ph3.folder,
            ph3.table_no,
            ph3.what,
            ph3.fixed,
            ph3.counted,
            ph3.base,
            ph3.base_new,
            row_number() OVER (PARTITION BY ph3.job_id, ph3.folder, ph3.base ORDER BY ph3.at, ph3.id) AS dup,
            row_number() OVER (PARTITION BY ph3.job_id, ph3.folder, ph3.base_new ORDER BY ph3.at, ph3.id) AS dup_new
           FROM ph3
        ), trips0 AS (
         SELECT l.id AS loadout_id,
            l.job_id,
                CASE
                    WHEN l.kind = 'dock'::text THEN 'Dock to dock '::text
                    WHEN l.kind in ('delivery', 'dock') THEN 'Delivery '::text
                    ELSE 'Pickup '::text
                END AS label,
                CASE
                    WHEN l.kind in ('delivery', 'dock') THEN COALESCE(l.scheduled_for, l.started_at)
                    ELSE COALESCE(l.completed_at, l.ready_at, l.started_at)
                END AS day_at
           FROM loadouts l
        ), trips AS (
         SELECT t.loadout_id,
            t.job_id,
            t.label || to_char((t.day_at AT TIME ZONE 'America/Indiana/Indianapolis'::text), 'YYYY-MM-DD'::text) AS day,
            row_number() OVER (PARTITION BY t.job_id, t.label, ((t.day_at AT TIME ZONE 'America/Indiana/Indianapolis'::text)::date) ORDER BY t.day_at, t.loadout_id) AS n
           FROM trips0 t
        ), docs AS (
         SELECT d.id,
            d.job_id,
            j.project_id,
            j.name AS job_name,
            d.is_test,
            d.storage_path,
            d.kind,
            d.added_at AS at,
            d.added_by_name AS by_name,
            d.loadout_id,
            d.archive_batch,
            d.file_removed_at,
            d.bytes,
            d.file_name,
            t.day ||
                CASE
                    WHEN t.n > 1 THEN (' ('::text || t.n) || ')'::text
                    ELSE ''::text
                END AS folder,
            lower(COALESCE("substring"(d.storage_path, '\.([a-z]+)$'::text), 'pdf'::text)) AS ext,
                CASE d.kind
                    WHEN 'ticket'::text THEN 'Delivery ticket'::text ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (replaced)'::text
                        ELSE ''::text
                    END
                    WHEN 'signature'::text THEN 'Signature'::text
                    ELSE "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(regexp_replace(d.file_name, '\.[A-Za-z0-9]{1,5}$'::text, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Site file'::text), 80) ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (taken off)'::text
                        ELSE ''::text
                    END
                END AS base,
                CASE d.kind
                    WHEN 'ticket'::text THEN 'Ticket'::text ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (replaced)'::text
                        ELSE ''::text
                    END
                    WHEN 'signature'::text THEN 'Signature'::text
                    ELSE "left"(COALESCE(NULLIF(TRIM(BOTH FROM regexp_replace(regexp_replace(d.file_name, '\.[A-Za-z0-9]{1,5}$'::text, ''::text), '[\\/:*?"<>|]+'::text, '-'::text, 'g'::text)), ''::text), 'Site file'::text), 40) ||
                    CASE
                        WHEN d.retired_at IS NOT NULL THEN ' (taken off)'::text
                        ELSE ''::text
                    END
                END AS base_new
           FROM delivery_docs d
             JOIN jobs j ON j.id = d.job_id
             JOIN trips t ON t.loadout_id = d.loadout_id
        ), docs2 AS (
         SELECT docs.id,
            docs.job_id,
            docs.project_id,
            docs.job_name,
            docs.is_test,
            docs.storage_path,
            docs.kind,
            docs.at,
            docs.by_name,
            docs.loadout_id,
            docs.archive_batch,
            docs.file_removed_at,
            docs.bytes,
            docs.file_name,
            docs.folder,
            docs.ext,
            docs.base,
            docs.base_new,
            row_number() OVER (PARTITION BY docs.job_id, docs.folder, docs.base, docs.ext ORDER BY docs.at, docs.id) AS dup,
            row_number() OVER (PARTITION BY docs.job_id, docs.folder, docs.base_new, docs.ext ORDER BY docs.at, docs.id) AS dup_new
           FROM docs
        )
 SELECT 'photo'::text AS source,
    p.id,
    p.job_id,
    p.project_id,
    p.job_name,
    p.is_test,
    'photos'::text AS bucket,
    p.storage_path,
    p.folder,
    ((p.base_new ||
        CASE
            WHEN p.dup_new > 1 THEN (' ('::text || p.dup_new) || ')'::text
            ELSE ''::text
        END) ||
        CASE
            WHEN p.mistake THEN ' (entered by mistake)'::text
            ELSE ''::text
        END) || '.jpg'::text AS file_name,
    p.sheet_number,
    p.table_no,
    p.kind,
    p.what,
    p.note,
    p.at,
    p.by_name,
    p.mistake,
    p.department,
    p.lat,
    p.lng,
    p.gps_accuracy,
    p.shot_at,
    p.loadout_id,
    p.archive_batch,
    p.file_removed_at IS NULL AS in_cloud,
    p.bytes,
    ((p.base ||
        CASE
            WHEN p.dup > 1 THEN (' ('::text || p.dup) || ')'::text
            ELSE ''::text
        END) ||
        CASE
            WHEN p.mistake THEN ' (entered by mistake)'::text
            ELSE ''::text
        END) || '.jpg'::text AS old_file_name
   FROM ph4 p
UNION ALL
 SELECT 'doc'::text AS source,
    d.id,
    d.job_id,
    d.project_id,
    d.job_name,
    d.is_test,
    'deliveries'::text AS bucket,
    d.storage_path,
    d.folder,
    ((d.base_new ||
        CASE
            WHEN d.dup_new > 1 THEN (' ('::text || d.dup_new) || ')'::text
            ELSE ''::text
        END) || '.'::text) || d.ext AS file_name,
    NULL::integer AS sheet_number,
    NULL::integer AS table_no,
    d.kind,
        CASE d.kind
            WHEN 'ticket'::text THEN 'Delivery ticket'::text
            WHEN 'signature'::text THEN 'Customer signature'::text
            ELSE 'Site file'::text
        END AS what,
        CASE
            WHEN d.kind = 'site_file'::text THEN d.file_name
            ELSE NULL::text
        END AS note,
    d.at,
    d.by_name,
    false AS mistake,
    'delivery'::text AS department,
    NULL::double precision AS lat,
    NULL::double precision AS lng,
    NULL::double precision AS gps_accuracy,
    NULL::timestamp with time zone AS shot_at,
    d.loadout_id,
    d.archive_batch,
    d.file_removed_at IS NULL AS in_cloud,
    d.bytes,
    ((d.base ||
        CASE
            WHEN d.dup > 1 THEN (' ('::text || d.dup) || ')'::text
            ELSE ''::text
        END) || '.'::text) || d.ext AS old_file_name
   FROM docs2 d
UNION ALL
 SELECT 'signed'::text AS source,
    l.id,
    l.job_id,
    j.project_id,
    j.name AS job_name,
    l.is_test,
    NULL::text AS bucket,
    NULL::text AS storage_path,
    t.day ||
        CASE
            WHEN t.n > 1 THEN (' ('::text || t.n) || ')'::text
            ELSE ''::text
        END AS folder,
    'Signed ticket.pdf'::text AS file_name,
    NULL::integer AS sheet_number,
    NULL::integer AS table_no,
    'signed_ticket'::text AS kind,
        CASE
            WHEN l.signed_name IS NOT NULL THEN 'Signed by '::text || l.signed_name
            ELSE 'Not signed: '::text || COALESCE(l.no_sign_reason, ''::text)
        END AS what,
    l.customer_note AS note,
    l.completed_at AS at,
    l.completed_by_name AS by_name,
    false AS mistake,
    'delivery'::text AS department,
    l.complete_lat AS lat,
    l.complete_lng AS lng,
    l.complete_accuracy AS gps_accuracy,
    l.signed_at AS shot_at,
    l.id AS loadout_id,
    ( SELECT min(d.archive_batch) AS min
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.archive_batch IS NOT NULL) AS archive_batch,
    NOT (EXISTS ( SELECT 1
           FROM delivery_docs d
          WHERE d.loadout_id = l.id AND d.file_removed_at IS NOT NULL)) AS in_cloud,
    NULL::bigint AS bytes,
    'Signed ticket.pdf'::text AS old_file_name
   FROM loadouts l
     JOIN jobs j ON j.id = l.job_id
     JOIN trips t ON t.loadout_id = l.id
  WHERE l.completed_at IS NOT NULL AND l.voided_at IS NULL AND l.kind <> 'shipping'::text;

-- check_deliveries() as in trip_types.sql, expecting the short names (step 15) and the archive's (step 16)
CREATE OR REPLACE FUNCTION public.check_deliveries()
 RETURNS TABLE(step integer, check_name text, result text, if_it_failed text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  tst      uuid;  sup uuid;  mgr uuid;
  as_tst   text;  as_sup text;  as_mgr text;
  v_real   uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v        jsonb;
  d1       uuid := gen_random_uuid();     -- the page's own ids
  d2       uuid := gen_random_uuid();
  d3       uuid := gen_random_uuid();
  d_real   uuid := gen_random_uuid();
  f        uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  ph       uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sig      uuid := gen_random_uuid();
  sig2     uuid := gen_random_uuid();
  l1       uuid;  l_id uuid;
  n        int;
  ok       boolean;
  msg      text;
  r        record;
  b        storage.buckets;
  v_batch  text;
  v_day    text;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments))
     and not schedules_deliveries order by ('sanding' = any(departments)) desc limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if tst is null or sup is null or mgr is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery), a supervisor from another department and a manager have logins', false,
      concat_ws(' ', case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when sup is null then 'No real supervisor outside Delivery.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin
    -- the Test Supervisor plays the driver here, so not a scheduler, even if it was made one for practice (undone at the end)
    update profiles set schedules_deliveries = false where id = tst;
    -- ---- 1. the parts exist ------------------------------------------------
    select * into b from storage.buckets where id = 'deliveries';
    ok := b.id is not null and not coalesce(b.public, true) and b.file_size_limit = 10485760
          and b.allowed_mime_types @> array['application/pdf', 'image/jpeg', 'image/png'] and cardinality(b.allowed_mime_types) = 3
          and exists (select 1 from pg_tables where tablename = 'delivery_docs' and rowsecurity)
          and (to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid)') is not null
               or to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid,text)') is not null)   -- trip_types.sql adds p_kind
          and to_regprocedure('public.complete_delivery(uuid,uuid,text,text,text,text,timestamp with time zone,double precision,double precision,double precision)') is not null
          and to_regclass('public.v_deliveries') is not null and to_regclass('public.v_filing') is not null
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'site_here');
    res := res || check_row(1, 'Deliveries are set up (the private deliveries bucket, the files table, the functions and views)', ok,
      case when b.id is null then 'There''s no deliveries bucket. Run deliveries.sql again.'
           when b.public then 'The deliveries bucket is PUBLIC — anyone could read the tickets. Run deliveries.sql again, which makes it private.'
           else 'Something is missing. Run deliveries.sql again from the top.' end);

    -- a throwaway job: sheets 1 and 2 are the same item (DC-1, 1 table and 2 tables), sheet 3 has no item code; and a test copy
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999993, 'DELCHECK', 'Delivery check - undone automatically', true, 'In Production', local_today() + 3)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 1, 'DC-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 2, 'DC-1', 'Round', '36"', '36"', '42"'),
             (v_wo, 3, 1, null, 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required) select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('DELCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;

    -- ---- 2. who can schedule --------------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_real, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'A supervisor scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'Delivery (without the scheduling permission) scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      -- the permission Julia gets
      update profiles set schedules_deliveries = true where id = sup;
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_real, now() + interval '2 days', 'Back door, ask for Pat', null, d_real);
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'The scheduler (a real login) scheduled a test job.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = sup;
      ok := ok and exists (select 1 from loadouts where client_id = d_real and scheduled_for is not null and kind = 'delivery' and schedule_note = 'Back door, ask for Pat');
      msg := coalesce(msg, 'A login with the scheduling permission couldn''t schedule a real job.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Only the delivery manager (and managers) schedule; nobody else, and never across lanes', ok, msg);

    -- ---- 3. a manager schedules the test copy; Delivery sees it -------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_test, now() + interval '1 day', 'Loading dock on the north side', null, d1);
      v := schedule_delivery(v_test, now() + interval '1 day', 'resent', null, d1);            -- a resend: once
      v := schedule_delivery(v_test, now() + interval '5 days', null, null, d2);               -- a second trip
      execute 'reset role';
      select id into l1 from loadouts where client_id = d1;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      select count(*) into n from v_loadouts where client_id in (d1, d2) and is_open and scheduled_for is not null and site_steps;
      select n + count(*) into n from v_deliveries where client_id = d1 and schedule_note = 'Loading dock on the north side' and not is_done;
      execute 'reset role';
      ok := n = 3 and (select count(*) from loadouts where client_id = d1) = 1;
      msg := format('Delivery should see both scheduled trips and the note; saw %s of 3.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A scheduled delivery, with its date, time and note, shows on Delivery''s phone', ok, msg);

    -- ---- 4. the ticket ---------------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := add_delivery_doc(f[1], d1, 'ticket', 'ticket.pdf'); ok := false; msg := 'A ticket was recorded before its file arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[1] || '.pdf', '{"size": 40000, "mimetype": "application/pdf"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[2] || '.pdf', '{"size": 41000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[1], d1, 'ticket', 'Ticket 4471.pdf');
      v := add_delivery_doc(f[2], d1, 'ticket', 'Ticket 4471 revised.pdf');
      execute 'reset role';
      ok := ok and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'ticket') = 2
               and exists (select 1 from delivery_docs where client_id = f[1] and retired_at is not null)
               and (select ticket->>'name' from v_deliveries where id = l1) = 'Ticket 4471 revised.pdf';
      msg := coalesce(msg, 'The newer ticket didn''t replace the old one, or the old one wasn''t kept.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The ticket is recorded once its file arrives; a new ticket replaces the old (kept)', ok, msg);

    -- ---- 5. site files ---------------------------------------------------------
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[3] || '.jpg', '{"size": 300000, "mimetype": "image/jpeg"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[4] || '.pdf', '{"size": 90000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[3], d1, 'site_file', 'Where the tables go.jpg');
      v := add_delivery_doc(f[4], d1, 'site_file', 'Site map.pdf');
      v := retire_delivery_doc((select id from delivery_docs where client_id = f[4]));
      execute 'reset role';
      ok := (select jsonb_array_length(files) from v_deliveries where id = l1) = 1
            and exists (select 1 from delivery_docs where client_id = f[4] and retired_at is not null);
      msg := 'The site files didn''t show as added, or a file taken off vanished instead of being kept.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Site files are added, and taking one off keeps it in history', ok, msg);

    -- the photo files, as the phone uploads them first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 2, "mimetype": "image/jpeg"}' from unnest(ph) x;

    -- ---- 6. the truck at the dock ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[1], d1, 'dock', null, null, 1, 39.77, -86.16, 12, now());
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[2], d1, 'dock', null, null, 0); ok := false; msg := 'Truck 0 was accepted.';
      exception when others then null; end;
      v := start_loadout(v_test, d3);
      v := set_loadout_details(d3, 'shipping', null, null);
      begin v := add_delivery_photo(ph[2], d3, 'dock', null, null, 1); ok := false; msg := 'A truck photo was accepted on a shipment.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from v_loadouts where client_id = d1 and trucks_here = array[1] and other_items = 0)
               and exists (select 1 from photos where client_id = ph[1] and stage = 'dock' and truck = 1 and note = 'Truck 1');
      msg := coalesce(msg, 'The truck photo wasn''t recorded as truck 1 (or it counted as an "other item").');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'At the dock, a delivery records one photo per truck (never on a shipment)', ok, msg);

    -- ---- 7. the tables at the site, with the phone's time and place -------------------
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[2], d1, 'site', 2, 1, null, 39.7684, -86.1581, 8, now() - interval '2 minutes');
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[3], d1, 'site', 2, 3); ok := false; msg := 'Table 3 was accepted on a sheet with 2 tables.';
      exception when others then null; end;
      begin v := add_delivery_photo(ph[3], d1, 'site', null, 1); ok := false; msg := 'A site photo with no sheet was accepted.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from photos where client_id = ph[2] and stage = 'site' and sheet_number = 2 and piece = 1
                                                   and lat = 39.7684 and lng = -86.1581 and gps_accuracy = 8 and shot_at is not null)
               and exists (select 1 from v_loadouts where client_id = d1 and site_here = array['2:1'] and not ('2:1' = any(pieces_here)))
               and not exists (select 1 from photos where client_id = ph[3]);
      msg := coalesce(msg, 'The site photo wasn''t saved with its table, time and location, or it counted as a dock photo.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'At the site, each table''s photo keeps its table, the phone''s time and GPS', ok, msg);

    -- ---- 8. signed ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := complete_delivery(sig, d1, '   '); ok := false; msg := 'A signature with no name was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig, d1, 'Pat Jones'); ok := false; msg := 'A signature was accepted before its image arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata)
        values ('deliveries', v_tpid || '/' || d1 || '/' || sig || '.png', '{"size": 9000, "mimetype": "image/png"}');
      v := complete_delivery(sig, d1, 'Pat Jones', 'Table by the window has a scuff', null, null, now() - interval '1 minute', 39.7684, -86.1581, 6);
      v := complete_delivery(sig, d1, 'Pat Jones');                                  -- a resend: once
      execute 'reset role';
      select * into r from loadouts where client_id = d1;
      ok := ok and r.completed_at is not null and r.finished_at is not null and r.signed_name = 'Pat Jones' and r.signed_at is not null
               and r.customer_note = 'Table by the window has a scuff' and r.no_sign_reason is null and r.complete_lat = 39.7684
               and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'signature') = 1
               and (select signature_path from v_deliveries where id = l1) = v_tpid || '/' || d1 || '/' || sig || '.png';
      msg := coalesce(msg, 'The signed delivery wasn''t recorded with its name, note, signature and place (or was recorded twice).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Signed: the name, the customer''s note and the signature are kept; a resend counts once', ok, msg);

    -- ---- 9. once delivered, it stays as signed -------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(gen_random_uuid(), d1, null, null, 'Nobody on site'); ok := false; msg := 'A delivered delivery was marked delivered again, differently.';
      exception when others then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/' || d1 || '/' || f[5] || '.pdf', '{"size": 1, "mimetype": "application/pdf"}');
      begin v := add_delivery_doc(f[5], d1, 'ticket', 'late.pdf'); ok := false; msg := 'The ticket was changed after the customer signed.';
      exception when others then null; end;
      begin v := schedule_delivery(null, now(), null, d1); ok := false; msg := 'A delivered delivery was moved to another date.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Once delivered, the ticket, the date and the signature can''t change', ok, msg);

    -- ---- 10. not signed --------------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(sig2, d2, null, null, 'Too busy'); ok := false; msg := 'A reason not on the list was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig2, d2, null, null, 'Other', '  '); ok := false; msg := '"Other" was accepted with no note.';
      exception when others then null; end;
      v := complete_delivery(sig2, d2, 'nobody', null, 'Nobody on site', 'Left inside the gym, door code from Pat');
      execute 'reset role';
      select * into r from loadouts where client_id = d2;
      ok := ok and r.completed_at is not null and r.no_sign_reason = 'Nobody on site' and r.signed_name is null
               and r.no_sign_note = 'Left inside the gym, door code from Pat'
               and not exists (select 1 from delivery_docs where loadout_id = r.id and kind = 'signature');
      msg := coalesce(msg, 'The unsigned delivery wasn''t recorded with its reason and note.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Not signed: a reason from the list (and a note for Other) is needed, and kept', ok, msg);

    -- ---- 11. Julia's "New" --------------------------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := mark_ticket_downloaded(d1); ok := false; msg := 'Delivery (not the scheduler) marked a ticket downloaded.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      select downloaded_at into r from loadouts where client_id = d1;
      update loadouts set downloaded_at = downloaded_at - interval '1 hour' where client_id = d1;
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      ok := ok and (select downloaded_at < now() - interval '59 minutes' and downloaded_by_name is not null from loadouts where client_id = d1);
      msg := coalesce(msg, 'Downloading didn''t record the first download (or a later one overwrote it).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Downloading a signed ticket is recorded once, by the scheduler or a manager', ok, msg);

    -- ---- 12. who sees delivery files ------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      select (select count(*) from v_deliveries where is_test) + (select count(*) from v_loadouts where job_id = v_test)
           + (select count(*) from delivery_docs) + (select count(*) from storage.objects where bucket_id = 'deliveries') into n;
      execute 'reset role';
      ok := n = 0;
      msg := format('A supervisor outside Delivery can see %s test deliveries or delivery files.', n);
      if ok then
        perform set_config('request.jwt.claims', as_tst, true);
        execute 'set local role authenticated';
        select count(*) into n from delivery_docs where loadout_id = l1;
        select n + count(*) into n from storage.objects where bucket_id = 'deliveries' and name like v_tpid || '/%';
        select n * 100 + count(*) into n from v_deliveries where client_id = d_real;
        execute 'reset role';
        ok := n >= 500 and n % 100 = 0;
        msg := 'Delivery can''t read the test delivery''s files, or can see a real one from the test lane.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Delivery files are for Delivery, the scheduler and managers, lane by lane', ok, msg);

    -- ---- 13. no writing around the functions -------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path) values (gen_random_uuid(), l1, v_test, 'ticket', 'x', 'x');
        ok := false; msg := 'A login wrote to delivery_docs directly.';
      exception when insufficient_privilege then null; end;
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/anything.exe', '{}');
        ok := false; msg := 'A file with the wrong name went into the deliveries bucket.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', 'DELCHECK/' || d_real || '/' || gen_random_uuid() || '.png', '{}');
        ok := false; msg := 'A supervisor outside Delivery uploaded a delivery file.';
      exception when insufficient_privilege then null; end;
      begin v := complete_delivery(gen_random_uuid(), d_real, null, null, 'Other', 'x'); ok := false; msg := 'A supervisor outside Delivery marked a delivery done.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Nobody writes delivery files or marks a delivery done around the checks', ok, msg);

    -- ---- 14. no login ----------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      ok := true; msg := null;
      begin select count(*) into n from delivery_docs; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from v_deliveries; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from storage.objects where bucket_id = 'deliveries'; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin v := schedule_delivery(v_real, now(), null); ok := false; exception when others then null; end;
      execute 'reset role';
      msg := 'Deliveries or their files are visible, or can be scheduled, without logging in. Do not go further.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Someone with no login sees no deliveries or delivery files', ok, msg);

    -- ---- 15. filed the way the shop files ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := log_defect(v_test, 'delivery', (select id from defect_types where department = 'delivery' and active order by sort_order limit 1), 2, 'check', gen_random_uuid());
      v := add_photo(ph[4], 'defect', (v->>'id')::uuid);
      execute 'reset role';
      v_day := 'Delivery ' || to_char((select scheduled_for from loadouts where client_id = d1) at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD');
      select count(*) into n from v_filing where job_id = v_test and (
             (source = 'photo' and folder = 'DC-1' and file_name = '2 Delivery.jpg' and old_file_name = 'DC-1-2 Delivery Picture.jpg' and id = (select id from photos where client_id = ph[2]))
          or (source = 'photo' and folder = 'Truck' and file_name = 'Truck-1.jpg')
          or (source = 'photo' and folder = 'DC-1' and file_name = 'Defect 1.jpg' and old_file_name = 'DC-1 Defect 1.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Ticket.pdf' and old_file_name = 'Delivery ticket.pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Ticket (replaced).pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Where the tables go.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Signature.png')
          or (source = 'signed' and folder = v_day and file_name = 'Signed ticket.pdf'));
      ok := n = 8;
      msg := format('Expected 8 files named the short way, each with its old name too (DC-1/2 Delivery.jpg, Truck/Truck-1.jpg, Ticket.pdf, the signature …); found %s.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'Photos and files are named by item and table without repeating the folder: DC-1/2 Delivery.jpg', ok, msg);

    -- ---- 16. the archive takes delivery files too ---------------------------------------
    perform set_config('request.jwt.claims', '', true);
    update jobs set is_active = false, phase = '100% Complete' where id = v_test;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_test;
    update photos set taken_at = now() - interval '61 days' where job_id = v_test;
    update delivery_docs set added_at = now() - interval '61 days' where job_id = v_test;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := prepare_photo_archive();
      v_batch := v->>'batch';
      v := file_archive_batch(v_batch);
      execute 'reset role';
      ok := (select count(*) from delivery_docs where job_id = v_test and archive_batch = v_batch) = 5
            and exists (select 1 from delivery_docs where client_id = f[2] and archive_name = v_tpid || '/' || v_day || '/Ticket.pdf')
            and exists (select 1 from photos where client_id = ph[2] and archive_name = v_tpid || '/DC-1/2 Delivery.jpg')
            and exists (select 1 from jsonb_array_elements(v->'files') x where x->>'source' = 'signed' and x->>'name' = v_tpid || '/' || v_day || '/Signed ticket.pdf')
            and not delivery_doc_released(v_tpid || '/' || d1 || '/' || f[2] || '.pdf');
      msg := 'The archive didn''t take the delivery files, named them wrongly, or would let them be removed before the next batch is saved.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(16, 'The monthly archive takes delivery files too, filed the same way', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_deliveries_undo__';
  exception when others then
    if sqlerrm <> '__check_deliveries_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$function$;
revoke all on function check_deliveries() from public, anon, authenticated;

-- check_delivery_types() as in delivery_types.sql, expecting the short names of a pickup's photos (step 10)
create or replace function check_delivery_types()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  tst     uuid;  sup uuid;  mgr uuid;  drv uuid;
  as_tst  text;  as_sup text;  as_mgr text;  as_drv text;
  v_real  uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v       jsonb;
  b1      uuid := gen_random_uuid();     -- the page's own ids: a BOL pickup, a customer pickup, a white glove, one started on the phone
  c1      uuid := gen_random_uuid();
  w1      uuid := gen_random_uuid();
  p1      uuid := gen_random_uuid();
  r1      uuid := gen_random_uuid();     -- a pickup to cancel (and the lane test)
  r2      uuid := gen_random_uuid();     -- real-job pickups: the office records one, a supervisor is refused another
  r3      uuid := gen_random_uuid();
  ph      uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sig     uuid := gen_random_uuid();
  ok      boolean;
  msg     text;
  n       int;
  t       text;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments))
     and not schedules_deliveries order by ('sanding' = any(departments)) desc limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if tst is null or sup is null or mgr is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery), a supervisor from another department and a manager have logins', false,
      concat_ws(' ', case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when sup is null then 'No real supervisor outside Delivery.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin
    -- ---- 1. the parts exist ----------------------------------------------------
    ok := to_regprocedure('public.schedule_pickup(uuid,text,text,uuid,uuid)') is not null
          and to_regprocedure('public.add_bol_photo(uuid,uuid,timestamp with time zone,integer,integer)') is not null
          and to_regprocedure('public.complete_pickup(uuid,uuid,text,text,text,text,timestamp with time zone)') is not null
          and exists (select 1 from information_schema.columns where table_name = 'v_deliveries' and column_name = 'bol_photos')
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'bol_here')
          and exists (select 1 from information_schema.columns where table_name = 'v_cancelled_deliveries' and column_name = 'ready_at')
          and pg_get_constraintdef((select oid from pg_constraint where conname = 'loadouts_kind_check')) like '%customer_pickup%'
          and pg_get_constraintdef((select oid from pg_constraint where conname = 'photos_stage_check')) like '%bol%';
    res := res || check_row(1, 'Delivery types are set up (the new kind, the functions, the columns the pages read)', ok,
      'Something is missing. Run delivery_types.sql again from the top.');

    -- a throwaway real job (3 tables on 2 sheets) and its test copy. The Test Supervisor plays the one handing over;
    -- a manager plays Julia (so the Test Supervisor isn't a scheduler, even if it was made one for practice: undone at the end)
    update profiles set schedules_deliveries = false where id = tst;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999992, 'PICKCHECK', 'Pickup check - undone automatically', true, 'In Production', local_today() + 3)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 2, 'PK-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 1, 'PK-2', 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required) select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('PICKCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 2, "mimetype": "image/jpeg"}' from unnest(ph) x;

    -- ---- 2. Julia's page: two pickups with no date ----------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_test, 'shipping', 'Estes, sometime this week', null, b1);
      v := schedule_pickup(v_test, 'shipping', 'resent', null, b1);                          -- a resend: once
      v := schedule_pickup(v_test, 'customer_pickup', null, null, c1);
      v := schedule_delivery(v_test, now() + interval '2 days', null, null, w1);
      select count(*) into n from v_deliveries
       where (client_id = b1 and kind = 'shipping' and scheduled_for is null and ready_at is not null and schedule_note = 'Estes, sometime this week')
          or (client_id = c1 and kind = 'customer_pickup' and scheduled_for is null and ready_at is not null)
          or (client_id = w1 and kind = 'delivery' and scheduled_for is not null and ready_at is null);
      execute 'reset role';
      ok := n = 3 and (select count(*) from loadouts where client_id = b1) = 1;
      msg := format('Expected a BOL pickup and a customer pickup with no date, and the white glove delivery with its date; found %s of 3.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'The scheduler sets up a BOL pickup and a customer pickup with no date; white glove keeps its date', ok, msg);

    -- ---- 3. only a scheduler sets one up, never across lanes ---------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_real, 'shipping', null, null, gen_random_uuid()); ok := false; msg := 'A supervisor from another department set up a pickup.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_test, 'customer_pickup', null, null, gen_random_uuid()); ok := false; msg := 'Delivery (without the scheduling permission) set up a pickup.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_pickup(v_real, 'shipping', null, null, r1); ok := false; msg := 'A test login set up a pickup on a real job.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = tst;
      ok := ok and not exists (select 1 from loadouts where client_id = r1);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Only the delivery manager (and managers) set up pickups; nobody else, and never across lanes', ok, msg);

    -- ---- 4. a pickup has no date, and keeps its kind --------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_test, now() + interval '1 day', null, b1, null); ok := false; msg := 'A pickup was given a date.';
      exception when others then if sqlerrm not like '%no date%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := set_loadout_details(c1, 'delivery', null, null); ok := false; msg := 'The phone changed a customer pickup into a delivery.';
      exception when insufficient_privilege then null; end;
      v := set_loadout_details(b1, null, 'Estes', 'BOL 44812');                              -- carrier and BOL number: allowed
      execute 'reset role';
      ok := ok and (select kind = 'customer_pickup' from loadouts where client_id = c1)
               and (select carrier = 'Estes' and tracking = 'BOL 44812' and scheduled_for is null from loadouts where client_id = b1);
      msg := coalesce(msg, 'The carrier and BOL number weren''t saved, or a kind changed.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A pickup can''t be given a date, and the phone can''t change its kind (carrier and BOL number still save)', ok, msg);

    -- ---- 5. a BOL pickup needs its BOL photo and a wrapped pallet ---------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), b1); ok := false; msg := 'A BOL pickup was marked picked up with no BOL photo.';
      exception when others then if sqlerrm not like '%BOL first%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      v := add_bol_photo(ph[1], b1, now(), 1600, 1200);
      v := add_bol_photo(ph[1], b1, now(), 1600, 1200);                                      -- a resend: once
      begin v := complete_pickup(gen_random_uuid(), b1); ok := false; msg := 'A BOL pickup was marked picked up with no pallet photo.';
      exception when others then if sqlerrm not like '%pallet%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      v := add_loadout_photo(ph[2], b1, null, null, 1, null, 1600, 1200);                    -- pallet 1, wrapped
      v := add_loadout_photo(ph[3], b1, 1, 1, null, null, 1600, 1200);                       -- sheet 1 table 1, before wrap
      v := complete_pickup(sig, b1, null, 'Two pallets, shrink-wrapped');
      v := complete_pickup(sig, b1);                                                          -- a resend: once
      begin v := add_bol_photo(ph[4], c1, now()); ok := false; msg := 'A BOL photo was accepted on a customer pickup.';
      exception when others then null; end;
      select count(*) into n from v_deliveries where client_id = b1 and is_done and jsonb_array_length(bol_photos) = 1
         and pallets_photographed = 1 and tables_photographed = 1 and completed_by_name is not null;
      execute 'reset role';
      ok := ok and n = 1 and (select finished_at is not null and customer_note = 'Two pallets, shrink-wrapped' from loadouts where client_id = b1)
            and (select stage = 'bol' and note = 'BOL page 1' from photos where client_id = ph[1]);
      msg := coalesce(msg, 'The BOL pickup didn''t come out picked up, with one BOL photo, one pallet and one table.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A BOL pickup is done only with a BOL photo and a wrapped pallet; no signature needed', ok, msg);

    -- ---- 6. a customer pickup needs a signature, or Customer refused / Other ------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[5], c1, 2, 1, null, null, 1600, 1200);                       -- sheet 2's table, handed over
      begin v := complete_pickup(gen_random_uuid(), c1, 'Pat Jones'); ok := false; msg := 'A customer pickup was signed before the signature arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      begin v := complete_pickup(gen_random_uuid(), c1, null, null, 'Nobody on site'); ok := false; msg := '"Nobody on site" was accepted on a pickup.';
      exception when others then null; end;
      begin v := complete_pickup(gen_random_uuid(), c1, null, null, 'Other', ' '); ok := false; msg := '"Other" was accepted with no note.';
      exception when others then null; end;
      execute 'reset role';
      insert into storage.objects (bucket_id, name, metadata)
        values ('deliveries', v_tpid || '/' || c1 || '/' || ph[6] || '.png', '{"size": 900, "mimetype": "image/png"}');
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := complete_pickup(ph[6], c1, 'Pat Jones', 'Took both tables in a van', null, null, now());
      select count(*) into n from v_deliveries where client_id = c1 and is_done and signed_name = 'Pat Jones' and signature_path like '%.png' and tables_photographed = 1;
      execute 'reset role';
      -- the office records one too: a manager, on a real job (managers don't record in the test lane)
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_real, 'customer_pickup', null, null, r2);
      v := complete_pickup(gen_random_uuid(), r2, null, 'Signed the paper ticket instead', 'Other', 'Signed our paper copy');
      execute 'reset role';
      ok := ok and n = 1 and (select completed_by = mgr and no_sign_reason = 'Other' from loadouts where client_id = r2);
      msg := coalesce(msg, 'The customer pickup didn''t come out signed by Pat Jones with its signature and table photo, or the office couldn''t record one.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A customer pickup is signed (or Customer refused / Other with a note); the office can record one too', ok, msg);

    -- ---- 7. nobody outside Delivery and the office records one -------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_real, 'shipping', null, null, r3);
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), r3); ok := false; msg := 'Someone outside Delivery recorded a pickup.';
      exception when insufficient_privilege then null; end;
      begin v := add_bol_photo(gen_random_uuid(), r3, now()); ok := false; msg := 'Someone outside Delivery added a BOL photo.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := complete_pickup(gen_random_uuid(), w1, null, null, 'Customer refused'); ok := false; msg := 'A white glove delivery was marked picked up.';
      exception when others then if sqlerrm not like '%white glove%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      begin v := complete_delivery(gen_random_uuid(), c1, null, null, 'Nobody on site'); ok := false; msg := 'A customer pickup was marked delivered.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and (select completed_at is null from loadouts where client_id = w1) and (select completed_at is null from loadouts where client_id = r3);
      msg := coalesce(msg, 'Something was recorded that shouldn''t have been.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Only Delivery and the office record a pickup; a delivery and a pickup can''t be finished the other''s way', ok, msg);

    -- ---- 8. started on the phone: the same steps, and it reaches Julia's Completed -------
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := start_loadout(v_test, p1);
      v := set_loadout_details(p1, 'customer_pickup', null, null);
      select count(*) into n from v_loadouts where client_id = p1 and kind = 'customer_pickup' and pickup_steps and ready_at is null;
      v := complete_pickup(gen_random_uuid(), p1, null, 'Picked up at the back door', 'Customer refused', null);
      select n * 10 + count(*) into n from v_deliveries where client_id = p1 and is_done and no_sign_reason = 'Customer refused';
      execute 'reset role';
      ok := n = 11;
      msg := format('A customer pickup started on the phone should have the new steps and reach Completed (expected 1 and 1, got %s and %s).', n / 10, n % 10);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A pickup started on the phone gets the same steps and shows on the Deliveries page once done', ok, msg);

    -- ---- 9. cancel and put back ----------------------------------------------------------
    ok := true; msg := null;
    begin
      -- the Test Supervisor sets it up (so it's "started by" them), then stops being a scheduler:
      -- "started by mistake" on the phone must still be refused
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := schedule_pickup(v_test, 'shipping', null, null, r1);
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin perform void_loadout(r1, null); ok := false; msg := 'The phone cancelled a pickup the scheduler set up.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      perform void_loadout(r1, 'Delivery cancelled');
      select count(*) into n from v_cancelled_deliveries where client_id = r1 and kind = 'shipping' and ready_at is not null;
      v := restore_delivery(r1);
      select n * 10 + count(*) into n from v_deliveries where client_id = r1;
      begin perform void_loadout(b1, 'Delivery cancelled'); ok := false; msg := 'A pickup already picked up was cancelled.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and n = 11;
      msg := coalesce(msg, format('Cancel should put it under Cancelled, and put back on the list (expected 1 and 1, got %s and %s).', n / 10, n % 10));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'A pickup is cancelled and put back like a delivery; once picked up it can''t be cancelled', ok, msg);

    -- ---- 10. filing ----------------------------------------------------------------------
    begin
      select string_agg(folder || '/' || file_name, ' | ' order by folder, file_name) into t
        from v_filing where job_id = v_test and (loadout_id in (select id from loadouts where client_id in (b1, c1)));
      ok := t like '%BOL/BOL-1.jpg%' and t like '%Pallets/Pallet-1.jpg%' and t like '%PK-1/1 Before wrap.jpg%'
            and t like '%PK-2/1 Pickup.jpg%' and t like '%Pickup ____-__-__%/Signature.png%'
            and (select count(*) from v_filing where source = 'signed' and loadout_id = (select id from loadouts where client_id = c1)) = 1
            and (select count(*) from v_filing where source = 'signed' and loadout_id = (select id from loadouts where client_id = b1)) = 0;
      msg := 'The files weren''t named as expected. Got: ' || coalesce(t, 'nothing');
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Pickups are filed: BOL/BOL-1.jpg, "1 Pickup", a Pickup <date> folder; a customer pickup gets a signed ticket', ok, msg);

    -- ---- 11. no login can read the new parts without signing in -----------------------------
    begin
      ok := not has_function_privilege('anon', 'public.schedule_pickup(uuid,text,text,uuid,uuid)', 'execute')
            and not has_function_privilege('anon', 'public.complete_pickup(uuid,uuid,text,text,text,text,timestamp with time zone)', 'execute')
            and not has_function_privilege('anon', 'public.add_bol_photo(uuid,uuid,timestamp with time zone,integer,integer)', 'execute')
            and not has_table_privilege('anon', 'public.v_deliveries', 'select')
            and not has_table_privilege('anon', 'public.v_loadouts', 'select')
            and not has_table_privilege('anon', 'public.v_cancelled_deliveries', 'select');
      msg := 'Someone with no login could call a pickup function or read the delivery lists. Run delivery_types.sql again.';
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Nobody without a login can set up, record or read pickups', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_delivery_types_undo__';
  exception when others then
    if sqlerrm <> '__check_delivery_types_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_delivery_types() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. The zip's folders, format 3. Returns {place, rel} or raises in
--    words. rel is where it's filed: inside the job's Production › Files,
--    or the library's Database.
-- ---------------------------------------------------------------------

alter table zip_drops drop constraint if exists zip_drops_format;      -- a zip_drops row may now say format 3
alter table zip_drops add constraint zip_drops_format check (format in (1, 2, 3));

create or replace function zip_path_place(p_path text, p_format int) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  segs text[] := string_to_array(coalesce(p_path, ''), '/');
  top text := segs[1]; n int := coalesce(array_length(segs, 1), 0);
  nm text := segs[n]; ext text := lower(substring(coalesce(segs[n], '') from '\.([A-Za-z0-9]+)$'));
  fmt int := coalesce(p_format, 1);
  folders text := case when coalesce(p_format, 1) >= 2 then 'Floor, Files, Router, Bend-Tech, Design, Database' else 'Floor, Files, Router, Bend-Tech, Database' end;
  s text; rest text; rel text; place text := 'job'; lim int;
begin
  if n < 2 then raise exception '%: every file goes in one of the zip''s folders (%).', p_path, folders; end if;
  foreach s in array segs loop
    if s = '' or s ~ '[\x01-\x1f\\:*?"<>|]' or s ~ '[. ]$' or s in ('.', '..') or length(s) > 200 then
      raise exception '%: that name isn''t one Windows accepts.', p_path;
    end if;
  end loop;
  if top in ('Floor', 'Router', 'Design') or (top = 'Bend-Tech' and fmt < 3) then
    if n <> 2 then raise exception '%: % holds files only, no folders.', p_path, top; end if;
  end if;
  if top = 'Floor' then
    if ext not in ('json', 'pdf') then raise exception '%: Floor holds only the upload file and the work order PDF.', p_path; end if;
    rel := nm;
  elsif top = 'Router' then
    if ext not in ('mprx', 'mpr') then raise exception '%: Router takes .mprx or .mpr only.', p_path; end if;
    rel := 'Router/' || nm;
  elsif top = 'Bend-Tech' then
    if fmt >= 3 and n <> 3 then raise exception '%: Bend-Tech holds one folder per item, named for the item, with its files in it (Bend-Tech/TB-01/Post.step).', p_path; end if;
    if ext not in ('step', 'stp', 'dxf') then raise exception '%: Bend-Tech takes .step, .stp or .dxf only.', p_path; end if;
    rel := array_to_string(segs, '/');
  elsif top = 'Design' then
    if fmt < 2 then raise exception '%: Design is new in format 2, and this zip says format 1.', p_path; end if;
    if ext not in ('step', 'stp') then raise exception '%: Design takes .step or .stp only.', p_path; end if;
    rel := 'Design/' || nm;
  elsif top = 'Files' then
    if fmt >= 3 then
      if n not in (3, 4) or segs[2] not in ('Metal', 'KI', 'Arrow', 'Other') then
        raise exception '%: Files holds only the folders Metal, KI, Arrow and Other (each with its files, or one folder per item), and nothing loose.', p_path;
      end if;
      rel := array_to_string(segs[2:n], '/');
    else
      if n < 3 or segs[2] not in ('Metal drawings', 'KI', 'Arrow', 'Other') then
        raise exception '%: Files holds only the folders Metal drawings, KI, Arrow and Other, and nothing loose.', p_path;
      end if;
      rel := case when segs[2] = 'Metal drawings' then 'Metal/' || array_to_string(segs[3:n], '/') else array_to_string(segs[2:n], '/') end;
    end if;
  elsif top = 'Database' then
    rest := array_to_string(segs[2:n], '/');
    if n < 4 or not (rest like 'Metal/Cut sheets/%' or rest like 'Metal/STEP files/%' or rest like 'CNC/KI/%' or rest like 'CNC/Other/%') then
      raise exception '%: library files go in Database/Metal/Cut sheets, Metal/STEP files, CNC/KI or CNC/Other.', p_path;
    end if;
    place := 'library'; rel := rest;
  else
    raise exception '%: % isn''t one of the zip''s folders (%).', p_path, top, folders;
  end if;
  lim := case when place = 'job' then 45 else 60 end;
  if fmt >= 3 and length(rel) > lim then
    raise exception '%: too long once filed (% is % characters; % at most). The folders already say the job and the item, so the name needn''t.',
      p_path, rel, length(rel), lim;
  end if;
  return jsonb_build_object('place', place, 'rel', rel);
end $$;
revoke all on function zip_path_place(text, int) from public, anon;

-- The item folder a format-3 path is in, or null: Bend-Tech/TB-01/x → TB-01, Files/Metal/TB-01/x → TB-01
create or replace function zip_item_folder(p_path text, p_format int) returns text
language sql immutable set search_path = public as $$
  select case
    when coalesce(p_format, 1) < 3 then null
    when split_part(p_path, '/', 1) = 'Bend-Tech' and array_length(string_to_array(p_path, '/'), 1) = 3 then split_part(p_path, '/', 2)
    when split_part(p_path, '/', 1) = 'Files' and array_length(string_to_array(p_path, '/'), 1) = 4 then split_part(p_path, '/', 3)
  end
$$;
revoke all on function zip_item_folder(text, int) from public, anon;

-- The drop: format 3 read, an item's folder must be its item (zip_drop.sql's, otherwise the same)
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
  if v_fmt is null or v_fmt not in (1, 2, 3) or (p_contents ->> 'format')::numeric <> v_fmt then
    raise exception 'contents.json says format %; this office reads formats 1 to 3. If it''s newer, the office needs updating.', coalesce(p_contents ->> 'format', 'nothing');
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
    -- format 3: an item's own folder is named for its item (Bend-Tech/TB-01/Post.step)
    if zip_item_folder(v_path, v_fmt) is not null and e ? 'item'
       and zip_item_folder(v_path, v_fmt) is distinct from btrim(coalesce(e ->> 'item', '')) then
      raise exception '%: its folder (%) should be its item (%).', v_path, zip_item_folder(v_path, v_fmt), e ->> 'item';
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

-- check_zip_drop() as in zip_drop.sql, with format 4 as the format it doesn't read (format 3 is read now)
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

-- Files › Metal drawings is now Files › Metal: files parked under the old name follow (zip_path keeps where they came from)
update parked_files set rel_path = 'Metal/' || substr(rel_path, length('Metal drawings/') + 1)
 where place = 'job' and rel_path like 'Metal drawings/%';


-- ---------------------------------------------------------------------
-- 3. The check
-- ---------------------------------------------------------------------

create or replace function check_short_names()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as a lab login
declare
  res jsonb := '[]'; ok boolean; msg text; v jsonb; n int;
  lab uuid; had_lab boolean := false; as_lab text;
  cont jsonb; files jsonb;
  f45 text := 'Files/Metal/TB-01/' || repeat('x', 22) || '.pdf';      -- Metal/TB-01/ (12) + 26 = 38: fits
  f46 text := 'Files/Metal/TB-01/' || repeat('x', 30) || '.pdf';      -- 46: one too many
  pth text;
begin
  -- ---- 1. format 3's folders ------------------------------------------------
  ok := zip_path_place('Bend-Tech/TB-01/Post.step', 3) = '{"place":"job","rel":"Bend-Tech/TB-01/Post.step"}'::jsonb
    and zip_path_place('Files/Metal/TB-01/Assembly.step', 3) ->> 'rel' = 'Metal/TB-01/Assembly.step'
    and zip_path_place('Files/Metal/Cut sheet.pdf', 3) ->> 'rel' = 'Metal/Cut sheet.pdf'
    and zip_path_place('Router/00503-TJRT4-3666.mpr', 3) ->> 'rel' = 'Router/00503-TJRT4-3666.mpr'
    and zip_path_place('Database/Metal/STEP files/JESS-POST-DIN.step', 3) = '{"place":"library","rel":"Metal/STEP files/JESS-POST-DIN.step"}'::jsonb
    and zip_path_place(f45, 3) ->> 'rel' = substr(f45, 7)
    and zip_item_folder('Bend-Tech/TB-01/Post.step', 3) = 'TB-01' and zip_item_folder('Files/Metal/TB-01/x.pdf', 3) = 'TB-01'
    and zip_item_folder('Files/Metal/x.pdf', 3) is null and zip_item_folder('Bend-Tech/TB-01/Post.step', 2) is null;
  res := res || check_row(1, 'Format 3: Metal, one folder per item (Bend-Tech/TB-01/Post.step), router and library as before', ok,
    'A format 3 path isn''t placed where 11_SHOP_FLOOR_ZIP.md v3 says. Run short_names.sql again.');

  -- ---- 2. format 3's refusals ---------------------------------------------
  ok := true; msg := null;
  foreach pth in array array['Bend-Tech/Post.step', 'Files/Metal drawings/x.pdf', 'Files/Metal/TB-01/a/x.pdf', 'Files/Loose.pdf', f46] loop
    begin
      v := zip_path_place(pth, 3);
      ok := false; msg := concat_ws(', ', msg, pth);
    exception when others then null;
    end;
  end loop;
  begin v := zip_path_place(f46, 3); exception when others then ok := ok and sqlerrm like '%too long once filed%46 characters; 45 at most%'; end;
  res := res || check_row(2, 'Format 3 refuses a Bend-Tech file with no item folder, Metal drawings, a folder too deep and a path over 45 characters', ok,
    coalesce('Taken, but shouldn''t be: ' || msg, 'The too-long message doesn''t say how long. Run short_names.sql again.'));

  -- ---- 3. formats 1 and 2 still read; their Metal drawings files into Metal ----
  ok := zip_path_place('Files/Metal drawings/30x60 2 Square-Post Legs-Levelers.pdf', 2) ->> 'rel' = 'Metal/30x60 2 Square-Post Legs-Levelers.pdf'
    and zip_path_place('Files/Metal drawings/A/B.pdf', 1) ->> 'rel' = 'Metal/A/B.pdf'
    and zip_path_place('Bend-Tech/PROJ-00415_TB-01_Post_QTY2.step', 2) ->> 'rel' = 'Bend-Tech/PROJ-00415_TB-01_Post_QTY2.step'
    and zip_path_place('Files/Other/' || repeat('y', 70) || '.pdf', 2) is not null
    and not exists (select 1 from parked_files where place = 'job' and rel_path like 'Metal drawings/%');
  begin v := zip_path_place('Bend-Tech/TB-01/Post.step', 2); ok := false; exception when others then null; end;
  res := res || check_row(3, 'Formats 1 and 2 are read as before (no length limit, Bend-Tech files only), with Metal drawings filed as Metal, parked files too', ok,
    'An older zip isn''t read as it was, or a parked file still says Metal drawings. Run short_names.sql again.');

  -- ---- 4. the drop takes format 3, and an item's folder must be its item ----
  select l.user_id into lab from lab_users l join profiles p on p.id = l.user_id where p.active and not p.is_test limit 1;
  if lab is null then select id into lab from profiles where role in ('manager', 'admin') and active and not is_test limit 1; else had_lab := true; end if;
  if lab is null then
    res := res || check_row(4, 'The drop takes format 3 and checks each item folder', false, 'Set up the logins first (a manager).');
  else
    as_lab := json_build_object('sub', lab, 'role', 'authenticated')::text;
    begin
      if not had_lab then insert into lab_users (user_id) values (lab); end if;
      cont := jsonb_build_object('kind', 'shop-floor-zip', 'format', 3, 'job', 'PROJ-99972', 'made_at', '2026-11-03T14:05:00-05:00',
        'files', jsonb_build_array(
          jsonb_build_object('path', 'Bend-Tech/TB-01/Post.step', 'what', 'STEP file', 'bytes', 1000, 'machine', 'bendtech', 'item', 'TB-01', 'part', 'Post', 'revision', 1),
          jsonb_build_object('path', 'Files/Metal/TB-01/Assembly.step', 'what', 'assembly STEP, view only', 'bytes', 2000, 'item', 'TB-01'),
          jsonb_build_object('path', 'Files/Metal/Cut sheet.pdf', 'what', 'metal cut sheet (PDF)', 'bytes', 3000)));
      files := jsonb_build_array(
        jsonb_build_object('path', 'Bend-Tech/TB-01/Post.step', 'bytes', 1000, 'sha256', repeat('d', 64)),
        jsonb_build_object('path', 'Files/Metal/TB-01/Assembly.step', 'bytes', 2000, 'sha256', repeat('e', 64)),
        jsonb_build_object('path', 'Files/Metal/Cut sheet.pdf', 'bytes', 3000, 'sha256', repeat('f', 64)));
      perform set_config('request.jwt.claims', as_lab, true);
      execute 'set local role authenticated';
      v := zip_drop_new('PROJ-99972.zip', cont, files);
      begin
        perform zip_drop_new('PROJ-99972.zip', jsonb_set(cont, '{files,0,item}', '"TB-02"'), files);
        msg := 'A Bend-Tech file in TB-01''s folder was taken as item TB-02.';
      exception when others then
        msg := case when sqlerrm like '%its folder (TB-01) should be its item (TB-02)%' then null else 'Refused, but not for the folder: ' || sqlerrm end;
      end;
      execute 'reset role';
      select count(*) into n from parked_files where project_id = 'PROJ-99972'
        and rel_path in ('Bend-Tech/TB-01/Post.step', 'Metal/TB-01/Assembly.step', 'Metal/Cut sheet.pdf');
      ok := n = 3 and msg is null and (select format from zip_drops where project_id = 'PROJ-99972' limit 1) = 3;
      msg := coalesce(msg, format('Expected the 3 files parked where they''re filed; found %s.', n));
      raise exception using errcode = 'SF002', message = 'undo';
    exception
      when sqlstate 'SF002' then null;
      when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', '', true);
    res := res || check_row(4, 'The drop takes a format 3 zip, files it where 11_SHOP_FLOOR_ZIP.md v3 says, and refuses an item folder that isn''t its item', ok, msg);
  end if;

  -- ---- 5. the save's names: short, with the old name beside them ------------------
  ok := exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'v_filing' and column_name = 'old_file_name')
    and not exists (select 1 from v_filing where old_file_name is null);
  res := res || check_row(5, 'v_filing gives every file its short name and the name it had before (old_file_name), so the save renames instead of filing twice', ok,
    'v_filing has no old_file_name, or a file has none. Run short_names.sql again.');

  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_short_names() from public, anon, authenticated;

select * from check_short_names();
