-- =====================================================================
-- Shop Floor — Advance (managers set where a sheet is, across departments)
--
-- HOW TO USE: every earlier file must have run already (up to photos
-- and check_photos). Paste this whole file into a NEW, empty query in
-- the Supabase SQL Editor and click Run. A table appears at the end:
-- every row should say PASS. Safe to run more than once.
-- Run the check again any time with just:   select * from check_advance();
--
-- What it adds:
--   * advance_sheet() — the one way the Advance tab saves. A manager
--     sets any department's count on a sheet, several at once, in one
--     go. Every change lands in the history under their name, labelled
--     "Manager adjustment".
--   * sheet_adjustments — one row per save, so a save the tablet sends
--     twice (Wi-Fi dropped mid-send) is only ever applied once, and a
--     late resend can't overwrite counts entered since.
--   * check_advance() — the PASS/FAIL check. It undoes everything it does.
--
-- Who can use it:
--   * managers (Luke, David), on real jobs only
--   * the Test Supervisor, on test jobs only (for the bench run)
--   * nobody else — real supervisors keep counting their own department
--     from the Work orders screen, exactly as before
--
-- Nothing here changes a supervisor's tablet, a table they write to, or
-- any existing function. Nothing is deleted.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('advance.sql'); end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'check_row')
     or not exists (select 1 from pg_proc where proname = 'lane_ok')
     or not exists (select 1 from information_schema.columns where table_name = 'progress_events' and column_name = 'source') then
    raise exception 'Run the earlier files first (everything up to check_floor.sql). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. sheet_adjustments — one row per Advance save
-- ---------------------------------------------------------------------

create table if not exists sheet_adjustments (
  client_id     uuid primary key,              -- made by the tablet; a resend carries the same one
  sheet_id      uuid not null references sheets(id) on delete cascade,
  job_id        uuid not null references jobs(id) on delete cascade,
  sheet_number  int  not null,
  changes       jsonb not null default '[]',   -- [{department, from, to, of}] — only what actually changed
  summary       text,
  made_by       uuid references profiles(id),
  made_by_name  text,
  is_test       boolean not null default false,
  made_at       timestamptz not null default now()
);
create index if not exists sheet_adjustments_job_idx on sheet_adjustments (job_id, made_at desc);

alter table sheet_adjustments enable row level security;

