// 11 Nov: delivery_photos_open.sql + index.html 2026-11-11.1 + delivery.html 2026-11-11.1, through the pages themselves.
// A white glove trip kept open for days (PROJ-00418, 20 tables on 9 sheets): its done sheets fold into one line, the
// calendar says Out since, there's no trip bar on another tab, the last table's photo is saved (it used to be refused 3
// days after the truck left), and Julia's page lists it under Out, not finished. Shawn's landing page: Start a load-out
// behind one button. A trip with tables unphotographed (PROJ-00099): Delivered asks, Some stayed, a part delivery in one
// tap. A photo the database refuses (its trip cancelled meanwhile): on Couldn't send, reported, on Julia's page; gone
// from there when dismissed.
//   TEMPLATE=sync_base_new bash base/fresh.sh && PAGE=/home/claude/sf/out/index.html OUT=/tmp/allpages TZ=America/Indiana/Indianapolis node test_delivery_photos_open.js
// OLDDB=1 on TEMPLATE=sync_base_old: the new phone page on the live database. The kept-open trip's last photo is refused
// as before (on Couldn't send, kept), nothing breaks, and Delivered still asks and finishes.
const fs = require("fs"), crypto = require("crypto"), path = require("path");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html", OLDDB = !!process.env.OLDDB;
const OUT = process.env.OUT || "/home/claude/sf/out";
const RAW = fs.readFileSync(PAGE, "utf8");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${c || !x ? "" : "  — " + x}`); };
async function until(fn, ms = 8000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(40); } return false; }
const q = (s, a) => admin.query(s, a).then(r => r.rows);
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
const tx = (el) => ((el || {}).textContent || "").replace(/\s+/g, " ").trim();
async function click(w, sel, pause = 250) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
let shots = 0;
function boot(user, idb) {
  const client = makeClient(user), errs = [];
  const w = new JSDOM(RAW, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html", pretendToBeVisual: true }).window;
  const fidb = require("fake-indexeddb"); w.indexedDB = idb || new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.File = File; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => null; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.Request = Request; w.Response = Response; w.sfNet = () => "wifi";
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.sfShrinkPhoto = async () => ({ blob: new Blob([Buffer.alloc(150000 + (shots++), 7)], { type: "image/jpeg" }), width: 1600, height: 1200 });
  w.sfWhere = async () => ({ lat: 39.7684, lng: -86.1581, accuracy: 7 });
  w.addEventListener("error", (e) => errs.push(e.message));
  w.eval([...RAW.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, idb: w.indexedDB, errs };
}
const fileOf = (f) => fs.existsSync(`${OUT}/${f}`) ? `${OUT}/${f}` : `/home/claude/sf/repo/${f}`;
function bootPage(page, user) {
  const raw = fs.readFileSync(fileOf(page), "utf8"), html = raw.replace(/<script src="[^"]+"[^>]*><\/script>/g, ""), client = makeClient(user);
  const script = [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(fileOf(m[1]), "utf8"))
    .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");
  const w = new JSDOM(html, { runScripts: "outside-only", url: `https://lukehart1228.github.io/shop-floor/${page}`, pretendToBeVisual: true }).window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => null; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.eval(script);
  return w;
}
async function snap(w) { const cam = w.document.getElementById("camera");
  const f = new w.File(["x"], "IMG.jpg", { type: "image/jpeg", lastModified: Date.now() });
  Object.defineProperty(cam, "files", { value: [f], configurable: true }); cam.dispatchEvent(new w.Event("change")); await wait(250); }
async function toLoadout(w) {
  await until(() => $$(w, "#app [data-loopen]").length || $(w, "[data-loback]"), 8000); await wait(600);    // the phone may reopen on the last trip
  if ($(w, "[data-loback]")) await click(w, "[data-loback]", 500); await click(w, '[data-tab="loadout"]', 900); }
async function openTrip(w, cid) {
  await toLoadout(w);
  const b = () => $$(w, "#app [data-loopen]").find(x => x.dataset.loopen === cid);
  await until(() => b(), 8000);
  for (let i = 0; !b() && i < 2; i++) await click(w, "[data-calnext]", 400);
  await click(w, b(), 900); await until(() => /The customer|The receiver/.test(txt(w)), 6000); await wait(300);
}
const call = async (c, fn, args) => { const r = await c.rpc(fn, args); if (r.error) throw new Error(fn + ": " + r.error.message); return r.data; };
const at = (days, h) => { const d = new Date(); d.setDate(d.getDate() + days); d.setHours(h, 0, 0, 0); return d; };

