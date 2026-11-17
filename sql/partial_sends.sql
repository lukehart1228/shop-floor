-- =====================================================================
-- partial_sends.sql — Full Custom sends the pieces it has finished
-- (17 Nov 2026; a hotfix, Luke's call)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 63. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table:
-- every row should say PASS. Paste it BEFORE index.html 2026-11-17.1
-- goes on GitHub. The tablet page now on the floor keeps working with it.
--
-- WHY
-- A send needed the whole sheet finished. A Full Custom sheet of 80 of
-- one item, 12 done, gave Sanding nothing until all 80 were done, and
-- it was holding up production.
--
-- WHAT IT DOES
-- 1. sheet_sends.qty_sent: how many pieces a send has sent so far, as a
--    running total (12, then 30), never an increment. Empty means the
--    whole sheet: every send before today, and the send of the last
--    pieces.
-- 2. send_pieces(sheet, from, route, how many): Full Custom sends what
--    it has counted and not sent yet. The first send picks Sanding or
--    straight to Finishing; every later send on that sheet goes the
--    same way. It refuses more than is counted, another route, and
--    Metal (Metal still sends whole sheets). The same total sent twice
--    is "Already sent", never doubled.
-- 3. v_ready_to_work: Sanding, Finishing and Assembly / QC get a Full
--    Custom sheet up to what's been sent, not nothing-or-everything.
--    The wood path and Metal are as before. Every column is as before.
-- 4. v_sheet_routes gains columns at its end for the tablet: the latest
--    Full Custom send on each sheet, how many it has sent, and whether
--    it can be undone. Its other columns mean what they meant: a sheet
--    counts as sent only once every piece has gone; Sanding's Not
--    needed also shows after a part sent straight to Finishing.
-- 5. Undo takes back the newest send on a sheet only, back to the
--    number before it, and only while the next department hasn't
--    counted past that number. The first send undoes as before.
-- 6. send_sheet() (the whole-sheet send the floor's page uses) works as
--    before, and finishes a sheet already partly sent the same way.
--
-- Jobs already on the floor follow this from the moment it runs.
-- Sheets already sent stay sent in full. Nothing is deleted.
--
-- Replaces current_send(), send_sheet(), undo_sheet_send(),
-- send_can_undo(), apply_sheet_routes() and v_sheet_routes from
-- send_routes.sql, and v_ready_to_work from handoff_recent.sql, so those
-- files now stop if run again.
-- Ends with check_partial_sends().
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('partial_sends.sql', 63, 'send_pieces', 'check_partial_sends', '{schema.sql,ready_issues.sql,send_routes.sql,handoff_recent.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('partial_sends.sql', '{schema.sql,ready_issues.sql,send_routes.sql,handoff_recent.sql}'); end if;
end $$;

do $$ begin
  if to_regclass('public.sheet_sends') is null or to_regprocedure('public.current_send(uuid,text)') is null then
    raise exception 'Run send_routes.sql first. This file builds on it.';
  end if;
  if to_regclass('public.v_recent_work') is null then raise exception 'Run handoff_recent.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.set_count(uuid,integer)') is null then raise exception 'Run counts_safety.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. How many a send has sent so far
-- ---------------------------------------------------------------------
alter table sheet_sends add column if not exists qty_sent int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sheet_sends_qty_sent_ck') then
    alter table sheet_sends add constraint sheet_sends_qty_sent_ck
      check (qty_sent is null or (qty_sent > 0 and from_dept = 'full_custom'));
  end if;
end $$;
comment on column sheet_sends.qty_sent is
  'Pieces sent so far on this sheet, as a running total (partial_sends.sql, 17 Nov 2026). Empty: the whole sheet.';


-- ---------------------------------------------------------------------
-- 2. The newest send on a sheet, and the send in force
-- ---------------------------------------------------------------------
-- the newest send not undone, from a sheet with the same number and
-- drawing on this job, however many it sent
create or replace function latest_send(p_sheet uuid, p_from text)
returns setof sheet_sends language sql stable security definer set search_path = public as $$
  select ss.*
    from sheets s
    join work_orders w on w.id = s.work_order_id
    join sheet_sends ss on ss.job_id = w.job_id and ss.sheet_number = s.sheet_number
                       and ss.from_dept = p_from and ss.spec_hash is not distinct from s.spec_hash
                       and ss.undone_at is null
   where s.id = p_sheet
   order by ss.sent_at desc, ss.id desc
   limit 1;
$$;
revoke all on function latest_send(uuid, text) from public, anon;
grant execute on function latest_send(uuid, text) to authenticated;

-- the whole sheet sent: the newest send, when it sent every piece and the
-- sender's count is still complete (as before; a part sent isn't this)
create or replace function current_send(p_sheet uuid, p_from text)
returns setof sheet_sends language sql stable security definer set search_path = public as $$
  select l.*
    from latest_send(p_sheet, p_from) l
   where exists (select 1 from sheet_progress p
                  where p.sheet_id = p_sheet and p.department = p_from and p.qty_done >= p.qty_required
                    and (l.qty_sent is null or l.qty_sent >= p.qty_required));
$$;
revoke all on function current_send(uuid, text) from public, anon;
grant execute on function current_send(uuid, text) to authenticated;

-- how many have gone on: total = what the sends say (the whole sheet for a
-- whole send); sent = that, but never more than the sender has counted
create or replace function sent_so_far(p_sheet uuid, p_from text)
returns table (send_id uuid, route text, total int, sent int)
language sql stable security definer set search_path = public as $$
  select l.id, l.route,
         coalesce(l.qty_sent, p.qty_required),
         least(coalesce(l.qty_sent, p.qty_required), p.qty_done, p.qty_required)
    from latest_send(p_sheet, p_from) l
    join sheet_progress p on p.sheet_id = p_sheet and p.department = p_from;
$$;
revoke all on function sent_so_far(uuid, text) from public, anon;
grant execute on function sent_so_far(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 3. What's ready: the tablets' Ready lists, the TV and Pace
--    As handoff_recent.sql, except a Full Custom sheet reaches Sanding,
--    Finishing and Assembly / QC up to what's been sent (marked 17 Nov).
-- ---------------------------------------------------------------------
create or replace view v_ready_to_work with (security_invoker = true) as
with recursive ancestors as (
  select key as dept, predecessor as anc, 1 as depth
    from departments where predecessor is not null
  union all
  select a.dept, d.predecessor, a.depth + 1
    from ancestors a join departments d on d.key = a.anc
   where d.predecessor is not null
)
select
  sp.department,
  s.id  as sheet_id,
  j.id  as job_id,
  greatest(g.available - sp.qty_done, 0) as ready,
  g.available,
  case when sp.qty_done < sp.qty_required and g.available <= sp.qty_done then
    array_remove(array[
      case when up.department is not null and up.qty_done <= sp.qty_done then up.department end,
      case when fc.present and fc.sent <= sp.qty_done then 'full_custom' end,              -- 17 Nov
      case when mt.present and not mt.at_arrow and mt.lim <= sp.qty_done then mt.wait end
    ], null)
  else '{}'::text[] end as waiting_on,
  coalesce(mt.at_arrow, false) and sp.qty_done < sp.qty_required as at_arrow,
  coalesce(ho.held, false) as held_for_handoff
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id and j.is_active
left join lateral (
  -- nearest wood stage before this one that the sheet has
  select pre.department, pre.qty_done
    from ancestors a
    join sheet_progress pre on pre.sheet_id = sp.sheet_id and pre.department = a.anc
   where a.dept = sp.department
   order by a.depth
   limit 1
) up on true
left join lateral (
  -- the cabinet: Sanding, Finishing and Assembly / QC get what Full Custom has sent (17 Nov: pieces, not the whole sheet)
  select true as present, coalesce((select x.sent from sent_so_far(s.id, 'full_custom') x), 0) as sent
    from sheet_progress f
   where sp.department in ('sanding', 'finishing', 'assembly_qc')
     and f.sheet_id = sp.sheet_id and f.department = 'full_custom'
) fc on true
left join lateral (
  -- the metal: Assembly / QC waits for paint or Arrow; Metal paint waits for Metal's send
  select true as present, x.route, x.at_arrow,
         case when sp.department = 'metal_paint' then case when x.route = 'paint' then sp.qty_required else 0 end
              when x.at_arrow or x.route is null then 0
              when x.route = 'paint' then coalesce(x.paint_done, 0)
              else x.metal_done end as lim,
         case when sp.department = 'assembly_qc' and x.route = 'paint' then 'metal_paint' else 'metal' end as wait
    from (
      select m.qty_done as metal_done,
             (select c.route from current_send(s.id, 'metal') c) as route,
             (select p.qty_done from sheet_progress p where p.sheet_id = s.id and p.department = 'metal_paint') as paint_done,
             exists (select 1 from outside_jobs o
                      where o.job_id = j.id and o.returned_on is null and o.voided_at is null
                        and s.sheet_number = any (o.sheet_numbers)) as at_arrow
        from sheet_progress m
       where sp.department in ('assembly_qc', 'metal_paint')
         and m.sheet_id = sp.sheet_id and m.department = 'metal'
    ) x
) mt on true
left join lateral (
  -- 2 Oct: Milling, Metal and Full Custom don't see a job until Monday says it's handed off,
  -- unless the department has already counted on it (then it stays until it's done).
  -- Same jobs as the office's Handoffs list. Unknown (null) is never held; test jobs never are.
  select true as held
   where sp.department in ('milling', 'metal', 'full_custom')
     and not j.is_test and j.handed_off is false
     and not exists (select 1 from sheet_progress p2 join sheets s2 on s2.id = p2.sheet_id
                      where s2.work_order_id = w.id and p2.department = sp.department and p2.qty_done > 0)
) ho on true
cross join lateral (
  select least(coalesce(up.qty_done, sp.qty_required),
               case when fc.present then fc.sent else sp.qty_required end,
               case when mt.present then mt.lim else sp.qty_required end,
               case when ho.held then 0 else sp.qty_required end,
               sp.qty_required) as available
) g;

revoke all on v_ready_to_work from anon;
grant select on v_ready_to_work to authenticated;


-- ---------------------------------------------------------------------
-- 4. Applying a send to the counts: as send_routes.sql, except Full
--    Custom's first send does it, however many pieces it sent
-- ---------------------------------------------------------------------
create or replace function apply_sheet_routes(p_sheet uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_s sheets; fc sheet_sends; mt sheet_sends; v_top boolean; v_sand sheet_progress;
begin
  select s.* into v_s from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where s.id = p_sheet;
  if v_s.id is null then return; end if;                       -- only the current version
  select * into fc from latest_send(p_sheet, 'full_custom');   -- 17 Nov: a part sent counts too
  select * into mt from current_send(p_sheet, 'metal');
  if fc.id is not null and fc.route in ('sanding', 'finishing') then
    if fc.route = 'sanding' then perform send_make_count(p_sheet, 'sanding', v_s.qty, fc.id, 'full_custom'); end if;
    perform send_make_count(p_sheet, 'finishing', v_s.qty, fc.id, 'full_custom');
    -- straight to Finishing with no top: nothing for Sanding to do on this sheet
    v_top := exists (select 1 from sheet_progress where sheet_id = p_sheet and department in ('milling', 'cnc'));
    if fc.route = 'finishing' and not v_top then
      select * into v_sand from sheet_progress where sheet_id = p_sheet and department = 'sanding';
      if v_sand.id is not null and v_sand.qty_done < v_sand.qty_required then
        insert into sheet_send_effects (send_id, progress_id, kind, qty_before)
        values (fc.id, v_sand.id, 'not_needed', v_sand.qty_done) on conflict do nothing;
        perform set_config('shopfloor.source', 'Not needed — sent straight to Finishing', true);
        update sheet_progress set qty_done = qty_required where id = v_sand.id;
        perform set_config('shopfloor.source', '', true);
      end if;
    end if;
  end if;
  if mt.id is not null and mt.route = 'paint' then
    perform send_make_count(p_sheet, 'metal_paint',
      (select qty_required from sheet_progress where sheet_id = p_sheet and department = 'metal'), mt.id, 'metal');
  end if;
end $$;
revoke all on function apply_sheet_routes(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. Undo: the newest send only, while the next department hasn't
--    counted past what was sent before it
-- ---------------------------------------------------------------------
-- the send before this one on the same sheet, not undone
create or replace function send_before(p_send uuid)
returns setof sheet_sends language sql stable security definer set search_path = public as $$
  select p.*
    from sheet_sends v
    join sheet_sends p on p.job_id = v.job_id and p.sheet_number = v.sheet_number and p.from_dept = v.from_dept
                      and p.spec_hash is not distinct from v.spec_hash and p.undone_at is null
                      and p.id <> v.id and (p.sent_at, p.id) < (v.sent_at, v.id)
   where v.id = p_send
   order by p.sent_at desc, p.id desc
   limit 1;
$$;
revoke all on function send_before(uuid) from public, anon;
grant execute on function send_before(uuid) to authenticated;

create or replace function send_can_undo(p_send uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v sheet_sends; v_cur uuid; v_next text; v_prev sheet_sends; v_done int;
begin
  select * into v from sheet_sends where id = p_send;
  if v.id is null or v.undone_at is not null or v.route = 'before' or v.source = 'Before send routes' then return false; end if;
  select s.id into v_cur from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
   where w.job_id = v.job_id and s.sheet_number = v.sheet_number and s.spec_hash is not distinct from v.spec_hash;
  if v_cur is null then return false; end if;
  if v.route = 'arrow' then
    return exists (select 1 from outside_jobs o where o.id = v.outside_job_id and o.returned_on is null and o.voided_at is null);
  end if;
  if (select l.id from latest_send(v_cur, v.from_dept) l) is distinct from v.id then return false; end if;   -- 17 Nov: newest only
  v_next := case v.route when 'sanding' then 'sanding' when 'finishing' then 'finishing' else 'metal_paint' end;
  select * into v_prev from send_before(v.id);
  if v_prev.id is not null then                                 -- a later send of a part: back to the number before it
    select qty_done into v_done from sheet_progress where sheet_id = v_cur and department = v_next;
    return coalesce(v_done, 0) <= coalesce(v_prev.qty_sent, 2147483647);
  end if;
  return not exists (
    select 1 from progress_events e
     where e.sheet_id = v_cur and e.department = v_next and e.id > coalesce(v.events_mark, 0)
       and coalesce(e.source, 'Tablet') in ('Tablet', 'Manager adjustment'));
end $$;
revoke all on function send_can_undo(uuid) from public, anon;
grant execute on function send_can_undo(uuid) to authenticated;

create or replace function undo_sheet_send(p_send uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v sheet_sends; e sheet_send_effects; v_cur uuid; v_prev sheet_sends; v_next text; v_done int;
begin
  select * into v from sheet_sends where id = p_send;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That send isn''t there.'; end if;
  if v.undone_at is not null then return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already undone.'); end if;
  if not (office_ok() or (owns_dept(v.from_dept) and v.is_test = am_test())) then
    raise exception 'Only % (who sent it) or a manager can undo this.', (select name from departments where key = v.from_dept)
      using errcode = 'insufficient_privilege';
  end if;
  if v.route = 'before' or v.source = 'Before send routes' then
    raise exception 'This sheet was finished before send routes started, so there''s no send to undo. A manager can change counts in Advance.';
  end if;
  select s.id into v_cur from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
   where w.job_id = v.job_id and s.sheet_number = v.sheet_number and s.spec_hash is not distinct from v.spec_hash;
  if v_cur is not null and v.route <> 'arrow' and (select l.id from latest_send(v_cur, v.from_dept) l) is distinct from v.id then
    raise exception 'Sheet % has a newer send. Undo that one first.', v.sheet_number;
  end if;
  select * into v_prev from send_before(v.id);
  if not send_can_undo(v.id) then
    v_next := case v.route when 'sanding' then 'Sanding' when 'finishing' then 'Finishing' else 'Metal paint' end;
    if v.route = 'arrow' then
      raise exception 'It''s back from Arrow already, so it can''t be undone here. A manager can fix it in Advance.';
    elsif v_prev.id is not null then
      select qty_done into v_done from sheet_progress where sheet_id = v_cur and department = lower(replace(v_next, ' ', '_'));
      raise exception '% has already counted % on this sheet, more than the % sent before this send, so it can''t be undone here. A manager can fix it in Advance.',
        v_next, coalesce(v_done, 0), v_prev.qty_sent;
    else
      raise exception '% has already counted on this sheet, so the send can''t be undone here. A manager can fix it in Advance.', v_next;
    end if;
  end if;
  for e in select * from sheet_send_effects where send_id = v.id order by id desc loop
    if e.kind = 'created' then
      delete from sheet_progress where id = e.progress_id and qty_done = 0;      -- a count the send made, never counted on
    elsif e.kind = 'not_needed' then
      perform set_config('shopfloor.source', 'Send undone', true);
      update sheet_progress set qty_done = least(coalesce(e.qty_before, 0), qty_required) where id = e.progress_id;
      perform set_config('shopfloor.source', '', true);
    end if;
  end loop;
  if v.outside_job_id is not null then perform void_arrow(v.outside_job_id, 'Send undone'); end if;
  update sheet_sends set undone_at = clock_timestamp(), undone_by_name = my_name() where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    case when v_prev.id is not null then format('Undone: sheet %s is back to %s sent.', v.sheet_number, v_prev.qty_sent)
         else format('Undone: sheet %s is back to not sent.', v.sheet_number) end);
end $$;
revoke all on function undo_sheet_send(uuid) from public, anon;
grant execute on function undo_sheet_send(uuid) to authenticated;


-- whether a send still standing marked this sheet's Sanding count Not needed
-- (17 Nov: the first part sent straight to Finishing does it, not only a whole send)
create or replace function sanding_skipped(p_sheet uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from sheet_send_effects e
                   join sheet_sends ss on ss.id = e.send_id and ss.undone_at is null and ss.from_dept = 'full_custom'
                   join sheet_progress p on p.id = e.progress_id
                  where e.kind = 'not_needed' and p.department = 'sanding' and p.sheet_id = p_sheet);
$$;
revoke all on function sanding_skipped(uuid) from public, anon;
grant execute on function sanding_skipped(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Each sheet's sends, for the tablets: as send_routes.sql, with the
--    latest Full Custom send and how many it has sent at the end
-- ---------------------------------------------------------------------
create or replace view v_sheet_routes with (security_invoker = true) as
select
  s.id as sheet_id,
  j.id as job_id,
  s.sheet_number,
  fc.id as fc_send_id, fc.route as fc_route, fc.sent_at as fc_sent_at, fc.sent_by_name as fc_sent_by,
  coalesce(send_can_undo(fc.id), false) as fc_can_undo,
  mt.id as metal_send_id, mt.route as metal_route, mt.sent_at as metal_sent_at, mt.sent_by_name as metal_sent_by,
  coalesce(send_can_undo(mt.id), false) as metal_can_undo,
  coalesce(send_not_needed(fc.id, s.id), false) or sanding_skipped(s.id) as sanding_not_needed,
  -- 17 Nov: the newest Full Custom send, whole or a part, and how many have gone so far
  fp.id as fc_part_send_id, fp.route as fc_part_route,
  coalesce(fp.qty_sent, (select p.qty_required from sheet_progress p where p.sheet_id = s.id and p.department = 'full_custom')) as fc_sent,
  fp.sent_at as fc_part_sent_at, fp.sent_by_name as fc_part_sent_by,
  coalesce(send_can_undo(fp.id), false) as fc_part_can_undo
from sheets s
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id
left join lateral (select * from current_send(s.id, 'full_custom')) fc on true
left join lateral (select * from current_send(s.id, 'metal')) mt on true
left join lateral (select * from latest_send(s.id, 'full_custom')) fp on true
where (j.monday_item_id is not null or j.is_test)
  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')))
  and j.is_test = am_test();
revoke all on v_sheet_routes from anon;
grant select on v_sheet_routes to authenticated;


-- ---------------------------------------------------------------------
-- 7. Sending: the whole sheet (the floor's page now) and pieces (17 Nov)
-- ---------------------------------------------------------------------
-- As send_routes.sql, plus: a Full Custom sheet already partly sent is
-- finished the same way, never another.
create or replace function send_sheet(p_sheet uuid, p_from text, p_route text, p_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_s sheets; v_job jobs; v_sp sheet_progress; v_prev sheet_sends; v_last sheet_sends; v_id uuid; v_arrow jsonb; v_out uuid;
begin
  if p_client_id is not null then
    select id into v_id from sheet_sends where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.'); end if;
  end if;
  if p_from not in ('full_custom', 'metal') then
    raise exception 'Only Full Custom and Metal send sheets on.';
  end if;
  if not ((p_from = 'full_custom' and p_route in ('sanding', 'finishing')) or (p_from = 'metal' and p_route in ('paint', 'arrow'))) then
    raise exception '%', case p_from when 'metal' then 'Pick where it goes: paint or Arrow.' else 'Pick where it goes: Sanding or straight to Finishing.' end;
  end if;
  select s.* into v_s from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where s.id = p_sheet;
  if v_s.id is null then raise exception 'That sheet isn''t on the current work order any more. Reload the page.'; end if;
  v_job := floor_entry_check(p_from, (select job_id from work_orders where id = v_s.work_order_id));
  select * into v_sp from sheet_progress where sheet_id = p_sheet and department = p_from;
  if v_sp.id is null then
    raise exception 'Sheet % has no % work on it.', v_s.sheet_number, (select name from departments where key = p_from);
  end if;
  if v_sp.qty_done < v_sp.qty_required then
    raise exception 'Finish all % first — % of % done.', v_sp.qty_required, v_sp.qty_done, v_sp.qty_required;
  end if;
  select * into v_prev from current_send(p_sheet, p_from);
  if v_prev.id is not null then
    raise exception 'Sheet % is already sent (%). Undo that first to send it another way.', v_s.sheet_number,
      case v_prev.route when 'sanding' then 'to Sanding' when 'finishing' then 'straight to Finishing' when 'paint' then 'to paint'
                        when 'arrow' then 'to Arrow' else 'before send routes started' end;
  end if;
  select * into v_last from latest_send(p_sheet, p_from);                 -- 17 Nov
  if v_last.id is not null and v_last.qty_sent is not null and v_last.route <> p_route then
    raise exception 'Sheet % is already going % (% sent). Every send on a sheet goes the same way; undo those sends to change it.',
      v_s.sheet_number, case v_last.route when 'sanding' then 'to Sanding' else 'straight to Finishing' end, v_last.qty_sent;
  end if;
  if p_route = 'arrow' then
    v_arrow := send_to_arrow(v_job.id, 'metal', 'powdercoat', array[v_s.sheet_number], null, null, null);
    v_out := (v_arrow->>'id')::uuid;
  end if;
  insert into sheet_sends (client_id, job_id, sheet_id, sheet_number, spec_hash, from_dept, route, outside_job_id,
                           is_test, source, sent_by, sent_by_name, events_mark)
  values (p_client_id, v_job.id, p_sheet, v_s.sheet_number, v_s.spec_hash, p_from, p_route, v_out, v_job.is_test,
          case when my_role() in ('manager', 'admin') then 'Manager adjustment' else 'Tablet' end, auth.uid(), my_name(),
          (select max(id) from progress_events))
  returning id into v_id;
  perform apply_sheet_routes(p_sheet);
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Sheet %s sent %s.', v_s.sheet_number,
    case p_route when 'sanding' then 'to Sanding' when 'finishing' then 'straight to Finishing'
                 when 'paint' then 'to paint' else 'to Arrow — it''s on the Arrow list' end));
end $$;
revoke all on function send_sheet(uuid, text, text, uuid) from public, anon;
grant execute on function send_sheet(uuid, text, text, uuid) to authenticated;

-- Full Custom sends the pieces it has finished. p_qty is the running total
-- to have sent (the tablet sends its count), never an increment.
create or replace function send_pieces(p_sheet uuid, p_from text, p_route text, p_qty int, p_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_s sheets; v_job jobs; v_sp sheet_progress; v_last sheet_sends; v_had int; v_id uuid; v_whole boolean;
begin
  if p_client_id is not null then
    select id into v_id from sheet_sends where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.'); end if;
  end if;
  if p_from is distinct from 'full_custom' then
    raise exception 'Only Full Custom sends part of a sheet. Metal sends each sheet once it''s done.';
  end if;
  if p_route is null or p_route not in ('sanding', 'finishing') then
    raise exception 'Pick where it goes: Sanding or straight to Finishing.';
  end if;
  select s.* into v_s from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where s.id = p_sheet;
  if v_s.id is null then raise exception 'That sheet isn''t on the current work order any more. Reload the page.'; end if;
  v_job := floor_entry_check(p_from, (select job_id from work_orders where id = v_s.work_order_id));
  select * into v_sp from sheet_progress where sheet_id = p_sheet and department = p_from;
  if v_sp.id is null then raise exception 'Sheet % has no Full Custom work on it.', v_s.sheet_number; end if;
  if p_qty is null or p_qty < 1 then raise exception 'Count at least one piece done before sending.'; end if;
  if p_qty > v_sp.qty_done then
    raise exception 'Only % of % are counted done on sheet %. Count them first, then send.', v_sp.qty_done, v_sp.qty_required, v_s.sheet_number;
  end if;
  select * into v_last from latest_send(p_sheet, p_from);
  v_had := case when v_last.id is null then 0 else coalesce(v_last.qty_sent, v_sp.qty_required) end;
  if v_last.id is not null and v_last.route <> p_route then
    raise exception 'Sheet % is already going % (% sent). Every send on a sheet goes the same way; undo those sends to change it.',
      v_s.sheet_number, case v_last.route when 'sanding' then 'to Sanding' else 'straight to Finishing' end, v_had;
  end if;
  if p_qty <= v_had then
    return jsonb_build_object('ok', true, 'id', v_last.id, 'already', true,
      'summary', format('Sheet %s: %s of %s already sent.', v_s.sheet_number, v_had, v_sp.qty_required));
  end if;
  v_whole := p_qty >= v_sp.qty_required;
  insert into sheet_sends (client_id, job_id, sheet_id, sheet_number, spec_hash, from_dept, route, qty_sent,
                           is_test, source, sent_by, sent_by_name, events_mark)
  values (p_client_id, v_job.id, p_sheet, v_s.sheet_number, v_s.spec_hash, p_from, p_route,
          case when v_whole then null else p_qty end, v_job.is_test,
          case when my_role() in ('manager', 'admin') then 'Manager adjustment' else 'Tablet' end, auth.uid(), my_name(),
          (select max(id) from progress_events))
  returning id into v_id;
  perform apply_sheet_routes(p_sheet);
  return jsonb_build_object('ok', true, 'id', v_id, 'sent', least(p_qty, v_sp.qty_required), 'whole', v_whole,
    'summary', format('Sheet %s: %s of %s sent %s.', v_s.sheet_number, least(p_qty, v_sp.qty_required), v_sp.qty_required,
                      case p_route when 'sanding' then 'to Sanding' else 'straight to Finishing' end));
end $$;
revoke all on function send_pieces(uuid, text, text, int, uuid) from public, anon;
grant execute on function send_pieces(uuid, text, text, int, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 8. The check
-- ---------------------------------------------------------------------
create or replace function check_partial_sends()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  fc_u uuid; sd_u uuid; fin_u uuid; nofc_u uuid; mgr uuid;
  v_job uuid; w1 uuid; s1 uuid; s2 uuid; s3 uuid;
  p_fc1 uuid; p_sd1 uuid; p_fc2 uuid; p_fc3 uuid;
  a1 uuid; a2 uuid; a3 uuid; b1 uuid;
  v jsonb; n int; m int; k int; ok boolean; msg text; t text;
  claims constant text := '{"sub":"%s","role":"authenticated"}';
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into fc_u from profiles where role = 'supervisor' and active and not is_test and 'full_custom' = any(departments) order by full_name limit 1;
  select id into sd_u from profiles where role = 'supervisor' and active and not is_test and 'sanding' = any(departments) order by full_name limit 1;
  select id into fin_u from profiles where role = 'supervisor' and active and not is_test and 'finishing' = any(departments) order by full_name limit 1;
  select id into nofc_u from profiles where role = 'supervisor' and active and not is_test and not ('full_custom' = any(departments))
     and cardinality(departments) > 0 and not coalesce(look_up, false) order by full_name limit 1;
  fc_u := coalesce(fc_u, mgr); sd_u := coalesce(sd_u, mgr); fin_u := coalesce(fin_u, mgr);

  -- ---- 1: the pieces are in place -------------------------------------------------------------
  ok := exists (select 1 from information_schema.columns where table_name = 'sheet_sends' and column_name = 'qty_sent')
        and exists (select 1 from information_schema.columns where table_name = 'v_sheet_routes' and column_name = 'fc_sent')
        and has_function_privilege('authenticated', 'send_pieces(uuid,text,text,integer,uuid)', 'execute')
        and not has_function_privilege('anon', 'send_pieces(uuid,text,text,integer,uuid)', 'execute')
        and not has_function_privilege('anon', 'latest_send(uuid,text)', 'execute')
        and not has_function_privilege('authenticated', 'apply_sheet_routes(uuid)', 'execute')
        and not has_table_privilege('authenticated', 'sheet_sends', 'insert')
        and not has_table_privilege('authenticated', 'sheet_sends', 'update');
  res := res || check_row(1, 'Partial sends are set up: the sent number, send_pieces() for signed-in logins only, and no login writing sends directly', ok,
    'Something is missing or open to the wrong login. Paste partial_sends.sql again.');

  if mgr is null then
    res := res || check_row(2, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999963, 'PARTCHECK', 'Partial sends check - undone automatically', true, 'In Production', local_today() + 20)
      returning id into v_job;
    insert into work_orders (job_id, version) values (v_job, 1) returning id into w1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 1, 10, 'PS-1', 'p1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 2, 6, 'PS-2', 'p2') returning id into s2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 3, 2, 'PS-3', 'p3') returning id into s3;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'full_custom', 10, 0), (s1, 'finishing', 10, 0), (s1, 'assembly_qc', 10, 0),                       -- cabinet, no Sanding count
      (s2, 'full_custom', 6, 0), (s2, 'sanding', 6, 0), (s2, 'finishing', 6, 0), (s2, 'assembly_qc', 6, 0),   -- cabinet with a Sanding count
      (s3, 'full_custom', 2, 0), (s3, 'finishing', 2, 0), (s3, 'assembly_qc', 2, 0);                          -- for the whole-sheet send
    select id into p_fc1 from sheet_progress where sheet_id = s1 and department = 'full_custom';
    select id into p_fc2 from sheet_progress where sheet_id = s2 and department = 'full_custom';
    select id into p_fc3 from sheet_progress where sheet_id = s3 and department = 'full_custom';

    -- ---- 2: count 4 of 10, nothing has moved; send 4 to Sanding --------------------------------
    perform set_config('request.jwt.claims', format(claims, fc_u), true);
    begin
      execute 'set local role authenticated';
      v := set_count(p_fc1, 4);
      select ready::text || '(' || array_to_string(waiting_on, ',') || ')' into t from v_ready_to_work where sheet_id = s1 and department = 'finishing';
      v := send_pieces(s1, 'full_custom', 'sanding', 4); a1 := (v->>'id')::uuid;
      select ready into n from v_ready_to_work where sheet_id = s1 and department = 'sanding';
      select fc_sent into m from v_sheet_routes where sheet_id = s1;
      execute 'reset role';
      ok := t = '0(full_custom)' and n = 4 and m = 4
            and (select qty_sent from sheet_sends where id = a1) = 4
            and (select qty_required from sheet_progress where sheet_id = s1 and department = 'sanding') = 10
            and (select fc_route from v_sheet_routes where sheet_id = s1) is null;
      msg := format('Before the send Finishing should wait on Full Custom (got %s); after sending 4, Sanding should have a count of 10 made with 4 ready (got %s), the tablet should see 4 sent (got %s), and the sheet should not count as sent in full.',
                    coalesce(t, 'no row'), coalesce(n::text, 'no row'), coalesce(m::text, 'nothing'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Full Custom sends the 4 of 10 it has finished: Sanding gets 4, and the sheet isn''t marked sent in full', coalesce(ok, false), msg);

    -- ---- 3: the same total again, more than counted, another route, Metal, another department ----
    begin
      execute 'set local role authenticated';
      v := send_pieces(s1, 'full_custom', 'sanding', 4);
      ok := (v->>'already')::boolean and (select count(*) from sheet_sends where job_id = v_job and undone_at is null) = 1;
      msg := 'Sending the same 4 again made a second send.';
      if ok then
        begin
          v := send_pieces(s1, 'full_custom', 'sanding', 6); ok := false; msg := 'It sent 6 with only 4 counted.';
        exception when others then ok := sqlerrm like 'Only 4 of 10 are counted done%'; msg := 'Unexpected refusal for too many: ' || sqlerrm;
        end;
      end if;
      if ok then
        v := set_count(p_fc1, 5);
        begin
          v := send_pieces(s1, 'full_custom', 'finishing', 5); ok := false; msg := 'A later send went another way.';
        exception when others then ok := sqlerrm like 'Sheet 1 is already going to Sanding (4 sent)%'; msg := 'Unexpected refusal for another route: ' || sqlerrm;
        end;
      end if;
      if ok then
        begin
          v := send_pieces(s1, 'metal', 'paint', 1); ok := false; msg := 'send_pieces took a Metal send.';
        exception when others then ok := sqlerrm like 'Only Full Custom sends part of a sheet%'; msg := 'Unexpected refusal for Metal: ' || sqlerrm;
        end;
      end if;
      execute 'reset role';
      if ok and nofc_u is not null then
        perform set_config('request.jwt.claims', format(claims, nofc_u), true);
        begin
          execute 'set local role authenticated';
          v := send_pieces(s1, 'full_custom', 'sanding', 5);
          execute 'reset role';
          ok := false; msg := 'A login without Full Custom sent Full Custom''s pieces.';
        exception when insufficient_privilege then execute 'reset role';
        when others then execute 'reset role'; ok := false; msg := 'Unexpected error for another department: ' || sqlerrm;
        end;
        perform set_config('request.jwt.claims', format(claims, fc_u), true);
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'The same total twice is one send; more than is counted, another route, Metal and another department are refused', coalesce(ok, false), msg);

    -- ---- 4: send more; Sanding counts; Finishing follows Sanding ----------------------------------
    begin
      execute 'set local role authenticated';
      v := set_count(p_fc1, 7);
      v := send_pieces(s1, 'full_custom', 'sanding', 7); a2 := (v->>'id')::uuid;
      execute 'reset role';
      select id into p_sd1 from sheet_progress where sheet_id = s1 and department = 'sanding';
      perform set_config('request.jwt.claims', format(claims, sd_u), true);
      execute 'set local role authenticated';
      v := set_count(p_sd1, 3);
      select ready into n from v_ready_to_work where sheet_id = s1 and department = 'sanding';
      execute 'reset role';
      perform set_config('request.jwt.claims', format(claims, fin_u), true);
      execute 'set local role authenticated';
      select ready into m from v_ready_to_work where sheet_id = s1 and department = 'finishing';
      execute 'reset role';
      ok := n = 4 and m = 3 and (select qty_sent from sheet_sends where id = a2) = 7;
      msg := format('After 7 sent and Sanding counting 3: Sanding should have 4 ready (got %s), Finishing 3 (got %s), the send saying 7.', coalesce(n::text, 'no row'), coalesce(m::text, 'no row'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A later send adds to what''s gone (a running total); Finishing follows Sanding as on the wood path', coalesce(ok, false), msg);

    -- ---- 5: Undo: newest only, back to the number before it ----------------------------------------
    perform set_config('request.jwt.claims', format(claims, fc_u), true);
    begin
      execute 'set local role authenticated';
      begin
        v := undo_sheet_send(a1); ok := false; msg := 'An older send was undone while a newer one stood.';
      exception when others then ok := sqlerrm like 'Sheet 1 has a newer send%'; msg := 'Unexpected refusal for the older send: ' || sqlerrm;
      end;
      if ok then
        ok := (select fc_part_can_undo from v_sheet_routes where sheet_id = s1);
        msg := 'The tablet isn''t offered Undo on the newest send, with Sanding at 3 of the 4 sent before it.';
      end if;
      if ok then
        v := undo_sheet_send(a2);
        select ready into n from v_ready_to_work where sheet_id = s1 and department = 'sanding';
        ok := v->>'summary' = 'Undone: sheet 1 is back to 4 sent.' and n = 1 and (select fc_sent from v_sheet_routes where sheet_id = s1) = 4;
        msg := format('After undoing the 7, Sanding should have 1 ready (4 sent, 3 counted; got %s) and the reply should say back to 4 sent (got %s).', coalesce(n::text, 'no row'), v->>'summary');
      end if;
      if ok then
        v := send_pieces(s1, 'full_custom', 'sanding', 7); a2 := (v->>'id')::uuid;
        execute 'reset role';
        perform set_config('request.jwt.claims', format(claims, sd_u), true);
        execute 'set local role authenticated';
        v := set_count(p_sd1, 5);                                                -- past the 4 sent before
        execute 'reset role';
        perform set_config('request.jwt.claims', format(claims, fc_u), true);
        execute 'set local role authenticated';
        begin
          v := undo_sheet_send(a2); ok := false; msg := 'The send was undone after Sanding counted past what was sent before it.';
        exception when others then ok := sqlerrm like 'Sanding has already counted 5 on this sheet, more than the 4 sent before%'; msg := 'Unexpected refusal: ' || sqlerrm;
        end;
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Undo takes back the newest send only, back to the number before it, and not once Sanding has counted past that number', coalesce(ok, false), msg);

    -- ---- 6: the last pieces: sent in full -----------------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := set_count(p_fc1, 10);
      v := send_pieces(s1, 'full_custom', 'sanding', 10); a3 := (v->>'id')::uuid;
      select ready into n from v_ready_to_work where sheet_id = s1 and department = 'sanding';
      select fc_route into t from v_sheet_routes where sheet_id = s1;
      execute 'reset role';
      ok := n = 5 and t = 'sanding' and (select qty_sent from sheet_sends where id = a3) is null and (v->>'whole')::boolean;
      msg := format('After all 10 are sent: Sanding should have 5 ready (got %s), the sheet should count as sent to Sanding in full (got %s), the send saying the whole sheet.', coalesce(n::text, 'no row'), coalesce(t, 'not sent'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Sending the last pieces sends the sheet in full, as the whole-sheet send did', coalesce(ok, false), msg);

    -- ---- 7: straight to Finishing, no top: Sanding Not needed at the first send; undo puts it back ---
    begin
      execute 'set local role authenticated';
      v := set_count(p_fc2, 2);
      v := send_pieces(s2, 'full_custom', 'finishing', 2); b1 := (v->>'id')::uuid;
      select ready into n from v_ready_to_work where sheet_id = s2 and department = 'finishing';
      ok := n = 2 and (select sanding_not_needed from v_sheet_routes where sheet_id = s2)
            and (select qty_done from sheet_progress where sheet_id = s2 and department = 'sanding') = 6;
      msg := format('After 2 sent straight to Finishing: Finishing should have 2 ready (got %s) and Sanding''s count marked Not needed.', coalesce(n::text, 'no row'));
      if ok then
        v := undo_sheet_send(b1);
        ok := (select qty_done from sheet_progress where sheet_id = s2 and department = 'sanding') = 0
              and (select ready from v_ready_to_work where sheet_id = s2 and department = 'finishing') = 0;
        msg := 'Undoing the first send should put Sanding back to 0 and leave Finishing nothing.';
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Straight to Finishing: the first part sent marks Sanding Not needed (no top), and its Undo puts it back', coalesce(ok, false), msg);

    -- ---- 8: the whole-sheet send (the floor's page now) ------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := set_count(p_fc3, 1);
      begin
        v := send_sheet(s3, 'full_custom', 'sanding'); ok := false; msg := 'The whole-sheet send went with 1 of 2 done.';
      exception when others then ok := sqlerrm like 'Finish all 2 first%'; msg := 'Unexpected refusal: ' || sqlerrm;
      end;
      if ok then
        v := send_pieces(s3, 'full_custom', 'sanding', 1);
        v := set_count(p_fc3, 2);
        begin
          v := send_sheet(s3, 'full_custom', 'finishing'); ok := false; msg := 'The whole-sheet send went another way than the part already sent.';
        exception when others then ok := sqlerrm like 'Sheet 3 is already going to Sanding (1 sent)%'; msg := 'Unexpected refusal: ' || sqlerrm;
        end;
      end if;
      if ok then
        v := send_sheet(s3, 'full_custom', 'sanding');
        select ready into n from v_ready_to_work where sheet_id = s3 and department = 'sanding';
        ok := n = 2 and (select fc_route from v_sheet_routes where sheet_id = s3) = 'sanding';
        msg := format('The whole-sheet send should finish the sheet: Sanding 2 ready (got %s).', coalesce(n::text, 'no row'));
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'The whole-sheet send works as before, and finishes a sheet already partly sent the same way', coalesce(ok, false), msg);

    -- ---- 9: no login ----------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      v := send_pieces(s2, 'full_custom', 'sanding', 1);
      execute 'reset role';
      ok := false;
    exception when others then execute 'reset role'; ok := true;
    end;
    res := res || check_row(9, 'Someone with no login can''t send pieces', ok, 'A send worked with no login. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_partial_sends_undo__';
  exception when others then
    if sqlerrm <> '__check_partial_sends_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_partial_sends() from public, anon, authenticated;

select * from check_partial_sends();
