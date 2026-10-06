# Testing kit — Part 8: deliveries (24 Sep, later)

*For build chats. Luke doesn't need to read this.* Parts 1–7 still apply (environment, "test as a real login", jsdom gaps). Part 5's `load.sh` / `fresh.sh` are unchanged.

This build added `deliveries.sql` (Julia's permission, `delivery_docs`, the `deliveries` bucket, truck and site photos, `complete_delivery()`, `v_deliveries`, `v_filing`, the archive additions, `check_deliveries()`) and `delivery.html`, and changed `index.html` and `office.html` (built on the Part 7 versions). Tested on a database built from **every live SQL file, unchanged**, plus `advance.sql`, `supply_lists.sql`, `loadouts_v2.sql` and `deliveries.sql`, each loaded twice.

## Setup notes

- **Getting the project files onto disk without retyping them:** `project_read` returns big docs inline, but the session transcript (`/root/.claude/projects/-home-claude/<session>.jsonl`) holds every tool result. A few lines of Python pull each `{"method":"project_read", "content": …}` out into a file. A subagent can do the same for docs you don't want in your own context.
- `npm install jsdom@24 pg fake-indexeddb playwright@1.56.0 @fontsource/barlow @fontsource/barlow-condensed pdf-lib jszip`.
- **`pgsupa.js`:** Part 6's JSON-argument fix, plus downloads now come back with the type they were uploaded with (`ftypes`). Before, every download from any bucket other than work-orders came back as `image/jpeg`.
- **jsdom realms:** the page's `Uint8Array`, `Array` and `File` aren't Node's. pdf-lib (Node's) checks `instanceof`, so `test_deliveries.js` hands the page a thin wrapper (`crossRealmPdfLib`) that converts bytes and page sizes. The test also gives the window Node's `File` (jsdom's has no `arrayBuffer()`, so uploads arrived as the text `[object File]`). A real browser needs none of this.
- **Stand-ins:** `sfShrinkPhoto` (the camera), `sfWhere` (GPS; set `w.__gps = null` for location off), `sfSignaturePng` (the canvas: a real PNG from `pngtiny.js`), `sfShrinkImage` (Julia's big-photo shrink), a small in-memory Cache API (Part 7), and `HTMLCanvasElement.prototype.getContext = () => null` (jsdom has no canvas). Pointer events for the signature are dispatched as `MouseEvent("pointerdown" …)`.
- **The camera-only rule** uses the file's `lastModified`: `new File([...], name, { lastModified: Date.now() - 3600000 })` stands in for a gallery pick.
- Run on shop time: `TZ=America/Indiana/Indianapolis`.
- **`test_loadouts_v2.js` with `deliveries.sql` loaded** stops at its first delivery row, on purpose: deliveries now use the new screen. Without `deliveries.sql` it gives 46 PASS against the new page, which proves the fallback. `test_deliveries.js` covers shipments with the new SQL.
- **`test_photos_e2e.js`**: 41 PASS on a database without `loadouts_v2.sql` (the v1 fallback). With the newer SQL its load-out rows drive old screens.
- `test_needs.js` (Part 4, Chromium) wasn't re-run. The office's Needs you tab wasn't touched; the Photos tab and archive are covered by `test_deliveries.js`.

## Results when delivered

| Suite | Result |
|---|---|
| `check_deliveries()`, loaded twice | 16 PASS, nothing left behind |
| `check_deliveries()` against 18 deliberate breaks (`breaks_deliveries.py`) | each caught. "Any reason for no signature" is caught only once the table's check constraint is dropped too, because that constraint is a second wall |
| All six checks together | floor 18, photos 16, advance 10, supply lists 10, load-outs 12, deliveries 16 |
| `test_deliveries.js`: core; Julia schedules (ticket, two files, a big PNG shrunk), changes the time, takes a file off, cancels one; Mike turned away; the driver's dock (camera-only, truck 1, a second truck, the truck is leaving), the site with no signal (files open offline, 3 photos wait then send with GPS), location off, the work order page, signed offline then sent; an unscheduled delivery not signed (Other plus a note), with the first trip's tables delivered earlier; a shipment unchanged; Julia's Completed (New, a real 3-page PDF, then not New); the office's job zip (filed names, both trips, the signed PDF, the spreadsheet); the archive with delivery files, which leave Supabase with their batch | 76 PASS |
| `test_deliveries_nosql.js` (no `deliveries.sql`) | 3 PASS: Julia's page says to run it; Delivery keeps v2; the office has no zip button and no warning |
| `test_mike_same.js` | Mike's 11 screens byte-for-byte the same as the live page |
| `test_app_e2e.js` (`SUPPLY=1 PHOTOS=1 ADVANCE=1`) / `test_supply_lists.js` / `test_advance.js` / `test_app_core.js` | 72 / 63 / 46 / 19 PASS |
| `test_loadouts_v2.js` (no `deliveries.sql`) / `test_photos_e2e.js` (no `loadouts_v2.sql`) | 46 / 41 PASS |
| `snap_dl.js`: Julia's schedule and Completed at 1280, the phone's list, dock, site, customer, no signature, confirm and delivered at 390×844, and the signed PDF's last page rendered | looked at: fits a phone, delivered is turquoise, New is dark |

Run order: `cd t && ../base/fresh.sh ../base/advance.sql ../base/supply_lists.sql ../base/loadouts_v2.sql ../out/deliveries.sql && TZ=America/Indiana/Indianapolis node <suite>.js`. Use a fresh database for each suite. `breaks_deliveries.py` runs from `w/`.

Not covered: a real phone's camera, GPS and touch; real Supabase Storage; pdf-lib from jsDelivr in a real browser; a PDF ticket opening on a real phone with no signal; the real SQL Editor (Walkthrough 11, step 4).

## Files

#### test_deliveries.js
```javascript
// Deliveries (24 Sep): Julia's page, the driver's phone (dock, site, customer), the office's job zip and archive.
// The real pages in jsdom against the real test database (pgsupa.js). The camera, GPS, the signature canvas and
// the browser's page cache are stood in for; the PDFs are real (pdf-lib) and so are the zips (read back with JSZip).
// Run: ../base/fresh.sh ../base/advance.sql ../base/supply_lists.sql ../base/loadouts_v2.sql ../out/deliveries.sql \
//        && TZ=America/Indiana/Indianapolis node test_deliveries.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const fidb = require("fake-indexeddb");
const JSZip = require("jszip");
const PDFLib = require("pdf-lib");
const png = require("./pngtiny");
const { makeClient, admin, users, setOffline, files } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"><\/script>/, "");
const APP = strip(fs.readFileSync("../out/index.html", "utf8"));
const DLV = strip(fs.readFileSync("../out/delivery.html", "utf8"));
const OFFICE = strip(fs.readFileSync("../out/office.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
const all = async (sql, p = []) => (await admin.query(sql, p)).rows;
const julia = { id: "99999999-9999-9999-9999-999999999999", email: "julia@example.com" };

function fakeCaches() {
  const stores = new Map();
  return { open: async (name) => { if (!stores.has(name)) stores.set(name, new Map()); const m = stores.get(name);
    return { match: async (req) => m.has(req.url) ? m.get(req.url).clone() : undefined, put: async (req, res) => { m.set(req.url, res); } }; }, _stores: stores };
}
// the page's bytes come from jsdom's realm; pdf-lib (Node's) checks instanceof, so hand it Node buffers (a real browser needs none of this)
const fixBytes = (b) => (b && b.buffer ? Buffer.from(b.buffer, b.byteOffset, b.byteLength) : b);
const wrapDoc = (d) => new Proxy(d, { get(t, k) { const v = t[k]; if (k === "embedPng" || k === "embedJpg") return (b) => v.call(t, fixBytes(b));
  if (k === "addPage") return (a) => v.call(t, Array.isArray(a) ? Array.from(a) : a); return typeof v === "function" ? v.bind(t) : v; } });
const crossRealmPdfLib = { ...PDFLib, PDFDocument: { create: async (...a) => wrapDoc(await PDFLib.PDFDocument.create(...a)),
                                                     load: async (b, o) => wrapDoc(await PDFLib.PDFDocument.load(fixBytes(b), o)) } };
function common(w, client) {
  w.HTMLCanvasElement.prototype.getContext = () => null;      // jsdom has no canvas
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.File = File; w.__saved = []; w.__opened = [];
  w.URL.createObjectURL = (b) => { w.__saved.push(b); return "blob:x" + w.__saved.length; }; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = (u) => { w.__opened.push(u); return null; }; w.scrollTo = () => {}; w.confirm = () => true;
  w.PDFLib = crossRealmPdfLib; w.TextEncoder = TextEncoder;
  w.client = client;
}
function bootApp(user, { idb, caches, preload = {} } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(APP, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.indexedDB = idb || new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  common(w, client);
  if (caches) { w.caches = caches; w.Request = Request; w.Response = Response; }
  w.sfShrinkPhoto = async () => ({ blob: new Blob([Buffer.alloc(150000, 7)], { type: "image/jpeg" }), width: 1600, height: 1200 });
  w.sfWhere = async () => (w.__gps === undefined ? { lat: 39.7684, lng: -86.1581, accuracy: 7 } : w.__gps);
  w.sfSignaturePng = async (strokes) => { w.__strokes = strokes; return new Blob([png(300, 100)], { type: "image/png" }); };
  w.eval([...APP.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
function bootPage(html, file, user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/" + file });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  common(w, client);
  w.sfShrinkImage = async (f) => new Blob([Buffer.alloc(800000, 3)], { type: "image/jpeg" });
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const byText = (w, sel, re) => $$(w, sel).find(e => re.test(e.textContent));
function type(w, sel, value, ev = "input") { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = value; el.dispatchEvent(new w.Event(ev)); }
function choose(w, sel, fileList) {
  const el = $(w, sel);
  Object.defineProperty(el, "files", { value: fileList, configurable: true });
  el.dispatchEvent(new w.Event("change"));
}
async function snap(w, { lastModified } = {}) {      // the driver takes the photo
  const cam = w.document.getElementById("camera");
  const f = new w.File(["x"], "IMG_0001.jpg", { type: "image/jpeg", lastModified: lastModified || Date.now() });
  Object.defineProperty(cam, "files", { value: [f], configurable: true });
  cam.dispatchEvent(new w.Event("change")); await wait(150);
}
function sign(w) {                                    // a finger across the pad
  const c = $(w, "#sigpad");
  for (const [t, x] of [["pointerdown", 10], ["pointermove", 60], ["pointermove", 120], ["pointerup", 120]])
    c.dispatchEvent(new w.MouseEvent(t, { clientX: x, clientY: x / 3, bubbles: true }));
}
const slot = (w, sheet, piece) => $(w, `[data-dlsite="${sheet}"][data-piece="${piece}"]`);
async function pdfOf(blob) { return PDFLib.PDFDocument.load(new Uint8Array(await blob.arrayBuffer())); }

(async () => {
  // ================= setup: Julia, and PROJ-00362 (in Delivery) with a work order =================
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  await admin.query("select set_delivery_scheduler($1, true)", [julia.email]);
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-2.png', now()),
      (w, 3, 2, 'TR-03', 'Oval', '42"', '84"', '30"', 'PROJ-00362/v1/sheet-3.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);
  const j362 = (await one("select id from jobs where project_id = 'PROJ-00362'")).id;

  // a real two-page ticket
  const tdoc = await PDFLib.PDFDocument.create(); tdoc.addPage([612, 792]); tdoc.addPage([612, 792]);
  const ticketBytes = Buffer.from(await tdoc.save());

  // ================= the core =================
  const coreOf = (html) => { const m = { exports: {} }; new Function("module", "require", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1])(m, require); return m.exports; };
  const D = coreOf(DLV), C = coreOf(APP), O = coreOf(OFFICE);
  ok("core: a date and time become one moment on this computer's clock", D.whenISO("2026-10-02", "9:00") === new Date("2026-10-02T09:00:00").toISOString() && D.whenISO("2026-10-02", "") === null);
  ok("core: \"Fri Oct 2, 9:00 am\" on the shop's clock", D.fmtWhen("2026-10-02T13:00:00Z") === "Fri Oct 2, 9:00 am", D.fmtWhen("2026-10-02T13:00:00Z"));
  ok("core: the download is named \"PROJ-00418 Signed ticket 2026-10-14.pdf\"", D.signedFileName({ project_id: "PROJ-00418", completed_at: "2026-10-14T18:00:00Z" }) === "PROJ-00418 Signed ticket 2026-10-14.pdf");
  ok("core: file kinds — PDF, JPEG, PNG only", D.fileKind({ type: "application/pdf" }) === "application/pdf" && D.fileKind({ name: "map.PNG" }) === "image/png" && D.fileKind({ name: "x.heic", type: "image/heic" }) === null);
  ok("core: the PDF's letters — dashes stay, anything else becomes ?", D.pdfText("Delivered — ✓ 日") === "Delivered — ? ?");
  const sp = D.splitDeliveries([{ is_done: false, scheduled_for: "2026-10-05" }, { is_done: false, scheduled_for: "2026-10-02" },
                                { is_done: true, completed_at: "2026-09-01", downloaded_at: null }, { is_done: true, completed_at: "2026-09-03", downloaded_at: "x" }]);
  ok("core: coming up soonest first; completed newest first; 1 new", sp.up[0].scheduled_for === "2026-10-02" && sp.done[0].completed_at === "2026-09-03" && sp.fresh === 1);
  const plan = C.deliveryPlan([{ sheet_number: 1, qty: 3 }, { sheet_number: 2, qty: 1 }], { trucks_here: [1], site_here: ["1:1"], site_earlier: ["2:1"] },
                              [{ stage: "site", sheet: 1, piece: 2 }, { stage: "dock", truck: 2 }], 1);
  ok("core: the plan — 2 trucks, 3 of 4 tables at the site (one delivered earlier), table 3 missing",
     plan.trucks === 2 && plan.trucksHere.join() === "1,2" && plan.site.done === 3 && plan.site.total === 4 && plan.site.missing[0].pieces.join() === "3" && !plan.delivered);
  ok("core: a photo taken over 10 minutes ago doesn't count as just taken", C.isFreshShot({ lastModified: Date.now() - 60000 }) && !C.isFreshShot({ lastModified: Date.now() - 3600000 }) && !C.isFreshShot({}));
  const sig = png(300, 100);
  const built = await D.buildSignedTicket(PDFLib, { project_id: "PROJ-00418", job_name: "Enid's Table", scheduled_for: "2026-10-02T13:00:00Z", completed_at: "2026-10-02T18:14:00Z",
    completed_by_name: "Shawn K", signed_name: "Pat Jones", signed_at: "2026-10-02T18:13:00Z", customer_note: "Scuff on table 3 — noted", pieces_total: 6, site_photographed: 6,
    complete_lat: 39.7684, complete_lng: -86.1581, complete_accuracy: 6 }, { bytes: ticketBytes, mime: "application/pdf" }, sig);
  ok("core: the signed ticket is the 2-page ticket plus one signature page", (await PDFLib.PDFDocument.load(built)).getPageCount() === 3);
  const noTicket = await D.buildSignedTicket(PDFLib, { project_id: "PROJ-00418", completed_at: "2026-10-02T18:14:00Z", no_sign_reason: "Nobody on site", no_sign_note: "Left in the gym" }, null, null);
  ok("core: no ticket, not signed: the record page on its own", (await PDFLib.PDFDocument.load(noTicket)).getPageCount() === 1);
  ok("office core: the same signed ticket (same pages)", (await PDFLib.PDFDocument.load(await O.buildSignedTicket(PDFLib, { project_id: "P", completed_at: "2026-10-02T18:14:00Z", signed_name: "A" }, { bytes: ticketBytes, mime: "application/pdf" }, sig))).getPageCount() === 3);

  // ================= Julia's page =================
  let m = bootPage(DLV, "delivery.html", users.mike);
  await until(() => /can't schedule deliveries/.test(txt(m)));
  ok("Mike's login is told it can't schedule deliveries", /Mike B isn't set up to schedule deliveries/.test(txt(m)));
  m.close();

  let w = bootPage(DLV, "delivery.html", julia);
  await until(() => /Schedule a delivery/.test(txt(w)) && $$(w, "[data-pickjob]").length > 0);
  ok("Julia: three tabs — Schedule a delivery · Coming up · Completed", $$(w, "nav.tabs button").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Schedule a delivery · Coming up · Completed");
  ok("the job list has jobs in production and in Delivery (PROJ-00362), no test jobs", $$(w, "[data-pickjob]").some(b => /PROJ-00362/.test(b.textContent)) && !$$(w, "[data-pickjob]").some(b => /TEST/.test(b.textContent)));
  ok("Schedule is off until a job and a date are picked", $(w, "[data-schedule]").disabled);
  type(w, "#jf", "362");
  await until(() => $$(w, "[data-pickjob]").length === 1);
  await click(w, "[data-pickjob]");
  ok("picking the job starts the date at Monday's delivery date", $(w, "#dd").value === (await one("select delivery_date::text d from jobs where id = $1", [j362])).d);
  type(w, "#dd", "2026-10-02"); type(w, "#dt", "09:30"); type(w, "#dn", "Loading dock on the north side. Ask for Pat.");
  choose(w, "#ticketIn", [new w.File([ticketBytes], "Ticket 4471.pdf", { type: "application/pdf" })]);
  await wait(50);
  choose(w, "#filesIn", [new w.File([Buffer.alloc(200000, 1)], "Where the tables go.jpg", { type: "image/jpeg" }),
                         new w.File([Buffer.alloc(2000000, 2)], "Site plan.png", { type: "image/png" })]);
  await wait(50);
  ok("the form lists the ticket and both files", /Ticket 4471\.pdf/.test(txt(w)) && /Where the tables go\.jpg/.test(txt(w)) && /Site plan\.png/.test(txt(w)) && !$(w, "[data-schedule]").disabled);
  await click(w, "[data-schedule]", 50);
  await until(() => /It's on Delivery's phone now/.test(txt(w)), 8000);
  const lo = await one("select * from loadouts where job_id = $1 and scheduled_for is not null", [j362]);
  ok("scheduled: PROJ-00362, Oct 2 9:30 am, the note, by Julia R", lo && lo.kind === "delivery" && lo.site_steps && new Date(lo.scheduled_for).toISOString() === new Date("2026-10-02T09:30:00").toISOString()
     && lo.schedule_note === "Loading dock on the north side. Ask for Pat." && lo.scheduled_by_name === "Julia R", lo && lo.scheduled_for);
  const docs = await all("select kind, file_name, mime, storage_path from delivery_docs where loadout_id = $1 order by added_at", [lo.id]);
  ok("the ticket and two site files are in the deliveries bucket, recorded", docs.length === 3 && docs[0].kind === "ticket" && docs[0].mime === "application/pdf"
     && docs.every(d => d.storage_path.startsWith(`PROJ-00362/${lo.client_id}/`)) && files.has("deliveries/" + docs[0].storage_path), docs.map(d => d.file_name).join(", "));
  ok("the big PNG was shrunk to a JPEG before it went", docs[2].file_name === "Site plan.jpg" && docs[2].mime === "image/jpeg");
  ok("it opens on Coming up", /Coming up/.test($(w, 'nav.tabs [aria-current="true"]').textContent));
  ok("...Coming up shows Fri Oct 2, 9:30 am, the ticket and files", /Fri Oct 2, 9:30 am.*PROJ-00362.*Note for the driver: Loading dock.*Ticket: Ticket 4471\.pdf.*Where the tables go\.jpg.*Site plan\.jpg/.test(txt(w)), txt(w).slice(0, 300));
  // change the time
  await click(w, "[data-editwhen]");
  type(w, "#et", "10:15");
  await click(w, "[data-savewhen]", 50);
  await until(async () => new Date((await one("select scheduled_for from loadouts where id = $1", [lo.id])).scheduled_for).getHours() === 10);
  ok("change the time to 10:15: saved, and says so", /delivery set for Fri Oct 2, 10:15 am/.test(txt(w)), txt(w).slice(0, 160));
  // take a file off, add it again
  await click(w, byText(w, "[data-retire]", /Take off/), 50);
  await until(async () => (await one("select count(*)::int n from delivery_docs where loadout_id = $1 and retired_at is not null", [lo.id])).n === 1);
  await until(() => $$(w, ".files li").every(li => !/Where the tables go/.test(li.textContent)));
  ok("Take off: the file leaves the list, kept in history", $$(w, ".files li").every(li => !/Where the tables go/.test(li.textContent)) && /taken off the delivery/.test(txt(w)));
  // a second delivery to cancel
  await click(w, '[data-tab="new"]');
  type(w, "#jf", "418"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  type(w, "#dd", "2026-10-09"); type(w, "#dt", "08:00");
  await click(w, "[data-schedule]", 50);
  await until(async () => (await one("select count(*)::int n from loadouts where scheduled_for is not null")).n === 2, 6000);
  await until(() => /No ticket yet/.test(txt(w)));
  ok("a delivery with no ticket says so on Coming up", /PROJ-00418.*No ticket yet/.test(txt(w)));
  const lo418 = await one("select * from loadouts where scheduled_for is not null and job_id <> $1", [j362]);
  await click(w, `[data-cancel="${lo418.id}"]`, 50);
  await until(async () => !!(await one("select voided_at from loadouts where id = $1", [lo418.id])).voided_at);
  ok("Cancel this delivery: off the list, kept (marked entered by mistake: Delivery cancelled)", (await one("select void_reason from loadouts where id = $1", [lo418.id])).void_reason === "Delivery cancelled");
  w.close();

  // ================= the driver's phone =================
  const cachesA = fakeCaches(), idbA = new fidb.IDBFactory();
  w = bootApp(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => /Scheduled deliveries/.test(txt(w)));
  ok("Shawn's Load-out: Scheduled deliveries, with the date and time", /Scheduled deliveries PROJ-00362.*Fri Oct 2, 10:15 am.*Delivery · no truck photo yet · 0 of 6 tables at the site/.test(txt(w)), txt(w).slice(0, 240));
  ok("...above Start a load-out, which is still there for other trips", txt(w).indexOf("Scheduled deliveries") < txt(w).indexOf("Start a load-out"));
  await click(w, `[data-loopen="${lo.client_id}"]`, 300);
  await until(() => /Ready for no signal/.test(txt(w)) && /✓/.test($(w, ".lopages").textContent), 6000);
  ok("opening it saves the pages, the ticket and the site file for no signal", /✓ Ready for no signal · 3 work order pages, the ticket and 1 site file saved on this device/.test(txt(w)), ($(w, ".lopages") || {}).textContent);
  ok("the date, the note from Julia, the ticket and the file", /Delivery Fri Oct 2, 10:15 am/.test(txt(w)) && /Note from Julia R: Loading dock/.test(txt(w)) && !!$(w, '[data-dlopen][data-name="Delivery ticket"]'));
  ok("three steps: the dock, the site, the customer", /1 · At the dock — a photo of each loaded truck — 0 of 1/.test(txt(w)) && /2 · At the site — each table where it ended up — 0 of 6/.test(txt(w)) && /3 · The customer/.test(txt(w)));
  ok("no Delivery/Shipping switch on a scheduled delivery", !$(w, "[data-lokind]"));
  // the dock
  await click(w, '[data-dltruck="1"]'); await snap(w, { lastModified: Date.now() - 3600000 });
  ok("a photo from the gallery (an hour old) is refused, in plain words", /wasn't just taken/.test(txt(w)) && (await one("select count(*)::int n from photos")).n === 0);
  await click(w, '[data-dltruck="1"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where truck = 1")).n === 1);
  const tp = await one("select * from photos where truck = 1");
  ok("truck 1: saved at the dock, with the phone's time and place", tp.stage === "dock" && tp.note === "Truck 1" && tp.lat === 39.7684 && tp.gps_accuracy === 7 && !!tp.shot_at);
  await click(w, "[data-dladdtruck]");
  ok("Add another truck: truck 2 appears", !!$(w, '[data-dltruck="2"]') && /0 of|1 of 2/.test(txt(w)));
  await click(w, "[data-lofinish]");
  ok("The truck is leaving: asks first, naming the missing truck photo", /No photo of truck 2 yet/.test($(w, ".mdl").textContent));
  await click(w, "[data-confirm]", 200);
  await until(async () => !!(await one("select finished_at from loadouts where id = $1", [lo.id])).finished_at);
  await until(() => /The truck left/.test(txt(w)));
  ok("recorded as left; the screen stays on the delivery for the site", /The truck left/.test(txt(w)) && /2 · At the site/.test(txt(w)));
  // the site, with no signal
  setOffline(true);
  await click(w, $(w, '[data-dlopen][data-name="Where the tables go.jpg"]') || $$(w, "[data-dlopen]")[1], 200);
  ok("no signal: the site file still opens (saved on the phone)", !!$(w, ".viewer img") && /blob:/.test($(w, ".viewer img").getAttribute("src")));
  await click(w, ".viewer [data-close]");
  await click(w, slot(w, 1, 1)); await snap(w);
  await click(w, slot(w, 1, 2)); await snap(w);
  await click(w, slot(w, 2, 1)); await snap(w);
  await until(() => /3 photos waiting to send/.test($(w, ".sync").textContent));
  ok("no signal: three site photos wait on the phone, their spots filled", /3 photos waiting to send/.test($(w, ".sync").textContent) && slot(w, 1, 1).classList.contains("here") && /Waiting to send/.test(slot(w, 2, 1).textContent));
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => (await one("select count(*)::int n from photos where stage = 'site'")).n === 3, 8000);
  const sp1 = await one("select * from photos where stage = 'site' and sheet_number = 2");
  ok("back on signal: all three sent, table by table, with time and GPS", sp1.piece === 1 && sp1.lat === 39.7684 && !!sp1.shot_at);
  await until(() => /3 of 6/.test(txt(w)));
  // the work order page, from the delivery
  await click(w, '[data-lowo="3"]', 200);
  await until(() => $(w, "#lopage img"));
  ok("Work order: sheet 3's page, with its site spots", /Sheet 3/.test($(w, "h1").textContent) && $$(w, "[data-dlsite]").length === 2 && /← Delivery/.test(txt(w)));
  w.__gps = null;                                    // GPS off: the photo still goes, without a place
  await click(w, slot(w, 3, 1)); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where stage = 'site'")).n === 4, 6000);
  ok("with location off, the photo still saves (no place recorded)", (await one("select lat from photos where stage = 'site' and sheet_number = 3")).lat === null);
  w.__gps = undefined;
  await click(w, "[data-lowoback]");
  // the customer: signed
  ok("Delivered — signed is off until there's a name and a signature", $(w, "[data-dldone]").disabled);
  type(w, "#dlNote", "Scuff on the leg of the oval table");
  type(w, "#dlName", "Pat Jones");
  ok("...a name alone isn't enough", $(w, "[data-dldone]").disabled);
  sign(w); await wait(30);
  ok("...a signature turns it on", !$(w, "[data-dldone]").disabled && $(w, ".sighint").textContent === "");
  await click(w, "[data-dldone]");
  ok("it asks first, naming the tables not photographed at the site", /Delivered, signed by Pat Jones\?/.test($(w, ".mdl").textContent) && /sheet 1: table 3 · sheet 3: table 2/.test($(w, ".mdl").textContent), $(w, ".mdl").textContent.replace(/\s+/g, " "));
  setOffline(true);
  await click(w, "[data-confirm]", 300);
  await until(() => /1 delivery waiting to send/.test($(w, ".sync").textContent));
  ok("no signal: it's marked delivered on the phone, waiting to send", /1 delivery waiting to send/.test($(w, ".sync").textContent) && /Delivered · signed by Pat Jones/.test(txt(w)) && /Waiting to send/.test(txt(w)));
  ok("...nothing reached the database yet", !(await one("select completed_at from loadouts where id = $1", [lo.id])).completed_at);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => !!(await one("select completed_at from loadouts where id = $1", [lo.id])).completed_at, 8000);
  const lc = await one("select * from loadouts where id = $1", [lo.id]);
  const sdoc = await one("select * from delivery_docs where loadout_id = $1 and kind = 'signature'", [lo.id]);
  ok("back on signal: delivered, signed by Pat Jones, with the note and the place", lc.signed_name === "Pat Jones" && lc.customer_note === "Scuff on the leg of the oval table" && lc.complete_lat === 39.7684 && !!lc.signed_at);
  ok("...the signature is a PNG in the deliveries bucket", !!sdoc && sdoc.mime === "image/png" && files.get("deliveries/" + sdoc.storage_path).slice(1, 4).toString() === "PNG");
  await until(() => /Delivered Fri|Delivered · signed by Pat Jones [A-Z][a-z]{2} /.test(txt(w)));
  ok("the phone shows it delivered, with the time", /Delivered · signed by Pat Jones/.test(txt(w)) && !$(w, "[data-dlsite]") && !$(w, "#sigpad"));
  await click(w, "[data-loback]", 300);
  await until(() => /Done in the last two weeks/.test(txt(w)));
  ok("the list: under Done, \"signed by Pat Jones\"", /Done in the last two weeks.*PROJ-00362.*Delivered .* · Shawn K · Delivery · truck photographed · 4 of 6 tables at the site · signed by Pat Jones/.test(txt(w)), txt(w).slice(txt(w).indexOf("Done"), txt(w).indexOf("Done") + 200));
  w.close();

  // an unscheduled delivery on the same job, not signed
  w = bootApp(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 300);
  await until(() => /1 · At the dock/.test(txt(w)));
  ok("an unscheduled delivery gets the same three steps (and the Delivery/Shipping switch)", /3 · The customer/.test(txt(w)) && !!$(w, "[data-lokind]"));
  await until(() => /Delivered earlier/.test(txt(w)), 6000);
  ok("the tables that went on the first trip show as delivered earlier", /Delivered earlier/.test(slot(w, 1, 1).textContent) && !/Delivered earlier/.test(slot(w, 1, 3).textContent));
  await click(w, slot(w, 1, 3)); await snap(w);
  await click(w, '[data-dlnosign="1"]');
  ok("Can't get a signature: three reasons; the button waits for one", $$(w, "[data-dlreason]").map(b => b.textContent).join("|") === "Nobody on site|Customer refused|Other" && $(w, "[data-dldone]").disabled);
  await click(w, '[data-dlreason="Other"]');
  ok("Other needs a note", $(w, "[data-dldone]").disabled);
  type(w, '[data-dlsig="reasonNote"]', "Customer's rep left early; tables inside the hall");
  ok("...with one it's on", !$(w, "[data-dldone]").disabled);
  await click(w, "[data-dldone]"); await click(w, "[data-confirm]", 300);
  await until(async () => (await one("select count(*)::int n from loadouts where completed_at is not null")).n === 2, 8000);
  const lu = await one("select * from loadouts where completed_at is not null and scheduled_for is null");
  ok("delivered, not signed: Other, the note, no signature; the truck marked left too", lu.no_sign_reason === "Other" && lu.no_sign_note === "Customer's rep left early; tables inside the hall" && !lu.signed_name && !!lu.finished_at);
  w.close();

  // a shipment keeps its old screen
  w = bootApp(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => $$(w, "[data-pickjob]").length > 0);
  await click(w, '[data-lostartkind="shipping"]');
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 300);
  await until(() => /Each pallet, once it's wrapped/.test(txt(w)));
  ok("a shipment: every table before wrap, then pallets — as before, no site or signature", /1 · Every table, before it's wrapped/.test(txt(w)) && !/The customer/.test(txt(w)) && !$(w, "[data-dltruck]"));
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'shipping'")));
  await click(w, '.loslot[data-loshoot="3"][data-piece="2"]'); await snap(w);
  await click(w, "[data-lopallet]"); await snap(w);
  type(w, "#loCarrier", "Estes"); type(w, "#loTracking", "BOL 44812"); await click(w, "[data-losavedet]", 100);
  await until(async () => (await one("select count(*)::int n from photos p join loadouts l on l.id = p.loadout_id where l.kind = 'shipping'")).n === 2, 6000);
  ok("...its table photo (before wrap), wrapped pallet and carrier still save the old way", !!(await one("select 1 x from photos p join loadouts l on l.id = p.loadout_id where l.kind = 'shipping' and p.sheet_number = 3 and p.piece = 2 and p.stage is null"))
     && !!(await one("select 1 x from photos where pallet = 1 and stage is null")) && !!(await one("select 1 x from loadouts where carrier = 'Estes' and tracking = 'BOL 44812'")));
  await click(w, "[data-lofinish]"); await click(w, "[data-confirm]", 200);
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'shipping' and finished_at is not null")));
  ok("...and it finishes as picked up, with no signature step", !(await one("select completed_at from loadouts where kind = 'shipping'")).completed_at);
  w.close();

  // ================= Julia: Completed =================
  w = bootPage(DLV, "delivery.html", julia, { sfd_tab: JSON.stringify("done") });
  await until(() => /Download signed ticket/.test(txt(w)));
  ok("Completed shows New (2) in the tab: both trips", /Completed2/.test($(w, '[data-tab="done"]').textContent));
  const cardOf = (id) => $$(w, ".card").find(c => c.querySelector(`[data-download="${id}"]`));
  ok("the signed one: New, delivered, Signed by Pat Jones, the customer's note, 4 of 6 tables", /New ?PROJ-00362.*Delivered ?.* · Shawn K.*Signed ?by Pat Jones.*Customer's note ?Scuff on the leg of the oval table.*4 of 6 tables photographed/.test(cardOf(lo.id).textContent.replace(/\s+/g, " ")), cardOf(lo.id).textContent.replace(/\s+/g, " "));
  ok("the other: Not signed — Other, with the driver's note", /Not signed — Other: Customer's rep left early/.test(txt(w)));
  await click(w, cardOf(lo.id).querySelector("[data-download]"), 50);
  await until(() => /has downloaded|couldn't|Can't/.test(txt(w)), 8000);
  if (!w.__saved.find(b => b.type === "application/pdf")) console.log("   (page said: " + txt(w).slice(0, 300) + ")");
  const pdfBlob = w.__saved.find(b => b.type === "application/pdf");
  const pdf = await pdfOf(pdfBlob);
  ok("Download: \"PROJ-00362 Signed ticket 2026-….pdf\" — the 2-page ticket plus the signature page", pdf.getPageCount() === 3 && /PROJ-00362 Signed ticket \d{4}-\d{2}-\d{2}\.pdf has downloaded/.test(txt(w)), txt(w).slice(0, 120));
  await until(async () => !!(await one("select downloaded_at from loadouts where id = $1", [lo.id])).downloaded_at);
  await until(() => /Completed1/.test($(w, '[data-tab="done"]').textContent));
  ok("...then it's no longer New, and says who downloaded it", /Downloaded .* by Julia R/.test(txt(w)) && (await one("select downloaded_by_name n from loadouts where id = $1", [lo.id])).n === "Julia R");
  w.close();

  // ================= the office: the job, its zip =================
  const o = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => o.document.querySelector("#phJob"), 6000);
  o.document.querySelector("#phJob").value = "362"; o.document.querySelector("[data-phfind]").click();
  await until(() => /What left the building/.test(txt(o)), 6000);
  ok("office Photos: the delivery — scheduled, delivered, signed by Pat Jones, the customer's note", /Scheduled for Fri Oct 2, 10:15 am by Julia R/.test(txt(o)) && /Delivered .* · signed by Pat Jones · 4 of 6 tables photographed at the site/.test(txt(o)) && /Customer's note: Scuff/.test(txt(o)), txt(o).slice(txt(o).indexOf("What left"), txt(o).indexOf("What left") + 500));
  ok("...photo captions say the truck and the site", /Truck 1, loaded/.test(txt(o)) && /Sheet 2 · table 1 · at the site/.test(txt(o)));
  await click(o, "[data-jobzip]", 50);
  await until(() => /photos .*\.zip has downloaded/.test(txt(o)), 10000);
  const zipBlob = o.__saved.find(b => b.type === "application/zip");
  const zip = await JSZip.loadAsync(Buffer.from(await zipBlob.arrayBuffer()));
  const names = Object.keys(zip.files).sort();
  const day = (await one("select to_char(scheduled_for at time zone 'America/Indiana/Indianapolis','YYYY-MM-DD') d from loadouts where id = $1", [lo.id])).d;
  const want = ["PROJ-00362/TR-01/TR-01-1 Delivery Picture.jpg", "PROJ-00362/TR-01/TR-01-2 Delivery Picture.jpg", "PROJ-00362/TR-01/TR-01-3 Delivery Picture.jpg",
                "PROJ-00362/TR-01/TR-01-4 Delivery Picture.jpg", "PROJ-00362/TR-03/TR-03-1 Delivery Picture.jpg", "PROJ-00362/Truck/Truck-1.jpg",
                `PROJ-00362/Delivery ${day}/Delivery ticket.pdf`, `PROJ-00362/Delivery ${day}/Where the tables go (taken off).jpg`, `PROJ-00362/Delivery ${day}/Site plan.jpg`,
                `PROJ-00362/Delivery ${day}/Signature.png`, `PROJ-00362/Delivery ${day}/Signed ticket.pdf`, "PROJ-00362/photos.csv"];
  ok("Download this job's photos: filed by item and table (TR-01-4 is sheet 2's table), trucks, the delivery folder", want.every(n => names.includes(n)), want.filter(n => !names.includes(n)).join(" | ") + " || have: " + names.join(" | "));
  ok("...the second trip's files have their own folder, the unsigned record included", names.some(n => /Delivery \d{4}-\d{2}-\d{2}( \(2\))?\/Signed ticket\.pdf/.test(n) && n !== `PROJ-00362/Delivery ${day}/Signed ticket.pdf`));
  ok("...the signed ticket in the zip is 3 pages", (await PDFLib.PDFDocument.load(await zip.file(`PROJ-00362/Delivery ${day}/Signed ticket.pdf`).async("uint8array"))).getPageCount() === 3);
  const csv = await zip.file("PROJ-00362/photos.csv").async("string");
  ok("...and the spreadsheet has the table numbers and the GPS", /TR-01-4 Delivery Picture\.jpg,PROJ-00362,Trinitas - Noblesville,2,4,Delivery Picture/.test(csv) && /39\.768400, -86\.158100/.test(csv));
  o.close();

  // ================= the archive: delivery files go too, filed the same way =================
  await admin.query("update jobs set is_active = false, phase = '100% Complete' where id = $1", [j362]);
  await admin.query("update jobs set floor_left_at = now() - interval '61 days' where id = $1", [j362]);
  await admin.query("update photos set taken_at = now() - interval '61 days' where job_id = $1", [j362]);
  await admin.query("update delivery_docs set added_at = now() - interval '61 days' where job_id = $1", [j362]);
  const o2 = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => $(o2, "[data-archstart]"), 6000);
  await click(o2, "[data-archstart]", 50);
  await until(() => /has downloaded/.test(txt(o2)), 10000);
  const az = await JSZip.loadAsync(Buffer.from(await o2.__saved.find(b => b.type === "application/zip").arrayBuffer()));
  const an = Object.keys(az.files);
  ok("the monthly archive: the same layout, with the delivery files and the signed ticket", ["PROJ-00362/TR-01/TR-01-4 Delivery Picture.jpg", `PROJ-00362/Delivery ${day}/Delivery ticket.pdf`, `PROJ-00362/Delivery ${day}/Signed ticket.pdf`, "photos.csv"].every(n => an.includes(n)), an.join(" | "));
  const batch = (await one("select id from photo_archive_batches")).id;
  ok("...the records say which zip holds each file", (await one("select count(*)::int n from delivery_docs where archive_batch = $1 and archive_name like 'PROJ-00362/Delivery %'", [batch])).n === 4);
  await click(o2, "[data-archsaved]", 50);
  await until(async () => (await one("select state from photo_archive_batches where id = $1", [batch])).state === "saved");
  ok("saved: the delivery files stay in Supabase for the month", (await one("select count(*)::int n from storage.objects where bucket_id = 'deliveries'")).n === 4);
  // a month later: the next batch releases this one, and its delivery files come off with its photos
  await admin.query("update photo_archive_batches set made_at = made_at - interval '31 days' where id = $1", [batch]);
  await admin.query("update photos set archive_batch = null, archive_name = null where false");
  const j418 = (await one("select id from jobs where project_id = 'PROJ-00418'")).id;
  await makeClient(users.mike).rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: (await one("select id from defect_types where department = 'sanding' order by sort_order limit 1")).id, p_sheet: 1 });
  await admin.query("insert into storage.objects (bucket_id, name, metadata) values ('photos', 'PROJ-00418/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg', '{\"size\": 3}')");
  await admin.query(`insert into photos (client_id, job_id, sheet_number, department, kind, defect_id, storage_path, bytes, taken_at)
                     select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', $1, 1, 'sanding', 'defect', id, 'PROJ-00418/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg', 3, now() - interval '61 days' from defects limit 1`, [j418]);
  await admin.query("update jobs set is_active = false, phase = '100% Complete' where id = $1", [j418]);
  await admin.query("update jobs set floor_left_at = now() - interval '61 days' where id = $1", [j418]);
  o2.close();
  const o3 = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => $(o3, "[data-archstart]"), 6000);
  await click(o3, "[data-archstart]", 50);
  await until(() => $(o3, "[data-archsaved]"), 10000);
  await click(o3, "[data-archsaved]", 50);
  await until(async () => (await one("select count(*)::int n from delivery_docs where file_removed_at is not null")).n === 4, 8000);
  ok("next month's batch saved: the first batch's delivery files come off Supabase; their records stay", (await one("select count(*)::int n from storage.objects where bucket_id = 'deliveries'")).n === 0
     && (await one("select count(*)::int n from delivery_docs")).n === 4);
  o3.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_deliveries_nosql.js
