// 31 Oct: the STEP viewer test page (step.html + designs.sql) in real Chromium, with real WebGL (SwiftShader) and the
// real STEP engine (occt-import-js 0.0.23's WebAssembly) and three.js 0.147.0, served in place of jsDelivr with the very
// integrity hashes the page pins. A manager converts sample STEP files from the engine's own test set, measures, and
// saves; Eric (Full Custom's supervisor) opens it on a "tablet" and measures again; he can't save. On a database
// without designs.sql the page says so and converting still works (the new page on the old database).
//   bash /home/claude/sf/base/fresh.sh            (sync_base_new, or TEMPLATE=sync_base_old for the old database)
//   OUT=<folder with the new pages> PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_step_chromium.js
// Needs the two libraries and the engine's sample files; on first run it fetches them (npm and GitHub, both allowed).
const fs = require("fs"), http = require("http"), path = require("path"), crypto = require("crypto"), zlib = require("zlib");
const { execSync } = require("child_process");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin, pool } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo", LIBS = "/home/claude/sf/steplibs";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

// ---- the libraries and sample files, once ----
if (!fs.existsSync(`${LIBS}/node_modules/occt-import-js/dist/occt-import-js.wasm`) || !fs.existsSync(`${LIBS}/node_modules/three/build/three.min.js`)) {
  fs.mkdirSync(LIBS, { recursive: true });
  execSync(`npm install --prefix ${LIBS} --no-audit --no-fund occt-import-js@0.0.23 three@0.147.0`, { stdio: "ignore" });
}
const SAMPLES = `${LIBS}/samples`;
if (!fs.existsSync(`${SAMPLES}/as1-oc-214.stp`)) {
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

const ERIC = { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email: "eric@example.com" };
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  let session = { user: ${JSON.stringify(user)} };
  const toB64 = async (blob) => { const u8 = new Uint8Array(await blob.arrayBuffer()); let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
    rpc: async (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (b) => ({
      list: async (prefix, opts) => call({ kind: "list", b, prefix, opts }),
      upload: async (p, blob, opts) => call({ kind: "up", b, p, b64: await toB64(blob), type: (opts || {}).contentType }),
      download: async (p) => { const r = await call({ kind: "dl", b, p }); if (r.error) return { data: null, error: r.error };
        const bin = Uint8Array.from(atob(r.b64), c => c.charCodeAt(0)); return { data: new Blob([bin], { type: r.type }), error: null }; } }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, "");
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : file.endsWith(".css") ? "text/css" : "application/octet-stream" });
  let body = fs.readFileSync(file);                                // the fake Supabase script can't match supabase-js's hash; the other libraries keep theirs
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.end(body);
});

async function asUser(user, sql, params) {         // a query under the login's row-level security, like Supabase does
  const c = await pool.connect();
  try { await c.query("begin"); await c.query("set local role authenticated");
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: user.id, role: "authenticated" })]);
    const r = await c.query(sql, params); await c.query("commit"); return { data: r.rows, error: null };
  } catch (e) { await c.query("rollback").catch(() => {}); return { data: null, error: { message: e.message } }; } finally { c.release(); }
}

