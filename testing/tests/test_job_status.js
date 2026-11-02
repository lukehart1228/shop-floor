// 28 Oct: Job status (status.html) in Chromium, through the real test database as each login.
// Mike (a supervisor) finds a job by number and reads its sentence, departments, done-by dates and sheet grid;
// Sally (a look-up login, made here) gets the same job with no done-by dates; a login with no profile is turned
// away; a #PROJ link opens the job; Luke's office menu has Job status and opens it inside the office.
// OLDDB=1 (no job_status.sql): the page says the database part isn't there yet. Screenshots with SHOTS=.
//   bash /home/claude/sf/base/fresh.sh ; psql … -f out/sql/job_status.sql
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_job_status.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo", OLD = !!process.env.OLDDB, SHOTS = process.env.SHOTS;
const PAGE_V = (fs.readFileSync(path.join(OUT, "status.html"), "utf8").match(/var PAGE_VERSION = "([^"]+)"/) || [])[1];
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const SALLY = { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", email: "sally.sales@example.com" };
const GHOST = { id: "cccccccc-cccc-cccc-cccc-cccccccccccc", email: "homag.stand-in@example.com" };

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session: localStorage.getItem("fake_signed_out") ? null : session } }),
                   signOut: async () => { localStorage.setItem("fake_signed_out", "1"); return {}; }, onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "Invalid login credentials" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }) };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/status.html";
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".css") ? "text/css" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});
async function session(browser, user, vp = { width: 1100, height: 900 }) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: vp, serviceWorkers: "block" });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs };
}
const text = (p) => p.$eval("#app", el => el.innerText).catch(() => "");
const shot = async (p, name) => { if (SHOTS) { fs.mkdirSync(SHOTS, { recursive: true }); await p.screenshot({ path: path.join(SHOTS, name + ".png"), fullPage: true }); } };

