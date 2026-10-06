// 5 Oct: the ticket drawn by the REAL pdf.js 3.11.174 in Chromium, at a phone's size, as Shawn, against the test database.
// pdf.js is served at its jsDelivr address from the npm package (byte-identical), with the page's integrity checks on.
// Then: a copy changed by one byte is refused; and with the service worker on, a trip opened on Wi-Fi still shows its
// ticket after the phone goes offline and the app is reopened.
// Run on a freshly seeded database (it schedules its own trip):
//   bash /home/claude/sf/base/fresh.sh && PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1 PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_pdf_chromium.js
// The PW_EXPERIMENTAL… switch routes the service worker's requests through the stand-ins; without it the no-signal part can't start.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const crypto = require("crypto");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = "/home/claude/sf/out", PJ = "/tmp/pj/package/legacy/build/";
let pass = 0, fail = 0;
// the sample files (made here, so the kit needs no fixture folder): a two-page ticket, a landscape plan, a JPEG
function makeFixtures(dir) {
  if (fs.existsSync(dir + "ticket.pdf") && fs.existsSync(dir + "plan.pdf") && fs.existsSync(dir + "site.jpg")) return;
  fs.mkdirSync(dir, { recursive: true });
  require("child_process").execSync(`python3 - <<'PY'
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas
from PIL import Image
d = "${dir}"
c = canvas.Canvas(d + "ticket.pdf", pagesize=letter)
for n in (1, 2):
    c.setFont("Helvetica-Bold", 28); c.drawString(72, 700, "SAMPLE DELIVERY TICKET")
    c.setFont("Helvetica", 16); c.drawString(72, 660, f"Test file for the in-app viewer - page {n} of 2")
    c.rect(72, 300, 468, 320); c.drawString(90, 590, "Customer: Sample Customer"); c.drawString(90, 560, "Received in good condition: ________________")
    c.showPage()
c.save()
c = canvas.Canvas(d + "plan.pdf", pagesize=(792, 612)); c.setFont("Helvetica-Bold", 30); c.drawString(72, 520, "SAMPLE SITE PLAN (landscape)"); c.circle(396, 280, 120); c.showPage(); c.save()
Image.new("RGB", (400, 300), (0, 180, 178)).save(d + "site.jpg", quality=80)
PY`, { shell: "/bin/bash" });
}
// pdf.js 3.11.174 from npm: the same bytes jsDelivr serves
if (!fs.existsSync("/tmp/pj/package/legacy/build/pdf.min.js"))
  require("child_process").execSync("rm -rf /tmp/pj && mkdir -p /tmp/pj && cd /tmp/pj && npm pack pdfjs-dist@3.11.174 -q && tar xzf pdfjs-dist-3.11.174.tgz", { shell: "/bin/bash", stdio: "ignore" });
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  return { auth: { getSession: async () => ({ data: { session: { user: ${JSON.stringify(user)} } } }), signOut: async () => ({}),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (b) => ({
      download: async (p) => { const r = await call({ kind: "download", b, p }); if (r.error) return r;
        const s = atob(r.b64), u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
        return { data: new Blob([u], { type: r.type }), error: null }; },
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  const f = path.join(OUT, p);
  const live = path.join("/home/claude/sf/repo", p);
  const file = fs.existsSync(f) ? f : fs.existsSync(live) ? live : null;
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith("index.html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));  // only supabase-js is a stand-in
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});

async function session(browser, base, opts = {}) {
  const client = makeClient(users.shawn); let offline = false;
  const ctx = await browser.newContext({ viewport: { width: 412, height: 915 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true,
                                         serviceWorkers: opts.sw ? "allow" : "block" });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (offline) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") { const r = await client.rpc(m.fn, m.args || {}); return JSON.parse(JSON.stringify(r)); }
    if (m.kind === "download") { const r = await client.storage.from(m.b).download(m.p); if (r.error) return r;
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), type: r.data.type }; }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  const fetched = [];
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/supabase-js@2\.45\.4/, r => r.fulfill({ body: FAKE(users.shawn), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  await ctx.route(/pdfjs-dist@3\.11\.174\/legacy\/build\/(pdf(\.worker)?\.min\.js)/, (r) => {
    const name = r.request().url().match(/(pdf(\.worker)?\.min\.js)/)[1]; fetched.push(name);
    if (offline) return r.abort("internetdisconnected");
    let body = fs.readFileSync(PJ + name);
    if (opts.tamper && name === "pdf.min.js") body = Buffer.concat([body, Buffer.from(" ")]);
    r.fulfill({ body, contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } });
  });
  const p = await ctx.newPage(); const msgs = [];
  p.on("console", m => msgs.push(m.text())); p.on("pageerror", e => msgs.push("PAGEERROR " + e.message));
  p.on("popup", () => msgs.push("POPUP"));
  return { ctx, p, msgs, fetched, setOffline: async (v) => { offline = v; await ctx.setOffline(v); } };
}
const app = (p) => p.evaluate(() => document.getElementById("app").innerText);
async function openTicket(p, pid) {
  await p.waitForFunction(() => /Load-out|Coming up|Delivery/i.test(document.getElementById("app").innerText), null, { timeout: 15000 });
  await p.waitForFunction((pid) => [...document.querySelectorAll("[data-loopen]")].some(b => b.textContent.includes(pid)), pid, { timeout: 15000 });
  await p.evaluate((pid) => [...document.querySelectorAll("[data-loopen]")].find(b => b.textContent.includes(pid)).click(), pid);
  await p.waitForSelector("[data-dlopen]", { timeout: 15000 });
}

(async () => {
  // a white glove delivery tomorrow with a two-page PDF ticket and a landscape PDF site plan (uploaded in this process)
  const luke = makeClient(users.luke), FX = "/tmp/sf_pdf_fixtures/"; makeFixtures(FX);
  const jid = (await admin.query("select id from jobs where project_id = 'PROJ-00418'")).rows[0].id;
  const cid = crypto.randomUUID(), when = new Date(Date.now() + 86400000); when.setHours(9, 0, 0, 0);
  let r = await luke.rpc("schedule_delivery", { p_job: jid, p_when: when.toISOString(), p_note: "Test trip", p_loadout: null, p_client_id: cid });
  if (r.error) throw new Error(r.error.message);
  for (const [file, kind, name] of [["ticket.pdf", "ticket", "Ticket.pdf"], ["plan.pdf", "site_file", "Floor plan.pdf"]]) {
    const id = crypto.randomUUID();
    const up = await luke.storage.from("deliveries").upload(`PROJ-00418/${cid}/${id}.pdf`, new Blob([fs.readFileSync(FX + file)], { type: "application/pdf" }), { contentType: "application/pdf", upsert: false });
    if (up.error) throw new Error(up.error.message);
    r = await luke.rpc("add_delivery_doc", { p_client_id: id, p_loadout: cid, p_kind: kind, p_file_name: name });
    if (r.error) throw new Error(r.error.message);
  }
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/index.html`;
  const browser = await chromium.launch();

  // 1. online: the real viewer draws both pages
  let s = await session(browser, base);
  await s.p.goto(base); await openTicket(s.p, "PROJ-00418");
  await s.p.waitForTimeout(1500);
  ok("Opening the delivery fetched both viewer files", s.fetched.includes("pdf.worker.min.js") && s.fetched.includes("pdf.min.js"), s.fetched.join(", "));
  await s.p.evaluate(() => [...document.querySelectorAll("[data-dlopen]")].find(b => b.textContent.trim() === "Delivery ticket").click());
  await s.p.waitForFunction(() => document.querySelectorAll("#lodoc img").length === 2 && [...document.querySelectorAll("#lodoc img")].every(i => i.complete && i.naturalWidth > 0), null, { timeout: 20000 }).catch(() => {});
  const pics = await s.p.evaluate(() => [...document.querySelectorAll("#lodoc img")].map(i => ({ w: i.naturalWidth, h: i.naturalHeight, alt: i.alt })));
  ok("The real pdf.js drew both pages, about 1600 pixels wide", pics.length === 2 && pics.every(x => x.w >= 1500 && x.w <= 1700 && x.h > x.w), JSON.stringify(pics));
  // the drawing has the ticket's words on it: dark pixels where the heading is, white elsewhere
  const ink = await s.p.evaluate(() => { const i = document.querySelector("#lodoc img"); const c = document.createElement("canvas"); c.width = i.naturalWidth; c.height = i.naturalHeight;
    const g = c.getContext("2d"); g.drawImage(i, 0, 0); const d = g.getImageData(0, 0, c.width, Math.round(c.height * 0.15)).data; let dark = 0;
    for (let k = 0; k < d.length; k += 4) if (d[k] < 100) dark++; const corner = g.getImageData(5, c.height - 10, 1, 1).data; return { dark, corner: [...corner] }; });
  ok("The page carries the ticket's printing on a white page", ink.dark > 2000 && ink.corner[0] === 255, JSON.stringify(ink));
  ok("No pop-up, and no errors on the page", !s.msgs.includes("POPUP") && !s.msgs.some(m => /PAGEERROR|integrity/i.test(m)), s.msgs.filter(m => /PAGEERROR|integrity|POPUP/.test(m)).join(" | "));
  ok("The page is still the app (no navigation away)", s.p.url() === base && /Delivery ticket/.test(await app(s.p)));
  await s.p.screenshot({ path: "/tmp/ticket_phone.png" });
  await s.p.evaluate(() => scrollTo(0, 99999)); await s.p.waitForTimeout(200); await s.p.screenshot({ path: "/tmp/ticket_phone_end.png" });
  // the landscape site plan
  await s.p.click("[data-lowoback]"); await s.p.waitForSelector("[data-dlopen]");
  await s.p.evaluate(() => [...document.querySelectorAll("[data-dlopen]")].find(b => b.textContent.trim() === "Floor plan.pdf").click());
  await s.p.waitForFunction(() => { const i = document.querySelector("#lodoc img"); return i && i.complete && i.naturalWidth > 0; }, null, { timeout: 20000 }).catch(() => {});
  const plan = await s.p.evaluate(() => [...document.querySelectorAll("#lodoc img")].map(i => [i.naturalWidth, i.naturalHeight]));
  ok("A landscape PDF draws landscape", plan.length === 1 && plan[0][0] > plan[0][1], JSON.stringify(plan));
  await s.ctx.close();

  // 2. a viewer file changed by one byte is refused, and the page says so instead of breaking
  s = await session(browser, base, { tamper: true });
  await s.p.goto(base); await openTicket(s.p, "PROJ-00418");
  await s.p.waitForTimeout(800);
  await s.p.evaluate(() => [...document.querySelectorAll("[data-dlopen]")].find(b => b.textContent.trim() === "Delivery ticket").click());
  await s.p.waitForFunction(() => /couldn't load/.test(document.getElementById("app").innerText), null, { timeout: 15000 }).catch(() => {});
  ok("A tampered viewer is refused by the integrity check", s.msgs.some(m => /integrity/i.test(m)) && /The PDF viewer couldn't load/.test(await app(s.p)) && !(await s.p.evaluate(() => !!window.pdfjsLib)));
  await s.ctx.close();

  // 3. no signal: open the trip on Wi-Fi (service worker on), go offline, reopen the app, open the ticket
  s = await session(browser, base, { sw: true });
  await s.p.goto(base);
  await s.p.waitForFunction(() => navigator.serviceWorker && navigator.serviceWorker.controller, null, { timeout: 15000 }).catch(() => {});
  await s.p.reload();                                    // now under the service worker's control
  await openTicket(s.p, "PROJ-00418");
  await s.p.waitForTimeout(3000);                         // the trip's files and the viewer are saved
  const cached = await s.p.evaluate(async () => { const out = []; for (const k of await caches.keys()) for (const r of await (await caches.open(k)).keys()) if (/pdfjs|delivery-files/.test(r.url)) out.push(r.url.replace(/^.*\//, "")); return out; });
  ok("On Wi-Fi the phone saved the viewer and the ticket", cached.includes("pdf.min.js") && cached.includes("pdf.worker.min.js") && cached.some(u => /\.pdf$/.test(decodeURIComponent(u))), cached.join(", "));
  await s.setOffline(true);
  await s.p.reload();
  await openTicket(s.p, "PROJ-00418");
  await s.p.evaluate(() => [...document.querySelectorAll("[data-dlopen]")].find(b => b.textContent.trim() === "Delivery ticket").click());
  await s.p.waitForFunction(() => document.querySelectorAll("#lodoc img").length === 2 || /couldn't|No connection/.test(document.getElementById("app").innerText), null, { timeout: 20000 }).catch(() => {});
  const off = await s.p.evaluate(() => ({ n: document.querySelectorAll("#lodoc img").length, t: document.getElementById("lodoc") ? document.getElementById("lodoc").innerText : "" }));
  ok("Offline, after reopening the app, the ticket still draws from the saved copies", off.n === 2, JSON.stringify(off));
  await s.ctx.close();

  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
