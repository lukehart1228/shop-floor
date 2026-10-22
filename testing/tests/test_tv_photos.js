// 7 Oct: In its new home — the Delivery phone's small copy of a white glove site photo, the TV's list and picture.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh        (a database with tv_photos.sql)
//   TZ=America/Indiana/Indianapolis node test_tv_photos.js           (the new index.html in /home/claude/sf/out)
//   OLDDB=1 … on a database without tv_photos.sql: the new page's site photo still saves, no copy
//   OUT=/home/claude/sf/repo … the live page on the new database: the site photo saves, no copy (nothing waits)
// The camera is stood in for (sfShrinkPhoto); everything after it is the page's real code.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out";
const OLDDB = !!process.env.OLDDB;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const q1 = async (sql, a = []) => (await admin.query(sql, a)).rows[0];
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 200) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }

// a real JPEG (632 bytes) for the copy, and a bigger "full" photo
const tvJpg = Buffer.from("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwAooorwT6U//9k=", "base64");

// the office page: the shared sf-common file and the page's script as one piece, the PIN already known
function bootOffice(user) {
  const raw = fs.readFileSync(`${OUT}/office.html`, "utf8"), html = raw.replace(/<script src="[^"]+"[^>]*><\/script>/g, ""), client = makeClient(user);
  const w = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html", pretendToBeVisual: true }).window;
  w.localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  const shared = [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => { const f = `${OUT}/${m[1]}`; return fs.readFileSync(fs.existsSync(f) ? f : `/home/claude/sf/repo/${m[1]}`, "utf8"); });
  w.eval(shared.concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n"));
  return { w, client };
}
function boot(user) {
  const raw = fs.readFileSync(`${OUT}/index.html`, "utf8"), client = makeClient(user);
  const w = new JSDOM(raw, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html", pretendToBeVisual: true }).window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.File = File; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => null; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.__shrinks = [];                                        // what the camera stand-in was asked for
  w.sfShrinkPhoto = async (file, opts = {}) => { w.__shrinks.push(!!opts.tv);
    return { blob: new Blob([Buffer.alloc(150000, 7)], { type: "image/jpeg" }), width: 1600, height: 1200, tv: opts.tv ? new Blob([tvJpg], { type: "image/jpeg" }) : undefined }; };
  w.sfWhere = async () => ({ lat: 39.7684, lng: -86.1581, accuracy: 7 });
  w.eval([...raw.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
async function snap(w) {                                   // the driver takes the photo
  const cam = w.document.getElementById("camera");
  const f = new w.File(["x"], "IMG_0001.jpg", { type: "image/jpeg", lastModified: Date.now() });
  Object.defineProperty(cam, "files", { value: [f], configurable: true });
  cam.dispatchEvent(new w.Event("change")); await wait(250);
}

(async () => {
  const hasTV = (await q1("select to_regclass('public.tv_photo_copies') is not null as h")).h;
  const pageVersion = (/PAGE_VERSION = "([^"]+)"/.exec(fs.readFileSync(`${OUT}/index.html`, "utf8")) || [])[1];
  console.log(`page ${pageVersion}, database ${hasTV ? "with" : "without"} tv_photos.sql`);
  if (OLDDB && hasTV) { console.log("OLDDB=1 but the database has tv_photos.sql: build sync from sync_base_old first."); process.exit(1); }

  // a white glove delivery on PROJ-00418, scheduled by the manager, as Julia would
  const job = await q1("select id from jobs where project_id = 'PROJ-00418'");
  const cid = (await q1("select gen_random_uuid() as id")).id;
  await admin.query("insert into loadouts (job_id, kind, client_id, scheduled_for, scheduled_by_name) values ($1, 'delivery', $2, now() + interval '1 hour', 'Julia R')", [job.id, cid]);
  const lo = await q1("select * from loadouts where client_id = $1", [cid]);

  // Shawn: the dock photo, the truck leaves, a table at the site
  let { w } = boot(users.shawn);
  await until(() => $$(w, "[data-loopen]").length, 8000); await wait(400);
  await click(w, `[data-loopen="${cid}"]`, 800);
  ok("Shawn opens the white glove delivery: dock, site, customer", /1 · At the dock/.test(txt(w)) && /2 · At the site/.test(txt(w)) && !!$(w, '[data-dltruck="1"]'));
  await click(w, '[data-dltruck="1"]'); await snap(w);
  await until(async () => (await q1("select count(*)::int n from photos where loadout_id = $1 and truck = 1", [lo.id])).n === 1);
  ok("The truck photo saves as before, and the camera stand-in was not asked for a TV copy", (await q1("select count(*)::int n from photos where loadout_id = $1 and truck = 1", [lo.id])).n === 1 && w.__shrinks[0] === false, String(w.__shrinks));
  await click(w, "[data-lofinish]"); await click(w, "[data-confirm]", 300);
  await until(async () => !!(await q1("select finished_at from loadouts where id = $1", [lo.id])).finished_at);
  await until(() => $$(w, "[data-dlsite]").length > 0, 6000);
  const slot = $(w, "[data-dlsite]");
  const sheet = Number(slot.dataset.dlsite), piece = Number(slot.dataset.piece);
  await click(w, slot); await snap(w);
  const got = await until(async () => (await q1("select count(*)::int n from photos where loadout_id = $1 and stage = 'site'", [lo.id])).n === 1, 8000);
  const ph = await q1("select * from photos where loadout_id = $1 and stage = 'site'", [lo.id]);
  ok(`A table at the site (sheet ${sheet}, table ${piece}) saves`, got && ph && ph.sheet_number === sheet && ph.piece === piece, got ? "" : "no site photo arrived");
  const newPage = /sendDeliveryPhoto/.test(fs.readFileSync(`${OUT}/index.html`, "utf8"));
  ok(newPage ? "The new page asked the camera for a TV copy of the site photo (and not of the truck)" : "The live page asks for no TV copy",
     newPage ? JSON.stringify(w.__shrinks) === "[false,true]" : !w.__shrinks.includes(true), String(w.__shrinks));
  ok("Nothing is left waiting on the phone", !/waiting to send|Couldn't send/.test(txt(w)), txt(w).slice(0, 100));

  if (!hasTV) {
    ok("Older database: the site photo saved without a copy, and the page shows no error", !!ph && !/isn't set up|Couldn't send/i.test(txt(w)), (txt(w).match(/.{30}(isn't set up|Couldn't send).{30}/i) || [""])[0]);
    w.close(); console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  const copy = await q1("select * from tv_photo_copies where photo_id = $1", [ph.id]);
  const truckCopy = await q1("select count(*)::int n from tv_photo_copies c join photos p on p.id = c.photo_id where p.loadout_id = $1 and p.stage = 'dock'", [lo.id]);
  if (newPage) {
    ok("The copy is in tv_photo_copies: the JPEG the phone made, byte for byte", copy && Buffer.compare(copy.jpeg, tvJpg) === 0 && copy.bytes === tvJpg.length, copy ? `${copy.bytes} bytes` : "no copy");
  } else {
    ok("The live page on the new database: the photo saves and no copy is kept (the TV simply shows nothing for it)", !copy);
  }
  ok("No copy of the truck photo", truckCopy.n === 0);

  // the TV: nothing until the trip is finished; then the picture, one fetch
  const key = (await q1("select new_tv_link()->>'key' as k")).k;
  let snapTV = await q1("select tv_snapshot($1) as v", [key]);
  ok("The TV's home list is empty while the delivery is still out", Array.isArray(snapTV.v.home) && snapTV.v.home.length === 0 && !("table" in snapTV.v) && !("kpis" in snapTV.v));
  await admin.query("update loadouts set completed_at = now(), signed_name = 'Pat Jones', signed_at = now() where id = $1", [lo.id]);
  snapTV = await q1("select tv_snapshot($1) as v", [key]);
  const item = snapTV.v.home.find(h => h.project_id === "PROJ-00418");
  if (newPage) {
    ok("Once delivered and signed, the TV lists one picture for PROJ-00418, 1 table delivered", item && item.id === ph.id && item.tables === 1, JSON.stringify(snapTV.v.home));
    const pic = await q1("select tv_photo($1, $2) as v", [key, ph.id]);
    ok("tv_photo hands the TV the copy", pic.v.ok && Buffer.compare(Buffer.from(pic.v.jpeg, "base64"), tvJpg) === 0);
    const no = await q1("select tv_photo('not-the-key', $1) as v", [ph.id]);
    ok("…and nothing without the link", JSON.stringify(no.v) === '{"ok":false}');
  } else {
    ok("With the live page's photo (no copy), the TV lists nothing for the job", !item);
  }
  w.close();

  // ---- the office: the job page's Floor TV line and the hide switch (only with the new office page) ----
  const officeRaw = fs.readFileSync(`${OUT}/office.html`, "utf8");
  if (newPage && /tv_job_pictures/.test(officeRaw)) {
    const o = bootOffice(users.luke); const ow = o.w;
    await until(() => $$(ow, "[data-jobfind]").length, 8000); await wait(300);
    const fnd = $(ow, "[data-jobfind]"); fnd.focus(); await wait(800);
    fnd.value = "00418"; fnd.dispatchEvent(new ow.Event("input", { bubbles: true })); await wait(300);
    await until(() => $$(ow, "[data-openjob]").length, 6000);
    $(ow, "[data-openjob]").dispatchEvent(new ow.MouseEvent("mousedown", { bubbles: true })); await wait(1500);
    await until(() => /Floor TV/.test(txt(ow)), 6000);
    ok("The job page says one picture of the job shows on the floor TV", /1 picture (of this job shows )?on the floor TV/.test(txt(ow)), (txt(ow).match(/Floor TV.{0,120}/) || [""])[0]);
    await click(ow, '[data-tvjob][data-hide="1"]', 1500);
    await until(() => /[Hh]idden from the floor TV/.test(txt(ow)), 6000);
    const hid = await q1("select hidden from tv_hides where job_id = $1 order by set_at desc limit 1", [job.id]);
    ok("Hide this job's pictures: recorded, the page says so, the TV lists nothing", hid && hid.hidden === true && /[Hh]idden from the floor TV/.test(txt(ow))
       && (await q1("select tv_snapshot($1) as v", [key])).v.home.length === 0, (txt(ow).match(/Floor TV.{0,80}/) || [""])[0]);
    await click(ow, '[data-tvjob][data-hide="0"]', 1500);
    await until(() => /1 picture (of this job shows )?on the floor TV/.test(txt(ow)), 6000);
    ok("…and Let them show again puts it back", /1 picture (of this job shows )?on the floor TV/.test(txt(ow)) && (await q1("select tv_snapshot($1) as v", [key])).v.home.length === 1);
    // one picture, from the viewer on Photos
    await click(ow, "[data-jobphotos]", 1500);
    await until(() => $$(ow, "[data-viewphoto]").length, 6000);
    await click(ow, `[data-viewphoto="${ph.id}"]`, 400);
    ok("The viewer offers Hide from the floor TV on a white glove site photo", !!$(ow, `[data-tvpic="${ph.id}"][data-hide="1"]`), txt(ow, ".viewer").slice(0, 160));
    await click(ow, `[data-tvpic="${ph.id}"][data-hide="1"]`, 1500);
    const hid2 = await q1("select hidden from tv_hides where photo_id = $1 order by set_at desc limit 1", [ph.id]);
    ok("Hiding one picture: recorded, and the TV no longer lists it", hid2 && hid2.hidden === true && (await q1("select tv_snapshot($1) as v", [key])).v.home.length === 0);
    await click(ow, `[data-viewphoto="${ph.id}"]`, 400);
    ok("…the viewer now offers Show on the floor TV again", !!$(ow, `[data-tvpic="${ph.id}"][data-hide="0"]`));
    ow.close();
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
