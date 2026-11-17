// 17 Nov: live and test, opened in ONE browser, share nothing. Real Chromium, real service workers (sw.js), one profile,
// both sites under one name (127.0.0.1:port stands in for lukehart1228.github.io): /shop-floor/ is live, /shop-floor-test/ test.
// Two sandbox databases: sync (live: which_database() says live) and sync_test (a copy, marked test).
//   1. Today's live page (the live repo) leaves a Feedback note waiting with no signal; the new page, put at the same
//      address, finds it under the same names and sends it, once (a tablet after the release loses nothing).
//   2. Live, then test, then live, then test: each site's waiting note goes to its own database only; neither site
//      shows the other's waiting entries; test's names all end -test, live's are unchanged.
//   3. No connection: live, then test, then live open from their own saved copies; both copies are still there.
//   4. The second lock: a test page that reaches the live database stops, and a live page that reaches the test
//      database stops; the floor TV the same, from its snapshot.
// Seed first (the new database), then:
//   OUT=/tmp/allpages LIVEREPO=/home/claude/sf/repo PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1 \
//   TZ=America/Indiana/Indianapolis node test_site_split_chromium.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const L = require("./pgsupa");
const NEW = process.env.OUT || "/tmp/allpages", OLD = process.env.LIVEREPO || "/home/claude/sf/repo";
// test's two values as they'll look once a chat fills them in (the files carry PASTE- placeholders until then)
const TEST_URL = "https://abcdefghijtestprojec.supabase.co", TEST_KEY = "sb_publishable_TESTtestTESTtestTEST01";
const LIVE_URL = "https://fueyfxjxlicqekaqtydi.supabase.co";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };
const wait = (ms) => new Promise(r => setTimeout(r, ms));

// the test database: a copy of the seeded one, marked test (the fixture marks it directly; this_is_the_test_database()
// rightly refuses a database with counts in it)
function makeTestDb() {      // a second seeded copy, made the way fresh.sh makes sync (sync itself can't be copied: the scheduler keeps it open)
  const P = "psql -h /tmp/pg -p 5433 -U postgres -q -v ON_ERROR_STOP=1";
  const cp = require("child_process");
  cp.execSync(`${P} -d postgres -c "drop database if exists sync_test with (force)" -c "create database sync_test template ${process.env.TEMPLATE || "sync_base_new"}"`, { stdio: "pipe" });
  for (const f of ["seed.sql", "seed_fb.sql"]) cp.execSync(`${P} -d sync_test -f /home/claude/sf/base/${f}`, { stdio: "pipe" });
  cp.execSync(`${P} -d sync_test -c "select set_person('shawn@example.com','Shawn K','supervisor','{delivery}')"`, { stdio: "pipe" });
}
let T;   // pgsupa for sync_test, made from pgsupa.js itself
function testDbClient() {
  const src = fs.readFileSync(path.join(__dirname, "pgsupa.js"), "utf8").replace(/database: "sync"/g, 'database: "sync_test"');
  const f = path.join(__dirname, "pgsupa_sync_test.js"); fs.writeFileSync(f, src); return require(f);
}

// "GitHub Pages": both sites on one name. live serves OLD (today's repo) until the switch, then NEW; test serves NEW.
const site = { liveDir: OLD, swapLive: false, swapTest: false };
const fill = (s, which) => {
  s = s.replace(/(supabase\.js") integrity="[^"]+"/, "$1").replace(/PASTE-TEST-PROJECT-URL/g, TEST_URL).replace(/PASTE-TEST-PUBLISHABLE-KEY/g, TEST_KEY);
  // the wrong-database cases: a block filled in wrongly, so the address points at the other site's database
  if (which === "test" && site.swapTest) s = s.split(`url: "${TEST_URL}"`).join(`url: "${LIVE_URL}"`);
  if (which === "live" && site.swapLive) s = s.split(`url: "${LIVE_URL}"`).join(`url: "${TEST_URL}"`);
  return s;
};
const server = http.createServer((req, res) => {
  const u = req.url.split("?")[0], m = u.match(/^\/(shop-floor|shop-floor-test)(\/.*)?$/);
  if (!m) { res.writeHead(404); return res.end(); }
  const which = m[1] === "shop-floor" ? "live" : "test";
  let p = m[2] || "/"; if (p === "/") p = "/index.html";
  const file = path.join(which === "live" ? site.liveDir : NEW, p);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); return res.end(); }
  const type = file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : file.endsWith(".css") ? "text/css"
             : file.endsWith(".png") ? "image/png" : file.endsWith(".webmanifest") ? "application/manifest+json" : "application/octet-stream";
  let body = fs.readFileSync(file);
  if (/\.(html|js)$/.test(file)) body = Buffer.from(fill(body.toString(), which));
  res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-cache" });
  res.end(body);
});

