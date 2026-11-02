// 6 Oct: saving to OneDrive and the hard drive (office page + onedrive_save.sql).
// 31 Oct: the Production layout (Delivery, Photos, Job Data), the one-time move of each job's old "shop-floor data"
//   folder, and files coming off Supabase once saved in both places (off_supabase.sql). The off-Supabase part runs
//   only on a database with off_supabase.sql; without it the page says so and the rest still has to pass (the new
//   page on the old database).
//   bash /home/claude/sf/base/fresh.sh            (a fresh seeded copy of sync_base_new, or TEMPLATE=sync_base_old)
//   cd /home/claude/sf/t && SF_MAX_ROWS=2 TZ=America/Indiana/Indianapolis node test_onedrive_save.js
//   SF_MAX_ROWS=2 caps every request at 2 rows and the page asks 2 at a time, so paging is exercised.
//   OLDDB=1 on a database WITHOUT onedrive_save.sql: the page says so and everything else still works.
//   OUT=/home/claude/sf/repo runs it on the live page, where it fails (the old layout).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out";
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 8000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const pageScript = (raw, html, dir) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(dir + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");

// ---------- a folder system like the browser's (File System Access), in memory ----------
let SEQ = 0; const LOG = [];                       // every write, in order: [seq, rootName, path]
const err = (name, msg) => { const e = new Error(msg || name); e.name = name; return e; };
class FFile {
  constructor(name, parent) { this.kind = "file"; this.name = name; this.parent = parent; this.data = new Uint8Array(0); this.writes = 0; }
  async getFile() { const d = this.data; return { size: d.byteLength, text: async () => new TextDecoder().decode(d),          // like Blob.text(): drops a leading BOM
                                                   arrayBuffer: async () => d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength) }; }
  async createWritable() { const f = this, chunks = []; this.root().check();
    return { write: async (x) => { chunks.push(typeof x === "string" ? new TextEncoder().encode(x) : new Uint8Array(x)); },
             close: async () => { const n = chunks.reduce((a, c) => a + c.length, 0), out = new Uint8Array(n); let o = 0; for (const c of chunks) { out.set(c, o); o += c.length; }
               f.data = out; f.writes++; LOG.push([++SEQ, f.root().name, f.path()]); } }; }
  root() { return this.parent.root(); }
  path() { return this.parent.path() + "/" + this.name; }
}
class FDir {
  constructor(name, parent = null) { this.kind = "directory"; this.name = name; this.parent = parent; this.kids = new Map(); this.perm = "granted"; this.gone = false; }
  root() { return this.parent ? this.parent.root() : this; }
  path() { return this.parent ? this.parent.path() + "/" + this.name : this.name; }
  check() { if (this.root().gone) throw err("NotFoundError", "A requested file or directory could not be found"); }
  async *entries() { this.check(); for (const [k, v] of this.kids) yield [k, v]; }
  async *keys() { this.check(); for (const k of this.kids.keys()) yield k; }
  async getDirectoryHandle(n, o = {}) { this.check(); let k = this.kids.get(n);
    if (!k) { if (!o.create) throw err("NotFoundError"); k = new FDir(n, this); this.kids.set(n, k); }
    if (k.kind !== "directory") throw err("TypeMismatchError"); return k; }
  async getFileHandle(n, o = {}) { this.check(); let k = this.kids.get(n);
    if (!k) { if (!o.create) throw err("NotFoundError"); k = new FFile(n, this); this.kids.set(n, k); }
    if (k.kind !== "file") throw err("TypeMismatchError"); return k; }
  async queryPermission() { return this.root().perm; }
  async requestPermission() { this.root().perm = "granted"; return "granted"; }
  async removeEntry(n, o = {}) { this.check(); const k = this.kids.get(n); if (!k) throw err("NotFoundError");
    if (k.kind === "directory" && k.kids.size && !o.recursive) throw err("InvalidModificationError");
    this.kids.delete(n); LOG.push([++SEQ, this.root().name, "DELETE " + this.path() + "/" + n]); }
  async isSameEntry(o) { return o === this; }
  async resolve(o) { const out = []; let x = o; while (x && x !== this) { out.unshift(x.name); x = x.parent; } return x === this ? out : null; }
  dir(...names) { let d = this; for (const n of names) { if (!d.kids.has(n)) d.kids.set(n, new FDir(n, d)); d = d.kids.get(n); } return d; }
  file(...names) { const d = this.dir(...names.slice(0, -1)); const n = names[names.length - 1];
    if (!d.kids.has(n)) d.kids.set(n, new FFile(n, d)); return d.kids.get(n); }
  find(path) { let d = this; for (const n of path.split("/")) { d = d && d.kids ? d.kids.get(n) : null; } return d || null; }
  files() { const out = []; const walk = (d, p) => { for (const [k, v] of d.kids) v.kind === "file" ? out.push(p + k) : walk(v, p + k + "/"); }; walk(this, ""); return out; }
}
const txtOf = (f) => f ? new TextDecoder().decode(f.data) : null;

