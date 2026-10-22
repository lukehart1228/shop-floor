#!/bin/bash
# direct_counts_off.sql (21 Oct, R-4): each line of check_direct_counts_off() shown to fail when its rule is broken;
# the four rewritten checks full on the new database; the TV photos check right with a real job's picture on the TV.
# Needs sync_base_new (with the file) and sync_base_old (without). Fresh seed per run.
P="psql -h /tmp/pg -p 5433 -U postgres -q -At -v ON_ERROR_STOP=0 -d sync"
F=${F:-/home/claude/sf/out/sql/direct_counts_off.sql}
score() { $P -c "select count(*) filter (where result='PASS')||'/'||count(*) from $1()"; }
fails() { $P -c "select string_agg(step::text, ',' order by step) from $1() where result<>'PASS'"; }
TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh >/dev/null || exit 1
for c in check_direct_counts_off verify_setup check_test_lane check_counts_safety check_tv_photos; do
  r=$(score $c); [ "$r" == "${r%%/*}/${r%%/*}" ] && echo "PASS $c $r on the new database" || echo "FAIL $c $r on the new database (steps $(fails $c))"; done
echo "--- breaks, each caught by the right line"
$P -c "grant update (qty_done) on sheet_progress to authenticated" >/dev/null
r=$(fails check_direct_counts_off); [ "$r" == "1,2" ] && echo "PASS the grant put back: lines 1 and 2 fail" || echo "FAIL expected lines 1,2 to fail, got '$r'"
r=$(fails check_counts_safety); [ "$r" == "6" ] && echo "PASS check_counts_safety line 6 fails with the grant back" || echo "FAIL expected line 6, got '$r'"
$P -c "revoke update (qty_done) on sheet_progress from authenticated" >/dev/null
$P -c "revoke execute on function set_count(uuid,int) from authenticated" >/dev/null
r=$(fails check_direct_counts_off); [ "$r" == "3" ] && echo "PASS set_count taken away: line 3 fails" || echo "FAIL expected line 3, got '$r'"
r=$(fails verify_setup); echo "$r" | grep -q "3" && echo "PASS verify_setup's count line fails without set_count (it counts the way the tablet does)" || echo "FAIL verify_setup didn't notice, got '$r'"
$P -c "grant execute on function set_count(uuid,int) to authenticated" >/dev/null
r=$(score check_direct_counts_off); [ "$r" == "3/3" ] && echo "PASS back to 3/3" || echo "FAIL $r"
echo "--- a real job's picture on the TV (the live FAIL of 20 Oct)"
cat > /tmp/realpic.sql <<'SQL'
do $$
declare j uuid; w uuid; l uuid; ph uuid;
begin
  insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test) values (-60603, 'PROJ-REALPIC', 'A real job with a TV picture', true, 'In Production', local_today(), false) returning id into j;
  insert into work_orders (job_id, version, is_current) values (j, 1, true) returning id into w;
  insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, 1, 1, 'RP-01');
  insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at, is_test) values (j, 'delivery', now() - interval '3 hours', now() - interval '1 hour', 'R Customer', now() - interval '1 hour', false) returning id into l;
  ph := gen_random_uuid();
  insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PROJ-REALPIC/' || ph || '.jpg', '{"size": 1}');
  insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, storage_path, is_test, taken_by_name, stage, piece)
    values (ph, j, 1, 'delivery', 'loadout', l, 'PROJ-REALPIC/' || ph || '.jpg', false, 'test', 'site', 1) returning id into ph;
  insert into tv_photo_copies (photo_id, jpeg, bytes) values (ph, decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64'), 300);
end $$;
SQL
$P -f /tmp/realpic.sql >/dev/null
n=$($P -c "select count(*) from tv_home_pictures()"); [ "$n" -ge 1 ] && echo "PASS the real job's picture is on the TV's home list ($n listed)" || echo "FAIL no picture listed"
r=$(score check_tv_photos); [ "$r" == "9/9" ] && echo "PASS the new check_tv_photos is 9/9 with it there" || echo "FAIL $r (steps $(fails check_tv_photos))"
TEMPLATE=sync_base_old bash /home/claude/sf/base/fresh.sh >/dev/null && $P -f /tmp/realpic.sql >/dev/null
r=$(score check_tv_photos); [ "$r" == "7/9" ] && echo "PASS the old check_tv_photos is 7/9 with it there (the 20 Oct live result)" || echo "FAIL old check $r"
echo "--- the file on the old database: runs, registers itself the old way, install_log.sql after it makes it whole"
$P -1 -f $F >/dev/null 2>/tmp/f.err && echo "PASS runs on a database with the 30 Sep install log" || { echo "FAIL $(head -2 /tmp/f.err)"; }
r=$($P -c "select run_order||' '||coalesce(fingerprint,'(none)') from sql_file_catalog where file='direct_counts_off.sql'"); echo "  catalogued as: $r (the old guard: next number, no fingerprint)"
r=$(score check_direct_counts_off); [ "$r" == "3/3" ] && echo "PASS its check is 3/3 there" || echo "FAIL $r"
$P -c "select count(*) from check_everything() where check_name='check_direct_counts_off'" | grep -q "^0$" && echo "PASS (expected) the old check_everything doesn't know it until install_log.sql is run"
$P -1 -f /home/claude/sf/out/sql/install_log.sql >/dev/null 2>&1 && echo "ran the 21 Oct install_log.sql after it"
r=$($P -c "select result||' '||detail from check_everything() where check_name='check_direct_counts_off'"); [ "$r" == "PASS 3/3" ] && echo "PASS now check_everything runs it" || echo "FAIL $r"
r=$($P -c "select run_order||' '||fingerprint||' '||replaces::text from sql_file_catalog where file='direct_counts_off.sql'"); [ "$r" == "45 check_direct_counts_off {verify_setup.sql,test_lane.sql,counts_safety.sql,tv_photos.sql}" ] && echo "PASS and its row is the master list's" || echo "FAIL row: $r"
r=$($P -c "select count(*) from whats_installed() where result<>'PASS'"); [ "$r" == 0 ] && echo "PASS whats_installed all PASS" || echo "FAIL $r not PASS"
$P -1 -f $F >/dev/null 2>&1 && echo "PASS runs again (twice)" || echo "FAIL second run"
