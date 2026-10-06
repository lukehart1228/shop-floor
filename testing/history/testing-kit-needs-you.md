# Testing kit — Part 4: Needs you and the compact tablet (23 Sep, late)

*For build chats. Luke doesn't need to read this.* Parts 1–3 still apply.

This change touched only `index.html` and `office.html` — no SQL, no new database calls. The office's Needs you tab reuses the same views and functions the old Your tasks / Problems / Ordering tabs called. So it was tested in real Chromium (Playwright) against a **stand-in Supabase** (`fakesupa.js` + `fixtures.js`), plus the kit's original tablet suites in jsdom, and then checked on the live site against the real database (read-only: Needs you showed the real 10 handoffs; a real sheet page loaded on the tablet).

## Setup (no Postgres needed)

```bash
cd /home/claude/work && npm init -y && npm install jsdom@24 playwright@1.56.0 @fontsource/barlow @fontsource/barlow-condensed
git clone https://github.com/lukehart1228/shop-floor.git /home/claude/live   # the live pages; orig/ = copies before the change
```

- **Google Fonts are blocked by the sandbox proxy** (403). The browser tests serve Barlow from the `@fontsource` npm packages instead (`shots.js`), so measurements use the real fonts.
- Chromium in the sandbox doesn't go through the proxy; serve pages from a local `http.server` and route the Supabase CDN script to `fakesupa.js`.
- `page.png` is a 1980×1530 placeholder work order page (PIL), about the size of a real 180-dpi page.
- The kit's `test_app_page.js` fake client needed one update since the photos build: queries now chain (`.select().eq().in()`), and tables other than `v_floor_sheets` return empty.

## Results when delivered

| Suite | Result |
|---|---|
| `test_app_core.js` (kit) | 19 PASS |
| `test_app_page.js` (kit, chaining fake) — same selectors and words, so counting, pager, offline, print and PDF are unchanged | 30 PASS on the old page and the new one |
| `test_needs.js` — Needs you actions, tab migration, empty state, narrow window; tablet sizes and counting in Chromium | 43 PASS (fails on the old pages, as it should) |
| `shots.js` — measurements, 1280×800 tablet: header 110→52px, pager 71→40, counter 212→82, work order page starts at 340px instead of 645 (155px→460px of it visible without scrolling) | — |
| Live check after commit `f2e2749` | both files byte-for-byte (SHA-256) on GitHub Pages |

## How it was put live

Claude in Chrome on the GitHub upload page: the page fetched the live files from raw.githubusercontent.com, checked their SHA-256 against the versions the build started from, applied a line patch in the browser, checked the result's SHA-256 against the tested files, then attached both via the file input's `DataTransfer` and committed. Chrome's tool output hides hex strings, so compare hashes inside the page and return true/false.

## Files

#### fakesupa.js

```javascript
/* A stand-in for supabase-js, served in place of the CDN file during browser tests.
   Tables come from window.__FIX.tables; RPCs from window.__FIX.rpc (functions of (args, FIX)).
   Every call is recorded in window.__calls. */
(function () {
  const FIX = window.__FIX || { tables: {}, rpc: {} };
  const calls = window.__calls = [];
  const clone = (x) => JSON.parse(JSON.stringify(x));
  function query(table) {
    const f = []; let single = null; let upd = null;
    const q = {
      select() { return q; },
      update(v) { upd = v; return q; },
      eq(c, v) { f.push(r => r[c] === v); return q; },
      neq(c, v) { f.push(r => r[c] !== v); return q; },
      in(c, a) { f.push(r => a.includes(r[c])); return q; },
      gte(c, v) { f.push(r => r[c] >= v); return q; },
      order() { return q; }, limit() { return q; },
      maybeSingle() { single = "maybe"; return q; },
      single() { single = "one"; return q; },
      then(res, rej) {
        calls.push({ table, upd });
        const rows = (FIX.tables[table] || []).filter(r => f.every(fn => fn(r)));
        if (upd) { rows.forEach(r => Object.assign(r, upd)); return Promise.resolve({ data: clone(rows), error: null }).then(res, rej); }
        let out = { data: clone(rows), error: null };
        if (single) out = { data: rows[0] ? clone(rows[0]) : null, error: null };
        return Promise.resolve(out).then(res, rej);
      },
    };
    return q;
  }
  const client = {
    auth: {
      getSession: async () => ({ data: { session: FIX.user ? { user: FIX.user } : null } }),
      signInWithPassword: async () => ({ data: { user: FIX.user }, error: null }),
      signOut: async () => ({}),
    },
    from: (t) => query(t),
    rpc: async (name, args) => {
      calls.push({ rpc: name, args });
      const fn = FIX.rpc && FIX.rpc[name];
      if (!fn) return { data: null, error: { message: `Could not find the function ${name} in the schema cache` } };
      try { return { data: fn(args || {}, FIX), error: null }; } catch (e) { return { data: null, error: { message: e.message } }; }
    },
    storage: { from: () => ({
      download: async () => { const r = await fetch("/page.png"); return { data: await r.blob(), error: null }; },
      createSignedUrl: async () => ({ data: { signedUrl: window.__PHOTO || "data:," }, error: null }),
      upload: async () => ({ data: {}, error: null }),
      remove: async () => ({ data: [], error: null }),
    }) },
  };
  window.supabase = { createClient: () => client };
})();
```

