#!/bin/bash
# every live check; prints n/m PASS per check
for c in verify_setup check_floor check_photos check_advance check_supply_lists check_loadouts check_deliveries check_deliveries_v2 check_ready_issues check_finish_by check_inventory check_pace check_send_routes check_arrow_pickup check_delivery_types check_test_lane "$@"; do
  r=$(psql -h /tmp/pg -p 5433 -U postgres -d ${DB:-sync} -At -c "select count(*) filter (where result='PASS') || '/' || count(*) from $c()" 2>&1 | tail -1); echo "$c $r"; done
