# Testing kit, part 10 — Ready queues, Tasks & Issues (24 Sep 2026)

How the Ready queues, Tasks & Issues build was tested in Claude's sandbox before it went live. Read `testing-kit.md` first (the stand-in database, `pgsupa.js`, jsdom); `testing-kit-nav.md` has the go-live method used for this build.

## The stand-in

- Local Postgres 16 in `/tmp/pg`, port 5433, database `sync`. Supabase stubs, then every live SQL file in run order, then `ready_issues.sql` (`base/load.sh ../out/ready_issues.sql`, wrapped by `base/fresh.sh`).
- `base/seed.sql` for this build:
  - **PROJ-00418**, 5 sheets at different stages. Sheet 3 has 1 of 2 through Finishing and Metal at 0; sheet 5 has no metal; an **open Arrow item** (powdercoat) names sheet 2.
  - **PROJ-00313**, In Production, in Sanding, Metal Status **Not Ready**. It's on All for Finishing but not on Ready.
  - **PROJ-00435**, Pre-Production, Metal Status **Not Ready**, to check Needs metal cut sheets outside In Production.
  - A TEST copy of PROJ-00418, and two Finishing routine tasks (one overdue, so the "!" shows).
- People: 1111 Mike (Sanding + Finishing), 2222 Luke (manager), 3333 Test Supervisor, 4444 Donnie, 5555 Willie, 6666 KP, 7777 Shawn, 8888 David, 9999 Jim (Finishing).

## What was run

| Test | What it covers | Result |
|---|---|---|
| `check_ready_issues()` (in the SQL file) | 14 steps: Assembly / QC waits on Finishing and Metal; no metal = done; Arrow holds a sheet until it's returned; *waiting on* text; ready follows the counts; the metal list (Not Ready only, Pre-Production included, test jobs never, managers only); defects asked, answered, replied (*Came back*), noted; lanes kept apart; supervisors can't answer | 14/14 PASS, sandbox and live |
| Deliberate breaks | 9 broken versions of the SQL, among them no Arrow hold and the `came_back` bug below, each loaded in turn | Each one makes the check fail |
| `t/test_ri_tablet.js` | The real `index.html` in jsdom through each login: tabs per department, Ready / All, "n pieces ready", job page marks, one Report button → Defect / Issue, Ask the office, replies, the "!" on Tasks and no pinned tasks on Work orders, old saved tabs (Problems → Issues, Log → Tasks), offline queue and resend | 51/51 PASS |
| `t/test_ri_office.js` | The real `office.html`: Issues from the floor (work stopped first, Issue / Defect tags), counted defects not waiting, Needs metal cut sheets (313 and 435, not 418) and it clearing when Monday changes, the Needs you number, Answer and close, notes, the job page's Issues panel, a supervisor refused by `answer_defect` | 16/16 PASS |
| `t/test_nav_tablet.js`, `t/test_office_nav.js` | The previous build's navigation tests, re-run on the new pages | 25/25 · 35/36 (the one miss also fails on the old page: its fixture asks for sheet 6 of a 5-sheet job) |
| Every earlier check | `verify_setup`, `check_test_lane`, `check_floor`, `check_photos`, `check_advance`, `check_supply_lists`, `check_loadouts`, `check_deliveries`, `check_deliveries_v2` | All PASS. `check_catch_up` steps 1–3 fail only in the sandbox (no Monday columns there) |
| Run twice | `ready_issues.sql` run twice more on a seeded database | No errors; 14/14 each time |
| Screens | `t/snap_ri.js` saves the new screens and photographs them in Chromium | Looked right |

## The bug the tests caught

`reply_defect()` on a counted defect (one not yet asked) set `came_back` to null and hit the not-null rule. Fixed with `coalesce(...)`; step 10 of the check now asks a question on a counted defect, and fails if the bug is put back.

## Going live (24 Sep, evening)

1. SQL Editor, new query tab: the live Metal labels first (`Not ready` in lower case on the board; the view ignores case and spaces). 10 In Production jobs matched.
2. `ready_issues.sql` pasted with a SHA-256 check, run, then `check_ready_issues()` again: **14/14 PASS**.
3. `index.html` and `office.html` built in the GitHub upload tab from the live files plus the tested changes, each checked by SHA-256 before and after, and committed as `b9d63fe`.
4. Both pages served from GitHub Pages matched the tested files byte for byte and loaded to the sign-in screen with no errors from the page (one old *Invalid Refresh Token* message is Supabase clearing a stale sign-in).
