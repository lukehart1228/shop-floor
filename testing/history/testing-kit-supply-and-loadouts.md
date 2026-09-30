# Testing kit — Parts 6 and 7: supply lists, the Arrow tab, one-line job names; load-outs v2 (24 Sep)

*Part 7 (load-outs v2) is at the end. Part 6 first.*

*For build chats. Luke doesn't need to read this.* Parts 1–5 still apply (environment, "test as a real login", jsdom gaps). Part 5's `load.sh` / `fresh.sh` are unchanged.

This build added `supply_lists.sql` (table `supply_items`, `set_supply_item()`, `move_supply_item()`, `retire_supply_item()`, the starting lists, `check_supply_lists()`) and changed `index.html` and `office.html`. Tested on a database built from **every live SQL file, unchanged**, plus `advance.sql` and `supply_lists.sql`, each loaded twice.

## Setup notes

- `apt-get update` **must succeed before** the Postgres install. In this chat the nodesource repo gave 403 and the chained `apt-get update && apt-get install` silently installed nothing; run them as two commands.
- `/bin/sh` is not bash: `mkdir -p w/{a,b}` makes one folder literally called `{a,b}`. Spell folders out.
- **`pgsupa.js` now sends `jsonb` arguments as JSON**, as Supabase does. Before, a JavaScript array went to Postgres as a Postgres array, which a `jsonb` parameter can't take (it mattered for `p_choices: []`). The change looks up each function's argument types once (below). Advance's object arguments were already fine.
- The office's Setup page **never shows the answer banner** (`msgBanner()` isn't on it); the defect lists have that gap still. Supply-list answers show inside the panel (`S.msgFrom === "sup"`).
- **Stale suites:** Part 3's `test_office_e2e.js` and `test_office_photos.js` expect the office's pre-Needs-you tabs and fail on the live page too. Use Part 4's `test_needs.js` (Chromium, `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`, needs a `page.png` placeholder — any 1980×1530 PNG) for the office.
- Part 3's retyped `test_app_e2e.js` still counted all `.tab`s for the Test Supervisor (9 with Advance). Now `.tab[data-dept]`; it failed on the old page too before that.
- `test_advance.js`: its "typing narrows the list" row was timing-flaky on the old page too (a 60 ms wait). It now waits for the list. Its row *"Mike: every screen is identical to the live page"* now fails **on purpose** (the materials chip, the one-line name, the Sanding list); `test_supply_lists.js` replaces it with "only the intended differences".

## Results when delivered

| Suite | Result |
|---|---|
| `check_supply_lists()`, loaded twice | 10 PASS, nothing left behind; the starting lists added once (14 items) |
| `check_supply_lists()` against 10 deliberate breaks (`breaks_supply.py`) | each caught at its own row |
| `check_floor()` / `check_photos()` / `check_advance()` beside it | 18 / 16 / 10 PASS |
| `test_supply_lists.js` — core; Mike's 8 screens differ from the current page only as intended (Finishing's Supplies byte-for-byte the same); Sanding's list, grit, send; Something else; offline; Full Custom's two sets; the Arrow tab and its count; Delivery, Milling; the office's add / two sets / duplicate / half-filled set / edit / move / retire / bring back; a supervisor refused | 63 PASS |
| `NOSQL=1 test_supply_lists.js` on a database **without** `supply_lists.sql` | 3 PASS: the tablet keeps the typed box, no warning; the office says run `supply_lists.sql` |
| `test_app_e2e.js` (`SUPPLY=1 PHOTOS=1 ADVANCE=1`) | 72 PASS (the old page, without `SUPPLY`: 67) |
| `test_app_core.js` | 19 PASS |
| `test_photos_e2e.js` | 41 PASS |
| `test_advance.js` | 45 PASS, 1 FAIL on purpose (above) |
| `test_needs.js` (`SRC=../out`) | 43 PASS (old pages: 43) |
| `snap_supply.js` — the queue with a long name, Sanding's pick, Plywood, Metal's Arrow tab, the office panel, at 1280×800 and 800×1280 | looked at: the name fits sideways and cuts with … upright; the chips wrap; the office form fits |

Run order: `cd t && ../base/fresh.sh ../base/advance.sql ../out/supply_lists.sql && node <suite>.js`. A fresh database for each suite.

Not covered: a real Android tablet and the real SQL Editor (Walkthrough 10).

## Files

#### pgsupa.js — the change (insert before `isSetReturning`, and use it in `client.rpc`)
```javascript
const jsonArgs = new Map();
// Supabase sends every argument as JSON, so a jsonb parameter gets a real JSON array; node-pg would send a Postgres array instead
async function jsonParams(fn) {
  if (!jsonArgs.has(fn)) {
    const r = await admin.query(`select unnest(proargnames) n, unnest(proargtypes::regtype[]::text[]) t from pg_proc
                                  where proname = $1 and pronamespace = 'public'::regnamespace`, [fn]);
    jsonArgs.set(fn, new Set(r.rows.filter(x => x.t === "jsonb" || x.t === "json").map(x => x.n)));
  }
  return jsonArgs.get(fn);
}
// in client.rpc, replacing `const params = names.map(n => args[n]);`:
    const js = await jsonParams(fn);
    const params = names.map(n => js.has(n) && args[n] !== null && args[n] !== undefined ? JSON.stringify(args[n]) : args[n]);
```

#### patch_e2e.py — applies the `SUPPLY=1` expectations to Part 3's `test_app_e2e.js` (run in `t/`)
```python
p='test_app_e2e.js'; s=open(p).read()
def rep(a,b):
    global s
    assert s.count(a)==1,(s.count(a),a[:70]); s=s.replace(a,b)
rep('const PHOTOS = !!process.env.PHOTOS;','const PHOTOS = !!process.env.PHOTOS;\nconst SUPPLY = !!process.env.SUPPLY;   // supply lists + Arrow tab + no materials chip (24 Sep)')
rep('''  ok("materials warning still shows (PROJ-00418 not ordered)", /Materials not ordered yet/.test(cards[0].textContent));''',
'''  if (SUPPLY) ok("no materials warning any more (Monday's column isn't used)", !/Materials not ordered/.test(txt(w)));
  else ok("materials warning still shows (PROJ-00418 not ordered)", /Materials not ordered yet/.test(cards[0].textContent));''')
rep('''  ok("Supplies: nothing open yet, then the box", /Nothing on order for Sanding/.test(txt(w)) && !!$(w, "#supItem") && $(w, "[data-ssend]").disabled);
  type(w, "#supItem", "120 grit discs, 6 inch");''','''  if (SUPPLY) {
    await until(() => $$(w, "[data-spick]").length === 8);
    ok("Supplies: nothing open yet, Sanding's list (7 and Something else), no box until asked", /Nothing on order for Sanding/.test(txt(w))
       && $$(w, "[data-spick]").map(b => b.textContent.trim()).join("|") === "Sandpaper|Hand sandpaper|Epoxy|Dye|Cups|Stir sticks|Gloves|Something else"
       && !$(w, "#supItem") && $(w, "[data-ssend]").disabled);
    await click(w, byText(w, "[data-spick]", /Something else/));
    ok("Something else opens the typed box", !!$(w, "#supItem"));
  } else
  ok("Supplies: nothing open yet, then the box", /Nothing on order for Sanding/.test(txt(w)) && !!$(w, "#supItem") && $(w, "[data-ssend]").disabled);
  type(w, "#supItem", "120 grit discs, 6 inch");''')
rep('''  ok("...and the box is cleared for the next one", $(w, "#supItem").value === "" && $(w, ".card .qty .n").textContent === "1");''',
'''  if (SUPPLY) ok("...and the form is cleared for the next one", !$(w, "#supItem") && !$(w, '[data-spick][aria-pressed="true"]') && $(w, ".card .qty .n").textContent === "1");
  else ok("...and the box is cleared for the next one", $(w, "#supItem").value === "" && $(w, ".card .qty .n").textContent === "1");''')
rep('''  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /At Arrow now/.test(txt(w)));
  ok("Metal's log has At Arrow", /At Arrow now.*Nothing at Arrow right now/.test(txt(w)));''','''  if (SUPPLY) {
    await until(() => $$(w, ".subtab").length === 5);
    ok("Willie: Arrow is its own area — Work orders · Arrow · Problems · Log · Supplies",
       $$(w, ".subtab").map(b => b.textContent.replace(/\\d+$/, "")).join(" · ") === "Work orders · Arrow · Problems · Log · Supplies");
    await click(w, '[data-tab="log"]', 150);
    await until(() => /Routine tasks/.test(txt(w)));
    ok("...and it's out of Metal's Log", !/At Arrow/.test(txt(w)) && !$(w, "[data-aropen]"));
    await click(w, '[data-tab="arrow"]', 150);
    await until(() => /At Arrow now/.test(txt(w)));
    ok("Metal's Arrow tab: nothing out yet", /At Arrow now.*Nothing at Arrow right now/.test(txt(w)) && !$(w, '[data-tab="arrow"] .c'));
  } else {
  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /At Arrow now/.test(txt(w)));
  ok("Metal's log has At Arrow", /At Arrow now.*Nothing at Arrow right now/.test(txt(w)));
  }''')
rep('''  await click(w, '[data-tab="problems"]', 50); await click(w, '[data-tab="log"]', 50);
  await until(() => /5 days out/.test(txt(w)));''','''  if (SUPPLY) ok("the Arrow tab counts what's out: 1", ($(w, '[data-tab="arrow"] .c') || {}).textContent === "1");
  await click(w, '[data-tab="problems"]', 50); await click(w, SUPPLY ? '[data-tab="arrow"]' : '[data-tab="log"]', 50);
  await until(() => /5 days out/.test(txt(w)));''')
rep('''  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /Look up a job/.test(txt(w)) && /At Arrow now/.test(txt(w)));
  ok("Assembly / QC's log has At Arrow and QC", true);''','''  if (SUPPLY) {
    await until(() => $$(w, ".subtab").length === 5);
    await click(w, '[data-tab="log"]', 150);
    await until(() => /Look up a job/.test(txt(w)));
    ok("Assembly / QC's log has QC, and Arrow is its own tab", !/At Arrow/.test(txt(w)) && !!$(w, '[data-tab="arrow"]'));
  } else {
  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /Look up a job/.test(txt(w)) && /At Arrow now/.test(txt(w)));
  ok("Assembly / QC's log has At Arrow and QC", true);
  }''')
rep('''=== "Load-out · Problems · Log",''','''=== (SUPPLY ? "Load-out · Arrow · Problems · Log" : "Load-out · Problems · Log"),''')
rep('''  await until(() => /At Arrow now/.test(txt(w)) && /Defects/.test(txt(w)));
  await click(w, '[data-defect="pick"]');''','''  await until(() => (SUPPLY || /At Arrow now/.test(txt(w))) && /Defects/.test(txt(w)));
  if (SUPPLY) ok("Delivery's Log no longer holds Arrow", !/At Arrow/.test(txt(w)));
  await click(w, '[data-defect="pick"]');''')
rep('''$$(w, ".tab").length === 8);''','''$$(w, ".tab[data-dept]").length === 8);''')
open(p,'w').write(s); print('patched')
```

