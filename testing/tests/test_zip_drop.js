// 1 Nov: the zip drop (drop.html, zip_drop.sql) in Chromium through the bridge. Real zips made with Python's zipfile
// (make_test_zips.py, as the Outputs project makes them) are dropped on the page as Luke: a good job zip loads the floor,
// sends its Router and Bend-Tech files through Machine files and parks every file; a zip that doesn't match its
// contents.json is refused whole with the reason and nothing is sent; a revised zip skips what's unchanged; format 2
// carries Design/; a library-only zip. David (a manager not let in) is turned away.
// OLDDB=1: a database without zip_drop.sql (the page says so plainly, and Machine files still works).
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_zip_drop.js
const fs = require("fs"), http = require("http"), path = require("path"), crypto = require("crypto");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin, files } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/newrepo", REPO = "/home/claude/sf/repo", MODE = process.env.MODE || "new";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  const b64 = async (blob) => { const u = new Uint8Array(await blob.arrayBuffer()); let s = ""; for (let i = 0; i < u.length; i += 8192) s += String.fromCharCode.apply(null, u.subarray(i, i + 8192)); return btoa(s); };
  let session = ${JSON.stringify(user)} ? { user: ${JSON.stringify(user)} } : null;
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => { session = null; return {}; }, onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (bucket) => ({
      upload: async (path, body, opts) => call({ kind: "storage", op: "upload", bucket, path, b64: await b64(body),   // the type supabase-js really sends: a Blob as its own type, anything else as contentType (2 Nov)
        opts: Object.assign({}, opts, { contentType: (typeof Blob !== "undefined" && body instanceof Blob) ? (body.type || "application/octet-stream") : ((opts && opts.contentType) || "text/plain;charset=UTF-8") }) }),
      download: async (path) => { const r = await call({ kind: "storage", op: "download", bucket, path });
        if (r.error) return r; const bin = atob(r.b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { data: new Blob([u]), error: null }; },
      remove: async (paths) => call({ kind: "storage", op: "remove", bucket, paths }) }) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, "");
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : "text/html" }); res.end(body);
});
async function session(browser, user, opts = {}) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: "block", acceptDownloads: true });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    if (m.kind === "storage") {
      const st = client.storage.from(m.bucket);
      if (m.op === "upload") return JSON.parse(JSON.stringify(await st.upload(m.path, Buffer.from(m.b64, "base64"), m.opts || {})));
      if (m.op === "remove") return JSON.parse(JSON.stringify(await st.remove(m.paths)));
      const r = await st.download(m.path); if (r.error) return { data: null, error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), error: null };
    }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  if (opts.folder) await ctx.addInitScript((name) => {   // the folder picker opens Chrome's private folder instead: same folder API
    window.showDirectoryPicker = async () => (await navigator.storage.getDirectory()).getDirectoryHandle(name, { create: true }); }, opts.folder);
  if (opts.noFolder) await ctx.addInitScript(() => { delete window.showDirectoryPicker; window.showDirectoryPicker = undefined; });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs, client };
}
const q = async (sql, a = []) => (await admin.query(sql, a)).rows;
const tmp = (name, content) => { const f = path.join("/tmp", name); fs.writeFileSync(f, content); return f; };
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const folderFiles = (p, name) => p.evaluate(async (name) => { const out = {}; const root = await (await navigator.storage.getDirectory()).getDirectoryHandle(name, { create: true });
  const walk = async (d, pre) => { for await (const [n, h] of d.entries()) { if (h.kind === "directory") await walk(h, pre + n + "/"); else out[pre + n] = await (await h.getFile()).text(); } };
  await walk(root, ""); return out; }, name);


