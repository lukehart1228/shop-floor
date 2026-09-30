# Testing kit — Part 9: menus, Undo, sync alert, job page, tamper checks (24 Sep, evening)

*For build chats. Luke doesn't need to read this.* Parts 1–8 still apply. Tested on a database built from **every live SQL file, unchanged** (`fresh.sh advance.sql supply_lists.sql loadouts_v2.sql deliveries.sql deliveries_v2.sql`). No SQL file changed in this build; `check_nav_build.sql` is a read-only script.

## Setup notes
- `pgsupa.js` = Part 5's photos version + Part 6's JSON-argument patch + Part 8's `ftypes` patch (assemble them; Part 8 lists only the diff).
- `npm install jsdom@24 pg fake-indexeddb playwright@1.56.0 pdf-lib jszip`; Chromium at `/opt/pw-browsers` (`PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`).
- The pages now load `<script src=…supabase.js integrity=… crossorigin=…>`. jsdom ignores it. **Chromium tests that swap in `fakesupa.js` must strip ` integrity="…"` from the HTML they serve**, or the browser (correctly) refuses the stand-in.
- Library hashes: `npm pack @supabase/supabase-js@2.45.4 pdf-lib@1.17.1`, then `openssl dgst -sha384 -binary <file> | openssl base64 -A`. **`dist/umd/supabase.min.js` is not in the npm package** — jsDelivr minifies on request, so never hash it; use `dist/umd/supabase.js`. Confirm in Luke's Chrome with `fetch(url, { integrity, mode: "cors" })` before going live.
- **Deploying through Claude in Chrome:** `file_upload` can't read container paths. What worked: diff live → new with difflib opcodes, gzip+base64 the ops (~15 KB for this build), and in the github.com upload tab fetch `raw.githubusercontent.com/…/main/<file>`, check its SHA-256 equals the base you diffed, apply the ops, check the result's SHA-256 equals the tested file, then put the `File`s on `input[type=file]` with a `DataTransfer` and dispatch `change`. The SQL Editor takes text through `monaco.editor.getModels()[0].setValue()` (same gzip + fingerprint trick) in a **new** query tab — never over Luke's open query. A status banner can shift the Run button; read the screen before clicking.

## Results when delivered
| Suite | Result |
|---|---|
| `test_nav_tablet.js` — Department menu (Luke, Test Supervisor), tabs unchanged (Donnie, Willie), Undo online / timed out / offline, history rows | 25 PASS |
| `test_office_nav.js` — sync alert (healthy, broken with 401, stopped timer), badge count, ☰ menu, remembered Setup, Find a job, job page grid against the database, flag / problems / Arrow / defects / photos, Back, PROJ links, no-work-order job, test job | 36 PASS |
| `test_sri.js` — real Chromium: each page loads the published library; one changed line is refused; pdf-lib the same | 12 PASS |
| `test_advance2.js` (Advance through the menu) / `test_mike_same.js` / `test_app_core.js` | 48 / identical / 19 |
| `test_needs2.js` (Chromium; six tabs, Setup via menu, fixture has a healthy sync row) | 43 PASS |
| `test_deliveries.js` / `test_supply_lists.js` / `test_tv.js` | 76 / 63 / 21 |
| `check_nav_build.sql` twice, and against 4 breaks (supervisors read sync log; any-update policy on sheet_progress; v_loadouts revoked; managers lose the sync log) | 5 PASS; each break caught |
| Live, in Luke's Chrome after deploy | check 5 PASS; office and tablet load (library via the v3 cache on the second load), job page on PROJ-00485, no console errors |

Not covered: a real tablet's touch and how soon it picks up the new service worker.

`test_office_e2e.js` (Part 2/5) predates Needs you and fails on the live page too — don't use it.

## Files

