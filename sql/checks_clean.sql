-- =====================================================================
-- checks_clean.sql — every check to a clean PASS; an uploaded job that
-- Monday will never have can be retired; R-14 on record as accepted
-- (12 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 62. Safe to run twice.
-- Registers itself: one paste. Run it after two_day_rule.sql and before
-- the 12 Nov install_log.sql. The last result is the PASS/FAIL table:
-- every row should say PASS.
--
-- WHAT IT DOES
-- 1. Retiring a placeholder. A work order uploaded under a PROJ number
--    Monday doesn't have is held as a job of its own, on the floor, and
--    the Monday sync reports it every 15 minutes. When that number was a
--    mistake and the work is done, select retire_placeholder('PROJ-…',
--    'why') (SQL Editor only) takes it off the office's lists and off Job
--    status; the sync and check_monday_sync() stop counting it;
--    an upload under that number is refused in plain words. Nothing is
--    deleted: the job, its sheets, counts and history stay.
--    select * from retired_placeholders(); lists them.
--    This file retires PROJ-00421-2 (a page missed from PROJ-00421,
--    which is done and shipped), once.
-- 2. Accepted findings (accepted_findings). R-14: on Supabase the http
--    extension's functions belong to supabase_admin and stay open to
--    every database role; the SQL Editor can't take that away. Luke
--    accepted it on 12 Nov 2026; the rule that no Supabase connector is
--    turned on stays. check_connector_safety() now says so in words and
--    PASSES for exactly that, and still FAILS for anything new: an
--    internet function the SQL Editor could close, another extension
--    (pg_net), the extension in a schema the API exposes, or a function
--    a login may run that reaches the internet.
-- 3. Checks that tripped over live data or the calendar, rewritten:
--    check_pace() (its test crossed the 1 Nov clock change),
--    check_incomplete_deliveries() (it picked a sales look-up login as
--    "another department's supervisor"), check_onedrive_save() (a real
--    save in the last 8 days), check_inventory() step 7 (it leaned on
--    the live Maple 6/4 count). What they test is unchanged.
-- Nothing on a tablet, the Delivery phone or the TV changes (a job Monday
-- doesn't have was never on a tablet). In the office a retired
-- placeholder leaves Jobs, Setup's list of uploads and the sync alert.
--
-- Replaces pieces of office.sql (run_monday_sync, check_monday_sync),
-- inventory.sql, pace.sql, onedrive_save.sql, connector_safety.sql,
-- incomplete_deliveries.sql (their checks) and job_status.sql
-- (job_lookup), so those files now stop if run again.
-- Ends with check_checks_clean().
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('checks_clean.sql', 62, 'retire_placeholder', 'check_checks_clean', '{office.sql,inventory.sql,pace.sql,onedrive_save.sql,connector_safety.sql,incomplete_deliveries.sql,job_status.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('checks_clean.sql', '{office.sql,inventory.sql,pace.sql,onedrive_save.sql,connector_safety.sql,incomplete_deliveries.sql,job_status.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.check_delivery_photos_open()') is null then raise exception 'Run delivery_photos_open.sql first. This file comes after it.'; end if;
  if to_regprocedure('public.check_job_items()') is null then raise exception 'Run job_items.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. Retiring a placeholder
-- ---------------------------------------------------------------------

alter table jobs add column if not exists retired_at  timestamptz;     -- set only on a placeholder (no Monday row) that was retired
alter table jobs add column if not exists retired_why text;

-- select retire_placeholder('PROJ-00421-2', 'why');   SQL Editor only. Safe to run twice.
create or replace function retire_placeholder(p_project text, p_why text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_pid text := upper(btrim(coalesce(p_project, '')));
  j     jobs;
  n_wo int; n_sheets int; n_counted int; n_trips int;
begin
  if v_pid = '' then
    return 'Give the number and why, like this:  select retire_placeholder(''PROJ-00421-2'', ''why it is being retired'');  Nothing was changed.';
  end if;
  if btrim(coalesce(p_why, '')) = '' then
    return format('Say why in a few words (it is kept with the job):  select retire_placeholder(%L, %L);  Nothing was changed.', v_pid, 'why');
  end if;
  select * into j from jobs where upper(project_id) = v_pid and monday_item_id is null and not coalesce(is_test, false) order by created_at limit 1;
  if j.id is null then
    if exists (select 1 from jobs where upper(project_id) = v_pid and monday_item_id is not null) then
      return v_pid || ' is on the Monday board, so it isn''t a placeholder. Nothing was changed. A real job leaves the floor when Monday''s Phase changes.';
    end if;
    return 'There is no uploaded job numbered ' || v_pid || ' waiting on Monday. Nothing was changed.';
  end if;
  if j.retired_at is not null then
    return v_pid || ' was already retired on ' || to_char(j.retired_at at time zone 'America/Indiana/Indianapolis', 'FMDD Mon YYYY') || '. Nothing was changed.';
  end if;
  update jobs set is_active = false, retired_at = now(), retired_why = left(btrim(p_why), 500), updated_at = now() where id = j.id;
  select count(*) into n_wo from work_orders where job_id = j.id;
  select count(*) into n_sheets from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = j.id and w.is_current;
  select count(*) into n_counted from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id
   where w.job_id = j.id and sp.qty_done > 0;
  select count(*) into n_trips from loadouts where job_id = j.id;
  return format('%s is retired: off every list and Job status, and the Monday sync and its check no longer count it. Nothing was deleted. Kept as history: %s work order version%s, %s sheet%s, %s count%s entered, %s trip%s.',
    v_pid, n_wo, case when n_wo = 1 then '' else 's' end, n_sheets, case when n_sheets = 1 then '' else 's' end,
    n_counted, case when n_counted = 1 then '' else 's' end, n_trips, case when n_trips = 1 then '' else 's' end);
end $$;
revoke all on function retire_placeholder(text, text) from public, anon, authenticated;

-- select * from retired_placeholders();   SQL Editor only
create or replace function retired_placeholders()
returns table (project_id text, name text, retired text, why text, sheets bigint)
language sql stable security definer set search_path = public as $$
  select j.project_id, j.name, to_char(j.retired_at at time zone 'America/Indiana/Indianapolis', 'FMDD Mon YYYY, HH12:MI am'), j.retired_why,
         (select count(*) from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = j.id and w.is_current)
    from jobs j where j.retired_at is not null and j.monday_item_id is null
   order by j.retired_at;
$$;
revoke all on function retired_placeholders() from public, anon, authenticated;

-- a work order uploaded under a retired number is refused, with nothing saved
create or replace function work_orders_retired_guard() returns trigger
language plpgsql set search_path = public as $$
declare j jobs;
begin
  select * into j from jobs where id = new.job_id;
  if j.retired_at is not null and j.monday_item_id is null then
    raise exception '% was retired on % and takes no more work orders: it was uploaded under a number that isn''t on the Monday board. Nothing was saved. Check the PROJ number on the work order; if this number is right, bring it to Claude in a chat.',
      j.project_id, to_char(j.retired_at at time zone 'America/Indiana/Indianapolis', 'FMDD Mon YYYY') using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function work_orders_retired_guard() from public, anon, authenticated;
drop trigger if exists work_orders_retired_guard on work_orders;
create trigger work_orders_retired_guard before insert on work_orders for each row execute function work_orders_retired_guard();


-- ---------------------------------------------------------------------
-- 2. The Monday sync and its check (from office.sql), leaving retired
--    placeholders out of "uploaded but not on the Monday board". Nothing
--    else in either changes.
-- ---------------------------------------------------------------------

create or replace function run_monday_sync(p_endpoint text default 'https://api.monday.com/v2')
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  c_board      constant bigint := 8693042231;
  c_col_proj   constant text   := 'text_mm0wnntf';   -- Project ID
  c_col_date   constant text   := 'date_mkwjd2an';   -- Delivery Date
  c_col_phase  constant text   := 'color_mkwqppkb';  -- Phase
  c_live_phase constant text   := 'In Production';

  v_extra    jsonb;       -- {key: column_id} for the columns setup found
  v_ho_id    text;
  v_ho_type  text;
  v_ho_yes   text;
  v_use_extra boolean;
  v_fields   text;
  v_present  jsonb;       -- which extra columns came back on at least one job
  v_ho_ok    boolean;
  v_stages   jsonb;
  k          text;

  v_token    text;
  v_cursor   text;
  v_page     int;
  v_query    text;
  v_resp     http_response;
  v_body     jsonb;
  v_batch    jsonb;
  v_items    jsonb;

  it         jsonb;
  v_cols     jsonb;
  v_mid      bigint;
  v_pid      text;
  v_name     text;
  v_phase    text;
  v_date     date;
  v_active   boolean;
  v_mat      boolean;
  v_ho       boolean;
  v_ho_text  text;
  v_job      uuid;
  v_seen     bigint[] := '{}';

  n_added    int := 0;
  n_updated  int := 0;
  n_adopted  int := 0;
  n_deact    int := 0;
  n_active   int := 0;
  v_problems jsonb := '[]'::jsonb;
  v_summary  text;
  v_err      text;
begin
  begin   -- everything in here is all-or-nothing

    select decrypted_secret into v_token
      from vault.decrypted_secrets where name = 'monday_token' limit 1;
    if v_token is null or trim(v_token) = '' then
      raise exception 'No Monday token in the Vault. Add a secret named monday_token (walkthrough 3, step 3).';
    end if;

    begin
      perform http_set_curlopt('CURLOPT_TIMEOUT', '30');
    exception when undefined_function then null;
    end;

    select coalesce(jsonb_object_agg(key, column_id) filter (where column_id is not null), '{}'::jsonb)
      into v_extra from monday_columns;
    select column_id, col_type, yes_label into v_ho_id, v_ho_type, v_ho_yes from monday_columns where key = 'handed_off';
    v_use_extra := v_extra <> '{}'::jsonb;

    <<attempt>>
    loop
      v_fields := format('id name column_values(ids: [%s]) { id text } subitems { name column_values(ids: ["status"]) { text } }',
        (select string_agg(to_json(x)::text, ',') from (
           select unnest(array[c_col_proj, c_col_date, c_col_phase]) x
           union all
           select value #>> '{}' from jsonb_each(v_extra) where v_use_extra) ids));
      v_cursor := null; v_page := 0; v_items := '[]'::jsonb;

      -- ---- read the whole board, page by page ------------------------
      loop
        v_page := v_page + 1;
        if v_page > 20 then
          raise exception 'Monday kept sending more pages (over 2,000 jobs). Stopped to be safe.';
        end if;

        if v_cursor is null then
          v_query := format('query { boards(ids: [%s]) { items_page(limit: 100) { cursor items { %s } } } }', c_board, v_fields);
        else
          v_query := format('query { next_items_page(limit: 100, cursor: %s) { cursor items { %s } } }',
                            to_json(v_cursor)::text, v_fields);
        end if;

        v_resp := http((
          'POST', p_endpoint,
          array[http_header('Authorization', trim(v_token))],
          'application/json',
          jsonb_build_object('query', v_query)::text
        )::http_request);

        if v_resp.status in (401, 403) then
          raise exception 'Monday refused access (%). The token may be wrong or revoked, or its account can''t open the Orders board. Put a fresh token in the Vault, from an account that can see the board.', v_resp.status;
        elsif v_resp.status = 429 then
          raise exception 'Monday asked us to slow down (429). This run was skipped; the next one will try again.';
        elsif v_resp.status <> 200 then
          raise exception 'Monday answered with an error (%): %', v_resp.status, left(v_resp.content, 200);
        end if;

        begin
          v_body := v_resp.content::jsonb;
        exception when others then
          raise exception 'Monday''s reply wasn''t readable: %', left(v_resp.content, 200);
        end;

        if v_body ? 'errors' or v_body ? 'error_message' then
          if v_use_extra and v_page = 1 then
            -- maybe one of the extra columns has gone; keep the floor syncing without them
            v_problems := v_problems || to_jsonb(format(
              'Monday refused the Handed Off / stage columns (%s), so this run read only Project ID, Delivery Date and Phase. Run: select * from setup_monday_columns();',
              left(coalesce(v_body->>'error_message', (v_body->'errors')::text), 150)));
            v_use_extra := false;
            continue attempt;
          end if;
          raise exception 'Monday reported a problem: %',
            left(coalesce(v_body->>'error_message', (v_body->'errors')::text), 300);
        end if;

        v_batch := case when v_cursor is null
                        then v_body #> '{data,boards,0,items_page}'
                        else v_body #> '{data,next_items_page}' end;
        if v_batch is null then
          raise exception 'Monday''s reply didn''t contain the Orders board. Check the token''s account can see it.';
        end if;

        v_items  := v_items || coalesce(v_batch->'items', '[]'::jsonb);
        v_cursor := nullif(v_batch->>'cursor', '');
        exit when v_cursor is null;
      end loop;
      exit attempt;
    end loop;

    -- the guard: an empty board is never believed
    if jsonb_array_length(v_items) = 0 then
      raise exception 'Monday returned an empty Orders board. Nothing was changed, in case that''s a mistake on Monday''s end.';
    end if;

    -- which extra columns actually came back (a column that's on no job at
    -- all was probably deleted: leave what we had rather than blank it)
    v_present := '{}'::jsonb;
    if v_use_extra then
      select coalesce(jsonb_object_agg(e.key, true), '{}'::jsonb) into v_present
        from jsonb_each(v_extra) e
       where exists (select 1 from jsonb_array_elements(v_items) i, jsonb_array_elements(coalesce(i->'column_values', '[]')) c
                      where c->>'id' = e.value #>> '{}');
      for k in select e.key from jsonb_each(v_extra) e where not v_present ? e.key loop
        v_problems := v_problems || to_jsonb(format(
          'The %s column (%s) didn''t come back from Monday on any job, so it was left as it was. If it was deleted or recreated, run: select * from setup_monday_columns();',
          (select what from monday_columns where key = k), v_extra->>k));
      end loop;
    end if;
    v_ho_ok := v_ho_id is not null and v_present ? 'handed_off'
               and (v_ho_type = 'checkbox' or v_ho_yes is not null);

    -- ---- one job at a time ---------------------------------------------
    for it in select * from jsonb_array_elements(v_items) loop
      v_mid  := (it->>'id')::bigint;
      v_seen := v_seen || v_mid;

      select coalesce(jsonb_object_agg(c->>'id', c->>'text'), '{}'::jsonb) into v_cols
        from jsonb_array_elements(coalesce(it->'column_values', '[]'::jsonb)) c;

      v_pid := upper(nullif(trim(v_cols->>c_col_proj), ''));
      if v_pid is null then
        v_pid := upper(substring(it->>'name' from '(?i)PROJ-\d+'));
      end if;
      if v_pid is null then
        v_problems := v_problems || to_jsonb(format(
          '"%s" has no PROJ number in its Project ID column or its name, so it was skipped.', it->>'name'));
        continue;
      end if;

      v_name  := nullif(trim(regexp_replace(it->>'name', '^\s*PROJ-\d+\s*[-–:]?\s*', '', 'i')), '');
      v_name  := coalesce(v_name, it->>'name');
      v_phase := nullif(trim(v_cols->>c_col_phase), '');
      v_date  := case when coalesce(v_cols->>c_col_date, '') ~ '^\d{4}-\d{2}-\d{2}'
                      then left(v_cols->>c_col_date, 10)::date end;
      v_active := (v_phase = c_live_phase);
      v_mat := exists (
        select 1 from jsonb_array_elements(coalesce(it->'subitems', '[]'::jsonb)) si
         where lower(si->>'name') like '%order materials%'
           and exists (select 1 from jsonb_array_elements(coalesce(si->'column_values', '[]'::jsonb)) cv
                        where lower(coalesce(cv->>'text', '')) = 'done'));

      -- Handed Off: a tick box reads "v" when ticked; a status reads its label
      v_ho_text := nullif(trim(v_cols->>v_ho_id), '');
      v_ho := case when not v_ho_ok then null
                   when v_ho_type = 'checkbox' then v_ho_text is not null
                   else lower(coalesce(v_ho_text, '')) = lower(v_ho_yes) end;

      -- stages that came back on this pass; the rest keep their last value
      select coalesce(jsonb_object_agg(e.key, nullif(trim(v_cols->>(e.value #>> '{}')), '')), '{}'::jsonb) into v_stages
        from jsonb_each(v_extra) e where e.key <> 'handed_off' and v_present ? e.key;

      begin
        update jobs set project_id = v_pid, name = v_name, delivery_date = v_date, phase = v_phase,
                        is_active = v_active, materials_ordered = v_mat, last_synced_at = now(),
                        handed_off      = case when v_ho_ok then v_ho      else handed_off end,
                        handed_off_text = case when v_ho_ok then v_ho_text else handed_off_text end,
                        monday_stages   = monday_stages || v_stages,
                        updated_at = now()
         where monday_item_id = v_mid
        returning id into v_job;

        if found then
          n_updated := n_updated + 1;
        else
          update jobs set monday_item_id = v_mid, name = v_name, delivery_date = v_date, phase = v_phase,
                          is_active = v_active, materials_ordered = v_mat, last_synced_at = now(),
                          handed_off      = case when v_ho_ok then v_ho      else handed_off end,
                          handed_off_text = case when v_ho_ok then v_ho_text else handed_off_text end,
                          monday_stages   = monday_stages || v_stages,
                          updated_at = now()
           where project_id = v_pid and monday_item_id is null and not is_test
          returning id into v_job;

          if found then
            n_adopted := n_adopted + 1;
          else
            insert into jobs (monday_item_id, project_id, name, delivery_date, phase,
                              is_active, materials_ordered, last_synced_at,
                              handed_off, handed_off_text, monday_stages)
            values (v_mid, v_pid, v_name, v_date, v_phase, v_active, v_mat, now(),
                    case when v_ho_ok then v_ho end, case when v_ho_ok then v_ho_text end, v_stages);
            n_added := n_added + 1;
          end if;
        end if;
      exception when unique_violation then
        v_problems := v_problems || to_jsonb(format(
          '%s already belongs to a different Monday row, so "%s" was skipped. If that PROJ number is used twice in Monday, fix the duplicate there.',
          v_pid, it->>'name'));
      end;
    end loop;

    -- ---- jobs no longer on the board: off the floor, history kept -----
    with gone as (
      update jobs set is_active = false, updated_at = now()
       where monday_item_id is not null
         and is_active
         and not (monday_item_id = any(v_seen))
      returning 1)
    select count(*) into n_deact from gone;

    -- work orders for PROJ numbers Monday has never heard of (test jobs never are)
    select v_problems || coalesce(jsonb_agg(to_jsonb(format(
             '%s has a work order uploaded but isn''t on the Monday board. Check the PROJ number.', project_id))), '[]')
      into v_problems
      from jobs where monday_item_id is null and not is_test and retired_at is null;   -- checks_clean.sql: a retired placeholder isn't reported

    select count(*) into n_active from jobs where is_active and monday_item_id is not null;

  exception when others then
    v_err := sqlerrm;
  end;

  if v_err is not null then
    v_summary := 'Sync failed, nothing changed. ' || v_err;
    insert into monday_sync_log (ok, summary, problems) values (false, v_summary, '[]');
    return jsonb_build_object('ok', false, 'summary', v_summary);
  end if;

  v_summary := format('Read %s jobs from Monday. %s in production.', jsonb_array_length(v_items), n_active);
  if n_added     > 0 then v_summary := v_summary || format(' %s new.', n_added); end if;
  if n_adopted   > 0 then v_summary := v_summary || format(' %s uploaded work order%s linked to Monday.', n_adopted, case when n_adopted = 1 then '' else 's' end); end if;
  if n_deact     > 0 then v_summary := v_summary || format(' %s left the board.', n_deact); end if;
  if jsonb_array_length(v_problems) > 0 then
    v_summary := v_summary || format(' %s thing%s to look at — see problems.',
      jsonb_array_length(v_problems), case when jsonb_array_length(v_problems) = 1 then '' else 's' end);
  end if;

  insert into monday_sync_log (ok, summary, items_read, active, added, updated, adopted, deactivated, problems)
  values (true, v_summary, jsonb_array_length(v_items), n_active, n_added, n_updated, n_adopted, n_deact, v_problems);

  return jsonb_build_object('ok', true, 'summary', v_summary, 'problems', v_problems);
end;
$$;
revoke all on function run_monday_sync(text) from public, anon, authenticated;

-- check_monday_sync() step 6 leaves test jobs and retired placeholders out
create or replace function check_monday_sync()
returns table (step int, check_name text, result text, detail text)
language plpgsql security definer
set search_path = public
as $$
declare
  last monday_sync_log;
  n    int;
  n_ret int;  v_ret text;
begin
  step := 1; check_name := 'The Monday token is in the Vault';
  select count(*) into n from vault.decrypted_secrets where name = 'monday_token' and coalesce(decrypted_secret, '') <> '';
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  detail := case when n > 0 then null else 'Add a Vault secret named exactly monday_token (walkthrough 3, step 3).' end;
  return next;

  step := 2; check_name := 'The sync is scheduled every 15 minutes';
  select count(*) into n from cron.job where jobname = 'shop-floor-monday-sync' and active;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  detail := case when n > 0 then null else 'The 15-minute schedule is missing. Paste this:  select cron.schedule(''shop-floor-monday-sync'', ''*/15 * * * *'', ''select public.run_monday_sync()'');' end;
  return next;

  select * into last from monday_sync_log order by run_at desc limit 1;

  step := 3; check_name := 'The most recent run worked';
  if last.id is null then
    result := 'FAIL'; detail := 'It hasn''t run yet. Run it once now: select run_monday_sync();';
  elsif last.ok then
    result := 'PASS'; detail := last.summary;
  else
    result := 'FAIL'; detail := last.summary;
  end if;
  return next;

  step := 4; check_name := 'It ran in the last 20 minutes';
  if last.id is not null and last.run_at > now() - interval '20 minutes' then
    result := 'PASS'; detail := 'Last run ' || to_char(last.run_at at time zone 'America/Indiana/Indianapolis', 'Mon DD, HH12:MI am');
  else
    result := 'FAIL';
    detail := case when last.id is null then 'No runs yet.'
                   else 'Last run was ' || to_char(last.run_at at time zone 'America/Indiana/Indianapolis', 'Mon DD, HH12:MI am') ||
                        '. If the project was paused, restore it; otherwise check step 2.' end;
  end if;
  return next;

  step := 5; check_name := 'Jobs are in production';
  select count(*) into n from jobs where is_active and monday_item_id is not null;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  detail := n || ' active jobs.';
  return next;

  step := 6; check_name := 'Every uploaded work order is linked to Monday';
  select count(*) into n from jobs where monday_item_id is null and not is_test and retired_at is null;
  select count(*), string_agg(project_id, ', ' order by retired_at) into n_ret, v_ret from jobs where monday_item_id is null and not is_test and retired_at is not null;
  result := case when n = 0 then 'PASS' else 'FAIL' end;
  detail := case when n = 0 then case when n_ret > 0 then 'Not counted: ' || n_ret || ' retired placeholder' || case when n_ret = 1 then '' else 's' end || ' (' || v_ret || ').' end
                 else n || ' still unlinked: ' ||
                      (select string_agg(project_id, ', ') from jobs where monday_item_id is null and not is_test and retired_at is null) ||
                      '. Either the sync hasn''t run since the upload, or the PROJ number isn''t on the board. If the number was a mistake and the work is done: select retire_placeholder(''PROJ-…'', ''why'');' end;
  return next;
end;
$$;
revoke all on function check_monday_sync() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Job status (job_lookup, from job_status.sql): a retired placeholder
--    isn't found. Nothing else in it changes.
-- ---------------------------------------------------------------------

create or replace function job_lookup(p_q text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me      profiles;
  v_mgr   boolean;
  v_look  boolean;
  v_test  boolean;
  v_q     text := lower(btrim(coalesce(p_q, '')));
  v_dig   text;
  v_words text[];
  v_out   jsonb;
begin
  if auth.uid() is null then
    raise exception 'Sign in to look up a job.' using errcode = 'insufficient_privilege';
  end if;
  select * into me from profiles where id = auth.uid();
  if me.id is null then
    raise exception 'This login can''t look up jobs.' using errcode = 'insufficient_privilege';
  end if;
  v_mgr  := me.role in ('manager', 'admin');
  v_look := coalesce(me.look_up, false) and not v_mgr;
  v_test := coalesce(me.is_test, false);
  if v_q = '' or length(v_q) > 80 then
    return jsonb_build_object('at', now(), 'look_up', v_look, 'jobs', '[]'::jsonb);
  end if;
  v_dig   := ltrim(regexp_replace(v_q, '\D', '', 'g'), '0');
  v_words := regexp_split_to_array(v_q, '\s+');

  select coalesce(jsonb_agg(job_status_json(f.id, v_look) order by f.is_active desc, f.project_id desc nulls last), '[]'::jsonb)
    into v_out
    from (select j.id, j.is_active, j.project_id from jobs j
           where (coalesce(j.is_test, false) = v_test or v_mgr)
             and not (j.retired_at is not null and j.monday_item_id is null)        -- checks_clean.sql: a retired placeholder
             and ((v_dig <> '' and ltrim(regexp_replace(coalesce(j.project_id, ''), '\D', '', 'g'), '0') like '%' || v_dig || '%')
                  or not exists (select 1 from unnest(v_words) w
                                  where position(w in lower(coalesce(j.name, '') || ' ' || coalesce(j.project_id, ''))) = 0))
           order by j.is_active desc, j.project_id desc nulls last
           limit 20) f;
  return jsonb_build_object('at', now(), 'look_up', v_look, 'jobs', v_out);
end;
$$;
revoke all on function job_lookup(text) from public, anon;
grant execute on function job_lookup(text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. One-time: PROJ-00421-2. A page missed from PROJ-00421 (an office
--    error) was uploaded under a number Monday doesn't have. PROJ-00421
--    is done and shipped, so nothing is re-issued or merged (Luke, 12 Nov
--    2026). Where there's no such job, or it's already retired, this
--    does nothing.
-- ---------------------------------------------------------------------

do $$ begin
  if exists (select 1 from jobs where upper(project_id) = 'PROJ-00421-2' and monday_item_id is null and not coalesce(is_test, false) and retired_at is null) then
    perform retire_placeholder('PROJ-00421-2',
      'A page missed from PROJ-00421 (an office error), uploaded under a number Monday doesn''t have. PROJ-00421 is done and shipped; nothing re-issued or merged (Luke, 12 Nov 2026).');
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 5. Accepted findings: a review finding Luke has decided to live with,
--    on record, so a check can say "accepted" instead of failing for
--    ever, and still fail for anything new. SQL Editor only.
--    To take an acceptance back:
--      update accepted_findings set withdrawn_at = now() where finding = 'R-14';
-- ---------------------------------------------------------------------

create table if not exists accepted_findings (
  finding      text primary key,
  accepted_on  date not null,
  accepted_by  text not null,
  what         text not null,          -- what is being lived with
  rule_kept    text not null,          -- the rule that stays because of it
  withdrawn_at timestamptz
);
alter table accepted_findings enable row level security;
revoke all on accepted_findings from public, anon, authenticated;

insert into accepted_findings (finding, accepted_on, accepted_by, what, rule_kept) values
  ('R-14', '2026-11-12', 'Luke',
   'On Supabase the http extension''s functions belong to supabase_admin and can be run by every database role; the SQL Editor can''t take that away. No page, login or the TV can reach them: the extension isn''t in a schema the API serves.',
   'No Supabase connector is turned on for any Claude project.')
on conflict (finding) do nothing;

-- the same closing-up connector_safety.sql did, so running this file again closes anything the SQL Editor can close
do $$
declare f regprocedure; who text;
begin
  who := 'public, anon, authenticated, service_role'
         || case when exists (select 1 from pg_roles where rolname = 'supabase_read_only_user') then ', supabase_read_only_user' else '' end;
  for f in
    select p.oid::regprocedure from pg_proc p
      join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
      join pg_extension e on e.oid = d.refobjid
     where e.extname in ('http', 'pg_net') and pg_get_userbyid(p.proowner) = current_user
  loop
    execute format('revoke all on function %s from %s', f, who);
  end loop;
  for f in
    select p.oid::regprocedure from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prosecdef and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

create or replace function check_connector_safety()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as no-login and a login
declare
  res     jsonb := '[]';
  roles   text[] := array['public', 'anon', 'authenticated', 'service_role', 'supabase_read_only_user'];
  ext_sch text;
  n int; m int; msg text; owners text; ok boolean;
  sup uuid;
  acc accepted_findings;  acc_note text;
  n_ours int; n_other int; n_theirs int; msg_new text;
  api_cfg text; api_schemas text; exposed boolean;
  reach text[]; more text[]; n_reach int; msg_reach text;
  allowed text[] := array['my_role', 'owns_dept', 'tv_snapshot', 'tv_photo'];
begin
  -- roles this database actually has ('public' is everyone)
  roles := array(select r from unnest(roles) r where r = 'public' or exists (select 1 from pg_roles where rolname = r));

  -- R-14 accepted? (accepted_findings; Luke, 12 Nov 2026)
  select * into acc from accepted_findings where finding = 'R-14' and withdrawn_at is null;
  acc_note := case when acc.finding is not null then
    format('Accepted, not fixed (R-14, %s, %s). Kept because of it: %s', to_char(acc.accepted_on, 'FMDD Mon YYYY'), acc.accepted_by, acc.rule_kept) end;

  -- ---- 1: nothing but the owner can call an internet-reaching function -------------------------
  -- Three kinds of "still open": one the SQL Editor could close (ours), one of another extension
  -- (pg_net), and the http extension's own functions belonging to someone else (R-14 as found on Supabase).
  with ext_fns as (
    select p.oid, p.proname, p.proowner, e.extname
      from pg_proc p
      join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
      join pg_extension e on e.oid = d.refobjid
     where e.extname in ('http', 'pg_net')
  ), open_to as (
    select f.oid, f.proname, f.proowner, f.extname, r as who
      from ext_fns f cross join unnest(roles) r
     where case when r = 'public'
                then exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = f.oid), acldefault('f', f.proowner))) a
                              where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                else has_function_privilege(r, f.oid, 'execute') end
  )
  select count(distinct oid) filter (where pg_get_userbyid(proowner) = current_user),
         count(distinct oid) filter (where pg_get_userbyid(proowner) <> current_user and extname <> 'http'),
         count(distinct oid) filter (where pg_get_userbyid(proowner) <> current_user and extname = 'http'),
         string_agg(distinct proname || ' (' || who || ')', ', ') filter (where pg_get_userbyid(proowner) = current_user or extname <> 'http'),
         string_agg(distinct proname || ' (' || who || ')', ', '),
         string_agg(distinct pg_get_userbyid(proowner), ', ') filter (where pg_get_userbyid(proowner) <> current_user)
    into n_ours, n_other, n_theirs, msg_new, msg, owners
    from open_to;
  if n_ours = 0 and n_other = 0 and n_theirs = 0 then
    res := res || check_row(1, 'Only the database owner can send anything to the internet (the http extension''s functions)', true);
  elsif n_ours = 0 and n_other = 0 and acc_note is not null then
    res := res || jsonb_build_array(jsonb_build_object('step', 1, 'name', 'Only the database owner can send anything to the internet (the http extension''s functions)',
      'result', 'PASS', 'msg', acc_note || format(' What is open: %s functions of the http extension, belonging to %s, which the SQL Editor can''t close. Nothing new is open.', n_theirs, owners)));
  else
    res := res || check_row(1, 'Only the database owner can send anything to the internet (the http extension''s functions)', false,
      case when n_ours > 0 or n_other > 0 then
             'Something new is open that R-14''s acceptance doesn''t cover: ' || left(msg_new, 300)
             || case when n_ours > 0 then '. Run checks_clean.sql again; if it''s still here after that, bring this line to Claude in a chat.'
                     else '. That is another extension that reaches the internet. Don''t turn a connector on; bring this line to Claude in a chat.' end
           else 'Still open: ' || left(msg, 300) || '. These belong to ' || owners
                || ', not postgres, so the SQL Editor can''t take them away, and R-14 isn''t on record as accepted. Don''t turn a connector on; bring this line to Claude in a chat.' end);
  end if;

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

    if n = m then
      res := res || check_row(2, 'No login and a signed-in login are refused when they try to reach the internet', true);
    elsif acc_note is not null and n_ours = 0 and n_other = 0 then
      -- R-14 as accepted: inside the database a role can call the extension. What has to hold instead is that
      -- nothing a PAGE can reach gets there: (a) the extension is in a schema the API doesn't serve, and
      -- (b) no function a login, or no login, may run uses it, directly or through another function.
      select string_agg(array_to_string(s.setconfig, ' | '), ' | ') into api_cfg
        from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole
       where ro.rolname = 'authenticator' and s.setdatabase in (0, (select oid from pg_database where datname = current_database()));
      api_schemas := substring(coalesce(api_cfg, '') from 'pgrst\.db_schemas=([^|]*)');
      exposed := ext_sch in ('public', 'graphql_public')
                 or (api_schemas is not null and ext_sch = any (regexp_split_to_array(replace(api_schemas, ' ', ''), ',')));
      -- every function in public that reaches the internet: it calls the http extension, or calls one that does
      select coalesce(array_agg(p.proname), '{}') into reach from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname not like 'check\_%'
         and p.prosrc ~* '\m(http|http_get|http_post|http_put|http_patch|http_delete|http_head)\s*\(';
      for k in 1 .. 4 loop
        select coalesce(array_agg(distinct p.proname), '{}') into more from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname not like 'check\_%' and not (p.proname = any (reach))
           and exists (select 1 from unnest(reach) x where p.prosrc ~* ('\m' || x || '\s*\('));
        exit when cardinality(more) = 0;
        reach := reach || more;
      end loop;
      select count(*), string_agg(p.oid::regprocedure::text, ', ') into n_reach, msg_reach from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = any (reach)
         and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
      if not exposed and n_reach = 0 then
        res := res || jsonb_build_array(jsonb_build_object('step', 2, 'name', 'No login and a signed-in login are refused when they try to reach the internet',
          'result', 'PASS', 'msg', acc_note || format(' Inside the database a role can call the extension, but nothing a page can reach does: it sits in the %s schema, which the API doesn''t serve%s, and none of the %s functions that reach the internet can be run by a login or without one.',
             ext_sch, case when api_schemas is null then ' (the API''s schema list can''t be read from here: Walkthrough 61 has you look once)' else ' (the API serves: ' || btrim(api_schemas) || ')' end,
             cardinality(reach))));
      else
        res := res || check_row(2, 'No login and a signed-in login are refused when they try to reach the internet', false,
          'Something new, which R-14''s acceptance doesn''t cover: '
          || concat_ws(' ', case when exposed then format('the http extension is in the %s schema, which the API serves, so a page could call it.', ext_sch) end,
                            case when n_reach > 0 then 'A login (or no login) may run a function that reaches the internet: ' || left(msg_reach, 300) || '.' end)
          || ' Don''t turn a connector on; bring this line to Claude in a chat.');
      end if;
    else
      res := res || check_row(2, 'No login and a signed-in login are refused when they try to reach the internet', false,
                              left(msg, 300) || '. Run checks_clean.sql again; if it''s still here after that, bring this line to Claude in a chat.');
    end if;
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

-- ---------------------------------------------------------------------
-- 6. Four checks that tripped over live data or the calendar. What each
--    tests is unchanged.
-- ---------------------------------------------------------------------

-- check_pace() (from pace.sql). Its Thursday 3 pm and Monday 9 am were worked out so that a weekend with a clock
-- change in it (1 Nov) came out an hour short. Now both are shop times, and a weekend with a clock change is skipped.
create or replace function check_pace()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res     jsonb := '[]';
  sup     uuid;  tst uuid;  mgr uuid;
  v_job   uuid;  v_job2 uuid;  v_wo uuid;  v_wo2 uuid;  v_test uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid;
  tz      constant text := 'America/Indiana/Indianapolis';
  v_thu   timestamptz;  v_mon timestamptz;
  n       numeric;  m numeric;  k int;
  ok      boolean;
  msg     text;
  v       jsonb;
  t       text;
begin
  select id into sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only) limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;

  -- ---- 1: schedules ----------------------------------------------------------
  select count(*), string_agg(format('%s %s', department, days), ', ' order by sort_order) into k, msg from v_pace_schedules;
  ok := k = (select count(*) from departments where not log_only)
        and not exists (select 1 from v_pace_schedules where department = 'delivery');
  res := res || check_row(1, 'Every counted department has working days (Delivery isn''t counted)', ok,
    format('Found %s: %s.', k, coalesce(msg, 'none')));

  -- ---- 2: working days --------------------------------------------------------
  -- a Thursday 3 pm and the Monday after at 9 am, shop time, from the week before last; if the clocks changed that
  -- weekend (it would be an hour longer or shorter than 3 days 18 hours), the weekend before that, and so on
  for k in 0 .. 3 loop
    v_thu := ((date_trunc('week', local_today()::timestamp)::date - 11 - 7 * k)::timestamp + interval '15 hours') at time zone tz;
    v_mon := ((date_trunc('week', local_today()::timestamp)::date - 7 - 7 * k)::timestamp + interval '9 hours') at time zone tz;
    exit when v_mon - v_thu = interval '90 hours';
  end loop;
  n := pace_workdays(v_thu, v_mon, array[1,2,3,4]);
  m := pace_workdays(v_thu, v_mon, array[1,2,3,4,5,6,7]);
  res := res || check_row(2, 'Working days skip days off: Thu 3 pm → Mon 9 am is 0.75 on Mon–Thu, 3.75 every day', n = 0.75 and m = 3.75,
    format('Got %s on Mon–Thu and %s every day.', n, m));

  if sup is null or mgr is null then
    res := res || check_row(3, 'A supervisor and a manager have logins', false,
      concat_ws(' ', case when sup is null then 'No real supervisor.' end, case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999975, 'PACECHECK', 'Pace check - undone automatically', true, 'In Production', local_today() + 1)
      returning id into v_job;
    insert into work_orders (job_id) values (v_job) returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 1, 2, 'PC-1', '36"', null)       returning id into s1;     -- a 36" round: 9 sq ft each
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 2, 3, 'PC-2', '30"', '30"')      returning id into s2;     -- a metal base only
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 3, 1, 'PC-3', '24"', '48"')      returning id into s3;     -- cabinet with a 24 × 48 top: 8 sq ft
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 4, 2, 'PC-4', 'TBD', null)       returning id into s4;     -- a top with no readable size
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values
      (v_wo, 5, 1, 'PC-5', null, null)        returning id into s5;     -- a cabinet, no top
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s1, 'milling', 2, 0), (s1, 'sanding', 2, 0), (s1, 'finishing', 2, 0), (s1, 'assembly_qc', 2, 0),
      (s2, 'metal', 3, 0), (s2, 'assembly_qc', 3, 0),
      (s3, 'milling', 1, 0), (s3, 'full_custom', 1, 0), (s3, 'sanding', 1, 0), (s3, 'finishing', 1, 0), (s3, 'assembly_qc', 1, 0),
      (s4, 'milling', 2, 0), (s4, 'sanding', 2, 0),
      (s5, 'full_custom', 1, 0), (s5, 'sanding', 1, 0);

    -- ---- 3: units -----------------------------------------------------------------
    select (select main_each = 9 and extra_each = 0 and not no_size from v_pace_units where sheet_id = s1 and department = 'sanding')
       and (select main_each = 9 from v_pace_units where sheet_id = s1 and department = 'assembly_qc')
       and (select main_each = 0 and extra_each = 1 from v_pace_units where sheet_id = s2 and department = 'assembly_qc')
       and (select main_each = 1 and extra_each = 0 from v_pace_units where sheet_id = s2 and department = 'metal')
       and (select main_each = 8 and extra_each = 1 from v_pace_units where sheet_id = s3 and department = 'finishing')
       and (select main_each = 8 and extra_each = 0 from v_pace_units where sheet_id = s3 and department = 'milling')
       and (select main_each = 1 from v_pace_units where sheet_id = s3 and department = 'full_custom')
       and (select main_each = 0 and no_size from v_pace_units where sheet_id = s4 and department = 'sanding')
       and (select main_each = 0 and extra_each = 1 and not no_size from v_pace_units where sheet_id = s5 and department = 'sanding')
      into ok;
    select string_agg(format('sheet %s %s: %s + %s%s', sheet_number, department, main_each, extra_each, case when no_size then ' (no size)' else '' end), '; ' order by sheet_number, department)
      into msg from v_pace_units where job_id = v_job;
    res := res || check_row(3, 'Square feet of top (a round is diameter²), cabinets in Sanding / Finishing, bases without a top in Assembly, pieces in Metal / Full Custom', coalesce(ok, false),
      'Expected 36" round = 9, 24 × 48 = 8, cabinets and bases counted beside, a top with no size flagged. Got: ' || coalesce(msg, 'nothing'));

    -- ---- 4: tablet counts only ----------------------------------------------------------
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'milling';          -- a tablet count
    perform set_config('shopfloor.source', 'Manager adjustment', true);
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'sanding';          -- Advance
    perform set_config('shopfloor.source', 'Catch-up from Monday', true);
    update sheet_progress set qty_done = 1 where sheet_id = s3 and department = 'milling';          -- catch-up
    perform set_config('shopfloor.source', '', true);
    select coalesce(sum(main) filter (where department = 'milling'), 0), coalesce(sum(main) filter (where department = 'sanding'), 0)
      into n, m from v_pace_done where job_id = v_job;
    res := res || check_row(4, 'Pace counts tablet counts only (not Advance, catch-up or uploads)', n = 18 and m = 0,
      format('Milling should show 18 sq ft (2 × 9, tablet) and Sanding 0 (Advance); got %s and %s. Catch-up on sheet 3 must not count either.', n, m));

    -- ---- 5: absolute counts ------------------------------------------------------------------
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'finishing';
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'finishing';      -- a correction down
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'finishing';
    select coalesce(sum(main), 0), count(*) into n, k from v_pace_done where job_id = v_job and department = 'finishing';
    res := res || check_row(5, 'Counts are absolute: a correction down takes back what it should', n = 18 and k = 3,
      format('2 → 1 → 2 on a 9 sq ft round should total 18 sq ft over 3 counts; got %s over %s.', n, k));

    -- ---- 6: time in stage ---------------------------------------------------------------------
    -- Finishing had its first piece on a Thursday at 3 pm; Assembly started Monday 9 am, finished Monday 9 pm (Mon–Thu)
    update progress_events set occurred_at = v_thu where sheet_id = s1 and department = 'finishing';
    update sheet_progress set qty_done = 1 where sheet_id = s1 and department = 'assembly_qc';
    update progress_events set occurred_at = v_mon where sheet_id = s1 and department = 'assembly_qc' and qty_to = 1;
    update sheet_progress set qty_done = 2 where sheet_id = s1 and department = 'assembly_qc';
    update progress_events set occurred_at = v_mon + interval '12 hours' where sheet_id = s1 and department = 'assembly_qc' and qty_to = 2;
    select wait_days, work_days into n, m from v_pace_times where sheet_id = s1 and department = 'assembly_qc';
    select work_days is null into ok from v_pace_times where sheet_id = s1 and department = 'milling';      -- counted in one go
    res := res || check_row(6, 'Wait to start and working time, in the department''s working days (a sheet counted in one go has no working time)', n = 0.75 and m = 0.5 and coalesce(ok, false),
      format('Expected a wait of 0.75 (Thu 3 pm → Mon 9 am, Mon–Thu) and 0.5 working (Mon 9 am → 9 pm); got %s and %s. Milling, entered all at once, should have no working time: %s.', coalesce(n::text, 'none'), coalesce(m::text, 'none'), case when ok then 'right' else 'it had one' end));

    -- ---- 7: started outside the tablet --------------------------------------------------------
    perform set_config('shopfloor.source', 'Catch-up from Monday', true);
    update sheet_progress set qty_done = 1 where sheet_id = s4 and department = 'milling';
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = 2 where sheet_id = s4 and department = 'milling';
    select started_outside and wait_days is null and work_days is null into ok from v_pace_times where sheet_id = s4 and department = 'milling';
    select ok and (select wait_days is not null from v_pace_times where sheet_id = s1 and department = 'milling') into ok;
    res := res || check_row(7, 'A sheet started by catch-up, Advance or a carried-over count is left out of time in stage', coalesce(ok, false),
      'Sheet 4 (catch-up first) should have no times; sheet 1 (tablet first) should.');

    -- ---- 8: test jobs ------------------------------------------------------------------------------
    if tst is null then
      res := res || check_row(8, 'Test jobs are left out', false, 'No Test Supervisor login to test with.');
    else
      v := make_test_job('PACECHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      update sheet_progress sp set qty_done = sp.qty_required from sheets s join work_orders w on w.id = s.work_order_id
       where sp.sheet_id = s.id and w.job_id = v_test;
      select (select count(*) from v_pace_done where job_id = v_test) + (select count(*) from v_pace_units where job_id = v_test) into k;
      res := res || check_row(8, 'Test jobs are left out', k = 0, format('%s test-job rows reached pace.', k));
    end if;

    -- ---- 9: the report ------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      v := pace_report(4);
      execute 'reset role';
      ok := false; msg := 'A supervisor opened the pace report. Only managers should.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    if ok then
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v := pace_report(4);
        execute 'reset role';
        ok := jsonb_array_length(v->'departments') = (select count(*) from departments where not log_only)
              and (select bool_and(x ? 'pace' and x ? 'ready' and x ? 'weekly' and jsonb_array_length(x->'weekly') = 9)
                     from jsonb_array_elements(v->'departments') x)
              and (select (x->>'this_week')::numeric >= 18 from jsonb_array_elements(v->'departments') x where x->>'key' = 'milling');
        msg := 'The manager''s report should list every counted department with pace, ready and 9 weeks of bars, and include this week''s 18 sq ft in Milling.';
      exception when others then execute 'reset role'; ok := false; msg := 'Error for a manager: ' || sqlerrm;
      end;
    end if;
    res := res || check_row(9, 'Managers get the report; supervisors are refused', coalesce(ok, false), msg);

    -- ---- 10: supervisors can't change working days -------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    k := 0; msg := null;
    begin
      execute 'set local role authenticated';
      t := set_pace_schedule('milling', array[1,2,3,4,5]);
      execute 'reset role';
      msg := 'A supervisor changed Milling''s days.';
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := 'Unexpected error: ' || sqlerrm;
    end;
    begin
      execute 'set local role authenticated';
      insert into pace_schedules (department, days, set_by_name) values ('milling', array[1], 'sneaky');
      execute 'reset role';
      msg := concat_ws(' ', msg, 'A supervisor wrote to pace_schedules directly.');
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := concat_ws(' ', msg, 'Unexpected error: ' || sqlerrm);
    end;
    foreach t in array array['v_pace_units', 'v_pace_done', 'v_pace_times', 'v_pace_backlog', 'v_pace_schedules', 'pace_schedules'] loop
      begin
        execute 'set local role authenticated';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        msg := concat_ws(' ', msg, format('A supervisor read %s.', t));
      exception when insufficient_privilege then execute 'reset role'; k := k + 1;
      when others then execute 'reset role'; msg := concat_ws(' ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(10, 'A supervisor can''t change working days, write the table, or read the working views', k = 8,
      coalesce(msg, format('%s of 8 refused.', k)));

    -- ---- 11: a manager changes one; history kept; bad input refused ---------------------------------
    select count(*) into k from pace_schedules where department = 'metal';
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      t := set_pace_schedule('metal', array[4,1,2,3,5]);
      msg := set_pace_schedule('metal', array[1,2,3,4,5]);
      execute 'reset role';
      ok := msg like '%Nothing changed%'
            and (select days from v_pace_schedules where department = 'metal') = array[1,2,3,4,5]
            and (select count(*) from pace_schedules where department = 'metal') = k + 1
            and (select set_by_name from v_pace_schedules where department = 'metal') = (select full_name from profiles where id = mgr);
      msg := 'Metal should now be Mon–Fri, one new row kept with the manager''s name, and the same again should change nothing.';
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    k := 0;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', '{}');          execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', array[0,1]);    execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', array[8]);      execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('metal', null);          execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    begin execute 'set local role authenticated'; t := set_pace_schedule('delivery', array[1]);   execute 'reset role'; exception when others then execute 'reset role'; k := k + 1; end;
    res := res || check_row(11, 'A manager changes working days (every change kept); no days, bad days and Delivery are refused', coalesce(ok, false) and k = 5,
      concat_ws(' ', case when not coalesce(ok, false) then msg end, case when k < 5 then format('Only %s of 5 bad changes were refused.', k) end));

    -- ---- 12: queue order and when it clears ------------------------------------------------------------
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999974, 'PACECHECK2', 'Pace check - undone automatically', true, 'In Production', local_today() + 2)
      returning id into v_job2;
    insert into work_orders (job_id) values (v_job2) returning id into v_wo2;
    insert into sheets (work_order_id, sheet_number, qty, item_code, width, length) values (v_wo2, 1, 4, 'PC-6', '30"', '60"') returning id into s6;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s6, 'sanding', 4, 0);
    select (select ahead_main from v_pace_backlog where job_id = v_job2 and department = 'sanding')
         - (select ahead_main from v_pace_backlog where job_id = v_job and department = 'sanding') into n;
    ok := n = 50 and pace_clears_on(100, 50) = local_today() + 14 and pace_clears_on(1, 0) is null;
    res := res || check_row(12, 'The queue runs in delivery-date order, and clears at the weekly pace in calendar days', coalesce(ok, false),
      format('The later job should add its own 50 sq ft (4 × 30 × 60) to the queue ahead of it; it added %s. 100 sq ft at 50 a week should clear in 14 days.', coalesce(n::text, 'nothing')));

    -- ---- 13: no login ------------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    k := 0; msg := null;
    begin
      execute 'set local role anon';
      v := pace_report(4);
      execute 'reset role';
      msg := 'The report opened with no login.';
    exception when insufficient_privilege then execute 'reset role'; k := k + 1;
    when others then execute 'reset role'; msg := 'Report: ' || sqlerrm;
    end;
    foreach t in array array['pace_schedules', 'v_pace_schedules', 'v_pace_units', 'v_pace_done', 'v_pace_times', 'v_pace_backlog'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        msg := concat_ws(' ', msg, format('%s rows of %s visible.', m, t));
      exception when insufficient_privilege then execute 'reset role'; k := k + 1;
      when others then execute 'reset role'; msg := concat_ws(' ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(13, 'Someone with no login gets none of it', k = 7,
      coalesce(msg, '') || ' Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_pace_undo__';
  exception when others then
    if sqlerrm <> '__check_pace_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('shopfloor.source', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_pace() from public, anon, authenticated;

-- check_incomplete_deliveries() (from incomplete_deliveries.sql). "Another department's supervisor" is now one with a
-- department of their own, never a sales look-up login; and an answer of "not finished" with nothing saved counts as refused.
create or replace function check_incomplete_deliveries()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  mgr uuid; sch uuid; dlv uuid; oth uuid;
  ja uuid; wo uuid; s1 uuid; s2 uuid;
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid();
  f1 uuid := gen_random_uuid(); f2 uuid := gen_random_uuid(); f3 uuid := gen_random_uuid(); f4 uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r3 uuid := gen_random_uuid(); r4 uuid := gen_random_uuid(); tk uuid := gen_random_uuid();
  r jsonb; n int; m int; k int; ok boolean; msg text; v_lo loadouts; v_rs loadouts; v_tp trip_parts; j jsonb; t1 text; t2 text;
begin
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select coalesce((select id from profiles where schedules_deliveries and active and not is_test and role = 'supervisor' order by full_name limit 1), mgr) into sch;
  select id into dlv from profiles where role = 'supervisor' and active and not is_test and 'delivery' = any(departments) and not schedules_deliveries order by full_name limit 1;
  select p.id into oth from profiles p where p.role = 'supervisor' and p.active and not p.is_test and not ('delivery' = any(p.departments)) and not p.schedules_deliveries
     and not coalesce(p.look_up, false)                                                        -- never a sales look-up login
     and exists (select 1 from departments d where d.key = any(p.departments) and not d.log_only)
   order by p.full_name limit 1;
  if mgr is null or dlv is null or oth is null then
    res := res || check_row(1, 'A manager, a Delivery login and another supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  -- ---- 1: the tables are locked down; the new functions need a login ----------------------------------------
  ok := has_table_privilege('authenticated', 'public.trip_parts', 'select')
        and not has_table_privilege('authenticated', 'public.trip_parts', 'insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('anon', 'public.trip_parts', 'select,insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('authenticated', 'public.part_extras', 'select,insert,update,delete,truncate,references,trigger')
        and not has_table_privilege('anon', 'public.part_extras', 'select,insert,update,delete,truncate,references,trigger')
        and (select relrowsecurity from pg_class where oid = 'public.trip_parts'::regclass)
        and (select relrowsecurity from pg_class where oid = 'public.part_extras'::regclass)
        and not has_function_privilege('anon', 'public.complete_trip_part(uuid,uuid,uuid,text[],text[],jsonb,text,text,text,text,text,text,timestamptz,double precision,double precision,double precision)', 'execute')
        and not has_function_privilege('anon', 'public.schedule_rest(uuid,text,timestamptz,text)', 'execute')
        and not has_function_privilege('anon', 'public.cancel_rest(uuid,text)', 'execute')
        and not has_function_privilege('anon', 'public.trip_chain(uuid)', 'execute')
        and not has_table_privilege('anon', 'public.v_rest_waiting', 'select');
  res := res || check_row(1, 'No login writes trip_parts or part_extras, nobody without a login reads them, and the new functions need a login', ok,
                          case when ok then null else 'A grant is wrong. Bring this line to Claude in a chat.' end);

  begin    -- everything below is undone at the end, whatever happens
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999461, 'IDCHECK-A', 'Incomplete deliveries check - undone automatically', true, 'In Production') returning id into ja;
    insert into work_orders (job_id, version, is_current) values (ja, 1, true) returning id into wo;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (wo, 1, 2, 'idcheck-1') returning id into s1;
    insert into sheets (work_order_id, sheet_number, qty, spec_hash) values (wo, 2, 3, 'idcheck-2') returning id into s2;
    insert into sheet_extras (sheet_id, position, name, qty) values (s2, 1, 'Data port', 4);
    set constraints all immediate;

    -- a white glove delivery set up by the delivery manager, with a ticket; Delivery loads all 4 data ports
    perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform schedule_delivery(ja, now() + interval '1 day', 'Check', null, c1, 'delivery');
    perform schedule_delivery(ja, now() + interval '2 days', 'Check', null, c2, 'delivery');
    perform schedule_pickup(ja, 'customer_pickup', null, null, c3);
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, is_test, added_by_name)
    select tk, l.id, ja, 'ticket', 'Ticket.pdf', 'IDCHECK-A/' || c1 || '/' || tk || '.pdf', 'application/pdf', 10, false, 'Check'
      from loadouts l where l.client_id = c1;
    insert into storage.objects (bucket_id, name, metadata) values ('deliveries', 'IDCHECK-A/' || c1 || '/' || f1 || '.png', '{"size": "10", "mimetype": "image/png"}');
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform set_extra_loaded(c1, 2, 'Data port', 4, null);
    execute 'reset role';

    -- ---- 2: Delivery finishes it part-way, signed: the rest is a new trip waiting for a day --------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f1, c1, r1, '{1:1,1:2,2:1}', '{2:2,2:3}', '[{"sheet": 2, "name": "Data port", "went": 3}]',
                              'Site not ready', 'Reading room not carpeted', 'Pat Lee', null, null, null, now(), null, null, null);
      execute 'reset role';
      select * into v_lo from loadouts where client_id = c1;
      select * into v_rs from loadouts where client_id = r1;
      select * into v_tp from trip_parts where loadout_id = v_lo.id;
      select went into n from part_extras where loadout_id = v_lo.id and name = 'Data port';
      ok := v_lo.completed_at is not null and v_lo.signed_name = 'Pat Lee'
            and v_tp.rest_id = v_rs.id and v_tp.went_pieces = '{1:1,1:2,2:1}' and v_tp.left_pieces = '{2:2,2:3}'
            and v_tp.reason = 'Site not ready' and v_tp.extras_left = 1 and n = 3
            and v_rs.kind = 'delivery' and v_rs.job_id = ja and v_rs.scheduled_for is null and v_rs.ready_at is null
            and v_rs.completed_at is null and v_rs.voided_at is null;
      msg := coalesce(r->>'summary', 'nothing') || format(' · rest kind %s, extras left %s, data ports went %s', v_rs.kind, v_tp.extras_left, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(2, 'Delivery finishes a trip part-way, signed: what went, what didn''t and why are kept, and the rest is a new trip waiting for a day', ok, msg);

    -- ---- 3: a resend changes nothing ---------------------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f1, c1, gen_random_uuid(), '{1:1,1:2,2:1}', '{2:2,2:3}', '[]', 'Site not ready', null, 'Pat Lee');
      execute 'reset role';
      select count(*) into n from loadouts where job_id = ja;
      ok := coalesce((r->>'already')::boolean, false) and n = 4 and (r->>'rest_id')::uuid = v_rs.id;
      msg := format('already %s, %s trips on the job (4 expected)', r->>'already', n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'Sending it again (no signal, then signal) changes nothing and makes no second rest', ok, msg);

    -- ---- 4: what each login sees while the rest waits ------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      select count(*), min(owed::text), min(ticket->>'inherited') into n, msg, t1 from v_rest_waiting where client_id = r1;
      select count(*) into m from v_loadouts where client_id = r1;
      select count(*) into k from v_deliveries where client_id = r1;
      select part into j from v_deliveries where client_id = c1;
      execute 'reset role';
      ok := n = 1 and msg = '{2:2,2:3}' and t1 = 'true' and m = 0 and k = 0
            and (j->>'went')::int = 3 and (j->>'left')::int = 2 and (j->>'rest_client_id')::uuid = r1 and j->>'reason' = 'Site not ready';
      msg := format('Delivery: waiting %s (owed %s, ticket inherited %s), on the trip list %s, on the delivery list %s, the trip says went %s left %s',
                    n, msg, t1, m, k, j->>'went', j->>'left');
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from v_rest_waiting where client_id = r1;
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into m from v_rest_waiting;
      select count(*) into k from trip_parts;
      execute 'reset role';
      ok := ok and n = 1 and m = 0 and k = 0;
      msg := msg || format(' · the delivery manager sees it %s; another supervisor sees %s waiting and %s trip_parts rows', n, m, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'The rest waits for a day where Delivery and the delivery manager see it, off the trip lists, with the ticket; nobody else sees it', ok, msg);

    -- ---- 5: what's refused, with nothing saved -------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform set_extra_loaded(c2, 2, 'Data port', 1, null);
    execute 'reset role';
    n := 0; msg := '';
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Too busy', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a reason not on the list was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Other', '  ', null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'Other with no words was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{3:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a table not on the job was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a table both gone and not was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1,1:2,2:1,2:2,2:3}', '{}', '[{"sheet": 2, "name": "Data port", "went": 1}]',
                              'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'a part delivery with nothing left was accepted; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[{"sheet": 2, "name": "Data port", "went": 2}]',
                              'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role'; msg := msg || 'more data ports went than were loaded; ';
    exception when others then execute 'reset role'; n := n + 1; end;
    perform set_config('request.jwt.claims', json_build_object('sub', oth, 'role', 'authenticated')::text, true);
    begin execute 'set local role authenticated';
      r := complete_trip_part(f2, c2, gen_random_uuid(), '{1:1}', '{1:2}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role';
      if coalesce((r ->> 'ok')::boolean, false) then msg := msg || 'another department''s supervisor finished it; ';
      else n := n + 1; end if;                                  -- answered "not finished" (a login that can't see the trip): refused; nothing saved is proved below
    exception when others then execute 'reset role'; n := n + 1; end;
    select count(*) into m from loadouts where job_id = ja;
    select count(*) into k from trip_parts tp join loadouts l on l.id = tp.loadout_id where l.client_id = c2;
    ok := n = 7 and m = 4 and k = 0 and (select completed_at is null from loadouts where client_id = c2);
    res := res || check_row(5, 'Refused, with nothing saved: a reason not on the list, Other with no words, a table not on the trip or on it twice, nothing left, more extras than loaded, another department', ok,
                            case when ok then null else msg || format('%s of 7 refused, %s trips (4 expected), %s parts on the second trip', n, m, k) end);

    -- ---- 6: the delivery manager gives the rest a day (and changes how it goes); Delivery can't -------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    n := 0;
    begin execute 'set local role authenticated'; r := schedule_rest(r1, 'delivery', now() + interval '3 days', null); execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated'; r := cancel_rest(r1, null); execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := schedule_rest(r1, 'dock', now() + interval '3 days', 'The rest');
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into m from v_rest_waiting where client_id = r1;
      select owed::text, rest->>'of_client_id', ticket->>'inherited' into msg, t1, t2 from v_deliveries where client_id = r1 and kind = 'dock' and scheduled_for is not null;
      select count(*) into k from v_loadouts where client_id = r1 and owed = '{2:2,2:3}';
      execute 'reset role';
      ok := n = 2 and m = 0 and msg = '{2:2,2:3}' and t1::uuid = c1 and t2 = 'true' and k = 1;
      msg := format('Delivery refused %s of 2; waiting now %s; on the delivery list with owed %s, the rest of %s, ticket inherited %s; on the trip list %s',
                    n, m, msg, case when t1::uuid = c1 then 'the first trip' else coalesce(t1, 'nothing') end, t2, k);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'The delivery manager gives the rest a day and can make it dock to dock; then it''s on the lists with only its own tables and the ticket; Delivery can''t', ok, msg);

    -- ---- 7: a rest finished part-way: only its own tables, every one of them --------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    n := 0;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, gen_random_uuid(), '{2:2}', '{}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, gen_random_uuid(), '{2:2}', '{1:1}', '[]', 'Damaged', null, null, null, 'Nobody on site');
      execute 'reset role';
    exception when others then execute 'reset role'; n := n + 1; end;
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f3, r1, r3, '{2:2}', '{2:3}', '[]', 'Damaged', 'Scratched top', null, null, 'Nobody on site', 'Left at the dock');
      select count(*), min(owed::text), min(ticket->>'name') into m, msg, t1 from v_rest_waiting where client_id = r3 and kind = 'dock';
      execute 'reset role';
      ok := n = 2 and m = 1 and msg = '{2:3}' and t1 = 'Ticket.pdf' and (select completed_at is not null from loadouts where client_id = r1);
      msg := format('refused %s of 2; the rest of the rest waiting %s with owed %s and ticket %s', n, m, msg, coalesce(t1, 'none'));
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'A rest finished part-way again: every table on it, and only those, gone or not; its rest keeps the first trip''s ticket', ok, msg);

    -- ---- 8: a pickup's rest goes straight back on Ready for pickup ----------------------------------------------------
    begin
      execute 'set local role authenticated';
      r := complete_trip_part(f4, c3, r4, '{1:1}', '{1:2}', '[]', 'Wouldn''t fit', null, null, null, 'Customer refused');
      select count(*) into n from v_deliveries where client_id = r4 and kind = 'customer_pickup' and ready_at is not null and owed = '{1:2}';
      select count(*) into m from v_rest_waiting where client_id = r4;
      execute 'reset role';
      ok := n = 1 and m = 0 and (select completed_at is not null from loadouts where client_id = c3);
      msg := coalesce(r->>'summary', 'nothing') || format(' · on Ready for pickup %s, waiting for a day %s', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A customer pickup finished part-way: its rest is back on Ready for pickup at once, no day needed', ok, msg);

    -- ---- 9: the delivery manager takes a waiting rest off; it's kept ----------------------------------------------------
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', sch, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := cancel_rest(r3, null);
      j := cancel_rest(r3, null);
      select count(*) into n from v_rest_waiting where client_id = r3;
      execute 'reset role';
      ok := n = 0 and coalesce((j->>'already')::boolean, false) and (select voided_at is not null and void_reason = 'Not needed' from loadouts where client_id = r3);
      msg := coalesce(r->>'summary', 'nothing') || format(' · still waiting %s; again: %s', n, j->>'summary');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(9, 'The delivery manager takes a rest off; it''s kept in history, and doing it twice is fine', ok, msg);

    -- ---- 10: extras: Delivery reads how many went; nobody reads part_extras itself --------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', dlv, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select went, loaded into n, m from v_loadout_extras where client_id = c1 and name = 'Data port';
      execute 'reset role';
      ok := n = 3 and m = 4; msg := format('went %s of %s loaded', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    begin
      execute 'set local role authenticated';
      select count(*) into k from part_extras;
      execute 'reset role';
      ok := false; msg := msg || ' · part_extras was readable directly';
    exception when others then execute 'reset role';
    end;
    res := res || check_row(10, 'Delivery sees how many of each extra went; the table itself can''t be read directly', ok, msg);

    raise exception using errcode = 'P0001', message = '__check_incomplete_deliveries_undo__';
  exception when others then
    if sqlerrm <> '__check_incomplete_deliveries_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end;
$$;
revoke all on function check_incomplete_deliveries() from public, anon, authenticated;

-- check_onedrive_save() (from onedrive_save.sql). Step 3 pretends the last good save was 8 days ago; a real good save
-- since then made it fail. Real saves are now set 30 days back for the length of the check (undone at the end, like everything in it).
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
                          'Bring this line to Claude in a chat.');
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
      update save_runs set finished_at = finished_at - interval '30 days', started_at = started_at - interval '30 days'
       where client_id is distinct from c1 and client_id is distinct from c2;                     -- the office's real saves, out of the way
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

-- check_inventory() (from inventory.sql). Step 7 did its arithmetic on the live Maple 6/4 in the live month, so a month
-- with no opening count for it failed. It now uses a lumber item, an opening count and a delivery slip of its own.
create or replace function check_inventory()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]';
  metal_sup uuid; other_sup uuid; tst uuid; mgr uuid;
  v_month date; v_first date; v_job uuid; v_pre uuid; v_wo uuid; v_pwo uuid; v_test uuid;
  s_rnd uuid; s_rect uuid; s_odd uuid; s_new uuid; s_start uuid; s_pre_started uuid; s_pre_new uuid;
  it_maple uuid; it_steel uuid; it_ply uuid; v_rec uuid;
  it_chk uuid; v_prev date;
  a numeric; b numeric; c numeric; d numeric;
  n int; m int; ok boolean; msg text; v jsonb; t text; r record;
begin
  select p.id into metal_sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test and 'metal' = any(p.departments) limit 1;
  select p.id into other_sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test
     and not ('full_custom' = any(p.departments)) and not ('metal' = any(p.departments)) and cardinality(p.departments) > 0 limit 1;
  select id into tst from profiles where is_test and role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active limit 1;
  select first_month_end into v_first from inv_settings where id = 1;

  -- ---- 1: lists and the starting count ---------------------------------------
  select count(*) into n from inv_lists;
  select count(*) into m from inv_items where list_key = 'lumber';
  select coalesce(sum(board_feet), 0) into a from v_inv_lumber_close where month_end = '2026-08-31';
  select coalesce(sum(c.qty), 0) into b from inv_counts c join inv_items i on i.id = c.item_id where c.month_end = '2026-08-31' and i.list_key = 'plywood';
  ok := n = 5 and m >= 20 and abs(a - 36440.2) < 1 and b = 207;
  res := res || check_row(1, 'Five count lists, and the 31 Aug count is loaded (36,440 bd ft of lumber, 207 sheets of plywood)', ok,
    format('Found %s lists, %s lumber items, %s bd ft and %s plywood sheets at 31 Aug. Bring this line to Claude in a chat.', n, m, round(a), b));

  -- ---- 2: sizes are read the way work orders write them -------------------------
  ok := inv_inches('36"') = 36 and inv_inches('30 1/2"') = 30.5 and inv_inches('30-1/2"') = 30.5 and inv_inches('1.25"') = 1.25
        and inv_inches('1 1/4') = 1.25 and inv_inches('3/4"') = 0.75 and inv_inches('36 in') = 36 and inv_inches('about 3 ft') is null;
  res := res || check_row(2, 'Sizes are read from the work order: 36"  30 1/2"  30-1/2"  1.25"  1 1/4  3/4"', ok,
    'One of the sizes was read wrongly.');

  if metal_sup is null or mgr is null or other_sup is null then
    res := res || check_row(3, 'A Metal supervisor, another supervisor and a manager have logins', false,
      concat_ws(' ', case when metal_sup is null then 'No real Metal supervisor.' end, case when other_sup is null then 'No other supervisor.' end,
                case when mgr is null then 'No manager.' end));
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;

  begin    -- everything below is undone at the end, whatever happens
    v_month := inv_current_month();
    insert into inv_months (month_end) values (v_month) on conflict do nothing;
    select id into it_maple from inv_items where list_key = 'lumber' and species = 'Maple' and stock = '6/4';
    select id into it_steel from inv_items where list_key = 'metal' and std_length_ft = 24 and not retired order by sort_order limit 1;

    -- a job uploaded this month: a round, a rectangle, an odd thickness, one not started, one started
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999975, 'INVCHECK', 'Inventory check - undone automatically', true, 'In Production', v_month + 40) returning id into v_job;
    insert into work_orders (job_id, created_at) values (v_job, (v_month - 20)::timestamp at time zone 'America/Indiana/Indianapolis') returning id into v_wo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 1, 2, 'IC-1', 'Checkwood Maple', 'Round', '36"', null, '1.25"') returning id into s_rnd;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 2, 3, 'IC-2', 'Checkwood Maple', 'Rectangle', '30"', '60"', '1.5"') returning id into s_rect;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 3, 1, 'IC-3', 'Checkwood Maple', 'Rectangle', '30"', '48"', '1.9"') returning id into s_odd;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 4, 4, 'IC-4', 'Checkwood Maple', 'Rectangle', '24"', '48"', '1.25"') returning id into s_new;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_wo, 5, 2, 'IC-5', 'Checkwood Maple', 'Rectangle', '24"', '24"', '1.25"') returning id into s_start;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values
      (s_rnd, 'milling', 2, 2), (s_rect, 'milling', 3, 3), (s_odd, 'milling', 1, 1), (s_new, 'milling', 4, 0), (s_start, 'milling', 2, 1);
    -- a job uploaded before the first month: one sheet Milling started back then, one it hadn't
    insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
      values (-999974, 'INVCHECK-PRE', 'Inventory check', true, 'In Production', v_month + 40) returning id into v_pre;
    insert into work_orders (job_id, created_at) values (v_pre, (v_first - 70)::timestamp at time zone 'America/Indiana/Indianapolis') returning id into v_pwo;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_pwo, 1, 1, 'IP-1', 'Checkwood Maple', 'Rectangle', '30"', '30"', '1.25"') returning id into s_pre_started;
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, shape, width, length, thickness)
      values (v_pwo, 2, 1, 'IP-2', 'Checkwood Maple', 'Rectangle', '30"', '30"', '1.25"') returning id into s_pre_new;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s_pre_started, 'milling', 1, 1), (s_pre_new, 'milling', 1, 0);
    update sheet_progress set started_at = (v_first - 60)::timestamp at time zone 'America/Indiana/Indianapolis' where sheet_id = s_pre_started;

    -- ---- 3: 0-scrap at full rectangle x stock thickness ---------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) filter (where problem like '%isn''t matched%') into n from v_inv_pool where job_id = v_job;
      v := set_species_match('Checkwood Maple', 'Maple', false);
      select board_feet, stock into a, t from v_inv_pool where sheet_id = s_rnd;
      select board_feet into b from v_inv_pool where sheet_id = s_rect;
      execute 'reset role';
      ok := n = 4 and a = 27 and t = '6/4' and b = 75;
      msg := format('A 36" round at 1.25" (2 tops) should be 36×36×1.5 = 27 bd ft of 6/4, and 30×60 at 1.5" (3 tops) 75 bd ft of 8/4; got %s (%s) and %s. Unmatched before the match: %s of 4.', a, t, b, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(3, 'A top''s 0-scrap is its full rectangle × stock thickness (a round is diameter × diameter); unknown species wait for a match', coalesce(ok, false), msg);

    -- ---- 4: a thickness with no rule waits; a rule fixes it; overlaps are refused ----
    begin
      execute 'set local role authenticated';
      select problem into t from v_inv_pool where sheet_id = s_odd;
      v := add_thickness_rule(1.9, 1.9, '8/4');
      select board_feet into a from v_inv_pool where sheet_id = s_odd;
      begin v := add_thickness_rule(1.2, 1.3, '6/4'); n := 0; exception when others then n := 1; end;
      execute 'reset role';
      ok := t like 'No stock size%' and a = 20 and n = 1;
      msg := format('1.9" should first say "No stock size", then count 30×48×2 = 20 bd ft after the rule, and an overlapping rule should be refused. Got "%s", %s, refused %s.', t, a, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(4, 'A thickness with no rule is flagged, not guessed; adding a rule counts it; overlapping rules are refused', coalesce(ok, false), msg);

    -- ---- 5: which sheets are on the month's list ----------------------------------
    begin
      execute 'set local role authenticated';
      v := make_test_job('INVCHECK');
      select id into v_test from jobs where project_id = v->>'project_id';
      select count(*) filter (where job_id = v_job), count(*) filter (where sheet_id = s_pre_started), count(*) filter (where sheet_id = s_pre_new),
             count(*) filter (where job_id = v_test)
        into n, m, a, b from v_inv_pool;
      execute 'reset role';
      ok := n = 5 and m = 0 and a = 1 and b = 0;
      msg := format('Expected the 5 sheets uploaded this month, the older sheet Milling hadn''t started, and not the older started one or the test copy; got %s, %s, %s, %s.', n, a, m, b);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'The month''s list: this month''s uploads and rolled-over sheets; not test jobs, not sheets started before the first month', coalesce(ok, false), msg);

    -- ---- 6: roll-over ----------------------------------------------------------------
    begin
      execute 'set local role authenticated';
      select zero_bf into a from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      v := set_rollover(v_job, 4, true);
      select zero_bf into b from v_inv_scrap where month_end = v_month and species = 'Maple' and stock = '6/4';
      begin v := set_rollover(v_job, 5, true); n := 0; exception when others then n := 1; end;
      execute 'reset role';
      ok := a - b = 48 and n = 1;
      msg := format('Rolling over the unstarted 24×48 sheet (4 tops, 48 bd ft) should take 48 off 0-scrap (took %s), and a sheet with pieces counted can''t roll (refused: %s).', a - b, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'A rolled-over sheet leaves this month''s 0-scrap; a sheet Milling has counted can''t roll over', coalesce(ok, false), msg);

    -- ---- 7: the arithmetic, on the check's own lumber with its own opening count (never a live item) ----
    begin
      v_prev := (date_trunc('month', v_month::timestamp) - interval '1 day')::date;
      insert into inv_items (list_key, name, species, stock, sort_order) values ('lumber', 'Zz Checkwood 6/4 (check)', 'Zz Checkwood', '6/4', 99999) returning id into it_chk;
      insert into inv_months (month_end, status) values (v_prev, 'closed') on conflict (month_end) do update set status = 'closed';
      insert into inv_lumber_lines (month_end, item_id, length_in, width_in, bundles) values (v_prev, it_chk, 120, 42, array[20]);   -- 20 rows × 120 × 42 × 1.5 / 144 = 1,050 bd ft to open with
      execute 'set local role authenticated';
      v := set_species_match('Checkwood Maple', 'Zz Checkwood', false);     -- the check's own tops now count against its own lumber
      v := add_inventory_receipt('lumber', least(local_today(), v_month), 'Check supplier', it_chk, 100, null, null, null);
      v_rec := (v->>'id')::uuid;
      v := set_lumber_line(it_chk, 479, array[1, 2.25], 42);             -- 3.25 rows × 479 × 42 × 1.5 / 144 = 681.1 bd ft
      select r2.* into r from v_inv_scrap r2 where r2.month_end = v_month and r2.species = 'Zz Checkwood' and r2.stock = '6/4';
      execute 'reset role';
      ok := r.opening_bf = 1050 and r.received_bf = 100 and abs(r.closing_bf - 681.078) < 0.01 and abs(r.used_bf - 468.922) < 0.01
            and r.used_bf = r.opening_bf + r.received_bf - r.closing_bf and r.zero_bf > 0 and r.scrap_bf = r.used_bf - r.zero_bf
            and r.scrap_rate is not null and abs(r.scrap_rate - r.scrap_bf / r.used_bf) < 0.0001;
      msg := format('The check''s own lumber: opening %s (1,050 expected) + received %s (100) − closing %s (681.08) should be used %s (468.92); 0-scrap %s; scrap %s; rate %s.', r.opening_bf, r.received_bf, r.closing_bf, r.used_bf, r.zero_bf, r.scrap_bf, r.scrap_rate);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Used = last count + received − this count; scrap = used − 0-scrap; rate = scrap ÷ used', coalesce(ok, false), msg);

    -- ---- 8: a slip entered by mistake stops counting and stays on record --------------
    begin
      execute 'set local role authenticated';
      select received_bf into a from v_inv_scrap where month_end = v_month and species = 'Zz Checkwood' and stock = '6/4';
      v := mark_receipt_mistake(v_rec);
      select received_bf into b from v_inv_scrap where month_end = v_month and species = 'Zz Checkwood' and stock = '6/4';
      execute 'reset role';
      ok := a - b = 100 and exists (select 1 from inv_receipts where id = v_rec and mistake_at is not null);
      msg := format('Received went %s → %s; it should drop by 100 and the slip should still be there.', a, b);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A delivery slip marked "Entered by mistake" stops counting but stays on record', coalesce(ok, false), msg);

    -- ---- 9–11: the Metal tablet (on a pretend count day, undone straight after) --------
    begin
      insert into inv_months (month_end) values ('2000-01-31');              -- the earliest open month: its count day has passed
      perform set_config('request.jwt.claims', json_build_object('sub', metal_sup, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        select count(*) into n from v_inv_tablet_lists where list_key = 'metal' and open_now;
        v := send_inventory_count('metal', jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 5, 'loose_ft', 7)), gen_random_uuid());
        select qty into a from v_inv_tablet_items where item_id = it_steel;
        select count(*) filter (where qty = 0), count(*) into m, c from v_inv_tablet_items where list_key = 'metal';
        begin v := send_inventory_count('metal', '[]', gen_random_uuid()); b := 0; exception when others then b := 1; end;
        v := reopen_inventory_count('metal');
        v := send_inventory_count('metal', jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 1, 'loose_ft', 0)), gen_random_uuid());
        select qty into d from v_inv_tablet_items where item_id = it_steel;
        execute 'reset role';
        ok := n = 1 and a = 5 * 24 + 7 and m = c - 1 and b = 1 and d = 24;
        msg := format('Metal''s list open: %s. 5 sticks + 7 ft of a 24'' item should be 127 ft (got %s); the other %s items 0 (got %s); a second send refused (%s); after "Change the count", 1 stick = 24 (got %s).', n, a, c - 1, m, b, d);
      exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
      end;
      res := res || check_row(9, 'Metal sends its count: sticks become feet, blanks count as 0, one send until "Change the count"', coalesce(ok, false), msg);

      -- 10: another department, prices, direct writes, office functions
      n := 0; msg := null;
      begin
        execute 'set local role authenticated';
        begin v := send_inventory_count('plywood', '[]', null); msg := concat_ws(', ', msg, 'sent Full Custom''s plywood count'); exception when insufficient_privilege then n := n + 1; end;
        select count(*) into m from inv_prices;  if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, format('read %s prices', m)); end if;
        select count(*) into m from v_inv_values; if m = 0 then n := n + 1; else msg := concat_ws(', ', msg, 'read values'); end if;
        begin insert into inv_counts (month_end, item_id, qty, counted_by_name) values ('2000-01-31', it_steel, 1, 'x'); msg := concat_ws(', ', msg, 'wrote a count directly');
        exception when insufficient_privilege then n := n + 1; end;
        begin v := set_lumber_line(it_maple, 100, array[1], 42); msg := concat_ws(', ', msg, 'entered lumber'); exception when insufficient_privilege then n := n + 1; end;
        begin v := add_inventory_receipt('plywood', local_today(), null, null, null, 5, null, null); msg := concat_ws(', ', msg, 'added a delivery'); exception when insufficient_privilege then n := n + 1; end;
        begin v := close_inventory_month(); msg := concat_ws(', ', msg, 'closed the month'); exception when insufficient_privilege then n := n + 1; end;
        begin v := set_inventory_price(it_steel, 1); msg := concat_ws(', ', msg, 'changed a price'); exception when insufficient_privilege then n := n + 1; end;
        execute 'reset role';
      exception when others then execute 'reset role'; msg := concat_ws(', ', msg, 'Error: ' || sqlerrm);
      end;
      res := res || check_row(10, 'A supervisor can''t send another department''s list, see prices, write directly, or use the office''s functions', n = 8,
        format('%s of 8 refused. The Metal supervisor %s.', n, coalesce(msg, '—')));

      -- 11: test logins
      if tst is null then
        res := res || check_row(11, 'A test login sees no inventory list and can''t send a count', false, 'No Test Supervisor login to test with.');
      else
        perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
        begin
          execute 'set local role authenticated';
          select count(*) into n from v_inv_tablet_lists;
          begin v := send_inventory_count('metal', '[]', null); m := 0; exception when insufficient_privilege then m := 1; end;
          execute 'reset role';
          ok := n = 0 and m = 1;
          msg := format('The Test Supervisor saw %s lists (0 expected); sending refused: %s.', n, m);
        exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
        end;
        res := res || check_row(11, 'A test login sees no inventory list and can''t send a count', coalesce(ok, false), msg);
      end if;
      raise exception using errcode = 'P0001', message = '__inv_pretend_day__';
    exception when others then
      if sqlerrm <> '__inv_pretend_day__' then
        res := res || check_row(9, 'The Metal tablet steps ran', false, 'They stopped early: ' || sqlerrm);
      end if;
    end;

    -- ---- 12: another supervisor sees no inventory at all --------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', other_sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_inv_tablet_items where list_key in ('metal', 'plywood');
      select count(*) into m from v_inv_pool;
      execute 'reset role';
      ok := n = 0 and m = 0 and not exists (select 1 from information_schema.columns where table_name = 'v_inv_tablet_items' and column_name ilike '%price%');
      msg := format('Saw %s Metal/Plywood items and %s sheets of the month''s list; the tablet view must have no price column.', n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(12, 'Each tablet sees only its own list, never prices, and not the office''s sheet list', coalesce(ok, false), msg);

    -- ---- 13–15: closing the month ---------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    begin
      v := inv_close_month_now(true);                 -- as the manager (not granted to logins; close_inventory_month() calls it)
      ok := false; msg := 'The month closed with counts still missing.';
    exception when others then execute 'reset role'; ok := sqlerrm like 'Still to come%'; msg := 'Refused, but with: ' || sqlerrm;
    end;
    res := res || check_row(13, 'A month won''t close until every count due is in', ok, msg);

    begin
      -- real sheets still needing Setup are left out here (inside the undo), so the close can run
      insert into inv_species_matches (wo_norm, wo_species, inventory_species, leave_out, set_by_name)
      select distinct inv_norm(coalesce(species, '(none)')), coalesce(species, '(none)'), null, true, 'check'
        from v_inv_pool where problem is not null and job_id not in (v_job, v_pre);
      execute 'set local role authenticated';
      v := set_lumber_done(true);
      for t in select key from inv_lists where department is not null and inv_list_due(key, v_month) loop
        if (inv_sent(t, v_month)).id is null then
          v := send_inventory_count(t, case when t = 'metal' then jsonb_build_array(jsonb_build_object('item_id', it_steel, 'sticks', 2, 'loose_ft', 0)) else '[]' end, null);
        end if;
      end loop;
      v := set_rollover_done(true);
      select coalesce(sum(value), 0) into a from v_inv_values where month_end = v_month;
      execute 'reset role';
      v := inv_close_month_now(true);
      select count(*) filter (where job_id = v_job), count(*) filter (where job_id = v_job and sheet_number = 4) into n, m from inv_close_sheets where month_end = v_month;
      ok := n = 4 and m = 0 and (select status from inv_months where month_end = v_month) = 'closed'
            and inv_current_month() = inv_month_end_d(v_month + 1)
            and exists (select 1 from v_inv_pool where job_id = v_job and sheet_number = 4);
      msg := format('Expected 4 of the check''s sheets saved with the month and the rolled-over one on next month''s list; got %s saved (rolled one saved: %s). %s', n, m, v->>'summary');
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(14, 'Closing saves the month''s sheets; a rolled-over sheet moves to next month''s list', coalesce(ok, false), msg);

    begin
      execute 'set local role authenticated';
      select item_id into it_ply from inv_close_values where month_end = v_month and qty > 0 order by qty desc limit 1;
      v := set_inventory_price(it_ply, 99999);
      select coalesce(sum(value), 0) into b from v_inv_values where month_end = v_month;
      begin v := add_inventory_receipt('plywood', v_month, null, null, null, 3, null, null); n := 0; exception when others then n := 1; end;
      begin v := mark_receipt_mistake(v_rec); m := 0; exception when others then m := 1; end;
      execute 'reset role';
      ok := it_ply is not null and a = b and n = 1 and m = 1;
      msg := format('After closing: a new price changed the month''s value %s → %s (must not), a slip for it was refused: %s, changing its slips refused: %s.', a, b, n, m);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(15, 'A closed month is frozen: its prices, deliveries and counts don''t change', coalesce(ok, false), msg);

    -- ---- 16: no login -----------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    n := 0; msg := null;
    foreach t in array array['inv_items', 'inv_prices', 'inv_counts', 'inv_lumber_lines', 'inv_receipts', 'inv_months', 'inv_close_sheets',
                             'v_inv_pool', 'v_inv_scrap', 'v_inv_values', 'v_inv_status', 'v_inv_tablet_lists', 'v_inv_tablet_items', 'v_inv_needs'] loop
      begin
        execute 'set local role anon';
        execute format('select count(*) from %I', t) into m;
        execute 'reset role';
        if m > 0 then n := n + m; msg := concat_ws(', ', msg, format('%s rows of %s', m, t)); end if;
      exception when insufficient_privilege then execute 'reset role';
      when others then execute 'reset role'; n := n + 1; msg := concat_ws(', ', msg, format('%s: %s', t, sqlerrm));
      end;
    end loop;
    res := res || check_row(16, 'Someone with no login sees none of it', n = 0, coalesce(msg, '') || ' visible without logging in. Do not go further.');

    raise exception using errcode = 'P0001', message = '__check_inventory_undo__';
  exception when others then
    if sqlerrm <> '__check_inventory_undo__' then
      res := res || check_row(99, 'The check ran to the end', false, 'It stopped early: ' || sqlerrm);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x order by (x->>'step')::int;
end;
$$;
revoke all on function check_inventory() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. This file's own check. It practises on its own upload under a made-up
--    number, as a manager signed in, and undoes all of it at the end.
-- ---------------------------------------------------------------------

create or replace function check_checks_clean()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res    jsonb := '[]';
  mgr    uuid;  sup uuid;  as_mgr text;  as_sup text;
  v_job  uuid;  v_real uuid;
  r      jsonb;  t text;  n int;  m int;  ok boolean;  msg text;
  pl     jsonb := '{"project_id": "CLEANCHECK-2", "project_name": "Checks check - undone automatically", "total_items": 3, "sheets": [
      {"sheet_number": 1, "item_code": "CC-1", "qty": 2, "width": "36", "length": "72", "departments": ["sanding"]},
      {"sheet_number": 2, "item_code": "CC-2", "qty": 1, "width": "30", "length": "60", "departments": ["sanding"]}]}';
