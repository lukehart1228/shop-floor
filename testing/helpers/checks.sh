#!/bin/bash
# Every check in the database, n/m PASS each. Since 6 Oct (R-10) the list comes from the database itself:
# verify_setup() and every check_…() that takes nothing and returns a result column — so a new
# file's check shows here without editing this file. Left out: check_everything() (it runs all of
# these) and the three that need the real Monday (check_monday_sync, check_office, check_catch_up).
P="psql -h /tmp/pg -p 5433 -U postgres -d ${DB:-sync} -At"
list=$($P -c "select string_agg(proname, ' ' order by proname) from pg_proc
               where pronamespace = 'public'::regnamespace and pronargs = 0
                 and (proname = 'verify_setup' or proname like 'check\_%')
                 and 'result' = any (proargnames)
                 and proname not in ('check_everything', 'check_monday_sync', 'check_office', 'check_catch_up')")
for c in $list "$@"; do
  r=$($P -c "select count(*) filter (where result='PASS') || '/' || count(*) from $c()" 2>&1 | tail -1); echo "$c $r"; done
