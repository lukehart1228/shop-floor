// 20 Oct: screenshots of the office's Operations home and a job page on the new pages, for a look.
// bash base/fresh.sh && OUT=/tmp/allpages PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node shots_office.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users } = require("./pgsupa");
const OUT = process.env.OUT || "/tmp/allpages", REPO = "/home/claude/sf/repo", SHOTS = process.env.SHOTS || "/tmp/shots"; fs.mkdirSync(SHOTS, { recursive: true });
const FONTS = "/home/claude/sf/node_modules/@fontsource";
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  return { auth: { getSession: async () => ({ data: { session: { user: ${JSON.stringify(user)} } } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }), signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: () => ({ download: async () => ({ data: null, error: { message: "no" } }), createSignedUrl: async () => ({ data: null, error: { message: "no" } }), upload: async () => ({ data: null, error: { message: "no" } }) }) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0]; if (p === "/" || p === "") p = "/office.html";
  if (p.startsWith("/fonts/")) { const f = path.join(FONTS, p.slice(7)); if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); } res.writeHead(200, { "Content-Type": f.endsWith(".css") ? "text/css" : "font/woff2" }); return res.end(fs.readFileSync(f)); }
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1")
    .replace(/<link[^>]*fonts\.googleapis[^>]*>/, `<link rel="stylesheet" href="/fonts/barlow/400.css"><link rel="stylesheet" href="/fonts/barlow/500.css"><link rel="stylesheet" href="/fonts/barlow/600.css"><link rel="stylesheet" href="/fonts/barlow/700.css"><link rel="stylesheet" href="/fonts/barlow-condensed/600.css"><link rel="stylesheet" href="/fonts/barlow-condensed/700.css">`));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".css") ? "text/css" : "text/html" }); res.end(body);
});
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r)); const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch(); const client = makeClient(users.luke);
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 860 }, serviceWorkers: "block" });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => { if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {}))); let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a); return JSON.parse(JSON.stringify(await b)); });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(users.luke), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = []; p.on("pageerror", e => errs.push(e.message));
  await p.goto(base + "/office.html"); try { await p.waitForFunction(() => /Needs you/i.test(document.getElementById("app").innerText), null, { timeout: 20000 }); } catch (e) { console.log("TEXT:", (await p.evaluate(() => document.getElementById("app").innerText)).slice(0, 400)); } await p.waitForTimeout(1200);
  await p.screenshot({ path: `${SHOTS}/office-home.png` });
  const ans = await p.$("[data-openanswer]"); if (ans) { await ans.click(); await p.waitForTimeout(500); await p.screenshot({ path: `${SHOTS}/office-home-answer.png` }); }
  await p.fill("[data-jobfind]", "00418"); await p.waitForTimeout(600); await p.keyboard.press("Enter"); await p.waitForTimeout(1500);
  await p.screenshot({ path: `${SHOTS}/office-job.png` });
  console.log("errors:", errs.length ? errs : "none"); await browser.close(); server.close();
})();
