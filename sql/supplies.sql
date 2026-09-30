-- =====================================================================
-- Shop Floor — supply orders (whole-floor build, step 7)
--
-- HOW TO USE: run problems.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. Safe to run
-- more than once.
--
-- The life of a request:
--   requested → the supervisor types what they need and how many
--   ordered   → the office ticks it on the Ordering screen
--   received  → the department that asked taps Received (the office
--               can too). Only now does it leave every list.
-- Side exits: the supervisor can cancel before it's ordered; the office
-- can mark "Not ordering" with a reason, which the supervisor sees.
-- The quantity is the number wanted, not an addition — the same rule as
-- counts — and can be changed while it's still waiting on the office.
-- Nothing is deleted; every step is kept with a name and a time.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('supplies.sql'); end if;
end $$;

do $$
begin
  if to_regprocedure('public.sees_lane(boolean)') is null then
    raise exception 'Run problems.sql first (step 4). This file builds on it.';
  end if;
end $$;

create table if not exists supply_requests (
  id                  uuid primary key default gen_random_uuid(),
  client_id           uuid unique,
  department          text        not null references departments(key),
  item                text        not null check (length(trim(item)) > 0),
  qty                 int         not null check (qty > 0),
  note                text,
  state               text        not null default 'requested'
                        check (state in ('requested', 'ordered', 'received', 'cancelled', 'not_ordering')),
  is_test             boolean     not null default false,
  requested_by        uuid        references profiles(id),
  requested_by_name   text,
  requested_at        timestamptz not null default now(),
  ordered_by_name     text,
  ordered_at          timestamptz,
  received_by_name    text,
  received_at         timestamptz,
  closed_by_name      text,          -- cancelled or not ordering
  closed_at           timestamptz,
  not_ordering_reason text,
  updated_at          timestamptz not null default now()
);
create index if not exists supply_requests_state_idx on supply_requests (state, department, requested_at);

create table if not exists supply_request_events (
  id          bigserial primary key,
  request_id  uuid        not null references supply_requests(id) on delete cascade,
  what        text        not null,
  by_name     text,
  at          timestamptz not null default now()
);

alter table supply_requests enable row level security;
alter table supply_request_events enable row level security;
drop policy if exists read_supply_requests on supply_requests;
create policy read_supply_requests on supply_requests for select to authenticated using (sees_lane(is_test));
drop policy if exists read_supply_events on supply_request_events;
create policy read_supply_events on supply_request_events for select to authenticated
  using (exists (select 1 from supply_requests r where r.id = request_id));
revoke insert, update, delete on supply_requests, supply_request_events from anon, authenticated;

-- a supervisor acting on their own department's request, in their own lane
create or replace function supply_floor_check(p_request uuid) returns supply_requests
language plpgsql stable security definer set search_path = public as $$
declare v supply_requests;
begin
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select * into v from supply_requests where id = p_request;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That request isn''t there.'; end if;
  if not is_manager() and (not owns_dept(v.department) or v.is_test <> am_test()) then
    raise exception 'Only % can change this request.', (select name from departments where key = v.department)
      using errcode = 'insufficient_privilege';
  end if;
  return v;
end $$;
revoke all on function supply_floor_check(uuid) from public, anon, authenticated;

