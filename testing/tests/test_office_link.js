// 20 Oct: the way back from the tablet app to the office. Managers (Luke, David) get "Back to the office" at the end of
// the Department ▾ menu; it opens office.html in the same tab. The Test Supervisor (who also has the menu) and every
// supervisor get nothing new. With counts still waiting to send, it asks first; saying no stays put and keeps them.
// Run on a seeded database:
//   bash /home/claude/sf/base/fresh.sh && PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_office_link.js
// PAGE=/home/claude/sf/repo/index.html runs it on the live page, where it fails.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  return { auth: { getSession: async () => ({ data: { session: { user: ${JSON.stringify(user)} } } }), signOut: async () => ({}),
                   onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: () => ({ download: async () => ({ data: null, error: { message: "not in this test" } }),
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  if (p === "/office.html") { res.writeHead(200, { "Content-Type": "text/html" }); return res.end("<!doctype html><title>Office</title><h1 id=office>Office stand-in</h1>"); }
  const file = p === "/index.html" ? PAGE : path.join("/home/claude/sf/repo", p);
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (p === "/index.html") body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});

async function session(browser, user, viewport = { width: 1280, height: 800 }) {
  const client = makeClient(user); const st = { offline: false };
  const ctx = await browser.newContext({ viewport, serviceWorkers: "block" });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (st.offline) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") { const r = await client.rpc(m.fn, m.args || {}); return JSON.parse(JSON.stringify(r)); }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/jsdelivr|unpkg|cdnjs/, r => /supabase-js@2\.45\.4/.test(r.request().url())
    ? r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }) : r.abort());
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  return { ctx, p, st, errs };
}
const loaded = (p) => p.waitForFunction(() => document.querySelector("[data-deptmenu]") && /jobs? ·|Nothing waiting/.test(document.getElementById("app").innerText), null, { timeout: 15000 });
const has = (p, sel) => p.evaluate((s) => !!document.querySelector(s), sel);

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/index.html`;
  const browser = await chromium.launch();

  // 1. Luke: the menu ends with Back to the office, and it opens the office in this tab
  let s = await session(browser, users.luke);
  await s.p.goto(base); await loaded(s.p);
  ok("Luke: nothing new on the screen until the menu opens", !(await has(s.p, "[data-gooffice]")));
  await s.p.click("[data-deptmenu]");
  const items = await s.p.evaluate(() => [...document.querySelectorAll(".deptmenu .dmitem")].map(b => b.innerText.replace(/\s+/g, " ").trim()));
  ok("Luke: the Department menu ends with Back to the office, after Advance",
     items.length >= 3 && /^Back to the office/.test(items[items.length - 1]) && /^Advance/.test(items[items.length - 2]), JSON.stringify(items));
  await s.p.screenshot({ path: "/tmp/office_link_menu.png" });
  await Promise.all([s.p.waitForURL(/office\.html$/, { timeout: 5000 }).catch(() => {}), s.p.click("[data-gooffice]")]);
  ok("Luke: it opens office.html in the same tab, with no question when nothing is waiting", /\/shop-floor\/office\.html$/.test(s.p.url()), s.p.url());
  ok("Luke: no errors on the page", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  // 2. David, on a phone-sized screen: the same
  s = await session(browser, users.david, { width: 412, height: 915 });
  await s.p.goto(base); await loaded(s.p); await s.p.click("[data-deptmenu]");
  ok("David (phone size): Back to the office is in the menu", await has(s.p, ".deptmenu [data-gooffice]"));
  const box = await s.p.evaluate(() => { const r = document.querySelector("[data-gooffice]").getBoundingClientRect(); return { b: r.bottom, h: r.height, vh: innerHeight }; });
  ok("David (phone size): it's a full-size button on the screen (the menu scrolls if needed)", box.h >= 48, JSON.stringify(box));
  await s.ctx.close();

  // 3. Counts waiting to send: it asks first; No stays and keeps them; Yes goes, and they're still on the device
  s = await session(browser, users.luke);
  await s.p.goto(base); await loaded(s.p);
  s.st.offline = true;
  await s.p.evaluate(() => localStorage.setItem("sf_outbox", JSON.stringify({ "11111111-aaaa-bbbb-cccc-000000000001": { qty: 3, at: new Date().toISOString(), label: "PROJ-00418 sheet 1 · Milling: 3 of 4 done" } })));
  await s.p.reload(); await loaded(s.p);
  let dialogText = "";
  s.p.once("dialog", d => { dialogText = d.message(); d.dismiss(); });
  await s.p.click("[data-deptmenu]"); await s.p.click("[data-gooffice]"); await s.p.waitForTimeout(400);
  ok("With a count waiting, it asks first and says the count stays on this device", /haven't sent yet/.test(dialogText) && /stay on this device/.test(dialogText), dialogText);
  ok("Saying no stays in the tablet app", /index\.html$/.test(s.p.url()), s.p.url());
  s.p.once("dialog", d => d.accept());
  await Promise.all([s.p.waitForURL(/office\.html$/, { timeout: 5000 }).catch(() => {}), s.p.click("[data-gooffice]").catch(async () => { await s.p.click("[data-deptmenu]"); await s.p.click("[data-gooffice]"); })]);
  ok("Saying yes opens the office", /office\.html$/.test(s.p.url()), s.p.url());
  const kept = await s.p.evaluate(() => localStorage.getItem("sf_outbox"));
  ok("…and the waiting count is still on the device", /11111111-aaaa-bbbb-cccc-000000000001/.test(kept || ""), kept);
  await s.ctx.close();

  // 4. The Test Supervisor has the menu but not the link; supervisors have no menu and no link
  s = await session(browser, users.test);
  await s.p.goto(base);
  await s.p.waitForSelector("[data-deptmenu]", { timeout: 15000 }); await s.p.click("[data-deptmenu]");
  ok("Test Supervisor: the menu has no Back to the office", (await has(s.p, ".deptmenu")) && !(await has(s.p, "[data-gooffice]")));
  await s.ctx.close();
  for (const [who, u] of [["Mike", users.mike], ["Donnie", users.donnie], ["Eric", users.eric], ["Shawn", users.shawn]]) {
    s = await session(browser, u);
    await s.p.goto(base);
    await s.p.waitForFunction(() => document.querySelector("header.top"), null, { timeout: 15000 }); await s.p.waitForTimeout(1200);
    const found = await s.p.evaluate(() => [...document.querySelectorAll("[data-gooffice], [data-deptmenu], a[href*='office']")].map(e => e.outerHTML.slice(0, 80)));
    ok(`${who}: no Department menu and no way to the office`, found.length === 0, found.join(" | "));
    await s.ctx.close();
  }

  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