#### fixtures.js

```javascript
/* Test data for the browser tests. window.__SCENARIO picks the login. */
(function () {
  const today = new Date();
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const daysAgo = (n) => new Date(today.getTime() - n * 86400000).toISOString();
  const dayISO = (n) => iso(new Date(today.getTime() + n * 86400000));

  const q = [1, 2, 2, 3, 3, 3, 4, 1, 1], codes = ['TB-03', 'TB-03', 'TB-03', 'TB-04', 'TB-04', 'TB-06', 'WMT-DAN-DIN', 'WMT-DAN-DIN', 'TB-01'];
  const sheets418 = q.map((n, i) => ({
    progress_id: `p418-${i + 1}`, department: "sanding", qty_done: i < 3 ? n : 0, qty_required: n, state: i < 3 ? "complete" : "not_started",
    sheet_id: `s418-${i + 1}`, sheet_number: i + 1, item_code: codes[i], species: "Ash", shape: "Rectangle", width: '36"', length: '36"', thickness: '1.25"',
    png_path: `PROJ-00418/v1/sheet-${i + 1}.png`, pdf_path: `PROJ-00418/v1/sheet-${i + 1}.pdf`, pages_ready: true, work_order_id: "wo418", version: 1,
    job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", delivery_date: dayISO(55),
    materials_ordered: false, is_test: false }));
  const sheets099 = [1, 2, 3].map(i => ({ ...sheets418[0], progress_id: `p099-${i}`, sheet_id: `s099-${i}`, sheet_number: i, item_code: "DSK-0" + i,
    species: "Maple", qty_done: 0, qty_required: 3, state: "not_started", png_path: `PROJ-00099/v1/sheet-${i}.png`, pdf_path: `PROJ-00099/v1/sheet-${i}.pdf`,
    job_id: "job-099", project_id: "PROJ-00099", job_name: "Oaks Academy Q01092", delivery_date: dayISO(28), materials_ordered: true }));

  const people = [
    { id: "u-luke", full_name: "Luke H", role: "manager", departments: [], is_test: false, active: true },
    { id: "u-david", full_name: "David D", role: "manager", departments: [], is_test: false, active: true },
    { id: "u-mike", full_name: "Mike B", role: "supervisor", departments: ["sanding", "finishing"], is_test: false, active: true },
  ];
  const problems = [
    { id: "pr1", job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", job_active: true, sheet_number: 7,
      department: "sanding", department_name: "Sanding", body: "Glue line opened on the top overnight. Reglue or remake?", work_stopped: true, status: "open",
      came_back: false, is_test: false, raised_by_name: "Mike B", raised_at: daysAgo(0.1), thread: [] },
    { id: "pr2", job_id: "job-099", project_id: "PROJ-00099", job_name: "Oaks Academy Q01092", job_active: true, sheet_number: null,
      department: "sanding", department_name: "Sanding", body: "Which grit for the desk edges?", work_stopped: false, status: "open",
      came_back: false, is_test: false, raised_by_name: "Mike B", raised_at: daysAgo(1), thread: [] },
    { id: "pr3", job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", job_active: true, sheet_number: 2,
      department: "finishing", department_name: "Finishing", body: "Stain sample doesn't match the approved chip.", work_stopped: false, status: "answered",
      came_back: false, is_test: false, raised_by_name: "Mike B", raised_at: daysAgo(6), answered_at: daysAgo(5), answered_by_name: "Luke H",
      thread: [{ kind: "answer", body: "Use the chip in the office — it's the approved one.", by: "Luke H", at: daysAgo(5) }] },
  ];
  const flags = [
    { id: "f1", job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", job_active: true, department: null, department_name: null,
      level: "priority", note: "Customer walkthrough — tops through finishing first", is_test: false, set_by_name: "Luke H", set_at: daysAgo(16), age_days: 16, is_open: true },
    { id: "f2", job_id: "job-099", project_id: "PROJ-00099", job_name: "Oaks Academy Q01092", job_active: true, department: null, department_name: null,
      level: "watch", note: "Customer may change the stain", is_test: false, set_by_name: "David D", set_at: daysAgo(2), age_days: 2, is_open: true },
  ];
  const sup = (id, dept, item, qty, state, extra = {}) => ({ id, department: dept, department_name: dept[0].toUpperCase() + dept.slice(1), item, qty, note: null, state,
    is_test: false, requested_by_name: "Mike B", requested_at: daysAgo(2), updated_at: daysAgo(1), is_open: state === "requested" || state === "ordered", events: [], ...extra });
  const supplies = [
    sup("r1", "sanding", "120 grit discs, 6 inch, hook and loop", 4, "requested", { note: "the yellow box" }),
    sup("r2", "sanding", "Tack cloths", 2, "requested"),
    sup("r3", "metal", "MIG wire .030", 1, "requested", { requested_by_name: "Willie J" }),
    sup("r4", "finishing", "Pre-cat lacquer, 5 gal", 1, "ordered", { ordered_by_name: "David D", ordered_at: daysAgo(3) }),
    sup("r5", "sanding", "Dust masks", 1, "received", { received_by_name: "Mike B", received_at: daysAgo(4), updated_at: daysAgo(4) }),
  ];
  const arrow = [
    { id: "a1", job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", sheet_numbers: [6, 9], description: "Bases, denim black",
      service: "powdercoat", department: "metal", department_name: "Metal", is_test: false, sent_on: dayISO(-22), sent_by_name: "Willie J", at_vendor: true, days_out: 22, voided: false },
    { id: "a2", job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", sheet_numbers: [], description: "8 brackets",
      service: "paint", department: "metal", department_name: "Metal", is_test: false, sent_on: dayISO(-3), sent_by_name: "Willie J", at_vendor: true, days_out: 3, voided: false },
  ];
  const defects = [
    { id: "d1", job_id: "job-418", project_id: "PROJ-00418", sheet_number: 4, department: "sanding", department_name: "Sanding", defect_type: "Caused defect — caught before finish", logged_at: daysAgo(1), logged_by_name: "Mike B", voided: false, is_test: false },
    { id: "d2", job_id: "job-418", project_id: "PROJ-00418", sheet_number: 2, department: "sanding", department_name: "Sanding", defect_type: "Missed defect — caught after finish", logged_at: daysAgo(2), logged_by_name: "Mike B", voided: false, is_test: false },
  ];
  const archive = { due: false, eligible: 0, eligible_bytes: 0, to_remove: 0, building: null, last_batch: null, days_since_last: null,
    bytes_all: 2097152, bytes_photos: 0, bytes_work_orders: 2097152, free_plan_bytes: 1073741824, photos_in_cloud: 0, batches: [] };

  const S = window.__SCENARIO || "mike";
  const user = { mike: { id: "u-mike", email: "mike@example.com" }, luke: { id: "u-luke", email: "luke@example.com" },
                 lukeTablet: { id: "u-luke", email: "luke@example.com" } }[S];
  const empty = window.__EMPTY === true;
  window.__FIX = {
    user,
    tables: {
      profiles: people,
      v_floor_sheets: [...sheets418, ...sheets099],
      sheet_progress: [...sheets418, ...sheets099].map(r => ({ id: r.progress_id, qty_done: r.qty_done, state: r.state })),
      v_flags: empty ? [] : flags,
      v_routine_tasks: [],
      defect_types: [{ id: "t1", department: "sanding", label: "Missed defect — caught after finish", sort_order: 1, active: true }],
      v_pick_jobs: [], v_pick_sheets: [], v_photos: [], v_loadouts: [], v_qc_entries: [],
      v_problems: empty ? [] : problems,
      v_defects: defects,
      v_supply_requests: S === "mike" ? [] : (empty ? [] : supplies),
      v_outside_jobs: empty ? [] : arrow,
      app_settings: [{ key: "arrow_alert_days", value: 14 }],
      v_handoff_tasks: empty ? [] : [
        { job_id: "job-500", project_id: "PROJ-00501", job_name: "Riverside Library", phase: "Pre-Production", delivery_date: dayISO(12), handed_off_text: "No" },
        { job_id: "job-501", project_id: "PROJ-00502", job_name: "Northside Cafe", phase: "In Production", delivery_date: dayISO(30), handed_off_text: null }],
      monday_columns: [{ key: "handed_off", what: "Handed Off", title: "Handed Off", column_id: "color_ho", col_type: "status", yes_label: "Yes", sort_order: 1, labels: [] }],
      departments: [], department_live_log: [], monday_sync_log: [], v_uploaded_jobs: [], monday_stage_map: [], jobs: [],
    },
    rpc: {
      photo_archive_status: () => archive,
      catch_up_preview: () => [],
      answer_problem: (a, F) => { const p = F.tables.v_problems.find(x => x.id === a.p_problem);
        p.thread.push({ kind: a.p_close ? "answer" : "office_note", body: a.p_body, by: "Luke H", at: new Date().toISOString() });
        if (a.p_close) { p.status = "answered"; p.answered_at = new Date().toISOString(); p.answered_by_name = "Luke H"; }
        return { ok: true, summary: a.p_close ? "Answered and closed." : "Reply sent; it stays open." }; },
      order_supplies: (a, F) => { let n = 0; F.tables.v_supply_requests.forEach(r => { if (a.p_requests.includes(r.id) && r.state === "requested") { r.state = "ordered"; r.ordered_by_name = "Luke H"; r.ordered_at = new Date().toISOString(); n++; } });
        return { ok: true, ordered: n, summary: `${n} line${n === 1 ? "" : "s"} marked ordered.` }; },
      not_ordering_supply: (a, F) => { if (!a.p_reason.trim()) throw new Error("Give a reason — the supervisor sees it."); const r = F.tables.v_supply_requests.find(x => x.id === a.p_request);
        Object.assign(r, { state: "not_ordering", is_open: false, not_ordering_reason: a.p_reason, closed_by_name: "Luke H", closed_at: new Date().toISOString(), updated_at: new Date().toISOString() });
        return { ok: true, summary: "Marked not ordering. The department sees your reason." }; },
      receive_supply: (a, F) => { const r = F.tables.v_supply_requests.find(x => x.id === a.p_request);
        Object.assign(r, { state: "received", is_open: false, received_by_name: "Luke H", received_at: new Date().toISOString(), updated_at: new Date().toISOString() });
        return { ok: true, summary: `${r.qty} × ${r.item} received.` }; },
      clear_flag: (a, F) => { const f = F.tables.v_flags.find(x => x.id === a.p_flag); f.is_open = false; f.cleared_at = new Date().toISOString(); f.cleared_by_name = "Luke H"; return "Flag cleared. It's kept in the history."; },
      return_from_arrow: (a, F) => { const x = F.tables.v_outside_jobs.find(o => o.id === a.p_item); x.at_vendor = false; x.returned_on = dayISO(0); x.returned_by_name = "Luke H";
        return { ok: true, summary: `${x.project_id} back from Arrow after ${x.days_out} days.` }; },
    },
  };
})();
```

