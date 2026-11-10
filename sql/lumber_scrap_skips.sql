-- =====================================================================
-- lumber_scrap_skips.sql — Months left out of the scrap results (7 Nov 2026)
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 58. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table.
-- Needs purchasing.sql (57). Replaces nothing, so no earlier file stops.
--
-- WHY: Purchasing's Lumber tab works out lumber saved against the 1.7
-- scrap allowance from the workbook's months and Inventory's closed
-- months. A month whose counts weren't complete (September 2026: the
-- counting wasn't done) gives a used figure that isn't real scrap, and
-- one such month swamps the year. A manager leaves it out on the Lumber
-- tab, with a reason. The month itself stays as it is everywhere,
-- Inventory included; only Purchasing's scrap results skip it. Put
-- back, it counts again. Nothing is deleted: a month left out and put
-- back keeps its row, marked.
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('lumber_scrap_skips.sql', 58, 'check_lumber_scrap_skips', 'check_lumber_scrap_skips', '{}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('lumber_scrap_skips.sql', '{}'); end if;
end $$;
do $$ begin
  if to_regprocedure('public.purchasing_data()') is null then raise exception 'Run purchasing.sql first. This file builds on it.'; end if;
end $$;

create table if not exists lumber_scrap_skips (
  month_end       date primary key,
  left_out        boolean not null default true,   -- false: put back (it counts again); the row is kept
  reason          text not null check (length(reason) between 1 and 200),
  changed_at      timestamptz not null default now(),
  changed_by_name text
);
alter table lumber_scrap_skips enable row level security;
revoke all on lumber_scrap_skips from anon, authenticated;

-- leave a month out of the scrap results (p_out true, with a reason) or put it back (p_out false)
create or replace function lumber_scrap_skip_save(p_month date, p_out boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_name text;
begin
  if not office_ok() then raise exception 'Only a manager changes the scrap results.' using errcode = 'insufficient_privilege'; end if;
  if p_month is null then raise exception 'Say which month.'; end if;
  if p_month <> (date_trunc('month', p_month) + interval '1 month - 1 day')::date then raise exception 'Give the month''s last day, like %.', (date_trunc('month', p_month) + interval '1 month - 1 day')::date; end if;
  v_name := to_char(p_month, 'FMMonth YYYY');
  if coalesce(p_out, true) then
    if v_reason is null then raise exception 'Say why % is left out (for example: the counts weren''t done).', v_name; end if;
    if length(v_reason) > 200 then raise exception 'Keep the reason under 200 letters.'; end if;
    insert into lumber_scrap_skips (month_end, left_out, reason, changed_by_name) values (p_month, true, v_reason, my_name())
    on conflict (month_end) do update set left_out = true, reason = excluded.reason, changed_at = now(), changed_by_name = excluded.changed_by_name;
    return jsonb_build_object('ok', true, 'summary', format('%s is left out of the scrap results. It stays on record.', v_name));
  end if;
  update lumber_scrap_skips set left_out = false, changed_at = now(), changed_by_name = my_name() where month_end = p_month;
  return jsonb_build_object('ok', true, 'summary', format('%s counts in the scrap results again.', v_name));
end $$;
revoke all on function lumber_scrap_skip_save(date, boolean, text) from public, anon;
grant execute on function lumber_scrap_skip_save(date, boolean, text) to authenticated;

-- the months left out, for the Lumber tab
create or replace function lumber_scrap_skips_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then raise exception 'Only a manager sees purchasing.' using errcode = 'insufficient_privilege'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('month_end', month_end, 'reason', reason, 'by', changed_by_name, 'at', changed_at) order by month_end)
                     from lumber_scrap_skips where left_out), '[]'::jsonb);
end $$;
revoke all on function lumber_scrap_skips_list() from public, anon;
grant execute on function lumber_scrap_skips_list() to authenticated;


create or replace function check_lumber_scrap_skips()
returns table(step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$
declare
  res jsonb := '[]'::jsonb; ok boolean; msg text; n int; r jsonb; l jsonb;
  mgr uuid := '00000000-0000-4000-8000-00000000c581'; sup uuid := '00000000-0000-4000-8000-00000000c582';
  m date := '2026-09-30';
begin
  select count(*) into n from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'lumber_scrap_skips' and grantee in ('anon', 'authenticated');
  ok := n = 0 and (select relrowsecurity from pg_class where oid = 'public.lumber_scrap_skips'::regclass);
  res := res || check_row(1, 'The months-left-out table has its security rule on, and no login reads or writes it directly', ok,
                          format('%s grants found, or the rule is off. Run lumber_scrap_skips.sql again.', n));
  select count(*) into n from information_schema.routine_privileges
   where routine_schema = 'public' and grantee in ('anon', 'PUBLIC') and routine_name in ('lumber_scrap_skip_save', 'lumber_scrap_skips_list');
  res := res || check_row(2, 'Its two functions need a login', n = 0, format('%s grants too many. Run lumber_scrap_skips.sql again.', n));

  begin   -- everything below is undone at the end
    insert into auth.users (id, email) values (mgr, 'check-skip-mgr@example.com'), (sup, 'check-skip-sup@example.com');
    insert into profiles (id, full_name, role, departments) values (mgr, 'Skip check (manager)', 'manager', '{}'), (sup, 'Skip check (supervisor)', 'supervisor', '{milling}');
    delete from lumber_scrap_skips where month_end = m;

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      begin perform lumber_scrap_skip_save(m, true, 'x'); ok := false; msg := 'A supervisor left a month out.';
      exception when insufficient_privilege then ok := true; msg := null; end;
      begin perform lumber_scrap_skips_list(); ok := false; msg := 'A supervisor read the list.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'A supervisor can''t leave a month out or read the list', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      msg := '';
      begin perform lumber_scrap_skip_save(m, true, ''); msg := msg || 'left out with no reason; '; exception when others then null; end;
      begin perform lumber_scrap_skip_save('2026-09-15', true, 'x'); msg := msg || 'a date that isn''t a month''s end; '; exception when others then null; end;
      r := lumber_scrap_skip_save(m, true, 'The counts weren''t done');
      l := lumber_scrap_skips_list();
      execute 'reset role';
      ok := msg = '' and exists (select 1 from jsonb_array_elements(l) x where (x ->> 'month_end')::date = m and x ->> 'reason' = 'The counts weren''t done');
      msg := nullif(msg, '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'A manager leaves September out with a reason; no reason, or a date that isn''t a month''s end, is refused', ok, coalesce(msg, l::text));

    begin execute 'set local role authenticated';
      r := lumber_scrap_skip_save(m, false);
      l := lumber_scrap_skips_list();
      execute 'reset role';
      ok := not exists (select 1 from jsonb_array_elements(l) x where (x ->> 'month_end')::date = m)
            and exists (select 1 from lumber_scrap_skips where month_end = m and not left_out);
      msg := l::text;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'Put back, it''s off the list and counts again; its row is kept, marked', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_lumber_scrap_skips_undo__';
  exception when others then
    begin execute 'reset role'; exception when others then null; end;
    if sqlerrm <> '__check_lumber_scrap_skips_undo__' then res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end $$;
revoke all on function check_lumber_scrap_skips() from public, anon, authenticated;

select * from check_lumber_scrap_skips();
