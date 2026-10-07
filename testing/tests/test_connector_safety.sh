#!/bin/bash
# Testing kit (7 Oct 2026). connector_safety.sql (R-14, R-17): the old and new databases side by side,
# the real run_monday_sync() against a local Monday stand-in (helpers/monday_standin.py), a role shaped
# like Supabase's read-only connector user, then each step of check_connector_safety() broken on purpose.
# Needs sync_base_old and sync_base_new (README §2). F= the file to test (default: the repo's copy).
H="-h /tmp/pg -p 5433"; P="timeout 120 psql $H -U postgres -X -q -At -v ON_ERROR_STOP=1"
F=${F:-/home/claude/sf/repo/sql/connector_safety.sql}
for d in sync_base_old sync_base_new; do $P -d $d -c 'select 1' >/dev/null 2>&1 || { echo "FAILED: no $d database. Make it first (README §2)."; exit 1; }; done
pass=0; fail=0
ok(){ if [ "${1:-0}" = "1" ]; then pass=$((pass+1)); echo "PASS  $2"; else fail=$((fail+1)); echo "FAIL  $2  [$3]"; fi; }
mk(){ $P -d postgres -c "drop database if exists $1 with (force)" -c "create database $1 template $2"; }
curl -s -m 2 http://127.0.0.1:8765/ >/dev/null || (setsid timeout 900 python3 /home/claude/sf/base/monday_standin.py >/dev/null 2>&1 < /dev/null &)
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s http://127.0.0.1:8765/ >/dev/null && break; sleep 0.5; done

# a role shaped like Supabase's read-only connector user (the reviewer's sandbox shape)
$P -d postgres -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='supabase_read_only_user') then
  create role supabase_read_only_user login bypassrls; end if; end \$\$;
  grant pg_read_all_data, pg_monitor to supabase_read_only_user;
  alter role supabase_read_only_user set default_transaction_read_only = on;"
RO="psql $H -U supabase_read_only_user -X -q -At"

for side in old new; do
  db=t_cs_$side; mk $db sync_base_$side
  $P -d $db -c "insert into vault.secrets(name, secret) values ('monday_token','stub-token') on conflict (name) do nothing"
  r=$($P -d $db -c "select run_monday_sync('http://127.0.0.1:8765/')->>'ok'" 2>&1)
  j=$($P -d $db -c "select count(*) from jobs where project_id in ('PROJ-09001','PROJ-09002')")
  ok $([ "$r" = "true" ] && [ "$j" = "2" ] && echo 1 || echo 0) "$side database: the Monday sync (as postgres, like the timer) reads the board and saves both jobs" "$r / $j"
  ro=$($RO -d $db -c "select status from extensions.http_get('http://127.0.0.1:8765/')" 2>&1)
  had=$($P -d $db -c "select to_regprocedure('public.check_connector_safety()') is not null")
  if [ $side = old ] && [ "$had" = "f" ]; then
    ok $([ "$ro" = "200" ] && echo 1 || echo 0) "old database: the read-only user CAN reach the internet (R-14 as found)" "$ro"
  elif [ $side = old ]; then
    ok $(echo "$ro" | grep -q "permission denied" && echo 1 || echo 0) "old database (already fixed): the read-only user is refused" "$ro"
  else
    ok $(echo "$ro" | grep -q "permission denied for function http_get" && echo 1 || echo 0) "new database: the read-only user is refused" "$ro"
    ro2=$($RO -d $db -c "select status from extensions.http((('GET','http://127.0.0.1:8765/',null,null,null))::extensions.http_request)" 2>&1)
    ok $(echo "$ro2" | grep -q "permission denied" && echo 1 || echo 0) "new database: the read-only user is refused http() too" "$ro2"
    ro3=$($RO -d $db -c "begin; set transaction read write; select set_person('x@example.com','X','supervisor','{}',false);" 2>&1)
    ok $(echo "$ro3" | grep -q "permission denied for function set_person" && echo 1 || echo 0) "new database: the read-only user can't run a setup function even with set transaction read write" "$ro3"
    t=$($P -d $db -c "select count(*) from check_connector_safety() where result='PASS'")
    ok $([ "$t" = "4" ] && echo 1 || echo 0) "new database: check_connector_safety() 4/4 with the read-only user present" "$t"
  fi
done

