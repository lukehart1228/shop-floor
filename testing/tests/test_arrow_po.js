// 1 Nov: Arrow POs on the tablet (arrow_pos.sql). Willie (Metal) ticks two waiting items on the Arrow tab, sends 7 of
// PROJ-00418's 15 pedestals and all of PROJ-00099's item, and taps Make the PO: one PO for the trip, AR-10(99,418-1),
// the 7 as a run of their own (8 still waiting), the PO printed in the NEW form's layout with the lines as the upload file
// spelled them (and never on the tablet's own screen); then the other 8 with no signal, sent once when it's back:
// AR-11(418-2). OLDDB=1: a database without arrow_pos.sql: Gone to Arrow as before, no ticks, no PO list.
//   fresh seed (new database); PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_arrow_po.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, admin, users } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html", OLDDB = process.env.OLDDB === "1";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const PAGES = new Map(), MISSING = new Set(), downloads = [];
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  const blob = (b64, type) => { const s = atob(b64), u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return new Blob([u], { type }); };
  return { auth: { getSession: async () => ({ data: { session: { user: ${JSON.stringify(user)} } } }), signOut: async () => ({}),
                   onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (bucket) => ({
      download: async (path) => { const r = await window.__st(bucket, path); return r.error ? { data: null, error: r.error } : { data: blob(r.b64, r.type), error: null }; },
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  const file = p === "/index.html" ? PAGE : path.join("/home/claude/sf/repo", p);
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (p === "/index.html") body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});

async function session(browser, user, viewport = { width: 1280, height: 800 }, ctx = null) {
  const client = makeClient(user); const st = { offline: false };
  ctx = ctx || await browser.newContext({ viewport, serviceWorkers: "block", hasTouch: true });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (st.offline) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") { const r = await client.rpc(m.fn, m.args || {}); return JSON.parse(JSON.stringify(r)); }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.exposeBinding("__st", async (_, bucket, p) => {
    downloads.push([p, st.offline]);
    if (st.offline) return { error: { message: "Failed to fetch" } };
    if (bucket !== "work-orders" || MISSING.has(p) || !PAGES.has(p)) return { error: { message: "Object not found", statusCode: "404" } };
    return { b64: PAGES.get(p), type: "image/png" };
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/jsdelivr|unpkg|cdnjs/, r => /supabase-js@2\.45\.4/.test(r.request().url())
    ? r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }) : r.abort());
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  return { ctx, p, st, errs };
}
const loaded = (p) => p.waitForFunction(() => document.querySelector(".subtabs") || document.querySelector(".head"), null, { timeout: 15000 });
const appText = (p) => p.evaluate(() => document.querySelector("#app").innerText.replace(/\s+/g, " "));
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/index.html`;
  const q = async (sql, args = []) => (await admin.query(sql, args)).rows;
  const willie = makeClient(users.willie), luke = makeClient(users.luke);
  const s5 = (await q(`select s.* from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
                        where j.project_id = 'PROJ-00418' and w.is_current and s.sheet_number = 5`))[0];
  const prog5 = (await q("select id, qty_required from sheet_progress where sheet_id = $1 and department = 'metal'", [s5.id]))[0];
  const setup = [await willie.rpc("set_count", { p_progress: prog5.id, p_qty: prog5.qty_required }),
                 await willie.rpc("send_sheet", { p_sheet: s5.id, p_from: "metal", p_route: "arrow" })];
  const j99 = (await q("select id from jobs where project_id = 'PROJ-00099'"))[0].id;
  await q(`insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
           values ($1, '{1}', 'powdercoat', 'metal', current_date, true, current_date, 'Willie', 'Willie')`, [j99]);
  if (!OLDDB) {
    setup.push(await luke.rpc("set_sheet_arrow", { p_work_order: s5.work_order_id, p_sheets: [{ sheet_number: 5, arrow: [
      { qty: 15, base: "JESS", description: "Pedestal Base, Round Disc, 3.5\" Post", pd_color: "Stardust Silver", arrow_color: "RAL 9006 White Aluminum" }] }] }));
    setup.push(await luke.rpc("set_arrow_po_settings", { p: { issued_by: "Luke Hart", phone: "555-0100", email: "luke@example.com",
      address: "Purposeful Design\n1 Test Street\nIndianapolis, IN", tax_line: "* Test tax-exempt line", next_number: 10 } }));
  }
  const bad = setup.filter(r => r.error).map(r => r.error.message);
  ok("setup through the real functions (the send, the lines, the PO details)", !bad.length, bad.join(" | "));

  const browser = await chromium.launch();
  const w = await session(browser, users.willie);
  await w.ctx.addInitScript(() => { window.print = () => { window.__printed = (window.__printed || 0) + 1; window.__printHtml = document.getElementById("printArea").innerHTML;
                                                           window.__printClass = document.getElementById("printArea").className; }; });
  await w.p.goto(base); await loaded(w.p);
  await w.p.click('[data-tab="arrow"]'); await w.p.waitForSelector("#app [data-argone], #app [data-arpick]", { timeout: 15000 });

  if (OLDDB) {
    ok("Older database: Gone to Arrow as before, no ticks, no PO list", !!(await w.p.$("[data-argone]")) && !(await w.p.$("[data-arpick]")) && !/Arrow POs this week/.test(await appText(w.p)));
    ok("No page errors", !w.errs.length, w.errs.join(" | "));
    console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
  }
  let t = await appText(w.p);
  ok("Waiting to go: Going to Arrow on each item, the count on PROJ-00418 (15 of 15 to go), no Gone to Arrow", (await w.p.$$("[data-arpick]")).length === 2
     && !(await w.p.$("[data-argone]")) && /15 of 15 to go/.test(t) && /Tick what's going/.test(t), t.slice(0, 300));
  const pick = async (pid) => { const id = (await q("select o.id from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = $1 and o.waiting", [pid]))[0].id;
    await w.p.click(`[data-arpick="${id}"]`); return id; };
  const id418 = await pick("PROJ-00418");
  ok("Ticking PROJ-00418 shows its line: Sheet 5, 15, of 15 left", /Sheet 5 − 15 \+ of 15 left|Sheet 5\s*−\s*15\s*\+\s*of 15 left/.test(await appText(w.p)), (await appText(w.p)).match(/Sheet 5.{0,40}/)?.[0]);
  for (let i = 0; i < 8; i++) await w.p.click(`[data-arqty="${id418}|5:1|-1"]`);
  await pick("PROJ-00099");
  t = await appText(w.p);
  ok("…down to 7; with PROJ-00099 ticked too, the button says Make the PO: 2 items going", /Sheet 5\s*−\s*7\s*\+\s*of 15 left/.test(t) && /Make the PO: 2 items going/.test(t));
  await w.p.click("[data-armake]"); await w.p.waitForSelector("[data-confirm]");
  ok("…it asks first, saying what's going", /PROJ-00418 #?5? ?\(7\)|PROJ-00418.*\(7\)/.test(await appText(w.p)) || /\(7\)/.test(await w.p.innerText(".mdl, body")));
  await w.p.click("[data-confirm]");
  await w.p.waitForFunction(() => /made just now/.test(document.querySelector("#app").innerText), null, { timeout: 15000 }).catch(() => {});
  const po = (await q("select * from arrow_pos order by made_at"))[0] || {};
  ok("One PO for the trip: AR-10(99,418-1).pdf, by Willie", po.name === "AR-10" && po.file_name === "AR-10(99,418-1).pdf" && /Willie/.test(po.made_by_name || ""), `${po.name} ${po.file_name}`);
  const rows = await q("select o.waiting, o.po_id is not null as on_po, o.arrow_qty, o.run_of is not null as run, j.project_id from outside_jobs o join jobs j on j.id = o.job_id where j.project_id in ('PROJ-00418','PROJ-00099') and o.voided_at is null order by j.project_id, o.run_of nulls first");
  ok("…the 7 went as a run of their own; 8 still waiting; PROJ-00099's item went whole",
     JSON.stringify(rows.map(r => [r.project_id, r.waiting, r.on_po, r.run, r.arrow_qty && r.arrow_qty[0] && r.arrow_qty[0].qty])) ===
     JSON.stringify([["PROJ-00099", false, true, false, null], ["PROJ-00418", true, false, false, 8], ["PROJ-00418", false, true, true, 7]]), JSON.stringify(rows));
  t = await appText(w.p);
  ok("The tab shows AR-10 made just now with Print the PO; At Arrow shows AR-10 · 7 of 15; 8 of 15 still to go",
     /Arrow POs this week/.test(t) && /AR-10/.test(t) && /made just now/.test(t) && /AR-10 · 7 of 15/.test(t) && /8 of 15 to go/.test(t), t.slice(0, 500));
  ok("…and no PO line's words on the tablet's own screen (base, description, colours)", !/JESS|Pedestal|Stardust|White Aluminum/.test(t));
  await w.p.click(`[data-arpoprint="${po.id}"]`);
  const pr = await w.p.evaluate(() => ({ n: window.__printed, html: window.__printHtml || "", cls: window.__printClass }));
  const prText = pr.html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  ok("Print the PO: the NEW form — Purchase Order, AR-10, Luke Hart and his details, To Arrow Powdercoating, Pickup, Delivered by PD, 99, 418-1",
     pr.n === 1 && pr.cls === "po" && /Purchase Order/.test(prText) && /PO Number: AR-10/.test(prText) && /Issued by: Luke Hart/.test(prText) && /555-0100/.test(prText)
     && /Arrow Powdercoating/.test(prText) && /Pickup/.test(prText) && /Delivered by PD/.test(prText) && /99, 418-1/.test(prText), prText.slice(0, 400));
  ok("…its lines: Stardust Silver first (7 JESS for PROJ-00418), then PROJ-00099's item with blanks for a pen; price columns empty; the footer",
     /7 JESS Pedestal Base, Round Disc, 3\.5" Post Stardust Silver RAL 9006 White Aluminum PROJ-00418/.test(prText)
     && /Item [^ ]+ \(sheet 1\) PROJ-00099/.test(prText) && prText.indexOf("JESS") < prText.indexOf("PROJ-00099")
     && /\*BLAST AND COAT ALL BASES\*/.test(prText) && /Test tax-exempt line/.test(prText) && /Authorized Signature: Luke Hart/.test(prText) && !/\$/.test(prText), prText.slice(400, 900));

  // the rest, with no signal: kept on the tablet, made once when the signal is back
  await w.p.click(`[data-arpick="${id418}"]`); await w.p.click("[data-armake]"); await w.p.waitForSelector("[data-confirm]");
  w.st.offline = true; await w.p.click("[data-confirm]"); await sleep(1500);
  ok("No signal: the PO waits on the tablet (nothing made yet)", (await q("select count(*)::int n from arrow_pos"))[0].n === 1);
  w.st.offline = false; await w.p.evaluate(() => window.dispatchEvent(new Event("online")));
  for (let i = 0; i < 30 && (await q("select count(*)::int n from arrow_pos"))[0].n < 2; i++) await sleep(300);
  await sleep(1500); await w.p.evaluate(() => window.dispatchEvent(new Event("online"))); await sleep(1500);
  const pos = await q("select name, file_name from arrow_pos order by po_number");
  ok("…when it's back, it's made exactly once: AR-11(418-2).pdf, and the item itself has gone", pos.length === 2 && pos[1].file_name === "AR-11(418-2).pdf"
     && (await q("select count(*)::int n from outside_jobs o join jobs j on j.id = o.job_id where j.project_id = 'PROJ-00418' and o.waiting"))[0].n === 0, JSON.stringify(pos));
  ok("No page errors", !w.errs.length, w.errs.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
