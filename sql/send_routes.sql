-- =====================================================================
-- Shop Floor — Send routes and the Past tab (29 Sep 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_send_routes();
--
-- What it does:
--   1. Metal paint — a new counted area belonging to Finishing (Jim, and
--      Mike on his Finishing toggle, count it). Starts switched OFF, like
--      every new department; switch it on in office → Setup → Departments.
--   2. sheet_sends — when Full Custom or Metal finishes a sheet, they send
--      it on: Full Custom to Sanding or straight to Finishing, Metal to
--      paint (Metal paint) or to Arrow (powdercoat; the Arrow item is made
--      by the send). One row per send, and undoing one keeps it, marked.
--   3. The Ready lists (v_ready_to_work, shared by the tablets and the TV)
--      now wait for those sends. Sheets with no Full Custom and no Metal
--      work are unchanged.
--   4. v_past_work — the Past tab: Full Custom's jobs whose every sheet is
--      sent, until Monday says 100% Complete.
--   5. v_sheet_routes — each sheet's sends, for the tablets.
--   6. send_sheet() / undo_sheet_send() — the only way in.
--   7. A send on a sheet that a change order leaves unchanged carries over
--      to the new version, with any count it made.
--   8. The first time this file runs, sheets that are already finished
--      count as sent the way they flow today, so nothing on the floor
--      stalls. Running it again never does that again.
--
-- Nothing is deleted except a count a send made that nobody has counted
-- on, when that send is undone. Test and real jobs stay in their lanes.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('send_routes.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.v_ready_to_work') is null
     or to_regclass('public.outside_jobs') is null
     or to_regprocedure('public.send_to_arrow(uuid,text,text,integer[],text,date,uuid)') is null
     or to_regprocedure('public.check_row(integer,text,boolean,text)') is null
     or to_regprocedure('public.floor_entry_check(text,uuid)') is null then
    raise exception 'Run the earlier files first (up to ready_issues.sql). This file builds on them.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Metal paint: Finishing's second list
-- ---------------------------------------------------------------------
insert into departments (key, name, sort_order, monday_column, predecessor, is_live, log_only)
values ('metal_paint', 'Metal paint', 6, null, null, false, false)
on conflict (key) do nothing;

-- Metal paint's defect list. (The office's defect-list editor doesn't show Metal paint yet; to change it, ask Claude.)
insert into defect_types (department, label, sort_order) values
  ('metal_paint', 'Runs', 1), ('metal_paint', 'Didn''t meet color spec', 2),
  ('metal_paint', 'Junk in finish', 3), ('metal_paint', 'Needs repaint', 4)
on conflict (department, label) do nothing;

-- whoever counts Finishing also counts Metal paint (managers count everything, as before)
create or replace function owns_dept(dept text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
     where id = auth.uid()
       and (role in ('manager','admin') or dept = any(departments)
            or (dept = 'metal_paint' and 'finishing' = any(departments)))
  );
$$;

-- ---------------------------------------------------------------------
-- 2. The sends
-- ---------------------------------------------------------------------
create table if not exists sheet_sends (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid unique,
  job_id          uuid not null references jobs(id),
  sheet_id        uuid not null references sheets(id),      -- the sheet it was sent from
  sheet_number    int  not null,
  spec_hash       text,                                     -- carries over while the drawing is unchanged
  from_dept       text not null check (from_dept in ('full_custom', 'metal')),
  route           text not null check (route in ('sanding', 'finishing', 'paint', 'arrow', 'before')),
  outside_job_id  uuid references outside_jobs(id),
  is_test         boolean not null default false,
  source          text not null default 'Tablet',
  sent_by         uuid references profiles(id),
  sent_by_name    text,
  sent_at         timestamptz not null default clock_timestamp(),
  events_mark     bigint,                                   -- the count history's last entry when it was sent
  undone_at       timestamptz,
  undone_by_name  text,
  check ((from_dept = 'full_custom' and route in ('sanding', 'finishing', 'before'))
      or (from_dept = 'metal'       and route in ('paint', 'arrow', 'before')))
);
alter table sheet_sends add column if not exists events_mark bigint;
create index if not exists sheet_sends_lookup_idx on sheet_sends (job_id, sheet_number, from_dept);

-- what each send did to the counts, so Undo can put it back
create table if not exists sheet_send_effects (
  id           bigserial primary key,
  send_id      uuid not null references sheet_sends(id),
  progress_id  uuid not null,
  kind         text not null check (kind in ('created', 'not_needed')),
  qty_before   int,
  at           timestamptz not null default clock_timestamp(),
  unique (send_id, progress_id, kind)
);

alter table sheet_sends enable row level security;
alter table sheet_send_effects enable row level security;
drop policy if exists read_sheet_sends on sheet_sends;
create policy read_sheet_sends on sheet_sends for select to authenticated using (sees_lane(is_test));
revoke all on sheet_sends, sheet_send_effects from anon, authenticated;
grant select on sheet_sends to authenticated;
revoke all on sequence sheet_send_effects_id_seq from anon, authenticated;

-- the send in force for a sheet: the newest one not undone, from a sheet
-- with the same number and drawing on this job, while the sender's count
-- on this sheet is still complete
create or replace function current_send(p_sheet uuid, p_from text)
returns setof sheet_sends language sql stable security definer set search_path = public as $$
  select ss.*
    from sheets s
    join work_orders w on w.id = s.work_order_id
    join sheet_sends ss on ss.job_id = w.job_id and ss.sheet_number = s.sheet_number
                       and ss.from_dept = p_from and ss.spec_hash is not distinct from s.spec_hash
                       and ss.undone_at is null
   where s.id = p_sheet
     and exists (select 1 from sheet_progress p
                  where p.sheet_id = s.id and p.department = p_from and p.qty_done >= p.qty_required)
   order by ss.sent_at desc
   limit 1;
$$;
revoke all on function current_send(uuid, text) from public, anon;
grant execute on function current_send(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. What's ready: the tablets' Ready lists and the TV
--    Wood as before; then the cabinet (Full Custom's send) and the metal
--    (Metal's send, paint count, or Arrow) on the sheets that have them.
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
      case when fc.present and fc.route is null then 'full_custom' end,
      case when mt.present and not mt.at_arrow and mt.lim <= sp.qty_done then mt.wait end
    ], null)
  else '{}'::text[] end as waiting_on,
  coalesce(mt.at_arrow, false) and sp.qty_done < sp.qty_required as at_arrow
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
  -- the cabinet: Sanding, Finishing and Assembly / QC wait until Full Custom sends it
  select true as present, (select c.route from current_send(s.id, 'full_custom') c) as route
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
cross join lateral (
  select least(coalesce(up.qty_done, sp.qty_required),
               case when fc.present and fc.route is null then 0 else sp.qty_required end,
               case when mt.present then mt.lim else sp.qty_required end,
               sp.qty_required) as available
) g;
revoke all on v_ready_to_work from anon;
grant select on v_ready_to_work to authenticated;

-- ---------------------------------------------------------------------
-- 4. The Past tab: jobs a department has finished (senders: sent),
--    while Monday says In Production, Delivery or Project Closeout
-- ---------------------------------------------------------------------
drop view if exists v_past_work;
create view v_past_work with (security_invoker = true) as
with finished as (
  select w.job_id, sp.department,
         case when sp.department in ('full_custom', 'metal')
              then max(case when cs.route = 'before' then coalesce(sp.completed_at, cs.sent_at) else cs.sent_at end)
              else coalesce(max(sp.completed_at), max(sp.updated_at)) end as done_at
    from sheet_progress sp
    join sheets s      on s.id = sp.sheet_id
    join work_orders w on w.id = s.work_order_id and w.is_current
    left join lateral (select c.route, c.sent_at from current_send(s.id, sp.department) c
                        where sp.department in ('full_custom', 'metal')) cs on true
   group by w.job_id, sp.department
  having sum(sp.qty_required) > 0
     and bool_and(sp.qty_done >= sp.qty_required)
     and bool_and(sp.department not in ('full_custom', 'metal') or cs.route is not null)
)
select
  sp.id                            as progress_id,
  sp.department,
  sp.qty_done,
  sp.qty_required,
  sp.state,
  sp.updated_at                    as progress_updated_at,
  s.id                             as sheet_id,
  s.sheet_number,
  s.item_code,
  s.species,
  s.shape,
  s.width,
  s.length,
  s.thickness,
  s.total_height,
  s.png_path,
  s.pdf_path,
  s.pdf_uploaded_at is not null    as pages_ready,
  w.id                             as work_order_id,
  w.version,
  j.id                             as job_id,
  j.project_id,
  j.name                           as job_name,
  j.delivery_date,
  j.materials_ordered,
  j.is_test,
  j.phase,
  f.done_at
from finished f
join jobs j            on j.id = f.job_id
join work_orders w     on w.job_id = j.id and w.is_current
join sheets s          on s.work_order_id = w.id
join sheet_progress sp on sp.sheet_id = s.id and sp.department = f.department
where (j.monday_item_id is not null or j.is_test)
  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')))
  and j.is_test = am_test();
revoke all on v_past_work from anon;
grant select on v_past_work to authenticated;

-- ---------------------------------------------------------------------
-- 5. Undo
-- ---------------------------------------------------------------------
-- Undo is allowed until the next department has counted on the sheet (for Arrow:
-- until it's marked returned). Sheets finished before send routes can't be undone.
create or replace function send_can_undo(p_send uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v sheet_sends; v_cur uuid; v_next text;
begin
  select * into v from sheet_sends where id = p_send;
  if v.id is null or v.undone_at is not null or v.route = 'before' or v.source = 'Before send routes' then return false; end if;
  select s.id into v_cur from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
   where w.job_id = v.job_id and s.sheet_number = v.sheet_number and s.spec_hash is not distinct from v.spec_hash;
  if v_cur is null then return false; end if;
  if v.route = 'arrow' then
    return exists (select 1 from outside_jobs o where o.id = v.outside_job_id and o.returned_on is null and o.voided_at is null);
  end if;
  v_next := case v.route when 'sanding' then 'sanding' when 'finishing' then 'finishing' else 'metal_paint' end;
  return not exists (
    select 1 from progress_events e
     where e.sheet_id = v_cur and e.department = v_next and e.id > coalesce(v.events_mark, 0)
       and coalesce(e.source, 'Tablet') in ('Tablet', 'Manager adjustment'));
end $$;

revoke all on function send_can_undo(uuid) from public, anon;
grant execute on function send_can_undo(uuid) to authenticated;

-- whether a send marked this sheet's Sanding count Not needed
create or replace function send_not_needed(p_send uuid, p_sheet uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from sheet_send_effects e join sheet_progress p on p.id = e.progress_id
                  where e.send_id = p_send and e.kind = 'not_needed' and p.department = 'sanding' and p.sheet_id = p_sheet);
$$;
revoke all on function send_not_needed(uuid, uuid) from public, anon;
grant execute on function send_not_needed(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Each sheet's sends, for the tablets
-- ---------------------------------------------------------------------
drop view if exists v_sheet_routes;
create view v_sheet_routes with (security_invoker = true) as
select
  s.id as sheet_id,
  j.id as job_id,
  s.sheet_number,
  fc.id as fc_send_id, fc.route as fc_route, fc.sent_at as fc_sent_at, fc.sent_by_name as fc_sent_by,
  coalesce(send_can_undo(fc.id), false) as fc_can_undo,
  mt.id as metal_send_id, mt.route as metal_route, mt.sent_at as metal_sent_at, mt.sent_by_name as metal_sent_by,
  coalesce(send_can_undo(mt.id), false) as metal_can_undo,
  coalesce(send_not_needed(fc.id, s.id), false) as sanding_not_needed
from sheets s
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id
left join lateral (select * from current_send(s.id, 'full_custom')) fc on true
left join lateral (select * from current_send(s.id, 'metal')) mt on true
where (j.monday_item_id is not null or j.is_test)
  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')))
  and j.is_test = am_test();
revoke all on v_sheet_routes from anon;
grant select on v_sheet_routes to authenticated;

-- ---------------------------------------------------------------------
-- 7. Applying a send to the counts (used by the send, and after uploads)
-- ---------------------------------------------------------------------
-- a count the work order didn't list: made with the sheet's quantity, and
-- if an earlier version of the same sheet had it, its number carries over
create or replace function send_make_count(p_sheet uuid, p_dept text, p_qty int, p_send uuid, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare v_s sheets; v_job uuid; v_done int; v_id uuid;
begin
  if p_qty is null or p_qty < 1 then return; end if;
  if exists (select 1 from sheet_progress where sheet_id = p_sheet and department = p_dept) then return; end if;
  select * into v_s from sheets where id = p_sheet;
  select job_id into v_job from work_orders where id = v_s.work_order_id;
  select least(p.qty_done, p_qty) into v_done
    from sheets s2 join work_orders w2 on w2.id = s2.work_order_id
    join sheet_progress p on p.sheet_id = s2.id and p.department = p_dept
   where w2.job_id = v_job and w2.id <> v_s.work_order_id and s2.sheet_number = v_s.sheet_number
     and s2.spec_hash is not distinct from v_s.spec_hash
   order by w2.version desc limit 1;
  perform set_config('shopfloor.source', case p_from when 'metal' then 'Sent from Metal' else 'Sent from Full Custom' end, true);
  insert into sheet_progress (sheet_id, department, qty_required, qty_done)
  values (p_sheet, p_dept, p_qty, coalesce(v_done, 0))
  on conflict (sheet_id, department) do nothing
  returning id into v_id;
  perform set_config('shopfloor.source', '', true);
  if v_id is not null then
    insert into sheet_send_effects (send_id, progress_id, kind) values (p_send, v_id, 'created') on conflict do nothing;
  end if;
end $$;
revoke all on function send_make_count(uuid, text, int, uuid, text) from public, anon, authenticated;

create or replace function apply_sheet_routes(p_sheet uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_s sheets; fc sheet_sends; mt sheet_sends; v_top boolean; v_sand sheet_progress;
begin
  select s.* into v_s from sheets s join work_orders w on w.id = s.work_order_id and w.is_current where s.id = p_sheet;
  if v_s.id is null then return; end if;                       -- only the current version
  select * into fc from current_send(p_sheet, 'full_custom');
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

-- after an upload (a change order), sends on unchanged sheets carry over. It runs at
-- the end of the upload and can never make one fail: a problem is only a warning.
create or replace function sheet_routes_follow()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform apply_sheet_routes(new.sheet_id);
  exception when others then
    raise warning 'Send routes: a send could not be carried to sheet % (%). The upload itself is fine.', new.sheet_id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists sheet_routes_follow_trg on sheet_progress;
create constraint trigger sheet_routes_follow_trg after insert on sheet_progress
  deferrable initially deferred for each row execute function sheet_routes_follow();

-- ---------------------------------------------------------------------
-- 8. Send and undo — the only way in
-- ---------------------------------------------------------------------
create or replace function send_sheet(p_sheet uuid, p_from text, p_route text, p_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_s sheets; v_job jobs; v_sp sheet_progress; v_prev sheet_sends; v_id uuid; v_arrow jsonb; v_out uuid;
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

create or replace function undo_sheet_send(p_send uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v sheet_sends; e sheet_send_effects;
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
  if not send_can_undo(v.id) then
    raise exception '%', case v.route when 'arrow' then 'It''s back from Arrow already, so it can''t be undone here. A manager can fix it in Advance.'
      else format('%s has already counted on this sheet, so the send can''t be undone here. A manager can fix it in Advance.',
                  case v.route when 'sanding' then 'Sanding' when 'finishing' then 'Finishing' else 'Metal paint' end) end;
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
  return jsonb_build_object('ok', true, 'summary', format('Undone: sheet %s is back to not sent.', v.sheet_number));
end $$;
revoke all on function undo_sheet_send(uuid) from public, anon;
grant execute on function undo_sheet_send(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 9. Go-live, once: sheets already finished count as sent the way they
--    flow today (Metal on an open Arrow item → the Arrow route)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from app_settings where key = 'send_routes_started') then return; end if;
  insert into sheet_sends (job_id, sheet_id, sheet_number, spec_hash, from_dept, route, outside_job_id, is_test,
                           source, sent_by_name, sent_at)
  select w.job_id, s.id, s.sheet_number, s.spec_hash, sp.department,
         case when sp.department = 'metal' and o.id is not null then 'arrow' else 'before' end,
         o.id, j.is_test, 'Before send routes', 'Finished before send routes', coalesce(sp.completed_at, now())
    from sheet_progress sp
    join sheets s      on s.id = sp.sheet_id
    join work_orders w on w.id = s.work_order_id and w.is_current
    join jobs j        on j.id = w.job_id
    left join lateral (select x.id from outside_jobs x
                        where sp.department = 'metal' and x.job_id = j.id and x.returned_on is null and x.voided_at is null
                          and s.sheet_number = any (x.sheet_numbers)
                        order by x.sent_at desc limit 1) o on true
   where sp.department in ('full_custom', 'metal') and sp.qty_done >= sp.qty_required;
  insert into app_settings (key, value, updated_by_name) values ('send_routes_started', to_jsonb(now()), 'send_routes.sql');
end $$;

-- ---------------------------------------------------------------------
-- 10. check_ready_issues(), updated for send routes: its metal now has
--     to be sent before Assembly / QC sees it. Same 14 steps otherwise.
--     (Don't run ready_issues.sql again after this file: it would put the
--     old Ready rules back. If it happens, run this file again.)
-- ---------------------------------------------------------------------
create or replace function check_ready_issues()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  sup_dept text;  other uuid;  tst uuid;  mgr uuid;
  v_job   uuid;  v_wo uuid;  v_pre uuid;  v_prog uuid;  v_test uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid;
  v_type  uuid;  v_ttype uuid;
  v       jsonb;
  d_ask   uuid;  d_plain uuid;  d_test uuid;
  n       int;   m int;
  ok      boolean;
  msg     text;
  r       record;
begin
  select p.id, coalesce((select d from unnest(p.departments) d where d = 'sanding'),
                        (select d from unnest(p.departments) d where d in (select key from departments where not log_only) limit 1))
    into sup, sup_dept
    from profiles p
   where p.role = 'supervisor' and p.active and not p.is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by ('sanding' = any(p.departments)) desc limit 1;
  select id into other from profiles p where p.role = 'supervisor' and p.active and not p.is_test and not (sup_dept = any(p.departments)) limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  if sup is null or mgr is null then
    res := res || check_row(1, 'A supervisor and a manager have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end, case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- a throwaway job, in production, whose Monday Metal Status says Not Ready
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, monday_stages)
      values (-999995, 'READYCHECK', 'Ready check - undone automatically', true, 'In Production', local_today() + 9, '{"metal":"Not Ready"}')
      returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 1, 3, 'RC-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 2, 3, 'RC-2') returning id into s2;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 3, 2, 'RC-3') returning id into s3;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 4, 2, 'RC-4') returning id into s4;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 5, 2, 'RC-5') returning id into s5;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'finishing', 3, 3), (s1, 'metal', 3, 3), (s1, 'assembly_qc', 3, 0),      -- both done: 3 ready
      (s2, 'finishing', 3, 3), (s2, 'metal', 3, 1), (s2, 'assembly_qc', 3, 0),      -- metal behind: 1 ready
      (s3, 'finishing', 2, 2),                      (s3, 'assembly_qc', 2, 0),      -- no metal: 2 ready
      (s4, 'finishing', 2, 2), (s4, 'metal', 2, 2), (s4, 'assembly_qc', 2, 0),      -- at Arrow: 0 ready
      (s5, 'sanding', 2, 2),   (s5, 'finishing', 2, 0), (s5, 'assembly_qc', 2, 0);  -- finishing behind
    insert into outside_jobs (job_id, sheet_numbers, description, service, department, sent_on, sent_by_name)
      values (v_job, '{4}', 'ready check bases', 'powdercoat', 'metal', local_today() - 2, 'Ready check');
    -- send routes (29 Sep): metal reaches Assembly / QC once Metal sends it; sheets 1 and 4 are sent
    insert into sheet_sends (job_id, sheet_id, sheet_number, from_dept, route, source, sent_by_name) values
      (v_job, s1, 1, 'metal', 'before', 'Before send routes', 'Ready check'),
      (v_job, s4, 4, 'metal', 'before', 'Before send routes', 'Ready check');
    -- two more jobs for the metal list: one Pre-Production (it counts), one whose metal is under way (it doesn't)
    insert into jobs (monday_item_id, project_id, name, is_active, phase, monday_stages)
      values (-999994, 'READYCHECK-PRE', 'Ready check', false, 'Pre-Production', '{"metal":" not ready "}') returning id into v_pre;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, monday_stages)
      values (-999993, 'READYCHECK-GO', 'Ready check', true, 'In Production', '{"metal":"In Progress"}') returning id into v_prog;

    -- ---- 1–4: what's ready, read as the supervisor would -----------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select string_agg(format('%s:%s', s.sheet_number, v.ready), ' ' order by s.sheet_number) into msg
        from v_ready_to_work v join sheets s on s.id = v.sheet_id where v.job_id = v_job and v.department = 'assembly_qc';
      execute 'reset role';
      ok := msg = '1:3 2:0 3:2 4:0 5:0';
      msg := 'Expected sheets 1:3 2:0 3:2 4:0 5:0 ready for Assembly / QC (sheet 2''s metal isn''t finished and sent); got ' || coalesce(msg, 'nothing') || '.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'Assembly / QC waits on Finishing and on Metal''s send; a sheet with no metal only waits on Finishing', ok, msg);

    select at_arrow and ready = 0 and waiting_on = '{}' into ok from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
    update outside_jobs set returned_on = local_today(), returned_by_name = 'Ready check' where job_id = v_job;
    select ok and ready = 2 and not at_arrow into ok from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
    res := res || check_row(2, 'A sheet at Arrow has nothing ready until it''s marked returned', coalesce(ok, false),
      'Sheet 4 wasn''t held while at Arrow, or wasn''t ready once it came back.');

    select (select waiting_on from v_ready_to_work where sheet_id = s2 and department = 'assembly_qc') = '{metal}'   -- metal not sent yet
       and (select waiting_on from v_ready_to_work where sheet_id = s5 and department = 'assembly_qc') = '{finishing}'
       and (select ready from v_ready_to_work where sheet_id = s5 and department = 'finishing') = 2
       and (select available from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc') = 3
      into ok;
    res := res || check_row(3, 'It says what a sheet is waiting on; wood stages work as before', coalesce(ok, false),
      'The "waiting on" list or Finishing''s ready count wasn''t what was expected.');

    update sheet_progress set qty_done = 3 where sheet_id = s2 and department = 'metal';
    insert into sheet_sends (job_id, sheet_id, sheet_number, from_dept, route, source, sent_by_name)
      values (v_job, s2, 2, 'metal', 'before', 'Before send routes', 'Ready check');
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'assembly_qc';
    select (select ready from v_ready_to_work where sheet_id = s2 and department = 'assembly_qc') = 3
       and (select ready from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc') = 2 into ok;
    res := res || check_row(4, 'Ready follows the counts: Metal finishing and sending frees pieces; Assembly''s own count uses them', coalesce(ok, false),
      'The ready numbers didn''t move with the counts.');

    -- ---- 5–6: Needs metal cut sheets --------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where job_id in (v_job, v_pre)), count(*) filter (where job_id = v_prog) into n, m from v_metal_cut_sheets;
      execute 'reset role';
      ok := n = 2 and m = 0;
      msg := format('Expected the In Production and Pre-Production jobs saying Not Ready (2) and not the one In Progress; got %s and %s.', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Needs metal cut sheets lists jobs whose Metal Status says Not Ready', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_metal_cut_sheets;
      execute 'reset role';
      ok := n = 0; msg := n || ' rows visible to a supervisor.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A supervisor can''t see that list (office only)', ok, msg);

    -- ---- 7–11: defects that ask the office --------------------------------
    select id into v_type from defect_types where department = sup_dept and active order by sort_order limit 1;
    begin
      execute 'set local role authenticated';
      v := report_defect(v_job, sup_dept, v_type, null, 'ready check: remake or touch up?', true, gen_random_uuid());
      d_ask := (v->>'id')::uuid;
      v := report_defect(v_job, sup_dept, v_type, null, 'ready check: counted only', false, gen_random_uuid());
      d_plain := (v->>'id')::uuid;
      execute 'reset role';
      ok := (select office_status = 'open' and ask_office from defects where id = d_ask)
        and (select office_status is null and not ask_office from defects where id = d_plain);
      msg := 'The asked defect isn''t waiting on the office, or the plain one is.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A defect with Ask the office waits on the office; one without is only counted', coalesce(ok, false), msg);

    begin
      execute 'set local role authenticated';
      v := answer_defect(d_ask, 'I shouldn''t be able to answer this');
      execute 'reset role';
      ok := false; msg := 'A supervisor answered a defect. Only the office should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Only the office can answer', ok, msg);

    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := answer_defect(d_ask, 'Ready check: touch it up', true);
      execute 'reset role';
      ok := (select office_status = 'answered' from defects where id = d_ask);
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := reply_defect(d_ask, 'Ready check: touched up, still shows', gen_random_uuid());
      select count(*) into n from v_defects where id = d_ask and jsonb_array_length(thread) = 2;
      execute 'reset role';
      ok := ok and n = 1 and (select office_status = 'open' and came_back from defects where id = d_ask);
      msg := 'The answer didn''t close it, or the reply didn''t bring it back tagged Came back with the thread.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'An answer closes it; a reply brings it back as "Came back", thread and all', coalesce(ok, false), msg);

    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := answer_defect(d_plain, 'Ready check: noted', true);
      execute 'reset role';
      ok := (select office_status is null from defects where id = d_plain)
        and (select count(*) = 1 from defect_messages where defect_id = d_plain and kind = 'office_note');
      msg := 'A note on a counted defect made it wait, or wasn''t kept.';
      if ok then     -- then the floor asks about it after all: now it waits
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        v := reply_defect(d_plain, 'Ready check: on second thoughts, remake?', gen_random_uuid());
        execute 'reset role';
        ok := (select office_status = 'open' and ask_office and not came_back from defects where id = d_plain);
        msg := 'Asking the office about a counted defect later didn''t send it to the office.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'A note on a counted defect doesn''t make it wait; asking about it later does', coalesce(ok, false), msg);

    if other is null then
      res := res || check_row(11, 'Another department can''t reply on this defect', true, null);
    else
      perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := reply_defect(d_plain, 'not my department');
        execute 'reset role';
        ok := false; msg := 'A supervisor from another department replied on it.';
      exception when insufficient_privilege then execute 'reset role'; ok := true;
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
      res := res || check_row(11, 'Another department can''t reply on this defect', ok, msg);
    end if;

    -- ---- 12–14: lanes, direct writes, no login ----------------------------
    if tst is null then
      res := res || check_row(12, 'Test defects and their threads stay out of real supervisors'' sight', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('READYCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      select id into v_ttype from defect_types where department = 'assembly_qc' and active order by sort_order limit 1;
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := report_defect(v_test, 'assembly_qc', v_ttype, 1, 'ready check, test lane', true, gen_random_uuid());
        d_test := (v->>'id')::uuid;
        v := reply_defect(d_test, 'ready check, test lane reply', gen_random_uuid());
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select (select count(*) from v_defects where id = d_test) + (select count(*) from defect_messages where defect_id = d_test) into n;
        execute 'reset role';
        ok := n = 0 and d_test is not null; msg := 'A real supervisor can see a test defect or its thread.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(12, 'Test defects and their threads stay out of real supervisors'' sight', ok, msg);
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      insert into defect_messages (defect_id, kind, body) values (d_plain, 'answer', 'sneaky');
      execute 'reset role';
      ok := false; msg := 'A supervisor wrote to defect_messages directly, around the checks.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Nobody can write a defect message directly', ok, msg);

    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select (select count(*) from defect_messages) + (select count(*) from v_ready_to_work) into n;
      execute 'reset role';
      ok := n = 0; msg := n || ' rows are visible without logging in. Do not go further.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Someone with no login sees none of it', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_ready_issues_undo__';
  exception when others then
    if sqlerrm <> '__check_ready_issues_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_ready_issues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. The check. Everything it makes is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_send_routes()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  fc_u uuid; mt_u uuid; fin_u uuid; nofin_u uuid; nofc_u uuid; tst uuid; mgr uuid;
  v_job uuid; w1 uuid; w2 uuid; v_test uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid; n1 uuid; n3 uuid;
  x1 uuid; x2 uuid; x5 uuid;
  v jsonb; n int; m int; k int; ok boolean; msg text; t text; t2 text;
  function_ok boolean;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'full_custom' = any(departments) limit 1), mgr) into fc_u;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'metal' = any(departments) limit 1), mgr) into mt_u;
  select coalesce((select id from profiles where role = 'supervisor' and active and not is_test and 'finishing' = any(departments) limit 1), mgr) into fin_u;
  select id into nofin_u from profiles where role = 'supervisor' and active and not is_test and not ('finishing' = any(departments)) and cardinality(departments) > 0 limit 1;
  select id into nofc_u from profiles where role = 'supervisor' and active and not is_test and not ('full_custom' = any(departments)) and cardinality(departments) > 0 limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;

  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'No manager login. Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999971, 'ROUTECHECK', 'Send routes check - undone automatically', true, 'In Production', local_today() + 20)
      returning id into v_job;
    insert into work_orders (job_id, version) values (v_job, 1) returning id into w1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 1, 2, 'RT-1', 'h1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 2, 1, 'RT-2', 'h2') returning id into s2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 3, 1, 'RT-3', 'h3') returning id into s3;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 4, 2, 'RT-4', 'h4') returning id into s4;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 5, 1, 'RT-5', 'h5') returning id into s5;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w1, 6, 2, 'RT-6', 'h6') returning id into s6;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'full_custom', 2, 1), (s1, 'finishing', 2, 0), (s1, 'assembly_qc', 2, 0),                             -- cabinet, no Sanding count
      (s2, 'full_custom', 1, 1), (s2, 'sanding', 1, 0), (s2, 'finishing', 1, 0), (s2, 'assembly_qc', 1, 0),      -- cabinet with a Sanding count
      (s3, 'milling', 1, 1), (s3, 'cnc', 1, 1), (s3, 'sanding', 1, 0), (s3, 'full_custom', 1, 1),
      (s3, 'finishing', 1, 0), (s3, 'assembly_qc', 1, 0),                                                       -- top + cabinet
      (s4, 'metal', 2, 2), (s4, 'assembly_qc', 2, 0),                                                           -- metal, to paint
      (s5, 'metal', 1, 1), (s5, 'assembly_qc', 1, 0),                                                           -- metal, to Arrow
      (s6, 'milling', 2, 2), (s6, 'cnc', 2, 0);                                                                 -- wood only

    -- ---- 1: Metal paint belongs to Finishing ----------------------------------------------
    select exists (select 1 from departments where key = 'metal_paint' and not log_only) into ok;
    perform set_config('request.jwt.claims', json_build_object('sub', fin_u, 'role', 'authenticated')::text, true);
    ok := ok and owns_dept('metal_paint');
    if nofin_u is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', nofin_u, 'role', 'authenticated')::text, true);
      ok := ok and not owns_dept('metal_paint');
    end if;
    res := res || check_row(1, 'Metal paint is a counted area, and it belongs to Finishing', ok,
      'Metal paint is missing, or a Finishing login can''t count it, or a login without Finishing can.');

    -- ---- 2: nothing moves until it's sent; wood unchanged ----------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', fin_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select string_agg(format('%s/%s:%s%s', s.sheet_number, v.department, v.ready,
                               case when cardinality(v.waiting_on) > 0 then '(' || array_to_string(v.waiting_on, ',') || ')' else '' end),
                        ' ' order by s.sheet_number, v.department) into msg
        from v_ready_to_work v join sheets s on s.id = v.sheet_id
       where v.job_id = v_job and v.department in ('sanding', 'finishing', 'assembly_qc', 'cnc');
      execute 'reset role';
      ok := msg = '1/assembly_qc:0(finishing,full_custom) 1/finishing:0(full_custom) 2/assembly_qc:0(finishing,full_custom) 2/finishing:0(sanding,full_custom) 2/sanding:0(full_custom) '
               || '3/assembly_qc:0(finishing,full_custom) 3/cnc:0 3/finishing:0(sanding,full_custom) 3/sanding:0(full_custom) '
               || '4/assembly_qc:0(metal) 5/assembly_qc:0(metal) 6/cnc:2';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Nothing reaches Sanding, Finishing or Assembly / QC until it''s sent; wood-only sheets are as before', ok,
      'Got: ' || coalesce(msg, 'nothing'));

    -- ---- 3: not before it's done; not by another department ---------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', fc_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_sheet(s1, 'full_custom', 'sanding');
      execute 'reset role';
      ok := false; msg := 'Sheet 1 was sent with 1 of 2 done.';
    exception when others then execute 'reset role'; ok := sqlerrm like 'Finish all 2 first%'; msg := 'Unexpected refusal: ' || sqlerrm;
    end;
    if ok and nofc_u is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', nofc_u, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := send_sheet(s2, 'full_custom', 'finishing');
        execute 'reset role';
        ok := false; msg := 'A login without Full Custom sent a Full Custom sheet.';
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    end if;
    if ok then
      begin
        execute 'set local role authenticated';
        insert into sheet_sends (job_id, sheet_id, sheet_number, from_dept, route) values (v_job, s2, 2, 'full_custom', 'finishing');
        execute 'reset role';
        ok := false; msg := 'A login wrote to sheet_sends directly, around the checks.';
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(3, 'A sheet can''t be sent before it''s done, by another department, or around the checks', ok, msg);

    -- ---- 4: to Sanding, with a count the work order didn't list ------------------------------
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'full_custom';
    perform set_config('request.jwt.claims', json_build_object('sub', fc_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_sheet(s1, 'full_custom', 'sanding'); x1 := (v->>'id')::uuid;
      select ready into n from v_ready_to_work where sheet_id = s1 and department = 'sanding';
      select ready::text || '(' || array_to_string(waiting_on, ',') || ')' into t from v_ready_to_work where sheet_id = s1 and department = 'finishing';
      execute 'reset role';
      ok := n = 2 and t = '0(sanding)'
            and (select qty_required from sheet_progress where sheet_id = s1 and department = 'sanding') = 2;
      msg := format('Expected a Sanding count of 2 made for sheet 1, 2 ready in Sanding, Finishing waiting on Sanding; got Sanding %s, Finishing %s.', coalesce(n::text, 'no row'), coalesce(t, 'no row'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Send to Sanding: Sanding gets it (a count is made if the work order had none); Finishing waits on Sanding', ok, msg);

    -- ---- 5: straight to Finishing — with no top, Sanding's count is Not needed ---------------
    begin
      execute 'set local role authenticated';
      v := send_sheet(s2, 'full_custom', 'finishing'); x2 := (v->>'id')::uuid;
      v := send_sheet(s3, 'full_custom', 'finishing');
      select ready into n from v_ready_to_work where sheet_id = s2 and department = 'finishing';
      select sanding_not_needed into ok from v_sheet_routes where sheet_id = s2;
      select ready into m from v_ready_to_work where sheet_id = s3 and department = 'sanding';
      select ready::text || '(' || array_to_string(waiting_on, ',') || ')' into t from v_ready_to_work where sheet_id = s3 and department = 'finishing';
      execute 'reset role';
      ok := ok and n = 1 and m = 1 and t = '0(sanding)'
            and (select qty_done from sheet_progress where sheet_id = s2 and department = 'sanding') = 1
            and (select qty_done from sheet_progress where sheet_id = s3 and department = 'sanding') = 0
            and exists (select 1 from progress_events where sheet_id = s2 and department = 'sanding' and source = 'Not needed — sent straight to Finishing');
      msg := format('Sheet 2 (no top) should be ready in Finishing with Sanding marked Not needed in history; sheet 3 (top + cabinet) should leave Sanding the top (1 ready) and Finishing waiting on it. Got Finishing %s, Sanding (sheet 3) %s, Finishing (sheet 3) %s.', n, m, t);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Straight to Finishing: Finishing gets it; with no top, Sanding''s count is marked Not needed (in history, not as Sanding''s work)', coalesce(ok, false), msg);

    -- ---- 6: Undo puts it back; not once the next department has counted ------------------------
    begin
      execute 'set local role authenticated';
      v := undo_sheet_send(x1);
      v := undo_sheet_send(x2);
      select ready::text || '(' || array_to_string(waiting_on, ',') || ')' into t from v_ready_to_work where sheet_id = s1 and department = 'finishing';
      execute 'reset role';
      ok := t = '0(full_custom)'
            and not exists (select 1 from sheet_progress where sheet_id = s1 and department = 'sanding')
            and (select qty_done from sheet_progress where sheet_id = s2 and department = 'sanding') = 0
            and (select count(*) from sheet_sends where id in (x1, x2) and undone_at is not null) = 2;
      msg := format('After Undo, sheet 1 should wait on Full Custom again (got %s), its made Sanding count gone, sheet 2''s Sanding back to 0, and both sends kept, marked undone.', coalesce(t, 'no row'));
      execute 'set local role authenticated';
      v := send_sheet(s1, 'full_custom', 'sanding'); x1 := (v->>'id')::uuid;
      v := send_sheet(s2, 'full_custom', 'finishing');
      execute 'reset role';
      update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'sanding';     -- Sanding counts one
      execute 'set local role authenticated';
      begin
        v := undo_sheet_send(x1);
        ok := false; msg := 'The send was undone after Sanding had counted on the sheet.';
      exception when others then ok := ok and sqlerrm like 'Sanding has already counted%';
      end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Undo puts the counts back and keeps the send in history; once the next department counts, Undo is refused', coalesce(ok, false), msg);

    -- ---- 7: Metal to paint --------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mt_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := send_sheet(s4, 'metal', 'paint');
      select ready into n from v_ready_to_work where sheet_id = s4 and department = 'metal_paint';
      select ready::text || '(' || array_to_string(waiting_on, ',') || ')' into t from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
      execute 'reset role';
      update sheet_progress set qty_done = 2 where sheet_id = s4 and department = 'metal_paint';
      select ready into m from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
      ok := n = 2 and t = '0(metal_paint)' and m = 2;
      msg := format('Expected 2 ready in Metal paint, Assembly / QC waiting on Metal paint, then 2 ready once painted; got %s, %s, %s.', n, t, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Send to paint: Finishing''s Metal paint list gets it; Assembly / QC waits until it''s painted', coalesce(ok, false), msg);

    -- ---- 8: Metal to Arrow -------------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      v := send_sheet(s5, 'metal', 'arrow'); x5 := (v->>'id')::uuid;
      select at_arrow and ready = 0 into ok from v_ready_to_work where sheet_id = s5 and department = 'assembly_qc';
      execute 'reset role';
      ok := ok and exists (select 1 from outside_jobs o join sheet_sends ss on ss.outside_job_id = o.id
                            where ss.id = x5 and o.service = 'powdercoat' and o.sheet_numbers = '{5}' and o.returned_on is null);
      update outside_jobs set returned_on = local_today(), returned_by_name = 'Send routes check'
       where id = (select outside_job_id from sheet_sends where id = x5);
      select ok and ready = 1 and not at_arrow into ok from v_ready_to_work where sheet_id = s5 and department = 'assembly_qc';
      execute 'set local role authenticated';
      begin
        v := undo_sheet_send(x5);
        ok := false;
      exception when others then ok := ok and sqlerrm like 'It''s back from Arrow already%';
      end;
      execute 'reset role';
      msg := 'Expected an Arrow item made (powdercoat, sheet 5), Assembly / QC held at Arrow, ready once returned, and no Undo after the return.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Send to Arrow: the Arrow item is made; Assembly / QC sees it only once it''s marked returned', coalesce(ok, false), msg);

    -- ---- 9: Past: Full Custom's job shows once every sheet is sent ----------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', fc_u, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_past_work where job_id = v_job and department = 'full_custom';
      v := undo_sheet_send((select id from sheet_sends where job_id = v_job and sheet_number = 2 and undone_at is null and from_dept = 'full_custom'));
      select count(*) into m from v_past_work where job_id = v_job and department = 'full_custom';
      v := send_sheet(s2, 'full_custom', 'finishing');
      execute 'reset role';
      ok := n = 3 and m = 0;
      msg := format('With all three Full Custom sheets sent, Past should list them (got %s rows); with one unsent, not at all (got %s).', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Past shows a Full Custom job once every one of its sheets is sent', coalesce(ok, false), msg);

    -- ---- 10: a change order: unchanged sheets keep their send and its count ---------------------
    update work_orders set is_current = false where id = w1;
    insert into work_orders (job_id, version, is_current) values (v_job, 2, true) returning id into w2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w2, 1, 2, 'RT-1', 'h1') returning id into n1;
    insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values (w2, 3, 1, 'RT-3', 'h3-changed') returning id into n3;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (n1, 'full_custom', 2, 2), (n1, 'finishing', 2, 0), (n1, 'assembly_qc', 2, 0),
      (n3, 'milling', 1, 0), (n3, 'cnc', 1, 0), (n3, 'sanding', 1, 0), (n3, 'full_custom', 1, 0), (n3, 'finishing', 1, 0), (n3, 'assembly_qc', 1, 0);
    set constraints all immediate;      -- what happens at the end of a real upload
    set constraints all deferred;
    select (select fc_route from v_sheet_routes where sheet_id = n1) = 'sanding'
       and (select qty_done from sheet_progress where sheet_id = n1 and department = 'sanding') = 1
       and (select fc_route from v_sheet_routes where sheet_id = n3) is null
      into ok;
    res := res || check_row(10, 'A change order: an unchanged sheet keeps its send and the count it made (with its number); a changed sheet starts over', coalesce(ok, false),
      'Sheet 1 (unchanged) should still be sent to Sanding with its Sanding count at 1; sheet 3 (changed) should have no send.');

    -- ---- 11: lanes ------------------------------------------------------------------------------
    if tst is null then
      res := res || check_row(11, 'Test jobs and real jobs stay in their own lanes', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('ROUTECHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      update sheet_progress sp set qty_done = sp.qty_required from sheets s, work_orders w
       where s.id = sp.sheet_id and w.id = s.work_order_id and w.job_id = v_test and w.is_current and sp.department = 'full_custom';
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := send_sheet((select s.id from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
                          where w.job_id = v_test and s.sheet_number = 1), 'full_custom', 'finishing');
        select count(*) filter (where job_id = v_test), count(*) filter (where job_id = v_job) into n, m from sheet_sends;
        select m + count(*) into m from v_sheet_routes where job_id = v_job;
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', fc_u, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into k from sheet_sends where job_id = v_test;
        select count(*) into t from v_sheet_routes where job_id = v_test;
        execute 'reset role';
        ok := n = 1 and m = 0 and k = 0 and t = '0';
        msg := format('The Test Supervisor saw %s test sends (1) and %s real sends or sheets (0); a real login saw %s test sends and %s test sheets (0, 0).', n, m, k, t);
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(11, 'Test jobs and real jobs stay in their own lanes', ok, msg);
    end if;

    -- ---- 12: no login ---------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    foreach t in array array['sheet_sends', 'sheet_send_effects', 'v_sheet_routes', 'v_past_work'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        if m > 0 then n := n + m; msg := concat_ws(', ', msg, format('%s rows of %s', m, t)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; n := n + 1; msg := concat_ws(', ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    begin
      execute 'set local role anon';
      v := send_sheet(s6, 'full_custom', 'sanding');
      execute 'reset role';
      n := n + 1; msg := concat_ws(', ', msg, 'a send worked with no login');
    exception when others then execute 'reset role';
    end;
    res := res || check_row(12, 'Someone with no login sees and sends nothing', n = 0, coalesce(msg, '') || '. Do not go further.');

    -- ---- 13: go-live happened once ----------------------------------------------------------------
    res := res || check_row(13, 'The one-time go-live step ran (finished sheets counted as sent)', exists (select 1 from app_settings where key = 'send_routes_started'),
      'It didn''t record that it ran. Run this file again.');

    raise exception using errcode = 'P0001', message = '__check_send_routes_undo__';
  exception when others then
    if sqlerrm <> '__check_send_routes_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_send_routes() from public, anon, authenticated;

select * from check_send_routes();
