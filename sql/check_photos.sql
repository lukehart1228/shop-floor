-- =====================================================================
-- Shop Floor — the photos check (Walkthrough 7)
--
-- HOW TO USE: run photos.sql first. Then paste this whole file into a
-- NEW, empty query in the Supabase SQL Editor and click Run. A table
-- appears. Every row should say PASS.
--
-- It builds a throwaway job and a test copy, pretends to upload photo
-- files (no real image is stored), tries everything as your supervisor,
-- the Test Supervisor, a manager and someone with no login, runs a
-- pretend archive — and then UNDOES EVERYTHING it did. Nothing real is
-- touched, and no real photo file is removed.
--
-- If more than one row says FAIL, look at the FIRST one.
-- Run it again any time with just:   select * from check_photos();
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('check_photos.sql'); end if;
end $$;

create or replace function check_photos()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res      jsonb := '[]';
  sup      uuid;  sup_name text;  sup_dept text;  other_dept text;  sup_delivers boolean;
  tst      uuid;
  mgr      uuid;
  v_real   uuid;  v_wo uuid;  v_test uuid;  v_tpid text;
  v_type   uuid;  v_otype uuid;
  v_def    uuid;  v_odef uuid;
  v_lo     uuid;
  p1       uuid := gen_random_uuid();
  p2       uuid := gen_random_uuid();
  p3       uuid := gen_random_uuid();
  p4       uuid := gen_random_uuid();
  p5       uuid := gen_random_uuid();
  v        jsonb;
  n        int;
  ok       boolean;
  msg      text;
  b1       text;  b2 text;
  v_b      storage.buckets;
  -- act as a login, the way the tablet does
  as_sup   text;  as_tst text;  as_mgr text;
