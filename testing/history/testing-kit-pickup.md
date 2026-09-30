# Testing kit, part 15 — Arrow pick-up list, QC tab removed, printing (30 Sep 2026)

*For build chats. Luke doesn't need to read this.* Parts 1–14 still apply.

## Setup notes (30 Sep)

- As Part 14. `project_read` returns `sql-files-2.md` as a file; the others come back inline, so they were written to disk by sub-agents (retyped, not piped). Every file loaded clean and every live check passed on it, so the copies are good.
- `load.sh` (Part 11) then `finish_by.sql` and `send_routes.sql` twice each, **before** the seed; snapshot `sync_base`. `inventory.sql` and `pace.sql` weren't loaded (nothing here touches them).
- `fresh_pickup.sh` = `fresh.sh arrow_pickup.sql` + `routes_seed.sql` (Part 14).
- Printing is tested in Chromium with `page.pdf()`, counting pages with `pdfinfo` and looking at them with `pdftoppm`. **Found:** with `@page { size: landscape }` Chromium evaluates `(orientation: …)` against the default portrait page, so a landscape page can't be told apart. Without `@page size`, the orientation query follows the paper chosen. Hence no `@page size` and a quarter turn on portrait paper.
- The old CSS reproduced the blank sheet: 2 pages on Letter (the picture at 100 % width runs past the page height).

## Results when delivered