begin
  -- ---- 1. locked: only the SQL Editor retires, and no login reads what's been accepted ----
  ok := exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'jobs' and column_name = 'retired_at')
        and to_regprocedure('public.retire_placeholder(text,text)') is not null
        and not has_function_privilege('authenticated', 'public.retire_placeholder(text,text)', 'execute')
        and not has_function_privilege('anon', 'public.retire_placeholder(text,text)', 'execute')
        and not has_function_privilege('authenticated', 'public.retired_placeholders()', 'execute')
        and not has_function_privilege('anon', 'public.retired_placeholders()', 'execute')
        and exists (select 1 from pg_trigger where tgrelid = 'public.work_orders'::regclass and tgname = 'work_orders_retired_guard' and tgenabled <> 'D')
        and (select relrowsecurity from pg_class where oid = 'public.accepted_findings'::regclass)
        and not has_table_privilege('authenticated', 'public.accepted_findings', 'select,insert,update,delete,truncate')
        and not has_table_privilege('anon', 'public.accepted_findings', 'select,insert,update,delete,truncate');
  res := res || check_row(1, 'Only the SQL Editor retires a placeholder or reads what''s been accepted; an upload under a retired number is watched for', coalesce(ok, false),
    'A piece is missing or open to a login. Run checks_clean.sql again.');

  -- ---- 2. the functions that changed are this file's -----------------------------------
  select string_agg(x.f, ', ') into msg
    from (values ('run_monday_sync(text)', 'retired_at is null'), ('check_monday_sync()', 'retired placeholder'), ('job_lookup(text)', 'retired_at is not null'),
                 ('check_connector_safety()', 'accepted_findings'), ('check_pace()', 'interval ''90 hours'''), ('check_incomplete_deliveries()', 'look_up'),
                 ('check_onedrive_save()', 'interval ''30 days'''), ('check_inventory()', 'Zz Checkwood')) as x(f, marker)
   where to_regprocedure('public.' || x.f) is null
      or (select position(x.marker in p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.' || x.f)) = 0;
  res := res || check_row(2, 'The Monday sync, Job status and the six rewritten checks are this file''s copies', msg is null,
    'An older copy is back: ' || coalesce(msg, '') || '. Run checks_clean.sql again; if that stops, bring this line to Claude in a chat.');

  -- ---- 3. PROJ-00421-2, and R-14 on record -------------------------------------------------
  ok := not exists (select 1 from jobs where upper(project_id) = 'PROJ-00421-2' and monday_item_id is null and not coalesce(is_test, false) and retired_at is null);
  res := res || check_row(3, 'PROJ-00421-2 is retired (or was never on this database)', ok,
    'PROJ-00421-2 is still held as a job waiting on Monday. Run checks_clean.sql again.');
  ok := exists (select 1 from accepted_findings where finding = 'R-14');
  res := res || check_row(4, 'R-14 is on record as accepted (who, when, and the rule that stays)', ok,
    'The record is missing. Run checks_clean.sql again.');

  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select p.id into sup from profiles p where p.role = 'supervisor' and p.active and not p.is_test and 'sanding' = any(p.departments) order by p.full_name limit 1;
  if mgr is null or sup is null then
    res := res || check_row(5, 'A manager and a Sanding supervisor have logins to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_sup := json_build_object('sub', sup, 'role', 'authenticated')::text;

  begin    -- everything below is undone at the end, whatever happens
    -- ---- 5. an upload under a number Monday doesn't have: on the floor, and counted as waiting on Monday ----
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      r := upload_work_order(pl);
      execute 'reset role';
      v_job := (r ->> 'job_id')::uuid;
      perform set_config('request.jwt.claims', as_sup, true);
      execute 'set local role authenticated';
      select count(*) into n from v_floor_sheets where job_id = v_job;                  -- the tablets' sheets: never a job Monday doesn't have
      execute 'reset role';
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      select count(*) into m from v_uploaded_jobs where job_id = v_job and is_active and not linked_to_monday;   -- the office's list of uploads
      select m + count(*) into m from v_ready_to_work where job_id = v_job;
      execute 'reset role';
      ok := (select is_active and monday_item_id is null and retired_at is null from jobs where id = v_job) and n = 0 and m = 3
            and exists (select 1 from jobs where id = v_job and monday_item_id is null and not is_test and retired_at is null);
      msg := format('The practice upload should be a job of its own, live in the office (%s of 3 rows found), waiting on Monday, and on no tablet (the Sanding supervisor saw %s of its sheets).', m, n);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(5, 'A work order uploaded under a number Monday doesn''t have is held as its own live job in the office, waiting on Monday, and is on no tablet', coalesce(ok, false), msg);

    -- ---- 6. retiring it: off the floor, off Job status, not counted; nothing deleted ----------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      begin
        execute 'set local role authenticated';
        t := retire_placeholder('CLEANCHECK-2', 'check');
        execute 'reset role'; ok := false; msg := 'A manager''s login retired a placeholder; only the SQL Editor may.';
      exception when insufficient_privilege then execute 'reset role'; ok := true;
      end;
      perform set_config('request.jwt.claims', '', true);
      t := retire_placeholder('cleancheck-2', 'Checks check');
      ok := ok and t like 'CLEANCHECK-2 is retired%'
            and (select not is_active and retired_at is not null and retired_why = 'Checks check' and floor_left_at is not null from jobs where id = v_job);
      perform set_config('request.jwt.claims', as_mgr, true);
      execute 'set local role authenticated';
      select count(*) into n from v_uploaded_jobs where job_id = v_job and is_active;
      select n + count(*) into n from v_ready_to_work where job_id = v_job;
      select n + count(*) into n from v_job_department_progress where job_id = v_job;
      r := job_lookup('cleancheck');
      execute 'reset role';
      ok := ok and n = 0 and jsonb_array_length(r -> 'jobs') = 0
            and not exists (select 1 from jobs where id = v_job and monday_item_id is null and not is_test and retired_at is null)
            and (select count(*) from work_orders where job_id = v_job) = 1
            and (select count(*) from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_job) = 2
            and (select count(*) from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id where w.job_id = v_job) = 2;
      if msg is null or ok is not false then
        msg := format('After retiring: "%s"; the office''s lists still hold %s rows of it; Job status finds %s; or its work order, sheets or counts were removed.', left(t, 80), n, jsonb_array_length(r -> 'jobs'));
      end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(6, 'Retired from the SQL Editor only: off the office''s lists and Job status, not counted as waiting on Monday, and nothing deleted', coalesce(ok, false), msg);

    -- ---- 7. twice, a real job, a number that isn't there -------------------------------------------------
    begin
      perform set_config('request.jwt.claims', '', true);
      insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999962, 'CLEANCHECK-REAL', 'Checks check - undone automatically', true, 'In Production')
        returning id into v_real;
      t := retire_placeholder('CLEANCHECK-2', 'again');
      ok := t like '%already retired%' and (select retired_why = 'Checks check' from jobs where id = v_job);
      t := retire_placeholder('CLEANCHECK-REAL', 'no');
      ok := ok and t like '%on the Monday board%' and (select is_active and retired_at is null from jobs where id = v_real);
      t := retire_placeholder('CLEANCHECK-NOBODY', 'no');
      ok := ok and t like 'There is no uploaded job%';
      t := retire_placeholder('CLEANCHECK-2', '  ');
      ok := ok and t like 'Say why%';
      msg := 'Retiring twice changed something, a job on the Monday board was retired, or a missing number or reason wasn''t turned away: ' || left(t, 120);
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(7, 'Retiring twice changes nothing; a job on the Monday board, an unknown number and a missing reason are turned away', coalesce(ok, false), msg);

    -- ---- 8. an upload under the retired number is refused, with nothing saved ---------------------------
    begin
      perform set_config('request.jwt.claims', as_mgr, true);
      begin
        execute 'set local role authenticated';
        r := upload_work_order(pl);
        execute 'reset role'; ok := false; msg := 'An upload under a retired number was saved.';
      exception when others then
        execute 'reset role';
        ok := sqlerrm like 'CLEANCHECK-2 was retired%'; msg := 'Refused, but with: ' || sqlerrm;
      end;
      ok := ok and (select count(*) from work_orders where job_id = v_job) = 1
               and (select count(*) from jobs where upper(project_id) = 'CLEANCHECK-2') = 1;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    res := res || check_row(8, 'A work order uploaded under a retired number is refused in plain words, and nothing is saved', coalesce(ok, false), msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end $$;
revoke all on function check_checks_clean() from public, anon, authenticated;

select * from check_checks_clean();