// a by-reference stand-in for the browser's IndexedDB (a real browser keeps folder handles there)
const IDB = new Map();
const fakeIndexedDB = { open() { const req = {}; setTimeout(() => {
  const db = { createObjectStore() {}, transaction() { const tx = { objectStore() { return {
    get(k) { const r = {}; setTimeout(() => { r.result = IDB.get(k); r.onsuccess && r.onsuccess(); }); return r; },
    put(v, k) { IDB.set(k, v); setTimeout(() => tx.oncomplete && tx.oncomplete()); } }; } }; return tx; } };
  req.result = db; req.onsuccess && req.onsuccess(); }); return req; } };

let PICK = [];                                    // what the folder picker returns next
function boot(user) {
  const raw = fs.readFileSync(`${OUT}/office.html`, "utf8"), html = strip(raw);
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html", pretendToBeVisual: true });
  const w = dom.window;
  w.localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
  w.localStorage.setItem("sfo_tab", JSON.stringify("photos"));
  w.indexedDB = fakeIndexedDB;
  w.supabase = { createClient: () => client };
  w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder;
  w.eval(fs.readFileSync("/home/claude/.npm-global/lib/node_modules/pdf-lib/dist/pdf-lib.min.js", "utf8"));   // in the page's own realm, as a browser has it
  w.SF_SAVE_PAGE = Number(process.env.SF_MAX_ROWS || 0) || undefined;
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.showDirectoryPicker = async () => { const h = PICK.shift(); if (!h) throw err("AbortError"); return h; };
  w.eval(pageScript(raw, html, OUT));
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const runs = async () => (await admin.query("select * from save_runs order by finished_at")).rows;
async function saveNow(w) { const n0 = (await runs()).length; await click(w, "[data-savenow]", 50);
  await until(async () => (await runs()).length > n0 && !/Saving|Reading/.test(txt(w, "#saveProgress")), 20000); await wait(300); return (await runs()).slice(-1)[0]; }

(async () => {
  const has = (await admin.query("select to_regclass('public.save_runs') is not null as h")).rows[0].h;
  const hasOff = (await admin.query("select to_regclass('public.filed_copies') is not null as h")).rows[0].h;
  if (process.env.OLDDB || !has) {
    const t = boot(users.luke);
    await until(() => /Look up a job/.test(txt(t.w)), 10000); await wait(800);
    ok("Older database: the Photos tab says to run onedrive_save.sql", /Run onedrive_save\.sql \(Walkthrough 24\)/.test(txt(t.w)));
    ok("…and the rest of the Photos tab still works", /Look up a job/.test(txt(t.w)) && /Space on Supabase/.test(txt(t.w)) && /Storage used/.test(txt(t.w)));
    await click(t.w, '[data-tab="tasks"]', 1200);
    ok("…and Needs you shows no saving card, no archive card and no error", !/Saving to OneDrive/.test(txt(t.w)) && !/Photo archive/.test(txt(t.w)) && /Operations|Needs you/.test(txt(t.w)));
    t.w.close(); console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }
  console.log(hasOff ? "(database with off_supabase.sql)" : "(database WITHOUT off_supabase.sql: the new page on the old database)");

  // ---------- the pure parts ----------
  const lib = (() => { const raw = fs.readFileSync(`${OUT}/office.html`, "utf8"), html = strip(raw);
    const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
    dom.window.module = { exports: {} }; dom.window.supabase = { createClient: () => makeClient(null) };
    dom.window.eval(pageScript(raw, html, OUT)); return dom.window.module.exports; })();
  ok("PROJ numbers: Proj-00418 Smith, PROJ-418, proj 00418 all read as 418; PROJ-004180 is 4180; Templates is none",
     lib.projNumber("Proj-00418 Smith Table") === 418 && lib.projNumber("PROJ-418") === 418 && lib.projNumber("proj 00418") === 418
     && lib.projNumber("PROJ-004180") === 4180 && lib.projNumber("Templates") === null && lib.projNumber("PROJ-00100 - 00199") === 100);
  ok("Names Windows refuses are made safe (a/b:c?, a trailing dot or space, CON)",
     lib.safeSeg("a/b:c?") === "a-b-c-" && lib.safeSeg("Note. ") === "Note" && lib.safeSeg("CON") === "_CON" && lib.safeSeg("") === "_");
  ok("A filing name becomes its path inside Production's Delivery or Photos", JSON.stringify(lib.saveRelPath("PROJ-00418/TB-03/TB-03-2 Delivery Picture.jpg")) === '["TB-03","TB-03-2 Delivery Picture.jpg"]');
  ok("The layout: the folder is Production; a trip's photos, tickets and signed tickets go in Delivery; defect and issue photos in Photos",
     lib.SAVE_DIR === "Production" && lib.SAVE_DIR_OLD === "shop-floor data"
     && lib.saveTop({ source: "photo", loadout_id: "x" }) === "Delivery" && lib.saveTop({ source: "photo", loadout_id: null }) === "Photos"
     && lib.saveTop({ source: "doc", loadout_id: "x" }) === "Delivery" && lib.saveTop({ source: "signed", loadout_id: "x" }) === "Delivery"
     && lib.SAVE_SUB.data === "Job Data");
  const recA = lib.jobRecords({ production: [{ sheet: 1, item: "TB-01", department: "Sanding", done: 2, of: 4, state: "Started" }], files: [], defects: [], problems: [], flags: [], arrow: [] });
  const recB = lib.jobRecords({ production: [{ sheet: 1, item: "TB-01", department: "Sanding", done: 2, of: 4, state: "Started" }], files: [], defects: [], problems: [], flags: [], arrow: [] });
  ok("Records come out the same for the same data (so unchanged records aren't rewritten), and empty ones aren't made",
     recA["Production record.csv"] === recB["Production record.csv"] && Object.keys(recA).join() === "Production record.csv");

  // ---------- the folders ----------
  const od = new FDir("OneDrive Projects");
  od.dir("PROJ-00000 - 00099", "PROJ-00099 Smith Lobby");            // a hundreds folder whose own name starts PROJ-
  od.dir("PROJ-00000 - 00099", "PROJ-00042 Old Job");
  const j418 = od.dir("PROJ-00418 Enid's Table"); j418.dir("Drawings"); j418.file("quote.pdf").data = new TextEncoder().encode("QUOTE");
  od.dir("500s", "Proj-00501 Hotel"); od.dir("500s", "PROJ-00502 Office"); od.dir("PROJ-00502 Office (old)");
  od.dir("Templates", "Kitchen");
  const idx = await lib.indexProjectFolders(od);
  ok("Finding job folders: in the main folder, in a hundreds folder (even one named PROJ-00000 - 00099), in 500s; a duplicate shows twice; Templates ignored",
     idx.get(99)[0].path === "PROJ-00000 - 00099 › PROJ-00099 Smith Lobby" && idx.get(418)[0].path === "PROJ-00418 Enid's Table"
     && idx.get(501)[0].path === "500s › Proj-00501 Hotel" && idx.get(502).length === 2 && !idx.has(0) && idx.size === 5,
     [...idx].map(([k, v]) => k + "=" + v.map(x => x.path).join("|")).join("; "));
  const bk = new FDir("Shop Floor Backup");

  // ---------- data: PROJ-00418 has a delivery (a site photo, a signed ticket) and a defect photo; PROJ-00325 a flag
  //            (no OneDrive folder); PROJ-00099 a delivery saved in the old layout before today ----------
  const job = async (p) => (await admin.query("select id from jobs where project_id = $1", [p])).rows[0].id;
  const J418 = await job("PROJ-00418"), J325 = await job("PROJ-00325"), J099 = await job("PROJ-00099");
  const lo = (await admin.query(`insert into loadouts (job_id, kind, scheduled_for, scheduled_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
      values ($1, 'delivery', now() - interval '2 hours', now() - interval '1 day', now() - interval '1 hour', 'Shawn K', 'Pat Customer', now() - interval '1 hour', now() - interval '1 hour') returning id`, [J418])).rows[0].id;
  const uuid = () => require("crypto").randomUUID();
  const PHOTO_PATH = `PROJ-00418/${uuid()}.jpg`, DEFECT_PATH = `PROJ-00418/${uuid()}.jpg`;
  const photoBytes = Buffer.from("\xff\xd8\xff JPEG site photo of table 1", "latin1"), defectBytes = Buffer.from("\xff\xd8\xff JPEG the scratch on TB-03", "latin1");
  const luke = makeClient(users.luke);
  for (const [p, b] of [[PHOTO_PATH, photoBytes], [DEFECT_PATH, defectBytes]]) {
    const up = await luke.storage.from("photos").upload(p, b, { contentType: "image/jpeg" }); if (up.error) console.log("UPLOAD", JSON.stringify(up.error)); }
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 1, 'site', $4, 'Shawn K', $3)`, [J418, lo, photoBytes.length, PHOTO_PATH]);
  const dtype = (await admin.query("select id, label from defect_types where department = 'sanding' and active order by sort_order limit 1")).rows[0];
  const def = (await admin.query(`insert into defects (job_id, sheet_number, department, defect_type_id, defect_type, note, logged_by_name)
      values ($1, 2, 'sanding', $2, $3, 'scratch on the top', 'Mike B') returning id`, [J418, dtype.id, dtype.label])).rows[0].id;
  await admin.query(`insert into photos (client_id, job_id, department, kind, defect_id, sheet_number, storage_path, taken_by_name, bytes)
      values (gen_random_uuid(), $1, 'sanding', 'defect', $2, 2, $4, 'Mike B', $3)`, [J418, def, defectBytes.length, DEFECT_PATH]);
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'watch', 'Customer asked about the edge profile', 'Luke H')", [J325]);
  // PROJ-00099: a delivery with two site photos, saved before 31 Oct in the old layout; one has since left Supabase (an archive zip)
  const lo99 = (await admin.query(`insert into loadouts (job_id, kind, scheduled_for, scheduled_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
      values ($1, 'delivery', now() - interval '3 days', now() - interval '4 days', now() - interval '3 days', 'Shawn K', 'Sam Lobby', now() - interval '3 days', now() - interval '3 days') returning id`, [J099])).rows[0].id;
  const P99 = `PROJ-00099/${uuid()}.jpg`, P99GONE = `PROJ-00099/${uuid()}.jpg`, P99VOID = `PROJ-00099/${uuid()}.jpg`, p99Bytes = Buffer.from("\xff\xd8\xff JPEG lobby table, in Supabase", "latin1");
  await luke.storage.from("photos").upload(P99, p99Bytes, { contentType: "image/jpeg" });
  await luke.storage.from("photos").upload(P99VOID, p99Bytes, { contentType: "image/jpeg" });
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes, file_removed_at)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 1, 'site', $3, 'Shawn K', $4, null),
             (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 2, 'site', $5, 'Shawn K', 40, now() - interval '1 day')`, [J099, lo99, P99, p99Bytes.length, P99GONE]);
  // …and one marked "entered by mistake" after it was saved (its name has changed since)
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes, voided_at, voided_by_name)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 2, 1, 'site', $3, 'Shawn K', $4, now(), 'Julia')`, [J099, lo99, P99VOID, p99Bytes.length]);
  const f99 = (await admin.query("select source, folder, file_name, storage_path from v_filing where project_id = 'PROJ-00099' order by source, file_name")).rows;
  const name99 = (p) => { const r = f99.find(x => x.storage_path === p); return [r.folder, r.file_name]; };
  const signed99 = f99.find(x => x.source === "signed");
  const OLD99 = new TextEncoder().encode("OLD COPY: lobby table, as saved before 31 Oct"), OLDGONE = new TextEncoder().encode("only here now: the archived lobby photo");
  for (const [root, base] of [[od, ["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby", "shop-floor data"]], [bk, ["PROJ-00099", "shop-floor data"]]]) {
    root.file(...base, ...name99(P99)).data = OLD99;
    root.file(...base, ...name99(P99GONE)).data = OLDGONE;
    root.file(...base, signed99.folder, signed99.file_name).data = new TextEncoder().encode("%PDF- old signed ticket");
    const [vf, vn] = name99(P99VOID); root.file(...base, vf, vn.replace(" (entered by mistake)", "")).data = OLD99;      // saved under its name before
    root.file(...base, "Production record.csv").data = new TextEncoder().encode("OLD RECORD");
  }
  od.file("PROJ-00000 - 00099", "PROJ-00099 Smith Lobby", "shop-floor data", name99(P99)[0], "Thumbs.db").data = new TextEncoder().encode("windows thumbnails");
  // PROJ-00501: an old folder with a file somebody put there by hand
  od.file("500s", "Proj-00501 Hotel", "shop-floor data", "Production record.csv").data = new TextEncoder().encode("OLD RECORD 501");
  od.file("500s", "Proj-00501 Hotel", "shop-floor data", "notes from the site visit.txt").data = new TextEncoder().encode("bring the long screws");

  // ---------- Luke's office, before any folder is chosen ----------
  let t = boot(users.luke);
  await until(() => /Saving to OneDrive and the hard drive/.test(txt(t.w)), 10000); await wait(600);
  ok("Photos tab: the saving panel, with both folders \"not chosen on this computer\" and nothing saved yet",
     /OneDrive projects folder: not chosen on this computer/.test(txt(t.w)) && /Backup folder \(hard drive\): not chosen/.test(txt(t.w)) && /Nothing has been saved yet/.test(txt(t.w)));
  ok("Photos tab: Space on Supabase replaces the photo archive (no Download archive button)",
     /Space on Supabase/.test(txt(t.w)) && /Storage used/.test(txt(t.w)) && !/Photo archive/.test(txt(t.w)) && !$(t.w, "[data-archstart]"));
  ok(hasOff ? "…it says nothing is due off Supabase yet" : "…and says off_supabase.sql hasn't been run yet",
     hasOff ? /Nothing is due yet/.test(txt(t.w)) : /until off_supabase\.sql has been run \(Walkthrough 42\)/.test(txt(t.w)), txt(t.w).match(/Space on Supabase.{0,400}/) || "");
  await click(t.w, '[data-tab="tasks"]', 1200);
  ok("Needs you: \"hasn't been set up yet\", with Open Photos; no Photo archive card", /Saving to OneDrive/.test(txt(t.w)) && /hasn't been set up yet/.test(txt(t.w)) && !/Photo archive/.test(txt(t.w)));
  await click(t.w, '[data-tab="photos"]', 900);

  // choose the folders; a backup folder inside OneDrive is refused
  PICK = [od]; await click(t.w, '[data-savepick="od"]', 400);
  ok("Choosing the OneDrive projects folder says what it'll do", /OneDrive projects folder chosen: OneDrive Projects/.test(txt(t.w)));
  PICK = [od.dir("Templates")]; await click(t.w, '[data-savepick="bk"]', 400);
  ok("A backup folder inside the OneDrive projects folder is refused, and nothing changes", /has to be separate/.test(txt(t.w)) && /Backup folder \(hard drive\): not chosen/.test(txt(t.w)));
  PICK = [bk]; await click(t.w, '[data-savepick="bk"]', 400);
  ok("Choosing the backup folder says the next save copies what it's missing", /Backup folder chosen: Shop Floor Backup/.test(txt(t.w)));

  // ---------- the first save ----------
  let r = await saveNow(t.w);
  const odJob = od.find("PROJ-00418 Enid's Table/Production"), bkJob = bk.find("PROJ-00418/Production");
  const odFiles = odJob ? odJob.files().sort() : [], bkFiles = bkJob ? bkJob.files().sort() : [];
  ok("First save: PROJ-00418's site photo and signed ticket go in Production › Delivery, its defect photo in Photos, its records in Job Data",
     odFiles.includes("Delivery/TB-03/TB-03-1 Delivery Picture.jpg") && odFiles.some(f => /^Delivery\/Delivery \d{4}-\d\d-\d\d\/Signed ticket\.pdf$/.test(f))
     && odFiles.some(f => /^Photos\/TB-03\/TB-03 Defect 1\.jpg$/.test(f)) && odFiles.includes("Job Data/Production record.csv") && odFiles.includes("Job Data/Photos and files.csv"),
     odFiles.join(", "));
  ok("…the same files in the backup folder, under PROJ-00418/Production", JSON.stringify(bkFiles) === JSON.stringify(odFiles), bkFiles.join(", "));
  ok("…and no old-style folder is made anywhere", !od.find("PROJ-00418 Enid's Table/shop-floor data") && !bk.find("PROJ-00418/shop-floor data"));
  ok("…the photo is the very file from Supabase, byte for byte", odJob && Buffer.from(odJob.find("Delivery/TB-03/TB-03-1 Delivery Picture.jpg").data).equals(photoBytes));
  const pdf = odJob && odJob.find(odFiles.find(f => /Signed ticket\.pdf$/.test(f)));
  ok("…the signed ticket is a real PDF, signed by Pat Customer", pdf && new TextDecoder().decode(pdf.data.slice(0, 5)) === "%PDF-");
  const prod = txtOf(odJob && odJob.find("Job Data/Production record.csv")) || "";
  ok("…the production record names sheets by number and item code only (no species, no sizes)", /Sheet,Item,Department/.test(prod) && !/Ash/.test(prod) && prod.split("\r\n").length > 10);
  ok("…the job folder's own files are untouched (quote.pdf, Drawings)", txtOf(j418.find("quote.pdf")) === "QUOTE" && j418.find("Drawings").kids.size === 0);
  ok("PROJ-00099 is saved inside its hundreds folder; PROJ-00501 inside 500s",
     !!od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby/Production/Job Data/Production record.csv") && !!od.find("500s/Proj-00501 Hotel/Production/Job Data/Production record.csv"));
  ok("PROJ-00502 (two folders) is written to neither; PROJ-00325 (no folder) gets no folder made",
     !od.find("500s/PROJ-00502 Office/Production") && !od.find("PROJ-00502 Office (old)/Production") && ![...od.kids.keys()].some(k => /00325/.test(k)));
  ok("…but the backup folder has both (it never depends on OneDrive's names)", !!bk.find("PROJ-00502/Production") && !!bk.find("PROJ-00325/Production/Job Data/Flags.csv"));
  const firstOd = LOG.find(x => x[1] === "OneDrive Projects" && /00418/.test(x[2])), firstBk = LOG.find(x => x[1] === "Shop Floor Backup" && /00418/.test(x[2]));
  ok("The hard drive copy is written first, then OneDrive", firstBk && firstOd && firstBk[0] < firstOd[0]);

  // the one-time move
  const j099 = od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby");
  const new99 = (root, base) => root.find([...base, "Production", "Delivery", ...name99(P99)].join("/"));
  ok("The move: PROJ-00099's old “shop-floor data” folder is gone from OneDrive and the backup",
     !j099.find("shop-floor data") && !bk.find("PROJ-00099/shop-floor data"), (j099.find("shop-floor data") ? "OneDrive kept: " + j099.find("shop-floor data").files().join(", ") : ""));
  ok("…its photo was copied across from the old folder, not downloaded again", new99(od, ["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby"]) && Buffer.from(new99(od, ["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby"]).data).equals(Buffer.from(OLD99)));
  ok("…a photo that's no longer in Supabase was copied across too (it was only in the old folder)",
     txtOf(od.find(["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby", "Production", "Delivery", ...name99(P99GONE)].join("/"))) === txtOf({ data: OLDGONE })
     && txtOf(bk.find(["PROJ-00099", "Production", "Delivery", ...name99(P99GONE)].join("/"))) === txtOf({ data: OLDGONE }));
  ok("…the old signed ticket kept its place in Delivery; the old record was replaced by the current one in Job Data",
     /old signed ticket/.test(txtOf(od.find(["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby", "Production", "Delivery", signed99.folder, signed99.file_name].join("/"))) || "")
     && /Sheet,Item,Department/.test(txtOf(od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby/Production/Job Data/Production record.csv")) || ""));
  ok("…and Windows' Thumbs.db went with the old folder (it didn't stop the move, and wasn't copied)", !j099.files().some(f => /Thumbs\.db/.test(f)));
  ok("…a photo marked entered by mistake since it was saved is recognised under its new name (copied across, not left behind)",
     /entered by mistake/.test(name99(P99VOID)[1]) && txtOf(od.find(["PROJ-00000 - 00099", "PROJ-00099 Smith Lobby", "Production", "Delivery", ...name99(P99VOID)].join("/"))) === txtOf({ data: OLD99 })
     && !j099.files().some(f => f.endsWith(name99(P99VOID)[1].replace(" (entered by mistake)", ""))), j099.files().join(", "));
  const j501 = od.find("500s/Proj-00501 Hotel");
  ok("PROJ-00501: a file put there by hand keeps its old folder, untouched, and the save says so",
     txtOf(j501.find("shop-floor data/notes from the site visit.txt")) === "bring the long screws"
     && (r.problems || []).some(x => /PROJ-00501: the old “shop-floor data” folder in OneDrive is kept: a file in it isn't where the save puts things \(notes from the site visit\.txt\)/.test(x))
     && /PROJ-00501: the old “shop-floor data” folder in OneDrive is kept/.test(txt(t.w)), JSON.stringify(r.problems));
  ok("…while its record still went into Production › Job Data", /Sheet,Item,Department/.test(txtOf(j501.find("Production/Job Data/Production record.csv")) || ""));
  ok("The panel says how many old folders were moved and removed",
     /2 old “shop-floor data” folders were moved into “Production” and removed \(\d+ files? copied across\)/.test(txt(t.w)), txt(t.w).match(/Saved [^]{0,300}/) || "");
  ok("The panel lists the skipped jobs and why, with both paths for the duplicate",
     /PROJ-00502: two folders \(500s › PROJ-00502 Office and PROJ-00502 Office \(old\)\)\. Move or rename one\./.test(txt(t.w)) && /PROJ-00325: no OneDrive folder yet/.test(txt(t.w)), txt(t.w).match(/skipped[^]*?again next time:[^]{0,300}/) || "");
  ok("The save is logged: both places reached, 2 skipped, by Luke's login",
     r && r.onedrive_ok && r.backup_ok && r.skipped.length === 2 && r.how === "button" && r.page_version === (fs.readFileSync(`${OUT}/office.html`, "utf8").match(/const OFFICE_VERSION = "([^"]+)"/) || [])[1],
     r && JSON.stringify({ od: r.onedrive_ok, bk: r.backup_ok, sk: r.skipped, files: r.files_written }));
  ok("No test job is ever saved", !bk.find("TEST-00418") && !bk.files().some(f => /TEST-/.test(f)));
  await click(t.w, '[data-tab="tasks"]', 1200);
  ok("Needs you: the saving card has gone", !/Saving to OneDrive/.test(txt(t.w)));
  await click(t.w, '[data-tab="photos"]', 900);

  // ---------- a second save writes nothing; a changed file in OneDrive is never overwritten ----------
  const photoFile = odJob.find("Delivery/TB-03/TB-03-1 Delivery Picture.jpg"); photoFile.data = new TextEncoder().encode("EDITED BY HAND");
  const writes0 = LOG.length;
  r = await saveNow(t.w);
  ok("Second save straight after: nothing new, nothing written (PROJ-00501's old folder is looked at again, and still kept)",
     r.files_written === 0 && LOG.length === writes0 && !!j501.find("shop-floor data"), `${r.files_written} files, ${LOG.length - writes0} writes`);
  ok("…and a file already in OneDrive is never overwritten, even if it differs", txtOf(photoFile) === "EDITED BY HAND");

  // ---------- a change on a job: only its record is rewritten, in both places ----------
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'priority', 'Rush: install moved up', 'Luke H')", [J418]);
  const w1 = LOG.length;
  r = await saveNow(t.w);
  const wrote = LOG.slice(w1).map(x => x[1] + ":" + x[2]);
  ok("A new flag on PROJ-00418: Job Data/Flags.csv is written in both places, nothing else", wrote.length === 2 && wrote.every(x => /Production\/Job Data\/Flags\.csv$/.test(x)), wrote.join(", "));
  ok("…and it says what the flag was", /Rush: install moved up/.test(txtOf(odJob.find("Job Data/Flags.csv"))));

  // ---------- fixing the duplicate; sorting out PROJ-00501's hand-placed file ----------
  od.kids.delete("PROJ-00502 Office (old)");
  j501.find("shop-floor data").kids.delete("notes from the site visit.txt");
  r = await saveNow(t.w);
  ok("After the duplicate folder is removed, the next save fills PROJ-00502 and only PROJ-00325 is still skipped",
     !!od.find("500s/PROJ-00502 Office/Production/Job Data/Production record.csv") && r.skipped.length === 1 && r.skipped[0].project_id === "PROJ-00325");
  ok("…and with the hand-placed file gone, PROJ-00501's old folder is removed", !j501.find("shop-floor data") && !!j501.find("Production/Job Data/Production record.csv"));

  // ---------- a file Supabase can't hand over: the save isn't counted as good, and it's tried again ----------
  const BAD = `PROJ-00418/${uuid()}.jpg`;
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 2, 'site', $3, 'Shawn K')`, [J418, lo, BAD]);
  r = await saveNow(t.w);
  ok("A photo that can't be downloaded: the save says so, isn't counted as complete, and the job is tried again",
     !r.onedrive_ok && !r.backup_ok && r.problems.some(x => /couldn't be downloaded.*tried again next time/.test(x)) && /tried again next time/.test(txt(t.w)), JSON.stringify(r.problems));
  await admin.query("delete from photos where storage_path = $1", [BAD]);
  r = await saveNow(t.w);
  ok("…once it's sorted out, the next save is complete again", r.onedrive_ok && r.backup_ok, JSON.stringify(r.problems));

  // ---------- the backup drive unplugged ----------
  bk.gone = true;
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'watch', 'Check the base finish', 'Luke H')", [J099]);
  r = await saveNow(t.w);
  ok("Backup drive unplugged: OneDrive still saves (PROJ-00099's new flag)", /Check the base finish/.test(txtOf(od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby/Production/Job Data/Flags.csv")) || ""));
  ok("…the page says \"Backup drive not connected\", and the log says the backup wasn't reached", /Backup drive not connected/.test(txt(t.w)) && r.onedrive_ok && !r.backup_ok);
  const st = (await t.client.rpc("save_status")).data;
  ok("…so the reminder still counts from the last save that reached both", st.last_backup_ok === false && st.good_at < st.last_at && !st.due);
  bk.gone = false;
  r = await saveNow(t.w);
  ok("Plugged back in: the next save catches the backup up (PROJ-00099's flag is there now)", r.backup_ok && /Check the base finish/.test(txtOf(bk.find("PROJ-00099/Production/Job Data/Flags.csv")) || ""));

  // ---------- off Supabase (off_supabase.sql) ----------
  if (hasOff) {
    // PROJ-00418 left the floor 61 days ago; its photos and a delivery ticket added then are 61 days old
    await admin.query("update jobs set is_active = false, phase = 'Complete' where id = $1", [J418]);
    await admin.query("update jobs set floor_left_at = now() - interval '61 days' where id = $1", [J418]);
    await admin.query("update photos set taken_at = now() - interval '61 days' where job_id = $1", [J418]);
    const { PDFDocument } = require("/home/claude/.npm-global/lib/node_modules/pdf-lib");
    const tdoc = await PDFDocument.create(); tdoc.addPage([612, 792]); const ticketBytes = Buffer.from(await tdoc.save());
    const TICKET = `PROJ-00418/${lo}/${uuid()}.pdf`;
    const upT = await luke.storage.from("deliveries").upload(TICKET, ticketBytes, { contentType: "application/pdf" });
    if (upT.error) console.log("TICKET UPLOAD", JSON.stringify(upT.error));
    await admin.query(`insert into delivery_docs (client_id, loadout_id, job_id, kind, file_name, storage_path, mime, bytes, added_by_name, added_at)
        values (gen_random_uuid(), $1, $2, 'ticket', 'ticket.pdf', $3, 'application/pdf', $4, 'Julia', now() - interval '61 days')`, [lo, J418, TICKET, ticketBytes.length]);
    const inStorage = async (p) => (await admin.query("select count(*)::int as n from storage.objects where name = $1", [p])).rows[0].n === 1;
    await click(t.w, '[data-tab="tasks"]', 600); await click(t.w, '[data-tab="photos"]', 1200);
    ok("Off Supabase: the Photos tab says PROJ-00418's 3 files are due now", /3 files are due now: they go with the next save that finds them in both OneDrive and the backup folder/.test(txt(t.w)),
       txt(t.w).match(/Space on Supabase.{0,500}/) || "");

    bk.gone = true;
    r = await saveNow(t.w);
    ok("Backup drive unplugged: nothing comes off Supabase (found in OneDrive only)",
       await inStorage(PHOTO_PATH) && await inStorage(DEFECT_PATH) && await inStorage(TICKET) && !/came off Supabase/.test(txt(t.w)));
    bk.gone = false;
    r = await saveNow(t.w);
    ok("Plugged back in: the next save finds them in both places, and the defect photo and the ticket come off Supabase",
       !await inStorage(DEFECT_PATH) && !await inStorage(TICKET) && /2 files came off Supabase: they're in both OneDrive and the backup folder/.test(txt(t.w)),
       txt(t.w).match(/Saved [^]{0,400}/) || "");
    ok("…but the site photo whose OneDrive copy was changed by hand (a different size) stays on Supabase, and the save says why",
       await inStorage(PHOTO_PATH) && (r.problems || []).some(x => /PROJ-00418: Delivery\/TB-03\/TB-03-1 Delivery Picture\.jpg in OneDrive isn't the same size as the copy on Supabase, so it stays on Supabase/.test(x)),
       JSON.stringify(r.problems));
    const marks = (await admin.query(`select (select count(*) from photos where job_id = $1 and file_removed_at is not null)::int as p,
                                             (select count(*) from delivery_docs where job_id = $1 and file_removed_at is not null)::int as d,
                                             (select count(*) from photos where job_id = $1)::int as pall`, [J418])).rows[0];
    ok("…the records stay, the two that went marked off Supabase", marks.p === 1 && marks.d === 1 && marks.pall === 2, JSON.stringify(marks));
    ok("…and they're still in OneDrive and the backup folder (the ticket saved just before it went)",
       !!odJob.find("Delivery/TB-03/TB-03-1 Delivery Picture.jpg") && !!bkJob.find("Photos/TB-03/TB-03 Defect 1.jpg")
       && odJob.files().some(f => /^Delivery\/Delivery \d{4}-\d\d-\d\d\/Delivery ticket\.pdf$/.test(f)) && bkJob.files().some(f => /Delivery ticket\.pdf$/.test(f)));
    ok("A job still on the floor keeps its files on Supabase (PROJ-00099)", await inStorage(P99));
    const w2 = LOG.length;
    r = await saveNow(t.w);
    ok("The next save: nothing new written, nothing missing, and the save is complete", r.files_written === 0 && LOG.length === w2 && r.onedrive_ok && r.backup_ok, JSON.stringify(r.problems));
    ok("The Photos tab counts what has come off (with the photo archived before) and what's still due", /3 files have come off so far\. 1 file is due now/.test(txt(t.w)),
       (txt(t.w).match(/Every record stays for good.{0,500}/) || [""])[0]);
    t.w.document.querySelector("#phJob").value = "418"; await click(t.w, "[data-phfind]", 1500);
    ok("Looking up PROJ-00418: the photo that went says it's in OneDrive", /Off Supabase · in OneDrive/.test(txt(t.w)) && /1 of this job's photos is off Supabase: it's in the job's OneDrive folder \(Production\) and the backup folder/.test(txt(t.w)),
       (txt(t.w).match(/On defects and issues.{0,300}/) || [""])[0]);
    odJob.find("Delivery/TB-03").kids.delete("TB-03-1 Delivery Picture.jpg");     // Luke deletes the edited copy
    r = await saveNow(t.w);
    ok("Deleting the changed copy: the next save puts the original back from Supabase, then takes it off",
       Buffer.from(odJob.find("Delivery/TB-03/TB-03-1 Delivery Picture.jpg").data).equals(photoBytes) && !await inStorage(PHOTO_PATH)
       && /1 file came off Supabase: it's in both OneDrive and the backup folder/.test(txt(t.w)), txt(t.w).match(/Saved [^]{0,300}/) || "");
  }

  // ---------- a new external drive: everything is copied ----------
  const ext = new FDir("External Drive Backup");
  PICK = [ext]; await click(t.w, '[data-savepick="bk"]', 400);
  r = await saveNow(t.w);
  const extFiles = ext.find("PROJ-00418/Production") ? ext.find("PROJ-00418/Production").files().sort() : [];
  const bkNow = bk.find("PROJ-00418/Production").files().sort();
  ok(hasOff ? "Changing the backup folder to a new drive: the next save copies every job's files it can still get there (not the ones off Supabase)"
            : "Changing the backup folder to a new drive: the next save copies every job's files there",
     (hasOff ? extFiles.length && extFiles.every(f => bkNow.includes(f)) && !extFiles.includes("Delivery/TB-03/TB-03-1 Delivery Picture.jpg") && !extFiles.includes("Photos/TB-03/TB-03 Defect 1.jpg")
             : JSON.stringify(extFiles) === JSON.stringify(bkNow)) && !!ext.find("PROJ-00325/Production/Job Data/Flags.csv"), extFiles.join(", "));

  // ---------- reopening the page: the folders are remembered; it saves by itself ----------
  t.w.close();
  od.perm = "prompt";
  const n0 = (await runs()).length;
  t = boot(users.luke);
  await until(() => /Saving to OneDrive and the hard drive/.test(txt(t.w)), 10000); await wait(800);
  ok("Reopened, with the browser wanting permission again: the folders are remembered and it offers Resume saving",
     /OneDrive projects folder: OneDrive Projects/.test(txt(t.w)) && /External Drive Backup/.test(txt(t.w)) && !!$(t.w, "[data-saveresume]"), (txt(t.w).match(/Saving to OneDrive and the hard drive.{0,400}/) || [""])[0]);
  await wait(21000);
  ok("…and it doesn't try to save without permission", (await runs()).length === n0);
  await click(t.w, "[data-saveresume]", 300);
  await until(async () => (await runs()).length > n0, 15000); await wait(300);
  r = (await runs()).slice(-1)[0];
  ok("Resume saving: permission given, and it saves by itself (marked auto)", r && r.how === "auto" && r.onedrive_ok && r.backup_ok);
  t.w.close();

  // ---------- David's computer: no folders; the reminder only when it's due ----------
  IDB.clear();                                     // another computer: its browser remembers no folders
  t = boot(users.david);
  await until(() => /Saving to OneDrive and the hard drive/.test(txt(t.w)), 10000); await wait(800);
  ok("David's office: the last save is shown, folders not chosen here, no Save now", /Last save that reached both places/.test(txt(t.w)) && /not chosen on this computer/.test(txt(t.w)) && !$(t.w, "[data-savenow]"));
  await admin.query("update save_runs set finished_at = finished_at - interval '9 days'");
  await click(t.w, '[data-tab="tasks"]', 1500);
  ok("Nine days without a good save: Needs you says so on David's office too", /The last save that reached both OneDrive and the backup folder was 9 days ago/.test(txt(t.w)), txt(t.w).match(/Saving to OneDrive.{0,200}/) || "");
  t.w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
