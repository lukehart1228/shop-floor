-- =====================================================================
-- Shop Floor — office view (trial build, step 1)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Safe to run more than once.
-- Then run, on their own:
--     select * from setup_monday_columns();
--     select run_monday_sync();
--     select * from check_office();
--
-- What it adds:
--   1. A live switch per department (only sanding starts on), with a
--      history of every change
--   2. monday_columns — which Monday columns hold Handed Off and the
--      stage statuses. setup_monday_columns() finds them by their titles
--      on the board, so nobody has to dig for column ids
--   3. The Monday sync, now also reading Handed Off and the four stage
--      columns (Wood, Metal, Full Custom, Assembly/QC). Still read-only.
--      If those columns can't be read, the sync carries on with the
--      rest exactly as before and says so in the log.
--   4. v_handoff_tasks — the office's "Your tasks" list
--   5. check_office() — the PASS / FAIL check
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Live switches
--
-- Which departments are live on the floor. Only the TV uses it; every
-- department's queue works whether it's live or not. Sanding is switched
-- on the first time this file runs, and never touched again after that,
-- so running the file twice can't undo a switch you've flipped.
-- ---------------------------------------------------------------------

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('office.sql'); end if;
end $$;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'departments' and column_name = 'is_live') then
    alter table departments add column is_live boolean not null default false;
    update departments set is_live = true where key = 'sanding';
  end if;
end $$;

-- every flip of a switch, kept for good
create table if not exists department_live_log (
  id          bigserial primary key,
  department  text        not null references departments(key),
  is_live     boolean     not null,
  changed_by  uuid        references profiles(id),
  changed_at  timestamptz not null default now()
);
alter table department_live_log enable row level security;
drop policy if exists read_live_log on department_live_log;
create policy read_live_log on department_live_log for select to authenticated
  using (my_role() in ('manager', 'admin'));
revoke insert, update, delete on department_live_log from anon, authenticated;

create or replace function set_department_live(p_department text, p_live boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role()::text, '') not in ('manager', 'admin') then
    raise exception 'Only a manager can switch a department live or off.'
      using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from departments where key = p_department) then
    raise exception '"%" is not a department.', p_department;
  end if;
  update departments set is_live = p_live where key = p_department and is_live is distinct from p_live;
  if found then
    insert into department_live_log (department, is_live, changed_by) values (p_department, p_live, auth.uid());
  end if;
  return p_live;
end;
$$;
revoke all on function set_department_live(text, boolean) from public, anon;
grant execute on function set_department_live(text, boolean) to authenticated;


-- ---------------------------------------------------------------------
-- 2. What the sync reads from Monday, beyond the three original columns
-- ---------------------------------------------------------------------

alter table jobs add column if not exists handed_off      boolean;            -- null = not known yet
alter table jobs add column if not exists handed_off_text text;
alter table jobs add column if not exists monday_stages   jsonb not null default '{}';
-- used by the test lane (step 2). Added here so the handoff list can leave test jobs out.
alter table jobs add column if not exists is_test         boolean not null default false;

create table if not exists monday_columns (
  key         text primary key,           -- handed_off, wood, metal, full_custom, assembly_qc
  what        text        not null,       -- plain name, for messages
  sort_order  int         not null,
  column_id   text,                       -- null until found
  title       text,                       -- the column's title on the board
  col_type    text,
  labels      jsonb       not null default '[]',   -- the column's labels, as the board has them
  yes_label   text,                       -- handed_off only: the label that means "handed off"
  found_by    text,                       -- 'setup' or 'by hand'
  updated_at  timestamptz not null default now()
);
insert into monday_columns (key, what, sort_order) values
  ('handed_off',  'Handed Off',          1),
  ('wood',        'Wood Status',         2),
  ('metal',       'Metal Status',        3),
  ('full_custom', 'Full Custom Status',  4),
  ('assembly_qc', 'Assembly/QC Status',  5)
on conflict (key) do nothing;

