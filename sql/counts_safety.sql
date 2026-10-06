-- =====================================================================
-- Shop Floor — counts land on the current work order; table grants tidied (6 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- Fixes review findings R-2, R-5 and the first half of R-4.
--
--   1. set_count(progress row, number): the one way the tablet page
--      (2026-10-06.1 and newer) sends a count. It checks the login, the
--      department and the test lane, as before. If a change order was
--      uploaded since the tablet loaded the job, it finds the same sheet
--      on the current work order and saves the count there, as long as
--      that sheet's drawing didn't change (the same rule the upload uses
--      to carry counts forward). If the drawing did change, it refuses
--      in plain words, so the count isn't saved against the wrong thing.
--      History still records it as a Tablet count by that login.
--   2. A count written straight to a replaced work order (an older
--      tablet page, or anything else using the direct route) is refused
--      with the same words Advance already uses. Before, it was saved to
--      the old version and never showed. Counts on the current work
--      order work exactly as before, so the old page keeps working.
--   3. TRUNCATE, TRIGGER and REFERENCES are taken away from no-login and
--      signed-in users on every table, and from tables made later.
--      Nothing uses them; TRUNCATE could empty a whole table.
--   4. check_counts_safety(): the PASS/FAIL check.
--
-- Not yet: taking away the old direct route (R-4's second half). That
-- waits until select * from devices(); shows every tablet and phone on
-- page 2026-10-06.1 or newer, so older pages keep working until then.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('counts_safety.sql', '{}'); end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. set_count — one sheet, one department, the number itself
-- ---------------------------------------------------------------------

create or replace function set_count(p_progress uuid, p_qty int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r      record;
  cur    record;
  v_row  uuid;
  v_req  int;
  v_dept text;
  v_out  sheet_progress;
begin
  if auth.uid() is null then
    raise exception 'Not signed in — the count is kept on the tablet and will send after signing in.' using errcode = '28000';
  end if;

  select sp.id, sp.department, sp.qty_required, sh.sheet_number, sh.spec_hash,
         w.is_current, w.job_id, j.project_id, j.is_test
    into r
    from sheet_progress sp
    join sheets sh     on sh.id = sp.sheet_id
    join work_orders w on w.id = sh.work_order_id
    join jobs j        on j.id = w.job_id
   where sp.id = p_progress;
  if not found then
    raise exception 'That sheet wasn''t found. Go back to the job and open it again.';
  end if;
  v_dept := coalesce((select name from departments where key = r.department), r.department);

  if not owns_dept(r.department) then
    raise exception 'This login isn''t allowed to change % counts.', v_dept using errcode = 'insufficient_privilege';
  end if;
  if r.is_test <> am_test() then
    raise exception '%', case when r.is_test then 'Test jobs are counted by the Test Supervisor, not this login.'
                              else 'The Test Supervisor can only count on test jobs.' end
      using errcode = 'insufficient_privilege';
  end if;

  v_row := r.id; v_req := r.qty_required;
  if not r.is_current then
    -- a change order came in since the tablet loaded the job: the same sheet on the current version
    select sp2.id, sp2.qty_required, sh2.spec_hash
      into cur
      from work_orders w2
      join sheets sh2 on sh2.work_order_id = w2.id and sh2.sheet_number = r.sheet_number
      left join sheet_progress sp2 on sp2.sheet_id = sh2.id and sp2.department = r.department
     where w2.job_id = r.job_id and w2.is_current;
    if cur.id is null or cur.spec_hash is null or r.spec_hash is null or cur.spec_hash <> r.spec_hash then
      raise exception '% has a new work order, and sheet % changed on it, so this % count wasn''t saved. Open the job again and count against the new sheet.',
        r.project_id, r.sheet_number, v_dept;
    end if;
    v_row := cur.id; v_req := cur.qty_required;
  end if;

  if p_qty is null or p_qty < 0 or p_qty > v_req then
    raise exception 'Sheet % needs a % count from 0 to %.', r.sheet_number, v_dept, v_req;
  end if;

  update sheet_progress set qty_done = p_qty where id = v_row returning * into v_out;
  return jsonb_build_object('id', v_out.id, 'qty_done', v_out.qty_done, 'state', v_out.state,
                            'moved', v_row <> r.id, 'from', r.id);
end $$;

revoke all on function set_count(uuid, int) from public, anon;
grant execute on function set_count(uuid, int) to authenticated;


-- ---------------------------------------------------------------------
-- 2. The direct route can't write to a replaced work order
--    (only checks requests made as a login: the SQL Editor, uploads,
--    Advance and the catch-up are untouched)
-- ---------------------------------------------------------------------

create or replace function sheet_progress_current_only() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon')
     and not exists (select 1 from sheets s join work_orders w on w.id = s.work_order_id
                      where s.id = new.sheet_id and w.is_current) then
    raise exception 'This work order has been replaced by a newer version since the tablet loaded it. Go back to the job and open the sheet again.';
  end if;
  return new;
end $$;

drop trigger if exists sheet_progress_current_only_trg on sheet_progress;
create trigger sheet_progress_current_only_trg
  before update of qty_done on sheet_progress
  for each row when (new.qty_done is distinct from old.qty_done)
  execute function sheet_progress_current_only();


-- ---------------------------------------------------------------------
-- 3. TRUNCATE, TRIGGER and REFERENCES: nobody without the secret key
-- ---------------------------------------------------------------------

do $$
declare t record;
begin
  for t in select c.relname from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f') loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', t.relname);
  end loop;
end $$;
-- and on tables made by later files (the SQL Editor runs as postgres)
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. The check
-- ---------------------------------------------------------------------

create or replace function check_counts_safety()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sup uuid; tst uuid;
  v_job uuid; v_wo1 uuid; v_wo2 uuid;
  s1 uuid; s2 uuid; s1b uuid; s2b uuid;
  p1 uuid; p2 uuid; p1b uuid; p2b uuid;
  r jsonb; n int; m int; ok boolean; msg text; e progress_events;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('sanding' = any (departments))
                                     and not ('delivery' = any (departments)) and cardinality(departments) > 0 order by full_name limit 1;
  select id into tst from profiles where is_test and active limit 1;
  if mgr is null then
    res := res || check_row(1, 'A manager login exists to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  -- ---- 1: the pieces are in place ---------------------------------------------------------------
  ok := to_regprocedure('public.set_count(uuid,integer)') is not null
        and has_function_privilege('authenticated', 'public.set_count(uuid,integer)', 'execute')
        and not has_function_privilege('anon', 'public.set_count(uuid,integer)', 'execute')
        and exists (select 1 from pg_trigger where tgname = 'sheet_progress_current_only_trg' and not tgisinternal);
  res := res || check_row(1, 'set_count() is there for signed-in logins only, and the replaced-version guard is on sheet_progress', ok,
                          case when ok then null else 'Run counts_safety.sql again.' end);

  -- ---- 2: no table can be emptied, or given triggers or references, without the secret key ----------
  select count(*), string_agg(distinct c.relname, ', ')
    into n, msg
    from pg_class c
    cross join (values ('anon'), ('authenticated')) g(who)
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and (has_table_privilege(g.who, c.oid, 'truncate') or has_table_privilege(g.who, c.oid, 'trigger')
          or has_table_privilege(g.who, c.oid, 'references'));
  res := res || check_row(2, 'No-login and signed-in users can''t empty any table (TRUNCATE) or add triggers or references to one', n = 0,
                          case when n = 0 then null else 'Granted again on: ' || left(msg, 300) || '. Run counts_safety.sql again.' end);

  begin    -- everything below is undone at the end, whatever happens
    -- a job with a work order of two sheets (Sanding on both), then a change order:
    -- sheet 1's drawing the same, sheet 2's changed
    insert into jobs (monday_item_id, project_id, name, phase, is_active, is_test)
    values (-60601, 'PROJ-CHECKCOUNTS', 'Count check — undone automatically', 'In Production', true, false)
    returning id into v_job;
    insert into work_orders (job_id, version, is_current) values (v_job, 1, true) returning id into v_wo1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo1, 1, 3, 'same') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo1, 2, 2, 'old')  returning id into s2;
    insert into sheet_progress (sheet_id, department, qty_required) values (s1, 'sanding', 3) returning id into p1;
    insert into sheet_progress (sheet_id, department, qty_required) values (s2, 'sanding', 2) returning id into p2;
    set constraints all immediate;

    -- ---- 3: a count on the current work order saves, recorded as a Tablet count by that login ----------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := set_count(p1, 1);
      execute 'reset role';
      select * into e from progress_events where sheet_id = s1 and department = 'sanding' order by occurred_at desc, id desc limit 1;
      ok := (r->>'qty_done')::int = 1 and not (r->>'moved')::boolean and e.qty_to = 1 and e.actor = mgr and e.source = 'Tablet';
      msg := case when ok then null else 'Got ' || coalesce(r::text, 'nothing') || ', history ' || coalesce(row_to_json(e)::text, 'none') end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A count sent through set_count() saves, and the history says Tablet and who', ok, msg);

    -- the change order: version 2 is current; sheet 1 carried forward (same drawing), sheet 2 changed
    update work_orders set is_current = false, superseded_at = now() where id = v_wo1;
    insert into work_orders (job_id, version, is_current) values (v_job, 2, true) returning id into v_wo2;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo2, 1, 3, 'same') returning id into s1b;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (v_wo2, 2, 2, 'new')  returning id into s2b;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s1b, 'sanding', 3, 1) returning id into p1b;
    insert into sheet_progress (sheet_id, department, qty_required) values (s2b, 'sanding', 2) returning id into p2b;
    set constraints all immediate;

    -- ---- 4: a count sent to the replaced version lands on the current one when the drawing is the same ---
    begin
      execute 'set local role authenticated';
      r := set_count(p1, 3);
      execute 'reset role';
      select qty_done into n from sheet_progress where id = p1b;
      select qty_done into m from sheet_progress where id = p1;
      ok := (r->>'moved')::boolean and (r->>'id')::uuid = p1b and n = 3 and m = 1;
      msg := case when ok then null else format('current version %s/3, replaced version %s (should stay 1); reply %s', n, m, r) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'After a change order, a count the tablet sends for an unchanged sheet lands on the current version', ok, msg);

    -- ---- 5: …and is refused, in plain words, when that sheet's drawing changed ---------------------------
    begin
      execute 'set local role authenticated';
      r := set_count(p2, 2);
      execute 'reset role';
      ok := false; msg := 'It was accepted: ' || r::text;
    exception when others then execute 'reset role';
      ok := sqlerrm like '%new work order%sheet 2 changed%'; msg := case when ok then null else 'Wrong refusal: ' || sqlerrm end;
    end;
    select count(*) into n from sheet_progress where id in (p2, p2b) and qty_done > 0;
    res := res || check_row(5, 'A count for a sheet whose drawing changed on the new work order is refused and saved nowhere', ok and n = 0,
                            coalesce(msg, case when n > 0 then 'It was saved somewhere' end));

    -- ---- 6: the old direct route: refused on the replaced version, still works on the current one -------
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 2 where id = p1;
      execute 'reset role'; msg := 'a direct write to the replaced version was saved';
    exception when others then execute 'reset role';
      if sqlerrm like '%replaced by a newer version%' then n := n + 1; else msg := 'Wrong refusal: ' || sqlerrm; end if;
    end;
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 2 where id = p1b;
      get diagnostics m = row_count;
      execute 'reset role';
      if m = 1 then n := n + 1; else msg := concat_ws(', ', msg, 'a direct write to the current version changed nothing'); end if;
    exception when others then execute 'reset role'; msg := concat_ws(', ', msg, 'the current version refused a direct write: ' || sqlerrm);
    end;
    res := res || check_row(6, 'An older tablet page''s direct count: refused on a replaced work order, saved as before on the current one', n = 2, msg);

    -- ---- 7: the department, the test lane, the range and no login are all checked ------------------------
    n := 0; m := 0; msg := null;
    if sup is not null then
      m := m + 1;
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; perform set_count(p1b, 2); execute 'reset role'; msg := 'another department''s supervisor counted Sanding';
      exception when others then execute 'reset role'; n := n + 1; end;
    end if;
    if tst is not null then
      m := m + 1;
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin execute 'set local role authenticated'; perform set_count(p1b, 2); execute 'reset role'; msg := concat_ws(', ', msg, 'the Test Supervisor counted a real job');
      exception when others then execute 'reset role'; n := n + 1; end;
    end if;
    m := m + 1;
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated'; perform set_count(p1b, 4); execute 'reset role'; msg := concat_ws(', ', msg, '4 of 3 was accepted');
    exception when others then execute 'reset role'; n := n + 1; end;
    m := m + 1;
    perform set_config('request.jwt.claims', '', true);
    begin execute 'set local role anon'; perform set_count(p1b, 2); execute 'reset role'; msg := concat_ws(', ', msg, 'no login counted');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(7, 'set_count() refuses another department, the other lane, a number past the sheet''s quantity, and no login', n = m, msg);

    raise exception using errcode = 'P0001', message = '__check_counts_safety_undo__';
  exception when others then
    if sqlerrm <> '__check_counts_safety_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_counts_safety() from public, anon, authenticated;

select * from check_counts_safety();
