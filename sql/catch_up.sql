-- =====================================================================
-- Shop Floor — catch-up from Monday (trial build, step 3)
--
-- HOW TO USE: run office.sql and test_lane.sql first. Then paste this
-- whole file into a NEW, empty query in the Supabase SQL Editor and
-- click Run. Safe to run more than once. Then:
--     select * from check_catch_up();
-- The catch-up itself is done from the office page (Setup → Catch up).
--
-- What it does: for every uploaded job in production, it reads the stage
-- Monday shows (Wood Status and the others) and proposes marking the
-- departments BEFORE that stage as complete. The office page shows the
-- proposal first; nothing is written until a manager ticks and applies.
--
-- The rules that keep it safe:
--   * it only fills from zero to complete — it never lowers a count
--   * the floor wins: any count a supervisor has entered is skipped
--   * the current stage is never guessed: "Sanding" marks milling and
--     CNC, never sanding itself
--   * it goes through the normal count path, so every change is in the
--     history under the manager's login, labelled "Catch-up from Monday"
--   * safe to run twice: anything already complete is skipped
--   * test jobs are never touched
--   * it only runs when a manager asks — never on a timer
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('catch_up.sql'); end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'make_test_job') then
    raise exception 'Run office.sql and test_lane.sql first (steps 1 and 2). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Where each count came from
--
-- New history rows say what made them: "Tablet", "Work order upload",
-- "Test job made" or "Catch-up from Monday". Rows written before this
-- file was run have no label.
-- ---------------------------------------------------------------------

alter table progress_events add column if not exists source text;

create or replace function sheet_progress_log() returns trigger as $$
begin
  if tg_op = 'UPDATE'
     and new.qty_done is not distinct from old.qty_done
     and new.state    is not distinct from old.state then
    return new;                      -- nothing worth recording
  end if;

  insert into progress_events (sheet_id, department, qty_from, qty_to, state_from, state_to, actor, source)
  values (new.sheet_id, new.department,
          case when tg_op = 'UPDATE' then old.qty_done end, new.qty_done,
          case when tg_op = 'UPDATE' then old.state    end, new.state,
          new.updated_by,
          coalesce(nullif(current_setting('shopfloor.source', true), ''),
                   case when tg_op = 'INSERT' then 'Work order upload' else 'Tablet' end));
  return new;
end $$ language plpgsql
   security definer set search_path = public;


-- ---------------------------------------------------------------------
-- 2. monday_stage_map — which departments count as done for each label
--
-- One row per label on each stage column. Filled with a suggestion the
-- first time a label is seen, which the office page shows and a manager
-- can change with a tick box. The suggestions are deliberately cautious:
--   Wood Status  "Milling" → nothing · "CNC" → milling · "Sanding" →
--                milling, CNC · "Finishing" → milling, CNC, sanding ·
--                "Done" → all four
--   Metal, Full Custom, Assembly/QC: only "Done" marks that department
--   Any label it doesn't recognise → nothing
-- ---------------------------------------------------------------------

create table if not exists monday_stage_map (
  column_key   text        not null references monday_columns(key),
  label        text        not null,
  departments  text[]      not null default '{}',
  set_by       uuid        references profiles(id),   -- null = the suggestion, not yet changed
  set_at       timestamptz,
  primary key (column_key, label)
);
alter table monday_stage_map enable row level security;
drop policy if exists read_stage_map on monday_stage_map;
create policy read_stage_map on monday_stage_map for select to authenticated
  using (my_role() in ('manager', 'admin'));
revoke insert, update, delete on monday_stage_map from anon, authenticated;

create or replace function suggest_stage_departments(p_key text, p_label text) returns text[]
language sql immutable as $$
  select case
    when p_label is null then '{}'::text[]
    when p_key = 'wood' then case
      when lower(p_label) ~ '\m(done|complete|completed)\M' then array['milling','cnc','sanding','finishing']
      when lower(p_label) ~ 'finish'                         then array['milling','cnc','sanding']
      when lower(p_label) ~ 'sand'                           then array['milling','cnc']
      when lower(p_label) ~ '\mcnc\M'                        then array['milling']
      else '{}'::text[] end
    when lower(p_label) ~ '\m(done|complete|completed)\M' then case p_key
      when 'metal'       then array['metal']
      when 'full_custom' then array['full_custom']
      when 'assembly_qc' then array['assembly_qc']
      else '{}'::text[] end
    else '{}'::text[] end;
