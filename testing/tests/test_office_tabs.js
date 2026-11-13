// 11 Nov: the office, simpler (office.html, purchasing.html and pace.html 2026-11-11.1), in real Chromium through the real
// database as Luke. The tabs are the daily work (Operations · Jobs · Purchasing · Deliveries; Jobs replaced Job status later on 11 Nov); the ☰ menu holds Project
// Handoff, Inventory, Data and OneDrive. Arrow's lists are on Operations (Gone to Arrow, Mark returned, back in three months); a
// computer that remembers the old Arrow tab opens Operations; the job page's Arrow line jumps there. Setup: the floor's rules,
// the Arrow alert (saved), then the connections; no Supply lists. Purchasing: AR-10 under POs with Make it again, the next AR
// number in Setup, the supply lists in Setup (add, edit, retire). Data: Pace, with Working days behind Setup.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis OUT=/tmp/allpages node test_office_tabs.js
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_arrow_po_remake.js
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_arrow_po_remake.js
const fs = require("fs"), http = require("http"), path = require("path"), cp = require("child_process");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo", OLDDB = process.env.OLDDB === "1";
const PDFLIB = "/tmp/pdflib/package/dist/pdf-lib.min.js";
if (!fs.existsSync(PDFLIB)) cp.execSync("mkdir -p /tmp/pdflib && cd /tmp/pdflib && npm pack pdf-lib@1.17.1 >/dev/null 2>&1 && tar xzf pdf-lib-1.17.1.tgz");
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session: localStorage.getItem("fake_signed_out") ? null : session } }),
                   signOut: async () => { localStorage.setItem("fake_signed_out", "1"); return {}; }, onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (b) => ({ download: async () => ({ data: null, error: { message: "not in this test" } }),
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }), upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/office.html";
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});
async function session(browser, user) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 860 }, serviceWorkers: "block" });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());          // (the last rule added wins in Playwright)
  await ctx.route(/pdf-lib@1\.17\.1/, r => r.fulfill({ body: fs.readFileSync(PDFLIB), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("framenavigated", () => {}); p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs };
}

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/office.html`;
  const q = async (sql, args = []) => (await admin.query(sql, args)).rows;
  await q("select lab_allow('luke@example.com')");
  const willie = makeClient(users.willie), luke = makeClient(users.luke);
  // two sheets of PROJ-00418 sent to Arrow by Metal: sheet 5 made into AR-10 (at Arrow), sheet 6 left waiting; sheet 5 later back
  const sheet = async (n) => (await q(`select s.* from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
                        where j.project_id = 'PROJ-00418' and w.is_current and s.sheet_number = $1`, [n]))[0];
  const setup = [await luke.rpc("set_arrow_po_settings", { p: { issued_by: "Luke Hart", phone: "555-0100", email: "luke@example.com",
                   address: "Purposeful Design\n1 Test Street", tax_line: "Tax exempt (test)", next_number: 10 } })];
  for (const n of [5, 6]) { const s = await sheet(n); if (!s) { setup.push({ error: { message: "no sheet " + n } }); continue; }
    const pr = (await q("select id, qty_required from sheet_progress where sheet_id = $1 and department = 'metal'", [s.id]))[0];
    if (!pr) { setup.push({ error: { message: "sheet " + n + " has no Metal step" } }); continue; }
    setup.push(await willie.rpc("set_count", { p_progress: pr.id, p_qty: pr.qty_required }));
    setup.push(await willie.rpc("send_sheet", { p_sheet: s.id, p_from: "metal", p_route: "arrow" })); }
  const items = await q(`select o.id, o.sheet_numbers from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = 'PROJ-00418' and o.waiting order by o.sheet_numbers`);
  const first = items.find(i => (i.sheet_numbers || []).includes(5));
  if (first) setup.push(await willie.rpc("arrow_po_make", { p_client_id: "6f0c0a10-0000-4000-8000-000000000011", p_gone_on: null, p_items: [{ id: first.id }] }));
  const bad = setup.filter(r => r.error).map(r => r.error.message);
  ok("setup through the real functions: two sheets sent to Arrow, AR-10 made for one", !bad.length && items.length === 2 && !!first, bad.join(" | ") || JSON.stringify(items));

  const browser = await chromium.launch();
  let s = await session(browser, users.luke), p = s.p;
  p.on("dialog", d => d.accept());
  await p.goto(base); await p.waitForSelector("header.top nav.tabs .tab", { timeout: 15000 });
  const tabs = await p.$$eval("nav.tabs .tab", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
  ok("The office's tabs: Operations, Jobs, Purchasing, Deliveries (Jobs since 11 Nov, test_jobs_tab)", JSON.stringify(tabs) === JSON.stringify(["Operations", "Jobs", "Purchasing", "Deliveries"]), tabs.join(", "));
  await p.click("[data-menu]"); await p.waitForSelector(".menu");
  const items2 = await p.$$eval(".menu .mitem, .menu a", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
  ok("The ☰ menu: Operations, Project Handoff, Inventory, Data, OneDrive, Tablet app, Setup, Feedback, Sign out",
     JSON.stringify(items2) === JSON.stringify(["Operations", "Project Handoff", "Inventory", "Data", "OneDrive", "Tablet app", "Setup", "Feedback", "Sign out"]), items2.join(", "));
  await p.click('.menu [data-tab="photos"]'); await p.waitForTimeout(800);
  ok("OneDrive opens from the menu", /OneDrive/.test(await p.$eval("main h1", e => e.textContent)));
  await p.click('header.top [data-tab="tasks"]');
  await p.waitForSelector("#opsarrow", { timeout: 15000 });
  const arr = async () => p.$eval("#opsarrow", e => e.innerText.replace(/\s+/g, " "));
  let a = await arr();
  ok("Operations has Arrow: 1 waiting to go, 1 at Arrow, with Gone to Arrow and Mark returned, and where the POs are", /1 waiting to go · 1 at Arrow/.test(a) && /Waiting to go to Arrow/.test(a)
     && !!(await p.$("#opsarrow [data-argone]")) && !!(await p.$("#opsarrow [data-arret]")) && /listed in Purchasing, under POs/.test(a), a.slice(0, 300));
  ok("…below the flags, and nothing called an Arrow tab anywhere", await p.evaluate(() => !!document.querySelector("#opsflags ~ #opsarrow")) && !(await p.$('[data-tab="arrow"]')));
  await p.click("#opsarrow [data-arret]"); await p.waitForFunction(() => /Back from Arrow — last three months \(1\)/.test(document.getElementById("opsarrow").innerText), null, { timeout: 10000 }).catch(() => {});
  a = await arr();
  ok("Mark returned: it leaves At Arrow and shows under Back from Arrow (1)", /Back from Arrow — last three months \(1\)/.test(a) && !/1 at Arrow/.test(a) && (await q("select count(*)::int n from outside_jobs where returned_on is not null"))[0].n === 1, a.slice(0, 200));
  // the job page's Arrow line jumps to Operations' Arrow section
  await p.click('header.top [data-tab="jobs"]'); await p.waitForSelector("[data-jobfind]", { timeout: 10000 });   // 11 Nov: Jobs
  await p.fill("[data-jobfind]", "418"); await p.waitForSelector("#jobhits button[data-openjob]", { state: "attached", timeout: 8000 });
  await p.press("[data-jobfind]", "Enter"); await p.waitForSelector("[data-arrowjump]", { timeout: 15000 });   // Enter opens the first hit
  await p.click("[data-arrowjump]"); await p.waitForSelector("#opsarrow", { timeout: 10000 }); await p.waitForTimeout(1500);
  ok("The job page's Arrow line (On Operations) opens Operations at its Arrow section", /Operations/.test(await p.$eval("main h1", e => e.textContent)) && await p.evaluate(() => document.getElementById("opsarrow").getBoundingClientRect().top < 400),
     await p.evaluate(() => document.querySelector("main h1").textContent + " top " + Math.round(document.getElementById("opsarrow").getBoundingClientRect().top)));
  // Setup
  await p.click("[data-menu]"); await p.click('.menu [data-tab="setup"]'); await p.waitForSelector("#set-arrow", { timeout: 15000 }); await p.waitForTimeout(2500);   // Setup's data arrives
  const jumps = await p.$$eval("nav.jumps button", els => els.map(e => e.textContent.trim()));
  ok("Setup: the floor's rules first, then the connections; no Supply lists", JSON.stringify(jumps) === JSON.stringify(["Routine tasks", "Departments", "Defect lists", "Finish-by days", "Arrow alert", "Monday connection", "Catch up from Monday", "TV link", "Test jobs"])
     && !(await p.$("#set-supplies")) && /Connections, set up once/.test(await p.innerText("main")), jumps.join(", "));
  await p.fill("#arDays", "21"); await p.click("[data-ardays]"); await p.waitForTimeout(1500);
  ok("The Arrow alert saves from Setup and says so there", (await q("select value from app_settings where key = 'arrow_alert_days'"))[0].value == 21 && !!(await p.$("#set-arrow .banner")), (await p.innerText("#set-arrow")).replace(/\s+/g, " ") + " | " + JSON.stringify(await q("select value from app_settings where key = 'arrow_alert_days'")));
  // an old computer that remembers the Arrow tab
  await p.evaluate(() => localStorage.setItem("sfo_tab", JSON.stringify("arrow"))); await p.goto(base); await p.waitForSelector("#opsarrow", { timeout: 15000 });
  ok("A computer that remembers the old Arrow tab opens Operations", /Operations/.test(await p.$eval("main h1", e => e.textContent)));
  // Purchasing as a tab
  await p.click('header.top [data-section="purchasing"]');
  const inFrame = await p.waitForFunction(() => [...document.querySelectorAll("#secs iframe")].some(f => !f.hidden && /purchasing/.test(f.src)), null, { timeout: 15000 }).then(() => true).catch(() => false);
  ok("The Purchasing tab opens Purchasing inside the office, marked as the open tab", inFrame && JSON.stringify(await p.$$eval("nav.tabs .tab", els => els.filter(e => e.getAttribute("aria-current") === "true").map(e => e.textContent.trim()))) === '["Purchasing"]');
  ok("No page errors on the office", !s.errs.length, s.errs.join(" | "));
  await s.ctx.close();

  // ---- Purchasing on its own ----
  s = await session(browser, users.luke); p = s.p; p.on("dialog", d => d.accept());
  await p.goto(base.replace("office.html", "purchasing.html")); await p.waitForSelector("#tabs [data-tab]", { timeout: 15000 });
  await p.click('#tabs [data-tab="buy"]'); await p.waitForSelector("[data-arpdf]", { timeout: 15000 });
  let t = await p.innerText("main");
  ok("Purchasing › POs lists AR-10 under Arrow POs, with PDF and Make it again, and says the next is AR-11", /Arrow POs/.test(t) && /AR-10/.test(t) && /418/.test(t) && !!(await p.$("[data-arremake]")) && /The next is AR-11/.test(t));
  await p.click('#tabs [data-tab="setup"]'); await p.waitForSelector("#nextArrow", { timeout: 10000 });
  ok("Setup › PO numbers has the next Arrow PO beside the other two, and says the last was AR-10", (await p.inputValue("#nextArrow")) === "11" && /The last Arrow PO is AR-10/.test(await p.innerText("main")));
  await p.fill("#nextArrow", "40"); await p.click("[data-savenextarrow]");
  // 12 Nov (R-36): wait for the save itself, up to 10 s, not a fixed 1.5 s (after a long run of browser tests the save once landed later and this line failed)
  let saved = {}; for (let i = 0; i < 20; i++) { saved = (await q("select next_number, phone from arrow_po_settings"))[0] || {}; if (saved.next_number === 40) break; await p.waitForTimeout(500); }
  ok("…saving it sets the next AR number, and only that", saved.next_number === 40 && saved.phone === "555-0100");
  t = await p.innerText("main");
  ok("Setup has Supply lists, one fold per department with a Supplies tab", /Supply lists/.test(t) && (await p.$$('details[data-keep^="sup_"]')).length === 7);
  await p.evaluate(() => { document.querySelector('details[data-keep="sup_cnc"]').open = true; });
  await p.click('[data-supadd="cnc"]'); await p.waitForSelector("#supName");
  await p.fill("#supName", "Shop rags"); await p.fill('[data-supg="0"][data-part="label"]', "Kind"); await p.fill('[data-supg="0"][data-part="options"]', "Cotton, Blue paper");
  await p.click("[data-supsave]"); await p.waitForTimeout(1500);
  const rag = (await q("select * from supply_items where name = 'Shop rags'"))[0];
  ok("Add an item: CNC's list gets Shop rags with its choices, and the fold shows it", rag && rag.department === "cnc" && JSON.stringify(rag.choices) === JSON.stringify([{ label: "Kind", options: ["Cotton", "Blue paper"] }])
     && /Shop rags/.test(await p.$eval('details[data-keep="sup_cnc"]', e => e.innerText)), JSON.stringify(rag));
  await p.click(`[data-supretire="${rag.id}"]`); await p.waitForTimeout(1500);
  ok("Retire it: off the list, kept as retired, with Bring back", (await q("select retired from supply_items where id = $1", [rag.id]))[0].retired === true && !!(await p.$(`[data-supback="${rag.id}"]`)));
  ok("No page errors on Purchasing", !s.errs.length, s.errs.join(" | "));
  await s.ctx.close();

  // ---- Data ----
  s = await session(browser, users.luke); p = s.p;
  await p.goto(base.replace("office.html", "pace.html")); await p.waitForSelector("#tabs button", { timeout: 15000 });
  const dt = await p.$$eval("#tabs button", els => els.map(e => e.textContent.trim()));
  ok("Data: one tab, Pace, and a Setup button", JSON.stringify(dt) === JSON.stringify(["Pace", "Setup"]), dt.join(", "));
  await p.click('#tabs [data-tab="days"]'); await p.waitForTimeout(800);
  ok("…Setup opens Working days", /Working days/.test(await p.innerText("main")));
  ok("No page errors on Data", !s.errs.length, s.errs.join(" | "));
  await s.ctx.close();

  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  crashed: " + e.message); process.exit(1); });