#### test_supply_lists.js
```javascript
// Supply lists, the Arrow tab, the one-line job name and no materials chip (24 Sep).
// The real index.html and office.html in jsdom, talking to the real test database through the same
// login path Supabase uses (pgsupa.js). Run on a fresh database:
//   ../base/fresh.sh ../base/advance.sql ../out/supply_lists.sql && node test_supply_lists.js
// With NOSQL=1 (a fresh database WITHOUT supply_lists.sql) it runs only the "before the SQL is run" checks.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"><\/script>/, "");
const NEW = strip(fs.readFileSync("../out/index.html", "utf8"));
const LIVE = strip(fs.readFileSync("../live/index.html", "utf8"));
const OFFICE = strip(fs.readFileSync("../out/office.html", "utf8"));
const NOSQL = !!process.env.NOSQL;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];

function bootTablet(user, { html = NEW, preload = {} } = {}) {
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
function bootOffice(user) {
  const client = makeClient(user);
  const dom = new JSDOM(OFFICE, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  w.localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
  w.localStorage.setItem("sfo_tab", JSON.stringify("setup"));
  w.supabase = { createClient: () => client };
  w.confirm = () => true; w.scrollTo = () => {}; w.TextEncoder = TextEncoder; w.Blob = Blob;
  w.eval([...OFFICE.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const byText = (w, sel, re) => $$(w, sel).find(e => re.test(e.textContent));
function type(w, sel, v) { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = v; el.dispatchEvent(new w.Event("input")); }
const chips = (w) => $$(w, "[data-spick]").map(b => b.textContent.trim());
async function officeTab(w, name) { await click(w, `.tab[data-tab="${name}"]`, 30); await until(() => $(w, `.tab[data-tab="${name}"][aria-current="true"]`)); await wait(300); }
const supDetails = (w, d) => $(w, `details[data-keep="sup_${d}"]`);
const itemRow = (w, d, name) => [...supDetails(w, d).querySelectorAll(".typ")].find(r => r.querySelector("span").firstChild.textContent.trim() === name);

(async () => {
  if (NOSQL) {
    // ================= before supply_lists.sql is run =================
    let w = bootTablet(users.mike);
    await until(() => /PROJ-00418/.test(txt(w)));
    await click(w, '[data-tab="supplies"]', 400);
    ok("tablet, no SQL yet: Supplies shows the typed box as before, no warning", !!$(w, "#supItem") && !$$(w, "[data-spick]").length && !/isn't set up/.test(txt(w)));
    type(w, "#supItem", "Tape");
    await click(w, "[data-ssend]", 50);
    await until(async () => (await one("select count(*)::int n from supply_requests")).n === 1);
    ok("...and a typed request still sends", (await one("select item from supply_requests")).item === "Tape");
    w = bootOffice(users.luke);
    await until(() => /Run supply_lists/.test(txt(w)), 6000);
    ok("office, no SQL yet: the Supply lists panel says to run supply_lists.sql", /Run supply_lists\.sql/.test(txt(w)) && !/isn't set up in the database yet\. Tell/.test(txt(w)));
    console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  // ================= core =================
  const coreOf = (html) => { const m = { exports: {} }; new Function("module", "require", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1])(m, require); return m.exports; };
  const C = coreOf(NEW), O = coreOf(OFFICE);
  const ply = { id: "p", name: "Plywood", department: "full_custom", sort_order: 1, retired: false,
                choices: [{ label: "Wood", options: ["Ash", "White Oak"] }, { label: "Thickness", options: ["3/4", "3/4 MDF"] }] };
  ok("core: nothing picked → both choices missing, no wording yet", C.supplyMissing(ply, {}).join() === "Wood,Thickness" && C.supplyText(ply, {}) === null);
  ok("core: one picked → the other is missing", C.supplyMissing(ply, { 0: "White Oak" }).join() === "Thickness" && C.supplyText(ply, { 0: "White Oak" }) === null);
  ok("core: both picked → \"Plywood — White Oak, 3/4 MDF\"", C.supplyText(ply, { 0: "White Oak", 1: "3/4 MDF" }) === "Plywood — White Oak, 3/4 MDF");
  ok("core: an item without choices is just its name", C.supplyText({ name: "Glue", choices: [] }, {}) === "Glue");
  ok("core: a department's list — its own, live, in order", C.supplyItemsFor([{ department: "sanding", name: "B", sort_order: 2 }, { department: "sanding", name: "A", sort_order: 1 },
      { department: "sanding", name: "Old", sort_order: 0, retired: true }, { department: "milling", name: "Glue", sort_order: 1 }], "sanding").map(i => i.name).join() === "A,B");
  ok("core: Arrow is its own area for Metal, Assembly / QC and Delivery only",
     C.tabsFor("metal").join() === "work,arrow,problems,log,supplies" && C.tabsFor("assembly_qc").join() === "work,arrow,problems,log,supplies"
     && C.tabsFor("delivery").join() === "loadout,arrow,problems,log" && C.tabsFor("sanding").join() === "work,problems,log,supplies");
  ok("office core: choices typed with commas are tidied", O.parseOptions(" Ash, Maple ,, White Oak ,").join("|") === "Ash|Maple|White Oak");
  ok("office core: a blank row is skipped; a half-filled one is kept (so the database can say what's missing)",
     JSON.stringify(O.choicesFromForm([{ label: "", options: "" }, { label: "Size", options: "S, L" }])) === '[{"label":"Size","options":["S","L"]}]'
     && O.choicesFromForm([{ label: "Size", options: "" }]).length === 1);
  ok("office core: the one-line summary", O.choiceSummary(ply.choices) === "Wood: Ash, White Oak · Thickness: 3/4, 3/4 MDF");

  // ================= Mike: only the intended differences =================
  async function mikeScreens(html) {
    const w = bootTablet(users.mike, { html });
    await until(() => /PROJ-00418/.test(txt(w))); await wait(400);
    const out = [];
    const snap = async (name) => { await wait(350); out.push([name, $(w, "#app").innerHTML]); };
    await snap("sanding queue");
    await click(w, "button.job"); await snap("job");
    await click(w, "button.sheet"); await snap("sheet");
    await click(w, "[data-back]"); await click(w, "[data-back]");
    for (const t of ["problems", "log", "work"]) { await click(w, `[data-tab="${t}"]`); await snap("tab " + t); }
    await click(w, '[data-dept="finishing"]'); await snap("finishing");
    await click(w, '[data-tab="supplies"]'); await snap("finishing supplies");
    return out;
  }
  const intended = (h) => h.replace(/<span class="jname">([^<]*)<\/span>/g, '<span class="jname" title="$1">$1</span>')
    .replace(/<div class="marks"><span class="chip">Materials not ordered yet<\/span><\/div>/g, "")
    .replace(/\s*<div class="banner warn">Materials for this job haven't been marked as ordered in Monday yet\.<\/div>/g, "")
    .replace(/\s+/g, " ");
  const a = await mikeScreens(LIVE), b = await mikeScreens(NEW);
  const diffs = a.filter(([n, h], i) => intended(h) !== b[i][1].replace(/\s+/g, " ")).map(([n]) => n);
  ok(`Mike: ${a.length} screens differ from the current page only by the materials chip, the banner and the job-name tooltip`, diffs.length === 0 && a.length === 8, diffs.join(", "));
  ok("Mike: Finishing has no list, so its Supplies form is exactly as before", a[7][1] === b[7][1]);
  if (a[7][1] !== b[7][1]) { fs.writeFileSync("/tmp/fin_old.html", a[7][1].replace(/></g, ">\n<")); fs.writeFileSync("/tmp/fin_new.html", b[7][1].replace(/></g, ">\n<")); }

  // ================= Mike: Sanding's list =================
  let w = bootTablet(users.mike);
  await until(() => /PROJ-00418/.test(txt(w)));
  ok("Mike: no materials chip on the queue", !/Materials not ordered/.test(txt(w)) && !$(w, ".job .chip"));
  ok("Mike: the job name sits on one line, cut with … (nowrap, ellipsis, can shrink)",
     /\.jname\{[^}]*white-space:nowrap[^}]*text-overflow:ellipsis/.test(NEW) && /\.job-top\{display:flex; gap:12px; align-items:baseline\}/.test(NEW) && $(w, ".jname").title === $(w, ".jname").textContent);
  await click(w, '[data-tab="supplies"]');
  await until(() => $$(w, "[data-spick]").length === 8);
  ok("Mike: Sanding's list as buttons, then Something else", chips(w).join("|") === "Sandpaper|Hand sandpaper|Epoxy|Dye|Cups|Stir sticks|Gloves|Something else");
  ok("...no typed box, and Send is off until something is picked", !$(w, "#supItem") && $(w, "[data-ssend]").disabled);
  await click(w, byText(w, "[data-spick]", /^Sandpaper$/));
  ok("tap Sandpaper: the four grits appear, Send stays off, it says what's missing",
     $$(w, "[data-schoice]").map(b => b.textContent).join("|") === "80 grit|100 grit|120 grit|150 grit" && $(w, "[data-ssend]").disabled && /Pick the grit/.test(txt(w)));
  await click(w, byText(w, "[data-schoice]", /120 grit/));
  await click(w, '[data-snew="1"]');
  ok("pick 120 grit and make it 2: it shows exactly what will be sent", /2 × Sandpaper — 120 grit/.test($(w, ".swhat").textContent) && !$(w, "[data-ssend]").disabled);
  await click(w, "[data-ssend]", 50);
  await until(async () => (await one("select count(*)::int n from supply_requests")).n === 1);
  const r1 = await one("select item, qty, department, requested_by_name from supply_requests");
  ok("sent: \"Sandpaper — 120 grit\", 2, Sanding, Mike B", r1.item === "Sandpaper — 120 grit" && r1.qty === 2 && r1.department === "sanding" && r1.requested_by_name === "Mike B", JSON.stringify(r1));
  await until(() => /Waiting on the office/.test(txt(w)));
  ok("...it sits in Open above, and the form is cleared", /Sandpaper — 120 grit.*Waiting on the office/.test(txt(w)) && !$(w, '[data-spick][aria-pressed="true"]') && !$(w, "[data-schoice]") && $(w, ".card .qty .n").textContent === "1");
  await click(w, byText(w, "[data-spick]", /^Gloves$/));
  await click(w, byText(w, "[data-spick]", /^Gloves$/));
  ok("tapping a picked item again un-picks it", !$(w, '[data-spick][aria-pressed="true"]') && $(w, "[data-ssend]").disabled);
  await click(w, byText(w, "[data-spick]", /^Gloves$/));
  ok("an item with no choices is ready at once: 1 × Gloves", /1 × Gloves/.test($(w, ".swhat").textContent) && !$(w, "[data-ssend]").disabled);
  await click(w, byText(w, "[data-spick]", /Something else/));
  ok("Something else: the typed box, empty; Send off until something's typed", !!$(w, "#supItem") && $(w, "#supItem").value === "" && $(w, "[data-ssend]").disabled && !$(w, ".swhat"));
  type(w, "#supItem", "Tack cloths");
  ok("...typing turns Send on", !$(w, "[data-ssend]").disabled);
  await click(w, "[data-ssend]", 50);
  await until(async () => (await one("select count(*)::int n from supply_requests")).n === 2);
  ok("...and it sends as typed", !!(await one("select 1 x from supply_requests where item = 'Tack cloths'")));
  await click(w, byText(w, "[data-spick]", /^Sandpaper$/));
  await click(w, '[data-dept="finishing"]', 300);
  await click(w, '[data-tab="supplies"]', 300);
  ok("switching to Finishing: no list there, the plain box, nothing carried over", !$$(w, "[data-spick]").length && !!$(w, "#supItem") && $(w, "#supItem").value === "");
  await click(w, '[data-dept="sanding"]', 300);
  await until(() => $$(w, "[data-spick]").length === 8);
  ok("back on Sanding: nothing picked", !$(w, '[data-spick][aria-pressed="true"]'));

  // offline: the list comes from the tablet's copy, and the pick waits to send
  setOffline(true);
  const w2 = bootTablet(users.mike, { preload: Object.fromEntries(Object.entries(w.localStorage).filter(([k]) => /^sf_/.test(k))) });
  await until(() => $$(w2, ".subtab").length > 0, 5000);
  await click(w2, '[data-tab="supplies"]', 400);
  await until(() => $$(w2, "[data-spick]").length === 8);
  ok("offline: the list still shows (the tablet's saved copy)", chips(w2).length === 8);
  await click(w2, byText(w2, "[data-spick]", /^Epoxy$/));
  await click(w2, "[data-ssend]", 150);
  ok("offline: the request waits on the tablet", /1 entry waiting to send/.test($(w2, ".sync").textContent) && (await one("select count(*)::int n from supply_requests")).n === 2);
  setOffline(false);
  w2.dispatchEvent(new w2.Event("online"));
  await until(async () => (await one("select count(*)::int n from supply_requests")).n === 3, 6000);
  ok("back online: it sends by itself, as \"Epoxy\"", !!(await one("select 1 x from supply_requests where item = 'Epoxy'")));
  w.close(); w2.close();

  // ================= Full Custom (a manager's tablet): two sets of choices =================
  w = bootTablet(users.luke, { preload: { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("supplies") } });
  await until(() => $$(w, "[data-spick]").length === 2, 6000);
  ok("Full Custom: Plywood and Something else", chips(w).join("|") === "Plywood|Something else");
  await click(w, byText(w, "[data-spick]", /Plywood/));
  ok("Plywood: Wood (5) and Thickness (4)", $$(w, ".sgroup").map(g => g.textContent).join("|") === "Wood|Thickness"
     && $$(w, '[data-schoice="0"]').length === 5 && $$(w, '[data-schoice="1"]').map(b => b.textContent).join("|") === "1/4|1/2|3/4|3/4 MDF");
  ok("...Send off, \"Pick the wood and thickness\"", $(w, "[data-ssend]").disabled && /Pick the wood and thickness/.test(txt(w)));
  await click(w, byText(w, '[data-schoice="0"]', /White Oak/));
  ok("wood only: still off, \"Pick the thickness\"", $(w, "[data-ssend]").disabled && /Pick the thickness/.test(txt(w)));
  await click(w, byText(w, '[data-schoice="1"]', /3\/4 MDF/));
  await click(w, byText(w, '[data-schoice="0"]', /Walnut/));
  ok("changing the wood swaps it: 1 × Plywood — Walnut, 3/4 MDF", /1 × Plywood — Walnut, 3\/4 MDF/.test($(w, ".swhat").textContent) && $$(w, '[data-schoice][aria-pressed="true"]').length === 2);
  await click(w, "[data-ssend]", 50);
  await until(async () => !!(await one("select 1 x from supply_requests where department = 'full_custom'")));
  ok("sent to the office as \"Plywood — Walnut, 3/4 MDF\"", (await one("select item from supply_requests where department = 'full_custom'")).item === "Plywood — Walnut, 3/4 MDF");
  w.close();

  // ================= Arrow: its own tab =================
  w = bootTablet(users.willie);
  await until(() => $$(w, ".subtab").length === 5);
  ok("Willie: Work orders · Arrow · Problems · Log · Supplies", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Work orders · Arrow · Problems · Log · Supplies");
  await click(w, '[data-tab="arrow"]', 200);
  await until(() => /At Arrow now/.test(txt(w)));
  ok("the Arrow tab: Send something to Arrow, then At Arrow now", !!$(w, "[data-aropen]") && txt(w).indexOf("Send something to Arrow") < txt(w).indexOf("At Arrow now"));
  const j418 = (await one("select id from jobs where project_id = 'PROJ-00418'")).id;
  const sa = await makeClient(users.willie).rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6], p_description: "Bases", p_sent_on: null, p_client_id: null });
  if (sa.error) throw new Error(sa.error.message);
  await click(w, '[data-tab="log"]', 200); await until(() => /Routine tasks/.test(txt(w)));
  ok("Log has no Arrow any more", !/At Arrow/.test(txt(w)));
  await until(() => ($(w, '[data-tab="arrow"] .c') || {}).textContent === "1");
  ok("the Arrow tab's count shows what's out (1), even from another tab", ($(w, '[data-tab="arrow"] .c') || {}).textContent === "1");
  const w3 = bootTablet(users.willie, { preload: { sf_tab: JSON.stringify("log") } });
  await until(() => $$(w3, ".subtab").length === 5);
  ok("a tablet that was left on Log still opens on Log", $(w3, '.subtab[aria-current="true"]').dataset.tab === "log");
  w.close(); w3.close();
  w = bootTablet(users.shawn);
  await until(() => $$(w, ".subtab").length === 4);
  ok("Shawn: Load-out · Arrow · Problems · Log, opening on Load-out",
     $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Load-out · Arrow · Problems · Log" && $(w, '.subtab[aria-current="true"]').dataset.tab === "loadout");
  w.close();
  w = bootTablet(users.donnie);
  await until(() => $$(w, ".subtab").length === 4);
  ok("Donnie (Milling): no Arrow tab", !$(w, '[data-tab="arrow"]'));
  await click(w, '[data-tab="supplies"]', 300);
  await until(() => $$(w, "[data-spick]").length === 5);
  ok("Milling's list: Glue, Glue rollers (once), Glue bottles, Boxes of biscuits", chips(w).join("|") === "Glue|Glue rollers|Glue bottles|Boxes of biscuits|Something else");
  w.close();

  // ================= the office: Setup → Supply lists =================
  w = bootOffice(users.luke);
  await until(() => /Supply lists/.test(txt(w)), 6000);
  if (!/Supply lists/.test(txt(w))) await officeTab(w, "setup");
  await until(() => /Sanding — 7/.test(txt(w)), 6000);
  const sums = $$(w, 'details[data-keep^="sup_"] > summary').map(s => s.textContent.trim());
  ok("office: a list per counted department, with how many are on it (no Delivery)",
     sums.join("|") === "Milling — 4|CNC — 0|Sanding — 7|Finishing — 0|Full Custom — 1|Metal — 0|Assembly / QC — 2", sums.join("|"));
  ok("...Plywood shows its choices on one line", /Plywood\s*Wood: Ash, Maple, White Oak, Walnut, Cherry · Thickness: 1\/4, 1\/2, 3\/4, 3\/4 MDF/.test(supDetails(w, "full_custom").textContent.replace(/\s+/g, " ")));
  ok("...CNC's empty list says the tablet shows the typed box", /No list yet/.test(supDetails(w, "cnc").textContent));

  // add a plain item to CNC
  await click(w, '[data-supadd="cnc"]');
  ok("Add an item: the form opens inside CNC's list, Add is off until there's a name",
     supDetails(w, "cnc").open && !!supDetails(w, "cnc").querySelector("#supName") && $(w, "[data-supsave]").disabled);
  type(w, "#supName", "Router bits  1/4 inch");
  ok("...typing a name turns Add on", !$(w, "[data-supsave]").disabled);
  await click(w, "[data-supsave]", 50);
  await until(async () => !!(await one("select 1 x from supply_items where department = 'cnc'")));
  const c1 = await one("select name, choices, added_by_name from supply_items where department = 'cnc'");
  ok("saved: \"Router bits 1/4 inch\", no choices, added by Luke H", c1.name === "Router bits 1/4 inch" && JSON.stringify(c1.choices) === "[]" && c1.added_by_name === "Luke H", JSON.stringify(c1));
  await until(() => /CNC — 1/.test(txt(w)));
  ok("...the list stays open, shows it, the form closes, and the answer shows", supDetails(w, "cnc").open && !!itemRow(w, "cnc", "Router bits 1/4 inch") && !$(w, "#supName") && /added to the list/.test(txt(w)));

  // add one with two sets of choices to Metal
  await click(w, '[data-supadd="metal"]');
  type(w, "#supName", "Welding wire");
  type(w, '[data-supg="0"][data-part="label"]', "Size"); type(w, '[data-supg="0"][data-part="options"]', ".030, .035 , ");
  type(w, '[data-supg="1"][data-part="label"]', "Spool"); type(w, '[data-supg="1"][data-part="options"]', "2 lb, 11 lb");
  await click(w, "[data-supsave]", 50);
  await until(async () => !!(await one("select 1 x from supply_items where department = 'metal'")));
  ok("two sets of choices saved as typed, tidied", JSON.stringify((await one("select choices from supply_items where department = 'metal'")).choices)
     === JSON.stringify([{ label: "Size", options: [".030", ".035"] }, { label: "Spool", options: ["2 lb", "11 lb"] }]));

  // a mistake: shown in the form, nothing saved, the typing kept
  await until(() => !$(w, "#supName") && /Metal — 1/.test(txt(w)));
  await click(w, '[data-supadd="sanding"]');
  type(w, "#supName", "gloves");
  await click(w, "[data-supsave]", 50);
  await until(() => /already on Sanding's list/.test(txt(w)));
  ok("a duplicate: the reason shows in the form itself, and the form stays with the typing", !!$(w, ".supform .banner.warn") && /already on Sanding's list/.test($(w, ".supform").textContent) && $(w, "#supName").value === "gloves");
  type(w, '[data-supg="0"][data-part="label"]', "Size");
  type(w, "#supName", "Nitrile gloves");
  await click(w, "[data-supsave]", 50);
  await until(() => /List at least one choice under "Size"/.test(txt(w)));
  ok("a set of choices with a name but no choices: refused, in plain words", /List at least one choice under "Size"/.test($(w, ".supform").textContent));
  await click(w, "[data-supcancel]");
  ok("Cancel closes the form; nothing was saved", !$(w, "#supName") && (await one("select count(*)::int n from supply_items where department = 'sanding'")).n === 7);

  // edit Plywood: add Birch
  await click(w, itemRow(w, "full_custom", "Plywood").querySelector("[data-supedit]"));
  ok("Edit: the form opens filled in (name and both sets)", $(w, "#supName").value === "Plywood" && $(w, '[data-supg="0"][data-part="options"]').value === "Ash, Maple, White Oak, Walnut, Cherry"
     && $(w, '[data-supg="1"][data-part="label"]').value === "Thickness");
  type(w, '[data-supg="0"][data-part="options"]', "Ash, Maple, White Oak, Walnut, Cherry, Birch");
  await click(w, "[data-supsave]", 50);
  await until(async () => (await one("select choices->0->'options' o from supply_items where name = 'Plywood'")).o.includes("Birch"));
  ok("saved: Plywood's woods now end with Birch", (await one("select choices->0->'options' o from supply_items where name = 'Plywood'")).o.join() === "Ash,Maple,White Oak,Walnut,Cherry,Birch");

  // move Gloves up
  await until(() => !$(w, "#supName"));
  await click(w, itemRow(w, "sanding", "Gloves").querySelector('[data-supmove][data-up="1"]'), 50);
  await until(async () => (await admin.query("select name from supply_items where department = 'sanding' and not retired order by sort_order")).rows.map(r => r.name)[5] === "Gloves");
  const order = (await admin.query("select name from supply_items where department = 'sanding' and not retired order by sort_order")).rows.map(r => r.name).join("|");
  ok("↑ moves Gloves above Stir sticks", order === "Sandpaper|Hand sandpaper|Epoxy|Dye|Cups|Gloves|Stir sticks", order);
  await until(() => [...supDetails(w, "sanding").querySelectorAll(".typ span")].map(s => s.firstChild.textContent.trim())[5] === "Gloves");
  ok("...the list shows the new order; the top item's ↑ and the bottom's ↓ are off",
     itemRow(w, "sanding", "Sandpaper").querySelector('[data-up="1"]').disabled && itemRow(w, "sanding", "Stir sticks").querySelector('[data-up="0"]').disabled);

  // retire Epoxy; the tablet stops showing it; bring it back
  await click(w, itemRow(w, "sanding", "Epoxy").querySelector("[data-supretire]"), 50);
  await until(async () => (await one("select retired from supply_items where name = 'Epoxy'")).retired);
  await until(() => /Sanding — 6/.test(txt(w)));
  ok("Retire: Epoxy moves under Retired, struck through, with Bring back", /Retired/.test(supDetails(w, "sanding").textContent)
     && itemRow(w, "sanding", "Epoxy").classList.contains("off") && !!itemRow(w, "sanding", "Epoxy").querySelector("[data-supback]"));
  const past = await one("select count(*)::int n from supply_requests where item = 'Epoxy'");
  ok("...the request Mike sent for Epoxy is untouched", past.n === 1);
  let t = bootTablet(users.mike, { preload: { sf_tab: JSON.stringify("supplies") } });
  await until(() => $$(t, "[data-spick]").length === 7);
  ok("Mike's tablet no longer lists Epoxy, and shows Gloves above Stir sticks", chips(t).join("|") === "Sandpaper|Hand sandpaper|Dye|Cups|Gloves|Stir sticks|Something else", chips(t).join("|"));
  t.close();
  await click(w, itemRow(w, "sanding", "Epoxy").querySelector("[data-supback]"), 50);
  await until(async () => !(await one("select retired from supply_items where name = 'Epoxy'")).retired);
  ok("Bring back: Epoxy is on the list again, at the bottom", (await admin.query("select name from supply_items where department = 'sanding' and not retired order by sort_order desc limit 1")).rows[0].name === "Epoxy");
  w.close();

  // a supervisor's login can't use the office's changes (the database says no)
  const sr = await makeClient(users.mike).rpc("set_supply_item", { p_id: null, p_department: "sanding", p_name: "Mine", p_choices: [] });
  ok("Mike's login is refused by the database, in plain words", !!sr.error && /Only a manager can change the supply lists/.test(sr.error.message));

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks_supply.py (run from the folder above `out/` and `t/`, on a loaded database)
```python
import subprocess
src = open('out/supply_lists.sql').read()
def section(a, b): return src[src.index(a):src.index(b)]
fset  = section('create or replace function set_supply_item', '-- move an item')
fmove = section('create or replace function move_supply_item', '-- retire an item')
fret  = section('create or replace function retire_supply_item', '-- ---------------------------------------------------------------------\n-- 5.')
fcl   = section('create or replace function supply_choices_clean', 'revoke all on function supply_choices_clean')
P = ['psql','-h','/tmp/pg','-p','5433','-U','postgres','-d','sync','-At','-v','ON_ERROR_STOP=1']
def run(sql): return subprocess.run(P+['-c',sql],capture_output=True,text=True)
guard = "if not office_ok() then\n    raise exception 'Only a manager can change the supply lists.' using errcode = 'insufficient_privilege';\n  end if;"
breaks = {
 'supervisors may add':      (fset, fset.replace(guard, ""), 4),
 'supervisors may retire':   (fret, fret.replace(guard, ""), 4),
 'retire deletes':           (fret, fret.replace("update supply_items set retired = true, retired_at = now(), retired_by_name = my_name(), updated_at = now() where id = p_id;", "delete from supply_items where id = p_id;"), 8),
 'three sets allowed':       (fcl, fcl.replace("if jsonb_array_length(p) > 2 then", "if false then"), 9),
 'delivery allowed':         (fset, fset.replace("if v_dept.log_only then", "if false then"), 9),
 'move does nothing':        (fmove, fmove.replace("update supply_items set sort_order = w.sort_order where id = v.id;", ""), 7),
 'names not trimmed':        (fset, fset.replace("v_name    text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\\s+', ' ', 'g'), '');", "v_name text := nullif(p_name, '');"), 7),
}
for name,(orig,body,row) in breaks.items():
    assert body != orig, name
    r = run(body); assert r.returncode == 0, r.stderr
    out = run("select step from check_supply_lists() where result <> 'PASS'").stdout.split()
    print(f"{name:24s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    run(orig)
for name, brk, fix, row in [
  ('direct insert allowed', "grant insert on supply_items to authenticated; create policy x on supply_items for insert to authenticated with check (true)", "revoke insert on supply_items from authenticated; drop policy x on supply_items", 5),
  ('anon can read',         "grant select on supply_items to anon; create policy y on supply_items for select to anon using (true)", "revoke select on supply_items from anon; drop policy y on supply_items", 6),
  ('supervisors cannot read', "drop policy read_supply_items on supply_items", "create policy read_supply_items on supply_items for select to authenticated using (true)", 3),
]:
    run(brk)
    out = run("select step from check_supply_lists() where result <> 'PASS'").stdout.split()
    print(f"{name:24s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    run(fix)
print('restored:', run("select count(*) from check_supply_lists() where result='PASS'").stdout.strip(), 'PASS')
```

#### snap_supply.js
```javascript
// Photograph the new screens: the real pages in jsdom against the test database, then Chromium.
// The body is snap_supply_body.js, run in the same scope as test_supply_lists.js's helpers.
const fs = require("fs");
const { chromium } = require("playwright");
const src = fs.readFileSync("test_supply_lists.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")).replace(/^const fs = require\("fs"\);/m, "") + fs.readFileSync("snap_supply_body.js", "utf8"));
```

#### snap_supply_body.js
```javascript
const fontCss = ["barlow/400", "barlow/500", "barlow/600", "barlow/700", "barlow-condensed/600", "barlow-condensed/700"].map(p => {
  const [fam, wt] = p.split("/"); const file = `../node_modules/@fontsource/${fam}/files/${fam}-latin-${wt}-normal.woff2`;
  return `@font-face{font-family:'${fam === "barlow" ? "Barlow" : "Barlow Condensed"}';font-weight:${wt};src:url(data:font/woff2;base64,${fs.readFileSync(file).toString("base64")})}`;
}).join("");
const shots = [];
const save = (w, name, focus = null) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
  shots.push([name, "<!DOCTYPE html>" + d.outerHTML.replace("<style>", "<style>" + fontCss), focus]); };
