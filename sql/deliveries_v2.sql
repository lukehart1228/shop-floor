-- =====================================================================
-- Shop Floor — deliveries v2 (24 Sep 2026)
--
-- HOW TO USE: run deliveries.sql first (Walkthrough 11). Then paste this
-- whole file into a NEW, empty query in the Supabase SQL Editor and click
-- Run. Safe to run more than once. The last thing it does is run
-- check_deliveries_v2(), so the Results show 6 rows that should all say
-- PASS. It also refreshes check_deliveries() (see 3b).
--
-- What it changes:
--   * A scheduled delivery can't be cancelled from the phone. On the
--     phone, "This load-out was started by mistake" cancelled the whole
--     delivery, ticket and all. Only whoever schedules deliveries (Julia,
--     or a manager) cancels one, on the Deliveries page.
--   * A delivered delivery can't be cancelled at all.
--   * A cancelled delivery can be put back (restore_delivery), from a
--     new "Cancelled" list on the Deliveries page. Each cancel and
--     put-back is kept in the delivery's void_history.
-- Nothing is deleted. void_loadout() keeps its name and inputs; ordinary
-- load-outs (not scheduled) work exactly as before.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('deliveries_v2.sql'); end if;
end $$;

do $$ begin
  if to_regclass('public.v_deliveries') is null then
    raise exception 'Run deliveries.sql first (Walkthrough 11, step 1), then run this file again.';
  end if;
end $$;

-- each cancel and put-back, oldest first: {voided_at, voided_by_name, void_reason, restored_at, restored_by_name}
alter table loadouts add column if not exists void_history jsonb not null default '[]'::jsonb;


