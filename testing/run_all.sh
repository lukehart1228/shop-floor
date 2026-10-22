#!/bin/bash
# run_all.sh — every test in the kit, each in its right mode, one score table at the end (21 Oct 2026).
#
#   bash /home/claude/sf/repo/testing/run_all.sh all          after setup.sh; changed files in /home/claude/sf/out
#   bash run_all.sh build | sql | pages1 | pages2 | browser1 | browser2 | table
#        the same in sections: in Claude's sandbox one command may run 5 minutes, and "all" takes about 15,
#        so run build, sql, pages1, pages2, browser1, browser2 one per command, then table prints the whole score sheet
#   OUT=/some/folder bash run_all.sh …                        another folder of changed files (laid out like the repo)
#   ONLY="test_same test_feedback" bash run_all.sh pages1     a few tests by name (no .js/.sh)
#
# What it does: builds sync_base_old (the live repo's sql/) and sync_base_new (the same plus OUT's sql/), lays every page
# out in /tmp/allpages (live pages, OUT's on top), then runs each test on a fresh seeded copy of the NEW database with the
# environment its README entry names. Each test's full output is in /tmp/run_all/<test>.log. A test's own OLDDB= / MODE=
# proofs for its build are not run here: those belong to the build chat that made the file (see testing/README.md §2).
# Exit code: 0 when every test is all PASS.
set -u
G=${1:-all}
SF=/home/claude/sf; REPO=$SF/repo; OUT=${OUT:-$SF/out}; T=$SF/t; B=$SF/base; LOG=/tmp/run_all; mkdir -p $LOG
PSQL="psql -h /tmp/pg -p 5433 -U postgres -q"
PW="PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1"
export TZ=America/Indiana/Indianapolis
ROWS=$LOG/rows.txt; [ "$G" == all ] || [ "$G" == build ] && : > $ROWS; touch $ROWS
row() { grep -v "^$1 " $ROWS > $ROWS.tmp 2>/dev/null; mv $ROWS.tmp $ROWS; printf '%-32s %-10s %s\n' "$1" "$2" "$3" | tee -a $ROWS; }   # one row per test; a rerun replaces it
in_group() { [ "$G" == all ] || [ "$G" == "$1" ]; }
pg_isready -q -h /tmp/pg -p 5433 || su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg/data -o '-k /tmp/pg -p 5433' -l /tmp/pg/log start" >/dev/null; sleep 1