$$;

-- add any label not yet in the map: from the board's label list, and from
-- whatever the sync has actually seen on jobs. Never changes existing rows.
create or replace function refresh_stage_map() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into monday_stage_map (column_key, label, departments)
  select key, label, suggest_stage_departments(key, label) from (
    select mc.key, l as label
      from monday_columns mc, jsonb_array_elements_text(mc.labels) l
     where mc.key <> 'handed_off' and mc.column_id is not null
    union
    select e.key, e.value #>> '{}'
      from jobs j, jsonb_each(j.monday_stages) e
     where not j.is_test and e.key <> 'handed_off' and nullif(e.value #>> '{}', '') is not null
  ) x
  where exists (select 1 from monday_columns where key = x.key)
  on conflict (column_key, label) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function refresh_stage_map() from public, anon;
grant execute on function refresh_stage_map() to authenticated;

create or replace function set_stage_map(p_column text, p_label text, p_departments text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare d text;
begin
  if not is_manager_or_editor() then
    raise exception 'Only a manager can change the catch-up rules.' using errcode = 'insufficient_privilege';
  end if;
  foreach d in array coalesce(p_departments, '{}') loop
    if not exists (select 1 from departments where key = d) then
      raise exception '"%" is not a department.', d;
    end if;
  end loop;
  update monday_stage_map set departments = coalesce(p_departments, '{}'), set_by = auth.uid(), set_at = now()
   where column_key = p_column and label = p_label;
  if not found then
    raise exception 'There''s no label "%" on %.', p_label, p_column;
  end if;
  return coalesce(p_departments, '{}');
end;
$$;
revoke all on function set_stage_map(text, text, text[]) from public, anon;
grant execute on function set_stage_map(text, text, text[]) to authenticated;


-- ---------------------------------------------------------------------
-- 3. The plan — shared by the preview and the apply, so what's shown is
--    exactly what's written
--
-- One row per job × department it would fill. Real, active, linked jobs
-- with a current work order only.
-- ---------------------------------------------------------------------

create or replace function catch_up_plan(p_jobs uuid[] default null)
returns table (job_id uuid, department text, because text,
               rows_to_fill int, pieces_to_fill int, rows_counted int, rows_complete int)
language sql stable security definer set search_path = public as $$
  with want as (           -- the departments Monday's stages say are done, and which label said so
    select j.id as job_id, d as department, string_agg(distinct mc.what || ': ' || (e.value #>> '{}'), ' · ') as because
      from jobs j
      join jsonb_each(j.monday_stages) e on nullif(e.value #>> '{}', '') is not null
      join monday_columns mc   on mc.key = e.key
      join monday_stage_map m  on m.column_key = e.key and m.label = e.value #>> '{}'
      cross join lateral unnest(m.departments) d
     where j.is_active and not j.is_test and j.monday_item_id is not null
       and (p_jobs is null or j.id = any(p_jobs))
     group by j.id, d
  )
  select w.job_id, w.department, w.because,
         count(*) filter (where sp.qty_done = 0)::int,
         coalesce(sum(sp.qty_required) filter (where sp.qty_done = 0), 0)::int,
         count(*) filter (where sp.qty_done > 0 and sp.qty_done < sp.qty_required)::int,
         count(*) filter (where sp.qty_done >= sp.qty_required)::int
    from want w
    join work_orders wo    on wo.job_id = w.job_id and wo.is_current
    join sheets s          on s.work_order_id = wo.id
    join sheet_progress sp on sp.sheet_id = s.id and sp.department = w.department
   group by w.job_id, w.department, w.because;
$$;
revoke all on function catch_up_plan(uuid[]) from public, anon, authenticated;

-- What the office page shows: one row per uploaded job in production,
-- whether or not there's anything to fill, with a plain sentence.
create or replace function catch_up_preview()
returns table (job_id uuid, project_id text, job_name text, delivery_date date,
               monday_says text, plan jsonb, pieces_to_fill int, line text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager_or_editor() then
    raise exception 'Only a manager can use the catch-up.' using errcode = 'insufficient_privilege';
  end if;
  perform refresh_stage_map();
  return query
  with p as (select * from catch_up_plan(null)),
  jobs_in as (
    select j.* from jobs j join work_orders w on w.job_id = j.id and w.is_current
     where j.is_active and not j.is_test and j.monday_item_id is not null
  )
  select j.id, j.project_id, j.name, j.delivery_date,
         coalesce((select string_agg(mc.what || ': ' || (e.value #>> '{}'), ' · ' order by mc.sort_order)
                     from jsonb_each(j.monday_stages) e join monday_columns mc on mc.key = e.key
                    where nullif(e.value #>> '{}', '') is not null), 'no stage in Monday'),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'department', p.department, 'name', d.name, 'rows_to_fill', p.rows_to_fill,
                     'pieces_to_fill', p.pieces_to_fill, 'rows_counted', p.rows_counted, 'rows_complete', p.rows_complete)
                     order by d.sort_order)
                     from p join departments d on d.key = p.department where p.job_id = j.id), '[]'::jsonb),
         coalesce((select sum(p.pieces_to_fill) from p where p.job_id = j.id), 0)::int,
         coalesce(
           (select 'Will mark ' || string_agg(format('%s %s/%s', d.name, p.pieces_to_fill,
                     (select coalesce(sum(sp.qty_required),0) from work_orders wo join sheets s on s.work_order_id = wo.id
                        join sheet_progress sp on sp.sheet_id = s.id and sp.department = p.department
                       where wo.job_id = j.id and wo.is_current)), ' and ' order by d.sort_order)
                   || coalesce(' · skips ' || nullif((select sum(p2.rows_counted) from p p2 where p2.job_id = j.id), 0)
                               || ' sheet' || case when (select sum(p2.rows_counted) from p p2 where p2.job_id = j.id) = 1 then '' else 's' end
                               || ' a supervisor has counted', '')
              from p join departments d on d.key = p.department where p.job_id = j.id and p.pieces_to_fill > 0),
           case when exists (select 1 from p where p.job_id = j.id and (p.rows_counted > 0 or p.rows_complete > 0))
                then 'Nothing to fill — already counted or complete'
                when not exists (select 1 from jsonb_each(j.monday_stages) e where nullif(e.value #>> '{}', '') is not null)
                then 'Nothing to fill — Monday shows no stage yet'
                else 'Nothing to fill — Monday''s stage is the first one, so the supervisor enters it' end)
    from jobs_in j
   order by (coalesce((select sum(p.pieces_to_fill) from p where p.job_id = j.id), 0) = 0), j.delivery_date nulls last, j.project_id;
end;
$$;
revoke all on function catch_up_preview() from public, anon;
grant execute on function catch_up_preview() to authenticated;


-- ---------------------------------------------------------------------
-- 4. catch_up_apply(job ids) — write the ticked jobs
--
-- Recomputes the plan itself rather than trusting the page, fills only
-- rows still at zero, and labels every change "Catch-up from Monday".
-- ---------------------------------------------------------------------

create or replace function catch_up_apply(p_jobs uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rows   int := 0;
  v_pieces int := 0;
  v_lines  text[] := '{}';
  r        record;
  n        int;
  q        int;
begin
  if not is_manager_or_editor() then
    raise exception 'Only a manager can use the catch-up.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(array_length(p_jobs, 1), 0) = 0 then
    return jsonb_build_object('ok', true, 'rows', 0, 'pieces', 0, 'lines', '[]'::jsonb, 'summary', 'Nothing was ticked, so nothing changed.');
  end if;

  perform set_config('shopfloor.source', 'Catch-up from Monday', true);

  for r in
    select p.job_id, j.project_id, string_agg(d.name, ' and ' order by d.sort_order) as depts,
           array_agg(p.department) as dept_keys, max(p.because) as because
      from catch_up_plan(p_jobs) p
      join jobs j        on j.id = p.job_id
      join departments d on d.key = p.department
     where p.rows_to_fill > 0
     group by p.job_id, j.project_id
     order by j.project_id
  loop
    with filled as (
      update sheet_progress sp set qty_done = sp.qty_required
        from sheets s, work_orders wo
       where s.id = sp.sheet_id and wo.id = s.work_order_id and wo.job_id = r.job_id and wo.is_current
         and sp.department = any(r.dept_keys)
         and sp.qty_done = 0                      -- the floor wins: anything counted is left alone
      returning sp.qty_required)
    select count(*), coalesce(sum(qty_required), 0) into n, q from filled;
    v_rows := v_rows + n; v_pieces := v_pieces + q;
    if n > 0 then
      v_lines := v_lines || format('%s — marked %s complete (%s pieces).', r.project_id, r.depts, q);
    end if;
  end loop;

  perform set_config('shopfloor.source', '', true);

  return jsonb_build_object('ok', true, 'rows', v_rows, 'pieces', v_pieces, 'lines', to_jsonb(v_lines),
    'summary', case when v_rows = 0 then 'Nothing needed filling — it had all been done already.'
                    else format('Caught up %s job%s: %s pieces marked complete, recorded as "Catch-up from Monday".',
                                array_length(v_lines, 1), case when array_length(v_lines, 1) = 1 then '' else 's' end, v_pieces) end);
end;
$$;
revoke all on function catch_up_apply(uuid[]) from public, anon;
grant execute on function catch_up_apply(uuid[]) to authenticated;


-- fill the map with suggestions for every label seen so far
do $$ begin perform refresh_stage_map(); end $$;


-- ---------------------------------------------------------------------
-- 5. check_catch_up() — the PASS / FAIL check
--
-- Builds a throwaway job that Monday "shows at Sanding", with one sheet
-- untouched and one a supervisor has already started, runs the catch-up
-- on it twice, checks what happened, then removes it.
--
--     select * from check_catch_up();
-- ---------------------------------------------------------------------

create or replace function check_catch_up()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  mgr   uuid;
  v_job uuid;
  v_tst uuid;
  v_wo  uuid;
  s1    uuid;
  s2    uuid;
  n     int;
  v_res jsonb;
  ok    boolean;
  msg   text;
begin
  delete from jobs where project_id in ('CATCHUPCHECK', 'TEST-CATCHUPCHECK');
  delete from monday_stage_map where label = '__catch-up check__';

  step := 1; check_name := 'The stage columns have been found on the Monday board';
  select count(*) into n from monday_columns where key <> 'handed_off' and column_id is not null;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  if_it_failed := case when n > 0 then null else 'Run: select * from setup_monday_columns();  then  select run_monday_sync();' end;
  return next;

  step := 2; check_name := 'The sync has read the stages onto jobs';
  select count(*) into n from jobs where not is_test and monday_stages <> '{}'::jsonb;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  if_it_failed := case when n > 0 then null else 'No job has a stage yet. Run the sync once: select run_monday_sync();' end;
  return next;

  step := 3; check_name := 'Every stage label has a catch-up rule';
  perform refresh_stage_map();
  select count(*) into n from monday_stage_map;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  if_it_failed := case when n > 0 then format('%s labels, %s of them mark something.', n,
                   (select count(*) from monday_stage_map where cardinality(departments) > 0))
                  else 'No labels found. Check steps 1 and 2.' end;
  if n > 0 then if_it_failed := null; end if;
  return next;

  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  -- a throwaway job: Monday "says" a made-up label that means milling + CNC are done
  insert into monday_stage_map (column_key, label, departments) values ('wood', '__catch-up check__', array['milling','cnc']);
  insert into jobs (monday_item_id, project_id, name, is_active, monday_stages)
    values (-999997, 'CATCHUPCHECK', 'Catch-up check - safe to delete', true, '{"wood":"__catch-up check__"}') returning id into v_job;
  insert into work_orders (job_id) values (v_job) returning id into v_wo;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 3) returning id into s1;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 2, 2) returning id into s2;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
    (s1, 'milling', 3, 0), (s1, 'cnc', 3, 0), (s1, 'sanding', 3, 0),
    (s2, 'milling', 2, 2), (s2, 'cnc', 2, 1), (s2, 'sanding', 2, 0);
  -- and a test job saying the same thing, which must be ignored
  insert into jobs (project_id, name, is_active, is_test, monday_stages)
    values ('TEST-CATCHUPCHECK', 'Catch-up check test job', true, true, '{"wood":"__catch-up check__"}') returning id into v_tst;
  insert into work_orders (job_id) values (v_tst) returning id into v_wo;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 3) returning id into s2;
  insert into sheet_progress (sheet_id, department, qty_required) values (s2, 'milling', 3), (s2, 'cnc', 3);
  select w.id into v_wo from work_orders w where w.job_id = v_job;
  select id into s2 from sheets where work_order_id = v_wo and sheet_number = 2;

  step := 4; check_name := 'The preview proposes the right pieces, and skips what the floor counted';
  select coalesce(sum(pieces_to_fill), 0) into n from catch_up_plan(array[v_job]);
  -- sheet 1: milling 3 + CNC 3 = 6 pieces. Sheet 2: milling already done, CNC counted by a supervisor.
  ok := n = 6 and exists (select 1 from catch_up_plan(array[v_job]) where department = 'cnc' and rows_counted = 1)
        and not exists (select 1 from catch_up_plan(null) where job_id = v_tst);
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else format('Expected 6 pieces proposed with one CNC sheet skipped; got %s.', n) end;
  return next;

  step := 5; check_name := 'Applying it marks milling and CNC — never the current stage';
  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  begin
    v_res := catch_up_apply(array[v_job, v_tst]);
    ok := (select qty_done from sheet_progress where sheet_id = s1 and department = 'milling') = 3
      and (select qty_done from sheet_progress where sheet_id = s1 and department = 'cnc') = 3
      and (select qty_done from sheet_progress where sheet_id = s1 and department = 'sanding') = 0;
    msg := case when ok then null else 'The counts after applying weren''t right: ' || coalesce(v_res->>'summary', '') end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 6; check_name := 'The floor wins: a count a supervisor entered is left alone';
  ok := (select qty_done from sheet_progress where sheet_id = s2 and department = 'cnc') = 1;
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'The catch-up overwrote a supervisor''s count.' end; return next;

  step := 7; check_name := 'Recorded in history as "Catch-up from Monday", under the manager';
  select count(*) into n from progress_events where sheet_id = s1 and source = 'Catch-up from Monday'
     and (actor = mgr or mgr is null);
  ok := n = 2;
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else format('Expected 2 history rows labelled "Catch-up from Monday"; found %s.', n) end; return next;

  step := 8; check_name := 'Running it twice changes nothing more';
  begin
    v_res := catch_up_apply(array[v_job]);
    ok := (v_res->>'rows')::int = 0;
    msg := case when ok then null else 'The second run changed ' || (v_res->>'rows') || ' more rows.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 9; check_name := 'Test jobs are never caught up';
  ok := not exists (select 1 from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id
                     where w.job_id = v_tst and sp.qty_done > 0);
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'The catch-up changed a test job.' end; return next;

  step := 10; check_name := 'An ordinary tablet count is still labelled "Tablet"';
  update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'sanding';
  ok := exists (select 1 from progress_events where sheet_id = s1 and department = 'sanding' and source = 'Tablet');
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'A normal count was labelled wrongly — the catch-up label may be leaking.' end; return next;

  perform set_config('request.jwt.claims', '', true);
  delete from jobs where id in (v_job, v_tst);
  delete from monday_stage_map where label = '__catch-up check__';
end;
$$;
revoke all on function check_catch_up() from public, anon, authenticated;
