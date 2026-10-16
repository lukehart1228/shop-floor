// 16 Oct: the whole work order beside the ticket on Delivery's phone. Every trip (white glove, dock to dock,
// BOL pickup, customer pickup) shows "Work order · n sheets" beside the ticket; it opens every sheet of the
// current work order in one read-only viewer (number buttons, previous / next, swipe), saved for no signal.
// The per-sheet Work order buttons on the table cards are unchanged. Run on a freshly seeded database:
//   bash /home/claude/sf/base/fresh.sh && TZ=America/Indiana/Indianapolis node test_wo_beside_ticket.js
// PAGE=/home/claude/sf/repo/index.html runs it on the live page, where it must fail (no such button).
const fs = require("fs");
const crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
const HTML = fs.readFileSync(PAGE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(HTML, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  let n = 0; w.Blob = Blob; w.URL.createObjectURL = () => "blob:t" + (n++); w.URL.revokeObjectURL = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.print = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.open = () => null;
  Object.defineProperty(w, "sfPdfjs", { get() { return { getDocument: () => ({ promise: Promise.reject(new Error("no viewer in this test")) }) }; } });
  w.eval([...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w) => ($(w, "#app") || {}).textContent.replace(/\s+/g, " ") || "";
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const sub = (w) => ($(w, "#app p.sub") || {}).textContent || "";
const img = (w) => ($(w, "#lopage img") || {}).alt || "";
function swipe(w, dx, fingers = 1) {
  const el = $(w, "#lopage"); const mk = (type, x, list) => { const e = new w.Event(type, { bubbles: true });
    Object.defineProperty(e, "touches", { value: list }); Object.defineProperty(e, "changedTouches", { value: [{ clientX: x, clientY: 300 }] }); el.dispatchEvent(e); };
  const pts = Array.from({ length: fingers }, () => ({ clientX: 200, clientY: 300 }));
  mk("touchstart", 200, pts); mk("touchmove", 200 + dx / 2, pts); mk("touchend", 200 + dx, []);
}
async function openTrip(w, pid) {
  if ($(w, '[data-loback]')) await click(w, '[data-loback]', 500);
  if ($(w, '[data-tab="loadout"]')) await click(w, '[data-tab="loadout"]', 400);
  await until(() => $$(w, "[data-loopen]").some(b => b.textContent.includes(pid)));
  await click(w, $$(w, "[data-loopen]").find(b => b.textContent.includes(pid)), 500);
  await until(() => /At the|Each table|Every table|each table/.test(txt(w)) && !/Loading the sheets/.test(txt(w)), 5000);
  await wait(200);
}

(async () => {
  const luke = makeClient(users.luke);
  const job = (pid) => admin.query("select id from jobs where project_id = $1", [pid]).then(r => r.rows[0].id);
  const tomorrow = new Date(Date.now() + 86400000); tomorrow.setHours(9, 0, 0, 0);
  const call = async (fn, args) => { const r = await luke.rpc(fn, args); if (r.error) throw new Error(fn + ": " + r.error.message); };
  // a white glove delivery with a ticket (PROJ-00418, 9 sheets); a dock to dock (PROJ-00501, 2 sheets);
  // a BOL pickup with no ticket (PROJ-00099, 3 sheets); a customer pickup on a job with no work order (PROJ-00362)
  const dcid = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: tomorrow.toISOString(), p_note: "Back dock", p_loadout: null, p_client_id: dcid });
  const tid = crypto.randomUUID();
  const up = await luke.storage.from("deliveries").upload(`PROJ-00418/${dcid}/${tid}.jpg`, new Blob([Buffer.from("jpg")], { type: "image/jpeg" }), { contentType: "image/jpeg", upsert: false });
  if (up.error) throw new Error(up.error.message);
  await call("add_delivery_doc", { p_client_id: tid, p_loadout: dcid, p_kind: "ticket", p_file_name: "Ticket.jpg" });
  await call("schedule_delivery", { p_job: await job("PROJ-00501"), p_when: tomorrow.toISOString(), p_note: null, p_loadout: null, p_client_id: crypto.randomUUID(), p_kind: "dock" });
  await call("schedule_pickup", { p_job: await job("PROJ-00099"), p_kind: "shipping", p_note: null, p_loadout: null, p_client_id: crypto.randomUUID() });
  await call("schedule_pickup", { p_job: await job("PROJ-00362"), p_kind: "customer_pickup", p_note: null, p_loadout: null, p_client_id: crypto.randomUUID() });

  let { w } = boot(users.shawn);
  await until(() => $(w, "#app") && txt(w).length > 50, 8000); await wait(500);

  console.log("--- White glove, PROJ-00418 (a ticket, 9 sheets)");
  await openTrip(w, "PROJ-00418");
  let b = $(w, "[data-lowoall]");
  ok("A Work order button sits in the ticket box", !!b && !!b.closest(".dlinfo"), b ? b.textContent : "none");
  ok("…labelled with the number of sheets", b && b.textContent.trim() === "Work order · 9 sheets");
  const box = $$(w, ".dlinfo .loslots button").map(x => x.textContent.trim());
  ok("…right after the Delivery ticket", box[0] === "Delivery ticket" && box[1] === "Work order · 9 sheets", box.join(" | "));
  ok("The per-sheet Work order buttons on the table cards are still there", $$(w, ".locard [data-lowo]").length === 9);
  await click(w, b, 300);
  await until(() => !!$(w, "#lopage img"));
  ok("It opens the viewer on sheet 1: ← Delivery, Work order, PROJ, Sheet 1 of 9",
     ($(w, "[data-lowoback]") || {}).textContent === "← Delivery" && $(w, "#app h1").textContent === "Work order" && /^PROJ-00418 · Sheet 1 of 9/.test(sub(w)), sub(w));
  ok("The page shown is sheet 1's", /sheet 1$/.test(img(w)), img(w));
  ok("A button per sheet, 1 to 9, sheet 1 marked", $$(w, ".wopick button").map(x => x.textContent).join(",") === "1,2,3,4,5,6,7,8,9"
     && $(w, '.wopick [aria-pressed="true"]').textContent === "1");
  ok("No photo buttons on this screen (read only)", !$(w, "[data-dlsite], [data-loshoot], [data-dltruck], #sigpad, .loslot"));
  ok("It says Pinch to zoom and how to swipe", /Pinch to zoom\. Swipe left or right/.test(txt(w)));
  ok("On sheet 1 there's no previous button, and Next says Sheet 2", $$(w, ".wonav button")[0].style.visibility === "hidden" && /Sheet 2 ›/.test($$(w, ".wonav button")[1].textContent));
  await click(w, $$(w, ".wopick button").find(x => x.textContent === "5"), 200);
  await until(() => /sheet 5$/.test(img(w)));
  ok("Tapping 5 shows sheet 5", /Sheet 5 of 9/.test(sub(w)) && /sheet 5$/.test(img(w)), sub(w));
  await click(w, $$(w, ".wonav button")[1], 200); await until(() => /sheet 6$/.test(img(w)));
  ok("Next goes to sheet 6", /Sheet 6 of 9/.test(sub(w)) && /sheet 6$/.test(img(w)));
  await click(w, $$(w, ".wonav button")[0], 200); await until(() => /sheet 5$/.test(img(w)));
  ok("Previous goes back to sheet 5", /Sheet 5 of 9/.test(sub(w)));
  swipe(w, -120); await wait(200); await until(() => /sheet 6$/.test(img(w)));
  ok("A swipe to the left goes to the next sheet", /Sheet 6 of 9/.test(sub(w)), sub(w));
  swipe(w, 120); await wait(200); await until(() => /sheet 5$/.test(img(w)));
  ok("A swipe to the right goes back", /Sheet 5 of 9/.test(sub(w)), sub(w));
  swipe(w, -30); await wait(200);
  ok("A small slide doesn't change sheet", /Sheet 5 of 9/.test(sub(w)));
  swipe(w, -120, 2); await wait(200);
  ok("Two fingers (a pinch) don't change sheet", /Sheet 5 of 9/.test(sub(w)));
  w.visualViewport = { scale: 2 }; swipe(w, -120); await wait(200);
  ok("While zoomed in, a swipe moves the page, not the sheet", /Sheet 5 of 9/.test(sub(w)));
  w.visualViewport = { scale: 1 };
  for (let i = 0; i < 4; i++) { await click(w, $$(w, ".wonav button")[1], 150); }
  await until(() => /sheet 9$/.test(img(w)));
  ok("On the last sheet Next is hidden, and a swipe left does nothing", $$(w, ".wonav button")[1].style.visibility === "hidden" && (swipe(w, -120), true));
  await wait(200); ok("…still on sheet 9", /Sheet 9 of 9/.test(sub(w)));
  await click(w, "[data-lowoback]", 300);
  ok("← Delivery goes back to the delivery", !!$(w, "[data-lowoall]") && /At the site/.test(txt(w)));
  await click(w, $$(w, ".locard [data-lowo]")[2], 300); await until(() => !!$(w, "#lopage img"));
  ok("A table card's own Work order button still opens that sheet with its photo buttons, as before",
     $(w, "#app h1").textContent === "Sheet 3" && !!$(w, "[data-dlsite]") && !$(w, ".wopick"), $(w, "#app h1").textContent);
  await click(w, "[data-lowoback]", 300);
  await click(w, "[data-lowoall]", 300); await until(() => !!$(w, "#lopage img"));
  ok("…and the Work order button after it still opens the whole work order on sheet 1", /Sheet 1 of 9/.test(sub(w)) && !!$(w, ".wopick"));
  console.log("--- With no signal");
  setOffline(true);
  await click(w, $$(w, ".wopick button").find(x => x.textContent === "8"), 300);
  await until(() => /sheet 8$/.test(img(w)));
  ok("With no signal, a saved page still shows", /sheet 8$/.test(img(w)), img(w) || txt(w).slice(-140));
  setOffline(false);
  await click(w, "[data-lowoback]", 300);

  console.log("--- Dock to dock, PROJ-00501 (no ticket, 2 sheets)");
  await openTrip(w, "PROJ-00501");
  b = $(w, "[data-lowoall]");
  ok("The Work order button shows on a dock to dock trip", b && b.textContent.trim() === "Work order · 2 sheets", b ? b.textContent : txt(w).slice(0, 200));
  ok("…with 'No delivery ticket attached.' beside it", /No delivery ticket attached\./.test($(w, ".dlinfo").textContent));
  await click(w, b, 300); await until(() => !!$(w, "#lopage img"));
  ok("It opens on Sheet 1 of 2, back says ← Delivery", /Sheet 1 of 2/.test(sub(w)) && $(w, "[data-lowoback]").textContent === "← Delivery");
  await click(w, "[data-lowoback]", 300);

  console.log("--- BOL pickup, PROJ-00099 (no ticket, no note, 3 sheets)");
  await openTrip(w, "PROJ-00099");
  b = $(w, "[data-lowoall]");
  ok("The Work order button shows on a BOL pickup that has no ticket or note", b && b.textContent.trim() === "Work order · 3 sheets", b ? b.textContent : txt(w).slice(0, 200));
  await click(w, b, 300); await until(() => !!$(w, "#lopage img"));
  ok("…back says ← BOL pickup", $(w, "[data-lowoback]").textContent === "← BOL pickup" && /Sheet 1 of 3/.test(sub(w)), $(w, "[data-lowoback]").textContent);
  await click(w, "[data-lowoback]", 300);

  console.log("--- Customer pickup, PROJ-00362 (no work order uploaded)");
  await openTrip(w, "PROJ-00362");
  ok("It says 'No work order uploaded.' where the button would be", !$(w, "[data-lowoall]") && /No work order uploaded\./.test(($(w, ".dlinfo") || {}).textContent || ""),
     ($(w, ".dlinfo") || {}).textContent);

  console.log("--- A change order on PROJ-00099 drops sheet 2");
  await admin.query(`do $$ declare v_job uuid; v_old uuid; v_new uuid; begin
    select id into v_job from jobs where project_id = 'PROJ-00099';
    select id into v_old from work_orders where job_id = v_job and is_current;
    update work_orders set is_current = false, superseded_at = now() where id = v_old;
    insert into work_orders (job_id, version, is_current) values (v_job, (select max(version) + 1 from work_orders where job_id = v_job), true) returning id into v_new;
    create temp table t_s on commit drop as select * from sheets where work_order_id = v_old and sheet_number <> 2;
    update t_s set id = gen_random_uuid(), work_order_id = v_new;
    insert into sheets select * from t_s; end $$;`);
  await click(w, "[data-loback]", 500);
  await openTrip(w, "PROJ-00099");
  b = $(w, "[data-lowoall]");
  ok("After the change order the button counts the current work order's sheets", b && b.textContent.trim() === "Work order · 2 sheets", b ? b.textContent : "none");
  await click(w, b, 300); await until(() => !!$(w, "#lopage img"));
  ok("Sheets 1 and 3: the heading says Sheet 1 · 1 of 2", /Sheet 1 · 1 of 2/.test(sub(w)) && $$(w, ".wopick button").map(x => x.textContent).join(",") === "1,3", sub(w));
  swipe(w, -120); await wait(200); await until(() => /sheet 3$/.test(img(w)));
  ok("…and the next sheet is 3 (Sheet 3 · 2 of 2)", /Sheet 3 · 2 of 2/.test(sub(w)), sub(w));

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
