// 26 Oct: when not everything goes (incomplete_deliveries.sql, index.html 2026-10-26.1). Delivery's phone:
// the Not everything was delivered box (ticked by itself when a table has no photo), the tables ticked from this trip's
// photos and fixed by a tap, the extras that went, one tap for why, the button's words, the check, the one-step send,
// the finished trip, the calendar, Waiting for a new date, the rest once it has a day (only its own tables, the box at the
// top, the ticket), a pickup's rest back on Ready for pickup, the damage report offer, and the page on the old database.
// Run on a fresh database with the new file:
//   bash /home/claude/sf/base/fresh.sh /home/claude/sf/out/sql/incomplete_deliveries.sql && TZ=America/Indiana/Indianapolis node test_incomplete_deliveries.js
// OLDDB=1, on a database without it (TEMPLATE=sync_base_old bash fresh.sh): no box, and a delivery finishes as before.
// PAGE=/home/claude/sf/repo/index.html runs it on the live page, where it must fail (no box).
const fs = require("fs");
const crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html", OLDDB = !!process.env.OLDDB;
const HTML = fs.readFileSync(PAGE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const SCRIPT = [...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(HTML, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  let n = 0; w.Blob = Blob; w.URL.createObjectURL = () => "blob:t" + (n++); w.URL.revokeObjectURL = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.print = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.open = () => null;
  w.Request = Request; w.Response = Response; w.sfNet = () => "wifi";
  w.eval(SCRIPT);
  return { w, client };
}
// Julia's page: the page's own files from OUT (else the repo), and the shared script it loads, as one piece
const OUT = process.env.OUT || "/home/claude/sf/out";
const fileOf = (f) => fs.existsSync(`${OUT}/${f}`) ? `${OUT}/${f}` : `/home/claude/sf/repo/${f}`;
function bootPage(page, user, pre = {}) {
  const raw = fs.readFileSync(fileOf(page), "utf8"), html = raw.replace(/<script src="[^"]+"[^>]*><\/script>/g, ""), client = makeClient(user);
  const script = [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(fileOf(m[1]), "utf8"))
    .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");
  const w = new JSDOM(html, { runScripts: "outside-only", url: `https://lukehart1228.github.io/shop-floor/${page}`, pretendToBeVisual: true }).window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => null; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  for (const [k, v] of Object.entries(pre)) w.localStorage.setItem(k, v);
  w.eval(script);
  return { w, client };
}
/** pdf-lib stood in for: every line of text the record page draws. */
function stubPdf() {
  const texts = [], page = { drawText: (t) => texts.push(String(t)), drawRectangle: () => {}, drawImage: () => {} };
  const font = { widthOfTextAtSize: (str, size) => String(str).length * size * 0.5 };
  const doc = { addPage: () => page, embedFont: async () => font, setTitle: () => {}, embedPng: async () => ({ width: 10, height: 10 }),
                embedJpg: async () => ({ width: 10, height: 10 }), save: async () => new Uint8Array([1]) };
  return { PDFLib: { PDFDocument: { create: async () => doc, load: async () => doc }, StandardFonts: {}, rgb: () => 0 }, texts };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
const tx = (el) => ((el || {}).textContent || "").replace(/\s+/g, " ").trim();
async function click(w, sel, pause = 200) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const at = (days, h, m = 0) => { const d = new Date(); d.setDate(d.getDate() + days); d.setHours(h, m, 0, 0); return d; };
const dayWord = (d) => `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]} ${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]} ${d.getDate()}`;
// the Load-out tab is a calendar, a week at a time: the nth trip matching `want`, this week, then the next two
async function tripButton(w, want, nth = 0) {
  const match = () => [...w.document.querySelectorAll("#app [data-loopen]")].filter(b => typeof want === "function" ? want(b) : b.textContent.includes(want));
  const cal = () => w.document.querySelector("#app [data-calnext]");
  await until(() => match().length > nth || cal(), 8000);
  if (!cal()) return match()[nth] || null;
  w.document.querySelector("#app [data-caltoday]").click(); await wait(150);
  const found = [];
  for (let k = 0; k < 3; k++) {
    await until(() => match().some(b => !found.includes(b.dataset.loopen)), k ? 500 : 6000);
    for (const b of match()) if (!found.includes(b.dataset.loopen)) found.push(b.dataset.loopen);
    if (found.length > nth) return match().find(b => b.dataset.loopen === found[nth]) || null;
    cal().click(); await wait(250);
  }
  return null;
}
async function toLoadout(w) { if ($(w, "[data-loback]")) await click(w, "[data-loback]", 500); await click(w, '[data-tab="loadout"]', 800); }
async function openTrip(w, want) { await toLoadout(w); await click(w, await tripButton(w, want), 900); await until(() => /The customer|The receiver/.test(txt(w)), 6000); await wait(300); }
const piece = (w, k) => $(w, `[data-partpiece="${k}"]`);

(async () => {
  const q = (sql, a) => admin.query(sql, a);
  const luke = makeClient(users.luke);
  const job = (pid) => q("select id from jobs where project_id = $1", [pid]).then(r => r.rows[0].id);
  const call = async (fn, args) => { const r = await luke.rpc(fn, args); if (r.error) throw new Error(fn + ": " + r.error.message); return r.data; };
  const shawnDb = makeClient(users.shawn);
  // PROJ-00418 (9 sheets, 20 tables): 3 data ports on sheet 4, as the upload would add them
  await q(`insert into sheet_extras (sheet_id, position, name, qty)
           select s.id, 1, 'Data port', 3 from work_orders w join jobs j on j.id = w.job_id join sheets s on s.work_order_id = w.id
            where j.project_id = 'PROJ-00418' and w.is_current and s.sheet_number = 4`);
  await q(`insert into work_order_extras (work_order_id, extras) select w.id, 1 from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00418' and w.is_current`);
  // a white glove delivery today at 9:00, with a ticket; the truck went, 17 of its 20 tables photographed at the site, 3 data ports loaded
  const c1 = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: at(0, 9).toISOString(), p_note: "Back dock", p_loadout: null, p_client_id: c1 });
  const lo1 = (await q("select id, job_id from loadouts where client_id = $1", [c1])).rows[0];
  const tk = crypto.randomUUID(), tpath = `PROJ-00418/${c1}/${tk}.pdf`;
  await luke.storage.from("deliveries").upload(tpath, new Blob([Buffer.from("%PDF ticket")], { type: "application/pdf" }), { contentType: "application/pdf", upsert: false });
  await call("add_delivery_doc", { p_client_id: tk, p_loadout: c1, p_kind: "ticket", p_file_name: "Ticket.pdf" });
  const photo = (loadout, jobId, stage, sheet, pc) => q(`insert into photos (client_id, job_id, department, kind, loadout_id, stage, sheet_number, piece, storage_path, taken_by_name, shot_at)
      values ($1, $2, 'delivery', 'loadout', $3, $4, $5, $6, $7, 'Shawn K', now())`, [crypto.randomUUID(), jobId, loadout, stage, sheet, pc, `PROJ-X/${crypto.randomUUID()}.jpg`]);
  const sheets = (await q(`select s.sheet_number, s.qty from jobs j join work_orders w on w.job_id = j.id and w.is_current join sheets s on s.work_order_id = w.id
                           where j.project_id = 'PROJ-00418' order by 1`)).rows;
  for (const s of sheets) for (let p = 1; p <= s.qty; p++) if (!["7:3", "7:4", "9:1"].includes(`${s.sheet_number}:${p}`)) await photo(lo1.id, lo1.job_id, "site", s.sheet_number, p);
  if (!OLDDB) { const r = await shawnDb.rpc("set_extra_loaded", { p_loadout: c1, p_sheet: 4, p_name: "Data port", p_loaded: 3, p_client_id: null }); if (r.error) throw new Error(r.error.message); }

  let { w } = boot(users.shawn);
  await until(() => $(w, '[data-tab="loadout"]'), 8000);
  await openTrip(w, "PROJ-00418");

  if (OLDDB) {
    ok("Old database: no Not everything was delivered box", !$(w, ".partbox"), txt(w).slice(0, 80));
    await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Nobody on site"]');
    ok("…and the button is the plain one", /^Delivered — not signed$/.test(tx($(w, "[data-dldone]"))), tx($(w, "[data-dldone]")));
    await click(w, "[data-dldone]"); await click(w, "[data-confirm]", 600);
    await until(async () => (await q("select completed_at from loadouts where client_id = $1", [c1])).rows[0].completed_at, 8000);
    ok("…and it's marked delivered as before", !!(await q("select completed_at from loadouts where client_id = $1", [c1])).rows[0].completed_at);
    console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
  }

  // ---- the box ticks itself; the tables come ticked from the photos ----
  const box = $(w, ".partbox");
  ok("The trip's last step has the Not everything was delivered box, ticked by itself", !!box && !!$(w, '[data-partbox="1"]') && $(w, '[data-partbox="1"]').checked, tx(box).slice(0, 90));
  ok("…saying why: 3 tables have no photo at the site", /Ticked because 3 tables have no photo at the site/.test(tx(box)), tx(box).slice(0, 140));
  ok("Tables photographed at the site come ticked as gone; the three without a photo don't",
     piece(w, "7:1").getAttribute("aria-pressed") === "true" && piece(w, "7:3").getAttribute("aria-pressed") === "false" && piece(w, "9:1").getAttribute("aria-pressed") === "false"
     && /To come/.test(tx(piece(w, "7:3"))), [tx(piece(w, "7:1")), tx(piece(w, "7:3"))].join(" | "));
  ok("Each sheet shows its count: sheet 7, 2 of 4 went", /2 of 4 went/.test(tx(piece(w, "7:3").closest(".partrow"))), tx(piece(w, "7:3").closest(".partrow")).slice(0, 60));
  ok("The summary: today 17 of 20 tables, Data port 3 of 3", /Today: 17 of 20 tables · Data port 3 of 3/.test(tx($(w, ".partsum"))), tx($(w, ".partsum")).slice(0, 120));

  // ---- fixing it by a tap; the extras; why ----
  await click(w, piece(w, "9:1"));                // went, with no photo
  await click(w, piece(w, "1:1"));                // photographed, but it came back
  await click(w, '[data-partx="4|Data port"][data-to="2"]');
  ok("A tap ticks one that went with no photo, and unticks one that came back",
     /Went · no photo/.test(tx(piece(w, "9:1"))) && /Came back/.test(tx(piece(w, "1:1"))) && piece(w, "1:1").getAttribute("aria-pressed") === "false", [tx(piece(w, "9:1")), tx(piece(w, "1:1"))].join(" | "));
  ok("Data ports: how many went, 2 of the 3 loaded", /2 of 3 went · 3 loaded/.test(tx($(w, ".partx"))), tx($(w, ".partx")));
  const sum = tx($(w, ".partsum"));
  ok("Still to come: 3 tables (sheet 1: the table · sheet 7: tables 3, 4) and 1 extra", /Still to come: 3 tables \(sheet 1: the table · sheet 7: tables 3, 4\) and 1 extra\./.test(sum), sum);
  await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Nobody on site"]');
  const btn = () => $(w, "[data-dldone]");
  ok("The button says Part delivered, and waits for why", /^Part delivered — not signed$/.test(tx(btn())) && btn().disabled, tx(btn()));
  await click(w, '[data-partreason="Other"]');
  ok("Other needs a few words first", btn().disabled && /needed/.test(tx($(w, 'label[for="partNote"]'))));
  await click(w, '[data-partreason="Site not ready"]');
  const note = $(w, "[data-partnote]"); note.value = "Reading room still being carpeted"; note.dispatchEvent(new w.Event("input")); await wait(100);
  ok("One tap for why, and it can be finished", !btn().disabled && $(w, '[data-partreason="Site not ready"]').getAttribute("aria-pressed") === "true");
  // the box off: an ordinary delivery's button; on again
  $(w, '[data-partbox="1"]').checked = false; $(w, '[data-partbox="1"]').dispatchEvent(new w.Event("change")); await wait(200);
  ok("Unticking the box gives back the ordinary button", /^Delivered — not signed$/.test(tx(btn())) && !$(w, ".partsum"), tx(btn()));
  $(w, '[data-partbox="1"]').checked = true; $(w, '[data-partbox="1"]').dispatchEvent(new w.Event("change")); await wait(200);
  ok("…and ticking it again keeps what was set", /Came back/.test(tx(piece(w, "1:1"))) && /2 of 3 went/.test(tx($(w, ".partx"))) && /^Part delivered — not signed$/.test(tx(btn())));

  // ---- the check, and the one-step send ----
  await click(w, btn());
  const m = txt(w, ".mdl");
  ok("The check says what went, what didn't and where the rest goes",
     /Part delivered, not signed\?/.test(m) && /17 of 20 tables and 2 of 3 × Data port went today/.test(m)
     && /The other 3 tables \(sheet 1: the table · sheet 7: tables 3, 4\) and 1 extra go on a new trip for PROJ-00418; the office gives it a day and time/.test(m), m.slice(0, 260));
  await click(w, "[data-confirm]", 800);
  await until(async () => (await q("select completed_at from loadouts where client_id = $1", [c1])).rows[0].completed_at, 10000);
  const tp = (await q(`select tp.*, r.client_id as rest_cid, r.kind as rest_kind, r.scheduled_for as rest_when from trip_parts tp join loadouts r on r.id = tp.rest_id where tp.loadout_id = $1`, [lo1.id])).rows[0];
  const pe = (await q("select went, loaded from part_extras where loadout_id = $1", [lo1.id])).rows[0];
  ok("Sent in one step: the trip is done, with what went, what didn't and why",
     !!tp && tp.went_pieces.length === 17 && JSON.stringify([...tp.left_pieces].sort()) === JSON.stringify(["1:1", "7:3", "7:4"]) && tp.reason === "Site not ready"
     && tp.reason_note === "Reading room still being carpeted" && tp.extras_left === 1 && pe && pe.went === 2 && pe.loaded === 3,
     tp ? `went ${tp.went_pieces.length}, left ${tp.left_pieces}, extras left ${tp.extras_left}, data ports ${pe && pe.went}` : "no trip_parts row");
  ok("…and the rest is a new white glove trip with no day yet", !!tp && tp.rest_kind === "delivery" && !tp.rest_when, tp ? `${tp.rest_kind} ${tp.rest_when}` : "");
  await until(() => /The rest waits for the office/.test(txt(w)), 8000);
  ok("The finished trip says Part delivered and where the rest is", /Part delivered · not signed \(Nobody on site\)/.test(txt(w)) && /17 of 20 tables went\. The rest waits for the office to give it a day\./.test(txt(w)),
     (txt(w).match(/Part delivered[^.]*\./) || [""])[0]);

  // ---- the calendar and Waiting for a new date ----
  await toLoadout(w);
  await until(() => /Waiting for a new date/.test(txt(w)), 6000);
  const done = $$(w, ".calitem.done").find(e => /PROJ-00418/.test(tx(e)));
  ok("On the calendar: ✓ Part delivered, 17 of 20 tables · 3 to come", !!done && /✓ Part delivered/.test(tx(done)) && /17 of 20 tables · 3 to come/.test(tx(done)), tx(done));
  const waitCard = $(w, ".restwait");
  ok("Under the calendar, Waiting for a new date: the rest, what's on it and why",
     !!waitCard && new RegExp(`PROJ-00418.*The rest of ${dayWord(new Date())}'s · 3 tables and 1 extra · white glove · Site not ready`).test(tx(waitCard)), tx(waitCard));

  // ---- Julia's page: Needs a new date; Completed says Part delivered; the record page lists what's still to come ----
  const J = bootPage("delivery.html", users.luke).w;
  await until(() => $(J, '[data-tab="up"]') || /Needs a new date/.test(txt(J)), 8000);
  if ($(J, '[data-tab="up"]') && !/Needs a new date/.test(txt(J))) await click(J, '[data-tab="up"]', 600);
  await until(() => /Needs a new date/.test(txt(J)), 6000);
  const rc = $(J, ".card.rest");
  ok("Julia's page: Needs a new date, first, with the rest's card", !!rc && txt(J).indexOf("Needs a new date") < Math.max(0, txt(J).indexOf("Scheduled deliveries")) + (txt(J).indexOf("Scheduled deliveries") < 0 ? 1e9 : 0), tx(rc).slice(0, 80));
  ok("…saying what's on it: 3 tables (sheet 1: table 1 · sheet 7: tables 3, 4) and 1 extra still to go; 17 of 20 went, not signed",
     /3 tables \(sheet 1: table 1 · sheet 7: tables 3, 4\) and 1 extra still to go\. 17 of 20 went; not signed \(nobody on site\)\./.test(tx(rc)), tx(rc).slice(0, 260));
  ok("…why, in Shawn's words, and that the ticket goes with it", /Why: Site not ready — Shawn K: “Reading room still being carpeted”/.test(tx(rc)) && /Going with it: the ticket/.test(tx(rc)), tx(rc).slice(0, 400));
  const kindSel = $(J, '[data-restfield="kind"]');
  kindSel.value = "customer_pickup"; kindSel.dispatchEvent(new J.Event("change")); await wait(200);
  ok("Changing how it goes to a pickup: no day to pick, Put it on Ready for pickup", !$(J, '[data-restfield="date"]') && /Put it on Ready for pickup/.test(tx($(J, "[data-restgo]"))), tx($(J, "[data-restgo]")));
  $(J, '[data-restfield="kind"]').value = "delivery"; $(J, '[data-restfield="kind"]').dispatchEvent(new J.Event("change")); await wait(200);
  ok("…back to white glove: Schedule it waits for a day", /Schedule it/.test(tx($(J, "[data-restgo]"))) && $(J, "[data-restgo]").disabled);
  const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const dIn = $(J, '[data-restfield="date"]'); dIn.value = ymd(at(1, 10)); dIn.dispatchEvent(new J.Event("input"));
  const tIn = $(J, '[data-restfield="time"]'); tIn.value = "10:00"; tIn.dispatchEvent(new J.Event("input")); await wait(100);
  await click(J, "[data-restgo]", 300);
  await until(async () => (await q("select scheduled_for from loadouts where client_id = $1", [tp.rest_cid])).rows[0].scheduled_for, 8000);
  await until(() => !$(J, ".card.rest"), 6000);
  const restSched = (await q("select kind, scheduled_for from loadouts where client_id = $1", [tp.rest_cid])).rows[0];
  ok("Schedule it gives the rest its day: it leaves Needs a new date", !!restSched.scheduled_for && restSched.kind === "delivery" && !$(J, ".card.rest") && /goes white glove/.test(txt(J)),
     `${restSched.kind} ${restSched.scheduled_for} · ${(txt(J).match(/PROJ-00418: the rest[^.]*\./) || [""])[0]}`);
  const sc = $$(J, "[data-card]").find(c => /The rest of/.test(tx(c)));
  ok("…and is on Scheduled deliveries, saying whose rest it is", !!sc && new RegExp(`The rest of ${dayWord(new Date())}'s delivery · 3 tables and 1 extra · Site not ready`).test(tx(sc)), sc ? tx(sc).slice(0, 160) : "");
  if ($(J, '[data-tab="done"]')) await click(J, '[data-tab="done"]', 600);
  const dc = $$(J, ".card").find(c => /PROJ-00418/.test(tx(c)) && /Part delivered/.test(tx(c)));
  ok("Completed: Part delivered, still to come, where the rest is, and why",
     !!dc && /Still to come ?3 tables \(sheet 1: table 1 · sheet 7: tables 3, 4\) and 1 extra · the rest goes /.test(tx(dc)) && /Why ?Site not ready — Reading room still being carpeted/.test(tx(dc)), dc ? tx(dc).slice(0, 300) : "");
  const row = (await luke.from("v_deliveries").select("*").eq("client_id", c1)).data[0];
  const pdf = stubPdf(); await J.buildSignedTicket(pdf.PDFLib, row, null, null);
  const page = pdf.texts.join(" ");
  ok("The record page: Part delivery record, today 17 of 20 tables went, still to come, why",
     /Part delivery record/.test(page) && / Today 17 of 20 tables went /.test(page) && /Still to come 3 tables \(sheet 1: table 1 · sheet 7: tables 3, 4\) and 1 extra, on a later trip/.test(page)
     && / Why Site not ready /.test(page) && !/Reading room/.test(page), page.slice(0, 400));

  // ---- the office: the job's trips (Photos › Look up a job), and its own record page, the one the OneDrive save files ----
  const O = bootPage("office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }) }).w;
  await until(() => $(O, '[data-tab="photos"]'), 8000);
  await click(O, '[data-tab="photos"]', 900);
  await until(() => $(O, "#phJob"), 6000);
  $(O, "#phJob").value = "PROJ-00418"; await click(O, "[data-phfind]", 300);
  await until(() => /Part delivered/.test(txt(O)), 8000);
  ok("The office's job page: Part delivered, how much went, what's still to come, where the rest is, and why",
     /Part delivered/.test(txt(O)) && /17 of 20 tables went · still to come: 3 tables \(sheet 1: table 1 · sheet 7: tables 3, 4\) and 1 extra · the rest goes [^·]+ · Site not ready/.test(txt(O)),
     (txt(O).match(/17 of 20[^|]{0,170}/) || [txt(O).slice(0, 120)])[0]);
  ok("…and the rest's own trip says whose rest it is", new RegExp(`The rest of ${dayWord(new Date())}[^']*'s delivery · 3 tables and 1 extra · Site not ready`).test(txt(O)),
     (txt(O).match(/The rest of[^|]{0,90}/) || [""])[0]);
  const opdf = stubPdf(); await O.buildSignedTicket(opdf.PDFLib, row, null, null);
  const opage = opdf.texts.join(" ");
  ok("The office's record page (what the OneDrive save files) says the same as Julia's",
     /Part delivery record/.test(opage) && / Today 17 of 20 tables went /.test(opage) && /Still to come 3 tables \(sheet 1: table 1 · sheet 7: tables 3, 4\) and 1 extra, on a later trip/.test(opage)
     && / Why Site not ready /.test(opage) && opage === page, opage.slice(0, 200));

  // ---- the office gave it a day: on the calendar, with only its own tables ----
  await click(w, '[data-tab="issues"]', 300); await click(w, '[data-tab="loadout"]', 1200);
  await until(() => !/Waiting for a new date/.test(txt(w)), 6000);
  const restBtn = await tripButton(w, (b) => b.dataset.loopen === tp.rest_cid);
  ok("Once it has a day it's on the calendar, saying it's the rest", !!restBtn && new RegExp(`The rest of ${dayWord(new Date())}'s · 3 tables and 1 extra`).test(tx(restBtn)) && !/Waiting for a new date/.test(txt(w)), tx(restBtn));
  await click(w, restBtn, 900); await until(() => /The customer/.test(txt(w)), 6000); await wait(400);
  const rb = tx($(w, ".restbox"));
  ok("Opened, a box at the top says whose rest it is and why", new RegExp(`The rest of ${dayWord(new Date())}'s delivery 3 tables and 1 extra still to go\\. Why: Site not ready — “Reading room still being carpeted”`).test(rb), rb);
  const site = $$(w, "[data-dlsite]").map(b => `${b.dataset.dlsite}:${b.dataset.piece}`).sort();
  ok("Only its own 3 tables to photograph at the site: sheet 1's table and sheet 7's tables 3 and 4", JSON.stringify(site) === JSON.stringify(["1:1", "7:3", "7:4"]) && /At the site — each table where it ended up — 0 of 3/.test(txt(w)), JSON.stringify(site));
  ok("…labelled as on the sheet: The table, Table 3, Table 4", /The table/.test(tx($(w, '[data-dlsite="1"]'))) && /Table 3/.test(tx($(w, '[data-dlsite="7"][data-piece="3"]'))));
  ok("The ticket went with it", !!$$(w, "[data-dlopen]").find(b => /Delivery ticket/.test(tx(b))));
  ok("Its extras: Data port, 2 went on an earlier trip", /2 went on an earlier trip/.test(txt(w)), (txt(w).match(/Data port[^.]{0,80}/) || [""])[0]);
  ok("Nothing on it has a photo yet, so its own box is ticked by itself", !!$(w, '[data-partbox="1"]') && $(w, '[data-partbox="1"]').checked && /Ticked because 3 tables have no photo/.test(tx($(w, ".partbox"))));

  // ---- a customer pickup, part-way: the rest back on Ready for pickup; damage, and the offer to report it ----
  const c3 = crypto.randomUUID();
  await call("schedule_pickup", { p_job: await job("PROJ-00501"), p_kind: "customer_pickup", p_note: null, p_loadout: null, p_client_id: c3 });
  const lo3 = (await q("select id, job_id from loadouts where client_id = $1", [c3])).rows[0];
  for (const [sh, pc] of [[1, 1], [1, 2], [2, 1]]) await photo(lo3.id, lo3.job_id, null, sh, pc);
  await toLoadout(w);
  const pkBtn = await tripButton(w, (b) => b.dataset.loopen === c3);
  await click(w, pkBtn, 900); await until(() => /The customer/.test(txt(w)), 6000); await wait(300);
  ok("A customer pickup has the box too: Not everything was picked up, 1 table with no photo", /Not everything was picked up/.test(tx($(w, ".partbox"))) && /Ticked because 1 table has no photo\./.test(tx($(w, ".partbox"))), tx($(w, ".partbox")).slice(0, 120));
  await click(w, piece(w, "2:2"));
  ok("Everything ticked as gone: it says so, and the button waits", /Everything is ticked as gone/.test(tx($(w, ".partsum"))));
  await click(w, piece(w, "2:2"));
  await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Customer refused"]'); await click(w, '[data-partreason="Damaged"]');
  ok("The button: Part picked up — not signed", /^Part picked up — not signed$/.test(tx($(w, "[data-dldone]"))) && !$(w, "[data-dldone]").disabled, tx($(w, "[data-dldone]")));
  await click(w, "[data-dldone]");
  ok("The check: the other table goes back on Ready for pickup", /The other table \(sheet 2: table 2\) goes back on Ready for pickup/.test(txt(w, ".mdl")), txt(w, ".mdl").slice(0, 200));
  await click(w, "[data-confirm]", 800);
  await until(async () => (await q("select completed_at from loadouts where client_id = $1", [c3])).rows[0].completed_at, 10000);
  const tp3 = (await q(`select r.client_id, r.kind, r.ready_at from trip_parts tp join loadouts r on r.id = tp.rest_id where tp.loadout_id = $1`, [lo3.id])).rows[0];
  ok("Its rest is a customer pickup, ready at once", !!tp3 && tp3.kind === "customer_pickup" && !!tp3.ready_at, tp3 ? tp3.kind : "none");
  await until(() => /Report the damage to the office/.test(txt(w)), 8000);
  ok("Damaged: the finished pickup offers to report it", !!$(w, "[data-reportjob]"));
  await click(w, "[data-reportjob]", 300);
  ok("…which opens the report, for this job", !!$(w, ".mdl") && /PROJ-00501/.test(txt(w, ".mdl")), txt(w, ".mdl").slice(0, 120));
  if ($(w, '.mdl [data-close]')) await click(w, '.mdl [data-close]', 200);
  await toLoadout(w);
  await until(() => $$(w, "[data-loopen]").some(b => b.dataset.loopen === tp3.client_id), 6000);
  const rp = $$(w, "[data-loopen]").find(b => b.dataset.loopen === tp3.client_id);
  ok("On Ready for pickup: the rest of today's pickup, 1 table", !!rp && new RegExp(`The rest of ${dayWord(new Date())}'s · 1 table`).test(tx(rp)), tx(rp));
  const pd = $$(w, ".li").find(e => /PROJ-00501/.test(tx(e)) && /Part picked up/.test(tx(e)));
  ok("Done in the last two weeks: Part picked up", !!pd, pd ? tx(pd).slice(0, 100) : "");

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("CRASH", e.stack); process.exit(1); });
