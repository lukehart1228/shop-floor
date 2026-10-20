// 20 Oct (index.html 2026-10-20.3): the page checks for a newer copy of itself every 15 minutes (and when the app comes back to
// the front) and reloads only when it's safe: signed in, on a list, nothing open, half-typed or waiting to send, untouched
// for 2 minutes. A local server stands in for GitHub Pages and is switched to newer, older and broken copies mid-session;
// Playwright's clock jumps time forward. Seed first, then:
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1 TZ=America/Indiana/Indianapolis node test_auto_update.js
// PAGE=/home/claude/sf/repo/index.html runs it on the page before, where every "reloads" line fails.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const PAGE = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8").replace(/(supabase\.js") integrity="[^"]+"/, "$1");
const OWN = (PAGE.match(/const PAGE_VERSION = "([^"]+)"/) || [])[1];
const copy = (v) => PAGE.replace(/const PAGE_VERSION = "[^"]+";/, `const PAGE_VERSION = "${v}";`);
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };

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

// "GitHub": what a check (fetch) gets and what a page load (navigation) gets can differ, to model a CDN that's behind
const gh = { check: PAGE, nav: PAGE, navs: 0, checks: 0 };
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  if (p === "/index.html") {
    const nav = req.headers["sec-fetch-mode"] === "navigate";
    nav ? gh.navs++ : gh.checks++;
    if (gh.broken && !nav) { res.writeHead(404); return res.end("Not found"); }
    res.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "max-age=600" });
    return res.end(nav ? gh.nav : gh.check);
  }
  const file = path.join("/home/claude/sf/repo", p);
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : "application/octet-stream" });
  res.end(fs.readFileSync(file));
});
const serve = (v) => { gh.check = gh.nav = v ? copy(v) : PAGE; gh.broken = false; };

