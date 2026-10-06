# Testing kit — Shop Floor Production System

*For build chats. Luke doesn't need to read this.* This one file replaces the sixteen `testing-kit*.md` parts (they're kept in `history/` for their feature test scripts). Updated 6 Oct 2026 (with counts_safety.sql and the review fixes R-1, R-2, R-5, R-9, R-10, R-12).

Every change is tested in Claude's sandbox against stand-ins for Supabase, Monday and the browser before Luke gets it. **Re-run the relevant tests before handing Luke any changed file,** and say plainly what the stand-ins can't cover: the real SQL Editor, GitHub Pages, the real Monday API, a real tablet's camera, signature and zoom, and jsDelivr in a real browser.

## 1. Build everything (one command)

```bash
curl -sfL -o /tmp/setup.sh https://raw.githubusercontent.com/lukehart1228/shop-floor/main/testing/setup.sh && bash /tmp/setup.sh
```

This installs Postgres 16 with `pg_cron` and the `http` extension, downloads the live repo to `/home/claude/sf/repo`, copies the helpers, and builds the `sync_base` database from every file in `sql/` in the run order written in `sql/README.md`, each run twice as one transaction. **Nothing is listed by hand** (finding R-10, 6 Oct): the build stops if a file in `sql/` has no row in that run order, and fails unless `whats_installed()` is all PASS afterwards, so the sandbox can't fall behind live. It ends with every check's score (`checks.sh` finds the checks in the database itself), and all should be full. It takes a few minutes the first time. After a sandbox reset, run it again; it skips what's already there. Set `KEEP_REPO=1` to keep a repo copy you've changed.

**Where things are afterwards:**

- `/home/claude/sf/repo`: the live pages at the top, plus `sql/` and `testing/`. This *is* what's live, byte for byte.
- `/home/claude/sf/out`: put new and changed files here while building.
- `/home/claude/sf/base`: `load.sh` (reads the run order from `sql/README.md`), `fresh.sh`, `checks.sh`, `overlaps.py`, the seeds and stubs, and `test_guards.sh`, `test_devices.sh`.
- `/home/claude/sf/t`: `pgsupa.js`, the fake Supabase client that talks to the real test database as a real login, and the browser tests.

## 2. Daily moves

