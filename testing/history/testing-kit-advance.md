# Testing kit — Part 5: Advance (23 Sep, later)

*For build chats. Luke doesn't need to read this.* Parts 1–4 still apply (environment, "test as a real login", jsdom gaps).

This build added `advance.sql` (the function `advance_sheet()`, the table `sheet_adjustments`, the check `check_advance()`) and changed `index.html` (the Advance tab). It was tested against a copy of the real database built from **every live SQL file, unchanged**, plus `advance.sql`, each loaded twice.

## Setup

- **Postgres 16, `pg_cron` and `http`.** `apt-get update` first — without it the Postgres packages 404. The `http` extension is built from source (Part 1). With both extensions present the real files load **unchanged**: no `_min.sql` trimming needed. `load.sh` unschedules the Monday timer straight after loading.
- **One stub file**, Part 3's `stubs.sql`. Logins and seed: Part 3's `people.sql` and `seed.sql` (Mike = sanding + finishing, Luke, David, Donnie, Willie, KP, Shawn; `test@example.com` becomes the Test Supervisor in `seed.sql`, since `set_person()` doesn't exist until `office.sql` has loaded). Test jobs are named `TEST-00418`, not `TEST-PROJ-00418`.
- Split `sql-files.md` and `sql-files-2.md` into files with a regex on the `## \`name.sql\`` headings; the test files out of Parts 1–4 the same way, taking the **latest** version of each name.
- `npm install jsdom@24 pg fake-indexeddb playwright@1.56.0 @fontsource/barlow @fontsource/barlow-condensed`. Chromium is at `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.
- **The kit's `test_app_page.js` fake client** needed the chaining update Part 4 mentions but didn't save. It's below. Two expectations there and in `test_app_e2e.js` now look only at department tabs (`.tab[data-dept]`), and with `ADVANCE=1` also check that Advance is the ninth and last.
- `/bin/sh` here isn't bash: `diff <(…)` fails. Write to a file first.

## Results when delivered

| Suite | Result |
|---|---|
| `check_advance()` on the stand-in, loaded twice | 10 PASS, nothing left behind |
| `check_advance()` against 6 deliberate breaks (`breaks_advance.py` + a grant-and-policy break) | each caught at its own row. A grant alone wasn't a breach: RLS still refused it |
| `check_floor()` / `check_photos()` beside it | 18 / 16 PASS |
| `test_app_core.js` (kit) | 19 PASS |
| `test_app_page.js` (kit, chaining fake, `ADVANCE=1`) | 31 PASS (30 on the live page) |
| `test_app_e2e.js` (`ADVANCE=1 PHOTOS=1`) | 67 PASS |
| `test_photos_e2e.js` | 41 PASS |
| `test_advance.js` — helpers; Mike's 8 screens byte-for-byte against the live page; Luke's whole flow; offline; the Test Supervisor | 46 PASS |
| `snap_adv.js` — the four Advance screens in Chromium, 1280×800 and 800×1280 | looked at: counters line up, Complete matches the buttons, portrait fits |

Run order: `cd t && ../base/fresh.sh ../out/advance.sql && node <suite>.js`. A fresh database for each suite.

Not covered: a real Android tablet and the real SQL Editor (Walkthrough 9).

## Files

#### load.sh (in `base/`)
```bash
#!/bin/bash
# rebuild 'sync' the way Luke's database is (every live file, each loaded twice), then any extra files given
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync" >/dev/null
cd /home/claude/w/base
$P -d sync -f stubs.sql
$P -d sync -c "create extension http with schema extensions; create extension pg_cron;" >/dev/null
$P -d sync -f schema.sql; $P -d sync -f schema.sql
$P -d sync -f people.sql
for f in verify_setup.sql upload_function.sql monday_sync.sql tablet.sql office.sql test_lane.sql catch_up.sql problems.sql flags.sql routine_tasks.sql supplies.sql arrow_qc.sql tv.sql check_floor.sql photos.sql check_photos.sql; do
  $P -d sync -f $f >/dev/null; $P -d sync -f $f >/dev/null; done
$P -d sync -c "select cron.unschedule('shop-floor-monday-sync')" >/dev/null 2>&1 || true
$P -d sync -f seed.sql >/dev/null
for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f" >/dev/null; $P -d sync -f "$f" >/dev/null; done
echo LOADED
```

#### fresh.sh (in `base/`)
```bash
#!/bin/bash
# a fresh database like Luke's (every live file), seeded, plus any extra files given
/home/claude/w/base/load.sh "$@" >/tmp/load.out 2>&1 || { echo LOAD FAILED; grep -i -B2 -A3 error /tmp/load.out | head -30; exit 1; }
echo READY
```

#### test_app_page.js — the chaining fake client (replaces `c.from` in the kit's version)
```javascript
  c.from = (table) => {                   // chainable, like supabase-js; only the counting tables have data
    const f = []; let upd = null;
    const run = async () => {
      if (!c.net) return { error: netErr };
      if (upd) {
        const id = (f.find(x => x[0] === "id") || [])[1];
        c.updates.push([id, upd.qty_done]);
        const r = c.rows.find(x => x.progress_id === id); if (r) r.qty_done = upd.qty_done;
        return { data: [{ id, qty_done: upd.qty_done, state: upd.qty_done ? "in_progress" : "not_started" }] };
      }
      if (table === "v_floor_sheets") return { data: c.rows.filter(r => f.every(([k, v]) => r[k] === v)) };
      return { data: [] };
    };
    const q = { select: () => q, eq: (k, v) => { f.push([k, v]); return q; }, in: () => q, neq: () => q, gte: () => q, order: () => q, limit: () => q,
      update: (v) => { upd = v; return q; },
      maybeSingle: async () => c.net ? { data: profile } : { error: netErr },
      then: (res, rej) => run().then(res, rej) };
    return q;
  };
```

#### test_advance.js
```javascript
// Advance (managers): the new tab, end to end. The real index.html in jsdom, talking to the real
// test database through the same login path Supabase uses (pgsupa.js), with advance.sql loaded.
// Run on a fresh seeded database: ../base/fresh.sh ../out/advance.sql && node test_advance.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const NEW = fs.readFileSync("../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const LIVE = fs.readFileSync("../live/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];

function boot(user, { html = NEW, preload = {} } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const byText = (w, sel, re) => $$(w, sel).find(e => re.test(e.textContent));
const row = (w, name) => $$(w, ".advrow").find(r => r.querySelector(".nm").firstChild.textContent.trim() === name);
const shown = (w, name) => Number(row(w, name).querySelector(".n").firstChild.textContent);
const qty = async (proj, sheet, dept) => (await one(`select sp.qty_done from sheet_progress sp join sheets s on s.id = sp.sheet_id
  join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id
  where j.project_id = $1 and s.sheet_number = $2 and sp.department = $3`, [proj, sheet, dept])).qty_done;

(async () => {
  // ================= core =================
  const C = (() => { const m = { exports: {} }; new Function("module", "require", [...NEW.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1])(m, require); return m.exports; })();
  ok("core: managers and the Test Supervisor get Advance; supervisors don't",
     C.canAdvance({ role: "manager" }) && C.canAdvance({ role: "supervisor", is_test: true }) && !C.canAdvance({ role: "supervisor", departments: ["sanding"] }) && !C.canAdvance(null));
  const R = (sheet, dept, done, req) => ({ sheet_id: "s" + sheet, sheet_number: sheet, department: dept, progress_id: `p${sheet}${dept}`, qty_done: done, qty_required: req, job_id: "j" });
  const sheets = C.advSheets([R(2, "metal", 0, 2), R(2, "milling", 2, 2), R(1, "sanding", 0, 3), R(1, "assembly_qc", 0, 3), R(1, "milling", 1, 3), R(1, "cnc", 0, 3), R(1, "metal", 0, 3)]);
  ok("core: rows become sheets in number order, stages in shop order",
     sheets.map(s => s.sheet_number).join() === "1,2" && sheets[0].stages.map(s => s.dept).join() === "milling,cnc,sanding,metal,assembly_qc");
  const st = sheets[0].stages;
  let e = C.advHere(st, "sanding", {});
  ok("core: \"It's here\" at Sanding marks Milling and CNC complete, leaves Sanding alone", e.milling === 3 && e.cnc === 3 && !("sanding" in e) && !("metal" in e));
  e = C.advHere(st, "assembly_qc", {});
  ok("core: \"It's here\" at Assembly / QC fills the wood chain but not Metal (it stands on its own)", e.sanding === 3 && !("metal" in e) && !("assembly_qc" in e));
  ok("core: no \"It's here\" for Milling or Metal (nothing before them)", C.advBefore(st, "milling").length === 0 && C.advBefore(st, "metal").length === 0);
  e = C.advHere(st, "sanding", { milling: 0 });
  ok("core: \"It's here\" only fills — it replaces a lowered edit with complete, never lowers", e.milling === 3);
  ok("core: an edit back to the saved number disappears", Object.keys(C.advTidy(st, { milling: 1, cnc: 2 })).join() === "cnc");
  const ch = C.advChanges(st, { milling: 0, cnc: 2 });
  ok("core: changes list what moves, and flags a lowered count", ch.length === 2 && ch[0].lower && !ch[1].lower && ch[1].from === 0 && ch[1].to === 2);
  const lb = { a: { fn: "advance_sheet", at: "2026-09-23T10:00", args: { p_sheet: "s1", p_counts: { cnc: 1 } } },
               b: { fn: "advance_sheet", at: "2026-09-23T10:05", args: { p_sheet: "s1", p_counts: { cnc: 3, milling: 3 } } },
               c: { fn: "log_defect", at: "2026-09-23T10:06", args: {} } };
  const over = C.withAdvPending([R(1, "cnc", 0, 3), R(1, "milling", 1, 3), R(2, "milling", 2, 2)], lb);
  ok("core: unsent saves show on the counts, newest winning", over[0].qty_done === 3 && over[1].qty_done === 3 && over[2].qty_done === 2);
  const jobs = [{ job_id: "a", project_id: "PROJ-1", is_active: true, has_work_order: true, delivery_date: "2026-10-01" },
                { job_id: "b", project_id: "PROJ-2", is_active: true, has_work_order: true, delivery_date: "2026-12-01" },
                { job_id: "c", project_id: "PROJ-3", is_active: false, has_work_order: true, delivery_date: "2026-09-01" },
                { job_id: "d", project_id: "PROJ-4", is_active: true, has_work_order: false, delivery_date: "2026-09-01" }];
  const aj = C.advJobs(jobs, [{ job_id: "b", department: "metal", level: "priority" }], "");
  ok("core: job list — in production with a work order only; a flag (even one department's) pins first",
     aj.map(j => j.project_id).join() === "PROJ-2,PROJ-1");

  // ================= Mike: byte-for-byte the same screens as the live page =================
  async function mikeScreens(html) {
    const w = boot(users.mike, { html });
    await until(() => /PROJ-00418/.test(txt(w))); await wait(400);
    const out = [];
    const snap = async (name) => { await wait(350); out.push([name, $(w, "#app").innerHTML]); };
    await snap("sanding queue");
    await click(w, "button.job"); await snap("job");
    await click(w, "button.sheet"); await snap("sheet");
    await click(w, "[data-back]"); await click(w, "[data-back]");
    for (const t of ["problems", "log", "supplies", "work"]) { await click(w, `[data-tab="${t}"]`); await snap("tab " + t); }
    await click(w, '[data-dept="finishing"]'); await snap("finishing");
    return out;
  }
  const a = await mikeScreens(LIVE), b = await mikeScreens(NEW);
  const diffs = a.filter(([n, h], i) => h !== b[i][1]).map(([n]) => n);
  ok(`Mike: every screen is identical to the live page (${a.length} screens compared)`, diffs.length === 0 && a.length === 8, diffs.join(", "));
  let w = boot(users.mike, { preload: { sf_adv: "true" } });
  await until(() => /PROJ-00418/.test(txt(w)));
  ok("Mike: no Advance tab, even if a tablet remembered one", !$(w, "[data-adv]") && !/Advance/.test($(w, "header").textContent) && $$(w, ".subtab").length === 4);
  const mr = await makeClient(users.mike).rpc("advance_sheet", { p_sheet: (await one("select id from sheets limit 1")).id, p_counts: { sanding: 1 }, p_client_id: null });
  ok("Mike: the database refuses him too (security isn't the missing button)", !!mr.error && /Only a manager/.test(mr.error.message), mr.error && mr.error.message);

  // ================= Luke =================
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  await makeClient(users.luke).rpc("set_flag", { p_job: j099, p_level: "priority", p_note: "Rush", p_department: "sanding" });
  w = boot(users.luke);
  await until(() => $(w, "[data-adv]"));
  const tabs = $$(w, ".tab").map(t => t.textContent);
  ok("Luke: Advance is the last tab, after the eight departments", tabs.length === 9 && tabs[8] === "Advance", tabs.join(","));
  await click(w, "[data-adv]");
  await until(() => $$(w, "[data-advjob]").length);
  const list = $$(w, "[data-advjob]").map(b => b.textContent.replace(/\s+/g, " "));
  ok("Luke: jobs in production with a work order — flagged PROJ-00099 first, no test jobs, no Delivery or Pre-Production",
     list.length === 2 && /PROJ-00099/.test(list[0]) && /Priority — Rush/.test(list[0]) && /PROJ-00418/.test(list[1]), list.join(" | "));
  const f = $(w, "[data-advfilter]"); f.value = "418"; f.dispatchEvent(new w.Event("input")); await wait(60);
  ok("Luke: typing narrows the list, and the box keeps focus", $$(w, "[data-advjob]").length === 1 && w.document.activeElement === $(w, "[data-advfilter]"));
  await click(w, "[data-advjob]");
  await until(() => $$(w, "[data-advsheet]").length === 9);
  const s4 = $$(w, "[data-advsheet]")[3];
  ok("Luke: 9 sheets, each showing every department's count",
     $$(w, "[data-advsheet]").length === 9 && /Milling 3\/3/.test(s4.textContent) && /Sanding 0\/3/.test(s4.textContent) && /Metal 0\/3/.test(s4.textContent), s4.textContent.replace(/\s+/g, " "));
  ok("Luke: complete stages are turquoise, the rest plain", s4.querySelectorAll(".stg.done").length === 2 && s4.querySelectorAll(".stg.part").length === 0);
  await click(w, s4);
  ok("Luke: sheet 4 opens, wood stages in order, Metal on its own",
     /Sheet 4/.test($(w, "h1").textContent) && $$(w, ".advrow").length === 6 && /In order/.test(txt(w)) && /On their own/.test(txt(w)));
  ok("Luke: \"It's here\" on CNC to Assembly / QC only; none on Milling or Metal",
     !row(w, "Milling").querySelector("[data-advhere]") && !row(w, "Metal").querySelector("[data-advhere]") && !!row(w, "Finishing").querySelector("[data-advhere]"));
  ok("Luke: nothing to save yet", !$(w, "[data-advsave]") && /Nothing changes until you press Save/.test(txt(w)));
  await click(w, row(w, "Finishing").querySelector("[data-advhere]"));
  ok("Luke: \"It's here\" at Finishing fills Sanding to 3, and Finishing is untouched", shown(w, "Sanding") === 3 && shown(w, "Finishing") === 0);
  ok("Luke: the save bar says exactly what will change", /Will save: Sanding 0 → 3/.test(txt(w)) && !/lowers a count/.test(txt(w)));
  ok("Luke: nothing reached the database before Save", await qty("PROJ-00418", 4, "sanding") === 0);
  await click(w, row(w, "Finishing").querySelector("[data-advstep='1']"));
  await click(w, "[data-advsave]", 50);
  await until(async () => await qty("PROJ-00418", 4, "finishing") === 1);
  ok("Luke: Save sends both at once — Sanding 3, Finishing 1", await qty("PROJ-00418", 4, "sanding") === 3 && await qty("PROJ-00418", 4, "finishing") === 1);
  const ev = await one(`select count(*)::int n, bool_and(e.actor = $1) mine from progress_events e join sheets s on s.id = e.sheet_id join work_orders wo on wo.id = s.work_order_id
    join jobs j on j.id = wo.job_id where j.project_id = 'PROJ-00418' and s.sheet_number = 4 and e.source = 'Manager adjustment'`, [users.luke.id]);
  ok("Luke: the history has both, under his name, labelled Manager adjustment", ev.n === 2 && ev.mine, JSON.stringify(ev));
  await until(() => /Saved\./.test(($(w, ".toast") || {}).textContent || ""));
  ok("Luke: a plain confirmation shows", /PROJ-00418 sheet 4: Sanding 0 → 3 of 3, Finishing 0 → 1 of 3\. Saved\./.test($(w, ".toast").textContent), ($(w, ".toast") || {}).textContent);
  await until(() => shown(w, "Finishing") === 1 && !$(w, "[data-advsave]"));
  ok("Luke: the screen shows the saved counts, and the save bar is gone", shown(w, "Sanding") === 3 && shown(w, "Finishing") === 1 && !$(w, "[data-advsave]"));

  // lowering asks first
  await click(w, row(w, "CNC").querySelector("[data-advstep='-1']"));
  ok("Luke: lowering is flagged in the save bar", /CNC 3 → 2/.test(txt(w)) && /lowers a count/.test(txt(w)));
  await click(w, "[data-advsave]");
  ok("Luke: Save asks \"Lower a count?\" first", /Lower a count\?/.test($(w, ".mdl").textContent) && /CNC goes from 3 back to 2/.test($(w, ".mdl").textContent));
  await click(w, ".mdl [data-close].btn");
  ok("Luke: Cancel changes nothing, and keeps the edit", await qty("PROJ-00418", 4, "cnc") === 3 && shown(w, "CNC") === 2);
  await click(w, "[data-advsave]"); await click(w, "[data-confirm]", 50);
  await until(async () => await qty("PROJ-00418", 4, "cnc") === 2);
  ok("Luke: confirmed, CNC is lowered to 2", await qty("PROJ-00418", 4, "cnc") === 2);

  // leaving with unsaved changes
  await until(() => !$(w, "[data-advsave]"));
  await click(w, row(w, "Metal").querySelector("[data-advall]"));
  ok("Luke: All done sets Metal to 3 of 3", shown(w, "Metal") === 3 && /Metal 0 → 3/.test(txt(w)));
  await click(w, $$(w, "[data-advgo]")[1]);
  ok("Luke: moving to the next sheet with changes asks first", /Leave without saving\?/.test(($(w, ".mdl") || {}).textContent || ""));
  await click(w, ".mdl [data-close].btn");
  ok("Luke: Cancel stays on sheet 4 with the change", /Sheet 4/.test($(w, "h1").textContent) && shown(w, "Metal") === 3);
  await click(w, $$(w, "[data-advgo]")[1]); await click(w, "[data-confirm]");
  ok("Luke: leaving drops the change — sheet 5 open, Metal on sheet 4 never saved",
     /Sheet 5/.test($(w, "h1").textContent) && await qty("PROJ-00418", 4, "metal") === 0 && !$(w, "[data-advsave]"));

  // offline
  setOffline(true);
  await click(w, row(w, "Sanding").querySelector("[data-advall]"));
  await click(w, "[data-advsave]", 150);
  ok("Luke, offline: the save waits on the tablet", /1 entry waiting to send/.test($(w, ".sync").textContent) && await qty("PROJ-00418", 5, "sanding") === 0);
  ok("Luke, offline: the screen already shows it", shown(w, "Sanding") === 3 && !$(w, "[data-advsave]"));
  await click(w, "[data-advback]");
  ok("Luke, offline: ...and so does the job's sheet list", /Sanding 3\/3/.test($$(w, "[data-advsheet]")[4].textContent));
  setOffline(false);
  w.dispatchEvent(new w.Event("online"));
  await until(async () => await qty("PROJ-00418", 5, "sanding") === 3);
  await until(() => /All saved/.test($(w, ".sync").textContent));
  ok("Luke: back online, it sends by itself — once", await qty("PROJ-00418", 5, "sanding") === 3 && /All saved/.test($(w, ".sync").textContent)
     && (await one("select count(*)::int n from sheet_adjustments a join sheets s on s.id = a.sheet_id where s.sheet_number = 5 and not a.is_test")).n === 1);

  // departments and coming back
  await click(w, '[data-dept="sanding"]', 300);
  ok("Luke: a department tab leaves Advance for that department's queue", !$(w, ".advjob") && /Sanding/.test($(w, "h1").textContent) && $(w, '[data-dept="sanding"]').getAttribute("aria-current") === "true");
  await click(w, "[data-adv]", 300);
  ok("Luke: back to Advance reopens the job he was on", $$(w, "[data-advsheet]").length === 9 && /PROJ-00418/.test($(w, "h1").textContent));
  await click(w, "[data-adv]", 300);
  ok("Luke: tapping Advance again goes to the job list (his search, 418, still in the box)", $$(w, "[data-advjob]").length === 1 && $(w, "[data-advfilter]").value === "418");
  const w2 = boot(users.luke, { preload: { sf_adv: w.localStorage.getItem("sf_adv") } });
  await until(() => $$(w2, "[data-advjob]").length === 2);
  ok("Luke: the tablet reopens on Advance where he left it", $(w2, "[data-adv]").getAttribute("aria-current") === "true" && /Pick a job/.test(txt(w2)));

  // ================= the Test Supervisor =================
  w = boot(users.test);
  await until(() => $(w, "[data-adv]"));
  await click(w, "[data-adv]");
  await until(() => $$(w, "[data-advjob]").length);
  const tl = $$(w, "[data-advjob]").map(b => b.textContent.replace(/\s+/g, " "));
  ok("Test Supervisor: only test jobs", tl.length === 1 && /TEST.*TEST-00418/.test(tl[0]), tl.join(" | "));
  await click(w, "[data-advjob]");
  await until(() => $$(w, "[data-advsheet]").length === 9);
  await click(w, $$(w, "[data-advsheet]")[6]);
  await click(w, row(w, "Assembly / QC").querySelector("[data-advhere]"));
  await click(w, "[data-advsave]");
  await until(async () => await qty("TEST-00418", 7, "finishing") === 4);
  ok("Test Supervisor: moves a test sheet along (Sanding and Finishing to 4 of 4)",
     await qty("TEST-00418", 7, "sanding") === 4 && await qty("TEST-00418", 7, "finishing") === 4 && await qty("PROJ-00418", 7, "finishing") === 0);

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### snap_adv.js
```javascript
// Drive the real page (jsdom + the test database) to each Advance screen, save it as static HTML, then photograph it in Chromium.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { chromium } = require("playwright");
const { makeClient, users } = require("./pgsupa");
const html = fs.readFileSync("../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const fontCss = ["barlow/400", "barlow/500", "barlow/600", "barlow/700", "barlow-condensed/600", "barlow-condensed/700"].map(p => {
  const [fam, wt] = p.split("/"); const file = `node_modules/@fontsource/${fam}/files/${fam}-latin-${wt}-normal.woff2`;
  return `@font-face{font-family:'${fam === "barlow" ? "Barlow" : "Barlow Condensed"}';font-weight:${wt};src:url(data:font/woff2;base64,${fs.readFileSync(file).toString("base64")})}`;
}).join("");
(async () => {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory();
  w.supabase = { createClient: () => makeClient(users.luke) };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  const $ = (s) => w.document.querySelector(s), $$ = (s) => [...w.document.querySelectorAll(s)];
  const shots = [];
  const save = (name) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
    shots.push([name, "<!DOCTYPE html>" + d.outerHTML.replace("<style>", "<style>" + fontCss)]); };
  await wait(1500); $("[data-adv]").click(); await wait(800); save("1-jobs");
  $$("[data-advjob]").find(b => /00418/.test(b.textContent)).click(); await wait(800); save("2-sheets");
  $$("[data-advsheet]")[3].click(); await wait(400); save("3-sheet");
  $$(".advrow").find(r => /Finishing/.test(r.textContent)).querySelector("[data-advhere]").click(); await wait(100);
  $$(".advrow").find(r => /^CNC/.test(r.textContent.trim())).querySelector("[data-advstep='-1']").click(); await wait(100); save("4-changes");
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [vw, vh, tag] of [[1280, 800, "land"], [800, 1280, "port"]]) {
    const p = await b.newPage({ viewport: { width: vw, height: vh } });
    for (const [n, h] of shots) { await p.setContent(h, { waitUntil: "load" }); await p.waitForTimeout(150); await p.screenshot({ path: `/tmp/adv_${n}_${tag}.png` }); }
  }
  await b.close(); console.log("shots:", shots.map(s => s[0]).join(", ")); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks_advance.py (run from the folder above `out/`, on a loaded database)
```python
import subprocess, re
src = open('out/advance.sql').read()
fn = src[src.index('create or replace function advance_sheet'):src.index('-- ---------------------------------------------------------------------\n-- 3. check_advance()')]
P = ['psql','-h','/tmp/pg','-p','5433','-U','postgres','-d','sync','-At','-v','ON_ERROR_STOP=1']
def run(sql): return subprocess.run(P+['-c',sql],capture_output=True,text=True)
breaks = {
 'supervisors allowed':      (fn.replace("if not v_mgr and not v_test then", "if false then"), 8),
 'no lane check':            (fn.replace("if s.is_test <> v_test then", "if false then"), 7),
 'resend applied twice':     (fn.replace("select summary into v_prev from sheet_adjustments where client_id = v_client;\n  if found then", "if false then").replace("on conflict (client_id) do nothing;\n  if not found then", "on conflict (client_id) do nothing;\n  if false then").replace("v_client  uuid := coalesce(p_client_id, gen_random_uuid());","v_client  uuid := gen_random_uuid();"), 4),
 'no history label':         (fn.replace("perform set_config('shopfloor.source', 'Manager adjustment', true);", ""), 3),
 'unknown dept accepted':    (fn.replace("raise exception 'Sheet % has no % work on it.', s.sheet_number, coalesce((select name from departments where key = k), k);", "continue;"), 6),
}
for name,(body,row) in breaks.items():
    assert body != fn, name
    r = run(body)
    assert r.returncode == 0, r.stderr
    out = run("select step from check_advance() where result <> 'PASS'").stdout.split()
    print(f"{name:26s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    run(fn)
# a grant break
run("grant insert on sheet_adjustments to authenticated")
out = run("select step from check_advance() where result <> 'PASS'").stdout.split()
print(f"{'direct insert allowed':26s} expected row 10: failed rows {out} ->", 'CAUGHT' if '10' in out else 'MISSED')
run("revoke insert on sheet_adjustments from authenticated")
print('restored:', run("select count(*) from check_advance() where result='PASS'").stdout.strip(), 'PASS')
```
