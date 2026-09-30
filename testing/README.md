# Testing kit — Shop Floor Production System

*For build chats. Luke doesn't need to read this.* This one file replaces the sixteen `testing-kit*.md` parts (they're kept in `history/` for their feature test scripts). Updated 30 Sep 2026.

Every change is tested in Claude's sandbox against stand-ins for Supabase, Monday and the browser before Luke gets it. **Re-run the relevant tests before handing Luke any changed file,** and say plainly what the stand-ins can't cover: the real SQL Editor, GitHub Pages, the real Monday API, a real tablet's camera, signature and zoom, and jsDelivr in a real browser.

## 1. Build everything (one command)

```bash
curl -sfL -o /tmp/setup.sh https://raw.githubusercontent.com/lukehart1228/shop-floor/main/testing/setup.sh && bash /tmp/setup.sh
```

This installs Postgres 16 with `pg_cron` and the `http` extension, downloads the live repo to `/home/claude/sf/repo`, copies the helpers, and builds the `sync_base` database from every file in `sql/` in the live order, each run twice as one transaction. It ends with every check's score, and all should be full. It takes a few minutes the first time. After a sandbox reset, run it again; it skips what's already there. Set `KEEP_REPO=1` to keep a repo copy you've changed.

**Where things are afterwards:**

- `/home/claude/sf/repo`: the live pages at the top, plus `sql/` and `testing/`. This *is* what's live, byte for byte.
- `/home/claude/sf/out`: put new and changed files here while building.
- `/home/claude/sf/base`: `load.sh`, `fresh.sh`, `checks.sh`, `overlaps.py`, the seeds and stubs, and `test_guards.sh`, `test_devices.sh`.
- `/home/claude/sf/t`: `pgsupa.js`, the fake Supabase client that talks to the real test database as a real login, and the browser tests.

## 2. Daily moves

- `bash /home/claude/sf/base/fresh.sh [/abs/path/new.sql …]` gives a fresh `sync` from `sync_base`, plus your files (each twice, one transaction each), plus the seed (PROJ-00099, 00325, 00362, 00418 with real-shaped sheets; PROJ-00501 due soon; 00502 with no date; Shawn on Delivery). It needs absolute paths. It loads files before the seed, so a one-time go-live step finds an empty floor; to test go-live, seed first, then load the file.
- `bash base/checks.sh` prints every live check as `n/m`. `select * from check_everything()` does the same inside the database, but its three Monday checks always fail here.
- Browser tests: `cd /home/claude/sf/t && TZ=America/Indiana/Indianapolis node test_x.js`. **Always use shop time**: after 8 pm Eastern the sandbox (UTC) is on tomorrow.
- `test_same.js`: every supervisor's screens (Mike, Donnie, Willie, KP, Jim, Eric, Shawn) on the new `index.html` (`/home/claude/sf/out/index.html`) compared with the live one, ids blanked. **Run it on every tablet-page change.** It also checks the version report.
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
2. **Add the file to the catalog.** Add its line to `install_log.sql`'s catalog insert (run order, fingerprint, replaces) so a fresh build knows it, and add its check to `check_everything()`'s list. Both happen in the same build.
3. **Safe to run twice.** Test twice, each as one transaction (`psql -1`), because the SQL Editor runs a whole file as one transaction.
4. **End with its own check**, so the editor's single visible result is the PASS/FAIL table. A `do` block at the end would hide it.
5. **After building, run `test_guards.sh`** with the file loaded. The expected refusals change when a new file replaces something, so update the `exp=` line.

## 5. Rules every page change follows

1. **Bump `PAGE_VERSION`** in `index.html` (`2026-09-30.3` → `2026-10-02.1`; keep the number after the dot to one digit per day). Update `OFFICE_VERSION` in `office.html` when it changes.
2. **Check library hashes.** Pages load supabase-js and pdf-lib with `integrity`. A library change means a new hash: `npm pack @supabase/supabase-js@2.45.4`, then `openssl dgst -sha384 -binary dist/umd/supabase.js | openssl base64 -A`. `supabase.min.js` isn't in the package; never hash it.
3. **Make sure the new page works on the old database and the old page on the new one.** Test both, because tablets and the database never update at the same moment.

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
- `sheet_progress.qty_required > 0`, so a skipped Sanding count is marked done, never zeroed.
- The change-order trigger is deferred; checks use `set constraints all immediate`.

**jsdom and the page harness**

- **Read `#app`, never `document.body`**: the body holds the page's script text.
- `textContent` runs adjacent elements together.
- **Close a window only after its render settles** (`await wait(500)`).
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
