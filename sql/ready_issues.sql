-- =====================================================================
-- Shop Floor — Ready queues, metal cut sheets and Issues (25 Sep)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- The last thing it does is run its own check, so the result at the
-- bottom is a table: every row should say PASS.
-- Run the check again any time with:   select * from check_ready_issues();
--
-- What it changes:
--   1. What's "ready" for a department (v_ready_to_work). Wood stages are
--      exactly as before. Assembly / QC now waits on Metal as well as
--      Finishing: a piece is ready once both have it done, whichever of
--      the two the sheet has. A sheet with no metal counts Metal as done.
--      A sheet named on an Arrow item that hasn't come back has nothing
--      ready for Assembly / QC until it's marked returned. The TV uses
--      the same view, so its Assembly / QC "ready" number follows.
--      Full Custom doesn't hold anything back (decided 24 Sep; later).
--   2. v_metal_cut_sheets — the office's "Needs metal cut sheets" list:
--      real jobs in Pre-Production or In Production whose Monday Metal
--      Status says "Not Ready". Worked out from what the sync already
--      reads, so it clears itself when Monday changes. Managers only.
--   3. Defects can ask the office. A defect is still counted and still
--      interrupts nobody — unless "Ask the office" is ticked, or the
--      floor replies on it later. Then it waits on the office like an
--      issue, with the same answer / reply / "Came back" thread.
--      The office can send a note on any defect without making it wait.
--
-- Nothing is deleted or renamed: the problems and defects tables keep
-- their names and all their history. New columns are added to defects;
-- defect threads get their own table, defect_messages.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('ready_issues.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.outside_jobs') is null or to_regclass('public.photos') is null
     or to_regprocedure('public.check_row(integer,text,boolean,text)') is null then
    raise exception 'Run the earlier files first (arrow_qc.sql, check_floor.sql and photos.sql). This file builds on them.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. What's ready for each department, per sheet
--
-- Same four columns as before (department, sheet_id, job_id, ready),
-- plus three the tablet uses:
--   available   pieces the stages before have finished (so the tablet
--               can work out "ready" as counts change: available − done)
--   waiting_on  which stages are holding the rest back, e.g. {metal}
--   at_arrow    this sheet is at Arrow, so Assembly / QC can't have it
-- ---------------------------------------------------------------------

create or replace view v_ready_to_work with (security_invoker = true) as
with recursive ancestors as (
  -- every stage upstream of each department, nearest first
  select key as dept, predecessor as anc, 1 as depth
    from departments where predecessor is not null
  union all
  select a.dept, d.predecessor, a.depth + 1
    from ancestors a join departments d on d.key = a.anc
   where d.predecessor is not null
)
select
  sp.department,
  s.id as sheet_id,
  j.id as job_id,
  greatest(g.available - sp.qty_done, 0) as ready,
  g.available,
  case when sp.qty_done < sp.qty_required and g.available <= sp.qty_done then
    array_remove(array[
      case when up.department is not null and up.qty_done <= sp.qty_done then up.department end,
      case when mt.qty_done is not null and not mt.at_arrow and mt.qty_done <= sp.qty_done then 'metal' end
    ], null)
  else '{}'::text[] end as waiting_on,
  (coalesce(mt.at_arrow, false) and sp.qty_done < sp.qty_required) as at_arrow