#### test_nav_tablet.js
```javascript
// This build (25 Sep): the Department ▾ menu (managers, Test Supervisor) and Undo after Mark all done.
// The real index.html in jsdom against the real test database (pgsupa.js).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const NEW = fs.readFileSync("../out/index.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(NEW, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...NEW.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const qty = async (proj, sheet, dept) => (await one(`select sp.qty_done from sheet_progress sp join sheets s on s.id = sp.sheet_id
  join work_orders wo on wo.id = s.work_order_id and wo.is_current join jobs j on j.id = wo.job_id
  where j.project_id = $1 and s.sheet_number = $2 and sp.department = $3`, [proj, sheet, dept])).qty_done;

(async () => {
  // ---------- Luke: the menu ----------
  let w = boot(users.luke);
  await until(() => $(w, "[data-deptmenu]"));
  ok("Luke: the header has the Department button and no tab strip", !!$(w, "[data-deptmenu]") && !$(w, "header .tabs"));
  ok("Luke: the menu starts closed", !$(w, ".deptmenu") && $(w, "[data-deptmenu]").getAttribute("aria-expanded") === "false");
  await click(w, "[data-deptmenu]");
  ok("Luke: tapping it opens the list, marked open", !!$(w, ".deptmenu") && $(w, "[data-deptmenu]").getAttribute("aria-expanded") === "true");
  const items = $$(w, ".deptmenu .dmitem").map(b => b.textContent.replace(/\s+/g, " ").trim());
  ok("Luke: eight departments in order, Delivery marked log only, then Advance",
     items.join("|") === "Milling|CNC|Sanding|Finishing|Full Custom|Metal|Assembly / QC|Deliverylog only|Advanceset counts by hand", items.join("|"));
  ok("Luke: exactly one item is marked as where he is", $$(w, '.deptmenu [aria-current="true"]').length === 1);
  await click(w, "[data-dmclose]");
  ok("Luke: tapping outside the list closes it", !$(w, ".deptmenu"));
  await click(w, "[data-deptmenu]"); await click(w, '[data-dept="metal"]', 400);
  ok("Luke: picking Metal closes the list and opens Metal", !$(w, ".deptmenu") && /Metal/.test($(w, "[data-deptmenu]").textContent) && /Metal/.test($(w, "h1").textContent));
  await click(w, "[data-deptmenu]"); await click(w, '[data-dept="delivery"]', 400);
  ok("Luke: Delivery opens on its own areas", /Delivery/.test($(w, "[data-deptmenu]").textContent) && !!$(w, '[data-tab="loadout"]'));
  await click(w, "[data-deptmenu]");
  ok("Luke: the list marks Delivery as where he is", $(w, '.deptmenu [data-dept="delivery"]').getAttribute("aria-current") === "true");

  // ---------- Test Supervisor: seven departments and Advance ----------
  w = boot(users.test);
  await until(() => $(w, "[data-deptmenu]"));
  await click(w, "[data-deptmenu]");
  ok("Test Supervisor: the menu too — all eight departments and Advance", $$(w, ".deptmenu .dmitem").length === 9 && !!$(w, ".deptmenu [data-adv]"), $$(w, ".deptmenu .dmitem").length + " items");

  // ---------- Donnie and Mike: tabs, as before ----------
  w = boot(users.donnie);
  await until(() => $$(w, "header .tab").length);
  ok("Donnie: still two tabs, no menu button", $$(w, "header .tab").length === 2 && !$(w, "[data-deptmenu]"));
  w = boot(users.willie);
  await until(() => $(w, "header .who"));
  ok("Willie (one department): no tabs, no menu", !$(w, "header .tab") && !$(w, "[data-deptmenu]"));

  // ---------- Mike: Undo ----------
  w = boot(users.mike);
  await until(() => $$(w, "[data-job]").length);
  const start = await qty("PROJ-00418", 4, "sanding");
  await click(w, $$(w, "[data-job]").find(b => /PROJ-00418/.test(b.textContent)), 200);
  const s4 = $$(w, "[data-sheet]").find(b => /^\s*4/.test(b.textContent));
  await click(w, s4, 300);
  ok("Mike: sheet 4 open, not finished", /Sheet 4/.test($(w, "h1").textContent) && !!$(w, "[data-all]"), `start ${start}`);
  await click(w, "[data-all]", 50);
  ok("Mike: Mark all done shows the message with an Undo button", !!$(w, ".toast.undo [data-undo]") && /Sheet 4 marked 3 of 3 done/.test($(w, ".toast.undo").textContent));
  await until(async () => await qty("PROJ-00418", 4, "sanding") === 3);
  ok("Mike: the count reached the database", await qty("PROJ-00418", 4, "sanding") === 3);
  await click(w, "[data-undo]", 50);
  ok("Mike: Undo takes the message away", !$(w, ".toast.undo"));
  await until(async () => await qty("PROJ-00418", 4, "sanding") === start);
  ok("Mike: Undo puts the database back to the number before", await qty("PROJ-00418", 4, "sanding") === start, `now ${await qty("PROJ-00418", 4, "sanding")}`);
  ok("Mike: the screen shows it too", Number($(w, ".readout .n").textContent) === start && !!$(w, "[data-all]"));
  const ev = await one(`select string_agg(e.qty_from || '>' || e.qty_to || ':' || e.source, ',' order by e.occurred_at) h from progress_events e
     join sheets s on s.id = e.sheet_id join work_orders wo on wo.id = s.work_order_id and wo.is_current join jobs j on j.id = wo.job_id
     where j.project_id = 'PROJ-00418' and s.sheet_number = 4 and e.department = 'sanding' and e.occurred_at > now() - interval '1 minute'`);
  ok("Mike: both changes are in the history, as the tablet's", ev.h === `${start}>3:Tablet,3>${start}:Tablet`, ev.h);

  // the message goes by itself
  await click(w, "[data-all]", 50);
  ok("Mike: Mark all again offers Undo again", !!$(w, ".toast.undo"));
  await wait(8400);
  ok("Mike: after eight seconds the Undo message is gone, the count stays", !$(w, ".toast.undo") && await qty("PROJ-00418", 4, "sanding") === 3);
  ok("Mike: a finished sheet has no Mark all, so no Undo", !$(w, "[data-all]"));

  // offline: Mark all then Undo, both wait, one result
  await click(w, "[data-step='-1']", 50); await click(w, "[data-step='-1']", 50);
  await until(async () => await qty("PROJ-00418", 4, "sanding") === 1);
  setOffline(true);
  await click(w, "[data-all]", 50); await click(w, "[data-undo]", 50);
  ok("Mike: offline, the count waits on the tablet", /waiting to send/.test($(w, ".sync").textContent) && Number($(w, ".readout .n").textContent) === 1);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(() => /All saved/.test($(w, ".sync").textContent), 5000);
  ok("Mike: back online, the database has the number from before Mark all", await qty("PROJ-00418", 4, "sanding") === 1);

  // the menu is managers-only in the markup too
  ok("Mike: no menu button anywhere", !$(w, "[data-deptmenu]") && !$(w, ".deptmenu"));
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_office_nav.js
```javascript
// This build (25 Sep): the office's ☰ menu, the Monday sync alert, Find a job and the job page.
// The real office.html in jsdom against the real test database (pgsupa.js), as Luke.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync("../out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
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
  w.confirm = () => true; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const badge = (w) => { const n = $(w, '.tab[data-tab="tasks"] .n'); return n ? Number(n.textContent) : 0; };
