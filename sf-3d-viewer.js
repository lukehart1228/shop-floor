/* sf-3d-viewer.js — the 3D design viewer's shared part (1 Nov 2026). One copy, used by three pages:
   index.html (Full Custom's tablet: the 3D design button on a sheet), office.html (the 3D button on a job page) and
   drop.html (making each Design/ STEP into a view file when a zip is dropped, and turning it upright).
   Pages load this file only when someone opens a design, then three.js 0.147.0 from jsDelivr with pinned integrity
   hashes; the STEP engine (occt-import-js 0.0.23, 7.6 MB) only when a view has to be made on this device. The offline
   helper keeps all of it for no signal. A view file is gzipped JSON (kind shop-floor-view, format 1): the shape in
   inches, grouped by part, with each part's outline edges; its STEP's own axes; which way is up is the database's.
   Parts are drawn in the colours the STEP carries (Fusion's appearances), part by part and face by face, with midnight
   outlines; a part with none is the brand's neutral tone (Luke, 1 Nov). Tapping a part shows its size, with Hide and Isolate for the
   body and for its component (Fusion's components come through the STEP); a mouse's right button opens the same as a menu.
   Seeing it better (Luke, 1 Nov): standard views (3D, Front, Top, Side), Flat (no perspective, like a drawing), a section cut
   with its cut faces filled, see-through parts, an exploded view (measuring works in it, as assembled), and zoom to a part (double-tap).
   Measure has three kinds (Luke, 1 Nov): Distance (two points), Angle (two edges, where they meet) and Holes (a round edge's
   diameter and radius, or an arc's radius, found from the circle its points lie on, then from its centre to another hole or square to an edge). Measuring snaps to corners and to any point
   along an edge, square across to a parallel edge; a corner or edge hidden behind a part is never picked through it: the
   viewer says what's in the way and offers to hide it. Design: the spec's 3D design viewer tab. Nothing here talks to
   the database except openDesign(). */