- **Old and new database, side by side.** Before building, copy today's live database: `psql -h /tmp/pg -p 5433 -U postgres -d postgres -c "create database sync_base_old template sync_base"`. After adding your file to a copy of `sql/` (and its README row), rebuild with `LIVE=/that/copy bash base/load.sh`, then `create database sync_base_new template sync_base`. `TEMPLATE=sync_base_old bash base/fresh.sh` (or `_new`) gives a seeded copy of either.
- `bash /home/claude/sf/base/fresh.sh [/abs/path/new.sql …]` gives a fresh `sync` from `sync_base` (or `TEMPLATE=…`), plus your files (each twice, one transaction each), plus the seed (PROJ-00099, 00325, 00362, 00418 with real-shaped sheets; PROJ-00501 due soon; 00502 with no date; Shawn on Delivery). It needs absolute paths. It loads files before the seed, so a one-time go-live step finds an empty floor; to test go-live, seed first, then load the file.
- `bash base/checks.sh` prints every live check as `n/m`. `select * from check_everything()` does the same inside the database, but its three Monday checks always fail here.
- Browser tests: `cd /home/claude/sf/t && TZ=America/Indiana/Indianapolis node test_x.js`. **Always use shop time**: after 8 pm Eastern the sandbox (UTC) is on tomorrow.
- `test_same.js`: every supervisor's screens (Mike, Donnie, Willie, KP, Jim, Eric, Shawn) on the new `index.html` (`/home/claude/sf/out/index.html`) compared with the live one, ids blanked. **Run it on every tablet-page change.** It also checks the version report. For a build that adds a tab, `NAV=ignore` sets the tab strip aside and `SKIP_TABS=past` skips a named tab; then read every remaining difference.
- `test_handoff_recent.js` (2 Oct): started jobs stay on Ready, the handoff hold, and Recently completed. Seed, load `scenario_handoff_recent.sql`, then run with `MODE=new` (with `handoff_recent.sql`) or `MODE=old` (without). On the live page it fails, which proves it tests something.
- `test_pdf_ticket.js` (5 Oct): a trip's PDF ticket and PDF site files open on their own screen inside the app, never in a new tab; pictures still open in the photo viewer; the no-viewer, no-signal and broken-file messages. Seed, then run. It makes its own sample PDFs (`/tmp/sf_pdf_fixtures/`). On the live page of 2 Oct (`PAGE=…`) it fails, which proves it tests something.
- `test_pdf_chromium.js` (5 Oct): the real pdf.js 3.11.174 drawing the ticket in Chromium at phone size, a tampered viewer file refused, and the ticket still drawing offline after the app is reopened. Seed first; it schedules its own trip. Run with `PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1 PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers` (the first routes the service worker's requests through the stand-ins). Playwright is at `/home/claude/.npm-global/lib/node_modules/playwright`.
- `test_feedback.js` (5 Oct): the Feedback button on every signed-in page (tablet, phone, office, deliveries, inventory, pace, upload), what each note records, the tablet's offline queue, the office's Feedback list (filter, copy as text). Load `feedback.sql` (and `install_log.sql`), seed, run. `OLDDB=1` on a database without `feedback.sql` tests the "not set up yet" messages; `OUT=/home/claude/sf/repo` runs it on the live pages, where it fails.
- `test_trip_types.js` (5 Oct): dock to dock deliveries and Delivery's tasks — Julia's kinds, scheduling both, changing a task (adding a PROJ later), cancelling and putting back; Shawn's dock-to-dock screen and a task's Done (online and with no signal); the photo sender's task-photo and drop-photo paths; the TV's going-out list. Load `feedback.sql`, `trip_types.sql` and `install_log.sql`, seed, run. `OLDDB=1` on a database without `trip_types.sql`. Makes a Julia (schedules deliveries, a supervisor with a department).
- `test_guards.sh` (updated 5 Oct): runs `feedback.sql` and `trip_types.sql` too; `delivery_types.sql` and `tv_pace.sql` now refuse, as `trip_types.sql` replaced pieces of both.
- `test_same.js`: `SHOWDIFF=1` prints where a screen differs from the live page.
- `test_office_sections.js` (5 Oct): the office app in Chromium — Deliveries, Upload, Inventory and Pace inside the office (frames, title rows hidden, state kept when switching), Julia's Deliveries-only office, a supervisor turned away, Feedback from inside a section, every page reporting its version, each section still working on its own. Load `feedback.sql` and `install_log.sql`, seed, run with `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`. In Playwright the last route added wins: add the catch-all block before the supabase-js stand-in.
- **Pages that load `sf-common-….js`** (office, delivery, inventory, pace, upload): a jsdom harness must run that file and the page's own script as ONE eval (`pageScript()` in `test_feedback.js`), because jsdom keeps each eval's top-level `const`s separate, unlike a browser.
- `test_same_office.js` (5 Oct): the office-side pages drawn live vs new, the same apart from the Feedback button. `test_same.js` covers the tablet: compare against a copy of the new `index.html` with the `data-feedback` button line taken out (`NEWPAGE=…`).
- `test_onedrive_save.js` (6 Oct): saving to OneDrive and the hard drive from the office page, against an in-memory folder system like the browser's: finding job folders (main folder, hundreds folders even when one is named `PROJ-00000 - 00099`, `500s`), skipping duplicates and missing folders, hard drive first, never overwriting, records rewritten only when changed, a file Supabase can't hand over, an unplugged backup drive, a new backup drive, permission asked again after reopening, David's computer and the 7-day reminder. Load `feedback.sql`, `trip_types.sql`, `onedrive_save.sql` and `install_log.sql`, seed, run with `SF_MAX_ROWS=2` (every request capped at 2 rows and the page asks 2 at a time, so paging is tested). Takes about a minute (it waits for the automatic save). `OLDDB=1` on a database without `onedrive_save.sql`; `OUT=/home/claude/sf/repo` runs it on the old page, where it fails. **Run it once per fresh database** (it adds flags; a second run hits "one open flag per job").
- `test_onedrive_save_chromium.js` (6 Oct): the same save in real Chromium, the folder picker pointed at the browser's private storage area (the same folder API): real writes and read-backs, a spreadsheet's leading marker surviving the "unchanged?" check, the folders remembered in real IndexedDB across a reload, then an automatic save. `OUT` must be a folder holding every page (the live pages plus the changed ones). Blob.text() drops a leading BOM, so compare bytes, never text.
- `pgsupa.js` (6 Oct) has `range(from, to)`, and `SF_MAX_ROWS=n` caps every select at n rows like Supabase's API (1,000 by default there).
- `test_office_sections.js`'s *Upload opens inside the office, its header hidden* is flaky: on 6 Oct it failed 2 runs in 3 on the live pages as well as the new ones (a race between the frame showing text and its header being hidden). Re-run before blaming a change. Since 6 Oct, it and `test_feedback.js` read the office's version from `office.html` instead of naming it.
- `test_send_safety.js` (6 Oct, R-1 and R-2): the tablet's three senders against every reply the reviewer used (a schema reload, a missing function, an expired sign-in, a 503, a request with no login, a business refusal, a check violation): kept and retried, or on the *Couldn't send* list with what it was — never deleted; the live page loses them in the same run. Then on a database with `counts_safety.sql`: a change order arrives while Mike's tablets have PROJ-00418 open; an unchanged sheet's count lands on the new version and the next tap too; a changed sheet's count is refused, kept, listed, retried and dismissed; the live page's count on the replaced version is refused, on the current one saved. `OLDDB=1` on a database without `counts_safety.sql`: the new page's counts still save. **Fresh seed per run** (it makes a change order).
- `test_csv_cell.js` (6 Oct, R-12): the office's spreadsheet cells — text starting with = + - @ gets a leading apostrophe. No database. `OUT=/home/claude/sf/repo` fails.
- **The pgsupa stand-in reports a missing function as Postgres does** (`42883 … does not exist`); real Supabase says `PGRST202`. The tablet treats both as "not there yet".
- Since 6 Oct `test_feedback.js` and `test_onedrive_save.js` read the tablet's and the office's version from the pages, and `test_same_office.js` takes `OUT=` (a folder with every page).
- **Login addresses in the kit are made up** (`@example.com`, R-9). Never put a real one in a test: the repo is public.
- `test_guards.sh` and `test_devices.sh` cover the install log, the guards, `check_everything()` and device versions (`install_log.sql`).
- Older feature tests (Advance, deliveries, pickups, pace, inventory, routes…) are in `history/`. Pull one out with `python3 base/kx.py history/testing-kit-deliveries.md "test_deliveries.js" t/test_deliveries.js`. They were written against the helpers of their day, so they may need the paths above, and a few are stale (see §6).

## 3. Test as a real login, never as postgres

Supabase's API connects as `authenticator`, then switches role and sets the JWT claims. `pgsupa.js` and the `as()` helper in `test_devices.sh` do exactly that. A plain `postgres` session sails through the "is this the SQL Editor?" checks and proves nothing. Logins from `people.sql`:

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
| Jim (Finishing) | `9999…9990` — Jim is **not** `9999…9999`, which is Julia's in `test_deliveries.js` |
| Eric (Full Custom + Assembly / QC) | `aaaa…` |

- Secret key: `set role service_role`.
- No login: `set role anon`.
- **Prove every new check can fail.** Break the thing it guards, one break at a time, and confirm the right step catches it. The `breaks_*.py` files in `history/` show the pattern.

## 4. Rules every new SQL file follows

1. **The guard line comes first**, straight after the header comment:
   ```sql
   do $$ begin
     if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('new_file.sql', '{older.sql}'); end if;
   end $$;
   ```
   The second argument lists the earlier files this one rewrites pieces of. Find them with `python3 base/overlaps.py /home/claude/sf/repo/sql /home/claude/sf/out/new_file.sql`. Use `'{}'` if none.
2. **Add the file to the catalog and the run order.** Add its line to `install_log.sql`'s catalog insert (run order, fingerprint, replaces), its check to `check_everything()`'s list, and its row to `sql/README.md`'s run order (that's what the testing kit loads from). All three in the same build; `load.sh` refuses to build without the README row.
3. **Safe to run twice.** Test twice, each as one transaction (`psql -1`), because the SQL Editor runs a whole file as one transaction.
4. **End with its own check**, so the editor's single visible result is the PASS/FAIL table. A `do` block at the end would hide it.
5. **After building, run `test_guards.sh`** with the file loaded. The expected refusals change when a new file replaces something, so update the `exp=` line.
6. **A new table revokes insert, update, delete and truncate from anon and authenticated** (`counts_safety.sql` also stops later tables getting TRUNCATE by default, and `check_counts_safety()` fails if any table has it).