-- managers see every adjustment; anyone else only their own (the Test Supervisor's test ones)
drop policy if exists read_adjustments on sheet_adjustments;
create policy read_adjustments on sheet_adjustments for select to authenticated
  using (is_manager() or made_by = auth.uid());

-- nobody writes here directly: only advance_sheet() does
revoke all on sheet_adjustments from anon;
revoke insert, update, delete, truncate on sheet_adjustments from authenticated;
grant select on sheet_adjustments to authenticated;


-- ---------------------------------------------------------------------
-- 2. advance_sheet(sheet, counts, client id)
--
-- counts is {"milling": 12, "cnc": 12, "sanding": 4} — the number done in
-- each department, as absolute numbers, never "add 4". Departments left
-- out are left alone. Either every count is saved or none is.
-- ---------------------------------------------------------------------

create or replace function advance_sheet(p_sheet uuid, p_counts jsonb, p_client_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_mgr     boolean := is_manager();
  v_test    boolean := am_test();
  v_client  uuid := coalesce(p_client_id, gen_random_uuid());
  s         record;
  k         text;
  v_txt     text;
  v_qty     int;
  v_row     record;
  v_changes jsonb := '[]';
  v_parts   text[] := '{}';
  v_summary text;
  v_prev    text;
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  if not v_mgr and not v_test then
    raise exception 'Only a manager can use Advance. Count from your own department''s Work orders screen instead.'
      using errcode = 'insufficient_privilege';
  end if;

  -- a resend of a save that already went through: say so, change nothing
  select summary into v_prev from sheet_adjustments where client_id = v_client;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'summary', coalesce(v_prev, 'Already saved.'));
  end if;

  select sh.id, sh.sheet_number, w.is_current, j.id as job_id, j.project_id, j.is_test, j.is_active
    into s
    from sheets sh
    join work_orders w on w.id = sh.work_order_id
    join jobs j        on j.id = w.job_id
   where sh.id = p_sheet;
  if not found then
    raise exception 'That sheet wasn''t found. Go back to the job and open it again.';
  end if;
  if s.is_test <> v_test then
    raise exception '%', case when v_test then 'The Test Supervisor can only use Advance on test jobs.'
                              else 'Test jobs are counted by the Test Supervisor, not a manager login.' end
      using errcode = 'insufficient_privilege';
  end if;
  if not s.is_current then
    raise exception 'This work order has been replaced by a newer version since the tablet loaded it. Go back to the job and open the sheet again.';
  end if;
  if not s.is_active then
    raise exception '% isn''t in production any more, so its counts can''t change.', s.project_id;
  end if;

  if p_counts is null or jsonb_typeof(p_counts) <> 'object' or p_counts = '{}'::jsonb then
    raise exception 'Nothing to save — no counts were sent.';
  end if;

  -- check every count before changing any of them
  for k, v_txt in select key, value #>> '{}' from jsonb_each(p_counts) loop
    select sp.id, sp.qty_required, sp.qty_done, d.name into v_row
      from sheet_progress sp join departments d on d.key = sp.department
     where sp.sheet_id = p_sheet and sp.department = k;
    if not found then
      raise exception 'Sheet % has no % work on it.', s.sheet_number, coalesce((select name from departments where key = k), k);
    end if;
    if v_txt is null or v_txt !~ '^[0-9]+$' then
      raise exception 'The % count must be a whole number.', v_row.name;
    end if;
    v_qty := v_txt::int;
    if v_qty > v_row.qty_required then
      raise exception '% has % on sheet %, so it can''t be set to %.', v_row.name, v_row.qty_required, s.sheet_number, v_qty;
    end if;
    if not v_mgr and not owns_dept(k) then
      raise exception 'This login doesn''t have %.', v_row.name using errcode = 'insufficient_privilege';
    end if;
  end loop;

  -- claim the client id first, so two copies of the same save arriving together can't both apply
  insert into sheet_adjustments (client_id, sheet_id, job_id, sheet_number, made_by, made_by_name, is_test)
  values (v_client, p_sheet, s.job_id, s.sheet_number, v_uid, my_name(), s.is_test)
  on conflict (client_id) do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'summary', 'Already saved.');
  end if;

  perform set_config('shopfloor.source', 'Manager adjustment', true);
  for v_row in
    select sp.id, sp.department, d.name, sp.qty_done, sp.qty_required, (p_counts ->> sp.department)::int as want
      from sheet_progress sp join departments d on d.key = sp.department
     where sp.sheet_id = p_sheet and p_counts ? sp.department
     order by d.sort_order
  loop
    if v_row.want <> v_row.qty_done then
      update sheet_progress set qty_done = v_row.want where id = v_row.id;
      v_changes := v_changes || jsonb_build_object('department', v_row.department, 'from', v_row.qty_done, 'to', v_row.want, 'of', v_row.qty_required);
      v_parts := v_parts || format('%s %s → %s of %s', v_row.name, v_row.qty_done, v_row.want, v_row.qty_required);
    end if;
  end loop;
  perform set_config('shopfloor.source', '', true);

  v_summary := case when array_length(v_parts, 1) is null
                    then format('%s sheet %s: nothing needed changing — those were already the counts.', s.project_id, s.sheet_number)
                    else format('%s sheet %s: %s. Saved.', s.project_id, s.sheet_number, array_to_string(v_parts, ', ')) end;
  update sheet_adjustments set changes = v_changes, summary = v_summary where client_id = v_client;

  return jsonb_build_object('ok', true, 'duplicate', false, 'changes', v_changes, 'summary', v_summary);