(async () => {
  await admin.query("update jobs set name = 'Riverside Community Church — fellowship hall tables, credenza and matching benches' where project_id = 'PROJ-00418'");
  let w = bootTablet(users.mike);
  await until(() => /PROJ-00418/.test(txt(w))); await wait(500); save(w, "1-queue");
  await click(w, '[data-tab="supplies"]'); await until(() => $$(w, "[data-spick]").length === 8);
  await click(w, byText(w, "[data-spick]", /^Sandpaper$/)); save(w, "2-sanding-pick", ".spick");
  await click(w, byText(w, "[data-schoice]", /120 grit/)); await click(w, '[data-snew="1"]'); save(w, "3-sanding-ready", ".spick");
  w = bootTablet(users.luke, { preload: { sf_dept: JSON.stringify("full_custom"), sf_tab: JSON.stringify("supplies") } });
  await until(() => $$(w, "[data-spick]").length === 2, 6000);
  await click(w, byText(w, "[data-spick]", /Plywood/)); await click(w, byText(w, '[data-schoice="0"]', /White Oak/)); save(w, "4-plywood", ".spick");
  w = bootTablet(users.willie);
  const j = (await one("select id from jobs where project_id = 'PROJ-00418'")).id;
  await makeClient(users.willie).rpc("send_to_arrow", { p_job: j, p_department: "metal", p_service: "powdercoat", p_sheets: [6, 9], p_description: "Bases, black", p_sent_on: null, p_client_id: null });
  await until(() => $$(w, ".subtab").length === 5); await click(w, '[data-tab="arrow"]', 300); await until(() => /0 days out/.test(txt(w))); save(w, "5-arrow");
  w = bootOffice(users.luke);
  await until(() => /Sanding — 7/.test(txt(w)), 6000);
  await click(w, itemRow(w, "full_custom", "Plywood").querySelector("[data-supedit]"));
  supDetails(w, "sanding").setAttribute("open", "");
  save(w, "6-office", 'details[data-keep="sup_milling"]');
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [vw, vh, tag] of [[1280, 800, "land"], [800, 1280, "port"]]) {
    const p = await b.newPage({ viewport: { width: vw, height: vh } });
    for (const [n, h, focus] of shots) {
      await p.setContent(h, { waitUntil: "load" }); await p.waitForTimeout(150);
      if (focus) await p.evaluate((f) => document.querySelector(f).scrollIntoView({ block: "start" }), focus);
      await p.screenshot({ path: `/tmp/sup_${n}_${tag}.png` });
    }
  }
  await b.close(); console.log("shots:", shots.map(s => s[0]).join(", ")); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

---

# Part 7 — load-outs v2 (24 Sep, later)

This build added `loadouts_v2.sql` (new columns `loadouts.kind / carrier / tracking`, `photos.piece / pallet`; view `v_loadout_sheets`; functions `set_loadout_details()`, `add_loadout_photo()`; `v_loadouts` and `v_photos` rebuilt with the new columns at the end; check `check_loadouts()`) and changed `index.html` and `office.html` again (built on the Part 6 versions). **No existing function changed**: `add_loadout_photo()` calls `add_photo()` and then records the table or pallet.

## Setup notes

- **Run the browser suites on shop time:** `TZ=America/Indiana/Indianapolis node …`. After 8 pm Eastern the sandbox (UTC) is already on tomorrow and `test_app_e2e.js`'s "history shows today" row fails for that reason alone.
- **jsdom has no Cache API**, so the tablet's page cache (`sheet-pages-v1`) is skipped there. `test_loadouts_v2.js` gives the window a small in-memory `caches` (with Node's `Request` / `Response`) so "saved for no signal" is really exercised: pages saved while online, then shown with the stand-in offline.
- `pgsupa.js` serves every `work-orders` download as a tiny PNG; sheet pages are never uploaded in the sandbox.
- **Two load-outs started inside one transaction share `started_at`**, so neither is "earlier". `check_loadouts()` row 8 backdates the first by an hour. Real trucks never start in the same transaction.
- **`test_photos_e2e.js` with `loadouts_v2.sql` loaded:** 33 PASS, 8 FAIL on purpose — its load-out rows drive the old screen. Without `loadouts_v2.sql`: 41 PASS, which proves the page falls back to the old screen when the SQL hasn't run. `test_loadouts_v2.js` replaces those 8.
- **Entries queued while another is sending** used to wait for the next trigger (up to a minute). `flushLog()` now goes round again at once. Found because a shipment's `set_loadout_details` queued right behind `start_loadout`.
- Snapshots of typed input don't carry the text (it's the `value` property, not the attribute): empty-looking boxes in `snap_lo.js`'s shots are expected.

