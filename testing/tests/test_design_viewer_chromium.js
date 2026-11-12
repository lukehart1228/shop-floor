// 1 Nov: the 3D design viewer (design_viewer.sql, sf-3d-viewer.js, drop.html, index.html, office.html) in real Chromium
// with real WebGL (SwiftShader), the real STEP engine (occt-import-js 0.0.23) and three.js 0.147.0, served in place of
// jsDelivr with the hashes the pages pin. Luke drops a format 2 zip for PROJ-00418 whose Design/ folder holds the engine's
// own sample STEP files: a 1,000 mm cube (TB-03), an 18-part assembly (TB-04) and a file that isn't a STEP (TB-06). The
// drop makes the views on his "PC", says why one couldn't be made, and lets him turn one upright. Eric (Full Custom +
// Assembly / QC) opens them from his sheets, turns, measures (corners snap; a hidden corner is never picked through the
// shape), hides a part, and opens one again with no signal. A model whose view wasn't made (the engine was out of reach at
// the drop) is made on his tablet from its parked STEP, then by Luke's Make it again. Mike (Sanding) gets no button and the
// database gives him no rows. The office's job page has a 3D button per sheet row. OLDDB=1: a database without
// design_viewer.sql: no buttons and no errors anywhere.
//   fresh seed; OUT=<folder with the new pages> PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_design_viewer_chromium.js
// Needs the two libraries and the engine's sample files; on first run it fetches them (npm and GitHub, both allowed).
const fs = require("fs"), http = require("http"), path = require("path");
const { execSync } = require("child_process");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo", LIBS = "/home/claude/sf/steplibs", OLDDB = process.env.OLDDB === "1";
const SHOTS = process.env.SHOTS || "";                 // a folder: screenshots for a look before handing over (not part of the score)
const shot = async (p, name) => { if (SHOTS) { fs.mkdirSync(SHOTS, { recursive: true }); await p.screenshot({ path: `${SHOTS}/${name}.png` }); } };
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const q = async (sql, a = []) => (await admin.query(sql, a)).rows;

// ---- the libraries and sample files, once (the same as test_step_chromium) ----
if (!fs.existsSync(`${LIBS}/node_modules/occt-import-js/dist/occt-import-js.wasm`) || !fs.existsSync(`${LIBS}/node_modules/three/build/three.min.js`)) {
  fs.mkdirSync(LIBS, { recursive: true });
  execSync(`npm install --prefix ${LIBS} --no-audit --no-fund occt-import-js@0.0.23 three@0.147.0`, { stdio: "ignore" });
}
const SAMPLES = `${LIBS}/samples`;
if (!fs.existsSync(`${SAMPLES}/as1-oc-214.stp`) || !fs.existsSync(`${SAMPLES}/rounded-cube.step`)) {
  fs.mkdirSync(SAMPLES, { recursive: true });
  const raw = "https://raw.githubusercontent.com/kovacsv/occt-import-js/main/test/testfiles/";
  for (const [p, n] of [["cube-units/cube-mm.step", "cube-mm.step"], ["cube-units/cube-in.step", "cube-in.step"],
                        ["rounded-cube/rounded-cube.step", "rounded-cube.step"], ["cax-if/as1-oc-214.stp", "as1-oc-214.stp"]])
    execSync(`curl -sfL -o "${SAMPLES}/${n}" "${raw}${p}"`);
}
const NM = `${LIBS}/node_modules`;
const CDN = { "three@0.147.0/build/three.min.js": `${NM}/three/build/three.min.js`,
              "three@0.147.0/examples/js/controls/OrbitControls.js": `${NM}/three/examples/js/controls/OrbitControls.js`,
              "occt-import-js@0.0.23/dist/occt-import-js.js": `${NM}/occt-import-js/dist/occt-import-js.js`,
              "occt-import-js@0.0.23/dist/occt-import-js.wasm": `${NM}/occt-import-js/dist/occt-import-js.wasm` };

// ---- the zips, made as the Outputs project makes them (Python's zipfile, deflated) ----
const ZIPS = "/tmp/zips3d";
execSync(`rm -rf ${ZIPS} && mkdir -p ${ZIPS}`);
fs.writeFileSync(`${ZIPS}/make.py`, `
import json, zipfile, sys, os
def make(name, files, job="PROJ-00418"):
    entries = []
    for path, src, item in files:
        b = open(src, "rb").read() if os.path.exists(src) else src.encode()
        entries.append((path, b, {"path": path, "what": "3D model", "bytes": len(b), "item": item}))
    c = {"kind": "shop-floor-zip", "format": 2, "job": job, "made_at": "2026-11-01T14:05:00-05:00", "files": [e for _, _, e in entries]}
    with zipfile.ZipFile(os.path.join("${ZIPS}", name), "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("contents.json", json.dumps(c, indent=1))
        for path, b, _ in entries: z.writestr(path, b)
S = "${SAMPLES}"
make("PROJ-00418-3d.zip", [("Design/TB-03 table.step", S + "/cube-mm.step", "TB-03"), ("Design/TB-04 assembly.stp", S + "/as1-oc-214.stp", "TB-04"),
                           ("Design/TB-06 broken.step", "ISO-10303-21; this is not a shape at all\\n", "TB-06")])
make("PROJ-00418-later.zip", [("Design/TB-01 rounded.step", S + "/rounded-cube.step", "TB-01")])
make("PROJ-00418-again.zip", [("Design/WMT-DAN-DIN.step", S + "/cube-in.step", "WMT-DAN-DIN")])
`);
execSync(`python3 ${ZIPS}/make.py`);

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  const b64 = async (blob) => { const u = new Uint8Array(await blob.arrayBuffer()); let s = ""; for (let i = 0; i < u.length; i += 8192) s += String.fromCharCode.apply(null, u.subarray(i, i + 8192)); return btoa(s); };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => { session = null; return {}; }, onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (bucket) => ({
      upload: async (path, body, opts) => call({ kind: "storage", op: "upload", bucket, path, b64: await b64(body),   // the type supabase-js really sends: a Blob as its own type, anything else as contentType (2 Nov)
        opts: Object.assign({}, opts, { contentType: (typeof Blob !== "undefined" && body instanceof Blob) ? (body.type || "application/octet-stream") : ((opts && opts.contentType) || "text/plain;charset=UTF-8") }) }),
      download: async (path) => { const r = await call({ kind: "storage", op: "download", bucket, path });
        if (r.error) return { data: null, error: r.error }; const bin = atob(r.b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { data: new Blob([u], { type: r.type }), error: null }; },
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      remove: async (paths) => call({ kind: "storage", op: "remove", bucket, paths }) }) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".css") ? "text/css" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});
async function session(browser, user, opts = {}) {
  const client = makeClient(user), st = { offline: false, tables: [], noEngine: !!opts.noEngine };
  const ctx = opts.ctx || await browser.newContext({ viewport: opts.viewport || { width: 1280, height: 900 }, serviceWorkers: "block", hasTouch: !!opts.touch });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (st.offline) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    if (m.kind === "storage") {
      const sb = client.storage.from(m.bucket);
      if (m.op === "upload") return JSON.parse(JSON.stringify(await sb.upload(m.path, Buffer.from(m.b64, "base64"), m.opts || {})));
      if (m.op === "remove") return JSON.parse(JSON.stringify(await sb.remove(m.paths)));
      const r = await sb.download(m.path); if (r.error) return { data: null, error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), type: r.data.type, error: null };
    }
    st.tables.push(m.t);
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net\/npm\//, (r) => {
    const url = r.request().url();
    if (/supabase-js@2\.45\.4/.test(url)) return r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } });
    const key = url.split("/npm/")[1], f = CDN[key];
    if (!f || (st.noEngine && /occt/.test(key))) return r.abort();
    r.fulfill({ body: fs.readFileSync(f), contentType: f.endsWith(".wasm") ? "application/wasm" : "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } });
  });
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, st, errs, client };
}
const appText = (p) => p.evaluate(() => (document.querySelector("#app") || document.body).innerText.replace(/\s+/g, " "));
const viewerState = (p) => p.evaluate(() => { const V = window.SF3D && window.SF3D.viewer(); const s = V && V.state;
  return s && { up: s.up, parts: s.parts.length, hidden: s.parts.filter(x => !x.grp.visible).length, size: s.view && s.view.size, pts: s.pts.map(x => ({ p: x.p, loose: x.loose })), measuring: s.measuring }; });
const shaded = (p) => p.evaluate(() => { const c = document.querySelector(".d3-stage canvas"); if (!c) return -1;
  const gl = c.getContext("webgl2") || c.getContext("webgl"); const px = new Uint8Array(4 * 60 * 60);
  gl.readPixels(Math.floor(c.width / 2) - 30, Math.floor(c.height / 2) - 30, 60, 60, gl.RGBA, gl.UNSIGNED_BYTE, px);
  let n = 0; for (let i = 0; i < px.length; i += 4) if (Math.abs(px[i] - 0xEF) + Math.abs(px[i + 1] - 0xED) + Math.abs(px[i + 2] - 0xE6) > 30) n++; return n; });