from sheet_progress sp
join sheets s      on s.id = sp.sheet_id
join work_orders w on w.id = s.work_order_id and w.is_current
join jobs j        on j.id = w.job_id and j.is_active
left join lateral (
  -- nearest upstream wood stage that exists on THIS sheet — so a sheet with
  -- no CNC work reads sanding's supply from milling rather than from nothing
  select pre.department, pre.qty_done
    from ancestors a
    join sheet_progress pre on pre.sheet_id = sp.sheet_id and pre.department = a.anc
   where a.dept = sp.department
   order by a.depth
   limit 1
) up on true
left join lateral (
  -- Assembly / QC also waits on Metal, when the sheet has metal. A sheet
  -- named on an Arrow item that hasn't come back counts as none ready.
  select m.qty_done,
         exists (select 1 from outside_jobs o
                  where o.job_id = j.id and o.returned_on is null and o.voided_at is null
                    and s.sheet_number = any(o.sheet_numbers)) as at_arrow
    from sheet_progress m
   where sp.department = 'assembly_qc' and m.sheet_id = sp.sheet_id and m.department = 'metal'
) mt on true
cross join lateral (
  select least(coalesce(up.qty_done, sp.qty_required),
               case when mt.qty_done is null then sp.qty_required
                    when mt.at_arrow then 0
                    else mt.qty_done end,
               sp.qty_required) as available
) g;

revoke all on v_ready_to_work from anon;
grant select on v_ready_to_work to authenticated;


-- ---------------------------------------------------------------------
-- 2. Needs metal cut sheets — for Needs you
-- ---------------------------------------------------------------------

drop view if exists v_metal_cut_sheets;
create view v_metal_cut_sheets with (security_invoker = true) as
select
  j.id            as job_id,
  j.project_id,
  j.name          as job_name,
  j.phase,
  j.delivery_date,
  j.monday_stages ->> 'metal' as metal_status
from jobs j
where j.monday_item_id is not null
  and not j.is_test
  and j.phase in ('Pre-Production', 'In Production')
  and lower(trim(coalesce(j.monday_stages ->> 'metal', ''))) = 'not ready'
  and my_role() in ('manager', 'admin');

revoke all on v_metal_cut_sheets from anon;
grant select on v_metal_cut_sheets to authenticated;


-- ---------------------------------------------------------------------
-- 3. Defects that ask the office
--
-- office_status:  null      counted, no answer needed (as every defect was)
--                 open      waiting on the office
--                 answered  the office answered and closed it
-- ---------------------------------------------------------------------

alter table defects add column if not exists ask_office       boolean not null default false;
alter table defects add column if not exists office_status    text check (office_status in ('open', 'answered'));
alter table defects add column if not exists came_back        boolean not null default false;
alter table defects add column if not exists answered_by      uuid references profiles(id);
alter table defects add column if not exists answered_by_name text;
alter table defects add column if not exists answered_at      timestamptz;
alter table defects add column if not exists last_activity_at timestamptz;
create index if not exists defects_office_idx on defects (office_status, last_activity_at) where office_status is not null;

create table if not exists defect_messages (
  id              bigserial primary key,
  client_id       uuid unique,
  defect_id       uuid        not null references defects(id) on delete cascade,
  kind            text        not null check (kind in ('answer', 'office_note', 'reply')),
  body            text        not null check (length(trim(body)) > 0),
  written_by      uuid        references profiles(id),
  written_by_name text,
  written_at      timestamptz not null default now()
);
create index if not exists defect_messages_defect_idx on defect_messages (defect_id, written_at);

alter table defect_messages enable row level security;
drop policy if exists read_defect_messages on defect_messages;
create policy read_defect_messages on defect_messages for select to authenticated
  using (exists (select 1 from defects d where d.id = defect_id));    -- defects' own rule decides
revoke insert, update, delete on defect_messages from anon, authenticated;
revoke all on defect_messages from anon;

