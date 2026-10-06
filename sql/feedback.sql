-- =====================================================================
-- Shop Floor — the Feedback button (5 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it adds (nothing existing changes):
--   1. A table, feedback: one row per note sent with the Feedback button
--      on any page. Each row keeps who sent it (and their name at the
--      time), whether it came from a test login, which page, what was
--      on screen, the page's version, the note, and when.
--   2. One function, send_feedback(), the only way in. Any signed-in
--      login can send; the login is read from the sign-in itself, so
--      nobody can send as someone else. A note that's resent (no signal,
--      tried again) carries the same id, so it's never kept twice.
--   3. Managers (the office) read every note; nobody else reads any.
--      Nothing is ever deleted. There are no replies: it's a record for
--      planning future changes.
--   4. check_feedback(): the PASS/FAIL check.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('feedback.sql', '{}'); end if;
end $$;

create table if not exists feedback (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null unique,                       -- made on the device; a resend can't double it
  user_id      uuid not null references profiles(id),
  person_name  text not null,                              -- their name when they sent it
  is_test      boolean not null default false,             -- sent from a test login
  page         text not null,                              -- index (tablets, phone), office, delivery, inventory, pace, upload
  screen       text,                                       -- what was on screen, in words
  page_version text,
  body         text not null,
  created_at   timestamptz not null default now(),
  constraint feedback_page_known check (page in ('index', 'office', 'delivery', 'inventory', 'pace', 'upload')),
  constraint feedback_body_size check (length(btrim(body)) between 1 and 2000)
);
create index if not exists feedback_created on feedback (created_at desc);

alter table feedback enable row level security;
revoke all on feedback from anon, authenticated;
grant select on feedback to authenticated;                  -- the rows a login may see are decided below
drop policy if exists feedback_office_reads on feedback;
create policy feedback_office_reads on feedback for select to authenticated using (is_manager());