/** tap a model point (inches, the model's own axes): off = pixels away from it (dx, dy) */
async function tapAt(p, pt, dx = 0, dy = 0) { const s = await p.evaluate((pt) => window.SF3D.viewer().screenOf(pt), pt); await p.mouse.click(s.x + dx, s.y + dy); await sleep(200); }

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const browser = await chromium.launch({ args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
  const has = (await q("select to_regclass('public.item_designs') is not null as h"))[0].h;
  console.log(has ? "(database with design_viewer.sql)" : "(database WITHOUT design_viewer.sql: the new pages on the old database)");

  /** a department with a stage before it lists only what's ready: All shows every job */
  const showAll = async (p) => { await sleep(500); if (await p.$('[data-qmode="all"]')) { await p.click('[data-qmode="all"]'); await sleep(300); } };
  // ---------- Eric's tablet: sign in, Assembly / QC, PROJ-00418, a sheet ----------
  async function ericTo(E, sheetNo, { dept = true } = {}) {
    await E.p.waitForFunction(() => document.querySelector(".subtabs") || document.querySelector(".head") || document.querySelector(".qhead"), null, { timeout: 20000 });
    if (dept && (await E.p.getAttribute('header [data-dept="assembly_qc"]', "aria-current").catch(() => null)) !== "true") {   // his department tabs
      await E.p.click('header [data-dept="assembly_qc"]'); await sleep(800);
    }
    await showAll(E.p);
    await E.p.waitForFunction(() => [...document.querySelectorAll("[data-job]")].some(b => /PROJ-00418/.test(b.innerText)), null, { timeout: 20000 })
      .catch(async (e) => { console.log("      (Eric's screen: " + (await appText(E.p)).slice(0, 600) + ")"); throw e; });
    await E.p.evaluate(() => [...document.querySelectorAll("[data-job]")].find(b => /PROJ-00418/.test(b.innerText)).click());
    await E.p.waitForSelector("[data-sheet]");
    await E.p.evaluate((n) => [...document.querySelectorAll("[data-sheet]")].find(b => b.querySelector(".no") && b.querySelector(".no").innerText.trim() === String(n)).click(), sheetNo);
    await E.p.waitForSelector("[data-print]");
  }
  const waitBtn = (p) => p.waitForSelector("[data-d3]", { timeout: 15000 }).then(() => true).catch(() => false);
  const openD3 = async (p) => { await p.click("[data-d3]"); await p.waitForFunction(() => ((document.getElementById("d3from") || {}).innerText || "").length > 3
      || !!document.querySelector("#d3host [data-d3err]"), null, { timeout: 120000 }); await sleep(400); };
  const actions = (p) => p.evaluate(() => document.querySelector(".actions").innerText.replace(/\s+/g, " ").trim());

  if (!has) {
    const E = await session(browser, users.eric, { touch: true });
    await E.p.goto(base + "index.html"); await ericTo(E, 1);
    await sleep(1500);
    ok("Older database: Eric's sheet has Print and Open the PDF, and no 3D design button", !(await E.p.$("[data-d3]")) && !!(await E.p.$("[data-pdf]")));
    ok("…and the tablet never asks for the 3D models table", !E.st.tables.includes("item_designs"), E.st.tables.join(","));
    ok("…no page errors", !E.errs.length, E.errs.join(" | "));
    const L = await session(browser, users.luke);
    await L.p.goto(base + "office.html");
    await L.p.waitForSelector('header.top [data-tab="jobs"]', { timeout: 20000 }); await L.p.click('header.top [data-tab="jobs"]');   // 11 Nov: Jobs
    await L.p.waitForSelector("[data-jobfind]", { timeout: 20000 }); await L.p.fill("[data-jobfind]", "PROJ-00418"); await sleep(500); await L.p.press("[data-jobfind]", "Enter");
    await L.p.waitForFunction(() => /Progress by sheet|Items, by department/i.test(document.body.innerText), null, { timeout: 20000 }); await sleep(500);
    ok("Older database: the office's job page has no 3D buttons, and no errors", !(await L.p.$("[data-d3]")) && /Sheet 1/.test(await appText(L.p)) && !L.errs.length, L.errs.join(" | "));
    console.log(`\n${pass} passed, ${fail} failed`); await browser.close(); server.close(); process.exit(fail ? 1 : 0);
  }

  // ---------- 1. Luke drops the zip; the views are made on his PC ----------
  await q("select lab_allow('luke@example.com')");
  const L = await session(browser, users.luke), lp = L.p;
  await lp.goto(base + "drop.html"); await lp.waitForSelector("#dropArea:not([hidden])", { timeout: 15000 });
  await lp.waitForFunction(() => !/Loading/.test(document.getElementById("d3list").innerText), null, { timeout: 15000 });
  ok("The drop page has a 3D views card: none yet", /None yet/.test(await lp.textContent("#d3list")));
  const drop = async (name) => { await lp.setInputFiles("#pick", path.join(ZIPS, name));
    await lp.waitForFunction(() => /Here’s what Send does|wasn’t used/.test(document.querySelector("#out").textContent), null, { timeout: 15000 }); return lp.textContent("#out"); };
  const send = async () => { await lp.click("#send");
    await lp.waitForFunction(() => /parked for the save|wasn’t used/.test((document.querySelector("#result") || document.querySelector("#out")).textContent), null, { timeout: 180000 }); await sleep(300); return lp.textContent("#out"); };
  let t = await drop("PROJ-00418-3d.zip");
  ok("The plan says each 3D model is made into a 3D view on this PC (Fine, Z up to start) and filed", /3D models/.test(t) && /TB-03, TB-04, TB-06: each made into a 3D view on this PC/.test(t) && /Fine detail, Z up to start/.test(t));
  const t0 = Date.now(); t = await send(); const sendMs = Date.now() - t0;
  const rows = await q("select item, status, view_path, step_sha256, view_bytes, size_in::float8[] as size, parts, triangles, convert_ms, failed_why, up from item_designs where project_id = 'PROJ-00418' order by item");
  const r3 = rows.find(r => r.item === "TB-03") || {}, r4 = rows.find(r => r.item === "TB-04") || {}, r6 = rows.find(r => r.item === "TB-06") || {};
  ok("Send makes the cube's view: 39.370 × 39.370 × 39.370 in, 1 part, ready", r3.status === "ready" && r3.size && r3.size.every(x => Math.abs(x - 39.3701) < 0.0005) && r3.parts === 1
     && /TB-03.*39\.370 × 39\.370 × 39\.370 in · 1 part/.test(t) && /Made/.test(t), JSON.stringify(r3).slice(0, 300));
  ok("…and the 18-part assembly's", r4.status === "ready" && r4.parts === 18 && r4.triangles > 1000 && /TB-04.*18 parts/.test(t), `${r4.parts} parts, ${r4.triangles} triangles, ${r4.convert_ms} ms`);
  ok("…a file that isn't a STEP: Not made, with the reason in words, kept for later; the rest of the drop is Done", r6.status === "failed" && /couldn.t be read as a STEP file/.test(r6.failed_why || "")
     && /Not made/.test(t) && /It couldn’t be made: it couldn't be read as a STEP file/.test(t) && /Done/.test(t), r6.failed_why);
  const objs = await q("select name, (metadata->>'size')::int as size from storage.objects where bucket_id = 'design-views' order by name");
  ok("The two view files are in the design-views storage, named by their STEP's fingerprint, at the size recorded", objs.length === 2
     && objs.every(o => rows.some(r => r.view_path === o.name && r.view_bytes === o.size)) && objs.every(o => /^PROJ-00418\/[0-9a-f]{64}\.fine\.view\.json\.gz$/.test(o.name)), JSON.stringify(objs));
  console.log(`      (in this sandbox: Send took ${(sendMs / 1000).toFixed(1)} s with the engine's first download; the cube converted in ${r3.convert_ms} ms, the assembly in ${r4.convert_ms} ms; view files ${objs.map(o => Math.round(o.size / 1024) + " KB").join(" and ")})`);
  ok("The drop's record lists the 3D views", (await q("select summary->'designs' as d from zip_drops order by dropped_at desc limit 1"))[0].d.length === 3);
  // 4 Nov: the list folds away, closed to start; its line says how many and how many weren't made (Luke)
  await lp.waitForFunction(() => /3 3D views/.test(document.querySelector("#d3list details.fold summary")?.textContent || ""), null, { timeout: 10000 });
  ok("The 3D views list starts folded, its line saying 3 3D views and 1 not made", await lp.$eval("#d3list details.fold", d => !d.open && /3 3D views/.test(d.querySelector("summary").textContent) && /1 not made/.test(d.querySelector("summary").textContent))
     && !(await lp.isVisible("#d3list [data-d3look]")));
  await lp.click("#d3list details.fold > summary");
  await lp.waitForFunction(() => /TB-04/.test(document.getElementById("d3list").innerText), null, { timeout: 10000 });
  t = await lp.textContent("#d3list");
  ok("The 3D views card lists them: two Ready with their size, one Not made with its reason and Make it again", (t.match(/Ready/g) || []).length === 2 && /Not made/.test(t)
     && /couldn.t be read/.test(t) && !!(await lp.$("#d3list [data-d3make]")), t.slice(0, 300));

  // ---------- 2. Luke looks at the assembly and turns it upright ----------
  const id4 = (await q("select id from item_designs where project_id = 'PROJ-00418' and item = 'TB-04'"))[0].id;
  await lp.click(`#d3list [data-d3look="${id4}"]`);
  await lp.waitForSelector("#d3host .d3-stage canvas", { timeout: 60000 }); await sleep(800);
  let vs = await viewerState(lp);
  ok("Look opens it here: 18 parts, Z up (the shop's start, as Luke's Fusion designs are drawn), the Up box shown", vs && vs.parts === 18 && vs.up === "z" && await lp.isVisible(".d3-up select"), JSON.stringify(vs));
  ok("…drawn (the middle of the view isn't empty)", (await shaded(lp)) > 200);
  await shot(lp, "drop-look");
  await lp.selectOption(".d3-up select", "y"); await sleep(800);
  ok("Changing Up to Y turns it and saves it for the tablets", (await viewerState(lp)).up === "y" && (await q("select up from item_designs where id = $1", [id4]))[0].up === "y"
     && /Saved: Y is up\./.test(await lp.textContent("#d3say")));
  await lp.selectOption(".d3-up select", "z"); await sleep(800);
  ok("…and back to Z, saved", (await viewerState(lp)).up === "z" && (await q("select up from item_designs where id = $1", [id4]))[0].up === "z" && /Saved: Z is up/.test(await lp.textContent("#d3say")));

  // ---------- 3. the same zip again: what's made stays; the broken one is tried again ----------
  t = await drop("PROJ-00418-3d.zip"); t = await send();
  const rows2 = await q("select item, status, superseded_at from item_designs where project_id = 'PROJ-00418' order by item, registered_at");
  ok("The same zip again: the cube and the assembly are Unchanged, kept (no new rows); the broken file is still Not made", rows2.length === 3 && rows2.every(r => !r.superseded_at)
     && (t.match(/Unchanged, kept/g) || []).length === 2 && /Not made/.test(t), JSON.stringify(rows2));
  ok("…and the assembly keeps Luke's Z", (await q("select up from item_designs where id = $1", [id4]))[0].up === "z");
  // the measuring checks below were written for the sample cube drawn Y up: Luke turns it to Y, as he would at the drop
  await q("update item_designs set up = 'y' where project_id = 'PROJ-00418' and item = 'TB-03' and superseded_at is null");

  // ---------- 4. a zip dropped when the STEP engine couldn't be reached ----------
  const L2 = await session(browser, users.luke, { noEngine: true });
  await L2.p.goto(base + "drop.html"); await L2.p.waitForSelector("#dropArea:not([hidden])", { timeout: 15000 });
  await L2.p.setInputFiles("#pick", path.join(ZIPS, "PROJ-00418-later.zip"));
  await L2.p.waitForFunction(() => /Here’s what Send does/.test(document.querySelector("#out").textContent), null, { timeout: 15000 });
  await L2.p.click("#send"); await L2.p.waitForFunction(() => /parked for the save/.test(document.querySelector("#out").textContent), null, { timeout: 60000 });
  const r1 = (await q("select id, status, failed_why, step_path from item_designs where project_id = 'PROJ-00418' and item = 'TB-01'"))[0] || {};
  ok("A drop with the STEP engine out of reach: TB-01's view Not made (the engine couldn't be downloaded), its STEP parked", r1.status === "failed" && /STEP engine couldn.t be downloaded/.test(r1.failed_why || "")
     && !!r1.step_path && /Done/.test(await L2.p.textContent("#out")), r1.failed_why);
  await L2.ctx.close();

  // ---------- 5. Eric's tablet ----------
  const E = await session(browser, users.eric, { touch: true, viewport: { width: 1280, height: 800 } }), ep = E.p;
  await ep.goto(base + "index.html"); await ericTo(E, 1);
  ok("Eric (Full Custom + Assembly / QC), on Assembly / QC: sheet 1 (TB-03) has a 3D design button beside Print and Open the PDF", await waitBtn(ep)
     && /Print this sheet Open the PDF 3D design/.test(await actions(ep)));
  await openD3(ep);
  vs = await viewerState(ep);
  t = await appText(ep);
  ok("3D design opens it inside the app: the cube, Overall 39.370 × 39.370 × 39.370 in, X × Y × Z", vs && vs.parts === 1 && /Overall 39\.370 × 39\.370 × 39\.370 in/.test(t) && /3D design · TB-03/.test(t), JSON.stringify(vs));
  ok("…downloaded once and kept on this tablet; no Up box (the office and the drop turn designs)", /Downloaded \(\d+ KB\) and kept on this tablet/.test(t) && !(await ep.isVisible(".d3-up select")));
  ok("…drawn in the brand's neutral tone (the middle of the view is shaded)", (await shaded(ep)) > 200);
  // measuring: corners snap; a tap just off the outline still finds its corner; a hidden corner is never picked through the shape
  const box = await ep.evaluate(() => ({ min: window.SF3D.viewer().state.view.min, max: window.SF3D.viewer().state.view.max }));
  const [x0, y0, z0] = box.min, [x1, y1, z1] = box.max;
  await ep.click('[data-d3t="measure"]'); await sleep(200);
  ok("Measure: the hint says to tap a corner", /Tap a corner or edge to start measuring/.test(await ep.innerText(".d3-hint")) && (await viewerState(ep)).measuring);
  const outward = await ep.evaluate(([a, c]) => { const V = window.SF3D.viewer(), s = V.screenOf(a), m = V.screenOf(c), d = Math.hypot(s.x - m.x, s.y - m.y); return [(s.x - m.x) / d * 7, (s.y - m.y) / d * 7]; },
    [[x1, y0, z1], [(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2]]);
  await tapAt(ep, [x1, y0, z1], outward[0], outward[1]);
  vs = await viewerState(ep);
  ok("A tap 7 px off the outline, outside the shape, snaps to the corner it was meant for", vs.pts.length === 1 && !vs.pts[0].loose
     && vs.pts[0].p.every((v, k) => Math.abs(v - [x1, y0, z1][k]) < 1e-3), JSON.stringify(vs.pts));
  await tapAt(ep, [x1, y1, z1], 3, -2);
  vs = await viewerState(ep); t = await appText(ep);
  ok("The next corner along the edge: 39.370 in (≈ 39 3/8\"), across Y", vs.pts.length === 2 && !vs.pts[1].loose && /39\.370 in \(≈ 39 3\/8"\)/.test(t) && /Y 39\.370/.test(t), JSON.stringify(vs.pts));
  await tapAt(ep, [x1, y0, z1], 0, 0); await tapAt(ep, [x1, y1, z1], 0, 0); await shot(ep, "tablet-measure");
  await ep.click('[data-d3t="clear"]'); await sleep(150);
  await tapAt(ep, [x0, y0, z0], 0, 0);
  vs = await viewerState(ep);
  ok("A tap right on the corner hidden behind the cube never picks it: no point, and it says that corner is on the far side", vs.pts.length === 0
     && /That corner is on the far side\. Turn the model to see it\./.test(await ep.innerText(".d3-note")), JSON.stringify(vs.pts));
  await tapAt(ep, [x1, (y0 + y1) / 2, (z0 + z1) / 2], 0, 0); await tapAt(ep, [x1, y1, z1], 0, 0);
  vs = await viewerState(ep);
  ok("A tap in the middle of a face, nothing in reach, takes the point on the surface, and the measurement says it's approximate", vs.pts.length === 2 && vs.pts[0].loose
     && /approximate/.test(await ep.innerText(".d3-meas")), JSON.stringify(vs.pts));
  await ep.click('[data-d3t="clear"]'); await sleep(150);
  await tapAt(ep, [x1, y0 + (y1 - y0) * 0.4, z1], 3, 0);
  vs = await viewerState(ep);
  ok("A tap on the middle of an edge snaps onto the edge itself, not just its ends", vs.pts.length === 1 && !vs.pts[0].loose && Math.abs(vs.pts[0].p[0] - x1) < 1e-3
     && Math.abs(vs.pts[0].p[2] - z1) < 1e-3 && Math.abs(vs.pts[0].p[1] - (y0 + (y1 - y0) * 0.4)) < 1.5, JSON.stringify(vs.pts));
  await tapAt(ep, [x1, y0 + (y1 - y0) * 0.7, z0], 3, 0);
  vs = await viewerState(ep);
  ok("A second tap on the parallel edge measures square across: 39.370 in, said so", vs.pts.length === 2 && Math.abs(vs.pts[1].p[1] - vs.pts[0].p[1]) < 1e-3
     && /39\.370 in/.test(await ep.innerText(".d3-meas")) && /Measured square across to that edge/.test(await ep.innerText(".d3-meas")), JSON.stringify(vs.pts));
  await ep.click('[data-d3t="clear"]'); await sleep(150);
  ok("Clear takes the points away", (await viewerState(ep)).pts.length === 0 && !(await ep.isVisible(".d3-meas")));
  // a table drawn here (a top over aprons, as Fusion would export it, with a colour per part and one face of its own):
  // the apron's top edge is hidden under the top's overhang from the usual view (Luke, 1 Nov: "the top grabs something random")
  const tbl = await ep.evaluate(() => {
    const box = (name, x0, y0, z0, x1, y1, z1, color, faceColors) => {
      const faces = [[[x0,y0,z1],[x1,y0,z1],[x1,y1,z1],[x0,y1,z1]], [[x1,y0,z0],[x0,y0,z0],[x0,y1,z0],[x1,y1,z0]], [[x1,y0,z1],[x1,y0,z0],[x1,y1,z0],[x1,y1,z1]],
                     [[x0,y0,z0],[x0,y0,z1],[x0,y1,z1],[x0,y1,z0]], [[x0,y1,z1],[x1,y1,z1],[x1,y1,z0],[x0,y1,z0]], [[x0,y0,z0],[x1,y0,z0],[x1,y0,z1],[x0,y0,z1]]];
      const pos = [], idx = [], brep_faces = [];
      faces.forEach((f, i) => { const b = pos.length / 3; f.forEach(q => pos.push(...q)); idx.push(b, b + 1, b + 2, b, b + 2, b + 3);
        brep_faces.push({ first: i * 2, last: i * 2 + 1, color: faceColors && faceColors[i] || null }); });
      return { name, color, attributes: { position: { array: pos } }, index: { array: idx }, brep_faces };
    };
    const wood = [0.55, 0.36, 0.2], steel = [0.3, 0.32, 0.36];
    const view = window.SF3D.readView(window.SF3D.buildView({ meshes: [box("Top", 0, 28.5, 0, 72, 30, 36, wood, { 4: [0.62, 0.42, 0.25] }),
      box("Leg 1", 2, 0, 2, 5, 28.5, 5, steel), box("Leg 2", 67, 0, 2, 70, 28.5, 5, steel), box("Leg 3", 2, 0, 31, 5, 28.5, 34, steel), box("Leg 4", 67, 0, 31, 70, 28.5, 34, steel),
      box("Apron", 5, 24.5, 32, 67, 28.5, 33, wood)],
      root: { name: "", children: [{ name: "Table", meshes: [0], children: [{ name: "Base", meshes: [1, 2, 3, 4, 5] }] }] } },
      { name: "table", file: "table.step", bytes: 1, detail: "fine", convert_ms: 1, up: "y", made_at: "" }));
    window.SF3D.viewer().show(view, { up: "y" });
    const P = window.SF3D.viewer().state.parts, hex = (c) => [c.r, c.g, c.b].map(v => +v.toFixed(2));
    const top = P[0].mesh, col = top.geometry.getAttribute("color");
    return { leg: hex(P[1].mesh.material.color), apron: hex(P[5].mesh.material.color), topVertex: col ? [col.getX(16), col.getY(16), col.getZ(16)].map(v => +v.toFixed(2)) : null,
             topSide: col ? [col.getX(0), col.getY(0), col.getZ(0)].map(v => +v.toFixed(2)) : null, faceColors: view.parts[0].face_colors };
  });
  ok("Fusion's colours: each part as the file says (steel legs, wooden apron), and a face with its own colour keeps it (the top's top face)", JSON.stringify(tbl.leg) === "[0.3,0.32,0.36]"
     && JSON.stringify(tbl.apron) === "[0.55,0.36,0.2]" && JSON.stringify(tbl.topVertex) === JSON.stringify([0.62, 0.42, 0.25]) && JSON.stringify(tbl.topSide) === JSON.stringify([0.55, 0.36, 0.2])
     && Array.isArray(tbl.faceColors) && tbl.faceColors.length === 1, JSON.stringify(tbl));
  await tapAt(ep, [36, 26.5, 33], 0, 0);
  ok("Measure off, a tap on the apron outlines it and shows its size: 62.000 × 4.000 × 1.000 in, Apron", /62\.000 × 4\.000 × 1\.000 in\s*Apron/.test(await ep.innerText(".d3-meas"))
     && await ep.evaluate(() => window.SF3D.viewer().state.parts[5].lines.material.color.getHex() === 0xED5E0F), await ep.innerText(".d3-meas").catch(() => ""));
  await ep.click('[data-d3t="measure"]'); await sleep(150);
  ok("…Measure takes the part's size away (and its outline)", !(await ep.isVisible(".d3-meas")) && await ep.evaluate(() => window.SF3D.viewer().state.parts[5].lines.material.color.getHex() === 0x181D2E));
  await tapAt(ep, [5, 28.5, 5], 0, 0);
  vs = await viewerState(ep);
  ok("A back leg's top corner, out of sight under the top: no guessed point; it says the corner is behind Top and offers to hide it", vs.pts.length === 0
     && /That corner is behind Top\. Turn the model to see it, or/.test(await ep.innerText(".d3-note")) && !!(await ep.$('.d3-note [data-d3hide="0"]')), JSON.stringify(vs.pts));
  await ep.click('.d3-note [data-d3hide="0"]'); await sleep(200);
  vs = await viewerState(ep);
  ok("Hide Top: the top is hidden (and unticked under Parts), and it says to tap again", vs.hidden === 1 && !(await ep.isChecked('.d3-plist [data-d3part="0"]'))
     && /Top is hidden\. Tap the point again/.test(await ep.innerText(".d3-note")));
  await tapAt(ep, [50, 24.5, 33], 0, 0); await tapAt(ep, [58, 28.5, 33], 0, 0);
  vs = await viewerState(ep);
  ok("Then the apron's bottom edge and top edge, taps not lined up: 4.000 in square across, both on their edges", vs.pts.length === 2 && !vs.pts[0].loose && !vs.pts[1].loose
     && /4\.000 in \(4"\)/.test(await ep.innerText(".d3-meas")) && /Measured square across/.test(await ep.innerText(".d3-meas")) && Math.abs(vs.pts[1].p[0] - vs.pts[0].p[0]) < 1e-3
     && Math.abs(vs.pts[1].p[2] - 33) < 1e-3, JSON.stringify(vs.pts));
  await shot(ep, "tablet-apron");
  // Hide and Isolate (Luke, 1 Nov: cabinets have many bodies; a door is a body): the Base component (legs and apron)
  await ep.click('[data-d3t="all"]'); await sleep(150);
  ok("Show all (1 hidden) brings the top back", (await viewerState(ep)).hidden === 0 && !(await ep.isVisible('[data-d3t="all"]')));
  await ep.click('[data-d3t="measure"]'); await sleep(150);
  await tapAt(ep, [36, 26.5, 33], 0, 0);
  let card = await ep.innerText(".d3-meas");
  const cardHas = async (k) => !!(await ep.$(`.d3-meas [data-d3do="${k}"]`));
  ok("Tapping the apron: its size, that it's in Base, Zoom, Hide, Isolate and See through for it, and Hide, Isolate and See through for Base (5 parts)", /in Base/.test(card)
     && /Base \(5 parts\):/.test(card) && await cardHas("zoom:5") && await cardHas("hide:5") && await cardHas("iso:5") && await cardHas("ghost:5")
     && await cardHas("hidec:5") && await cardHas("isoc:5") && await cardHas("ghostc:5"), card.replace(/\s+/g, " "));
  await ep.click('.d3-meas [data-d3do="isoc:5"]'); await sleep(200);
  vs = await viewerState(ep);
  ok("Isolate Base: only the five base parts show, and Show all (1 hidden) appears", vs.hidden === 1 && /Show all \(1 hidden\)/.test(await ep.innerText('[data-d3t="all"]')), JSON.stringify(vs));
  const corner = await ep.evaluate(() => { const r = document.querySelector(".d3-stage canvas").getBoundingClientRect(); return [r.left + 12, r.top + r.height - 12]; });
  await ep.mouse.click(corner[0], corner[1], { button: "right" }); await sleep(200);
  ok("A right-click off the model: a menu with just Show all (1 hidden)", (await ep.isVisible(".d3-menu")) && (await ep.innerText(".d3-menu")).trim() === "Show all (1 hidden)", await ep.innerText(".d3-menu").catch(() => ""));
  await ep.click('.d3-menu [data-d3do="all:0"]'); await sleep(200);
  ok("…which shows everything again and closes the menu", (await viewerState(ep)).hidden === 0 && !(await ep.isVisible(".d3-menu")));
  // Seeing it better (Luke, 1 Nov): standard views, Flat, a section cut, see-through, explode, zoom to a part
  const V3 = (f, a) => ep.evaluate(f, a);
  const dirNow = () => V3(() => { const V = window.SF3D.viewer(), c = V.cam(); return c.position.clone().sub(V.controls.target).normalize().toArray().map(v => +v.toFixed(4)); });
  const pressed = async (sel) => (await ep.getAttribute(sel, "aria-pressed")) === "true";
  await ep.click('[data-d3v="front"]'); await sleep(150); let dn = await dirNow();
  ok("Front: the camera looks straight at the front (from +Z), and Front shows pressed", dn[2] > 0.9999 && await pressed('[data-d3v="front"]') && !(await pressed('[data-d3v="iso"]')), JSON.stringify(dn));
  await ep.click('[data-d3v="top"]'); await sleep(150); dn = await dirNow();
  ok("Top: from straight above", dn[1] > 0.9999, JSON.stringify(dn));
  await ep.click('[data-d3v="side"]'); await sleep(150); dn = await dirNow();
  ok("Side: from the right (+X)", dn[0] > 0.9999, JSON.stringify(dn));
  await ep.click('[data-d3v="front"]'); await sleep(150); await ep.click('[data-d3t="flat"]'); await sleep(200);
  ok("Flat: no perspective (an orthographic camera), still from the front, Flat pressed", await V3(() => window.SF3D.viewer().cam().isOrthographicCamera === true) && await pressed('[data-d3t="flat"]') && (await dirNow())[2] > 0.9999);
  await ep.click('[data-d3t="measure"]'); await sleep(100);
  await tapAt(ep, [2, 0, 34], 0, 0); await tapAt(ep, [5, 0, 34], 0, 0);
  ok("Measuring works in Flat: the front leg is 3.000 in wide, corner to corner", /^3\.000 in/.test((await ep.innerText(".d3-meas")).trim()) && (await viewerState(ep)).pts.every(x => !x.loose), await ep.innerText(".d3-meas").catch(() => ""));
  await ep.click('[data-d3t="clear"]'); await ep.click('[data-d3t="measure"]'); await ep.click('[data-d3t="flat"]'); await sleep(200);
  ok("Flat again: back to perspective", await V3(() => window.SF3D.viewer().cam().isPerspectiveCamera === true) && !(await pressed('[data-d3t="flat"]')));
  await ep.click('[data-d3v="iso"]'); await sleep(150);
  await ep.click('[data-d3t="cut"]'); await sleep(250);
  const cut = await V3(() => { const V = window.SF3D.viewer(); return { c: V.state.cut, n: V.plane.normal.toArray(), k: V.plane.constant, row: !document.querySelector(".d3-cutrow").hidden }; });
  ok("Cut: from the front, half way through (Z 18 of 0–36), its row showing", cut.c && cut.c.from === "front" && cut.c.t === 0.5 && JSON.stringify(cut.n) === "[0,0,-1]" && Math.abs(cut.k - 18) < 1e-6 && cut.row && await pressed('[data-d3c="front"]'), JSON.stringify(cut));
  let apronAt = await V3(() => { const V = window.SF3D.viewer(), s = V.screenOf([36, 26.5, 33]); return V.partAt(s.x, s.y); });
  ok("The cut takes the apron away (it's in front of the cut): a tap there doesn't find it", apronAt !== 5, String(apronAt));
  const px = await V3(() => { const V = window.SF3D.viewer(); V.draw(); const s = V.screenOf([36, 29.25, 18]), c = document.querySelector(".d3-stage canvas"), r = c.getBoundingClientRect();
    const k = c.width / r.width, t = document.createElement("canvas"); t.width = c.width; t.height = c.height; const g = t.getContext("2d"); g.drawImage(c, 0, 0);
    return Array.from(g.getImageData(Math.round((s.x - r.left) * k), Math.round((s.y - r.top) * k), 1, 1).data).slice(0, 3); });
  ok("…and the top's cut face is filled (the slate cut colour, not hollow)", Math.abs(px[0] - 0x57) < 14 && Math.abs(px[1] - 0x5C) < 14 && Math.abs(px[2] - 0x6E) < 14, JSON.stringify(px));
  await shot(ep, "tablet-cut");
  await ep.$eval("[data-d3cut]", (el) => { el.value = "100"; el.dispatchEvent(new Event("input", { bubbles: true })); }); await sleep(150);
  apronAt = await V3(() => { const V = window.SF3D.viewer(), s = V.screenOf([36, 26.5, 33]); return V.partAt(s.x, s.y); });
  ok("Slid all the way: nothing cut away, the apron is back under a tap", apronAt === 5, String(apronAt));
  await ep.click('[data-d3c="top"]'); await sleep(100); await ep.click('[data-d3t="flip"]'); await sleep(100);
  ok("From the top, then Flip: the plane turns (keeps what's above it)", JSON.stringify(await V3(() => window.SF3D.viewer().plane.normal.toArray())) === "[0,1,0]" && await pressed('[data-d3t="flip"]'));
  await ep.click('[data-d3t="cut"]'); await sleep(150);
  ok("Cut off: its row hides, nothing is cut", !(await ep.isVisible(".d3-cutrow")) && await V3(() => window.SF3D.viewer().state.parts.every(p => !(p.mesh.material.clippingPlanes || []).length)));
  await tapAt(ep, [36, 29.25, 30], 0, 0);
  await ep.click('.d3-meas [data-d3do="ghost:0"]'); await sleep(150);
  ok("See through the top: it goes faint, the card offers Solid, and Show all says 1 see-through", await V3(() => { const m = window.SF3D.viewer().state.parts[0].mesh.material; return m.transparent && m.opacity < 0.5; })
     && await cardHas("solid:0") && /Show all \(1 see-through\)/.test(await ep.innerText('[data-d3t="all"]')));
  await ep.click('[data-d3t="measure"]'); await sleep(100); await tapAt(ep, [5, 28.5, 5], 0, 0);
  vs = await viewerState(ep);
  ok("…and it's never in the way: the back leg's corner under it, hidden before, now snaps", vs.pts.length === 1 && !vs.pts[0].loose && vs.pts[0].p.every((v, k) => Math.abs(v - [5, 28.5, 5][k]) < 1e-3), JSON.stringify(vs.pts));
  await ep.click('[data-d3t="clear"]'); await ep.click('[data-d3t="measure"]'); await ep.click('[data-d3t="all"]'); await sleep(150);
  ok("Show all makes it solid again", await V3(() => !window.SF3D.viewer().state.parts[0].mesh.material.transparent));
  await ep.$eval("[data-d3x]", (el) => { el.value = "100"; el.dispatchEvent(new Event("input", { bubbles: true })); }); await sleep(150);
  const ex = await V3(() => ({ leg: window.SF3D.viewer().state.parts[1].grp.position.toArray(), off: document.querySelector('[data-d3t="measure"]').disabled }));
  ok("Explode all the way: a leg moves out from the middle, 1.5 times as far (−48.75, −1.125, −21.75), and Measure still works", [-48.75, -1.125, -21.75].every((v, k) => Math.abs(ex.leg[k] - v) < 1e-6) && !ex.off, JSON.stringify(ex));
  await shot(ep, "tablet-explode");
  // measuring while exploded (Luke, 1 Nov): tapped where the parts are drawn, every number as assembled
  await ep.click('[data-d3t="reset"]'); await sleep(150);
  const drawnAt = (i, p) => V3(([i, p]) => { const o = window.SF3D.viewer().state.parts[i].grp.position; return [p[0] + o.x, p[1] + o.y, p[2] + o.z]; }, [i, p]);
  await ep.click('[data-d3t="measure"]'); await sleep(100);
  await tapAt(ep, await drawnAt(3, [2, 0, 34]), 0, 0); await tapAt(ep, await drawnAt(3, [5, 0, 34]), 0, 0);
  let exm = (await ep.innerText(".d3-meas")).replace(/\s+/g, " ");
  ok("Exploded, across one leg: 3.000 in, as it really is (no note)", /^3\.000 in/.test(exm) && !/as assembled/.test(exm), exm);
  await tapAt(ep, await drawnAt(3, [2, 0, 34]), 0, 0); await tapAt(ep, await drawnAt(4, [70, 0, 34]), 0, 0);
  exm = (await ep.innerText(".d3-meas")).replace(/\s+/g, " ");
  ok("…between two legs pulled apart on screen: 68.000 in as assembled, and it says so", /^68\.000 in/.test(exm) && /Measured as assembled/.test(exm), exm);
  await ep.$eval("[data-d3x]", (el) => { el.value = "0"; el.dispatchEvent(new Event("input", { bubbles: true })); }); await sleep(150);
  exm = (await ep.innerText(".d3-meas")).replace(/\s+/g, " ");
  ok("…and back together: every part home, the measurement and its marks with them, the note gone", await V3(() => window.SF3D.viewer().state.parts.every(p => p.grp.position.length() === 0))
     && /^68\.000 in/.test(exm) && !/as assembled/.test(exm) && await V3(() => { const V = window.SF3D.viewer(), d = V.state.marks.find(m => m.isMesh); return !!d && Math.abs(d.position.x - 2) < 1e-6 && Math.abs(d.position.z - 34) < 1e-6; }), exm);
  await ep.click('[data-d3t="clear"]'); await ep.click('[data-d3t="measure"]'); await sleep(100);
  const far = await V3(() => window.SF3D.viewer().cam().position.distanceTo(window.SF3D.viewer().controls.target));
  const sp = await V3(() => window.SF3D.viewer().screenOf([36, 26.5, 33]));
  await ep.mouse.dblclick(sp.x, sp.y); await sleep(250);
  const zm = await V3(() => { const V = window.SF3D.viewer(); return { t: V.controls.target.toArray(), d: V.cam().position.distanceTo(V.controls.target) }; });
  ok("A double-click on the apron zooms to it: centred on it, closer", [36, 26.5, 32.5].every((v, k) => Math.abs(zm.t[k] - v) < 1e-6) && zm.d < far * 0.9, JSON.stringify([zm, far]));
  await ep.click('[data-d3t="reset"]'); await sleep(150);
  ok("Reset view: the whole table again, in 3D", await pressed('[data-d3v="iso"]') && await V3(() => Math.abs(window.SF3D.viewer().controls.target.x - 36) < 1e-6));
  // Fusion leaves bodies nameless (Luke's real bookcase, 1 Nov): they take their component's name, numbered
  const nm = await V3(() => { const b = (x) => ({ name: "", attributes: { position: { array: [x, 0, 0, x + 1, 0, 0, x, 1, 0] } }, index: { array: [0, 1, 2] }, brep_faces: [{ first: 0, last: 0 }] });
    return window.SF3D.buildView({ meshes: [b(0), b(2), b(4), b(6)], root: { name: "", children: [{ name: "Bookcase", meshes: [3], children: [{ name: "Shelves", meshes: [0, 1, 2] }] }] } },
      { name: "n", file: "n.step", bytes: 1, detail: "fine", convert_ms: 1, up: "y", made_at: "" }).parts.map(p => p.name); });
  ok("Bodies with no name of their own take their component's name, numbered (Shelves 1–3); a nameless loose body is Part", JSON.stringify(nm) === JSON.stringify(["Shelves 1", "Shelves 2", "Shelves 3", "Part"]), JSON.stringify(nm));
  // Holes, curves and angles (Luke, 1 Nov: "this will make or break it"): a kit drawn here with known sizes: a 35 mm hinge-cup
  // hole 22.5 mm from an edge, two 8 mm dowels 32 mm apart, a leg splayed 10°, and a top with a 1" corner radius
  const R35 = 0.688976, A225 = 0.885827, R8 = 0.15748, C32 = 1.259843, S10 = 6 * Math.tan(10 * Math.PI / 180), RT = Math.SQRT1_2;
  await V3(({ R35, A225, R8, C32, S10 }) => {
    const ring = (cx, y, cz, r, n) => Array.from({ length: n }, (_, k) => [cx + r * Math.cos(2 * Math.PI * k / n), y, cz + r * Math.sin(2 * Math.PI * k / n)]);
    const orient = (f, out) => { f.tris = f.tris.map(([i, j, k]) => { const A = f.verts[i], B = f.verts[j], C = f.verts[k], u = [B[0] - A[0], B[1] - A[1], B[2] - A[2]], v = [C[0] - A[0], C[1] - A[1], C[2] - A[2]];
      const n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]], o = out([(A[0] + B[0] + C[0]) / 3, (A[1] + B[1] + C[1]) / 3, (A[2] + B[2] + C[2]) / 3]);
      return n[0] * o[0] + n[1] * o[1] + n[2] * o[2] >= 0 ? [i, j, k] : [i, k, j]; }); return f; };
    const fan = (verts, out) => orient({ verts, tris: verts.slice(2).map((_, k) => [0, k + 1, k + 2]) }, () => out);
    const strip = (lo, hi, out, close) => { const n = lo.length, tris = []; for (let k = 0; k < (close ? n : n - 1); k++) { const k2 = (k + 1) % n; tris.push([k, k2, n + k2], [k, n + k2, n + k]); } return orient({ verts: [...lo, ...hi], tris }, out); };
    const cap = (c, rim, out) => orient({ verts: [c, ...rim], tris: rim.map((_, k) => [0, 1 + k, 1 + (k + 1) % rim.length]) }, () => out);
    const mesh = (name, color, faces) => { const pos = [], idx = [], brep_faces = []; let t = 0;
      for (const f of faces) { const b = pos.length / 3, first = t; f.verts.forEach(v => pos.push(...v)); f.tris.forEach(tr => { idx.push(b + tr[0], b + tr[1], b + tr[2]); t++; }); brep_faces.push({ first, last: t - 1 }); }
      return { name, color, attributes: { position: { array: pos } }, index: { array: idx }, brep_faces }; };
    const cyl = (name, cx, cz, y0, y1, r, n, color) => { const lo = ring(cx, y0, cz, r, n), hi = ring(cx, y1, cz, r, n);
      return mesh(name, color, [strip(lo, hi, (p) => [p[0] - cx, 0, p[2] - cz], true), cap([cx, y1, cz], hi, [0, 1, 0]), cap([cx, y0, cz], lo, [0, -1, 0])]); };
    const cup = (name, cx, cz, a, r, y0, y1, n, color) => {
      const sq = (y) => Array.from({ length: n }, (_, k) => { const t = 2 * Math.PI * k / n, c = Math.cos(t), sn = Math.sin(t), m = a / Math.max(Math.abs(c), Math.abs(sn)); return [cx + m * c, y, cz + m * sn]; });
      const ann = (y, up) => { const tris = []; for (let k = 0; k < n; k++) { const k2 = (k + 1) % n; tris.push([k, k2, n + k2], [k, n + k2, n + k]); } return orient({ verts: [...ring(cx, y, cz, r, n), ...sq(y)], tris }, () => [0, up, 0]); };
      const C = [[cx - a, cz - a], [cx + a, cz - a], [cx + a, cz + a], [cx - a, cz + a]], sides = [];
      for (let k = 0; k < 4; k++) { const [x0, z0] = C[k], [x1, z1] = C[(k + 1) % 4]; sides.push(fan([[x0, y0, z0], [x1, y0, z1], [x1, y1, z1], [x0, y1, z0]], [(x0 + x1) / 2 - cx, 0, (z0 + z1) / 2 - cz])); }
      return mesh(name, color, [ann(y1, 1), ann(y0, -1), strip(ring(cx, y0, cz, r, n), ring(cx, y1, cz, r, n), (p) => [cx - p[0], 0, cz - p[2]], true), ...sides]);
    };
    const splay = (name, x0, x1, z0, z1, h, sh, color) => {
      const B = [[x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1]], Tp = B.map(([x, , z]) => [x + sh, h, z]), q = (i, j, out) => fan([B[i], B[j], Tp[j], Tp[i]], out);
      return mesh(name, color, [fan(B, [0, -1, 0]), fan(Tp, [0, 1, 0]), q(0, 1, [0, 0, -1]), q(1, 2, [h, -sh, 0]), q(2, 3, [0, 0, 1]), q(3, 0, [-h, sh, 0])]);
    };
    const rplate = (name, x0, x1, z0, z1, R, m, y0, y1, color) => {
      const cx = x1 - R, cz = z1 - R, arc = Array.from({ length: m + 1 }, (_, k) => { const t = (Math.PI / 2) * k / m; return [cx + R * Math.cos(t), cz + R * Math.sin(t)]; });
      const out2 = [[x0, z0], [x1, z0], ...arc, [x0, z1]], at = (y) => out2.map(([x, z]) => [x, y, z]);
      const flat = (pp, qq, out) => fan([[pp[0], y0, pp[1]], [qq[0], y0, qq[1]], [qq[0], y1, qq[1]], [pp[0], y1, pp[1]]], out);
      return mesh(name, color, [fan(at(y1), [0, 1, 0]), fan(at(y0), [0, -1, 0]), flat([x0, z0], [x1, z0], [0, 0, -1]), flat([x1, z0], arc[0], [1, 0, 0]), flat(arc[m], [x0, z1], [0, 0, 1]),
        flat([x0, z1], [x0, z0], [-1, 0, 0]), strip(arc.map(([x, z]) => [x, y0, z]), arc.map(([x, z]) => [x, y1, z]), (pp) => [pp[0] - cx, 0, pp[2] - cz], false)]);
    };
    const W = [0.55, 0.36, 0.2], M = [0.62, 0.63, 0.65];
    const view = window.SF3D.readView(window.SF3D.buildView({ meshes: [cup("Cup block", 2, 2, A225, R35, 0, 0.75, 64, W), cyl("Dowel 1", 5, 2, 0, 1, R8, 48, M), cyl("Dowel 2", 5 + C32, 2, 0, 1, R8, 48, M),
      splay("Splayed leg", 8, 9.5, 1, 2.5, 6, S10, M), rplate("Corner top", 11, 15, 0, 4, 1, 16, 0, 0.75, W)] }, { name: "kit", file: "kit.step", bytes: 1, detail: "fine", convert_ms: 1, up: "y", made_at: "" }));
    window.SF3D.viewer().show(view, { up: "y" });
  }, { R35, A225, R8, C32, S10 }); await sleep(300);
  const holes = () => V3(() => window.SF3D.viewer().holes().map(h => ({ kind: h.kind, r: h.r, full: h.full, sweep: h.sweep, c: h.c })));
  const meas = () => ep.innerText(".d3-meas").then(t => t.replace(/\s+/g, " ")).catch(() => "");
  await ep.click('[data-d3t="measure"]'); await sleep(100);
  ok("Measure offers Distance, Angle and Holes, Distance chosen", await pressed('[data-d3m="dist"]') && await ep.isVisible('[data-d3m="angle"]') && await ep.isVisible('[data-d3m="hole"]'));
  await ep.click('[data-d3m="hole"]'); await sleep(100);
  ok("Holes: the hint says to tap the rim of a hole", /Tap the rim of a hole/.test(await ep.innerText(".d3-hint")));
  await tapAt(ep, [2, 0.75, 2 + R35], 0, 0);
  let hs = await holes(), res = await meas();
  ok("The hinge-cup hole's rim: Ø 1.378 in, 35.00 mm, and its radius R 0.689 in, 17.50 mm; a full circle, its centre found", hs.length === 1 && hs[0].full && Math.abs(2 * hs[0].r - 2 * R35) < 2e-4
     && hs[0].c.every((v, k) => Math.abs(v - [2, 0.75, 2][k]) < 2e-4) && /Ø 1\.378 in/.test(res) && /35\.00 mm/.test(res) && /R 0\.689 in/.test(res) && /17\.50 mm/.test(res) && /A full circle/.test(res), res);
  await tapAt(ep, [2, 0.75, 2 + A225], 0, 0); res = await meas();
  ok("…then the block's front edge: 0.886 in, 22.50 mm, from the centre square to that edge", /^0\.886 in/.test(res) && /22\.50 mm/.test(res) && /square to that edge/.test(res), res);
  await shot(ep, "tablet-holes");
  await tapAt(ep, [5, 1, 2 + R8], 0, 0); await tapAt(ep, [5 + C32, 1, 2 + R8], 0, 0); res = await meas();
  ok("Two 8 mm dowels: Ø 0.315 in (8.00 mm) each, 1.260 in (32.00 mm) centre to centre", /^1\.260 in/.test(res) && /32\.00 mm/.test(res) && /Centre to centre/.test(res) && (res.match(/8\.00 mm/g) || []).length === 2, res);
  await tapAt(ep, [8 + S10 / 2, 3, 2.5], 0, 0);
  ok("A straight edge isn't a hole: it says so, and nothing changes", /That edge is straight/.test(await ep.innerText(".d3-note")) && (await holes()).length === 2);
  await tapAt(ep, [14 + RT, 0.75, 3 + RT], 0, 0); hs = await holes(); res = await meas();
  ok("A rounded corner: R 1.000 in (25.40 mm), a curve of 90.0°", hs.length === 1 && !hs[0].full && Math.abs(hs[0].r - 1) < 2e-4 && Math.abs(hs[0].sweep - 90) < 0.05
     && /R 1\.000 in/.test(res) && /25\.40 mm/.test(res) && /90\.0°/.test(res), res);
  await ep.click('[data-d3m="angle"]'); await sleep(100);
  ok("Angle: choosing it clears the hole, and the hint says to tap the first edge", (await holes()).length === 0 && /Tap the first edge/.test(await ep.innerText(".d3-hint")) && await pressed('[data-d3m="angle"]'));
  await tapAt(ep, [8 + S10 / 2, 3, 2.5], 0, 0);
  ok("…one edge, then it asks for the second", /Now tap the second edge/.test(await ep.innerText(".d3-hint")));
  await tapAt(ep, [8.75, 0, 2.5], 0, 0);
  let an = await V3(() => { const a = window.SF3D.viewer().angle(); return a && { deg: a.deg, meet: a.meet }; }); res = await meas();
  ok("The splayed leg's edge and its bottom edge: 80.0° (100.0° the other way), where they meet", an && Math.abs(an.deg - 80) < 0.01 && an.meet && /^80\.0°/.test(res) && /100\.0° the other way/.test(res), JSON.stringify([an, res]));
  await shot(ep, "tablet-angle");
  await tapAt(ep, [14 + RT, 0.75, 3 + RT], 0, 0); await tapAt(ep, [12.5, 0.75, 4], 0, 0);
  an = await V3(() => { const a = window.SF3D.viewer().angle(); return a && { deg: a.deg, meet: a.meet }; }); res = await meas();
  ok("A curve and a straight edge: the curve's exact tangent where it was tapped, 135.0° (45.0° the other way)", an && Math.abs(an.deg - 135) < 0.01 && an.meet && /^135\.0°/.test(res) && !/approximate/.test(res), JSON.stringify([an, res]));
  await ep.click('[data-d3m="dist"]'); await tapAt(ep, [11, 0.75, 0], 0, 0); await tapAt(ep, [15, 0.75, 0], 0, 0);
  ok("Distance still measures as before: the top's back edge, 4.000 in", /^4\.000 in/.test(await meas()), await meas());
  // a real STEP: the rounded cube's fillet is 5 mm in the file (its CYLINDRICAL_SURFACE and its two CIRCLEs)
  const rc = await V3(async (b) => {
    const bytes = Uint8Array.from(atob(b), (ch) => ch.charCodeAt(0)), { view } = await window.SF3D.convertStep(bytes, { file: "rounded-cube.step", detail: "fine", up: "y" });
    const V = window.SF3D.viewer(); V.show(window.SF3D.readView(view), { up: "y" });
    const g = V.state.parts[0].segs, arcs = [], seen = new Set();
    for (let i = 0; i < g.length; i += 6) { const rd = V.roundAt(0, Array.from(g.subarray(i, i + 6)));
      if (rd && rd.circle) { const k = rd.circle.c.map(v => v.toFixed(3)).join(); if (!seen.has(k)) { seen.add(k); arcs.push({ mid: rd.run[rd.run.length >> 1], r: rd.circle.r, sweep: rd.sweep, full: rd.full }); } } }
    return arcs;
  }, fs.readFileSync(`${SAMPLES}/rounded-cube.step`).toString("base64"));
  ok("The real rounded cube, converted from its STEP: two fillet arcs found, each R 5 mm (0.197 in) over 90°", rc.length === 2 && rc.every(a => !a.full && Math.abs(a.r - 5 / 25.4) < 2e-4 && Math.abs(a.sweep - 90) < 0.1), JSON.stringify(rc.map(a => [a.r, a.sweep, a.full])));
  await ep.click('[data-d3t="measure"]'); await ep.click('[data-d3m="hole"]'); await sleep(100);
  let got = null;
  for (const v of ["iso", "front", "side", "top"]) { await ep.click(`[data-d3v="${v}"]`); await sleep(120);
    for (const a of rc) { await tapAt(ep, a.mid, 0, 0); hs = await holes(); if (hs.length) { got = hs[0]; break; } }
    if (got) break; }
  res = await meas();
  ok("…and tapped on screen: R 0.197 in, 5.00 mm, a curve of 90.0°", got && Math.abs(got.r - 5 / 25.4) < 2e-4 && /R 0\.197 in/.test(res) && /5\.00 mm/.test(res) && /90\.0°/.test(res), res);
  await ep.click("[data-d3close]"); await ep.waitForSelector("[data-print]");
  ok("← Sheet 1 · TB-03 goes back to the sheet", /Sheet 1 · TB-03/.test(await appText(ep)) && !!(await ep.$("[data-d3]")));

  // the assembly on sheet 4: Luke's Z up, parts to hide
  await ep.click("[data-back]"); await ep.waitForSelector("[data-sheet]");
  await ep.evaluate(() => [...document.querySelectorAll("[data-sheet]")].find(b => b.querySelector(".no").innerText.trim() === "4").click());
  await ep.waitForSelector("[data-print]"); await waitBtn(ep); await openD3(ep);
  vs = await viewerState(ep);
  ok("Sheet 4 (TB-04): the 18-part assembly, standing the way Luke turned it (Z up)", vs && vs.parts === 18 && vs.up === "z", JSON.stringify(vs));
  await ep.click(".d3-parts summary"); await sleep(200);
  await ep.click('.d3-plist [data-d3part="0"]'); await sleep(200);
  ok("Parts: unticking one hides it", (await viewerState(ep)).hidden === 1);
  const groups = await ep.evaluate(() => (window.SF3D.viewer().state.view.groups || []).map(g => g.name));
  ok("The drop kept Fusion's components from the STEP: rod-assembly, two l-bracket-assemblies and plate", groups.filter(g => g === "l-bracket-assembly").length === 2
     && groups.includes("rod-assembly") && groups.includes("plate"), JSON.stringify(groups));
  await ep.evaluate(() => document.querySelector(".d3-stage").scrollIntoView({ block: "center" })); await sleep(200);
  const spot = await ep.evaluate(() => { const V = window.SF3D.viewer(), r = document.querySelector(".d3-stage canvas").getBoundingClientRect();
    for (let y = 0.15; y < 0.9; y += 0.04) for (let x = 0.15; x < 0.9; x += 0.04) { const cx = r.left + x * r.width, cy = r.top + y * r.height;
      if (cy < 10 || cy > innerHeight - 10) continue;
      const i = V.partAt(cx, cy), c = i >= 0 && V.compOf(i);
      if (c) return { cx, cy, i, name: V.state.parts[i].name, comp: c.name, n: c.list.length }; } return null; });
  ok("(a spot on the screen where a part of a component shows)", !!spot, JSON.stringify(spot));
  await ep.mouse.click(spot.cx, spot.cy, { button: "right" }); await sleep(250);
  let menuText = await ep.innerText(".d3-menu").catch(() => "");
  ok("A right-click on it (a mouse): Hide and Isolate for the body and its component, and Show all (1 hidden)", menuText.includes(`Hide ${spot.name}`) && menuText.includes(`Isolate ${spot.name}`)
     && menuText.includes(`Hide ${spot.comp} (${spot.n} parts)`) && menuText.includes(`Isolate ${spot.comp}`) && /Show all \(1 hidden\)/.test(menuText), menuText.replace(/\s+/g, " "));
  await ep.click(`.d3-menu [data-d3do="isoc:${spot.i}"]`); await sleep(250);
  vs = await viewerState(ep);
  ok(`Isolate ${spot.comp}: only its ${spot.n} parts show`, vs.parts - vs.hidden === spot.n, JSON.stringify(vs));
  await ep.click('[data-d3t="all"]'); await sleep(200);
  ok("Show all: all 18 again", (await viewerState(ep)).hidden === 0);
  const before = await ep.evaluate(() => window.SF3D.viewer().controls.target.toArray());
  await ep.mouse.move(spot.cx, spot.cy); await ep.mouse.down({ button: "right" }); await ep.mouse.move(spot.cx + 90, spot.cy + 30, { steps: 6 }); await ep.mouse.up({ button: "right" }); await sleep(200);
  const after = await ep.evaluate(() => window.SF3D.viewer().controls.target.toArray());
  ok("A right-drag still slides the view, with no menu", !(await ep.isVisible(".d3-menu")) && after.some((v, k) => Math.abs(v - before[k]) > 1e-3), JSON.stringify([before, after]));
  await shot(ep, "tablet-assembly");
  await ep.click("[data-d3close]"); await ep.waitForSelector("[data-print]");

  // sheet 9 (TB-01): never made at the drop; made here from its parked STEP, then kept
  await ep.click("[data-back]"); await ep.waitForSelector("[data-sheet]");
  await ep.evaluate(() => [...document.querySelectorAll("[data-sheet]")].find(b => b.querySelector(".no").innerText.trim() === "9").click());
  await ep.waitForSelector("[data-print]"); await waitBtn(ep); await openD3(ep);
  t = await appText(ep); vs = await viewerState(ep);
  ok("Sheet 9 (TB-01), whose view wasn't made at the drop: made on the tablet from its parked STEP, shown, and kept", vs && vs.parts >= 1 && /Made on this tablet from TB-01 rounded\.step in [\d.]+ s, and kept here/.test(t), t.slice(-200));
  ok("…the tablet made it for itself only: nothing was added to storage, and the database still says it wasn't made", (await q("select count(*)::int n from storage.objects where bucket_id = 'design-views'"))[0].n === 2
     && (await q("select status from item_designs where id = $1", [r1.id]))[0].status === "failed");
  await ep.click("[data-d3close]"); await ep.waitForSelector("[data-print]");
  // sheet 6 (TB-06): the broken file: the reason in words, no crash
  await ep.click("[data-back]"); await ep.waitForSelector("[data-sheet]");
  await ep.evaluate(() => [...document.querySelectorAll("[data-sheet]")].find(b => b.querySelector(".no").innerText.trim() === "6").click());
  await ep.waitForSelector("[data-print]"); await waitBtn(ep); await openD3(ep);
  ok("Sheet 6 (TB-06, not a STEP): it says plainly the STEP file couldn't be made into a 3D view", /The STEP file couldn't be made into a 3D view: it couldn't be read as a STEP file/.test(await appText(ep)));
  await ep.click("[data-d3close]"); await ep.waitForSelector("[data-print]");

  // no signal: reload with the database out of reach; TB-03 opens from the tablet's copy
  E.st.offline = true;
  await ep.reload(); await ericTo(E, 1, { dept: false });
  ok("With no signal, after a reload: sheet 1 still has its 3D design button (the list kept on the tablet)", await waitBtn(ep));
  await openD3(ep);
  ok("…and it opens from the tablet's copy: it works with no signal", /Opened from this tablet's copy: it works with no signal/.test(await appText(ep)) && (await viewerState(ep)).parts === 1);
  await ep.click("[data-d3close]"); await ep.click("[data-back]"); await ep.waitForSelector("[data-sheet]");
  await ep.evaluate(() => [...document.querySelectorAll("[data-sheet]")].find(b => b.querySelector(".no").innerText.trim() === "5").click());
  await ep.waitForSelector("[data-print]"); await waitBtn(ep); await openD3(ep);
  ok("Sheet 5 (TB-04 too) opens from the copy kept when sheet 4 opened it: the same view file", /Opened from this tablet's copy/.test(await appText(ep)));
  E.st.offline = false;
  ok("No page errors on Eric's tablet", !E.errs.length, E.errs.join(" | "));
  await E.ctx.close();

  // ---------- 6. Mike (Sanding): no button, no rows ----------
  const M = await session(browser, users.mike);
  await M.p.goto(base + "index.html");
  await M.p.waitForFunction(() => document.querySelector(".qhead"), null, { timeout: 20000 }); await showAll(M.p);
  await M.p.waitForFunction(() => [...document.querySelectorAll("[data-job]")].some(b => /PROJ-00418/.test(b.innerText)), null, { timeout: 20000 });
  await M.p.evaluate(() => [...document.querySelectorAll("[data-job]")].find(b => /PROJ-00418/.test(b.innerText)).click());
  await M.p.waitForSelector("[data-sheet]"); await M.p.click("[data-sheet]"); await M.p.waitForSelector("[data-print]"); await sleep(1500);
  ok("Mike (Sanding) gets no 3D design button, and his tablet never asks for 3D models", !(await M.p.$("[data-d3]")) && !M.st.tables.includes("item_designs"), M.st.tables.filter(x => /design/.test(x)).join());
  const mrows = await makeClient(users.mike).from("item_designs").select("id");
  const mview = await makeClient(users.mike).storage.from("design-views").download(r3.view_path);
  ok("…and the database gives him no rows and no view file, even if asked directly", Array.isArray(mrows.data) && mrows.data.length === 0 && !!mview.error);
  ok("No page errors on Mike's tablet", !M.errs.length, M.errs.join(" | "));
  await M.ctx.close();

  // ---------- 7. the office's job page ----------
  const O = await session(browser, users.luke), op = O.p;
  await op.goto(base + "office.html");
  await op.waitForSelector('header.top [data-tab="jobs"]', { timeout: 20000 }); await op.click('header.top [data-tab="jobs"]');   // 11 Nov: Jobs
  await op.waitForSelector("[data-jobfind]", { timeout: 20000 }); await op.fill("[data-jobfind]", "PROJ-00418"); await sleep(600); await op.press("[data-jobfind]", "Enter");
  await op.waitForFunction(() => /Progress by sheet|Items, by department/i.test(document.body.innerText) && document.querySelectorAll("[data-d3]").length, null, { timeout: 20000 });
  const btns = await op.evaluate(() => [...document.querySelectorAll(".grid .gs")].map(g => [g.querySelector("b") && g.querySelector("b").innerText, !!g.querySelector("[data-d3]")]).filter(x => x[0]));
  ok("The office's job page: a 3D button on each sheet row whose item has a model (sheets 1–6 and 9), none on 7–8", JSON.stringify(btns.filter(x => x[1]).map(x => x[0])) === JSON.stringify(["Sheet 1", "Sheet 2", "Sheet 3", "Sheet 4", "Sheet 5", "Sheet 6", "Sheet 9"]), JSON.stringify(btns));
  await op.click(".grid .gs [data-d3]");
  await op.waitForFunction(() => (document.getElementById("d3from") || {}).innerText, null, { timeout: 60000 }); await sleep(500);
  t = await op.evaluate(() => document.querySelector(".d3panel").innerText.replace(/\s+/g, " "));
  ok("It opens over the job page: 3D design · TB-03, the overall size, an Up box (a manager can turn it)", /3D design · TB-03/.test(t) && /Overall 39\.370 × 39\.370 × 39\.370 in/.test(t) && await op.isVisible(".d3-up select"), t.slice(0, 200));
  await op.selectOption(".d3-up select", "x"); await sleep(600);
  await shot(op, "office-overlay");
  ok("…turning it saves it (X up)", (await q("select up from item_designs where project_id = 'PROJ-00418' and item = 'TB-03'"))[0].up === "x" && /Saved: X is up/.test(await op.textContent("#d3from")));
  await op.selectOption(".d3-up select", "y"); await sleep(600);
  await op.keyboard.press("Escape"); await sleep(300);
  ok("Escape closes it", !(await op.$(".d3panel")));
  ok("No page errors in the office", !O.errs.length, O.errs.join(" | "));
  await O.ctx.close();

  // ---------- 8. Make it again (Luke), from the parked STEP ----------
  await lp.reload(); await lp.waitForSelector("#dropArea:not([hidden])", { timeout: 15000 });
  await lp.waitForSelector("#d3list details.fold > summary", { timeout: 15000 });
  ok("After a reload the 3D views list is folded again (open only while the page stays open)", await lp.$eval("#d3list details.fold", d => !d.open));
  await lp.click("#d3list details.fold > summary");
  await lp.waitForFunction(() => /TB-01/.test(document.getElementById("d3list").innerText), null, { timeout: 15000 });
  await lp.click(`#d3list [data-d3make="${r1.id}"]`);
  await lp.waitForFunction(() => /Made:|couldn/.test(document.getElementById("d3look").innerText), null, { timeout: 120000 });
  ok("Make it again: TB-01's view is made from its parked STEP and is ready", /Made: [\d.]+ × [\d.]+ × [\d.]+ in/.test(await lp.textContent("#d3look"))
     && (await q("select status from item_designs where id = $1", [r1.id]))[0].status === "ready");
  // once its STEP has gone to OneDrive, Make it again asks for the file and checks it's the same one
  await q("update parked_files set removed_at = now() where id = (select parked_file_id from item_designs where project_id = 'PROJ-00418' and item = 'TB-06')");
  await q(`with c as (select set_config('storage.allow_delete_query', 'true', true) as x)
           delete from storage.objects where bucket_id = 'parked-files' and (select x from c) = 'true'
              and name = (select step_path from item_designs where project_id = 'PROJ-00418' and item = 'TB-06')`);   // as the save does once it's filed
  const r6id = (await q("select id from item_designs where project_id = 'PROJ-00418' and item = 'TB-06'"))[0].id;
  await lp.click(`#d3list [data-d3make="${r6id}"]`);
  await lp.waitForSelector("#d3file", { timeout: 15000 });
  ok("Once a STEP has left Supabase, Make it again asks for the file from the job's Design folder", /Pick TB-06 broken\.step from PROJ-00418 › Production › Files › Design/.test(await lp.textContent("#d3look")));
  await lp.setInputFiles("#d3file", `${SAMPLES}/cube-mm.step`);
  await lp.waitForFunction(() => /isn’t the file that was dropped/.test(document.getElementById("d3look").innerText), null, { timeout: 15000 });
  ok("…a different file is refused (its fingerprint differs), and nothing changes", (await q("select status from item_designs where id = $1", [r6id]))[0].status === "failed");

  // ---------- 9. a database without design_viewer.sql under the new drop page ----------
  await q("alter function design_register(uuid) rename to design_register_away");
  await drop("PROJ-00418-again.zip"); t = await send();
  ok("If design_viewer.sql hasn't run, the drop says the 3D view isn't set up yet, and the rest is Done", /Not set up yet/.test(t) && /design_viewer\.sql hasn’t run/.test(t) && /Done/.test(t), t.slice(-300));
  await q("alter function design_register_away(uuid) rename to design_register");
  ok("No page errors on the drop page", !L.errs.length, L.errs.join(" | "));

  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close(); server.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  the test crashed: " + (e && e.stack || e)); process.exit(1); });