(async () => {
  await new Promise(r => server.listen(0, r)); const BASE = `http://127.0.0.1:${server.address().port}`;
  const job = (await admin.query(`select j.id, j.project_id from jobs j join work_orders w on w.job_id = j.id and w.is_current
                                   where not j.is_test order by j.project_id limit 1`)).rows[0];
  const num = job.project_id.replace(/\D/g, "").replace(/^0+/, "");
  await admin.query(`insert into auth.users (id, email) values ($1, $2), ($3, $4) on conflict do nothing`, [SALLY.id, SALLY.email, GHOST.id, GHOST.email]);
  await admin.query(`insert into profiles (id, full_name, role, departments) values ($1, 'Sally (sales)', 'supervisor', '{}') on conflict (id) do nothing`, [SALLY.id]);
  if (!OLD) await admin.query(`select set_look_up($1)`, [SALLY.email]);
  const browser = await chromium.launch();

  if (OLD) {
    const { p, errs, ctx } = await session(browser, users.mike);
    await p.goto(`${BASE}/status.html`); await p.fill("#q", num); await p.waitForTimeout(1200);
    ok("On a database without job_status.sql the page says that part isn't set up yet", /isn't set up in the database yet/.test(await text(p)), (await text(p)).slice(0, 120));
    ok("…and nothing breaks", errs.length === 0, errs.join(" | "));
    await ctx.close(); await browser.close(); server.close(); await admin.end();
    console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
  }

  // ---- Mike: search by number, open, read ---------------------------------------------------------------
  { const { p, errs, ctx } = await session(browser, users.mike);
    await p.goto(`${BASE}/status.html`); await p.waitForSelector("#q");
    ok("Signed in, it opens to just the search box", (await p.$$("#q")).length === 1 && !(await p.$(".hit")));
    await p.fill("#q", num); await p.waitForSelector(".hit", { timeout: 5000 }).catch(() => {});
    const hits = await p.$$eval(".hit", els => els.map(e => e.innerText.replace(/\s+/g, " ")));
    ok(`Typing ${num} finds ${job.project_id}, with a few words of status beside it`, hits.some(h => h.includes(job.project_id)), hits.join(" / ").slice(0, 160));
    await p.press("#q", "Enter"); await p.waitForSelector(".say", { timeout: 5000 }).catch(() => {});
    const say = await p.$eval(".say p", el => el.innerText).catch(() => "");
    ok("Enter opens the job, and it stays open (doesn't bounce back to the search)", !!say && !(await p.$("#q")), say);
    const rows = await p.$$eval(".drow", els => els.map(e => e.innerText.replace(/\s+/g, " ")));
    const dbn = (await admin.query(`select count(distinct sp.department)::int n from sheet_progress sp join sheets s on s.id = sp.sheet_id
                                    join work_orders w on w.id = s.work_order_id and w.is_current where w.job_id = $1`, [job.id])).rows[0].n;
    ok("One row per department the job goes through", rows.length === dbn, `${rows.length} rows, ${dbn} departments`);
    ok("Mike sees done-by dates on the departments still working", rows.some(r => /Done by [A-Z][a-z]{2} \d+/.test(r)), rows.join(" / ").slice(0, 200));
    ok("The facts strip shows Phase, Delivery and Trip", /PHASE[\s\S]*DELIVERY[\s\S]*TRIP/i.test(await p.$eval(".facts", el => el.innerText).catch(() => "")));
    await p.click("details.later summary"); const cells = await p.$$eval(".grid td", els => els.length);
    ok("Sheet by sheet unfolds to the grid", cells > 0, `${cells} cells`);
    ok("The address now carries the job (#PROJ…), so the link can be shared", (await p.evaluate(() => location.hash)) === "#" + job.project_id);
    const banned = await p.$eval("#app", el => /species|thickness|glue|finish spec|floor note/i.test(el.innerText));
    ok("No work order content on the page (sheet number and item code only)", !banned);
    await shot(p, "status-mike-job");
    await p.click("[data-back]"); await p.waitForSelector("#q");
    ok("← Search goes back to the search with the results kept", (await p.$$(".hit")).length > 0);
    const dev = (await admin.query(`select version from device_versions where page = 'status' order by last_seen desc limit 1`).catch(() => ({ rows: [] }))).rows[0];
    ok("The page reports its version for devices()", dev && dev.version === PAGE_V, dev ? dev.version : "no report");
    ok("No errors in the page", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  // ---- Sally (look-up): same job, no done-by dates; the #link opens straight onto it ------------------------
  { const { p, errs, ctx } = await session(browser, SALLY, { width: 390, height: 844 });
    await p.goto(`${BASE}/status.html#${job.project_id}`); await p.waitForSelector(".say", { timeout: 5000 }).catch(() => {});
    const all = await text(p);
    ok("A #PROJ link opens the job directly", (await p.$(".say")) && all.includes(job.project_id), all.slice(0, 80));
    ok("Sally (look-up login) sees the same departments with no done-by dates", (await p.$$(".drow")).length > 0 && !/Done by|past its done-by|days past/.test(all), all.replace(/\s+/g, " ").slice(0, 200));
    await shot(p, "status-sally-phone");
    ok("No errors in the page", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  // ---- a login with no profile (the machines) ------------------------------------------------------------
  { const { p, errs, ctx } = await session(browser, GHOST);
    await p.goto(`${BASE}/status.html`); await p.waitForTimeout(800);
    ok("A login with no profile is told it can't look up jobs", /can't look up jobs/.test(await text(p)), (await text(p)).slice(0, 100));
    await ctx.close(); }

  // ---- Luke: the office menu has Job status, and it opens inside the office --------------------------------
  { const { p, errs, ctx } = await session(browser, users.luke, { width: 1366, height: 860 });
    await p.goto(`${BASE}/office.html`); await p.waitForSelector("[data-menu]", { timeout: 8000 });
    await p.click("[data-menu]"); await p.waitForSelector(".menu");
    // each item's own label (its first text), not innerText: the office re-draws as its data arrives, and an item caught
    // mid-redraw has no layout, so its label and note ran together and the check failed at random (31 Oct)
    const items = await p.$$eval(".menu .mitem, .menu a", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
    ok("Luke's office ☰ menu lists Job status", items.includes("Job status"), items.join(", "));
    await p.click(".menu >> text=Job status"); await p.waitForTimeout(1500);
    const fr = p.frames().find(f => f.url().includes("status.html"));
    const hdr = fr ? await fr.$eval("header .hrow", el => getComputedStyle(el).display).catch(() => "?") : "no frame";
    ok("It opens inside the office, with the page's own header hidden", !!fr && hdr === "none", `frame ${!!fr}, header ${hdr}`);
    ok("No errors in the office", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  await browser.close(); server.close(); await admin.end();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
