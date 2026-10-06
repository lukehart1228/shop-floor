#!/bin/bash
# Guards: every older file refuses and changes nothing; the rest run; rollback path; new-file path.
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q -At -d sync"
L=${LIVE:-/home/claude/sf/repo/sql}
FP="select md5(string_agg(x, '|' order by x)) from (select pg_get_functiondef(p.oid) x from pg_proc p where pronamespace='public'::regnamespace and prokind='f' union all select c.relname||pg_get_viewdef(c.oid) from pg_class c where relnamespace='public'::regnamespace and relkind='v') q"
before=$($P -c "$FP"); runs0=$($P -c "select count(*) from sql_file_runs")
refused=(); ran=()
for f in schema verify_setup upload_function monday_sync tablet office test_lane catch_up problems flags routine_tasks supplies arrow_qc tv check_floor photos check_photos advance supply_lists loadouts_v2 deliveries deliveries_v2 ready_issues finish_by inventory pace send_routes arrow_pickup delivery_types install_log tv_pace handoff_recent feedback trip_types onedrive_save; do
  if out=$($P -1 -f $L/$f.sql 2>&1 >/dev/null); then ran+=($f); else
    if echo "$out" | grep -q "Stop — nothing was changed"; then refused+=($f); else echo "UNEXPECTED ERROR $f: $out"; fi; fi
done
echo "REFUSED: ${refused[*]}"
echo "RAN: ${#ran[@]} files"
exp="schema monday_sync tablet problems arrow_qc tv photos loadouts_v2 deliveries deliveries_v2 ready_issues send_routes delivery_types tv_pace"   # trip_types.sql (5 Oct) replaced pieces of the last two
[ "${refused[*]}" == "$exp" ] && echo "PASS refusals are exactly the replaced files" || echo "FAIL refusals, expected: $exp"
after=$($P -c "$FP")
[ "$before" == "$after" ] && echo "PASS every function and view unchanged after all 35 runs" || echo "FAIL definitions changed"
echo "runs logged: $runs0 -> $($P -c "select count(*) from sql_file_runs") (expect +21, refusals leave no line)"
$P -c "select count(*) from sql_file_runs where how='ran' and ran_at > now() - interval '5 min'" | xargs echo "  ran lines just now:"
bash /home/claude/sf/base/checks.sh | grep -v -E ' ([0-9]+)/\1$' | sed 's/^/  NOT ALL PASS: /'
echo "--- the message Luke sees:"; $P -1 -f $L/ready_issues.sql 2>&1 | grep -o 'Stop.*' | head -1
# Rollback demo on tablet.sql (replaced by test_lane.sql). Since 2 Oct, ready_issues.sql and send_routes.sql
# can't be rolled back without dropping v_ready_to_work first (handoff_recent.sql added a column) — a chat job.
echo "--- rollback path"
$P -c "select allow_older_file('tablet.sql')"
$P -1 -f $L/tablet.sql >/dev/null 2>&1 && echo "PASS tablet ran with permission" || echo "FAIL it refused"
$P -1 -f $L/tablet.sql >/dev/null 2>&1 && echo "FAIL permission used twice" || echo "PASS permission is one-time"
r=$($P -c "select result from whats_installed() where file='tablet.sql'"); [ "$r" == FAIL ] && echo "PASS whats_installed flags the rollback until you go forward" || echo "FAIL whats_installed didn't flag it"
r=$($P -c "select result from check_everything() where step=1"); [ "$r" == FAIL ] && echo "PASS check_everything flags it too" || echo "FAIL check_everything didn't flag it"
$P -1 -f $L/test_lane.sql >/dev/null 2>&1 && echo "test_lane re-run"
r=$($P -c "select result from whats_installed() where file='tablet.sql'"); [ "$r" == PASS ] && echo "PASS clear again after test_lane.sql" || echo "FAIL still flagged"
[ "$before" == "$($P -c "$FP")" ] && echo "PASS back to the same definitions after going forward" || echo "NOTE definitions differ after rollback+forward"
echo "--- stale permission"
$P -c "select allow_older_file('photos.sql')" >/dev/null; $P -c "update sql_file_allow set allowed_at = now() - interval '31 minutes' where file='photos.sql'"
$P -1 -f $L/photos.sql >/dev/null 2>&1 && echo "FAIL old permission used" || echo "PASS a 31-minute-old permission doesn't count"
echo "--- a new file that names what it replaces"
printf "select sql_file_start('zz_new.sql', '{pace.sql}');\nselect 1;\n" > /tmp/zz_new.sql
$P -1 -f /tmp/zz_new.sql >/dev/null && $P -1 -f $L/pace.sql >/dev/null 2>&1 && echo "FAIL pace ran after its replacement" || echo "PASS pace.sql now refuses (zz_new.sql replaces it)"
$P -c "select file||' #'||run_order||' '||replaces::text from sql_file_catalog where file='zz_new.sql'"