-- Log a defect, and optionally ask the office about it in the same step.
-- Everything log_defect checks, this checks (it calls it).
create or replace function report_defect(p_job uuid, p_department text, p_type uuid, p_sheet int default null,
                                         p_note text default null, p_ask boolean default false, p_client_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; v_id uuid;
begin
  v := log_defect(p_job, p_department, p_type, p_sheet, p_note, p_client_id);
  v_id := nullif(v->>'id', '')::uuid;
  if coalesce(p_ask, false) and v_id is not null then
    update defects set ask_office = true, office_status = 'open', last_activity_at = now()
     where id = v_id and office_status is null;
    if found then
      v := v || jsonb_build_object('summary', (v->>'summary') || ' It''s with the office too.');
    end if;
  end if;
  return v;
end $$;
revoke all on function report_defect(uuid, text, uuid, int, text, boolean, uuid) from public, anon;
grant execute on function report_defect(uuid, text, uuid, int, text, boolean, uuid) to authenticated;

-- The floor asks about a defect, or adds to one already asked. It goes to the
-- office; an answered one comes back tagged "Came back".
create or replace function reply_defect(p_defect uuid, p_body text, p_client_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v defects; v_came boolean;
begin
  if p_client_id is not null and exists (select 1 from defect_messages where client_id = p_client_id) then
    return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
  end if;
  select * into v from defects where id = p_defect;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That defect isn''t there.'; end if;
  if v.voided_at is not null then raise exception 'That defect was marked entered by mistake.'; end if;
  perform floor_entry_check(v.department, v.job_id);
  if nullif(trim(p_body), '') is null then raise exception 'Say what you need from the office first.'; end if;
  v_came := coalesce(v.office_status = 'answered', false);
  insert into defect_messages (client_id, defect_id, kind, body, written_by, written_by_name)
  values (p_client_id, p_defect, 'reply', trim(p_body), auth.uid(), my_name());
  update defects set ask_office = true, office_status = 'open', came_back = came_back or v_came, last_activity_at = now()
   where id = p_defect;
  return jsonb_build_object('ok', true, 'summary', case when v_came then 'Sent back to the office.'
                                                        when v.office_status is null then 'Sent to the office.'
                                                        else 'Added. It''s with the office.' end);
exception when unique_violation then
  return jsonb_build_object('ok', true, 'already', true, 'summary', 'Already sent.');
end $$;
revoke all on function reply_defect(uuid, text, uuid) from public, anon;
grant execute on function reply_defect(uuid, text, uuid) to authenticated;

-- The office answers. p_close true on a defect that's waiting = answered and
-- closed; otherwise it's a note, and a counted defect stays counted-only.
create or replace function answer_defect(p_defect uuid, p_body text, p_close boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v defects; v_kind text;
begin
  if not office_ok() then
    raise exception 'Only the office (a manager login) can answer.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from defects where id = p_defect;
  if v.id is null then raise exception 'That defect isn''t there.'; end if;
  if nullif(trim(p_body), '') is null then raise exception 'Write the answer first.'; end if;
  v_kind := case when coalesce(p_close, true) and v.office_status = 'open' then 'answer' else 'office_note' end;
  insert into defect_messages (defect_id, kind, body, written_by, written_by_name)
  values (p_defect, v_kind, trim(p_body), auth.uid(), my_name());
  if v_kind = 'answer' then
    update defects set office_status = 'answered', came_back = false, answered_by = auth.uid(), answered_by_name = my_name(),
                       answered_at = now(), last_activity_at = now()
     where id = p_defect;
  else
    update defects set last_activity_at = now() where id = p_defect;
  end if;
  return jsonb_build_object('ok', true, 'summary', case when v_kind = 'answer' then 'Answered and closed.'
                                                        when v.office_status = 'open' then 'Reply sent; it stays open.'
                                                        else 'Note sent. It still doesn''t wait on you.' end);
end $$;
revoke all on function answer_defect(uuid, text, boolean) from public, anon;
grant execute on function answer_defect(uuid, text, boolean) to authenticated;

-- v_defects: the same columns as before, then the thread and where it stands
create or replace view v_defects with (security_invoker = true) as
select d.id, d.job_id, j.project_id, j.name as job_name, d.sheet_number, d.department, dp.name as department_name,
       d.defect_type_id, d.defect_type, d.note, d.is_test, d.logged_by, d.logged_by_name, d.logged_at,
       (d.voided_at is not null) as voided, d.voided_at, d.voided_by_name, d.void_reason,
       d.ask_office, d.office_status, d.came_back, d.answered_by_name, d.answered_at,
       coalesce(d.last_activity_at, d.logged_at) as last_activity_at, j.is_active as job_active,
       coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'body', m.body, 'by', m.written_by_name, 'at', m.written_at)
                                  order by m.written_at, m.id)
                   from defect_messages m where m.defect_id = d.id), '[]'::jsonb) as thread