```javascript
// Before deliveries.sql is run: nothing breaks. Julia's page says to run it; the office has no zip button; Delivery keeps v2.
const src = require("fs").readFileSync("test_deliveries.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")) + `(async () => {
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  let w = bootPage(DLV, "delivery.html", users.luke);
  await until(() => /aren't set up yet/.test(txt(w)));
  ok("Julia's page, no SQL yet: says to run deliveries.sql", /Run deliveries\\.sql in the Supabase SQL Editor/.test(txt(w)));
  w.close();
  w = bootApp(users.shawn);
  await until(() => /Start a load-out/.test(txt(w)));
  ok("Delivery's phone, no SQL yet: the load-out screen as before (no Scheduled deliveries)", !/Scheduled deliveries/.test(txt(w)) && /Open load-outs/.test(txt(w)) && !/isn't set up/.test(txt(w)));
  w.close();
  const o = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => o.document.querySelector("#phJob"), 6000);
  o.document.querySelector("#phJob").value = "418"; o.document.querySelector("[data-phfind]").click();
  await until(() => /PROJ-00418/.test(txt(o)), 6000); await wait(300);
  ok("office, no SQL yet: no zip button, no warning banner", !o.document.querySelector("[data-jobzip]") && !/isn't set up in the database/.test(txt(o)));
  o.close();
  console.log(\`\\n\${pass} PASS, \${fail} FAIL\`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });`);
```

#### test_mike_same.js
```javascript
// Mike's tablet: every screen he uses is byte-for-byte the same on the new index.html as on the live one.
// Run on a database with deliveries.sql loaded (and again without it).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"><\/script>/, "");
const NEW = strip(fs.readFileSync("../out/index.html", "utf8")), LIVE = strip(fs.readFileSync("../live/index.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(html, user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const $ = (w, s) => w.document.querySelector(s);
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function screens(html, user) {
  const w = boot(html, user);
  await until(() => /PROJ-00418/.test(w.document.getElementById("app").textContent)); await wait(400);
  const out = [];
  const snap = async (name) => { await wait(350); out.push([name, $(w, "#app").innerHTML]); };
  await snap("sanding queue");
  await click(w, "button.job"); await snap("job");
  await click(w, "button.sheet"); await snap("sheet");
  await click(w, "[data-defect]"); await snap("log a defect");
  w.document.querySelector(".ovl").click(); await wait(100);
  await click(w, "[data-problem]"); await snap("flag a problem");
  w.document.querySelector(".ovl").click(); await wait(100);
  await click(w, "[data-back]"); await click(w, "[data-back]");
  for (const t of ["problems", "log", "supplies", "work"]) { await click(w, `[data-tab="${t}"]`); await snap("tab " + t); }
  await click(w, '[data-dept="finishing"]'); await snap("finishing");
  await click(w, '[data-tab="supplies"]'); await snap("finishing supplies");
  w.close();
  return out;
}
(async () => {
  for (const [who, user] of [["Mike", users.mike], ["Donnie", users.donnie], ["Willie", users.willie]]) {
    let a, b;
    try { a = await screens(LIVE, user); b = await screens(NEW, user); }
    catch (e) { if (who === "Mike") throw e; a = b = null; }
    if (!a) { console.log(`(skipped ${who}: his screens differ in shape from Mike's)`); continue; }
    const diffs = a.filter(([n, h], i) => h !== b[i][1]).map(([n]) => n);
    ok(`${who}: ${a.length} screens identical, byte for byte, to the live page`, diffs.length === 0 && a.length === b.length, diffs.join(", "));
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks_deliveries.py
```python
import subprocess
src = open('out/deliveries.sql').read()
def section(a, b): return src[src.index(a):src.index(b)]
fsched = section('create or replace function schedule_delivery', 'revoke all on function schedule_delivery')
fdoc   = section('create or replace function add_delivery_doc', 'revoke all on function add_delivery_doc')
fphoto = section('create or replace function add_delivery_photo', 'revoke all on function add_delivery_photo')
fdone  = section('create or replace function complete_delivery', 'revoke all on function complete_delivery')
fdown  = section('create or replace function mark_ticket_downloaded', 'revoke all on function mark_ticket_downloaded')
vfile  = section('create view v_filing', 'revoke all on v_filing')
farch  = section('create or replace function delivery_docs_archivable_ids', 'revoke all on function delivery_docs_archivable_ids')
P = ['psql','-h','/tmp/pg','-p','5433','-U','postgres','-d','sync','-At','-v','ON_ERROR_STOP=1']
def run(sql): return subprocess.run(P+['-c',sql],capture_output=True,text=True)
def failed(): return run("select step from check_deliveries() where result <> 'PASS'").stdout.split()
def rep(s, a, b):
    assert s.count(a) >= 1, a[:60]; return s.replace(a, b)
breaks = {
 'anyone schedules':        (fsched, rep(fsched, "if not can_schedule_deliveries() then\n    raise exception 'Only the delivery manager or a manager can schedule deliveries.' using errcode = 'insufficient_privilege';\n  end if;", ""), 2),
 'scheduler crosses lanes': (fsched, rep(fsched, "if v_job.is_test and not (is_manager() or am_test()) then", "if false then"), 2),
 'ticket before its file':  (fdoc, rep(fdoc, "if v_obj.name is null then raise exception 'The file hasn''t arrived, so it wasn''t saved. Add it again.'; end if;", "v_obj.name := coalesce(v_obj.name, 'x/' || p_client_id);"), 4),
 'old ticket deleted':      (fdoc, rep(fdoc, "update delivery_docs set retired_at = now(), retired_by_name = my_name(), retire_reason = 'Replaced by a newer ticket'\n     where loadout_id = v.id and kind = 'ticket' and retired_at is null;", "delete from delivery_docs where loadout_id = v.id and kind = 'ticket';"), 4),
 'truck on a shipment':     (fphoto, rep(fphoto, "if v.kind <> 'delivery' then raise exception 'Truck and site photos", "if false then raise exception 'Truck and site photos"), 6),
 'GPS not kept':            (fphoto, rep(fphoto, "lat = case when v_ok_gps then p_lat end", "lat = null"), 7),
 'any table number':        (fphoto, rep(fphoto, "if p_piece < 1 or p_piece > v_qty then", "if false then"), 7),
 'no signature needed':     (fdone, rep(fdone, "if v_obj.name is null then raise exception 'The signature hasn''t arrived, so the delivery wasn''t marked done. Try again.'; end if;", "if v_obj.name is null then v_obj.name := v_path; end if;"), 8),
 'ticket after signing':    (fdoc, rep(fdoc, "if v.completed_at is not null then\n    raise exception 'That delivery is already done", "if false then\n    raise exception 'That delivery is already done"), 9),
 'anyone marks downloaded': (fdown, rep(fdown, "v := delivery_scheduler_check(p_loadout);", "v := delivery_lookup(p_loadout);"), 11),
 'filing ignores sheets':   (vfile, rep(vfile, "coalesce(s.unit_offset, 0) + coalesce(p.piece, 1)", "coalesce(p.piece, 1)"), 15),
 'archive skips files':     (farch, rep(farch, "where d.archive_batch is null and d.file_removed_at is null", "where false and d.file_removed_at is null"), 16),
}
for name,(orig,body,row) in breaks.items():
    assert body != orig, name
    pre = 'drop view if exists v_filing;\n' if body.startswith('create view v_filing') else ''
    r = run(pre + body); assert r.returncode == 0, (name, r.stderr)
    out = failed()
    print(f"{name:26s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    r = run(pre + orig + ('\ngrant select on v_filing to authenticated;' if pre else '')); assert r.returncode == 0, r.stderr
for name, brk, fix, row in [
  ('any reason (and no table rule)', "alter table loadouts drop constraint loadouts_no_sign_reason_check; " + rep(fdone, "if p_no_sign_reason not in ('Nobody on site', 'Customer refused', 'Other') then", "if false then"),
                             "alter table loadouts add constraint loadouts_no_sign_reason_check check (no_sign_reason is null or no_sign_reason in ('Nobody on site', 'Customer refused', 'Other')); " + fdone, 10),
  ('bucket public',          "update storage.buckets set public = true where id = 'deliveries'", "update storage.buckets set public = false where id = 'deliveries'", 1),
  ('files readable by all',  "drop policy read_delivery_docs on delivery_docs; create policy read_delivery_docs on delivery_docs for select to authenticated using (true)",
                             "drop policy read_delivery_docs on delivery_docs; create policy read_delivery_docs on delivery_docs for select to authenticated using (sees_lane(is_test) and sees_deliveries())", 12),
  ('bucket readable by all', "create policy zz on storage.objects for select to authenticated using (bucket_id = 'deliveries')", "drop policy zz on storage.objects", 12),
  ('direct insert allowed',  "grant insert on delivery_docs to authenticated; create policy x on delivery_docs for insert to authenticated with check (true)", "revoke insert on delivery_docs from authenticated; drop policy x on delivery_docs", 13),
  ('anon can read',          "grant select on delivery_docs to anon; create policy y on delivery_docs for select to anon using (true)", "revoke select on delivery_docs from anon; drop policy y on delivery_docs", 14),
]:
    r = run(brk); assert r.returncode == 0, (name, r.stderr)
    out = failed()
    print(f"{name:26s} expected row {row}: failed rows {out} ->", 'CAUGHT' if str(row) in out else 'MISSED')
    r = run(fix); assert r.returncode == 0, r.stderr
print('restored:', run("select count(*) from check_deliveries() where result='PASS'").stdout.strip(), 'PASS')
```

#### pngtiny.js
```javascript
// a real PNG (w × h, a dark diagonal line on white), so pdf-lib can embed it like a signature
const zlib = require("zlib");
function crc32(buf) { let c, crc = 0xFFFFFFFF; for (const b of buf) { c = (crc ^ b) & 0xFF; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; crc = (crc >>> 8) ^ c; } return (crc ^ 0xFFFFFFFF) >>> 0; }
function chunk(type, data) { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td)); return Buffer.concat([len, td, crc]); }
module.exports = function png(w = 300, h = 100) {
  const raw = Buffer.alloc((w * 3 + 1) * h, 255);
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; const x = Math.floor(y * w / h); for (let dx = 0; dx < 3 && x + dx < w; dx++) { const o = y * (w * 3 + 1) + 1 + (x + dx) * 3; raw[o] = 24; raw[o + 1] = 29; raw[o + 2] = 46; } }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
};
```

#### snap_dl.js
```javascript
// Photograph the delivery screens: the real pages in jsdom against the test database, then Chromium.
const fs = require("fs");
const { chromium } = require("playwright");
const src = fs.readFileSync("test_deliveries.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")).replace(/^const fs = require\("fs"\);/m, "") + fs.readFileSync("snap_dl_body.js", "utf8"));
```

#### snap_dl_body.js
```javascript
const fontCss = ["barlow/400", "barlow/500", "barlow/600", "barlow/700", "barlow-condensed/600", "barlow-condensed/700"].map(p => {
  const [fam, wt] = p.split("/"); const file = `../node_modules/@fontsource/${fam}/files/${fam}-latin-${wt}-normal.woff2`;
  return `@font-face{font-family:'${fam === "barlow" ? "Barlow" : "Barlow Condensed"}';font-weight:${wt};src:url(data:font/woff2;base64,${fs.readFileSync(file).toString("base64")})}`;
}).join("");
const pageImg = "data:image/png;base64," + fs.readFileSync("page.png").toString("base64");
const shots = [];
const save = (w, name, vw, focus = null) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
  d.querySelectorAll("img").forEach(i => i.setAttribute("src", pageImg));
  shots.push([name, "<!DOCTYPE html>" + d.outerHTML.replace("<style>", "<style>" + fontCss), vw, focus]); };
(async () => {
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  await admin.query("select set_delivery_scheduler($1, true)", [julia.email]);
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-02', 'Rectangle', '30"', '60"', '30"', 'PROJ-00362/v1/sheet-2.png', now()),
      (w, 3, 2, 'TR-03', 'Oval', '42"', '84"', '30"', 'PROJ-00362/v1/sheet-3.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);
  const tdoc = await PDFLib.PDFDocument.create(); tdoc.addPage([612, 792]); const ticketBytes = Buffer.from(await tdoc.save());
  // Julia schedules
  let w = bootPage(DLV, "delivery.html", julia);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "#jf", "362"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  type(w, "#dd", "2026-10-02"); type(w, "#dt", "10:15"); type(w, "#dn", "Loading dock on the north side. Ask for Pat.");
  choose(w, "#ticketIn", [new w.File([ticketBytes], "Ticket 4471.pdf", { type: "application/pdf" })]); await wait(50);
  choose(w, "#filesIn", [new w.File([Buffer.alloc(200000, 1)], "Where the tables go.jpg", { type: "image/jpeg" })]); await wait(80);
  save(w, "j1-schedule", 1280);
  await click(w, "[data-schedule]", 50); await until(() => /It's on Delivery's phone now/.test(txt(w)), 8000);
  save(w, "j2-coming-up", 1280);
  w.close();
  // Shawn
  const caches = fakeCaches();
  w = bootApp(users.shawn, { caches });
  await until(() => /Scheduled deliveries/.test(txt(w))); await wait(300);
  save(w, "p1-list", 390);
  const lo = await one("select * from loadouts where scheduled_for is not null");
  await click(w, `[data-loopen="${lo.client_id}"]`, 300);
  await until(() => /✓ Ready for no signal/.test(txt(w)), 6000);
  await click(w, '[data-dltruck="1"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos")).n === 1); await wait(300);
  save(w, "p2-delivery-top", 390);
  await click(w, "[data-lofinish]"); await click(w, "[data-confirm]", 300);
  await until(() => /The truck left/.test(txt(w)));
  await click(w, slot(w, 1, 1)); await snap(w); await click(w, slot(w, 1, 2)); await snap(w); await click(w, slot(w, 2, 1)); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where stage='site'")).n === 3, 6000); await wait(300);
  save(w, "p3-site", 390, ".lostep:nth-of-type(2)");
  type(w, "#dlNote", "Scuff on the leg of the oval table"); type(w, "#dlName", "Pat Jones"); sign(w); await wait(50);
  save(w, "p4-customer", 390, "#dlNote");
  await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Nobody on site"]');
  save(w, "p5-no-signature", 390, "#dlNote");
  await click(w, '[data-dlnosign="0"]'); sign(w); type(w, "#dlName", "Pat Jones");
  await click(w, "[data-dldone]"); save(w, "p6-confirm", 390);
  await click(w, "[data-confirm]", 300);
  await until(async () => !!(await one("select completed_at from loadouts where id = $1", [lo.id])).completed_at, 8000); await wait(400);
  save(w, "p7-delivered", 390, ".dldone");
  w.close();
  w = bootPage(DLV, "delivery.html", julia, { sfd_tab: JSON.stringify("done") });
  await until(() => /Download signed ticket/.test(txt(w))); save(w, "j3-completed", 1280);
  // the signed ticket itself, as a picture
  await click(w, "[data-download]", 50); await until(() => /has downloaded/.test(txt(w)), 8000);
  fs.writeFileSync("/tmp/dl_signed.pdf", Buffer.from(await w.__saved.find(b => b.type === "application/pdf").arrayBuffer()));
  w.close();
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [n, h, vw, focus] of shots) {
    const p = await b.newPage({ viewport: { width: vw, height: vw < 500 ? 844 : 900 } });
    await p.setContent(h, { waitUntil: "load" }); await p.waitForTimeout(200);
    if (focus) await p.evaluate((f) => { const el = document.querySelector(f); if (el) el.scrollIntoView({ block: "start" }); }, focus);
    await p.screenshot({ path: `/tmp/dl_${n}.png` }); await p.close();
  }
  await b.close(); console.log("shots:", shots.map(s => s[0]).join(", ")); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### pgsupa.js — the change (on top of Part 6's)
```javascript
// beside `const files = new Map();`
const ftypes = new Map();
// in upload(), after files.set(key(path), buf);
ftypes.set(key(path), type);
// in download(), the last line
return { data: new Blob([buf], { type: ftypes.get(key(path)) || "image/jpeg" }), error: null };
```

## Deliveries v2 (24 Sep, later)

- `deliveries_v2.sql` loads after `deliveries.sql`: `../base/fresh.sh ../base/advance.sql ../base/supply_lists.sql ../base/loadouts_v2.sql ../out/deliveries.sql ../out/deliveries_v2.sql`.
- `test_deliveries_v2.js` (22 checks): drag and drop on Julia's page (a stand-in `dataTransfer` with `types: ["Files"]` and `files`, since jsdom has none), wrong kinds refused by name, a drop beside the boxes prevented; drops onto a delivery under Coming up (site file added, ticket replaced and kept); the phone shows no "started by mistake" on a scheduled delivery for Shawn or for Julia (the scheduler, i.e. "started by" her, which is the case that used to show it), and the database refuses Shawn's call; an unscheduled load-out still voids; Cancel → Cancelled list → Put it back, with `void_history`; Shawn can't put back.
- `breaks_deliveries_v2.py` (from `w/`): 6 breaks, all caught by `check_deliveries_v2()`. Row 2 had to make the Test Supervisor schedule the delivery and then lose the flag: the old "only whoever started it" rule already blocks a plain driver, so that alone couldn't catch the new rule going missing.
- `snap_dl2.js` photographs the drop states, Coming up with Cancelled, and the phone's line.
- `check_deliveries()` now turns the Test Supervisor's `schedules_deliveries` off inside its own run: on the live database the Test Supervisor was made a scheduler for the practice delivery, which made row 2 (and 11) fail. `deliveries_v2.sql` carries the refreshed function.
- Results: v2 22/22; deliveries 76 (with and without the v2 SQL); Mike same (full and bare); nosql 3; e2e 72 (`SUPPLY=1 PHOTOS=1`); supply 63; Advance 46; core 19; load-outs v2 46; photos 41. Live checks after the run: deliveries 16, deliveries v2 6, load-outs 12, photos 16, floor 18, supply 10, Advance 10.
- Re-running `photos.sql` would bring back the old `void_loadout()`; run `deliveries_v2.sql` after it.