end;
$$;
revoke all on function advance_sheet(uuid, jsonb, uuid) from public, anon;
grant execute on function advance_sheet(uuid, jsonb, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 3. check_advance() — PASS/FAIL, undoes everything it does
-- ---------------------------------------------------------------------

create or replace function check_advance()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  tst uuid;  mgr uuid;  mgr_name text;
  v_real  uuid;  v_wo uuid;  s1 uuid;  v_test uuid;  t1 uuid;
  v       jsonb;
  c1      uuid := gen_random_uuid();
  n       int;
  ok      boolean;
  msg     text;
begin
  select id into sup from profiles where role = 'supervisor' and active and not is_test
     and exists (select 1 from departments d where d.key = any(departments) and not d.log_only)
   order by ('sanding' = any(departments)) desc limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id, full_name into mgr, mgr_name from profiles where role in ('manager', 'admin') and active order by full_name limit 1;

  if sup is null or tst is null or mgr is null then
    res := res || check_row(1, 'A supervisor, the Test Supervisor and a manager all have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end,
                     case when tst is null then 'No Test Supervisor.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;

  begin
    -- ---- 1. the parts exist ------------------------------------------------
    ok := exists (select 1 from pg_proc where proname = 'advance_sheet')
          and exists (select 1 from pg_tables where tablename = 'sheet_adjustments' and rowsecurity);
    res := res || check_row(1, 'Advance is set up (its function, and its table with security on)', ok,
      'Something is missing. Run advance.sql again from the top.');

    -- a throwaway job: one sheet with Milling, CNC, Sanding and Metal, and a test copy of it
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999995, 'ADVCHECK', 'Advance check - undone automatically', true, 'In Production', local_today() + 5)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 1, 4, 'ADV-1') returning id into s1;
    insert into sheet_progress (sheet_id, department, qty_required)
      select s1, d, 4 from unnest(array['milling', 'cnc', 'sanding', 'metal']) d;
    v := make_test_job('ADVCHECK');
    select id into v_test from jobs where project_id = v->>'project_id';
    select sh.id into t1 from sheets sh join work_orders w on w.id = sh.work_order_id and w.is_current where w.job_id = v_test and sh.sheet_number = 1;

    -- ---- 2–4. a manager moves the sheet along -------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := advance_sheet(s1, '{"milling": 4, "cnc": 4, "sanding": 1}', c1);
      execute 'reset role';
      ok := (v->>'ok')::boolean
            and (select qty_done from sheet_progress where sheet_id = s1 and department = 'milling') = 4
            and (select qty_done from sheet_progress where sheet_id = s1 and department = 'cnc') = 4
            and (select qty_done from sheet_progress where sheet_id = s1 and department = 'sanding') = 1
            and (select qty_done from sheet_progress where sheet_id = s1 and department = 'metal') = 0;
      msg := 'The counts didn''t come out as sent (Milling 4, CNC 4, Sanding 1, Metal left at 0).';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A manager can set several departments on a sheet in one go', ok, msg);

    select count(*) into n from progress_events
     where sheet_id = s1 and source = 'Manager adjustment' and actor = mgr;
    res := res || check_row(3, 'Each change is in the history under the manager''s name, as "Manager adjustment"', n = 3,
      format('Expected 3 history rows labelled "Manager adjustment" under %s; found %s.', mgr_name, n));

    -- the floor counts sanding on to 3; then the same save arrives again (a resend)
    update sheet_progress set qty_done = 3 where sheet_id = s1 and department = 'sanding';
    begin
      execute 'set local role authenticated';
      v := advance_sheet(s1, '{"milling": 4, "cnc": 4, "sanding": 1}', c1);
      execute 'reset role';
      ok := (v->>'duplicate')::boolean
            and (select qty_done from sheet_progress where sheet_id = s1 and department = 'sanding') = 3
            and (select count(*) from sheet_adjustments where client_id = c1) = 1;
      msg := 'A resent save was applied again and put Sanding back from 3 to 1.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A save sent twice is only applied once (it can''t undo later counting)', ok, msg);

    -- ---- 5. a manager can lower a count (fixing a mistake) -------------------
    begin
      execute 'set local role authenticated';
      v := advance_sheet(s1, '{"cnc": 2}', gen_random_uuid());
      execute 'reset role';
      ok := (select qty_done from sheet_progress where sheet_id = s1 and department = 'cnc') = 2
            and (select state from sheet_progress where sheet_id = s1 and department = 'cnc') = 'in_progress';
      msg := 'Lowering CNC from 4 to 2 didn''t take, or its state didn''t follow.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A manager can lower a count to fix a mistake', ok, msg);

    -- ---- 6. bad numbers are refused, and nothing is half-saved ---------------
    begin
      execute 'set local role authenticated';
      begin
        v := advance_sheet(s1, '{"milling": 0, "cnc": 9}', gen_random_uuid());
        ok := false; msg := 'CNC was set to 9 of 4.';
      exception when others then ok := true;
      end;
      begin
        v := advance_sheet(s1, '{"finishing": 1}', gen_random_uuid());
        ok := false; msg := 'A count was accepted for a department that isn''t on the sheet.';
      exception when others then null;
      end;
      execute 'reset role';
      if ok and (select qty_done from sheet_progress where sheet_id = s1 and department = 'milling') <> 4 then
        ok := false; msg := 'Milling changed even though the save was refused — it should be all or nothing.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Impossible counts are refused, and a refused save changes nothing', ok, msg);

    -- ---- 7. managers can't count on test jobs ------------------------------
    begin
      execute 'set local role authenticated';
      v := advance_sheet(t1, '{"milling": 1}', gen_random_uuid());
      execute 'reset role';
      ok := false; msg := 'A manager changed a test job''s count. Test jobs belong to the Test Supervisor.';
    exception when others then execute 'reset role'; ok := true;
    end;
    res := res || check_row(7, 'A manager can''t change a test job', ok, msg);

    -- ---- 8. a real supervisor can't use Advance --------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := advance_sheet(s1, '{"sanding": 4}', gen_random_uuid());
      execute 'reset role';
      ok := false; msg := 'A supervisor used Advance. Only managers (and the Test Supervisor on test jobs) should.';
    exception when others then execute 'reset role'; ok := (select qty_done from sheet_progress where sheet_id = s1 and department = 'sanding') = 3;
      msg := 'The save was refused, but the count changed anyway.';
    end;
    res := res || check_row(8, 'A supervisor can''t use Advance (they count from Work orders as before)', ok, msg);

    -- ---- 9. the Test Supervisor: test jobs yes, real jobs no ----------------------
    perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := advance_sheet(t1, '{"milling": 4, "cnc": 4}', gen_random_uuid());
      ok := (v->>'ok')::boolean;
      begin
        v := advance_sheet(s1, '{"metal": 1}', gen_random_uuid());
        ok := false;
      exception when others then null;
      end;
      execute 'reset role';
      ok := ok and (select qty_done from sheet_progress where sheet_id = t1 and department = 'cnc') = 4
               and (select qty_done from sheet_progress where sheet_id = s1 and department = 'metal') = 0;
      msg := 'The Test Supervisor couldn''t move a test sheet along, or could change a real one.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'The Test Supervisor can use Advance on test jobs only', ok, msg);

    -- ---- 10. nobody writes the record by hand, and no login sees nothing ----------
    begin
      execute 'set local role authenticated';
      begin
        insert into sheet_adjustments (client_id, sheet_id, job_id, sheet_number) values (gen_random_uuid(), s1, v_real, 1);
        ok := false; msg := 'A login wrote to sheet_adjustments directly.';
      exception when insufficient_privilege then ok := true;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      begin
        v := advance_sheet(s1, '{"metal": 1}', gen_random_uuid());
        ok := false; msg := 'Someone with no login used Advance.';
      exception when others then null;
      end;
      begin
        select count(*) into n from sheet_adjustments;
        if n > 0 then ok := false; msg := 'Adjustments are visible without logging in.'; end if;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Nobody writes the record by hand; someone with no login can''t use it', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_advance_undo__';
  exception when others then
    if sqlerrm <> '__check_advance_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_advance() from public, anon, authenticated;

select * from check_advance();