## Results when delivered

| Suite | Result |
|---|---|
| `check_loadouts()`, loaded twice | 12 PASS, nothing left behind |
| `check_loadouts()` against 9 deliberate breaks (`breaks_loadouts.py`) | each caught. Two were first missed — the department rule hidden behind the lane rule, and the sheets view's lane filter behind the jobs table's own security — so rows 11 and 12 now test a real-lane load-out and the Test Supervisor listing real sheets |
| All five checks together | `check_floor` 18, `check_photos` 16, `check_advance` 10, `check_supply_lists` 10, `check_loadouts` 12 |
| `test_loadouts_v2.js` — core (size labels, tables, pallets, missing text); a delivery with per-table spots, a second photo not double-counting, the work order page, offline page and photo, finishing with gaps; a shipment on the same job (earlier truck, pallets, add a pallet, carrier and tracking, finishing); switching kind; the office Photos tab; the phone CSS; Mike's defect photo still through `add_photo` | 46 PASS (run twice) |
| `test_app_e2e.js` (`SUPPLY=1 PHOTOS=1 ADVANCE=1`, shop time) | 72 PASS |
| `test_supply_lists.js` | 63 PASS |
| `test_photos_e2e.js` | 41 PASS without `loadouts_v2.sql`; 33 + 8 on purpose with it |
| `test_advance.js` | 45 PASS, 1 FAIL on purpose (Part 6) |
| `test_app_core.js` / `test_needs.js` | 19 / 43 PASS |
| `snap_lo.js` — Mike's queue, starting, a delivery, the work order page, a shipment's pallet step, at 390×844 | looked at: two-line job names, tabs on one row, spots wrap, the page view fits |