# the file runs on the old database (what live is today) twice, each as one transaction
mk t_cs_run sync_base_old
a=$($P -1 -d t_cs_run -f $F 2>&1 | tail -4 | tr '\n' ' '); b=$($P -1 -d t_cs_run -f $F 2>&1 | grep -c PASS)
ok $([ "$b" = "4" ] && echo 1 || echo 0) "runs on the old database twice, 4/4 PASS both times" "$a / $b"

# ---- each step broken on purpose; the right step must fail ----
brk(){ # name, expected failing steps (space-separated), sql to break
  mk t_cs_b sync_base_new; $P -d t_cs_b -c "$3" >/dev/null 2>&1 || { ok 0 "break: $1" "the break itself failed"; return; }
  got=$($P -d t_cs_b -c "select string_agg(step::text, ' ' order by step) from check_connector_safety() where result<>'PASS'")
  msg=$($P -d t_cs_b -c "select string_agg(if_it_failed, ' | ') from check_connector_safety() where result<>'PASS'")
  ok $([ "$got" = "$2" ] && echo 1 || echo 0) "break: $1 → step $2 fails" "got '$got': $msg"
}
brk "http_get granted to no-login (http() still refused inside it)" "1" "grant execute on function extensions.http_get(varchar) to anon"
brk "http_post granted to everyone"          "1"   "grant execute on function extensions.http_post(varchar,varchar,varchar) to public"
brk "http() granted to signed-in logins"     "1 2" "grant execute on function extensions.http(extensions.http_request) to authenticated"
brk "http() granted to no-login"             "1 2" "grant execute on function extensions.http(extensions.http_request) to anon"
brk "http() granted to the read-only user"   "1"   "grant execute on function extensions.http(extensions.http_request) to supabase_read_only_user"
brk "http_header granted to the secret key"  "1"   "grant execute on function extensions.http_header(varchar,varchar) to service_role"
brk "Monday sync owner can't reach http"     "3"   "do \$\$ begin if not exists (select 1 from pg_roles where rolname='sim_owner') then create role sim_owner nosuperuser; end if; end \$\$; alter function run_monday_sync(text) owner to sim_owner"
brk "http extension switched off"            "3"   "drop extension http"
brk "a new SECURITY DEFINER function left open" "4" "create function public.leaky() returns int language sql security definer as 'select 1'"
brk "set_person granted to no-login"         "4"   "grant execute on function set_person(text,text,text,text[],boolean) to anon"
brk "a trigger function given back to everyone" "4" "grant execute on function sheet_progress_log() to public"

# the http functions belonging to someone else (as may be the case on Supabase): the file's revokes
# do nothing and don't stop it; the check says who owns them
mk t_cs_f sync_base_old
$P -d t_cs_f -c "do \$\$ declare f regprocedure; begin
  if not exists (select 1 from pg_roles where rolname='sim_admin') then create role sim_admin nosuperuser; end if;
  if not exists (select 1 from pg_roles where rolname='sim_pg') then create role sim_pg nosuperuser; end if; grant usage on schema extensions to sim_pg, sim_admin;
  for f in select p.oid::regprocedure from pg_proc p join pg_depend d on d.objid=p.oid and d.deptype='e' join pg_extension e on e.oid=d.refobjid where e.extname='http'
  loop execute format('alter function %s owner to sim_admin', f); end loop; end \$\$;"
sec1=$(sed -n '/^-- 1. Only the owner/,/^-- 2. Trigger functions/p' $F | sed -n '/^do \$\$/,/^end \$\$;/p')
w=$(echo "set role sim_pg; $sec1 reset role;" | $P -d t_cs_f 2>&1); rc=$?
ok $([ $rc = 0 ] && echo 1 || echo 0) "not the owner: section 1 finishes without an error (Postgres only warns)" "$w"
$P -d t_cs_f -f $F >/dev/null 2>&1   # as superuser it would revoke; put a public grant back as the owner to model the editor
$P -d t_cs_f -c "set role sim_admin; grant execute on function extensions.http_get(varchar) to public; reset role;"
m=$($P -d t_cs_f -c "select if_it_failed from check_connector_safety() where step=1 and result='FAIL'")
ok $(echo "$m" | grep -q "belong to sim_admin, not postgres" && echo 1 || echo 0) "not the owner: step 1 says who owns them and not to turn a connector on" "$m"

for d in t_cs_old t_cs_new t_cs_run t_cs_b t_cs_f; do $P -d postgres -c "drop database if exists $d with (force)"; done
echo "== $pass passed, $fail failed"
