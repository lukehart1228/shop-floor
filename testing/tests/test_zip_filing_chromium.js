// 1 Nov: the save files what dropped zips parked (zip_drop.sql) — in real Chromium, with the browser's real folder API
// standing in for OneDrive, the backup drive and Claudes Shop System Folder. Job files go into Production › Files in
// both places; a different file already there keeps its name and the new one gets the drop date; library files wait
// until the third folder is chosen, then go into Database; a library file that differs waits until Luke says replace
// it; Database index.csv lists what's really in the folder (a file added by hand too); every filed file comes off
// Supabase, its record kept; a second save writes nothing.
//   TEMPLATE=sync_base_new bash base/fresh.sh, then
//   OUT=<folder with the new pages> PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_zip_filing_chromium.js
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
    storage: { from: (b) => ({ remove: async (paths) => call({ kind: "rm", b, paths }), download: async (p) => { const r = await call({ kind: "dl", b, p }); if (r.error) return { data: null, error: r.error };
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
const LIST = async (p, name) => p.evaluate(async (name) => {
  const out = {}; let root; try { root = await (await navigator.storage.getDirectory()).getDirectoryHandle(name); } catch (e) { return out; }
  const walk = async (d, pre) => { for await (const [k, h] of d.entries()) {
    if (h.kind === "file") out[pre + k] = await (await h.getFile()).text(); else await walk(h, pre + k + "/"); } };
  await walk(root, ""); return out; }, name);
const q = async (sql, a = []) => (await admin.query(sql, a)).rows;
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/office.html`;
  await admin.query("select lab_allow('luke@example.com')");
  const luke = makeClient(users.luke);
  // park a zip as the drop page does
  const park = async (name, job, fmt, files) => {
    const contents = { kind: "shop-floor-zip", format: fmt, job, made_at: "2026-11-01T09:00:00-05:00",
      files: files.map(([path, data, m]) => ({ path, what: m.what || "file", bytes: Buffer.byteLength(data), ...m, what: m.what || "file" })) };
    const r = await luke.rpc("zip_drop_new", { p_zip_name: name, p_contents: contents, p_files: files.map(([path, data]) => ({ path, bytes: Buffer.byteLength(data), sha256: sha(Buffer.from(data)) })) });
    if (r.error) throw new Error(r.error.message);
    for (const x of r.data.files) if (x.storage_path) {
      const data = files.find(f => f[0] === x.path)[1];
      const up = await luke.storage.from("parked-files").upload(x.storage_path, Buffer.from(data), { contentType: "application/octet-stream" });
      if (up.error) throw new Error(up.error.message);
      const st = await luke.rpc("parked_file_stored", { p_id: x.id }); if (st.error) throw new Error(st.error.message);
    }
    return r.data;
  };
  await park("PROJ-00418.zip", "PROJ-00418", 2, [
    ["Floor/PROJ-00418_Production_Sheets.pdf", "%PDF work order 418", { what: "work order" }],
    ["Files/Metal drawings/A base.pdf", "%PDF the NEW base drawing", { what: "metal drawing" }],
    ["Router/418-A.mpr", "program A", { what: "CNC program", machine: "homag", item: "A", part: "Top", revision: 1 }],
    ["Design/A whole.step", "ISO-10303-21; A", { what: "3D model", item: "A" }],
    ["Database/Metal/Cut sheets/SAM 30x60.pdf", "%PDF cut sheet from the zip", { what: "cut sheet", replaces: false }],
    ["Database/CNC/Other/Round 36.mpr", "round program", { what: "CNC program", replaces: false }]]);
  await park("PROJ-00501.zip", "PROJ-00501", 1, [["Files/Other/site plan.pdf", "%PDF hotel site plan", { what: "site plan" }]]);
  // an Arrow PO made on the floor (arrow_pos.sql, 1 Nov), through Willie's own login; none before that file
  const hasPo = (await q("select to_regprocedure('public.arrow_po_make(uuid,date,jsonb)') is not null as y"))[0].y;
  let poRow = null;
  if (hasPo) {
    await luke.rpc("set_arrow_po_settings", { p: { issued_by: "Luke Hart", address: "Purposeful Design", next_number: 10 } });
    const j99 = (await q("select id from jobs where project_id = 'PROJ-00099'"))[0].id;
    await q(`insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
             values ($1, '{1}', 'powdercoat', 'metal', current_date, true, current_date, 'Willie', 'Willie')`, [j99]);
    const item = (await q("select id from outside_jobs where job_id = $1 and waiting", [j99]))[0].id;
    const mk = await makeClient(users.willie).rpc("arrow_po_make", { p_client_id: crypto.randomUUID(), p_gone_on: null, p_items: [{ id: item }] });
    poRow = mk.data;
  }
  const day = (await q("select to_char(dropped_at at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') d from zip_drops limit 1"))[0].d;

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 860 }, serviceWorkers: "block" });
  await ctx.addInitScript(() => {
    localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); localStorage.setItem("sfo_tab", JSON.stringify("photos"));
    window.showDirectoryPicker = async () => { const n = (JSON.parse(localStorage.getItem("pick") || "[]")).shift();
      localStorage.setItem("pick", "[]"); if (!n) { const e = new Error("cancelled"); e.name = "AbortError"; throw e; }
      let d = await navigator.storage.getDirectory(); for (const x of n.split("/")) d = await d.getDirectoryHandle(x, { create: true }); return d; };
  });
  const client = makeClient(users.luke);
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "dl") { const r = await client.storage.from(m.b).download(m.p); if (r.error) return { error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), type: r.data.type }; }
    if (m.kind === "rm") return JSON.parse(JSON.stringify(await client.storage.from(m.b).remove(m.paths)));
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(users.luke), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  // the real pdf-lib 1.17.1 (the office checks its hash), from npm instead of jsDelivr: the Arrow POs' PDFs
  const PDFLIB = "/tmp/pdflib/package/dist/pdf-lib.min.js";
  if (!fs.existsSync(PDFLIB)) require("child_process").execSync("mkdir -p /tmp/pdflib && cd /tmp/pdflib && npm pack pdf-lib@1.17.1 >/dev/null 2>&1 && tar xzf pdf-lib-1.17.1.tgz");
  await ctx.route(/pdf-lib@1\.17\.1/, r => r.fulfill({ body: fs.readFileSync(PDFLIB), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  await p.goto(base);
  await p.waitForSelector("[data-savepick]", { timeout: 15000 });
  // OneDrive already has a different "A base.pdf" in PROJ-00418's Files; the library already has a different SAM 30x60.pdf and a file added by hand
  await p.evaluate(async () => { const r = await navigator.storage.getDirectory();
    const put = async (d, n, text) => { const w = await (await d.getFileHandle(n, { create: true })).createWritable(); await w.write(text); await w.close(); };
    const dir = async (d, segs) => { for (const s of segs) d = await d.getDirectoryHandle(s, { create: true }); return d; };
    await put(await dir(r, ["od", "400s", "PROJ-00418 Enid's Table", "Production", "Files", "Metal drawings"]), "A base.pdf", "%PDF the OLD base drawing");
    await put(await dir(r, ["sys", "Database", "Metal", "Cut sheets"]), "SAM 30x60.pdf", "%PDF the library's own cut sheet");
    await put(await dir(r, ["sys", "Database", "CNC", "KI"]), "hand.mpr", "added by hand"); });
  const pick = async (k, folder, re) => { await p.evaluate((f) => localStorage.setItem("pick", JSON.stringify([f])), folder); await p.click(`[data-savepick="${k}"]`);
    await p.waitForFunction((s) => new RegExp(s).test(document.body.innerText), re); };
  await pick("od", "od", "OneDrive projects folder chosen: od"); await pick("bk", "bk", "Backup folder chosen: bk");
  ok("The saving panel offers the third folder, Claudes Shop System Folder", /Claudes Shop System Folder \(the library\)/.test(await p.innerText("body")));
  const saveNow = async () => { const n0 = (await q("select count(*) n from save_runs"))[0].n; await p.click("[data-savenow]");
    await p.waitForFunction(() => !/Saving|Reading|Filing/.test((document.getElementById("saveProgress") || {}).textContent || ""), null, { timeout: 30000 });
    for (let i = 0; i < 40 && (await q("select count(*) n from save_runs"))[0].n === n0; i++) await p.waitForTimeout(250);
    await p.waitForTimeout(500); return (await q("select * from save_runs order by finished_at desc limit 1"))[0]; };

  // 1. no third folder yet
  let run = await saveNow();
  let od = await LIST(p, "od"), bk = await LIST(p, "bk");
  const F = "400s/PROJ-00418 Enid's Table/Production/Files/", B = "PROJ-00418/Production/Files/";
  ok("Job files are filed in OneDrive's Production › Files (the job in a hundreds folder): the work order at the top, the rest in the zip's folders",
     od[F + "PROJ-00418_Production_Sheets.pdf"] === "%PDF work order 418" && od[F + "Router/418-A.mpr"] === "program A" && od[F + "Design/A whole.step"] === "ISO-10303-21; A", Object.keys(od).join(", "));
  ok("…the old Metal drawings folder moved into Metal (3 Nov); a different file already called A base.pdf is left alone, and the new one is filed beside it as A base r2.pdf",
     od[F + "Metal/A base.pdf"] === "%PDF the OLD base drawing" && od[F + "Metal/A base r2.pdf"] === "%PDF the NEW base drawing"
     && !Object.keys(od).some(k => k.includes("Metal drawings")), Object.keys(od).filter(k => /Files/.test(k)).join(", "));
  ok("…the backup folder has the same files under the same names", bk[B + "Metal/A base r2.pdf"] === "%PDF the NEW base drawing" && bk[B + "Design/A whole.step"] === "ISO-10303-21; A"
     && !bk[B + "Metal/A base.pdf"], Object.keys(bk).filter(k => /Files/.test(k)).join(", "));
  const gone = await q("select rel_path, filed_name, removed_at from parked_files where place = 'job' and project_id = 'PROJ-00418' order by rel_path");
  ok("…every job file came off Supabase once it was in both places; the records stay, with the name it was filed under",
     gone.length === 4 && gone.every(r => r.removed_at) && gone.find(r => r.rel_path === "Metal/A base.pdf").filed_name === "A base r2.pdf"
     && (await q("select count(*) n from storage.objects where bucket_id = 'parked-files' and name like 'PROJ-00418/%'"))[0].n == 0, JSON.stringify(gone));
  const lib1 = await q("select rel_path, held, removed_at, backup_at from parked_files where place = 'library' order by rel_path");
  ok("Library files wait for the third folder (filed in the backup meanwhile), and the save says so",
     lib1.every(r => !r.removed_at && /Claudes Shop System Folder/.test(r.held || "")) && /library files wait for Claudes Shop System Folder/.test(await p.innerText("body")), JSON.stringify(lib1));

  const h501 = (await q("select held, removed_at, backup_at, onedrive_at from parked_files where project_id = 'PROJ-00501'"))[0];
  ok("A job with no OneDrive folder yet: its file goes to the backup folder and waits on Supabase, with the reason",
     bk["PROJ-00501/Production/Files/Other/site plan.pdf"] === "%PDF hotel site plan" && !h501.removed_at && !h501.onedrive_at
     && /Waiting for PROJ-00501's OneDrive folder/.test(h501.held || ""), JSON.stringify(h501));
  await p.evaluate(async () => { const r = await navigator.storage.getDirectory();
    await (await (await r.getDirectoryHandle("od")).getDirectoryHandle("500s", { create: true })).getDirectoryHandle("Proj-00501 Hotel", { create: true }); });

  // 2. the third folder
  await p.evaluate(() => localStorage.setItem("pick", JSON.stringify(["bk"]))); await p.click('[data-savepick="sys"]');
  await p.waitForFunction(() => /has to be its own folder/.test(document.body.innerText));
  ok("The backup folder can't be chosen as Claudes Shop System Folder", true);
  await pick("sys", "sys", "Shop system folder chosen: sys");
  run = await saveNow();
  let sys = await LIST(p, "sys"); bk = await LIST(p, "bk");
  ok("With it chosen: a new library file goes into Database and the backup's Claudes Shop System Folder › Database",
     sys["Database/CNC/Other/Round 36.mpr"] === "round program" && bk["Claudes Shop System Folder/Database/CNC/Other/Round 36.mpr"] === "round program", Object.keys(sys).join(", "));
  ok("…a library file that differs from the one there is not overwritten, and waits with the reason",
     sys["Database/Metal/Cut sheets/SAM 30x60.pdf"] === "%PDF the library's own cut sheet"
     && /different file is already in the library/.test((await q("select held from parked_files where rel_path = 'Metal/Cut sheets/SAM 30x60.pdf'"))[0].held || ""));
  const idx = sys["Database/Database index.csv"] || "";
  const lines = idx.replace(/^\ufeff/, "").trim().split(/\r\n/);
  ok("Database index.csv: a header and one row per file really there (the hand-added one too), with its kind, size and when it changed",
     lines[0] === "path,kind,size,changed" && lines.length === 4 && /^CNC\/KI\/hand\.mpr,KI program,13,\d{4}-\d\d-\d\d \d\d:\d\d$/.test(lines[1])
     && /^CNC\/Other\/Round 36\.mpr,CNC program,13,/.test(lines[2]) && /^Metal\/Cut sheets\/SAM 30x60\.pdf,cut sheet,\d+,/.test(lines[3]), lines.join(" | "));
  ok("…and the library's four folders are there for the Outputs project", await p.evaluate(async () => { let d = await (await navigator.storage.getDirectory()).getDirectoryHandle("sys");
       d = await d.getDirectoryHandle("Database"); for (const s of ["Metal/Cut sheets", "Metal/STEP files", "CNC/KI", "CNC/Other"]) { let x = d; for (const y of s.split("/")) x = await x.getDirectoryHandle(y); } return true; }).catch(() => false));
  od = await LIST(p, "od");
  const h501b = (await q("select held, removed_at from parked_files where project_id = 'PROJ-00501'"))[0];
  ok("…once its folder is there, the next save files it and it comes off Supabase",
     od["500s/Proj-00501 Hotel/Production/Files/Other/site plan.pdf"] === "%PDF hotel site plan" && !!h501b.removed_at && !h501b.held, JSON.stringify(h501b));
  if (hasPo) {
    const pdfName = poRow && poRow.file_name, a = await p.evaluate(async (n) => { const out = {};
      for (const [k, segs] of [["sys", ["sys", "Arrow"]], ["bk", ["bk", "Claudes Shop System Folder", "Arrow"]]]) {
        try { let d = await navigator.storage.getDirectory(); for (const s of segs) d = await d.getDirectoryHandle(s);
              const f = await (await d.getFileHandle(n)).getFile(); out[k] = { size: f.size, head: new TextDecoder().decode((await f.arrayBuffer()).slice(0, 5)) }; } catch (e) { out[k] = null; } }
      return out; }, pdfName);
    ok("The save put the floor's Arrow PO in Claudes Shop System Folder › Arrow and the backup's copy, as a PDF named AR-10(99).pdf",
       pdfName === "AR-10(99).pdf" && a.sys && a.bk && a.sys.head === "%PDF-" && a.sys.size === a.bk.size && a.sys.size > 1000, JSON.stringify(a));
    ok("…and it's recorded as saved in both, so it isn't made again", !!(await q("select onedrive_at is not null and backup_at is not null as y from arrow_pos where name = 'AR-10'"))[0].y);
  }
  ok("Round 36.mpr came off Supabase once in both places", !!(await q("select removed_at from parked_files where rel_path = 'CNC/Other/Round 36.mpr'"))[0].removed_at);

  // 3. Luke says replace it
  const sam = (await q("select id from parked_files where rel_path = 'Metal/Cut sheets/SAM 30x60.pdf'"))[0].id;
  const ok1 = await luke.rpc("parked_replace_ok", { p_id: sam });
  run = await saveNow();
  sys = await LIST(p, "sys");
  ok("Once Luke says replace it, the next save puts the new one in the library, and it comes off Supabase",
     !ok1.error && sys["Database/Metal/Cut sheets/SAM 30x60.pdf"] === "%PDF cut sheet from the zip" && !!(await q("select removed_at from parked_files where id = $1", [sam]))[0].removed_at);
  ok("…and the index shows its new size", (sys["Database/Database index.csv"] || "").includes(`Metal/Cut sheets/SAM 30x60.pdf,cut sheet,${"%PDF cut sheet from the zip".length},`));

  // the office's Arrow tab: the PO details and the list, with the PDF
  if (hasPo) {
    await p.click('[data-tab="arrow"]'); await p.waitForSelector("[data-posave]", { state: "attached", timeout: 15000 });
    ok("Office › Arrow: Arrow POs lists AR-10 (saved in the Arrow folder) with its PDF", /AR-10/.test(await p.innerText("main")) && /saved in the Arrow folder/.test(await p.innerText("main")) && !!(await p.$("[data-popdf]")));
    const [dl] = await Promise.all([p.waitForEvent("download", { timeout: 10000 }).catch(() => null), p.click("[data-popdf]")]);
    ok("…its PDF downloads under the PO's own file name", dl && dl.suggestedFilename() === "AR-10(99).pdf", dl ? dl.suggestedFilename() : "no download");
    await p.evaluate(() => { document.querySelector("details:has([data-posave])").open = true; }); await p.fill("#poPhone", "317-000-0000"); await p.click("[data-posave]"); await p.waitForTimeout(1200);
    ok("…the PO details save from the office (kept in the database)", (await q("select phone from arrow_po_settings"))[0].phone === "317-000-0000");
    await p.evaluate(() => { document.querySelector("details:has([data-posave])").open = true; }); await p.fill("#poNext", "5"); await p.click("[data-posave]"); await p.waitForTimeout(1200);
    ok("…and the next number can't go back to one already used", (await q("select next_number from arrow_po_settings"))[0].next_number === 11 && /already used/.test(await p.innerText("main")));
    await p.click('[data-tab="photos"]'); await p.waitForSelector("[data-savenow]");
  }

  // 4. nothing new
  run = await saveNow();
  ok("A save with nothing new writes nothing (the index is unchanged)", run.files_written === 0 && run.onedrive_ok && run.backup_ok, `${run.files_written} written`);
  ok("No page errors", !errs.length, errs.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
