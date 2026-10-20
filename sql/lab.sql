-- =====================================================================
-- Shop Floor — the Prototype lab (18 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table. Then let yourself in, once, with:  select lab_allow('your login email');
--
-- What it adds (nothing existing changes; the floor never sees any of it):
--   1. lab_users: who may use the lab. Added only from the SQL Editor with
--      lab_allow(); being a manager isn't enough.
--   2. lab_rules: what the lab has been taught (a floor note for a shape,
--      "an unnamed power unit is a Dean", a template's inputs...). Each
--      change is a new row; the newest row for a rule wins, and "stop using
--      it" is a row too. Nothing is changed or deleted, so the history of
--      what it learned, and why, is always there.
--   3. lab_answers: values given for one job (this power unit is a Dean).
--      Same rules: new rows only.
--   4. lab_runs: one row per work order run through the lab: what it made,
--      what it got stuck on, and why. The "what I've learned" file and the
--      count of what it gets stuck on most come from here.
--   5. v_lab_rules_now, v_lab_answers_now: the newest row of each, read with
--      the reader's own permissions.
--   6. check_lab(): the PASS/FAIL check.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('lab.sql', '{}'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Who may use the lab
-- ---------------------------------------------------------------------
create table if not exists lab_users (
  user_id  uuid primary key references profiles(id),
  added_at timestamptz not null default now(),
  added_by text not null default current_user
);
alter table lab_users enable row level security;
revoke all on lab_users from anon, authenticated;
grant select on lab_users to authenticated;
drop policy if exists lab_users_self on lab_users;
create policy lab_users_self on lab_users for select to authenticated using (user_id = auth.uid());

create or replace function lab_allowed() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lab_users u join profiles p on p.id = u.user_id
                 where u.user_id = auth.uid() and p.active);
$$;
revoke all on function lab_allowed() from public, anon;
grant execute on function lab_allowed() to authenticated;

-- SQL Editor only: let a login into the lab by its email address.
create or replace function lab_allow(p_email text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid; v_name text;
begin
  select u.id, p.full_name into v_id, v_name
  from auth.users u join profiles p on p.id = u.id
  where lower(u.email) = lower(btrim(coalesce(p_email, '')));
  if v_id is null then
    return 'No login with that email has a profile. Check the address (Authentication → Users in Supabase).';
  end if;
  insert into lab_users (user_id) values (v_id) on conflict (user_id) do nothing;
  return v_name || ' can use the Prototype lab. It appears in the office''s ☰ menu after the office page is reloaded.';
end;
$$;
revoke all on function lab_allow(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2–4. What it learned, answers for one job, and each run
-- ---------------------------------------------------------------------
create table if not exists lab_rules (
  id        uuid primary key default gen_random_uuid(),
  rule_set  text not null,
  rule_key  text not null,
  value     jsonb,                        -- null: stop using this rule
  note      text,                         -- why, in words
  job       text,                         -- the job that prompted it, if one did
  made_by   uuid not null default auth.uid() references profiles(id),
  made_at   timestamptz not null default now(),
  constraint lab_rules_set_known check (rule_set in ('notes_by_shape', 'shape_names', 'cnc_by_shape', 'cnc_templates', 'defaults', 'settings')),
  constraint lab_rules_key_size check (length(btrim(rule_key)) between 1 and 80),
  constraint lab_rules_value_size check (value is null or length(value::text) <= 20000),
  constraint lab_rules_note_size check (note is null or length(note) <= 2000),
  constraint lab_rules_job_size check (job is null or length(job) <= 80)
);
create index if not exists lab_rules_by_key on lab_rules (rule_set, rule_key, made_at desc);

create table if not exists lab_answers (
  id         uuid primary key default gen_random_uuid(),
  project_id text not null,
  item_id    text not null,
  field      text not null,
  value      text,                        -- null: take the answer back
  note       text,
  made_by    uuid not null default auth.uid() references profiles(id),
  made_at    timestamptz not null default now(),
  constraint lab_answers_project check (project_id ~ '^PROJ-[0-9]{5}$'),
  constraint lab_answers_item_size check (length(btrim(item_id)) between 1 and 120),
  constraint lab_answers_field_known check (field in ('power_model', 'port_cutout', 'full_custom', 'width', 'length', 'thickness', 'top_shape', 'qty')),
  constraint lab_answers_value_size check (value is null or length(value) <= 200),
  constraint lab_answers_note_size check (note is null or length(note) <= 2000)
);
create index if not exists lab_answers_by_item on lab_answers (project_id, item_id, field, made_at desc);

create table if not exists lab_runs (
  id            uuid primary key default gen_random_uuid(),
  project_id    text,
  file_name     text,
  rules_version text,
  made          int not null default 0,
  looks         int not null default 0,
  stuck         int not null default 0,
  no_generator  int not null default 0,
  stuck_reasons jsonb not null default '[]',   -- [{kind, text, item}]
  report        jsonb,                         -- the sheets' results, for looking back
  page_version  text,
  made_by       uuid not null default auth.uid() references profiles(id),
  made_at       timestamptz not null default now(),
  constraint lab_runs_report_size check (report is null or length(report::text) <= 1500000),
  constraint lab_runs_reasons_size check (length(stuck_reasons::text) <= 200000)
);
create index if not exists lab_runs_newest on lab_runs (made_at desc);

-- Lab users read and add; nobody changes or deletes (not even them); nobody else sees any of it.
do $$ declare t text; begin
  foreach t in array array['lab_rules', 'lab_answers', 'lab_runs'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select, insert on %I to authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_read', t);
    execute format('create policy %I on %I for select to authenticated using (lab_allowed())', t || '_read', t);
    execute format('drop policy if exists %I on %I', t || '_add', t);
    execute format('create policy %I on %I for insert to authenticated with check (lab_allowed() and made_by = auth.uid())', t || '_add', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. The newest row of each rule and answer, read as the person reading
-- ---------------------------------------------------------------------
create or replace view v_lab_rules_now with (security_invoker = true) as
  select distinct on (rule_set, rule_key) rule_set, rule_key, value, note, job, made_at
  from lab_rules order by rule_set, rule_key, made_at desc;
create or replace view v_lab_answers_now with (security_invoker = true) as
  select distinct on (project_id, item_id, field) project_id, item_id, field, value, note, made_at
  from lab_answers order by project_id, item_id, field, made_at desc;
revoke all on v_lab_rules_now, v_lab_answers_now from anon, authenticated;
grant select on v_lab_rules_now, v_lab_answers_now to authenticated;

-- ---------------------------------------------------------------------
-- 6. The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_lab()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  labu uuid; mgr uuid; sup uuid; r uuid := gen_random_uuid();
  n int; m int; ok boolean; msg text; txt text;
begin
  -- a lab user to test with (someone already let in, or else a manager let in for the check only), and a manager who isn't
  select u.user_id into labu from lab_users u join profiles p on p.id = u.user_id where p.active order by u.added_at limit 1;
  if labu is null then
    select id into labu from profiles where role in ('manager', 'admin') and active and not coalesce(is_test, false) order by full_name limit 1;
  end if;
  select id into mgr from profiles p where role in ('manager', 'admin') and active and not coalesce(is_test, false) and id <> labu
    and not exists (select 1 from lab_users u where u.user_id = p.id) order by full_name limit 1;
  select id into sup  from profiles where role = 'supervisor' and active and not coalesce(is_test, false) order by full_name limit 1;

  -- ---- 1: the four tables are there, each with row-level security on --------------------------------
  select count(*) into n from pg_class c where c.relnamespace = 'public'::regnamespace
    and c.relname in ('lab_users', 'lab_rules', 'lab_answers', 'lab_runs') and c.relrowsecurity;
  res := res || check_row(1, 'The lab''s four tables are there, each with row-level security on', n = 4, format('%s of 4. Run lab.sql again.', n));

  -- ---- 2: nobody can change, delete or empty them, and the views read with the reader''s permissions --
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name in ('lab_users', 'lab_rules', 'lab_answers', 'lab_runs')
     and grantee in ('anon', 'authenticated') and privilege_type in ('UPDATE', 'DELETE', 'TRUNCATE');
  select count(*) into m from pg_class c where c.relname in ('v_lab_rules_now', 'v_lab_answers_now')
     and c.relnamespace = 'public'::regnamespace and coalesce(c.reloptions::text, '') like '%security_invoker=true%';
  res := res || check_row(2, 'No login can change, delete or empty the lab''s tables, and its two views read with the reader''s own permissions', n = 0 and m = 2,
                          format('%s change/delete grants, %s of 2 views checked. Run lab.sql again.', n, m));

  -- ---- 3: lab_allow can''t be called by any login, only the SQL Editor --------------------------------
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'lab_allow' and grantee in ('anon', 'authenticated', 'PUBLIC');
  res := res || check_row(3, 'Only the SQL Editor can let someone into the lab (lab_allow)', n = 0, 'A login could let itself in. Run lab.sql again.');

  if labu is null or sup is null then
    res := res || check_row(4, 'A manager and a supervisor login exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into lab_users (user_id) values (labu) on conflict do nothing;

    -- ---- 4: a lab user adds a rule, an answer and a run, and reads them back -------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', labu, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      insert into lab_rules (id, rule_set, rule_key, value, note, job) values (r, 'notes_by_shape', 'check-shape', '"NO BISCUITS!"', 'Check rule - undone automatically', 'PROJ-00000');
      insert into lab_answers (project_id, item_id, field, value, note) values ('PROJ-00000', 'CHECK', 'power_model', 'Dean', 'Check answer');
      insert into lab_runs (project_id, file_name, made, stuck) values ('PROJ-00000', 'check.pdf', 3, 1);
      select count(*) into n from v_lab_rules_now where rule_key = 'check-shape' and value = '"NO BISCUITS!"';
      select count(*) into m from v_lab_answers_now where item_id = 'CHECK' and value = 'Dean';
      select n + m + count(*) into n from lab_runs where file_name = 'check.pdf';
      ok := lab_allowed() and n = 3;
      execute 'reset role';
      msg := format('read back %s of 3', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A lab user can teach a rule, give an answer and save a run, and reads them back', ok, msg);

    -- ---- 5: the newest row wins, and "stop using" is a row too ---------------------------------------
    begin
      execute 'set local role authenticated';
      insert into lab_rules (rule_set, rule_key, value, note, made_at) values ('notes_by_shape', 'check-shape', null, 'Stop using - check', now() + interval '1 second');
      select value::text into txt from v_lab_rules_now where rule_key = 'check-shape';
      select count(*) into n from lab_rules where rule_key = 'check-shape';
      execute 'reset role';
      ok := txt is null and n = 2; msg := format('newest value %s, %s rows kept', coalesce(txt, 'none'), n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A newer rule replaces an older one, and both rows are kept', ok, msg);

    -- ---- 6: even a lab user can''t change or delete what's there, or write as someone else ----------
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      update lab_rules set note = 'changed' where id = r; get diagnostics m = row_count; execute 'reset role';
      if m > 0 then msg := 'changed a rule'; else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      delete from lab_rules where id = r; get diagnostics m = row_count; execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'deleted a rule'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      insert into lab_rules (rule_set, rule_key, value, made_by) values ('defaults', 'check', '1', sup); execute 'reset role';
      msg := concat_ws(', ', msg, 'wrote a rule as someone else');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      insert into lab_rules (rule_set, rule_key, value) values ('anything_else', 'check', '1'); execute 'reset role';
      msg := concat_ws(', ', msg, 'kept a rule of an unknown kind');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(6, 'Nobody changes or deletes a rule, writes one as someone else, or adds an unknown kind', n = 4, msg);

    -- ---- 7: another manager, not let in, sees and writes nothing --------------------------------------
    if mgr is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      n := 0; msg := null;
      begin execute 'set local role authenticated';
        select count(*) into m from lab_rules; select m + count(*) into m from lab_runs; select m + count(*) into m from v_lab_answers_now;
        ok := lab_allowed(); execute 'reset role';
        if m > 0 or ok then msg := format('saw %s rows, allowed=%s', m, ok); else n := n + 1; end if;
      exception when others then execute 'reset role'; n := n + 1; end;
      begin execute 'set local role authenticated';
        insert into lab_rules (rule_set, rule_key, value) values ('defaults', 'check', '1'); execute 'reset role';
        msg := concat_ws(', ', msg, 'added a rule');
      exception when others then execute 'reset role'; n := n + 1; end;
      res := res || check_row(7, 'Another manager, not let into the lab, can''t see or add anything', n = 2, msg);
    else
      res := res || check_row(7, 'Another manager can''t see the lab (every manager is let in, so skipped)', true, null);
    end if;

    -- ---- 8: a supervisor sees and writes nothing ------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      select count(*) into m from lab_rules; select m + count(*) into m from lab_answers; select m + count(*) into m from lab_users;
      execute 'reset role';
      if m > 0 then msg := format('saw %s rows', m); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      insert into lab_runs (project_id) values ('PROJ-00000'); execute 'reset role';
      msg := concat_ws(', ', msg, 'saved a run');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      insert into lab_users (user_id) values (sup); execute 'reset role';
      msg := concat_ws(', ', msg, 'let itself into the lab');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(8, 'A supervisor can''t see the lab, save to it, or let itself in', n = 3, msg);

    -- ---- 9: no login: nothing ---------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin execute 'set local role anon';
      select count(*) into m from lab_rules; execute 'reset role';
      if m > 0 then msg := format('read %s rules', m); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role anon';
      perform lab_allowed(); execute 'reset role'; msg := concat_ws(', ', msg, 'called lab_allowed()');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(9, 'Someone with no login can''t read the lab or ask who''s in it', n = 2, coalesce(msg, '') || '. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_lab_undo__';
  exception when others then
    if sqlerrm <> '__check_lab_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  -- ---- 10: who's in (information: a PASS either way) ---------------------------------------------------
  perform set_config('request.jwt.claims', '', true);
  select count(*), string_agg(p.full_name, ', ' order by p.full_name) into n, txt from lab_users u join profiles p on p.id = u.user_id;
  res := res || check_row(10, case when n = 0 then 'Nobody is let into the lab yet. Next: select lab_allow(''your login email'');'
                                   else 'Let into the lab: ' || txt end, true, null);

  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_lab() from public, anon, authenticated;

select * from check_lab();