const OLDDB = process.env.OLDDB === "1", ZIPS = "/tmp/zips";
(async () => {
  require("child_process").execSync(`rm -rf ${ZIPS} && python3 ${path.join(__dirname, "make_test_zips.py")} ${ZIPS}`);
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const browser = await chromium.launch();
  await admin.query("select lab_allow('luke@example.com')");

  // David: a manager, not let in
  { const s = await session(browser, users.david); await s.p.goto(base + "drop.html"); await s.p.waitForSelector("#notAllowed:not([hidden])");
    ok("David (a manager not let in) is turned away, told how to be let in", /isn’t let in/.test(await s.p.textContent("#notAllowedBody"))); await s.ctx.close(); }

  const S = await session(browser, users.luke), p = S.p;
  await p.goto(base + "drop.html"); await p.waitForSelector("#dropArea:not([hidden])", { timeout: 15000 });
  await p.waitForSelector("#fSend", { timeout: 15000 });
  const outText = () => p.textContent("#out");
  const drop = async (name) => { await p.setInputFiles("#pick", path.join(ZIPS, name));
    await p.waitForFunction(() => /Here’s what Send does|wasn’t used/.test(document.querySelector("#out").textContent), null, { timeout: 15000 }); return outText(); };
  const send = async () => { await p.click("#send");
    await p.waitForFunction(() => /parked for the save|wasn’t used/.test((document.querySelector("#result") || document.querySelector("#out")).textContent), null, { timeout: 30000 }); return outText(); };
  const n = async (sql, a = []) => Number((await q(sql, a))[0].n);

  if (OLDDB) {
    ok("Older database: the waiting card says zip_drop.sql hasn’t run", /zip_drop\.sql hasn’t run/.test(await p.textContent("#waiting")));
    const wo0 = await n("select count(*) n from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00502'");
    await drop("PROJ-00502.zip");
    const t = await send();
    ok("…a dropped zip is checked, then Send says plainly it isn’t set up, and nothing is sent", /wasn’t used/.test(t) && /zip_drop\.sql hasn’t run/.test(t), t.slice(0, 200));
    ok("…no work order and no machine file were made", await n("select count(*) n from machine_files") === 0
       && await n("select count(*) n from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00502'") === wo0);
    ok("…Machine files still lists and sends (its card is there)", !!(await p.$("#fSend")));
    ok("No page errors", !S.errs.length, S.errs.join(" | "));
    console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
  }

  // refusals: nothing reaches the database
  for (const [z, re, why] of [["not-a-zip.zip", /isn't a zip/, "not a zip"], ["unlisted.zip", /stray\.txt is in the zip but not listed/, "a file not listed"],
      ["wrongsize.zip", /X-1 base\.pdf is \d+ bytes in the zip, but contents\.json says/, "a wrong size"],
      ["noarrow.zip", /Sheet 2 in the upload file has no arrow list/, "a sheet with no arrow list"],
      ["wrongitem.zip", /item Z-9, but no sheet in the upload file has that item code/, "a machine file for an item not on the sheets"],
      ["design-v1.zip", /Design is new in format 2, and this zip says format 1/, "Design/ in a format 1 zip"],
      ["badcrc.zip", /X-1 base\.pdf in this zip is damaged/, "a file that doesn't match its checksum"],
      ["format4.zip", /says format 4; this page reads formats 1 to 3/, "a newer format"],
      ["bt-noitem3.zip", /Bend-Tech holds one folder per item/, "format 3: a Bend-Tech file with no item folder"],
      ["wrongfolder3.zip", /its folder \(X-2\) should be its item \(X-1\)/, "format 3: an item folder that isn't its item"],
      ["toolong3.zip", /too long once filed \(Metal\/X-1\/A+\.pdf is 46 characters; 45 at most\)/, "format 3: a path too long once filed"],
      ["metaldrawings3.zip", /Files holds only the folders Metal, KI, Arrow, Other/, "format 3: the old Metal drawings folder"],
      ["badjob.zip", /job should look like PROJ-00512/, "a job number that isn't PROJ-#####"],
      ["loose.zip", /Files holds only the folders/, "a loose file in Files"],
      ["wrongext.zip", /Router takes \.mprx or \.mpr only/, "a Router file that isn't a program"],
      ["nomachine.zip", /machine should be "homag"/, "a Router file that doesn't name its machine"],
      ["badname.zip", /isn't one Windows accepts/, "a name Windows refuses"],
      ["badlib.zip", /library files go in Database\/Metal\/Cut sheets/, "a library file outside the library's folders"],
      ["libjobnull.zip", /a zip with no job \(job: null\) holds only Database files/, "job files in a zip with no job"]]) {
    const t = await drop(z);
    ok(`Refused before Send, with the reason: ${why}`, /wasn’t used/.test(t) && re.test(t) && !(await p.$("#send")), t.slice(0, 160));
  }
  ok("…and nothing reached the database", await n("select count(*) n from zip_drops") === 0);

  // a good zip
  let t = await drop("PROJ-00502.zip");
  ok("A good zip shows what Send does: the floor (2 sheets, 1 Arrow line), both machines, Files and the library",
     /Loads the floor/.test(t) && /2 sheets from the upload file \(X-1, X-2\)/.test(t) && /1 Arrow line ride/.test(t)
     && /Homag router · item X-1 · Top/.test(t) && /Bend-Tech · item X-1 · V-Arm/.test(t)
     && /Filed in PROJ-00502 › Production › Files/.test(t) && /Metal\/X-1 base\.pdf/.test(t) && /Router\/00502-X1\.mpr/.test(t)
     && /library \(Claudes Shop System Folder › Database\)/.test(t) && /Metal\/Cut sheets\/SAM 30x60\.pdf/.test(t), t.slice(0, 400));
  ok("…and nothing is sent before Send", await n("select count(*) n from zip_drops") === 0);
  const V = await n("select coalesce(max(w.version), 0) + 1 n from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00502'");
  t = await send();
  ok("Send: Done, the floor saved as Upload did, 7 files parked", /Done/.test(t) && new RegExp(`Saved PROJ-00502 — version ${V}, 2 sheets`).test(t) && /7 files parked for the save/.test(t), t.slice(-500));
  const hasArrowSql = (await q("select to_regprocedure('public.set_sheet_arrow(uuid,jsonb)') is not null as y"))[0].y;
  if (hasArrowSql) ok("…and the sheets' Arrow lines are saved for the POs (one on sheet 1, none on sheet 2), as the upload file spelled them",
     /1 Arrow line saved for the POs/.test(t) && (await q(`select l.sheet_number, l.qty, l.base, l.pd_color from sheet_arrow_lines l join work_orders w on w.id = l.work_order_id join jobs j on j.id = w.job_id
       where j.project_id = 'PROJ-00502' and w.is_current`)).map(r => `${r.sheet_number} ${r.qty} ${r.base} ${r.pd_color}`).join() === "1 4 DAN Denim Black");
  ok("…the work order is on the floor with both sheets and their page files", await n(`select count(*) n from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
       where j.project_id = 'PROJ-00502' and w.is_current and s.png_path is not null and s.pdf_path is not null`) === 2);
  const parked = await q("select zip_path, place, rel_path, stored_at, storage_path, size_bytes from parked_files order by zip_path");
  ok("…every file parked and stored, each where it’s filed", parked.length === 7 && parked.every(r => r.stored_at)
     && parked.some(r => r.zip_path === "Floor/PROJ-00502_upload.json" && r.rel_path === "PROJ-00502_upload.json")
     && parked.some(r => r.place === "library" && r.rel_path === "Metal/Cut sheets/SAM 30x60.pdf"), JSON.stringify(parked.map(r => r.rel_path)));
  const bytesOk = await (async () => { for (const r of parked) { const d = await S.client.storage.from("parked-files").download(r.storage_path);
      if (d.error || (await d.data.arrayBuffer()).byteLength !== Number(r.size_bytes)) return false; } return true; })();
  ok("…and each stored file is its exact size in the parked-files bucket", bytesOk);
  const mf = await q("select machine, item_id, part, rev, file_name, stored_at, note from machine_files where project_id = 'PROJ-00502' order by machine");
  ok("…the Router and Bend-Tech files are waiting for their machines, named and noted", mf.length === 2 && mf.every(r => r.stored_at)
     && mf[0].machine === "bendtech" && mf[0].file_name === "PROJ-00502_X-1_V-Arm_r1.step" && mf[1].file_name === "PROJ-00502_X-1_Top_r1.mpr"
     && /from PROJ-00502\.zip, revision 1 there/.test(mf[1].note), JSON.stringify(mf));
  await p.waitForFunction(() => /Waiting for the save on your PC/.test(document.querySelector("#waiting").textContent));
  const w = await p.textContent("#waiting");
  ok("The waiting list shows each file waiting for the save, and the zip as Done", (w.match(/Waiting for the save on your PC/g) || []).length === 7 && /PROJ-00502\.zip/.test(w) && /Done/.test(w));
  ok("Machine files lists the two new files", /PROJ-00502_X-1_V-Arm_r1\.step/.test(await p.textContent("#files")));

  // the revised zip: one changed program
  t = await drop("PROJ-00502-rev.zip");
  ok("A revised zip: unchanged files are marked before Send", (t.match(/unchanged, skipped/g) || []).length === 6 && /already sent/.test(t), (t.match(/unchanged, skipped/g) || []).length + "");
  t = await send();
  ok("…Send: the floor isn’t loaded again, the changed program is parked, 6 skipped", /already has this upload file/.test(t) && /1 file parked for the save; 6 unchanged, skipped/.test(t), t.slice(-400));
  ok("…the floor keeps the same version", await n("select max(w.version) n from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00502'") === V);
  const mf2 = await q("select machine, rev, replaced_by from machine_files where project_id = 'PROJ-00502' order by machine, rev");
  ok("…the program goes as r2 and replaces r1; the unchanged STEP file isn’t sent again", mf2.length === 3 && mf2.filter(r => r.machine === "homag").map(r => r.rev).join() === "1,2"
     && mf2.find(r => r.machine === "homag" && r.rev === 1).replaced_by && mf2.filter(r => r.machine === "bendtech").length === 1, JSON.stringify(mf2));

  // format 2: Design/
  t = await drop("PROJ-00502-v2.zip");
  ok("Format 2 with Design/: shown as a 3D model for X-1, made into a 3D view and filed under Files › Design", /3D models/.test(t) && /X-1: each made into a 3D view on this PC/.test(t)
     && /filed under Files › Design/.test(t) && /Design\/X-1 whole\.step/.test(t));
  t = await send();
  ok("…sent: the 3D model parked (nothing to a machine)", /1 file parked/.test(t)
     && await n("select count(*) n from parked_files where zip_path = 'Design/X-1 whole.step' and item = 'X-1' and machine is null and stored_at is not null") === 1
     && await n("select count(*) n from machine_files where project_id = 'PROJ-00502'") === 3);
  // 1 Nov: the 3D view. jsDelivr is shut off in this test, so the STEP engine can't load: the view isn't made, the page says
  // why in words, the reason is kept for Make it again, and the rest of the drop is Done as before (test_design_viewer_chromium makes real ones)
  const has3d = (await q("select to_regclass('public.item_designs') is not null as h"))[0].h;
  ok(has3d ? "…its 3D view couldn't be made here (no STEP engine): Not made, with the reason, kept in the database; the drop is still Done"
           : "…a database without design_viewer.sql: the 3D view says it isn't set up yet, and the drop is still Done",
     /3D views/.test(t) && /Done/.test(t) && (has3d ? /Not made/.test(t) && /STEP engine couldn.t be downloaded/.test(t)
       && await n("select count(*) n from item_designs where project_id = 'PROJ-00502' and item = 'X-1' and status = 'failed' and failed_why like '%STEP engine%'") === 1
       : /Not set up yet/.test(t) && /design_viewer\.sql hasn.t run/.test(t)), t.slice(-500));

  // format 3 (3 Nov): Files › Metal, one folder per item, nothing over 45 characters as filed
  t = await drop("PROJ-00502-v3.zip");
  ok("Format 3: the plan shows Bend-Tech and Files › Metal with one folder per item", /format 3/.test(t) && /Bend-Tech\/X-1\/V-Arm\.step/.test(t)
     && /Metal\/X-1\/Base\.pdf/.test(t) && /Metal\/Cut sheet\.pdf/.test(t), t.slice(0, 400));
  t = await send();
  ok("…sent: recorded as format 3, each file parked where it's filed (the STEP file unchanged, so not sent to the Bend-Tech again)", /Done/.test(t)
     && await n("select count(*) n from zip_drops where format = 3") === 1
     && await n("select count(*) n from parked_files where rel_path in ('Bend-Tech/X-1/V-Arm.step', 'Metal/X-1/Base.pdf', 'Metal/Cut sheet.pdf') and stored_at is not null") === 3
     && await n("select count(*) n from machine_files where project_id = 'PROJ-00502'") === 3, t.slice(-300));
  ok("…a format 2 zip's Metal drawings is parked as Metal", await n("select count(*) n from parked_files where zip_path = 'Files/Metal drawings/X-1 base.pdf' and rel_path = 'Metal/X-1 base.pdf'") >= 1);

  // a library-only zip
  t = await drop("Database 2026-11-03.zip");
  ok("A library-only zip: no floor, no machines, two library files (one replacing)", !/Loads the floor/.test(t) && /The library/.test(t) && /CNC\/Other\/Round 36\.mpr/.test(t) && /replaces the one there/.test(t));
  t = await send();
  ok("…sent: both parked, as library files with no job", /2 files parked/.test(t)
     && await n("select count(*) n from parked_files where place = 'library' and project_id is null and stored_at is not null") === 3);

  // the narrow screen: nothing runs off the side
  await p.setViewportSize({ width: 390, height: 800 });
  ok("At phone width the page doesn’t scroll sideways", await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
  ok("No page errors", !S.errs.length, S.errs.join(" | "));
  if (process.env.SHOTS) await p.screenshot({ path: path.join(process.env.SHOTS, "drop.png"), fullPage: true });
  console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
