// 5 Oct: the office app in Chromium. Deliveries, Upload, Inventory and Pace open inside the office (each its own page
// in a frame, its title row hidden), one sign-in, what each login sees, Feedback from inside a section, every page
// reporting its version, and the shared file. Pages talk to the test database through a bridge, as each login.
//   bash /home/claude/sf/base/fresh.sh /home/claude/sf/out/sql/feedback.sql /home/claude/sf/out/sql/install_log.sql
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_office_sections.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
const OFFICE_V = (require("fs").readFileSync(`${process.env.OUT || "/home/claude/sf/out"}/office.html`, "utf8").match(/const OFFICE_VERSION = "([^"]+)"/) || [])[1];   // 6 Oct: read from the page, not written in here
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

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
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("framenavigated", () => {}); p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs };
}
const frameOf = (p, file) => p.frames().find(f => f.url().includes(file + "?embed=1"));
const menu = async (p) => { await p.click("[data-menu]"); await p.waitForSelector(".menu"); return p.$$eval(".menu .mitem, .menu a", els => els.map(e => e.childNodes[0].textContent.trim())); };
const visible = (p, sel) => p.$eval(sel, el => !!(el.offsetWidth || el.offsetHeight)).catch(() => false);

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/office.html`;
  const browser = await chromium.launch();
  // a Julia: not a manager, schedules deliveries
  await admin.query("insert into auth.users (id, email) select gen_random_uuid(), 'julia@example.com' where not exists (select 1 from auth.users where email = 'julia@example.com')");
  await admin.query("select set_person('julia@example.com', 'Julia R', 'supervisor', '{finishing}')");
  await admin.query("update profiles set schedules_deliveries = true where id = (select id from auth.users where email = 'julia@example.com')");
  const julia = { id: (await admin.query("select id from auth.users where email = 'julia@example.com'")).rows[0].id, email: "julia@example.com" };

  // ---- Luke ----
  let s = await session(browser, users.luke), p = s.p;
  await p.goto(base); await p.waitForSelector("header.top [data-tab]", { timeout: 15000 }).catch(async (e) => { console.log("APP:", (await p.evaluate(() => document.body.innerText)).slice(0, 400)); console.log("ERRS:", s.errs.join(" | ")); throw e; });
  const items = await menu(p);
  ok("Luke's ☰ menu: the office's tabs, then Deliveries, Upload, Inventory, Pace inside the office; Tablet app, Setup, Feedback",
     JSON.stringify(items) === JSON.stringify(["Operations, Arrow, Photos", "Deliveries", "Upload a work order", "Inventory", "Pace", "Tablet app", "Setup", "Feedback", "Sign out"]), JSON.stringify(items));
  await p.click('.menu [data-section="deliveries"]');
  await p.waitForFunction(() => { const f = document.querySelector("#secs iframe"); return f && f.contentDocument && f.contentDocument.querySelector("#app") && f.contentDocument.querySelector("#app").textContent.length > 20; }, null, { timeout: 15000 });
  let fr = frameOf(p, "delivery.html");
  ok("Deliveries opens inside the office: the header says Deliveries, and the address says #deliveries",
     /Deliveries/.test(await p.$eval("header.top .place", e => e.textContent)) && p.url().endsWith("#deliveries") && await visible(p, "#secs"));
  ok("…its own title row is hidden; its schedule shows", await fr.evaluate(() => document.documentElement.classList.contains("sf-embedded") && getComputedStyle(document.querySelector("header")).display === "none")
     && /Schedule|delivery/i.test(await fr.evaluate(() => document.getElementById("app").innerText)));
  const geo = await p.evaluate(() => ({ hdr: Math.round(document.querySelector("header.top").getBoundingClientRect().bottom), top: Math.round(document.getElementById("secs").getBoundingClientRect().top), h: document.getElementById("secs").getBoundingClientRect().height }));
  ok("…and fills the screen right under the office's header", Math.abs(geo.hdr - geo.top) <= 1 && geo.h > 600, JSON.stringify(geo));
  await fr.evaluate(() => { window.__mark = "kept"; });
  await menu(p); await p.click('.menu [data-section="inventory"]');
  await p.waitForFunction(() => [...document.querySelectorAll("#secs iframe")].some(f => !f.hidden && /inventory/.test(f.src) && f.contentDocument && f.contentDocument.getElementById("app") && f.contentDocument.getElementById("app").textContent.length > 20), null, { timeout: 15000 });
  fr = frameOf(p, "inventory.html");
  ok("Inventory: its tabs stay, its title row hides", await fr.evaluate(() => getComputedStyle(document.querySelector("header .hrow")).display === "none" && !document.getElementById("tabs").hidden && getComputedStyle(document.getElementById("tabs")).display !== "none"),
     await fr.evaluate(() => document.getElementById("tabs").outerHTML.slice(0, 120)));
  // Feedback from inside Inventory
  await p.click("header.top [data-sffb]"); await p.waitForSelector("#sf-fb textarea");
  const where = await p.$eval("#sf-fb .sf-fb-sub b", e => e.textContent);
  await p.fill("#sf-fb textarea", "Inventory note from the office app"); await p.click("#sf-fb [data-sffbsend]");
  await p.waitForFunction(() => /Thanks/.test(document.getElementById("sf-fb") ? document.getElementById("sf-fb").innerText : ""), null, { timeout: 8000 });
  let f = (await admin.query("select * from feedback order by created_at desc limit 1")).rows[0];
  ok("Feedback from inside Inventory is kept as Inventory, with its tab and its version", f && f.page === "inventory" && /^Inventory › /.test(f.screen) && f.page_version === "2026-10-05.1" && f.person_name === "Luke H",
     JSON.stringify({ where, page: f && f.page, screen: f && f.screen, v: f && f.page_version }));
  await p.waitForTimeout(2700);
  await menu(p); await p.click('.menu [data-section="deliveries"]'); await p.waitForTimeout(300);
  fr = frameOf(p, "delivery.html");
  ok("Back to Deliveries: the same page, not reloaded (nothing typed there is lost)", await fr.evaluate(() => window.__mark) === "kept");
  await p.click('header.top [data-tab="arrow"]'); await p.waitForTimeout(800);
  ok("A tab (Arrow) leaves the section: the office screen shows, the section hides", /Arrow/.test(await p.$eval("main h1", e => e.textContent)) && !(await visible(p, "#secs")) && !p.url().includes("#"));
  ok("…and the page scrolls normally again", await p.evaluate(() => !document.documentElement.classList.contains("in-section")));
  await p.goto(base + "#pace"); await p.waitForFunction(() => [...document.querySelectorAll("#secs iframe")].some(f => !f.hidden && /pace/.test(f.src)), null, { timeout: 15000 });
  ok("A link to office.html#pace opens straight into Pace", /Pace/.test(await p.$eval("header.top .place", e => e.textContent)));
  await p.waitForTimeout(1500);
  const dev = await p.evaluate(() => JSON.parse(localStorage.getItem("sf_device")));
  const rep = (await admin.query("select page, version from device_versions where device_id = $1 order by page", [dev])).rows.map(r => r.page + " " + r.version);
  ok("Every page reports its version, as one device", ["delivery 2026-10-05.2", "inventory 2026-10-05.1", `office ${OFFICE_V}`, "pace 2026-10-05.1"].every(x => rep.includes(x)), rep.join(", "));
  await menu(p); await p.click('.menu [data-section="upload"]');
  await p.waitForFunction(() => [...document.querySelectorAll("#secs iframe")].some(f => !f.hidden && /upload/.test(f.src) && f.contentDocument && f.contentDocument.body && f.contentDocument.body.innerText.length > 20), null, { timeout: 15000 });
  fr = frameOf(p, "upload.html");
  ok("Upload opens inside the office, its header hidden", await fr.evaluate(() => getComputedStyle(document.querySelector("header")).display === "none"));
  ok("No errors on any page", s.errs.length === 0, s.errs.join(" | "));
  await menu(p); await p.click('.menu [data-signout]'); await p.waitForTimeout(500);
  ok("Sign out closes every section and shows the sign-in", await p.evaluate(() => document.querySelectorAll("#secs iframe").length === 0 && !!document.querySelector("form.card")));
  await s.ctx.close();

  // ---- Julia: Deliveries only ----
  s = await session(browser, julia); p = s.p;
  await p.goto(base);
  await p.waitForFunction(() => { const f = document.querySelector("#secs iframe"); return f && f.contentDocument && f.contentDocument.getElementById("app") && f.contentDocument.getElementById("app").textContent.length > 20; }, null, { timeout: 15000 });
  ok("Julia signs in to the office and lands in Deliveries", /Deliveries/.test(await p.$eval("header.top .place", e => e.textContent)));
  ok("…with no office tabs and no Find a job", !(await p.$("header.top [data-tab]")) && !(await p.$("[data-jobfind]")));
  const jitems = await menu(p);
  ok("…and her ☰ menu is just Deliveries and Sign out", JSON.stringify(jitems) === JSON.stringify(["Deliveries", "Sign out"]), JSON.stringify(jitems));
  await p.click("[data-menuclose]");
  fr = frameOf(p, "delivery.html");
  ok("Deliveries works for her as it did on its own page", /Schedule|delivery/i.test(await fr.evaluate(() => document.getElementById("app").innerText)) && !/isn't allowed|not allowed/i.test(await fr.evaluate(() => document.getElementById("app").innerText)));
  await p.click("header.top [data-sffb]"); await p.waitForSelector("#sf-fb textarea");
  await p.fill("#sf-fb textarea", "Julia's note"); await p.click("#sf-fb [data-sffbsend]");
  await p.waitForFunction(() => /Thanks/.test(document.getElementById("sf-fb") ? document.getElementById("sf-fb").innerText : ""), null, { timeout: 8000 });
  f = (await admin.query("select * from feedback order by created_at desc limit 1")).rows[0];
  ok("Her feedback is kept as Deliveries, from Julia", f.page === "delivery" && f.person_name === "Julia R" && /^Deliveries/.test(f.screen), JSON.stringify({ page: f.page, s: f.screen }));
  await p.goto(base + "#inventory"); await p.waitForTimeout(2500);
  ok("A link to #inventory still opens Deliveries for her", /Deliveries/.test(await p.$eval("header.top .place", e => e.textContent)) && !frameOf(p, "inventory.html"));
  ok("No errors on her pages", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  // ---- a supervisor ----
  s = await session(browser, users.mike); p = s.p;
  await p.goto(base); await p.waitForSelector("form.card", { timeout: 15000 });
  ok("A supervisor is turned away with a plain message", /Mike B is a supervisor login\. The office is for managers and whoever schedules deliveries/.test(await p.$eval("form.card", e => e.innerText)) && !(await p.$("#secs iframe")));
  await s.ctx.close();

  // ---- each section opened on its own still works (as before) ----
  for (const [file, word] of [["delivery.html", "Deliveries"], ["inventory.html", "Inventory"], ["pace.html", "Pace"], ["upload.html", "upload"]]) {
    s = await session(browser, users.luke); p = s.p;
    await p.goto(base.replace("office.html", file)); await p.waitForTimeout(2500);
    ok(`${file} opened on its own: its header shows, with its Feedback button`, await visible(p, "header") && !!(await p.$("header [data-sffb]")) && new RegExp(word, "i").test(await p.$eval("header", e => e.innerText)) && s.errs.length === 0, s.errs.join(" | "));
    await s.ctx.close();
  }

  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
