-- =====================================================================
-- job_items.sql — Job status, item by item (4 Nov 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 55. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE the new status.html goes on GitHub. Today's status.html
-- keeps working with it: every field it reads is still there.
--
-- WHAT IT DOES (design: the Job status tab, Item detail, 4 Nov)
-- job_lookup() (job_status.sql) answers with each item (work order sheet)
-- carrying more, for status.html's Items list and item pages:
--   page       its work order page image (the work-orders bucket), for
--              everyone with Job status, look-up logins too (Luke, 4 Nov)
--   arrow      its Arrow item: PO number, since, waiting, back
--   went, went_on, went_kind  how many of its pieces finished trips took
--              (a part trip's own list, a rest's owed list, or all of it)
--   issue      its newest open issue and how many are open; never for a
--              look-up login
-- The 3D design isn't here: status.html asks item_designs, whose own rule
-- (design_viewer.sql) never gives a look-up login a row.
-- Replaces job_status_json() from job_status.sql, so that file now stops
-- if run again. Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('job_items.sql', 55, 'check_job_items', 'check_job_items', '{job_status.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('job_items.sql', '{job_status.sql}'); end if;
end $$;

-- One job, as status.html draws it. Only job_lookup() calls this.
create or replace function job_status_json(p_job uuid, p_look boolean)
returns jsonb
language sql stable set search_path = public as $$
  with j as (select * from jobs where id = p_job),
  sp as (
    select p.department, p.qty_required, p.qty_done, p.completed_at
      from sheets s
      join work_orders w on w.id = s.work_order_id and w.is_current and w.job_id = p_job
      join sheet_progress p on p.sheet_id = s.id
  ),
  d as (
    select sp.department as key, min(dp.name) as name, min(dp.sort_order) as sort_order,
           sum(sp.qty_required)::int as total, sum(sp.qty_done)::int as done, max(sp.completed_at) as last_done
      from sp join departments dp on dp.key = sp.department
     group by sp.department
  ),
  allp as (
    select s.sheet_number || ':' || g as piece
      from sheets s join work_orders w on w.id = s.work_order_id and w.is_current and w.job_id = p_job
     cross join generate_series(1, greatest(coalesce(s.qty, 0), 0)) g
  ),
  carried as (    -- every piece a finished trip took: its own list if it went part-way, a rest's owed list, or all of it
    select x as piece, t.completed_at as done_at, trip_kind_name(t.kind) as kind
      from v_deliveries t
     cross join lateral unnest(case when t.part is not null then array(select jsonb_array_elements_text(t.part -> 'went_pieces'))
                                    when t.owed is not null then t.owed
                                    else array(select piece from allp) end) x
     where t.job_id = p_job and t.completed_at is not null
  ),
  rd as (
    select r.department, sum(r.ready)::int as ready, bool_or(r.held_for_handoff) as held,
           (select coalesce(jsonb_agg(distinct coalesce(x.name, w)), '[]'::jsonb)
              from v_ready_to_work r2 cross join unnest(r2.waiting_on) w left join departments x on x.key = w
             where r2.job_id = p_job and r2.department = r.department) as waiting
      from v_ready_to_work r where r.job_id = p_job group by r.department
  )
  select jsonb_build_object(
    'job_id', j.id, 'proj', j.project_id, 'name', j.name, 'phase', j.phase,
    'delivery', j.delivery_date, 'handed_off', j.handed_off, 'active', j.is_active, 'test', j.is_test,
    'departments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', d.key, 'name', d.name, 'total', d.total, 'done', d.done,
               'done_on', case when d.done >= d.total then (d.last_done at time zone 'America/Indiana/Indianapolis')::date end,
               'ready', coalesce(rd.ready, 0), 'waiting', coalesce(rd.waiting, '[]'::jsonb), 'held', coalesce(rd.held, false),
               'finish_by', case when not p_look then (select j.delivery_date - n.days from v_finish_by_days n where n.department = d.key) end)
             order by d.sort_order, d.key)
        from d left join rd on rd.department = d.key), '[]'::jsonb),
    'arrow', coalesce((
      select jsonb_agg(jsonb_build_object('sheets', o.sheet_numbers, 'waiting', o.waiting,
               'since', coalesce((o.gone_at at time zone 'America/Indiana/Indianapolis')::date, o.sent_on), 'days_out', o.days_out)
             order by o.sent_on)
        from v_outside_jobs o where o.job_id = p_job and not coalesce(o.voided, false) and o.returned_on is null), '[]'::jsonb),
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', trip_kind_name(t.kind),
               'day', (t.scheduled_for at time zone 'America/Indiana/Indianapolis')::date,
               'time', case when t.kind = 'delivery' then lower(to_char(t.scheduled_for at time zone 'America/Indiana/Indianapolis', 'FMHH12:MI am')) end,
               'ready', t.ready_at is not null and t.completed_at is null,
               'done_on', (t.completed_at at time zone 'America/Indiana/Indianapolis')::date,
               'went', case when t.completed_at is null then null
                            when t.part is not null then (t.part->>'went')::int
                            when t.rest is not null then (t.rest->>'count')::int
                            else t.pieces_total end,
               'of', t.pieces_total)
             order by coalesce(t.completed_at, t.scheduled_for, t.ready_at))
        from v_deliveries t where t.job_id = p_job), '[]'::jsonb),
    'sheets', coalesce((
      select jsonb_agg(jsonb_build_object('n', s.sheet_number, 'code', s.item_code, 'qty', s.qty, 'page', s.png_path,
               'p', coalesce((select jsonb_object_agg(p.department, jsonb_build_object('done', p.qty_done, 'of', p.qty_required))
                                from sheet_progress p where p.sheet_id = s.id), '{}'::jsonb),
               'arrow', (select jsonb_build_object('po', case when a.po_number is not null then 'AR-' || a.po_number end,
                                  'waiting', o.waiting, 'back', o.returned_on,
                                  'since', coalesce((o.gone_at at time zone 'America/Indiana/Indianapolis')::date, o.sent_on))
                           from outside_jobs o left join arrow_pos a on a.id = o.po_id
                          where o.job_id = p_job and o.voided_at is null and s.sheet_number = any(o.sheet_numbers)
                          order by (o.returned_on is null) desc, o.sent_on desc limit 1),
               'went', (select count(distinct c.piece)::int from carried c where split_part(c.piece, ':', 1) = s.sheet_number::text),
               'went_on', (select (max(c.done_at) at time zone 'America/Indiana/Indianapolis')::date from carried c
                            where split_part(c.piece, ':', 1) = s.sheet_number::text),
               'went_kind', (select c.kind from carried c where split_part(c.piece, ':', 1) = s.sheet_number::text order by c.done_at desc limit 1),
               'issue', case when not p_look then
                          (select jsonb_build_object('open', count(*) over (), 'dept', coalesce(x.name, pr.department),
                                    'text', left(pr.body, 160), 'stopped', pr.work_stopped,
                                    'at', (pr.raised_at at time zone 'America/Indiana/Indianapolis')::date)
                             from problems pr left join departments x on x.key = pr.department
                            where pr.job_id = p_job and pr.sheet_number = s.sheet_number and pr.status = 'open'
                            order by pr.raised_at desc limit 1) end)
             order by s.sheet_number)
        from sheets s join work_orders w on w.id = s.work_order_id and w.is_current and w.job_id = p_job), '[]'::jsonb)
  ) from j;
