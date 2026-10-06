# SQL files

Every SQL file the database is built from, one current copy of each. To run one, open it on GitHub, press the copy button (top right of the file), paste it into a **new, empty** query in the Supabase SQL Editor and click Run. The editor shows only the last result, which is each file's own PASS/FAIL table.

**See what's installed:** `select * from whats_installed();`
**Check everything at once:** `select * from check_everything();`
**See which page each tablet runs:** `select * from devices();`

## Safe by design

Every file starts by writing a line in the install log. If a newer file has already replaced some of its pieces, it stops before changing anything, with a message saying so. So an old file can't quietly undo newer work. Rolling back on purpose is done with Claude in a chat.

## The order they were run

On the live database these have all run. The order matters only when building a new database from nothing.

| # | File | Notes |
|---|---|---|
| 1 | `schema.sql` | Tables, roles, security |
| 2 | `verify_setup.sql` | |
| 3 | `upload_function.sql` | |
| 4 | `monday_sync.sql` | Starts the 15-minute sync (needs the Vault secret `monday_token`) |
| 5 | `tablet.sql` | |
| 6 | `office.sql` | Replaces part of `monday_sync.sql` |
| 7 | `test_lane.sql` | Replaces `tablet.sql`'s view |
| 8 | `catch_up.sql` | |
| 9 | `problems.sql` | |
| 10 | `flags.sql` | |
| 11 | `routine_tasks.sql` | |
| 12 | `supplies.sql` | |
| 13 | `arrow_qc.sql` | |
| 14 | `tv.sql` | |
| 15 | `check_floor.sql` | |
| 16 | `photos.sql` | |
| 17 | `check_photos.sql` | |
| 18 | `advance.sql` | |
| 19 | `supply_lists.sql` | |
| 20 | `loadouts_v2.sql` | |
| 21 | `deliveries.sql` | |
| 22 | `deliveries_v2.sql` | |
| 23 | `ready_issues.sql` | |
| 24 | `finish_by.sql` | |
| 25 | `inventory.sql` | |
| 26 | `pace.sql` | Run again after `send_routes.sql` (it was, live); safe to re-run any time |
| 27 | `send_routes.sql` | |
| 28 | `arrow_pickup.sql` | |
| 29 | `delivery_types.sql` | |
| 30 | `install_log.sql` | The install log, guards, `check_everything()`, `devices()` |
| 31 | `tv_pace.sql` | The floor TV with pace, work stopped and going out. Replaces `tv.sql`'s TV function. Run `install_log.sql` again after it |
| 32 | `handoff_recent.sql` | Milling, Metal and Full Custom wait for Monday's Handed Off; the tablets' Recently completed tab. Replaces `send_routes.sql`'s ready view, so `send_routes.sql` now stops. Run `install_log.sql` again after it |
| 33 | `feedback.sql` | The Feedback button's table and `send_feedback()`; the office's Feedback list reads it. Run `install_log.sql` again after it |
| 34 | `trip_types.sql` | Dock to dock deliveries and Delivery's tasks. Replaces pieces of `deliveries.sql`, `deliveries_v2.sql`, `delivery_types.sql` and `tv_pace.sql`, so those now stop. Run `install_log.sql` again after it |

Not here on purpose: **`set_up_logins.sql`**, which has everyone's login addresses. Keep it on your own computer, not on GitHub.
