-- =====================================================================
-- job_status.sql — Job status: look a job up by PROJ number or name (28 Oct 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 47. Safe to run twice.
-- Registers itself: one paste, no need to run install_log.sql after it.
-- The last result is the PASS/FAIL table: every row should say PASS.
-- Run it BEFORE status.html goes on GitHub. Nothing the tablets, the TV,
-- the office or Julia's page read changes for any login they use.
--
-- WHAT IT DOES (design: the Job status tab, 28 Oct)
-- 1. Look-up logins (profiles.look_up), for sales: they open status.html
--    and nothing else. set_look_up('email') from the SQL Editor makes
--    one, and refuses a login that counts, looks at a department,
--    schedules, manages or tests.
-- 2. sees_lane() says no to a look-up login, so it reads none of the
--    floor's logs: issues, defects, flags, photos, trips, tickets and site
--    files, Arrow, supplies, sends, QC, routine tasks. Everyone else reads
--    exactly what they did before.
-- 3. job_lookup(text): finds jobs by PROJ number or words of the name and
--    returns what status.html shows: Monday's phase and delivery date, each
--    department's pieces done and ready, Arrow, trips and the sheet grid.
--    Sheet number and item code only, never work order content. Done-by
--    dates go to supervisors and managers, not to look-up logins.
-- 4. check_job_status(): the PASS/FAIL check (it undoes itself).
-- Replaces sees_lane() from problems.sql, so that file now stops if run
-- again. Nothing is deleted.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('job_status.sql', 47, 'check_job_status', 'check_job_status', '{problems.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('job_status.sql', '{problems.sql}'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Look-up logins
-- ---------------------------------------------------------------------
alter table profiles add column if not exists look_up boolean not null default false;
revoke insert, update, delete, truncate on profiles from anon, authenticated;

create or replace function am_look_up() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select look_up from profiles where id = auth.uid()), false);
$$;
revoke all on function am_look_up() from public, anon, authenticated;

create or replace function set_look_up(p_email text, p_on boolean default true)
returns text
language plpgsql set search_path = public as $$
declare
  v profiles;
begin
  select p.* into v from auth.users u join profiles p on p.id = u.id
   where lower(u.email) = lower(trim(p_email));
  if v.id is null then
    raise exception 'No login with a profile has the address %. Make the login in Supabase (Authentication, Add user), give it a profile in set_up_logins.sql, then run this again.', p_email;
  end if;
  if not coalesce(p_on, true) then
    update profiles set look_up = false where id = v.id;
    return format('%s is no longer a look-up login.', v.full_name);
  end if;
  if v.role in ('manager', 'admin') then
    raise exception '% is a manager. A look-up login is for someone who only looks.', v.full_name;
  end if;
  if cardinality(coalesce(v.departments, '{}')) > 0 or cardinality(coalesce(v.look_departments, '{}')) > 0 then
    raise exception '% works in or looks at a department on the tablet. A look-up login has no departments: give them none first.', v.full_name;
  end if;
  if coalesce(v.schedules_deliveries, false) then
    raise exception '% schedules deliveries. A look-up login only looks.', v.full_name;
  end if;
  if coalesce(v.is_test, false) then
    raise exception '% is a test login. Look-up logins are real people.', v.full_name;
  end if;
  update profiles set look_up = true where id = v.id;
  return format('%s can now look up jobs on status.html, and nothing else.', v.full_name);