$$;
revoke all on function job_status_json(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- check_job_items(): the PASS / FAIL check
--
-- Makes a throwaway job (two sheets, an open issue on sheet 1, an Arrow
-- item on sheet 2, a trip that took part and its rest), a look-up login
-- and a supervisor, asks as each, then undoes everything.
-- ---------------------------------------------------------------------
create or replace function check_job_items()
returns table(step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  res   jsonb := '[]'::jsonb;
  look  uuid := '00000000-0000-4000-8000-00000000c055';
  sup   uuid := '00000000-0000-4000-8000-00000000c056';
  v_job uuid; v_wo uuid; s1 uuid; s2 uuid;
  r jsonb; ok boolean; msg text; n int;
begin
  -- ---- 1: only job_lookup() builds an item's status; no login runs the builder itself ------------------
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'job_status_json' and grantee in ('anon', 'authenticated', 'PUBLIC');
  res := res || check_row(1, 'Only job_lookup() builds a job''s and its items'' status; no login can run the builder itself', n = 0,
                          format('%s grants on job_status_json. Run job_items.sql again.', n));

  begin    -- everything below is undone at the end
    insert into auth.users (id, email) values (look, 'check-items-look@example.com'), (sup, 'check-items-sup@example.com');
    insert into profiles (id, full_name, role, departments, look_up) values (look, 'Items check (look-up)', 'supervisor', '{}', true), (sup, 'Items check', 'supervisor', '{finishing}', false);
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999955, 'PROJ-99955', 'Job items check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, item_code, qty, png_path) values (v_wo, 1, 'TA-01', 4, 'PROJ-99955/page-1.png') returning id into s1;
    insert into sheets (work_order_id, sheet_number, item_code, qty, png_path) values (v_wo, 2, 'TA-02', 2, 'PROJ-99955/page-2.png') returning id into s2;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1, 'finishing', 4, 4), (s2, 'finishing', 2, 2), (s2, 'metal', 2, 2);
    insert into problems (job_id, sheet_number, department, body, work_stopped, status, is_test) values (v_job, 1, 'finishing', 'Items check', true, 'open', false);
    insert into outside_jobs (job_id, sheet_numbers, description, vendor, service, department, sent_on, gone_at, is_test)
      values (v_job, '{2}', 'Items check', 'Arrow', 'powdercoat', 'metal', local_today() - 3, now() - interval '3 days', false);
    insert into loadouts (id, job_id, kind, scheduled_for, started_at, completed_at, is_test)
      values ('00000000-0000-4000-8000-0000000c05a1', v_job, 'dock', now() - interval '2 days', now() - interval '2 days', now() - interval '2 days', false),
             ('00000000-0000-4000-8000-0000000c05a2', v_job, 'dock', now() - interval '1 day', now() - interval '1 day', now() - interval '1 day', false);
    insert into trip_parts (loadout_id, rest_id, is_test, reason, went_pieces, left_pieces, by_name)
      values ('00000000-0000-4000-8000-0000000c05a1', '00000000-0000-4000-8000-0000000c05a2', false, 'Damaged', '{1:1,1:2}', '{1:3,2:1}', 'check');

    -- ---- 2: a look-up login: each item's page, its Arrow and its trip, never its issue -------------------
    perform set_config('request.jwt.claims', json_build_object('sub', look, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := job_lookup('PROJ-99955'); execute 'reset role';
      ok := r#>>'{jobs,0,sheets,0,page}' = 'PROJ-99955/page-1.png' and r#>>'{jobs,0,sheets,1,page}' = 'PROJ-99955/page-2.png'
            and r#>'{jobs,0,sheets,0,issue}' = 'null'::jsonb;
      msg := left(r#>>'{jobs,0,sheets}', 220);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(2, 'A look-up login gets each item''s work order page, and not its open issue', ok, msg);

    -- ---- 3: Arrow shows on the sheet it went out with, not the others ------------------------------------
    ok := r#>'{jobs,0,sheets,0,arrow}' = 'null'::jsonb and r#>>'{jobs,0,sheets,1,arrow,since}' = (local_today() - 3)::text
          and (r#>>'{jobs,0,sheets,1,arrow,waiting}')::boolean = false and r#>'{jobs,0,sheets,1,arrow,back}' = 'null'::jsonb;
    res := res || check_row(3, 'An Arrow item shows on the sheet it went out with, and not on the others', ok,
                            case when not ok then format('sheet 1: %s; sheet 2: %s', r#>>'{jobs,0,sheets,0,arrow}', r#>>'{jobs,0,sheets,1,arrow}') end);

    -- ---- 4: a trip that took part, then its rest: each sheet counts the pieces that went -----------------
    ok := (r#>>'{jobs,0,sheets,0,went}')::int = 3 and (r#>>'{jobs,0,sheets,1,went}')::int = 1
          and r#>>'{jobs,0,sheets,0,went_kind}' is not null;
    res := res || check_row(4, 'After a trip that took 2 pieces of sheet 1 and its rest that took 2 more, sheet 1 shows 3 of 4 went and sheet 2 1 of 2', ok,
                            case when not ok then format('sheet 1 went %s, sheet 2 went %s', r#>>'{jobs,0,sheets,0,went}', r#>>'{jobs,0,sheets,1,went}') end);

    -- ---- 5: a supervisor also gets the item's open issue -------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := job_lookup('PROJ-99955'); execute 'reset role';
      ok := (r#>>'{jobs,0,sheets,0,issue,open}')::int = 1 and (r#>>'{jobs,0,sheets,0,issue,stopped}')::boolean
            and r#>'{jobs,0,sheets,1,issue}' = 'null'::jsonb and r#>>'{jobs,0,sheets,0,page}' = 'PROJ-99955/page-1.png';
      msg := format('sheet 1 issue %s; sheet 2 issue %s', r#>>'{jobs,0,sheets,0,issue}', r#>>'{jobs,0,sheets,1,issue}');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'A supervisor gets the open issue on the sheet it was raised on (work stopped), and none on the other', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_job_items_undo__';
  exception when others then
    begin execute 'reset role'; exception when others then null; end;
    if sqlerrm <> '__check_job_items_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_job_items() from public, anon, authenticated;

select * from check_job_items();
