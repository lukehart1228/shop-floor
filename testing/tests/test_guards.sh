#!/bin/bash
# Guards: every older file refuses and changes nothing; the rest run; rollback path; new-file path.
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q -At -d sync"
L=${LIVE:-/home/claude/sf/repo/sql}
FP="select md5(string_agg(x, '|' order by x)) from (select pg_get_functiondef(p.oid) x from pg_proc p where pronamespace='public'::regnamespace and prokind='f' union all select c.relname||pg_get_viewdef(c.oid) from pg_class c where relnamespace='public'::regnamespace and relkind='v') q"
before=$($P -c "$FP"); runs0=$($P -c "select count(*) from sql_file_runs")
refused=(); ran=()
# every file, in the run order from sql/README.md (since 6 Oct, R-10: no hand list to fall behind)
ORDER=$(grep -oE '^\| *[0-9]+ *\| *`[a-z_0-9]+\.sql`' $L/README.md | sed -E 's/.*`([a-z_0-9]+)\.sql`/\1/')
for f in $ORDER; do
  if out=$($P -1 -f $L/$f.sql 2>&1 >/dev/null); then ran+=($f); else
    if echo "$out" | grep -q "Stop — nothing was changed"; then refused+=($f); else echo "UNEXPECTED ERROR $f: $out"; fi; fi
