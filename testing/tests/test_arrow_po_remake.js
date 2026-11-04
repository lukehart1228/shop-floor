// 4 Nov: Make an Arrow PO again (arrow_po_remake.sql) and the office's PDF as a copy of the NEW form. As AR-10 happened:
// the PO details had Arrow's name where Purposeful Design's address goes and "?" for the tax line, and the job had no
// Arrow lines yet, so the PO printed an item with blanks. Luke fixes the details on the office page, the job's lines
// arrive (as a dropped zip saves them), and Make it again gives r2: same number, the colours, the right details; the
// first version kept; the PDF portrait letter with the form's words. OLDDB=1: no Make it again, the PDF as before.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh
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
  const willie = makeClient(users.willie), luke = makeClient(users.luke);
  const s5 = (await q(`select s.* from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
                        where j.project_id = 'PROJ-00418' and w.is_current and s.sheet_number = 5`))[0];
  const prog5 = (await q("select id, qty_required from sheet_progress where sheet_id = $1 and department = 'metal'", [s5.id]))[0];
  const setup = [await willie.rpc("set_count", { p_progress: prog5.id, p_qty: prog5.qty_required }),
                 await willie.rpc("send_sheet", { p_sheet: s5.id, p_from: "metal", p_route: "arrow" }),
                 await luke.rpc("set_arrow_po_settings", { p: { issued_by: "Luke Hart", phone: "555-0100", email: "luke@example.com",
                   address: "Arrow Powdercoating", tax_line: "?", next_number: 10 } })];
  const item = (await q("select o.id from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = 'PROJ-00418' and o.waiting"))[0];
  setup.push(await willie.rpc("arrow_po_make", { p_client_id: "6f0c0a10-0000-4000-8000-000000000010", p_gone_on: null, p_items: [{ id: item.id }] }));
  const bad = setup.filter(r => r.error).map(r => r.error.message);
  ok("setup through the real functions: the send, the PO details as they were, AR-10 made before the job's lines", !bad.length, bad.join(" | "));

  const browser = await chromium.launch();
  const s = await session(browser, users.luke), p = s.p;
  p.on("dialog", d => d.accept());
  await p.goto(base); await p.waitForSelector('header.top [data-tab]', { timeout: 15000 });
  await p.click('[data-tab="arrow"]'); await p.waitForSelector("[data-popdf]", { timeout: 15000 });
  const txt = async () => p.evaluate(() => document.querySelector("#app").innerText.replace(/\s+/g, " "));
  let t = await txt();
  ok("The office lists AR-10, and the PO details label says whose address goes there", /AR-10/.test(t) && /Purposeful Design's name and address/.test(await p.evaluate(() => document.querySelector("#app").textContent)), t.slice(0, 300));

  if (OLDDB) {
    ok("Older database: no Make it again", !(await p.$("[data-poremake]")));
  } else {
    ok("…AR-10 says 1 line without colours, with Make it again beside PDF", /1 line without colours/.test(t) && !!(await p.$("[data-poremake]")));
    // Luke fixes the details on the page
    // the details panel folds away once filled in; open it and save, in one go (the page redraws)
    await p.evaluate(() => { document.querySelector("#poAddr").closest("details").open = true;
      document.querySelector("#poAddr").value = "Purposeful Design\n1 Test Street\nIndianapolis, IN";
      document.querySelector("#poTax").value = "* Purposeful Design is tax exempt (test)";
      document.querySelector("[data-posave]").click(); });
    await sleep(1500);
    // the job's lines arrive, as dropping its zip saves them
    const r = await luke.rpc("set_sheet_arrow", { p_work_order: s5.work_order_id, p_sheets: [{ sheet_number: 5, arrow: [
      { qty: 15, base: "JESS", description: "Pedestal Base, Round Disc, 3.5\" Post", pd_color: "Stardust Silver", arrow_color: "RAL 9006 White Aluminum" }] }] });
    ok("…the details saved from the page; the job's lines saved", !r.error && (await q("select address from arrow_po_settings"))[0].address.startsWith("Purposeful Design"), r.error && r.error.message);
    await p.click("[data-poremake]");
    await p.waitForFunction(() => /made again/.test(document.querySelector("#app").innerText), null, { timeout: 15000 }).catch(() => {});
    t = await txt();
    const po = (await q("select * from arrow_pos where name = 'AR-10'"))[0];
    ok("Make it again: the office says so; AR-10 is r2 with the colour, 15 JESS, the address and tax line now; filed next save as r2",
       /made again \(r2\)/.test(t) && /r2/.test(t) && !/without colours/.test(t) && po.revision === 2 && po.file_name === "AR-10(418).pdf".replace(".pdf", " r2.pdf")
       && po.lines[0].pd_color === "Stardust Silver" && po.lines[0].qty === 15 && po.header.address.startsWith("Purposeful Design") && po.onedrive_at === null,
       `${po.file_name} ${JSON.stringify(po.lines)} | ${t.slice(0, 200)}`);
    ok("…the first version kept: the blank line, Arrow's name and the ?", po.earlier.length === 1 && po.earlier[0].header.address === "Arrow Powdercoating"
       && po.earlier[0].header.tax_line === "?" && po.earlier[0].lines[0].pd_color === "" && po.earlier[0].file_name === "AR-10(418).pdf");
  }
  // the PDF: portrait letter, the form's words
  const [dl] = await Promise.all([p.waitForEvent("download", { timeout: 15000 }), p.click("[data-popdf]")]);
  const file = "/tmp/remake_test.pdf"; await dl.saveAs(file);
  const info = cp.execSync(`pdfinfo ${file}`).toString(), words = cp.execSync(`pdftotext -layout ${file} -`).toString();
  ok("The PDF is portrait letter with the NEW form's words: Purchase Order, the boxes, To and Ship To, the date row, the columns, the footer",
     /Page size:\s+612 x 792/.test(info) && ["Purchase Order", "PO Number:", "Date Issued:", "Contact e-mail:", "Ship To:", "Date Required", "How Shipped", "PO# / Job Number",
       "Base Description", "Arrow Color", "Unit Price", "Total", "*BLAST AND COAT ALL BASES*", "Authorized Signature:"].every(w => words.includes(w)), info.match(/Page size.*/)[0]);
  if (!OLDDB) ok("…with AR-10's colour and Purposeful Design's address, not Arrow's", /Stardust Silver/.test(words) && /1 Test Street/.test(words) && /tax exempt \(test\)/.test(words));
  ok("No page errors", !s.errs.length, s.errs.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
