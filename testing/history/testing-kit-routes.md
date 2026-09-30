# Testing kit, part 14 — Send routes, the Past tab and sign-in zoom (29 Sep 2026)

*For build chats. Luke doesn't need to read this.* Parts 1–13 still apply. Setup as Part 11: every **live** SQL file, unchanged, twice each, into `sync`, snapshot `sync_base` — through `ready_issues.sql`, then `inventory.sql`. `finish_by.sql` and `pace.sql` aren't live: load them per test.

## Setup notes (29 Sep)

- `rm -f /etc/apt/sources.list.d/nodesource*`, `apt-get update`, install `postgresql-16 postgresql-16-cron libcurl4-openssl-dev postgresql-server-dev-16`, build pgsql-http, cluster on 5433 as `testing-kit.md` §1. `npm install jsdom@24 pg fake-indexeddb playwright@1.56.0` in `/home/claude`; `NODE_PATH=/home/claude/node_modules`. Chromium `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.
- `extract.py` (Part 11) on `sql-files.md` … `sql-files-6.md`, then `site-files.md` … `site-files-4.md` in order.
- `stubs.sql`, `people.sql`, `seed.sql`, `pgsupa.js` from Part 3 + Part 11's JSON patch; `people.sql` plus Jim W (`9999…`) and Eric B (`aaaa…`); `pgsupa.js`'s `users` gains `jim`, `eric`.
- **`fresh.sh` loads files BEFORE the seed**, so `send_routes.sql`'s one-time go-live finds an empty floor. To test go-live, seed first, then load the file (see Results).
- **`fresh.sh` / `fresh_*.sh` need absolute paths** (they `cd` first).
- **The sandbox restarted Postgres between turns**; `pg_isready … || pg_ctl … start`.
- **A test suite changes the database**: a fresh database per run.
- **jsdom: close a window only after its async render settles** (`await wait(500)`) — otherwise a late `showPage()` throws on a closed document.
- **The check fires the change-order trigger with `set constraints all immediate`** (it's deferred to commit, and the check rolls back).
- **Undo uses `events_mark`** (the history's last id at send time), not times: inside one transaction a count and a send share `now()`.
- **`sheet_progress.qty_required > 0`** is a constraint, so a skipped Sanding count is marked done (history source *Not needed — sent straight to Finishing*), not zeroed.
- **`check_ready_issues()` encodes the old metal rule**; `send_routes.sql` carries an updated copy (metal sent as `before`, expectations `1:3 2:0 …`, step 3 `{metal}`, step 4 sends sheet 2). Re-running `ready_issues.sql` puts the old view and check back.
- `check_catch_up`, `check_office`, `check_monday_sync` fail in the sandbox with or without this file (no Monday) — not regressions.

## Results when delivered

| Test | Result |
|---|---|
| `send_routes.sql` twice on a seeded database; `check_send_routes()` | 13/13 PASS each time; nothing left behind |
| Every live check after it (verify_setup 10, check_floor 18, check_ready_issues 14 — updated copy, check_advance 10, check_test_lane 10, check_inventory 16, check_photos 16, check_supply_lists 10, check_loadouts 12, check_deliveries 16, check_deliveries_v2 6) | All PASS |
| With `finish_by.sql` and the updated `pace.sql` | check_finish_by 12/12, check_pace 13/13; Metal paint measured in pieces |
| Go-live on an under-way floor (seed, finished Full Custom and Metal, one metal sheet at Arrow; then the file twice) | 11 *Before send routes* sends (the Arrow one on the Arrow route); Sanding and Assembly Ready identical before/after; second run added none |
| A real change order through `upload_work_order()` (v1 → send sheet 1 to Sanding → Sanding counts 1 → v2 with sheet 1 unchanged, sheet 2 changed) | Upload ok; v2 sheet 1 keeps the send and a Sanding count 1/2 (carried); sheet 2 reset, no send; no warning in the log |
| `breaks_routes.py` — 11 broken versions | Each fails at its own step (the lanes break needed step 11 to also read as the Test Supervisor — added) |
| `test_routes_tablet.js` | 53/53 (four runs) |
| `test_past_tablet.js` (sends seeded first; the finish step now sends) | 49/49 |
| `test_nav_tablet.js` / `test_fb_tablet.js` / `test_inv_tablet.js` on the new index.html | 25/25 · 27/27 (×3) · 19/19 |
| Screens (`snap_routes.js` → `shoot_routes.js`) | Two wording fixes: one sheet says *Send it on*; Metal to paint's heading matches its tab |
| Bugs found and fixed | view read `sheet_send_effects` as the login (→ `send_not_needed()`); Undo allowed after a same-transaction count (→ `events_mark`); a late Sanding answer shown on Finishing after a department switch (→ second `wd()` guard in `loadRows`) |

Not covered: the real SQL Editor, GitHub Pages, a real tablet, the office (`office.html` unchanged: no Metal paint column on the job page; Setup's defect-list editor doesn't list Metal paint).

## Files

#### routes_seed.sql
```sql
-- send-routes cases, on Part 3's seed + past_seed.sql. PROJ-00600: every kind of sheet.
update profiles set departments = '{full_custom,assembly_qc}' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages)
values (16000000009, 'PROJ-00600', 'Cabinet Co', local_today() + 30, 'In Production', true, true, true, '{}');
do $$
declare w uuid; s uuid;
begin
  insert into work_orders (job_id) select id from jobs where project_id = 'PROJ-00600' returning id into w;
  insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at, spec_hash)
    values (w, 1, 2, 'CAB-1', 'Walnut', 'PROJ-00600/v1/sheet-1.png', 'PROJ-00600/v1/sheet-1.pdf', now(), 'a1') returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'full_custom', 2, 1), (s, 'finishing', 2, 0), (s, 'assembly_qc', 2, 0);
  insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at, spec_hash)
    values (w, 2, 1, 'CAB-2', 'Walnut', 'PROJ-00600/v1/sheet-2.png', 'PROJ-00600/v1/sheet-2.pdf', now(), 'a2') returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'full_custom', 1, 1), (s, 'sanding', 1, 0), (s, 'finishing', 1, 0), (s, 'assembly_qc', 1, 0);
  insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at, spec_hash)
    values (w, 3, 1, 'CAB-3', 'Walnut', 'PROJ-00600/v1/sheet-3.png', 'PROJ-00600/v1/sheet-3.pdf', now(), 'a3') returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'milling', 1, 1), (s, 'cnc', 1, 1), (s, 'sanding', 1, 0),
    (s, 'full_custom', 1, 1), (s, 'finishing', 1, 0), (s, 'assembly_qc', 1, 0);
  insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at, spec_hash)
    values (w, 4, 2, 'BASE-4', null, 'PROJ-00600/v1/sheet-4.png', 'PROJ-00600/v1/sheet-4.pdf', now(), 'a4') returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'metal', 2, 2), (s, 'assembly_qc', 2, 0);
  insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at, spec_hash)
    values (w, 5, 1, 'BASE-5', null, 'PROJ-00600/v1/sheet-5.png', 'PROJ-00600/v1/sheet-5.pdf', now(), 'a5') returning id into s;
  insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'metal', 1, 1), (s, 'assembly_qc', 1, 0);