done
echo "REFUSED: ${refused[*]}"
echo "RAN: ${#ran[@]} files"
exp="schema verify_setup upload_function monday_sync tablet test_lane problems arrow_qc tv photos loadouts_v2 deliveries deliveries_v2 ready_issues send_routes delivery_types tv_pace trip_types counts_safety tv_photos"   # 21 Oct: direct_counts_off.sql replaced pieces of verify_setup, test_lane, counts_safety and tv_photos; earlier: trip_types.sql (5 Oct) replaced pieces of delivery_types and tv_pace; tv_photos.sql (7 Oct) of tv_pace and trip_types; delivery_extras.sql (16 Oct) upload_work_order from upload_function; tv_coming.sql (20 Oct) tv_snapshot from tv_photos
[ "${refused[*]}" == "$exp" ] && echo "PASS refusals are exactly the replaced files" || echo "FAIL refusals, expected: $exp"
after=$($P -c "$FP")
[ "$before" == "$after" ] && echo "PASS every function and view unchanged after all $(echo $ORDER | wc -w) runs" || echo "FAIL definitions changed"
echo "runs logged: $runs0 -> $($P -c "select count(*) from sql_file_runs") (expect +$(( $(echo $ORDER | wc -w) - $(echo $exp | wc -w) )), refusals leave no line)"
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
# going forward from a tablet.sql rollback (21 Oct): test_lane.sql itself is replaced by direct_counts_off.sql, so it refuses on its own,
# runs once with permission, and direct_counts_off.sql runs after it
$P -1 -f $L/test_lane.sql >/dev/null 2>&1 && echo "FAIL test_lane.sql ran without permission (direct_counts_off.sql replaced pieces of it)" || echo "PASS test_lane.sql refuses on its own (direct_counts_off.sql replaced pieces of it)"
$P -c "select allow_older_file('test_lane.sql')" >/dev/null
$P -1 -f $L/test_lane.sql >/dev/null 2>&1 && echo "test_lane re-run, older on purpose"
r=$($P -c "select string_agg(file, ',' order by file) from whats_installed() where result='FAIL'"); [ "$r" == "test_lane.sql" ] && echo "PASS tablet.sql is clear and test_lane.sql is flagged until direct_counts_off.sql goes forward" || echo "FAIL flagged: $r"
$P -1 -f $L/direct_counts_off.sql >/dev/null 2>&1 && echo "direct_counts_off re-run"
r=$($P -c "select count(*) from whats_installed() where result='FAIL'"); [ "$r" == 0 ] && echo "PASS clear again after direct_counts_off.sql" || echo "FAIL still flagged: $($P -c "select string_agg(file, ',') from whats_installed() where result='FAIL'")"
[ "$before" == "$($P -c "$FP")" ] && echo "PASS back to the same definitions after going forward" || echo "NOTE definitions differ after rollback+forward"
echo "--- stale permission"
$P -c "select allow_older_file('photos.sql')" >/dev/null; $P -c "update sql_file_allow set allowed_at = now() - interval '31 minutes' where file='photos.sql'"
$P -1 -f $L/photos.sql >/dev/null 2>&1 && echo "FAIL old permission used" || echo "PASS a 31-minute-old permission doesn't count"
echo "--- a new file that names what it replaces"
printf "select sql_file_start('zz_new.sql', '{pace.sql}');\nselect 1;\n" > /tmp/zz_new.sql
$P -1 -f /tmp/zz_new.sql >/dev/null && $P -1 -f $L/pace.sql >/dev/null 2>&1 && echo "FAIL pace ran after its replacement" || echo "PASS pace.sql now refuses (zz_new.sql replaces it)"
$P -c "select file||' #'||run_order||' '||replaces::text from sql_file_catalog where file='zz_new.sql'"
echo "--- a file that registers itself (21 Oct: one paste, no install_log.sql after it)"
cat > /tmp/zz_reg.sql <<'SQL'
do $$ begin perform sql_file_register('zz_reg.sql', 99, 'check_zz_reg', 'check_zz_reg', '{}'); perform sql_file_start('zz_reg.sql', '{}'); end $$;
create or replace function check_zz_reg() returns table (step int, check_name text, result text, if_it_failed text) language sql as $$ select 1, 'a practice check', 'PASS', null::text $$;
revoke all on function check_zz_reg() from public, anon, authenticated;
SQL
$P -1 -f /tmp/zz_reg.sql >/dev/null && echo "ran zz_reg.sql"
r=$($P -c "select result||' '||detail from check_everything() where check_name='check_zz_reg'"); [ "$r" == "PASS 1/1" ] && echo "PASS check_everything() runs a self-registered file's check with no install_log.sql re-run" || echo "FAIL got '$r'"
r=$($P -c "select run_order||' '||fingerprint||' '||check_fn from sql_file_catalog where file='zz_reg.sql'"); [ "$r" == "99 check_zz_reg check_zz_reg" ] && echo "PASS its catalog row is its own" || echo "FAIL row: $r"
r=$($P -c "select result from whats_installed() where file='zz_reg.sql'"); [ "$r" == PASS ] && echo "PASS whats_installed() lists it" || echo "FAIL whats_installed: $r"
$P -c "update sql_file_catalog set run_order = 98 where file='zz_reg.sql'" >/dev/null     # as if install_log.sql's list said 98
if $P -1 -f /tmp/zz_reg.sql >/dev/null 2>/tmp/reg.err; then echo "FAIL a file whose own line disagrees with the list ran"; else
  grep -q "describes itself as run order 99" /tmp/reg.err && echo "PASS a file whose own line disagrees with install_log.sql's list stops, nothing changed" || { echo "FAIL wrong refusal:"; head -2 /tmp/reg.err; }; fi
r=$($P -c "select run_order from sql_file_catalog where file='zz_reg.sql'"); [ "$r" == "98" ] && echo "PASS the list's row is untouched by the refusal" || echo "FAIL row changed to $r"
$P -c "update sql_file_catalog set run_order = 99, fingerprint = null, check_fn = null where file='zz_reg.sql'" >/dev/null   # a row sql_file_start made on an older install log
$P -1 -f /tmp/zz_reg.sql >/dev/null 2>&1 && echo "PASS a row the old guard made (no fingerprint) is filled in, not refused" || echo "FAIL refused a row with no fingerprint"
r=$($P -c "select fingerprint||' '||check_fn from sql_file_catalog where file='zz_reg.sql'"); [ "$r" == "check_zz_reg check_zz_reg" ] && echo "PASS and now carries its check" || echo "FAIL row: $r"
