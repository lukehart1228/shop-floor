#!/bin/bash
# Testing kit (12 Nov 2026). The 12 Nov release: two_day_rule.sql (R-26), checks_clean.sql (the checks, retiring a
# placeholder, R-14 accepted) and install_log.sql (the device line). It makes the OLD database look like live did on
# 12 Nov (a sales look-up login first by name, a real good save two days ago, the http extension's functions belonging
# to someone else and open to everyone, PROJ-00421-2 uploaded and reported by the sync, Maple 6/4 with no opening
# count, the devices as Luke pasted them), shows the old checks failing the way live's did, pastes the three files
# (each twice, each as one transaction), and shows every one of those checks full. Then each new piece is broken on
# purpose and the right line must fail. Needs sync_base_old and sync_base_new (README §2) and helpers/monday_standin.py.
H="-h /tmp/pg -p 5433"; P="timeout 280 psql $H -U postgres -X -q -At -v ON_ERROR_STOP=1"
SQL=${SQL:-/tmp/run_all_sql}
pg_isready -q -h /tmp/pg -p 5433 || { su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg/data -o '-k /tmp/pg -p 5433' -l /tmp/pg/log start" >/dev/null; sleep 2; }
for d in sync_base_old sync_base_new; do $P -d $d -c 'select 1' >/dev/null 2>&1 || { echo "FAIL no $d database. Make it first (README §2)."; exit 1; }; done
pass() { echo "PASS $1"; }; fail() { echo "FAIL $1  [$2]"; }
is() { if [ "$1" == "$2" ]; then pass "$3"; else fail "$3" "got '$1', expected '$2'"; fi; }
has() { if echo "$1" | grep -q -- "$2"; then pass "$3"; else fail "$3" "got '$1'"; fi; }
mk() { $P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$1' and pid<>pg_backend_pid()" -c "drop database if exists $1 with (force)" -c "create database $1 template $2" >/dev/null; }
score() { $P -d $1 -c "select count(*) filter (where result='PASS') || '/' || count(*) from $2()"; }
bad() { $P -d $1 -c "select string_agg(step::text, ' ' order by step) from $2() where result <> 'PASS'"; }
curl -s -m 2 http://127.0.0.1:8765/ >/dev/null || (setsid timeout 1500 python3 /home/claude/sf/base/monday_standin.py >/dev/null 2>&1 < /dev/null &)
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 2 http://127.0.0.1:8765/ >/dev/null && break; sleep 0.5; done

# ---- the seeded old database, made to look like live on 12 Nov -------------------------------------------------
TEMPLATE=sync_base_old bash /home/claude/sf/base/fresh.sh >/dev/null 2>&1; mk t_cc sync; D=t_cc
cat > /tmp/cc_live.sql <<'SQL'
-- a sales look-up login, first of the supervisors by name (live: B. Roberts)
insert into auth.users (id, email) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b.sales@example.com') on conflict do nothing;
insert into profiles (id, full_name, role, departments) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B. Sales', 'supervisor', '{}') on conflict (id) do nothing;
select set_look_up('b.sales@example.com');
-- a real save that reached both folders two days ago, and one today that missed the backup
insert into save_runs (client_id, run_by, run_by_name, how, started_at, finished_at, onedrive_ok, backup_ok, files_written)
  values (gen_random_uuid(), '22222222-2222-2222-2222-222222222222', 'Luke H', 'auto', now() - interval '2 days', now() - interval '2 days', true, true, 4),
         (gen_random_uuid(), '88888888-8888-8888-8888-888888888888', 'David D', 'button', now() - interval '1 hour', now() - interval '1 hour', true, false, 0);
-- the http extension's functions belong to someone else and are open to everyone (Supabase: supabase_admin)
do $$ declare f regprocedure; begin
  if not exists (select 1 from pg_roles where rolname = 'sim_supabase_admin') then create role sim_supabase_admin nosuperuser; end if;
  grant usage on schema extensions to sim_supabase_admin;
  for f in select p.oid::regprocedure from pg_proc p join pg_depend d on d.objid = p.oid and d.deptype = 'e' join pg_extension e on e.oid = d.refobjid where e.extname = 'http'
  loop execute format('alter function %s owner to sim_supabase_admin', f); execute format('grant execute on function %s to public', f); end loop;
end $$;
-- the month being counted has no opening count (live, 22 Oct: September's lumber was never counted, so October's Maple 6/4 had none)
insert into inv_months (month_end, status) values ('2026-09-30', 'closed') on conflict (month_end) do update set status = 'closed';
-- the page PROJ-00421 missed, uploaded under a number Monday doesn't have
select upload_work_order('{"project_id": "PROJ-00421-2", "project_name": "The missed page", "total_items": 2, "sheets": [{"sheet_number": 1, "item_code": "TB-9", "qty": 2, "departments": ["sanding", "finishing"]}]}') \g /dev/null
insert into vault.secrets (name, secret) values ('monday_token', 'stub-token') on conflict (name) do nothing;
select run_monday_sync('http://127.0.0.1:8765/') \g /dev/null
SQL
$P -d $D -f /tmp/cc_live.sql >/dev/null 2>/tmp/cc_live.err || { fail "the old database made to look like live" "$(tail -2 /tmp/cc_live.err)"; exit 1; }

echo "--- the old checks on it, failing the way live's did on 12 Nov"
is "$(score $D check_incomplete_deliveries)" "9/10" "old: check_incomplete_deliveries 9/10 (a sales look-up login taken for another department's supervisor)"
is "$(bad $D check_incomplete_deliveries)" "5" "old: it is step 5 that fails"
is "$(score $D check_onedrive_save)" "7/8" "old: check_onedrive_save 7/8 (a real good save in the last 8 days)"
is "$(score $D check_connector_safety)" "2/4" "old: check_connector_safety 2/4 (R-14: the functions aren't the SQL Editor's to close)"
is "$(score $D check_inventory)" "15/16" "old: check_inventory 15/16 when the live Maple 6/4 has no opening count"
is "$($P -d $D -c "select result from check_monday_sync() where step = 6")" "FAIL" "old: check_monday_sync step 6 fails on PROJ-00421-2"
has "$($P -d $D -c "select problems::text from monday_sync_log order by run_at desc limit 1")" "PROJ-00421-2 has a work order uploaded" "old: the sync reports PROJ-00421-2 on every run"
r=$($P -d $D -c "select count(*) from check_pace() where result <> 'PASS'")
echo "     (old check_pace today: $r failing; it fails only in the two weeks after a clock change, as on 12 Nov)"

echo "--- the release: two_day_rule.sql, checks_clean.sql, install_log.sql, each twice, each as one transaction"
for f in two_day_rule checks_clean install_log; do
  a=$($P -1 -d $D -f $SQL/$f.sql 2>&1 | grep -c "FAIL\|ERROR"); b=$($P -1 -d $D -f $SQL/$f.sql 2>&1 | grep -c "FAIL\|ERROR")
  is "$a $b" "0 0" "$f.sql runs twice with no FAIL row and no error"
done
is "$($P -d $D -c "select count(*) || ' ' || count(*) filter (where result = 'PASS') from whats_installed()")" "62 62" "whats_installed(): 62 files, all PASS"

echo "--- the same checks afterwards"
for c in check_incomplete_deliveries:10/10 check_onedrive_save:8/8 check_connector_safety:4/4 check_inventory:16/16 check_pace:13/13 check_off_supabase:10/10 check_zip_drop:12/12 check_two_day_rule:6/6 check_checks_clean:8/8 check_job_status:10/10 check_job_items:5/5; do
  is "$(score $D ${c%%:*})" "${c##*:}" "new: ${c%%:*} ${c##*:}"
done
has "$($P -d $D -c "select if_it_failed from check_connector_safety() where step = 1")" "^Accepted, not fixed (R-14, 12 Nov 2026, Luke)" "step 1 passes in words: accepted, not fixed, who and when"
has "$($P -d $D -c "select if_it_failed from check_connector_safety() where step = 2")" "nothing a page can reach does" "step 2 passes in words: nothing a page can reach gets to the internet"
is "$($P -d $D -c "select is_active::text || ' ' || (retired_at is not null)::text || ' ' || (floor_left_at is not null)::text from jobs where project_id = 'PROJ-00421-2'")" "false true true" "PROJ-00421-2 is retired by the paste: inactive, stamped, off the floor"
is "$($P -d $D -c "select (select count(*) from work_orders w where w.job_id = j.id) || ' ' || (select count(*) from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = j.id) || ' ' || (select count(*) from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id where w.job_id = j.id) from jobs j where project_id = 'PROJ-00421-2'")" "1 1 2" "its work order, sheet and both departments' counts are still there"
has "$($P -d $D -c "select why from retired_placeholders() where project_id = 'PROJ-00421-2'")" "A page missed from PROJ-00421" "retired_placeholders() lists it with why"
$P -d $D -c "select run_monday_sync('http://127.0.0.1:8765/')" >/dev/null
is "$($P -d $D -c "select problems::text from monday_sync_log order by run_at desc limit 1")" "[]" "the patched sync (the real function, against the stand-in Monday) no longer reports it"
is "$($P -d $D -c "select count(*) from jobs where project_id in ('PROJ-09001','PROJ-09002') and monday_item_id is not null")" "2" "and still reads the board and saves its jobs"
has "$($P -d $D -c "select result || ' ' || detail from check_monday_sync() where step = 6")" "^PASS Not counted: 1 retired placeholder (PROJ-00421-2)" "check_monday_sync step 6 passes and names what it didn't count"
r=$($P -d $D -c "select step || ' ' || check_name from check_everything() where result <> 'PASS' and check_name not in ('check_monday_sync', 'check_office', 'check_catch_up')" | tr '\n' ';')
is "$r" "" "check_everything(): every line PASS but the three that need the real Monday's schedule and columns"
has "$($P -d $D -c "select detail from check_everything() where check_name = 'check_connector_safety'")" "^4/4. 2 of them accepted, not fixed (R-14, 12 Nov 2026, Luke)" "check_everything() says 4/4 with 2 accepted, not fixed (R-14)"

echo "--- through the logins (as Supabase's API connects)"
as() { if [ "$1" == anon ]; then pre="set role anon;"; else pre="set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false) \\g /dev/null"; fi
  printf "%s\n%s\n" "$pre" "$2" > /tmp/as_cc.sql; psql $H -U authenticator -d $D -q -At -v ON_ERROR_STOP=1 -f /tmp/as_cc.sql > /tmp/as_cc.out 2>&1; grep -v "^CONTEXT" /tmp/as_cc.out | tail -1; }
LUKE=22222222-2222-2222-2222-222222222222; MIKE=11111111-1111-1111-1111-111111111111; SALES=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
has "$(as $LUKE "select retire_placeholder('PROJ-00421-2', 'x')")" "permission denied" "a manager's login can't retire a placeholder"
has "$(as $LUKE "select * from retired_placeholders()")" "permission denied" "nor list them (SQL Editor only)"
has "$(as $LUKE "select count(*) from accepted_findings")" "permission denied" "nor read what's been accepted"
has "$(as anon "select count(*) from accepted_findings")" "permission denied" "no login reads accepted_findings"
is "$(as $LUKE "select jsonb_array_length(job_lookup('421') -> 'jobs')")" "0" "Luke's Job status look-up for 421 doesn't find the retired placeholder"
is "$(as $SALES "select jsonb_array_length(job_lookup('PROJ-00421-2') -> 'jobs')")" "0" "nor does a sales look-up login's"
is "$(as $LUKE "select jsonb_array_length(job_lookup('99') -> 'jobs') > 0")" "t" "an ordinary job is still found"
is "$(as $LUKE "select count(*) from v_uploaded_jobs where project_id = 'PROJ-00421-2' and is_active")" "0" "it's off the office's list of live uploads"
is "$(as $LUKE "select count(*) from v_job_department_progress p join jobs j on j.id = p.job_id where j.project_id = 'PROJ-00421-2'")" "0" "and off the office's job grid"
is "$(as $MIKE "select count(*) from v_floor_sheets where project_id = 'PROJ-00421-2'")" "0" "Mike's tablet doesn't show it (it never did: Monday doesn't have it)"
has "$(as $LUKE "select upload_work_order('{\"project_id\": \"PROJ-00421-2\", \"total_items\": 1, \"sheets\": [{\"sheet_number\": 1, \"item_code\": \"TB-9\", \"qty\": 1, \"departments\": [\"sanding\"]}]}')"; grep -m1 ERROR /tmp/as_cc.out)" "PROJ-00421-2 was retired on .* and takes no more work orders" "Luke's upload under the retired number is refused in plain words"
is "$($P -d $D -c "select count(*) from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00421-2'")" "1" "and nothing was saved"
has "$(as $LUKE "select upload_work_order('{\"project_id\": \"PROJ-00099\", \"total_items\": 1, \"sheets\": [{\"sheet_number\": 1, \"item_code\": \"TB-9\", \"qty\": 1, \"departments\": [\"sanding\"]}]}')->>'ok'")" "true" "an upload to an ordinary job still saves"

echo "--- R-26 through a manager's login: a photo found in both places today stays; a day later it goes"
cat > /tmp/cc_r26.sql <<'SQL'
insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999960, 'PROJ-09960', 'Two-day test', false, 'Complete');
update jobs set floor_left_at = now() - interval '61 days' where project_id = 'PROJ-09960';
insert into loadouts (id, job_id, kind, scheduled_for, started_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
  select 'cccccccc-0000-0000-0000-000000000001', id, 'delivery', now() - interval '62 days', now() - interval '62 days', now() - interval '61 days', 'T', 'T', now() - interval '61 days', now() - interval '61 days' from jobs where project_id = 'PROJ-09960';
insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PROJ-09960/cccccccc-0000-0000-0000-000000000002.jpg', '{"size": 1234}');
insert into photos (id, client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes, taken_at)
  select 'cccccccc-0000-0000-0000-000000000002', gen_random_uuid(), id, 'delivery', 'loadout', 'cccccccc-0000-0000-0000-000000000001', 1, 1, 'site', 'PROJ-09960/cccccccc-0000-0000-0000-000000000002.jpg', 'T', 1234, now() - interval '61 days' from jobs where project_id = 'PROJ-09960';
SQL
$P -d $D -f /tmp/cc_r26.sql >/dev/null
REC="select record_filed_copies('[{\"source\":\"photo\",\"id\":\"cccccccc-0000-0000-0000-000000000002\",\"place\":\"onedrive\",\"bytes\":1234},{\"source\":\"photo\",\"id\":\"cccccccc-0000-0000-0000-000000000002\",\"place\":\"backup\",\"bytes\":1234}]')->>'recorded'"
is "$(as $LUKE "$REC")" "2" "the save reports the photo found in OneDrive and the backup"
is "$(as $LUKE "select jsonb_array_length(files_ready_to_remove(1000))")" "0" "the same save's list of files to take off Supabase is empty"
has "$(as $LUKE "select set_config('storage.allow_delete_query','true',false) \\g /dev/null
delete from storage.objects where bucket_id = 'photos' and name like 'PROJ-09960/%' returning 1")" "^$" "and storage itself won't let a manager remove it today"
$P -d $D -c "update filed_copies set first_seen = first_seen - interval '25 hours', checked_at = checked_at - interval '25 hours' where file_id = 'cccccccc-0000-0000-0000-000000000002'"
is "$(as $LUKE "select jsonb_array_length(files_ready_to_remove(1000))")" "0" "a day later, before the save has looked again, it still stays (the look is a day old)"
is "$(as $LUKE "$REC")" "2" "the next day's save finds both copies again"
is "$(as $LUKE "select files_ready_to_remove(1000) -> 0 ->> 'path'")" "PROJ-09960/cccccccc-0000-0000-0000-000000000002.jpg" "now it's on the list"
is "$(as $LUKE "select set_config('storage.allow_delete_query','true',false) \\g /dev/null
delete from storage.objects where bucket_id = 'photos' and name like 'PROJ-09960/%' returning 1")" "1" "and storage lets the manager remove it"
is "$(as $LUKE "select mark_filed_removed('[{\"source\":\"photo\",\"id\":\"cccccccc-0000-0000-0000-000000000002\"}]')->>'photos'")" "1" "the record stays, marked as off Supabase"

echo "--- the device line, with rows shaped like the 12 Nov devices() paste"
cat > /tmp/cc_dev.sql <<'SQL'
delete from device_versions;
insert into auth.users (id, email) values ('dddddddd-0000-0000-0000-000000000001', 'homag@example.com') on conflict do nothing;
insert into device_versions (device_id, page, version, user_id, last_seen) values
  ('tab-sanding-1', 'index', '2026-11-11.1', '11111111-1111-1111-1111-111111111111', now() - interval '2 hours'),
  ('tab-assembly1', 'index', '2026-11-04.2', '66666666-6666-6666-6666-666666666666', now() - interval '2 days'),
  ('tab-metal-001', 'index', '2026-11-04.2', '55555555-5555-5555-5555-555555555555', now() - interval '3 days'),
  ('phone-shawn-1', 'index', '2026-11-11.1', '77777777-7777-7777-7777-777777777777', now() - interval '1 hour'),
  ('phone-shawn-0', 'index', '2026-10-06.1', '77777777-7777-7777-7777-777777777777', now() - interval '37 days'),
  ('pc-homag-0001', 'machine', '2026-11-04.1', 'dddddddd-0000-0000-0000-000000000001', now() - interval '1 day'),
  ('pc-luke-00001', 'office', '2026-11-11.2', '22222222-2222-2222-2222-222222222222', now() - interval '10 minutes'),
  ('pc-luke-00001', 'delivery', '2026-11-04.1', '22222222-2222-2222-2222-222222222222', now() - interval '1 day'),
  ('pc-luke-00001', 'inventory', '2026-11-05.2', '22222222-2222-2222-2222-222222222222', now() - interval '7 days'),
  ('pc-luke-00001', 'index', '2026-11-04.2', '22222222-2222-2222-2222-222222222222', now() - interval '3 days'),
  ('pc-luke-00002', 'index', '2026-11-04.2', '22222222-2222-2222-2222-222222222222', now() - interval '1 day'),
  ('pc-david-0001', 'office', '2026-11-11.1', '88888888-8888-8888-8888-888888888888', now() - interval '3 hours'),
  ('pc-julia-0001', 'delivery', '2026-11-11.1', '77777777-7777-7777-7777-777777777777', now() - interval '2 hours'),
  ('pc-other-0001', 'inventory', '2026-11-10.1', '88888888-8888-8888-8888-888888888888', now() - interval '1 day');
SQL
$P -d $D -f /tmp/cc_dev.sql >/dev/null
r=$($P -d $D -c "select result || ' | ' || detail from check_everything() where check_name like 'Every device%'")
has "$r" "^FAIL | 2 floor devices on an older page: " "the line fails on the two tablets really behind, and only those"
has "$r" "KP (2026-11-04.2" "KP's tablet is named"; has "$r" "Willie J (2026-11-04.2" "Willie's tablet is named"
if echo "$r" | grep -q "Luke H\|David D"; then fail "no manager's computer is named" "$r"; else pass "no manager's computer is named (Luke's old tablet-app rows, David's office a version behind)"; fi
has "$r" "1 not opened in 14 days, not counted" "Shawn's phone row from 37 days ago isn't counted"
has "$r" "Also not counted: 8 office and earlier rows" "the office and earlier rows are counted up, not failed on"
is "$($P -d $D -c "select note from devices() where person = 'Luke H' and page = 'delivery'")" "An earlier page on this device — not counted (its latest page is what counts)" "devices(): Luke's older Deliveries row says its latest page is what counts"
has "$($P -d $D -c "select note from devices() where person = 'David D' and page = 'office'")" "^Office computer, older page when last opened — not counted" "devices(): David's office row says it isn't counted"
is "$($P -d $D -c "select note from devices() where person = 'KP'")" "Older page — close the app fully and reopen it on Wi-Fi" "devices(): KP's row says what to do"
$P -d $D -c "update device_versions set version = '2026-11-11.1', last_seen = now() where device_id in ('tab-assembly1', 'tab-metal-001')"
r=$($P -d $D -c "select result || ' | ' || detail from check_everything() where check_name like 'Every device%'")
has "$r" "^PASS | 5 floor devices opened in the last 14 days, all on the newest page (1 not opened in 14 days, not counted)" "once both tablets reopen, the line passes: 4 tablets and phones and the Homag's computer"
$P -d $D -c "update device_versions set version = '2026-11-01.1' where device_id = 'pc-homag-0001'; insert into device_versions (device_id, page, version, user_id) values ('pc-bendtech-1', 'machine', '2026-11-04.1', 'dddddddd-0000-0000-0000-000000000001')"
has "$($P -d $D -c "select result || ' | ' || detail from check_everything() where check_name like 'Every device%'")" "^FAIL | 1 floor device on an older page: (no profile) (2026-11-01.1" "a machine's computer on an older machine page fails the line too"

echo "--- broken on purpose: the right line must fail"
brk() { # name, check, expected failing steps, sql
  mk t_ccb $D; $P -d t_ccb -c "$4" >/dev/null 2>/tmp/cc_brk.err || { fail "break: $1" "the break itself failed: $(tail -1 /tmp/cc_brk.err)"; return; }
  is "$(bad t_ccb $2)" "$3" "break: $1 → $2 step $3 fails"; }
brk "R-14's acceptance withdrawn" check_connector_safety "1 2" "update accepted_findings set withdrawn_at = now() where finding = 'R-14'"
brk "an http function the SQL Editor could close is open" check_connector_safety "1 2" "alter function extensions.http_get(varchar) owner to postgres; grant execute on function extensions.http_get(varchar) to anon"
brk "a function a login may run reaches the internet" check_connector_safety "2" "create function public.fetch_it(u text) returns int language sql as 'select (extensions.http_get(u)).status'; revoke all on function public.fetch_it(text) from public, anon; grant execute on function public.fetch_it(text) to authenticated"
brk "a login may run something that calls the Monday sync" check_connector_safety "2" "create function public.sync_now() returns jsonb language sql security definer as 'select public.run_monday_sync()'; revoke all on function public.sync_now() from public, anon; grant execute on function public.sync_now() to authenticated"
brk "the API told to serve the extensions schema" check_connector_safety "2" "alter role authenticator in database t_ccb set pgrst.db_schemas = 'public, graphql_public, extensions'"
brk "a new SECURITY DEFINER function left open" check_connector_safety "4" "create function public.leaky() returns int language sql security definer as 'select 1'"
brk "the http extension switched off" check_connector_safety "3" "drop extension http cascade"
: "the Monday sync's owner unable to reach http can't be modelled here: on this database, as on live, http is open to every role" "3" "do \$\$ begin if not exists (select 1 from pg_roles where rolname='sim_owner') then create role sim_owner nosuperuser; end if; end \$\$; alter function run_monday_sync(text) owner to sim_owner"
brk "PROJ-00421-2 un-retired" check_checks_clean "3" "update jobs set retired_at = null, is_active = true where project_id = 'PROJ-00421-2'"
brk "R-14's record gone" check_checks_clean "4" "delete from accepted_findings"
brk "retire_placeholder granted to logins" check_checks_clean "1 6 7" "grant execute on function retire_placeholder(text, text) to authenticated"
brk "the upload guard switched off" check_checks_clean "1 8" "alter table work_orders disable trigger work_orders_retired_guard"
brk "the old job_lookup back (finds retired placeholders)" check_checks_clean "2 6" "$(sed -n '/^create or replace function job_lookup/,/^\$\$;/p' /home/claude/sf/repo/sql/job_status.sql)"
brk "the old check_pace back" check_checks_clean "2" "$(sed -n '/^create or replace function check_pace/,/^\$\$;/p' /home/claude/sf/repo/sql/pace.sql)"
brk "the one-day rule back for photos" check_two_day_rule "2 3 4 5" "$(sed -n '/^create or replace function filed_removable/,/^end \$\$;/p' /home/claude/sf/repo/sql/off_supabase.sql)"
brk "the one-day rule back for zip files" check_two_day_rule "2" "$(sed -n '/^create or replace function parked_removable/,/^\$\$;/p' /home/claude/sf/repo/sql/zip_drop.sql)"
brk "the one-day rule back for zip files (its own check)" check_zip_drop "9" "$(sed -n '/^create or replace function parked_removable/,/^\$\$;/p' /home/claude/sf/repo/sql/zip_drop.sql)"
brk "the save's report forgets when a copy was first found" check_two_day_rule "2 5" "$(sed -n '/^create or replace function record_filed_copies/,/^end \$\$;/p' /home/claude/sf/repo/sql/off_supabase.sql)"
brk "a zip file's report forgets when it was first found" check_two_day_rule "2 6" "$(sed -n '/^create or replace function record_parked_filed/,/^end \$\$;/p' /home/claude/sf/repo/sql/zip_drop.sql)"
brk "a found zip file with no first-found time" check_two_day_rule "1" "insert into zip_drops (id, zip_name, format, contents, dropped_by) values ('eeeeeeee-0000-0000-0000-000000000001', 'x.zip', 1, '{}', '22222222-2222-2222-2222-222222222222'); insert into parked_files (drop_id, zip_path, place, rel_path, what, size_bytes, sha256, storage_path, stored_at, onedrive_at, onedrive_bytes) values ('eeeeeeee-0000-0000-0000-000000000001', 'Database/Metal/Cut sheets/x.pdf', 'library', 'Metal/Cut sheets/x.pdf', 'cut sheet', 5, repeat('e', 64), 'x/y.pdf', now(), now(), 5)"

echo "--- the other paste order (install_log.sql first) and the old files now stop"
TEMPLATE=sync_base_old bash /home/claude/sf/base/fresh.sh >/dev/null 2>&1; mk t_cc2 sync
r=$($P -1 -d t_cc2 -f $SQL/install_log.sql 2>&1 | grep -c "Not installed")
is "$r" "2" "install_log.sql pasted first: its table shows the two new files as not installed yet, nothing else"
for f in two_day_rule checks_clean; do is "$($P -1 -d t_cc2 -f $SQL/$f.sql 2>&1 | grep -c "FAIL\|ERROR")" "0" "then $f.sql: no FAIL, no error"; done
is "$($P -d t_cc2 -c "select count(*) filter (where result = 'PASS') from whats_installed()")" "62" "and whats_installed() is 62 PASS"
for f in off_supabase short_names pace onedrive_save connector_safety incomplete_deliveries inventory office job_status; do
  has "$($P -1 -d t_cc2 -f /home/claude/sf/repo/sql/$f.sql 2>&1 | grep -m1 "ERROR")" "Stop — nothing was changed" "$f.sql run again now stops, changing nothing"
done
for d in t_cc t_ccb t_cc2; do $P -d postgres -c "drop database if exists $d with (force)" >/dev/null; done
