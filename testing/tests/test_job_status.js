// 28 Oct: Job status (status.html) in Chromium, through the real test database as each login.
// Mike (a supervisor) finds a job by number and reads its sentence, departments, done-by dates and sheet grid;
// Sally (a look-up login, made here) gets the same job with no done-by dates; a login with no profile is turned
// away; a #PROJ link opens the job. In the office, Jobs replaced the Job status tab (11 Nov).
// 4 Nov: each job's Items list and an item's page (its work order page, open issue, Arrow, ‹ ›, #PROJ….n), for Mike;
// Sally gets the page but no issue, done-by or 3D; Luke gets the 3D panel where the database gives him a design.
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
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (b) => ({ createSignedUrl: async (pth) => { window.__signed = (window.__signed || []).concat([b + "/" + pth]);
      return { data: { signedUrl: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=" }, error: null }; } }) } };
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
async function session(browser, user, vp = { width: 1100, height: 900 }, over = null) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: vp, serviceWorkers: "block" });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (over) { const o = over(m); if (o) return o; }
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
  // 4 Nov: the job's sheets get page images, sheet 1 an open issue, sheet 2 an Arrow item
  await admin.query(`update sheets s set png_path = $2 || '/page-' || s.sheet_number || '.png', item_code = coalesce(s.item_code, 'IT-' || s.sheet_number)
                       from work_orders w where w.id = s.work_order_id and w.is_current and w.job_id = $1`, [job.id, job.project_id]);
  const sh = (await admin.query(`select s.sheet_number n, s.item_code code from sheets s join work_orders w on w.id = s.work_order_id and w.is_current
                                  where w.job_id = $1 order by s.sheet_number`, [job.id])).rows;
  if (!OLD) {
    await admin.query(`insert into problems (job_id, sheet_number, department, body, work_stopped, status, is_test)
                       values ($1, $2, 'sanding', 'Edge chipped on two tops', true, 'open', false)`, [job.id, sh[0].n]);
    await admin.query(`insert into outside_jobs (job_id, sheet_numbers, description, vendor, service, department, sent_on, gone_at, is_test)
                       values ($1, $2, 'bases', 'Arrow', 'powdercoat', 'metal', current_date - 5, now() - interval '5 days', false)`, [job.id, [sh[1].n]]);
  }

  if (OLD) {     // 4 Nov: the old database is today's live one, without job_items.sql (no item fields yet)
    const { p, errs, ctx } = await session(browser, users.mike);
    await p.goto(`${BASE}/status.html#${job.project_id}`); await p.waitForSelector(".irow", { timeout: 6000 }).catch(() => {});
    ok("On today's database the job and its Items list still show", (await p.$$(".drow")).length > 0 && (await p.$$(".irow")).length === sh.length);
    await p.click('[data-item="0"]').catch(() => {}); await p.waitForSelector("#item .say", { timeout: 4000 }).catch(() => {});
    const it = await p.$eval("#item", el => el.innerText).catch(() => "");
    ok("An item's page opens, saying its work order page waits for job_items.sql (not that it was never uploaded)", /once the database has job_items.sql \(4 Nov\)/.test(it), it.replace(/\s+/g, " ").slice(0, 160));
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


  // ---- Mike: the Items list and an item's page (4 Nov) -----------------------------------------------------
  { const { p, errs, ctx } = await session(browser, users.mike);
    await p.goto(`${BASE}/status.html#${job.project_id}`); await p.waitForSelector(".irow", { timeout: 6000 }).catch(() => {});
    const rows = await p.$$eval(".irow", els => els.map(e => e.innerText.replace(/\s+/g, " ")));
    ok("The job lists its items, one row per sheet, each with a square per department", rows.length === sh.length && (await p.$$(".irow .dot")).length > 0, rows.join(" / ").slice(0, 200));
    await p.click('[data-item="0"]'); await p.waitForSelector("#item .say", { timeout: 5000 }).catch(() => {});
    const say = await p.$eval("#item .say p", el => el.innerText).catch(() => "");
    ok(`Tapping sheet ${sh[0].n} opens its own page and sentence`, new RegExp(`Sheet ${sh[0].n}`).test(await p.$eval("#item h1", el => el.innerText).catch(() => "")) && !!say, say);
    await p.waitForSelector("#item .page img", { timeout: 5000 }).catch(() => {});
    const signed = await p.evaluate(() => window.__signed || []);
    ok("Its work order page shows, from the work-orders bucket", (await p.$$("#item .page img")).length === 1 && signed.includes(`work-orders/${job.project_id}/page-${sh[0].n}.png`), signed.join(", "));
    const txt = await p.$eval("#item", el => el.innerText).catch(() => "");
    ok("Mike sees the sheet's open issue, in the sentence and on its own line", /has an open issue \(work stopped\)/.test(say) && /Open issue[\s\S]*Edge chipped/.test(txt), txt.replace(/\s+/g, " ").slice(0, 220));
    ok("…and done-by dates on its departments still working", /Done by [A-Z][a-z]{2} \d+/.test(txt));
    await p.click("[data-big]"); ok("Tapping the page makes it bigger", (await p.$$("#item .page.big")).length === 1);
    await p.click('.nav [data-item="1"]'); await p.waitForTimeout(300);
    const t2 = await p.$eval("#item", el => el.innerText).catch(() => "");
    ok(`› goes to sheet ${sh[1].n}, which has an Arrow item out`, new RegExp(`Sheet ${sh[1].n}`).test(t2) && /Arrow\s*At Arrow since/.test(t2) && /at Arrow/.test(await p.$eval("#item .say p", el => el.innerText).catch(() => "")), t2.replace(/\s+/g, " ").slice(0, 220));
    ok("The address carries the item (#PROJ….n), so the link can be shared", (await p.evaluate(() => location.hash)) === `#${job.project_id}.${sh[1].n}`);
    await shot(p, "status-mike-item");
    await p.click("[data-tojob]"); await p.waitForSelector(".irow", { timeout: 3000 }).catch(() => {});
    ok("← PROJ goes back to the job", (await p.$$(".irow")).length === sh.length);
    ok("No errors in the page", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  // ---- Luke: a 3D design where the database gives him one -----------------------------------------------------
  { const over = (m) => m.kind === "from" && m.t === "item_designs"
      ? { data: [{ id: "d3-check", project_id: job.project_id, item: sh[0].code, status: "ready", up: "z", detail: "normal", view_path: "x", parts: 3, step_name: "check.step" }], error: null } : null;
    const { p, errs, ctx } = await session(browser, users.luke, { width: 1100, height: 900 }, over);
    await p.goto(`${BASE}/status.html#${job.project_id}.${sh[0].n}`); await p.waitForSelector("#item [data-d3]", { timeout: 6000 }).catch(() => {});
    ok("Where the database gives a 3D design for the item, its page has Open the 3D design", (await p.$$("#item [data-d3]")).length === 1);
    await p.click("#item [data-d3]").catch(() => {}); await p.waitForSelector(".d3ovl", { timeout: 3000 }).catch(() => {});
    ok("It opens the 3D panel, as on the office job page", (await p.$$(".d3ovl")).length === 1);
    await p.click("[data-d3close]").catch(() => {}); await p.waitForTimeout(200);
    ok("Close shuts it, back on the item", (await p.$$(".d3ovl")).length === 0 && (await p.$$("#item .say")).length === 1);
    ok("No errors in the page", errs.filter(e => !/viewer|three|3D|Failed to fetch|net::/i.test(e)).length === 0, errs.join(" | "));
    await ctx.close(); }

  // ---- Sally (look-up): same job, no done-by dates; the #link opens straight onto it ------------------------
  { const { p, errs, ctx } = await session(browser, SALLY, { width: 390, height: 844 });
    await p.goto(`${BASE}/status.html#${job.project_id}`); await p.waitForSelector(".say", { timeout: 5000 }).catch(() => {});
    const all = await text(p);
    ok("A #PROJ link opens the job directly", (await p.$(".say")) && all.includes(job.project_id), all.slice(0, 80));
    ok("Sally (look-up login) sees the same departments with no done-by dates", (await p.$$(".drow")).length > 0 && !/Done by|past its done-by|days past/.test(all), all.replace(/\s+/g, " ").slice(0, 200));
    await shot(p, "status-sally-phone");
    await p.goto(`${BASE}/status.html?again=1#${job.project_id}.${sh[0].n}`); await p.waitForSelector("#item .say", { timeout: 6000 }).catch(() => {});
    await p.waitForSelector("#item .page img", { timeout: 5000 }).catch(() => {});
    const it = await p.$eval("#item", el => el.innerText).catch(() => "");
    ok("A #PROJ….n link opens the item, and Sally sees its work order page", (await p.$$("#item .page img")).length === 1, it.replace(/\s+/g, " ").slice(0, 100));
    ok("…but not its open issue, done-by dates or a 3D design", !/open issue|Done by|3D design/i.test(it), it.replace(/\s+/g, " ").slice(0, 220));
    await shot(p, "status-sally-item-phone");
    ok("No errors in the page", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  // ---- a login with no profile (the machines) ------------------------------------------------------------
  { const { p, errs, ctx } = await session(browser, GHOST);
    await p.goto(`${BASE}/status.html`); await p.waitForTimeout(800);
    ok("A login with no profile is told it can't look up jobs", /can't look up jobs/.test(await text(p)), (await text(p)).slice(0, 100));
    await ctx.close(); }

  // ---- Luke: Jobs replaced the Job status tab (11 Nov, test_jobs_tab.js has the rest); status.html stays the sales page --------
  { const { p, errs, ctx } = await session(browser, users.luke, { width: 1366, height: 860 });
    await p.goto(`${BASE}/office.html`); await p.waitForSelector("nav.tabs .tab", { timeout: 8000 });
    const tabs = await p.$$eval("nav.tabs .tab", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
    ok("The office's tabs are Operations, Jobs, Purchasing, Deliveries (11 Nov)", JSON.stringify(tabs) === JSON.stringify(["Operations", "Jobs", "Purchasing", "Deliveries"]), tabs.join(", "));
    await p.click("[data-menu]"); await p.waitForSelector(".menu");
    // each item's own label (its first text), not innerText: the office re-draws as its data arrives (31 Oct)
    const items = await p.$$eval(".menu .mitem, .menu a", els => els.map(e => ((e.firstChild && e.firstChild.textContent) || e.textContent).trim()));
    ok("The ☰ menu doesn't list Job status (its first item, Operations, goes back to the tabs)", !items.includes("Job status") && items[0] === "Operations", items.join(", "));
    await p.click("[data-menuclose]").catch(() => {}); await p.waitForTimeout(200);
    await p.goto(`${BASE}/office.html?again=1#status`); await p.waitForSelector("main h1", { timeout: 8000 }); await p.waitForTimeout(1200);   // a new address, so it really loads again
    ok("An old #status link opens Jobs, not status.html inside the office", /Jobs/.test(await p.$eval("main h1", e => e.textContent)) && !p.frames().some(f => f.url().includes("status.html")));
    await p.click('nav.tabs [data-tab="tasks"]'); await p.waitForTimeout(800);
    const back = await p.evaluate(() => ({ inSec: document.documentElement.classList.contains("in-section"), h1: (document.querySelector("main h1") || {}).textContent || "" }));
    ok("Operations takes it back to the office's own screen", !back.inSec && /Operations/.test(back.h1), JSON.stringify(back));
    ok("No errors in the office", errs.length === 0, errs.join(" | "));
    await ctx.close(); }

  await browser.close(); server.close(); await admin.end();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