create or replace function request_supply(p_department text, p_item text, p_qty int, p_note text default null,
                                          p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text;
begin
  if p_client_id is not null then
    select id into v_id from supply_requests where client_id = p_client_id;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.'); end if;
  end if;
  if my_role() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  select name into v_name from departments where key = p_department;
  if v_name is null then raise exception '"%" is not a department.', p_department; end if;
  if not owns_dept(p_department) then
    raise exception 'This login can''t ask for supplies for %.', v_name using errcode = 'insufficient_privilege';
  end if;
  if nullif(trim(p_item), '') is null then raise exception 'Type what you need first.'; end if;
  if coalesce(p_qty, 0) < 1 then raise exception 'How many? At least 1.'; end if;
  insert into supply_requests (client_id, department, item, qty, note, is_test, requested_by, requested_by_name)
  values (p_client_id, p_department, trim(p_item), p_qty, nullif(trim(p_note), ''), am_test(), auth.uid(), my_name())
  returning id into v_id;
  insert into supply_request_events (request_id, what, by_name) values (v_id, format('Asked for %s', p_qty), my_name());
  return jsonb_build_object('ok', true, 'id', v_id, 'summary', format('Asked the office for %s × %s.', p_qty, trim(p_item)));
exception when unique_violation then
  select id into v_id from supply_requests where client_id = p_client_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', true, 'summary', 'Already sent.');
end $$;
revoke all on function request_supply(text, text, int, text, uuid) from public, anon;
grant execute on function request_supply(text, text, int, text, uuid) to authenticated;

-- the number wanted, not an addition. While it's still waiting on the office.
create or replace function set_supply_qty(p_request uuid, p_qty int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_requests;
begin
  v := supply_floor_check(p_request);
  if coalesce(p_qty, 0) < 1 then raise exception 'How many? At least 1.'; end if;
  if v.state <> 'requested' then
    raise exception 'This has already been %. Ask for more with a new request.', replace(v.state, '_', ' ');
  end if;
  if v.qty <> p_qty then
    update supply_requests set qty = p_qty, updated_at = now() where id = p_request;
    insert into supply_request_events (request_id, what, by_name) values (p_request, format('Changed %s → %s', v.qty, p_qty), my_name());
  end if;
  return jsonb_build_object('ok', true, 'summary', format('Now asking for %s.', p_qty));
end $$;
revoke all on function set_supply_qty(uuid, int) from public, anon;
grant execute on function set_supply_qty(uuid, int) to authenticated;

create or replace function cancel_supply(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_requests;
begin
  v := supply_floor_check(p_request);
  if v.state = 'cancelled' then return jsonb_build_object('ok', true, 'summary', 'Already cancelled.'); end if;
  if v.state <> 'requested' then
    raise exception 'This has already been %, so it can''t be cancelled here. Tell the office.', replace(v.state, '_', ' ');
  end if;
  update supply_requests set state = 'cancelled', closed_by_name = my_name(), closed_at = now(), updated_at = now() where id = p_request;
  insert into supply_request_events (request_id, what, by_name) values (p_request, 'Cancelled', my_name());
  return jsonb_build_object('ok', true, 'summary', 'Cancelled.');
end $$;
revoke all on function cancel_supply(uuid) from public, anon;
grant execute on function cancel_supply(uuid) to authenticated;

create or replace function receive_supply(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_requests;
begin
  v := supply_floor_check(p_request);
  if v.state = 'received' then return jsonb_build_object('ok', true, 'summary', 'Already received.'); end if;
  if v.state not in ('ordered', 'requested') or (v.state = 'requested' and not is_manager()) then
    raise exception '%', case v.state when 'requested' then 'The office hasn''t ordered this yet.'
                                      else 'This request is closed.' end;
  end if;
  update supply_requests set state = 'received', received_by_name = my_name(), received_at = now(), updated_at = now() where id = p_request;
  insert into supply_request_events (request_id, what, by_name) values (p_request, 'Received', my_name());
  return jsonb_build_object('ok', true, 'summary', format('%s × %s received.', v.qty, v.item));
end $$;
revoke all on function receive_supply(uuid) from public, anon;
grant execute on function receive_supply(uuid) to authenticated;

-- the office: tick one or several lines as ordered
create or replace function order_supplies(p_requests uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not office_ok() then
    raise exception 'Only the office (a manager login) can mark supplies ordered.' using errcode = 'insufficient_privilege';
  end if;
  with done as (
    update supply_requests set state = 'ordered', ordered_by_name = my_name(), ordered_at = now(), updated_at = now()
     where id = any(coalesce(p_requests, '{}')) and state = 'requested'
    returning id)
  insert into supply_request_events (request_id, what, by_name) select id, 'Ordered', my_name() from done;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'ordered', n,
    'summary', format('%s line%s marked ordered.', n, case when n = 1 then '' else 's' end));
end $$;
revoke all on function order_supplies(uuid[]) from public, anon;
grant execute on function order_supplies(uuid[]) to authenticated;

create or replace function not_ordering_supply(p_request uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v supply_requests;
begin
  if not office_ok() then
    raise exception 'Only the office (a manager login) can decide not to order.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from supply_requests where id = p_request;
  if v.id is null then raise exception 'That request isn''t there.'; end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Give a reason — the supervisor sees it (for example "we have 3 boxes in the back").';
  end if;
  if v.state not in ('requested', 'ordered') then raise exception 'This request is already closed.'; end if;
  update supply_requests set state = 'not_ordering', not_ordering_reason = trim(p_reason), closed_by_name = my_name(),
                             closed_at = now(), updated_at = now() where id = p_request;
  insert into supply_request_events (request_id, what, by_name) values (p_request, 'Not ordering: ' || trim(p_reason), my_name());
  return jsonb_build_object('ok', true, 'summary', 'Marked not ordering. The department sees your reason.');
end $$;
revoke all on function not_ordering_supply(uuid, text) from public, anon;
grant execute on function not_ordering_supply(uuid, text) to authenticated;

drop view if exists v_supply_requests;
create view v_supply_requests with (security_invoker = true) as
select r.id, r.department, d.name as department_name, r.item, r.qty, r.note, r.state, r.is_test,
       r.requested_by, r.requested_by_name, r.requested_at, r.ordered_by_name, r.ordered_at,
       r.received_by_name, r.received_at, r.closed_by_name, r.closed_at, r.not_ordering_reason, r.updated_at,
       (r.state in ('requested', 'ordered')) as is_open,
       coalesce((select jsonb_agg(jsonb_build_object('what', e.what, 'by', e.by_name, 'at', e.at) order by e.at, e.id)
                   from supply_request_events e where e.request_id = r.id), '[]'::jsonb) as events
from supply_requests r
join departments d on d.key = r.department;
revoke all on v_supply_requests from anon;
grant select on v_supply_requests to authenticated;