// supabase-js stand-in: a client made with live's address talks to sync, test's to sync_test (as a signed-in Jim)
const FAKE = (user) => `window.supabase = { createClient: (url) => {
  const which = url.indexOf("${LIVE_URL}") === 0 ? "L" : "T";
  const call = (m) => window["__sb" + which](m);
  const session = { user: ${JSON.stringify(user)} };
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  window.__signedOut = window.__signedOut || [];
  return { auth: { getSession: async () => ({ data: { session } }),
                   signOut: async (o) => { window.__signedOut.push(which); return {}; },
                   onAuthStateChange: (cb) => { setTimeout(() => cb("INITIAL_SESSION", session), 0); return { data: { subscription: { unsubscribe() {} } } }; },
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: () => ({ download: async () => ({ data: null, error: { message: "not in this test" } }),
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const net = { L: false, T: false };            // a site's database "out of reach" (no signal) when true
async function context(browser, user, sw = true) {
  const cl = { L: L.makeClient(user), T: T.makeClient(user) };
  const asked = { L: [], T: [] };
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: sw ? "allow" : "block" });
  for (const w of ["L", "T"]) await ctx.exposeBinding("__sb" + w, async (_, m) => {
    if (net[w]) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") { asked[w].push(m.fn); return JSON.parse(JSON.stringify(await cl[w].rpc(m.fn, m.args || {}))); }
    let b = cl[w].from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  // the TV asks the database itself (no library): answer as no login from the database its address names
  await ctx.route(/supabase\.co\/rest\/v1\/rpc\/tv_snapshot/, async (r) => {
    const w = r.request().url().indexOf(LIVE_URL) === 0 ? "L" : "T";
    const args = JSON.parse(r.request().postData() || "{}");
    const out = await (w === "L" ? L : T).makeClient(null).rpc("tv_snapshot", args);
    r.fulfill({ status: 200, contentType: "application/json", headers: { "Access-Control-Allow-Origin": "*" }, body: JSON.stringify(out.data) });
  });
  await ctx.route(/supabase\.co\/rest\/v1\/rpc\/tv_photo/, r => r.fulfill({ status: 200, contentType: "application/json", headers: { "Access-Control-Allow-Origin": "*" }, body: "{\"ok\":false}" }));
  await ctx.route(/jsdelivr|unpkg|cdnjs/, r => /supabase-js@2\.45\.4/.test(r.request().url())
    ? r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }) : r.abort());
  return { ctx, asked };
}
const txt = (p, sel = "body") => p.evaluate((s) => (document.querySelector(s) || {}).innerText || "", sel).catch(() => "");
async function loaded(p) { for (let i = 0; i < 150; i++) { if (/jobs? (ready )?·|Nothing waiting|Stop: wrong database/.test(await txt(p, "body"))) return true; await wait(100); } return false; }
async function until(p, re, ms = 8000) { for (let i = 0; i < ms / 100; i++) { if (re.test(await txt(p))) return true; await wait(100); } return false; }
async function controlled(p) { for (let i = 0; i < 100; i++) { if (await p.evaluate(() => !!(navigator.serviceWorker && navigator.serviceWorker.controller)).catch(() => false)) return true; await wait(100); } return false; }
async function feedback(p, words) {
  await p.click("[data-feedback]"); await p.fill("[data-mfield=text]", words); await p.click("[data-savefeedback]"); await wait(900);
}
const notes = async (db, body) => Number((await db.admin.query("select count(*) n from feedback where body = $1", [body])).rows[0].n);
const keysOf = (p) => p.evaluate(async () => ({ ls: Object.keys(localStorage).sort(), caches: (await caches.keys()).sort(),
  idb: indexedDB.databases ? (await indexedDB.databases()).map(d => d.name).sort() : [] }));

(async () => {
  makeTestDb(); T = testDbClient();
  await T.admin.query("insert into database_site (site) values ('test') on conflict do nothing");
  ok("The two databases say what they are (sync: live, sync_test: test)",
     (await L.admin.query("select which_database() w")).rows[0].w === "live" && (await T.admin.query("select which_database() w")).rows[0].w === "test");
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const root = `http://127.0.0.1:${server.address().port}`, LIVE = root + "/shop-floor/index.html", TEST = root + "/shop-floor-test/index.html";
  const browser = await chromium.launch();
  const { ctx, asked } = await context(browser, L.users.jim);
  const errs = []; ctx.on("weberror", e => errs.push(e.error().message));

  // ---- 1. today's live page leaves a note waiting; the new page at the same address sends it ----
  let p = await ctx.newPage();
  await p.goto(LIVE); await loaded(p); await controlled(p);
  const oldVer = await p.evaluate(() => PAGE_VERSION);
  const devBefore = await p.evaluate(() => localStorage.getItem("sf_device"));
  net.L = true;
  await feedback(p, "Waiting since the old page");
  ok(`Today's live page (${oldVer}) keeps a note waiting with no signal`, /1 entry waiting to send/.test(await txt(p, "header")), await txt(p, "header"));
  site.liveDir = NEW; net.L = false;
  await p.reload(); await loaded(p); await wait(2500);
  const newVer = await p.evaluate(() => PAGE_VERSION);
  ok(`The new page at the same address (${newVer}) finds it and sends it, once`, newVer !== oldVer && await notes(L, "Waiting since the old page") === 1
     && /All saved/.test(await txt(p, "header")), `${newVer}; sent ${await notes(L, "Waiting since the old page")}; ${await txt(p, "header")}`);
  ok("…the same device id as before, so devices() shows one tablet, on the new page",
     (await p.evaluate(() => localStorage.getItem("sf_device"))) === devBefore
     && (await L.admin.query("select version from device_versions where device_id = $1 and page = 'index'", [JSON.parse(devBefore)])).rows.map(r => r.version).join() === newVer);
  ok("Live shows no TEST bar, and asked its database which it is once someone was signed in",
     !(await p.$("#sfTestBar")) && asked.L.includes("which_database") && !/^TEST/.test(await p.title()));

  // ---- 2. live, then test, then live, then test ----
  net.L = true; await feedback(p, "Live, waiting");
  ok("Live: a second note waits", /1 entry waiting to send/.test(await txt(p, "header")));
  const t = await ctx.newPage();
  await t.goto(TEST); await loaded(t); await controlled(t); await wait(1500);
  ok("Test opens in the same browser with its bar across the top: TEST, not the real floor",
     (await txt(t, "#sfTestBar")) === "TEST, not the real floor" && /^TEST · /.test(await t.title()) && asked.T.includes("which_database"), await txt(t, "#sfTestBar"));
  ok("Test doesn't see live's waiting note", !/waiting to send/.test(await txt(t, "header")) && /All saved/.test(await txt(t, "header")), await txt(t, "header"));
  net.T = true; await feedback(t, "Test, waiting");
  ok("Test: its own note waits", /1 entry waiting to send/.test(await txt(t, "header")));
  const k1 = await keysOf(t);
  const testLs = k1.ls.filter(k => /-test$/.test(k)), liveLs = k1.ls.filter(k => !/-test$/.test(k));
  ok("On the device, test's names all end -test and live's are as they were (" + testLs.length + " and " + liveLs.length + " keys)",
     testLs.length >= 3 && liveLs.every(k => /^sf_/.test(k)) && testLs.every(k => liveLs.includes(k.replace(/-test$/, "")) || /^sf_/.test(k))
     && k1.caches.includes("shop-floor-shell-v4") && k1.caches.includes("shop-floor-shell-v4-test"),
     JSON.stringify(k1));
  net.L = false; await p.reload(); await loaded(p); await wait(2500);
  ok("Live again: its note goes to the live database only, and it doesn't see test's",
     await notes(L, "Live, waiting") === 1 && await notes(T, "Live, waiting") === 0 && await notes(L, "Test, waiting") === 0 && /All saved/.test(await txt(p, "header")),
     `${await notes(L, "Live, waiting")}/${await notes(T, "Live, waiting")}/${await notes(L, "Test, waiting")}; ${await txt(p, "header")}`);
  net.T = false; await t.reload(); await loaded(t); await wait(2500);
  ok("Test again: its note goes to the test database only, once",
     await notes(T, "Test, waiting") === 1 && await notes(L, "Test, waiting") === 0 && await notes(T, "Waiting since the old page") === 0 && /All saved/.test(await txt(t, "header")));

  // ---- 3. no connection: live, then test, then live, each from its own saved copy ----
  await ctx.setOffline(true);
  const order = [["live", LIVE], ["test", TEST], ["live", LIVE]], seen = [];
  for (const [w, url] of order) {
    const q = await ctx.newPage(); let okLoad = true;
    await q.goto(url).catch(() => { okLoad = false; });
    const v = okLoad ? await q.evaluate(() => typeof PAGE_VERSION === "string" ? PAGE_VERSION : null).catch(() => null) : null;
    const bar = okLoad ? !!(await q.$("#sfTestBar")) : null;
    seen.push(`${w}: ${v || "didn't open"}${bar ? " with the TEST bar" : ""}`);
    ok(`No connection: ${w} opens from its own saved copy${w === "test" ? ", with its bar" : ", without the bar"}`, v === newVer && bar === (w === "test"), seen[seen.length - 1]);
    await q.close();
  }
  const k2 = await keysOf(p);
  ok("…and afterwards both saved copies are still there", k2.caches.includes("shop-floor-shell-v4") && k2.caches.includes("shop-floor-shell-v4-test"), k2.caches.join(", "));
  await ctx.setOffline(false);
  ok("No errors on any page", errs.length === 0, errs.join(" | "));
  await ctx.close();

  // ---- 4. the second lock ----
  const tvKey = async (db) => (await db.makeClient(db.users.luke).rpc("new_tv_link")).data.key;
  const kL = await tvKey(L), kT = await tvKey(T);
  site.swapTest = true;                                       // test's address filled in with live's database by mistake
  let c = await context(browser, L.users.jim, false); let q = await c.ctx.newPage();
  await q.goto(TEST); await until(q, /Stop: wrong database/);
  ok("A test page that reaches the live database stops, says so, and signs out of it",
     /Stop: wrong database/.test(await txt(q)) && /doesn't say it is the test database/.test(await txt(q)) && (await q.evaluate(() => window.__signedOut || [])).includes("L"), (await txt(q)).slice(0, 160));
  await q.goto(root + "/shop-floor-test/tv.html#k=" + kL); await until(q, /Stop: wrong database/);
  ok("…the TV the same, from its snapshot", /Stop: wrong database/.test(await txt(q)), (await txt(q)).slice(0, 120));
  await c.ctx.close(); site.swapTest = false; site.swapLive = true;  // live's address filled in with test's database by mistake
  c = await context(browser, L.users.jim, false); q = await c.ctx.newPage();
  await q.goto(LIVE); await until(q, /Stop: wrong database/);
  ok("A live page that reaches the test database stops and says so", /Stop: wrong database/.test(await txt(q)) && /is the test database/.test(await txt(q)), (await txt(q)).slice(0, 160));
  await q.goto(root + "/shop-floor/tv.html#k=" + kT); await until(q, /Stop: wrong database/);
  ok("…the TV the same", /Stop: wrong database/.test(await txt(q)), (await txt(q)).slice(0, 120));
  await c.ctx.close(); site.swapLive = false;
  c = await context(browser, L.users.jim, false); q = await c.ctx.newPage();
  await q.goto(root + "/shop-floor-test/tv.html#k=" + kT); await until(q, /Coming up|Stop/); await wait(1500);
  const tvTest = await txt(q);
  ok("The test TV on its own database shows the floor, with the TEST bar", !/Stop/.test(tvTest) && /TEST, not the real floor/.test(tvTest), tvTest.slice(0, 120));
  await q.goto(root + "/shop-floor/tv.html#k=" + kL); await until(q, /Coming up|Stop/); await wait(1500);
  ok("The live TV on its own database shows the floor, no bar", !/Stop|TEST, not/.test(await txt(q)));
  await c.ctx.close();

  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await L.admin.end(); await L.pool.end(); await T.admin.end(); await T.pool.end();
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  The test itself stopped: " + (e && e.stack || e)); process.exit(1); });