end;
$$;
revoke all on function set_look_up(text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. The lane rule: a look-up login sees none of the floor's logs
-- ---------------------------------------------------------------------
create or replace function sees_lane(p_is_test boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select (coalesce(p_is_test, false) = am_test() and not am_look_up()) or is_manager();
$$;
revoke all on function sees_lane(boolean) from public, anon;
grant execute on function sees_lane(boolean) to authenticated;

-- refresh_stage_map() (catch_up.sql) adds Monday labels to the catch-up's map. No page calls it; it
-- runs from the SQL Editor. Until now any signed-in login could run it too: no longer.
revoke execute on function refresh_stage_map() from authenticated;

-- ---------------------------------------------------------------------
-- 3. job_lookup(): what status.html shows
-- ---------------------------------------------------------------------
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
      select jsonb_agg(jsonb_build_object('n', s.sheet_number, 'code', s.item_code, 'qty', s.qty,
               'p', coalesce((select jsonb_object_agg(p.department, jsonb_build_object('done', p.qty_done, 'of', p.qty_required))
                                from sheet_progress p where p.sheet_id = s.id), '{}'::jsonb))
             order by s.sheet_number)
        from sheets s join work_orders w on w.id = s.work_order_id and w.is_current and w.job_id = p_job), '[]'::jsonb)
  ) from j;
$$;
revoke all on function job_status_json(uuid, boolean) from public, anon, authenticated;