async function signedIn(w) { await until(() => /This is my own computer/.test(txt(w)) || $(w, ".tab")); if ($(w, "[data-nopin]")) await click(w, "[data-nopin]", 300); await until(() => $(w, ".tab")); await wait(400); }

(async () => {
  const mike = makeClient(users.mike), willie = makeClient(users.willie);
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Glue line opened on the top overnight.", p_sheet: 3, p_work_stopped: true });
  await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: (await one("select id from defect_types where department='sanding' order by sort_order limit 1")).id, p_sheet: 1 });
  await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6], p_sent_on: "2026-09-15" });
  await makeClient(users.luke).rpc("set_flag", { p_job: j418, p_level: "priority", p_note: "Customer moved the date up", p_department: null });

  // ---------- a healthy sync: nothing said ----------
  await admin.query("delete from monday_sync_log");
  await admin.query("insert into monday_sync_log (ok, summary, run_at) values (true, 'Read 293 jobs', now() - interval '10 minutes')");
  let w = boot(users.luke);
  await signedIn(w);
  ok("Healthy sync: no alert on Needs you", !$(w, ".syncalert"));
  const base = badge(w);

  // ---------- broken: the last good sync 3 hours ago, Monday refusing since ----------
  await admin.query("delete from monday_sync_log");
  await admin.query(`insert into monday_sync_log (ok, summary, run_at) values
    (true, 'Read 293 jobs', now() - interval '3 hours 5 minutes'),
    (false, 'Monday refused access (401). The token may be wrong or revoked.', now() - interval '10 minutes')`);
  w = boot(users.luke);
  await signedIn(w);
  await until(() => $(w, ".syncalert"));
  const al = $(w, ".syncalert");
  ok("Broken sync: the alert is at the top of Needs you", !!al && al === $(w, "main .syncalert") && /Monday hasn't synced for 3 hours/.test(al.textContent), al && al.textContent.replace(/\s+/g, " ").slice(0, 90));
  ok("Broken sync: it says what that means and quotes Monday", /new jobs won't reach the floor/.test(al.textContent) && /Monday refused access \(401\)/.test(al.textContent) && /token needs replacing/.test(al.textContent));
  ok("Broken sync: Needs you's number counts it", badge(w) === base + 1, `${base} → ${badge(w)}`);
  await click(w, ".syncalert [data-tab='setup']", 400);
  ok("Open Setup goes to Setup", /Monday/.test($(w, "main h1") ? $(w, "main").textContent : "") && !$(w, '.tab[aria-current="true"]'));

  // ---------- stopped timer: no rows for hours ----------
  await admin.query("delete from monday_sync_log");
  await admin.query("insert into monday_sync_log (ok, summary, run_at) values (true, 'Read 293 jobs', now() - interval '5 hours')");
  w = boot(users.luke, { sfo_pin: JSON.stringify({ none: true }) });
  await until(() => $(w, ".syncalert"));
  ok("Stopped timer: says the timer may have stopped, no Monday reply", /timer may have stopped/.test($(w, ".syncalert").textContent) && !$(w, ".syncalert .reply"));
  await admin.query("insert into monday_sync_log (ok, summary, run_at) values (true, 'Read 293 jobs', now())");

  // ---------- the ☰ menu ----------
  w = boot(users.luke, { sfo_pin: JSON.stringify({ none: true }) });
  await until(() => $(w, ".tab"));
  const tabs = $$(w, ".tab").map(t => t.firstChild.textContent.trim());
  ok("Six tabs, no Setup", tabs.join(",") === "Needs you,Flags,Arrow,Routine tasks,Departments,Photos", tabs.join(","));
  ok("The menu starts closed", !$(w, ".menu") && $(w, "[data-menu]").getAttribute("aria-expanded") === "false");
  await click(w, "[data-menu]");
  const links = $$(w, ".menu a").map(a => a.getAttribute("href"));
  ok("The menu links all four pages, by their exact lower-case names", links.join(",") === "office.html,upload.html,delivery.html,index.html", links.join(","));
  ok("The menu has Setup, Sign out and the version", !!$(w, ".menu [data-tab='setup']") && !!$(w, ".menu [data-signout]") && /Version \d+ \w+ 2026/.test($(w, ".menu .ver").textContent));
  await click(w, ".mshade");
  ok("Tapping outside closes it", !$(w, ".menu"));
  await click(w, "[data-menu]"); await click(w, ".menu [data-tab='setup']", 400);
  ok("Setup from the menu: the menu closes and Setup opens", !$(w, ".menu") && /TV link/.test(txt(w)));
  const w2 = boot(users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("setup") });
  await until(() => /TV link/.test(txt(w2)), 5000);
  ok("A computer that remembered Setup still opens on it", /TV link/.test(txt(w2)));

  // ---------- Find a job ----------
  w = boot(users.luke, { sfo_pin: JSON.stringify({ none: true }) });
  await until(() => $(w, ".tab"));
  await wait(600);
  let box = $(w, "[data-jobfind]");
  box.focus(); await wait(300);
  ok("A redraw while the box has focus keeps the focus", (w.eval("void 0"), true) && w.document.activeElement.matches("[data-jobfind]"));
  box = $(w, "[data-jobfind]");
  box = $(w, "[data-jobfind]"); box.value = "418"; box.dispatchEvent(new w.Event("input")); await wait(50);
  const hits = $$(w, "#jobhits [data-openjob]").map(b => b.textContent.replace(/\s+/g, " ").trim());
  ok("Typing 418 finds the real job first, and the test job labelled TEST", hits.length === 2 && /^PROJ-00418/.test(hits[0]) && /TEST/.test(hits[1]), hits.join(" | "));
  ok("The box keeps focus while typing", w.document.activeElement === $(w, "[data-jobfind]"));
  box.value = "oaks"; box.dispatchEvent(new w.Event("input")); await wait(50);
  ok("A word searches the job names", $$(w, "#jobhits [data-openjob]").length === 1 && /PROJ-00099/.test($(w, "#jobhits").textContent));
  box.value = "zzz"; box.dispatchEvent(new w.Event("input")); await wait(50);
  ok("No match says so", /No job matches that/.test($(w, "#jobhits").textContent));
  box.value = "418"; box.dispatchEvent(new w.Event("input")); await wait(50);
  box.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" }));
  await until(() => $(w, ".grid"));

  // ---------- the job page ----------
  ok("Enter opens the first match's job page", /PROJ-00418/.test($(w, ".jobhead h1").textContent) && !$(w, '.tab[aria-current="true"]'));
  const exp = (await admin.query(`select s.sheet_number, sp.department, sp.qty_done, sp.qty_required from sheet_progress sp join sheets s on s.id = sp.sheet_id
     join work_orders wo on wo.id = s.work_order_id and wo.is_current where wo.job_id = $1`, [j418])).rows;
  const nSheets = new Set(exp.map(r => r.sheet_number)).size, depts = [...new Set(exp.map(r => r.department))];
  const heads = $$(w, ".grid .gh").map(x => x.textContent);
  ok("The grid: a column for each department on this job, in shop order", heads.length === depts.length && heads[0] === "Milling", heads.join(","));
  ok("The grid: a row for each sheet", $$(w, ".grid .gs").length === nSheets + 1, `${$$(w, ".grid .gs").length - 1} rows, ${nSheets} sheets`);
  const DN = { milling: "Milling", cnc: "CNC", sanding: "Sanding", finishing: "Finishing", full_custom: "Full Custom", metal: "Metal", assembly_qc: "Assembly / QC" };
  const rowsEl = $$(w, ".grid .gs").slice(1);
  let bad = [];
  for (const r of exp) {
    const rowEl = rowsEl.find(e => e.querySelector("b").textContent === `Sheet ${r.sheet_number}`);
    let el = rowEl; const k = heads.indexOf(DN[r.department]);
    for (let i = 0; i <= k; i++) el = el.nextElementSibling;
    const want = `${r.qty_done}/${r.qty_required}`, kind = r.qty_done >= r.qty_required ? "done" : r.qty_done > 0 ? "part" : "zero";
    if (!el || el.textContent !== want || !el.classList.contains(kind)) bad.push(`${r.sheet_number}/${r.department}`);
  }
  ok("The grid: every cell matches the database, coloured by state", bad.length === 0, bad.join(","));
  ok("The grid: sheets that skip a department show —", $$(w, ".grid .c.no").every(e => e.textContent === "—"));
  const done = $$(w, ".grid .c.done").length;
  ok("Complete cells are turquoise (class done)", done === exp.filter(r => r.qty_done >= r.qty_required).length);
  ok("The flag shows as a band", /Priority: Customer moved the date up/.test($(w, ".jobband").textContent));
  ok("Problems: the open one, with Work stopped", /Sheet 3 · Sanding/.test(txt(w)) && /Glue line opened/.test(txt(w)) && !!$(w, ".side .stoptag"));
  ok("Arrow: sheet 6 at Arrow, with its days out", /sheet 6/.test($$(w, ".side .panel")[1].textContent) && /days out/.test($$(w, ".side .panel")[1].textContent));
  ok("Defects: one", /Defects 1/.test($$(w, ".side .panel")[2].textContent.replace(/\s+/g, " ")));
  ok("Nothing on the page repeats the work order's specs", !/species|walnut|oak|finish spec/i.test($(w, ".grid").textContent));

  await click(w, "[data-jobback]", 400);
  ok("Back returns to Needs you", $(w, '.tab[data-tab="tasks"]').getAttribute("aria-current") === "true" && !$(w, ".grid"));

  // from a problem card on Needs you
  await until(() => $(w, "main .pidlink"));
  await click(w, "main .pidlink", 50);
  await until(() => $(w, ".grid"));
  ok("A PROJ number on Needs you opens the job page", /PROJ-00418/.test($(w, ".jobhead h1").textContent));
  await click(w, ".tab[data-tab='flags']", 300);
  ok("A tab leaves the job page", !$(w, ".grid") && $(w, '.tab[data-tab="flags"]').getAttribute("aria-current") === "true");

  // a job with no work order
  box.value = "";
  const b2 = $(w, "[data-jobfind]"); b2.focus(); b2.dispatchEvent(new w.Event("focus")); await wait(200);
  b2.value = "325"; b2.dispatchEvent(new w.Event("input")); await wait(50);
  ok("An inactive job is found too, labelled with its phase", /PROJ-00325/.test($(w, "#jobhits").textContent) && !/on the floor/.test($(w, "#jobhits").textContent));
  b2.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" }));
  await until(() => /No work order uploaded/.test(txt(w)));
  ok("A job with no work order says so, and nothing breaks", /No work order uploaded/.test(txt(w)) && /None open/.test(txt(w)));

  // the test job
  const b3 = $(w, "[data-jobfind]"); b3.focus(); b3.dispatchEvent(new w.Event("focus")); await wait(200);
  b3.value = "TEST"; b3.dispatchEvent(new w.Event("input")); await wait(50);
  b3.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" }));
  await until(() => /TEST-00418/.test(($(w, ".jobhead") || {}).textContent || ""));
  ok("The test job opens, labelled TEST", !!$(w, ".jobhead .tag") && $$(w, ".grid .gs").length > 1);

  // photos button
  await admin.query(`insert into photos (client_id, job_id, department, kind, defect_id, storage_path, taken_by, is_test)
     select gen_random_uuid(), $1, 'sanding', 'defect', (select id from defects where job_id = $1 limit 1), 'PROJ-00418/' || gen_random_uuid() || '.jpg', '11111111-1111-1111-1111-111111111111', false`, [j418]).catch(e => console.log("(photo seed skipped: " + e.message.split("\n")[0] + ")"));
  const b4 = $(w, "[data-jobfind]"); b4.focus(); b4.dispatchEvent(new w.Event("focus")); await wait(100);
  b4.value = "PROJ-00418"; b4.dispatchEvent(new w.Event("input")); await wait(50);
  b4.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" }));
  await until(() => $(w, ".grid"));
  if ($(w, "[data-jobphotos]")) {
    await click(w, "[data-jobphotos]", 600);
    ok("See them on Photos opens the Photos tab on that job", $(w, '.tab[data-tab="photos"]').getAttribute("aria-current") === "true" && /PROJ-00418/.test(txt(w)));
  } else ok("Photos panel: none yet (no photo could be seeded)", /Photos None yet/.test(txt(w).replace(/\s+/g, " ")));

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_sri.js
```javascript
// The tamper check in real Chromium: the published supabase.js and pdf-lib load; one changed byte is refused.
const fs = require("fs"), http = require("http");
const { chromium } = require("playwright");
const SB = fs.readFileSync("/tmp/sri/supabase-supabase-js-2.45.4/package/dist/umd/supabase.js");
const PL = fs.readFileSync("/tmp/sri/pdf-lib-1.17.1/package/dist/pdf-lib.min.js");
let pass = 0, fail = 0; const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const server = http.createServer((req, res) => { const f = "../out" + req.url.split("?")[0]; if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": f.endsWith(".js") ? "application/javascript" : "text/html" }); res.end(fs.readFileSync(f)); });
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const browser = await chromium.launch();
  async function tryPage(page, body, pdf) {
    const ctx = await browser.newContext({ serviceWorkers: "block" });
    await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
    await ctx.route(/supabase-js@2\.45\.4\/dist\/umd\/supabase\.js/, r => r.fulfill({ body, contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
    await ctx.route(/pdf-lib@1\.17\.1/, r => r.fulfill({ body: pdf, contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
    const p = await ctx.newPage(); const msgs = [];
    p.on("console", m => msgs.push(m.text()));
    await p.goto(`http://127.0.0.1:${server.address().port}/${page}`); await p.waitForTimeout(600);
    const has = await p.evaluate(() => !!window.supabase);
    let pdfOk = null;
    if (page === "office.html") pdfOk = await p.evaluate((sri) => new Promise(res => { const s = document.createElement("script"); s.integrity = sri; s.crossOrigin = "anonymous";
      s.src = "https://cdn.jsdelivr.net/npm/pdf-lib@1.17.1/dist/pdf-lib.min.js"; s.onload = () => res(!!window.PDFLib); s.onerror = () => res(false); document.head.appendChild(s); }),
      fs.readFileSync("../out/office.html", "utf8").match(/PDF_LIB_SRI = "([^"]+)"/)[1]);
    await ctx.close(); return { has, pdfOk, msgs };
  }
  for (const page of ["index.html", "office.html", "delivery.html", "upload.html", "tv.html"]) {
    const good = await tryPage(page, SB, PL);
    ok(`${page}: the published library loads`, good.has);
    const bad = Buffer.concat([SB, Buffer.from("\n//x")]);
    const r = await tryPage(page, bad, Buffer.concat([PL, Buffer.from(" ")]));
    ok(`${page}: a copy changed by one line is refused`, !r.has && r.msgs.some(m => /integrity/i.test(m)), r.msgs.find(m => /integrity/i.test(m)) ? "" : r.msgs.join("|").slice(0, 120));
    if (page === "office.html") { ok("office: pdf-lib loads when unchanged", good.pdfOk === true); ok("office: altered pdf-lib is refused", r.pdfOk === false); }
  }
  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`);
})();
```

