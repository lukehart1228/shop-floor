-- =====================================================================
-- Shop Floor — Monday sync (Phase 1, step 3)
--
-- HOW TO USE: follow Walkthrough 3. In short — turn on the "http" and
-- "pg_cron" extensions, put your Monday token in the Vault, then paste
-- this whole file into a NEW, empty query and click Run.
-- Safe to run more than once.
--
-- What it does, every 15 minutes, inside Supabase:
--   * reads every job on the Monday Orders board (read only — it never
--     writes anything to Monday)
--   * updates the jobs table: name, delivery date, phase, materials
--   * a job is live on the floor when its Phase is "In Production"
--   * links work orders uploaded before Monday knew the job
--   * marks jobs that have left production as inactive — they keep all
--     their history, they just leave the tablets
--   * writes a plain-English line to monday_sync_log every time
--
-- Safety: if Monday gives no answer, an error, or an empty board, NOTHING
-- is changed. A broken reply can never switch the whole floor off.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. The two extensions must be on first (walkthrough 3, step 2)
-- ---------------------------------------------------------------------

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('monday_sync.sql'); end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'http') then
    raise exception 'The "http" extension is off. Turn it on first: Database → Extensions → search "http" → switch it on. Then run this file again.';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'The "pg_cron" extension is off. Turn it on first: Database → Extensions → search "pg_cron" → switch it on. Then run this file again.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The log — one row per run
-- ---------------------------------------------------------------------

create table if not exists monday_sync_log (
  id           bigserial primary key,
  run_at       timestamptz not null default now(),
  ok           boolean     not null,
  summary      text        not null,           -- the plain-English line
  items_read   int,
  active       int,
  added        int,
  updated      int,
  adopted      int,
  deactivated  int,
  problems     jsonb       not null default '[]'
);

alter table monday_sync_log enable row level security;
drop policy if exists read_sync_log on monday_sync_log;
create policy read_sync_log on monday_sync_log for select to authenticated
  using (my_role() in ('manager', 'admin'));