create or replace function job_lookup(p_q text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me      profiles;
  v_mgr   boolean;
  v_look  boolean;
  v_test  boolean;
  v_q     text := lower(btrim(coalesce(p_q, '')));
  v_dig   text;
  v_words text[];
  v_out   jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sign in to look up a job.' using errcode = 'insufficient_privilege';
  end if;
  select * into me from profiles where id = auth.uid();
  if me.id is null then
    raise exception 'This login can''t look up jobs.' using errcode = 'insufficient_privilege';
  end if;
  v_mgr  := me.role in ('manager', 'admin');
  v_look := coalesce(me.look_up, false) and not v_mgr;
  v_test := coalesce(me.is_test, false);
  if v_q = '' or length(v_q) > 80 then
    return jsonb_build_object('at', now(), 'look_up', v_look, 'jobs', '[]'::jsonb);
  end if;
  v_dig   := ltrim(regexp_replace(v_q, '\D', '', 'g'), '0');
  v_words := regexp_split_to_array(v_q, '\s+');

  select coalesce(jsonb_agg(job_status_json(f.id, v_look) order by f.is_active desc, f.project_id desc nulls last), '[]'::jsonb)
    into v_out
    from (select j.id, j.is_active, j.project_id from jobs j
           where (coalesce(j.is_test, false) = v_test or v_mgr)
             and ((v_dig <> '' and ltrim(regexp_replace(coalesce(j.project_id, ''), '\D', '', 'g'), '0') like '%' || v_dig || '%')
                  or not exists (select 1 from unnest(v_words) w
                                  where position(w in lower(coalesce(j.name, '') || ' ' || coalesce(j.project_id, ''))) = 0))
           order by j.is_active desc, j.project_id desc nulls last
           limit 20) f;
  return jsonb_build_object('at', now(), 'look_up', v_look, 'jobs', v_out);
end;
$$;
revoke all on function job_lookup(text) from public, anon;
grant execute on function job_lookup(text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. check_job_status(): the PASS / FAIL check
--
-- Makes a throwaway job, a look-up login and a supervisor, tries things
-- as each, then undoes everything.
-- ---------------------------------------------------------------------
create or replace function check_job_status()
returns table(step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  res     jsonb := '[]'::jsonb;
  look    uuid := '00000000-0000-4000-8000-00000000c047';
  sup     uuid := '00000000-0000-4000-8000-00000000c048';
  ghost   uuid := '00000000-0000-4000-8000-00000000c049';
  v_job   uuid; v_test_job uuid; v_wo uuid; v_sheet uuid; p_fin uuid;
  r       jsonb; ok boolean; msg text; n int; m int; txt text;
begin
  -- ---- 1: only the SQL Editor makes a look-up login; no login runs the setup or the inside helpers --
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name in ('set_look_up', 'am_look_up', 'job_status_json', 'refresh_stage_map')
     and grantee in ('anon', 'authenticated', 'PUBLIC');
  select count(*) into m from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'job_lookup' and grantee in ('anon', 'PUBLIC');
  res := res || check_row(1, 'Only the SQL Editor can make a look-up login or refresh the catch-up''s map, and job_lookup() needs a login', n = 0 and m = 0,
                          format('%s grants on the setup and helpers, %s on job_lookup for no login. Run job_status.sql again.', n, m));

  begin    -- everything below is undone at the end
    insert into auth.users (id, email) values (look, 'check-lookup-' || look || '@example.com'), (sup, 'check-sup-' || sup || '@example.com');
    insert into profiles (id, full_name, role, departments) values (look, 'Lookup check', 'supervisor', '{}'), (sup, 'Finishing check', 'supervisor', '{finishing}');
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, handed_off)
      values (-999947, 'PROJ-99947', 'Job status check - undone automatically', true, 'In Production', local_today() + 20, true) returning id into v_job;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, is_test)
      values (-999948, 'TEST-99947', 'Job status check (test lane) - undone automatically', true, 'In Production', true) returning id into v_test_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, item_code, qty) values (v_wo, 1, 'TA-01', 4) returning id into v_sheet;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (v_sheet, 'sanding', 4, 4);
    insert into sheet_progress (sheet_id, department, qty_required) values (v_sheet, 'finishing', 4) returning id into p_fin;
    insert into problems (job_id, department, body, is_test) values (v_job, 'finishing', 'Job status check', false);
    insert into flags (job_id, level, note, is_test) values (v_job, 'watch', 'Job status check', false);

    -- ---- 2: set_look_up() makes the login, and refuses one that counts, and an unknown address ------
    ok := true; msg := null;
    begin
      txt := set_look_up('check-lookup-' || look || '@example.com');
      select look_up into ok from profiles where id = look;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm; end;
    n := 0;
    begin perform set_look_up('check-sup-' || sup || '@example.com'); exception when others then n := n + 1; end;
    begin perform set_look_up('nobody-' || look || '@example.com'); exception when others then n := n + 1; end;
    ok := ok and n = 2 and not (select look_up from profiles where id = sup);
    if n <> 2 then msg := concat_ws(', ', msg, format('%s of 2 bad requests refused', n)); end if;
    res := res || check_row(2, 'set_look_up() makes a look-up login, and refuses a supervisor who counts and an unknown address', ok, msg);

    -- ---- 3: the look-up login finds the job by number and by name, without done-by dates ------------
    perform set_config('request.jwt.claims', json_build_object('sub', look, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := job_lookup('99947'); m := jsonb_array_length(job_lookup('status check undone')->'jobs');
      execute 'reset role';
      n := jsonb_array_length(r->'jobs');
      ok := n = 1 and m = 1 and (r->>'look_up')::boolean
            and (r#>>'{jobs,0,departments,1,done}')::int = 0 and (r#>>'{jobs,0,departments,0,done}')::int = 4
            and r#>'{jobs,0,departments,1,finish_by}' = 'null'::jsonb;
      msg := format('%s found by number, %s by name; reply %s', n, m, left(r::text, 160));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'A look-up login finds the job by PROJ number and by name, with its counts and no done-by dates', ok, msg);

    -- ---- 4: and reads none of the floor's logs ------------------------------------------------------
    begin execute 'set local role authenticated';
      select (select count(*) from problems where job_id = v_job) + (select count(*) from flags where job_id = v_job)
           + (select count(*) from defects) + (select count(*) from photos) + (select count(*) from loadouts)
           + (select count(*) from outside_jobs) + (select count(*) from delivery_docs) + (select count(*) from trip_parts)
           + (select count(*) from supply_requests) + (select count(*) from sheet_sends) + (select count(*) from routine_tasks)
           + (select count(*) from storage.objects where bucket_id in ('photos', 'deliveries'))
        into n;
      execute 'reset role';
      ok := n = 0; msg := format('%s rows readable', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'It reads none of the floor''s logs: issues, flags, defects, photos, trips, Arrow, tickets and files, supplies, sends, tasks', ok, msg);

    -- ---- 5: and changes nothing: counts, issues, defects, trips, Arrow ------------------------------
    n := 0; txt := null;
    begin execute 'set local role authenticated'; perform set_count(p_fin, 2); execute 'reset role';
      txt := concat_ws(', ', txt, 'a count');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform flag_problem(v_job, 'finishing', 'check', null, false, gen_random_uuid()); execute 'reset role';
      txt := concat_ws(', ', txt, 'an issue');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform log_defect(v_job, 'finishing', (select id from defect_types limit 1), 1, 'check', gen_random_uuid()); execute 'reset role';
      txt := concat_ws(', ', txt, 'a defect');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform start_loadout(v_job, gen_random_uuid()); execute 'reset role';
      txt := concat_ws(', ', txt, 'a trip');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform send_to_arrow(v_job, 'metal', 'Powder coat', '{1}', 'check', local_today(), gen_random_uuid()); execute 'reset role';
      txt := concat_ws(', ', txt, 'an Arrow item');
    exception when others then execute 'reset role'; n := n + 1; end;
    select qty_done into m from sheet_progress where id = p_fin;
    ok := n = 5 and m = 0;
    res := res || check_row(5, 'It can''t change anything: a count, an issue, a defect, a trip or an Arrow item is refused', ok,
                            case when not ok then format('saved: %s; Finishing count now %s', coalesce(txt, 'nothing'), m) end);

    -- ---- 6: a supervisor still reads the issues and flags, and gets done-by dates -----------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      select (select count(*) from problems where job_id = v_job), (select count(*) from flags where job_id = v_job) into n, m;
      r := job_lookup('PROJ-99947');
      execute 'reset role';
      ok := n = 1 and m = 1 and (r->>'look_up')::boolean = false and r#>>'{jobs,0,departments,1,finish_by}' is not null;
      msg := format('%s issues, %s flags; done-by %s', n, m, coalesce(r#>>'{jobs,0,departments,1,finish_by}', 'missing'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(6, 'A supervisor still reads the job''s issues and flags as before, and sees done-by dates', ok, msg);

    -- ---- 7: lanes: a real login never finds a TEST job --------------------------------------------
    begin execute 'set local role authenticated';
      n := jsonb_array_length(job_lookup('test lane')->'jobs');
      execute 'reset role';
      ok := n = 0; msg := format('%s test jobs found', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'A real login never finds a TEST job', ok, msg);

    -- ---- 8: a login with no profile (the machines) and no login at all are turned away -------------
    n := 0;
    perform set_config('request.jwt.claims', json_build_object('sub', ghost, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated'; perform job_lookup('99947'); execute 'reset role';
    exception when others then execute 'reset role'; if sqlerrm like '%can''t look up jobs%' then n := n + 1; end if; end;
    perform set_config('request.jwt.claims', '', true);
    begin execute 'set local role anon'; perform job_lookup('99947'); execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(8, 'A login with no profile (the machines) and no login at all are turned away', n = 2, format('%s of 2 turned away', n));

    raise exception using errcode = 'P0001', message = '__check_job_status_undo__';
  exception when others then
    begin execute 'reset role'; exception when others then null; end;
    if sqlerrm <> '__check_job_status_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ---- 9: no look-up login also counts, looks, schedules, manages or tests -------------------------
  select string_agg(full_name, ', ' order by full_name) into txt from profiles
   where look_up and (cardinality(coalesce(departments, '{}')) > 0 or cardinality(coalesce(look_departments, '{}')) > 0
                      or coalesce(schedules_deliveries, false) or coalesce(is_test, false) or role in ('manager', 'admin'));
  res := res || check_row(9, 'No look-up login also counts, looks at a department, schedules, manages or tests', txt is null,
                          'Give them only one: ' || txt || '. Undo with select set_look_up(''email'', false);');

  select string_agg(full_name, ', ' order by full_name) into txt from profiles where look_up;
  res := res || check_row(10, coalesce('Look-up logins: ' || txt, 'No look-up logins yet. For each sales person: make the login, give it a profile with no departments, then select set_look_up(''their email'');'), true, null);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_job_status() from public, anon, authenticated;

select * from check_job_status();
