#!/bin/bash
# Builds the 'sync' test database from every SQL file in the live order, each loaded twice,
# then any extra files given (twice). Saves it as the template sync_base.
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
L=${LIVE:-/home/claude/sf/repo/sql}
B=/home/claude/sf/base
$P -d postgres -c "drop database if exists sync with (force)" -c "drop database if exists sync_base with (force)" -c "create database sync" >/dev/null
$P -d sync -f $B/stubs.sql
$P -d sync -c "create extension http with schema extensions; create extension pg_cron;" >/dev/null
two() { for f in "$@"; do $P -1 -d sync -f $L/$f.sql >/dev/null || { echo "FAILED $f"; exit 1; }; $P -d sync -1 -f $L/$f.sql >/dev/null || { echo "FAILED 2nd $f"; exit 1; }; done; }
two schema verify_setup upload_function monday_sync tablet office test_lane catch_up problems flags routine_tasks supplies arrow_qc tv
$P -d sync -c "select cron.unschedule(jobname) from cron.job" >/dev/null 2>&1 || true
$P -d sync -f $B/people.sql >/dev/null
$P -d sync -c "select set_person('test@pdindy.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true)" >/dev/null
two check_floor photos check_photos advance supply_lists loadouts_v2 deliveries deliveries_v2 ready_issues
two finish_by inventory pace send_routes arrow_pickup pace delivery_types
[ -f $L/install_log.sql ] && two install_log
$P -d sync -c "select cron.unschedule(jobname) from cron.job" >/dev/null 2>&1 || true
for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f" >/dev/null; $P -d sync -f "$f" > /tmp/last_load.out; done
$P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='sync' and pid<>pg_backend_pid()" -c "create database sync_base template sync" >/dev/null
echo LOADED