## 5. Rules every page change follows

1. **Bump `PAGE_VERSION`** in `index.html` (`2026-09-30.3` → `2026-10-02.1`; keep the number after the dot to one digit per day). Update `OFFICE_VERSION` in `office.html` when it changes.
2. **Check library hashes.** Pages load supabase-js and pdf-lib with `integrity`; `index.html` also loads pdf.js 3.11.174 (`legacy/build/pdf.worker.min.js`, then `pdf.min.js`, both checked) when a trip has a PDF. A library change means a new hash: `npm pack @supabase/supabase-js@2.45.4`, then `openssl dgst -sha384 -binary dist/umd/supabase.js | openssl base64 -A`. `supabase.min.js` isn't in the package; never hash it.
3. **A queued entry is only discarded when the database refuses it for a business reason** (R-1): anything else stays queued, and a refusal goes on the tablet's *Couldn't send* list with its content. Use `sendOutcome()`.
4. **Counts go through `set_count()`** (R-2), which finds the current work order itself. Don't add another direct write to `sheet_progress`.
5. **Make sure the new page works on the old database and the old page on the new one.** Test both, because tablets and the database never update at the same moment.

## 6. Gotchas that cost time

**Sandbox and shell**

- `/bin/sh` isn't bash: there's no `{a,b}`, no `<( )` and no `time`. Run scripts with `bash`.
- The sandbox restarts Postgres between turns. `setup.sh` restarts it, or use `pg_isready -h /tmp/pg -p 5433 || su postgres -c "…pg_ctl … start"`.
- Background jobs get killed.
- `api.github.com` is often rate-limited (shared address). `raw.githubusercontent.com` and `codeload.github.com` work.
- `apt-get update` fails on a nodesource repo (403); delete it first and run update separately from install.