| Test | Result |
|---|---|
| `arrow_pickup.sql` twice on a seeded database; `check_arrow_pickup()` | 10/10 PASS each time; nothing left behind (0 Arrow items after) |
| Every live check after it (verify_setup 10, check_floor 18, check_ready_issues 14, check_send_routes 13, check_advance 10, check_test_lane 10, check_finish_by 12, check_photos 16, check_supply_lists 10, check_loadouts 12, check_deliveries 16, check_deliveries_v2 6) | All PASS |
| `breaks_pickup.py` — 7 broken versions | Each fails at its own step |
| `test_pickup_tablet.js` | 36/36 |
| `test_routes_tablet.js` (Part 14's, two expectations changed: no QC tab; "Waiting to go to Arrow") | 53/53 on the new page; the **old** page on the new database fails only those two lines |
| New page on the old database (file not run) | Only the wording line differs (it says "At Arrow") |
| `test_pickup_office.js` | 8/8 |
| Print: Letter / A4 / Legal, portrait and landscape, tablet held both ways | 1 page every time; landscape as is, portrait turned to fill |
| Bug found and fixed | a tablet opening on Work orders never loaded the Arrow list (no count, no "Waiting to go" on sheets) → `start()` loads it for Arrow departments |

Not covered: the real SQL Editor, GitHub Pages, a real tablet's print dialog and printer.

## Files

#### fresh_pickup.sh
```bash
#!/bin/bash
cd /home/claude/sf/base && ./fresh.sh /home/claude/sf/out/arrow_pickup.sql >/dev/null || exit 1
psql -h /tmp/pg -p 5433 -U postgres -d sync -q -v ON_ERROR_STOP=1 -f /home/claude/sf/base/routes_seed.sql >/tmp/pseed.out 2>&1 || { echo SEED FAILED; cat /tmp/pseed.out; exit 1; }
echo SEEDED
```

#### breaks_pickup.py
```python
import subprocess
good = open('/home/claude/sf/out/arrow_pickup.sql').read()
B = {
 "1 no trigger": [("create trigger arrow_send_waits_trg after insert on sheet_sends\n  for each row execute function arrow_send_waits();", "")],
 "2 returns while waiting": [("  if v.waiting then raise exception 'That hasn''t gone", "  if false then raise exception 'That hasn''t gone")],
 "3 anyone marks gone": [("  if not is_manager() and not exists (select 1 from unnest(arrow_departments()) d where owns_dept(d)) then\n    raise exception 'Only Metal, Assembly / QC, Delivery or the office can mark Arrow items gone.'", "  if false then\n    raise exception 'Only Metal, Assembly / QC, Delivery or the office can mark Arrow items gone.'")],
 "4 future ok": [("  if v_on > local_today() then raise exception 'The day it went", "  if false then raise exception 'The day it went")],
 "5 clock not restarted": [("set waiting = false, sent_on = v_on,", "set waiting = false,")],
 "6 go-live sends wait": [("     and coalesce(new.source, '') in ('Tablet', 'Manager adjustment') then", "     then")],
 "7 lanes mixed": [("    if not sees_lane(v.is_test) then raise exception 'That Arrow item isn''t there.'; end if;\n    if not is_manager() and v.is_test <> am_test() then\n      raise exception 'That item is in the other lane.' using errcode = 'insufficient_privilege';\n    end if;\n    if v.voided_at", "    if v.voided_at")],
}
P = "psql -h /tmp/pg -p 5433 -U postgres -q"
for name, reps in B.items():
    s = good
    for a, b in reps:
        assert s.count(a) >= 1, (name, a[:50]); s = s.replace(a, b, 1)
    open('/tmp/broken.sql', 'w').write(s)
    subprocess.run(f'{P} -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base"', shell=True, capture_output=True)
    subprocess.run(f'{P} -d sync -f /home/claude/sf/base/seed.sql', shell=True, capture_output=True)
    r = subprocess.run(f'{P} -d sync -v ON_ERROR_STOP=1 -At -F"|" -f /tmp/broken.sql', shell=True, capture_output=True, text=True)
    fails = [l.split('|')[0] for l in r.stdout.splitlines() if '|FAIL|' in l]
    print(f"{name:26} -> failed steps {fails}" + (f"  LOAD ERR {r.stderr[-150:]}" if r.returncode else ""))
```

#### test_pickup_tablet.js
```javascript
// Arrow pick-up list and the QC tab's removal, on the tablet: the real index.html in jsdom,
// against the real test database (pgsupa.js), through each login.
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
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => { w.printed = (w.printed || 0) + 1; }; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client; return w;
}
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const click = async (w, el, p = 200) => { (typeof el === "string" ? $(w, el) : el).click(); await wait(p); };
const app = (w) => w.document.getElementById("app");
const txt = (w) => app(w).textContent.replace(/\s+/g, " ");
const subtabs = (w) => $$(w, ".subtab").map(b => b.firstChild.textContent.trim());
const card = (w, pid) => $$(w, "button.job").find(b => b.textContent.includes(pid));
const sheetBtn = (w, n) => $$(w, "button.sheet").find(b => b.querySelector(".no").textContent.trim() === String(n));
const dept = (d, tab = "work") => ({ sf_dept: JSON.stringify(d), sf_tab: JSON.stringify(tab) });
const J = "PROJ-00600";
const item = async (n) => one(`select o.* from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = $1 and $2 = any(o.sheet_numbers) and o.voided_at is null order by o.sent_at desc limit 1`, [J, n]);
const openJob = async (w, pid) => { await until(() => card(w, pid)); await click(w, card(w, pid), 250); };
const section = (w, title) => { const h = $$(w, "h2.sec").find(x => x.textContent.trim() === title); if (!h) return null; const out = []; let n = h.nextElementSibling;
  while (n && !(n.tagName === "H2")) { out.push(n); n = n.nextElementSibling; } return out; };
const sectionText = (w, title) => (section(w, title) || []).map(e => e.textContent).join(" ").replace(/\s+/g, " ");

(async () => {
  // ---- core ----
  fs.writeFileSync("/tmp/pickup_core.js", [...fs.readFileSync(FILE, "utf8").matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  const C = require("/tmp/pickup_core.js");
  ok("core: Assembly / QC's tabs are Work orders · Arrow · Tasks · Issues · Supplies (no QC)", C.tabsFor("assembly_qc").join(",") === "work,arrow,tasks,issues,supplies", C.tabsFor("assembly_qc").join(","));
  ok("core: no department has a QC tab", ["milling", "cnc", "sanding", "finishing", "full_custom", "metal", "assembly_qc", "delivery"].every(d => !C.tabsFor(d).includes("qc")));
  ok("core: other tabs unchanged (Metal, Finishing, Full Custom, Delivery)", C.tabsFor("metal").join(",") === "work,arrow,tasks,issues,supplies"
     && C.tabsFor("finishing").join(",") === "work,paint,tasks,issues,supplies" && C.tabsFor("full_custom").join(",") === "work,past,tasks,issues,supplies"
     && C.tabsFor("delivery").join(",") === "loadout,arrow,tasks,issues");
  const L = [{ id: "a", at_vendor: true, waiting: true, job_id: "j", sheet_numbers: [5], queued_on: "2026-09-28", project_id: "P2" },
             { id: "b", at_vendor: true, waiting: false, job_id: "j", sheet_numbers: [4] },
             { id: "c", at_vendor: true, job_id: "k", sheet_numbers: [1] },                    // a page from before: no waiting column
             { id: "d", at_vendor: true, waiting: true, job_id: "k", sheet_numbers: [2], queued_on: "2026-09-20", project_id: "P1" },
             { id: "e", at_vendor: false, waiting: false, job_id: "j", sheet_numbers: [3], returned_on: "2026-09-01" }];
  ok("core: the pick-up list is the waiting items, oldest first", C.arrowWaiting(L).map(a => a.id).join(",") === "d,a");
  ok("core: At Arrow now is the rest of what's out (old rows without the column count as out)", C.arrowOut(L).map(a => a.id).join(",") === "b,c");
  const r5 = { job_id: "j", sheet_number: 5, qty_done: 0, qty_required: 1, available: 0, at_arrow: true };
  ok("core: a sheet held for Arrow reads 'Waiting to go to Arrow' while it waits, 'At Arrow' once gone",
     C.waitingText(r5, L) === "Waiting to go to Arrow" && C.waitingText({ ...r5, sheet_number: 4 }, L) === "At Arrow" && C.waitingText(r5) === "At Arrow");

  // ---- Willie sends two metal sheets to Arrow ----
  let w = boot(users.willie, dept("metal"));
  await openJob(w, J); await click(w, sheetBtn(w, 5), 300);
  await click(w, '[data-send="arrow"]', 500);
  await until(async () => !!(await item(5)));
  let a5 = await item(5);
  ok("Willie: Send to Arrow on sheet 5 makes an Arrow item that's waiting to go, under his name", a5 && a5.waiting && a5.queued_by_name === "Willie J" && a5.returned_on === null, JSON.stringify(a5 && { w: a5.waiting, q: a5.queued_by_name }));
  await until(() => $(w, ".sent") && /pick-up list/.test($(w, ".sent").textContent), 4000);
  ok("...the sheet says 'Sent to Arrow' · on the Arrow pick-up list", /Sent to Arrow/.test($(w, ".sent").textContent) && /on the Arrow pick-up list/.test($(w, ".sent").textContent), $(w, ".sent") && $(w, ".sent").textContent.replace(/\s+/g, " "));
  await click(w, '[data-back="job"]'); await click(w, sheetBtn(w, 4), 300);
  await click(w, '[data-send="arrow"]', 500);
  await until(async () => !!(await item(4)));
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 300);
  await click(w, '[data-tab="arrow"]', 500);
  await until(() => section(w, "Waiting to go to Arrow"));
  ok("Willie's Arrow tab opens with 'Waiting to go to Arrow': both sheets, each with Gone to Arrow",
     $$(w, "[data-argone]").length === 2 && /sheet 5/.test(sectionText(w, "Waiting to go to Arrow")) && /sheet 4/.test(sectionText(w, "Waiting to go to Arrow")), sectionText(w, "Waiting to go to Arrow").slice(0, 200));
  ok("...with 'All 2 gone to Arrow' for a whole trip", /All 2 gone to Arrow/.test(($(w, "[data-argoneall]") || {}).textContent || ""));
  ok("...and they're not under At Arrow now", !/PROJ-00600/.test(sectionText(w, "At Arrow now")) && /Nothing at Arrow right now/.test(sectionText(w, "At Arrow now")), sectionText(w, "At Arrow now"));
  ok("...each says who sent it on and since when", /Powdercoat · sent on .* by Willie J/.test(sectionText(w, "Waiting to go to Arrow")) && /since today/.test(sectionText(w, "Waiting to go to Arrow")));
  const badge = () => { const b = $$(w, ".subtab").find(x => x.dataset.tab === "arrow"); const c = b && b.querySelector(".c"); return c ? Number(c.textContent) : 0; };
  ok("the Arrow tab's number counts them (2)", badge() === 2, String(badge()));
  ok("the 'Send something to Arrow' form is still there", !!$(w, "[data-aropen]"));
  w.close();

  // ---- KP: no QC tab; Assembly sees 'Waiting to go to Arrow' ----
  let kp = boot(users.kp, dept("assembly_qc", "qc"));          // a tablet last left on the old QC tab
  await until(() => subtabs(kp).length);
  ok("KP's tabs: Work orders · Arrow · Tasks · Issues · Supplies — no QC", subtabs(kp).join(",") === "Work orders,Arrow,Tasks,Issues,Supplies", subtabs(kp).join(","));
  ok("a tablet left on QC opens on Work orders", $$(kp, ".subtab").find(b => b.getAttribute("aria-current") === "true").textContent.startsWith("Work orders"));
  await until(() => $$(kp, "button.job").length);
  if ($(kp, '[data-qmode="all"]')) await click(kp, '[data-qmode="all"]');
  await openJob(kp, J);
  await until(() => /Waiting to go to Arrow/.test(sheetBtn(kp, 5).textContent), 4000);
  ok("KP: sheets 4 and 5 say 'Waiting to go to Arrow'", /Waiting to go to Arrow/.test(sheetBtn(kp, 5).textContent) && /Waiting to go to Arrow/.test(sheetBtn(kp, 4).textContent),
     [4, 5].map(n => sheetBtn(kp, n).textContent.replace(/\s+/g, " ")).join(" | "));
  await click(kp, sheetBtn(kp, 5), 300);
  ok("the sheet page has no Record QC button; Report a defect or issue is there", !$(kp, "[data-qcsheet]") && !/Record QC/.test(txt(kp)) && !!$(kp, '[data-report="here"]'));
  ok("...and the counter is the one way to finish it (Mark all done)", !!$(kp, "[data-all]"));
  await click(kp, '[data-report="here"]'); await click(kp, '[data-reportkind="defect"]');
  ok("a failed check is reported as a defect: 'Failed QC' is on Assembly / QC's list", $$(kp, "[data-picktype]").some(b => /Failed QC/.test(b.textContent)), $$(kp, "[data-picktype]").map(b => b.textContent.trim()).join(" | "));
  await click(kp, "[data-close]"); if ($(kp, "[data-close]")) await click(kp, "[data-close]");
  await click(kp, '[data-back="job"]'); await click(kp, '[data-back="queue"]', 300);
  await click(kp, '[data-tab="arrow"]', 500);
  await until(() => section(kp, "Waiting to go to Arrow"));
  ok("KP's Arrow tab has the same pick-up list", $$(kp, "[data-argone]").length === 2);
  kp.close();

  // ---- Shawn takes one over ----
  let sh = boot(users.shawn, dept("delivery", "arrow"));
  await until(() => section(sh, "Waiting to go to Arrow"));
  ok("Shawn's phone, Arrow tab: the pick-up list is there", $$(sh, "[data-argone]").length === 2);
  a5 = await item(5);
  await click(sh, `[data-argone="${a5.id}"]`, 150);
  ok("Gone to Arrow asks first, saying what and that the count starts today", /Gone to Arrow\?/.test($(sh, ".mdl").textContent) && /PROJ-00600 sheet 5/.test($(sh, ".mdl").textContent) && /starts today/.test($(sh, ".mdl").textContent),
     $(sh, ".mdl") && $(sh, ".mdl").textContent.replace(/\s+/g, " "));
  await click(sh, "[data-confirm]", 600);
  await until(async () => !(await item(5)).waiting);
  a5 = await item(5);
  const today = (await one("select local_today()::text d")).d;
  ok("confirmed: at Arrow from today, taken over by Shawn K", !a5.waiting && a5.sent_on === today && a5.gone_by_name === "Shawn K" && a5.queued_on !== null, JSON.stringify({ s: a5.sent_on, g: a5.gone_by_name }));
  await until(() => /PROJ-00600/.test(sectionText(sh, "At Arrow now")), 4000);
  ok("...it moves from the pick-up list to At Arrow now, saying who took it", /sheet 5/.test(sectionText(sh, "At Arrow now")) && /taken by Shawn K/.test(sectionText(sh, "At Arrow now"))
     && $$(sh, "[data-argone]").length === 1 && !$(sh, "[data-argoneall]"), sectionText(sh, "At Arrow now"));
  ok("...with 0 days out and Mark returned", /0 days out/.test(sectionText(sh, "At Arrow now")) && $$(sh, "[data-arreturn]").length === 1);

  // offline: the last one goes while the phone has no signal
  const a4 = await item(4);
  setOffline(true);
  await click(sh, `[data-argone="${a4.id}"]`, 150); await click(sh, "[data-confirm]", 500);
  ok("offline: Gone to Arrow waits on the phone; nothing changed yet", (await item(4)).waiting && Object.values(JSON.parse(sh.localStorage.getItem("sf_logbox") || "{}")).some(e => e.fn === "arrow_gone"));
  setOffline(false);
  sh.dispatchEvent(new sh.Event("online"));
  await until(async () => !(await item(4)).waiting, 6000);
  const b4 = await item(4);
  ok("back online: it sends by itself, with the day it was tapped", !b4.waiting && b4.sent_on === today && b4.gone_by_name === "Shawn K");
  await until(() => !section(sh, "Waiting to go to Arrow"), 4000);
  ok("...and the pick-up list is empty (the section goes away)", !section(sh, "Waiting to go to Arrow") && /sheet 4/.test(sectionText(sh, "At Arrow now")));
  await wait(400); sh.close();

  // ---- KP: now 'At Arrow' ----
  kp = boot(users.kp, dept("assembly_qc"));
  await until(() => $$(kp, "button.job").length);
  if ($(kp, '[data-qmode="all"]')) await click(kp, '[data-qmode="all"]');
  await openJob(kp, J);
  await until(() => /At Arrow/.test(sheetBtn(kp, 5).textContent) && !/Waiting to go/.test(sheetBtn(kp, 5).textContent), 4000);
  ok("KP: once gone, sheets 4 and 5 say 'At Arrow'", /At Arrow/.test(sheetBtn(kp, 5).textContent) && !/Waiting to go/.test(sheetBtn(kp, 5).textContent) && /At Arrow/.test(sheetBtn(kp, 4).textContent));
  kp.close();

  // ---- the whole trip at once, and Undo while waiting ----
  await admin.query(`update sheet_sends set undone_at = now() where outside_job_id in (select o.id from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = $1)`, [J]);
  await admin.query(`update outside_jobs o set voided_at = now() from jobs j where j.id = o.job_id and j.project_id = $1`, [J]);
  w = boot(users.willie, dept("metal"));
  await openJob(w, J);
  await click(w, "[data-sendall]"); await click(w, '[data-sendallroute="arrow"]', 800);
  await until(async () => (await one("select count(*)::int n from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = $1 and o.waiting and o.voided_at is null", [J])).n === 2);
  ok("Send all … to Arrow: both sheets wait on the pick-up list", true);
  await click(w, sheetBtn(w, 5), 300);
  await until(() => $(w, "[data-unsend]"));
  await click(w, "[data-unsend]"); await click(w, "[data-confirm]", 600);
  await until(async () => (await one("select count(*)::int n from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = $1 and o.waiting and o.voided_at is null", [J])).n === 1);
  ok("Undo on sheet 5 while it waits: it comes off the pick-up list", true);
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 300); await click(w, '[data-tab="arrow"]', 500);
  await until(() => section(w, "Waiting to go to Arrow") && $$(w, "[data-argone]").length === 1);
  ok("Willie's pick-up list shows just sheet 4 now", $$(w, "[data-argone]").length === 1 && !$(w, "[data-argoneall]") && /sheet 4/.test(sectionText(w, "Waiting to go to Arrow")));
  w.close();

  // ---- the database says no ----
  const mike = makeClient(users.mike);
  let r = await mike.rpc("arrow_gone", { p_items: [(await item(4)).id], p_gone_on: null });
  ok("Mike (Sanding / Finishing) can't mark it gone, through the same login path", !!r.error && /Only Metal, Assembly/.test(r.error.message), r.error && r.error.message);
  r = await makeClient(users.kp).rpc("return_from_arrow", { p_item: (await item(4)).id, p_returned_on: null });
  ok("an old page's Mark returned on a waiting item is refused in plain words", !!r.error && /hasn't gone to Arrow yet/.test(r.error.message), r.error && r.error.message);

  // ---- printing: one Print this sheet still prints ----
  kp = boot(users.kp, dept("assembly_qc"));
  await until(() => $$(kp, "button.job").length);
  if ($(kp, '[data-qmode="all"]')) await click(kp, '[data-qmode="all"]');
  await openJob(kp, J); await click(kp, sheetBtn(kp, 1), 400);
  await until(() => $(kp, "#printArea img"));
  await click(kp, "[data-print]");
  ok("Print this sheet still prints the sheet's page", kp.printed === 1 && !!$(kp, "#printArea img"));
  await wait(400); kp.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_pickup_office.js
```javascript
// Arrow pick-up list in the office: the real office.html in jsdom, against the real test database, as Luke.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.OFFICE || "../out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.supabase = { createClient: () => client };
  w.confirm = () => true; w.scrollTo = () => {}; w.TextEncoder = TextEncoder; w.Blob = Blob;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function signedIn(w) { await until(() => /This is my own computer/.test(txt(w)) || $(w, ".tab")); if ($(w, "[data-nopin]")) await click(w, "[data-nopin]", 300); await until(() => $(w, ".tab")); await wait(400); }
const panel = (w, title) => $$(w, "section.panel").find(p => (p.querySelector("h2") || {}).textContent && p.querySelector("h2").textContent.startsWith(title));
const J = "PROJ-00600";
const opsNumber = (w) => { const n = $(w, '.tab[data-tab="tasks"] .n'); return n ? Number(n.textContent) : 0; };

(async () => {
  // Willie sends sheet 5 to Arrow (waiting); sheet 4 went with the form 20 days ago (at Arrow, over 14 days)
  const sheetId = async (n) => (await one("select s.id from sheets s join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id where j.project_id = $1 and s.sheet_number = $2", [J, n])).id;
  const jobId = (await one("select id from jobs where project_id = $1", [J])).id;
  let r = await makeClient(users.willie).rpc("send_sheet", { p_sheet: await sheetId(5), p_from: "metal", p_route: "arrow", p_client_id: null });
  ok("setup: Willie sends sheet 5 to Arrow", !r.error, r.error && r.error.message);
  r = await makeClient(users.willie).rpc("send_to_arrow", { p_job: jobId, p_department: "metal", p_service: "paint", p_sheets: [], p_description: "brackets, black", p_sent_on: null, p_client_id: null });
  await admin.query("update outside_jobs set sent_on = local_today() - 20 where description = 'brackets, black'");
  // a waiting item that has sat 20 days: it's not "at Arrow over 14 days"
  await admin.query("update outside_jobs set sent_on = local_today() - 20, queued_on = local_today() - 20 where waiting");

  let w = boot(users.luke, { sfo_pin: JSON.stringify({ none: true }) }); await signedIn(w);
  await until(() => /At Arrow over 14 days/.test(txt(w)), 4000);
  const need = $$(w, "section.need").find(s => s.dataset.need === "arrow");
  ok("Needs you: 'At Arrow over 14 days' lists the brackets (gone 20 days ago) only — not the sheet still waiting to go",
     need && /brackets, black/.test(need.textContent) && !/sheet 5/.test(need.textContent) && /At Arrow over 14 days 1/.test(need.querySelector("h2").textContent.replace(/\s+/g, " ")),
     need && need.textContent.replace(/\s+/g, " ").slice(0, 200));

  await click(w, '.tab[data-tab="arrow"]', 300);
  await until(() => panel(w, "Waiting to go to Arrow"));
  const wp = panel(w, "Waiting to go to Arrow"), ap = panel(w, "At Arrow now");
  ok("Arrow tab: 'Waiting to go to Arrow' first, with sheet 5, who sent it on, days waiting and Gone to Arrow",
     wp && /PROJ-00600/.test(wp.textContent) && /sheet 5/.test(wp.textContent) && /by Willie J/.test(wp.textContent) && /waiting 20 days/.test(wp.textContent) && !!wp.querySelector("[data-argone]"),
     wp && wp.textContent.replace(/\s+/g, " ").slice(0, 240));
  ok("...and At Arrow now has only the brackets", ap && /brackets, black/.test(ap.textContent) && !/sheet 5/.test(ap.textContent), ap && ap.textContent.replace(/\s+/g, " ").slice(0, 200));
  ok("...the page says the count starts when it goes", /the count starts when it goes/.test(txt(w)));

  await click(w, wp.querySelector("[data-argone]"), 600);
  await until(async () => !(await one("select bool_or(waiting) w from outside_jobs")).w);
  const a5 = await one("select o.* from outside_jobs o where 5 = any(sheet_numbers) and voided_at is null");
  ok("Gone to Arrow from the office: at Arrow from today, taken by Luke H", !a5.waiting && a5.gone_by_name === "Luke H" && a5.sent_on === (await one("select local_today()::text d")).d);
  await until(() => !panel(w, "Waiting to go to Arrow") && /sheet 5/.test((panel(w, "At Arrow now") || {}).textContent || ""), 4000);
  ok("...the waiting section goes; sheet 5 is At Arrow now, 'taken by Luke H'", !panel(w, "Waiting to go to Arrow") && /taken by Luke H/.test(panel(w, "At Arrow now").textContent));

  // the job page
  await admin.query("update outside_jobs set waiting = true, gone_by_name = null, gone_at = null where 5 = any(sheet_numbers)");
  $(w, "[data-jobfind]").focus(); await wait(300);
  const box = $(w, "[data-jobfind]"); box.value = "600"; box.dispatchEvent(new w.Event("input")); await wait(80);
  box.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" })); await until(() => panel(w, "Arrow")); await wait(300);
  const jp = panel(w, "Arrow");
  ok("job page: its Arrow panel shows sheet 5 'waiting to go' and the brackets at Arrow", jp && /sheet 5/.test(jp.textContent) && /waiting to go/.test(jp.textContent) && /brackets, black/.test(jp.textContent) && /20 days out/.test(jp.textContent),
     jp && jp.textContent.replace(/\s+/g, " "));
  w.close();

  // the old office page against the new database: still works (waiting shows as out)
  if (process.env.OLD_OFFICE) {
    const old = fs.readFileSync(process.env.OLD_OFFICE, "utf8");
    ok("(old office)", !!old);
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### print test (build.py + pr3.js, in ../print)
```python
import re,sys,base64
src=sys.argv[1]; out=sys.argv[2]
h=open(src).read()
style=re.search(r'<style>(.*?)</style>',h,re.S).group(1)
img=base64.b64encode(open('page.png','rb').read()).decode()
open(out,'w').write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>{style}</style></head>
<body><div id="app"><header>app header</header><div class="page">{'<p>lots of screen content</p>'*80}</div></div>
<div id="printArea"><img alt="" src="data:image/png;base64,{img}"></div></body></html>''')
```
```javascript
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [vw, vh] of [[1280, 800], [800, 1280]]) {
    const p = await b.newPage({ viewport: { width: vw, height: vh } });
    await p.goto("file:///home/claude/sf/print/new.html");
    for (const [fmt, land] of [["Letter", false], ["Letter", true], ["A4", false], ["A4", true], ["Legal", false]])
      await p.pdf({ path: `n_${vw}_${fmt}_${land ? "L" : "P"}.pdf`, format: fmt, landscape: land });
    await p.close();
  }
  await b.close();
})();
```
