// 11 Nov: Jobs (office.html 2026-11-11.2), in real Chromium through the real database as Luke. The Jobs tab replaced the Job
// status tab and the corner Find a job: a list of the jobs in production, soonest delivery first, with a search that finds any
// job; one job page (the sentence sales read, the facts with the trip, the sheet grid whose sheets open, Status, and the photos
// and trips at the foot); an item page (its sentence, departments, work order page, Previous/Next, back to the job). OneDrive
// no longer looks jobs up. A computer that remembers the Job status tab opens Jobs.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis OUT=/tmp/allpages node test_jobs_tab.js
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
  const browser = await chromium.launch();
  let s = await session(browser, users.luke), p = s.p;
  const main = async () => p.evaluate(() => document.querySelector("main").innerText.replace(/\s+/g, " "));
  await p.goto(base); await p.waitForSelector("header.top nav.tabs .tab", { timeout: 15000 });
  const tabs = await p.$$eval("nav.tabs .tab", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
  ok("The office's tabs: Operations, Jobs, Purchasing, Deliveries", JSON.stringify(tabs) === JSON.stringify(["Operations", "Jobs", "Purchasing", "Deliveries"]), tabs.join(", "));
  ok("…and no Find a job box in the corner", !(await p.$("header.top input")));
  await p.waitForSelector('main [data-tab="jobs"]', { timeout: 15000 });
  await p.click('main [data-tab="jobs"]'); await p.waitForSelector(".jrow", { timeout: 15000 });
  ok("Operations' Jobs in production tile opens Jobs", /Jobs/.test(await p.$eval("main h1", e => e.textContent)));
  const rows = await p.$$eval(".jrow .pid", els => els.map(e => e.textContent.trim()));
  const want = (await q(`select project_id from jobs where is_active order by is_test, delivery_date nulls last, project_id`)).map(r => (r.project_id || "").trim());
  ok("The list: every job in production, soonest delivery first, test jobs last", JSON.stringify(rows.map(r => r.replace(/^TEST\s*/, ""))) === JSON.stringify(want), `${rows.join(", ")} | ${want.join(", ")}`);
  const r418 = await p.$eval('.jrow:has(.pid:text("PROJ-00418"))', e => e.innerText.replace(/\s+/g, " ")).catch(() => "");
  ok("…each with where it stands and its delivery date (PROJ-00418: In Sanding)", /In Sanding/.test(r418) && /days left|late|due today/.test(r418), r418);
  await p.fill("[data-jobfind]", "oaks"); await p.waitForTimeout(400);
  let hits = await p.$$eval(".jrow .pid", els => els.map(e => e.textContent.trim()));
  ok("Typing filters as you go: “oaks” finds PROJ-00099 only", JSON.stringify(hits) === '["PROJ-00099"]', hits.join(", "));
  ok("…and the box keeps the cursor while the list redraws", await p.evaluate(() => document.activeElement && document.activeElement.matches("[data-jobfind]")));
  await p.fill("[data-jobfind]", "zzqq"); await p.waitForTimeout(300);
  ok("No match says so", /No job matches “zzqq”/.test(await main()));
  await p.fill("[data-jobfind]", "418"); await p.waitForTimeout(400); await p.press("[data-jobfind]", "Enter");
  await p.waitForSelector(".say", { timeout: 20000 }); await p.waitForTimeout(1500);
  let t = await main();
  const say = await p.$eval(".say p", e => e.textContent.trim());
  ok("Enter opens the first hit: PROJ-00418's page, with ← Jobs and Jobs still marked as the open tab", /PROJ-00418/.test(await p.$eval("main h1", e => e.textContent)) && /← Jobs/.test(t)
     && JSON.stringify(await p.$$eval("nav.tabs .tab", els => els.filter(e => e.getAttribute("aria-current") === "true").map(e => e.textContent.trim()))) === '["Jobs"]');
  ok("The job page: the one sentence first, then the facts with the trip, the sheet grid, Status, and Photos and deliveries",
     say.length > 10 && /Trip/i.test(t) && /Items, by department/i.test(t) && /Status/i.test(t) && !!(await p.$("#jobphotos")) && /Photos and deliveries/i.test(t), say);
  // the same sentence the sales logins read, from status.html as Luke
  const s2 = await session(browser, users.luke); const p2 = s2.p;
  await p2.goto(base.replace("office.html", "status.html#PROJ-00418")); await p2.waitForSelector(".say p", { timeout: 20000 }).catch(() => {});
  const say2 = await p2.$eval(".say p", e => e.textContent.trim()).catch(() => "(none)");
  ok("…the sentence is word for word what status.html says", say === say2, `${say} | ${say2}`); await s2.ctx.close();
  // an item
  const items = await p.$$("[data-item]");
  ok("Each sheet in the grid opens its item (9 sheets, 9 links)", items.length === 9, String(items.length));
  await items[0].click(); await p.waitForSelector("[data-itemback]", { timeout: 10000 });
  t = await main();
  ok("Sheet 1's page: its sentence, This item's trip, the work order page, Departments, and Sheet 2 ›", /Sheet 1/.test(await p.$eval("main h1", e => e.textContent)) && /This item's trip/i.test(t)
     && /Work order page/i.test(t) && /Departments/i.test(t) && /Sheet 2 ›/.test(t) && (await p.$$(".drow")).length >= 3, t.slice(0, 260));
  await p.click('[data-item="2"]'); await p.waitForTimeout(500);
  ok("Sheet 2 › moves to the next sheet", /Sheet 2/.test(await p.$eval("main h1", e => e.textContent)));
  await p.click("[data-itemback]"); await p.waitForSelector(".say", { timeout: 10000 });
  ok("← PROJ-00418 goes back to the job page", /Items, by department/i.test(await main()));
  await p.click("[data-jobback]"); await p.waitForSelector(".jrow", { timeout: 10000 });
  ok("← Jobs goes back to the list, still filtered to what was typed", (await p.inputValue("[data-jobfind]")) === "418" && (await p.$$(".jrow")).length >= 1);
  // OneDrive no longer looks jobs up
  await p.click("[data-menu]"); await p.click('.menu [data-tab="photos"]'); await p.waitForTimeout(1200);
  t = await main();
  ok("OneDrive has no Look up a job, and says where a job's photos are now", !(await p.$("#phJob")) && !/Look up a job/.test(t) && /open it on Jobs/.test(t));
  // a computer that remembers the Job status tab
  await p.evaluate(() => { localStorage.setItem("sfo_section", JSON.stringify("status")); localStorage.setItem("sfo_tab", JSON.stringify("tasks")); });
  await p.goto(base); await p.waitForSelector("main h1", { timeout: 15000 }); await p.waitForTimeout(1200);
  ok("A computer that remembers the Job status tab opens Jobs", /Jobs/.test(await p.$eval("main h1", e => e.textContent)) && !(await p.$("#secs iframe:not([hidden])")));
  ok("No page errors", !s.errs.length, s.errs.join(" | "));
  await s.ctx.close();
  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  crashed: " + e.message); process.exit(1); });