end $$;
```

#### past_seed.sql
```sql
-- Past tab cases, on Part 3's seed. Eric B gets Assembly / QC too, as set_up_logins.sql will give him.
update profiles set departments = '{full_custom,assembly_qc}' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
-- PROJ-00418 (In Production): Full Custom on sheets 1-3, all done, finished 2 days ago
insert into sheet_progress (sheet_id, department, qty_required, qty_done, completed_at)
  select s.id, 'full_custom', s.qty, s.qty, now() - interval '2 days' from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
   where j.project_id = 'PROJ-00418' and s.sheet_number <= 3;
-- PROJ-00099 (In Production): Full Custom 1 of 3 on one sheet -> still on Work orders
insert into sheet_progress (sheet_id, department, qty_required, qty_done)
  select s.id, 'full_custom', 3, 1 from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
   where j.project_id = 'PROJ-00099' and s.sheet_number = 1;
-- three more jobs, all Full Custom done: Delivery (finished 9 days ago), Project Closeout (20 days ago), 100% Complete
insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages) values
 (15000000001,'PROJ-00380','Meridian Office', local_today()-2,'Delivery',false,true,true,'{}'),
 (15000000002,'PROJ-00355','Northside Clinic', local_today()-15,'Project Closeout',false,true,true,'{}'),
 (15000000003,'PROJ-00301','Old Closed Job', local_today()-60,'100% Complete',false,true,true,'{}');
do $$
declare w uuid; s uuid; p text; n int; ago int;
begin
  foreach p in array array['PROJ-00380','PROJ-00355','PROJ-00301'] loop
    insert into work_orders (job_id) select id from jobs where project_id = p returning id into w;
    ago := case p when 'PROJ-00380' then 9 when 'PROJ-00355' then 20 else 50 end;
    for n in 1..2 loop
      insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
        values (w, n, 1, 'CAB-0'||n, 'Walnut', format('%s/v1/sheet-%s.png',p,n), format('%s/v1/sheet-%s.pdf',p,n), now()) returning id into s;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done, completed_at) values
        (s, 'full_custom', 1, 1, now() - make_interval(days => ago)), (s, 'assembly_qc', 1, 1, now() - make_interval(days => ago));
    end loop;
  end loop;
end $$;
```

#### fresh_routes.sh
```bash
#!/bin/bash
# sync_base + Part 3 seed + send_routes.sql (twice, BEFORE the seed, so go-live finds nothing) + past_seed + routes_seed
cd /home/claude/sf/base && ./fresh.sh /home/claude/sf/out/send_routes.sql >/dev/null || exit 1
P="psql -h /tmp/pg -p 5433 -U postgres -d sync -q -v ON_ERROR_STOP=1"
$P -f past_seed.sql >/tmp/pseed.out 2>&1 && $P -f routes_seed.sql >>/tmp/pseed.out 2>&1 || { echo SEED FAILED; cat /tmp/pseed.out; exit 1; }
echo SEEDED
```

#### breaks_routes.py
```python
import subprocess
good = open('/home/claude/sf/out/send_routes.sql').read()
B = {
 "1 paint not Finishing's": [("            or (dept = 'metal_paint' and 'finishing' = any(departments)))", "            )")],
 "2 cabinet doesn't gate": [("               case when fc.present and fc.route is null then 0 else sp.qty_required end,", "               sp.qty_required,")],
 "3 send before done": [("  if v_sp.qty_done < v_sp.qty_required then\n    raise exception 'Finish all", "  if false then\n    raise exception 'Finish all")],
 "4 no count made": [("    if fc.route = 'sanding' then perform send_make_count(p_sheet, 'sanding', v_s.qty, fc.id, 'full_custom'); end if;", "")],
 "5 not-needed skipped": [("    if fc.route = 'finishing' and not v_top then", "    if false then")],
 "6 undo ignores counts": [("       and coalesce(e.source, 'Tablet') in ('Tablet', 'Manager adjustment'));", "       and false);")],
 "7 paint not waited on": [("              when x.route = 'paint' then coalesce(x.paint_done, 0)", "              when x.route = 'paint' then x.metal_done")],
 "8 Arrow not held": [("              when x.at_arrow or x.route is null then 0", "              when x.route is null then 0")],
 "9 Past ignores sends": [("     and bool_and(sp.department not in ('full_custom', 'metal') or cs.route is not null)", "")],
 "10 change orders drop sends": [("create constraint trigger sheet_routes_follow_trg after insert on sheet_progress\n  deferrable initially deferred for each row execute function sheet_routes_follow();", "")],
 "11 lanes mixed": [("  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')))\n  and j.is_test = am_test();\nrevoke all on v_sheet_routes", "  and (j.is_active or (not j.is_test and j.phase in ('Delivery', 'Project Closeout')));\nrevoke all on v_sheet_routes")],
}
P = "psql -h /tmp/pg -p 5433 -U postgres -q"
for name, reps in B.items():
    s = good
    for a, b in reps:
        assert s.count(a) >= 1, (name, a[:50]); s = s.replace(a, b, 1)
    open('/tmp/broken.sql', 'w').write(s)
    subprocess.run(f'{P} -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base"', shell=True, capture_output=True)
    r = subprocess.run(f'{P} -d sync -v ON_ERROR_STOP=1 -At -F"|" -f /tmp/broken.sql', shell=True, capture_output=True, text=True)
    fails = [l.split('|')[0] for l in r.stdout.splitlines() if '|FAIL|' in l]
    print(f"{name:28} -> failed steps {fails}" + (f"  LOAD ERR {r.stderr[-150:]}" if r.returncode else ""))