begin
  select p.id, p.full_name, coalesce((select d from unnest(p.departments) d where d = 'sanding'), p.departments[1]), 'delivery' = any(p.departments)
    into sup, sup_name, sup_dept, sup_delivers
    from profiles p
   where p.role = 'supervisor' and p.active and not p.is_test and array_length(p.departments, 1) > 0
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by ('sanding' = any(p.departments)) desc limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active and 'delivery' = any(departments) limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;
  if sup is null or tst is null or mgr is null then
    res := res || check_row(1, 'A supervisor, the Test Supervisor (with Delivery) and a manager all have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor with a counted department.' end,
                     case when tst is null then 'No Test Supervisor with Delivery — see row 18 of check_floor().' end,
                     case when mgr is null then 'No manager.' end));
    return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
    return;
  end if;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;
  as_tst := json_build_object('sub', tst, 'role', 'authenticated')::text;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  select key into other_dept from departments d
   where not d.log_only and not exists (select 1 from profiles p where p.id = sup and d.key = any(p.departments))
   order by sort_order limit 1;

  -- everything below is undone at the end, whatever happens
  begin
    -- ---- 1. the bucket -------------------------------------------------
    select * into v_b from storage.buckets where id = 'photos';
    res := res || check_row(1, 'The photos bucket exists: private, JPEG only, 2 MB at most',
      v_b.id is not null and not coalesce(v_b.public, true) and v_b.allowed_mime_types = array['image/jpeg'] and v_b.file_size_limit = 2097152,
      case when v_b.id is null then 'There''s no photos bucket. Run photos.sql again.'
           when v_b.public then 'The photos bucket is PUBLIC — anyone could see the photos. Run photos.sql again, which makes it private.'
           else 'The bucket''s size limit or file type isn''t set. Run photos.sql again.' end);

    insert into jobs (monday_item_id, project_id, name, is_active, phase)
      values (-999995, 'PHOTOCHECK', 'Photos check - undone automatically', true, 'In Production') returning id into v_real;
    insert into work_orders (job_id) values (v_real) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 2), (v_wo, 2, 2);
    v := make_test_job('PHOTOCHECK');
    v_tpid := v->>'project_id';
    select id into v_test from jobs where project_id = v_tpid;
    select id into v_type from defect_types where department = sup_dept and active order by sort_order limit 1;

    -- ---- 2–5. a supervisor's photo on their own defect ----------------
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata)
        values ('photos', 'PHOTOCHECK/' || p1 || '.jpg', '{"size": 350000, "mimetype": "image/jpeg"}');
      execute 'reset role';
      ok := true; msg := null;
    exception when others then execute 'reset role'; ok := false; msg := 'The upload was refused: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A supervisor can upload a photo file into a job''s folder', ok, msg);

    begin
      execute 'set local role authenticated';
      v := log_defect(v_real, sup_dept, v_type, 2, 'photos check', gen_random_uuid());
      v_def := (v->>'id')::uuid;
      v := add_photo(p1, 'defect', v_def, null, 'the scratch');
      execute 'reset role';
      ok := (v->>'ok')::boolean and exists (select 1 from photos where client_id = p1 and defect_id = v_def and sheet_number = 2
                                                  and taken_by = sup and taken_by_name = sup_name and bytes = 350000);
      msg := 'The photo wasn''t saved on the defect, or has the wrong sheet, name or size: ' || coalesce(v->>'summary', '');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'It''s saved on their defect, on the defect''s sheet, under their name', ok, msg);

    begin
      execute 'set local role authenticated';
      v := add_photo(p1, 'defect', v_def);
      execute 'reset role';
      ok := coalesce((v->>'already')::boolean, false) and (select count(*) from photos where client_id = p1) = 1;
      msg := 'Sending the same photo again added it twice.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The same photo sent twice (a Wi-Fi retry) is saved once', ok, msg);

    begin
      execute 'set local role authenticated';
      v := add_photo(p2, 'defect', v_def);
      execute 'reset role';
      ok := false; msg := 'A photo with no file behind it was saved.';
    exception when others then execute 'reset role'; ok := sqlerrm like '%hasn''t arrived%'; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A photo whose file never arrived is refused', ok, msg);

    -- ---- 6. someone else's entry ---------------------------------------
    if other_dept is not null then
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      select id into v_otype from defect_types where department = other_dept and active order by sort_order limit 1;
      v := log_defect(v_real, other_dept, v_otype, 1, 'photos check, other department', null);
      v_odef := (v->>'id')::uuid;
      execute 'reset role';
      perform set_config('request.jwt.claims', as_sup, true);
      begin
        execute 'set local role authenticated';
        insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PHOTOCHECK/' || p2 || '.jpg', '{"size": 1}');
        v := add_photo(p2, 'defect', v_odef);
        execute 'reset role';
        ok := false; msg := format('%s added a photo to a %s entry.', sup_name, other_dept);
      exception when insufficient_privilege then execute 'reset role'; ok := true;
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    else ok := true;
    end if;
    res := res || check_row(6, 'Nobody can add a photo to another department''s entry', ok, msg);

    -- ---- 7. the lanes --------------------------------------------------
    begin
      execute 'set local role authenticated';
      begin
        insert into storage.objects (bucket_id, name, metadata) values ('photos', v_tpid || '/' || p3 || '.jpg', '{"size": 1}');
        ok := false; msg := 'A real supervisor uploaded into a TEST job''s folder.';
      exception when insufficient_privilege then ok := true;
      end;
      execute 'reset role';
      if ok then
        perform set_config('request.jwt.claims', as_tst, true);
        execute 'set local role authenticated';
        begin
          insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PHOTOCHECK/' || p3 || '.jpg', '{"size": 1}');
          ok := false; msg := 'The Test Supervisor uploaded into a REAL job''s folder.';
        exception when insufficient_privilege then ok := true;
        end;
        -- a test photo, for the next check
        insert into storage.objects (bucket_id, name, metadata) values ('photos', v_tpid || '/' || p3 || '.jpg', '{"size": 2}');
        v := start_loadout(v_test, gen_random_uuid());
        v_lo := (v->>'id')::uuid;
        v := add_photo(p3, 'loadout', v_lo, 1);
        execute 'reset role';
        perform set_config('request.jwt.claims', as_sup, true);
        execute 'set local role authenticated';
        select (select count(*) from photos where is_test) + (select count(*) from loadouts where is_test)
             + (select count(*) from v_photos where is_test) + (select count(*) from v_loadouts where is_test)
             + (select count(*) from storage.objects where bucket_id = 'photos' and name like 'TEST-%') into n;
        execute 'reset role';
        ok := ok and n = 0; msg := coalesce(msg, 'A real supervisor can see test photos, load-outs or files.');
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Test photos stay in the test lane, both ways', ok, msg);

    -- ---- 8. no writing around the functions; no deleting ---------------
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      begin
        insert into photos (client_id, job_id, department, kind, defect_id, storage_path) values (gen_random_uuid(), v_real, sup_dept, 'defect', v_def, 'x');
        ok := false; msg := 'A supervisor wrote to the photos table directly, around the checks.';
      exception when insufficient_privilege then ok := true;
      end;
      if ok then
        begin
          update storage.objects set metadata = '{}' where bucket_id = 'photos' and name = 'PHOTOCHECK/' || p1 || '.jpg';
          get diagnostics n = row_count;
          if n > 0 then ok := false; msg := 'A supervisor changed a photo file.'; end if;
        exception when insufficient_privilege then null;
        end;
        begin
          perform set_config('storage.allow_delete_query', 'true', true);
          delete from storage.objects where bucket_id = 'photos' and name = 'PHOTOCHECK/' || p1 || '.jpg';
          get diagnostics n = row_count;
          if n > 0 then ok := false; msg := 'A supervisor deleted a photo file.'; end if;
        exception when others then null;          -- refused, one way or another: good
        end;
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'Nobody writes photos around the checks, or changes or deletes a photo file', ok, msg);

    -- ---- 9. entered by mistake -----------------------------------------
    begin
      execute 'set local role authenticated';
      perform void_photo((select id from photos where client_id = p1));
      select count(*) into n from v_photos where client_id = p1 and voided;
      execute 'reset role';
      ok := n = 1 and exists (select 1 from storage.objects where bucket_id = 'photos' and name = 'PHOTOCHECK/' || p1 || '.jpg');
      msg := 'The photo wasn''t marked, or its row or file went.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, '"Entered by mistake" hides a photo and keeps it', ok, msg);

    -- ---- 10–11. load-outs ----------------------------------------------
    perform set_config('request.jwt.claims', as_tst, true);
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name, metadata) values ('photos', v_tpid || '/' || p4 || '.jpg', '{"size": 2}');
      begin
        v := add_photo(p4, 'loadout', v_lo, null, '   ');
        ok := false; msg := 'An item with no sheet and no description was accepted.';
      exception when others then ok := sqlerrm like '%say what it is%'; msg := 'Unexpected error: ' || sqlerrm;
      end;
      if ok then
        v := add_photo(p4, 'loadout', v_lo, null, 'hardware box');
        select count(*) into n from v_loadouts where id = v_lo and sheets_here = array[1] and other_items = 1 and sheets_total = 2;
        v := finish_loadout(v_lo);
        ok := n = 1 and v->>'summary' like '%1 of 2 sheets photographed%plus 1 other item%';
        msg := 'The load-out didn''t show sheet 1 of 2 plus one other item: ' || coalesce(v->>'summary', '');
      end if;
      execute 'reset role';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(10, 'Load-out: sheets are ticked off as they''re photographed; other items need a description', ok, msg);

    if not sup_delivers then
      perform set_config('request.jwt.claims', as_sup, true);
      begin
        execute 'set local role authenticated';
        v := start_loadout(v_real, gen_random_uuid());
        execute 'reset role';
        ok := false; msg := format('%s started a load-out, but only Delivery should.', sup_name);
      exception when insufficient_privilege then execute 'reset role'; ok := true;
      when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
      end;
    else ok := true;
    end if;
    res := res || check_row(11, 'Only Delivery (or a manager) starts a load-out', ok, msg);

    -- ---- 12. the floor clock ---------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    update jobs set phase = 'Delivery', is_active = false where id = v_real;
    ok := (select floor_left_at is null from jobs where id = v_real);
    update jobs set phase = '100% Complete' where id = v_real;
    ok := ok and (select floor_left_at > now() - interval '1 minute' from jobs where id = v_real);
    update jobs set phase = 'In Production', is_active = true where id = v_real;
    ok := ok and (select floor_left_at is null from jobs where id = v_real);
    res := res || check_row(12, 'A job''s clock starts when it moves past Delivery, and clears if it comes back', ok,
      'The date a job left the floor isn''t being recorded. Run photos.sql again.');

    -- ---- 13. only managers archive -------------------------------------
    perform set_config('request.jwt.claims', as_sup, true);
    begin
      execute 'set local role authenticated';
      v := prepare_photo_archive();
      execute 'reset role';
      ok := false; msg := 'A supervisor started a photo archive.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    res := res || check_row(13, 'Only a manager can archive photos', ok, msg);

    -- ---- 14–15. the archive, with its month of overlap ---------------------
    -- the job left the floor 61 days ago, and the photo is that old too;
    -- a second photo on the same job stays behind for the next batch
    update jobs set phase = '100% Complete', is_active = false where id = v_real;
    update jobs set floor_left_at = now() - interval '61 days' where id = v_real;
    update photos set taken_at = now() - interval '61 days' where client_id = p1;
    perform set_config('request.jwt.claims', as_sup, true);
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PHOTOCHECK/' || p5 || '.jpg', '{"size": 5}');
    v := flag_problem(v_real, sup_dept, 'photos check problem', 1, false, null);
    v := add_photo(p5, 'problem', (v->>'id')::uuid);
    execute 'reset role';
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := prepare_photo_archive();
      b1 := v->>'batch';
      execute 'reset role';
      ok := exists (select 1 from photos where client_id = p1 and archive_batch = b1
                                         and archive_name = 'PHOTOCHECK/sheet-02_' || replace(sup_dept, '_', '-') || '_'
                                             || to_char((now() - interval '61 days') at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') || '.jpg')
        and exists (select 1 from photos where client_id = p5 and archive_batch is null)
        and not exists (select 1 from photos where client_id = p3 and archive_batch is not null);
      msg := 'The archive picked the wrong photos, or named them wrongly.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'The archive takes photos from jobs off the floor 60+ days — not newer ones', ok, msg);

    begin
      execute 'set local role authenticated';
      v := confirm_photo_archive(b1);
      ok := not photo_file_released('PHOTOCHECK/' || p1 || '.jpg');                    -- saved, but kept a month
      execute 'reset role';
      update photos set taken_at = now() - interval '61 days' where client_id = p5;     -- a month later: the next batch
      execute 'set local role authenticated';
      v := prepare_photo_archive();  b2 := v->>'batch';
      v := confirm_photo_archive(b2);
      ok := ok and v->'released' ? b1 and photo_file_released('PHOTOCHECK/' || p1 || '.jpg')
                and not photo_file_released('PHOTOCHECK/' || p5 || '.jpg');
      begin
        perform set_config('storage.allow_delete_query', 'true', true);
        delete from storage.objects where bucket_id = 'photos' and name in ('PHOTOCHECK/' || p1 || '.jpg', 'PHOTOCHECK/' || p5 || '.jpg');
        get diagnostics n = row_count;
        ok := ok and n = 1;                                                              -- the released one only
        v := mark_photo_files_removed(b1);
        ok := ok and exists (select 1 from photos where client_id = p1 and file_removed_at is not null);
      exception when others then
        -- this Supabase stops file deletes from SQL altogether; the rule itself was checked above
        if sqlerrm not ilike '%direct deletion%' then raise; end if;
      end;
      execute 'reset role';
      ok := ok and exists (select 1 from photos where client_id = p1);                 -- the record stays
      msg := 'Files could be removed too early, the wrong ones could be removed, or the record went with them.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'A batch''s files leave Supabase only after the next batch is saved; records stay', ok, msg);

    -- ---- 16. no login --------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    begin
      execute 'set local role anon';
      select (select count(*) from photos) + (select count(*) from loadouts)
           + (select count(*) from storage.objects where bucket_id = 'photos') into n;
      execute 'reset role';
      ok := n = 0; msg := n || ' photos, load-outs or files are visible without logging in. Do not go further.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(16, 'Someone with no login sees no photos', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_photos_undo__';
  exception when others then
    if sqlerrm <> '__check_photos_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end;
$$;
revoke all on function check_photos() from public, anon, authenticated;

select * from check_photos();
