#!/bin/bash
# fresh 'sync' from the template sync_base (built by load.sh), then any extra files (twice), then the seed
P="psql -h /tmp/pg -p 5433 -U postgres -q -v ON_ERROR_STOP=1"
$P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='sync' and pid<>pg_backend_pid()" -c "drop database if exists sync with (force)" -c "create database sync template sync_base" >/dev/null || exit 1
for f in "$@"; do $P -1 -d sync -f "$f" >/dev/null 2>/tmp/load.err || { echo LOAD FAILED $f; cat /tmp/load.err; exit 1; }; $P -1 -d sync -f "$f" >/dev/null 2>&1; done
for s in seed.sql seed_fb.sql; do $P -d sync -f /home/claude/sf/base/$s >/tmp/seed.out 2>&1 || { echo SEED FAILED $s; head /tmp/seed.out; exit 1; }; done
$P -d sync -c "select set_person('shawn@pdindy.com','Shawn K','supervisor','{delivery}')" >/dev/null
echo SEEDED