-- ---------------------------------------------------------------------
-- 1. "Started by mistake" / "Cancel this delivery"
--    Same as before, plus: a scheduled delivery is cancelled only by a
--    scheduler (or a manager), and a delivered one not at all.
-- ---------------------------------------------------------------------
create or replace function void_loadout(p_loadout uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v loadouts;
begin
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That load-out isn''t there.'; end if;
  if v.voided_at is not null then
    return 'Marked as entered by mistake. It''s kept in history, with its photos.';      -- a resend: nothing changes
  end if;
  if v.completed_at is not null then
    raise exception 'That delivery was already delivered (%), so it can''t be cancelled.', local_when(v.completed_at);
  end if;
  if v.scheduled_for is not null and not can_schedule_deliveries() then
    raise exception 'This delivery was scheduled by %, so it''s cancelled on the Deliveries page, not here. A wrong photo can be marked entered by mistake on its own.',
      coalesce(v.scheduled_by_name, 'the delivery manager') using errcode = 'insufficient_privilege';
  end if;
  if not (v.started_by = auth.uid() or office_ok() or (v.scheduled_for is not null and can_schedule_deliveries())) then
    raise exception 'Only the person who started it, or a manager, can mark it entered by mistake.' using errcode = 'insufficient_privilege';
  end if;
  update loadouts set voided_at = now(), voided_by_name = my_name(),
                      void_reason = coalesce(nullif(trim(p_reason), ''), 'Entered by mistake')
   where id = v.id;
  return 'Marked as entered by mistake. It''s kept in history, with its photos.';
end $$;
revoke all on function void_loadout(uuid, text) from public, anon;
grant execute on function void_loadout(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- 2. Put a cancelled delivery back
-- ---------------------------------------------------------------------
create or replace function restore_delivery(p_loadout uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v loadouts; v_pid text;
begin
  if not can_schedule_deliveries() then
    raise exception 'Only the delivery manager or a manager can put a delivery back.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from loadouts where id = p_loadout or client_id = p_loadout;
  if v.id is null or not sees_lane(v.is_test) then raise exception 'That delivery isn''t there.'; end if;
  if v.is_test and not (is_manager() or am_test()) then
    raise exception 'That''s a test delivery. Only a manager or the Test Supervisor puts it back.' using errcode = 'insufficient_privilege';
  end if;
  if not v.is_test and am_test() then
    raise exception 'A test login can only put back test deliveries.' using errcode = 'insufficient_privilege';
  end if;
  if v.scheduled_for is null or v.kind <> 'delivery' then
    raise exception 'Only a scheduled delivery can be put back here.';
  end if;
  select project_id into v_pid from jobs where id = v.job_id;
  if v.voided_at is null then                                            -- a resend, or already back
    return jsonb_build_object('ok', true, 'summary', format('The %s delivery of %s is on the list.', local_when(v.scheduled_for), v_pid));
  end if;
  update loadouts
     set void_history = void_history || jsonb_build_array(jsonb_build_object(
           'voided_at', v.voided_at, 'voided_by_name', v.voided_by_name, 'void_reason', v.void_reason,
           'restored_at', now(), 'restored_by_name', my_name())),
         voided_at = null, voided_by_name = null, void_reason = null
   where id = v.id;
  return jsonb_build_object('ok', true, 'summary',
    format('The %s delivery of %s is back, on Delivery''s phone too.%s', local_when(v.scheduled_for), v_pid,
           case when v.scheduled_for < now() then ' Its date has passed: change it if the delivery is still to come.' else '' end));
end $$;
revoke all on function restore_delivery(uuid) from public, anon;
grant execute on function restore_delivery(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 3. The Deliveries page's Cancelled list: the last 60 days
-- ---------------------------------------------------------------------
create or replace view v_cancelled_deliveries with (security_invoker = true) as
select l.id, l.client_id, l.job_id, j.project_id, j.name as job_name, l.is_test,
       l.scheduled_for, l.schedule_note, l.scheduled_by_name, l.voided_at, l.voided_by_name, l.void_reason,
       exists (select 1 from delivery_docs d where d.loadout_id = l.id and d.kind = 'ticket' and d.retired_at is null) as has_ticket,
       (select count(*)::int from delivery_docs d where d.loadout_id = l.id and d.kind = 'site_file' and d.retired_at is null) as site_files
from loadouts l
join jobs j on j.id = l.job_id
where l.voided_at is not null and l.voided_at > now() - interval '60 days'
  and l.kind = 'delivery' and l.scheduled_for is not null and l.completed_at is null
  and sees_deliveries();
revoke all on v_cancelled_deliveries from anon;
grant select on v_cancelled_deliveries to authenticated;


-- ---------------------------------------------------------------------
-- 3b. deliveries.sql's own check, unchanged except that it now switches
--     the Test Supervisor's scheduling off for its run (undone at the end),
--     so it passes after the Test Supervisor was made a scheduler for practice.
-- ---------------------------------------------------------------------
create or replace function check_deliveries()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  tst      uuid;  sup uuid;  mgr uuid;
  as_tst   text;  as_sup text;  as_mgr text;
  v_real   uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v        jsonb;
  d1       uuid := gen_random_uuid();     -- the page's own ids
  d2       uuid := gen_random_uuid();
  d3       uuid := gen_random_uuid();
  d_real   uuid := gen_random_uuid();
  f        uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  ph       uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  sig      uuid := gen_random_uuid();
  sig2     uuid := gen_random_uuid();
  l1       uuid;  l_id uuid;
  n        int;
  ok       boolean;
  msg      text;
  r        record;
  b        storage.buckets;
  v_batch  text;
  v_day    text;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test and not ('delivery' = any(departments))
     and not schedules_deliveries order by ('sanding' = any(departments)) desc limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if tst is null or sup is null or mgr is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery), a supervisor from another department and a manager have logins', false,
      concat_ws(' ', case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when sup is null then 'No real supervisor outside Delivery.' end,
                     case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin
    -- the Test Supervisor plays the driver here, so not a scheduler, even if it was made one for practice (undone at the end)
    update profiles set schedules_deliveries = false where id = tst;
    -- ---- 1. the parts exist ------------------------------------------------
    select * into b from storage.buckets where id = 'deliveries';
    ok := b.id is not null and not coalesce(b.public, true) and b.file_size_limit = 10485760
          and b.allowed_mime_types @> array['application/pdf', 'image/jpeg', 'image/png'] and cardinality(b.allowed_mime_types) = 3
          and exists (select 1 from pg_tables where tablename = 'delivery_docs' and rowsecurity)
          and to_regprocedure('public.schedule_delivery(uuid,timestamp with time zone,text,uuid,uuid)') is not null
          and to_regprocedure('public.complete_delivery(uuid,uuid,text,text,text,text,timestamp with time zone,double precision,double precision,double precision)') is not null
          and to_regclass('public.v_deliveries') is not null and to_regclass('public.v_filing') is not null
          and exists (select 1 from information_schema.columns where table_name = 'v_loadouts' and column_name = 'site_here');
    res := res || check_row(1, 'Deliveries are set up (the private deliveries bucket, the files table, the functions and views)', ok,
      case when b.id is null then 'There''s no deliveries bucket. Run deliveries.sql again.'
           when b.public then 'The deliveries bucket is PUBLIC — anyone could read the tickets. Run deliveries.sql again, which makes it private.'
           else 'Something is missing. Run deliveries.sql again from the top.' end);

    -- a throwaway job: sheets 1 and 2 are the same item (DC-1, 1 table and 2 tables), sheet 3 has no item code; and a test copy
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999993, 'DELCHECK', 'Delivery check - undone automatically', true, 'In Production', local_today() + 3)
      returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height)
      values (v_wo, 1, 1, 'DC-1', 'Round', '36"', '36"', '42"'), (v_wo, 2, 2, 'DC-1', 'Round', '36"', '36"', '42"'),
             (v_wo, 3, 1, null, 'Rectangle', '30"', '60"', '30"');
    insert into sheet_progress (sheet_id, department, qty_required) select s.id, 'assembly_qc', s.qty from sheets s where s.work_order_id = v_wo;
    v := make_test_job('DELCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;

    -- ---- 2. who can schedule --------------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_real, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'A supervisor scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'Delivery (without the scheduling permission) scheduled a delivery.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      -- the permission Julia gets
      update profiles set schedules_deliveries = true where id = sup;
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_real, now() + interval '2 days', 'Back door, ask for Pat', null, d_real);
      begin v := schedule_delivery(v_test, now() + interval '2 days', null, null, gen_random_uuid()); ok := false; msg := 'The scheduler (a real login) scheduled a test job.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = sup;
      ok := ok and exists (select 1 from loadouts where client_id = d_real and scheduled_for is not null and kind = 'delivery' and schedule_note = 'Back door, ask for Pat');
      msg := coalesce(msg, 'A login with the scheduling permission couldn''t schedule a real job.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Only the delivery manager (and managers) schedule; nobody else, and never across lanes', ok, msg);

    -- ---- 3. a manager schedules the test copy; Delivery sees it -------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_test, now() + interval '1 day', 'Loading dock on the north side', null, d1);
      v := schedule_delivery(v_test, now() + interval '1 day', 'resent', null, d1);            -- a resend: once
      v := schedule_delivery(v_test, now() + interval '5 days', null, null, d2);               -- a second trip
      execute 'reset role';
      select id into l1 from loadouts where client_id = d1;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      select count(*) into n from v_loadouts where client_id in (d1, d2) and is_open and scheduled_for is not null and site_steps;
      select n + count(*) into n from v_deliveries where client_id = d1 and schedule_note = 'Loading dock on the north side' and not is_done;
      execute 'reset role';
      ok := n = 3 and (select count(*) from loadouts where client_id = d1) = 1;
      msg := format('Delivery should see both scheduled trips and the note; saw %s of 3.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A scheduled delivery, with its date, time and note, shows on Delivery''s phone', ok, msg);

    -- ---- 4. the ticket ---------------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := add_delivery_doc(f[1], d1, 'ticket', 'ticket.pdf'); ok := false; msg := 'A ticket was recorded before its file arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[1] || '.pdf', '{"size": 40000, "mimetype": "application/pdf"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[2] || '.pdf', '{"size": 41000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[1], d1, 'ticket', 'Ticket 4471.pdf');
      v := add_delivery_doc(f[2], d1, 'ticket', 'Ticket 4471 revised.pdf');
      execute 'reset role';
      ok := ok and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'ticket') = 2
               and exists (select 1 from delivery_docs where client_id = f[1] and retired_at is not null)
               and (select ticket->>'name' from v_deliveries where id = l1) = 'Ticket 4471 revised.pdf';
      msg := coalesce(msg, 'The newer ticket didn''t replace the old one, or the old one wasn''t kept.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The ticket is recorded once its file arrives; a new ticket replaces the old (kept)', ok, msg);

    -- ---- 5. site files ---------------------------------------------------------
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values
        ('deliveries', v_tpid || '/' || d1 || '/' || f[3] || '.jpg', '{"size": 300000, "mimetype": "image/jpeg"}'),
        ('deliveries', v_tpid || '/' || d1 || '/' || f[4] || '.pdf', '{"size": 90000, "mimetype": "application/pdf"}');
      v := add_delivery_doc(f[3], d1, 'site_file', 'Where the tables go.jpg');
      v := add_delivery_doc(f[4], d1, 'site_file', 'Site map.pdf');
      v := retire_delivery_doc((select id from delivery_docs where client_id = f[4]));
      execute 'reset role';
      ok := (select jsonb_array_length(files) from v_deliveries where id = l1) = 1
            and exists (select 1 from delivery_docs where client_id = f[4] and retired_at is not null);
      msg := 'The site files didn''t show as added, or a file taken off vanished instead of being kept.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Site files are added, and taking one off keeps it in history', ok, msg);

    -- the photo files, as the phone uploads them first
    insert into storage.objects (bucket_id, name, metadata)
      select 'photos', v_tpid || '/' || x || '.jpg', '{"size": 2, "mimetype": "image/jpeg"}' from unnest(ph) x;

    -- ---- 6. the truck at the dock ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[1], d1, 'dock', null, null, 1, 39.77, -86.16, 12, now());
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[2], d1, 'dock', null, null, 0); ok := false; msg := 'Truck 0 was accepted.';
      exception when others then null; end;
      v := start_loadout(v_test, d3);
      v := set_loadout_details(d3, 'shipping', null, null);
      begin v := add_delivery_photo(ph[2], d3, 'dock', null, null, 1); ok := false; msg := 'A truck photo was accepted on a shipment.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from v_loadouts where client_id = d1 and trucks_here = array[1] and other_items = 0)
               and exists (select 1 from photos where client_id = ph[1] and stage = 'dock' and truck = 1 and note = 'Truck 1');
      msg := coalesce(msg, 'The truck photo wasn''t recorded as truck 1 (or it counted as an "other item").');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'At the dock, a delivery records one photo per truck (never on a shipment)', ok, msg);

    -- ---- 7. the tables at the site, with the phone's time and place -------------------
    begin
      execute 'set local role authenticated';
      v := add_delivery_photo(ph[2], d1, 'site', 2, 1, null, 39.7684, -86.1581, 8, now() - interval '2 minutes');
      ok := true; msg := null;
      begin v := add_delivery_photo(ph[3], d1, 'site', 2, 3); ok := false; msg := 'Table 3 was accepted on a sheet with 2 tables.';
      exception when others then null; end;
      begin v := add_delivery_photo(ph[3], d1, 'site', null, 1); ok := false; msg := 'A site photo with no sheet was accepted.';
      exception when others then null; end;
      execute 'reset role';
      ok := ok and exists (select 1 from photos where client_id = ph[2] and stage = 'site' and sheet_number = 2 and piece = 1
                                                   and lat = 39.7684 and lng = -86.1581 and gps_accuracy = 8 and shot_at is not null)
               and exists (select 1 from v_loadouts where client_id = d1 and site_here = array['2:1'] and not ('2:1' = any(pieces_here)))
               and not exists (select 1 from photos where client_id = ph[3]);
      msg := coalesce(msg, 'The site photo wasn''t saved with its table, time and location, or it counted as a dock photo.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'At the site, each table''s photo keeps its table, the phone''s time and GPS', ok, msg);

    -- ---- 8. signed ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      ok := true; msg := null;
      begin v := complete_delivery(sig, d1, '   '); ok := false; msg := 'A signature with no name was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig, d1, 'Pat Jones'); ok := false; msg := 'A signature was accepted before its image arrived.';
      exception when others then if sqlerrm not like '%hasn''t arrived%' then ok := false; msg := 'Unexpected error: ' || sqlerrm; end if; end;
      insert into storage.objects (bucket_id, name, metadata)
        values ('deliveries', v_tpid || '/' || d1 || '/' || sig || '.png', '{"size": 9000, "mimetype": "image/png"}');
      v := complete_delivery(sig, d1, 'Pat Jones', 'Table by the window has a scuff', null, null, now() - interval '1 minute', 39.7684, -86.1581, 6);
      v := complete_delivery(sig, d1, 'Pat Jones');                                  -- a resend: once
      execute 'reset role';
      select * into r from loadouts where client_id = d1;
      ok := ok and r.completed_at is not null and r.finished_at is not null and r.signed_name = 'Pat Jones' and r.signed_at is not null
               and r.customer_note = 'Table by the window has a scuff' and r.no_sign_reason is null and r.complete_lat = 39.7684
               and (select count(*) from delivery_docs where loadout_id = l1 and kind = 'signature') = 1
               and (select signature_path from v_deliveries where id = l1) = v_tpid || '/' || d1 || '/' || sig || '.png';
      msg := coalesce(msg, 'The signed delivery wasn''t recorded with its name, note, signature and place (or was recorded twice).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Signed: the name, the customer''s note and the signature are kept; a resend counts once', ok, msg);

    -- ---- 9. once delivered, it stays as signed -------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(gen_random_uuid(), d1, null, null, 'Nobody on site'); ok := false; msg := 'A delivered delivery was marked delivered again, differently.';
      exception when others then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/' || d1 || '/' || f[5] || '.pdf', '{"size": 1, "mimetype": "application/pdf"}');
      begin v := add_delivery_doc(f[5], d1, 'ticket', 'late.pdf'); ok := false; msg := 'The ticket was changed after the customer signed.';
      exception when others then null; end;
      begin v := schedule_delivery(null, now(), null, d1); ok := false; msg := 'A delivered delivery was moved to another date.';
      exception when others then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'Once delivered, the ticket, the date and the signature can''t change', ok, msg);

    -- ---- 10. not signed --------------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := complete_delivery(sig2, d2, null, null, 'Too busy'); ok := false; msg := 'A reason not on the list was accepted.';
      exception when others then null; end;
      begin v := complete_delivery(sig2, d2, null, null, 'Other', '  '); ok := false; msg := '"Other" was accepted with no note.';
      exception when others then null; end;
      v := complete_delivery(sig2, d2, 'nobody', null, 'Nobody on site', 'Left inside the gym, door code from Pat');
      execute 'reset role';
      select * into r from loadouts where client_id = d2;
      ok := ok and r.completed_at is not null and r.no_sign_reason = 'Nobody on site' and r.signed_name is null
               and r.no_sign_note = 'Left inside the gym, door code from Pat'
               and not exists (select 1 from delivery_docs where loadout_id = r.id and kind = 'signature');
      msg := coalesce(msg, 'The unsigned delivery wasn''t recorded with its reason and note.');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Not signed: a reason from the list (and a note for Other) is needed, and kept', ok, msg);

    -- ---- 11. Julia's "New" --------------------------------------------------------
    ok := true; msg := null;
    begin
      execute 'set local role authenticated';
      begin v := mark_ticket_downloaded(d1); ok := false; msg := 'Delivery (not the scheduler) marked a ticket downloaded.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      select downloaded_at into r from loadouts where client_id = d1;
      update loadouts set downloaded_at = downloaded_at - interval '1 hour' where client_id = d1;
      execute 'set local role authenticated';
      v := mark_ticket_downloaded(d1);
      execute 'reset role';
      ok := ok and (select downloaded_at < now() - interval '59 minutes' and downloaded_by_name is not null from loadouts where client_id = d1);
      msg := coalesce(msg, 'Downloading didn''t record the first download (or a later one overwrote it).');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(11, 'Downloading a signed ticket is recorded once, by the scheduler or a manager', ok, msg);

    -- ---- 12. who sees delivery files ------------------------------------------------
    begin
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      select (select count(*) from v_deliveries where is_test) + (select count(*) from v_loadouts where job_id = v_test)
           + (select count(*) from delivery_docs) + (select count(*) from storage.objects where bucket_id = 'deliveries') into n;
      execute 'reset role';
      ok := n = 0;
      msg := format('A supervisor outside Delivery can see %s test deliveries or delivery files.', n);
      if ok then
        perform set_config('request.jwt.claims', as_tst, true);
        execute 'set local role authenticated';
        select count(*) into n from delivery_docs where loadout_id = l1;
        select n + count(*) into n from storage.objects where bucket_id = 'deliveries' and name like v_tpid || '/%';
        select n * 100 + count(*) into n from v_deliveries where client_id = d_real;
        execute 'reset role';
        ok := n >= 500 and n % 100 = 0;
        msg := 'Delivery can''t read the test delivery''s files, or can see a real one from the test lane.';
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Delivery files are for Delivery, the scheduler and managers, lane by lane', ok, msg);

    -- ---- 13. no writing around the functions -------------------------------------------
    ok := true; msg := null;
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      begin insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path) values (gen_random_uuid(), l1, v_test, 'ticket', 'x', 'x');
        ok := false; msg := 'A login wrote to delivery_docs directly.';
      exception when insufficient_privilege then null; end;
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', v_tpid || '/anything.exe', '{}');
        ok := false; msg := 'A file with the wrong name went into the deliveries bucket.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      begin insert into storage.objects (bucket_id, name, metadata) values ('deliveries', 'DELCHECK/' || d_real || '/' || gen_random_uuid() || '.png', '{}');
        ok := false; msg := 'A supervisor outside Delivery uploaded a delivery file.';
      exception when insufficient_privilege then null; end;
      begin v := complete_delivery(gen_random_uuid(), d_real, null, null, 'Other', 'x'); ok := false; msg := 'A supervisor outside Delivery marked a delivery done.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Nobody writes delivery files or marks a delivery done around the checks', ok, msg);

    -- ---- 14. no login ----------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      ok := true; msg := null;
      begin select count(*) into n from delivery_docs; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from v_deliveries; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin select count(*) into n from storage.objects where bucket_id = 'deliveries'; if n > 0 then ok := false; end if; exception when insufficient_privilege then null; end;
      begin v := schedule_delivery(v_real, now(), null); ok := false; exception when others then null; end;
      execute 'reset role';
      msg := 'Deliveries or their files are visible, or can be scheduled, without logging in. Do not go further.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Someone with no login sees no deliveries or delivery files', ok, msg);

    -- ---- 15. filed the way the shop files ------------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      v := log_defect(v_test, 'delivery', (select id from defect_types where department = 'delivery' and active order by sort_order limit 1), 2, 'check', gen_random_uuid());
      v := add_photo(ph[4], 'defect', (v->>'id')::uuid);
      execute 'reset role';
      v_day := 'Delivery ' || to_char((select scheduled_for from loadouts where client_id = d1) at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD');
      select count(*) into n from v_filing where job_id = v_test and (
             (source = 'photo' and folder = 'DC-1' and file_name = 'DC-1-2 Delivery Picture.jpg' and id = (select id from photos where client_id = ph[2]))
          or (source = 'photo' and folder = 'Truck' and file_name = 'Truck-1.jpg')
          or (source = 'photo' and folder = 'DC-1' and file_name = 'DC-1 Defect 1.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Delivery ticket.pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Delivery ticket (replaced).pdf')
          or (source = 'doc' and folder = v_day and file_name = 'Where the tables go.jpg')
          or (source = 'doc' and folder = v_day and file_name = 'Signature.png')
          or (source = 'signed' and folder = v_day and file_name = 'Signed ticket.pdf'));
      ok := n = 8;
      msg := format('Expected 8 files named the filing way (DC-1/DC-1-2 Delivery Picture.jpg, Truck/Truck-1.jpg, the ticket, the signature …); found %s.', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'Photos and files are named by job, item and table: DC-1/DC-1-2 Delivery Picture.jpg', ok, msg);

    -- ---- 16. the archive takes delivery files too ---------------------------------------
    perform set_config('request.jwt.claims', '', true);
    update jobs set is_active = false, phase = '100% Complete' where id = v_test;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_test;
    update photos set taken_at = now() - interval '61 days' where job_id = v_test;
    update delivery_docs set added_at = now() - interval '61 days' where job_id = v_test;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := prepare_photo_archive();
      v_batch := v->>'batch';
      v := file_archive_batch(v_batch);
      execute 'reset role';
      ok := (select count(*) from delivery_docs where job_id = v_test and archive_batch = v_batch) = 5
            and exists (select 1 from delivery_docs where client_id = f[2] and archive_name = v_tpid || '/' || v_day || '/Delivery ticket.pdf')
            and exists (select 1 from photos where client_id = ph[2] and archive_name = v_tpid || '/DC-1/DC-1-2 Delivery Picture.jpg')
            and exists (select 1 from jsonb_array_elements(v->'files') x where x->>'source' = 'signed' and x->>'name' = v_tpid || '/' || v_day || '/Signed ticket.pdf')
            and not delivery_doc_released(v_tpid || '/' || d1 || '/' || f[2] || '.pdf');
      msg := 'The archive didn''t take the delivery files, named them wrongly, or would let them be removed before the next batch is saved.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(16, 'The monthly archive takes delivery files too, filed the same way', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_deliveries_undo__';
  exception when others then
    if sqlerrm <> '__check_deliveries_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_deliveries() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. The check: 6 rows, all PASS. It builds a throwaway test job, tries
--    everything as a driver, a scheduler and a manager, then undoes it all.
-- ---------------------------------------------------------------------
create or replace function check_deliveries_v2()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  tst     uuid;  mgr uuid;
  as_tst  text;  as_mgr text;
  v_job   uuid;
  v       jsonb;
  d1      uuid := gen_random_uuid();
  d2      uuid := gen_random_uuid();
  lo1     uuid := gen_random_uuid();
  ok      boolean;
  msg     text;
  n       int;
begin
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active order by full_name limit 1;
  if tst is null or mgr is null then
    res := res || check_row(1, 'The Test Supervisor (with Delivery) and a manager have logins', false,
      case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' else 'No manager.' end);
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;

  begin
    -- ---- 1. the parts exist ----------------------------------------------------
    ok := to_regprocedure('public.restore_delivery(uuid)') is not null
          and to_regclass('public.v_cancelled_deliveries') is not null
          and exists (select 1 from information_schema.columns where table_name = 'loadouts' and column_name = 'void_history');
    res := res || check_row(1, 'Deliveries v2 is set up (put-back, the Cancelled list, the history column)', ok,
      'Something is missing. Run deliveries_v2.sql again from the top.');

    -- a throwaway test job; the Test Supervisor plays the driver (not a scheduler) until row 3
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test)
      values (null, 'TEST-DELV2CHECK', 'Delivery v2 check - undone automatically', true, 'In Production', local_today() + 3, true)
      returning id into v_job;
    update profiles set schedules_deliveries = false where id = tst;

    -- ---- 2. only someone who schedules deliveries cancels one ---------------------
    --      The Test Supervisor schedules it (so it's "started by" them), then stops
    --      being a scheduler: the phone's "started by mistake" must be refused.
    begin
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := schedule_delivery(v_job, now() + interval '2 days', 'North dock', null, d1);
      execute 'reset role';
      update profiles set schedules_deliveries = false where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      ok := false;
      begin perform void_loadout(d1, null); exception when insufficient_privilege then ok := true; end;
      select count(*) into n from v_deliveries where client_id = d1;
      execute 'reset role';
      ok := ok and n = 1 and (select voided_at from loadouts where client_id = d1) is null;
      msg := '"Started by mistake" on the phone cancelled a scheduled delivery for someone who doesn''t schedule deliveries, or it left Delivery''s list.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A scheduled delivery is cancelled only by someone who schedules deliveries; it stays on the list', ok, msg);

    -- ---- 3. the scheduler cancels it; it shows under Cancelled -----------------------
    begin
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      perform void_loadout(d1, 'Delivery cancelled');
      perform void_loadout(d1, 'Delivery cancelled');                                   -- a resend: once
      select count(*) into n from v_deliveries where client_id = d1;
      select n * 10 + count(*) into n from v_cancelled_deliveries where client_id = d1 and void_reason = 'Delivery cancelled' and has_ticket = false;
      execute 'reset role';
      ok := n = 1;
      msg := format('After cancelling it should be off the list and under Cancelled (expected 0 and 1, got %s and %s).', n / 10, n % 10);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'The scheduler cancels it: off the list and the phone, shown under Cancelled', ok, msg);

    -- ---- 4. putting it back ---------------------------------------------------------
    begin
      update profiles set schedules_deliveries = false where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      ok := false;
      begin perform restore_delivery(d1); exception when insufficient_privilege then ok := true; end;
      execute 'reset role';
      update profiles set schedules_deliveries = true where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := restore_delivery(d1);
      v := restore_delivery(d1);                                                        -- a resend: no change
      select count(*) into n from v_deliveries where client_id = d1;
      select n * 10 + count(*) into n from v_cancelled_deliveries where client_id = d1;
      execute 'reset role';
      ok := ok and n = 10 and (v->>'ok')::boolean
            and (select jsonb_array_length(void_history) = 1 and void_history->0->>'void_reason' = 'Delivery cancelled'
                        and void_history->0->>'restored_by_name' is not null and voided_at is null
                   from loadouts where client_id = d1);
      msg := 'Someone who doesn''t schedule could put it back, or it didn''t come back once with its history kept.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'Put it back: back on the list, with the cancel kept in its history; only a scheduler can', ok, msg);

    -- ---- 5. a delivered delivery can't be cancelled ------------------------------------
    begin
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := complete_delivery(gen_random_uuid(), d1, null, null, 'Nobody on site', null, now(), null, null, null);
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      ok := false;
      begin perform void_loadout(d1, 'Delivery cancelled'); exception when others then ok := sqlerrm like '%already delivered%'; end;
      execute 'reset role';
      ok := ok and (select voided_at is null and completed_at is not null from loadouts where client_id = d1);
      msg := 'A delivered delivery could be cancelled, even by a manager.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'Once delivered, a delivery can''t be cancelled (not even by a manager)', ok, msg);

    -- ---- 6. an ordinary load-out started by mistake: unchanged ---------------------------
    begin
      update profiles set schedules_deliveries = false where id = tst;
      perform set_config('request.jwt.claims', as_tst, true);
      execute 'set local role authenticated';
      v := start_loadout(v_job, lo1);
      perform void_loadout(lo1, null);
      execute 'reset role';
      ok := (select void_reason = 'Entered by mistake' and voided_at is not null from loadouts where client_id = lo1);
      msg := 'The driver could no longer mark their own unscheduled load-out as started by mistake.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A load-out the driver started (not scheduled) can still be marked started by mistake', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_deliveries_v2_undo__';
  exception when others then
    if sqlerrm <> '__check_deliveries_v2_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_deliveries_v2() from public, anon, authenticated;

select * from check_deliveries_v2();