async function context(browser, user) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: "block" });
  const client = makeClient(user);
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    if (m.kind === "dl") { const r = await client.storage.from(m.b).download(m.p); if (r.error) return { error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), type: r.data.type }; }
    if (m.kind === "up") return JSON.parse(JSON.stringify(await client.storage.from(m.b).upload(m.p, Buffer.from(m.b64, "base64"), { contentType: m.type })));
    if (m.kind === "list") {
      const r = await asUser(user, "select name, metadata from storage.objects where bucket_id = $1 and name like $2 order by name desc", [m.b, m.prefix + "/%"]);
      if (r.error) return r;
      const b = (await admin.query("select 1 from storage.buckets where id = $1", [m.b])).rows.length;
      if (!b) return { data: null, error: { message: "Bucket not found" } };
      return { data: r.data.map(x => ({ name: x.name.slice(m.prefix.length + 1), metadata: x.metadata })), error: null };
    }
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/supabase-js@2\.45\.4/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  await ctx.route(/cdn\.jsdelivr\.net\/npm\//, (r) => {
    const key = r.request().url().split("/npm/")[1], f = CDN[key];
    if (!f) return r.fallback();                                  // supabase-js: the fake, below
    r.fulfill({ body: fs.readFileSync(f), contentType: f.endsWith(".wasm") ? "application/wasm" : "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } });
  });
  const p = await ctx.newPage(); p.errs = []; p.on("pageerror", e => p.errs.push(e.message));
  return { ctx, p };
}
const text = (p) => p.evaluate(() => document.body.innerText);
async function convert(p, file) {
  await p.setInputFiles("#file", file);
  await p.waitForFunction(() => window.__step && (window.__step.S.raw || window.__step.S.err) && !window.__step.S.busy, null, { timeout: 120000 });
  await p.waitForTimeout(300);
}
/** tap a model point (inches, the model's own axes), a few pixels off so the snapping is what lands it */
async function tapAt(p, pt, off = 4) { const s = await p.evaluate((pt) => window.__step.screenOf(pt), pt); await p.mouse.click(s.x + off, s.y - off); await p.waitForTimeout(150); }

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const URL = `http://127.0.0.1:${server.address().port}/shop-floor/step.html`;
  const hasDesigns = (await admin.query("select to_regclass('public.check_designs') is not null as h")).rows[0].h
                  || (await admin.query("select to_regprocedure('public.check_designs()') is not null as h")).rows[0].h;
  console.log(hasDesigns ? "(database with designs.sql)" : "(database WITHOUT designs.sql: the new page on the old database)");
  const browser = await chromium.launch({ args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });

  // ---------- the core, in the page ----------
  let { ctx, p } = await context(browser, users.luke);
  await p.goto(URL);
  await p.waitForFunction(() => /Saved designs/.test(document.body.innerText), null, { timeout: 15000 });
  const core = await p.evaluate(async () => {
    const C = StepCore, f = (x) => C.frac(x);
    const idx = new Uint32Array([0, 1, 2, 0, 2, 3]);                       // one square face, two triangles
    const e = C.boundaryEdges(idx, [{ first: 0, last: 1 }]);
    const gz = await C.gzip("hello view"), back = await C.gunzip(gz);
    return { a: f(23.875), b: f(0.39370), c: f(39.37008), d: f(2), name: C.safeName("C:\\Designs\\Table #3 (final).STEP"), empty: C.safeName(".stp"),
             edges: e.length / 2, back, gzType: gz.type };
  });
  ok("Fractions: 23.875 is exactly 23 7/8; 0.3937 is about 25/64; 39.37008 about 39 3/8; 2 is 2",
     core.a.text === "23 7/8" && core.a.exact && core.b.text === "25/64" && !core.b.exact && core.c.text === "39 3/8" && !core.c.exact && core.d.text === "2" && core.d.exact, JSON.stringify(core));
  ok("File names are made safe (Table-3-final); a bare .stp becomes design", core.name === "Table-3-final" && core.empty === "design", core.name);
  ok("A face's outline: a square of two triangles has 4 edges (the diagonal isn't one)", core.edges === 4);
  ok("View files are gzipped and come back the same", core.back === "hello view");

  // ---------- the PC: Luke converts a STEP ----------
  const t0 = Date.now();
  await convert(p, `${SAMPLES}/cube-mm.step`);
  const S1 = await p.evaluate(() => ({ raw: window.__step.S.raw && { ...window.__step.S.raw, json: undefined }, err: window.__step.S.err, size: window.__step.S.view && window.__step.S.view.size }));
  ok("A 1,000 mm cube (a STEP in millimetres) converts, and its overall size reads in inches: 39.370 each way",
     S1.raw && S1.size.every(x => Math.abs(x - 39.3701) < 0.0005) && /Overall 39\.370 × 39\.370 × 39\.370 in/.test(await text(p)), JSON.stringify(S1).slice(0, 300));
  ok("…with what it took: the time, 1 part, 6 faces, 12 triangles, and the view file's size", /Converted in/.test(await text(p)) && S1.raw.parts === 1 && S1.raw.faces === 6 && S1.raw.triangles === 12
     && /view file \d+ KB/.test(await text(p)), `${Date.now() - t0} ms in this sandbox, with the engine download`);
  const canvas = await p.evaluate(() => { const c = document.querySelector("#stage canvas"); if (!c) return null;
    const gl = c.getContext("webgl2") || c.getContext("webgl"); const px = new Uint8Array(4 * 50 * 50);
    gl.readPixels(Math.floor(c.width / 2) - 25, Math.floor(c.height / 2) - 25, 50, 50, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let shaded = 0; for (let i = 0; i < px.length; i += 4) if (Math.abs(px[i] - 0xF4) + Math.abs(px[i + 1] - 0xF1) + Math.abs(px[i + 2] - 0xEA) > 30) shaded++;
    return { w: c.width, h: c.height, shaded }; });
  ok("It's drawn: the middle of the view shows the cube, not the empty background", canvas && canvas.shaded > 1000, JSON.stringify(canvas));
  ok("Luke's login is a manager's: the Save for the tablets button is there", !!(await p.$("[data-save]")));

  // measuring (Y up, seen from the +X +Y +Z side): visible corners, tapped a little off
  await p.click("[data-measure]");
  const box = await p.evaluate(() => { const v = window.__step.S.view; return { min: v.min, max: v.max }; });
  const [x0, y0, z0] = box.min, [x1, y1, z1] = box.max;
  await tapAt(p, [x1, y1, z1]); await tapAt(p, [x0, y1, z1]);
  let m = await p.evaluate(() => window.__step.measured());
  ok("Measuring: two taps a few pixels off two corners snap to them: 39.370 in along X, exact corners (not approximate)",
     m && Math.abs(m.dist - 39.3701) < 0.001 && !m.loose && /39\.370 in \(≈ 39 3\/8"\)/.test(await text(p)), JSON.stringify(m));
  await tapAt(p, [x1, y1, z1]); await tapAt(p, [x0, y1, z0]);
  m = await p.evaluate(() => window.__step.measured());
  ok("…and across the top, corner to corner: 55.678 in (39.370 × √2)", m && Math.abs(m.dist - 39.3701 * Math.SQRT2) < 0.001 && !m.loose, JSON.stringify(m));
  // a corner on the outline, tapped just outside the model, still counts
  const out = await p.evaluate(([c, a]) => { const s = window.__step.screenOf(c), o = window.__step.screenOf(a); const dx = s.x - o.x, dy = s.y - o.y, n = Math.hypot(dx, dy) || 1;
    return { x: s.x + dx / n * 7, y: s.y + dy / n * 7 }; }, [[x1, y0, z1], [(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2]]);
  await tapAt(p, [x1, y1, z1]); await p.mouse.click(out.x, out.y); await p.waitForTimeout(150);
  m = await p.evaluate(() => window.__step.measured());
  ok("A corner on the outline tapped just outside the model still snaps to it: 39.370 in down Y", m && Math.abs(m.dist - 39.3701) < 0.001 && !m.loose, JSON.stringify(m));
  // the corner hidden behind the cube is never picked through the surface
  await p.click("[data-clear]"); await tapAt(p, [x0, y0, z0], 0);
  const hid = await p.evaluate(() => window.__step.S.pts[0]);
  ok("A corner hidden behind the cube isn't picked through it (that tap lands on the face in front)",
     hid && !(Math.abs(hid.p[0] - x0) < 1e-6 && Math.abs(hid.p[1] - y0) < 1e-6 && Math.abs(hid.p[2] - z0) < 1e-6), JSON.stringify(hid));
  await p.click("[data-clear]");
  ok("Clear takes the measurement away", !(await p.evaluate(() => window.__step.measured())) && await p.$eval("#meas", e => e.hidden));

  // an assembly: parts, names, hiding one
  const t1 = Date.now();
  await convert(p, `${SAMPLES}/as1-oc-214.stp`);
  const S2 = await p.evaluate(() => ({ raw: { ...window.__step.S.raw, json: undefined }, parts: window.__step.S.view.parts.map(x => x.name) }));
  ok("An assembly converts with its 18 parts named (nut, nut (2)…, rod, bolt, plate)", S2.raw.parts === 18 && S2.parts.includes("nut (2)") && S2.parts.includes("rod") && S2.parts.includes("plate"),
     `${S2.raw.triangles} triangles, ${S2.raw.convert_ms} ms to convert here (${Date.now() - t1} ms in all); ${S2.parts.slice(0, 6).join(", ")}…`);
  await p.click("details.parts summary"); await p.click('[data-part="0"]');
  ok("A part can be hidden from the Parts list", await p.evaluate(() => window.__step.V.parts[0].grp.visible === false));

  // the rounded cube: curves at the finest setting
  await p.selectOption("#detail", "veryfine");
  await convert(p, `${SAMPLES}/rounded-cube.step`);
  const S3 = await p.evaluate(() => ({ raw: { ...window.__step.S.raw, json: undefined }, size: window.__step.S.view.size }));
  ok("Very fine: a rounded cube converts, more triangles on its curves, size 0.394 in (10 mm)", S3.raw.triangles > 140 && S3.size.every(x => Math.abs(x - 0.3937) < 0.0005), JSON.stringify(S3));

  // save it for the tablets (the cube, at fine)
  await p.selectOption("#detail", "fine");
  await convert(p, `${SAMPLES}/cube-mm.step`);
  await p.selectOption("#up", "z"); await p.waitForTimeout(300);
  if (hasDesigns) {
    await p.click("[data-save]");
    await p.waitForFunction(() => /Saved for the tablets: cube-mm/.test(document.body.innerText), null, { timeout: 15000 });
    const stored = (await admin.query("select name, metadata from storage.objects where bucket_id = 'designs'")).rows;
    const { files } = require("./pgsupa"), buf = files.get("designs/" + (stored[0] || {}).name);
    let vf = null; try { vf = JSON.parse(zlib.gunzipSync(buf).toString()); } catch (e) {}
    ok("Saved: one gzip view file in designs, named test/<date>-<time>-cube-mm.view.json.gz", stored.length === 1 && /^test\/\d{8}-\d{6}-cube-mm\.view\.json\.gz$/.test(stored[0].name), JSON.stringify(stored));
    ok("…it's a view file: inches, Z up as chosen, from cube-mm.step, with its one part", vf && vf.kind === "shop-floor-view" && vf.units === "in" && vf.up === "z" && vf.source.file === "cube-mm.step" && vf.parts.length === 1);
    ok("…and the Saved designs list shows it", /cube-mm/.test(await text(p)) && !!(await p.$('[data-open]')));
  } else {
    ok("Old database: Saved designs says the storage isn't set up yet (run designs.sql)", /The designs storage isn't set up yet: run designs\.sql/.test(await text(p)));
    await p.click("[data-save]"); await p.waitForTimeout(800);
    ok("…and saving says so too, while converting and measuring still work", /designs storage isn't set up yet|Couldn't save/.test(await text(p)) && S1.raw);
  }
  ok("No errors on the PC page", p.errs.length === 0, p.errs.join(" | "));
  await ctx.close();

  // ---------- the tablet: Eric (Full Custom) opens it ----------
  if (hasDesigns) {
    ({ ctx, p } = await context(browser, ERIC));
    await p.setViewportSize({ width: 1280, height: 800 });
    await p.goto(URL);
    await p.waitForFunction(() => /Saved designs/.test(document.body.innerText) && document.querySelector("[data-open]"), null, { timeout: 15000 });
    await p.click("[data-open]");
    await p.waitForFunction(() => window.__step.S.view && /Opened in/.test(document.body.innerText), null, { timeout: 30000 });
    const T = await p.evaluate(() => ({ up: window.__step.S.up, size: window.__step.S.view.size, from: window.__step.S.viewFrom }));
    ok("Eric's tablet opens it: Z up as saved, 39.370 each way, and it says how long it took", T.up === "z" && T.size.every(x => Math.abs(x - 39.3701) < 0.0005) && /Opened in .* Made from cube-mm\.step/.test(T.from), T.from);
    await p.click("[data-measure]");
    // with Z up the cube is turned: tap the corner nearest the eye, then the one beside it along the model's Y
    const near = await p.evaluate(() => { const T = window.THREE, V = window.__step.V, v = window.__step.S.view, out = [];
      for (const x of [v.min[0], v.max[0]]) for (const y of [v.min[1], v.max[1]]) for (const z of [v.min[2], v.max[2]])
        out.push({ p: [x, y, z], d: new T.Vector3(x, y, z).applyMatrix4(V.model.matrixWorld).distanceTo(V.camera.position) });
      out.sort((a, b) => a.d - b.d); const c = out[0].p; return { c, other: [c[0], c[1] === v.min[1] ? v.max[1] : v.min[1], c[2]] }; });
    await tapAt(p, near.c); await tapAt(p, near.other);
    m = await p.evaluate(() => window.__step.measured());
    ok("…and measures a corner to corner: 39.370 in along Y", m && Math.abs(m.dist - 39.3701) < 0.001 && !m.loose, JSON.stringify(m));
    await convert(p, `${SAMPLES}/cube-in.step`);
    ok("A supervisor can convert on the tablet too, but there's no Save: only a manager's login saves",
       !(await p.$("[data-save]")) && /Only a manager's login saves view files/.test(await text(p)));
    const direct = await p.evaluate(async () => { const b = new Blob([new Uint8Array([31, 139, 8, 0])]);
      return await window.supabase.createClient().storage.from("designs").upload("test/20261031-120000-sneaky.view.json.gz", b, { contentType: "application/gzip" }); });
    ok("…and the database refuses his save even when asked directly", direct && direct.error, JSON.stringify(direct));
    ok("No errors on the tablet page", p.errs.length === 0, p.errs.join(" | "));
    await ctx.close();
  }
  await browser.close(); server.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
