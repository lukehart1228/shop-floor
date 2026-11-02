# SQL files

Every SQL file the database is built from, one current copy of each. To run one, open it on GitHub, press the copy button (top right of the file), paste it into a **new, empty** query in the Supabase SQL Editor and click Run. The editor shows only the last result, which is each file's own PASS/FAIL table.

**See what's installed:** `select * from whats_installed();`
**Check everything at once:** `select * from check_everything();`
**See which page each tablet runs:** `select * from devices();`

## Safe by design

Every file starts by writing a line in the install log. If a newer file has already replaced some of its pieces, it stops before changing anything, with a message saying so. So an old file can't quietly undo newer work. Rolling back on purpose is done with Claude in a chat.

Since 21 Oct a new file also **registers itself** when it runs (its run order, its check and what it replaces), so running a new file is **one paste**: there's no need to run `install_log.sql` again after it. `install_log.sql` keeps the master list all the same, and is run again only when it changes itself; a file whose own line disagrees with that list stops before changing anything.

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
| 30 | `install_log.sql` | The install log, guards, `check_everything()`, `devices()`. 21 Oct: files register themselves, `check_everything()` reads its list of checks from the catalog, and a device not opened in 14 days is listed but not counted |
| 31 | `tv_pace.sql` | The floor TV with pace, work stopped and going out. Replaces `tv.sql`'s TV function. Run `install_log.sql` again after it |
| 32 | `handoff_recent.sql` | Milling, Metal and Full Custom wait for Monday's Handed Off; the tablets' Recently completed tab. Replaces `send_routes.sql`'s ready view, so `send_routes.sql` now stops. Run `install_log.sql` again after it |
| 33 | `feedback.sql` | The Feedback button's table and `send_feedback()`; the office's Feedback list reads it. Run `install_log.sql` again after it |
| 34 | `trip_types.sql` | Dock to dock deliveries and Delivery's tasks. Replaces pieces of `deliveries.sql`, `deliveries_v2.sql`, `delivery_types.sql` and `tv_pace.sql`, so those now stop. Run `install_log.sql` again after it |
| 35 | `onedrive_save.sql` | Saving each job's photos, files, signed tickets and records into its OneDrive folder and a backup folder: the save log, the jobs that changed, the production record, the 7-day reminder. Run `install_log.sql` again after it |
| 36 | `counts_safety.sql` | Counts sent after a change order land on the current work order (or are refused in plain words if that sheet's drawing changed); the tablet's `set_count()`; nobody without the secret key can empty a table. Run `install_log.sql` again after it |
| 37 | `connector_safety.sql` | Only the database owner can reach the internet (the `http` extension), and only the floor TV's and the security rules' functions run without a login. Needed before any Claude connector to Supabase is turned on. Run `install_log.sql` again after it |
| 38 | `tv_photos.sql` | In its new home: a site photo from a finished white glove delivery on the floor TV. The TV's copies table and gate, `tv_photo()`, the hide switch, the 14-day cache clearing; `tv_snapshot` stops sending the job table it never showed. Replaces pieces of `trip_types.sql` and `tv_pace.sql`, so those now stop. Run `install_log.sql` again after it |
| 39 | `delivery_extras.sql` | Extras on Delivery's trips: each sheet's extras (small loose items like cabinet shelves and data ports, from the generator's upload file) are saved with the work order, and the Delivery phone ticks them off as the truck is loaded (`set_extra_loaded()`, the number itself). Only the Delivery login and managers can see them. Replaces `upload_work_order()` from `upload_function.sql`, so that file now stops. Run `install_log.sql` again after it |
| 40 | `lab.sql` | The Prototype lab (office ☰ menu, only for logins let in with `lab_allow()`): what it has been taught, answers for one job, and each run. The floor never sees any of it. Run `install_log.sql` again after it, then `select lab_allow('your login email');` |
| 41 | `machine_files.sql` | Machine files (Prototype lab): STEP files and programs sent from the lab to the Homag router's and the Bend-Tech's own logins (`machine.html`), with revisions; a file is cleared from storage once the machine has it, its record kept. Needs `lab.sql`. Run `install_log.sql` again after it; machine logins are added with `select machine_allow('email', 'homag');` |
| 42 | `look_only.sql` | Look-only departments: a supervisor can be given another department's Work orders and Recently completed to look at on the tablet, never to change (Sam on CNC looks at Milling, 20 Oct). `set_look_only(email, departments)` from the SQL Editor; who may count doesn't change. Run `install_log.sql` again after it |
| 43 | `feedback_close.sql` | Closing feedback notes: the office marks a note Solved or Not relevant (or puts it back), and it moves to a folded Closed list. Nothing is deleted: the note stays, with who closed it and when. Managers only. Needs `feedback.sql`. Run `install_log.sql` again after it |
| 44 | `tv_coming.sql` | Coming up on the floor TV: the next 10 jobs In Production by Monday's delivery date (today or later), with PROJ number, name and date, in place of the department rows. `tv_snapshot` sends them as `coming` (version 4); nothing else it sends changes. Replaces `tv_snapshot` from `tv_photos.sql`, so that file now stops. Run `install_log.sql` again after it |
| 45 | `direct_counts_off.sql` | The old direct count route is closed (review finding R-4): no login changes a count except through `set_count()` (managers also through Advance). Also carries `check_counts_safety()` and `check_tv_photos()` rewritten so the live `check_everything()` is all PASS: the first now expects the direct route refused, the second looks only at its own practice jobs (a real job's picture was on the TV). Replaces pieces of `counts_safety.sql` and `tv_photos.sql`, so those now stop. Registers itself: one paste, nothing to run after it |
| 46 | `incomplete_deliveries.sql` | When not everything goes on a trip (26 Oct). Delivery finishes it part-way in one step (`complete_trip_part()`): which tables went, which didn't and why, how many of each extra went; the database makes a new trip for the rest (same job and kind, only the tables still owed, the ticket and site files going with it). A white glove or dock to dock rest waits for the delivery manager to give it a day (`schedule_rest()`, or `cancel_rest()` to take it off); a pickup's rest is back on Ready for pickup at once. New tables `trip_parts` and `part_extras`, new view `v_rest_waiting`; `v_deliveries`, `v_loadouts` and `v_loadout_extras` gain columns at the end. Replaces those three views, so `trip_types.sql`, `delivery_types.sql` and `delivery_extras.sql` now stop if run again. One paste; registers itself. Ends with `check_incomplete_deliveries()`. |
| 47 | `job_status.sql` | Job status (`status.html`): look a job up by PROJ number or name and see where it is. Adds look-up logins for sales, who can open that page and nothing else (`select set_look_up('their email');` from the SQL Editor), and turns them away from every log: issues, defects, flags, photos, trips, tickets, Arrow. Replaces `sees_lane()` from `problems.sql`, so that file now stops. Registers itself: one paste, nothing to run after it |
| 48 | `off_supabase.sql` | Saved files come off Supabase (31 Oct). A photo or delivery file leaves Supabase once its job has been past Delivery for 60 days (and the file is 60 days old) and the office's save has found it, at the same size, in both the job's OneDrive folder and the backup folder within the last day; a trip's ticket and signature also wait for its signed ticket. The record stays; only the file leaves. New table `filed_copies`, the save's `record_filed_copies()` and `save_due_jobs()`, a storage rule (`filed_removable()`), `files_ready_to_remove()`, `mark_filed_removed()` and `off_supabase_status()`. Takes over from the monthly photo archive, which the office page no longer offers; replaces nothing. One paste; registers itself. Ends with `check_off_supabase()`. |
| 49 | `designs.sql` | The STEP viewer test's storage (31 Oct). A private `designs` bucket for view files (gzip, 20 MB at most), `sees_designs()` (a manager, or a supervisor that isn't a look-up login; works before job_status.sql), and three storage rules: shop logins read; managers add test view files named `test/<date>-<time>-<name>.view.json.gz` and may clear them. Only `step.html` reads it. Replaces nothing. One paste; registers itself. Ends with `check_designs()`. |
| 50 | `zip_drop.sql` | The zip drop (1 Nov). A job's zip from the Outputs project (11_SHOP_FLOOR_ZIP.md, format 1 or 2), dropped on the office's Drop a job's zip section (`drop.html`, lab logins only): every file in it is parked in a private `parked-files` bucket until the office's save has filed it in OneDrive and the backup folder (the job's Production › Files, or Claudes Shop System Folder › Database), then comes off Supabase; the record stays. New tables `zip_drops` and `parked_files`; `zip_drop_new()` refuses a zip that doesn't match its contents.json; the save's `parked_to_file()`, `record_parked_filed()`, `hold_parked()`, `parked_ready_to_remove()`, `mark_parked_removed()` and a storage rule (`parked_removable()`); `parked_replace_ok()`. Replaces nothing. One paste; registers itself. Ends with `check_zip_drop()`. |
| 51 | `arrow_pos.sql` | Arrow POs made by the app, and split runs (1 Nov). Each sheet's Arrow lines from the upload file (`sheet_arrow_lines`, saved by the drop page with `set_sheet_arrow()`); the PO details and next number (`arrow_po_settings`, set from the office; never in a page file); every PO as printed (`arrow_pos`); `arrow_po_make()` marks what's ticked gone and makes one PO across jobs, a part of an item going as a run of its own (`outside_jobs` gains `po_id`, `run_of`, `arrow_qty`); `v_outside_jobs` gains `po_id`, `po_name`, `run_of`, `arrow_counts` at its end; the save's `arrow_pos_to_file()` and `record_arrow_po_filed()`. Replaces `v_outside_jobs` from `arrow_pickup.sql`, so that file now stops. One paste; registers itself. Ends with `check_arrow_pos()`. |
| 52 | `design_viewer.sql` | The 3D design viewer (1 Nov). `item_designs`: one row per item's 3D model from a zip's Design/ folder (the newest for a job's item is the one shown; older ones are kept). A private `design-views` bucket for the view files the drop page makes on Luke's PC (gzip, 20 MB at most): read by managers and by supervisors in the departments on one setting (Full Custom to start; widen it with `select set_design_departments('{full_custom,assembly_qc}');`), put in by lab logins only where a row waits for one, never changed or removed. While a 3D model's STEP is still parked, those same logins may read it, so a tablet can make a missing view itself. `design_register()`, `design_view_stored()`, `design_view_failed()` (the drop page), `set_design_up()` (turn a design upright). Needs `zip_drop.sql`. Registers itself: one paste. Ends with `check_design_viewer()`. |

Not here on purpose: **`set_up_logins.sql`**, which has everyone's login addresses. Keep it on your own computer, not on GitHub.
