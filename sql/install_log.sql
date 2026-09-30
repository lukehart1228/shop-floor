-- =====================================================================
-- install_log.sql — what's installed, guards, one check for everything,
-- which page each tablet runs (30 Sep 2026)
--
-- 1. The install log. From now on every SQL file writes a line here
--    when it runs. This file also looks for every file that ran before
--    the log existed and lists it as "found".
-- 2. Guards. Some files replace pieces of earlier ones (send_routes.sql
--    replaces ready_issues.sql's Ready rules, office.sql replaces
--    monday_sync.sql's sync, and so on). Running the older file again
--    would quietly put the old pieces back. Now it stops instead, with
--    a plain message, and changes nothing.
-- 3. select * from whats_installed();   every file: installed or not,
--    and whether any ran out of order.
-- 4. select * from check_everything();  every check in one paste, one
--    line each. Nothing any check does is kept.
-- 5. select * from devices();           which page each tablet and
--    phone is running, and when it last opened it.
--
-- Run after delivery_types.sql. Safe to run twice. Nothing anyone sees
-- on a tablet, the office or the TV changes. Ends with
-- whats_installed(): every row should say PASS.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.check_delivery_types()') is null then
    raise exception 'Run delivery_types.sql first. This file comes after it.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The install log
-- ---------------------------------------------------------------------

-- Every SQL file the system is built from, in the order they're run.
-- fingerprint: something only that file makes, so a file that ran before
-- the log started can still be found. replaces: earlier files whose
-- pieces this one rewrites (running one of those again would undo it).
create table if not exists sql_file_catalog (
  file        text primary key,
  run_order   numeric not null,
  fingerprint text,
  replaces    text[] not null default '{}',
  added_at    timestamptz not null default now()
);

-- One line per run (or per file found at the start). Kept for good.
create table if not exists sql_file_runs (
  id      bigserial primary key,
  file    text not null,
  ran_at  timestamptz,                   -- null for a file found, not seen running
  how     text not null check (how in ('ran', 'found', 'ran older on purpose')),
  ran_by  text not null default current_user
);
create index if not exists sql_file_runs_file_idx on sql_file_runs (file, id);

-- A one-time permission to run an older file (rolling back on purpose).
create table if not exists sql_file_allow (
  id         bigserial primary key,
  file       text not null,
  allowed_at timestamptz not null default now(),
  allowed_by text not null default current_user,
  used_at    timestamptz
);

-- The SQL Editor only: no login reads or writes these.
alter table sql_file_catalog enable row level security;
alter table sql_file_runs    enable row level security;
alter table sql_file_allow   enable row level security;
revoke all on sql_file_catalog, sql_file_runs, sql_file_allow from anon, authenticated;
revoke all on sequence sql_file_runs_id_seq, sql_file_allow_id_seq from anon, authenticated;

insert into sql_file_catalog (file, run_order, fingerprint, replaces) values
  ('schema.sql',           1,  'my_role',                '{}'),
  ('verify_setup.sql',     2,  'verify_setup',           '{}'),
  ('upload_function.sql',  3,  'can_upload_work_orders', '{}'),
  ('monday_sync.sql',      4,  'monday_sync_log',        '{}'),
  ('tablet.sql',           5,  'v_floor_sheets',         '{}'),
  ('office.sql',           6,  'check_office',           '{monday_sync.sql}'),
  ('test_lane.sql',        7,  'check_test_lane',        '{tablet.sql}'),
  ('catch_up.sql',         8,  'check_catch_up',         '{schema.sql}'),
  ('problems.sql',         9,  'check_job_sheet',        '{}'),
  ('flags.sql',            10, 'clear_flag',             '{}'),
  ('routine_tasks.sql',    11, 'add_routine_task',       '{}'),
  ('supplies.sql',         12, 'cancel_supply',          '{}'),
  ('arrow_qc.sql',         13, 'arrow_departments',      '{}'),
  ('tv.sql',               14, 'new_tv_link',            '{}'),
  ('check_floor.sql',      15, 'check_floor',            '{}'),
  ('photos.sql',           16, 'add_photo',              '{}'),
  ('check_photos.sql',     17, 'check_photos',           '{}'),
  ('advance.sql',          18, 'check_advance',          '{}'),
  ('supply_lists.sql',     19, 'check_supply_lists',     '{}'),
  ('loadouts_v2.sql',      20, 'check_loadouts',         '{photos.sql}'),
  ('deliveries.sql',       21, 'add_delivery_doc',       '{photos.sql,loadouts_v2.sql}'),
  ('deliveries_v2.sql',    22, 'check_deliveries_v2',    '{photos.sql,deliveries.sql}'),
  ('ready_issues.sql',     23, 'answer_defect',          '{schema.sql,problems.sql}'),
  ('finish_by.sql',        24, 'check_finish_by',        '{}'),
  ('inventory.sql',        25, 'check_inventory',        '{}'),
  ('pace.sql',             26, 'check_pace',             '{}'),
  ('send_routes.sql',      27, 'check_send_routes',      '{schema.sql,ready_issues.sql}'),
  ('arrow_pickup.sql',     28, 'check_arrow_pickup',     '{arrow_qc.sql}'),
  ('delivery_types.sql',   29, 'check_delivery_types',   '{photos.sql,loadouts_v2.sql,deliveries.sql,deliveries_v2.sql}'),
  ('install_log.sql',      30, 'sql_file_start',         '{}'),
  ('tv_pace.sql',          31, 'check_tv',               '{tv.sql}')
on conflict (file) do update set run_order = excluded.run_order, fingerprint = excluded.fingerprint, replaces = excluded.replaces;

-- does the database already have this file's fingerprint?
create or replace function sql_file_found(p_fingerprint text) returns boolean
language sql stable set search_path = public as $$
  select p_fingerprint is not null and (
       exists (select 1 from pg_proc  where proname = p_fingerprint and pronamespace = 'public'::regnamespace)
    or exists (select 1 from pg_class where relname = p_fingerprint and relnamespace = 'public'::regnamespace));
$$;

-- Files that ran before the log existed: listed once, as found.
insert into sql_file_runs (file, ran_at, how)
select c.file, null, 'found'
from sql_file_catalog c
where c.file <> 'install_log.sql' and sql_file_found(c.fingerprint)
  and not exists (select 1 from sql_file_runs r where r.file = c.file);

-- ---------------------------------------------------------------------
-- 2. The guard every SQL file calls first
-- ---------------------------------------------------------------------

-- sql_file_start('ready_issues.sql')  → records the run, or stops the
-- whole file (nothing changes) if a newer file that replaces it is installed.
-- A new file names what it replaces:  sql_file_start('x.sql', '{y.sql}')
create or replace function sql_file_start(p_file text, p_replaces text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  newer text[];
  ok    bigint;
begin
  if p_replaces is not null then
    insert into sql_file_catalog (file, run_order, fingerprint, replaces)
    values (p_file, coalesce((select max(run_order) from sql_file_catalog), 0) + 1, null, p_replaces)
    on conflict (file) do update set replaces = excluded.replaces;
  elsif not exists (select 1 from sql_file_catalog where file = p_file) then
    insert into sql_file_catalog (file, run_order) values (p_file, coalesce((select max(run_order) from sql_file_catalog), 0) + 1);
  end if;

  select array_agg(c.file order by c.run_order) into newer
  from sql_file_catalog c
  where p_file = any (c.replaces)
    and exists (select 1 from sql_file_runs r where r.file = c.file);

  if newer is not null then
    select id into ok from sql_file_allow
    where file = p_file and used_at is null and allowed_at > now() - interval '30 minutes'
    order by id desc limit 1;
    if ok is null then
      raise exception '%', format(
        'Stop — nothing was changed. %s is older than %s, which is already installed and replaced some of its pieces. '
        'Running %s again would put the old versions back. '
        'If you meant to run a newer file, open that one instead. '
        'Rolling back on purpose? Work it out with Claude in a chat first: it will give you the files and the order.',
        p_file, array_to_string(newer, ' and '), p_file)
      using errcode = 'P0001';
    end if;
    update sql_file_allow set used_at = now() where id = ok;
    insert into sql_file_runs (file, ran_at, how) values (p_file, now(), 'ran older on purpose');
    return;
  end if;

  insert into sql_file_runs (file, ran_at, how) values (p_file, now(), 'ran');
end $$;

-- select allow_older_file('ready_issues.sql');  → that file may run once in the next 30 minutes
create or replace function allow_older_file(p_file text) returns text
language plpgsql security definer set search_path = public as $$
declare newer text;
begin
  if not exists (select 1 from sql_file_catalog where file = p_file) then
    return format('There''s no file called %s in the list. Check the spelling, including .sql.', p_file);
  end if;
  select string_agg(c.file, ' and ' order by c.run_order) into newer
  from sql_file_catalog c where p_file = any (c.replaces) and exists (select 1 from sql_file_runs r where r.file = c.file);
  insert into sql_file_allow (file) values (p_file);
  return format('OK — %s may run once in the next 30 minutes. %s', p_file,
    case when newer is null then 'Nothing newer replaces it, so it didn''t need this.'
         else 'It was replaced by ' || newer || ', so newer files will need running again afterwards to go forward — in the order Claude gives you.' end);
end $$;

revoke all on function sql_file_start(text, text[]), allow_older_file(text), sql_file_found(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. What's installed
-- ---------------------------------------------------------------------

create or replace function whats_installed()
returns table (step int, file text, result text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  c    record;
  last record;
  late text;
  n    int := 0;
begin
  for c in select * from sql_file_catalog order by run_order loop
    n := n + 1; step := n; file := c.file;
    select * into last from sql_file_runs r where r.file = c.file order by r.id desc limit 1;

    -- a newer file that replaces this one ran BEFORE this file's latest run
    select string_agg(g.file, ' and ' order by g.run_order) into late
    from sql_file_catalog g
    where c.file = any (g.replaces) and last.ran_at is not null
      and (select max(r.ran_at) from sql_file_runs r where r.file = g.file) < last.ran_at;

    if last.id is null and not sql_file_found(c.fingerprint) then
      result := 'FAIL'; detail := 'Not installed. Run it (in the order of the sql folder''s README).';
    elsif late is not null then
      result := 'FAIL';
      detail := format('Ran after %s, which replaces some of its pieces — the old versions are back. Run %s again to go forward%s.',
                       late, late, case when last.how = 'ran older on purpose' then ' (unless you''re rolling back)' else '' end);
    elsif last.id is null then
      result := 'PASS'; detail := 'Installed (found; ran before the log started)';
    elsif last.ran_at is null then
      result := 'PASS'; detail := 'Installed (ran before the log started)';
    else
      result := 'PASS';
      detail := 'Last run ' || to_char(last.ran_at at time zone 'America/Indiana/Indianapolis', 'Mon DD, HH12:MI am')
                || case when last.how = 'ran older on purpose' then ' (older file, on purpose)' else '' end;
    end if;
    return next;
  end loop;
end $$;

revoke all on function whats_installed() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Which page each device runs  (section 4, check_everything, uses it)
-- ---------------------------------------------------------------------

-- One row per device and page; updated each time the app opens there.
create table if not exists device_versions (
  device_id  text not null,
  page       text not null,
  version    text not null,
  user_id    uuid,
  agent      text,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (device_id, page)
);
alter table device_versions enable row level security;
revoke all on device_versions from anon, authenticated;

-- Called by the tablet page when it opens with a connection. Any signed-in login.
create or replace function report_device(p_device text, p_page text, p_version text, p_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = 'insufficient_privilege'; end if;
  if coalesce(length(p_device), 0) not between 8 and 100 or coalesce(length(p_page), 0) not between 1 and 40
     or coalesce(length(p_version), 0) not between 1 and 60 then
    raise exception 'That device report doesn''t look right.';
  end if;
  insert into device_versions (device_id, page, version, user_id, agent)
  values (p_device, p_page, p_version, auth.uid(), left(p_agent, 300))
  on conflict (device_id, page) do update
    set version = excluded.version, user_id = excluded.user_id, agent = excluded.agent, last_seen = now();
end $$;
revoke all on function report_device(text, text, text, text) from public, anon;
grant execute on function report_device(text, text, text, text) to authenticated;

-- select * from devices();   newest page first; "older page" = not the newest any device has
create or replace function devices()
returns table (person text, login text, page text, version text, last_opened text, note text)
language sql security definer set search_path = public as $$
  with newest as (select page, max(version) as v from device_versions group by page)
  select coalesce(p.full_name, '(no profile)') || case when p.is_test then ' (test)' else '' end,
         u.email, d.page, d.version,
         to_char(d.last_seen at time zone 'America/Indiana/Indianapolis', 'Mon DD, HH12:MI am'),
         case when d.version < n.v then 'Older page — close the app fully and reopen it on Wi-Fi'
              else 'Newest page' end
  from device_versions d
  join newest n on n.page = d.page
  left join profiles p on p.id = d.user_id
  left join auth.users u on u.id = d.user_id
  order by d.page, d.version desc, d.last_seen desc;
$$;
revoke all on function devices() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Every check in one paste
-- ---------------------------------------------------------------------

-- Each check runs inside its own undo: whatever it does is thrown away
-- afterwards, even if the check itself forgot to tidy up.
create or replace function check_everything()
returns table (step int, check_name text, result text, detail text)
language plpgsql set search_path = public as $$
declare
  fns text[] := array['verify_setup', 'check_monday_sync', 'check_office', 'check_test_lane', 'check_catch_up',
                      'check_floor', 'check_photos', 'check_advance', 'check_supply_lists', 'check_loadouts',
                      'check_deliveries', 'check_deliveries_v2', 'check_ready_issues', 'check_finish_by',
                      'check_inventory', 'check_pace', 'check_send_routes', 'check_arrow_pickup', 'check_delivery_types',
                      'check_tv'];
  fn    text;
  rows  jsonb;
  total int; passed int; firstbad text;
  bad   int;
  n     int := 1;
  stale int; seen int;
begin
  step := 1; check_name := 'Every SQL file installed, in order';
  select count(*) filter (where w.result <> 'PASS'), count(*),
         (array_agg(w.file || ': ' || w.detail order by w.step) filter (where w.result <> 'PASS'))[1]
    into bad, total, firstbad from whats_installed() w;
  result := case when bad = 0 then 'PASS' else 'FAIL' end;
  detail := case when bad = 0 then total || ' files' else bad || ' to fix. First: ' || firstbad || '  (select * from whats_installed(); for all)' end;
  return next;

  foreach fn in array fns loop
    n := n + 1; step := n; check_name := fn;
    if to_regprocedure('public.' || fn || '()') is null then
      result := 'FAIL'; detail := 'This check isn''t installed — its SQL file hasn''t run.';
      return next; continue;
    end if;
    rows := null;
    begin
      execute format('select jsonb_agg(to_jsonb(r)) from public.%I() r', fn) into rows;
      raise exception using errcode = 'SF001', message = 'undo the check';
    exception
      when sqlstate 'SF001' then null;                       -- the planned undo; rows is kept
      when others then rows := jsonb_build_array(jsonb_build_object('result', 'ERROR', 'detail', sqlerrm));
    end;
    select count(*), count(*) filter (where e->>'result' = 'PASS'),
           (array_agg(coalesce('step ' || (e->>'step') || ': ', '') || coalesce(e->>'check_name', e->>'looking_for', e->>'name', '')
                      || coalesce(' — ' || coalesce(e->>'detail', e->>'if_it_failed'), '')) filter (where e->>'result' <> 'PASS'))[1]
      into total, passed, firstbad
    from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) e;
    -- advice written before a file was replaced ("Run photos.sql again") would now stop at its guard, or undo newer work
    if firstbad ~ 'Run monday_sync\.sql again' then
      firstbad := firstbad || '  →  Don''t run monday_sync.sql (office.sql replaced it). Paste this instead:  select cron.schedule(''shop-floor-monday-sync'', ''*/15 * * * *'', ''select public.run_monday_sync()'');';
    elsif substring(firstbad from 'Run ([a-z_0-9]+\.sql) again') in
          (select f.file from sql_file_catalog f where exists (select 1 from sql_file_catalog g where f.file = any (g.replaces)
                                                                and exists (select 1 from sql_file_runs r where r.file = g.file))) then
      firstbad := firstbad || '  →  ' || substring(firstbad from 'Run ([a-z_0-9]+\.sql) again')
                  || ' has been replaced by newer files, so don''t run it. Bring this line to Claude in a chat.';
    end if;
    result := case when total > 0 and passed = total then 'PASS' else 'FAIL' end;
    detail := passed || '/' || total || case when firstbad is not null then '. First: ' || firstbad else '' end;
    return next;
  end loop;

  n := n + 1; step := n; check_name := 'Tablets and phones on the newest page';
  select count(*) filter (where d.note <> 'Newest page'), count(*),
         string_agg(case when d.note <> 'Newest page' then d.person || ' (' || d.version || ', opened ' || d.last_opened || ')' end, '; ')
    into stale, seen, firstbad
  from devices() d;
  result := case when stale = 0 then 'PASS' else 'FAIL' end;
  detail := case when seen = 0 then 'No device has reported yet — each one does the first time it opens the new tablet page.'
                 when stale = 0 then seen || ' device' || case when seen = 1 then '' else 's' end || ', all on the newest page'
                 else stale || ' on an older page: ' || firstbad || '. Close the app fully and reopen it on Wi-Fi.  (select * from devices(); for all)' end;
  return next;
end $$;
revoke all on function check_everything() from public, anon, authenticated;

-- This file's own line in the log
select sql_file_start('install_log.sql');

select * from whats_installed();