Run order: `cd t && ../base/fresh.sh ../base/advance.sql ../out/supply_lists.sql ../out/loadouts_v2.sql && TZ=America/Indiana/Indianapolis node <suite>.js`.

Not covered: a real phone camera, the real Cache API on a real phone, and the real SQL Editor (Walkthrough 10).

## Files (Part 7)

#### test_loadouts_v2.js
```javascript
// Load-outs, version 2 (24 Sep): size labels, a spot for every table, shipments with wrapped-pallet photos,
// carrier and tracking, the work order page from the load-out, pages saved for no signal, the phone layout.
// The real index.html and office.html in jsdom against the real test database (pgsupa.js); the camera is
// stood in for (sfShrinkPhoto) and the browser's page cache by a small in-memory Cache API.
// Run: ../base/fresh.sh ../base/advance.sql ../out/supply_lists.sql ../out/loadouts_v2.sql && TZ=America/Indiana/Indianapolis node test_loadouts_v2.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const fidb = require("fake-indexeddb");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"><\/script>/, "");
const html = strip(fs.readFileSync("../out/index.html", "utf8"));
const OFFICE = strip(fs.readFileSync("../out/office.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
const all = async (sql, p = []) => (await admin.query(sql, p)).rows;

// a stand-in for the browser's Cache API (jsdom has none), shared like a real device's
function fakeCaches() {
  const stores = new Map();
  return { open: async (name) => { if (!stores.has(name)) stores.set(name, new Map()); const m = stores.get(name);
    return { match: async (req) => m.has(req.url) ? m.get(req.url).clone() : undefined, put: async (req, res) => { m.set(req.url, res); } }; },
    _stores: stores };
}
function boot(user, { idb, caches, preload = {} } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.indexedDB = idb || new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:local-preview"; w.URL.revokeObjectURL = () => {};
  if (caches) { w.caches = caches; w.Request = Request; w.Response = Response; }
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.sfShrinkPhoto = async () => ({ blob: new Blob([Buffer.alloc(200000, 7)], { type: "image/jpeg" }), width: 1600, height: 1200 });
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
function type(w, sel, value) { const el = $(w, sel); el.value = value; el.dispatchEvent(new w.Event("input")); }
async function snap(w) {             // the person takes the photo
  const cam = w.document.getElementById("camera");
  Object.defineProperty(cam, "files", { value: [new w.File(["x"], "IMG_0001.jpg", { type: "image/jpeg" })], configurable: true });
  cam.dispatchEvent(new w.Event("change")); await wait(150);
}
const card = (w, n) => $$(w, ".locard").find(c => c.querySelector(".no").textContent.trim() === String(n));
const slot = (w, sheet, piece) => $(w, `.loslot[data-loshoot="${sheet}"][data-piece="${piece}"]`);

(async () => {
  // ================= core =================
  const C = (() => { const m = { exports: {} }; new Function("module", "require", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1])(m, require); return m.exports; })();
  ok("core: round → \"36 rnd · 42 H\"", C.sizeLabel({ shape: "Round", width: '36"', length: '36"', total_height: '42"' }) === "36 rnd · 42 H");
  ok("core: rectangle → \"30 × 60 · 30 H\"", C.sizeLabel({ shape: "Rectangle", width: '30"', length: '60"', total_height: '30"' }) === "30 × 60 · 30 H");
  ok("core: another shape names itself → \"42 × 84 oval · 30 H\"", C.sizeLabel({ shape: "Oval", width: "42", length: "84 in", total_height: '30"' }) === "42 × 84 oval · 30 H");
  ok("core: no height → size only; nothing at all → null", C.sizeLabel({ shape: "Rectangle", width: "24", length: "48" }) === "24 × 48" && C.sizeLabel({ shape: "", width: "", length: null }) === null);
  const sh = [{ sheet_number: 1, qty: 3 }, { sheet_number: 2, qty: 1 }];
  let p = C.loadoutPieces(sh, { pieces_here: ["1:1"], pieces_earlier: ["1:2"], pallets_here: [1], other_items: 0 }, [{ sheet: 2, piece: 1 }, { pallet: 2 }], 1);
  ok("core: tables — here, earlier, waiting; 3 of 4 done", p.total === 4 && p.done === 3 && p.list[0].slots[1].earlier && p.list[1].slots[0].waiting && p.missing.length === 1 && p.missing[0].pieces.join() === "3");
  ok("core: pallets — planned 1, but pallet 2 waiting → 2 pallets, none missing", p.pallets === 2 && p.palletsHere.join() === "1,2" && p.palletsMissing.length === 0);
  ok("core: an old photo with no table number counts as table 1", C.loadoutPieces([{ sheet_number: 5, qty: 2 }], { pieces_here: [] }, [{ sheet: 5 }]).list[0].slots[0].here);
  ok("core: missing, in words", C.missingText([{ sheet: 4, qty: 3, pieces: [3] }, { sheet: 6, qty: 3, pieces: [1, 2, 3] }, { sheet: 8, qty: 1, pieces: [1] }]) === "sheet 4: table 3 · sheet 6: all 3 tables · sheet 8: the table");

  // PROJ-00362 is in Delivery; give it a work order with real sizes: 3 round, 1 rectangle, 2 oval
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-02', 'Rectangle', '30"', '60"', '30"', 'PROJ-00362/v1/sheet-2.png', now()),
      (w, 3, 2, 'TR-03', 'Oval', '42"', '84"', '30"', 'PROJ-00362/v1/sheet-3.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);

  // ================= Shawn: a delivery =================
  const cachesA = fakeCaches(), idbA = new fidb.IDBFactory();
  let w = boot(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => /Start a load-out/.test(txt(w)));
  ok("Shawn: Load-out · Arrow · Problems · Log", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Load-out · Arrow · Problems · Log");
  ok("start: Delivery or Shipping, Delivery picked", $$(w, "[data-lostartkind]").length === 2 && $(w, '[data-lostartkind="delivery"]').getAttribute("aria-pressed") === "true");
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 200);
  await until(() => $$(w, ".locard").length === 3);
  ok("started: three sheet cards, labelled by size, not item code", $$(w, ".locard .size").map(x => x.textContent).join("|") === "36 rnd · 42 H|30 × 60 · 30 H|42 × 84 oval · 30 H" && !/TR-0/.test(txt(w)));
  ok("a spot for every table: Table 1–3, The table, Table 1–2", $$(w, ".loslot").map(b => b.firstChild.textContent.trim()).join("|") === "Table 1|Table 2|Table 3|The table|Table 1|Table 2");
  ok("the count is in tables: 0 of 6; no pallets on a delivery", /0 of 6 tables photographed/.test(txt(w)) && !$(w, "[data-lopallet]") && !/Each pallet/.test(txt(w)) && /The truck is leaving/.test(txt(w)));
  await until(() => /Ready for no signal · 3 work order pages saved/.test(txt(w)));
  ok("opening the load-out saves all 3 work order pages on the device, and says so", /✓ Ready for no signal · 3 work order pages saved on this device/.test(txt(w)) && cachesA._stores.get("sheet-pages-v1").size === 3);
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'delivery'")));
  await click(w, slot(w, 1, 2)); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where piece = 2 and sheet_number = 1")).n === 1);
  ok("tap Table 2 of sheet 1: saved as sheet 1, table 2", !!(await one("select 1 x from photos where kind = 'loadout' and sheet_number = 1 and piece = 2 and pallet is null")));
  await until(() => /1 of 6 tables photographed/.test(txt(w)));
  ok("...its spot turns turquoise; sheet 1 shows 1 of 3", slot(w, 1, 2).classList.contains("here") && card(w, 1).querySelector(".cnt").textContent === "1 of 3");
  await click(w, slot(w, 2, 1)); await snap(w);
  await until(() => card(w, 2).classList.contains("done"));
  ok("the one table on sheet 2: the whole card turns complete", card(w, 2).classList.contains("done"));
  await click(w, slot(w, 1, 2)); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where sheet_number = 1 and piece = 2")).n === 2);
  await until(() => /2 of 6 tables/.test(txt(w)));
  ok("a second photo of the same table doesn't count it twice (2 of 6)", /2 of 6 tables photographed/.test(txt(w)));

  // the work order page, from the load-out
  await click(w, $(w, '[data-lowo="3"]'), 150);
  await until(() => $(w, "#lopage img"));
  ok("Work order: sheet 3's page, its size and tables, and its two spots", /Sheet 3/.test($(w, "h1").textContent) && /42 × 84 oval · 30 H · 2 tables/.test(txt(w)) && !!$(w, "#lopage img") && $$(w, ".loslot").length === 2);
  await click(w, slot(w, 3, 1)); await snap(w);
  await until(async () => !!(await one("select 1 x from photos where sheet_number = 3 and piece = 1")));
  ok("photographing from the page view works too (sheet 3, table 1)", true);
  await click(w, "[data-lowoback]");
  ok("← Load-out goes back to the cards", $$(w, ".locard").length === 3);

  // no signal: the page still opens, photos wait
  setOffline(true);
  await click(w, $(w, '[data-lowo="1"]'), 200);
  await until(() => $(w, "#lopage img") || $(w, "#lopage .missing:not(:empty)"));
  ok("no signal: sheet 1's page still opens (saved on the device)", !!$(w, "#lopage img"));
  await click(w, slot(w, 1, 3)); await snap(w);
  await until(() => /1 photo waiting to send/.test($(w, ".sync").textContent));
  ok("no signal: a table photo waits, its spot says so", /Waiting to send/.test(slot(w, 1, 3).textContent) && slot(w, 1, 3).classList.contains("here"));
  await click(w, "[data-lowoback]");
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => !!(await one("select 1 x from photos where sheet_number = 1 and piece = 3")), 6000);
  ok("back online: it sends by itself, as sheet 1, table 3", !!(await one("select 1 x from photos where sheet_number = 1 and piece = 3")));

  // finishing with gaps
  await until(() => /4 of 6 tables/.test(txt(w)));
  await click(w, "[data-lofinish]");
  ok("finishing with tables missing says exactly which", /The truck is leaving\?/.test($(w, ".mdl").textContent) && /Not photographed — sheet 1: table 1 · sheet 3: table 2\./.test($(w, ".mdl").textContent), $(w, ".mdl").textContent.replace(/\s+/g, " "));
  await click(w, "[data-confirm]", 200);
  await until(async () => !!(await one("select 1 x from loadouts where finished_at is not null")));
  ok("finished: recorded as left", !!(await one("select 1 x from loadouts where kind = 'delivery' and finished_at is not null")));
  await until(() => /Left in the last two weeks/.test(txt(w)));
  ok("the list line says it in tables: \"Delivery · 4 of 6 tables photographed\"", /Delivery · 4 of 6 tables photographed/.test(txt(w)));
  w.close();

  // ================= Shawn: a shipment on the same job (the rest of it) =================
  w = boot(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => $$(w, "[data-pickjob]").length > 0 || /Start a load-out/.test(txt(w)));
  await click(w, '[data-lostartkind="shipping"]');
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 200);
  await until(() => $$(w, ".locard").length === 4);
  ok("a shipment: Shipping picked, step 1 (tables) and step 2 (one pallet)", $(w, '[data-lokind="shipping"]').getAttribute("aria-pressed") === "true"
     && /1 · Every table, before it's wrapped/.test(txt(w)) && /2 · Each pallet, once it's wrapped — 0 of 1/.test(txt(w)) && /Picked up — finish this shipment/.test(txt(w)));
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'shipping'")));
  ok("...recorded in the database as a shipment", !!(await one("select 1 x from loadouts where kind = 'shipping' and finished_at is null")));
  ok("the earlier truck's tables show as gone earlier (4 of 6)", /4 of 6 tables photographed/.test(txt(w)) && slot(w, 1, 2).classList.contains("earlier") && /Went on an earlier truck/.test(slot(w, 2, 1).textContent));
  await click(w, slot(w, 1, 1)); await snap(w);
  await click(w, slot(w, 3, 2)); await snap(w);
  await until(() => /6 of 6 tables/.test(txt(w)), 6000);
  await click(w, "[data-lopallet]"); await snap(w);
  await until(async () => !!(await one("select 1 x from photos where pallet = 1")), 6000);
  const pal = await one("select note, sheet_number, piece from photos where pallet = 1");
  ok("the wrapped pallet: saved as pallet 1, no sheet, noted \"Pallet 1, wrapped\"", pal.sheet_number === null && pal.piece === null && pal.note === "Pallet 1, wrapped");
  await click(w, "[data-loaddpallet]");
  ok("Add another pallet: pallet 2 appears, not yet photographed", $$(w, "[data-lopallet]").length === 2 && /0 of|1 of 2/.test(txt(w)));
  ok("carrier and tracking: Save is off until something's typed", $(w, "[data-losavedet]").disabled);
  type(w, "#loCarrier", "Estes"); type(w, "#loTracking", "BOL 44812");
  ok("...typing turns it on", !$(w, "[data-losavedet]").disabled);
  await click(w, "[data-losavedet]", 100);
  await until(async () => !!(await one("select 1 x from loadouts where carrier = 'Estes' and tracking = 'BOL 44812'")));
  ok("saved: Estes, BOL 44812", !!(await one("select 1 x from loadouts where kind = 'shipping' and carrier = 'Estes' and tracking = 'BOL 44812'")));
  await click(w, "[data-lofinish]");
  ok("finishing a shipment with pallet 2 unphotographed asks first, naming it", /Picked up\?/.test($(w, ".mdl").textContent) && /No wrapped photo of pallet 2\./.test($(w, ".mdl").textContent) && !/Not photographed/.test($(w, ".mdl").textContent));
  await click(w, ".mdl [data-close].btn");
  await click(w, $$(w, "[data-lopallet]")[1]); await snap(w);
  await until(async () => !!(await one("select 1 x from photos where pallet = 2")), 6000);
  await until(() => /2 of 2/.test(txt(w)));
  await click(w, "[data-lofinish]");
  ok("everything photographed: \"This records that the shipment was picked up now\"", /Everything is photographed\. This records that the shipment was picked up now\./.test($(w, ".mdl").textContent));
  await click(w, "[data-confirm]", 200);
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'shipping' and finished_at is not null")));
  await until(() => /Shipment · 6 of 6 tables photographed · 2 pallets/.test(txt(w)));
  ok("the list: \"Shipment · 6 of 6 tables photographed · 2 pallets\"", /Shipment · 6 of 6 tables photographed · 2 pallets/.test(txt(w)));
  w.close();

  // switching a delivery to a shipment
  w = boot(users.shawn);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 200);
  await until(() => $$(w, ".locard").length === 3);
  await until(async () => (await one("select count(*)::int n from loadouts where finished_at is null")).n === 1);
  await click(w, '[data-lokind="shipping"]', 200);
  await until(async () => !!(await one("select 1 x from loadouts where finished_at is null and kind = 'shipping'")));
  ok("an open delivery can be switched to a shipment (the pallet step appears)", /Each pallet, once it's wrapped/.test(txt(w)));
  await click(w, "[data-lovoid]"); await click(w, "[data-confirm]", 200);
  w.close();

  // ================= the office: what left the building =================
  const client = makeClient(users.luke);
  const dom = new JSDOM(OFFICE, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const o = dom.window;
  o.localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); o.localStorage.setItem("sfo_tab", JSON.stringify("photos"));
  o.supabase = { createClient: () => client }; o.confirm = () => true; o.scrollTo = () => {}; o.TextEncoder = TextEncoder; o.Blob = Blob;
  o.eval([...OFFICE.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  await until(() => o.document.querySelector("#phJob"), 6000);
  o.document.querySelector("#phJob").value = "362"; o.document.querySelector("[data-phfind]").click();
  await until(() => /What left the building/.test(txt(o)), 6000);
  const ot = txt(o);
  ok("office Photos: the shipment — picked up, Estes, tracking, 2 of 6 tables on it, 2 wrapped pallets",
     /Shipment · Picked up/.test(ot) && /Estes · tracking BOL 44812/.test(ot) && /Tables on this shipment: 2 · 6 of 6 photographed so far · 2 wrapped pallets/.test(ot), ot.slice(ot.indexOf("What left"), ot.indexOf("What left") + 400));
  ok("...and the delivery — left, 4 tables on this truck", /Delivery · Left/.test(ot) && /Tables on this truck: 4 · 4 of 6 photographed so far/.test(ot));
  ok("photo captions say the table and the pallet", /Sheet 1 · table 2/.test(ot) && /Pallet 1, wrapped/.test(ot));
  o.close();

  // ================= the phone layout =================
  const css = html;
  ok("phones (under 600px): the area tabs stay on one row and scroll", /@media \(max-width: 600px\)\{\s*\.subtabs\{flex-wrap:nowrap; overflow-x:auto/.test(css));
  ok("phones: a job name may take two lines, the due date keeps its place", /\.jname\{order:3; flex:1 1 100%; white-space:normal; display:-webkit-box; -webkit-line-clamp:2/.test(css));
  ok("tablets: none of that applies above 600px (the one-line rule stands)", /\.jname\{color:var\(--ink2\); flex:1 1 0; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis\}/.test(css));

  // Mike's defect photo still goes the old way (add_photo), untouched
  w = boot(users.mike);
  await until(() => /PROJ-00418/.test(txt(w)));
  await click(w, "button.job"); await click(w, "button.sheet");
  await click(w, "[data-defect]"); await wait(100);
  await click(w, $$(w, "[data-picktype]")[0]);
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-savedefect]", 200);
  await until(async () => !!(await one("select 1 x from photos where kind = 'defect'")), 6000);
  ok("Mike's defect photo still saves through add_photo, as before", !!(await one("select 1 x from photos where kind = 'defect' and piece is null and pallet is null"))
     && w.client.rpcs.some(r => r[0] === "add_photo") && !w.client.rpcs.some(r => r[0] === "add_loadout_photo"));

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks_loadouts.py (run from the folder above `out/` and `t/`, on a loaded database)
```python
import subprocess
src = open('out/loadouts_v2.sql').read()
def section(a, b): return src[src.index(a):src.index(b)]
fphoto = section('create or replace function add_loadout_photo', 'revoke all on function add_loadout_photo')
fdet   = section('create or replace function set_loadout_details', 'revoke all on function set_loadout_details')
vlo    = section('drop view if exists v_loadouts;', '-- v_photos gains')
vsh    = section('drop view if exists v_loadout_sheets;', '-- ---------------------------------------------------------------------\n-- 3.')
P = ['psql','-h','/tmp/pg','-p','5433','-U','postgres','-d','sync','-At','-v','ON_ERROR_STOP=1']
def run(sql): return subprocess.run(P+['-c',sql],capture_output=True,text=True)
breaks = {
 'any table number':        (fphoto, fphoto.replace("if p_piece < 1 or p_piece > v_qty then", "if false then"), 5),
 'pallet on a delivery':    (fphoto, fphoto.replace("if v.kind <> 'shipping' then", "if false then"), 7),
 'piece not recorded':      (fphoto, fphoto.replace("update photos set piece = p_piece, pallet = p_pallet where client_id = p_client_id;", ""), 4),
 'no waiting':              (fphoto, fphoto.replace("return jsonb_build_object('ok', false, 'waiting', true, 'summary', 'The load-out this photo belongs to hasn''t reached the database yet.');", "raise exception 'no load-out';"), 9),
 'anyone sets details':     (fdet, fdet.replace("v_job := floor_entry_check('delivery', v.job_id);", "select * into v_job from jobs where id = v.job_id;"), 11),
 'carrier not saved':       (fdet, fdet.replace("carrier  = case when p_carrier  is null then carrier  else nullif(trim(p_carrier), '')  end,", ""), 2),
 'old photos not table 1':  (vlo, vlo.replace("p.sheet_number || ':' || coalesce(p.piece, 1)) from photos p\n                  where p.loadout_id = l.id", "p.sheet_number || ':' || p.piece) from photos p\n                  where p.loadout_id = l.id"), 10),
 'earlier trucks ignored':  (vlo, vlo.replace("where l2.job_id = l.job_id and l2.id <> l.id and l2.voided_at is null and l2.started_at < l.started_at\n                    and p.voided_at is null and p.sheet_number is not null), '{}') as pieces_earlier", "where false), '{}') as pieces_earlier"), 8),
 'no lane on sheets':       (vsh, vsh.replace("and j.is_test = am_test();", ";"), 12),
}
for name,(orig,body,row) in breaks.items():
    assert body != orig, name
    r = run(body); assert r.returncode == 0, (name, r.stderr)
    out = run("select step from check_loadouts() where result <> 'PASS'").stdout.split()
    print(f"{name:24s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    run(orig)
run("grant insert on photos to authenticated; create policy x on photos for insert to authenticated with check (true)")
print("direct photo insert: (covered by check_photos)", run("select step from check_photos() where result <> 'PASS'").stdout.split())
run("revoke insert on photos from authenticated; drop policy x on photos")
print('restored:', run("select count(*) from check_loadouts() where result='PASS'").stdout.strip(), 'PASS')
```

#### snap_lo.js
```javascript
// Photograph the load-out screens at phone size: the real page in jsdom against the test database, then Chromium.
const fs = require("fs");
const { chromium } = require("playwright");
const src = fs.readFileSync("test_loadouts_v2.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")).replace(/^const fs = require\("fs"\);/m, "") + fs.readFileSync("snap_lo_body.js", "utf8"));
```

#### snap_lo_body.js
```javascript
const fontCss = ["barlow/400", "barlow/500", "barlow/600", "barlow/700", "barlow-condensed/600", "barlow-condensed/700"].map(p => {
  const [fam, wt] = p.split("/"); const file = `../node_modules/@fontsource/${fam}/files/${fam}-latin-${wt}-normal.woff2`;
  return `@font-face{font-family:'${fam === "barlow" ? "Barlow" : "Barlow Condensed"}';font-weight:${wt};src:url(data:font/woff2;base64,${fs.readFileSync(file).toString("base64")})}`;
}).join("");
const page = "data:image/png;base64," + fs.readFileSync("page.png").toString("base64");
const shots = [];
const save = (w, name, focus = null) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
  d.querySelectorAll("img").forEach(i => i.setAttribute("src", page));
  shots.push([name, "<!DOCTYPE html>" + d.outerHTML.replace("<style>", "<style>" + fontCss), focus]); };