async function session(browser, user, sw = false) {
  const client = makeClient(user); const st = { offline: false };
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: sw ? "allow" : "block" });
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
  await p.clock.install(); await p.clock.resume();
  return { ctx, p, st, errs };
}
const wait = (ms) => new Promise(r => setTimeout(r, ms));
async function loaded(p) { for (let i = 0; i < 150; i++) { try { if (await p.evaluate(() => /jobs? (ready )?·|Nothing waiting/.test(document.getElementById("app").innerText))) return true; } catch (e) {} await wait(100); } return false; }
const version = (p) => p.evaluate(() => PAGE_VERSION).catch(() => null);
const mark = (p) => p.evaluate(() => { window.__same = true; });
const sameLoad = (p) => p.evaluate(() => window.__same === true).catch(() => false);
/** Jump the tablet's clock forward a minute at a time (each minute's timer runs once), letting its requests finish. */
async function minutes(p, n) { for (let i = 0; i < n; i++) { await p.clock.fastForward(61000); await wait(250); } }

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/index.html`;
  const browser = await chromium.launch();
  let s;

  // 1. Nothing new on GitHub: it asks, and stays put
  serve(null);
  s = await session(browser, users.mike); await s.p.goto(base); ok("Mike's tablet opens", await loaded(s.p)); await mark(s.p);
  await minutes(s.p, 20);
  ok("No new version: it asked GitHub and didn't reload", gh.checks >= 2 && await sameLoad(s.p), `checks ${gh.checks}`);
  ok("…it asks every 15 minutes, not every minute", gh.checks <= 3, `checks ${gh.checks} in 20 minutes`);
  // 2. A newer copy appears: it reloads into it once the tablet has been left alone
  serve("2026-10-20.9"); const navs0 = gh.navs;
  await minutes(s.p, 16); await loaded(s.p);
  ok("A newer version on GitHub: the idle tablet reloads by itself into it", !(await sameLoad(s.p)) && await version(s.p) === "2026-10-20.9" && gh.navs === navs0 + 1,
     `version ${await version(s.p)}, navigations ${gh.navs - navs0}`);
  const t1 = await s.p.evaluate(() => document.getElementById("app").innerText);
  ok("…and comes back on the same list, signed in", /jobs? (ready )?·|Nothing waiting/.test(t1), JSON.stringify(t1.slice(0, 200)));
  ok("No errors on the page", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  // 3. An older copy, or a broken answer, never reloads
  serve(null);
  s = await session(browser, users.mike); await s.p.goto(base); await loaded(s.p); await mark(s.p);
  gh.check = gh.nav = copy("2026-10-19.1");
  await minutes(s.p, 5);
  ok("An older version on GitHub: no reload", await sameLoad(s.p) && await version(s.p) === OWN, `same page ${await sameLoad(s.p)}, version ${await version(s.p)}, navigations ${gh.navs}`);
  gh.broken = true; await minutes(s.p, 16);
  ok("GitHub answering 404: no reload", await sameLoad(s.p));
  await s.ctx.close();

  // 4. Someone is using it: a sheet open, then touching the screen; it waits, then goes once left alone on the list
  serve(null);
  s = await session(browser, users.mike); await s.p.goto(base); await loaded(s.p);
  serve("2026-10-20.9");
  await s.p.click("[data-job]"); await wait(400); await s.p.click("[data-sheet]"); await wait(400); await mark(s.p);
  await minutes(s.p, 30);
  ok("A sheet left open for 30 minutes: no reload", await sameLoad(s.p) && await s.p.evaluate(() => !!document.querySelector("#page, .page")), `version ${await version(s.p)}`);
  await s.p.click("[data-back]"); await wait(300); await s.p.click("[data-back]").catch(() => {}); await wait(300);
  for (let i = 0; i < 4; i++) { await s.p.keyboard.press("Shift"); await minutes(s.p, 1); }
  ok("Back on the list but tapped every minute: no reload", await sameLoad(s.p));
  await minutes(s.p, 3); await loaded(s.p);
  ok("Left alone for 2 minutes on the list: reloads into the new version", await version(s.p) === "2026-10-20.9", `version ${await version(s.p)}`);
  await s.ctx.close();

  // 5. A count waiting to send: it waits until the count has gone, and the count is kept
  serve(null);
  s = await session(browser, users.mike); await s.p.goto(base); await loaded(s.p);
  serve("2026-10-20.9");
  await s.p.click("[data-job]"); await wait(400);
  const nSheets = await s.p.evaluate(() => document.querySelectorAll("[data-sheet]").length);
  for (let i = 0; i < nSheets; i++) {          // a sheet with room for one more
    await s.p.evaluate((k) => document.querySelectorAll("[data-sheet]")[k].click(), i); await wait(400);
    if (await s.p.$('[data-step="1"]:not([disabled])')) break;
    await s.p.click("[data-back]"); await wait(300);
  }
  s.st.offline = true;
  await s.p.click('[data-step="1"]'); await wait(400);
  await s.p.click("[data-back]"); await wait(300); await s.p.click("[data-back]").catch(() => {}); await wait(300); await mark(s.p);
  const queued = await s.p.evaluate(() => Object.keys(JSON.parse(localStorage.getItem("sf_outbox") || "{}")).length);
  await minutes(s.p, 20);
  ok("A count waiting to send (no signal to the database): no reload for 20 minutes", queued > 0 && await sameLoad(s.p), `queued ${queued}`);
  s.st.offline = false; await minutes(s.p, 5); await loaded(s.p);
  const left = await s.p.evaluate(() => Object.keys(JSON.parse(localStorage.getItem("sf_outbox") || "{}")).length);
  ok("Signal back: the count sends, then it reloads into the new version", await version(s.p) === "2026-10-20.9" && left === 0, `version ${await version(s.p)}, still waiting ${left}`);
  await s.ctx.close();

  // 6. GitHub's cache behind: the check sees the new copy but the reload gets the old one. It tries once per 30 minutes, no loop
  serve(null);
  s = await session(browser, users.mike); await s.p.goto(base); await loaded(s.p);
  gh.check = copy("2026-10-20.9"); gh.nav = PAGE; const n0 = gh.navs;
  await minutes(s.p, 4); await loaded(s.p);
  ok("Reload came back old: one reload", gh.navs === n0 + 1, `navigations ${gh.navs - n0}`);
  await minutes(s.p, 20);
  ok("…then no second try for 30 minutes (no reload loop)", gh.navs === n0 + 1, `navigations ${gh.navs - n0}`);
  gh.nav = copy("2026-10-20.9"); await minutes(s.p, 14); await loaded(s.p);
  ok("…after that it tries again and gets the new version", await version(s.p) === "2026-10-20.9", `version ${await version(s.p)}, navigations ${gh.navs - n0}`);
  await s.ctx.close();

  // 7. Shawn's phone, with the service worker as on the real phone: a trip open waits; on the Load-out list it reloads
  serve(null);
  s = await session(browser, users.shawn, true); await s.p.goto(base); await wait(1500); await s.p.reload(); await wait(1500);
  const swOn = await s.p.evaluate(() => !!navigator.serviceWorker.controller);
  ok("Shawn's phone: the service worker is running, as on the real phone", swOn);
  serve("2026-10-20.9"); await mark(s.p);
  await minutes(s.p, 18); await wait(1500);
  ok("Shawn on the Load-out list: reloads into the new version through the service worker", await version(s.p) === "2026-10-20.9", `version ${await version(s.p)}`);
  ok("No errors on the page", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  await browser.close(); server.close();
  console.log(`${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