revoke insert, update, delete on monday_sync_log from anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. The sync
--
-- Board and column ids were read from the real Orders board. If a column
-- is ever deleted and recreated in Monday, its id changes and the log
-- will start reporting blank dates or phases — that's the sign to update
-- the ids below.
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
  c_fields     constant text   :=
    'id name column_values(ids: ["text_mm0wnntf","date_mkwjd2an","color_mkwqppkb"]) { id text } '
    'subitems { name column_values(ids: ["status"]) { text } }';

  v_token    text;
  v_cursor   text := null;
  v_page     int  := 0;
  v_query    text;
  v_resp     http_response;
  v_body     jsonb;
  v_batch    jsonb;
  v_items    jsonb := '[]'::jsonb;

  it         jsonb;
  v_cols     jsonb;
  v_mid      bigint;
  v_pid      text;
  v_name     text;
  v_phase    text;
  v_date     date;
  v_active   boolean;
  v_mat      boolean;
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
    exception when undefined_function then null;   -- older http versions; default timeout is fine
    end;

    -- ---- read the whole board, page by page ------------------------
    loop
      v_page := v_page + 1;
      if v_page > 20 then
        raise exception 'Monday kept sending more pages (over 2,000 jobs). Stopped to be safe.';
      end if;

      if v_cursor is null then
        v_query := format('query { boards(ids: [%s]) { items_page(limit: 100) { cursor items { %s } } } }',
                          c_board, c_fields);
      else
        v_query := format('query { next_items_page(limit: 100, cursor: %s) { cursor items { %s } } }',
                          to_json(v_cursor)::text, c_fields);
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

    -- the guard: an empty board is never believed
    if jsonb_array_length(v_items) = 0 then
      raise exception 'Monday returned an empty Orders board. Nothing was changed, in case that''s a mistake on Monday''s end.';
    end if;

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

      -- "PROJ-00418   Enid's Table" -> "Enid's Table"
      v_name  := nullif(trim(regexp_replace(it->>'name', '^\s*PROJ-\d+\s*[-–:]?\s*', '', 'i')), '');
      v_name  := coalesce(v_name, it->>'name');
      v_phase := nullif(trim(v_cols->>c_col_phase), '');
      -- "2026-11-17 04:30" -> 2026-11-17 ; the time is a Monday artefact
      v_date  := case when coalesce(v_cols->>c_col_date, '') ~ '^\d{4}-\d{2}-\d{2}'
                      then left(v_cols->>c_col_date, 10)::date end;
      v_active := (v_phase = c_live_phase);
      v_mat := exists (
        select 1 from jsonb_array_elements(coalesce(it->'subitems', '[]'::jsonb)) si
         where lower(si->>'name') like '%order materials%'
           and exists (select 1 from jsonb_array_elements(coalesce(si->'column_values', '[]'::jsonb)) cv
                        where lower(coalesce(cv->>'text', '')) = 'done'));

      begin
        -- already linked to this Monday row
        update jobs set project_id = v_pid, name = v_name, delivery_date = v_date, phase = v_phase,
                        is_active = v_active, materials_ordered = v_mat, last_synced_at = now(),
                        updated_at = now()
         where monday_item_id = v_mid
        returning id into v_job;

        if found then
          n_updated := n_updated + 1;
        else
          -- a work order arrived before Monday knew the job: adopt it
          update jobs set monday_item_id = v_mid, name = v_name, delivery_date = v_date, phase = v_phase,
                          is_active = v_active, materials_ordered = v_mat, last_synced_at = now(),
                          updated_at = now()
           where project_id = v_pid and monday_item_id is null
          returning id into v_job;

          if found then
            n_adopted := n_adopted + 1;
          else
            insert into jobs (monday_item_id, project_id, name, delivery_date, phase,
                              is_active, materials_ordered, last_synced_at)
            values (v_mid, v_pid, v_name, v_date, v_phase, v_active, v_mat, now());
            n_added := n_added + 1;
          end if;
        end if;
      exception when unique_violation then
        -- two Monday rows claiming the same PROJ number
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

    -- work orders for PROJ numbers Monday has never heard of
    select v_problems || coalesce(jsonb_agg(to_jsonb(format(
             '%s has a work order uploaded but isn''t on the Monday board. Check the PROJ number.', project_id))), '[]')
      into v_problems
      from jobs where monday_item_id is null;

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

-- only the scheduler and the SQL Editor run this; the tablets can't
revoke all on function run_monday_sync(text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Run it every 15 minutes
-- ---------------------------------------------------------------------

select cron.schedule('shop-floor-monday-sync', '*/15 * * * *', 'select public.run_monday_sync()');


-- ---------------------------------------------------------------------
-- 4. check_monday_sync() — the plain PASS / FAIL check
--
--    select * from check_monday_sync();
-- ---------------------------------------------------------------------

create or replace function check_monday_sync()
returns table (step int, check_name text, result text, detail text)
language plpgsql security definer
set search_path = public
as $$
declare
  last monday_sync_log;
  n    int;
begin
  step := 1; check_name := 'The Monday token is in the Vault';
  select count(*) into n from vault.decrypted_secrets where name = 'monday_token' and coalesce(decrypted_secret, '') <> '';
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  detail := case when n > 0 then null else 'Add a Vault secret named exactly monday_token (walkthrough 3, step 3).' end;
  return next;

  step := 2; check_name := 'The sync is scheduled every 15 minutes';
  select count(*) into n from cron.job where jobname = 'shop-floor-monday-sync' and active;
  result := case when n > 0 then 'PASS' else 'FAIL' end;
  detail := case when n > 0 then null else 'Run monday_sync.sql again — its schedule line didn''t take.' end;
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
  select count(*) into n from jobs where monday_item_id is null;
  result := case when n = 0 then 'PASS' else 'FAIL' end;
  detail := case when n = 0 then null
                 else n || ' still unlinked: ' ||
                      (select string_agg(project_id, ', ') from jobs where monday_item_id is null) ||
                      '. Either the sync hasn''t run since the upload, or the PROJ number isn''t on the board.' end;
  return next;
end;
$$;

revoke all on function check_monday_sync() from public, anon, authenticated;
