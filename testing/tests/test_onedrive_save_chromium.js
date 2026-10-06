// 6 Oct: saving to OneDrive in real Chromium. The folder picker is pointed at the browser's private storage area,
// which has the very same folder API (entries, getDirectoryHandle, createWritable, getFile, resolve), and the folders
// are remembered in the browser's real IndexedDB. Checks what jsdom can't: real writes and read-backs, a spreadsheet's
// leading marker surviving the "unchanged?" comparison, and the folders remembered across a reload with an automatic save.
//   bash /home/claude/sf/base/fresh.sh <feedback.sql> <trip_types.sql> <onedrive_save.sql> <install_log.sql>
//   OUT=<folder with the new pages> PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_onedrive_save_chromium.js
const fs = require("fs"), http = require("http"), path = require("path"), crypto = require("crypto");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (b) => ({ download: async (p) => { const r = await call({ kind: "dl", b, p }); if (r.error) return { data: null, error: r.error };
      const bin = Uint8Array.from(atob(r.b64), c => c.charCodeAt(0)); return { data: new Blob([bin], { type: r.type }), error: null }; } }) } };
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
const runs = async () => (await admin.query("select * from save_runs order by finished_at")).rows;
// list every file under a private-storage folder, with its first bytes and size
const LIST = async (p, name) => p.evaluate(async (name) => {
  const out = {}; const root = await (await navigator.storage.getDirectory()).getDirectoryHandle(name);
  const walk = async (d, pre) => { for await (const [k, h] of d.entries()) {
    if (h.kind === "file") { const f = await h.getFile(); const b = new Uint8Array(await f.arrayBuffer()); out[pre + k] = { size: f.size, head: [...b.slice(0, 3)], last: f.lastModified }; }
    else await walk(h, pre + k + "/"); } };
  await walk(root, ""); return out; }, name);

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/office.html`;
  // a photo on PROJ-00418
  const J418 = (await admin.query("select id from jobs where project_id = 'PROJ-00418'")).rows[0].id;
  const PATH = `PROJ-00418/${crypto.randomUUID()}.jpg`, BYTES = Buffer.from("\xff\xd8\xff a real browser photo", "latin1");
  const luke = makeClient(users.luke);
  const up = await luke.storage.from("photos").upload(PATH, BYTES, { contentType: "image/jpeg" });
  if (up.error) console.log("UPLOAD", up.error);
  const lo = (await admin.query("insert into loadouts (job_id, kind, started_at) values ($1, 'delivery', now()) returning id", [J418])).rows[0].id;
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 1, 'dock', $3, 'Shawn K', $4)`, [J418, lo, PATH, BYTES.length]);

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 860 }, serviceWorkers: "block" });
  await ctx.addInitScript(() => {
    localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); localStorage.setItem("sfo_tab", JSON.stringify("photos"));
    // the picker hands back folders from the private storage area; the test says which next
    window.showDirectoryPicker = async () => { const n = (JSON.parse(localStorage.getItem("pick") || "[]")).shift();
      localStorage.setItem("pick", "[]"); if (!n) { const e = new Error("cancelled"); e.name = "AbortError"; throw e; }
      let d = await navigator.storage.getDirectory(); for (const x of n.split("/")) d = await d.getDirectoryHandle(x, { create: true }); return d; };
  });
  const client = makeClient(users.luke);
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "dl") { const r = await client.storage.from(m.b).download(m.p); if (r.error) return { error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), type: r.data.type }; }
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(users.luke), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  let p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  await p.goto(base);
  await p.waitForSelector("[data-savepick]", { timeout: 15000 });
  // the OneDrive projects folder: PROJ-00418 at the top, PROJ-00501 in a hundreds folder
  await p.evaluate(async () => { let r = await navigator.storage.getDirectory();
    const od = await r.getDirectoryHandle("od", { create: true }); await od.getDirectoryHandle("PROJ-00418 Enid's Table", { create: true });
    await (await od.getDirectoryHandle("500s", { create: true })).getDirectoryHandle("Proj-00501 Hotel", { create: true }); });

  await p.evaluate(() => localStorage.setItem("pick", JSON.stringify(["od"]))); await p.click('[data-savepick="od"]');
  await p.waitForFunction(() => /OneDrive projects folder chosen: od/.test(document.body.innerText));
  await p.evaluate(() => localStorage.setItem("pick", JSON.stringify(["od/500s"]))); await p.click('[data-savepick="bk"]');
  await p.waitForFunction(() => /has to be separate/.test(document.body.innerText));
  ok("Real browser: a backup folder inside the OneDrive folder is refused (the browser's own resolve())", true);
  await p.evaluate(() => localStorage.setItem("pick", JSON.stringify(["bk"]))); await p.click('[data-savepick="bk"]');
  await p.waitForFunction(() => /Backup folder chosen: bk/.test(document.body.innerText));

  let n0 = (await runs()).length;
  await p.click("[data-savenow]");
  await p.waitForFunction(() => /Saved .*files? written/.test(document.body.innerText), null, { timeout: 30000 });
  let r = (await runs()).slice(-1)[0];
  const od = await LIST(p, "od"), bk = await LIST(p, "bk");
  const odKeys = Object.keys(od).filter(k => /^PROJ-00418/.test(k)).map(k => k.replace(/^[^/]+\/shop-floor data\//, "")).sort();
  const bkKeys = Object.keys(bk).filter(k => /^PROJ-00418\//.test(k)).map(k => k.replace(/^[^/]+\/shop-floor data\//, "")).sort();
  ok("Real browser: the save wrote PROJ-00418's photo and records into its OneDrive folder", odKeys.some(k => /Load-out Picture\.jpg$|\.jpg$/.test(k)) && odKeys.includes("Production record.csv"), odKeys.join(", "));
  ok("…the same files in the backup folder", JSON.stringify(odKeys) === JSON.stringify(bkKeys), bkKeys.join(", "));
  const photo = Object.entries(od).find(([k]) => /\.jpg$/.test(k));
  ok("…the photo is the full file", photo && photo[1].size === BYTES.length);
  const prod = od["PROJ-00418 Enid's Table/shop-floor data/Production record.csv"];
  ok("…the spreadsheet starts with its marker (so Excel reads it right)", prod && prod.head.join() === "239,187,191");
  ok("…PROJ-00501 was found inside 500s", Object.keys(od).some(k => /^500s\/Proj-00501 Hotel\/shop-floor data\/Production record\.csv$/.test(k)));
  ok("…and the log says both places were reached", r && r.onedrive_ok && r.backup_ok && r.how === "button" && (await runs()).length === n0 + 1);

  await p.click("[data-savenow]");
  await p.waitForFunction((n) => !/Saving|Reading/.test((document.getElementById("saveProgress") || {}).textContent || "") , null, { timeout: 30000 });
  await p.waitForTimeout(1500);
  r = (await runs()).slice(-1)[0];
  ok("Real browser: a second save writes nothing (the spreadsheets are recognised as unchanged)", r.files_written === 0, `${r.files_written} files written`);

  // reload: the folders come back from the browser's real IndexedDB, and it saves by itself within half a minute
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'watch', 'Seen after the reload', 'Luke H')", [J418]);
  n0 = (await runs()).length;
  await p.reload();
  await p.waitForFunction(() => /OneDrive projects folder: od/.test(document.body.innerText) && /Backup folder \(hard drive\): bk/.test(document.body.innerText), null, { timeout: 15000 });
  ok("Real browser, reloaded: both folders are remembered", true);
  const t0 = Date.now();
  while (Date.now() - t0 < 40000 && (await runs()).length === n0) await p.waitForTimeout(500);
  r = (await runs()).slice(-1)[0];
  const flags = await p.evaluate(async () => { const r = await navigator.storage.getDirectory();
    const d = await (await (await r.getDirectoryHandle("od")).getDirectoryHandle("PROJ-00418 Enid's Table")).getDirectoryHandle("shop-floor data");
    return (await (await d.getFileHandle("Flags.csv")).getFile()).text(); }).catch(e => "missing: " + e.message);
  ok("…it saved by itself after opening (marked auto), and the new flag is in Flags.csv", r && r.how === "auto" && r.onedrive_ok && r.backup_ok && /Seen after the reload/.test(flags), flags.slice(0, 120));
  ok("No page errors", errs.length === 0, errs.join(" | "));
  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
