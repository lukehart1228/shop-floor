-- =====================================================================
-- arrow_pos.sql — Arrow POs made by the app, and split runs (1 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 51. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE the new pages go on GitHub. The pages there now keep
-- working with it: v_outside_jobs only gains columns at its end.
--
-- WHAT IT DOES (design: the Arrow POs tab, 30–31 Oct)
-- 1. sheet_arrow_lines: each sheet's Arrow lines (qty, base, description,
--    PD colour, Arrow colour) from the upload file, saved by the drop page
--    through set_sheet_arrow(). Never typed or edited in the app. Only
--    managers read the table; the floor sees counts, and the lines only
--    on the PO it makes.
-- 2. arrow_po_settings: the next PO number (AR-10 to start; set at go-live),
--    and what the PO prints about the issuer (name, phone, email, address,
--    the tax-exempt line). Kept here, never in a page file (the repo is
--    public). Managers set it from the office.
-- 3. arrow_pos: every PO, its number, the jobs, its file name and the
--    lines exactly as printed. Nothing is deleted.
-- 4. Split runs: outside_jobs gains po_id, run_of and arrow_qty. When a
--    PO takes part of an item (7 of 15 pedestals), the 7 become a new row
--    that has gone (run_of = the item); the item stays waiting with 8
--    left. When a PO takes the rest, the item itself goes. So every page
--    that shows Arrow items shows runs, and Returned works per run.
-- 5. arrow_po_make(): tick what's going, how many of each line; one call
--    marks it gone and makes the PO across jobs. Safe to resend.
-- 6. v_outside_jobs gains, at its end, the PO, run_of and each line's
--    counts (what this row holds, of how many).
-- 7. The office's save files each PO as a PDF in Claudes Shop System
--    Folder › Arrow: arrow_pos_to_file(), record_arrow_po_filed().
-- Nothing existing changes meaning, and nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('arrow_pos.sql', 51, 'check_arrow_pos', 'check_arrow_pos', '{arrow_pickup.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('arrow_pos.sql', '{arrow_pickup.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.arrow_gone(uuid[],date)') is null then raise exception 'Run arrow_pickup.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.can_upload_work_orders()') is null then raise exception 'Run the earlier files first (upload_work_order).'; end if;
  if to_regprocedure('public.check_row(integer,text,boolean,text)') is null then raise exception 'Run check_floor.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Each sheet's Arrow lines, from the upload file
-- ---------------------------------------------------------------------

create table if not exists sheet_arrow_lines (
  work_order_id uuid not null references work_orders(id),
  sheet_number  int  not null,
  position      int  not null,
  qty           int  not null,
  base          text not null,
  description   text not null,
  pd_color      text not null,
  arrow_color   text not null,
  saved_at      timestamptz not null default now(),
  primary key (work_order_id, sheet_number, position),
  constraint sheet_arrow_lines_qty  check (qty between 1 and 100000),
  constraint sheet_arrow_lines_text check (length(base) between 1 and 200 and length(description) between 1 and 200
                                           and length(pd_color) between 1 and 200 and length(arrow_color) between 1 and 200)
);
alter table sheet_arrow_lines enable row level security;
revoke all on sheet_arrow_lines from anon, authenticated;
grant select on sheet_arrow_lines to authenticated;
drop policy if exists sheet_arrow_lines_office on sheet_arrow_lines;
create policy sheet_arrow_lines_office on sheet_arrow_lines for select to authenticated using (is_manager());

-- which work orders listed their Arrow lines (an empty list counts: "nothing on this work order goes to Arrow")
create table if not exists work_order_arrow (
  work_order_id uuid primary key references work_orders(id),
  lines         int  not null,
  saved_at      timestamptz not null default now(),
  saved_by      uuid references profiles(id)
);
alter table work_order_arrow enable row level security;
revoke all on work_order_arrow from anon, authenticated;
grant select on work_order_arrow to authenticated;
drop policy if exists work_order_arrow_office on work_order_arrow;
create policy work_order_arrow_office on work_order_arrow for select to authenticated using (is_manager());

-- the drop page, straight after loading the floor: [{sheet_number, arrow: [{qty, base, description, pd_color, arrow_color}]}]
create or replace function set_sheet_arrow(p_work_order uuid, p_sheets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s jsonb; a jsonb; i int; n int := 0; v_num int;
begin
  if not (is_manager() or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'))) then   -- the drop page (a manager), or the SQL Editor
    raise exception 'Only a manager login can save Arrow lines.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from work_orders where id = p_work_order) then raise exception 'There''s no such work order.'; end if;
  if exists (select 1 from work_order_arrow where work_order_id = p_work_order) then
    return jsonb_build_object('ok', true, 'already', true, 'lines', (select lines from work_order_arrow where work_order_id = p_work_order));
  end if;
  if jsonb_typeof(p_sheets) is distinct from 'array' then raise exception 'Send each sheet''s arrow list.'; end if;
  for s in select * from jsonb_array_elements(p_sheets) loop
    v_num := (s ->> 'sheet_number')::int;
    if not exists (select 1 from sheets where work_order_id = p_work_order and sheet_number = v_num) then
      raise exception 'Sheet % isn''t on that work order.', coalesce(s ->> 'sheet_number', '?');
    end if;
    if jsonb_typeof(s -> 'arrow') is distinct from 'array' then raise exception 'Sheet % has no arrow list.', v_num; end if;
    i := 0;
    for a in select * from jsonb_array_elements(s -> 'arrow') loop
      i := i + 1;
      if jsonb_typeof(a -> 'qty') is distinct from 'number' or (a ->> 'qty')::numeric < 1 or (a ->> 'qty')::numeric <> floor((a ->> 'qty')::numeric) then
        raise exception 'Sheet %: an Arrow line''s qty should be a whole number, 1 or more.', v_num;
      end if;
      insert into sheet_arrow_lines (work_order_id, sheet_number, position, qty, base, description, pd_color, arrow_color)
      values (p_work_order, v_num, i, (a ->> 'qty')::int, btrim(a ->> 'base'), btrim(a ->> 'description'), btrim(a ->> 'pd_color'), btrim(a ->> 'arrow_color'));
      n := n + 1;
    end loop;
  end loop;
  insert into work_order_arrow (work_order_id, lines, saved_by) values (p_work_order, n, auth.uid());
  return jsonb_build_object('ok', true, 'lines', n);
exception when not_null_violation or check_violation then
  raise exception 'An Arrow line is missing its base, description or a colour, or one is over 200 letters.';
end $$;
revoke all on function set_sheet_arrow(uuid, jsonb) from public, anon;
grant execute on function set_sheet_arrow(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 2. The PO's own details, and the numbers
-- ---------------------------------------------------------------------

create table if not exists arrow_po_settings (
  id            boolean primary key default true check (id),
  next_number   int  not null default 10,
  next_test     int  not null default 1,
  issued_by     text,
  phone         text,
  email         text,
  address       text,      -- a few lines: the company name, street, city, website
  tax_line      text,      -- printed under the lines, e.g. the tax-exempt sentence
  updated_at    timestamptz,
  updated_by    uuid references profiles(id),
  constraint arrow_po_settings_len check (length(coalesce(issued_by, '')) <= 80 and length(coalesce(phone, '')) <= 40
         and length(coalesce(email, '')) <= 120 and length(coalesce(address, '')) <= 400 and length(coalesce(tax_line, '')) <= 200)
);
insert into arrow_po_settings (id) values (true) on conflict (id) do nothing;
alter table arrow_po_settings enable row level security;
revoke all on arrow_po_settings from anon, authenticated;

-- who makes POs: managers and the Arrow departments (Metal, Assembly / QC, Delivery)
create or replace function arrow_po_maker() returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() is not null and (is_manager() or exists (select 1 from unnest(arrow_departments()) d where owns_dept(d)));
$$;
revoke all on function arrow_po_maker() from public, anon;
grant execute on function arrow_po_maker() to authenticated;

create or replace function arrow_po_settings_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not arrow_po_maker() then raise exception 'Only the Arrow departments and the office see the PO details.' using errcode = 'insufficient_privilege'; end if;
  return (select jsonb_build_object('next_number', s.next_number, 'issued_by', s.issued_by, 'phone', s.phone, 'email', s.email,
                                    'address', s.address, 'tax_line', s.tax_line, 'ready', nullif(btrim(coalesce(s.issued_by, '')), '') is not null,
                                    'last_number', (select max(po_number) from arrow_pos where not is_test))
            from arrow_po_settings s);
end $$;
revoke all on function arrow_po_settings_get() from public, anon;
grant execute on function arrow_po_settings_get() to authenticated;

-- managers: the details, and the next number (never one already used)
create or replace function set_arrow_po_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_next int; v_max int;
begin
  if not office_ok() then raise exception 'Only a manager sets the PO details.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Send the details.'; end if;
  select max(po_number) into v_max from arrow_pos where not is_test;
  if p ? 'next_number' then
    v_next := (p ->> 'next_number')::int;
    if v_next is null or v_next < 1 or v_next > 999999 then raise exception 'The next PO number should be a whole number.'; end if;
    if v_next <= coalesce(v_max, 0) then raise exception 'AR-% is already used. The next number has to be higher.', v_max; end if;
  end if;
  update arrow_po_settings set
    next_number = coalesce(v_next, next_number),
    issued_by   = case when p ? 'issued_by' then nullif(btrim(p ->> 'issued_by'), '') else issued_by end,
    phone       = case when p ? 'phone'     then nullif(btrim(p ->> 'phone'), '')     else phone end,
    email       = case when p ? 'email'     then nullif(btrim(p ->> 'email'), '')     else email end,
    address     = case when p ? 'address'   then nullif(btrim(p ->> 'address'), '')   else address end,
    tax_line    = case when p ? 'tax_line'  then nullif(btrim(p ->> 'tax_line'), '')  else tax_line end,
    updated_at = now(), updated_by = auth.uid();
  return jsonb_build_object('ok', true);
exception when check_violation then raise exception 'One of the details is too long.';
end $$;
revoke all on function set_arrow_po_settings(jsonb) from public, anon;
grant execute on function set_arrow_po_settings(jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 3. The POs
-- ---------------------------------------------------------------------

create table if not exists arrow_pos (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null unique,
  po_number      int  not null,
  is_test        boolean not null default false,
  name           text not null,                 -- AR-10 (AR-T1 on the test lane)
  file_name      text not null,                 -- AR-10(99,418,451-1).pdf
  gone_on        date not null,
  jobs           text[] not null,
  header         jsonb not null,                -- what it printed about the issuer and dates
  lines          jsonb not null,                -- the lines as printed, in order
  made_at        timestamptz not null default now(),
  made_by        uuid references profiles(id),
  made_by_name   text,
  onedrive_bytes bigint, onedrive_at timestamptz,
  backup_bytes   bigint, backup_at   timestamptz,
  constraint arrow_pos_number unique (is_test, po_number)
);
alter table arrow_pos enable row level security;
revoke all on arrow_pos from anon, authenticated;
grant select on arrow_pos to authenticated;
drop policy if exists arrow_pos_read on arrow_pos;
create policy arrow_pos_read on arrow_pos for select to authenticated using (arrow_po_maker() and sees_lane(is_test));


-- ---------------------------------------------------------------------
-- 4. Runs: outside_jobs gains three columns
--    arrow_qty: [{sheet, pos, qty}] what this row holds; null = all of its sheets' lines
-- ---------------------------------------------------------------------

alter table outside_jobs add column if not exists po_id     uuid references arrow_pos(id);
alter table outside_jobs add column if not exists run_of    uuid references outside_jobs(id);
alter table outside_jobs add column if not exists arrow_qty jsonb;

-- an item's lines on its job's current work order: [{sheet, pos, total, holds}] (never the line's text)
create or replace function arrow_item_counts(p_job uuid, p_sheets int[], p_qty jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('sheet', l.sheet_number, 'pos', l.position, 'total', l.qty,
           'holds', coalesce((select (x ->> 'qty')::int from jsonb_array_elements(p_qty) x
                               where (x ->> 'sheet')::int = l.sheet_number and (x ->> 'pos')::int = l.position),
                             case when p_qty is null then l.qty else 0 end))
           order by l.sheet_number, l.position), '[]'::jsonb)
    from sheet_arrow_lines l
    join work_orders w on w.id = l.work_order_id and w.is_current and w.job_id = p_job
   where l.sheet_number = any(coalesce(p_sheets, '{}'));
$$;
revoke all on function arrow_item_counts(uuid, int[], jsonb) from public, anon, authenticated;

-- the same for one row the caller can see (the view below runs as the caller)
create or replace function arrow_item_counts_for(p_item uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select arrow_item_counts(o.job_id, o.sheet_numbers, o.arrow_qty) from outside_jobs o where o.id = p_item and sees_lane(o.is_test);
$$;
revoke all on function arrow_item_counts_for(uuid) from public, anon;
grant execute on function arrow_item_counts_for(uuid) to authenticated;

-- the Arrow list, with the PO, the run and the counts added at the end (columns before them unchanged)
create or replace view v_outside_jobs with (security_invoker = true) as
select o.id, o.job_id, j.project_id, j.name as job_name, o.sheet_numbers, o.description, o.vendor, o.service,
       o.department, d.name as department_name, o.is_test, o.sent_on, o.sent_by, o.sent_by_name,
       o.returned_on, o.returned_by_name, (o.voided_at is not null) as voided, o.void_reason,
       (o.returned_on is null and o.voided_at is null) as at_vendor,
       coalesce(o.returned_on, local_today()) - o.sent_on as days_out,
       o.waiting and o.returned_on is null and o.voided_at is null as waiting,
       o.queued_on, o.queued_by_name, o.gone_by_name, o.gone_at,
       exists (select 1 from sheet_sends ss where ss.outside_job_id = o.id and ss.undone_at is null) as from_send,
       o.po_id, p.name as po_name, o.run_of,
       arrow_item_counts_for(o.id) as arrow_counts
from outside_jobs o
join jobs j        on j.id = o.job_id
join departments d on d.key = o.department
left join arrow_pos p on p.id = o.po_id;
revoke all on v_outside_jobs from anon;
grant select on v_outside_jobs to authenticated;


-- ---------------------------------------------------------------------
-- 5. Making the PO. p_items: [{id, lines: [{sheet, pos, qty}]}]. An item
--    with Arrow lines says how many of each are going (0 to what's left);
--    an item without (sent by hand, or from before the lines existed)
--    goes whole and prints with base and colour blank. Returns the PO.
-- ---------------------------------------------------------------------

create or replace function arrow_colour_rank(p_colour text) returns int
language sql immutable as $$
  select case when lower(btrim(coalesce(p_colour, ''))) = '' then 4
              when lower(btrim(p_colour)) in ('denim black', 'black') then 0
              when lower(btrim(p_colour)) = 'stardust silver' then 1
              when lower(btrim(p_colour)) like 'custom%' then 3 else 2 end;
$$;
revoke all on function arrow_colour_rank(text) from public, anon;
grant execute on function arrow_colour_rank(text) to authenticated;

create or replace function arrow_po_make(p_client_id uuid, p_gone_on date, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_on date := coalesce(p_gone_on, local_today()); st arrow_po_settings; v_po uuid := gen_random_uuid();
  it jsonb; v outside_jobs; c jsonb; ln jsonb; want int; v_left int; v_take jsonb; v_rest jsonb; v_all boolean; v_any boolean;
  v_test boolean := null; v_num int; v_name text; v_file text; v_jobs text[]; v_lines jsonb := '[]'; v_header jsonb;
  v_run uuid; n_items int := 0; k int; v_tag text; v_tags text[] := '{}'; pj text;
  v_go jsonb := '[]';                       -- [{row, take, whole}] decided first, written after the checks
begin
  if not arrow_po_maker() then raise exception 'Only Metal, Assembly / QC, Delivery or the office make Arrow POs.' using errcode = 'insufficient_privilege'; end if;
  if p_client_id is null then raise exception 'The tablet sent no id for this PO. Try again.'; end if;
  if exists (select 1 from arrow_pos where client_id = p_client_id) then          -- sent twice (no signal, then a retry): the same PO
    return (select jsonb_build_object('ok', true, 'already', true, 'id', id, 'name', name, 'file_name', file_name, 'gone_on', gone_on,
                                      'jobs', to_jsonb(jobs), 'header', header, 'lines', lines) from arrow_pos where client_id = p_client_id);
  end if;
  if v_on > local_today() then raise exception 'The day it went can''t be in the future.'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Tick what''s going to Arrow.'; end if;
  select * into st from arrow_po_settings for update;
  if nullif(btrim(coalesce(st.issued_by, '')), '') is null then
    raise exception 'The office hasn''t filled in the PO details yet (office → Arrow → PO details). Nothing was marked gone.';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    select * into v from outside_jobs where id = (it ->> 'id')::uuid for update;
    if v.id is null or not sees_lane(v.is_test) then raise exception 'That Arrow item isn''t there.'; end if;
    if not is_manager() and v.is_test <> am_test() then raise exception 'That item is in the other lane.' using errcode = 'insufficient_privilege'; end if;
    if v.voided_at is not null then raise exception 'One of those was taken off the list (entered by mistake, or its send was undone).'; end if;
    if not v.waiting or v.returned_on is not null then raise exception 'One of those has already gone to Arrow. Reload the list.'; end if;
    if v_on < coalesce(v.queued_on, v.sent_on) then raise exception 'It can''t go before Metal sent it on (%).', to_char(coalesce(v.queued_on, v.sent_on), 'Mon FMDD'); end if;
    if v_test is null then v_test := v.is_test; elsif v_test <> v.is_test then raise exception 'Test items and real items go on separate POs.'; end if;
    c := arrow_item_counts(v.job_id, v.sheet_numbers, v.arrow_qty);
    v_take := '[]'; v_rest := '[]'; v_all := true; v_any := false;
    for ln in select * from jsonb_array_elements(c) loop
      v_left := (ln ->> 'holds')::int;
      select (x ->> 'qty')::int into want from jsonb_array_elements(coalesce(it -> 'lines', '[]')) x
       where (x ->> 'sheet')::int = (ln ->> 'sheet')::int and (x ->> 'pos')::int = (ln ->> 'pos')::int;
      want := coalesce(want, v_left);                                      -- not said: all that's left
      if want < 0 or want > v_left then raise exception 'Only % of that line are left to go (sheet %).', v_left, ln ->> 'sheet'; end if;
      if want > 0 then v_take := v_take || jsonb_build_object('sheet', (ln ->> 'sheet')::int, 'pos', (ln ->> 'pos')::int, 'qty', want); v_any := true; end if;
      if v_left - want > 0 then v_rest := v_rest || jsonb_build_object('sheet', (ln ->> 'sheet')::int, 'pos', (ln ->> 'pos')::int, 'qty', v_left - want); v_all := false; end if;
    end loop;
    if jsonb_array_length(c) > 0 and not v_any then raise exception 'Say how many are going (sheet %).', array_to_string(v.sheet_numbers, ', '); end if;
    v_go := v_go || jsonb_build_object('row', v.id, 'take', case when jsonb_array_length(c) > 0 then v_take end, 'rest', v_rest, 'whole', v_all);
    n_items := n_items + 1;
  end loop;

  -- the number
  if v_test then v_num := st.next_test; update arrow_po_settings set next_test = next_test + 1; v_name := 'AR-T' || v_num;
  else v_num := st.next_number; update arrow_po_settings set next_number = next_number + 1; v_name := 'AR-' || v_num; end if;
  insert into arrow_pos (id, client_id, po_number, is_test, name, file_name, gone_on, jobs, header, lines, made_by, made_by_name)
  values (v_po, p_client_id, v_num, v_test, v_name, v_name || '.pdf', v_on, '{}', '{}', '[]', auth.uid(), my_name());

  -- mark it gone: the whole item, or a new run row for the part that's going
  for it in select * from jsonb_array_elements(v_go) loop
    select * into v from outside_jobs where id = (it ->> 'row')::uuid;
    if (it ->> 'whole')::boolean then
      update outside_jobs set waiting = false, sent_on = v_on, gone_by_name = my_name(), gone_at = now(), po_id = v_po,
                              arrow_qty = case when it -> 'take' is not null and jsonb_typeof(it -> 'take') = 'array' then it -> 'take' else arrow_qty end
       where id = v.id;
    else
      insert into outside_jobs (job_id, sheet_numbers, description, vendor, service, department, is_test, sent_on, sent_by, sent_by_name,
                                waiting, queued_on, queued_by_name, gone_by_name, gone_at, po_id, run_of, arrow_qty)
      values (v.job_id, v.sheet_numbers, v.description, v.vendor, v.service, v.department, v.is_test, v_on, v.sent_by, v.sent_by_name,
              false, coalesce(v.queued_on, v.sent_on), v.queued_by_name, my_name(), now(), v_po, v.id, it -> 'take');
      update outside_jobs set arrow_qty = it -> 'rest' where id = v.id;
    end if;
  end loop;

  -- the lines, as printed: one per job, base and colours (merged); an item without lines by job and item, blanks for a pen
  with went as (
    select o.*, j.project_id from outside_jobs o join jobs j on j.id = o.job_id where o.po_id = v_po),
  lined as (
    select w.project_id, l.base, l.description, l.pd_color, l.arrow_color, sum((x ->> 'qty')::int) as qty
      from went w
      cross join lateral jsonb_array_elements(coalesce(w.arrow_qty, '[]')) x
      join work_orders wo on wo.job_id = w.job_id and wo.is_current
      join sheet_arrow_lines l on l.work_order_id = wo.id and l.sheet_number = (x ->> 'sheet')::int and l.position = (x ->> 'pos')::int
     group by w.project_id, l.base, l.description, l.pd_color, l.arrow_color),
  bare as (
    select w.project_id, ''::text as base,
           coalesce(nullif(btrim(w.description), ''),
                    'Item ' || coalesce((select string_agg(distinct s.item_code, ', ') from sheets s join work_orders wo on wo.id = s.work_order_id and wo.is_current
                                          where wo.job_id = w.job_id and s.sheet_number = any(w.sheet_numbers)), '')
                    || ' (sheet' || case when cardinality(w.sheet_numbers) = 1 then ' ' else 's ' end || array_to_string(w.sheet_numbers, ', ') || ')') as description,
           ''::text as pd_color, ''::text as arrow_color, null::int as qty
      from went w where jsonb_array_length(arrow_item_counts(w.job_id, w.sheet_numbers, null)) = 0)
  select coalesce(jsonb_agg(jsonb_build_object('qty', x.qty, 'base', x.base, 'description', x.description, 'pd_color', x.pd_color,
                                               'arrow_color', x.arrow_color, 'project', x.project_id)
                            order by arrow_colour_rank(x.pd_color), lower(x.pd_color), x.project_id, x.base, x.description), '[]')
    into v_lines from (select * from lined union all select * from bare) x;

  -- the jobs, in number order, as Luke writes them (PROJ-00418 → 418); -1, -2… when a job goes in more than one run
  for pj in select distinct j.project_id from outside_jobs o join jobs j on j.id = o.job_id where o.po_id = v_po order by 1 loop
    v_jobs := coalesce(v_jobs, '{}') || pj;
    select count(distinct o.po_id) into k from outside_jobs o join jobs j on j.id = o.job_id
     where j.project_id = pj and o.po_id is not null and o.voided_at is null;
    v_tag := ltrim(regexp_replace(pj, '^[A-Z]+-', ''), '0');
    if k > 1 or exists (select 1 from outside_jobs o join jobs j on j.id = o.job_id
                         where j.project_id = pj and o.waiting and o.returned_on is null and o.voided_at is null and o.is_test = v_test) then
      v_tag := v_tag || '-' || k;
    end if;
    v_tags := v_tags || v_tag;
  end loop;
  v_file := v_name || '(' || array_to_string(v_tags, ',') || ').pdf';
  v_header := jsonb_build_object('issued_by', st.issued_by, 'phone', st.phone, 'email', st.email, 'address', st.address, 'tax_line', st.tax_line,
                                 'date_issued', v_on, 'date_required', v_on + 7, 'to', 'Arrow Powdercoating', 'ship_to', 'Pickup',
                                 'how_shipped', 'Delivered by PD', 'po_jobs', array_to_string(v_tags, ', '));
  update arrow_pos set jobs = v_jobs, file_name = v_file, header = v_header, lines = v_lines where id = v_po;
  return jsonb_build_object('ok', true, 'id', v_po, 'name', v_name, 'file_name', v_file, 'gone_on', v_on, 'jobs', to_jsonb(v_jobs),
                            'header', v_header, 'lines', v_lines, 'items', n_items,
                            'summary', format('%s made: %s. Gone to Arrow %s.', v_name, array_to_string(v_tags, ', '),
                                              case when v_on = local_today() then 'today' else to_char(v_on, 'Mon FMDD') end));
end $$;
revoke all on function arrow_po_make(uuid, date, jsonb) from public, anon;
grant execute on function arrow_po_make(uuid, date, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 6. The office's save files each real PO as a PDF in Claudes Shop System
--    Folder › Arrow, and the backup's copy of that folder.
-- ---------------------------------------------------------------------

create or replace function arrow_pos_to_file() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager can save the shop floor''s files.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'file_name', file_name, 'gone_on', gone_on, 'jobs', to_jsonb(jobs),
                                                       'header', header, 'lines', lines, 'onedrive_bytes', onedrive_bytes, 'backup_bytes', backup_bytes)
                                    order by po_number)
                     from arrow_pos where not is_test and (onedrive_at is null or backup_at is null)), '[]'::jsonb);
end $$;
revoke all on function arrow_pos_to_file() from public, anon;
grant execute on function arrow_pos_to_file() to authenticated;

create or replace function record_arrow_po_filed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not office_ok() or auth.uid() is null then raise exception 'Only a manager''s office page reports filed POs.' using errcode = 'insufficient_privilege'; end if;
  if jsonb_typeof(p) is distinct from 'array' or jsonb_array_length(p) > 1000 then raise exception 'Send a list of 1,000 or fewer.'; end if;
  -- one update per place: an update joined to two rows for the same PO would apply only one of them
  update arrow_pos a set onedrive_bytes = x.bytes, onedrive_at = now()
    from (select distinct on (id) id, bytes from jsonb_to_recordset(p) as y(id uuid, place text, bytes bigint) where place = 'onedrive' and bytes > 0) x
   where a.id = x.id and not a.is_test;
  get diagnostics n = row_count;
  update arrow_pos a set backup_bytes = x.bytes, backup_at = now()
    from (select distinct on (id) id, bytes from jsonb_to_recordset(p) as y(id uuid, place text, bytes bigint) where place = 'backup' and bytes > 0) x
   where a.id = x.id and not a.is_test;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function record_arrow_po_filed(jsonb) from public, anon;
grant execute on function record_arrow_po_filed(jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 7. The check. Its own two jobs, work orders and Arrow items, as a
--    manager, Metal's supervisor and a Sanding supervisor signed in;
--    the PO numbers and details are put back as they were.
-- ---------------------------------------------------------------------

create or replace function check_arrow_pos()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]'; mgr uuid; met uuid; san uuid; as_mgr text; as_met text; as_san text;
  j1 uuid; j2 uuid; w1 uuid; w2 uuid; a1 uuid; a2 uuid; a3 uuid; v jsonb; v2 jsonb; cid uuid := gen_random_uuid();
  st arrow_po_settings; n int; ok boolean; msg text; t record; r record; num int;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test limit 1;
  select p.id into met from profiles p where p.role = 'supervisor' and p.active and not p.is_test and 'metal' = any(p.departments) limit 1;
  select p.id into san from profiles p where p.role = 'supervisor' and p.active and not p.is_test
     and not (p.departments && arrow_departments()) limit 1;
  if mgr is null or met is null or san is null then
    res := res || check_row(1, 'A manager, Metal''s supervisor and another supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_met := json_build_object('sub', met, 'role', 'authenticated')::text;
  as_san := json_build_object('sub', san, 'role', 'authenticated')::text;

  -- ---- 1. tables locked -----------------------------------------------------
  ok := true;
  for t in select x.tb from unnest(array['public.sheet_arrow_lines', 'public.work_order_arrow', 'public.arrow_po_settings', 'public.arrow_pos']) x(tb) loop
    ok := ok and (select relrowsecurity from pg_class where oid = t.tb::regclass)
             and not has_table_privilege('authenticated', t.tb, 'insert') and not has_table_privilege('authenticated', t.tb, 'update')
             and not has_table_privilege('authenticated', t.tb, 'delete') and not has_table_privilege('anon', t.tb, 'select');
  end loop;
  ok := ok and not has_table_privilege('authenticated', 'public.arrow_po_settings', 'select');
  res := res || check_row(1, 'The four tables have row-level security and no login writes them directly; the PO details are read only through a function', ok,
    'A table can be written directly or read where it shouldn''t. Run arrow_pos.sql again.');

  -- ---- 2. functions need a login --------------------------------------------
  ok := true; msg := null;
  for t in select x.f from unnest(array['set_sheet_arrow(uuid,jsonb)', 'arrow_po_maker()', 'arrow_po_settings_get()', 'set_arrow_po_settings(jsonb)',
         'arrow_item_counts_for(uuid)', 'arrow_po_make(uuid,date,jsonb)', 'arrow_pos_to_file()', 'record_arrow_po_filed(jsonb)']) x(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then ok := false; msg := concat_ws(' ', msg, t.f); end if;
  end loop;
  ok := ok and not has_function_privilege('authenticated', 'public.arrow_item_counts(uuid,integer[],jsonb)', 'execute');
  res := res || check_row(2, 'Its functions need a login; the inside helper is closed to logins', ok, coalesce('Missing, or open to no login: ' || msg, 'arrow_item_counts is open to logins.'));

  select * into st from arrow_po_settings;
  begin
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999971, 'PROJ-99971', 'Arrow PO check - undone automatically', true, 'In Production') returning id into j1;
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999972, 'PROJ-99972', 'Arrow PO check 2 - undone automatically', true, 'In Production') returning id into j2;
    insert into work_orders (job_id, is_current) values (j1, true) returning id into w1;
    insert into work_orders (job_id, is_current) values (j2, true) returning id into w2;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w1, 1, 15, 'PD-01'), (w2, 1, 2, 'TB-01'), (w2, 2, 1, 'TB-02');
    update arrow_po_settings set issued_by = null, next_number = 9000;

    -- ---- 3. the lines: only a manager saves them, once per work order -----------
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": []}]');
      execute 'reset role'; ok := false; msg := 'Metal''s supervisor saved Arrow lines.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": [{"qty": 15, "base": "JESS", "description": "Pedestal Base, Round Disc, 3.5\" Post", "pd_color": "Stardust Silver", "arrow_color": "RAL 9006 White Aluminum"}]}]');
      v2 := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": []}]');
      v := set_sheet_arrow(w2, '[{"sheet_number": 1, "arrow": [{"qty": 4, "base": "DAN", "description": "Angled Post Leg", "pd_color": "Denim Black", "arrow_color": "PCU90229 Denim Black"}, {"qty": 2, "base": "BEN", "description": "Inverted Trapezoid Leg", "pd_color": "Bronze", "arrow_color": "38/60080 Bronze"}]}, {"sheet_number": 2, "arrow": []}]');
      execute 'reset role';
      ok := ok and (v2 ->> 'already')::boolean and (select count(*) from sheet_arrow_lines where work_order_id in (w1, w2)) = 3;
      if not ok and msg is null then msg := 'The lines weren''t saved once each: ' || v2::text; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'Only a manager saves a work order''s Arrow lines, and only once (a resend changes nothing)', ok, msg);

    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j1, '{1}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a1;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j2, '{1}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a2;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j2, '{2}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a3;

    -- ---- 4. details first; a supervisor can't set them; the number never goes back ---------
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := arrow_po_make(cid, null, jsonb_build_array(jsonb_build_object('id', a2)));
      execute 'reset role'; ok := false; msg := 'A PO was made with no issuer filled in.';
    exception when others then execute 'reset role'; ok := sqlerrm like '%PO details%'; msg := 'Unexpected: ' || sqlerrm; end;
    begin
      execute 'set local role authenticated';
      v := set_arrow_po_settings('{"issued_by": "X"}');
      execute 'reset role'; ok := false; msg := 'Metal''s supervisor set the PO details.';
    exception when insufficient_privilege then execute 'reset role';
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := set_arrow_po_settings('{"issued_by": "Check Issuer", "phone": "000", "email": "check@example.com", "tax_line": "Check line", "next_number": 9000}');
      execute 'reset role';
      ok := ok and (select issued_by from arrow_po_settings) = 'Check Issuer' and (select count(*) from outside_jobs where id in (a1, a2, a3) and waiting) = 3;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'No PO until the office fills in the details (nothing is marked gone); only a manager fills them in', ok, msg);

    -- ---- 5. a PO across two jobs: 7 of 15 pedestals (a run), and the other job whole ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := arrow_po_make(cid, null, jsonb_build_array(
             jsonb_build_object('id', a1, 'lines', jsonb_build_array(jsonb_build_object('sheet', 1, 'pos', 1, 'qty', 7))),
             jsonb_build_object('id', a2), jsonb_build_object('id', a3)));
      execute 'reset role';
      select * into r from outside_jobs where run_of = a1;
      ok := v ->> 'name' = 'AR-9000' and v ->> 'file_name' = 'AR-9000(99971-1,99972).pdf'
        and r.id is not null and not r.waiting and r.po_id = (v ->> 'id')::uuid and r.arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 7}]'::jsonb
        and (select waiting and arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 8}]'::jsonb and po_id is null from outside_jobs where id = a1)
        and (select count(*) from outside_jobs where id in (a2, a3) and not waiting and po_id = (v ->> 'id')::uuid) = 2;
      msg := 'The PO, its file name or the runs are wrong: ' || left(v::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'One PO across jobs: 7 of 15 go as a run of their own, 8 stay waiting; the file is named AR-n(99971-1,99972)', ok, msg);

    -- ---- 6. the lines as printed: Denim Black first, then Stardust Silver; an item without lines by item, blanks for a pen ---
    ok := jsonb_array_length(v -> 'lines') = 4
      and v #>> '{lines,0,pd_color}' = 'Denim Black' and (v #>> '{lines,0,qty}')::int = 4 and v #>> '{lines,0,project}' = 'PROJ-99972'
      and v #>> '{lines,1,pd_color}' = 'Stardust Silver' and (v #>> '{lines,1,qty}')::int = 7 and v #>> '{lines,1,base}' = 'JESS'
      and v #>> '{lines,2,pd_color}' = 'Bronze' and (v #>> '{lines,2,qty}')::int = 2
      and v #>> '{lines,3,pd_color}' = '' and v #>> '{lines,3,description}' = 'Item TB-02 (sheet 2)' and v #> '{lines,3,qty}' = 'null'::jsonb
      and v #>> '{header,issued_by}' = 'Check Issuer' and v #>> '{header,date_required}' = to_char(local_today() + 7, 'YYYY-MM-DD');
    res := res || check_row(6, 'The lines: grouped by colour (Denim Black, Stardust Silver, the rest, Custom, then blanks), merged, as the upload file spelled them', ok,
      'The lines are in the wrong order or wrong: ' || left((v -> 'lines')::text, 400));

    -- ---- 7. sent twice (no signal): the same PO, nothing doubled; Sanding can't make one ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v2 := arrow_po_make(cid, null, jsonb_build_array(jsonb_build_object('id', a1)));
      execute 'reset role';
      ok := (v2 ->> 'already')::boolean and v2 ->> 'name' = 'AR-9000' and (select count(*) from arrow_pos where client_id = cid) = 1
            and (select count(*) from outside_jobs where run_of = a1) = 1;
      msg := 'A resend made another PO or another run.';
      perform set_config('request.jwt.claims', as_san, true);
      begin
        execute 'set local role authenticated';
        v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1)));
        execute 'reset role'; ok := false; msg := 'A Sanding supervisor made a PO.';
      exception when insufficient_privilege then execute 'reset role'; end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'A PO sent twice is one PO; a supervisor outside Metal, Assembly / QC and Delivery can''t make one', ok, msg);

    -- ---- 8. the rest goes on the next PO: the item itself goes, -2; more than left is refused ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      begin
        v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1, 'lines', '[{"sheet": 1, "pos": 1, "qty": 9}]'::jsonb)));
        ok := false; msg := 'More than was left went.';
      exception when others then ok := sqlerrm like 'Only 8 of that line%'; msg := 'Unexpected: ' || sqlerrm; end;
      v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1)));
      execute 'reset role';
      ok := ok and v2 ->> 'name' = 'AR-9001' and v2 ->> 'file_name' = 'AR-9001(99971-2).pdf'
        and (select not waiting and arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 8}]'::jsonb from outside_jobs where id = a1)
        and (v2 #>> '{lines,0,qty}')::int = 8;
      if not ok and msg like 'Unexpected%' is false then msg := coalesce(msg, 'The second run is wrong: ') || left(v2::text, 200); end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(8, 'The rest goes on the next PO (the item itself, named 99971-2); more than is left is refused', ok, msg);

    -- ---- 9. every page sees the runs and their counts; Returned works per run --------
    perform set_config('request.jwt.claims', as_san, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_outside_jobs where job_id = j1 and at_vendor and not waiting;
      select arrow_counts into v from v_outside_jobs where run_of = a1;
      execute 'reset role';
      ok := n = 2 and v = '[{"pos": 1, "sheet": 1, "holds": 7, "total": 15}]'::jsonb;
      perform set_config('request.jwt.claims', as_met, true);
      execute 'set local role authenticated';
      v2 := return_from_arrow((select id from outside_jobs where run_of = a1), null);
      execute 'reset role';
      ok := ok and (select returned_on is not null from outside_jobs where run_of = a1) and (select returned_on is null from outside_jobs where id = a1);
      msg := format('%s runs at Arrow, counts %s', n, v);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(9, 'Any login sees each run at Arrow with its count (7 of 15); one run comes back on its own', ok, msg);

    -- ---- 10. the office files real POs; a supervisor can't report filing; no login sees anything ----
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := arrow_pos_to_file();
      v2 := record_arrow_po_filed((select jsonb_agg(jsonb_build_object('id', id, 'place', p, 'bytes', 1000)) from arrow_pos, unnest(array['onedrive', 'backup']) p where name in ('AR-9000')));
      v2 := arrow_pos_to_file();
      execute 'reset role';
      ok := v @> '[{"name": "AR-9000"}]'::jsonb and not v2 @> '[{"name": "AR-9000"}]'::jsonb and v2 @> '[{"name": "AR-9001"}]'::jsonb;
      msg := 'The office''s list of POs to file is wrong.';
      perform set_config('request.jwt.claims', as_san, true);
      begin execute 'set local role authenticated'; v := record_arrow_po_filed('[]'); execute 'reset role'; ok := false; msg := 'A supervisor reported a filed PO.';
      exception when insufficient_privilege then execute 'reset role'; end;
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      begin select count(*) into n from arrow_pos; exception when insufficient_privilege then n := 0; end;
      execute 'reset role';
      ok := ok and n = 0;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(10, 'The office files real POs once each; a supervisor can''t report filing; no login sees a PO', ok, msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end $$;
revoke all on function check_arrow_pos() from public, anon, authenticated;

select * from check_arrow_pos();