(async () => {
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-02', 'Rectangle', '30"', '60"', '30"', 'PROJ-00362/v1/sheet-2.png', now()),
      (w, 3, 2, 'TR-03', 'Oval', '42"', '84"', '30"', 'PROJ-00362/v1/sheet-3.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);
  await admin.query("update jobs set name = 'Riverside Community Church — fellowship hall tables, credenza and matching benches' where project_id = 'PROJ-00418'");
  let w = boot(users.mike); await until(() => /PROJ-00418/.test(txt(w))); await wait(400); save(w, "0-mike-queue");
  const caches = fakeCaches();
  w = boot(users.shawn, { caches });
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]"); save(w, "1-start");
  await click(w, "[data-lostart]", 200); await until(() => /Ready for no signal/.test(txt(w)));
  await click(w, slot(w, 1, 1)); await snap(w); await click(w, slot(w, 2, 1)); await snap(w);
  await until(() => /2 of 6/.test(txt(w)), 6000); await wait(300); save(w, "2-delivery");
  await click(w, '[data-lowo="1"]', 200); await until(() => $(w, "#lopage img")); save(w, "3-workorder");
  await click(w, "[data-lowoback]"); await click(w, '[data-lokind="shipping"]', 300);
  await click(w, slot(w, 1, 2)); await snap(w); await click(w, slot(w, 1, 3)); await snap(w); await click(w, slot(w, 3, 1)); await snap(w); await click(w, slot(w, 3, 2)); await snap(w);
  await click(w, "[data-lopallet]"); await snap(w); await until(() => /Wrapped ✓/.test(txt(w)), 6000);
  type(w, "#loCarrier", "Estes"); type(w, "#loTracking", "BOL 44812"); await wait(200);
  save(w, "4-shipment", ".lostep:nth-of-type(2)");
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  for (const [n, h, focus] of shots) {
    await p.setContent(h, { waitUntil: "load" }); await p.waitForTimeout(200);
    if (n === "4-shipment") await p.evaluate(() => { const x = [...document.querySelectorAll(".lostep")].pop(); x.scrollIntoView({ block: "start" }); });
    await p.screenshot({ path: `/tmp/lo_${n}.png` });
  }
  await b.close(); console.log("shots:", shots.map(s => s[0]).join(", ")); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```
