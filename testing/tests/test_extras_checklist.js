// 16 Oct: extras on Delivery's trips (delivery_extras.sql + index.html 2026-10-16.2). Each sheet's extras (from the
// generator's upload file) show on Shawn's phone at the dock as "Don't forget — extras", ticked off as they're loaded
// (the number itself, through set_extra_loaded), with leaving short asked about, not refused.
//   Load delivery_extras.sql (and install_log.sql), seed, then:
//   TZ=America/Indiana/Indianapolis node test_extras_checklist.js
// OLDDB=1 on a database without delivery_extras.sql: no extras block, nothing breaks, the Work order button still works.
// PAGE=/home/claude/sf/repo/index.html runs it on the page before, where it fails.
const fs = require("fs");
const crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
const OLDDB = !!process.env.OLDDB;
const HTML = fs.readFileSync(PAGE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(HTML, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  let n = 0; w.Blob = Blob; w.URL.createObjectURL = () => "blob:t" + (n++); w.URL.revokeObjectURL = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.print = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.open = () => null;
  Object.defineProperty(w, "sfPdfjs", { get() { return { getDocument: () => ({ promise: Promise.reject(new Error("no viewer")) }) }; } });
  w.eval([...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w) => ($(w, "#app") || {}).textContent.replace(/\s+/g, " ") || "";
const modal = (w) => (($(w, ".mdl") || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 200) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const card = (w, name) => $$(w, ".locard").find(c => (c.querySelector(".size") || {}).textContent === name);
const cnt = (w, name) => { const c = card(w, name); return c ? c.querySelector(".cnt").textContent : "none"; };
const btnIn = (w, name, re) => { const c = card(w, name); return c && [...c.querySelectorAll("button")].find(b => re.test(b.textContent.trim())); };
const q = (sql, a) => admin.query(sql, a);
const loaded = async (pid, name) => (await q(`select x.loaded from loadout_extras x join loadouts l on l.id = x.loadout_id join jobs j on j.id = l.job_id
  where j.project_id = $1 and x.name = $2 and l.voided_at is null order by x.at desc limit 1`, [pid, name])).rows.map(r => r.loaded)[0];
async function openTrip(w, pid, nth = 0) {
  if ($(w, "[data-lowoback]")) await click(w, "[data-lowoback]", 300);
  if ($(w, "[data-loback]")) await click(w, "[data-loback]", 600);
  if ($(w, '[data-tab="loadout"]')) await click(w, '[data-tab="loadout"]', 400);
  await until(() => $$(w, "[data-loopen]").filter(b => b.textContent.includes(pid)).length > nth);
  await click(w, $$(w, "[data-loopen]").filter(b => b.textContent.includes(pid))[nth], 600);
  await until(() => !/Loading the sheets/.test(txt(w)) && /At the|Each table|Every table/.test(txt(w)), 5000);
  await wait(400);
}

(async () => {
  const luke = makeClient(users.luke);
  const job = (pid) => q("select id from jobs where project_id = $1", [pid]).then(r => r.rows[0].id);
  const call = async (fn, args) => { const r = await luke.rpc(fn, args); if (r.error) throw new Error(fn + ": " + r.error.message); return r.data; };
  const tomorrow = new Date(Date.now() + 86400000); tomorrow.setHours(9, 0, 0, 0);
  if (!OLDDB) {
    // PROJ-00418: extras added to its current work order as the upload would (keeps its pages)
    await q(`insert into sheet_extras (sheet_id, position, name, qty)
             select s.id, x.pos, x.name, x.qty from work_orders w join jobs j on j.id = w.job_id join sheets s on s.work_order_id = w.id
             join (values (1, 1, 'Data port', 4), (1, 2, 'Grommet', 3), (3, 1, 'Cabinet shelf', 2)) x(sheet, pos, name, qty) on x.sheet = s.sheet_number
             where j.project_id = 'PROJ-00418' and w.is_current`);
    await q(`insert into work_order_extras (work_order_id, extras) select w.id, 3 from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00418' and w.is_current`);
    // PROJ-00502: a work order uploaded through the upload function by Luke, listing no extras
    const r = await call("upload_work_order", { payload: { project_id: "PROJ-00502", total_items: 2, sheets: [
      { sheet_number: 1, item_code: "X-1", qty: 1, departments: ["sanding"], extras: [] }, { sheet_number: 2, item_code: "X-2", qty: 1, departments: ["sanding"], extras: [] }] } });
    ok("Luke's upload with an empty extras list is saved and marked as listing them", r.ok && r.extras_listed === true && r.extras === 0, JSON.stringify({ e: r.extras, l: r.extras_listed }));
    // PROJ-00099: uploaded with an extra on sheet 2
    const r2 = await call("upload_work_order", { payload: { project_id: "PROJ-00099", total_items: 9, sheets: [
      { sheet_number: 1, item_code: "DSK-01", qty: 3, departments: ["sanding"] },
      { sheet_number: 2, item_code: "DSK-02", qty: 3, departments: ["sanding"], extras: [{ name: "Cord tray", qty: 3 }] },
      { sheet_number: 3, item_code: "DSK-03", qty: 3, departments: ["sanding"] }] } });
    ok("Luke's upload with an extra on sheet 2 saves it", r2.ok && r2.extras === 1, JSON.stringify({ e: r2.extras }));
    const bad = await luke.rpc("upload_work_order", { payload: { project_id: "PROJ-00099", sheets: [{ sheet_number: 1, item_code: "DSK-01", qty: 3, departments: ["sanding"], extras: [{ name: "Cord tray", qty: 0 }] }] } });
    ok("A bad extras list is refused through the same login path, in plain words", bad.error && /^Sheet 1: the extra "Cord tray" needs a whole-number quantity/.test(bad.error.message), bad.error ? bad.error.message : "accepted");
  }
  const dcid = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: tomorrow.toISOString(), p_note: "Back dock", p_loadout: null, p_client_id: dcid });
  await call("schedule_delivery", { p_job: await job("PROJ-00501"), p_when: tomorrow.toISOString(), p_note: null, p_loadout: null, p_client_id: crypto.randomUUID(), p_kind: "dock" });
  await call("schedule_delivery", { p_job: await job("PROJ-00502"), p_when: tomorrow.toISOString(), p_note: null, p_loadout: null, p_client_id: crypto.randomUUID(), p_kind: "dock" });
  await call("schedule_pickup", { p_job: await job("PROJ-00099"), p_kind: "shipping", p_note: null, p_loadout: null, p_client_id: crypto.randomUUID() });

  let { w } = boot(users.shawn);
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);

  if (OLDDB) {
    await openTrip(w, "PROJ-00418");
    ok("Older database: no extras block, and nothing else changes", !/Don't forget/.test(txt(w)) && /At the site/.test(txt(w)) && !$(w, "[data-xset]"));
    ok("…the Work order button still works", !!$(w, "[data-lowoall]"));
    await click(w, "[data-lowoall]", 300); ok("…and opens", /Sheet 1 of 9/.test(txt(w)));
    console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
  }

  console.log("--- White glove, PROJ-00418: three extras on sheets 1 and 3");
  await openTrip(w, "PROJ-00418");
  ok("The trip shows Don't forget — extras, 0 of 3 loaded", /Don't forget — extras — 0 of 3 loaded/.test(txt(w)), (txt(w).match(/Don't forget[^]{0,40}/) || [""])[0]);
  ok("…one card per extra, with its sheet, name and quantity", cnt(w, "Data port") === "0 of 4" && cnt(w, "Grommet") === "0 of 3" && cnt(w, "Cabinet shelf") === "0 of 2"
     && card(w, "Data port").querySelector(".no").textContent === "1" && card(w, "Cabinet shelf").querySelector(".no").textContent === "3");
  const pos = (re) => txt(w).search(re);
  ok("…in step 1, after the truck photos and before The truck is leaving", pos(/1 · At the dock/) < pos(/Don't forget/) && pos(/Don't forget/) < pos(/Add another truck/) && pos(/Don't forget/) < pos(/2 · At the site/));
  await click(w, btnIn(w, "Data port", /^\+$/), 400);
  await until(async () => (await loaded("PROJ-00418", "Data port")) === 1);
  ok("+ on Data port: 1 of 4, and the trip records 1 loaded", cnt(w, "Data port") === "1 of 4" && (await loaded("PROJ-00418", "Data port")) === 1, cnt(w, "Data port"));
  await click(w, btnIn(w, "Data port", /^All 4 loaded$/), 400);
  await until(async () => (await loaded("PROJ-00418", "Data port")) === 4);
  ok("All 4 loaded: the card turns turquoise (done) and the trip records 4, the number itself", cnt(w, "Data port") === "4 of 4" && card(w, "Data port").classList.contains("done")
     && (await loaded("PROJ-00418", "Data port")) === 4 && /1 of 3 loaded/.test(txt(w)));
  ok("…+ can't go past the quantity, and the All button is gone", btnIn(w, "Data port", /^\+$/).disabled && !btnIn(w, "Data port", /^All/));
  await click(w, btnIn(w, "Data port", /^−$/), 400);
  await until(async () => (await loaded("PROJ-00418", "Data port")) === 3);
  ok("− takes one off (3), as a number, not an increment", cnt(w, "Data port") === "3 of 4" && (await loaded("PROJ-00418", "Data port")) === 3 && !card(w, "Data port").classList.contains("done"));
  const rows = (await q("select count(*)::int n from loadout_extras x join loadouts l on l.id = x.loadout_id where l.client_id = $1", [dcid])).rows[0].n;
  ok("One row per extra on the trip, however many taps", rows === 1, rows + " rows");
  await click(w, btnIn(w, "Cabinet shelf", /^Sheet 3$/), 400); await until(() => /sheet 3$/.test(($(w, "#lopage img") || {}).alt || ""));
  ok("The Sheet 3 button opens that sheet in the work order viewer", /^Work order$/.test($(w, "#app h1").textContent) && /Sheet 3 of 9/.test(txt(w)));
  await click(w, "[data-lowoback]", 400);
  ok("…and ← Delivery comes back to the trip", /Don't forget — extras/.test(txt(w)));

  console.log("--- No signal");
  setOffline(true);
  for (let i = 0; i < 3; i++) await click(w, btnIn(w, "Grommet", /^\+$/), 150);
  const waiting = Object.values(JSON.parse(w.localStorage.getItem(Object.keys(w.localStorage).find(k => /logbox/.test(k))) || "{}")).filter(e => e.fn === "set_extra_loaded");
  ok("With no signal, three taps on Grommet show 3 of 3 and wait as ONE entry, the number 3", cnt(w, "Grommet") === "3 of 3" && waiting.length === 1 && waiting[0].args.p_loaded === 3,
     `${cnt(w, "Grommet")}, ${waiting.length} waiting: ${waiting.map(e => e.args.p_loaded)}`);
  setOffline(false);
  w.dispatchEvent(new w.Event("online")); await wait(300);
  await until(async () => (await loaded("PROJ-00418", "Grommet")) === 3, 6000);
  ok("…and sends itself when the signal is back", (await loaded("PROJ-00418", "Grommet")) === 3);

  console.log("--- Leaving short");
  await click(w, "[data-lofinish]", 300);
  ok("The truck is leaving names what isn't loaded and asks", /Not loaded: Data port × 1 \(sheet 1\), Cabinet shelf × 2 \(sheet 3\)\. Leave anyway\?/.test(modal(w)), modal(w));
  await click(w, "[data-close]", 200);
  await click(w, btnIn(w, "Data port", /^All 4 loaded$/), 300);
  await click(w, btnIn(w, "Cabinet shelf", /^All 2 loaded$/), 300);
  await until(async () => (await loaded("PROJ-00418", "Cabinet shelf")) === 2);
  ok("Everything ticked: 3 of 3 loaded", /3 of 3 loaded/.test(txt(w)));
  await click(w, "[data-lofinish]", 300);
  ok("…and the question no longer mentions extras", /The truck is leaving/.test(modal(w)) && !/Not loaded/.test(modal(w)), modal(w));
  await click(w, "[data-confirm]", 800);
  await until(async () => (await q("select finished_at from loadouts where client_id = $1", [dcid])).rows[0].finished_at);
  await openTrip(w, "PROJ-00418");
  ok("After the truck left, the extras show as loaded with nothing to tap", /3 of 3 loaded/.test(txt(w)) && !$(w, "[data-xset]"));

  console.log("--- A second trip for the same job");
  const d2 = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: new Date(tomorrow.getTime() + 86400000).toISOString(), p_note: "Second trip", p_loadout: null, p_client_id: d2 });
  await q("update sheet_extras set qty = 6 from sheets s, work_orders w, jobs j where sheet_extras.sheet_id = s.id and s.work_order_id = w.id and w.job_id = j.id and j.project_id = 'PROJ-00418' and w.is_current and sheet_extras.name = 'Data port'");
  await openTrip(w, "PROJ-00418", 0);
  if (!/Second trip/.test(txt(w))) await openTrip(w, "PROJ-00418", 1);
  ok("(the second trip is the one open)", /Second trip/.test(txt(w)));
  ok("The second trip counts what went on the first: Data port 4 of 6, 4 went on an earlier trip",
     cnt(w, "Data port") === "4 of 6" && /4 went on an earlier trip/.test(card(w, "Data port").textContent) && card(w, "Grommet").classList.contains("done"), cnt(w, "Data port"));
  ok("…and only the rest can be added here (All 2 loaded)", !!btnIn(w, "Data port", /^All 2 loaded$/));
  const refused = await makeClient(users.shawn).rpc("set_extra_loaded", { p_loadout: dcid, p_sheet: 1, p_name: "Data port", p_loaded: 9, p_client_id: null });
  ok("The database refuses more than the quantity", !!refused.error && /from 0 to 6/.test(refused.error.message), refused.error ? refused.error.message : "accepted");
  const mike = await makeClient(users.mike).from("v_sheet_extras").select("*");
  ok("Mike (Sanding and Finishing) reads no extras through the same login path", !mike.error && mike.data.length === 0, mike.error ? mike.error.message : mike.data.length + " rows");

  console.log("--- Dock to dock, PROJ-00501 (uploaded before extras existed)");
  await openTrip(w, "PROJ-00501");
  ok("A work order uploaded before extras existed shows no extras section at all", !/Don't forget|Extras weren't listed/.test(txt(w)) && !$(w, "[data-xset]") && /At our dock/.test(txt(w)));
  console.log("--- Dock to dock, PROJ-00502 (listed, none)");
  await openTrip(w, "PROJ-00502");
  ok("A work order that listed no extras shows no extras block", !/Don't forget/.test(txt(w)));
  console.log("--- BOL pickup, PROJ-00099 (an extra on sheet 2)");
  await openTrip(w, "PROJ-00099");
  ok("The pickup shows its extra after the tables and pallets, before the BOL", cnt(w, "Cord tray") === "0 of 3"
     && txt(w).search(/Don't forget/) > txt(w).search(/2 · Each pallet/) && txt(w).search(/Don't forget/) < txt(w).search(/3 · The BOL/), cnt(w, "Cord tray"));
  await click(w, btnIn(w, "Cord tray", /^All 3 loaded$/), 400);
  await until(async () => (await loaded("PROJ-00099", "Cord tray")) === 3);
  ok("…and ticks off the same way", (await loaded("PROJ-00099", "Cord tray")) === 3 && card(w, "Cord tray").classList.contains("done"));

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
