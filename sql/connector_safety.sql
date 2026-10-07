-- =====================================================================
-- Shop Floor — nothing but the database owner can reach the internet;
-- no-login functions limited to the ones meant for it (7 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- Fixes review findings R-14 and R-17, before any Claude connector to
-- Supabase is turned on. Nothing a supervisor or the office sees changes.
--
--   1. The http extension (and pg_net, if it's ever switched on) can send
--      anything to any address on the internet. Until now every role
--      could call it, including no-login, every login and the read-only
--      user a connector would use. Now only the database owner (postgres)
--      can. The Monday sync and setup_monday_columns() keep working: they
--      already run as postgres.
--   2. Three trigger functions lose the "anyone may call this" grant they
--      got by default. Triggers fire regardless; nobody could call them
--      directly anyway. This just makes the rule below hold everywhere.
--   3. check_connector_safety(): the PASS/FAIL check. check_everything()
--      runs it too, so a later SQL file that forgets its revoke lines
--      shows up as a FAIL.
--
-- The rule from here on: every function gets
--   revoke all on function … from public, anon;
-- before its grants. The only functions anyone may run without a login
-- are my_role(), owns_dept() (the security rules use them), tv_snapshot()
-- and tv_photo() (the floor TV).
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('connector_safety.sql', '{}'); end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Only the owner can reach the internet (R-14)
-- ---------------------------------------------------------------------
-- Every function belonging to the http or pg_net extension, found by
-- asking Postgres, so a rerun also covers anything an upgrade adds.
-- If a function doesn't belong to postgres, Postgres can't take its
-- grants away and only warns; the check below then says so plainly.

do $$
declare
  f    regprocedure;
  who  text;
begin
  who := 'public, anon, authenticated, service_role'
         || case when exists (select 1 from pg_roles where rolname = 'supabase_read_only_user') then ', supabase_read_only_user' else '' end;
  for f in
    select p.oid::regprocedure
      from pg_proc p
      join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
      join pg_extension e on e.oid = d.refobjid
     where e.extname in ('http', 'pg_net')
  loop
    begin
      execute format('revoke all on function %s from %s', f, who);
    exception when insufficient_privilege then
      raise notice 'Couldn''t change %: %. The check below says what to do.', f, sqlerrm;
    end;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 2. Trigger functions: no "anyone may call this" (R-17)
-- ---------------------------------------------------------------------

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prosecdef
       and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 3. The check
-- ---------------------------------------------------------------------

create or replace function check_connector_safety()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as no-login and a login
declare
  res     jsonb := '[]';
  roles   text[] := array['public', 'anon', 'authenticated', 'service_role', 'supabase_read_only_user'];
  ext_sch text;
  n int; m int; msg text; owners text; ok boolean;
  sup uuid;
  allowed text[] := array['my_role', 'owns_dept', 'tv_snapshot', 'tv_photo'];
begin
  -- roles this database actually has ('public' is everyone)
  roles := array(select r from unnest(roles) r where r = 'public' or exists (select 1 from pg_roles where rolname = r));

  -- ---- 1: nothing but the owner can call an internet-reaching function -------------------------
  with ext_fns as (
    select p.oid, p.proname, p.proowner
      from pg_proc p
      join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
      join pg_extension e on e.oid = d.refobjid
     where e.extname in ('http', 'pg_net')
  ), open_to as (
    select f.proname, f.proowner, r as who
      from ext_fns f cross join unnest(roles) r
     where case when r = 'public'
                then exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = f.oid), acldefault('f', f.proowner))) a
                              where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                else has_function_privilege(r, f.oid, 'execute') end
  )
  select count(distinct proname), string_agg(distinct proname || ' (' || who || ')', ', '),
         string_agg(distinct pg_get_userbyid(proowner), ', ') filter (where pg_get_userbyid(proowner) <> current_user)
    into n, msg, owners
    from open_to;
  res := res || check_row(1, 'Only the database owner can send anything to the internet (the http extension''s functions)', n = 0,
                          case when n = 0 then null
                               when owners is not null then 'Still open: ' || left(msg, 300) || '. These belong to ' || owners
                                    || ', not postgres, so the SQL Editor can''t take them away. Don''t turn a connector on; bring this line to Claude in a chat.'
                               else 'Still open: ' || left(msg, 300) || '. Run connector_safety.sql again.' end);

  -- ---- 2: proven by trying, as no login and as a signed-in login --------------------------------
  -- It tries http() itself, the function every other one goes through. The address is this
  -- machine's closed port 9, so even a wrong result sends nothing out.
  select extnamespace::regnamespace::text into ext_sch from pg_extension where extname = 'http';
  if ext_sch is null then
    res := res || check_row(2, 'No login and a signed-in login are refused when they try to reach the internet', true);
  else
    select id into sup from profiles where role = 'supervisor' and active and not is_test order by full_name limit 1;
    n := 0; m := 0; msg := null;

    m := m + 1;
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      execute format('select %1$I.http((%2$L, %3$L, null, null, null)::%1$I.http_request)', ext_sch, 'GET', 'http://127.0.0.1:9/');
      execute 'reset role'; msg := 'no login got through';
    exception
      when insufficient_privilege then execute 'reset role'; n := n + 1;
      when others then execute 'reset role'; msg := 'no login got as far as: ' || sqlerrm;
    end;

    if sup is not null then
      m := m + 1;
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        execute format('select %1$I.http((%2$L, %3$L, null, null, null)::%1$I.http_request)', ext_sch, 'GET', 'http://127.0.0.1:9/');
        execute 'reset role'; msg := concat_ws(', ', msg, 'a signed-in login got through');
      exception
        when insufficient_privilege then execute 'reset role'; n := n + 1;
        when others then execute 'reset role'; msg := concat_ws(', ', msg, 'a signed-in login got as far as: ' || sqlerrm);
      end;
      perform set_config('request.jwt.claims', '', true);
    end if;

    res := res || check_row(2, 'No login and a signed-in login are refused when they try to reach the internet', n = m,
                            left(msg, 300) || '. Run connector_safety.sql again.');
  end if;

  -- ---- 3: the Monday sync and setup_monday_columns() can still reach Monday -------------------
  select count(*), string_agg(f.fn || ' → ' || h.needs, ', ')
    into n, msg
    from (values ('run_monday_sync'), ('monday_request')) f(fn)
    cross join (values ('http'), ('http_header'), ('http_set_curlopt')) h(needs)
   where not exists (
           select 1
             from pg_proc p, pg_proc q
            where p.pronamespace = 'public'::regnamespace and p.proname = f.fn and p.prosecdef
              and q.pronamespace = (select extnamespace from pg_extension where extname = 'http') and q.proname = h.needs
              and has_function_privilege(p.proowner, q.oid, 'execute'));
  res := res || check_row(3, 'The Monday sync and setup_monday_columns() can still reach Monday (they run as the owner)', n = 0,
                          case when ext_sch is null then 'The http extension is off. Turn it on: Database → Extensions → http.'
                               else 'Can''t: ' || left(msg, 300) || '. Bring this line to Claude in a chat.' end);

  -- ---- 4: only the intended functions run without a login, or for anyone -----------------------
  select count(*), string_agg(p.oid::regprocedure::text, ', ')
    into n, msg
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and not (p.proname = any (allowed))
     and (   exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                      where a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or has_function_privilege('anon', p.oid, 'execute'));
  res := res || check_row(4, 'The only functions that run with full rights for anyone, or with no login, are my_role, owns_dept and the TV''s', n = 0,
                          case when n = 0 then null
                               else 'Open to everyone or no login: ' || left(msg, 300)
                                    || '. Its SQL file is missing "revoke all on function … from public, anon;". Bring this line to Claude in a chat.' end);

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
exception when others then
  begin execute 'reset role'; exception when others then null; end;
  perform set_config('request.jwt.claims', '', true);
  res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_connector_safety() from public, anon, authenticated;

select * from check_connector_safety();