#### snap_nav.js
```javascript
// save the new screens' HTML from jsdom (real DB), then photograph them in Chromium
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { chromium } = require("playwright");
const { makeClient, admin, users } = require("./pgsupa");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
function boot(file, user, url, preload = {}) {
  const html = strip(fs.readFileSync(file, "utf8"));
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client }; w.confirm = () => true; w.scrollTo = () => {};
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const save = (w, name) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove()); fs.writeFileSync(`/tmp/snap_${name}.html`, "<!doctype html>" + d.outerHTML); };
(async () => {
  const mike = makeClient(users.mike);
  const j418 = (await admin.query("select id from jobs where project_id='PROJ-00418'")).rows[0].id;
  await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Glue line opened on the top overnight.", p_sheet: 3, p_work_stopped: true });
  await makeClient(users.willie).rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6], p_sent_on: "2026-09-15" });
  await makeClient(users.luke).rpc("set_flag", { p_job: j418, p_level: "priority", p_note: "Customer moved the date up", p_department: null });
  await admin.query("delete from monday_sync_log");
  await admin.query(`insert into monday_sync_log (ok, summary, run_at) values (true, 'Read 293 jobs', now() - interval '3 hours 5 minutes'),
    (false, 'Monday refused access (401). The token may be wrong or revoked, or its account can''t open the Orders board.', now() - interval '10 minutes')`);
  const O = "https://lukehart1228.github.io/shop-floor/office.html", pin = { sfo_pin: JSON.stringify({ none: true }) };
  let w = boot("../out/office.html", users.luke, O, pin); await wait(1500); save(w, "office_needs");
  w.document.querySelector("[data-menu]").click(); await wait(100); save(w, "office_menu");
  w = boot("../out/office.html", users.luke, O, pin); await wait(1200);
  const b = w.document.querySelector("[data-jobfind]"); b.focus(); await wait(300); b.value = "418"; b.dispatchEvent(new w.Event("input")); await wait(100); save(w, "office_find");
  b.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" })); await wait(1200); save(w, "office_job");
  const T = "https://lukehart1228.github.io/shop-floor/index.html";
  w = boot("../out/index.html", users.luke, T, { sf_dept: JSON.stringify("sanding") }); await wait(1500);
  w.document.querySelector("[data-deptmenu]").click(); await wait(100); save(w, "tablet_menu");
  w = boot("../out/index.html", users.mike, T); await wait(1500);
  [...w.document.querySelectorAll("[data-job]")].find(x => /00418/.test(x.textContent)).click(); await wait(300);
  [...w.document.querySelectorAll("[data-sheet]")].find(x => /^\s*4/.test(x.textContent)).click(); await wait(300);
  w.document.querySelector("[data-all]").click(); await wait(80); save(w, "tablet_undo");
  const browser = await chromium.launch();
  for (const [n, vp] of [["office_needs", [1366, 900]], ["office_menu", [1366, 900]], ["office_find", [1366, 500]], ["office_job", [1366, 1150]], ["tablet_menu", [1280, 800]], ["tablet_undo", [1280, 800]], ["tablet_menu_upright", [800, 1280]]]) {
    const p = await browser.newPage({ viewport: { width: vp[0], height: vp[1] } });
    await p.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
    await p.goto("file:///tmp/snap_" + n.replace("_upright", "") + ".html"); await p.waitForTimeout(200);
    await p.screenshot({ path: `/tmp/shot_${n}.png` }); await p.close();
  }
  await browser.close(); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_advance2.js / test_needs2.js
Made from Part 6's `test_advance.js` and Part 4's `test_needs.js` by opening `[data-deptmenu]` before `[data-adv]` / `[data-dept]`, expecting six office tabs with Setup from `.menu [data-tab="setup"]`, adding a recent `ok` row to `monday_sync_log` in `fixtures.js`, and stripping `integrity` in the test server.