#### test_needs.js

```javascript
// The office's "Needs you" tab and the compact tablet, in real Chromium with the stand-in database.
const fs = require("fs"), path = require("path"), http = require("http");
const { chromium } = require("playwright");
const SRC = process.env.SRC || "..";
const files = { "/index.html": path.join(SRC, "index.html"), "/office.html": path.join(SRC, "office.html"), "/page.png": "page.png" };
const server = http.createServer((req, res) => { const f = files[req.url.split("?")[0]]; if (!f) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": f.endsWith(".png") ? "image/png" : "text/html" }); res.end(fs.readFileSync(f)); });
let pass = 0, fail = 0; const errors = [];
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const wait = (ms) => new Promise(r => setTimeout(r, ms));

async function open(browser, scenario, page, { vp = { width: 1366, height: 900 }, extra = "" } = {}) {
  const ctx = await browser.newContext({ viewport: vp, serviceWorkers: "block" });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await ctx.route(/supabase-js/, r => r.fulfill({ contentType: "application/javascript", body: fs.readFileSync("fakesupa.js") }));
  await ctx.addInitScript(`window.__SCENARIO=${JSON.stringify(scenario)}; localStorage.setItem("sfo_pin", JSON.stringify({none:true})); window.confirm = () => true; ${extra}`);
  await ctx.addInitScript({ path: path.resolve("fixtures.js") });
  const p = await ctx.newPage();
  p.on("pageerror", e => errors.push(`${scenario}/${page}: ${e.message}`));
  await p.goto(`http://127.0.0.1:${server.address().port}/${page}`); await p.waitForTimeout(700);
  return p;
}
const text = (p, sel = "#app") => p.$eval(sel, e => e.textContent.replace(/\s+/g, " "));
const rpcs = (p) => p.evaluate(() => window.__calls.filter(c => c.rpc).map(c => c.rpc));

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const browser = await chromium.launch();

  // ---------- the office ----------
  let p = await open(browser, "luke", "office.html");
  const tabs = await p.$$eval(".tab", t => t.map(x => x.childNodes[0].textContent));
  ok("seven tabs: Needs you · Flags · Arrow · Routine tasks · Departments · Photos · Setup", tabs.join(" · ") === "Needs you · Flags · Arrow · Routine tasks · Departments · Photos · Setup", tabs.join("|"));
  ok("only Needs you carries a number: 2 problems + 3 to order + 1 flag + 1 Arrow + 2 handoffs = 9", (await p.$$eval(".tab .n", n => n.map(x => x.textContent))).join() === "9");
  ok("the header is one row, about half its old height (≤ 52px, was 99)", (await p.$eval("header.top", e => e.getBoundingClientRect().height)) <= 52);
  const order = await p.$$eval("section.need", s => s.map(x => x.dataset.need));
  ok("sections in order: problems, ordering, flags, arrow, handoffs", order.join(",") === "problems,ordering,flags,arrow,handoffs", order.join(","));
  const probs = await p.$$eval('[data-need="problems"] .li', l => l.map(x => x.textContent.replace(/\s+/g, " ")));
  ok("work-stopped problem first", /PROJ-00418 · sheet 7.*Work stopped/.test(probs[0]) && /PROJ-00099 · whole job/.test(probs[1]));
  ok("the answered problem is folded away, not in the list", probs.length === 2 && /Answered problems — last 30 days \(1\)/.test(await text(p)));
  ok("the answer buttons wait for typing", await p.$eval('[data-answer="pr1"][data-close="1"]', b => b.disabled));
  await p.fill('[data-draft="pr1"]', "Remake the top; new blank Monday.");
  ok("...and wake up when something's typed", !(await p.$eval('[data-answer="pr1"][data-close="1"]', b => b.disabled)));
  await p.click('[data-answer="pr1"][data-close="1"]'); await wait(400);
  ok("Answer and close calls answer_problem with close = true", (await p.evaluate(() => window.__calls.find(c => c.rpc === "answer_problem").args)).p_close === true);
  ok("...the plain answer shows at the top, the problem leaves the list", /Answered and closed/.test(await text(p)) && (await p.$$('[data-need="problems"] .li')).length === 1);
  ok("...and the count drops to 8", (await p.$eval(".tab .n", n => n.textContent)) === "8");
  await p.fill('[data-draft="pr2"]', "Use 180 on the edges."); await p.click('[data-answer="pr2"][data-close="0"]'); await wait(400);
  ok("Reply, keep it open: stays in the list, marked 'You replied — still open'", /You replied — still open/.test(await text(p, '[data-need="problems"]')));

  ok("the order button waits for a tick", await p.$eval("[data-order]", b => b.disabled));
  await p.check('[data-otick="r1"]'); await p.check('[data-otick="r2"]'); await wait(100);
  ok("tick two: 'Mark 2 ticked as ordered'", /Mark 2 ticked as ordered/.test(await p.$eval("[data-order]", b => b.textContent)));
  await p.click("[data-order]"); await wait(400);
  const ordArgs = await p.evaluate(() => window.__calls.find(c => c.rpc === "order_supplies").args.p_requests);
  ok("order_supplies gets exactly the two ticked lines (no catch-up ids mixed in)", JSON.stringify(ordArgs.sort()) === '["r1","r2"]', JSON.stringify(ordArgs));
  ok("they leave 'Supplies to order'; the metal line stays", (await p.$$('[data-need="ordering"] [data-otick]')).length === 1);
  ok("...and appear under 'Ordered, not received (3)'", /Ordered, not received \(3\)/.test(await text(p)));
  await p.click('[data-noopen="r3"]'); await p.fill("[data-noreason]", "We have a spool in the back"); await p.click('[data-nosave="r3"]'); await wait(400);
  ok("Not ordering, with the reason: the section empties and goes", !(await p.$('[data-need="ordering"]')) && /Supply requests closed — last 60 days \(2\)/.test(await text(p)));

  await p.click('[data-need="flags"] [data-clearflag="f1"]'); await wait(400);
  ok("Clear it on the stale flag: clear_flag called, section gone", (await rpcs(p)).includes("clear_flag") && !(await p.$('[data-need="flags"]')));
  await p.click('[data-need="arrow"] [data-arret="a1"]'); await wait(400);
  ok("Mark returned on the Arrow item: section gone", (await rpcs(p)).includes("return_from_arrow") && !(await p.$('[data-need="arrow"]')));

  await p.click('details[data-keep="ordered"] summary'); await wait(100);
  ok("a folded section opens", await p.$eval('details[data-keep="ordered"]', d => d.open));
  await p.click('[data-oreceive="r4"]'); await wait(400);
  ok("Mark received inside it works, and the section stays open after the refresh", (await rpcs(p)).includes("receive_supply") && await p.$eval('details[data-keep="ordered"]', d => d.open));
  await p.click('details[data-keep="defects"] summary'); await p.click('[data-deffrom="all"]'); await wait(100);
  ok("Defects logged: switching to All time keeps it open, Sanding — 2", await p.$eval('details[data-keep="defects"]', d => d.open) && /Sanding — 2/.test(await text(p, 'details[data-keep="defects"]')));

  for (const t of ["flags", "arrow", "routine", "departments", "photos", "setup"]) {
    await p.click(`.tab[data-tab="${t}"]`); await wait(300);
    ok(`the ${t} tab still opens`, await p.$eval(`.tab[data-tab="${t}"]`, b => b.getAttribute("aria-current") === "true") && (await text(p, "main")).length > 50);
  }
  await p.context().close();

  p = await open(browser, "luke", "office.html", { extra: 'localStorage.setItem("sfo_tab", JSON.stringify("ordering"));' });
  ok("a computer that remembered the old Ordering tab opens on Needs you", await p.$eval('.tab[data-tab="tasks"]', b => b.getAttribute("aria-current") === "true") && /Needs you/.test(await text(p, "h1")));
  await p.context().close();
  p = await open(browser, "luke", "office.html", { extra: "window.__EMPTY=true;" });
  ok("nothing waiting: 'Nothing needs you', no number on the tab", /Nothing needs you/.test(await text(p)) && !(await p.$(".tab .n")));
  await p.context().close();
  p = await open(browser, "luke", "office.html", { vp: { width: 820, height: 1000 } });
  ok("a narrow window: the tabs scroll inside the one-row header, no page-wide scroll",
     await p.evaluate(() => document.documentElement.scrollWidth <= innerWidth) && (await p.$eval("header.top", e => e.getBoundingClientRect().height)) <= 52);
  await p.context().close();

  // ---------- the tablet, in a real browser ----------
  p = await open(browser, "mike", "index.html", { vp: { width: 1280, height: 800 } });
  ok("tablet header: one row, 52px (was 110)", (await p.$eval("header.top", e => e.getBoundingClientRect().height)) <= 53);
  await p.click('[data-job="job-418"]'); await wait(200);
  ok("job screen: back, PROJ number and job line on one line", await p.$eval(".head", e => e.getBoundingClientRect().height < 50));
  await p.click('[data-sheet="p418-4"]'); await wait(500);
  const g = await p.evaluate(() => { const b = (s) => document.querySelector(s).getBoundingClientRect();
    return { head: b(".head").height, pager: b(".pager").height, counter: b(".counter").height, step: b('.counter [data-step="1"]').width, page: b("#page").top }; });
  ok("sheet screen: title line under 50px", g.head < 50, JSON.stringify(g));
  ok("pager about half height: 40px (was 71)", g.pager <= 42);
  ok("counter on one row: ≤ 84px (was 212), + and − are 60px", g.counter <= 84 && g.step === 60);
  ok("the work order starts ~300px higher: at ≤ 345px (was 645)", g.page <= 345);
  await p.click('[data-step="1"]'); await wait(300);
  ok("tap +: 1 of 3, sent as the number itself", (await p.$eval(".readout .n", e => e.textContent)) === "1" && (await p.evaluate(() => window.__calls.filter(c => c.upd).pop().upd.qty_done)) === 1);
  await p.click("[data-all]"); await wait(300);
  const done = await p.evaluate(() => { const c = document.querySelector(".counter .complete"); return c && { h: c.getBoundingClientRect().height, t: c.textContent }; });
  ok("Mark all done: 'Sheet complete' sits in the same row", done && done.t === "Sheet complete" && done.h === 60 && (await p.$eval(".counter", e => e.getBoundingClientRect().height)) <= 84);
  await p.click('.pager [data-goto]:not([disabled]):last-of-type'); await wait(400);
  ok("Next moves to sheet 5", /Sheet 5 · TB-04/.test(await text(p, ".head h1")));
  await p.context().close();
  p = await open(browser, "mike", "index.html", { vp: { width: 600, height: 900 } });
  await p.click('[data-job="job-418"]'); await wait(200); await p.click('[data-sheet="p418-4"]'); await wait(400);
  ok("a narrow screen: the counter wraps instead of overflowing", await p.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await p.context().close();

  ok("no script errors on any page", errors.length === 0, errors.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### shots.js

```javascript
// Screenshots and measurements in real Chromium, with the stand-in database.
// node shots.js orig|new
const fs = require("fs"), path = require("path"), http = require("http");
const { chromium } = require("playwright");
const V = process.argv[2] || "new";
const SRC = V === "orig" ? "../orig" : "..";
const OUT = `/home/claude/work/shots/${V}`; fs.mkdirSync(OUT, { recursive: true });
const LIVE = "/home/claude/live";
const files = { "/index.html": path.join(SRC, "index.html"), "/office.html": path.join(SRC, "office.html"), "/page.png": "page.png",
  "/manifest.webmanifest": path.join(LIVE, "manifest.webmanifest"), "/icon-192.png": path.join(LIVE, "icon-192.png") };
const server = http.createServer((req, res) => {
  const f = files[req.url.split("?")[0]];
  if (!f) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": f.endsWith(".png") ? "image/png" : f.endsWith(".woff2") ? "font/woff2" : f.endsWith(".html") ? "text/html" : "application/json" });
  res.end(fs.readFileSync(f));
});
const FD = "/home/claude/work/node_modules/@fontsource";
const face = (fam, dir, w) => `@font-face{font-family:'${fam}';font-weight:${w};font-style:normal;src:url(http://127.0.0.1:${server.address().port}/font/${dir}-latin-${w}-normal.woff2) format('woff2')}`;
const FONTCSS = () => [400, 500, 600, 700].map(w => face("Barlow", "barlow", w)).join("") + [600, 700].map(w => face("Barlow Condensed", "barlow-condensed", w)).join("");
for (const w of [400, 500, 600, 700]) files[`/font/barlow-latin-${w}-normal.woff2`] = `${FD}/barlow/files/barlow-latin-${w}-normal.woff2`;
for (const w of [600, 700]) files[`/font/barlow-condensed-latin-${w}-normal.woff2`] = `${FD}/barlow-condensed/files/barlow-condensed-latin-${w}-normal.woff2`;
const wait = (ms) => new Promise(r => setTimeout(r, ms));

async function open(browser, scenario, page, viewport, extra = "") {
  const ctx = await browser.newContext({ viewport, serviceWorkers: "block", deviceScaleFactor: 1 });
  await ctx.route(/fonts\.googleapis\.com/, r => r.fulfill({ contentType: "text/css", body: FONTCSS() }));
  await ctx.route(/fonts\.gstatic\.com/, r => r.abort());
  await ctx.route(/supabase-js/, r => r.fulfill({ contentType: "application/javascript", body: fs.readFileSync("fakesupa.js") }));
  await ctx.addInitScript(`window.__SCENARIO=${JSON.stringify(scenario)}; try{localStorage.setItem("sfo_pin", JSON.stringify({none:true}))}catch(e){} ${extra}`);
  await ctx.addInitScript({ path: path.resolve("fixtures.js") });
  const p = await ctx.newPage();
  p.on("pageerror", e => console.log("PAGE ERROR", scenario, e.message));
  await p.goto(`http://127.0.0.1:${server.address().port}/${page}`);
  await p.waitForTimeout(900);
  return p;
}
const box = (p, sel) => p.evaluate((s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return { top: Math.round(r.top + scrollY), h: Math.round(r.height) }; }, sel);

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const browser = await chromium.launch();
  const m = {};
  for (const [name, vp] of [["portrait", { width: 800, height: 1280 }], ["landscape", { width: 1280, height: 800 }]]) {
    for (const who of ["mike", "lukeTablet"]) {
      const p = await open(browser, who, "index.html", vp, who === "lukeTablet" ? 'localStorage.setItem("sf_dept", JSON.stringify("sanding"));' : "");
      await p.screenshot({ path: `${OUT}/tablet-${who}-${name}-queue.png` });
      await p.click('[data-job="job-418"]'); await wait(300);
      await p.screenshot({ path: `${OUT}/tablet-${who}-${name}-job.png` });
      await p.click('[data-sheet="p418-4"]'); await wait(700);
      await p.screenshot({ path: `${OUT}/tablet-${who}-${name}-sheet.png` });
      m[`${who}-${name}`] = { header: await box(p, "header.top"), pager: await box(p, ".pager"), counter: await box(p, ".counter"), page: await box(p, "#page"),
                              visibleOfPage: await p.evaluate(() => { const e = document.querySelector("#page"); return Math.max(0, Math.round(innerHeight - e.getBoundingClientRect().top)); }) };
      await p.context().close();
    }
  }
  const o = await open(browser, "luke", "office.html", { width: 1366, height: 768 });
  await o.screenshot({ path: `${OUT}/office-first-tab.png`, fullPage: true });
  await o.screenshot({ path: `${OUT}/office-first-tab-fold.png` });
  m.office = { header: await box(o, "header.top"), tabs: await o.$$eval(".tab", t => t.map(x => x.textContent)) };
  await o.context().close();
  const e = await open(browser, "luke", "office.html", { width: 1366, height: 768 }, "window.__EMPTY=true;");
  await e.screenshot({ path: `${OUT}/office-empty.png` });
  await e.context().close();
  console.log(JSON.stringify(m, null, 1));
  fs.writeFileSync(`${OUT}/measure.json`, JSON.stringify(m, null, 1));
  await browser.close(); server.close();
})().catch(e => { console.error(e); process.exit(1); });
```

#### mkrows.js

```javascript
// rows shaped like v_floor_sheets for Mike (sanding), PROJ-00418 as seeded in the testing kit
const q = [1,2,2,3,3,3,4,1,1], codes = ['TB-03','TB-03','TB-03','TB-04','TB-04','TB-06','WMT-DAN-DIN','WMT-DAN-DIN','TB-01'];
const rows = q.map((n, i) => ({
  progress_id: `00000000-0000-4000-8000-0000000004${String(i+1).padStart(2,"0")}`, department: "sanding",
  qty_done: i < 3 ? n : 0, qty_required: n, state: i < 3 ? "complete" : "not_started",
  sheet_id: `s418-${i+1}`, sheet_number: i + 1, item_code: codes[i], species: "Ash", shape: "Rectangle", width: '36"', length: '36"', thickness: '1.25"',
  png_path: null, pdf_path: null, pages_ready: false, work_order_id: "wo418", version: 1,
  job_id: "job-418", project_id: "PROJ-00418", job_name: "Enid's Table Restaurant and Bookstore", delivery_date: "2026-11-17",
  materials_ordered: false, is_test: false }));
require("fs").writeFileSync("/tmp/rows_sanding.json", JSON.stringify(rows));
console.log(rows.length, "rows; done", rows.reduce((a, x) => a + x.qty_done, 0), "of", rows.reduce((a, x) => a + x.qty_required, 0));
```

