// 10 Nov: Purchasing, the simpler page (purchasing.sql, lumber_scrap_skips.sql, purchasing_log.sql, purchasing.html).
// In real Chromium through the real database as Luke. Three tabs and Setup. Setup: PO details, a supplier with other names,
// items, a baseline. Buy: a tablet's request put on PO 00001 and marked ordered, then under Ordered, not received and marked
// Received; Not ordering. Log a purchase: no Mark ordered; two ticked requests fill the form, one as an item the shop has and
// one as a new item; a supplier the shop hasn't used is added; the requests are marked ordered naming where; Logged lately;
// it counts in Prices; Change takes a line off and its request is to be ordered again; It was a mistake stops it counting.
// The POs: the PD - POs folder chosen and PO 00001.pdf filed; Lumber PO 24 numbered apart, its delivery slips offered on
// the PO. Prices: a Purchases file as a real .xlsx added in one step; a line with no item given one from a sheet; the same
// file again adds nothing; the next file's line files itself; a file naming new items makes them without a question, takes
// a look-alike as the item the shop has and says so; Not the same splits it off; Same as folds an item into another from
// the sheet and from Setup; what you paid, a category chip, More on lumber, Worth a look, the export. Savings: the
// sentence, the chart and a month's figures, the movers opening Prices, a scrap month left out and put back. Then the page
// without lumber_scrap_skips.sql and without purchasing_log.sql (no Log a purchase, Mark ordered as before; a file still
// goes in, its new names wait), Mike turned away by the page and the database, and phone width.
// OLDDB=1: a database without purchasing.sql: the page says it isn't set up, no page errors. The live database has had
// purchasing.sql since 7 Nov, so take it out first: TEMPLATE=sync_base_old fresh.sh, then psql -c "drop function purchasing_data() cascade".
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh
//   OUT=/tmp/allpages PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_purchasing.js
const fs = require("fs"), http = require("http"), path = require("path"), cp = require("child_process");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo", OLDDB = process.env.OLDDB === "1";
const PDFLIB = "/tmp/pdflib/package/dist/pdf-lib.min.js";
if (!fs.existsSync(PDFLIB)) cp.execSync("mkdir -p /tmp/pdflib && cd /tmp/pdflib && npm pack pdf-lib@1.17.1 >/dev/null 2>&1 && tar xzf pdf-lib-1.17.1.tgz");
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: () => ({ download: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/purchasing.html";
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : file.endsWith(".png") ? "image/png" : "application/octet-stream" });
  res.end(body);
});
async function session(browser, user, w = 1366) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: { width: w, height: 860 }, serviceWorkers: "block", acceptDownloads: true });
  await ctx.addInitScript(() => {
    window.showDirectoryPicker = async () => { const d = await navigator.storage.getDirectory(); return d.getDirectoryHandle("PD - POs", { create: true }); };
  });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());          // registered first: the stand-ins below win
  await ctx.route(/pdf-lib@1\.17\.1/, r => r.fulfill({ body: fs.readFileSync(PDFLIB), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs };
}
const txt = (p) => p.evaluate(() => document.querySelector("#app").innerText.replace(/\s+/g, " "));
const banner = (p) => p.evaluate(() => { const b = document.querySelector("[role=status]"); return b ? b.innerText.replace(/\s+/g, " ") : ""; });
const tab = async (p, k) => { await p.click(`[data-tab="${k}"]`); await sleep(900); };
const folderFiles = (p) => p.evaluate(async () => { const out = {}; const d = await (await navigator.storage.getDirectory()).getDirectoryHandle("PD - POs", { create: true });
  for await (const [n, h] of d.entries()) { const f = await h.getFile(); out[n] = Array.from(new Uint8Array(await f.arrayBuffer())); } return out; });
const pdfText = (bytes) => { fs.writeFileSync("/tmp/tp.pdf", Buffer.from(bytes)); return cp.execSync("pdftotext -layout /tmp/tp.pdf - 2>/dev/null").toString(); };
/** a Purchases file as Excel saves it: openpyxl writes a real .xlsx with a Lines tab (and a tab before it) */
function makeXlsx(file, rows) {
  const py = `import openpyxl, json, datetime, sys
wb = openpyxl.Workbook(); wb.active.title = "Baseline 2026"; wb.active["A1"] = "not the lines"
ws = wb.create_sheet("Lines"); ws.append(["Date","Supplier","Bill / receipt #","How","Description on the bill","Category","Item","Qty","Unit","Amount","In the baseline","Note"])
for r in json.loads(sys.argv[2]):
    r[0] = datetime.datetime.strptime(r[0], "%Y-%m-%d"); ws.append(r)
wb.save(sys.argv[1])`;
  fs.writeFileSync("/tmp/mkx.py", py); cp.execFileSync("python3", ["/tmp/mkx.py", file, JSON.stringify(rows)]);
}

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const q = async (sql, args = []) => (await admin.query(sql, args)).rows;
  const browser = await chromium.launch();
  const s = await session(browser, users.luke), p = s.p;

  if (OLDDB) {
    await p.goto(base + "purchasing.html"); await sleep(1500);
    ok("OLDDB: the page says Purchasing isn't set up yet (run purchasing.sql)", /isn't set up in the database yet/.test(await txt(p)) && /purchasing\.sql/.test(await txt(p)), await txt(p));
    ok("OLDDB: no page errors", !s.errs.length, s.errs.join(" | "));
    console.log(`\ntest_purchasing (OLDDB): ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
  }
  const addFile = async (pg, file) => { await pg.setInputFiles("#fileIn", file); await pg.waitForSelector("[data-filesend]"); const card = await txt(pg); await pg.click("[data-filesend]"); await sleep(1500); return card; };
  const openFold = async (pg, k) => { await pg.evaluate((k) => { const d = document.querySelector(`details[data-keep="${k}"]`); if (d && !d.open) d.querySelector("summary").click(); }, k); await sleep(200); };

  const year = Number((await q("select extract(year from local_today())::int y"))[0].y), today = (await q("select local_today()::text d"))[0].d;
  await p.goto(base + "purchasing.html"); await p.waitForSelector("[data-tab]"); await sleep(800);
  const tabs = await p.$$eval("[data-tab]", b => b.map(x => x.innerText.trim()));
  ok("Three tabs and Setup: Buy, Savings, Prices, Setup; the page opens on Buy", tabs.join("|") === "Buy|Savings|Prices|Setup" && /Needs buying/.test(await txt(p)), tabs.join("|"));
  await p.goto(base + "purchasing.html#lumber"); await p.waitForSelector("[data-tab]"); await sleep(600);
  ok("An old bookmark (#lumber) lands on the tab that holds it now (Savings)", (await p.getAttribute('[data-tab="savings"]', "aria-current")) === "true");

  // ---- Setup ----
  await tab(p, "setup");
  await p.fill("#isBy", "Luke Hart"); await p.fill("#isPhone", "317-555-0100"); await p.fill("#isEmail", "luke@example.com");
  await p.fill("#isAddr", "Purposeful Design\n100 Shop Road\nCarmel, IN 46032"); await p.fill("#isTax", "Tax exempt: check line");
  await p.click("[data-saveissuer]"); await sleep(600);
  await p.click('[data-editsupplier="new"]'); await sleep(200);
  await p.fill('[data-v="name"]', "Test Supply Co"); await p.fill('[data-v="contact"]', "Pat Test"); await p.fill('[data-v="aliases"]', "TEST SUPPLY CO INC\nTSC");
  await p.click("[data-savesupplier]"); await sleep(600);
  await p.click('[data-editsupplier="new"]'); await sleep(200);
  await p.fill('[data-v="name"]', "Test Lumber Co"); await p.fill('[data-v="contact"]', "Sam Mill"); await p.click("[data-savesupplier]"); await sleep(600);
  await p.click('[data-edititem="new:hardware"]'); await sleep(200);
  await p.fill('[data-i="name"]', "Titebond III gallon"); await p.fill('[data-i="unit"]', "gallon"); await p.click("[data-saveitem]"); await sleep(600);
  await p.click('[data-edititem="new:lumber"]'); await sleep(200);
  await p.fill('[data-i="name"]', "8/4 Ash"); await p.fill('[data-i="quarters"]', "8"); await p.click("[data-saveitem]"); await sleep(600);
  const ash8 = (await q("select id from purchase_items where name = '8/4 Ash'"))[0];
  await p.click('[data-edititem="new:lumber"]'); await sleep(200);
  await p.fill('[data-i="name"]', "7/4 Ash"); await p.fill('[data-i="quarters"]', "7");
  if (ash8) await p.selectOption('[data-i="compare_as"]', ash8.id);
  await p.click("[data-saveitem]"); await sleep(600);
  if (ash8) { await p.selectOption("#blItem", ash8.id); await p.fill("#blYear", String(year - 1)); await p.fill("#blPrice", "4.42"); await p.click("[data-savebase]"); await sleep(600); }
  const sup = await q("select name, aliases from purchase_suppliers order by name");
  const its = await q("select i.name, i.category_key, i.unit, i.quarters, (select name from purchase_items c where c.id = i.compare_as) ca from purchase_items i order by name");
  ok("Setup: PO details saved (shared with the Arrow POs)", (await q("select issued_by from arrow_po_settings"))[0].issued_by === "Luke Hart");
  ok("Setup: a supplier with two other names", sup.some(x => x.name === "Test Supply Co" && x.aliases.length === 2), JSON.stringify(sup));
  ok("Setup: a hardware item in gallons, 8/4 Ash, and 7/4 Ash compared as 8/4", its.some(i => i.name === "Titebond III gallon" && i.category_key === "hardware" && i.unit === "gallon")
     && its.some(i => i.name === "7/4 Ash" && i.ca === "8/4 Ash" && i.quarters === 7), JSON.stringify(its));
  ok(`Setup: 8/4 Ash's ${year - 1} baseline, and 7/4 Ash measured against it at the same square feet ($5.0514)`, /\$5\.051/.test(await txt(p)) && (await q("select count(*)::int n from purchase_baselines"))[0].n === 1, (await txt(p)).slice(0, 200));

  // ---- Buy: the departments' requests, on a PO ----
  await q(`insert into supply_requests (department, item, qty, note, requested_by_name) values ('assembly_qc', 'Titebond III gallon', 2, 'for the glue-up', 'KP'), ('finishing', 'Rags', 1, null, 'Jim')`);
  await tab(p, "buy");
  let t = await txt(p);
  ok("Buy: the tablets' requests with who asked, then the POs under them", /2 × Titebond III gallon/.test(t) && /Assembly \/ QC, KP/.test(t) && /1 × Rags/.test(t) && /POs/.test(t) && /Make a lumber PO/.test(t), t.slice(0, 400));
  const req = (await q("select id from supply_requests where item = 'Titebond III gallon'"))[0].id, rags = (await q("select id from supply_requests where item = 'Rags'"))[0].id;
  await p.check(`[data-tick="${req}"]`); await sleep(200);
  await p.click("[data-reqpo]"); await sleep(500);
  t = await txt(p);
  ok("Put ticked on a PO: the editor opens as Make PO 00001 with the request's line", /Make PO 00001/.test(t) && (await p.inputValue('[data-l="0|description"]')) === "Titebond III gallon" && (await p.inputValue('[data-l="0|qty"]')) === "2"
     && /Assembly \/ QC asked for it/.test(t), t.slice(0, 200));
  const supId = (await q("select id from purchase_suppliers where name = 'Test Supply Co'"))[0].id, titeId = (await q("select id from purchase_items where name = 'Titebond III gallon'"))[0].id;
  await p.selectOption('[data-e="vendor_id"]', supId); await p.fill('[data-l="0|unit"]', "gallon"); await p.fill('[data-l="0|unit_price"]', "38.50");
  await p.selectOption('[data-l="0|item_id"]', titeId); await sleep(200);
  ok("The editor works out the amount as you type", (await p.$eval("#amt-0", e => e.textContent)) === "$77.00");
  await p.click("[data-savepo]"); await sleep(1200);
  t = await banner(p);
  ok("PO 00001 made, and its supply request marked ordered; the page is back on Buy", /PO 00001 made/.test(t) && /1 supply request is marked ordered/.test(t) && (await p.getAttribute('[data-tab="buy"]', "aria-current")) === "true", t);
  const ev = await q("select what from supply_request_events where request_id = $1", [req]);
  ok("The request is ordered in the database, naming the PO", (await q("select state from supply_requests where id = $1", [req]))[0].state === "ordered" && ev.some(e => e.what === "Ordered on PO 00001"), JSON.stringify(ev));
  await openFold(p, "ordered"); t = await txt(p);
  ok("Buy: it's under Ordered, not received, on PO 00001; Rags still waits", /Ordered, not received \(1\)/.test(t) && /Ordered on PO 00001/.test(t) && /1 × Rags/.test(t), t.slice(0, 500));
  p.once("dialog", d => d.accept());
  await p.click(`[data-received="${req}"]`); await sleep(1200);
  await openFold(p, "closed"); t = await txt(p);
  ok("Received here closes it, as the tablet's tap does: it's under Closed in the last 60 days", (await q("select state from supply_requests where id = $1", [req]))[0].state === "received" && /Closed in the last 60 days \(1\)/.test(t) && /Received/.test(t), t.slice(0, 500));
  p.once("dialog", () => {});
  await p.click(`[data-noorder="${rags}"]`); await sleep(200); await p.fill("[data-noreason]", "We have a case in the back"); await p.click(`[data-nosave="${rags}"]`); await sleep(1200);
  ok("Not ordering, with why: the request is closed with the reason", (await q("select not_ordering_reason r from v_supply_requests where id = $1", [rags]))[0].r === "We have a case in the back" && /Nothing waiting to be bought/.test(await txt(p)), await banner(p));


  // ---- Buy: Log a purchase ----
  ok("Buy: Log a purchase leads, beside Put on a PO; there's no Mark ordered any more", !!(await p.$("[data-logopen]")) && !(await p.$("[data-reqorder]")));
  await q(`insert into supply_requests (department, item, qty, requested_by_name) values ('assembly_qc', 'Titebond III gallon', 1, 'KP'), ('metal', 'Steel wire brushes', 3, 'Willie J')`);
  await tab(p, "prices"); await tab(p, "buy");
  const rqT = (await q("select id from supply_requests where item = 'Titebond III gallon' and state = 'requested'"))[0].id, rqB = (await q("select id from supply_requests where item = 'Steel wire brushes'"))[0].id;
  await p.check(`[data-tick="${rqT}"]`); await p.check(`[data-tick="${rqB}"]`); await sleep(200);
  ok("Ticking two: the button says Log a purchase for 2 ticked", /Log a purchase for 2 ticked/.test(await p.innerText("[data-logopen]")));
  await p.click("[data-logopen]"); await sleep(400);
  ok("The form opens with both requests as lines: Titebond as the item the shop has, the brushes as a new item asking its category",
     (await p.inputValue('[data-lg="0|name"]')) === "Titebond III gallon" && (await p.inputValue('[data-lg="0|qty"]')) === "1"
     && (await p.inputValue('[data-lg="1|name"]')) === "Steel wire brushes" && (await p.isHidden('[data-lgnew="0"]')) && (await p.isVisible('[data-lgnew="1"]'))
     && /Assembly \/ QC asked for it/.test(await txt(p)) && /Metal asked for it/.test(await txt(p)));
  await p.fill('[data-lgf="supplier"]', "Corner Hardware"); await p.fill('[data-lgf="doc"]', "R-1188");
  await p.fill('[data-lg="0|price"]', "31.49"); await p.fill('[data-lg="1|price"]', "6.98");
  await p.selectOption('[data-lg="1|cat"]', "hardware"); await p.fill('[data-lg="1|unit"]', "each"); await sleep(200);
  ok("It totals as you type ($52.43), and says the supplier is new", (await p.innerText("#logTotal")) === "$52.43" && (await p.isVisible("#logSupNew")), await p.innerText("#logTotal"));
  await p.click("[data-logsave]"); await sleep(1800);
  t = await banner(p);
  ok("Logged: $52.43 from Corner Hardware, 2 requests marked ordered, the brushes a new item, the supplier added", /Logged: \$52\.43 from Corner Hardware/.test(t) && /2 supply requests are marked ordered/.test(t)
     && /New item: Steel wire brushes/.test(t) && /Corner Hardware is a new supplier/.test(t), t);
  ok("In the database: both requests ordered, naming where they were bought", (await q("select count(*)::int n from supply_request_events where what = 'Ordered: bought from Corner Hardware'"))[0].n === 2
     && (await q("select state from supply_requests where id = $1", [rqB]))[0].state === "ordered");
  t = await txt(p);
  ok("Logged lately: Corner Hardware, R-1188, both items, $52.43, with Change and It was a mistake", /Logged lately/.test(t) && /Corner Hardware/.test(t) && /R-1188/.test(t)
     && /Titebond III gallon × 1, Steel wire brushes × 3/.test(t) && /\$52\.43/.test(t) && !!(await p.$("[data-logchange]")), t.slice(0, 900));
  await tab(p, "prices"); t = await txt(p);
  ok("Prices counts it straight away: Steel wire brushes, 3 each at $6.98", /Steel wire brushes 3 each \$6\.98/.test(t), t.slice(0, 1200));
  await tab(p, "buy");
  const lg = (await q("select id from purchase_logs"))[0].id;
  await p.click(`[data-logchange="${lg}"]`); await sleep(400);
  ok("Change: the form opens with what was logged", (await p.inputValue('[data-lgf="supplier"]')) === "Corner Hardware" && (await p.inputValue('[data-lg="1|price"]')) === "6.98");
  await p.click('[data-logx="1"]'); await sleep(300); await p.fill('[data-lg="0|price"]', "30.99"); await p.click("[data-logsave]"); await sleep(1800);
  ok("Changed: the brushes came off, so Metal's request is to be ordered again; Titebond is now $30.99", /Changed: \$30\.99 from Corner Hardware/.test(await banner(p)) && /1 request is back to be ordered/.test(await banner(p))
     && (await q("select state from supply_requests where id = $1", [rqB]))[0].state === "requested" && /3 × Steel wire brushes/.test(await txt(p)), await banner(p));
  p.once("dialog", d => d.accept("Logged it twice"));
  await p.click(`[data-logmistake="${lg}"]`); await sleep(1800); t = await txt(p);
  ok("It was a mistake: kept under Logged lately, marked and not counted; its request is to be ordered again", /A mistake: Logged it twice, not counted/.test(t)
     && (await q("select state from supply_requests where id = $1", [rqT]))[0].state === "requested" && !(await p.$(`[data-logchange="${lg}"]`)), t.slice(0, 900));
  await tab(p, "prices");
  ok("…and Prices no longer counts it", !/Steel wire brushes 3 each/.test(await txt(p)));
  await tab(p, "buy");
  for (const id of [rqT, rqB]) { await p.click(`[data-noorder="${id}"]`); await sleep(200); await p.fill("[data-noreason]", "Test"); await p.click(`[data-nosave="${id}"]`); await sleep(1200); }
  // ---- the folder, filing, the PDF ----
  t = await txt(p);
  ok("Buy: PO 00001 not filed yet; the banner offers the folder", /PO 00001/.test(t) && /Not filed/.test(t) && /Choose the PD - POs folder/.test(t), t.slice(0, 300));
  await p.click("[data-pickfolder]"); await sleep(2500);
  let files = await folderFiles(p);
  ok("Choosing the folder files PO 00001.pdf in it", !!files["PO 00001.pdf"], Object.keys(files).join(", "));
  if (files["PO 00001.pdf"]) {
    const pt = pdfText(files["PO 00001.pdf"]);
    ok("The PDF is the PD - PO sheet: Purchase Order, PO Number 00001, the supplier, the line and the total", /Purchase Order/.test(pt) && /00001/.test(pt) && /Pat Test/.test(pt)
       && /2 gallon/.test(pt) && /Titebond III gallon/.test(pt) && /38\.50/.test(pt) && /77\.00/.test(pt) && /Tax exempt: check line/.test(pt), pt.slice(0, 600));
  }
  ok("The database knows it's filed", (await q("select filed_at is not null f from purchase_pos where name = 'PO 00001'"))[0].f);

  // ---- a lumber PO, and its delivery slips on the PO ----
  await p.click('[data-newpo="lumber"]'); await sleep(400);
  t = await txt(p);
  ok("Make a lumber PO: Lumber PO 24 (its own numbers)", /Make Lumber PO 24/.test(t), t.slice(0, 120));
  const lumId = (await q("select id from purchase_suppliers where name = 'Test Lumber Co'"))[0].id, ash7 = (await q("select id from purchase_items where name = '7/4 Ash'"))[0].id;
  await p.selectOption('[data-e="vendor_id"]', lumId); await p.fill('[data-l="0|qty"]', "2000"); await p.fill('[data-l="0|description"]', "7/4 Natural Ash SB SLR");
  await p.fill('[data-l="0|unit_price"]', "3.015"); await p.selectOption('[data-l="0|item_id"]', ash7);
  await p.click("[data-savepo]"); await sleep(2500);
  files = await folderFiles(p);
  ok("Lumber PO 24.pdf is filed beside PO 00001, its price printed as 3.02 (half up)", !!files["Lumber PO 24.pdf"] && /3\.02/.test(pdfText(files["Lumber PO 24.pdf"])), await banner(p));
  const lpo = (await q("select id from purchase_pos where name = 'Lumber PO 24'"))[0].id;
  if (!(await p.$(`[data-slippo="${lpo}"]`))) { await p.click(`[data-openpo="${lpo}"]`); await sleep(300); }
  await p.click(`[data-slippo="${lpo}"]`); await sleep(1200);
  ok("A lumber PO's delivery slips are picked on the PO (none on Inventory yet here)", /No lumber slips on the Inventory page for this PO|Fills/.test(await txt(p)), (await txt(p)).slice(-300));

  // ---- Prices: a Purchases file, in one step ----
  makeXlsx("/tmp/purchases-check.xlsx", [
    [`${year}-01-06`, "TSC", "B-100", "Bill", "TITEBOND III 1 GAL", "Hardware", "Titebond III gallon", 4, "gallon", 150, "Yes", ""],
    [`${year}-01-06`, "TSC", "B-100", "Bill", "Shop towels, box of 200", "Other", "", 1, "box", 32.5, "Yes", ""],
    [`${today}`, "Test Lumber Co", "L-24", "Bill", "7/4 ASH 2,000 BF", "Lumber", "7/4 Ash", 2000, "bd ft", 6030, "Yes", "Lumber PO 24 (ordered 2,000)"],
  ]);
  await tab(p, "prices");
  let card = await addFile(p, "/tmp/purchases-check.xlsx");
  ok("Reading the .xlsx: its Lines tab, 3 lines, 1 for a PO, before anything is added", /3 lines/.test(card) && /1 say which PO/.test(card), card.slice(0, 300));
  t = await txt(p);
  ok("Added: the page says 3 lines went in, and that 1 line has no item", /purchases-check\.xlsx added: 3 lines/.test(t) && /1 line has no item/.test(t), t.slice(0, 300));
  const buys = await q("select description, item_id is not null matched, po_ref, supplier_id is not null known from purchase_buys order by bought_on, line_key");
  ok("The supplier found by its other name; the lumber bill kept against Lumber PO 24", buys.find(b => b.description === "TITEBOND III 1 GAL").known && buys.find(b => b.description === "7/4 ASH 2,000 BF").po_ref === "Lumber PO 24", JSON.stringify(buys));
  await p.click('[data-sheet="match"]'); await sleep(300); t = await txt(p);
  ok("Give it an item: a sheet with that one line, and New item, It's for a PO and Leave it out", /Shop towels, box of 200/.test(t) && /New item/.test(t) && /It's for a PO/.test(t) && /Leave it out/.test(t), t.slice(-400));
  await p.click("[data-newitemopen]"); await sleep(200);
  await p.fill('[data-nm="name"]', "Shop towels 200"); await p.selectOption('[data-nm="category_key"]', "other"); await p.fill('[data-nm="unit"]', "box");
  await p.click("[data-newitem]"); await sleep(1800);
  ok("New item made and matched; the sheet says every line has an item", /Every line has an item/.test(await txt(p)) && (await q("select count(*)::int n from purchase_buys where item_id is null and po_ref = ''"))[0].n === 0, (await txt(p)).slice(-200));
  await p.click(".sheet [data-sheetclose]"); await sleep(300);
  await addFile(p, "/tmp/purchases-check.xlsx");
  ok("The same file again: 0 lines added, 3 already in", /added: 0 lines, 3 already in/.test(await txt(p)), (await txt(p)).slice(0, 200));
  makeXlsx("/tmp/purchases-feb.xlsx", [[`${year}-02-03`, "Test Supply Co Inc", "B-200", "Card", "Shop towels, box of 200", "", "", 2, "box", 66, "Yes", ""]]);
  await addFile(p, "/tmp/purchases-feb.xlsx");
  ok("The next file's same line files itself (another name for the same supplier): nothing to give an item", !/no item/.test(await txt(p))
     && (await q("select count(*)::int n from purchase_buys where doc_number = 'B-200' and item_id is not null"))[0].n === 1, (await txt(p)).slice(0, 200));

  // ---- a file naming items that aren't here yet: made without a question, reported after ----
  makeXlsx("/tmp/purchases-mar.xlsx", [
    [`${year}-03-03`, "Test Supply Co", "B-300", "Bill", "3/4 MPL PLY VC 4X8", "Sheet goods", "3/4\" Maple ply, VC", 10, "sheet", 612.5, "Yes", ""],
    [`${year}-03-03`, "Test Supply Co", "B-300", "Bill", "1/2 BIRCH PLY 4X8", "Sheet goods", "1/2\" Birch ply", 2, "sheet", 96, "Yes", ""],
    [`${year}-03-04`, "Other Lumber Yard", "L-30", "Bill", "7/4 ASH FAS 100 BF", "Lumber", "7/4 Ash lumber", 100, "bd ft", 330, "Yes", ""]]);
  card = await addFile(p, "/tmp/purchases-mar.xlsx");
  ok("Before adding: it names 3 items that aren't here yet, 1 looking like an item the shop has", /names 3 items that aren't here yet \(1 look/.test(card), card.slice(0, 400));
  t = await txt(p);
  ok("After: 3 lines added, 2 new items made, and “7/4 Ash lumber” taken as 7/4 Ash, with Not the same", /purchases-mar\.xlsx added: 3 lines/.test(t) && /2 new items were made/.test(t)
     && /“7\/4 Ash lumber” was taken as 7\/4 Ash/.test(t) && /Not the same/.test(t) && !/no item/.test(t), t.slice(0, 400));
  const ply = (await q("select id, category_key, unit from purchase_items where name = '3/4\" Maple ply, VC'"))[0], birch = (await q("select id from purchase_items where name = '1/2\" Birch ply'"))[0];
  ok("In the database: the plywood is a sheet-goods item in sheets, and 7/4 Ash has the file's name as another name", ply && ply.category_key === "sheet_goods" && ply.unit === "sheet" && !!birch
     && (await q("select aliases from purchase_items where name = '7/4 Ash'"))[0].aliases.includes("7/4 Ash lumber")
     && (await q("select count(*)::int n from purchase_buys where item_id is null and po_ref = ''"))[0].n === 0);
  await p.click("[data-split]"); await sleep(1500);
  const split = (await q("select id, quarters from purchase_items where name = '7/4 Ash lumber'"))[0];
  ok("Not the same: “7/4 Ash lumber” is an item of its own with its line, and no longer a name for 7/4 Ash", split && split.quarters === 7
     && (await q("select count(*)::int n from purchase_buys where doc_number = 'L-30' and item_id = $1", [split && split.id]))[0].n === 1
     && !(await q("select aliases from purchase_items where name = '7/4 Ash'"))[0].aliases.includes("7/4 Ash lumber"), await banner(p));
  await p.click('[data-sheet="newitems"]'); await sleep(300); t = await txt(p);
  ok("See them: the two items the file made, each with Same as…", /2 new items from purchases-mar\.xlsx/.test(t) && /3\/4" Maple ply, VC/.test(t) && /1\/2" Birch ply/.test(t), t.slice(-300));
  const k = await p.evaluate((id) => { const b = [...document.querySelectorAll("[data-foldgo]")].find(x => x.dataset.foldgo.endsWith(id)); return b.dataset.foldgo.split("|")[0]; }, birch.id);
  await p.selectOption(`[data-foldsel="${k}"]`, ply.id); await p.click(`[data-foldgo="${k}|${birch.id}"]`); await sleep(1500);
  ok("Same as, from the sheet: the birch line moves to the plywood item and the birch item is retired, kept", (await q("select count(*)::int n from purchase_buys where description = '1/2 BIRCH PLY 4X8' and item_id = $1", [ply.id]))[0].n === 1
     && (await q("select retired, name from purchase_items where id = $1", [birch.id]))[0].retired, await banner(p));
  if (await p.$(".sheet [data-sheetclose]")) { await p.click(".sheet [data-sheetclose]"); await sleep(200); }
  await tab(p, "setup"); await p.click(`[data-edititem="${split.id}"]`); await sleep(300);
  await p.selectOption("#foldInto", ash7); p.once("dialog", d => d.accept()); await p.click(`[data-folditem="${split.id}"]`); await sleep(1500);
  ok("Same as, from Setup: “7/4 Ash lumber” is folded back into 7/4 Ash, its line with it", (await q("select count(*)::int n from purchase_buys where doc_number = 'L-30' and item_id = $1", [ash7]))[0].n === 1
     && (await q("select retired from purchase_items where id = $1", [split.id]))[0].retired, await banner(p));

  // ---- Prices: what was paid, worth a look, the export ----
  await tab(p, "prices"); t = await txt(p);
  ok("Prices: five columns, an item a row, with 7/4 Ash down against 8/4's baseline × 8/7", /Item Bought Average Against its baseline Saved/.test(t) && /7\/4 Ash 2,100 bd ft/.test(t) && /down \d/.test(t) && /Titebond III gallon/.test(t), t.slice(0, 900));
  ok("Worth a look: 7/4 Ash has two prices (two lumber yards), in a sentence", /7\/4 Ash has two prices\./.test(t) && /\$3\.015 at Test Lumber Co/.test(t) && /\$3\.30 at Other Lumber Yard/.test(t), t.slice(0, 500));
  await p.click(`[data-openitem="${ash7}"]`); await sleep(300); t = await txt(p);
  ok("Tap an item: every price paid, and what it's measured against", /Measured against \$5\.051/.test(t) && /Lumber PO 24/.test(t) && /L-30/.test(t), t.slice(0, 1200));
  await p.click('[data-cat="lumber"]'); await sleep(300); await openFold(p, "lumber"); t = await txt(p);
  ok("The Lumber chip: only lumber in the table, and More on lumber with the POs' board feet", !/Titebond III gallon/.test(t) && /Board feet on lumber POs 2,000/.test(t), t.slice(-600));
  const [dl] = await Promise.all([p.waitForEvent("download"), p.click("[data-export]")]);
  const csv = fs.readFileSync(await dl.path(), "utf8");
  const lines = csv.replace(/\r\n$/, "").split(/\r\n/);          // (not trim(): it would take the byte-order mark Excel needs)
  // counted: PO 00001 and Lumber PO 24 (a line each), and six file lines with no PO; the lumber bill for PO 24 not again
  ok("The export: a header and one row per counted line (8), named for the year", lines.length === 9 && /^\ufeffDate,From,PO or bill #,Supplier/.test(lines[0]) && new RegExp(`Purchasing ${year}`).test(dl.suggestedFilename()), lines.length + " " + dl.suggestedFilename());
  ok("The export has the lumber PO line once, and no line for its bill", lines.filter(l => /7\/4 Natural|7\/4 ASH 2,000/.test(l)).length === 1 && lines.some(l => /^\S+,PO,Lumber PO 24/.test(l)), lines.join("\n").slice(0, 600));

  // ---- Savings: the year as pictures ----
  const expect = 77 + 6030 + 150 + 32.5 + 66 + 612.5 + 96 + 330;
  await q(`insert into lumber_scrap_history (month_end, zero_bf, used_bf) values ('${year}-04-30', 3106, 4434), ('${year}-09-30', 7446, 31185)`);
  await tab(p, "savings"); t = await txt(p);
  ok(`Savings: one sentence for the year, on $${Math.round(expect).toLocaleString("en-US")} of buying (each buy counted once)`, /saved so far in \d{4}\./.test(t) && new RegExp(`on \\$${Math.round(expect).toLocaleString("en-US")} of production buying`).test(t), t.slice(0, 300));
  ok("Savings: the chart is drawn, with where it came from and the biggest movers as bars", (await p.$$("#chart svg path.c-line")).length === 1 && /Where it came from/.test(t) && /Biggest movers/.test(t) && (await p.$$("[data-mover]")).length >= 3, t.slice(0, 600));
  await p.click('[data-m="2"]'); await sleep(200);
  ok("Tap a month: March's figures under the chart", /Mar: .* on \$1,039 of buying/.test(await p.innerText("#readout")), await p.innerText("#readout"));
  ok("Lumber scrap: a bar a month; September (4.19) swamps it", /Lumber scrap/.test(t) && /September/.test(t) && /4\.19/.test(t), t.slice(0, 900));
  p.once("dialog", d => d.accept("The counts weren't done"));
  await p.click(`[data-skipmonth="${year}-09-30"]`); await sleep(1500); t = await txt(p);
  ok("Leave out: September shows as left out with Put back, the scrap saved is April's alone (846 bd ft), and the month is kept", /September\s+left out\s+Put back/.test(t) && !/4\.19/.test(t) && /846 bd ft/.test(t)
     && (await q("select left_out from lumber_scrap_skips where month_end = $1", [`${year}-09-30`]))[0].left_out
     && (await q("select count(*)::int n from lumber_scrap_history where month_end = $1", [`${year}-09-30`]))[0].n === 1, t.slice(0, 900));
  await p.click(`[data-putbackmonth="${year}-09-30"]`); await sleep(1500);
  ok("Put back: September counts again; its row is kept, marked", /4\.19/.test(await txt(p)) && (await q("select left_out from lumber_scrap_skips where month_end = $1", [`${year}-09-30`]))[0].left_out === false);
  await p.click(`[data-mover="${ash7}"]`); await sleep(500);
  ok("Tap a mover: Prices opens with that item's prices paid", (await p.getAttribute('[data-tab="prices"]', "aria-current")) === "true" && /Measured against \$5\.051/.test(await txt(p)));
  ok("No page errors for Luke", !s.errs.length, s.errs.join(" | "));

  // ---- the page on a database without the two newer files ----
  await q("drop function lumber_scrap_skips_list()");
  const s2 = await session(browser, users.luke);            // a fresh session: headless Chromium falls over reloading with the stand-in folder kept
  await s2.p.goto(base + "purchasing.html#savings"); await s2.p.waitForSelector("[data-tab]"); await sleep(1200);
  ok("Without lumber_scrap_skips.sql: the scrap bars show, with no Leave out link, and no page errors",
     /September/.test(await txt(s2.p)) && !(await s2.p.$("[data-skipmonth]")) && !s2.errs.length, s2.errs.join(" | "));
  await q("drop function purchases_add(uuid, jsonb, jsonb, jsonb)"); await q("drop function purchase_file_items_list()"); await q("drop function purchase_logs_list()");
  const s3 = await session(browser, users.luke);
  await s3.p.goto(base + "purchasing.html#prices"); await s3.p.waitForSelector("[data-tab]"); await sleep(1200);
  makeXlsx("/tmp/purchases-apr.xlsx", [[`${year}-04-02`, "Test Supply Co", "B-400", "Bill", "DRAWER SLIDE 20IN", "Hardware", "Drawer slide, 20 in", 12, "each", 286.8, "Yes", ""]]);
  await addFile(s3.p, "/tmp/purchases-apr.xlsx"); t = await txt(s3.p);
  ok("Without purchasing_log.sql: a file still goes in, its new name waits for an item as before, and no page errors", /1 new line/.test(t) && /1 line has no item/.test(t)
     && (await q("select count(*)::int n from purchase_buys where doc_number = 'B-400' and item_id is null"))[0].n === 1 && !s3.errs.length, t.slice(0, 300) + s3.errs.join(" | "));
  await q("insert into supply_requests (department, item, qty, requested_by_name) values ('cnc', 'Pod pads', 6, 'Sam D')");
  await s3.p.click('[data-tab="buy"]'); await sleep(900);
  ok("Without purchasing_log.sql: no Log a purchase, and Mark ordered is there as before", !(await s3.p.$("[data-logopen]")) && !!(await s3.p.$("[data-reqorder]")) && !/Logged lately/.test(await txt(s3.p)));

  // ---- Mike ----
  const m = await session(browser, users.mike);
  await m.p.goto(base + "purchasing.html"); await sleep(1500);
  ok("Mike (a supervisor) is turned away by the page", /For managers/.test(await txt(m.p)), await txt(m.p));
  const r = await makeClient(users.mike).rpc("purchasing_data");
  ok("…and by the database: purchasing_data refuses him", !!r.error, JSON.stringify(r).slice(0, 200));

  // ---- phone width ----
  const ph = await session(browser, users.luke, 390);
  for (const tb of ["buy", "savings", "prices"]) {
    await ph.p.goto(base + "purchasing.html#" + tb); await sleep(1500);
    const wide = await ph.p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    ok(`At phone width ${tb[0].toUpperCase() + tb.slice(1)} doesn't scroll sideways (wide tables scroll in their box)`, !wide);
  }
  ok("No page errors at phone width", !ph.errs.length, ph.errs.join(" | "));

  console.log(`\ntest_purchasing: ${fail} failed`);
  await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(async e => { console.error("FAIL  the test stopped: " + (e && e.stack || e)); process.exit(1); });