**Database**

- **pg_cron keeps a connection to `sync`**; `load.sh` terminates it before snapshotting. It also unschedules the sync so nothing calls the real Monday.
- **Never put JSON inline in `psql -c`**: shell quoting strips it. Write a file and use `-f`.
- `pgrep -f` matches itself; use `"[s]erver.py"`.
- Two things in one transaction share `now()`. Undo in send routes uses `events_mark`, and `check_loadouts` backdates one load-out.
- **`check_ready_issues()` exists in two files.** `send_routes.sql` carries the current one.
- **`v_ready_to_work` belongs to `handoff_recent.sql`** since 2 Oct, with an extra last column (`held_for_handoff`). An older file can't put the old view back without `drop view v_ready_to_work cascade` first (Postgres won't drop a column with `create or replace`), so a rollback of `ready_issues.sql` or `send_routes.sql` is a chat job. `test_guards.sh` now demonstrates the rollback path on `tablet.sql`.
- `sheet_progress.qty_required > 0`, so a skipped Sanding count is marked done, never zeroed.
- The change-order trigger is deferred; checks use `set constraints all immediate`.

**jsdom and the page harness**

- **Read `#app`, never `document.body`**: the body holds the page's script text.
- `textContent` runs adjacent elements together.
- **Close a window only after its render settles** (`await wait(500)`).
- **`pgsupa.js` keeps uploaded files in memory,** so a test that downloads a file must upload it in the same process.
- `pgsupa.js` sends `jsonb` arguments as JSON (as Supabase does) and returns downloads with their uploaded type. Work-order pages download as a tiny PNG.
- jsdom has no Cache API, `print`, `open` or `createObjectURL`; stub them. pdf-lib and the page live in different realms, so wrap bytes with `new Uint8Array(fs.readFileSync(…))`.
- The office asks for a PIN on a new computer: click `[data-k]` 1-2-3-4 twice.
- The tablet shows a toast *before* it reloads after a send; wait for the banner, not the toast.
- Typed input isn't in snapshots (it's the `value` property).

**Chromium tests**

- Screens and printing use Chromium (`npm install playwright@1.56.0`, `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`).
- Chromium ignores the sandbox proxy: serve pages from a local `http.server`, route the Supabase script to a stand-in, and **strip ` integrity="…"`** from the served HTML or the browser rightly refuses it.
- Google Fonts are blocked; use `@fontsource/barlow`.
- Printing: no `@page size` (Chromium misreads orientation).

**Known stale suites**

- Part 3's office suites expect the old tabs.
- `test_mike_same.js` is replaced by `test_same.js`.
- `test_photos_e2e.js` and `test_loadouts_v2.js` fail rows on purpose once newer SQL is loaded; they prove the old-screen fallback.
- `check_monday_sync`, `check_office` and `check_catch_up` need the real Monday.

## 7. Delivering

Files go to Luke with exact GitHub destinations: pages at the top of the repo, SQL in `sql/`, and kit changes in `testing/`. Claude in Chrome can commit with Luke's go-ahead each time. Claude in Chrome's `file_upload` can't read container paths. What worked: diff live → new, gzip+base64 the edits, and apply them in the github.com editor tab from `raw.githubusercontent.com`. After a commit, compare the served file with the tested one byte for byte.