create or replace function send_feedback(p_client_id uuid, p_page text, p_screen text default null,
                                         p_version text default null, p_body text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_p profiles; v_id uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  if auth.uid() is null then
    raise exception 'Sign in first, so the office knows who it''s from.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_p from profiles where id = auth.uid();
  if v_p.id is null or not v_p.active then
    raise exception 'This login isn''t set up in the shop floor system.' using errcode = 'insufficient_privilege';
  end if;
  if p_client_id is null then raise exception 'This note has no id. Send it again.'; end if;
  select id into v_id from feedback where client_id = p_client_id;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent. Thanks.');
  end if;
  if v_body = '' then raise exception 'Type what you''d like to say first.'; end if;
  if length(v_body) > 2000 then raise exception 'Keep it to 2,000 letters, or send it as two notes.'; end if;
  if coalesce(p_page, '') not in ('index', 'office', 'delivery', 'inventory', 'pace', 'upload') then
    raise exception 'That page isn''t one the system knows.';
  end if;
  insert into feedback (client_id, user_id, person_name, is_test, page, screen, page_version, body)
  values (p_client_id, v_p.id, v_p.full_name, coalesce(v_p.is_test, false), p_page,
          left(nullif(btrim(coalesce(p_screen, '')), ''), 300), left(nullif(btrim(coalesce(p_version, '')), ''), 60), v_body)
  on conflict (client_id) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from feedback where client_id = p_client_id; end if;   -- sent twice at once
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', 'Thanks — sent to the office.');
end;
$$;
revoke all on function send_feedback(uuid, text, text, text, text) from public, anon;
grant execute on function send_feedback(uuid, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_feedback()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sup uuid; tst uuid; c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  r jsonb; n int; m int; ok boolean; msg text; f feedback;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test order by full_name limit 1;
  select id into tst from profiles where is_test and active limit 1;
  if mgr is null or sup is null then
    res := res || check_row(1, 'A manager and a supervisor login exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- ---- 1: a supervisor sends a note; it records who, where and what --------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := send_feedback(c1, 'index', 'Sanding › Work orders › PROJ-CHECK', '2026-10-05.1', '  Check note - undone automatically  ');
      execute 'reset role';
      select * into f from feedback where client_id = c1;
      ok := f.user_id = sup and f.person_name = (select full_name from profiles where id = sup) and f.page = 'index'
            and f.screen = 'Sanding › Work orders › PROJ-CHECK' and f.page_version = '2026-10-05.1'
            and f.body = 'Check note - undone automatically' and not f.is_test;
      msg := case when ok then null else 'Got: ' || coalesce(row_to_json(f)::text, 'nothing saved') end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'A supervisor can send feedback; it keeps their name, the page, the screen, the version and the note', ok, msg);

    -- ---- 2: sending the same note again keeps one ------------------------------------------------------
    begin
      execute 'set local role authenticated';
      r := send_feedback(c1, 'index', 'again', null, 'Check note - undone automatically');
      execute 'reset role';
      select count(*) into n from feedback where client_id = c1;
      ok := n = 1 and (r->>'already')::boolean; msg := format('%s rows', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A note sent twice (no signal, tried again) is kept once', ok, msg);

    -- ---- 3: an empty note, a note over 2,000 letters, an unknown page are refused --------------------
    n := 0; msg := null;
    begin execute 'set local role authenticated'; perform send_feedback(gen_random_uuid(), 'index', null, null, '   ');
      execute 'reset role'; msg := 'an empty note was kept';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform send_feedback(gen_random_uuid(), 'index', null, null, repeat('x', 2001));
      execute 'reset role'; msg := concat_ws(', ', msg, 'a 2,001-letter note was kept');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform send_feedback(gen_random_uuid(), 'somewhere', null, null, 'Check');
      execute 'reset role'; msg := concat_ws(', ', msg, 'an unknown page was kept');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(3, 'An empty note, one over 2,000 letters, or an unknown page is refused', n = 3, msg);

    -- ---- 4: a supervisor reads none, and can't write or change the table directly -----------------------
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      select count(*) into m from feedback;
      execute 'reset role';
      if m > 0 then msg := format('read %s notes', m); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      insert into feedback (client_id, user_id, person_name, page, body) values (gen_random_uuid(), mgr, 'Someone else', 'index', 'Check');
      execute 'reset role'; msg := concat_ws(', ', msg, 'wrote a note straight into the table');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      update feedback set body = 'changed' where client_id = c1;
      get diagnostics m = row_count;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'changed a note'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      delete from feedback where client_id = c1;
      get diagnostics m = row_count;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'deleted a note'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(4, 'A supervisor can''t read anyone''s feedback, write it as someone else, change it or delete it', n = 4, msg);

    -- ---- 5: a manager reads them all ---------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from feedback where client_id = c1;
      execute 'reset role';
      ok := n = 1; msg := format('saw %s of 1', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A manager (the office) reads every note', ok, msg);

    -- ---- 6: a test login's note is marked test ---------------------------------------------------------
    if tst is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        perform send_feedback(c2, 'index', 'Test', null, 'Check note - undone automatically');
        execute 'reset role';
        select is_test into ok from feedback where client_id = c2;
        msg := case when ok then null else 'It wasn''t marked test' end;
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(6, 'A note from the Test Supervisor is marked TEST', coalesce(ok, false), msg);
    else
      res := res || check_row(6, 'A note from the Test Supervisor is marked TEST (no test login, so skipped)', true, null);
    end if;

    -- ---- 7: no login: can't send, can't read --------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin
      execute 'set local role anon';
      perform send_feedback(gen_random_uuid(), 'index', null, null, 'Check');
      execute 'reset role'; msg := 'sent a note with no login';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role anon';
      select count(*) into m from feedback;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, format('read %s notes', m)); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(7, 'Someone with no login can''t send or read feedback', n = 2, coalesce(msg, '') || '. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_feedback_undo__';
  exception when others then
    if sqlerrm <> '__check_feedback_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_feedback() from public, anon, authenticated;

select * from check_feedback();
