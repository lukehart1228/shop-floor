# Testing kit — Shop Floor Production System

*For build chats. Luke doesn't need to read this.* Every change is tested in Claude's sandbox against stand-ins for Supabase, Monday and the browser before Luke gets it. Say plainly what the stand-ins can't cover: the real SQL Editor, GitHub Pages, the real Monday API, a real tablet's camera, signature and zoom, and jsDelivr in a real browser. (History of the kit: the spec's Changelog; the old per-feature kits are in `history/`.)

## 1. Build everything (one command)

```bash
curl -sfL -o /tmp/setup.sh https://raw.githubusercontent.com/lukehart1228/shop-floor/main/testing/setup.sh && bash /tmp/setup.sh
```

Installs Postgres 16 with `pg_cron` and the `http` extension, downloads the live repo to `/home/claude/sf/repo`, copies the helpers, and builds the `sync_base` database from every file in `sql/` in the run order written in `sql/README.md`, each run twice as one transaction. Nothing is listed by hand: the build stops if a file in `sql/` has no row in that run order, if a self-registering file has no line in `install_log.sql`'s master list, or if `whats_installed()` isn't all PASS afterwards. It ends with every check's score (`checks.sh` finds the checks in the database itself); all should be full except the three that need the real Monday. A few minutes the first time; after a sandbox reset run it again (it skips what's there). `KEEP_REPO=1` keeps a repo copy you've changed.

Afterwards: `/home/claude/sf/repo` is what's live, byte for byte · `/home/claude/sf/out` is where new and changed files go, laid out like the repo (`out/sql/…`, `out/testing/tests/…`, pages at the top) · `/home/claude/sf/base` has the helpers (`load.sh`, `fresh.sh`, `checks.sh`, `overlaps.py`, the seeds, stubs and the `.sh` tests) · `/home/claude/sf/t` has `pgsupa.js` (the fake Supabase client that talks to the real test database as a real login) and the browser tests.

## 2. Run everything (one command, in sections)

```bash
bash /home/claude/sf/repo/testing/run_all.sh build      # sync_base_old = live sql/; sync_base_new = live + out/sql
bash /home/claude/sf/repo/testing/run_all.sh sql        # then: pages1, pages2, browser1, browser2
bash /home/claude/sf/repo/testing/run_all.sh table      # the score sheet; exit 1 if anything failed
```

`run_all.sh all` does the lot, but in Claude's sandbox one command may run for 5 minutes and the lot takes about 15, so run the sections one per command. Every test runs on a fresh seeded copy of the **new** database with the environment its row below names, pages served from `/tmp/allpages` (the live pages with `out/`'s on top), tests and helpers from `out/testing/` on top of the repo's. Each test's full output is in `/tmp/run_all/<test>.log`; a rerun of one test (`ONLY="test_same" bash run_all.sh pages1`) replaces its row. **The Changelog quotes the table, not a paragraph of scores.**

What run_all doesn't do: a test's own `OLDDB=` / `MODE=` / `LIVEPAGE=` proofs (they belong to the build chat that made the file, §3), screenshots (`shots_*.js`), and the three Monday checks.

**Old and new database by hand.** `TEMPLATE=sync_base_old bash base/fresh.sh` (or `_new`) gives a seeded `sync` from either. To rebuild the new one after editing a SQL file: `LIVE=/tmp/run_all_sql bash base/load.sh` (a folder with the live sql plus yours) then `create database sync_base_new template sync_base`. A copy made earlier still has the old functions.

**The seed** (`fresh.sh`): PROJ-00099, 00325, 00362, 00418 with real-shaped sheets; PROJ-00501 due soon; 00502 with no date; Shawn on Delivery; logins from `people.sql` (§4). It loads any files given before the seed, so a one-time go-live step finds an empty floor.

## 3. The tests

