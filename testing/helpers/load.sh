#!/bin/bash
# Builds the 'sync' test database from every SQL file in sql/, in the run order written in
# sql/README.md (the order the live database was built in), each loaded twice as one transaction,
# then any extra files given (twice). Saves it as the template sync_base.
#
# Since 6 Oct (finding R-10) nothing is listed here by hand. It stops, and the build fails, if:
#   - a file in sql/ has no row in sql/README.md's run order (or the order names a missing file),
#   - a file fails to load, or
#   - afterwards whats_installed() isn't PASS for every file in install_log.sql's catalog.
# So the sandbox can't fall behind live: a new SQL file only loads once its README row is added.
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
L=${LIVE:-/home/claude/sf/repo/sql}
B=/home/claude/sf/base

# the run order: the "| 12 | `supplies.sql` |" rows of sql/README.md, top to bottom
ORDER=$(grep -oE '^\| *[0-9]+ *\| *`[a-z_0-9]+\.sql`' $L/README.md | sed -E 's/.*`([a-z_0-9]+)\.sql`/\1/')
[ -n "$ORDER" ] || { echo "FAILED: no run order found in $L/README.md"; exit 1; }
for f in $L/*.sql; do
  n=$(basename "$f" .sql)
  echo "$ORDER" | grep -qx "$n" || { echo "FAILED: sql/$n.sql has no row in sql/README.md's run order. Add its row (and its line in install_log.sql's catalog)."; exit 1; }
done
for n in $ORDER; do [ -f $L/$n.sql ] || { echo "FAILED: sql/README.md names $n.sql, which isn't in sql/"; exit 1; }; done

$P -d postgres -c "drop database if exists sync with (force)" -c "drop database if exists sync_base with (force)" -c "create database sync" >/dev/null
$P -d sync -f $B/stubs.sql
$P -d sync -c "create extension http with schema extensions; create extension pg_cron;" >/dev/null
two() { for f in "$@"; do $P -1 -d sync -f $L/$f.sql >/dev/null || { echo "FAILED $f"; exit 1; }; $P -d sync -1 -f $L/$f.sql >/dev/null || { echo "FAILED 2nd $f"; exit 1; }; done; }
unsched() { $P -d sync -c "select cron.unschedule(jobname) from cron.job" >/dev/null 2>&1 || true; }   # never call the real Monday

for n in $ORDER; do
  two $n
  case $n in
    monday_sync) unsched ;;
    tv)          # the logins, once set_person() exists (test_lane.sql) and before the checks that need them
                 $P -d sync -f $B/people.sql >/dev/null
                 $P -d sync -c "select set_person('test@example.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true)" >/dev/null ;;
    send_routes) two pace ;;   # the README: pace.sql was run again after send_routes.sql, live
  esac
done
# the README: "Run install_log.sql again after it" for every file after the install log; once at the end does the same
echo "$ORDER" | grep -qx install_log && two install_log
unsched

# every catalogued file installed, in order — the same test as the first line of check_everything()
bad=$($P -At -d sync -c "select string_agg(file || ': ' || detail, '; ') from whats_installed() where result <> 'PASS'" 2>&1 || true)
if [ -n "$bad" ]; then echo "FAILED: whats_installed() isn't all PASS in the sandbox: $bad"; exit 1; fi
echo "LOADED $(echo $ORDER | wc -w) files from sql/README.md"

for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f" >/dev/null; $P -d sync -f "$f" > /tmp/last_load.out; done
$P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='sync' and pid<>pg_backend_pid()" -c "create database sync_base template sync" >/dev/null
echo LOADED
