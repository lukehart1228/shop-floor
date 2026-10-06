-- =====================================================================
-- Shop Floor — saving to OneDrive and the hard drive (6 Oct 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Then run install_log.sql again.
-- Both are safe to run more than once. The last result is the PASS/FAIL
-- table.
--
-- What it adds (nothing existing changes):
--   1. A table, save_runs: one row each time the office page saves the
--      shop floor's files into the job folders (OneDrive) and the backup
--      folder (hard drive): who, when, whether each place worked, how
--      many jobs and files, which jobs were skipped and why.
--   2. save_jobs(since): the real jobs whose photos, files, trips,
--      issues, defects, flags, Arrow items or counts changed since a
--      time (all of them when there's no time), so a save only looks at
--      what's new. Test jobs are never included.
--   3. save_production_record(jobs): each sheet x department on those
--      jobs, how many pieces of how many, and when, how and by whom it
--      was finished. Sheet number and item code only, never the work
--      order's content.
--   4. record_save_run() and save_status(): the log, and the Needs you
--      reminder when 7 days pass without a save that reached both places.
--   Managers only, all of it. Nothing is deleted.
--   5. check_onedrive_save(): the PASS/FAIL check.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('onedrive_save.sql', '{}'); end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The log of saves
-- ---------------------------------------------------------------------
create table if not exists save_runs (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null unique,                     -- made by the page; a resend can't double it
  run_by        uuid not null references profiles(id),
  run_by_name   text not null,
  how           text not null,                            -- auto (the page on its own) or button (Save now)
  started_at    timestamptz not null,
  finished_at   timestamptz not null default clock_timestamp(),
  onedrive_ok   boolean not null,                         -- every job with a folder was saved there
  backup_ok     boolean not null,                         -- every job was saved to the backup folder
  jobs_checked  int not null default 0,
  jobs_saved    int not null default 0,                   -- jobs that had something new
  files_written int not null default 0,
  bytes         bigint not null default 0,
  skipped       jsonb not null default '[]',              -- [{"project_id": "PROJ-00468", "why": "No folder yet"}]
  problems      jsonb not null default '[]',              -- plain sentences
  page_version  text,
  constraint save_runs_how check (how in ('auto', 'button')),
  constraint save_runs_counts check (jobs_checked >= 0 and jobs_saved >= 0 and files_written >= 0 and bytes >= 0),
  constraint save_runs_lists check (jsonb_typeof(skipped) = 'array' and jsonb_typeof(problems) = 'array'
                                    and jsonb_array_length(skipped) <= 1000 and jsonb_array_length(problems) <= 50)
);
create index if not exists save_runs_finished on save_runs (finished_at desc);

alter table save_runs enable row level security;
revoke all on save_runs from anon, authenticated;
grant select on save_runs to authenticated;                 -- which rows: the policy below
drop policy if exists save_runs_office_reads on save_runs;
create policy save_runs_office_reads on save_runs for select to authenticated using (is_manager());

-- ---------------------------------------------------------------------
-- 2. Which jobs changed since a time
--    Every time below is set by the database when the row is written,
--    except a trip finished with no signal (the phone's time). The page
--    asks from two days before its last save, which covers that.
-- ---------------------------------------------------------------------
create or replace function save_jobs(p_since timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can save the shop floor''s files.' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('as_of', now(), 'jobs', coalesce((
    with t as (
      select job_id, greatest(taken_at, voided_at) as at from photos
      union all select job_id, greatest(logged_at, last_activity_at, answered_at, voided_at) from defects
      union all select job_id, greatest(raised_at, last_activity_at, answered_at) from problems
      union all select job_id, greatest(set_at, cleared_at) from flags
      union all select job_id, greatest(sent_at, gone_at, returned_at, voided_at) from outside_jobs
      union all select job_id, greatest(started_at, finished_at, scheduled_at, ready_at, completed_at, signed_at, voided_at) from loadouts
      union all select job_id, greatest(added_at, retired_at) from delivery_docs
      union all select job_id, greatest(sent_at, undone_at) from sheet_sends
      union all select job_id, created_at from work_orders
      union all select w.job_id, sp.updated_at from sheet_progress sp join sheets s on s.id = sp.sheet_id
                                                    join work_orders w on w.id = s.work_order_id and w.is_current
    ), j as (
      select t.job_id, max(t.at) as changed_at from t group by t.job_id
    )
    select jsonb_agg(jsonb_build_object('job_id', jb.id, 'project_id', jb.project_id, 'name', jb.name, 'changed_at', j.changed_at)
                     order by jb.project_id)
      from j join jobs jb on jb.id = j.job_id
     where not jb.is_test and jb.project_id is not null
       and (p_since is null or j.changed_at > p_since)
  ), '[]'::jsonb));
end $$;
revoke all on function save_jobs(timestamptz) from public, anon;
grant execute on function save_jobs(timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 3. The production record: sheet number and item code only
-- ---------------------------------------------------------------------
create or replace function save_production_record(p_job_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not office_ok() then
    raise exception 'Only a manager can save the shop floor''s files.' using errcode = 'insufficient_privilege';
  end if;
  if cardinality(coalesce(p_job_ids, '{}')) > 200 then
    raise exception 'Ask for 200 jobs or fewer at a time.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'job_id', w.job_id, 'project_id', jb.project_id, 'version', w.version, 'sheet', s.sheet_number,
             'item', s.item_code, 'department', d.name,
             'done', sp.qty_done, 'of', sp.qty_required,
             'state', case sp.state when 'complete' then 'Finished' when 'in_progress' then 'Started'
                                    when 'blocked' then 'Blocked' else 'Not started' end,
             'started', to_char(sp.started_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD HH24:MI'),
             'finished', case when sp.state = 'complete' then
                           to_char(sp.completed_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD HH24:MI') end,
             'how', case when sp.state = 'complete' then fin.source end,
             'by', case when sp.state = 'complete' then fin.by_name end)
           order by jb.project_id, s.sheet_number, d.sort_order, d.key)
      from sheet_progress sp
      join sheets s on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id and w.is_current
      join jobs jb on jb.id = w.job_id
      join departments d on d.key = sp.department
      left join lateral (
        select e.source, p.full_name as by_name
          from progress_events e left join profiles p on p.id = e.actor
         where e.sheet_id = sp.sheet_id and e.department = sp.department and e.state_to = 'complete'
         order by e.occurred_at desc, e.id desc limit 1) fin on true
     where w.job_id = any(p_job_ids) and not jb.is_test
  ), '[]'::jsonb);
end $$;
revoke all on function save_production_record(uuid[]) from public, anon;
grant execute on function save_production_record(uuid[]) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Recording a save, and the reminder
-- ---------------------------------------------------------------------
create or replace function record_save_run(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_client uuid;
begin
  if not office_ok() or auth.uid() is null then
    raise exception 'Only a manager''s office page records a save.' using errcode = 'insufficient_privilege';
  end if;
  begin v_client := (p ->> 'client_id')::uuid; exception when others then v_client := null; end;
  if v_client is null then raise exception 'The save has no id.'; end if;
  if coalesce(p ->> 'how', '') not in ('auto', 'button') then raise exception 'A save is auto or button.'; end if;
  if (p ->> 'started_at')::timestamptz > now() + interval '1 day' then raise exception 'That start time is in the future.'; end if;

  insert into save_runs (client_id, run_by, run_by_name, how, started_at, onedrive_ok, backup_ok,
                         jobs_checked, jobs_saved, files_written, bytes, skipped, problems, page_version)
  values (v_client, auth.uid(), coalesce(my_name(), 'Office'), p ->> 'how', (p ->> 'started_at')::timestamptz,
          coalesce((p ->> 'onedrive_ok')::boolean, false), coalesce((p ->> 'backup_ok')::boolean, false),
          coalesce((p ->> 'jobs_checked')::int, 0), coalesce((p ->> 'jobs_saved')::int, 0),
          coalesce((p ->> 'files_written')::int, 0), coalesce((p ->> 'bytes')::bigint, 0),
          coalesce(p -> 'skipped', '[]'::jsonb), coalesce(p -> 'problems', '[]'::jsonb), left(p ->> 'page_version', 40))
  on conflict (client_id) do nothing
  returning id into v_id;
  return jsonb_build_object('ok', true, 'already', v_id is null);
end $$;
revoke all on function record_save_run(jsonb) from public, anon;
grant execute on function record_save_run(jsonb) to authenticated;

create or replace function save_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_last save_runs; v_good save_runs; v_days int;
begin
  if not office_ok() then
    raise exception 'Only a manager can see the saves.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_last from save_runs order by finished_at desc, started_at desc limit 1;
  select * into v_good from save_runs where onedrive_ok and backup_ok order by finished_at desc, started_at desc limit 1;
  v_days := case when v_good.id is null then null
                 else local_today() - (v_good.finished_at at time zone 'America/Indiana/Indianapolis')::date end;
  return jsonb_build_object(
    'ever',            v_last.id is not null,
    'last_at',         v_last.finished_at,
    'last_by',         v_last.run_by_name,
    'last_how',        v_last.how,
    'last_onedrive_ok', v_last.onedrive_ok,
    'last_backup_ok',  v_last.backup_ok,
    'last_jobs_saved', v_last.jobs_saved,
    'last_files',      v_last.files_written,
    'last_skipped',    coalesce(v_last.skipped, '[]'::jsonb),
    'last_problems',   coalesce(v_last.problems, '[]'::jsonb),
    'good_at',         v_good.finished_at,
    'good_by',         v_good.run_by_name,
    'days_since_good', v_days,
    'due',             v_good.id is null or v_days >= 7);
end $$;
revoke all on function save_status() from public, anon;
grant execute on function save_status() to authenticated;

-- ---------------------------------------------------------------------
-- 5. The check. Everything it does is undone at the end.
-- ---------------------------------------------------------------------
create or replace function check_onedrive_save()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sup uuid; c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  r jsonb; n int; m int; ok boolean; msg text; real_job uuid; test_job uuid; ids text[];
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select id into sup from profiles where role = 'supervisor' and active and not is_test order by full_name limit 1;

  ok := to_regclass('public.save_runs') is not null
        and (select relrowsecurity from pg_class where oid = 'public.save_runs'::regclass)
        and to_regprocedure('public.save_jobs(timestamptz)') is not null
        and to_regprocedure('public.save_production_record(uuid[])') is not null
        and to_regprocedure('public.record_save_run(jsonb)') is not null
        and to_regprocedure('public.save_status()') is not null;
  res := res || check_row(1, 'The save log and its functions are in place, with row-level security on', ok,
                          'Run onedrive_save.sql again.');
  if mgr is null or sup is null then
    res := res || check_row(2, 'A manager and a supervisor login exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    -- ---- 2: a manager records a save; a resend keeps one; it's the last good save -----------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      r := record_save_run(jsonb_build_object('client_id', c1, 'how', 'auto', 'started_at', now(), 'onedrive_ok', true,
             'backup_ok', true, 'jobs_checked', 3, 'jobs_saved', 2, 'files_written', 9, 'bytes', 1000,
             'skipped', jsonb_build_array(jsonb_build_object('project_id', 'PROJ-CHECK', 'why', 'No folder yet'))));
      r := record_save_run(jsonb_build_object('client_id', c1, 'how', 'auto', 'started_at', now(), 'onedrive_ok', true, 'backup_ok', true));
      select count(*) into n from save_runs where client_id = c1 and bytes = 1000 and files_written = 9;
      r := save_status();
      execute 'reset role';
      ok := n = 1 and (r ->> 'days_since_good')::int = 0 and not (r ->> 'due')::boolean and (r ->> 'last_files')::int = 9
            and r -> 'last_skipped' -> 0 ->> 'project_id' = 'PROJ-CHECK';
      msg := case when ok then null else format('%s rows; status %s', n, r) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'A manager''s office page records a save once (even sent twice), and it counts as the last good save', ok, msg);

    -- ---- 3: a save that missed the backup folder is recorded but isn't a good save ------------------
    begin
      execute 'set local role authenticated';
      perform record_save_run(jsonb_build_object('client_id', c2, 'how', 'button', 'started_at', now() + interval '1 minute',
             'onedrive_ok', true, 'backup_ok', false, 'problems', jsonb_build_array('Backup drive not connected')));
      r := save_status();
      execute 'reset role';
      ok := (r ->> 'last_backup_ok')::boolean = false and (r ->> 'good_at')::timestamptz <= (r ->> 'last_at')::timestamptz
            and r -> 'last_problems' ->> 0 = 'Backup drive not connected';
      msg := case when ok then null else format('status %s', r) end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    -- the last good save was 8 days ago: the reminder is due
    if ok then
      update save_runs set finished_at = finished_at - interval '8 days', started_at = started_at - interval '8 days' where client_id = c1;
      begin
        execute 'set local role authenticated';
        r := save_status();
        execute 'reset role';
        ok := (r ->> 'due')::boolean and (r ->> 'days_since_good')::int = 8;
        msg := case when ok then null else format('8 days after the last good save: %s', r) end;
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(3, 'A save that missed the backup folder is logged, but the 7-day reminder counts from the last save that reached both', ok, msg);

    -- ---- 4: the jobs list: a real job with counts is there, a test job never is --------------------
    select w.job_id into real_job from sheet_progress sp join sheets s on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id
     where not j.is_test limit 1;
    select w.job_id into test_job from work_orders w join jobs j on j.id = w.job_id where j.is_test limit 1;
    begin
      execute 'set local role authenticated';
      r := save_jobs(null);
      execute 'reset role';
      select array_agg(x ->> 'job_id') into ids from jsonb_array_elements(r -> 'jobs') x;
      ok := (real_job is null or real_job::text = any(ids)) and (test_job is null or not (test_job::text = any(coalesce(ids, '{}'))))
            and (r ->> 'as_of') is not null;
      msg := case when ok then null else format('real job %s listed: %s; test job %s listed: %s', real_job, real_job::text = any(ids),
                                               test_job, test_job::text = any(coalesce(ids, '{}'))) end;
      if ok and real_job is null then msg := null; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The jobs to save include real jobs with counts and never a test job'
                               || case when real_job is null then ' (no counts yet, so partly skipped)' else '' end, ok, msg);

    -- ---- 5: the production record names sheet and item code only ------------------------------------
    if real_job is not null then
      begin
        execute 'set local role authenticated';
        r := save_production_record(array[real_job]);
        execute 'reset role';
        select count(*) into n from jsonb_array_elements(r) x, jsonb_object_keys(x) k
         where k not in ('job_id', 'project_id', 'version', 'sheet', 'item', 'department', 'done', 'of', 'state', 'started', 'finished', 'how', 'by');
        ok := jsonb_array_length(r) > 0 and n = 0;
        msg := case when ok then null else format('%s rows, %s unexpected fields', jsonb_array_length(r), n) end;
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(5, 'The production record lists each sheet and department by sheet number and item code only', ok, msg);
    else
      res := res || check_row(5, 'The production record lists each sheet and department (no counts yet, so skipped)', true, null);
    end if;

    -- ---- 6: a supervisor can do none of it ------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin execute 'set local role authenticated'; perform record_save_run(jsonb_build_object('client_id', gen_random_uuid(), 'how', 'auto', 'started_at', now()));
      execute 'reset role'; msg := 'recorded a save';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform save_jobs(null);
      execute 'reset role'; msg := concat_ws(', ', msg, 'listed the jobs');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform save_production_record(array[coalesce(real_job, gen_random_uuid())]);
      execute 'reset role'; msg := concat_ws(', ', msg, 'read a production record');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; perform save_status();
      execute 'reset role'; msg := concat_ws(', ', msg, 'read the save status');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; select count(*) into m from save_runs;
      execute 'reset role'; if m > 0 then msg := concat_ws(', ', msg, format('read %s saves', m)); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(6, 'A supervisor can''t record a save, list the jobs, read a production record, or see the saves', n = 5, msg);

    -- ---- 7: nobody writes straight into the log, not even a manager -----------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    n := 0; msg := null;
    begin execute 'set local role authenticated';
      insert into save_runs (client_id, run_by, run_by_name, how, started_at, onedrive_ok, backup_ok)
      values (gen_random_uuid(), mgr, 'Someone', 'auto', now(), true, true);
      execute 'reset role'; msg := 'wrote a save straight into the table';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; update save_runs set files_written = 0 where client_id = c1;
      get diagnostics m = row_count; execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'changed a save'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; delete from save_runs where client_id = c1;
      get diagnostics m = row_count; execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'deleted a save'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(7, 'Nobody writes, changes or deletes the save log directly; only the office page''s save adds to it', n = 3, msg);

    -- ---- 8: no login: nothing ---------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    begin execute 'set local role anon'; perform save_jobs(null); execute 'reset role'; msg := 'listed the jobs with no login';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role anon'; perform save_status(); execute 'reset role'; msg := concat_ws(', ', msg, 'read the status with no login');
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role anon'; select count(*) into m from save_runs; execute 'reset role';
      if m > 0 then msg := concat_ws(', ', msg, 'read the saves with no login'); else n := n + 1; end if;
    exception when others then execute 'reset role'; n := n + 1; end;
    res := res || check_row(8, 'Someone with no login can''t list jobs, read the status or see the saves', n = 3, coalesce(msg, '') || '. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_onedrive_save_undo__';
  exception when others then
    if sqlerrm <> '__check_onedrive_save_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_onedrive_save() from public, anon, authenticated;

select * from check_onedrive_save();
