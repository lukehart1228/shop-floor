-- =====================================================================
-- Shop Floor — closing feedback notes (20 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it adds (nothing existing changes; the feedback table and
-- send_feedback() are untouched):
--   1. A table, feedback_closes: one row each time the office marks a
--      note Solved or Not relevant, or puts it back. Who, when, which
--      state. Rows are only ever added, so the history stays.
--   2. A view, v_feedback: every note with its current state (open,
--      solved or not_relevant) and, when closed, who closed it and when.
--      It reads through the same rule as the feedback table, so only
--      managers see anything. The office page (office.html 2026-10-20.1
--      or later) shows open notes first and closed ones folded under
--      Closed, each with Put it back.
--   3. set_feedback_state(note, state): managers only. Marking a note
--      the state it's already in adds nothing, so a double tap is
--      harmless.
--   4. Nothing is deleted: a closed note keeps its text, who sent it and
--      when, and stays in the feedback table. An older office page still
--      lists every note, closed or not.
--   5. check_feedback_close(): the PASS/FAIL check.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('feedback_close.sql', '{}'); end if;
end $$;

do $$ begin
  if to_regclass('public.feedback') is null then
    raise exception 'Run feedback.sql first. This file comes after it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The history of closing and putting back
-- ---------------------------------------------------------------------
create table if not exists feedback_closes (
  id           bigserial primary key,                      -- the order things happened in
  feedback_id  uuid not null references feedback(id),
  state        text not null,
  by_user      uuid references profiles(id),
  by_name      text not null,
  at           timestamptz not null default now(),
  constraint feedback_closes_state_known check (state in ('open', 'solved', 'not_relevant'))
);
create index if not exists feedback_closes_note on feedback_closes (feedback_id, id desc);

alter table feedback_closes enable row level security;
revoke all on feedback_closes from anon, authenticated;
revoke all on sequence feedback_closes_id_seq from anon, authenticated;
grant select on feedback_closes to authenticated;           -- the rows a login may see are decided below
drop policy if exists feedback_closes_office_reads on feedback_closes;
create policy feedback_closes_office_reads on feedback_closes for select to authenticated using (is_manager());

-- ---------------------------------------------------------------------
-- 2. Every note with its current state
-- ---------------------------------------------------------------------
create or replace view v_feedback with (security_invoker = true) as
select f.*,
       coalesce(c.state, 'open')                         as state,
       case when c.state in ('solved', 'not_relevant') then c.by_name end as closed_by_name,
       case when c.state in ('solved', 'not_relevant') then c.at end      as closed_at
from feedback f
left join lateral (select x.state, x.by_name, x.at from feedback_closes x
                   where x.feedback_id = f.id order by x.id desc limit 1) c on true;
revoke all on v_feedback from anon, authenticated;
grant select on v_feedback to authenticated;

-- ---------------------------------------------------------------------
-- 3. set_feedback_state(): the office closes a note, or puts it back
-- ---------------------------------------------------------------------
create or replace function set_feedback_state(p_feedback_id uuid, p_state text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_now text;
begin
  if not office_ok() then
    raise exception 'Only the office can close feedback.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_state, '') not in ('open', 'solved', 'not_relevant') then
    raise exception 'Choose Solved, Not relevant or Put it back.';
  end if;
  if p_feedback_id is null or not exists (select 1 from feedback where id = p_feedback_id) then
    raise exception 'That note isn''t there. Reload the page.';
  end if;
  perform 1 from feedback where id = p_feedback_id for update;     -- two taps at once keep one row
  select coalesce((select state from feedback_closes where feedback_id = p_feedback_id order by id desc limit 1), 'open') into v_now;
  if v_now = p_state then
    return jsonb_build_object('ok', true, 'state', p_state, 'already', true);
  end if;
  insert into feedback_closes (feedback_id, state, by_user, by_name) values (p_feedback_id, p_state, auth.uid(), my_name());
  return jsonb_build_object('ok', true, 'state', p_state,
    'summary', case p_state when 'solved' then 'Closed as solved. It''s under Closed at the bottom; Put it back undoes it.'
                when 'not_relevant' then 'Closed as not relevant. It''s under Closed at the bottom; Put it back undoes it.'
                else 'Put back on the list.' end);
end;
$$;
revoke all on function set_feedback_state(uuid, text) from public, anon;
grant execute on function set_feedback_state(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_feedback_close()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sup uuid; c1 uuid := gen_random_uuid(); note uuid;
  r jsonb; n int; m int; ok boolean; msg text; v record; body_before text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test order by full_name limit 1;
  if mgr is null or sup is null then
    res := res || check_row(1, 'A manager and a supervisor login exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- a note to work on, sent by the supervisor as the Feedback button would
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    r := send_feedback(c1, 'index', 'Check', '2026-10-20.1', 'Check note - undone automatically');
    execute 'reset role';
    note := (r->>'id')::uuid;
    select body into body_before from feedback where id = note;

    -- ---- 1: a manager marks it Solved -----------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := set_feedback_state(note, 'solved');
      select * into v from v_feedback where id = note;
      execute 'reset role';
      ok := v.state = 'solved' and v.closed_by_name = (select full_name from profiles where id = mgr) and v.closed_at is not null
            and v.body = body_before and v.person_name = (select full_name from profiles where id = sup);
      msg := case when ok then null else format('state %s, closed by %s', v.state, v.closed_by_name) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'A manager can close a note as Solved; it shows who closed it and when, and the note is unchanged', ok, msg);

    -- ---- 2: a double tap adds nothing; Not relevant, then Put it back, keeps all the history -------------
    begin
      execute 'set local role authenticated';
      perform set_feedback_state(note, 'solved');
      execute 'reset role';
      select count(*) into n from feedback_closes where feedback_id = note;
      execute 'set local role authenticated';
      perform set_feedback_state(note, 'not_relevant');
      perform set_feedback_state(note, 'open');
      select * into v from v_feedback where id = note;
      execute 'reset role';
      select count(*) into m from feedback_closes where feedback_id = note;
      ok := n = 1 and m = 3 and v.state = 'open' and v.closed_by_name is null and v.closed_at is null;
      msg := case when ok then null else format('after the double tap %s rows (want 1); after three changes %s (want 3); now %s', n, m, v.state) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Closing twice keeps one record; Not relevant then Put it back reopens the note and keeps every change', ok, msg);

    -- ---- 3: an unknown state, or a note that isn't there, is refused ------------------------------------
    n := 0; msg := null;
    begin execute 'set local role authenticated'; perform set_feedback_state(note, 'gone');
      execute 'reset role'; msg := 'an unknown state was kept';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform set_feedback_state(gen_random_uuid(), 'solved');
      execute 'reset role'; msg := concat_ws(', ', msg, 'a note that isn''t there was closed');
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(3, 'An unknown state, or a note that isn''t there, is refused', n = 2, msg);

    -- ---- 4: a supervisor can't close or reopen, and reads nothing -----------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin execute 'set local role authenticated'; perform set_feedback_state(note, 'solved');
      execute 'reset role'; msg := 'closed a note';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      select count(*) into m from v_feedback;
      select count(*) + m into m from feedback_closes;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, format('read %s rows', m)); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(4, 'A supervisor can''t close or reopen a note, or read the notes or who closed them', n = 2, msg);

    -- ---- 5: nobody signed in writes the history directly, or deletes a note --------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin
      execute 'set local role authenticated';
      insert into feedback_closes (feedback_id, state, by_name) values (note, 'solved', 'Someone else');
      execute 'reset role'; msg := 'a manager wrote straight into the history';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      delete from feedback_closes where feedback_id = note;
      get diagnostics m = row_count;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'a manager deleted the history'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      delete from feedback where id = note;
      get diagnostics m = row_count;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'a manager deleted the note'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      update feedback set body = 'changed' where id = note;
      get diagnostics m = row_count;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'a manager changed the note'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(5, 'Nobody can write or delete the close history directly, or delete or change a note: closing never removes anything', n = 4, msg);

    -- ---- 6: the older office page still reads every note, closed or not ------------------------------------
    begin
      execute 'set local role authenticated';
      perform set_feedback_state(note, 'solved');
      select count(*) into n from feedback where id = note;
      execute 'reset role';
      ok := n = 1; msg := case when ok then null else 'The closed note is missing from the feedback table' end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A closed note is still in the feedback table, so an older office page still lists it', ok, msg);

    -- ---- 7: no login: can't close, can't read ------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin
      execute 'set local role anon';
      perform set_feedback_state(note, 'open');
      execute 'reset role'; msg := 'reopened a note with no login';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role anon';
      select count(*) into m from v_feedback;
      execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, format('read %s notes', m)); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(7, 'Someone with no login can''t close, reopen or read notes', n = 2, case when n = 2 then null else msg || '. Do not go further.' end);

    raise exception using errcode = 'P0001', message = '__check_feedback_close_undo__';
  exception when others then
    if sqlerrm <> '__check_feedback_close_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_feedback_close() from public, anon, authenticated;

select * from check_feedback_close();
