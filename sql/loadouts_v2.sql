-- =====================================================================
-- Shop Floor — load-outs, version 2 (24 Sep 2026)
--
-- HOW TO USE: run photos.sql first (it's live). Then paste this whole
-- file into a NEW, empty query in the Supabase SQL Editor and click Run.
-- Safe to run more than once. The last thing it does is run
-- check_loadouts(), so the Results show 12 rows that should all say PASS.
--
-- What it adds (Delivery's load-out, on a tablet or a phone):
--   * Two kinds of load-out: a DELIVERY (white glove, our truck — what's
--     built now) and a SHIPMENT (palletized, a carrier). A shipment can
--     note the carrier and a tracking or BOL number; both optional.
--   * A photo for every table: each photo can say which table of its
--     sheet it shows (sheet 4 has 3 tables: table 1, 2 or 3), so the
--     count is in tables, not sheets.
--   * Pallet photos for a shipment: one per wrapped pallet.
--   * v_loadout_sheets: each sheet's size (width, length, height, shape)
--     and quantity, so the phone can label it "36 rnd · 42 H" instead of
--     "TB-03", and open its work order page.
--
-- What it doesn't change: every existing function stays exactly as it
-- is — start_loadout, finish_loadout, add_photo (Mike's photo button),
-- void_photo. The new photos go through add_loadout_photo(), which uses
-- add_photo underneath and then records the table or pallet. A photo
-- with no table number (from before) counts as table 1 of its sheet.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('loadouts_v2.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.add_photo(uuid,text,uuid,integer,text,integer,integer)') is null
     or to_regclass('public.loadouts') is null then
    raise exception 'Run photos.sql first. This file builds on it.';
  end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run check_floor.sql first. This file''s check uses it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. New columns
-- ---------------------------------------------------------------------

alter table loadouts add column if not exists kind     text not null default 'delivery';
alter table loadouts add column if not exists carrier  text;
alter table loadouts add column if not exists tracking text;
alter table photos   add column if not exists piece    int;     -- which table of its sheet (1 = the first)
alter table photos   add column if not exists pallet   int;     -- a shipment's pallet, photographed wrapped

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'loadouts_kind_check') then
    alter table loadouts add constraint loadouts_kind_check check (kind in ('delivery', 'shipping'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'photos_piece_check') then
    alter table photos add constraint photos_piece_check
      check (piece is null or (piece >= 1 and sheet_number is not null and kind = 'loadout'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'photos_pallet_check') then
    alter table photos add constraint photos_pallet_check
      check (pallet is null or (pallet >= 1 and sheet_number is null and piece is null and kind = 'loadout'));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. What the phone reads for each sheet: its size, quantity and page
-- ---------------------------------------------------------------------

drop view if exists v_loadout_sheets;
create view v_loadout_sheets with (security_invoker = true) as
select w.job_id, s.sheet_number, s.item_code, s.qty, s.species, s.shape,
       s.width, s.length, s.thickness, s.total_height,
       s.png_path, (s.pdf_uploaded_at is not null) as pages_ready
from work_orders w
join sheets s on s.work_order_id = w.id
join jobs j   on j.id = w.job_id
where w.is_current
  and (j.monday_item_id is not null or j.is_test)
  and j.is_test = am_test();
revoke all on v_loadout_sheets from anon;
grant select on v_loadout_sheets to authenticated;

-- ---------------------------------------------------------------------
-- 3. A load-out's kind, carrier and tracking number
--    p_loadout is its id, or the tablet's own id for it. Any of the
--    three may be left out (null) to keep what's there. Allowed while
--    it's open and for three days after it finishes (for a tracking
--    number that arrives later).
-- ---------------------------------------------------------------------

create or replace function set_loadout_details(p_loadout uuid, p_kind text default null,
                                               p_carrier text default null, p_tracking text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_job jobs; v_kind text := nullif(trim(lower(coalesce(p_kind, ''))), '');
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  v_job := floor_entry_check('delivery', v.job_id);
  if v.voided_at is not null then raise exception 'That load-out was marked entered by mistake.'; end if;
  if v.finished_at is not null and v.finished_at < now() - interval '3 days' then
    raise exception 'That load-out finished more than three days ago, so it can''t be changed.';
  end if;
  if v_kind is not null and v_kind not in ('delivery', 'shipping') then
    raise exception 'A load-out is a delivery or a shipment.';
  end if;
  if length(coalesce(p_carrier, '')) > 80 or length(coalesce(p_tracking, '')) > 80 then
    raise exception 'Keep the carrier and tracking number to 80 letters each.';
  end if;
  update loadouts set kind     = coalesce(v_kind, kind),
                      carrier  = case when p_carrier  is null then carrier  else nullif(trim(p_carrier), '')  end,
                      tracking = case when p_tracking is null then tracking else nullif(trim(p_tracking), '') end
   where id = v.id
  returning * into v;
  return jsonb_build_object('ok', true, 'summary',
    format('%s: %s%s%s.', v_job.project_id, case v.kind when 'shipping' then 'a shipment' else 'a delivery' end,
           coalesce(', ' || v.carrier, ''), coalesce(', tracking ' || v.tracking, '')));
end $$;
revoke all on function set_loadout_details(uuid, text, text, text) from public, anon;
grant execute on function set_loadout_details(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. A load-out photo of one table, or of a wrapped pallet
--    Same rules as add_photo (the file first; a resend counts once; a
--    load-out that hasn't arrived yet answers "waiting"), plus:
--    a table number must be one of its sheet's tables; a pallet photo
--    belongs to a shipment and has no sheet.
-- ---------------------------------------------------------------------

create or replace function add_loadout_photo(p_client_id uuid, p_loadout uuid, p_sheet int default null,
                                             p_piece int default null, p_pallet int default null,
                                             p_note text default null, p_width int default null, p_height int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_qty int; v_res jsonb; v_note text := nullif(trim(p_note), '');
begin
  if p_client_id is null then raise exception 'This photo has no id. Take it again.'; end if;
  if exists (select 1 from photos where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Photo already saved.',
                              'id', (select id from photos where client_id = p_client_id));
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then
    return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The load-out this photo belongs to hasn''t reached the database yet.');
  end if;
  perform floor_entry_check('delivery', v.job_id);

  if p_piece is not null and p_pallet is not null then raise exception 'A photo is of a table or of a pallet, not both.'; end if;
  if p_piece is not null then
    if p_sheet is null then raise exception 'Say which sheet this table is on.'; end if;
    select s.qty into v_qty from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
     where w.job_id = v.job_id and s.sheet_number = p_sheet;
    if v_qty is null then raise exception 'Sheet % isn''t on this job''s work order.', p_sheet; end if;
    if p_piece < 1 or p_piece > v_qty then
      raise exception 'Sheet % has % table%, so there''s no table %.', p_sheet, v_qty, case when v_qty = 1 then '' else 's' end, p_piece;
    end if;
  end if;
  if p_pallet is not null then
    if v.kind <> 'shipping' then raise exception 'Pallet photos are for shipments. This load-out is a delivery.'; end if;
    if p_sheet is not null then raise exception 'A pallet photo isn''t of one sheet.'; end if;
    if p_pallet < 1 or p_pallet > 50 then raise exception 'Pallet numbers run from 1 to 50.'; end if;
    v_note := concat_ws(' — ', format('Pallet %s, wrapped', p_pallet), v_note);
  end if;

  v_res := add_photo(p_client_id, 'loadout', v.id, p_sheet, v_note, p_width, p_height);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
  update photos set piece = p_piece, pallet = p_pallet where client_id = p_client_id;
  return v_res || jsonb_build_object('summary',
    format('Photo saved on %s%s.', (select project_id from jobs where id = v.job_id),
           case when p_pallet is not null then format(', pallet %s', p_pallet)
                when p_piece is not null then format(' sheet %s, table %s', p_sheet, p_piece)
                when p_sheet is not null then format(' sheet %s', p_sheet) else '' end));
end $$;
revoke all on function add_loadout_photo(uuid, uuid, int, int, int, text, int, int) from public, anon;
grant execute on function add_loadout_photo(uuid, uuid, int, int, int, text, int, int) to authenticated;

-- ---------------------------------------------------------------------
-- 5. v_loadouts, with the kind, tables and pallets
--    Every column it had before is still there, in the same place.
--    Tables are "sheet:table" (for example '4:2'); a sheet photo with no
--    table number counts as table 1.
-- ---------------------------------------------------------------------

drop view if exists v_loadouts;
create view v_loadouts with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, j.phase, j.delivery_date, l.is_test,
       l.started_by, l.started_by_name, l.started_at, l.finished_at, l.finished_by_name, l.note,
       (l.finished_at is null) as is_open,
       (select count(*)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as sheets_total,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null), '{}') as sheets_here,
       coalesce((select array_agg(distinct p.sheet_number order by p.sheet_number) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null), '{}') as sheets_earlier,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is null and p.pallet is null) as other_items,
       (select count(*)::int from photos p where p.loadout_id = l.id and p.voided_at is null) as photo_count,
       -- version 2
       l.kind, l.carrier, l.tracking,
       (select coalesce(sum(s.qty), 0)::int from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = l.job_id) as pieces_total,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.sheet_number is not null), '{}') as pieces_here,
       coalesce((select array_agg(distinct p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p join loadouts l2 on l2.id = p.loadout_id
                  where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at
                    and p.voided_at is null and p.sheet_number is not null), '{}') as pieces_earlier,
       coalesce((select array_agg(distinct p.pallet order by p.pallet) from photos p
                  where p.loadout_id = l.id and p.voided_at is null and p.pallet is not null), '{}') as pallets_here
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is null;
revoke all on v_loadouts from anon;
grant select on v_loadouts to authenticated;

-- v_photos gains the table and pallet (and the load-out's kind), at the end
drop view if exists v_photos;
create view v_photos with (security_invoker = true) as
select p.id, p.client_id, p.job_id, j.project_id, j.name as job_name, p.sheet_number, p.department, d.name as department_name,
       p.kind, p.defect_id, p.problem_id, p.loadout_id, l.client_id as loadout_client_id,
       df.defect_type, pr.body as problem_body,
       p.note, p.storage_path, p.bytes, p.width, p.height, p.is_test,
       p.taken_by, p.taken_by_name, p.taken_at,
       (p.voided_at is not null) as voided, p.voided_by_name, p.void_reason,
       p.archive_batch, p.archive_name, p.file_removed_at, (p.file_removed_at is null) as in_cloud,
       p.piece, p.pallet, l.kind as loadout_kind
from photos p
join jobs j         on j.id = p.job_id
join departments d  on d.key = p.department
left join defects df  on df.id = p.defect_id
left join problems pr on pr.id = p.problem_id
left join loadouts l  on l.id = p.loadout_id;
revoke all on v_photos from anon;
grant select on v_photos to authenticated;

-- ---------------------------------------------------------------------
-- 6. check_loadouts() — PASS/FAIL, undoes everything it does
-- ---------------------------------------------------------------------

create or replace function check_loadouts()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  tst      uuid;  sup uuid;
  as_tst   text;  as_sup text;
  v_real   uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v        jsonb;
  lo1      uuid := gen_random_uuid();   -- the tablet's own ids
  lo2      uuid := gen_random_uuid();
  lo_real  uuid;
  ph       uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                           gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  n        int;
  ok       boolean;
  msg      text;
  r        record;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments)) limit 1;
  if tst is null or sup is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery) and a supervisor from another department have logins', false,
      concat_ws(' ', case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when sup is null then 'No real supervisor outside Delivery.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;

  begin
    -- ---- 1. the parts exist ------------------------------------------------
    ok := to_regprocedure('public.set_loadout_details(uuid,text,text,text)') is not null
          and to_regprocedure('public.add_loadout_photo(uuid,uuid,integer,integer,integer,text,integer,integer)') is not null
          and to_regclass('public.v_loadout_sheets') is not null
          and exists (select 1 from information_schema.columns where table_name = 'photos' and column_name = 'piece')
          and exists (select 1 from information_schema.columns where table_name = 'loadouts' and column_name = 'kind')
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'pieces_here');
    res := res || check_row(1, 'Load-outs version 2 is set up (the new columns, view and two functions)', ok,
      'Something is missing. Run loadouts_v2.sql again from the top.');

    -- a throwaway job: sheet 1 is 3 round tables, sheet 2 one rectangle; and a test copy
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999994, 'LOADCHECK', 'Load-out check - undone automatically', false, 'Delivery', local_today())
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 3, 'LC-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 1, 'LC-2', 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required)
      select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('LOADCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;
    -- the photo files, as a tablet would upload them first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 1}' from unnest(ph) x;

    -- ---- 2. a shipment, with its carrier and tracking number -------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := start_loadout(v_test, lo1);
      v := set_loadout_details(lo1, 'shipping', 'Estes', 'BOL 44812');
      execute 'reset role';
      ok := exists (select 1 from v_loadouts where client_id = lo1 and kind = 'shipping' and carrier = 'Estes' and tracking = 'BOL 44812');
      msg := 'The load-out didn''t come out as a shipment with carrier Estes and tracking BOL 44812.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A load-out can be a shipment, with a carrier and a tracking or BOL number', ok, msg);

    -- ---- 3. the phone's sheet list has sizes and quantities --------------------
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_loadout_sheets
       where job_id = v_test and ((sheet_number = 1 and qty = 3 and shape = 'Round' and width = '36"' and total_height = '42"')
                               or (sheet_number = 2 and qty = 1 and length = '60"'));
      execute 'reset role';
      ok := n = 2;
      msg := format('Expected both sheets with their sizes and quantities; found %s.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'The sheet list for load-outs has each sheet''s size and number of tables', ok, msg);

    -- ---- 4. a photo per table ------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[1], lo1, 1, 1);
      v := add_loadout_photo(ph[2], lo1, 1, 3);
      v := add_loadout_photo(ph[3], lo1, 2, 1);
      execute 'reset role';
      select pieces_total, pieces_here into r from v_loadouts where client_id = lo1;
      ok := r.pieces_total = 4 and r.pieces_here @> array['1:1', '1:3', '2:1'] and cardinality(r.pieces_here) = 3;
      msg := format('Expected 3 of 4 tables photographed (1:1, 1:3, 2:1); got %s of %s.', r.pieces_here, r.pieces_total);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Each table gets its own photo, and the load-out counts tables (3 of 4)', ok, msg);

    -- ---- 5. a table that isn't on the sheet is refused ---------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := add_loadout_photo(ph[4], lo1, 1, 4); ok := false; msg := 'Table 4 was accepted on a sheet with 3 tables.';
      exception when others then null; end;
      begin v := add_loadout_photo(ph[4], lo1, 1, 0); ok := false; msg := 'Table 0 was accepted.';
      exception when others then null; end;
      begin v := add_loadout_photo(ph[4], lo1, null, 1); ok := false; msg := 'A table number with no sheet was accepted.';
      exception when others then null; end;
      execute 'reset role';
      if ok and exists (select 1 from photos where client_id = ph[4]) then ok := false; msg := 'A refused photo was saved anyway.'; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A table number that isn''t on the sheet is refused, and nothing is saved', ok, msg);

    -- ---- 6. the wrapped pallet --------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[4], lo1, null, null, 1);
      execute 'reset role';
      ok := exists (select 1 from v_loadouts where client_id = lo1 and pallets_here = array[1] and other_items = 0)
            and exists (select 1 from photos where client_id = ph[4] and pallet = 1 and note like 'Pallet 1, wrapped%');
      msg := 'The pallet photo wasn''t recorded as pallet 1 (or it was counted as an "other item").';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A shipment records a photo of each wrapped pallet', ok, msg);

    -- ---- 7. pallets only on shipments, never on a sheet ----------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := add_loadout_photo(ph[5], lo1, 1, null, 2); ok := false; msg := 'A pallet photo was accepted on a sheet.';
      exception when others then null; end;
      v := start_loadout(v_test, lo2);                          -- a second truck: a plain delivery
      begin v := add_loadout_photo(ph[5], lo2, null, null, 1); ok := false; msg := 'A pallet photo was accepted on a delivery.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Pallet photos are refused on a delivery, and on a sheet', ok, msg);

    -- ---- 8. a resend counts once; the second truck sees the first ------------------
    begin
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[1], lo1, 1, 1);                 -- the same photo, sent again
      v := add_loadout_photo(ph[5], lo2, 1, 2);
      execute 'reset role';
      -- both trucks started inside this one check, at the same moment; make the first one earlier, as real trucks are
      update loadouts set started_at = started_at - interval '1 hour' where client_id = lo1;
      ok := (select count(*) from photos where client_id = ph[1]) = 1
            and exists (select 1 from v_loadouts where client_id = lo2 and kind = 'delivery'
                           and pieces_here = array['1:2'] and pieces_earlier @> array['1:1', '1:3', '2:1']);
      msg := 'A resent photo was added twice, or the second truck didn''t show what went on the first.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A photo sent twice counts once; a second truck shows what went on the first', ok, msg);

    -- ---- 9. a photo for a load-out that hasn't arrived waits -----------------------
    begin
      execute 'set local role authenticated';
      v := add_loadout_photo(ph[6], gen_random_uuid(), 1, 1);
      execute 'reset role';
      ok := coalesce((v->>'waiting')::boolean, false) and not exists (select 1 from photos where client_id = ph[6]);
      msg := 'A photo for a load-out still on its way wasn''t told to wait.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'A photo taken with no signal waits for its load-out, rather than failing', ok, msg);

    -- ---- 10. old photos still work: no table number = table 1 ------------------------
    begin
      execute 'set local role authenticated';
      v := add_photo(ph[7], 'loadout', lo2, 2);                 -- how the current page adds a load-out photo
      execute 'reset role';
      ok := coalesce((v->>'ok')::boolean, false)
            and exists (select 1 from v_loadouts where client_id = lo2 and pieces_here @> array['2:1'] and sheets_here @> array[2]);
      msg := 'A load-out photo added the old way (no table number) didn''t count as table 1.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Photos added the old way still work, and count as table 1', ok, msg);

    -- ---- 11. other logins are refused ----------------------------------------------
    -- a real load-out too, so the department rule is tested on its own (not just the test lane)
    insert into loadouts (job_id, is_test, started_by_name) values (v_real, false, 'check') returning id into lo_real;
    perform set_config('request.jwt.claims', as_sup, true);
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := set_loadout_details(lo1, 'delivery'); ok := false; msg := 'A supervisor outside Delivery changed a load-out.';
      exception when others then null; end;
      begin v := set_loadout_details(lo_real, 'shipping'); ok := false; msg := 'A supervisor outside Delivery changed a real load-out.';
      exception when others then null; end;
      begin v := add_loadout_photo(ph[8], lo1, 2, 1);
        if coalesce((v->>'ok')::boolean, false) then ok := false; msg := 'A supervisor outside Delivery added a load-out photo.'; end if;
      exception when others then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      begin v := add_loadout_photo(ph[8], lo1, 2, 1); ok := false; msg := 'Someone with no login added a load-out photo.';
      exception when others then null; end;
      begin select count(*) into n from v_loadout_sheets; if n > 0 then ok := false; msg := 'Sheets are readable without logging in.'; end if;
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      ok := ok and (select kind from loadouts where client_id = lo1) = 'shipping' and (select kind from loadouts where id = lo_real) = 'delivery'
               and not exists (select 1 from photos where client_id = ph[8]);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Only Delivery (and managers) can change a load-out; someone with no login sees nothing', ok, msg);

    -- ---- 12. real and test stay apart -------------------------------------------------
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_loadout_sheets where job_id = v_test;
      select n + count(*) into n from v_loadouts where job_id = v_test;
      execute 'reset role';
      ok := n = 0;
      msg := 'A real supervisor can see the test job''s sheets or load-outs.';
      if ok then
        perform set_config('request.jwt.claims', as_tst, true);
        execute 'set local role authenticated';
        select count(*) into n from v_loadout_sheets where job_id = v_real;
        execute 'reset role';
        ok := n = 0;
        msg := 'The Test Supervisor''s load-out sheet list shows a real job''s sheets.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Real and test stay apart: real logins don''t see test load-outs, the test login doesn''t list real sheets', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_loadouts_undo__';
  exception when others then
    if sqlerrm <> '__check_loadouts_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_loadouts() from public, anon, authenticated;

select * from check_loadouts();
