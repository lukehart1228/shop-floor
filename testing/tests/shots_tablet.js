// 20 Oct: screenshots of the tablet queue (and a job) on the new page, for a look, at tablet and phone sizes.
// bash base/fresh.sh && PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node shots_tablet.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
const OUT = process.env.SHOTS || "/tmp/shots"; fs.mkdirSync(OUT, { recursive: true });
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
    storage: { from: () => ({ download: async () => ({ data: null, error: { message: "no" } }), createSignedUrl: async () => ({ data: null, error: { message: "no" } }), upload: async () => ({ data: null, error: { message: "no" } }) }) } };
} };`;
const FONTS = "/home/claude/sf/node_modules/@fontsource";
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0]; if (p === "/" || p === "") p = "/index.html";
  if (p.startsWith("/fonts/")) { const f = path.join(FONTS, p.slice(7)); if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); } res.writeHead(200, { "Content-Type": f.endsWith(".css") ? "text/css" : "font/woff2" }); return res.end(fs.readFileSync(f)); }
  const file = p === "/index.html" ? PAGE : path.join("/home/claude/sf/repo", p);
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (p === "/index.html") body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1")
    .replace(/<link[^>]*fonts\.googleapis[^>]*>/, fs.existsSync(FONTS) ? `<link rel="stylesheet" href="/fonts/barlow/400.css"><link rel="stylesheet" href="/fonts/barlow/500.css"><link rel="stylesheet" href="/fonts/barlow/600.css"><link rel="stylesheet" href="/fonts/barlow/700.css"><link rel="stylesheet" href="/fonts/barlow-condensed/600.css"><link rel="stylesheet" href="/fonts/barlow-condensed/700.css">` : ""));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : "text/html" }); res.end(body);
});
async function session(browser, user, viewport) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport, serviceWorkers: "block" });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") { const r = await client.rpc(m.fn, m.args || {}); return JSON.parse(JSON.stringify(r)); }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a); return JSON.parse(JSON.stringify(await b)); });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/jsdelivr|unpkg|cdnjs/, r => /supabase-js@2\.45\.4/.test(r.request().url()) ? r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }) : r.abort());
  const p = await ctx.newPage(); const errs = []; p.on("pageerror", e => errs.push(e.message)); return { ctx, p, errs };
}
const loaded = (p) => p.waitForFunction(() => /jobs? ·|Nothing waiting|Nothing ready/.test(document.getElementById("app").innerText), null, { timeout: 20000 });
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r)); const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  for (const [who, name, vp] of [["mike", "mike-tablet", { width: 1024, height: 768 }], ["jim", "jim-tablet", { width: 1024, height: 768 }], ["mike", "mike-phone", { width: 390, height: 844 }]]) {
    const { ctx, p, errs } = await session(browser, users[who], vp);
    await p.goto(base + "/index.html"); await loaded(p); await p.waitForTimeout(800);
    await p.screenshot({ path: `${OUT}/${name}-queue.png` });
    const row = await p.$("button.qrow, button.job"); if (row) { await row.click(); await p.waitForTimeout(800); await p.screenshot({ path: `${OUT}/${name}-job.png` }); }
    console.log(name, "errors:", errs.length ? errs : "none"); await ctx.close();
  }
  await browser.close(); server.close();
})();
