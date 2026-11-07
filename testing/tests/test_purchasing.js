// 7 Nov: Purchasing (purchasing.sql, purchasing.html), the standalone first release. In real Chromium through the real
// database as Luke: Setup (PO details, a supplier with another name, a hardware item, 8/4 and 7/4 Ash with a 2025 baseline);
// To buy shows a tablet's supply request, two ticked go onto a PO and are marked ordered (Operations sees the same); PO 00001
// and Lumber PO 24 numbered apart; the PD - POs folder chosen and both filed as PDFs (PO 00001's number printed as 00001);
// the Purchases file as a real .xlsx (its Lines tab): a line naming a known item filed under it, a line for Lumber PO 24 kept
// against it and not counted again, the rest in Match these; matching it, and the next file's same line filing itself;
// Prices counting each buy once, the export's lines; Savings to chase; Lumber; Mike turned away by the page and the database.
// OLDDB=1: a database without purchasing.sql: the page says it isn't set up, no page errors.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh        (OLDDB=1: TEMPLATE=sync_base_old)
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

  const year = Number((await q("select extract(year from local_today())::int y"))[0].y), today = (await q("select local_today()::text d"))[0].d;
  await p.goto(base + "purchasing.html"); await p.waitForSelector("[data-tab]"); await sleep(800);
  const tabs = await p.$$eval("[data-tab]", b => b.map(x => x.innerText.trim()));
  ok("Seven tabs: To buy, POs, Prices, Savings to chase, Lumber, Purchases file, Setup", tabs.join("|").startsWith("To buy|POs|Prices|Savings to chase|Lumber|Purchases file|Setup"), tabs.join("|"));

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
  ok("Setup: a supplier with two other names", sup.some(x => x.name === "Test Supply Co" && x.aliases.join("|") === "TEST SUPPLY CO INC|TSC") || sup.some(x => x.name === "Test Supply Co" && x.aliases.length === 2), JSON.stringify(sup));
  ok("Setup: a hardware item in gallons, 8/4 Ash, and 7/4 Ash compared as 8/4", its.some(i => i.name === "Titebond III gallon" && i.category_key === "hardware" && i.unit === "gallon")
     && its.some(i => i.name === "7/4 Ash" && i.ca === "8/4 Ash" && i.quarters === 7), JSON.stringify(its));
  ok(`Setup: 8/4 Ash's ${year - 1} baseline, and 7/4 Ash measured against it at the same square feet ($5.0514)`, /\$5\.051/.test(await txt(p)) && (await q("select count(*)::int n from purchase_baselines"))[0].n === 1, (await txt(p)).slice(0, 200));

  // ---- To buy → a PO ----
  await q(`insert into supply_requests (department, item, qty, note, requested_by_name) values ('assembly_qc', 'Titebond III gallon', 2, 'for the glue-up', 'KP'), ('finishing', 'Rags', 1, null, 'Jim')`);
  await tab(p, "buy");
  let t = await txt(p);
  ok("To buy: the tablets' requests by department, waiting", /Assembly \/ QC/.test(t) && /2 × Titebond III gallon/.test(t) && /Finishing/.test(t) && /Waiting/.test(t), t.slice(0, 300));
  const req = (await q("select id from supply_requests where item = 'Titebond III gallon'"))[0].id;
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
  ok("PO 00001 made, and its supply request marked ordered", /PO 00001 made/.test(t) && /1 supply request is marked ordered/.test(t), t);
  const rq = (await q("select state from supply_requests where id = $1", [req]))[0];
  const ev = await q("select what from supply_request_events where request_id = $1", [req]);
  ok("The request is ordered in the database, as Operations' tick does, naming the PO", rq.state === "ordered" && ev.some(e => e.what === "Ordered on PO 00001"), JSON.stringify(ev));
  await tab(p, "buy"); t = await txt(p);
  ok("To buy shows it ordered on PO 00001; the other still waiting", /Ordered on PO 00001/.test(t) && /Rags/.test(t), t.slice(0, 400));

  // ---- the folder, filing, the PDF ----
  await tab(p, "pos"); t = await txt(p);
  ok("POs: PO 00001 not filed yet; the banner offers the folder", /PO 00001/.test(t) && /Not filed/.test(t) && /Choose the PD - POs folder/.test(t), t.slice(0, 300));
  await p.click("[data-pickfolder]"); await sleep(2500);
  let files = await folderFiles(p);
  ok("Choosing the folder files PO 00001.pdf in it", !!files["PO 00001.pdf"], Object.keys(files).join(", "));
  if (files["PO 00001.pdf"]) {
    const pt = pdfText(files["PO 00001.pdf"]);
    ok("The PDF is the PD - PO sheet: Purchase Order, PO Number 00001, the supplier, the line and the total", /Purchase Order/.test(pt) && /00001/.test(pt) && /Pat Test/.test(pt)
       && /2 gallon/.test(pt) && /Titebond III gallon/.test(pt) && /38\.50/.test(pt) && /77\.00/.test(pt) && /Tax exempt: check line/.test(pt), pt.slice(0, 600));
  }
  ok("The database knows it's filed", (await q("select filed_at is not null f from purchase_pos where name = 'PO 00001'"))[0].f);

  // ---- a lumber PO ----
  await p.click('[data-newpo="lumber"]'); await sleep(400);
  t = await txt(p);
  ok("Make a lumber PO: Lumber PO 24 (its own numbers)", /Make Lumber PO 24/.test(t), t.slice(0, 120));
  const lumId = (await q("select id from purchase_suppliers where name = 'Test Lumber Co'"))[0].id, ash7 = (await q("select id from purchase_items where name = '7/4 Ash'"))[0].id;
  await p.selectOption('[data-e="vendor_id"]', lumId); await p.fill('[data-l="0|qty"]', "2000"); await p.fill('[data-l="0|description"]', "7/4 Natural Ash SB SLR");
  await p.fill('[data-l="0|unit_price"]', "3.015"); await p.selectOption('[data-l="0|item_id"]', ash7);
  await p.click("[data-savepo]"); await sleep(2500);
  files = await folderFiles(p);
  ok("Lumber PO 24 made and filed beside PO 00001", /Lumber PO 24 made/.test(await banner(p)) || !!files["Lumber PO 24.pdf"], await banner(p));
  ok("Lumber PO 24.pdf is in the folder, its number printed as 24 and the price as 3.02 (half up)", !!files["Lumber PO 24.pdf"] && /3\.02/.test(pdfText(files["Lumber PO 24.pdf"])));

  // ---- the Purchases file ----
  makeXlsx("/tmp/purchases-check.xlsx", [
    [`${year}-01-06`, "TSC", "B-100", "Bill", "TITEBOND III 1 GAL", "Hardware", "Titebond III gallon", 4, "gallon", 150, "Yes", ""],
    [`${year}-01-06`, "TSC", "B-100", "Bill", "Shop towels, box of 200", "Other", "", 1, "box", 32.5, "Yes", ""],
    [`${today}`, "Test Lumber Co", "L-24", "Bill", "7/4 ASH 2,000 BF", "Lumber", "7/4 Ash", 2000, "bd ft", 6030, "Yes", "Lumber PO 24 (ordered 2,000)"],
  ]);
  await tab(p, "file");
  await p.setInputFiles("#fileIn", "/tmp/purchases-check.xlsx"); await sleep(1500);
  t = await txt(p);
  ok("Reading the .xlsx: its Lines tab, 3 lines, 1 of them for a PO", /3 lines/.test(t) && /1 of them say which PO/.test(t), t.slice(0, 300));
  await p.click("[data-filesend]"); await sleep(1200);
  t = await banner(p);
  ok("Added: 3 new lines, 2 filed under an item, 1 to match", /3 new lines \(2 filed under an item, 1 to match\)/.test(t), t);
  const buys = await q("select description, item_id is not null matched, po_ref, supplier_id is not null known from purchase_buys order by bought_on, line_key");
  ok("The supplier found by its other name; the lumber bill kept against Lumber PO 24", buys.find(b => b.description === "TITEBOND III 1 GAL").known && buys.find(b => b.description === "7/4 ASH 2,000 BF").po_ref === "Lumber PO 24", JSON.stringify(buys));
  t = await txt(p);
  ok("Match these: the shop towels wait, with New item, For a PO and Leave out", /Shop towels, box of 200/.test(t) && /New item/.test(t) && /Leave out/.test(t), t.slice(0, 400));
  await p.click('[data-newitemopen]'); await sleep(200);
  await p.fill('[data-nm="name"]', "Shop towels 200"); await p.selectOption('[data-nm="category_key"]', "other"); await p.fill('[data-nm="unit"]', "box");
  await p.click("[data-newitem]"); await sleep(1500);
  ok("New item made and matched; nothing left to match", /Nothing waiting/.test(await txt(p)) && (await q("select count(*)::int n from purchase_buys where item_id is null"))[0].n === 0, await banner(p));
  await p.setInputFiles("#fileIn", "/tmp/purchases-check.xlsx"); await sleep(1200); await p.click("[data-filesend]"); await sleep(1200);
  ok("The same file again: nothing new, 3 already in", /0 new lines.*3 already in/.test(await banner(p)), await banner(p));
  makeXlsx("/tmp/purchases-feb.xlsx", [[`${year}-02-03`, "Test Supply Co Inc", "B-200", "Card", "Shop towels, box of 200", "", "", 2, "box", 66, "Yes", ""]]);
  await p.setInputFiles("#fileIn", "/tmp/purchases-feb.xlsx"); await sleep(1200); await p.click("[data-filesend]"); await sleep(1200);
  ok("The next file's same line files itself (matched before)", /1 filed under an item, 0 to match/.test(await banner(p)), await banner(p));

  makeXlsx("/tmp/purchases-mar.xlsx", [
    [`${year}-03-03`, "Test Supply Co", "B-300", "Bill", "3/4 MPL PLY VC 4X8", "Sheet goods", "3/4\" Maple ply, VC", 10, "sheet", 612.5, "Yes", ""],
    [`${year}-03-04`, "Test Lumber Co", "L-30", "Bill", "7/4 ASH FAS 100 BF", "Lumber", "7/4 Ash lumber", 100, "bd ft", 300, "Yes", ""]]);
  await p.setInputFiles("#fileIn", "/tmp/purchases-mar.xlsx"); await sleep(1200); await p.click("[data-filesend]"); await sleep(1500);
  t = await txt(p);
  ok("A file naming items that aren't here yet: listed, with the 7/4 Ash look-alike proposed as Same as 7/4 Ash", /names 2 items that aren't here yet/.test(t)
     && (await p.$eval('[data-fndo="0"]', e => e.options[e.selectedIndex].text)) === "Same as 7/4 Ash" && (await p.$eval('[data-fndo="1"]', e => e.value)) === "new", t.slice(0, 500));   // lumber is listed first
  await p.click("[data-fnapply]"); await sleep(2500);
  const ply = (await q("select category_key, unit from purchase_items where name = '3/4\" Maple ply, VC'"))[0], a7 = (await q("select aliases from purchase_items where name = '7/4 Ash'"))[0];
  ok("Do these: the plywood made as a sheet-goods item in sheets, the lumber line filed as 7/4 Ash with the file's name kept as another name",
     ply && ply.category_key === "sheet_goods" && ply.unit === "sheet" && a7.aliases.includes("7/4 Ash lumber")
     && (await q("select count(*)::int n from purchase_buys where item_id is null and po_ref = ''"))[0].n === 0, JSON.stringify({ ply, a7, b: await banner(p) }));

  // ---- Prices, the export ----
  await tab(p, "prices"); t = await txt(p);
  // counted: PO 00001 2 x 38.50 = 77; Lumber PO 24 2,000 x 3.015 = 6,030; file: Titebond 150, towels 32.50 and 66 (Jan and Feb); the lumber bill not again
  const expect = 77 + 6030 + 150 + 32.5 + 66 + 612.5 + 300;
  ok(`Prices: spent ${expect.toLocaleString("en-US")} (the lumber bill for Lumber PO 24 not counted twice)`, new RegExp(`Spent on production \\$${Math.round(expect).toLocaleString("en-US")}`).test(t), t.slice(0, 300));
  ok("Prices: the items with their baselines (7/4 Ash against 8/4's baseline × 8/7)", /7\/4 Ash/.test(t) && /\$5\.051/.test(t) && /Titebond III gallon/.test(t), t.slice(0, 900));
  const [dl] = await Promise.all([p.waitForEvent("download"), p.click("[data-export]")]);
  const csv = fs.readFileSync(await dl.path(), "utf8");
  const lines = csv.replace(/\r\n$/, "").split(/\r\n/);          // (not trim(): it would take the byte-order mark Excel needs)
  ok("The export: a header and one row per counted line (7), named for the year", lines.length === 8 && /^\ufeffDate,From,PO or bill #,Supplier/.test(lines[0]) && new RegExp(`Purchasing ${year}`).test(dl.suggestedFilename()), lines.length + " " + dl.suggestedFilename());
  ok("The export has the lumber PO line once, and no line for its bill", lines.filter(l => /7\/4 Natural|7\/4 ASH 2,000/.test(l)).length === 1 && lines.some(l => /^\S+,PO,Lumber PO 24/.test(l)), lines.join("\n").slice(0, 600));

  // ---- the other tabs ----
  await tab(p, "chase"); t = await txt(p);
  ok("Savings to chase draws its three lists", /two suppliers/.test(t) && /creeping/.test(t) && /one supplier only/.test(t), t.slice(0, 200));
  await tab(p, "lumber"); t = await txt(p);
  ok("Lumber: 2,000 bd ft bought on lumber POs this year", /Board feet bought 2,000/.test(t), t.slice(0, 300));
  await p.click("[data-loadslips]"); await sleep(800);
  ok("Lumber: Inventory's slips can be shown to pick their PO lines", /No lumber slips on the Inventory page yet|Fills/.test(await txt(p)));
  ok("No page errors for Luke", !s.errs.length, s.errs.join(" | "));

  // ---- Mike ----
  const m = await session(browser, users.mike);
  await m.p.goto(base + "purchasing.html"); await sleep(1500);
  ok("Mike (a supervisor) is turned away by the page", /For managers/.test(await txt(m.p)), await txt(m.p));
  const r = await makeClient(users.mike).rpc("purchasing_data");
  ok("…and by the database: purchasing_data refuses him", !!r.error, JSON.stringify(r).slice(0, 200));

  // ---- phone width ----
  const ph = await session(browser, users.luke, 390);
  await ph.p.goto(base + "purchasing.html#prices"); await sleep(1500);
  const wide = await ph.p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  ok("At phone width the page doesn't scroll sideways (wide tables scroll in their box)", !wide);

  console.log(`\ntest_purchasing: ${fail} failed`);
  await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(async e => { console.error("FAIL  the test stopped: " + (e && e.stack || e)); process.exit(1); });
