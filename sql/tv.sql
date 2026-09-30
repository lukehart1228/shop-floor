-- =====================================================================
-- Shop Floor — the floor TV (whole-floor build, step 9)
--
-- HOW TO USE: run problems.sql, flags.sql and arrow_qc.sql first. Then
-- paste this whole file into a NEW, empty query in the Supabase SQL
-- Editor and click Run. Safe to run more than once.
--
-- The TV page (tv.html) has no login. Instead it's opened with a secret
-- link made on the office page (Setup → TV link). Without that link the
-- database hands out nothing — someone with no login still sees nothing.
-- Making a new link switches the old one off.
--
-- What the TV gets: live departments only (not log-only ones), real jobs
-- only (never test jobs), and only the numbers the screen shows — no
-- project values, no per-person numbers.
-- =====================================================================

-- Install log (install_log.sql): records this run, and stops here, changing
-- nothing, if a newer file that replaced pieces of this one is installed.
do $$ begin
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('tv.sql'); end if;
end $$;

do $$
begin
  if to_regclass('public.flags') is null or to_regclass('public.outside_jobs') is null then
    raise exception 'Run problems.sql, flags.sql and arrow_qc.sql first (steps 4, 5 and 8). This file builds on them.';
  end if;
end $$;

-- a new TV link: returns the secret once; only its fingerprint is kept
create or replace function new_tv_link() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_key text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not office_ok() then
    raise exception 'Only a manager can make the TV link.' using errcode = 'insufficient_privilege';
  end if;
  insert into app_settings (key, value, updated_by_name, updated_at)
  values ('secret_tv_key_hash', to_jsonb(encode(sha256(convert_to(v_key, 'UTF8')), 'hex')), my_name(), now())
  on conflict (key) do update set value = excluded.value, updated_by_name = excluded.updated_by_name, updated_at = now();
  insert into app_settings (key, value, updated_by_name, updated_at)
  values ('tv_link_made', to_jsonb(now()), my_name(), now())
  on conflict (key) do update set value = excluded.value, updated_by_name = excluded.updated_by_name, updated_at = now();
  return jsonb_build_object('ok', true, 'key', v_key,
                            'summary', 'New TV link made. Any TV using an older link has stopped showing numbers.');
end $$;
revoke all on function new_tv_link() from public, anon;
grant execute on function new_tv_link() to authenticated;

create or replace function tv_snapshot(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_hash  text;
  v_today date := local_today();
  v_alert int;
  v_out   jsonb;
begin
  select value #>> '{}' into v_hash from app_settings where key = 'secret_tv_key_hash';
  if v_hash is null or nullif(p_key, '') is null or encode(sha256(convert_to(p_key, 'UTF8')), 'hex') <> v_hash then
    return jsonb_build_object('ok', false,
      'reason', 'This TV link isn''t valid any more. Make a new one on the office page (Setup → TV link) and open it on this screen.');
  end if;
  select coalesce((select (value #>> '{}')::int from app_settings where key = 'arrow_alert_days'), 14) into v_alert;

  with live as (
    select key, name, sort_order from departments where is_live and not log_only
  ),
  r as (      -- every live-department count on real, active, linked jobs
    select j.id as job_id, j.project_id, j.name as job_name, j.delivery_date, j.materials_ordered,
           sp.department, sp.qty_done, sp.qty_required, coalesce(rw.ready, 0) as ready
      from sheet_progress sp
      join live l        on l.key = sp.department
      join sheets s      on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id and w.is_current
      join jobs j        on j.id = w.job_id and j.is_active and not j.is_test and j.monday_item_id is not null
      left join v_ready_to_work rw on rw.sheet_id = sp.sheet_id and rw.department = sp.department
  ),
  per_job as (
    select job_id, project_id, job_name, delivery_date, materials_ordered,
           sum(qty_required - qty_done) as left_n, sum(qty_done) as done_n, sum(qty_required) as total_n
      from r group by job_id, project_id, job_name, delivery_date, materials_ordered
  ),
  on_floor as (select * from per_job where left_n > 0),
  per_dept as (
    select l.key, l.name, l.sort_order,
           coalesce(sum(r.qty_required - r.qty_done), 0) as left_n,
           coalesce(sum(r.ready), 0) as ready_n,
           count(distinct r.job_id) filter (where r.qty_done < r.qty_required) as jobs_n
      from live l left join r on r.department = l.key
     group by l.key, l.name, l.sort_order
  ),
  open_flags as (
    select f.job_id, f.level, f.note, f.department, d.name as department_name, j.project_id, j.name as job_name
      from flags f join jobs j on j.id = f.job_id
      left join departments d on d.key = f.department
     where f.cleared_at is null and not f.is_test and j.is_active
       and (f.department is null or f.department in (select key from live))
  ),
  tbl as (
    select o.*, (o.delivery_date - v_today) as days,
           (select case max(case level when 'critical' then 3 when 'priority' then 2 else 1 end)
                   when 3 then 'critical' when 2 then 'priority' when 1 then 'watch' end
              from open_flags f where f.job_id = o.job_id) as flag
      from on_floor o
     order by o.delivery_date nulls last, o.project_id
     limit 15
  ),
  attention as (
    select 1 as ord, p.raised_at as at,
           left(format('%s%s · %s: %s', j.project_id, coalesce(' sheet ' || p.sheet_number, ''), d.name, p.body), 160) as text,
           'stopped' as kind
      from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
     where p.status = 'open' and p.work_stopped and not p.is_test and j.is_active
       and p.department in (select key from live)
    union all
    select 2, o.sent_at,
           format('%s at Arrow %s days — %s', j.project_id, v_today - o.sent_on,
                  coalesce(o.description, 'sheet' || case when cardinality(o.sheet_numbers) = 1 then ' ' else 's ' end
                                          || array_to_string(o.sheet_numbers, ', '))),
           'arrow'
      from outside_jobs o join jobs j on j.id = o.job_id
     where o.returned_on is null and o.voided_at is null and not o.is_test and v_today - o.sent_on > v_alert
    union all
    select 3, null, format('%s — materials not marked ordered in Monday, due in %s days', t.project_id, t.days), 'materials'
      from tbl t where not t.materials_ordered and t.days <= 14
  )
  select jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'today', v_today,
    'arrow_alert_days', v_alert,
    'live', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'name', name, 'left', left_n, 'ready', ready_n, 'jobs', jobs_n)
                                       order by sort_order) from per_dept), '[]'::jsonb),
    'kpis', jsonb_build_object(
       'jobs',  (select count(*) from on_floor),
       'left',  (select coalesce(sum(left_n), 0) from on_floor),
       'ready', (select coalesce(sum(ready_n), 0) from per_dept),
       'due14', (select count(*) from on_floor where delivery_date - v_today <= 14)),
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'table', coalesce((select jsonb_agg(jsonb_build_object(
                 'project_id', t.project_id, 'job_name', t.job_name, 'delivery_date', t.delivery_date, 'days', t.days,
                 'flag', t.flag,
                 'depts', (select jsonb_agg(jsonb_build_object('key', l.key,
                                   'done', coalesce((select sum(qty_done) from r where r.job_id = t.job_id and r.department = l.key), 0),
                                   'total', coalesce((select sum(qty_required) from r where r.job_id = t.job_id and r.department = l.key), 0))
                                   order by l.sort_order) from live l))
               order by t.delivery_date nulls last, t.project_id) from tbl t), '[]'::jsonb),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;
revoke all on function tv_snapshot(text) from public;
grant execute on function tv_snapshot(text) to anon, authenticated;