Run a browser test as `cd /home/claude/sf/t && TZ=America/Indiana/Indianapolis node test_x.js` — always shop time (after 8 pm Eastern the sandbox is on tomorrow). Chromium tests also take `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1` (the second routes the service worker's requests through the stand-ins). `PAGE=` is a tablet page, `OUT=` a folder holding every page, `OLDDB=1` runs a test on a database without its own SQL file (the "not set up yet" messages, or nothing changed). **A new check must be shown to fail:** break what it guards, one break at a time, and see the right line catch it.

| Test | Covers | Runs with | Notes |
|---|---|---|---|
| `checks.sh` | every check in the database, n/m each | `DB=sync` | finds the checks itself; the three Monday checks always fail here |
| `test_guards.sh` | refusals are exactly the replaced files; definitions unchanged after re-running all 45; the rollback path (tablet.sql → test_lane.sql → direct_counts_off.sql); a stale permission; a new file naming what it replaces; a self-registering file (its check runs with no install_log.sql re-run; one whose line disagrees with the master list stops) | `LIVE=<sql folder>` on a fresh `sync` | update `exp=` when a new file replaces something |
| `test_devices.sh` | device reports, the walls on the install-log tables, the SQL-Editor-only functions, the 14-day rule for devices | fresh `sync` | |
| `test_direct_counts_off.sh` | the four rewritten checks; each line of `check_direct_counts_off()` fails when broken; `check_tv_photos()` with a real job's picture on the TV (old 7/9, new 9/9); the file on the old install log, then install_log.sql after it | `F=` the file; needs `sync_base_old` and `_new` | |
| `test_connector_safety.sh` | R-14 and R-17: the read-only connector role can't reach the internet; `run_monday_sync()` against a local Monday | needs `helpers/monday_standin.py` | the stand-in never reached the repo (7 Oct chat); run_all skips it |
| `test_csv_cell.js` | spreadsheet cells: text starting with `= + - @` gets a leading apostrophe | `OUT=` | no database |
| `test_style_same.js` | `index.html`'s inline colour tokens equal the newest `sf-style-<date>.css`; `office.html` loads it and carries no `:root`; no hard-coded sheet greys, no white on turquoise | `OUT=` | no database; **run on every change to index.html, office.html or the stylesheet** |
| `test_lab_reference.js` | the lab's engine (from `lab.html`) against the generator's hand-checked PROJ-00418 reference and the CNC template's hard rules | `LAB=` the lab page | no database |
| `test_same.js` | every supervisor's screens on the new tablet page vs the live one, ids blanked; the version report | `NEWPAGE=`, `LIVEPAGE=`; `NAV=ignore` sets the tab strip aside, `SKIP_TABS=past` skips a tab, `SHOWDIFF=1` prints the differences | seeded; **run on every tablet-page change** and read every difference; the queue is rows (`button.qrow`; `button.job` only on Recently completed and load-outs) |
| `test_same_office.js` | the office-side pages drawn live vs new, the same apart from the Feedback button | `OUT=` | seeded |
| `test_feedback.js` | the Feedback button on every signed-in page, what a note records, the tablet's offline queue, the office's list | `OUT=`; `OLDDB=1` | seeded; reads every page from `OUT`, so a tablet-only build needs a folder with all pages |
| `test_feedback_close.js` | Solved / Not relevant, the folded Closed list, Put it back, Copy as text; Mike refused | `OUT=`; `OLDDB=1`; `OFFICE=` an older office page | seeded |
| `test_trip_types.js` | dock to dock and Delivery's tasks on Julia's page, Shawn's phone and the TV | `OUT=`; `OLDDB=1` | seeded; makes its own Julia |
| `test_pdf_ticket.js` | a trip's PDF ticket and site files open inside the app; the no-viewer, no-signal and broken-file messages | `PAGE=` | seeded; makes its own PDFs |
| `test_wo_beside_ticket.js` | Work order · n sheets beside the ticket; the read-only viewer and its swipe; a change order dropping a sheet | `PAGE=` | seeded |
| `test_extras_checklist.js` | extras on Delivery's trips: upload, the dock checklist, no signal, The truck is leaving, read-only once left, the second trip | `PAGE=`; `OLDDB=1` | seeded |
| `test_handoff_recent.js` | started jobs stay on Ready, the handoff hold, Recently completed | `PAGE=`; `MODE=new` or `old` | seed + `tests/scenario_handoff_recent.sql` |
| `test_recent_delivery.js` | the delivery date on Recently completed, words only | `PAGE=` | seed + the same scenario |
| `test_look_only.js` | Sam (CNC) looks at Milling: tabs, byte-for-byte screens, nothing to press, the database refusing his Milling count | `PAGE=`; `OLDDB=1`; `LIVEPAGE=` a page from before 20 Oct adds the line showing it ignore the list | seeded (new database) |
| `test_send_safety.js` | every reply the tablet's three senders can get: kept, retried or on Couldn't send, never dropped; a change order while the job is open; counts through `set_count()` | `NEWPAGE=`; `OLDDB=1`; `LIVEPAGE=` a page from before 6 Oct adds the lines showing that page losing entries | **fresh seed per run** (it makes a change order) |
| `test_tv_photos.js` | a site photo's TV copy, the home list, `tv_photo()`, the job page's Floor TV line and the hide switch | `OUT=`; `OLDDB=1` | seeded (new database); the camera is stood in for |
| `test_onedrive_save.js` | saving to OneDrive and the backup folder against an in-memory folder system: finding job folders, never overwriting, records rewritten only when changed, paging, the 7-day reminder | `OUT= SF_MAX_ROWS=2`; `OLDDB=1` | seeded; **once per fresh database**; about a minute |
| `test_office_sections.js` | the office app in Chromium: the sections inside it, Julia's Deliveries-only office, a supervisor turned away, every page reporting its version | `OUT=` + Playwright | seeded |
| `test_office_link.js` | Back to the office from the tablet app (managers), asking first when something waits to send | `PAGE=` + Playwright | seeded |
| `test_auto_update.js` | the tablet checks for a newer copy of itself and reloads only when safe; Shawn's phone through the real service worker | `PAGE=`; `ROOT=` a folder with every page (to test a changed `sw.js`) + Playwright | seeded; "newer" is worked out from the page's own version |
| `test_sw_assets.js` | the offline helper (`sw.js`): the shop's own `.js` and `.css` fetched fresh when connected, from the saved copy when not; libraries saved-copy first; one cache name | `SW=` the worker + Playwright | no database; the 30 Sep worker fails its changed-in-place lines |
| `test_pdf_chromium.js` | the real pdf.js drawing the ticket at phone size; a tampered viewer refused; the ticket offline after reopening | Playwright (reads `out/` first, then the repo) | seeded; unpacks pdfjs-dist 3.11.174 to `/tmp/pj` |
| `test_onedrive_save_chromium.js` | the same save in real Chromium with the browser's folder API and IndexedDB | `OUT=` + Playwright | seeded; compare bytes, never text (a leading BOM) |
| `test_tv_coming.js` | the floor TV in real Chromium through the real database as anon: the picture actually drawn, the floor bar, Coming up, three screen sizes | `OUT=`; `OLDDB=1`; `PAGE=`; `SHOTS=` + Playwright | **fresh seed per run**; waits for the first snapshot |
| `test_machine_files.js` | STEP files and programs from the lab to the Homag and Bend-Tech logins: fingerprints, revisions, the Bend-Tech's folders, the router's flat folder, refusals | `OUT=`; `MODE=nofiles` + Playwright | fresh seed (new database) |
| `test_lab.js` | the Prototype lab in Chromium: a run saved, an answer, Always, a rule file, Stop using, Download what I've learned; David, Mike and no login refused | `OUT=`; `OLDDB=1`; `NM=` pdfjs-dist path + Playwright | **needs the three work orders (PROJ-00212, 00317, 00421) beside it in `t/`: customer documents, ask Luke to attach them, never on GitHub** |
| `shots_tablet.js`, `shots_office.js` | screenshots of the queue (tablet and phone size) and the office, for a look before handing over | `PAGE=` / `OUT=`, `SHOTS=/tmp/shots` + Playwright | not tests; Barlow from `@fontsource` if installed |

Older feature tests (Advance, deliveries, pickups, pace, inventory, routes…) exist only inside `history/testing-kit-*.md` (pull one out with `python3 base/kx.py history/<file>.md "<test>.js" t/<test>.js`); they were written against the helpers of their day and some are stale. For those features the regression net is their `check_*()` function plus `test_same.js`'s screen comparison.

## 4. Test as a real login, never as postgres

Supabase's API connects as `authenticator`, then switches role and sets the JWT claims. `pgsupa.js` and the `as()` helper in `test_devices.sh` do exactly that. A plain `postgres` session sails through the "is this the SQL Editor?" checks and proves nothing. Logins from `people.sql` (made-up addresses, `@example.com`, finding R-9 — never a real one, the repo is public):

| Login | ID |
|---|---|
| Mike (Sanding + Finishing) | `1111…` |
| Luke (manager) | `2222…` |
| Test Supervisor | `3333…` |
| Donnie (Milling, CNC) | `4444…` |
| Willie (Metal) | `5555…` |
| KP (Assembly / QC) | `6666…` |
| Shawn (Delivery) | `7777…` |
| David (manager) | `8888…` |
| Jim (Finishing) | `9999…9990` (not `9999…9999`, Julia's in the old deliveries test) |
| Eric (Full Custom + Assembly / QC) | `aaaa…` |

Secret key: `set role service_role`. No login: `set role anon`.

## 5. Rules every new SQL file follows

1. **Its first lines register it and guard it**, straight after the header comment:
   ```sql
   do $$ begin
     if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
       perform sql_file_register('new_file.sql', 46, 'check_new_file', 'check_new_file', '{older.sql}');
     end if;
     if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('new_file.sql', '{older.sql}'); end if;
   end $$;
   ```
   Run order, fingerprint (something only this file makes), its check, and the earlier files it rewrites pieces of (find them with `python3 base/overlaps.py /home/claude/sf/repo/sql /home/claude/sf/out/sql/new_file.sql`; `'{}'` if none). On a database with an older install log the register line is skipped and `sql_file_start` catalogues the file the old way; `install_log.sql` run after it makes it whole.
2. **Add its line to `install_log.sql`'s master list and its row to `sql/README.md`'s run order**, in the same build. `load.sh` refuses to build without either, and the database refuses a file whose own line disagrees with the master list. For Luke a release is then **one paste** (no "run install_log.sql again"); `install_log.sql` is pasted only when it changed itself, and then before the files that need it.
3. **Safe to run twice.** Test twice, each as one transaction (`psql -1`), because the SQL Editor runs a whole file as one transaction.
4. **End with its own check**, so the editor's single visible result is the PASS/FAIL table. A `do` block at the end would hide it.
5. **Run `test_guards.sh`** with the file loaded. When a file replaces something, the expected refusals change: update its `exp=` line.
6. **A new table revokes insert, update, delete and truncate from anon and authenticated** (`counts_safety.sql` also stops later tables getting TRUNCATE by default, and `check_counts_safety()` fails if any table has it).
7. **Every function gets `revoke all on function … from public, anon;` before its grants**, SECURITY DEFINER or not (R-17). The only functions that may run with no login are `my_role()` and `owns_dept()` (the security rules use them) and the TV's `tv_snapshot()` and `tv_photo()`; a new one means adding its name to the `allowed` list in `check_connector_safety()`. **No function of an extension that reaches the internet** (`http`, `pg_net`) is executable by anyone but postgres (R-14). `check_connector_safety()`, and so `check_everything()`, fails if either is missed. Supabase is reached through a connector read-only only; SQL files are run by Luke or Claude in Chrome in the SQL Editor.
8. **Counts go through `set_count()`**, one sheet at a time; no login holds an update grant on `sheet_progress` (R-4, 21 Oct) and `check_direct_counts_off()` fails if one comes back. A check that needs to count does it as the tablet does, through `set_count()`.

## 6. Rules every page change follows

1. **Bump the version** — `PAGE_VERSION` in `index.html` (`2026-10-20.4` → `2026-10-21.1`: the date, then the build that day), `OFFICE_VERSION` in `office.html`, `TV_VERSION` in `tv.html`, `PAGE_VERSION` in the others.
2. **Check library hashes.** Pages load supabase-js and pdf-lib with `integrity`; `index.html` also loads pdf.js 3.11.174 (`legacy/build/pdf.worker.min.js`, then `pdf.min.js`, both checked). A library change means a new hash: `npm pack @supabase/supabase-js@2.45.4`, then `openssl dgst -sha384 -binary dist/umd/supabase.js | openssl base64 -A`. `supabase.min.js` isn't in the package; never hash it.
3. **A queued entry is only discarded when the database refuses it for a business reason** (R-1): anything else stays queued, and a refusal goes on the tablet's *Couldn't send* list with its content. Use `sendOutcome()`.
4. **Counts go through `set_count()`** (R-2). Don't add a direct write to `sheet_progress`: the grant is gone.
5. **The new page on the old database and the old page on the new one** — test both, because tablets and the database never update at the same moment.
6. **Any screen where something can be half-done must keep `safeToReload()` from reloading there** (add its state, or leave its tab out of `UPDATE_SAFE_TABS`), or the self-update could reload under a supervisor's fingers.
7. **Shared files.** `sf-common-<date>.<n>.js` and `sf-style-<date>.<n>.css` carry a date because the offline helper used to serve the saved copy for ever. Since `sw.js` shell v4 (21 Oct) the helper fetches the shop's own `.js` and `.css` fresh like pages, so the **next** change to either can rename it to a stable name (`sf-common.js`, `sf-style.css`), edit it in place after that, and retire the seven-page rename; `test_style_same.js` then needs to look for the stable name.

## 7. Gotchas that cost time

**Sandbox and shell**

- `/bin/sh` isn't bash: there's no `{a,b}`, no `<( )` and no `time`. Run scripts with `bash`.
- The sandbox restarts Postgres between turns: `pg_isready -h /tmp/pg -p 5433 || su postgres -c "…pg_ctl … start"` (`setup.sh` and `run_all.sh` do it). A browser test stuck on Sign in with `ECONNREFUSED` means Postgres is down.
- One command may run 5 minutes; background jobs get killed. Split long runs (run_all's sections).
- `api.github.com` is often rate-limited (shared address). `raw.githubusercontent.com` and `codeload.github.com` work.
- `apt-get update` fails on a nodesource repo (403); delete it first and run update separately from install.
- `pgrep -f` matches itself; use `"[s]erver.py"`. **`pkill -f` can kill the shell running it** if that command line names the process: the whole turn hangs. Check a stand-in server by its port (`curl -s -m 2 http://127.0.0.1:8765/`) and start it with `setsid … &`.

**Database**

- **pg_cron keeps a connection to `sync`**; `load.sh` terminates it before snapshotting. It also unschedules the sync so nothing calls the real Monday.
- **Never put JSON inline in `psql -c`**: shell quoting strips it. Write a file and use `-f`.
- **After editing a SQL file, rebuild the template before testing on it.** A copy made earlier still has the old functions, and a break test then passes or fails for the wrong reason.
- Two things in one transaction share `now()`. Undo in send routes uses `events_mark`, and `check_loadouts` backdates one load-out.
- Where the current copy of a function lives is wherever the newest file defines it (`overlaps.py`): `check_ready_issues()` in `send_routes.sql`; `v_ready_to_work` in `handoff_recent.sql` (with an extra last column, so an older file can't put the old view back without `drop view … cascade` — a rollback of `ready_issues.sql` or `send_routes.sql` is a chat job); `verify_setup()`, `check_test_lane()`, `check_counts_safety()` and `check_tv_photos()` in `direct_counts_off.sql`.
- A file that ran before the install log existed shows as *found* with no time; `whats_installed()` treats it as before any logged run (21 Oct), so a rollback over it is still flagged.
- `sheet_progress.qty_required > 0`, so a skipped Sanding count is marked done, never zeroed.
- The change-order trigger is deferred; checks use `set constraints all immediate`.
- Like Supabase, the stubs refuse a storage delete that doesn't come through the Storage API (`storage.allow_delete_query`); `pgsupa.js`'s `remove()` sets it, and so must any check that deletes storage rows (as `check_photos` does).

**jsdom and the page harness**

- **Read `#app`, never `document.body`**: the body holds the page's script text. `textContent` runs adjacent elements together. Typed input isn't in snapshots (it's the `value` property).
- **Pages that load `sf-common-….js`** (office, delivery, inventory, pace, upload): a jsdom harness must run that file and the page's own script as ONE eval (`pageScript()` in `test_feedback.js`), because jsdom keeps each eval's top-level `const`s separate, unlike a browser.
- **Close a window only after its render settles** (`await wait(500)`). The tablet shows a toast *before* it reloads after a send; wait for the banner, not the toast.
- `pgsupa.js`: keeps uploaded files in memory (a test that downloads a file must upload it in the same process); sends `jsonb` arguments as JSON and returns downloads with their uploaded type (work-order pages as a tiny PNG); has `range()`, `insert()` (one row or many; arrays and objects as JSON), `select(cols, { count: "exact", head: true })`, and `SF_MAX_ROWS=n` caps every select like Supabase's API (1,000 by default there). It reports a missing function as Postgres does (`42883`); real Supabase says `PGRST202`; the tablet treats both as "not there yet".
- jsdom has no Cache API, `print`, `open` or `createObjectURL`; stub them. pdf-lib and the page live in different realms, so wrap bytes with `new Uint8Array(fs.readFileSync(…))`.
- The office asks for a PIN on a new computer: click `[data-k]` 1-2-3-4 twice.

**Chromium**

- Chromium ignores the sandbox proxy: serve pages from a local `http.server`, route the Supabase script to a stand-in, and **strip ` integrity="…"`** from the served HTML or the browser rightly refuses it. In Playwright the last route added wins: add the catch-all block before the supabase-js stand-in.
- Google Fonts are blocked; use `@fontsource/barlow` (`npm install @fontsource/barlow @fontsource/barlow-condensed` in `/home/claude/sf`).
- Printing: no `@page size` (Chromium misreads orientation).
- Playwright is at `/home/claude/.npm-global/lib/node_modules/playwright`, browsers in `/opt/pw-browsers`.

## 8. Delivering

Files go to Luke as one zip laid out like the repo: pages at the top, SQL in `sql/`, kit changes in `testing/`, each file in the folder it goes in on GitHub. Say which SQL files to paste and in what order (`install_log.sql` first when it changed). Claude in Chrome can commit with Luke's go-ahead each time; its `file_upload` can't read container paths — what worked: diff live → new, gzip+base64 the edits, and apply them in the github.com editor tab from `raw.githubusercontent.com`. After a commit, compare the served file with the tested one byte for byte.
