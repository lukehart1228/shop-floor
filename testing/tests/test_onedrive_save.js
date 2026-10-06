// 6 Oct: saving to OneDrive and the hard drive (office page + onedrive_save.sql).
//   bash /home/claude/sf/base/fresh.sh <feedback.sql> <trip_types.sql> <onedrive_save.sql> <install_log.sql>
//   cd /home/claude/sf/t && SF_MAX_ROWS=2 TZ=America/Indiana/Indianapolis node test_onedrive_save.js
//   SF_MAX_ROWS=2 caps every request at 2 rows and the page asks 2 at a time, so paging is exercised.
//   OLDDB=1 on a database WITHOUT onedrive_save.sql: the page says so and everything else still works.
//   OUT=/home/claude/sf/repo runs it on the live page, where it fails (no saving there).
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
  if (process.env.OLDDB || !has) {
    const t = boot(users.luke);
    await until(() => /Look up a job/.test(txt(t.w)), 10000); await wait(800);
    ok("Older database: the Photos tab says to run onedrive_save.sql", /Run onedrive_save\.sql \(Walkthrough 24\)/.test(txt(t.w)));
    ok("…and the rest of the Photos tab still works", /Look up a job/.test(txt(t.w)) && /Photo archive/.test(txt(t.w)));
    await click(t.w, '[data-tab="tasks"]', 1200);
    ok("…and Needs you shows no saving card and no error", !/Saving to OneDrive/.test(txt(t.w)) && /Operations|Needs you/.test(txt(t.w)));
    t.w.close(); console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

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
  ok("A filing name becomes its path inside shop-floor data", JSON.stringify(lib.saveRelPath("PROJ-00418/TB-03/TB-03-2 Delivery Picture.jpg")) === '["TB-03","TB-03-2 Delivery Picture.jpg"]');
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

  // ---------- data: a delivery with a site photo and a signed ticket on PROJ-00418; a flag on PROJ-00325 (no OneDrive folder) ----------
  const job = async (p) => (await admin.query("select id from jobs where project_id = $1", [p])).rows[0].id;
  const J418 = await job("PROJ-00418"), J325 = await job("PROJ-00325"), J099 = await job("PROJ-00099");
  const lo = (await admin.query(`insert into loadouts (job_id, kind, scheduled_for, scheduled_at, completed_at, completed_by_name, signed_name, signed_at, finished_at)
      values ($1, 'delivery', now() - interval '2 hours', now() - interval '1 day', now() - interval '1 hour', 'Shawn K', 'Pat Customer', now() - interval '1 hour', now() - interval '1 hour') returning id`, [J418])).rows[0].id;
  const PHOTO_PATH = `PROJ-00418/${require("crypto").randomUUID()}.jpg`;
  const photoBytes = Buffer.from("\xff\xd8\xff JPEG site photo of table 1", "latin1");
  const luke = makeClient(users.luke);
  const up = await luke.storage.from("photos").upload(PHOTO_PATH, photoBytes, { contentType: "image/jpeg" });
  if (up.error) console.log("UPLOAD", JSON.stringify(up.error));
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, sheet_number, piece, stage, storage_path, taken_by_name, bytes)
      values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 1, 1, 'site', $4, 'Shawn K', $3)`, [J418, lo, photoBytes.length, PHOTO_PATH]);
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'watch', 'Customer asked about the edge profile', 'Luke H')", [J325]);

  // ---------- Luke's office, before any folder is chosen ----------
  let t = boot(users.luke);
  await until(() => /Saving to OneDrive and the hard drive/.test(txt(t.w)), 10000); await wait(600);
  ok("Photos tab: the saving panel, with both folders \"not chosen on this computer\" and nothing saved yet",
     /OneDrive projects folder: not chosen on this computer/.test(txt(t.w)) && /Backup folder \(hard drive\): not chosen/.test(txt(t.w)) && /Nothing has been saved yet/.test(txt(t.w)));
  await click(t.w, '[data-tab="tasks"]', 1200);
  ok("Needs you: \"hasn't been set up yet\", with Open Photos", /Saving to OneDrive/.test(txt(t.w)) && /hasn't been set up yet/.test(txt(t.w)));
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
  const sfd = (d) => d.find("shop-floor data");
  const odJob = od.find("PROJ-00418 Enid's Table/shop-floor data"), bkJob = bk.find("PROJ-00418/shop-floor data");
  const odFiles = odJob ? odJob.files().sort() : [], bkFiles = bkJob ? bkJob.files().sort() : [];
  ok("First save: PROJ-00418 gets its site photo, signed ticket and records in OneDrive",
     odFiles.some(f => /Delivery Picture\.jpg$/.test(f)) && odFiles.some(f => /Signed ticket\.pdf$/.test(f)) && odFiles.includes("Production record.csv") && odFiles.includes("Photos and files.csv"),
     odFiles.join(", "));
  ok("…the same files in the backup folder, under PROJ-00418/shop-floor data", JSON.stringify(bkFiles) === JSON.stringify(odFiles), bkFiles.join(", "));
  const photoF = odJob && odJob.files().find(f => /Delivery Picture\.jpg$/.test(f));
  ok("…the photo is the very file from Supabase, byte for byte", photoF && Buffer.from(odJob.find(photoF).data).equals(photoBytes));
  const pdf = odJob && odJob.find(odFiles.find(f => /Signed ticket\.pdf$/.test(f)));
  ok("…the signed ticket is a real PDF, signed by Pat Customer", pdf && new TextDecoder().decode(pdf.data.slice(0, 5)) === "%PDF-");
  const prod = txtOf(odJob && odJob.find("Production record.csv")) || "";
  ok("…the production record names sheets by number and item code only (no species, no sizes)", /Sheet,Item,Department/.test(prod) && !/Ash/.test(prod) && prod.split("\r\n").length > 10);
  ok("…the job folder's own files are untouched (quote.pdf, Drawings)", txtOf(j418.find("quote.pdf")) === "QUOTE" && j418.find("Drawings").kids.size === 0);
  ok("PROJ-00099 is saved inside its hundreds folder; PROJ-00501 inside 500s",
     !!od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby/shop-floor data/Production record.csv") && !!od.find("500s/Proj-00501 Hotel/shop-floor data/Production record.csv"));
  ok("PROJ-00502 (two folders) is written to neither; PROJ-00325 (no folder) gets no folder made",
     !od.find("500s/PROJ-00502 Office/shop-floor data") && !od.find("PROJ-00502 Office (old)/shop-floor data") && ![...od.kids.keys()].some(k => /00325/.test(k)));
  ok("…but the backup folder has both (it never depends on OneDrive's names)", !!bk.find("PROJ-00502/shop-floor data") && !!bk.find("PROJ-00325/shop-floor data/Flags.csv"));
  const firstOd = LOG.find(x => x[1] === "OneDrive Projects" && /00418/.test(x[2])), firstBk = LOG.find(x => x[1] === "Shop Floor Backup" && /00418/.test(x[2]));
  ok("The hard drive copy is written first, then OneDrive", firstBk && firstOd && firstBk[0] < firstOd[0]);
  ok("The panel lists the skipped jobs and why, with both paths for the duplicate",
     /PROJ-00502: two folders \(500s › PROJ-00502 Office and PROJ-00502 Office \(old\)\)\. Move or rename one\./.test(txt(t.w)) && /PROJ-00325: no OneDrive folder yet/.test(txt(t.w)), txt(t.w).match(/skipped[^]*?again next time:[^]{0,300}/) || "");
  ok("The save is logged: both places reached, 2 skipped, by Luke's login", r && r.onedrive_ok && r.backup_ok && r.skipped.length === 2 && r.how === "button" && r.page_version === (require("fs").readFileSync(`${process.env.OUT || "/home/claude/sf/out"}/office.html`, "utf8").match(/const OFFICE_VERSION = "([^"]+)"/) || [])[1],
     r && JSON.stringify({ od: r.onedrive_ok, bk: r.backup_ok, sk: r.skipped, files: r.files_written }));
  ok("No test job is ever saved", !bk.find("TEST-00418") && !bk.files().some(f => /TEST-/.test(f)));
  await click(t.w, '[data-tab="tasks"]', 1200);
  ok("Needs you: the saving card has gone", !/Saving to OneDrive/.test(txt(t.w)));
  await click(t.w, '[data-tab="photos"]', 900);

  // ---------- a second save writes nothing; a changed file in OneDrive is never overwritten ----------
  const photoFile = odJob.find(photoF); photoFile.data = new TextEncoder().encode("EDITED BY HAND");
  const writes0 = LOG.length;
  r = await saveNow(t.w);
  ok("Second save straight after: nothing new, nothing written", r.files_written === 0 && LOG.length === writes0, `${r.files_written} files, ${LOG.length - writes0} writes`);
  ok("…and a file already in OneDrive is never overwritten, even if it differs", txtOf(photoFile) === "EDITED BY HAND");

  // ---------- a change on a job: only its record is rewritten, in both places ----------
  await admin.query("insert into flags (job_id, level, note, set_by_name) values ($1, 'priority', 'Rush: install moved up', 'Luke H')", [J418]);
  const w1 = LOG.length;
  r = await saveNow(t.w);
  const wrote = LOG.slice(w1).map(x => x[1] + ":" + x[2].split("/").slice(-1)[0]);
  ok("A new flag on PROJ-00418: Flags.csv is written in both places, nothing else", wrote.length === 2 && wrote.every(x => /Flags\.csv$/.test(x)), wrote.join(", "));
  ok("…and it says what the flag was", /Rush: install moved up/.test(txtOf(odJob.find("Flags.csv"))));

  // ---------- fixing the duplicate: the next save fills PROJ-00502 ----------
  od.kids.delete("PROJ-00502 Office (old)");
  r = await saveNow(t.w);
  ok("After the duplicate folder is removed, the next save fills PROJ-00502 and only PROJ-00325 is still skipped",
     !!od.find("500s/PROJ-00502 Office/shop-floor data/Production record.csv") && r.skipped.length === 1 && r.skipped[0].project_id === "PROJ-00325");

  // ---------- a file Supabase can't hand over: the save isn't counted as good, and it's tried again ----------
  const BAD = `PROJ-00418/${require("crypto").randomUUID()}.jpg`;
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
  ok("Backup drive unplugged: OneDrive still saves (PROJ-00099's new flag)", /Check the base finish/.test(txtOf(od.find("PROJ-00000 - 00099/PROJ-00099 Smith Lobby/shop-floor data/Flags.csv")) || ""));
  ok("…the page says \"Backup drive not connected\", and the log says the backup wasn't reached", /Backup drive not connected/.test(txt(t.w)) && r.onedrive_ok && !r.backup_ok);
  const st = (await t.client.rpc("save_status")).data;
  ok("…so the reminder still counts from the last save that reached both", st.last_backup_ok === false && st.good_at < st.last_at && !st.due);
  bk.gone = false;
  r = await saveNow(t.w);
  ok("Plugged back in: the next save catches the backup up (PROJ-00099's flag is there now)", r.backup_ok && /Check the base finish/.test(txtOf(bk.find("PROJ-00099/shop-floor data/Flags.csv")) || ""));

  // ---------- a new external drive: everything is copied ----------
  const ext = new FDir("External Drive Backup");
  PICK = [ext]; await click(t.w, '[data-savepick="bk"]', 400);
  r = await saveNow(t.w);
  ok("Changing the backup folder to a new drive: the next save copies every job's files there",
     JSON.stringify(ext.find("PROJ-00418/shop-floor data").files().sort()) === JSON.stringify(bk.find("PROJ-00418/shop-floor data").files().sort()) && !!ext.find("PROJ-00325/shop-floor data/Flags.csv"));

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
