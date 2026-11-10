-- =====================================================================
-- qc_checklist.sql — The QC checklist at Assembly / QC (database, 7 Nov 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 56. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Nothing on the tablets changes until the new index.html goes on
-- GitHub; this file only adds. Today's pages never call any of it.
--
-- WHAT IT DOES (design: the QC checklist tab, 5 Nov)
-- Each piece of each sheet is checked at Assembly / QC against its work
-- order page: section by section where the generator sent sections
-- (qc_sections in the upload file), or against the whole page where it
-- didn't. A piece passes with a photo of it finished; a piece with
-- something wrong is sent back as a Failed QC defect on its sheet, with
-- what's wrong and its photos, like any defect.
--   sheet_qc_sections   each sheet's sections: a number and a rectangle
--                       on the page image (shares of its width and
--                       height), never any work order text
--   qc_checks           every check of a piece: pass or sent back, who,
--                       when, each section, the finished photo, the
--                       Failed QC defect it logged. Tied to the sheet's
--                       drawing (spec_hash): a change order that changes
--                       the drawing starts that sheet's QC again; the
--                       old checks stay as history. Nothing is deleted:
--                       a mistake is marked entered by mistake.
--   set_sheet_qc_sections()  the drop page saves a work order's sections
--                       (managers, or the SQL Editor)
--   qc_record()         the tablet records one check (Assembly / QC and
--                       managers), in one step
--   qc_job()            the tablet's view of a job's QC: each sheet's
--                       sections, how many pieces passed, which were
--                       sent back and which sections passed then
--   qc_void()           a manager marks a check entered by mistake
-- Passing QC sets Assembly / QC's count (Luke, 7 Nov): each pass raises the
-- sheet's Assembly / QC count to the number of pieces passed, through
-- set_count() in the same step, so the sheet turns turquoise when every
-- piece has passed. A count already higher (counted by hand before QC) is
-- never lowered; a pass marked entered by mistake takes one back off.
-- Replaces nothing. Ends with check_qc_checklist().
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('qc_checklist.sql', 56, 'check_qc_checklist', 'check_qc_checklist', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('qc_checklist.sql', '{}'); end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Each sheet's sections, from the upload file
-- ---------------------------------------------------------------------

create table if not exists sheet_qc_sections (
  sheet_id   uuid primary key references sheets(id),
  sections   jsonb not null,           -- [{"n":1,"x":0.0449,"y":0.2137,"w":0.1088,"h":0.0641}, …] in reading order
  saved_at   timestamptz not null default now(),
  saved_by   uuid references profiles(id),
  constraint sheet_qc_sections_array check (jsonb_typeof(sections) = 'array')
);
alter table sheet_qc_sections enable row level security;
drop policy if exists read_sheet_qc_sections on sheet_qc_sections;
create policy read_sheet_qc_sections on sheet_qc_sections for select to authenticated using (true);   -- like sheets: rectangles only
revoke insert, update, delete, truncate on sheet_qc_sections from anon, authenticated;
revoke all on sheet_qc_sections from anon;

-- Checks one sheet's qc_sections and returns them tidied, or raises in plain words.
create or replace function qc_sections_clean(p_sheet int, p_list jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare a jsonb; out jsonb := '[]'::jsonb; i int := 0; x numeric; y numeric; w numeric; h numeric;
begin
  if jsonb_typeof(p_list) is distinct from 'array' then raise exception 'Sheet %: qc_sections should be a list.', p_sheet; end if;
  if jsonb_array_length(p_list) > 40 then raise exception 'Sheet % has % QC sections; 40 is the most.', p_sheet, jsonb_array_length(p_list); end if;
  for a in select * from jsonb_array_elements(p_list) loop
    i := i + 1;
    if jsonb_typeof(a -> 'n') is distinct from 'number' or (a ->> 'n')::numeric <> i then
      raise exception 'Sheet %: QC sections should be numbered 1, 2, 3… in order (section % says %).', p_sheet, i, coalesce(a ->> 'n', 'nothing');
    end if;
    if jsonb_typeof(a -> 'x') is distinct from 'number' or jsonb_typeof(a -> 'y') is distinct from 'number'
       or jsonb_typeof(a -> 'w') is distinct from 'number' or jsonb_typeof(a -> 'h') is distinct from 'number' then
      raise exception 'Sheet %: QC section % needs x, y, w and h as numbers.', p_sheet, i;
    end if;
    x := (a ->> 'x')::numeric; y := (a ->> 'y')::numeric; w := (a ->> 'w')::numeric; h := (a ->> 'h')::numeric;
    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > 1.0005 or y + h > 1.0005 then
      raise exception 'Sheet %: QC section % isn''t on the page (x %, y %, w %, h % should be shares of the page, 0 to 1).', p_sheet, i, x, y, w, h;
    end if;
    out := out || jsonb_build_object('n', i, 'x', round(x, 4), 'y', round(y, 4), 'w', round(w, 4), 'h', round(h, 4));
  end loop;
  return out;
end $$;
revoke all on function qc_sections_clean(int, jsonb) from public, anon, authenticated;

-- The drop page saves a work order's sections after its upload, like set_sheet_arrow().
-- p_sheets is the upload file's sheets list; a sheet with no qc_sections is skipped
-- (it gets the whole-page check). Saved once per sheet: a second save changes nothing.
create or replace function set_sheet_qc_sections(p_work_order uuid, p_sheets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s jsonb; v_num int; v_sheet uuid; v_clean jsonb; n_saved int := 0; n_already int := 0; n_none int := 0;
begin
  if not (is_manager() or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'))) then
    raise exception 'Only a manager login can save QC sections.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from work_orders where id = p_work_order) then raise exception 'There''s no such work order.'; end if;
  if jsonb_typeof(p_sheets) is distinct from 'array' then raise exception 'Send the upload file''s sheets list.'; end if;
  for s in select * from jsonb_array_elements(p_sheets) loop
    v_num := (s ->> 'sheet_number')::int;
    select id into v_sheet from sheets where work_order_id = p_work_order and sheet_number = v_num;
    if v_sheet is null then raise exception 'Sheet % isn''t on that work order.', coalesce(s ->> 'sheet_number', '?'); end if;
    if s -> 'qc_sections' is null or jsonb_typeof(s -> 'qc_sections') = 'null'
       or (jsonb_typeof(s -> 'qc_sections') = 'array' and jsonb_array_length(s -> 'qc_sections') = 0) then
      n_none := n_none + 1; continue;
    end if;
    v_clean := qc_sections_clean(v_num, s -> 'qc_sections');
    insert into sheet_qc_sections (sheet_id, sections, saved_by) values (v_sheet, v_clean, auth.uid())
    on conflict (sheet_id) do nothing;
    if found then n_saved := n_saved + 1; else n_already := n_already + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'saved', n_saved, 'already', n_already, 'whole_page', n_none);
end $$;
revoke all on function set_sheet_qc_sections(uuid, jsonb) from public, anon;
grant execute on function set_sheet_qc_sections(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 2. Every check of a piece
-- ---------------------------------------------------------------------

create table if not exists qc_checks (
  id                  uuid primary key default gen_random_uuid(),
  client_id           uuid not null unique,                 -- the tablet's own id: a resend can't record it twice
  job_id              uuid not null references jobs(id),
  sheet_number        int  not null,
  sheet_id            uuid not null references sheets(id),  -- the sheet row as it was checked
  spec_hash           text,                                 -- its drawing; a change order that changes it starts QC again
  piece               int  not null,
  result              text not null check (result in ('pass', 'fail')),
  sections            jsonb not null,                       -- [{"n":1,"ok":true}, {"n":5,"ok":false,"note":"…"}]; n 0 = the whole page
  finished_photo_path text,                                 -- photos bucket, <PROJ>/<id>.jpg; every pass has one
  defect_id           uuid references defects(id),          -- the Failed QC defect a send-back logged
  recheck_of          uuid references qc_checks(id),        -- the send-back this check followed
  is_test             boolean not null default false,
  checked_by          uuid references profiles(id),
  checked_by_name     text,
  checked_at          timestamptz not null default now(),
  voided_at           timestamptz,                          -- "entered by mistake": kept, not counted
  voided_by_name      text,
  void_reason         text,
  constraint qc_checks_piece check (piece >= 1),
  constraint qc_checks_pass_photo check (result <> 'pass' or finished_photo_path is not null),
  constraint qc_checks_fail_defect check (result <> 'fail' or defect_id is not null)
);
create index if not exists qc_checks_job_idx on qc_checks (job_id, sheet_number, piece);
-- one standing pass per piece of a drawing
create unique index if not exists qc_checks_one_pass on qc_checks (job_id, sheet_number, coalesce(spec_hash, ''), piece)
  where result = 'pass' and voided_at is null;
alter table qc_checks enable row level security;
drop policy if exists read_qc_checks on qc_checks;
create policy read_qc_checks on qc_checks for select to authenticated using (sees_lane(is_test));
revoke insert, update, delete, truncate on qc_checks from anon, authenticated;
revoke all on qc_checks from anon;

-- The sheet on a job's current work order, or nothing.
create or replace function qc_current_sheet(p_job uuid, p_sheet int) returns sheets
language sql stable security definer set search_path = public as $$
  select s.* from sheets s join work_orders w on w.id = s.work_order_id
   where w.job_id = p_job and w.is_current and s.sheet_number = p_sheet limit 1;
$$;
revoke all on function qc_current_sheet(uuid, int) from public, anon, authenticated;

-- Assembly / QC's count on a sheet after QC: raised to the pieces passed, never lowered by a pass;
-- p_less takes one off (a pass marked entered by mistake), never below the pieces passed.
-- Through set_count(), so its own rules (who, lane, change orders) apply. Nothing if the sheet
-- doesn't go through Assembly / QC.
create or replace function qc_set_count(p_job uuid, p_sheet int, p_passed int, p_less boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare v_row uuid; v_done int; v_req int; v_to int;
begin
  select sp.id, sp.qty_done, sp.qty_required into v_row, v_done, v_req
    from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id
   where w.job_id = p_job and w.is_current and s.sheet_number = p_sheet and sp.department = 'assembly_qc';
  if v_row is null then return null; end if;
  v_to := case when p_less then greatest(p_passed, v_done - 1) else greatest(v_done, p_passed) end;
  v_to := least(v_to, v_req);
  if v_to <> v_done then perform set_count(v_row, v_to); end if;
  return v_to;
end $$;
revoke all on function qc_set_count(uuid, int, int, boolean) from public, anon, authenticated;

-- A photo file the tablet put in the photos bucket: its path, or a plain refusal.
create or replace function qc_photo_path(p_job jobs, p_photo uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_path text;
begin
  v_path := p_job.project_id || '/' || p_photo || '.jpg';
  if not exists (select 1 from storage.objects o where o.bucket_id = 'photos' and o.name = v_path) then
    raise exception 'A photo hasn''t arrived yet, so the check wasn''t saved. It sends again by itself.';
  end if;
  return v_path;
end $$;
revoke all on function qc_photo_path(jobs, uuid) from public, anon, authenticated;

-- Record one check of one piece, in one step.
--   p_sections       every section of the sheet, each {"n", "ok"} (and "note" when not ok);
--                    a sheet with no sections is one: {"n": 0} for the whole page
--   p_finished_photo the photo of the finished piece (needed to pass)
--   p_fail_photos    the photos of what's wrong (needed to send back, 1 to 6)
create or replace function qc_record(p_client_id uuid, p_job uuid, p_sheet int, p_piece int, p_sections jsonb,
                                     p_finished_photo uuid default null, p_fail_photos jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_job jobs; v_sheet sheets; v_expect int[]; v_got int[]; v_secs jsonb := '[]'::jsonb;
  a jsonb; v_fail boolean := false; v_notes text[] := '{}'; v_note text; v_type uuid; v_def uuid; v_path text;
  v_photo text; v_finished text; v_prev uuid; v_passed int; v_by text; v_at timestamptz; k int := 0;
begin
  if p_client_id is null then raise exception 'This check has no id. Start it again.'; end if;
  select id into v_id from qc_checks where client_id = p_client_id;
  if v_id is not null then
    return (select jsonb_build_object('ok', true, 'id', id, 'already', true, 'result', result, 'summary', 'Already saved.') from qc_checks where id = v_id);
  end if;
  v_job := floor_entry_check('assembly_qc', p_job);
  v_sheet := qc_current_sheet(p_job, p_sheet);
  if v_sheet.id is null then raise exception 'Sheet % isn''t on %''s current work order.', coalesce(p_sheet::text, '?'), v_job.project_id; end if;
  if p_piece is null or p_piece < 1 or p_piece > v_sheet.qty then
    raise exception 'Sheet % has % piece%, so there''s no piece %.', p_sheet, v_sheet.qty, case when v_sheet.qty = 1 then '' else 's' end, coalesce(p_piece::text, '?');
  end if;
  select checked_by_name, checked_at into v_by, v_at from qc_checks
   where job_id = p_job and sheet_number = p_sheet and coalesce(spec_hash, '') = coalesce(v_sheet.spec_hash, '')
     and piece = p_piece and result = 'pass' and voided_at is null;
  if found then
    raise exception 'Piece % of sheet % already passed QC (%, %).', p_piece, p_sheet, coalesce(v_by, 'someone'),
      to_char(v_at at time zone 'America/Indiana/Indianapolis', 'Mon FMDD FMHH12:MI AM');
  end if;

  -- the sections this sheet has, every one answered once
  select coalesce(array_agg((e ->> 'n')::int order by (e ->> 'n')::int), '{0}') into v_expect
    from sheet_qc_sections q, jsonb_array_elements(q.sections) e where q.sheet_id = v_sheet.id;
  if jsonb_typeof(p_sections) is distinct from 'array' then raise exception 'Send every section''s answer.'; end if;
  begin
    select coalesce(array_agg((e ->> 'n')::int order by (e ->> 'n')::int), '{}') into v_got from jsonb_array_elements(p_sections) e;
  exception when others then raise exception 'This check doesn''t match the sheet''s sections. Close it, open the sheet again and check again.';
  end;
  if v_got is distinct from v_expect then
    raise exception 'This check doesn''t match the sheet''s sections. Close it, open the sheet again and check again.';
  end if;
  for a in select * from jsonb_array_elements(p_sections) e order by (e ->> 'n')::int loop
    if jsonb_typeof(a -> 'ok') is distinct from 'boolean' then raise exception 'Section % has no answer.', a ->> 'n'; end if;
    if (a ->> 'ok')::boolean then
      v_secs := v_secs || jsonb_build_object('n', (a ->> 'n')::int, 'ok', true);
    else
      v_fail := true;
      v_note := btrim(coalesce(a ->> 'note', ''));
      if v_note = '' then raise exception 'Say what''s wrong in %.', case when (a ->> 'n')::int = 0 then 'the piece' else 'section ' || (a ->> 'n') end; end if;
      if length(v_note) > 300 then raise exception 'Keep what''s wrong to 300 letters.'; end if;
      v_secs := v_secs || jsonb_build_object('n', (a ->> 'n')::int, 'ok', false, 'note', v_note);
      v_notes := v_notes || (case when (a ->> 'n')::int = 0 then '' else 'section ' || (a ->> 'n') || ': ' end || v_note);
    end if;
  end loop;

  -- the send-back this follows, if the piece's last check was one
  select id into v_prev from qc_checks
   where job_id = p_job and sheet_number = p_sheet and coalesce(spec_hash, '') = coalesce(v_sheet.spec_hash, '')
     and piece = p_piece and voided_at is null
   order by checked_at desc limit 1;
  if v_prev is not null and (select result from qc_checks where id = v_prev) <> 'fail' then v_prev := null; end if;

  if v_fail then
    if jsonb_typeof(p_fail_photos) is distinct from 'array' or jsonb_array_length(p_fail_photos) = 0 then
      raise exception 'Take a photo of what''s wrong before sending the piece back.';
    end if;
    if jsonb_array_length(p_fail_photos) > 6 then raise exception 'Six photos is the most on one send-back.'; end if;
    select id into v_type from defect_types where department = 'assembly_qc' and label = 'Failed QC' and active;
    if v_type is null then
      raise exception '"Failed QC" isn''t on Assembly / QC''s defect list. In the office: Setup → Defect lists → Assembly / QC → add "Failed QC".';
    end if;
    v_def := (log_defect(p_job, 'assembly_qc', v_type, p_sheet,
                         format('QC, piece %s of %s: %s', p_piece, v_sheet.qty, array_to_string(v_notes, '; ')), null) ->> 'id')::uuid;
    for v_photo in select jsonb_array_elements_text(p_fail_photos) loop
      k := k + 1;
      v_path := qc_photo_path(v_job, v_photo::uuid);
      insert into photos (client_id, job_id, sheet_number, department, kind, defect_id, storage_path, bytes, is_test, taken_by, taken_by_name)
      values (v_photo::uuid, v_job.id, p_sheet, 'assembly_qc', 'defect', v_def, v_path,
              (select coalesce((o.metadata ->> 'size')::bigint, 0) from storage.objects o where o.bucket_id = 'photos' and o.name = v_path),
              v_job.is_test, auth.uid(), my_name());
    end loop;
  else
    if p_finished_photo is null then raise exception 'Take the finished photo to pass the piece.'; end if;
    v_finished := qc_photo_path(v_job, p_finished_photo);
  end if;

  insert into qc_checks (client_id, job_id, sheet_number, sheet_id, spec_hash, piece, result, sections, finished_photo_path,
                         defect_id, recheck_of, is_test, checked_by, checked_by_name)
  values (p_client_id, p_job, p_sheet, v_sheet.id, v_sheet.spec_hash, p_piece, case when v_fail then 'fail' else 'pass' end,
          v_secs, v_finished, v_def, v_prev, v_job.is_test, auth.uid(), my_name())
  returning id into v_id;

  select count(*) into v_passed from qc_checks
   where job_id = p_job and sheet_number = p_sheet and coalesce(spec_hash, '') = coalesce(v_sheet.spec_hash, '')
     and result = 'pass' and voided_at is null;
  if not v_fail then perform qc_set_count(p_job, p_sheet, v_passed); end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'result', case when v_fail then 'fail' else 'pass' end,
    'passed', v_passed, 'of', v_sheet.qty, 'defect_id', v_def,
    'summary', case when v_fail
      then format('Piece %s of sheet %s sent back: logged as Failed QC on %s sheet %s.', p_piece, p_sheet, v_job.project_id, p_sheet)
      else format('Piece %s of sheet %s passed QC (%s of %s).', p_piece, p_sheet, v_passed, v_sheet.qty) end);
exception when unique_violation then
  select id into v_id from qc_checks where client_id = p_client_id;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already saved.');
  end if;
  raise exception 'Piece % of sheet % already passed QC.', p_piece, p_sheet;
end $$;
revoke all on function qc_record(uuid, uuid, int, int, jsonb, uuid, jsonb) from public, anon;
grant execute on function qc_record(uuid, uuid, int, int, jsonb, uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 3. A job's QC, as the tablet draws it
-- ---------------------------------------------------------------------
-- Each sheet on the current work order: its piece count, its sections (or
-- null: the whole page), how many pieces passed on its drawing, and each
-- piece whose last check sent it back, with which sections passed then.
create or replace function qc_job(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_job jobs;
begin
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null or not sees_lane(v_job.is_test) then raise exception 'That job isn''t in the system.'; end if;
  return jsonb_build_object('ok', true, 'job', v_job.project_id, 'sheets', coalesce((
    select jsonb_agg(jsonb_build_object(
             'sheet', s.sheet_number, 'item', s.item_code, 'qty', s.qty,
             'sections', q.sections,
             'passed', (select count(*) from qc_checks c
                         where c.job_id = p_job and c.sheet_number = s.sheet_number and coalesce(c.spec_hash, '') = coalesce(s.spec_hash, '')
                           and c.result = 'pass' and c.voided_at is null),
             'pieces', coalesce((
               select jsonb_agg(jsonb_build_object('piece', l.piece, 'state', l.result, 'by', l.checked_by_name, 'at', l.checked_at,
                                                   'sections', l.sections) order by l.piece)
                 from (select distinct on (c.piece) c.* from qc_checks c
                        where c.job_id = p_job and c.sheet_number = s.sheet_number and coalesce(c.spec_hash, '') = coalesce(s.spec_hash, '')
                          and c.voided_at is null
                        order by c.piece, c.checked_at desc) l), '[]'::jsonb))
           order by s.sheet_number)
      from sheets s join work_orders w on w.id = s.work_order_id
      left join sheet_qc_sections q on q.sheet_id = s.id
     where w.job_id = p_job and w.is_current), '[]'::jsonb));
end $$;
revoke all on function qc_job(uuid) from public, anon;
grant execute on function qc_job(uuid) to authenticated;

-- "Entered by mistake": a manager takes a check out of the count. It stays, with who and why.
-- A send-back's Failed QC defect is its own entry: mark that one separately if it was a mistake too.
create or replace function qc_void(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v qc_checks;
begin
  if not is_manager() then raise exception 'Only a manager can mark a QC check entered by mistake.' using errcode = 'insufficient_privilege'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Say why it was a mistake.'; end if;
  select * into v from qc_checks where id = p_id;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'There''s no such QC check.'; end if;
  if v.voided_at is not null then return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already marked entered by mistake.'); end if;
  update qc_checks set voided_at = now(), voided_by_name = my_name(), void_reason = left(btrim(p_reason), 300) where id = p_id;
  if v.result = 'pass' and v.spec_hash is not distinct from (qc_current_sheet(v.job_id, v.sheet_number)).spec_hash then
    perform qc_set_count(v.job_id, v.sheet_number,
      (select count(*)::int from qc_checks c where c.job_id = v.job_id and c.sheet_number = v.sheet_number
          and coalesce(c.spec_hash, '') = coalesce(v.spec_hash, '') and c.result = 'pass' and c.voided_at is null), true);
  end if;
  return jsonb_build_object('ok', true, 'summary', format('Piece %s of sheet %s: that check is marked entered by mistake.', v.piece, v.sheet_number));
end $$;
revoke all on function qc_void(uuid, text) from public, anon;
grant execute on function qc_void(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 4. The check
-- ---------------------------------------------------------------------
create or replace function check_qc_checklist()
returns table(step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  res jsonb := '[]'::jsonb;
  mgr uuid := '00000000-0000-4000-8000-00000000c561';
  qc  uuid := '00000000-0000-4000-8000-00000000c562';
  fin uuid := '00000000-0000-4000-8000-00000000c563';
  v_job uuid; v_wo uuid; v_wo2 uuid; s1 uuid; s2 uuid; s3 uuid; v_pid text := 'PROJ-99956';
  p1 uuid := '00000000-0000-4000-8000-0000000c5601'; p2 uuid := '00000000-0000-4000-8000-0000000c5602';
  p3 uuid := '00000000-0000-4000-8000-0000000c5603'; p4 uuid := '00000000-0000-4000-8000-0000000c5604';
  r jsonb; r2 jsonb; ok boolean; msg text; n int; v_def defects;
  all3 jsonb := '[{"n":1,"ok":true},{"n":2,"ok":true},{"n":3,"ok":true}]';
  secs jsonb := '[{"sheet_number":1,"qc_sections":[{"n":1,"x":0.0449,"y":0.2137,"w":0.1088,"h":0.0641},{"n":2,"x":0.1537,"y":0.2137,"w":0.1088,"h":0.0641},{"n":3,"x":0.0449,"y":0.2935,"w":0.2672,"h":0.1922}]},{"sheet_number":2}]';
begin
  -- ---- 1: the two tables: rules on, nobody writes them directly ----------------------------------------
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('sheet_qc_sections', 'qc_checks') and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  ok := n = 0 and (select bool_and(relrowsecurity) from pg_class where oid in ('public.sheet_qc_sections'::regclass, 'public.qc_checks'::regclass));
  res := res || check_row(1, 'QC''s two tables have their security rules on, and no login can write them except through the functions', ok,
                          format('%s write grants found, or a rule is off. Run qc_checklist.sql again.', n));

  -- ---- 2: no function runs without a login; the inside helpers run for nobody --------------------------
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and grantee in ('anon', 'PUBLIC')
     and routine_name in ('set_sheet_qc_sections', 'qc_record', 'qc_job', 'qc_void', 'qc_sections_clean', 'qc_current_sheet', 'qc_photo_path', 'qc_set_count');
  select n + count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and grantee = 'authenticated' and routine_name in ('qc_sections_clean', 'qc_current_sheet', 'qc_photo_path', 'qc_set_count');
  res := res || check_row(2, 'QC''s functions need a login, and its four helpers run only inside them', n = 0,
                          format('%s grants too many. Run qc_checklist.sql again.', n));

  -- ---- 3: Failed QC is on Assembly / QC's list ---------------------------------------------------------
  res := res || check_row(3, '"Failed QC" is on Assembly / QC''s defect list (a send-back logs one)',
    exists (select 1 from defect_types where department = 'assembly_qc' and label = 'Failed QC' and active),
    'It''s missing or retired. In the office: Setup → Defect lists → Assembly / QC → add "Failed QC".');

  begin    -- everything below is undone at the end
    insert into auth.users (id, email) values (mgr, 'check-qc-mgr@example.com'), (qc, 'check-qc-sup@example.com'), (fin, 'check-qc-fin@example.com');
    insert into profiles (id, full_name, role, departments) values (mgr, 'QC check (manager)', 'manager', '{}'),
      (qc, 'QC check', 'supervisor', '{assembly_qc}'), (fin, 'QC check (Finishing)', 'supervisor', '{finishing}');
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999956, v_pid, 'QC checklist check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into v_job;
    insert into work_orders (job_id, version, is_current) values (v_job, 1, true) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, item_code, qty, spec_hash) values (v_wo, 1, 'CT-01', 2, 'hash-a') returning id into s1;
    insert into sheets (work_order_id, sheet_number, item_code, qty, spec_hash) values (v_wo, 2, 'CT-02', 1, 'hash-b') returning id into s2;
    insert into sheets (work_order_id, sheet_number, item_code, qty, spec_hash) values (v_wo, 3, 'CT-03', 3, 'hash-c') returning id into s3;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1, 'assembly_qc', 2, 0), (s2, 'assembly_qc', 1, 0),
      (s3, 'assembly_qc', 3, 2);   -- sheet 3: 2 counted by hand before QC
    insert into storage.objects (bucket_id, name, metadata) values
      ('photos', v_pid || '/' || p1 || '.jpg', '{"size": 1000}'), ('photos', v_pid || '/' || p2 || '.jpg', '{"size": 1000}'),
      ('photos', v_pid || '/' || p3 || '.jpg', '{"size": 1000}'), ('photos', v_pid || '/' || p4 || '.jpg', '{"size": 1000}');

    -- ---- 4: the drop page's save: sections kept as sent, once; a bad one refused --------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := set_sheet_qc_sections(v_wo, secs);
      r2 := set_sheet_qc_sections(v_wo, secs);
      begin perform set_sheet_qc_sections(v_wo, '[{"sheet_number":2,"qc_sections":[{"n":1,"x":0.9,"y":0.1,"w":0.2,"h":0.1}]}]'); msg := 'a section off the page was saved';
      exception when others then msg := null; end;
      execute 'reset role';
      ok := (r ->> 'saved')::int = 1 and (r ->> 'whole_page')::int = 1 and (r2 ->> 'already')::int = 1 and msg is null
            and (select jsonb_array_length(sections) from sheet_qc_sections where sheet_id = s1) = 3
            and not exists (select 1 from sheet_qc_sections where sheet_id = s2);
      msg := coalesce(msg, format('first %s, second %s', r, r2));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'The drop page saves a sheet''s QC sections once; a sheet without them gets the whole page; a section off the page is refused', ok, msg);

    -- ---- 5: only Assembly / QC and managers record a check ------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      begin perform qc_record(gen_random_uuid(), v_job, 1, 1, all3, p1, null); ok := false; msg := 'Finishing recorded a QC check';
      exception when insufficient_privilege then ok := true; msg := null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'A supervisor outside Assembly / QC can''t record a QC check', ok, msg);

    -- ---- 6: a pass, a resend, the same piece again, missing photo, missing section -----------------------
    perform set_config('request.jwt.claims', json_build_object('sub', qc, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := qc_record('00000000-0000-4000-8000-0000000c5611', v_job, 1, 1, all3, p1, null);
      r2 := qc_record('00000000-0000-4000-8000-0000000c5611', v_job, 1, 1, all3, p1, null);
      msg := '';
      begin perform qc_record(gen_random_uuid(), v_job, 1, 1, all3, p1, null); msg := msg || 'piece 1 passed twice; ';
      exception when others then if sqlerrm not like '%already passed QC%' then msg := msg || sqlerrm || '; '; end if; end;
      begin perform qc_record(gen_random_uuid(), v_job, 1, 2, all3, null, null); msg := msg || 'passed with no photo; ';
      exception when others then if sqlerrm not like '%finished photo%' then msg := msg || sqlerrm || '; '; end if; end;
      begin perform qc_record(gen_random_uuid(), v_job, 1, 2, '[{"n":1,"ok":true},{"n":2,"ok":true}]', p2, null); msg := msg || 'a section was skipped; ';
      exception when others then if sqlerrm not like '%match the sheet%' then msg := msg || sqlerrm || '; '; end if; end;
      begin perform qc_record(gen_random_uuid(), v_job, 1, 2, all3, gen_random_uuid(), null); msg := msg || 'a photo that never arrived; ';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then msg := msg || sqlerrm || '; '; end if; end;
      begin perform qc_record(gen_random_uuid(), v_job, 1, 3, all3, p2, null); msg := msg || 'a piece 3 of 2; ';
      exception when others then if sqlerrm not like '%no piece 3%' then msg := msg || sqlerrm || '; '; end if; end;
      execute 'reset role';
      ok := r ->> 'result' = 'pass' and (r ->> 'passed')::int = 1 and (r2 ->> 'already')::boolean and msg = '';
      msg := nullif(msg, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(6, 'Assembly / QC passes piece 1 with its photo; a resend saves nothing new; a second pass, no photo, a skipped section, a missing file and a piece that isn''t there are refused', ok, msg);

    -- ---- 7: a send-back logs Failed QC on the sheet with the words and the photo --------------------------
    begin execute 'set local role authenticated';
      r := qc_record('00000000-0000-4000-8000-0000000c5612', v_job, 1, 2,
                     '[{"n":1,"ok":true},{"n":2,"ok":false,"note":"length is 40 in"},{"n":3,"ok":true}]', null, jsonb_build_array(p3));
      execute 'reset role';
      select * into v_def from defects where id = (r ->> 'defect_id')::uuid;
      ok := r ->> 'result' = 'fail' and v_def.defect_type = 'Failed QC' and v_def.sheet_number = 1 and v_def.department = 'assembly_qc'
            and v_def.note = 'QC, piece 2 of 2: section 2: length is 40 in'
            and exists (select 1 from photos where defect_id = v_def.id and client_id = p3 and kind = 'defect');
      msg := format('%s; defect: %s / %s', r, v_def.defect_type, v_def.note);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'Sending piece 2 back logs a Failed QC defect on sheet 1 with the section, the words and the photo, like any defect', ok, msg);

    -- ---- 8: the tablet's view, then the re-check ---------------------------------------------------------
    begin execute 'set local role authenticated';
      r := qc_job(v_job);
      r2 := qc_record('00000000-0000-4000-8000-0000000c5613', v_job, 1, 2, all3, p4, null);
      execute 'reset role';
      ok := (r #>> '{sheets,0,passed}')::int = 1 and r #>> '{sheets,0,pieces,1,state}' = 'fail'
            and (r #>> '{sheets,0,pieces,1,sections,1,ok}')::boolean = false and jsonb_array_length(r #> '{sheets,0,sections}') = 3
            and r #> '{sheets,1,sections}' = 'null'::jsonb
            and (r2 ->> 'passed')::int = 2
            and (select recheck_of from qc_checks where client_id = '00000000-0000-4000-8000-0000000c5613')
                = (select id from qc_checks where client_id = '00000000-0000-4000-8000-0000000c5612');
      msg := format('view %s; re-check %s', left(r::text, 300), r2);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(8, 'The tablet sees 1 of 2 passed and piece 2 sent back (which sections passed); the re-check passes it, 2 of 2, linked to the send-back', ok, msg);

    -- ---- 9: passing sets Assembly / QC's count: 2 of 2 now; the pass and the send-back counted right ---
    ok := (select qty_done from sheet_progress where sheet_id = s1 and department = 'assembly_qc') = 2;
    res := res || check_row(9, 'Passing QC set sheet 1''s Assembly / QC count to 2 of 2 (the send-back didn''t count; the re-check did)', ok,
                            format('count is %s', (select qty_done from sheet_progress where sheet_id = s1 and department = 'assembly_qc')));

    -- ---- 10: a sheet without sections: one answer for the whole page --------------------------------------
    begin execute 'set local role authenticated';
      msg := '';
      begin perform qc_record(gen_random_uuid(), v_job, 2, 1, all3, p1, null); msg := 'sections accepted on a whole-page sheet; ';
      exception when others then null; end;
      r := qc_record(gen_random_uuid(), v_job, 2, 1, '[{"n":0,"ok":true}]', p2, null);
      execute 'reset role';
      ok := msg = '' and r ->> 'result' = 'pass' and (r ->> 'passed')::int = 1
            and (select qty_done from sheet_progress where sheet_id = s2 and department = 'assembly_qc') = 1;
      msg := nullif(msg || r::text, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(10, 'A sheet with no sections is checked against the whole page, in one answer', ok, msg);

    -- ---- 11: a count made by hand before QC isn't lowered; a pass marked a mistake takes one off -------
    begin execute 'set local role authenticated';
      msg := '';
      perform qc_record(gen_random_uuid(), v_job, 3, 1, '[{"n":0,"ok":true}]', p1, null);
      if (select qty_done from sheet_progress where sheet_id = s3) <> 2 then msg := msg || format('after 1 pass: %s; ', (select qty_done from sheet_progress where sheet_id = s3)); end if;
      perform qc_record(gen_random_uuid(), v_job, 3, 2, '[{"n":0,"ok":true}]', p1, null);
      perform qc_record('00000000-0000-4000-8000-0000000c5633', v_job, 3, 3, '[{"n":0,"ok":true}]', p1, null);
      if (select qty_done from sheet_progress where sheet_id = s3) <> 3 then msg := msg || format('after 3 passes: %s; ', (select qty_done from sheet_progress where sheet_id = s3)); end if;
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform qc_void((select id from qc_checks where client_id = '00000000-0000-4000-8000-0000000c5633'), 'wrong piece');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', qc, 'role', 'authenticated')::text, true);
      if (select qty_done from sheet_progress where sheet_id = s3) <> 2 then msg := msg || format('after the mistake: %s; ', (select qty_done from sheet_progress where sheet_id = s3)); end if;
      ok := msg = ''; msg := nullif(msg, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(11, 'Sheet 3, counted 2 by hand before QC: one pass leaves it at 2, the third pass makes it 3, and that pass marked a mistake takes it back to 2', ok, msg);

    -- ---- 12: a change order: a changed drawing starts again, an unchanged one keeps its QC ---------------
    update work_orders set is_current = false where id = v_wo;
    insert into work_orders (job_id, version, is_current) values (v_job, 2, true) returning id into v_wo2;
    insert into sheets (work_order_id, sheet_number, item_code, qty, spec_hash) values (v_wo2, 1, 'CT-01', 2, 'hash-a2'), (v_wo2, 2, 'CT-02', 1, 'hash-b');
    begin execute 'set local role authenticated';
      r := qc_job(v_job); execute 'reset role';
      ok := (r #>> '{sheets,0,passed}')::int = 0 and (r #>> '{sheets,1,passed}')::int = 1
            and (select count(*) from qc_checks where job_id = v_job) = 7;
      msg := left(r::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(12, 'After a change order, the sheet whose drawing changed starts QC again and the unchanged one keeps its pass; every check is kept', ok, msg);

    -- ---- 13: entered by mistake: managers only, kept, not counted ----------------------------------------
    begin execute 'set local role authenticated';
      begin perform qc_void((select id from qc_checks where job_id = v_job and sheet_number = 2), 'test'); msg := 'a supervisor marked it';
      exception when insufficient_privilege then msg := null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := qc_void((select id from qc_checks where job_id = v_job and sheet_number = 2), 'tapped the wrong sheet');
      r2 := qc_job(v_job);
      execute 'reset role';
      ok := msg is null and (r2 #>> '{sheets,1,passed}')::int = 0 and (select count(*) from qc_checks where job_id = v_job) = 7;
      msg := coalesce(msg, left(r2::text, 300));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(13, 'Only a manager marks a check entered by mistake; it''s kept but no longer counted', ok, msg);

    -- ---- 14: nobody writes the tables directly ------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', qc, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      begin
        insert into qc_checks (client_id, job_id, sheet_number, sheet_id, piece, result, sections, finished_photo_path)
        values (gen_random_uuid(), v_job, 1, s1, 2, 'pass', '[]', 'x'); ok := false; msg := 'a supervisor wrote a pass straight into qc_checks';
      exception when insufficient_privilege then ok := true; msg := null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(14, 'A login can''t write a QC pass straight into the table', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_qc_checklist_undo__';
  exception when others then
    begin execute 'reset role'; exception when others then null; end;
    if sqlerrm <> '__check_qc_checklist_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_qc_checklist() from public, anon, authenticated;

select * from check_qc_checklist();