```

#### test_routes_tablet.js
```javascript
// Send routes on the tablet: the real index.html in jsdom, against the real test database (pgsupa.js), through each login.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const FILE = process.env.APP || "../out/index.html";
const html = fs.readFileSync(FILE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client; return w;
}
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const click = async (w, el, p = 200) => { (typeof el === "string" ? $(w, el) : el).click(); await wait(p); };
const app = (w) => w.document.getElementById("app");
const subtabs = (w) => $$(w, ".subtab").map(b => b.firstChild.textContent.trim());
const card = (w, pid) => $$(w, "button.job").find(b => b.textContent.includes(pid));
const sheetBtn = (w, n) => $$(w, "button.sheet").find(b => b.querySelector(".no").textContent.trim() === String(n));
const dept = (d) => ({ sf_dept: JSON.stringify(d), sf_tab: JSON.stringify("work") });
const J = "PROJ-00600";
const sendOf = async (n, from) => one(`select ss.route, ss.source, ss.undone_at is not null as undone from sheet_sends ss join jobs j on j.id = ss.job_id
  where j.project_id = $1 and ss.sheet_number = $2 and ss.from_dept = $3 order by ss.sent_at desc limit 1`, [J, n, from]);
const count = async (n, d) => one(`select sp.qty_done, sp.qty_required from sheet_progress sp join sheets s on s.id = sp.sheet_id
  join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id where j.project_id = $1 and s.sheet_number = $2 and sp.department = $3`, [J, n, d]);
const openJob = async (w, pid) => { await until(() => card(w, pid)); await click(w, card(w, pid), 250); };