# 1. the pages: live, with OUT's on top; the kit files the same way (tests and helpers from OUT win)
if [ "$G" != table ]; then
rm -rf /tmp/allpages && mkdir -p /tmp/allpages
cp $REPO/*.html $REPO/*.js $REPO/*.css $REPO/*.png $REPO/manifest.webmanifest /tmp/allpages/ 2>/dev/null
[ -d $OUT ] && cp $OUT/*.html $OUT/*.js $OUT/*.css $OUT/*.png $OUT/manifest.webmanifest /tmp/allpages/ 2>/dev/null
for f in $OUT/testing/tests/*.js $OUT/testing/tests/*.sh; do [ -f "$f" ] && cp "$f" $T/ && cp "$f" $B/ 2>/dev/null; done
for f in $OUT/testing/helpers/*; do [ -f "$f" ] && cp "$f" $B/; done
[ -f $OUT/testing/helpers/pgsupa.js ] && cp $OUT/testing/helpers/pgsupa.js $T/
chmod +x $B/*.sh 2>/dev/null
fi

# 2. the databases
NEWSQL=/tmp/run_all_sql
if in_group build; then
  rm -rf $NEWSQL && cp -r $REPO/sql $NEWSQL && [ -d $OUT/sql ] && cp $OUT/sql/* $NEWSQL/ 2>/dev/null
  echo "== building sync_base_old (live sql/)"; LIVE=$REPO/sql bash $B/load.sh 2>&1 | grep -E "FAILED|LOADED [0-9]" || { echo "BUILD FAILED (old)"; exit 1; }
  $PSQL -d postgres -c "drop database if exists sync_base_old with (force)" -c "create database sync_base_old template sync_base" >/dev/null 2>&1
  echo "== building sync_base_new (live sql/ + $OUT/sql)"; LIVE=$NEWSQL bash $B/load.sh 2>&1 | grep -E "FAILED|LOADED [0-9]" || { echo "BUILD FAILED (new)"; exit 1; }
  $PSQL -d postgres -c "drop database if exists sync_base_new with (force)" -c "create database sync_base_new template sync_base" >/dev/null 2>&1
  [ "$G" == build ] && { echo "built; now: sql, pages1, pages2, browser1, browser2, then table"; exit 0; }
fi
fresh() { TEMPLATE=sync_base_new bash $B/fresh.sh "$@" >/dev/null 2>&1 || echo "  (fresh.sh failed)"; }
scenario() { local f=$OUT/testing/tests/$1; [ -f "$f" ] || f=$REPO/testing/tests/$1; $PSQL -d sync -f "$f" >/dev/null 2>&1 || echo "  (scenario $1 failed to load)"; }

want() { [ -z "${ONLY:-}" ] || echo " $ONLY " | grep -q " $1 "; }
score_of() { local p f; p=$(grep -c "^PASS" "$1"); f=$(grep -c "^FAIL" "$1"); echo "$p PASS, $f FAIL"; [ "$f" == 0 ] && [ "$p" -gt 0 ]; }
# run <name> <needs: none|seed|scenario> <env…> -- the command runs in $T
run() {
  local name=$1 needs=$2; shift 2; want $name || return
  local env=(); while [ "$1" != "--" ]; do env+=("$1"); shift; done; shift
  [ -f $T/$name.js ] || [ -f $B/$name.sh ] || { row $name skipped "not in the kit"; return; }
  echo "== $name"
  case $needs in seed) fresh ;; scenario) fresh; scenario scenario_handoff_recent.sql ;; esac
  (cd $T && env "${env[@]}" timeout 1200 "$@") > $LOG/$name.log 2>&1
  local s; s=$(score_of $LOG/$name.log) && row $name "all PASS" "$s" || row $name "FAIL" "$s — see $LOG/$name.log"
}
P=/tmp/allpages; PAGE=$P/index.html

# 3. the SQL side
if in_group sql; then
if want checks; then
  fresh; echo "== every check in the database (new)"; DB=sync bash $B/checks.sh > $LOG/checks.log 2>&1
  bad=$(grep -v -E ' ([0-9]+)/\1$' $LOG/checks.log | grep -v "^check_monday_sync\|^check_office\|^check_catch_up")
  [ -z "$bad" ] && row checks "all PASS" "$(wc -l < $LOG/checks.log) checks full" || { row checks FAIL "$(echo $bad | tr '\n' ' ')"; }
fi
run test_guards            seed  LIVE=$NEWSQL -- bash $B/test_guards.sh
run test_devices           seed  -- bash $B/test_devices.sh
run test_direct_counts_off none  F=$NEWSQL/direct_counts_off.sql -- bash $B/test_direct_counts_off.sh
[ -f $B/monday_standin.py ] && run test_connector_safety none -- bash $B/test_connector_safety.sh || { want test_connector_safety && row test_connector_safety skipped "needs helpers/monday_standin.py"; }
fi

# 4. pages, no browser engine (two sections)
if in_group pages1; then
run test_csv_cell          none  OUT=$P -- node test_csv_cell.js
run test_style_same        none  OUT=$P -- node test_style_same.js
run test_lab_reference     none  LAB=$P/lab.html -- node test_lab_reference.js
if [ -f $OUT/index.html ]; then run test_same seed NEWPAGE=$OUT/index.html -- node test_same.js; else want test_same && row test_same skipped "no tablet page in OUT"; fi
run test_same_office       seed  OUT=$P -- node test_same_office.js
run test_feedback          seed  OUT=$P -- node test_feedback.js
run test_feedback_close    seed  OUT=$P -- node test_feedback_close.js
run test_trip_types        seed  OUT=$P -- node test_trip_types.js
run test_pdf_ticket        seed  PAGE=$PAGE -- node test_pdf_ticket.js
run test_wo_beside_ticket  seed  PAGE=$PAGE -- node test_wo_beside_ticket.js
run test_extras_checklist  seed  PAGE=$PAGE -- node test_extras_checklist.js
fi
if in_group pages2; then
run test_handoff_recent    scenario MODE=new PAGE=$PAGE -- node test_handoff_recent.js
run test_recent_delivery   scenario PAGE=$PAGE -- node test_recent_delivery.js
run test_look_only         seed  PAGE=$PAGE -- node test_look_only.js
run test_send_safety       seed  NEWPAGE=$PAGE -- node test_send_safety.js
run test_tv_photos         seed  OUT=$P -- node test_tv_photos.js
run test_onedrive_save     seed  OUT=$P SF_MAX_ROWS=2 -- node test_onedrive_save.js
fi

# 5. pages in Chromium, two sections
if in_group browser1; then
run test_office_sections   seed  OUT=$P $PW -- node test_office_sections.js
run test_office_link       seed  PAGE=$PAGE $PW -- node test_office_link.js
run test_auto_update       seed  PAGE=$PAGE ROOT=$P $PW -- node test_auto_update.js
run test_sw_assets         none  SW=$P/sw.js $PW -- node test_sw_assets.js
fi
if in_group browser2; then
run test_pdf_chromium      seed  $PW -- node test_pdf_chromium.js
run test_onedrive_save_chromium seed OUT=$P $PW -- node test_onedrive_save_chromium.js
run test_tv_coming         seed  OUT=$P $PW -- node test_tv_coming.js
run test_machine_files     seed  OUT=$P $PW -- node test_machine_files.js
if ls $T/PROJ-00212*.pdf >/dev/null 2>&1; then run test_lab seed OUT=$P $PW -- node test_lab.js; else want test_lab && row test_lab skipped "needs the three work orders beside it in t/ (ask Luke; never on GitHub)"; fi
fi

if in_group table; then
echo; echo "===================== run_all: $(date '+%d %b %H:%M') — pages from $P, sql from $NEWSQL ====================="
printf '%-32s %-10s %s\n' TEST RESULT SCORE; cat $ROWS
echo "Not run here: shots_tablet.js and shots_office.js (screenshots, not tests); each test's OLDDB=/MODE= proofs for its own build; the three Monday checks (need the real Monday)."
if grep -qE '^\S+\s+FAIL' $ROWS; then echo "SOMETHING FAILED — read the log named on its row"; exit 1; else echo "ALL PASS ($(grep -c 'all PASS' $ROWS) tests full, $(grep -c ' skipped ' $ROWS) skipped)"; fi
fi
