-- review/snapshot.sql — the reviewer's view of the live database.
--
-- READ ONLY. This is a single SELECT: it changes nothing, logs nothing,
-- and is not part of the install log or check_everything().
-- It shows no logins, no email addresses, no job data and no secrets.
--
-- How to use: paste it all into the Supabase SQL Editor and run it.
-- The first three rows are PASS/FAIL headlines. Then use the results'
-- export button (Export → CSV) and attach the file to a reviewer chat.

with
tbl as (
  select n.nspname, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity,
         c.reloptions, pg_get_userbyid(c.relowner) as owner
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r','p','v','m')
    and (n.nspname = 'public' or (n.nspname = 'storage' and c.relname in ('objects','buckets')))
),
fn as (
  select p.oid, n.nspname, p.proname, p.prosecdef, p.proconfig, p.prosrc,
         pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f','p')
    and not exists (select 1 from pg_depend d
                    where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
),
rows as (
  -- Headlines
  select 0 as ord, 'Headline' as section,
         'Row-level security on every table' as name,
         case when count(*) filter (where not relrowsecurity) = 0 then 'PASS'
              else 'FAIL — RLS is off on: ' || string_agg(relname, ', ') filter (where not relrowsecurity) end as detail
  from tbl where nspname = 'public' and relkind in ('r','p')
  union all
  select 0, 'Headline', 'Every storage bucket is private',
         case when count(*) filter (where public) = 0 then 'PASS'
              else 'FAIL — public: ' || string_agg(id, ', ') filter (where public) end
  from storage.buckets
  union all
  select 0, 'Headline', 'Every SECURITY DEFINER function fixes its search_path',
         case when count(*) filter (where prosecdef and not coalesce(array_to_string(proconfig, ' ') like '%search_path=%', false)) = 0
              then 'PASS'
              else 'FAIL — not set on: ' || string_agg(proname, ', ')
                     filter (where prosecdef and not coalesce(array_to_string(proconfig, ' ') like '%search_path=%', false)) end
  from fn

  -- 1. Tables and their row-level security
  union all
  select 1, '1 Table', nspname || '.' || relname,
         case when relrowsecurity then 'RLS on' else 'RLS OFF' end
         || case when relforcerowsecurity then ', forced' else '' end
         || ' · owner ' || owner
  from tbl where relkind in ('r','p')

  -- 2. Policies (public tables and storage)
  union all
  select 2, '2 Policy', schemaname || '.' || tablename || ' · ' || policyname,
         permissive || ' ' || cmd || ' to ' || array_to_string(roles, ',')
         || ' · using: ' || coalesce(qual, '—')
         || ' · check: ' || coalesce(with_check, '—')
  from pg_policies where schemaname in ('public','storage')

  -- 3. Table and view grants to the login roles
  union all
  select 3, '3 Grant', table_schema || '.' || table_name,
         grantee || ': ' || string_agg(privilege_type, ', ' order by privilege_type)
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon','authenticated','PUBLIC')
  group by table_schema, table_name, grantee

  -- 4. Column-by-column grants
  union all
  select 4, '4 Column grant', n.nspname || '.' || c.relname || '.' || a.attname,
         array_to_string(a.attacl, ' ')
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped and a.attacl is not null

  -- 5. Views: does each one respect row-level security?
  union all
  select 5, '5 View', nspname || '.' || relname,
         case when coalesce(array_to_string(reloptions, ','), '') ~* 'security_invoker=(true|on|1|yes)'
              then 'security_invoker (respects RLS)'
              else 'runs as its owner ' || owner || ' (skips RLS on the tables it reads)' end
  from tbl where relkind in ('v','m')

  -- 6. Functions: definer or not, search_path, who can call, fingerprint
  union all
  select 6, '6 Function', proname || '(' || args || ')',
         case when prosecdef then 'SECURITY DEFINER' else 'invoker' end
         || ' · search_path ' || coalesce((select string_agg(x, ',') from unnest(proconfig) x where x like 'search_path=%'), 'NOT SET')
         || ' · callable by: ' || coalesce(nullif(concat_ws(', ',
               case when has_function_privilege('anon', oid, 'EXECUTE') then 'anon (no login)' end,
               case when has_function_privilege('authenticated', oid, 'EXECUTE') then 'authenticated' end), ''), 'neither login role')
         || ' · body md5 ' || left(md5(prosrc), 12)
  from fn

  -- 7. Storage buckets
  union all
  select 7, '7 Bucket', id,
         case when public then 'PUBLIC' else 'private' end
         || ' · size limit ' || coalesce(file_size_limit::text || ' bytes', 'none')
         || ' · types ' || coalesce(array_to_string(allowed_mime_types, ', '), 'any')
  from storage.buckets

  -- 8. Scheduled jobs (name, timing and on/off only; commands are in the repo)
  union all
  select 8, '8 Scheduled job', jobname,
         schedule || ' · ' || case when active then 'on' else 'OFF' end
  from cron.job

  -- 9. Extensions and where they live
  union all
  select 9, '9 Extension', e.extname, e.extversion || ' in schema ' || n.nspname
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
)
select section, name, detail
from rows
order by ord, section, name;