(async () => {
  const luke = makeClient(users.luke);
  const job = async (pid) => (await q("select id from jobs where project_id = $1", [pid]))[0].id;
  const j418 = await job("PROJ-00418"), j99 = await job("PROJ-00099");

  // ---- a trip kept open: the truck left 5 days ago; 19 of 20 tables photographed then ----
  const k = crypto.randomUUID();
  await call(luke, "schedule_delivery", { p_job: j418, p_when: at(0, 15).toISOString(), p_note: "Last table, back dock", p_loadout: null, p_client_id: k });
  const lo = (await q("update loadouts set finished_at = now() - interval '5 days', finished_by_name = 'Shawn K' where client_id = $1 returning id", [k]))[0].id;
  const sheets = await q("select s.sheet_number, s.qty from work_orders w join sheets s on s.work_order_id = w.id where w.job_id = $1 and w.is_current order by 1", [j418]);
  const all = sheets.flatMap(s => Array.from({ length: s.qty }, (_, i) => `${s.sheet_number}:${i + 1}`)), last = all[all.length - 1];
  for (const key of all.slice(0, -1)) { const [sh, pc] = key.split(":").map(Number);
    await q(`insert into photos (client_id, job_id, department, kind, loadout_id, stage, sheet_number, piece, storage_path, taken_by_name, taken_at, shot_at)
             values (gen_random_uuid(), $1, 'delivery', 'loadout', $2, 'site', $3, $4, 'PROJ-00418/' || gen_random_uuid() || '.jpg', 'Shawn K', now() - interval '5 days', now() - interval '5 days')`, [j418, lo, sh, pc]); }

  let { w, idb, errs } = boot(users.shawn);
  await until(() => $(w, '[data-tab="loadout"]'), 8000);
  await toLoadout(w); await wait(600);
  if (!OLDDB) {
    const card = $$(w, "#app [data-loopen]").find(b => b.dataset.loopen === k);
    ok("The calendar card says Out since the day of its first photo, and 19 of 20 at the site", !!card && /Out since \w{3} \w{3} \d{1,2}/.test(tx(card)) && /19 of 20/.test(tx(card)), tx(card));
    ok("No trip bar for it: nothing happened on it today", !$(w, ".tripbar"), $$(w, ".tripbar").map(tx).join(" | "));
    ok("Start a load-out is one button; the job picker isn't on the landing page", !!$(w, "[data-lostartopen]") && !$(w, "[data-lostart]"));
    await click(w, "[data-lostartopen]", 300);
    ok("…which opens Start a load-out as before", !!$(w, "[data-lostart]") && /Start a load-out/.test(txt(w)));
  }
  await openTrip(w, k);
  ok("The trip: truck photo optional, no The truck is leaving, and no Not everything box",
     /1 · Truck photo · optional/.test(txt(w)) && !$(w, "[data-lofinish]") && !$(w, ".partbox"), (txt(w).match(/1 · [^·]+· optional/) || [""])[0]);
  const fold = $(w, ".tbfold");
  ok("Its done sheets fold into one line, and the one table left is the only row", !!fold && /✓ 8 sheets · 19 tables done/.test(tx(fold)) && $$(w, ".tbrow").length === 1 && $$(w, "[data-dlsite]").length === 1,
     `${tx(fold)} · ${$$(w, ".tbrow").length} rows`);
  await click(w, ".tbfold", 300);
  ok("Show unfolds them: 9 rows, 20 tables, 19 turquoise", $$(w, ".tbrow").length === 9 && $$(w, ".tb[data-dlsite]").length === 20 && $$(w, ".tb.here[data-dlsite]").length === 19);
  const [ls, lp] = last.split(":");
  const tb = $(w, `[data-dlsite="${ls}"][data-piece="${lp}"]`);
  ok("Each table is a button read out as which table it is", /^Sheet \d+, (the table|table \d+): not photographed yet$/.test(tb.getAttribute("aria-label")), tb.getAttribute("aria-label"));
  await click(w, tb); await snap(w);
  if (!OLDDB) {
    await until(async () => (await q("select count(*)::int n from photos where loadout_id = $1 and sheet_number = $2 and piece = $3 and voided_at is null", [lo, Number(ls), Number(lp)]))[0].n === 1, 8000);
    const n = (await q("select count(*)::int n from photos where loadout_id = $1 and sheet_number = $2 and piece = $3", [lo, Number(ls), Number(lp)]))[0].n;
    ok("The last table's photo is saved, 5 days after the truck left (it used to be refused)", n === 1, `${n} saved`);
  } else {
    await until(() => /Couldn't send|couldn't send/i.test(txt(w, "body")) || $$(w, "[data-failretry]").length > 0, 8000); await wait(1200);
    const n = (await q("select count(*)::int n from photos where loadout_id = $1 and sheet_number = $2 and piece = $3", [lo, Number(ls), Number(lp)]))[0].n;
    ok("Old database: the photo is refused as before, and kept on the phone", n === 0 && /finished on/.test(txt(w, "body")), txt(w, "body").match(/[^.]*finished on[^.]*\./) ? txt(w, "body").match(/[^.]*finished on[^.]*\./)[0] : "");
  }

  // ---- Julia's page: Out, not finished ----
  if (!OLDDB) {
    const J = bootPage("delivery.html", users.luke);
    await until(() => $(J, '[data-tab="up"]'), 8000); await click(J, '[data-tab="up"]', 300);
    await until(() => /Out, not finished|Scheduled deliveries/.test(txt(J)), 8000); await wait(300);
    const oc = $(J, ".card.out");
    ok("Julia's page: Out, not finished, first, with this trip, saying since when and the last photo", !!oc && /^Out, not finished/.test(tx($(J, "h3.sec")))
       && /PROJ-00418/.test(tx(oc)) && /Out since \w{3} \w{3} \d{1,2} · last photo \w{3} \w{3} \d{1,2}/.test(tx(oc)), oc ? tx(oc).slice(0, 220) : txt(J).slice(0, 200));
    ok("…with everything a scheduled card has (ticket, files, change, cancel)", !!oc && !!oc.querySelector("[data-addticket]") && !!oc.querySelector("[data-editwhen]") && !!oc.querySelector("[data-cancel]"));
  }

  // ---- PROJ-00099: 7 of 9 tables photographed through the page; Delivered asks; Some stayed; part delivered ----
  const p = crypto.randomUUID();
  await call(luke, "schedule_delivery", { p_job: j99, p_when: at(0, 16).toISOString(), p_note: null, p_loadout: null, p_client_id: p });
  w.close(); ({ w, idb, errs } = boot(users.shawn, idb));
  await until(() => $(w, '[data-tab="loadout"]'), 8000);
  await openTrip(w, p);
  const keys = $$(w, "[data-dlsite]").map(b => `${b.dataset.dlsite}:${b.dataset.piece}`);
  for (const key of keys.slice(0, 7)) { const [sh, pc] = key.split(":"); await click(w, `[data-dlsite="${sh}"][data-piece="${pc}"]`); await snap(w); }
  const lo2 = (await q("select id from loadouts where client_id = $1", [p]))[0].id;
  await until(async () => (await q("select count(*)::int n from photos where loadout_id = $1", [lo2]))[0].n === 7, 10000);
  await until(() => $$(w, ".tb.here[data-dlsite]").length === 7, 6000);
  ok("Seven tables photographed at the site, through the rows", (await q("select count(*)::int n from photos where loadout_id = $1", [lo2]))[0].n === 7 && $$(w, ".tb.here[data-dlsite]").length === 7, String($$(w, ".tb.here[data-dlsite]").length));
  if (!OLDDB) ok("Something happened on it today, so its trip bar is up on another tab", await (async () => { await click(w, '[data-tab="issues"]', 600); const b = $$(w, ".tripbar").find(x => /PROJ-00099/.test(tx(x))); const r = !!b && /^AT THE SITE/.test(tx(b.querySelector("small"))); if (b) await click(w, b, 900); await until(() => /The customer/.test(txt(w)), 5000); return r; })());
  await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Nobody on site"]');
  ok("The button is the plain Delivered", /^Delivered — not signed$/.test(tx($(w, "[data-dldone]"))), tx($(w, "[data-dldone]")));
  await click(w, "[data-dldone]", 300);
  ok("Delivered asks: 2 tables have no photo, naming them", /2 tables have no photo/.test(txt(w, ".mdl")) && /Did they go today\?/.test(txt(w, ".mdl")), txt(w, ".mdl").slice(0, 160));
  await click(w, "[data-close]", 200);
  ok("Go back closes it with nothing sent", !$(w, ".mdl") && !(await q("select completed_at from loadouts where id = $1", [lo2]))[0].completed_at);
  await click(w, "[data-dldone]", 300); await click(w, "[data-asksome]", 300);
  const left = keys.slice(7);
  ok("Some stayed: the two, each Stayed", $$(w, ".mdl [data-partpiece]").length === 2 && $$(w, ".mdl [data-partpiece]").every(b => /Stayed/.test(tx(b))), $$(w, ".mdl [data-partpiece]").map(tx).join(" | "));
  await click(w, `[data-partpiece="${left[0]}"]`); await click(w, '[data-partreason="Wouldn\'t fit"]');
  ok("One went with no photo, one stayed: today 8 of 9, and the button is ready", /Today: 8 of 9 tables/.test(tx($(w, ".partsum"))) && !$(w, "[data-askpart]").disabled && /^Part delivered · not signed$/.test(tx($(w, "[data-askpart]"))), tx($(w, ".partsum")));
  await click(w, "[data-askpart]", 800);
  await until(async () => !!(await q("select completed_at from loadouts where id = $1", [lo2]))[0].completed_at, 10000);
  const tp = (await q("select went_pieces, left_pieces, reason from trip_parts where loadout_id = $1", [lo2]))[0];
  ok("Sent in one tap: 8 went, 1 left, Wouldn't fit; the rest waits for a day", !!tp && tp.went_pieces.length === 8 && tp.left_pieces.length === 1 && tp.left_pieces[0] === left[1] && tp.reason === "Wouldn't fit",
     tp ? JSON.stringify(tp) : "no trip_parts row");

  // ---- a photo the database refuses: on Couldn't send, reported, on Julia's page; gone when dismissed ----
  const c = crypto.randomUUID();
  await call(luke, "schedule_delivery", { p_job: j418, p_when: at(1, 9).toISOString(), p_note: null, p_loadout: null, p_client_id: c });
  w.close(); ({ w, idb, errs } = boot(users.shawn, idb));
  await until(() => $(w, '[data-tab="loadout"]'), 8000);
  await openTrip(w, c);
  setOffline(true);
  await click(w, $(w, "[data-dlsite]")); await snap(w);
  await q("update loadouts set voided_at = now(), voided_by_name = 'Julia R', void_reason = 'Delivery cancelled' where client_id = $1", [c]);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(() => $$(w, "[data-failretry]").length > 0 || /Couldn't send/.test(txt(w, "body")), 15000); await wait(1500);
  const dev = OLDDB ? null : (await q("select items, photos, jobs from device_unsent order by reported_at desc limit 1"))[0];
  if (!OLDDB) {
    ok("Refused (its trip was cancelled): the phone reports 1 photo it couldn't send, on PROJ-00418", !!dev && dev.items === 1 && dev.photos === 1 && dev.jobs.includes("PROJ-00418"), JSON.stringify(dev));
    let J = bootPage("delivery.html", users.luke);
    await until(() => $(J, '[data-tab="up"]'), 8000); await click(J, '[data-tab="up"]', 300);
    await until(() => /Scheduled deliveries|Out, not finished/.test(txt(J)), 8000); await wait(300);
    ok("Julia's page: Shawn K's phone is holding 1 photo it couldn't send", /Shawn K's phone is holding 1 photo it couldn't send/.test(txt(J)) && /PROJ-00418/.test(tx($(J, ".banner.warn"))), ($(J, ".banner.warn") ? tx($(J, ".banner.warn")) : "no banner"));
    const mikeSees = await makeClient(users.mike).rpc("unsent_on_phones", {});
    ok("Mike (another department) can't read it, through the same login path", !!mikeSees.error, mikeSees.error ? "" : JSON.stringify(mikeSees.data));
    if (!$(w, "[data-faildismiss]")) await click(w, "[data-failed]", 300);           // Couldn't send, at the top
    await click(w, "[data-faildismiss]", 300); await click(w, "[data-confirm]", 600);      // Dismiss asks first
    await until(async () => (await q("select items from device_unsent order by reported_at desc limit 1"))[0].items === 0, 6000);
    J = bootPage("delivery.html", users.luke);
    await until(() => $(J, '[data-tab="up"]'), 8000); await click(J, '[data-tab="up"]', 300);
    await until(() => /Scheduled deliveries|Out, not finished/.test(txt(J)), 8000); await wait(300);
    ok("Dismissed on the phone: the report goes to 0 and Julia's page no longer says so", (await q("select items from device_unsent order by reported_at desc limit 1"))[0].items === 0 && !/couldn't send/.test(txt(J)));
  } else {
    ok("Old database: the refusal is on Couldn't send, and reporting it fails quietly", $$(w, "[data-failretry]").length > 0 || /Couldn't send/.test(txt(w, "body")));
  }
  ok("No script errors on the page", errs.length === 0, errs.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error("CRASH", e.stack || e.message); process.exit(1); });