from defects d
join jobs j         on j.id = d.job_id
join departments dp on dp.key = d.department;
revoke all on v_defects from anon;
grant select on v_defects to authenticated;


-- ---------------------------------------------------------------------
-- 4. check_ready_issues() — the PASS / FAIL check
--
-- Builds a throwaway job, tries everything as a supervisor, another
-- supervisor, the Test Supervisor, a manager and someone with no login,
-- then UNDOES EVERYTHING it did. Nothing real is touched.
-- ---------------------------------------------------------------------

create or replace function check_ready_issues()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  sup_dept text;  other uuid;  tst uuid;  mgr uuid;
  v_job   uuid;  v_wo uuid;  v_pre uuid;  v_prog uuid;  v_test uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid;
  v_type  uuid;  v_ttype uuid;
  v       jsonb;
  d_ask   uuid;  d_plain uuid;  d_test uuid;
  n       int;   m int;
  ok      boolean;
  msg     text;
  r       record;
begin
  select p.id, coalesce((select d from unnest(p.departments) d where d = 'sanding'),
                        (select d from unnest(p.departments) d where d in (select key from departments where not log_only) limit 1))
    into sup, sup_dept
    from profiles p
   where p.role = 'supervisor' and p.active and not p.is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by ('sanding' = any(p.departments)) desc limit 1;
  select id into other from profiles p where p.role = 'supervisor' and p.active and not p.is_test and not (sup_dept = any(p.departments)) limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  if sup is null or mgr is null then
    res := res || check_row(1, 'A supervisor and a manager have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end, case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- a throwaway job, in production, whose Monday Metal Status says Not Ready
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, monday_stages)
      values (-999995, 'READYCHECK', 'Ready check - undone automatically', true, 'In Production', local_today() + 9, '{"metal":"Not Ready"}')
      returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 1, 3, 'RC-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 2, 3, 'RC-2') returning id into s2;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 3, 2, 'RC-3') returning id into s3;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 4, 2, 'RC-4') returning id into s4;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (v_wo, 5, 2, 'RC-5') returning id into s5;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'finishing', 3, 3), (s1, 'metal', 3, 3), (s1, 'assembly_qc', 3, 0),      -- both done: 3 ready
      (s2, 'finishing', 3, 3), (s2, 'metal', 3, 1), (s2, 'assembly_qc', 3, 0),      -- metal behind: 1 ready
      (s3, 'finishing', 2, 2),                      (s3, 'assembly_qc', 2, 0),      -- no metal: 2 ready
      (s4, 'finishing', 2, 2), (s4, 'metal', 2, 2), (s4, 'assembly_qc', 2, 0),      -- at Arrow: 0 ready
      (s5, 'sanding', 2, 2),   (s5, 'finishing', 2, 0), (s5, 'assembly_qc', 2, 0);  -- finishing behind
    insert into outside_jobs (job_id, sheet_numbers, description, service, department, sent_on, sent_by_name)
      values (v_job, '{4}', 'ready check bases', 'powdercoat', 'metal', local_today() - 2, 'Ready check');
    -- two more jobs for the metal list: one Pre-Production (it counts), one whose metal is under way (it doesn't)
    insert into jobs (monday_item_id, project_id, name, is_active, phase, monday_stages)
      values (-999994, 'READYCHECK-PRE', 'Ready check', false, 'Pre-Production', '{"metal":" not ready "}') returning id into v_pre;
    insert into jobs (monday_item_id, project_id, name, is_active, phase, monday_stages)
      values (-999993, 'READYCHECK-GO', 'Ready check', true, 'In Production', '{"metal":"In Progress"}') returning id into v_prog;

    -- ---- 1–4: what's ready, read as the supervisor would -----------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select string_agg(format('%s:%s', s.sheet_number, v.ready), ' ' order by s.sheet_number) into msg
        from v_ready_to_work v join sheets s on s.id = v.sheet_id where v.job_id = v_job and v.department = 'assembly_qc';
      execute 'reset role';
      ok := msg = '1:3 2:1 3:2 4:0 5:0';
      msg := 'Expected sheets 1:3 2:1 3:2 4:0 5:0 ready for Assembly / QC; got ' || coalesce(msg, 'nothing') || '.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(1, 'Assembly / QC waits on Finishing and Metal; a sheet with no metal only waits on Finishing', ok, msg);

    select at_arrow and ready = 0 and waiting_on = '{}' into ok from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
    update outside_jobs set returned_on = local_today(), returned_by_name = 'Ready check' where job_id = v_job;
    select ok and ready = 2 and not at_arrow into ok from v_ready_to_work where sheet_id = s4 and department = 'assembly_qc';
    res := res || check_row(2, 'A sheet at Arrow has nothing ready until it''s marked returned', coalesce(ok, false),
      'Sheet 4 wasn''t held while at Arrow, or wasn''t ready once it came back.');

    select (select waiting_on from v_ready_to_work where sheet_id = s2 and department = 'assembly_qc') = '{}'   -- 1 ready: nothing to say
       and (select waiting_on from v_ready_to_work where sheet_id = s5 and department = 'assembly_qc') = '{finishing}'
       and (select ready from v_ready_to_work where sheet_id = s5 and department = 'finishing') = 2
       and (select available from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc') = 3
      into ok;
    res := res || check_row(3, 'It says what a sheet is waiting on; wood stages work as before', coalesce(ok, false),
      'The "waiting on" list or Finishing''s ready count wasn''t what was expected.');

    update sheet_progress set qty_done = 3 where sheet_id = s2 and department = 'metal';
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'assembly_qc';
    select (select ready from v_ready_to_work where sheet_id = s2 and department = 'assembly_qc') = 3
       and (select ready from v_ready_to_work where sheet_id = s1 and department = 'assembly_qc') = 2 into ok;
    res := res || check_row(4, 'Ready follows the counts: Metal catching up frees pieces; Assembly''s own count uses them', coalesce(ok, false),
      'The ready numbers didn''t move with the counts.');

    -- ---- 5–6: Needs metal cut sheets --------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where job_id in (v_job, v_pre)), count(*) filter (where job_id = v_prog) into n, m from v_metal_cut_sheets;
      execute 'reset role';
      ok := n = 2 and m = 0;
      msg := format('Expected the In Production and Pre-Production jobs saying Not Ready (2) and not the one In Progress; got %s and %s.', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Needs metal cut sheets lists jobs whose Metal Status says Not Ready', ok, msg);

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_metal_cut_sheets;
      execute 'reset role';
      ok := n = 0; msg := n || ' rows visible to a supervisor.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A supervisor can''t see that list (office only)', ok, msg);

    -- ---- 7–11: defects that ask the office --------------------------------
    select id into v_type from defect_types where department = sup_dept and active order by sort_order limit 1;
    begin
      execute 'set local role authenticated';
      v := report_defect(v_job, sup_dept, v_type, null, 'ready check: remake or touch up?', true, gen_random_uuid());
      d_ask := (v->>'id')::uuid;
      v := report_defect(v_job, sup_dept, v_type, null, 'ready check: counted only', false, gen_random_uuid());
      d_plain := (v->>'id')::uuid;
      execute 'reset role';
      ok := (select office_status = 'open' and ask_office from defects where id = d_ask)
        and (select office_status is null and not ask_office from defects where id = d_plain);
      msg := 'The asked defect isn''t waiting on the office, or the plain one is.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A defect with Ask the office waits on the office; one without is only counted', coalesce(ok, false), msg);

    begin
      execute 'set local role authenticated';
      v := answer_defect(d_ask, 'I shouldn''t be able to answer this');
      execute 'reset role';
      ok := false; msg := 'A supervisor answered a defect. Only the office should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Only the office can answer', ok, msg);

    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := answer_defect(d_ask, 'Ready check: touch it up', true);
      execute 'reset role';
      ok := (select office_status = 'answered' from defects where id = d_ask);
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := reply_defect(d_ask, 'Ready check: touched up, still shows', gen_random_uuid());
      select count(*) into n from v_defects where id = d_ask and jsonb_array_length(thread) = 2;
      execute 'reset role';
      ok := ok and n = 1 and (select office_status = 'open' and came_back from defects where id = d_ask);
      msg := 'The answer didn''t close it, or the reply didn''t bring it back tagged Came back with the thread.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'An answer closes it; a reply brings it back as "Came back", thread and all', coalesce(ok, false), msg);

    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := answer_defect(d_plain, 'Ready check: noted', true);
      execute 'reset role';
      ok := (select office_status is null from defects where id = d_plain)
        and (select count(*) = 1 from defect_messages where defect_id = d_plain and kind = 'office_note');
      msg := 'A note on a counted defect made it wait, or wasn''t kept.';
      if ok then     -- then the floor asks about it after all: now it waits
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        v := reply_defect(d_plain, 'Ready check: on second thoughts, remake?', gen_random_uuid());
        execute 'reset role';
        ok := (select office_status = 'open' and ask_office and not came_back from defects where id = d_plain);
        msg := 'Asking the office about a counted defect later didn''t send it to the office.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'A note on a counted defect doesn''t make it wait; asking about it later does', coalesce(ok, false), msg);

    if other is null then
      res := res || check_row(11, 'Another department can''t reply on this defect', true, null);
    else
      perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := reply_defect(d_plain, 'not my department');
        execute 'reset role';
        ok := false; msg := 'A supervisor from another department replied on it.';
      exception when insufficient_privilege then execute 'reset role'; ok := true;
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
      res := res || check_row(11, 'Another department can''t reply on this defect', ok, msg);
    end if;

    -- ---- 12–14: lanes, direct writes, no login ----------------------------
    if tst is null then
      res := res || check_row(12, 'Test defects and their threads stay out of real supervisors'' sight', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('READYCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      select id into v_ttype from defect_types where department = 'assembly_qc' and active order by sort_order limit 1;
      perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := report_defect(v_test, 'assembly_qc', v_ttype, 1, 'ready check, test lane', true, gen_random_uuid());
        d_test := (v->>'id')::uuid;
        v := reply_defect(d_test, 'ready check, test lane reply', gen_random_uuid());
        execute 'reset role';
        perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select (select count(*) from v_defects where id = d_test) + (select count(*) from defect_messages where defect_id = d_test) into n;
        execute 'reset role';
        ok := n = 0 and d_test is not null; msg := 'A real supervisor can see a test defect or its thread.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(12, 'Test defects and their threads stay out of real supervisors'' sight', ok, msg);
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      insert into defect_messages (defect_id, kind, body) values (d_plain, 'answer', 'sneaky');
      execute 'reset role';
      ok := false; msg := 'A supervisor wrote to defect_messages directly, around the checks.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Nobody can write a defect message directly', ok, msg);

    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select (select count(*) from defect_messages) + (select count(*) from v_ready_to_work) into n;
      execute 'reset role';
      ok := n = 0; msg := n || ' rows are visible without logging in. Do not go further.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Someone with no login sees none of it', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_ready_issues_undo__';
  exception when others then
    if sqlerrm <> '__check_ready_issues_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_ready_issues() from public, anon, authenticated;

select * from check_ready_issues();
