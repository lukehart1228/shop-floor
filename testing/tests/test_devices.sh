#!/bin/bash
# Device versions and the new tables' walls, through the login path Supabase uses.
as() { # as <uuid|anon> "sql"
  if [ "$1" == anon ]; then pre="set role anon;"; else pre="set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false) \\g /dev/null"; fi
  printf "%s\n%s\n" "$pre" "$2" > /tmp/as.sql
  psql -h /tmp/pg -p 5433 -U authenticator -d sync -q -At -v ON_ERROR_STOP=1 -f /tmp/as.sql 2>&1 | grep -v "^CONTEXT" | tail -1; }
MIKE=11111111-1111-1111-1111-111111111111; WILLIE=55555555-5555-5555-5555-555555555555; LUKE=22222222-2222-2222-2222-222222222222
ok()  { r=$(as $1 "$2"); if echo "$r" | grep -q -i error; then echo "FAIL $3: $r"; else echo "PASS $3"; fi; }
no()  { r=$(as $1 "$2"); if echo "$r" | grep -q -i -E 'error'; then echo "PASS $3 ($(echo $r | sed 's/.*ERROR: *//' | cut -c1-60))"; else echo "FAIL $3: got $r"; fi; }
ok $MIKE   "select report_device('dev-mike-0001','index','2026-09-30.1','test agent')" "Mike's tablet reports its page"
ok $WILLIE "select report_device('dev-willie-01','index','2026-09-29.1',null)" "Willie's tablet reports an older page"
ok $MIKE   "select report_device('dev-mike-0001','index','2026-09-30.1','test agent')" "the same device reporting again updates, doesn't add"
no anon    "select report_device('dev-anon-0001','index','x',null)" "no login can't report"
no $MIKE   "select report_device('x','index','2026-09-30.1',null)" "a malformed device id is refused"
no $MIKE   "select count(*) from device_versions" "Mike can't read device_versions"
no $MIKE   "select count(*) from sql_file_runs" "Mike can't read the install log"
no $LUKE   "select count(*) from sql_file_catalog" "a manager login can't read the catalog either (SQL Editor only)"
no $LUKE   "select * from devices()" "devices() is SQL Editor only"
no $LUKE   "select * from whats_installed()" "whats_installed() is SQL Editor only"
no $LUKE   "select * from check_everything()" "check_everything() is SQL Editor only"
no $MIKE   "select sql_file_start('schema.sql')" "a login can't write to the install log"
no $MIKE   "select allow_older_file('schema.sql')" "a login can't grant a rollback"
no anon    "select * from check_everything()" "no login: check_everything refused"
P="psql -h /tmp/pg -p 5433 -U postgres -q -At -d sync"
echo "rows: $($P -c "select count(*) from device_versions") (expect 2)"
$P -c "select person||' | '||version||' | '||note from devices()"
$P -c "select result||' '||detail from check_everything() where check_name like 'Tablets%'"