alter table monday_columns enable row level security;
drop policy if exists read_monday_columns on monday_columns;
create policy read_monday_columns on monday_columns for select to authenticated
  using (my_role() in ('manager', 'admin'));
revoke insert, update, delete on monday_columns from anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. setup_monday_columns() — find the columns by their titles
--
-- Reads the Orders board's list of columns (read-only) and matches:
--   Handed Off   -> a status or checkbox column whose title says "handed off"
--   Wood Status  -> a status column with "wood" in its title
--   Metal        -> "metal";  Full Custom -> "custom";  Assembly/QC -> "assembly" or "QC"
-- It reports what it found. If a title matches twice, it picks nothing
-- and says so, rather than guessing. Fix a column by hand with
--   select set_monday_column('wood', 'color_abc123');
-- ---------------------------------------------------------------------

create or replace function monday_request(p_endpoint text, p_query text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text;
  v_resp  http_response;
  v_body  jsonb;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'monday_token' limit 1;
  if v_token is null or trim(v_token) = '' then
    raise exception 'No Monday token in the Vault. Add a secret named monday_token (walkthrough 3, step 3).';
  end if;
  begin perform http_set_curlopt('CURLOPT_TIMEOUT', '30'); exception when undefined_function then null; end;
  v_resp := http(('POST', p_endpoint, array[http_header('Authorization', trim(v_token))],
                  'application/json', jsonb_build_object('query', p_query)::text)::http_request);
  if v_resp.status in (401, 403) then
    raise exception 'Monday refused access (%). Check the token in the Vault.', v_resp.status;
  elsif v_resp.status <> 200 then
    raise exception 'Monday answered with an error (%): %', v_resp.status, left(v_resp.content, 200);
  end if;
  begin v_body := v_resp.content::jsonb;
  exception when others then raise exception 'Monday''s reply wasn''t readable: %', left(v_resp.content, 200);
  end;
  return v_body;
end;
$$;
revoke all on function monday_request(text, text) from public, anon, authenticated;

-- a column's labels, in the order the board shows them, whichever shape Monday sends them in
create or replace function monday_labels(p_settings jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(l order by pos, ord), '[]'::jsonb) from (
    select distinct on (l) l, pos, ord from (
      -- older shape: {"labels": {"0": "Done", ...}, "labels_positions_v2": {"0": 3, ...}}
      select nullif(trim(e.value #>> '{}'), '') as l,
             coalesce((p_settings #>> array['labels_positions_v2', e.key])::int,
                      case when e.key ~ '^\d+$' then e.key::int end, 999) as pos,
             0 as ord
        from jsonb_each(case when jsonb_typeof(p_settings->'labels') = 'object' then p_settings->'labels' else '{}'::jsonb end) e
      union all
      -- newer shape: {"labels": [{"id": 0, "label": "Done", "position": 3}, ...]}
      select nullif(trim(coalesce(x->>'label', x->>'name', x #>> '{}')), ''),
             coalesce(case when x->>'position' ~ '^\d+$' then (x->>'position')::int end, o::int), o::int
        from jsonb_array_elements(case when jsonb_typeof(p_settings->'labels') = 'array' then p_settings->'labels' else '[]'::jsonb end)
             with ordinality as a(x, o)
    ) raw
    where l is not null
    order by l, pos, ord
  ) b;
$$;

create or replace function setup_monday_columns(p_endpoint text default 'https://api.monday.com/v2')
returns table (step int, looking_for text, result text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  c_board constant bigint := 8693042231;
  v_body  jsonb;
  v_cols  jsonb;
  mc      monday_columns;
  v_pat   text;
  v_types text[];
  v_hits  jsonb;
  v_hit   jsonb;
  v_lab   jsonb;
  v_yes   text;
begin
  -- newer Monday API versions renamed settings_str to settings; try one, then the other
  v_body := monday_request(p_endpoint, format('query { boards(ids: [%s]) { columns { id title type settings_str } } }', c_board));
  if v_body ? 'errors' then
    v_body := monday_request(p_endpoint, format('query { boards(ids: [%s]) { columns { id title type settings } } }', c_board));
  end if;
  if v_body ? 'errors' or v_body ? 'error_message' then
    raise exception 'Monday reported a problem: %', left(coalesce(v_body->>'error_message', (v_body->'errors')::text), 300);
  end if;
  v_cols := v_body #> '{data,boards,0,columns}';
  if v_cols is null or jsonb_array_length(v_cols) = 0 then
    raise exception 'Monday''s reply didn''t list the Orders board''s columns. Check the token''s account can see the board.';
  end if;

  for mc in select * from monday_columns order by sort_order loop
    step := mc.sort_order; looking_for := mc.what;

    if mc.found_by = 'by hand' then
      result := 'PASS'; detail := format('Set by hand: "%s" (%s). Left as it is.', mc.title, mc.column_id);
      return next; continue;
    end if;

    v_pat := case mc.key
      when 'handed_off'  then 'handed ?off|hand ?off'
      when 'wood'        then 'wood'
      when 'metal'       then 'metal'
      when 'full_custom' then 'custom'
      when 'assembly_qc' then 'assembl|\mqc\M' end;
    v_types := case when mc.key = 'handed_off' then array['status','color','checkbox'] else array['status','color'] end;

    select coalesce(jsonb_agg(c), '[]') into v_hits
      from jsonb_array_elements(v_cols) c
     where lower(c->>'title') ~ v_pat and c->>'type' = any(v_types);
    -- two matches: prefer the one whose title also says "status"
    if jsonb_array_length(v_hits) > 1 then
      select coalesce(jsonb_agg(c), '[]') into v_hit from jsonb_array_elements(v_hits) c where lower(c->>'title') like '%status%';
      if jsonb_array_length(v_hit) = 1 then v_hits := v_hit; end if;
    end if;

    if jsonb_array_length(v_hits) = 0 then
      update monday_columns set column_id = null, title = null, col_type = null, labels = '[]', yes_label = null,
                                found_by = null, updated_at = now() where key = mc.key;
      result := 'FAIL';
      detail := format('No %s column found on the board. If it has a different title, set it by hand: select set_monday_column(''%s'', ''<column id>'');',
                       mc.what, mc.key);
      return next; continue;
    end if;
    if jsonb_array_length(v_hits) > 1 then
      result := 'FAIL';
      detail := format('More than one column could be %s: %s. %s Choose one: select set_monday_column(''%s'', ''<column id>'');',
                       mc.what, (select string_agg(format('"%s" (%s)', c->>'title', c->>'id'), ', ') from jsonb_array_elements(v_hits) c),
                       case when mc.column_id is null then 'Nothing picked.' else format('Kept the one set before (%s) for now.', mc.column_id) end, mc.key);
      return next; continue;
    end if;

    v_hit := v_hits->0;
    v_lab := monday_labels(coalesce(case when jsonb_typeof(v_hit->'settings_str') = 'string' then (v_hit->>'settings_str')::jsonb end,
                                    v_hit->'settings', '{}'::jsonb));
    v_yes := null;
    if mc.key = 'handed_off' and v_hit->>'type' <> 'checkbox' then
      select l into v_yes from jsonb_array_elements_text(v_lab) l where lower(l) = 'yes' limit 1;
    end if;

    update monday_columns
       set column_id = v_hit->>'id', title = v_hit->>'title', col_type = v_hit->>'type', labels = v_lab,
           yes_label = case when key = 'handed_off' then coalesce(yes_label, v_yes) end,
           found_by = 'setup', updated_at = now()
     where key = mc.key
    returning * into mc;

    if mc.key = 'handed_off' and mc.col_type <> 'checkbox' and mc.yes_label is null then
      result := 'FAIL';
      detail := format('Found "%s" (%s), but none of its labels is "Yes". Its labels: %s. Tell it which one means handed off: select set_monday_column(''handed_off'', ''%s'', ''<that label>'');',
                       mc.title, mc.column_id, (select string_agg(l, ', ') from jsonb_array_elements_text(mc.labels) l), mc.column_id);
    else
      result := 'PASS';
      detail := format('"%s" (%s)%s', mc.title, mc.column_id,
                       case when mc.key = 'handed_off' then
                              case when mc.col_type = 'checkbox' then ' — a tick box; ticked means handed off.'
                                   else format(' — "%s" means handed off.', mc.yes_label) end
                            else coalesce(' — labels: ' || (select string_agg(l, ', ') from jsonb_array_elements_text(mc.labels) l), '') end);
    end if;
    return next;
  end loop;
end;
$$;
revoke all on function setup_monday_columns(text) from public, anon, authenticated;

-- set one by hand, if the titles don't match. p_yes_label is for handed_off only.
create or replace function set_monday_column(p_key text, p_column_id text, p_yes_label text default null)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from monday_columns where key = p_key) then
    raise exception '"%" isn''t one of: handed_off, wood, metal, full_custom, assembly_qc.', p_key;
  end if;
  update monday_columns
     set column_id = nullif(trim(p_column_id), ''),
         title     = coalesce(case when column_id = nullif(trim(p_column_id), '') then title end, nullif(trim(p_column_id), '')),
         yes_label = coalesce(nullif(trim(p_yes_label), ''), case when column_id = nullif(trim(p_column_id), '') then yes_label end),
         found_by  = case when nullif(trim(p_column_id), '') is null then null else 'by hand' end,
         updated_at = now()
   where key = p_key;
  return format('Set %s to %s. It takes effect at the next sync.', p_key, coalesce(nullif(trim(p_column_id), ''), 'nothing'));
end;
$$;
revoke all on function set_monday_column(text, text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. The Monday sync, reading the new columns too
--
-- Everything the old version did, it still does, the same way. Added:
--   * handed_off and the stage columns, if setup found them
--   * if Monday refuses the request because one of those columns is
--     gone, it tries again with only the original three columns, so
--     the floor keeps syncing, and logs what to fix
--   * if a configured column comes back on no job at all, that column
--     is left as it was rather than being blanked everywhere
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
      from jobs where monday_item_id is null and not is_test;

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

-- check_monday_sync() step 6 now leaves test jobs out (they never link to Monday)
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
  select count(*) into n from jobs where monday_item_id is null and not is_test;
  result := case when n = 0 then 'PASS' else 'FAIL' end;
  detail := case when n = 0 then null
                 else n || ' still unlinked: ' ||
                      (select string_agg(project_id, ', ') from jobs where monday_item_id is null and not is_test) ||
                      '. Either the sync hasn''t run since the upload, or the PROJ number isn''t on the board.' end;
  return next;
end;
$$;
revoke all on function check_monday_sync() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. v_handoff_tasks — the office's "Your tasks"
--
-- Every Pre-Production or In Production job whose Handed Off isn't Yes.
-- Nothing stored: it's worked out from what the sync read, so it can
-- never disagree with Monday for more than 15 minutes. A job whose
-- Handed Off hasn't been read yet (null) is left out, so the list can't
-- flood with every job before setup is done. Managers only.
-- ---------------------------------------------------------------------

drop view if exists v_handoff_tasks;
create view v_handoff_tasks with (security_invoker = true) as
select
  j.id              as job_id,
  j.project_id,
  j.name            as job_name,
  j.phase,
  j.delivery_date,
  j.handed_off_text
from jobs j
where j.monday_item_id is not null
  and not j.is_test
  and j.phase in ('Pre-Production', 'In Production')
  and j.handed_off is false
  and my_role() in ('manager', 'admin');

revoke all on v_handoff_tasks from anon;
grant select on v_handoff_tasks to authenticated;


-- ---------------------------------------------------------------------
-- 6. check_office() — the PASS / FAIL check
--
--     select * from check_office();
-- ---------------------------------------------------------------------

create or replace function check_office()
returns table (step int, check_name text, result text, detail text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as a supervisor
declare
  sup   uuid;
  mgr   uuid;
  n     int;
  m     int;
  ok    boolean;
  msg   text;
  last  monday_sync_log;
begin
  select id into sup from profiles where role = 'supervisor' and active limit 1;
  select id into mgr from profiles where role in ('manager','admin') and active limit 1;

  step := 1; check_name := 'Departments have live switches, and at least one is on';
  select count(*) filter (where is_live), count(*) into n, m from departments;
  result := case when m >= 7 and n >= 1 then 'PASS' else 'FAIL' end;
  detail := format('%s of %s live: %s', n, m, coalesce((select string_agg(name, ', ' order by sort_order) from departments where is_live), 'none'));
  return next;

  step := 2; check_name := 'The Handed Off column has been found on the Monday board';
  select count(*) into n from monday_columns where key = 'handed_off' and column_id is not null
     and (col_type = 'checkbox' or yes_label is not null);
  result := case when n = 1 then 'PASS' else 'FAIL' end;
  detail := case when n = 1 then (select format('"%s" (%s)', title, column_id) from monday_columns where key = 'handed_off')
                 else 'Run: select * from setup_monday_columns();  — it finds the column by its title and says what''s wrong.' end;
  return next;

  step := 3; check_name := 'The four stage columns have been found (needed for catch-up)';
  select count(*) into n from monday_columns where key <> 'handed_off' and column_id is not null;
  result := case when n = 4 then 'PASS' else 'FAIL' end;
  detail := case when n = 4 then (select string_agg(format('%s: "%s"', what, title), ' · ' order by sort_order) from monday_columns where key <> 'handed_off')
                 else format('%s of 4 found. Missing: %s. Run: select * from setup_monday_columns();', n,
                             (select string_agg(what, ', ' order by sort_order) from monday_columns where key <> 'handed_off' and column_id is null)) end;
  return next;

  step := 4; check_name := 'The sync has read Handed Off since it was set up';
  select * into last from monday_sync_log order by run_at desc limit 1;
  select count(*) into n from jobs where handed_off is not null;
  if last.id is null or not last.ok then
    result := 'FAIL'; detail := coalesce('The last sync failed: ' || last.summary, 'The sync hasn''t run yet.') || ' Run: select run_monday_sync();';
  elsif n = 0 then
    result := 'FAIL'; detail := 'No job has a Handed Off value yet. Run the sync once now: select run_monday_sync();';
  else
    result := 'PASS'; detail := format('%s jobs have a Handed Off value.', n);
  end if;
  return next;

  step := 5; check_name := 'Your tasks: the handoff list works';
  select count(*) into n from jobs j where j.monday_item_id is not null and not j.is_test
     and j.phase in ('Pre-Production', 'In Production') and j.handed_off is false;
  result := 'PASS';
  detail := format('%s job%s waiting to be handed off.', n, case when n = 1 then '' else 's' end);
  return next;

  -- 6 & 7: as a supervisor, the way the tablet would try it
  step := 6; check_name := 'A supervisor cannot switch a department live';
  if sup is null then
    result := 'FAIL'; detail := 'No supervisor login exists to test with.'; return next;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform set_department_live('metal', true);
      execute 'reset role';
      ok := false; msg := 'A supervisor switched a department live. Do not go further.';
      update departments set is_live = false where key = 'metal';   -- undo it
    exception when insufficient_privilege then
      execute 'reset role'; ok := true; msg := null;
    when others then
      execute 'reset role'; ok := false; msg := 'Unexpected error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; detail := msg; return next;

    step := 7; check_name := 'A supervisor sees no handoff tasks (office only)';
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_handoff_tasks;
      execute 'reset role';
      ok := (n = 0); msg := case when n = 0 then null else n || ' tasks visible to a supervisor.' end;
    exception when others then
      execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; detail := msg; return next;
    perform set_config('request.jwt.claims', '', true);
  end if;
end;
$$;
revoke all on function check_office() from public, anon, authenticated;