(function (root) {
  "use strict";
  if (root.SF3D) return;
  const VERSION = "2026-11-01.9";

  // the libraries, pinned and checked (the same files and hashes as step.html, the test page)
  const LIBS = {
    three: [
      { src: "https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js", integrity: "sha384-vV17nr/rMaJqmeZkFUzXLpHdQ+ME5QHKdydaqqN+3Ga39RJlNrTatJxHwGV4ml2C" },
      { src: "https://cdn.jsdelivr.net/npm/three@0.147.0/examples/js/controls/OrbitControls.js", integrity: "sha384-I0DMsfimAPIqWT8lF+oA997gRgdUi3jhidoTq3fN0zmn35smXZukD01FLnsPRU9i" },
    ],
    occt: { src: "https://cdn.jsdelivr.net/npm/occt-import-js@0.0.23/dist/occt-import-js.js", integrity: "sha384-Z8pO9JEhFZF+mvDKxMuLvPT85VP7nly8CqYjBatl0bMeW9OsaKCes4gEUPL4nihc" },
    wasm: { src: "https://cdn.jsdelivr.net/npm/occt-import-js@0.0.23/dist/occt-import-js.wasm", integrity: "sha384-6BbVZ7iPDgcRszsoavxGz4TaYCwC2EkeYCy1aR9XFwqMZYXDQP+0vZSTP6Yw35iD", bytes: 7604031 },
  };
  // how closely curves are followed, in inches (corners are exact at every setting). Fine to start (Luke, 31 Oct).
  const DETAIL = {
    normal:   { label: "Normal (curves within 0.005 in)",     linear: 0.005,  angular: 0.2 },
    fine:     { label: "Fine (curves within 0.002 in)",       linear: 0.002,  angular: 0.1 },
    veryfine: { label: "Very fine (curves within 0.0005 in)", linear: 0.0005, angular: 0.05 },
  };
  const VIEW_KIND = "shop-floor-view", VIEW_FORMAT = 1;
  // the brand palette: --gray for every part, --midnight outlines, --orange for what you tap, --paper behind
  const COLORS = { part: 0xC2BAA0, edge: 0x181D2E, mark: 0xED5E0F, back: 0xEFEDE6, cap: 0x575C6E };
  const KEEP = "design-views-v1";                    // this device's kept view files (not the offline helper's cache)
  const now = () => (root.performance && performance.now ? performance.now() : Date.now());

  // ---------- small pieces ----------
  function b64(u8) { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); }
  function unb64(s) { const bin = atob(s), u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i); return u8; }
  function safeName(file) {
    const base = String(file || "").replace(/^.*[\\/]/, "").replace(/\.(step|stp)$/i, "");
    return base.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[-.]+|[-.]+$/g, "").slice(0, 80) || "design";
  }
  /** 23.875 → { text: "23 7/8", exact: true }: the nearest 64th, and whether it's within half a thousandth */
  function frac(x) {
    const neg = x < 0; x = Math.abs(x);
    let n = Math.round(x * 64), whole = Math.floor(n / 64), r = n % 64, d = 64;
    while (r && r % 2 === 0) { r /= 2; d /= 2; }
    const text = (neg ? "-" : "") + (whole || !r ? String(whole) : "") + (r ? `${whole ? " " : ""}${r}/${d}` : "");
    return { text, exact: Math.abs(x - n / 64) < 0.0005 };
  }
  function fmtIn(x) { const f = frac(x); return `${x.toFixed(3)} in (${f.exact ? "" : "≈ "}${f.text}")`; }
  const sizeText = (size) => (size || []).map(x => Number(x).toFixed(3)).join(" × ");
  /** A face's outline: the edges of its triangles used once. Vertices are never shared between faces, so these are
   *  the shape's true edges. index: triangle corners; faces: [{first, last}] triangle ranges. Returns pairs. */
  function boundaryEdges(index, faces) {
    const out = [];
    for (const f of faces) {
      const seen = new Map();
      for (let t = f.first; t <= f.last; t++) for (let k = 0; k < 3; k++) {
        const a = index[t * 3 + k], b = index[t * 3 + (k + 1) % 3], key = a < b ? a * 4294967296 + b : b * 4294967296 + a;
        seen.set(key, (seen.get(key) || 0) + 1);
      }
      for (const [key, n] of seen) if (n === 1) out.push(Math.floor(key / 4294967296), key % 4294967296);
    }
    return new Uint32Array(out);
  }
  /** occt-import-js's result → a view file (plain object). Normals are left out: the viewer works them out. */
  function buildView(result, meta) {
    const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity], parts = [], names = new Map();
    // the components, as the STEP nests them: each body's nearest named node, with the names from the top down
    const groups = [], meshGroup = new Map();
    const walk = (node, path) => {
      const name = String(node.name || "").trim(), here = name ? path.concat(name) : path;
      if (node.meshes && node.meshes.length) { groups.push({ name: here[here.length - 1] || "", path: here }); for (const i of node.meshes) meshGroup.set(i, groups.length - 1); }
      for (const c of node.children || []) walk(c, here);
    };
    if (result.root) walk(result.root, []);
    const meshes = result.meshes || [];
    // Fusion leaves many bodies nameless (Luke's bookcase, 1 Nov: a Face Frame of 8 unnamed bodies); those take their
    // component's name, numbered when it has several (Face Frame 3), so the menus and the Parts list read well
    const unnamedIn = new Map(), seenIn = new Map();
    meshes.forEach((m, i) => { if (!String(m.name || "").trim() && meshGroup.has(i)) unnamedIn.set(meshGroup.get(i), (unnamedIn.get(meshGroup.get(i)) || 0) + 1); });
    for (let mi = 0; mi < meshes.length; mi++) {
      const m = meshes[mi];
      const pos = new Float32Array(m.attributes.position.array), idx = new Uint32Array(m.index.array);
      if (!idx.length) continue;
      for (let i = 0; i < pos.length; i += 3) for (let k = 0; k < 3; k++) { if (pos[i + k] < min[k]) min[k] = pos[i + k]; if (pos[i + k] > max[k]) max[k] = pos[i + k]; }
      let name = String(m.name || "").trim();
      if (!name && meshGroup.has(mi) && groups[meshGroup.get(mi)].path.length >= 2) {
        const g = meshGroup.get(mi), k = (seenIn.get(g) || 0) + 1; seenIn.set(g, k);
        name = unnamedIn.get(g) > 1 ? `${groups[g].name} ${k}` : groups[g].name;
      }
      name = name || "Part";
      const n = (names.get(name) || 0) + 1; names.set(name, n); if (n > 1) name = `${name} (${n})`;
      const faces = (m.brep_faces || []).map(f => ({ first: f.first, last: f.last }));
      const r3 = (c) => Math.round(c * 1000) / 1000;
      const faceColors = (m.brep_faces || []).filter(f => Array.isArray(f.color)).map(f => [f.first, f.last, r3(f.color[0]), r3(f.color[1]), r3(f.color[2])]);
      parts.push({ name, color: Array.isArray(m.color) ? m.color.map(r3) : null,
        pos: b64(new Uint8Array(pos.buffer)), idx: b64(new Uint8Array(idx.buffer)),
        edges: b64(new Uint8Array(boundaryEdges(idx, faces).buffer)), faces: faces.length, triangles: idx.length / 3,
        face_colors: faceColors.length ? faceColors : undefined, group: meshGroup.has(mi) ? meshGroup.get(mi) : undefined });
    }
    if (!parts.length) throw stop("convert", "there's no shape in it: it may point to other files for its parts, or hold only a drawing. Export the whole piece as one STEP file.");
    return { kind: VIEW_KIND, format: VIEW_FORMAT, units: "in", up: meta.up || "z", name: meta.name, made_at: meta.made_at,
      source: { file: meta.file, bytes: meta.bytes }, detail: meta.detail, convert_ms: meta.convert_ms,
      min, max, size: max.map((v, k) => v - min[k]), parts, groups: groups.length ? groups : undefined };
  }
  /** a view file's parts as typed arrays, after checking it's one */
  function readView(v) {
    if (!v || v.kind !== VIEW_KIND || !Array.isArray(v.parts)) throw stop("broken", "That isn't a view file.");
    if (v.format > VIEW_FORMAT) throw stop("broken", "That view file was made by a newer page than this one. Reload the page.");
    return { ...v, parts: v.parts.map(p => ({ ...p,
      pos: new Float32Array(unb64(p.pos).buffer), idx: new Uint32Array(unb64(p.idx).buffer), edges: new Uint32Array(unb64(p.edges).buffer) })) };
  }
  async function gzip(text) { return await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"))).blob(); }
  async function gunzip(blob) { return await new Response(blob.stream().pipeThrough(new DecompressionStream("gzip"))).text(); }
  function stop(kind, message) { const e = new Error(message); e.kind = kind; return e; }
  const isNet = (e) => !!e && (e.kind === "offline" || /failed to fetch|networkerror|network request|load failed|offline|err_internet|timed out/i.test(String(e.message || e.error || e)));

  // ---------- the libraries: loaded once, checked; a failure can be tried again ----------
  const loading = new Map();
  function script(lib) {
    if (!loading.has(lib.src)) loading.set(lib.src, new Promise((res, rej) => {
      const s = document.createElement("script"); s.src = lib.src; s.integrity = lib.integrity; s.crossOrigin = "anonymous";
      s.onload = res;
      s.onerror = () => { s.remove(); loading.delete(lib.src); rej(stop("viewer", "The 3D viewer couldn't load. It needs a connection the first time; after that it's kept.")); };
      document.head.appendChild(s);
    }));
    return loading.get(lib.src);
  }
  async function needThree() { if (root.THREE && root.THREE.OrbitControls) return root.THREE; for (const l of LIBS.three) await script(l); return root.THREE; }
  let occtReady = null;
  function needOcct() {
    if (!occtReady) occtReady = (async () => {
      try { await script(LIBS.occt); } catch (e) { throw stop("engine", "The STEP engine couldn't be downloaded (7.6 MB from jsDelivr). Check the connection and try again."); }
      let r;
      try { r = await fetch(LIBS.wasm.src, { integrity: LIBS.wasm.integrity, mode: "cors" }); } catch (e) { r = null; }
      if (!r || !r.ok) throw stop("engine", "The STEP engine couldn't be downloaded (7.6 MB from jsDelivr). Check the connection and try again.");
      return await root.occtimportjs({ wasmBinary: await r.arrayBuffer() });
    })().catch(e => { occtReady = null; throw e.kind ? e : stop("engine", "The STEP engine couldn't be loaded. Check the connection and try again."); });
    return occtReady;
  }

  /** A STEP file's bytes → { view, gz, facts }. Fine detail, inches. Throws in words if it can't. */
  async function convertStep(bytes, { file = "design.step", detail = "fine", up = "z" } = {}) {
    const occt = await needOcct();
    const d = DETAIL[detail] || DETAIL.fine, t0 = now();
    let result;
    try { result = occt.ReadStepFile(bytes, { linearUnit: "inch", linearDeflectionType: "absolute_value", linearDeflection: d.linear, angularDeflection: d.angular }); }
    catch (e) { throw stop("convert", "the STEP engine stopped on it. Export it again from Fusion as STEP."); }
    const ms = Math.round(now() - t0);
    if (!result || !result.success) throw stop("convert", "it couldn't be read as a STEP file. Export it again from Fusion as STEP.");
    const view = buildView(result, { name: safeName(file), file, bytes: bytes.length, detail, convert_ms: ms, up, made_at: new Date().toISOString() });
    const gz = await gzip(JSON.stringify(view));
    const facts = { size_in: view.size.map(x => Math.round(x * 10000) / 10000), parts: view.parts.length,
                    triangles: view.parts.reduce((a, p) => a + p.triangles, 0), faces: view.parts.reduce((a, p) => a + p.faces, 0), convert_ms: ms, up };
    return { view, gz, facts };
  }

  // ---------- kept on this device (the Cache API, like the tablets' work order pages) ----------
  const keyOf = (path) => new Request(location.origin + "/__design-views__/" + encodeURIComponent(path));
  async function kept(path) {
    if (!("caches" in root) || !path) return null;
    try { const hit = await (await caches.open(KEEP)).match(keyOf(path)); return hit ? await hit.blob() : null; } catch (e) { return null; }
  }
  async function keep(path, blob) {
    if (!("caches" in root) || !path) return false;
    try { await (await caches.open(KEEP)).put(keyOf(path), new Response(blob, { headers: { "Content-Type": "application/gzip" } })); return true; } catch (e) { return false; }
  }

  /** One design (an item_designs row) → { view, from: kept|downloaded|made, bytes, ms }. The kept copy first (a view
   *  file never changes: its name is its STEP's fingerprint), then the stored one, then, only if it was never made,
   *  made here from its parked STEP. Throws with .kind: offline, nostep, convert, engine, viewer, broken. */
  async function openDesign({ db, row, keep: wantKeep = false, onStatus = () => {} }) {
    const t0 = now();
    const three = needThree();                               // in parallel with the file
    three.catch(() => {});
    let gz = wantKeep ? await kept(row.view_path) : null, from = gz ? "kept" : null, gone = false;
    if (!gz && row.status === "ready") {
      onStatus("Downloading the design…");
      let r;
      try { r = await db.storage.from("design-views").download(row.view_path); } catch (e) { r = { error: e }; }
      if (r.error) { if (isNet(r.error)) throw stop("offline", "No connection, and this design hasn't been opened on this device before. Open it once with a connection and it's kept here."); gone = true; }
      else { gz = r.data; from = "downloaded"; if (wantKeep) await keep(row.view_path, gz); }
    }
    if (!gz) {
      if (!row.step_path) throw stop("nostep", gone ? "This design's view file can't be found, and its STEP file has gone from Supabase to OneDrive. Luke can make the view again on Drop a job's zip."
                                                 : "This design's 3D view wasn't made when its zip was dropped, and its STEP file has gone from Supabase to OneDrive. Luke can make the view again on Drop a job's zip.");
      onStatus("This design's 3D view wasn't made when its zip was dropped, so it's being made here from its STEP file. Fetching the STEP file…");
      let r;
      try { r = await db.storage.from("parked-files").download(row.step_path); } catch (e) { r = { error: e }; }
      if (r.error) throw isNet(r.error) ? stop("offline", "No connection. This design's 3D view has to be made here from its STEP file, and that needs a connection.")
                                        : stop("nostep", "This design's 3D view wasn't made when its zip was dropped, and its STEP file has gone from Supabase to OneDrive. Luke can make the view again on Drop a job's zip.");
      onStatus(`Making the 3D view here from ${row.step_name || "the STEP file"}… the first time, the STEP engine downloads (7.6 MB), and the screen may pause.`);
      await new Promise(res => setTimeout(res, 60));
      let c;
      try { c = await convertStep(new Uint8Array(await r.data.arrayBuffer()), { file: row.step_name, detail: row.detail || "fine", up: row.up || "z" }); }
      catch (e) { if (e.kind === "convert") e.message = `The STEP file couldn't be made into a 3D view: ${e.message}`; throw e; }
      gz = c.gz; from = "made"; if (wantKeep) await keep(row.view_path, gz);
    }
    onStatus("Opening it…");
    await three;
    const view = readView(JSON.parse(await gunzip(gz)));
    return { view, from, bytes: gz.size, ms: Math.round(now() - t0) };
  }

  // ---------- the viewer: one per page, kept alive across the page's redraws (it moves into each new host) ----------
  const CSS = `
.d3v{background:#fff; border-radius:12px; overflow:hidden; color:var(--midnight,#181D2E)}
.d3-stage{position:relative; width:100%; height:min(66vh,720px); min-height:300px; background:var(--paper,#EFEDE6); touch-action:none; user-select:none; -webkit-user-select:none}
.d3-stage canvas{display:block; width:100%; height:100%}
.d3-size{position:absolute; left:10px; top:10px; background:rgba(255,255,255,.93); border-radius:8px; padding:6px 10px; font-size:15px; line-height:1.3; pointer-events:none}
.d3-size b{font-family:'Barlow Condensed',sans-serif; font-size:20px; font-variant-numeric:tabular-nums}
.d3-size small{color:var(--ink2,#6B7082); font-size:13px}
.d3-meas{position:absolute; right:10px; top:10px; max-width:62%; background:var(--midnight,#181D2E); color:var(--sawdust,#FFF4D5); border-radius:8px; padding:8px 12px; font-size:15px; line-height:1.35; pointer-events:none}
.d3-meas b{font-family:'Barlow Condensed',sans-serif; font-size:24px; color:#fff; font-variant-numeric:tabular-nums}
.d3-tag{position:absolute; transform:translate(-50%,-130%); background:var(--orange,#ED5E0F); color:#fff; border-radius:6px; padding:2px 8px; font-family:'Barlow Condensed',sans-serif; font-weight:700; font-size:18px; white-space:nowrap; pointer-events:none}
.d3-hint{position:absolute; left:50%; bottom:10px; transform:translateX(-50%); background:rgba(24,29,46,.88); color:#fff; border-radius:99px; padding:5px 14px; font-size:15px; pointer-events:none; white-space:nowrap}
.d3-note{position:absolute; left:50%; bottom:10px; transform:translateX(-50%); width:max-content; max-width:94%; display:flex; flex-wrap:wrap; gap:6px 10px; align-items:center; justify-content:center; text-align:center; background:var(--midnight,#181D2E); color:#fff; border-radius:12px; padding:8px 12px; font-size:15px; line-height:1.35}
.d3-note button{min-height:40px; padding:4px 14px; border-radius:8px; border:1.5px solid var(--sawdust,#FFF4D5); background:transparent; color:var(--sawdust,#FFF4D5); font:inherit; font-weight:700; cursor:pointer}
.d3-menu{position:absolute; z-index:3; min-width:210px; max-width:min(320px,92%); background:#fff; color:var(--midnight,#181D2E); border:1px solid var(--line,#E4DFCF); border-radius:10px; box-shadow:0 8px 24px rgba(24,29,46,.25); padding:4px; display:flex; flex-direction:column}
.d3-menu button{min-height:44px; text-align:left; padding:8px 12px; border:none; border-radius:8px; background:none; color:inherit; font:inherit; font-weight:600; cursor:pointer}
.d3-menu button:hover,.d3-menu button:focus-visible{background:var(--paper,#EFEDE6)}
.d3-acts{display:flex; flex-wrap:wrap; gap:6px; margin-top:8px; pointer-events:auto}
.d3-acts button{min-height:40px; padding:4px 12px; border-radius:8px; border:1.5px solid var(--sawdust,#FFF4D5); background:transparent; color:var(--sawdust,#FFF4D5); font:inherit; font-weight:700; cursor:pointer}
.d3-ghead{grid-column:1/-1; font-weight:700; font-size:14px; color:var(--ink2,#6B7082); margin-top:6px}
.d3-seg{display:inline-flex; border:1.5px solid var(--gray,#C2BAA0); border-radius:10px; overflow:hidden}
.d3-seg button{border:none!important; border-radius:0!important; margin:0!important}
.d3-seg button+button{border-left:1.5px solid var(--gray,#C2BAA0)!important}
.d3-tools button[aria-pressed="true"]{background:var(--midnight,#181D2E); color:var(--sawdust,#FFF4D5); border-color:var(--midnight,#181D2E)}
.d3-tools button:disabled{opacity:.45; cursor:default}
.d3-slide{display:inline-flex; align-items:center; gap:8px; font-weight:600}
.d3-slide input,.d3-cutrow input[type=range]{width:min(220px,42vw); min-height:44px; accent-color:var(--orange,#ED5E0F)}
.d3-acts span{align-self:center; font-size:14px}
p.d3-help{margin:0; padding:2px 12px 10px}
.d3v [hidden]{display:none!important}
.d3-msg{position:absolute; inset:0; display:flex; align-items:center; justify-content:center; text-align:center; padding:24px; font-size:17px; line-height:1.45; background:var(--paper,#EFEDE6)}
.d3-msg span{max-width:34em}
.d3-tools{display:flex; flex-wrap:wrap; gap:8px; padding:10px 12px; border-top:1px solid var(--line,#E4DFCF); align-items:center}
.d3-tools button{min-height:48px; padding:8px 16px; border-radius:10px; border:1.5px solid var(--gray,#C2BAA0); background:#fff; color:var(--midnight,#181D2E); font:inherit; font-weight:600; cursor:pointer}
.d3-tools button.on{background:var(--midnight,#181D2E); color:var(--sawdust,#FFF4D5); border-color:var(--midnight,#181D2E)}
.d3-tools select{min-height:48px; border:1.5px solid var(--gray,#C2BAA0); border-radius:10px; background:#fff; color:var(--midnight,#181D2E); font:inherit; padding:0 10px}
.d3-up{display:inline-flex; align-items:center; gap:8px; font-weight:600}
.d3-help{color:var(--ink2,#6B7082); font-size:15px}
.d3-parts{padding:0 12px 10px} .d3-parts summary{min-height:44px; display:flex; align-items:center; font-weight:600; cursor:pointer}
.d3-plist{display:grid; grid-template-columns:repeat(auto-fill,minmax(200px,1fr)); gap:2px 12px; font-size:15px}
.d3-plist label{display:flex; gap:8px; align-items:center; min-height:44px}
.d3-plist input{width:22px; height:22px}
.d3v button:focus-visible,.d3v select:focus-visible,.d3v summary:focus-visible,.d3v input:focus-visible{outline:3px solid var(--bright,#F0A721); outline-offset:2px}
@media (max-width:560px){ .d3-stage{height:58vh} .d3-help{flex-basis:100%} }`;
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const REACH = 30;                                          // how far from a corner a tap still finds it, in screen pixels

  let V = null;
  /** The page's viewer (made on first use; three.js must be loaded). attach(host) moves it into a host element. */
  function viewer() {
    if (V) return V;
    const T = root.THREE;
    if (!T || !T.OrbitControls) throw stop("viewer", "The 3D viewer isn't loaded yet.");
    if (!document.getElementById("sf3d-css")) { const s = document.createElement("style"); s.id = "sf3d-css"; s.textContent = CSS; document.head.appendChild(s); }
    const el = document.createElement("div"); el.className = "d3v";
    el.innerHTML = `<div class="d3-stage"><div class="d3-size" hidden></div><div class="d3-meas" hidden></div><div class="d3-tag" hidden></div><div class="d3-hint" hidden></div><div class="d3-note" role="status" hidden></div><div class="d3-menu" role="menu" hidden></div><div class="d3-msg" hidden><span></span></div></div>
      <div class="d3-tools"><button type="button" data-d3t="measure">Measure</button><span class="d3-seg d3-modes" role="group" aria-label="Measure what" hidden><button type="button" data-d3m="dist">Distance</button><button type="button" data-d3m="angle">Angle</button><button type="button" data-d3m="hole">Holes</button></span><button type="button" data-d3t="clear">Clear</button><button type="button" data-d3t="reset">Reset view</button><button type="button" data-d3t="all" hidden>Show all</button>
        <label class="d3-up" hidden>Up <select aria-label="Which way is up"><option value="z">Z</option><option value="y">Y</option><option value="x">X</option></select></label></div>
      <div class="d3-tools d3-look"><span class="d3-seg" role="group" aria-label="View from"><button type="button" data-d3v="iso">3D</button><button type="button" data-d3v="front">Front</button><button type="button" data-d3v="top">Top</button><button type="button" data-d3v="side">Side</button></span><button type="button" data-d3t="flat" aria-pressed="false">Flat</button><button type="button" data-d3t="cut" aria-pressed="false">Cut</button><label class="d3-slide">Explode <input type="range" min="0" max="100" value="0" data-d3x></label></div>
      <div class="d3-tools d3-cutrow" hidden><span class="d3-seg" role="group" aria-label="Cut from"><button type="button" data-d3c="front">From the front</button><button type="button" data-d3c="top">From the top</button><button type="button" data-d3c="side">From the side</button></span><input type="range" min="0" max="100" value="50" data-d3cut aria-label="Where the cut is"><button type="button" data-d3t="flip" aria-pressed="false">Flip</button></div>
      <p class="d3-help">Turn it with one finger or the mouse; pinch or scroll to zoom; double-tap a part to zoom to it. Tap a part for its size, Zoom, Hide, Isolate and See through (with a mouse, right-click it). Flat takes out the perspective, like a drawing. Measure has Distance (two points), Angle (two edges) and Holes (a hole's or a curve's size, then from its centre).</p>
      <details class="d3-parts" hidden><summary></summary><div class="d3-plist"></div></details>`;
    const $ = (s) => el.querySelector(s);
    const stage = $(".d3-stage"), sizeBox = $(".d3-size"), measBox = $(".d3-meas"), tag = $(".d3-tag"), hint = $(".d3-hint"), noteBox = $(".d3-note"), menu = $(".d3-menu"), msgBox = $(".d3-msg");
    const renderer = new T.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
    renderer.setPixelRatio(Math.min(2, root.devicePixelRatio || 1));
    const canvas = renderer.domElement; stage.prepend(canvas);
    const scene = new T.Scene(); scene.background = new T.Color(COLORS.back);
    const camera = new T.PerspectiveCamera(40, 1, 0.01, 100000);
    scene.add(new T.HemisphereLight(0xffffff, 0x8a8478, 0.9));
    const sun = new T.DirectionalLight(0xffffff, 0.7); sun.position.set(1, 2, 1.5); camera.add(sun); scene.add(camera);
    const controls = new T.OrbitControls(camera, canvas); controls.enableDamping = false;
    const ortho = new T.OrthographicCamera(-1, 1, 1, -1, 0.01, 100000); scene.add(ortho);
    let cam = camera;                                             // the camera drawing: perspective, or Flat (orthographic)
    renderer.localClippingEnabled = true;
    const plane = new T.Plane(new T.Vector3(0, 0, -1), 0);        // the section cut
    const cap = new T.Mesh(new T.PlaneGeometry(1, 1), new T.MeshBasicMaterial({ color: COLORS.cap, side: T.DoubleSide, stencilWrite: true, stencilRef: 0,
      stencilFunc: T.NotEqualStencilFunc, stencilFail: T.ReplaceStencilOp, stencilZFail: T.ReplaceStencilOp, stencilZPass: T.ReplaceStencilOp }));
    cap.renderOrder = 2; cap.visible = false; cap.onAfterRender = (r) => r.clearStencil(); scene.add(cap);   // fills the cut faces of solid parts
    const VIEWS = { iso: [1, 0.8, 1.4], front: [0, 0, 1], top: [0, 1, 1e-4], side: [1, 0, 0] };
    const ray = new T.Raycaster();
    const st = { view: null, model: null, parts: [], groups: [], radius: 1, R: 1, measuring: false, pts: [], marks: [], up: "z", onUp: null, upChoice: false, sel: -1,
                 viewKey: "iso", half: 1, cut: null, explode: 0, center0: null, mode: "dist", ang: [], hole: [], angTag: null };

    function draw() { if (!st.model) return; renderer.render(scene, cam); placeTag(); }
    controls.addEventListener("change", draw);
    controls.addEventListener("end", () => {                     // turned away from a standard view: it's no longer that view
      if (st.viewKey && curDir().dot(new T.Vector3(...VIEWS[st.viewKey]).normalize()) < 0.9998) { st.viewKey = null; paintLook(); } });
    function resize() {
      const w = stage.clientWidth, h = stage.clientHeight;
      if (!w || !h) return;
      renderer.setSize(w, h, false); camera.aspect = w / Math.max(1, h); camera.updateProjectionMatrix(); sizeOrtho(); draw();
    }
    if (root.ResizeObserver) new ResizeObserver(resize).observe(stage); else root.addEventListener("resize", resize);
    canvas.addEventListener("webglcontextlost", (e) => e.preventDefault());
    canvas.addEventListener("webglcontextrestored", () => draw());
    el.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenu(); });

    // a tap (not a turn) while measuring: under 8 px of movement, under half a second
    let down = null, lastTap = null;
    canvas.addEventListener("pointerdown", (e) => { closeMenu(); down = e.isPrimary ? { x: e.clientX, y: e.clientY, t: Date.now(), b: e.button } : null; });
    canvas.addEventListener("pointerup", (e) => {
      if (!down) return;
      const still = Math.hypot(e.clientX - down.x, e.clientY - down.y) < 8;
      if (down.b === 2) { if (still) openMenu(e.clientX, e.clientY); }          // a right-click (a drag slides the view)
      else if (still && Date.now() - down.t < 500) {
        const now = Date.now(), twice = !st.measuring && lastTap && now - lastTap.t < 400 && Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 24;
        lastTap = twice ? null : { t: now, x: e.clientX, y: e.clientY };
        if (twice) { const i = partAt(e.clientX, e.clientY); if (i >= 0) zoomTo(i); }       // a double-tap or double-click: zoom to that part
        else if (st.measuring) tap(e.clientX, e.clientY); else pick(e.clientX, e.clientY);
      }
      down = null;
    });
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());

    function disposeModel() {
      if (!st.model) return;
      scene.remove(st.model);
      st.model.traverse(o => { if (o.geometry) o.geometry.dispose(); if (o.material) o.material.dispose(); });
      st.model = null; st.parts = []; st.marks = []; st.pts = [];
    }
    function applyUp() {                                     // three.js draws Y up
      st.model.rotation.set(0, 0, 0);
      if (st.up === "z") st.model.rotation.x = -Math.PI / 2; else if (st.up === "x") st.model.rotation.z = Math.PI / 2;
      st.model.updateMatrixWorld(true);
    }
    const curDir = () => cam.position.clone().sub(controls.target).normalize();
    function shownBox() {
      const box = new T.Box3(), vis = st.parts.filter(p => p.grp.visible);
      (vis.length ? vis : st.parts).forEach(p => box.expandByObject(p.mesh));
      return box;
    }
    function sizeOrtho() { const a = camera.aspect || 1, h = st.half || 1; ortho.left = -h * a; ortho.right = h * a; ortho.top = h; ortho.bottom = -h; ortho.updateProjectionMatrix(); }
    /** both cameras on a box from a direction, with a margin (so Flat can switch either way) */
    function fitTo(box, dir) {
      const c = box.isEmpty() ? new T.Vector3() : box.getCenter(new T.Vector3()), r = box.isEmpty() ? 1 : (box.getSize(new T.Vector3()).length() / 2 || 1);
      st.radius = r; controls.target.copy(c);
      const fit = r / Math.sin(camera.fov * Math.PI / 360) * 1.2 / Math.min(1, camera.aspect);   // the whole shape in view, with a margin
      camera.position.copy(c).addScaledVector(dir, fit); camera.near = r / 1000; camera.far = r * 100 + fit; camera.updateProjectionMatrix();
      ortho.position.copy(camera.position); ortho.near = r / 1000; ortho.far = r * 100 + fit; ortho.zoom = 1;
      st.half = r * 1.2 / Math.min(1, camera.aspect); sizeOrtho();
      controls.update(); draw();
    }
    /** frame what's shown: from a standard view (iso, front, top, side), or from where it's looked at now */
    function frame(key) {
      if (!st.model) return;
      if (key) st.viewKey = key;
      fitTo(shownBox(), st.viewKey ? new T.Vector3(...VIEWS[st.viewKey]).normalize() : curDir());
      paintLook();
    }
    function zoomTo(i) { const p = st.parts[i]; if (p && st.model) fitTo(new T.Box3().expandByObject(p.mesh), curDir()); }
    /** Flat: an orthographic camera, no perspective; the same view, the same size on screen */
    function setFlat(on) {
      if (!st.model || on === (cam === ortho)) return;
      const t = controls.target, d = cam.position.clone().sub(t), tan = Math.tan(camera.fov * Math.PI / 360);
      if (on) { st.half = d.length() * tan; ortho.position.copy(camera.position); ortho.quaternion.copy(camera.quaternion); ortho.zoom = 1;
                ortho.near = st.radius / 1000; ortho.far = d.length() + st.radius * 100; sizeOrtho(); cam = ortho; }
      else { camera.position.copy(t).addScaledVector(d.normalize(), st.half / (ortho.zoom || 1) / tan); camera.updateProjectionMatrix(); cam = camera; }
      cam.add(sun); controls.object = cam; controls.update(); paintLook(); draw();
    }
    const AX = { side: 0, top: 1, front: 2 };
    /** the section cut: a plane square to the chosen view, at t of the way through; what's nearer that view is taken away */
    function applyCut() {
      const on = !!(st.cut && st.model), planes = on ? [plane] : [];
      for (const p of st.parts) {
        for (const m of [p.mesh.material, p.lines.material, p.sb.material, p.sf.material]) if ((m.clippingPlanes || []).length !== planes.length) { m.clippingPlanes = planes; m.needsUpdate = true; }
        p.sb.visible = p.sf.visible = on;
      }
      cap.visible = on;
      if (on) {
        const box = new T.Box3(); st.parts.forEach(p => box.expandByObject(p.mesh));
        const k = AX[st.cut.from] ?? 2, lo = box.min.getComponent(k), hi = box.max.getComponent(k), at = lo + (hi - lo) * st.cut.t;
        const n = new T.Vector3(); n.setComponent(k, st.cut.flip ? 1 : -1);
        plane.set(n, st.cut.flip ? -at : at);
        const c = box.getCenter(new T.Vector3()); c.setComponent(k, at);
        const sz = box.getSize(new T.Vector3()).length() * 2 || 1;
        cap.position.copy(c); cap.lookAt(c.clone().add(n)); cap.scale.set(sz, sz, 1); cap.updateMatrixWorld();
      }
      paintLook(); draw();
    }
    const kept = (w) => !st.cut || plane.distanceToPoint(w) >= -1e-6 * Math.max(1, st.R);
    const keptAt = (x, y, z) => !st.cut || kept(new T.Vector3(x, y, z).applyMatrix4(st.model.matrixWorld));
    /** Explode: each part moves out from the middle, up to 1.5 times as far; measuring still works, as assembled */
    function applyExplode(v) {
      if (!st.model) return;
      st.explode = v; const c = st.center0;
      for (const p of st.parts) p.grp.position.set((p.c0.x - c.x) * v, (p.c0.y - c.y) * v, (p.c0.z - c.z) * v);
      st.model.updateMatrixWorld(true);
      if (st.pts.length || st.ang.length || st.hole.length) drawMarks();     // the marks ride with their parts
      if (st.cut) applyCut(); else draw();
      paintMeasure();
    }
    function paintLook() {
      el.querySelectorAll("[data-d3v]").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.d3v === st.viewKey)));
      $('[data-d3t="flat"]').setAttribute("aria-pressed", String(cam === ortho));
      $('[data-d3t="cut"]').setAttribute("aria-pressed", String(!!st.cut));
      $(".d3-cutrow").hidden = !st.cut;
      if (st.cut) {
        el.querySelectorAll("[data-d3c]").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.d3c === st.cut.from)));
        $("[data-d3cut]").value = String(Math.round(st.cut.t * 100)); $('[data-d3t="flip"]').setAttribute("aria-pressed", String(!!st.cut.flip));
      }
    }
    /** screen position (page pixels) of a point in the model's own inches */
    function screenOf(p) {
      const v = new T.Vector3(p[0], p[1], p[2]).applyMatrix4(st.model.matrixWorld).project(cam), r = canvas.getBoundingClientRect();
      return { x: r.left + (v.x + 1) / 2 * r.width, y: r.top + (1 - v.y) / 2 * r.height, z: v.z };
    }
    /** is this point (model inches) in plain sight? If not, which part is in the way */
    function sight(p, meshes) {
      const w = new T.Vector3(p[0], p[1], p[2]).applyMatrix4(st.model.matrixWorld);
      let eye, dist;
      if (cam === ortho) { dist = Math.max(st.R, st.radius) * 50; eye = w.clone().addScaledVector(cam.getWorldDirection(new T.Vector3()), -dist); }   // Flat: straight back along the view
      else { eye = cam.position; dist = w.distanceTo(eye); }
      ray.set(eye, w.clone().sub(eye).normalize()); ray.near = 0; ray.far = dist;
      const h = ray.intersectObjects(meshes, false).find(x => kept(x.point));             // what the cut took away is in no one's way
      const ok = !h || h.distance >= dist - Math.max(st.radius * 0.004, 1e-4);
      return { ok, by: ok ? null : (st.parts.find(x => x.mesh === h.object) || null) };
    }
    const shownMeshes = () => st.parts.filter(p => p.grp.visible && !p.ghost).map(p => p.mesh);   // what can be in the way (not see-through parts)
    /** the point of an edge (6 numbers from g at i) nearest a ray (model space): exact on the 3D edge */
    function nearestOnEdge(O, D, g, i) {
      const ax = g[i], ay = g[i + 1], az = g[i + 2], vx = g[i + 3] - ax, vy = g[i + 4] - ay, vz = g[i + 5] - az;
      const wx = O.x - ax, wy = O.y - ay, wz = O.z - az;
      const a = D.x * D.x + D.y * D.y + D.z * D.z, b = D.x * vx + D.y * vy + D.z * vz, c = vx * vx + vy * vy + vz * vz;
      const d = D.x * wx + D.y * wy + D.z * wz, e = vx * wx + vy * wy + vz * wz, den = a * c - b * b;
      let t = den > 1e-12 ? (a * e - b * d) / den : (c ? e / c : 0);
      t = Math.max(0, Math.min(1, t));
      return [ax + t * vx, ay + t * vy, az + t * vz];
    }
    /** the foot of the square from point p onto an edge [ax,ay,az,bx,by,bz], or null if it falls off the edge or p is on the edge's line */
    function squareFoot(p, e) {
      const vx = e[3] - e[0], vy = e[4] - e[1], vz = e[5] - e[2], c = vx * vx + vy * vy + vz * vz;
      if (!c) return null;
      const t = ((p[0] - e[0]) * vx + (p[1] - e[1]) * vy + (p[2] - e[2]) * vz) / c;
      if (t < -1e-6 || t > 1 + 1e-6) return null;
      const f = [e[0] + t * vx, e[1] + t * vy, e[2] + t * vz];
      return Math.hypot(f[0] - p[0], f[1] - p[1], f[2] - p[2]) > 1e-4 ? f : null;
    }
    function parallel(e1, e2) {
      const u = [e1[3] - e1[0], e1[4] - e1[1], e1[5] - e1[2]], v = [e2[3] - e2[0], e2[4] - e2[1], e2[5] - e2[2]];
      const lu = Math.hypot(u[0], u[1], u[2]), lv = Math.hypot(v[0], v[1], v[2]);
      if (!lu || !lv) return false;
      const cx = u[1] * v[2] - u[2] * v[1], cy = u[2] * v[0] - u[0] * v[2], cz = u[0] * v[1] - u[1] * v[0];
      return Math.hypot(cx, cy, cz) / (lu * lv) < 0.01;                 // within about half a degree
    }
    function note(html) { noteBox.hidden = !html; noteBox.innerHTML = html || ""; paintMeasure(); }
    // A tap finds the nearest corner, or the nearest point along an edge (a corner wins a close call), within reach of the
    // finger. Something in the way never gets picked through: the tap says what's in the way and offers to hide it. With
    // nothing to snap to in reach, it takes the point on the surface and says it's approximate.
    function snapAt(cx, cy, want) {
      const r = canvas.getBoundingClientRect(), shown = st.parts.filter(p => p.grp.visible), meshes = shown.map(p => p.mesh), solid = shown.filter(p => !p.ghost).map(p => p.mesh);
      ray.setFromCamera(new T.Vector2((cx - r.left) / r.width * 2 - 1, -((cy - r.top) / r.height) * 2 + 1), cam); ray.near = 0; ray.far = Infinity;
      const hits = ray.intersectObjects(meshes, false).filter(h => kept(h.point)), hit = hits.find(h => solid.includes(h.object)) || hits[0];
      const inv = new T.Matrix4().copy(st.model.matrixWorld).invert();
      const O = ray.ray.origin.clone().applyMatrix4(inv), D = ray.ray.direction.clone().transformDirection(inv);
      const m = new T.Matrix4().multiplyMatrices(cam.projectionMatrix, cam.matrixWorldInverse).multiply(st.model.matrixWorld), e = m.elements;
      const toScreen = (x, y, z) => {
        const w = e[3] * x + e[7] * y + e[11] * z + e[15]; if (w <= 0) return null;
        const nz = (e[2] * x + e[6] * y + e[10] * z + e[14]) / w; if (nz > 1 || nz < -1) return null;
        return [r.left + ((e[0] * x + e[4] * y + e[8] * z + e[12]) / w + 1) / 2 * r.width, r.top + (1 - (e[1] * x + e[5] * y + e[9] * z + e[13]) / w) / 2 * r.height];
      };
      const cands = [];
      for (const part of shown) {
        // a part may be exploded out: it's tapped where it's drawn (its own place plus o), and its points are kept in its own,
        // assembled place, so every number is the design's
        const o = part.grp.position;
        if (want.corners) {
          const c = part.corners;
          for (let i = 0; i < c.length; i += 3) {
            const s = toScreen(c[i] + o.x, c[i + 1] + o.y, c[i + 2] + o.z); if (!s) continue;
            const d = Math.hypot(s[0] - cx, s[1] - cy);
            if (d < REACH && keptAt(c[i] + o.x, c[i + 1] + o.y, c[i + 2] + o.z)) cands.push({ d, p: [c[i], c[i + 1], c[i + 2]], part, kind: "corner" });
          }
        }
        if (want.edges) {
          const g = part.segs, Op = { x: O.x - o.x, y: O.y - o.y, z: O.z - o.z };   // the finger's ray, in the part's own place
          for (let i = 0; i < g.length; i += 6) {
            const a = toScreen(g[i] + o.x, g[i + 1] + o.y, g[i + 2] + o.z), b = toScreen(g[i + 3] + o.x, g[i + 4] + o.y, g[i + 5] + o.z); if (!a || !b) continue;
            const vx = b[0] - a[0], vy = b[1] - a[1], L = vx * vx + vy * vy;
            const t = L ? Math.max(0, Math.min(1, ((cx - a[0]) * vx + (cy - a[1]) * vy) / L)) : 0;
            const d = Math.hypot(a[0] + t * vx - cx, a[1] + t * vy - cy);
            if (d < REACH - 4) { const q = nearestOnEdge(Op, D, g, i); if (keptAt(q[0] + o.x, q[1] + o.y, q[2] + o.z)) cands.push({ d: d + 4, p: q, part, kind: "edge", edge: Array.from(g.subarray(i, i + 6)) }); }
          }
        }
      }
      cands.sort((x, y) => x.d - y.d);
      let hidden = null; const tried = new Set();
      for (const c of cands) {
        if (hidden && c.d > hidden.d + 4) break;                  // aimed at something hidden: don't jump to something a few pixels off
        const k = c.p.map(v => v.toFixed(4)).join(","); if (tried.has(k)) continue; tried.add(k);
        if (tried.size > 60) break;
        const s = sight(disp(c.p, c.part), solid);
        if (s.ok) return { c };
        if (!hidden) hidden = { ...c, by: s.by };
      }
      if (hidden) return { hidden };
      if (hit) { const local = hit.point.clone().applyMatrix4(inv), hp = st.parts.find(q => q.mesh === hit.object) || null, o = hp ? hp.grp.position : { x: 0, y: 0, z: 0 };
                 return { surface: [local.x - o.x, local.y - o.y, local.z - o.z], part: hp }; }
      return {};
    }
    function hiddenNote(h) {
      const what = h.kind === "corner" ? "corner" : "edge", by = h.by;
      if (by && by !== h.part) return note(`That ${what} is behind ${esc(by.name)}. Turn the model to see it, or <button type="button" data-d3hide="${st.parts.indexOf(by)}">Hide ${esc(by.name)}</button>`);
      return note(`That ${what} is on the far side. Turn the model to see it.`);
    }
    function tap(cx, cy) {
      if (!st.model) return;
      note(null);
      if (st.mode === "angle") return tapAngle(cx, cy);
      if (st.mode === "hole") return tapHole(cx, cy);
      const s = snapAt(cx, cy, { corners: true, edges: true });
      if (s.c) return place(s.c);
      if (s.hidden) return hiddenNote(s.hidden);
      if (s.surface) place({ p: s.surface, kind: "surface", part: s.part });
    }
    // small vector helpers (model inches, as [x, y, z])
    const vsub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]], vadd = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
    const vsc = (a, k) => [a[0] * k, a[1] * k, a[2] * k], vdot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const vcross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    const vlen = (a) => Math.hypot(a[0], a[1], a[2]), vnorm = (a) => { const l = vlen(a) || 1; return vsc(a, 1 / l); };
    const disp = (p, part) => { const o = part && part.grp.position; return o ? [p[0] + o.x, p[1] + o.y, p[2] + o.z] : p; };   // where a point is drawn now
    const apart = (a, b) => st.explode > 0 && !!a && !!b && a !== b;                // two parts, pulled apart on screen
    /** each outline edge of a part once (a face's outline and its neighbour's share edges), and which meet at each point */
    function edgeIndex(part) {
      if (part.ei) return part.ei;
      const g = part.segs, key = (x, y, z) => `${Math.round(x * 1e4)},${Math.round(y * 1e4)},${Math.round(z * 1e4)}`;
      const segs = [], at = new Map(), byPair = new Map();
      for (let i = 0; i < g.length; i += 6) {
        const ka = key(g[i], g[i + 1], g[i + 2]), kb = key(g[i + 3], g[i + 4], g[i + 5]); if (ka === kb) continue;
        const pk = ka < kb ? ka + "|" + kb : kb + "|" + ka; if (byPair.has(pk)) continue;
        const n = segs.length; byPair.set(pk, n);
        segs.push({ a: [g[i], g[i + 1], g[i + 2]], b: [g[i + 3], g[i + 4], g[i + 5]], ka, kb });
        for (const k of [ka, kb]) { const l = at.get(k); if (l) l.push(n); else at.set(k, [n]); }
      }
      return (part.ei = { segs, at, byPair, key });
    }
    /** the smooth run of outline edges through a tapped one (turning under 35° at each point): its points in order */
    function chainFrom(part, edge) {
      const ei = edgeIndex(part), ka = ei.key(edge[0], edge[1], edge[2]), kb = ei.key(edge[3], edge[4], edge[5]);
      const s0 = ei.byPair.get(ka < kb ? ka + "|" + kb : kb + "|" + ka); if (s0 === undefined) return null;
      const S = ei.segs[s0], used = new Set([s0]), smooth = Math.cos(35 * Math.PI / 180);
      const walk = (fromKey, d, stopKey) => {
        const out = []; let fk = fromKey, pd = d;
        for (let n = 0; n < 20000; n++) {
          let best = -1, bc = smooth, bd = null;
          for (const j of ei.at.get(fk) || []) {
            if (used.has(j)) continue;
            const q = ei.segs[j], fwd = q.ka === fk, dj = vnorm(vsub(fwd ? q.b : q.a, fwd ? q.a : q.b)), c = vdot(dj, pd);
            if (c > bc) { bc = c; best = j; bd = dj; }
          }
          if (best < 0) return { pts: out, closed: false };
          const q = ei.segs[best], fwd = q.ka === fk, far = fwd ? q.kb : q.ka; used.add(best);
          if (far === stopKey) return { pts: out, closed: true };
          out.push(fwd ? q.b : q.a); fk = far; pd = bd;
        }
        return { pts: out, closed: false };
      };
      const f = walk(S.kb, vnorm(vsub(S.b, S.a)), S.ka);
      if (f.closed) return { pts: [S.a, S.b, ...f.pts], i0: 0, closed: true };
      const bk = walk(S.ka, vnorm(vsub(S.a, S.b)), null);
      return { pts: [...bk.pts.reverse(), S.a, S.b, ...f.pts], i0: bk.pts.length, closed: false };
    }
    function circle3(a, b, c) {                                   // the circle through three points, or null if they're in a line
      const ab = vsub(b, a), ac = vsub(c, a), n = vcross(ab, ac), nn = vdot(n, n);
      if (!nn || Math.sqrt(nn) < 1e-5 * vlen(ab) * vlen(ac)) return null;
      const cc = vadd(a, vsc(vadd(vsc(vcross(n, ab), vdot(ac, ac)), vsc(vcross(ac, n), vdot(ab, ab))), 1 / (2 * nn)));
      return { c: cc, r: vlen(vsub(a, cc)), n: vsc(n, 1 / Math.sqrt(nn)) };
    }
    /** a round edge: the circle its outline points lie on (the shape's points sit exactly on the curve), grown from the tap
        along the run while every point stays on it; a full circle when it goes all the way round. Straight: null. */
    function roundAt(part, edge) {
      const ch = chainFrom(part, edge); if (!ch || ch.pts.length < 3) return null;
      let P = ch.pts, i0 = ch.i0; const n = P.length;
      if (ch.closed) { const h = n >> 1, k = ((i0 - h) % n + n) % n; P = P.slice(k).concat(P.slice(0, k)); i0 = h; }
      // A curve comes in even pieces (the STEP engine cuts it by angle); a straight edge beside it is one long piece. So a
      // circle only grows over pieces like the tapped one, and a tapped piece with no piece like it beside it is straight.
      const len = (i) => vlen(vsub(P[i + 1], P[i])), L0 = len(i0), lastSeg = ch.closed ? n - 1 : n - 2;
      const like = (i) => i >= 0 && i <= Math.min(lastSeg, n - 2) && len(i) < 2 * L0 && len(i) > L0 / 2;
      let lo = i0, hi = i0 + 1;
      if (like(i0 - 1)) lo = i0 - 1; else if (like(i0 + 1)) hi = i0 + 2; else return null;
      let C = circle3(P[lo], P[(lo + hi) >> 1], P[hi]); if (!C) return null;                  // in a line: straight
      const tol = (c) => 3e-4 + 1e-4 * c.r, on = (p, c) => Math.abs(vdot(vsub(p, c.c), c.n)) < tol(c) && Math.abs(vlen(vsub(p, c.c)) - c.r) < tol(c);
      let offLo = false, offHi = false;                           // did the curve leave the circle (not just end)?
      for (let grew = true; grew; ) {
        grew = false;
        if (!offLo && lo > 0 && like(lo - 1)) { if (on(P[lo - 1], C)) { lo--; grew = true; } else offLo = true; }
        if (!offHi && hi < n - 1 && like(hi)) { if (on(P[hi + 1], C)) { hi++; grew = true; } else offHi = true; }
        if (grew && (hi - lo) % 6 === 0) C = circle3(P[lo], P[(lo + hi) >> 1], P[hi]) || C;
      }
      const F = circle3(P[lo], P[(lo + hi) >> 1], P[hi]), run = P.slice(lo, hi + 1);
      if (!F || run.length < 4 || !run.every(p => on(p, F)) || ((offLo || offHi) && run.length < 6)) return { curved: true };
      let sweep = 0;
      for (let i = 1; i < run.length; i++) sweep += Math.acos(Math.max(-1, Math.min(1, vdot(vnorm(vsub(run[i - 1], F.c)), vnorm(vsub(run[i], F.c))))));
      const full = ch.closed && lo === 0 && hi === n - 1;
      return { circle: F, run, full, sweep: full ? 360 : sweep * 180 / Math.PI };
    }
    const lineFoot = (p, e) => { const a = e.slice(0, 3), d = vsub(e.slice(3), a), c = vdot(d, d) || 1; return vadd(a, vsc(d, vdot(vsub(p, a), d) / c)); };
    // Angle: two edges; the angle where their lines meet, between the parts that were tapped (a curve uses its tangent there)
    function tapAngle(cx, cy) {
      const s = snapAt(cx, cy, { corners: false, edges: true });
      if (s.hidden) return hiddenNote(s.hidden);
      if (!s.c) return note("Tap right on an edge.");
      if (st.ang.length >= 2) clearMeasure();
      const c = s.c, rd = roundAt(c.part, c.edge);
      const dir = rd && rd.circle ? vnorm(vcross(rd.circle.n, vsub(c.p, rd.circle.c))) : vnorm(vsub(c.edge.slice(3), c.edge.slice(0, 3)));
      st.ang.push({ p: c.p, dir, edge: c.edge, approx: !!(rd && rd.curved), part: c.part });
      drawMarks(); paintMeasure();
    }
    function angleResult() {
      if (st.ang.length < 2) return null;
      const [a, b] = st.ang, B = vdot(a.dir, b.dir), den = 1 - B * B, approx = a.approx || b.approx;
      if (den < 1e-8) return { parallel: true, approx };
      const w = vsub(a.p, b.p), Dd = vdot(a.dir, w), E = vdot(b.dir, w), s = (B * E - Dd) / den, t = (E - B * Dd) / den;
      const X1 = vadd(a.p, vsc(a.dir, s)), X2 = vadd(b.p, vsc(b.dir, t));
      const arm = (q, X) => { let u = vsub(q.p, X); if (vlen(u) < 1e-6) { const e0 = q.edge.slice(0, 3), e1 = q.edge.slice(3); u = vsub(vlen(vsub(e0, X)) > vlen(vsub(e1, X)) ? e0 : e1, X); } return u; };
      const u = arm(a, X1), v = arm(b, X2), deg = Math.acos(Math.max(-1, Math.min(1, vdot(vnorm(u), vnorm(v))))) * 180 / Math.PI;
      return { deg, other: 180 - deg, X: vsc(vadd(X1, X2), 0.5), X1, X2, u, v, meet: vlen(vsub(X1, X2)) < 1e-3, approx };
    }
    // Holes: a round edge's size and centre; a second tap measures from that centre (to another centre, or square to an edge)
    function tapHole(cx, cy) {
      const s = snapAt(cx, cy, { corners: false, edges: true });
      if (s.hidden) return hiddenNote(s.hidden);
      if (!s.c) return note("Tap right on the rim of a hole or on a curved edge.");
      const c = s.c, rd = roundAt(c.part, c.edge);
      const round = rd && rd.circle ? { kind: "round", c: rd.circle.c, r: rd.circle.r, n: rd.circle.n, full: rd.full, sweep: rd.sweep, run: rd.run, p: rd.circle.c, part: c.part } : null;
      if (st.hole.length !== 1) {
        if (!round) return note(rd && rd.curved ? "That curve isn't part of a circle, so it has no one size." : "That edge is straight. Tap the rim of a hole or a curved edge.");
        clearMeasure(); st.hole = [round];
      } else st.hole.push(round || { kind: "edge", p: lineFoot(st.hole[0].c, c.edge), edge: c.edge, part: c.part });
      drawMarks(); paintMeasure();
    }
    function addDot(p) {
      const d = new T.Mesh(new T.SphereGeometry(st.radius * 0.012, 16, 12), new T.MeshBasicMaterial({ color: COLORS.mark, depthTest: false }));
      d.position.set(p[0], p[1], p[2]); d.renderOrder = 10; st.model.add(d); st.marks.push(d);
    }
    function addLine(pts, closed) {
      const g = new T.BufferGeometry().setFromPoints(pts.map(p => new T.Vector3(p[0], p[1], p[2])));
      const L = new (closed ? T.LineLoop : T.Line)(g, new T.LineBasicMaterial({ color: COLORS.mark, depthTest: false })); L.renderOrder = 10; st.model.add(L); st.marks.push(L);
    }
    function clearMarks() { for (const m of st.marks) { if (st.model) st.model.remove(m); if (m.geometry) m.geometry.dispose(); if (m.material) m.material.dispose(); } st.marks = []; }
    function drawMarks() {                                        // what's been picked, drawn over the model where its parts are now
      clearMarks(); st.angTag = null;
      if (st.mode === "dist") {
        const P = st.pts.map(q => disp(q.p, q.part));
        P.forEach(addDot); if (P.length === 2) addLine(P);
      } else if (st.mode === "angle") {
        for (const q of st.ang) addLine([disp(q.edge.slice(0, 3), q.part), disp(q.edge.slice(3), q.part)]);
        const a = angleResult();
        if (a && !a.parallel) {
          const [A, B] = st.ang;
          addLine([disp(a.X1, A.part), disp(A.p, A.part)]); addLine([disp(a.X2, B.part), disp(B.p, B.part)]);
          const u = vnorm(a.u), v = vnorm(a.v), r = Math.max(Math.min(vlen(a.u), vlen(a.v)) * 0.6, st.radius * 0.04);   // the arc, big enough to see
          let w = vsub(v, vsc(u, vdot(u, v))); w = vlen(w) > 1e-6 ? vnorm(w) : vnorm(vcross(u, Math.abs(u[1]) < 0.9 ? [0, 1, 0] : [1, 0, 0]));
          const th = a.deg * Math.PI / 180, arc = [];
          for (let k = 0; k <= 32; k++) { const f = th * k / 32; arc.push(disp(vadd(a.X, vadd(vsc(u, r * Math.cos(f)), vsc(w, r * Math.sin(f)))), A.part)); }
          addLine(arc); st.angTag = disp(vadd(a.X, vadd(vsc(u, r * 1.45 * Math.cos(th / 2)), vsc(w, r * 1.45 * Math.sin(th / 2)))), A.part);
        }
      } else if (st.mode === "hole") {
        for (const h of st.hole) {
          if (h.kind === "round") addLine(h.run.map(q => disp(q, h.part)), h.full); else addLine([disp(h.edge.slice(0, 3), h.part), disp(h.edge.slice(3), h.part)]);
          addDot(disp(h.p, h.part));
        }
        if (st.hole.length === 2) addLine([disp(st.hole[0].c, st.hole[0].part), disp(st.hole[1].p, st.hole[1].part)]);
      }
      draw();
    }
    /** Measure off: a tap on a part outlines it and shows its size (along X, Y and Z, as drawn); a tap off the model clears it */
    function partAt(cx, cy) {
      if (!st.model) return -1;
      const r = canvas.getBoundingClientRect(), shown = st.parts.filter(p => p.grp.visible);
      ray.setFromCamera(new T.Vector2((cx - r.left) / r.width * 2 - 1, -((cy - r.top) / r.height) * 2 + 1), cam); ray.near = 0; ray.far = Infinity;
      const hits = ray.intersectObjects(shown.map(p => p.mesh), false).filter(h => kept(h.point));
      const hit = hits.find(h => !(st.parts.find(p => p.mesh === h.object) || {}).ghost) || hits[0];   // a solid part before a see-through one
      return hit ? st.parts.findIndex(p => p.mesh === hit.object) : -1;
    }
    function pick(cx, cy) { if (!st.model) return; if (st.pts.length) clearMeasure(); select(partAt(cx, cy)); }   // a part's card replaces an old measurement
    /** the component a part belongs to, if it's a sub-component with more than this one part (a body loose in the design has none) */
    function compOf(i) {
      const p = st.parts[i], g = p && st.groups[p.group];
      if (!g || g.path.length < 2) return null;
      const list = st.parts.map((q, j) => q.group === p.group ? j : -1).filter(j => j >= 0);
      return list.length > 1 ? { name: g.name, list } : null;
    }
    const hiddenCount = () => st.parts.filter(p => !p.grp.visible).length, ghostCount = () => st.parts.filter(p => p.ghost).length;
    const changedText = () => [hiddenCount() && `${hiddenCount()} hidden`, ghostCount() && `${ghostCount()} see-through`].filter(Boolean).join(", ");
    function partActions(i) {                                     // the right-click menu
      const p = st.parts[i]; if (!p) return "";
      const c = compOf(i), n = esc(p.name), b = (k, label) => `<button type="button" role="menuitem" data-d3do="${k}:${i}">${label}</button>`;
      return b("zoom", `Zoom to ${n}`) + b("hide", `Hide ${n}`) + b("iso", `Isolate ${n}`) + (p.ghost ? b("solid", `Make ${n} solid`) : b("ghost", `See through ${n}`))
        + (c ? b("hidec", `Hide ${esc(c.name)} (${c.list.length} parts)`) + b("isoc", `Isolate ${esc(c.name)}`) + b("ghostc", `See through ${esc(c.name)}`) : "");
    }
    function cardActions(i) {                                     // the same on a tapped part's card, shorter
      const p = st.parts[i]; if (!p) return "";
      const c = compOf(i), b = (k, label) => `<button type="button" data-d3do="${k}:${i}">${label}</button>`;
      return `<div class="d3-acts">${b("zoom", "Zoom")}${b("hide", "Hide")}${b("iso", "Isolate")}${p.ghost ? b("solid", "Solid") : b("ghost", "See through")}</div>`
        + (c ? `<div class="d3-acts"><span>${esc(c.name)} (${c.list.length} parts):</span>${b("hidec", "Hide")}${b("isoc", "Isolate")}${b("ghostc", "See through")}</div>` : "");
    }
    function setGhost(list, on) {                                 // see-through: still there, faint, never in the way
      for (const j of list) { const p = st.parts[j]; if (!p) continue; p.ghost = on;
        const m = p.mesh.material; m.transparent = on; m.opacity = on ? 0.2 : 1; m.depthWrite = !on; m.needsUpdate = true;
        const l = p.lines.material; l.transparent = on; l.opacity = on ? 0.3 : 1; l.needsUpdate = true; }
    }
    function openMenu(cx, cy) {
      const i = partAt(cx, cy), n = changedText();
      const html = (i >= 0 ? partActions(i) : "") + (n ? `<button type="button" role="menuitem" data-d3do="all:0">Show all (${n})</button>` : "");
      if (!html) return closeMenu();
      menu.innerHTML = html; menu.hidden = false;
      const r = stage.getBoundingClientRect();
      menu.style.left = `${Math.max(4, Math.min(cx - r.left, r.width - menu.offsetWidth - 4))}px`;
      menu.style.top = `${Math.max(4, Math.min(cy - r.top, r.height - menu.offsetHeight - 4))}px`;
      const first = menu.querySelector("button"); if (first) first.focus({ preventScroll: true });
    }
    function closeMenu() { if (!menu.hidden) { menu.hidden = true; menu.innerHTML = ""; } }
    function setShown(list, on) { for (const j of list) if (st.parts[j]) st.parts[j].grp.visible = on; if (st.sel >= 0 && !st.parts[st.sel].grp.visible) select(-1); afterShown(); }
    function isolate(list) { st.parts.forEach((p, j) => { p.grp.visible = list.includes(j); }); select(-1); afterShown(); frame(); }
    function showAll() { st.parts.forEach(p => { p.grp.visible = true; }); setGhost(st.parts.map((p, j) => j), false); afterShown(); frame(); }
    function afterShown() { noteBox.hidden = true; noteBox.innerHTML = ""; paintParts(); paintTools(); draw(); paintMeasure(); }
    function paintTools() { const b = $('[data-d3t="all"]'), n = changedText(); b.hidden = !n; b.textContent = `Show all (${n})`; }
    function act(k, i) {
      if (k === "hide") setShown([i], false);
      else if (k === "iso") isolate([i]);
      else if (k === "hidec") { const c = compOf(i); setShown(c ? c.list : [i], false); }
      else if (k === "isoc") { const c = compOf(i); isolate(c ? c.list : [i]); }
      else if (k === "all") showAll();
      else if (k === "zoom") zoomTo(i);
      else if (k === "ghost" || k === "solid") { setGhost([i], k === "ghost"); afterShown(); }
      else if (k === "ghostc") { const c = compOf(i); setGhost(c ? c.list : [i], true); afterShown(); }
    }
    function select(i) {
      const was = st.parts[st.sel]; if (was) was.lines.material.color.setHex(COLORS.edge);
      st.sel = i; const p = st.parts[i]; if (p) p.lines.material.color.setHex(COLORS.mark);
      draw(); paintMeasure();
    }
    function partSize(p) {
      if (!p.size) { p.mesh.geometry.computeBoundingBox(); const b = p.mesh.geometry.boundingBox; p.size = [b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z]; }
      return p.size;
    }
    function place(c) {
      if (st.pts.length >= 2) clearMeasure();
      let p = c.p, square = false;
      const p1 = st.pts[0];
      if (st.pts.length === 1 && c.kind === "edge" && (p1.kind === "corner" || (p1.kind === "edge" && parallel(p1.edge, c.edge)))) {
        const f = squareFoot(p1.p, c.edge);                         // straight across from the first point, as a tape would read it
        if (f && sight(disp(f, c.part), shownMeshes()).ok) { p = f; square = true; }
      }
      st.pts.push({ p, loose: c.kind === "surface", kind: c.kind, edge: c.edge || null, square, part: c.part || null });
      drawMarks(); paintMeasure();
    }
    function clearMeasure() {
      noteBox.hidden = true; noteBox.innerHTML = "";
      for (const m of st.marks) { if (st.model) st.model.remove(m); if (m.geometry) m.geometry.dispose(); if (m.material) m.material.dispose(); }
      st.marks = []; st.pts = []; st.ang = []; st.hole = []; st.angTag = null; paintMeasure(); draw();
    }
    function measured() {
      if (st.pts.length < 2) return null;
      const [a, b] = st.pts, d = [0, 1, 2].map(k => b.p[k] - a.p[k]);
      return { dist: Math.hypot(d[0], d[1], d[2]), d, loose: a.loose || b.loose, square: !!b.square };
    }
    const mm = (x) => `${(x * 25.4).toFixed(2)} mm`;
    function tagInfo() {                                          // the number on the model, where its marks are drawn
      const mid = (a, b) => vsc(vadd(a, b), 0.5);
      if (st.mode === "angle") { const a = angleResult(); return a && !a.parallel && st.angTag ? { at: st.angTag, text: `${a.deg.toFixed(1)}°` } : null; }
      if (st.mode === "hole") {
        const h = st.hole; if (!h.length) return null;
        if (h.length === 1) return { at: disp(h[0].c, h[0].part), text: h[0].full ? `Ø ${(2 * h[0].r).toFixed(3)}"` : `R ${h[0].r.toFixed(3)}"` };
        return { at: mid(disp(h[0].c, h[0].part), disp(h[1].p, h[1].part)), text: `${vlen(vsub(h[1].p, h[0].c)).toFixed(3)}"` };
      }
      const m = measured(); return m ? { at: mid(disp(st.pts[0].p, st.pts[0].part), disp(st.pts[1].p, st.pts[1].part)), text: `${m.dist.toFixed(3)}"` } : null;
    }
    function placeTag() {
      const t = st.model && tagInfo();
      if (!t) { tag.hidden = true; return; }
      const s = screenOf(t.at), r = canvas.getBoundingClientRect();
      tag.hidden = false; tag.textContent = t.text; tag.style.left = `${s.x - r.left}px`; tag.style.top = `${s.y - r.top}px`;
    }
    function hintText() {
      if (st.mode === "angle") return ["Tap the first edge", "Now tap the second edge"][st.ang.length] || "Tap an edge to measure another angle";
      if (st.mode === "hole") return ["Tap the rim of a hole, or a curved edge", "Tap another hole, or an edge, to measure from its centre"][st.hole.length] || "Tap a hole or a curve to start again";
      return st.pts.length === 1 ? "Now tap the second point" : st.pts.length === 2 ? "Tap a corner to measure again" : "Tap a corner or edge to start measuring";
    }
    function resultHtml() {
      if (st.mode === "angle") {
        const a = angleResult(); if (!a) return "";
        if (a.parallel) return `<b>Parallel</b><br><small>The two edges run the same way (0°).</small>`;
        return `<b>${a.deg.toFixed(1)}°</b> between the edges<br><small>${a.other.toFixed(1)}° the other way.${a.meet ? "" : " The edges don't meet: this is the angle between their directions."}${a.approx ? " A curve that isn't round was used, so this is approximate." : ""}${apart(st.ang[0].part, st.ang[1].part) ? " Measured as assembled; the parts are pulled apart on screen." : ""}</small>`;
      }
      if (st.mode === "hole") {
        const h = st.hole; if (!h.length) return "";
        const size = (x) => x.full ? `Ø ${fmtIn(2 * x.r)} · ${mm(2 * x.r)}` : `R ${fmtIn(x.r)} · ${mm(x.r)}`;
        if (h.length === 1) return `<b>${esc(size(h[0]))}</b>${h[0].full ? `<br>R ${esc(fmtIn(h[0].r))} · ${mm(h[0].r)}` : ""}`      // a hole: its radius too (Luke, 1 Nov)
          + `<br><small>${h[0].full ? "A full circle (a hole or a round end)." : `A curve of ${h[0].sweep.toFixed(1)}°; this is its radius.`} Its centre is marked: tap another hole or an edge to measure from it.</small>`;
        const d = vsub(h[1].p, h[0].c), L = vlen(d);
        return `<b>${esc(fmtIn(L))} · ${mm(L)}</b><br>${h[1].kind === "round" ? "Centre to centre" : "From the centre, square to that edge"} · across X ${Math.abs(d[0]).toFixed(3)} · Y ${Math.abs(d[1]).toFixed(3)} · Z ${Math.abs(d[2]).toFixed(3)} in`
          + `<br><small>${esc(size(h[0]))}${h[1].kind === "round" ? ` and ${esc(size(h[1]))}` : ""}</small>`
          + (apart(h[0].part, h[1].part) ? `<br><small>Measured as assembled; the parts are pulled apart on screen.</small>` : "");
      }
      const m = measured(); if (!m) return "";
      return `<b>${esc(fmtIn(m.dist))}</b><br>across X ${Math.abs(m.d[0]).toFixed(3)} · Y ${Math.abs(m.d[1]).toFixed(3)} · Z ${Math.abs(m.d[2]).toFixed(3)} in`
        + (m.loose ? `<br><small>A point wasn't on a corner or edge, so this is approximate.</small>` : "")
        + (m.square && !m.loose ? `<br><small>Measured square across to that edge.</small>` : "")
        + (apart(st.pts[0].part, st.pts[1].part) ? `<br><small>Measured as assembled; the parts are pulled apart on screen.</small>` : "");
    }
    function paintMeasure() {
      hint.hidden = !st.measuring || !st.model || !noteBox.hidden;
      hint.textContent = hintText();
      const b = $('[data-d3t="measure"]'); b.classList.toggle("on", st.measuring); b.textContent = st.measuring ? "Measuring" : "Measure";
      b.setAttribute("aria-pressed", st.measuring ? "true" : "false");
      const modes = $(".d3-modes"); modes.hidden = !st.measuring;
      modes.querySelectorAll("[data-d3m]").forEach(x => x.setAttribute("aria-pressed", String(x.dataset.d3m === st.mode)));
      const sp = !st.measuring && st.parts[st.sel];
      if (sp) {                                                      // a part's size, Measure off
        measBox.hidden = false;
        const c = compOf(st.sel);
        measBox.innerHTML = `<b>${esc(sizeText(partSize(sp)))}</b> in<br>${esc(sp.name)}${c ? ` <small>· in ${esc(c.name)}</small>` : ""}<br><small>Its size along X × Y × Z, as drawn in Fusion.</small>${cardActions(st.sel)}`;
        placeTag(); return;
      }
      const html = resultHtml();
      measBox.hidden = !html; if (html) measBox.innerHTML = html;
      placeTag();
    }
    function paintParts() {
      const box = $(".d3-parts"), v = st.view;
      if (!v || v.parts.length < 2) { box.hidden = true; return; }
      box.hidden = false;
      const n = hiddenCount();
      $(".d3-parts summary").textContent = `Parts (${v.parts.length})${n ? `, ${n} hidden` : ""}: untick one to hide it`;
      const row = (i) => `<label><input type="checkbox" data-d3part="${i}"${st.parts[i] && !st.parts[i].grp.visible ? "" : " checked"}> ${esc(v.parts[i].name)}</label>`;
      const order = v.parts.map((p, i) => i);
      if (st.groups.length > 1) {                                    // grouped by component, in the STEP's order
        order.sort((a, b) => (st.parts[a].group ?? -1) - (st.parts[b].group ?? -1) || a - b);
        let last = null, html = "";
        for (const i of order) { const g = st.groups[st.parts[i].group]; const head = g && g.path.length >= 2 ? g.name : "";
          if (head !== last) { if (head) html += `<div class="d3-ghead">${esc(head)}</div>`; last = head; } html += row(i); }
        $(".d3-plist").innerHTML = html;
      } else $(".d3-plist").innerHTML = order.map(row).join("");
    }
    el.addEventListener("click", (e) => {
      const todo = e.target.closest("[data-d3do]");
      if (todo) { const [k, i] = todo.dataset.d3do.split(":"); closeMenu(); act(k, +i); return; }
      if (!e.target.closest(".d3-menu")) closeMenu();
      const hide = e.target.closest("[data-d3hide]");
      if (hide) {                                                 // the part in the way, out of the way
        const p = st.parts[+hide.dataset.d3hide];
        if (p) { p.grp.visible = false; if (st.sel === +hide.dataset.d3hide) select(-1); paintParts(); paintTools();
                 draw(); note(`${esc(p.name)} is hidden. Tap the ${st.pts.length ? "second point" : "point"} again; tick it under Parts to bring it back.`); }
        return;
      }
      const mb = e.target.closest("[data-d3m]"); if (mb) { st.mode = mb.dataset.d3m; clearMeasure(); return; }
      const vb = e.target.closest("[data-d3v]"); if (vb) { frame(vb.dataset.d3v); return; }
      const cb = e.target.closest("[data-d3c]"); if (cb) { st.cut = { t: 0.5, flip: false, ...(st.cut || {}), from: cb.dataset.d3c }; applyCut(); return; }
      const b = e.target.closest("[data-d3t]"); if (!b) return;
      const k = b.dataset.d3t;
      if (k === "measure") { st.measuring = !st.measuring; if (st.measuring) select(-1); else { noteBox.hidden = true; noteBox.innerHTML = ""; } paintMeasure(); }
      else if (k === "clear") clearMeasure();
      else if (k === "reset") frame("iso");
      else if (k === "all") showAll();
      else if (k === "flat") setFlat(cam !== ortho);
      else if (k === "cut") { st.cut = st.cut ? null : { from: "front", t: 0.5, flip: false }; applyCut(); }
      else if (k === "flip" && st.cut) { st.cut.flip = !st.cut.flip; applyCut(); }
    });
    el.addEventListener("input", (e) => {                       // the sliders, as they move
      const t = e.target;
      if (t.matches("[data-d3x]")) applyExplode(+t.value / 100 * 1.5);
      else if (t.matches("[data-d3cut]") && st.cut) { st.cut.t = +t.value / 100; applyCut(); }
    });
    el.addEventListener("change", (e) => {
      const t = e.target;
      if (t.matches("[data-d3part]")) { const p = st.parts[+t.dataset.d3part]; if (p) { p.grp.visible = t.checked; if (!t.checked && st.sel === +t.dataset.d3part) select(-1); paintTools(); draw(); paintMeasure(); } }
      else if (t.matches(".d3-up select") && st.model) { st.up = t.value; applyUp(); clearMeasure(); frame(); if (st.cut) applyCut(); if (st.onUp) st.onUp(st.up); }
    });

    V = {
      el, state: st, measured, screenOf, frame, tap, draw, controls, partAt, compOf, zoomTo, setFlat, plane, cam: () => cam, angle: angleResult, holes: () => st.hole, roundAt: (i, e) => roundAt(st.parts[i], e),
      /** move the viewer into a host element (the page redraws its own; the viewer and what's on it carry over) */
      attach(host) { if (!host) return; if (el.parentNode !== host) host.replaceChildren(el); resize(); },
      /** words over the stage while something is loading or went wrong; null clears them */
      message(text) { msgBox.hidden = !text; msgBox.querySelector("span").textContent = text || ""; if (text) { sizeBox.hidden = true; measBox.hidden = true; tag.hidden = true; hint.hidden = true; } },
      /** show a view file: up is y, z or x; upChoice shows the Up box, and onUp(up) is told when it's changed */
      show(view, opts = {}) {
        disposeModel();
        st.view = view; st.up = ["y", "z", "x"].includes(opts.up) ? opts.up : (view.up || "z"); st.onUp = opts.onUp || null; st.upChoice = !!opts.upChoice;
        st.groups = Array.isArray(view.groups) ? view.groups : []; closeMenu();
        st.measuring = false; st.sel = -1; st.mode = "dist"; st.ang = []; st.hole = [];   // each design starts with Measure off (Distance), nothing picked
        const model = new T.Group();
        view.parts.forEach((p) => {
          const g = new T.BufferGeometry();
          g.setAttribute("position", new T.BufferAttribute(p.pos, 3)); g.setIndex(new T.BufferAttribute(p.idx, 1)); g.computeVertexNormals();
          const own = Array.isArray(p.color) ? p.color : null, look = { roughness: 0.85, metalness: 0.05, polygonOffset: true, polygonOffsetFactor: 1, polygonOffsetUnits: 1 };
          let mat;
          if (Array.isArray(p.face_colors) && p.face_colors.length) {      // a face with its own colour: colour by corner (faces never share corners)
            const base = own || [((COLORS.part >> 16) & 255) / 255, ((COLORS.part >> 8) & 255) / 255, (COLORS.part & 255) / 255];
            const col = new Float32Array(p.pos.length); for (let i = 0; i < col.length; i += 3) col.set(base, i);
            for (const [first, last, cr, cg, cb] of p.face_colors) for (let t = first; t <= last; t++) for (let k = 0; k < 3; k++) col.set([cr, cg, cb], p.idx[t * 3 + k] * 3);
            g.setAttribute("color", new T.BufferAttribute(col, 3));
            mat = new T.MeshStandardMaterial({ vertexColors: true, ...look });
          } else mat = new T.MeshStandardMaterial({ color: own ? new T.Color(own[0], own[1], own[2]) : new T.Color(COLORS.part), ...look });
          const mesh = new T.Mesh(g, mat);
          const eg = new T.BufferGeometry(); eg.setAttribute("position", g.getAttribute("position")); eg.setIndex(new T.BufferAttribute(p.edges, 1));
          const lines = new T.LineSegments(eg, new T.LineBasicMaterial({ color: COLORS.edge }));
          mesh.renderOrder = 3; lines.renderOrder = 3;
          const grp = new T.Group(); grp.add(mesh); grp.add(lines); model.add(grp);
          const sMat = (side, op) => new T.MeshBasicMaterial({ depthWrite: false, depthTest: false, colorWrite: false, stencilWrite: true, stencilFunc: T.AlwaysStencilFunc, side, stencilFail: op, stencilZFail: op, stencilZPass: op });
          const sb = new T.Mesh(g, sMat(T.BackSide, T.IncrementWrapStencilOp)), sf = new T.Mesh(g, sMat(T.FrontSide, T.DecrementWrapStencilOp));   // mark where the cut is inside a part
          sb.renderOrder = sf.renderOrder = 1; sb.visible = sf.visible = false; grp.add(sb); grp.add(sf);
          g.computeBoundingBox(); const c0 = g.boundingBox.getCenter(new T.Vector3());
          const seen = new Set(), corners = [], segs = new Float32Array(p.edges.length * 3);
          for (const i of p.edges) if (!seen.has(i)) { seen.add(i); corners.push(p.pos[i * 3], p.pos[i * 3 + 1], p.pos[i * 3 + 2]); }
          for (let i = 0; i < p.edges.length; i++) segs.set(p.pos.subarray(p.edges[i] * 3, p.edges[i] * 3 + 3), i * 3);   // each edge's two ends
          st.parts.push({ name: p.name, grp, mesh, lines, sb, sf, c0, ghost: false, corners: new Float32Array(corners), segs, group: Number.isInteger(p.group) ? p.group : -1 });
        });
        st.model = model; scene.add(model); applyUp();
        { const b0 = new T.Box3(); st.parts.forEach(p => b0.union(p.mesh.geometry.boundingBox)); st.center0 = b0.getCenter(new T.Vector3()); st.R = b0.getSize(new T.Vector3()).length() / 2 || 1; }
        st.cut = null; st.viewKey = "iso"; st.explode = 0; $("[data-d3x]").value = "0"; $('[data-d3t="measure"]').disabled = false;   // each design starts whole, in 3D
        if (cam !== camera) { cam = camera; cam.add(sun); controls.object = cam; }
        applyCut();
        $(".d3-up").hidden = !st.upChoice; $(".d3-up select").value = st.up;
        sizeBox.hidden = false;
        sizeBox.innerHTML = `Overall <b>${esc(sizeText(view.size))}</b> in<br><small>X × Y × Z, as drawn in Fusion</small>`;
        this.message(null); sizeBox.hidden = false;
        st.pts = []; st.marks = []; paintMeasure(); paintParts(); paintTools(); resize(); frame();
      },
      setUp(up) { if (!st.model || !["y", "z", "x"].includes(up)) return; st.up = up; $(".d3-up select").value = up; applyUp(); clearMeasure(); frame(); if (st.cut) applyCut(); },
      clear() { disposeModel(); st.view = null; sizeBox.hidden = true; measBox.hidden = true; tag.hidden = true; hint.hidden = true; $(".d3-parts").hidden = true; $(".d3-up").hidden = true; renderer.clear(); },
    };
    return V;
  }

  root.SF3D = { VERSION, LIBS, DETAIL, COLORS, b64, unb64, safeName, frac, fmtIn, sizeText, boundaryEdges, buildView, readView, gzip, gunzip,
                needThree, needOcct, convertStep, kept, keep, openDesign, viewer, isNet };
})(window);
