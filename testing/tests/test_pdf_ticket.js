// 5 Oct: a trip's PDF ticket and PDF site files open inside the app (their own screen, like a work order page),
// never in a new tab. Images still open in the viewer as before. Run on a freshly seeded database:
//   bash /home/claude/sf/base/fresh.sh && TZ=America/Indiana/Indianapolis node test_pdf_ticket.js
// PAGE=/home/claude/sf/repo/index.html runs it on the live page, where it must fail (the live page opens a new tab).
const fs = require("fs");
const crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
const HTML = fs.readFileSync(PAGE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const FX = "/tmp/sf_pdf_fixtures/";
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
makeFixtures(FX);
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }

// a stand-in for pdf.js: hands back the number of pages asked for, and notes what it was given
function fakePdfjs(pages, seen) {
  return { getDocument: (o) => { seen.push(o); const head = Buffer.from(o.data.slice(0, 4)).toString();
    return { promise: head === "%PDF" ? Promise.resolve({ numPages: pages, destroy() {},
      getPage: async () => ({ getViewport: ({ scale }) => ({ width: 612 * scale, height: 792 * scale }), render: () => ({ promise: Promise.resolve() }), cleanup() {} }) })
      : Promise.reject(new Error("Invalid PDF structure")) }; } };
}
function boot(user, opts = {}) {
  const client = makeClient(user);
  if (opts.storageDown) client.storage = { from: () => ({ download: async () => ({ data: null, error: { message: "Failed to fetch" } }) }) };
  const dom = new JSDOM(HTML, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  const blobs = new Map(); let n = 0;
  w.Blob = Blob; w.URL.createObjectURL = (b) => { const k = "blob:t" + (n++); blobs.set(k, b); return k; }; w.URL.revokeObjectURL = () => {};
  w.fetch = async (u) => ({ arrayBuffer: () => blobs.get(u).arrayBuffer() });
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.HTMLCanvasElement.prototype.toBlob = function (cb) { cb(new Blob(["png"], { type: "image/png" })); };
  w.print = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  const opened = []; w.open = (...a) => { opened.push(a); return null; };
  const seen = []; let asked = 0;
  if (opts.viewer === "missing") Object.defineProperty(w, "sfPdfjs", { get() { asked++; throw new Error("pdf viewer"); } });
  else { const lib = fakePdfjs(opts.pages || 2, seen); Object.defineProperty(w, "sfPdfjs", { get() { asked++; return lib; } }); }
  w.eval([...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client, opened, seen, asked: () => asked };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w) => ($(w, "#app") || {}).textContent.replace(/\s+/g, " ") || "";
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const btn = (w, label) => $$(w, "[data-dlopen]").find(b => b.textContent.trim() === label);

async function addDoc(luke, pid, cid, file, mime, kind, name) {
  const id = crypto.randomUUID(), ext = { "application/pdf": "pdf", "image/jpeg": "jpg" }[mime];
  const up = await luke.storage.from("deliveries").upload(`${pid}/${cid}/${id}.${ext}`, new Blob([fs.readFileSync(FX + file)], { type: mime }), { contentType: mime, upsert: false });
  if (up.error) throw new Error("upload: " + up.error.message);
  const r = await luke.rpc("add_delivery_doc", { p_client_id: id, p_loadout: cid, p_kind: kind, p_file_name: name });
  if (r.error) throw new Error("add_delivery_doc: " + r.error.message);
}
async function openTrip(w, pid) {
  if ($(w, '[data-tab="loadout"]')) await click(w, '[data-tab="loadout"]', 400);
  await until(() => $$(w, "[data-loopen]").some(b => b.textContent.includes(pid)));
  await click(w, $$(w, "[data-loopen]").find(b => b.textContent.includes(pid)), 500);
  await until(() => $$(w, "[data-dlopen]").length > 0);
}

(async () => {
  const luke = makeClient(users.luke);
  const job = (pid) => admin.query("select id from jobs where project_id = $1", [pid]).then(r => r.rows[0].id);
  // a white glove delivery tomorrow, with a PDF ticket, a JPEG site file and a PDF site file
  const dcid = crypto.randomUUID();
  const when = new Date(Date.now() + 86400000); when.setHours(9, 0, 0, 0);
  let r = await luke.rpc("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: when.toISOString(), p_note: "Test trip", p_loadout: null, p_client_id: dcid });
  if (r.error) throw new Error("schedule_delivery: " + r.error.message);
  await addDoc(luke, "PROJ-00418", dcid, "ticket.pdf", "application/pdf", "ticket", "Ticket.pdf");
  await addDoc(luke, "PROJ-00418", dcid, "site.jpg", "image/jpeg", "site_file", "Site photo.jpg");
  await addDoc(luke, "PROJ-00418", dcid, "plan.pdf", "application/pdf", "site_file", "Floor plan.pdf");
  // a customer pickup with a PDF ticket
  const pcid = crypto.randomUUID();
  r = await luke.rpc("schedule_pickup", { p_job: await job("PROJ-00362"), p_kind: "customer_pickup", p_note: null, p_loadout: null, p_client_id: pcid });
  if (r.error) throw new Error("schedule_pickup: " + r.error.message);
  await addDoc(luke, "PROJ-00362", pcid, "ticket.pdf", "application/pdf", "ticket", "Ticket.pdf");

  // ---- Shawn opens the delivery and taps the ticket ----
  let t = boot(users.shawn), w = t.w;
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);
  await openTrip(w, "PROJ-00418");
  ok("The delivery shows its ticket and site files", !!btn(w, "Delivery ticket") && !!btn(w, "Site photo.jpg") && !!btn(w, "Floor plan.pdf"),
     $$(w, "[data-dlopen]").map(b => b.textContent.trim()).join(", "));
  await wait(300);
  ok("Opening the delivery on Wi-Fi also fetches the PDF viewer (kept for no signal)", t.asked() > 0);
  await click(w, btn(w, "Delivery ticket"));
  await until(() => $$(w, "#lodoc img").length > 0);
  ok("Tapping the ticket opens no new tab", t.opened.length === 0, JSON.stringify(t.opened));
  ok("It opens on its own screen: ← Delivery, the name, the PROJ number",
     ($(w, "[data-lowoback]") || {}).textContent === "← Delivery" && $(w, "#app h1").textContent === "Delivery ticket" && /PROJ-00418/.test(txt(w)));
  const imgs = $$(w, "#lodoc img");
  ok("Both pages of the ticket show as pictures, in order", imgs.length === 2 && imgs[0].alt === "Delivery ticket, page 1 of 2" && imgs[1].alt === "Delivery ticket, page 2 of 2",
     imgs.map(i => i.alt).join(" | "));
  ok("The viewer was given the ticket's real bytes, with font code switched off", t.seen.length === 1 && t.seen[0].isEvalSupported === false);
  ok("It says Pinch to zoom", /Pinch to zoom/.test(txt(w)));
  ok("The delivery's own steps are not on this screen", !$(w, "#sigpad") && !/At the dock/.test(txt(w)));
  // a render while it's showing doesn't draw it again
  w.dispatchEvent(new w.Event("online")); await wait(600);
  ok("Coming back to it doesn't draw it again", t.seen.length === 1 && $$(w, "#lodoc img").length === 2);
  await click(w, "[data-lowoback]", 400);
  ok("← Delivery goes back to the delivery", !!btn(w, "Delivery ticket") && /At the dock/.test(txt(w)) && !$(w, "#lodoc"));
  await click(w, btn(w, "Site photo.jpg"), 400);
  await until(() => $(w, ".viewer img"));
  ok("A picture site file still opens in the photo viewer, as before", !!$(w, ".viewer img") && t.opened.length === 0);
  await click(w, ".viewer [data-close]", 300);
  await click(w, btn(w, "Floor plan.pdf"));
  await until(() => $$(w, "#lodoc img").length > 0);
  ok("A PDF site file opens inside the app too", $(w, "#app h1").textContent === "Floor plan.pdf" && $$(w, "#lodoc img").length === 2 && t.opened.length === 0);
  await click(w, "[data-lowoback]", 300);
  await click(w, "[data-loback]", 600);
  await openTrip(w, "PROJ-00418");
  ok("Leaving the trip and coming back opens the trip, not the PDF", !$(w, "#lodoc") && !!btn(w, "Delivery ticket"));
  w.close();

  // ---- the pickup ----
  t = boot(users.shawn); w = t.w;
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);
  await openTrip(w, "PROJ-00362");
  await click(w, btn(w, "Ticket"));
  await until(() => $$(w, "#lodoc img").length > 0);
  ok("A pickup's ticket opens inside the app, with ← Customer pickup", /^← /.test(($(w, "[data-lowoback]") || {}).textContent || "") && /pickup/i.test($(w, "[data-lowoback]").textContent)
     && $$(w, "#lodoc img").length === 2 && t.opened.length === 0, ($(w, "[data-lowoback]") || {}).textContent);
  w.close();

  // ---- when it can't be shown ----
  t = boot(users.shawn, { viewer: "missing" }); w = t.w;
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);
  await openTrip(w, "PROJ-00418"); await click(w, btn(w, "Delivery ticket"));
  await until(() => /couldn't load/.test(txt(w)));
  ok("No viewer: it says so in plain words", /The PDF viewer couldn't load. It needs a connection the first time/.test(txt(w)));
  ok("…and offers a new window as a fallback, which works only when tapped", !!$(w, "[data-dlpopout]") && t.opened.length === 0);
  await click(w, "[data-dlpopout]", 300);
  ok("The fallback opens the saved copy", t.opened.length === 1 && /^blob:/.test(t.opened[0][0]));
  w.close();

  t = boot(users.shawn, { storageDown: true }); w = t.w;
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);
  await openTrip(w, "PROJ-00418"); await click(w, btn(w, "Delivery ticket"));
  await until(() => /No connection/.test(txt(w)));
  ok("No signal and never saved: the same words as before, and no fallback button",
     /No connection, and this file wasn't saved on this phone before\. Open the delivery on Wi-Fi to save its files\./.test(txt(w)) && !$(w, "[data-dlpopout]"));
  w.close();

  // a file that isn't a real PDF
  const bad = crypto.randomUUID();
  r = await luke.rpc("schedule_delivery", { p_job: await job("PROJ-00099"), p_when: when.toISOString(), p_note: null, p_loadout: null, p_client_id: bad });
  if (r.error) throw new Error("schedule_delivery 00325: " + r.error.message);
  const id = crypto.randomUUID();
  await luke.storage.from("deliveries").upload(`PROJ-00099/${bad}/${id}.pdf`, new Blob(["not a pdf"], { type: "application/pdf" }), { contentType: "application/pdf", upsert: false });
  await luke.rpc("add_delivery_doc", { p_client_id: id, p_loadout: bad, p_kind: "ticket", p_file_name: "Ticket.pdf" });
  t = boot(users.shawn); w = t.w;
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);
  await openTrip(w, "PROJ-00099"); await click(w, btn(w, "Delivery ticket"));
  await until(() => /couldn't be shown/.test(txt(w)));
  ok("A broken PDF: 'This PDF couldn't be shown', with the fallback", /This PDF couldn't be shown/.test(txt(w)) && !!$(w, "[data-dlpopout]") && t.opened.length === 0);
  w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
