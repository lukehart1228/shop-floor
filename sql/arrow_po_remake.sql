-- =====================================================================
-- arrow_po_remake.sql — Make an Arrow PO again (4 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 54. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Needs arrow_pos.sql (run order 51) with its 4 Nov re-paste
-- (Walkthrough 45). Replaces nothing, so no earlier file stops.
--
-- WHAT IT DOES (design: the Arrow POs tab, 4 Nov)
-- A PO keeps its header and lines exactly as made. AR-10 was made
-- before its jobs' Arrow lines were in the app (they went on the floor
-- through the old Upload page), so it printed "Item CR-01 (sheet 7)"
-- with blanks, and with the PO details as they stood then. Once those
-- jobs' zips are dropped (which saves their lines) and the PO details are
-- right, the office's Make it again rebuilds the PO:
-- 1. arrow_pos gains revision (1 as made), earlier (every earlier
--    version: its header, lines and file name, kept for good), and who
--    made it again and when.
-- 2. arrow_po_remake(): managers only. Same number, same items, same
--    dates and jobs; the lines worked out again from the items on it and
--    their Arrow lines now (an item that went whole before its lines
--    existed takes all of them); the issuer, address and tax-exempt line
--    from the PO details now. The file becomes AR-10(...) r2.pdf, filed
--    by the next save beside the first one (nothing is overwritten or
--    deleted). If nothing would change, nothing does.
-- 3. arrow_po_lines(): the lines for a PO's items, as arrow_po_make()
--    works them out. Inside only; no login calls it.
-- Nothing existing changes meaning, and nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('arrow_po_remake.sql', 54, 'check_arrow_po_remake', 'check_arrow_po_remake', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('arrow_po_remake.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.arrow_po_make(uuid,date,jsonb)') is null then raise exception 'Run arrow_pos.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. arrow_pos keeps its earlier versions
-- ---------------------------------------------------------------------

alter table arrow_pos add column if not exists revision       int not null default 1;
alter table arrow_pos add column if not exists earlier        jsonb not null default '[]';
alter table arrow_pos add column if not exists remade_at      timestamptz;
alter table arrow_pos add column if not exists remade_by_name text;


-- ---------------------------------------------------------------------
-- 2. The lines for a PO's items, worked out now
-- ---------------------------------------------------------------------

create or replace function arrow_po_lines(p_po uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with went as (
    select o.*, j.project_id,
           -- what the item took: as recorded; an item that went whole with no lines recorded takes all its lines now
           coalesce(o.arrow_qty,
                    (select jsonb_agg(jsonb_build_object('sheet', c ->> 'sheet', 'pos', c ->> 'pos', 'qty', c ->> 'holds'))
                       from jsonb_array_elements(arrow_item_counts(o.job_id, o.sheet_numbers, null)) c)) as took
      from outside_jobs o join jobs j on j.id = o.job_id
     where o.po_id = p_po and o.voided_at is null),
  lined as (
    select w.project_id, l.base, l.description, l.pd_color, l.arrow_color, sum((x ->> 'qty')::int) as qty
      from went w
      cross join lateral jsonb_array_elements(coalesce(w.took, '[]')) x
      join work_orders wo on wo.job_id = w.job_id and wo.is_current
      join sheet_arrow_lines l on l.work_order_id = wo.id and l.sheet_number = (x ->> 'sheet')::int and l.position = (x ->> 'pos')::int
     where (x ->> 'qty')::int > 0
     group by w.project_id, l.base, l.description, l.pd_color, l.arrow_color),
  bare as (
    select w.project_id, ''::text as base,
           coalesce(nullif(btrim(w.description), ''),
                    'Item ' || coalesce((select string_agg(distinct s.item_code, ', ') from sheets s join work_orders wo on wo.id = s.work_order_id and wo.is_current
                                          where wo.job_id = w.job_id and s.sheet_number = any(w.sheet_numbers)), '')
                    || ' (sheet' || case when cardinality(w.sheet_numbers) = 1 then ' ' else 's ' end || array_to_string(w.sheet_numbers, ', ') || ')') as description,
           ''::text as pd_color, ''::text as arrow_color, null::int as qty
      from went w where jsonb_array_length(coalesce(w.took, '[]')) = 0)
  select coalesce(jsonb_agg(jsonb_build_object('qty', x.qty, 'base', x.base, 'description', x.description, 'pd_color', x.pd_color,
                                               'arrow_color', x.arrow_color, 'project', x.project_id)
                            order by arrow_colour_rank(x.pd_color), lower(x.pd_color), x.project_id, x.base, x.description), '[]')
    from (select * from lined union all select * from bare) x;
$$;
revoke all on function arrow_po_lines(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Make it again (the office)
-- ---------------------------------------------------------------------

create or replace function arrow_po_remake(p_po uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare po arrow_pos; st arrow_po_settings; v_lines jsonb; v_header jsonb; v_file text; v_rev int; n_col int; n_all int;
begin
  if not office_ok() then raise exception 'Only a manager makes a PO again.' using errcode = 'insufficient_privilege'; end if;
  select * into po from arrow_pos where id = p_po for update;
  if po.id is null or not sees_lane(po.is_test) then raise exception 'That PO isn''t there.'; end if;
  select * into st from arrow_po_settings;
  if nullif(btrim(coalesce(st.issued_by, '')), '') is null then
    raise exception 'Fill in the PO details first (Issued by at least). Nothing was changed.';
  end if;
  v_lines := arrow_po_lines(po.id);
  if jsonb_array_length(v_lines) = 0 then raise exception 'Nothing on % is still on the Arrow list (taken off by mistake?). Nothing was changed.', po.name; end if;
  -- the issuer and the words from the PO details now; the dates, Arrow, pickup and the jobs as made
  v_header := po.header || jsonb_build_object('issued_by', st.issued_by, 'phone', st.phone, 'email', st.email, 'address', st.address, 'tax_line', st.tax_line);
  select count(*) filter (where nullif(x ->> 'pd_color', '') is not null), count(*) into n_col, n_all from jsonb_array_elements(v_lines) x;
  if v_lines = po.lines and v_header = po.header then
    return jsonb_build_object('ok', true, 'unchanged', true, 'id', po.id, 'name', po.name,
      'summary', format('%s is already up to date: the same lines and details as it has now. %s',
                        po.name, case when n_col < n_all then format('%s of its %s lines have no colour: drop those jobs'' zips first.', n_all - n_col, n_all) else '' end));
  end if;
  v_rev := po.revision + 1;
  v_file := regexp_replace(po.file_name, '( r\d+)?\.pdf$', '') || ' r' || v_rev || '.pdf';
  update arrow_pos set
    earlier = earlier || jsonb_build_array(jsonb_build_object('revision', po.revision, 'file_name', po.file_name, 'header', po.header, 'lines', po.lines,
                                                              'made_at', coalesce(po.remade_at, po.made_at), 'made_by_name', coalesce(po.remade_by_name, po.made_by_name),
                                                              'onedrive_at', po.onedrive_at, 'backup_at', po.backup_at)),
    revision = v_rev, file_name = v_file, header = v_header, lines = v_lines,
    remade_at = now(), remade_by_name = my_name(),
    onedrive_bytes = null, onedrive_at = null, backup_bytes = null, backup_at = null     -- the next save files the new one beside the old
   where id = po.id;
  return jsonb_build_object('ok', true, 'id', po.id, 'name', po.name, 'file_name', v_file, 'revision', v_rev, 'header', v_header, 'lines', v_lines,
    'summary', format('%s made again (r%s): %s line%s, %s with colours. The next save files it as %s beside the first one.',
                      po.name, v_rev, n_all, case when n_all = 1 then '' else 's' end, n_col, v_file));
end $$;
revoke all on function arrow_po_remake(uuid) from public, anon;
grant execute on function arrow_po_remake(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 4. The check. Its own job, lines and PO, as a manager and Metal's
--    supervisor signed in; everything is undone at the end.
-- ---------------------------------------------------------------------

create or replace function check_arrow_po_remake()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]'; mgr uuid; met uuid; as_mgr text; as_met text; j1 uuid; w1 uuid; a1 uuid; a2 uuid;
  v jsonb; v2 jsonb; po arrow_pos; ok boolean; msg text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test limit 1;
  select p.id into met from profiles p where p.role = 'supervisor' and p.active and not p.is_test and 'metal' = any(p.departments) limit 1;
  if mgr is null or met is null then
    res := res || check_row(1, 'A manager and Metal''s supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_met := json_build_object('sub', met, 'role', 'authenticated')::text;

  -- ---- 1. the function needs a manager's login; the helper is closed ----------
  ok := to_regprocedure('public.arrow_po_remake(uuid)') is not null
    and not has_function_privilege('anon', 'public.arrow_po_remake(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.arrow_po_remake(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.arrow_po_lines(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.arrow_po_lines(uuid)', 'execute')
    and not has_table_privilege('authenticated', 'public.arrow_pos', 'update');
  res := res || check_row(1, 'Make it again needs a login; the lines helper is closed to logins; no login writes a PO directly', ok,
    'A function or the PO table is open where it shouldn''t be. Run arrow_po_remake.sql again.');

  begin
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999961, 'PROJ-99961', 'Arrow PO remake check - undone automatically', true, 'In Production') returning id into j1;
    insert into work_orders (job_id, is_current) values (j1, true) returning id into w1;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w1, 1, 4, 'TB-01'), (w1, 2, 1, 'CR-01');
    update arrow_po_settings set issued_by = 'Check Issuer', address = 'Arrow Powdercoating', tax_line = '?', next_number = greatest(next_number, 9500) where id;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j1, '{1}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a1;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j1, '{2}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a2;

    -- ---- 2. a PO made before the job had lines: blanks, as AR-10 was ------------
    perform set_config('request.jwt.claims', as_met, true);
    execute 'set local role authenticated';
    v := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1), jsonb_build_object('id', a2)));
    execute 'reset role';
    ok := jsonb_array_length(v -> 'lines') = 2 and v #>> '{lines,0,pd_color}' = '' and v -> 'lines' @> '[{"description": "Item TB-01 (sheet 1)"}, {"description": "Item CR-01 (sheet 2)"}]'::jsonb
          and v #>> '{header,address}' = 'Arrow Powdercoating';
    res := res || check_row(2, 'A PO made before its job''s Arrow lines prints the items with blanks (as AR-10 did)', ok, 'Unexpected: ' || left(v::text, 300));

    -- ---- 3. Metal's supervisor can't make it again --------------------------------
    begin
      perform set_config('request.jwt.claims', as_met, true);
      execute 'set local role authenticated';
      v2 := arrow_po_remake((v ->> 'id')::uuid);
      execute 'reset role'; ok := false; msg := 'Metal''s supervisor made a PO again.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'Only a manager makes a PO again', ok, msg);

    -- ---- 4. the lines arrive (the zip dropped again) and the details are fixed; made again ----
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v2 := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": [{"qty": 4, "base": "HNRY", "description": "H-Leg, 2\" Square Tube", "pd_color": "Stardust Silver", "arrow_color": "RAL 9006 White Aluminum"}]},
                               {"sheet_number": 2, "arrow": [{"qty": 2, "base": "DAN", "description": "Angled Post Leg", "pd_color": "Denim Black", "arrow_color": "PCU90229 Denim Black"}]}]');
    v2 := set_arrow_po_settings('{"address": "Purposeful Design\n1 Test Street", "tax_line": "Check tax line"}');
    v2 := arrow_po_remake((v ->> 'id')::uuid);
    execute 'reset role';
    select * into po from arrow_pos where id = (v ->> 'id')::uuid;
    ok := po.revision = 2 and po.name = v ->> 'name' and po.file_name = regexp_replace(v ->> 'file_name', '\.pdf$', '') || ' r2.pdf'
      and jsonb_array_length(po.lines) = 2 and po.lines #>> '{0,pd_color}' = 'Denim Black' and (po.lines #>> '{0,qty}')::int = 2
      and po.lines #>> '{1,pd_color}' = 'Stardust Silver' and (po.lines #>> '{1,qty}')::int = 4 and po.lines #>> '{1,base}' = 'HNRY'
      and po.header ->> 'address' like 'Purposeful Design%' and po.header ->> 'tax_line' = 'Check tax line'
      and po.header ->> 'date_issued' = v #>> '{header,date_issued}' and po.header ->> 'po_jobs' = v #>> '{header,po_jobs}'
      and po.onedrive_at is null and po.backup_at is null and po.remade_by_name is not null;
    res := res || check_row(4, 'Made again: same number and dates, the colours from the lines now (Denim Black first), the details now, filed as r2', ok,
      'Unexpected: ' || left(row_to_json(po)::text, 400));

    -- ---- 5. the first version is kept; nothing changed means nothing done ----------
    ok := jsonb_array_length(po.earlier) = 1 and po.earlier #> '{0,lines}' @> '[{"description": "Item TB-01 (sheet 1)"}]'::jsonb
          and po.earlier #>> '{0,header,address}' = 'Arrow Powdercoating' and po.earlier #>> '{0,file_name}' = v ->> 'file_name';
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v2 := arrow_po_remake((v ->> 'id')::uuid);
    execute 'reset role';
    ok := ok and (v2 ->> 'unchanged')::boolean and (select revision from arrow_pos where id = po.id) = 2;
    res := res || check_row(5, 'The first version is kept in full; making it again with nothing new changes nothing', ok, 'Unexpected: ' || left(v2::text, 300));

    -- ---- 6. the office's save lists it again to file -------------------------------
    perform set_config('request.jwt.claims', as_mgr, true);
    execute 'set local role authenticated';
    v2 := arrow_pos_to_file();
    execute 'reset role';
    ok := po.is_test or v2 @> jsonb_build_array(jsonb_build_object('file_name', po.file_name));
    res := res || check_row(6, 'The next save files the new version (a test PO is never filed)', ok, 'Not listed to file: ' || left(v2::text, 300));

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  when others then
    begin execute 'reset role'; exception when others then null; end;
    res := res || check_row(9, 'The check ran to the end', false, 'Error: ' || sqlerrm);
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end $$;
revoke all on function check_arrow_po_remake() from public, anon, authenticated;

select * from check_arrow_po_remake();