(async () => {
  // ---- core ----
  fs.writeFileSync("/tmp/routes_core.js", [...fs.readFileSync(FILE, "utf8").matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  const C = require("/tmp/routes_core.js");
  ok("core: Finishing's tabs are Work orders · Metal to paint · Tasks · Issues · Supplies", C.tabsFor("finishing").join(",") === "work,paint,tasks,issues,supplies", C.tabsFor("finishing").join(","));
  ok("core: other tabs unchanged (Sanding, Metal, Assembly / QC, Delivery)", C.tabsFor("sanding").join(",") === "work,tasks,issues,supplies" && C.tabsFor("metal").join(",") === "work,arrow,tasks,issues,supplies"
     && C.tabsFor("assembly_qc").join(",") === "work,arrow,qc,tasks,issues,supplies" && C.tabsFor("delivery").join(",") === "loadout,arrow,tasks,issues");
  const rows = [{ sheet_id: "a", department: "full_custom", qty_done: 2, qty_required: 2 }, { sheet_id: "b", department: "full_custom", qty_done: 1, qty_required: 1 },
                { sheet_id: "c", department: "full_custom", qty_done: 0, qty_required: 1 }];
  const withS = C.withSends(rows, [{ sheet_id: "a", fc_route: "sanding", fc_send_id: "x", fc_can_undo: true }, { sheet_id: "b" }, { sheet_id: "c" }], "full_custom");
  ok("core: a sent sheet isn't 'to send'; a finished unsent one is; an unfinished one isn't", !C.toSend(withS[0]) && C.toSend(withS[1]) && !C.toSend(withS[2]));
  const q = C.buildQueue(withS.map(r => ({ ...r, job_id: "j", project_id: "P", job_name: "J" })));
  ok("core: a job stays on Work orders while a finished sheet is still to send", q.length === 1 && q[0].toSend === 1);
  const q2 = C.buildQueue([{ ...withS[0], job_id: "j" }]);
  ok("core: once every finished sheet is sent, the job leaves Work orders", q2.length === 0);
  ok("core: without the routes view the list works as before (nothing to send)", C.buildQueue([{ ...rows[1], job_id: "j" }]).length === 0);
  ok("core: route words", ["sanding", "finishing", "paint", "arrow"].map(C.routeWords).join("|") === "to Sanding|straight to Finishing|to paint|to Arrow");
  ok("core: Metal paint and Full Custom have names for 'Waiting on …'", C.DEPT_NAME.metal_paint === "Metal paint" && C.DEPT_NAME.full_custom === "Full Custom");

  // ---- before any send: Sanding and Finishing don't see the cabinets ----
  let w = boot(users.mike, dept("sanding"));
  await until(() => $$(w, "button.job").length);
  ok("Mike, Sanding, Ready: PROJ-00600 isn't there (its cabinets aren't sent)", !card(w, J));
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]');
  await openJob(w, J);
  ok("...on All, its sheets say 'Waiting on Full Custom'", /Waiting on Full Custom/.test(sheetBtn(w, 2).textContent) && /Waiting on Full Custom/.test(sheetBtn(w, 3).textContent),
     sheetBtn(w, 2) && sheetBtn(w, 2).textContent.replace(/\s+/g, " "));
  w.close();

  // ---- Eric: to send ----
  w = boot(users.eric, dept("full_custom"));
  await until(() => card(w, J));
  ok("Eric's Work orders: the job shows '2 sheets to send'", /2 sheets to send/.test(card(w, J).textContent), card(w, J).textContent.replace(/\s+/g, " "));
  await click(w, card(w, J), 250);
  ok("job page: '2 finished sheets to send on' and Send all", /2 finished sheets to send on/.test($(w, ".sendbar").textContent) && !!$(w, "[data-sendall]"));
  ok("sheets 2 and 3 say To send; sheet 1 (1 of 2) doesn't", /To send/.test(sheetBtn(w, 2).textContent) && /To send/.test(sheetBtn(w, 3).textContent) && !/To send/.test(sheetBtn(w, 1).textContent));
  await click(w, sheetBtn(w, 1), 300);
  ok("an unfinished sheet has no send buttons", !$(w, "[data-send]"));
  await click(w, "[data-all]", 400);
  await until(() => $(w, "[data-send]"));
  ok("Mark all done: the send buttons appear at once — Send to Sanding / Send straight to Finishing",
     $$(w, "[data-send]").map(b => b.textContent.trim()).join(" | ") === "Send to Sanding | Send straight to Finishing");
  await until(async () => (await count(1, "full_custom")).qty_done === 2);
  await click(w, '[data-back="job"]'); await click(w, sheetBtn(w, 2), 300);
  await click(w, '[data-send="finishing"]', 300);
  await until(async () => { const s = await sendOf(2, "full_custom"); return s && !s.undone; });
  let s2 = await sendOf(2, "full_custom");
  ok("Send straight to Finishing (sheet 2): recorded as Eric's, from the tablet", s2.route === "finishing" && s2.source === "Tablet", JSON.stringify(s2));
  const sand2 = await count(2, "sanding");
  ok("...no top on it, so Sanding's count is marked done — Not needed", sand2.qty_done === 1);
  await until(() => $(w, ".sent") && $(w, "[data-unsend]"));
  ok("the sheet says 'Sent straight to Finishing' with an Undo", /Sent straight to Finishing/.test($(w, ".sent").textContent) && !!$(w, "[data-unsend]"), $(w, ".sent") && $(w, ".sent").textContent.replace(/\s+/g, " "));

  // Mike sees Not needed; Jim sees it ready
  let m = boot(users.mike, dept("sanding"));
  await until(() => $$(w, "button.job").length);
  if ($(m, '[data-qmode="all"]')) await click(m, '[data-qmode="all"]');
  await openJob(m, J);
  ok("Mike's Sanding: sheet 2 reads 'Not needed — sent straight to Finishing'", /Not needed/.test(sheetBtn(m, 2).textContent));
  m.close();
  let jim = boot(users.jim, dept("finishing"));
  await until(() => card(jim, J));
  await click(jim, card(jim, J), 250);
  ok("Jim's Finishing, Ready: PROJ-00600 is there, sheet 2 with 1 ready", /1 ready/.test(sheetBtn(jim, 2).textContent), sheetBtn(jim, 2) && sheetBtn(jim, 2).textContent.replace(/\s+/g, " "));
  jim.close();

  // Undo
  await click(w, "[data-unsend]"); await click(w, "[data-confirm]", 400);
  await until(async () => (await sendOf(2, "full_custom")).undone);
  ok("Undo: the send is kept, marked undone; Sanding's count goes back to 0", (await sendOf(2, "full_custom")).undone && (await count(2, "sanding")).qty_done === 0);
  await until(() => $(w, "[data-send]"));
  ok("...and the sheet offers the two sends again", $$(w, "[data-send]").length === 2);

  // Send all
  await click(w, '[data-back="job"]', 250);
  ok("job page: now 3 to send (sheet 1 done too)", /3 finished sheets to send on/.test($(w, ".sendbar").textContent));
  await click(w, "[data-sendall]");
  ok("Send all asks where: Send to Sanding / Send straight to Finishing", $$(w, "[data-sendallroute]").map(b => b.querySelector("b").textContent).join(" | ") === "Send to Sanding | Send straight to Finishing");
  await click(w, '[data-sendallroute="sanding"]', 600);
  await until(async () => (await one("select count(*)::int n from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = $1 and ss.from_dept = 'full_custom' and ss.route = 'sanding' and undone_at is null", [J])).n === 3);
  ok("all three sheets sent to Sanding", true);
  const s1 = await count(1, "sanding");
  ok("sheet 1 had no Sanding count on the work order: the send made one (0 of 2)", s1 && s1.qty_done === 0 && s1.qty_required === 2, JSON.stringify(s1));
  await click(w, '[data-back="queue"]', 500);
  await until(() => !card(w, J));
  ok("the job leaves Eric's Work orders", !card(w, J));
  await click(w, '[data-tab="past"]', 400);
  await until(() => card(w, J));
  ok("...and is on Past", !!card(w, J));
  await click(w, card(w, J), 250);
  ok("on Past, each sheet says 'Sent to Sanding'", $$(w, "button.sheet").every(b => /Sent to Sanding/.test(b.textContent)) && $$(w, "button.sheet").length === 3);
  await click(w, sheetBtn(w, 3), 300);
  ok("a Past sheet shows where it went and can still be undone", /Sent to Sanding/.test($(w, ".sent").textContent) && !!$(w, "[data-unsend]"));
  w.close();

  m = boot(users.mike, dept("sanding"));
  await until(() => card(m, J));
  await click(m, card(m, J), 250);
  ok("Mike's Sanding, Ready: the job is there — sheet 1: 2 ready, 2: 1 ready, 3: 1 ready",
     /2 ready/.test(sheetBtn(m, 1).textContent) && /1 ready/.test(sheetBtn(m, 2).textContent) && /1 ready/.test(sheetBtn(m, 3).textContent));
  await click(m, sheetBtn(m, 3), 300); await click(m, '[data-step="1"]', 400);
  await until(async () => (await count(3, "sanding")).qty_done === 1);
  m.close();
  w = boot(users.eric, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("past") });
  await until(() => card(w, J)); await click(w, card(w, J), 250); await click(w, sheetBtn(w, 3), 300);
  ok("once Sanding counts sheet 3, Eric's Undo is gone", /Sent to Sanding/.test($(w, ".sent").textContent) && !$(w, "[data-unsend]"));
  w.close();

  // ---- Willie: paint and Arrow ----
  w = boot(users.willie, dept("metal"));
  await until(() => card(w, J));
  ok("Willie's Work orders: '2 sheets to send'", /2 sheets to send/.test(card(w, J).textContent));
  await click(w, card(w, J), 250); await click(w, sheetBtn(w, 4), 300);
  ok("Metal's buttons: Send to paint / Send to Arrow", $$(w, "[data-send]").map(b => b.textContent.trim()).join(" | ") === "Send to paint | Send to Arrow");
  await click(w, '[data-send="paint"]', 400);
  await until(async () => (await sendOf(4, "metal")) && (await count(4, "metal_paint")));
  ok("Send to paint: a Metal paint count of 2 is made", (await count(4, "metal_paint")).qty_required === 2);
  await click(w, '[data-back="job"]'); await click(w, sheetBtn(w, 5), 300);
  await click(w, '[data-send="arrow"]', 400);
  await until(async () => (await sendOf(5, "metal")));
  const arrow = await one("select o.service, o.sheet_numbers, o.returned_on from outside_jobs o join sheet_sends ss on ss.outside_job_id = o.id join jobs j on j.id = ss.job_id where j.project_id = $1", [J]);
  ok("Send to Arrow: an Arrow item is made — powdercoat, sheet 5", arrow && arrow.service === "powdercoat" && String(arrow.sheet_numbers) === "5");
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 400);
  await click(w, '[data-tab="arrow"]', 500);
  await until(() => /PROJ-00600/.test(app(w).textContent));
  ok("...and it's on Willie's Arrow tab", /PROJ-00600/.test(app(w).textContent));
  w.close();

  // ---- Jim: Metal to paint ----
  jim = boot(users.jim, dept("finishing"));
  await until(() => subtabs(jim).length);
  ok("Jim's tabs: Work orders · Metal to paint · Tasks · Issues · Supplies", subtabs(jim).join(",") === "Work orders,Metal to paint,Tasks,Issues,Supplies", subtabs(jim).join(","));
  await click(jim, '[data-tab="paint"]', 500);
  await until(() => card(jim, J));
  ok("Metal to paint: PROJ-00600 is there, headed Metal to paint", !!card(jim, J) && /Metal to paint/.test($(jim, "h1").textContent));
  await click(jim, card(jim, J), 250);
  ok("...only the sheet sent to paint (sheet 4), with 2 ready", $$(jim, "button.sheet").length === 1 && /2 ready/.test(sheetBtn(jim, 4).textContent));
  await click(jim, sheetBtn(jim, 4), 300);
  ok("its counter is Metal paint's", /Metal paint/.test($(jim, ".readout").textContent));
  await click(jim, '[data-report="here"]'); await click(jim, '[data-reportkind="defect"]');
  ok("a defect from here uses Metal paint's list", $$(jim, "[data-picktype]").some(b => /Needs repaint/.test(b.textContent)) && /Metal paint/.test($(jim, ".mdl").textContent));
  await click(jim, $$(jim, "[data-picktype]").find(b => /Needs repaint/.test(b.textContent)));
  await click(jim, "[data-savedefect]", 500);
  await until(async () => (await one("select count(*)::int n from defects d join jobs j on j.id = d.job_id where j.project_id = $1 and d.department = 'metal_paint'", [J])).n === 1);
  ok("...and is saved under Metal paint", true);
  await click(jim, "[data-all]", 400);
  await until(async () => (await count(4, "metal_paint")).qty_done === 2);
  ok("Mark all done counts Metal paint (2 of 2)", true);
  await click(jim, '[data-back="job"]'); await click(jim, '[data-back="queue"]', 400);
  await click(jim, '[data-tab="work"]', 500);
  await until(() => $$(jim, "button.job").length);
  ok("back on Work orders, Jim's own Finishing list is back", /Finishing/.test($(jim, "h1").textContent));
  jim.close();

  // ---- KP: Assembly / QC ----
  let kp = boot(users.kp, dept("assembly_qc"));
  await until(() => $$(kp, "button.job").length);
  if ($(kp, '[data-qmode="all"]')) await click(kp, '[data-qmode="all"]');
  await openJob(kp, J);
  ok("KP: sheet 4 (painted) is ready; sheet 5 says At Arrow", /2 ready/.test(sheetBtn(kp, 4).textContent) && /At Arrow/.test(sheetBtn(kp, 5).textContent),
     [4, 5].map(n => sheetBtn(kp, n).textContent.replace(/\s+/g, " ")).join(" | "));
  kp.close();
  await admin.query("update outside_jobs set returned_on = local_today(), returned_by_name = 'KP' where id = (select ss.outside_job_id from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = $1 and ss.route = 'arrow')", [J]);
  kp = boot(users.kp, dept("assembly_qc"));
  await until(() => $$(kp, "button.job").length);
  if ($(kp, '[data-qmode="all"]')) await click(kp, '[data-qmode="all"]');
  await openJob(kp, J);
  ok("back from Arrow: sheet 5 is ready for Assembly / QC", /1 ready/.test(sheetBtn(kp, 5).textContent), sheetBtn(kp, 5).textContent.replace(/\s+/g, " "));
  kp.close();

  // ---- offline: a send waits on the tablet ----
  await admin.query("update sheet_progress sp set qty_done = 0 from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id where sp.sheet_id = s.id and j.project_id = 'PROJ-00099' and sp.department = 'full_custom'").catch(() => {});
  await admin.query(`insert into sheet_progress (sheet_id, department, qty_required, qty_done) select s.id, 'full_custom', 1, 1 from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
    join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00099' and s.sheet_number = 2 on conflict (sheet_id, department) do update set qty_done = excluded.qty_done, qty_required = 1`);
  w = boot(users.eric, dept("full_custom"));
  await until(() => card(w, "PROJ-00099"));
  await click(w, card(w, "PROJ-00099"), 250); await click(w, sheetBtn(w, 2), 300);
  setOffline(true);
  await click(w, '[data-send="finishing"]', 500);
  ok("offline: the sheet shows as sent, 'waiting to send'", /waiting to send/.test($(w, ".sent").textContent));
  ok("...nothing reached the database yet", !(await one("select 1 x from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = 'PROJ-00099'")));
  setOffline(false);
  w.dispatchEvent(new w.Event("online"));
  await until(async () => !!(await one("select 1 x from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = 'PROJ-00099' and route = 'finishing'")), 6000);
  ok("back online: it sends by itself", !!(await one("select 1 x from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = 'PROJ-00099' and route = 'finishing'")));
  await until(() => $(w, ".sent") && !/waiting to send/.test($(w, ".sent").textContent), 4000);
  ok("...and the tablet then shows it as sent, no longer waiting", !/waiting to send/.test($(w, ".sent").textContent));
  await wait(500); w.close();

  // ---- the database says no ----
  const c = makeClient(users.mike);
  const r = await c.rpc("send_sheet", { p_sheet: (await one("select s.id from sheets s join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00099' and s.sheet_number = 2")).id, p_from: "full_custom", p_route: "sanding", p_client_id: null });
  ok("Mike (no Full Custom) can't send a Full Custom sheet, through the same login path", !!r.error && /can't make entries for Full Custom/.test(r.error.message), r.error && r.error.message);

  // ---- without send_routes.sql's routes view, sheets work as before ----
  await admin.query("drop view v_sheet_routes cascade");
  w = boot(users.eric, dept("full_custom"));
  await until(() => $$(w, "button.job").length || /Nothing waiting/.test(app(w).textContent));
  ok("routes view missing: no send buttons, no errors, the list as before", !$(w, "[data-sendall]") && !/to send/.test(app(w).textContent) && !$(w, ".banner.warn"));
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_past_tablet.js
```javascript
// Past tab and the sign-in zoom lock: the real index.html in jsdom, against the real test database (pgsupa.js), through each login.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const FILE = process.env.APP || "../out/index.html";
const html = fs.readFileSync(FILE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, preload = {}, client) {
  client = client || makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => { w.printed = (w.printed || 0) + 1; };
  w.open = (u) => { w.opened = u; }; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client; w.dom = dom; return w;
}
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const click = async (w, el, p = 150) => { (typeof el === "string" ? $(w, el) : el).click(); await wait(p); };
const app = (w) => w.document.getElementById("app");
const subtabs = (w) => $$(w, ".subtab").map(b => b.firstChild.textContent.trim());
const cards = (w) => $$(w, "button.job").map(b => (b.textContent.match(/PROJ-\d+/) || [""])[0]);
const card = (w, pid) => $$(w, "button.job").find(b => b.textContent.includes(pid));
const vp = (w) => w.document.querySelector('meta[name="viewport"]').getAttribute("content");
const ORIGINAL_VP = "width=device-width, initial-scale=1, viewport-fit=cover";

const SEND_ALL = `insert into sheet_sends (job_id, sheet_id, sheet_number, spec_hash, from_dept, route, is_test, source, sent_by_name, sent_at)
  select w.job_id, s.id, s.sheet_number, s.spec_hash, 'full_custom', 'finishing', j.is_test, 'Tablet', 'Eric B', sp.completed_at
    from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id
   where sp.department = 'full_custom' and sp.qty_done >= sp.qty_required
     and not exists (select 1 from sheet_sends x where x.sheet_id = s.id and x.from_dept = 'full_custom')`;
(async () => {
  await admin.query(SEND_ALL);          // send routes: Eric has sent every finished sheet on
  // ---- core ----
  fs.writeFileSync("/tmp/past_core.js", [...fs.readFileSync(FILE, "utf8").matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  const C = require("/tmp/past_core.js");
  ok("core: Full Custom's tabs are Work orders · Past · Tasks · Issues · Supplies", C.tabsFor("full_custom").join(",") === "work,past,tasks,issues,supplies", C.tabsFor("full_custom").join(","));
  ok("core: no other department gets Past", ["milling", "cnc", "sanding", "finishing", "metal", "assembly_qc", "delivery"].every(d => !C.tabsFor(d).includes("past")));
  ok("core: other departments' tabs unchanged", C.tabsFor("assembly_qc").join(",") === "work,arrow,qc,tasks,issues,supplies" && C.tabsFor("delivery").join(",") === "loadout,arrow,tasks,issues");
  const bp = C.buildPast([
    { job_id: "a", project_id: "PROJ-1", job_name: "A", phase: "Delivery", done_at: "2026-09-20T15:00:00Z", qty_required: 2 },
    { job_id: "b", project_id: "PROJ-2", job_name: "B", phase: "In Production", done_at: "2026-09-26T15:00:00Z", qty_required: 1 },
    { job_id: "a", project_id: "PROJ-1", job_name: "A", phase: "Delivery", done_at: "2026-09-22T15:00:00Z", qty_required: 1 }]);
  ok("core: one entry per job, most recently finished first", bp.map(j => j.project_id).join(",") === "PROJ-2,PROJ-1" && bp[1].sheets === 2 && bp[1].pieces === 3);
  ok("core: a job's finish date is its latest sheet's", bp[1].done_at === "2026-09-22T15:00:00Z");
  ok("core: the line reads Done Sep 22 · 2 sheets · Monday: Delivery", C.pastLine(bp[1]) === "Done Sep 22 · 2 sheets · Monday: Delivery", C.pastLine(bp[1]));
  ok("core: one sheet, no phase", C.pastLine({ done_at: "2026-09-22T15:00:00Z", sheets: 1 }) === "Done Sep 22 · 1 sheet");

  // ---- sign-in: zoom locked, then back ----
  let w = boot(null);
  await until(() => $(w, "#f"));
  ok("sign-in screen: zoom is off (the page asks for no zooming)", /maximum-scale=1/.test(vp(w)) && /user-scalable=no/.test(vp(w)) && w.document.documentElement.classList.contains("nozoom"), vp(w));
  ok("...and still fits the screen edge to edge as before", vp(w).startsWith("width=device-width, initial-scale=1") && /viewport-fit=cover/.test(vp(w)));
  $(w, "#e").value = "eric@pdindy.com"; $(w, "#p").value = "wrong";
  $(w, "#f").dispatchEvent(new w.Event("submit", { cancelable: true })); await until(() => !$(w, "#err").hidden);
  ok("a wrong password: still on sign-in, zoom still off", !!$(w, "#f") && /user-scalable=no/.test(vp(w)));
  $(w, "#p").value = "right";
  $(w, "#f").dispatchEvent(new w.Event("submit", { cancelable: true }));
  await until(() => $$(w, "header .tab").length);
  ok("signed in: zoom works again, the page's setting exactly as it was", vp(w) === ORIGINAL_VP && !w.document.documentElement.classList.contains("nozoom"), vp(w));
  ok("Eric has two department tabs: Full Custom and Assembly / QC", $$(w, "header .tab").map(b => b.textContent.trim()).join(",") === "Full Custom,Assembly / QC", $$(w, "header .tab").map(b => b.textContent.trim()).join(","));
  await until(() => subtabs(w).length);
  ok("Full Custom's tabs: Work orders · Past · Tasks · Issues · Supplies", subtabs(w).join(",") === "Work orders,Past,Tasks,Issues,Supplies", subtabs(w).join(","));
  await until(() => card(w, "PROJ-00099"));
  ok("Work orders: the unfinished job is there; the finished one (PROJ-00418) isn't", !!card(w, "PROJ-00099") && !card(w, "PROJ-00418"), cards(w).join(","));

  // ---- the Past list ----
  await click(w, '[data-tab="past"]', 300);
  await until(() => cards(w).length >= 3);
  ok("Past: finished jobs, most recently finished first — In Production, Delivery, Project Closeout", cards(w).join(",") === "PROJ-00418,PROJ-00380,PROJ-00355", cards(w).join(","));
  ok("Past: a 100% Complete job isn't there, nor an unfinished one", !card(w, "PROJ-00301") && !card(w, "PROJ-00099"));
  const d2 = (await one("select to_char(now() - interval '2 days', 'Mon FMDD') d")).d, d9 = (await one("select to_char(now() - interval '9 days', 'Mon FMDD') d")).d;
  const line = (pid) => card(w, pid).querySelector(".pastline").textContent;
  ok("each card says when, how many sheets, and Monday's phase", line("PROJ-00418") === `Done ${d2} · 3 sheets · Monday: In Production` && line("PROJ-00380") === `Done ${d9} · 2 sheets · Monday: Delivery`, line("PROJ-00418") + " | " + line("PROJ-00380"));
  ok("each card has the turquoise Done mark; no other colour", card(w, "PROJ-00380").querySelector(".donechip").textContent === "Done" && !card(w, "PROJ-00380").className.includes("f-"));
  ok("no work order content on the card (no species, sizes or item codes)", !/Walnut|CAB-0/.test(card(w, "PROJ-00380").textContent));
  ok("Sign out is at the bottom of the Past list, as on Work orders", !!$(w, "[data-signout]"));

  // ---- a job in Delivery, read only ----
  await click(w, card(w, "PROJ-00380"), 200);
  ok("its page lists its sheets, each complete", $$(w, "button.sheet").length === 2 && $$(w, "button.sheet.done").length === 2 && $(w, ".back").textContent.includes("Past"));
  ok("no counting on a Past job page", !$(w, "[data-step]") && !$(w, "[data-all]"));
  ok("no Sign out while inside a job", !$(w, "[data-signout]"));
  await click(w, $$(w, "button.sheet")[0], 300);
  await until(() => $(w, "#page img"));
  ok("a sheet opens with its page image", !!$(w, "#page img") && $(w, "h1").textContent.includes("Sheet 1"));
  ok("read only: no − / + / Mark all done, and it says so", !$(w, "[data-step]") && !$(w, "[data-all]") && /can't be changed here/.test(app(w).textContent) && /Sheet complete/.test($(w, ".complete").textContent));
  await click(w, "[data-pdf]", 200);
  ok("Open the PDF works", /signed\.pdf/.test(w.opened || ""), w.opened);
  await click(w, "[data-print]"); ok("Print this sheet works", w.printed === 1);
  await click(w, $$(w, "[data-goto]").find(b => !b.disabled && /Sheet 2/.test(b.textContent)), 300);
  ok("the pager goes to sheet 2", $(w, "h1").textContent.includes("Sheet 2"));
  // report a defect on a job that's in Delivery
  const nDef = (await one("select count(*)::int n from defects d join jobs j on j.id = d.job_id where j.project_id = 'PROJ-00380'")).n;
  await click(w, '[data-report="here"]');
  ok("Report a defect or issue opens, for this job and sheet", /PROJ-00380 · sheet 2 · Full Custom/.test($(w, ".mdl").textContent), $(w, ".mdl") && $(w, ".mdl").textContent.slice(0, 120));
  await click(w, '[data-reportkind="defect"]');
  await click(w, $$(w, "[data-picktype]")[0]);
  await click(w, "[data-savedefect]", 600);
  await until(async () => (await one("select count(*)::int n from defects d join jobs j on j.id = d.job_id where j.project_id = 'PROJ-00380'")).n > nDef);
  const def = await one("select d.department, d.sheet_number, p.full_name from defects d join jobs j on j.id = d.job_id join profiles p on p.id = d.logged_by where j.project_id = 'PROJ-00380' order by d.logged_at desc limit 1").catch(e => ({ err: e.message }));
  ok("a defect on a Past job (in Delivery) is saved: Full Custom, sheet 2, by Eric", def && def.department === "full_custom" && def.sheet_number === 2 && def.full_name === "Eric B", JSON.stringify(def));
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 300);
  ok("back to the Past list", cards(w).join(",") === "PROJ-00418,PROJ-00380,PROJ-00355");

  // ---- the database refuses a count change on a Past job? No: counts are Work orders' job. The page offers none. ----
  // ---- Assembly / QC for Eric ----
  await click(w, $$(w, "header .tab").find(b => /Assembly/.test(b.textContent)), 400);
  ok("Eric's Assembly / QC tab: Assembly's own tabs, no Past", subtabs(w).join(",") === "Work orders,Arrow,QC,Tasks,Issues,Supplies", subtabs(w).join(","));
  ok("...and it opens on Work orders", $$(w, ".subtab").find(b => b.getAttribute("aria-current") === "true").textContent.startsWith("Work orders"));
  await until(() => cards(w).length);
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00418"));
  ok("Assembly's Work orders shows Assembly's jobs", !!card(w, "PROJ-00418"), cards(w).join(","));
  await click(w, $$(w, "header .tab").find(b => /Full Custom/.test(b.textContent)), 400);
  await click(w, '[data-tab="past"]', 300);
  await until(() => cards(w).length >= 3);
  ok("back on Full Custom's Past, the list is there again", cards(w).join(",") === "PROJ-00418,PROJ-00380,PROJ-00355", cards(w).join(","));
  w.close();

  // ---- remembered: the tablet reopens on Past, straight from its saved list, even offline ----
  const saved = {};
  w = boot(users.eric, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("past") });
  await until(() => cards(w).length >= 3);
  ok("the app reopens on Past when that's where it was left", $$(w, ".subtab").find(b => b.getAttribute("aria-current") === "true").textContent.startsWith("Past") && cards(w).length === 3, cards(w).join(","));
  const store = Object.fromEntries(Object.keys(w.localStorage).map(k => [k, w.localStorage.getItem(k)]));
  w.close();
  setOffline(true);
  w = boot(users.eric, store);
  await until(() => cards(w).length >= 3, 3000);
  ok("offline: Past shows the list saved on this tablet", cards(w).join(",") === "PROJ-00418,PROJ-00380,PROJ-00355", cards(w).join(","));
  await click(w, card(w, "PROJ-00355"), 200);
  ok("offline: a Past job still opens", $$(w, "button.sheet").length === 2);
  w.close();
  setOffline(false);

  // ---- finishing a job on Work orders moves it to Past ----
  w = boot(users.eric, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("work") });
  await until(() => card(w, "PROJ-00099"));
  await click(w, card(w, "PROJ-00099"), 200);
  await click(w, $$(w, "button.sheet")[0], 300);
  await click(w, "[data-all]", 300);
  await until(async () => (await one("select sp.qty_done from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders wo on wo.id = s.work_order_id join jobs j on j.id = wo.job_id where j.project_id='PROJ-00099' and sp.department='full_custom'")).qty_done === 3);
  await until(() => $(w, '[data-send="finishing"]'));
  await click(w, '[data-send="finishing"]', 400);
  await until(async () => !!(await one("select 1 x from sheet_sends ss join jobs j on j.id = ss.job_id where j.project_id = 'PROJ-00099'")));
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 400);
  ok("marked all done and sent on: the job leaves Work orders", !card(w, "PROJ-00099"), cards(w).join(","));
  await click(w, '[data-tab="past"]', 400);
  await until(() => card(w, "PROJ-00099"));
  ok("...and is first on Past", cards(w)[0] === "PROJ-00099", cards(w).join(","));
  // Monday says 100% Complete: it leaves Past at the next refresh
  await admin.query("update jobs set phase = '100% Complete', is_active = false where project_id = 'PROJ-00380'");
  await click(w, '[data-tab="past"]', 400);
  await until(() => !card(w, "PROJ-00380"));
  ok("once Monday says 100% Complete, the job leaves Past", !card(w, "PROJ-00380") && !!card(w, "PROJ-00355"), cards(w).join(","));
  w.close();

  // ---- other logins ----
  w = boot(users.mike);
  await until(() => subtabs(w).length);
  ok("Mike (Sanding + Finishing): no Past tab", !subtabs(w).includes("Past"), subtabs(w).join(","));
  await click(w, $$(w, "header .tab").find(b => /Finishing/.test(b.textContent)), 300);
  ok("...on Finishing either", !subtabs(w).includes("Past"));
  w.close();
  w = boot(users.kp);
  await until(() => subtabs(w).length);
  ok("KP (Assembly / QC): tabs unchanged", subtabs(w).join(",") === "Work orders,Arrow,QC,Tasks,Issues,Supplies", subtabs(w).join(","));
  w.close();

  // Test Supervisor: a finished test job, and no real ones
  const tj = await one("select id from jobs where is_test limit 1");
  await admin.query("insert into sheet_progress (sheet_id, department, qty_required, qty_done) select s.id, 'full_custom', 1, 1 from sheets s join work_orders wo on wo.id = s.work_order_id where wo.job_id = $1 and wo.is_current and s.sheet_number = 1 on conflict do nothing", [tj.id]);
  await admin.query(SEND_ALL);
  w = boot(users.test, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("past") });
  await until(() => $$(w, "button.job").length);
  ok("Test Supervisor on Full Custom's Past: only the test job, labelled TEST", $$(w, "button.job").length === 1 && /TEST/.test($$(w, "button.job")[0].textContent), $$(w, "button.job").map(b => b.textContent.replace(/\s+/g, " ").trim()).join(" | "));
  w.close();
  w = boot(users.eric, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("past") });
  await until(() => cards(w).length);
  ok("Eric never sees the test job", !$$(w, "button.job").some(b => /TEST/.test(b.textContent)));
  // sign out: back to sign-in, zoom off again
  await click(w, "[data-signout]", 300);
  await until(() => $(w, "#f"));
  ok("after Sign out, the sign-in screen has zoom off again", /user-scalable=no/.test(vp(w)) && w.document.documentElement.classList.contains("nozoom"));
  w.close();

  // ---- the database without past_work.sql: the tab says so, the rest carries on ----
  await admin.query("drop view v_past_work");
  w = boot(users.eric, { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("past") });
  await until(() => /isn't set up in the database yet/.test(app(w).textContent));
  ok("without past_work.sql: Past says it isn't set up yet", /isn't set up in the database yet/.test(app(w).textContent) && !/Nothing here yet/.test(app(w).textContent));
  await click(w, '[data-tab="work"]', 400);
  await until(() => $$(w, "button.job").length || /Nothing waiting/.test(app(w).textContent));
  ok("...and Work orders works as before", !/isn't set up/.test(app(w).textContent));
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### snap_routes.js
```javascript
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync("../out/index.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
function boot(user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const PAGE = "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1100" height="850"><rect width="1100" height="850" fill="#fff"/><rect x="40" y="40" width="1020" height="60" fill="#ddd"/><text x="60" y="80" font-size="28" font-family="sans-serif" fill="#555">Work order page (stand-in)</text></svg>');
const save = (w, name) => { const d = w.document.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
  d.querySelectorAll("img").forEach(i => { if (/^blob:/.test(i.getAttribute("src"))) i.setAttribute("src", PAGE); });
  fs.writeFileSync(`/tmp/snap_${name}.html`, "<!DOCTYPE html>" + d.documentElement.outerHTML); };
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const card = (w, pid) => $$(w, "button.job").find(b => b.textContent.includes(pid));
const sheet = (w, n) => $$(w, "button.sheet").find(b => b.querySelector(".no").textContent.trim() === String(n));
(async () => {
  let w = boot(users.eric, { sf_dept: '"full_custom"', sf_tab: '"work"' }); await wait(1500);
  save(w, "r_queue");
  card(w, "PROJ-00600").click(); await wait(300); save(w, "r_job");
  sheet(w, 2).click(); await wait(800); save(w, "r_sheet");
  w.document.querySelector('[data-send="finishing"]').click(); await wait(1500); save(w, "r_sent");
  w.document.querySelector('[data-back="job"]').click(); await wait(300);
  w.document.querySelector("[data-sendall]").click(); await wait(300); save(w, "r_sendall");
  w.close();
  w = boot(users.willie, { sf_dept: '"metal"', sf_tab: '"work"' }); await wait(1500);
  card(w, "PROJ-00600").click(); await wait(300); sheet(w, 4).click(); await wait(800);
  w.document.querySelector('[data-send="paint"]').click(); await wait(1500); w.close();
  w = boot(users.jim, { sf_dept: '"finishing"', sf_tab: '"paint"' }); await wait(1800); save(w, "r_paint");
  w.close();
  w = boot(users.mike, { sf_dept: '"sanding"', sf_tab: '"work"' }); await wait(1500);
  const all = w.document.querySelector('[data-qmode="all"]'); if (all) { all.click(); await wait(300); }
  card(w, "PROJ-00600").click(); await wait(400); save(w, "r_sanding");
  w.close(); await admin.end(); process.exit(0);
})();
```

#### shoot_routes.js
```javascript
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [name, W, H] of [["r_queue", 1280, 800], ["r_job", 1280, 800], ["r_sheet", 800, 1280], ["r_sent", 800, 1280], ["r_sendall", 1280, 800], ["r_paint", 1280, 800], ["r_sanding", 1280, 800]]) {
    const p = await b.newPage({ viewport: { width: W, height: H } });
    await p.goto("file:///tmp/snap_" + name + ".html"); await p.waitForTimeout(300);
    await p.screenshot({ path: `/tmp/shot_${name}.png` }); await p.close();
  }
  await b.close();
})();
```
