// 22 Oct: Delivery's phone. The Load-out tab as a calendar (Week and Month, the switch remembered); the trip bar on every
// Delivery tab while a trip is in progress (none otherwise); today's and tomorrow's trips saved for no signal in the
// background on Wi-Fi only (and a phone that can't tell Wi-Fi from mobile data saying so); what changed on a trip since it
// was last opened; trips called off after the phone saw them, until OK, got it; each sheet's drawing on a trip's table cards.
// Run on a freshly seeded database:
//   bash /home/claude/sf/base/fresh.sh && TZ=America/Indiana/Indianapolis node test_delivery_calendar.js
// PAGE=/home/claude/sf/repo/index.html runs it on the live page, where it must fail (no calendar, no bar).
const fs = require("fs");
const crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
const HTML = fs.readFileSync(PAGE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const SCRIPT = [...HTML.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }

// the phone's own copies (the Cache API), in memory: each kept file stored once, a fresh response on every match
function cacheStub() {
  const stores = new Map();
  const api = { open: async (name) => {
    if (!stores.has(name)) stores.set(name, new Map());
    const m = stores.get(name);
    return { match: async (req) => { const e = m.get(typeof req === "string" ? req : req.url); return e ? new Response(e.buf, { headers: { "Content-Type": e.type } }) : undefined; },
             put: async (req, res) => { m.set(typeof req === "string" ? req : req.url, { buf: Buffer.from(await res.arrayBuffer()), type: res.headers.get("Content-Type") || "" }); } };
  } };
  return { api, keys: () => [...stores.values()].flatMap(m => [...m.keys()]).map(decodeURIComponent) };
}
const net = { kind: "wifi" };
/** Shawn's phone (or anyone's). `store`: localStorage carried over from an earlier boot (a reload); `cache`: its saved copies. */
function boot(user, opt = {}) {
  const client = makeClient(user), downloads = [];
  const from = client.storage.from;
  client.storage.from = (b) => { const o = from(b), dl = o.download.bind(o); o.download = async (p) => { downloads.push(b + "/" + p); return dl(p); }; return o; };
  const dom = new JSDOM(HTML, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(opt.store || {})) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  let n = 0; w.Blob = Blob; w.URL.createObjectURL = () => "blob:t" + (n++); w.URL.revokeObjectURL = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.print = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.open = () => null;
  w.Request = Request; w.Response = Response;
  if (opt.cache) w.caches = opt.cache.api;
  w.sfNet = () => net.kind;                          // what the phone says its connection is (the page asks window.sfNet first)
  w.eval(SCRIPT);
  return { w, client, downloads };
}
const kept = (w) => { const o = {}; for (let i = 0; i < w.localStorage.length; i++) { const k = w.localStorage.key(i); o[k] = w.localStorage.getItem(k); } return o; };
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
const tx = (el) => ((el || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const at = (days, h, m = 0) => { const d = new Date(); d.setDate(d.getDate() + days); d.setHours(h, m, 0, 0); return d; };
const TODAY = iso(new Date()), TOMORROW = iso(at(1, 12));
const when = (d) => `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]} ${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]} ${d.getDate()}`;
/** The week holding `day`, on screen (Today, then forward or back). */
async function showDay(w, day) {
  if (typeof w.weekStart !== "function" || !$(w, "[data-caltoday]")) return null;
  if ($(w, '[data-calview="week"][aria-pressed="false"]')) await click(w, '[data-calview="week"]', 200);
  await click(w, "[data-caltoday]", 150);
  let k = Math.round((new Date(w.weekStart(day) + "T12:00:00") - new Date(w.weekStart(TODAY) + "T12:00:00")) / (7 * 86400000));
  while (k > 0) { await click(w, "[data-calnext]", 120); k--; }
  while (k < 0) { await click(w, "[data-calprev]", 120); k++; }
  return $(w, `.wkday[data-day="${day}"]`);
}
const tripIn = (el, pid) => el ? [...el.querySelectorAll("[data-loopen]")].find(b => b.textContent.includes(pid)) : null;
async function toLoadout(w) { if ($(w, "[data-loback]")) await click(w, "[data-loback]", 500); if ($(w, "[data-taskback]")) await click(w, "[data-taskback]", 400); await click(w, '[data-tab="loadout"]', 700); }

(async () => {
  const luke = makeClient(users.luke);
  const job = (pid) => admin.query("select id from jobs where project_id = $1", [pid]).then(r => r.rows[0].id);
  const call = async (fn, args) => { const r = await luke.rpc(fn, args); if (r.error) throw new Error(fn + ": " + r.error.message); return r.data; };
  const upload = async (pid, cid, name, kind) => {
    const fid = crypto.randomUUID(), path = `${pid}/${cid}/${fid}.jpg`;
    const up = await luke.storage.from("deliveries").upload(path, new Blob([Buffer.from("jpg " + name)], { type: "image/jpeg" }), { contentType: "image/jpeg", upsert: false });
    if (up.error) throw new Error(up.error.message);
    await call("add_delivery_doc", { p_client_id: fid, p_loadout: cid, p_kind: kind, p_file_name: name });
    return path;
  };
  // today 9:00 white glove with a ticket (PROJ-00418, 9 sheets); tomorrow 3 pm dock to dock with a site file (PROJ-00501, 2 sheets);
  // nine days out (PROJ-00099); one still open from two days ago (PROJ-00325, no work order); a task today 11:30; one done today 7:00
  const d1 = crypto.randomUUID(), d2 = crypto.randomUUID(), d3 = crypto.randomUUID(), d4 = crypto.randomUUID(), d0 = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: at(0, 9).toISOString(), p_note: "Back dock", p_loadout: null, p_client_id: d1 });
  const ticket1 = await upload("PROJ-00418", d1, "Ticket.jpg", "ticket");
  await call("schedule_delivery", { p_job: await job("PROJ-00501"), p_when: at(1, 15).toISOString(), p_note: null, p_loadout: null, p_client_id: d2, p_kind: "dock" });
  const site2 = await upload("PROJ-00501", d2, "Dock map.jpg", "site_file");
  await call("schedule_delivery", { p_job: await job("PROJ-00099"), p_when: at(9, 10).toISOString(), p_note: null, p_loadout: null, p_client_id: d3 });
  await admin.query("insert into loadouts (job_id, kind, client_id, scheduled_for, scheduled_by_name) values ($1, 'delivery', $2, $3, 'Julia R')",   // not schedulable now (closeout)
                    [await job("PROJ-00325"), d4, at(-2, 13).toISOString()]);
  await call("schedule_delivery", { p_job: await job("PROJ-00362"), p_when: at(0, 6).toISOString(), p_note: null, p_loadout: null, p_client_id: d0 });
  await admin.query("update loadouts set finished_at = $2, completed_at = $3, completed_by_name = 'Shawn K', signed_name = 'Pat Lee', signed_at = $3 where client_id = $1",
                    [d0, at(0, 6, 30).toISOString(), at(0, 7).toISOString()]);
  await call("schedule_task", { p_client_id: crypto.randomUUID(), p_when: at(0, 11, 30).toISOString(), p_what: "Pick up a damaged chair", p_where: "back entrance", p_job: null, p_for: "Smith dining set", p_task: null });

  // ======== on Wi-Fi ========
  net.kind = "wifi";
  const cacheA = cacheStub();
  let { w, downloads } = boot(users.shawn, { cache: cacheA });
  await until(() => $$(w, "#app [data-loopen]").length >= 2, 8000); await wait(400);
  console.log("--- The calendar: Week");
  ok("It opens on Week: the switch says Week", tx($(w, '.calsw [aria-pressed="true"]')) === "Week", tx($(w, ".calsw")));
  ok("…headed This week, with its dates", /^This week · [A-Z][a-z]{2} \d{1,2} – /.test(tx($(w, ".calnav b"))), tx($(w, ".calnav b")));
  ok("…seven days, Monday first", $$(w, ".wkday").length === 7 && tx($(w, ".wkday .wkdate small")) === "MON", $$(w, ".wkday .wkdate small").map(tx).join(" "));
  let today = $(w, `.wkday[data-day="${TODAY}"]`);
  ok("Today's row is marked today (its date circled)", !!today && today.classList.contains("today") && $$(w, ".wkday.today").length === 1);
  let b = tripIn(today, "PROJ-00418");
  ok("…with today's trip: 9:00 am, Delivery, PROJ-00418 and its job", !!b && /9:00 am/.test(tx(b)) && /Delivery/.test(tx(b)) && /Enid's Table/.test(tx(b)), tx(b).slice(0, 90));
  const task = today && today.querySelector("[data-taskopen]");
  ok("…and the task at 11:30 am, what to do first, then what it's for and where", !!task && /11:30 am/.test(tx(task)) && /Pick up a damaged chair/.test(tx(task)) && /Smith dining set · back entrance/.test(tx(task)), tx(task));
  const carried = tripIn(today, "PROJ-00325");
  ok("A trip still open from two days ago shows on today, with its own date", !!carried && tx(carried).includes(when(at(-2, 13))), tx(carried).slice(0, 80));
  const own = $(w, `.wkday[data-day="${iso(at(-2, 12))}"]`);
  ok("…and not on its own day", !own || !tripIn(own, "PROJ-00325"), own ? "its own day is this week" : "its own day is last week");
  const done = today && [...today.querySelectorAll(".calitem.done")].find(x => /PROJ-00362/.test(tx(x)));
  ok("A delivery done today is on today in turquoise: ✓ Delivered 7:00 am", !!done && /✓ Delivered 7:00 am/.test(tx(done)) && !done.matches("[data-loopen]"), tx(done));
  const order = today ? [...today.querySelectorAll(".calitem")].map(x => (tx(x).match(/PROJ-\d+|damaged chair/) || ["?"])[0]) : [];
  ok("Today's row: the carried-over trip first, then the rest in time order", order.join(",") === "PROJ-00325,PROJ-00362,PROJ-00418,damaged chair", order.join(","));
  let row = await showDay(w, TOMORROW);
  b = tripIn(row, "PROJ-00501");
  ok("Tomorrow's dock to dock is on tomorrow: 3:00 pm, Dock to dock", !!b && /3:00 pm/.test(tx(b)) && /Dock to dock/.test(tx(b)), tx(b).slice(0, 80));

  console.log("--- Saved for no signal, on Wi-Fi");
  await showDay(w, TODAY);
  await until(() => /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418"))), 8000);
  ok("Today's trip saves itself: ✓ Ready for no signal", /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418"))), tx(tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418")).slice(0, 140));
  row = await showDay(w, TOMORROW);
  await until(() => /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TOMORROW}"]`), "PROJ-00501"))), 8000);
  ok("…and tomorrow's", /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TOMORROW}"]`), "PROJ-00501"))));
  const k = cacheA.keys();
  const pages418 = (await admin.query("select s.png_path from sheets s join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00418'")).rows.map(r => r.png_path);
  ok("…the work order pages are in the phone's copies (all 9 of today's)", pages418.every(p => k.some(x => x.endsWith("/__sheet-pages__/" + p))), `${pages418.filter(p => k.some(x => x.endsWith("/__sheet-pages__/" + p))).length} of ${pages418.length}`);
  ok("…the ticket and the site file too", k.some(x => x.endsWith("/__delivery-files__/" + ticket1)) && k.some(x => x.endsWith("/__delivery-files__/" + site2)));
  await click(w, '[data-tab="issues"]', 300); await click(w, '[data-tab="loadout"]', 1200);      // the lists again, and the saving looks again
  await click(w, '[data-tab="issues"]', 300); await click(w, '[data-tab="loadout"]', 1200);
  const twice = downloads.filter((x, i) => downloads.indexOf(x) !== i);
  ok("…each fetched once, however often the phone looks again", downloads.length > 0 && !twice.length, twice.slice(0, 3).join(", "));
  const day9 = iso(at(9, 12));
  row = await showDay(w, day9);
  b = tripIn(row, "PROJ-00099");
  ok("A trip nine days out says Saves itself the day before", !!b && /Saves itself the day before/.test(tx(b)), tx(b).slice(0, 120));
  const pages099 = (await admin.query("select s.png_path from sheets s join work_orders w on w.id = s.work_order_id and w.is_current join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00099'")).rows.map(r => r.png_path);
  ok("…and nothing of it is fetched yet", !downloads.some(x => pages099.some(p => x.endsWith(p))));
  await click(w, "[data-caltoday]", 200);
  ok("Today comes back to this week", /^This week/.test(tx($(w, ".calnav b"))) && !!$(w, `.wkday[data-day="${TODAY}"]`));

  console.log("--- A trip from the calendar");
  await click(w, tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418"), 600);
  await until(() => /2 · At the site/.test(txt(w)) && !/Loading the sheets/.test(txt(w)), 5000);
  ok("Tapping it opens the trip for load-out", tx($(w, "#app h1")) === "PROJ-00418" && /1 · At the dock/.test(txt(w)) && /2 · At the site/.test(txt(w)));
  const cards = $$(w, ".locard .tbhead");
  ok("Each table card has its sheet's drawing beside the number, size and count", $$(w, ".locard .tbhead [data-snip]").length === 9 && cards.every(h => h.querySelector(".lotop .size")), `${$$(w, ".locard .tbhead [data-snip]").length} drawings, ${cards.length} cards`);
  ok("…while the trip's own banner says Ready for no signal, as before", !!$(w, ".lopages.ready"));
  ok("No trip bar while nothing is in progress", !$(w, ".tripbar"));
  await toLoadout(w);

  console.log("--- The calendar: Month");
  await click(w, '[data-calview="month"]', 300);
  ok("Month: the switch says Month and shows the month's name", tx($(w, '.calsw [aria-pressed="true"]')) === "Month" && tx($(w, ".calnav b")) === w.monthName(TODAY), tx($(w, ".calnav b")));
  const cells = $$(w, ".mgrid .mday");
  ok("…a grid of whole weeks, Monday first", cells.length >= 28 && cells.length % 7 === 0 && tx($(w, ".mdow span")) === "M", String(cells.length));
  const tc = $(w, `.mday[data-calday="${TODAY}"]`);
  ok("…today's square marked today and picked", !!tc && tc.classList.contains("today") && tc.getAttribute("aria-pressed") === "true");
  ok("…with a dot per trip, a ring for the task and ✓ for the one done", tc && tc.querySelectorAll(".mmarks i:not(.task)").length === 2 && tc.querySelectorAll(".mmarks i.task").length === 1 && /✓/.test(tx(tc.querySelector(".mmarks"))), tc ? tc.querySelector(".mmarks").innerHTML : "");
  ok("…and its words for a screen reader", tc && /2 trips, 1 task, 1 done/.test(tc.getAttribute("aria-label")), tc ? tc.getAttribute("aria-label") : "");
  ok("Under the grid, today's list", /· today$/.test(tx($(w, "#app h2.sec"))) && !!tripIn($(w, ".mlist"), "PROJ-00418") && !!$(w, ".mlist [data-taskopen]"));
  await click(w, `.mday[data-calday="${TOMORROW}"]`, 300);
  ok("Tapping tomorrow's square lists tomorrow's dock to dock", !!tripIn($(w, ".mlist"), "PROJ-00501") && $(w, `.mday[data-calday="${TOMORROW}"]`).getAttribute("aria-pressed") === "true");
  await click(w, tripIn($(w, ".mlist"), "PROJ-00501"), 600);
  await until(() => /1 · At our dock/.test(txt(w)) && !/Loading the sheets/.test(txt(w)), 5000);
  ok("…which opens from there; dock to dock's table cards have the drawings too", tx($(w, "#app h1")) === "PROJ-00501" && $$(w, ".locard .tbhead [data-snip]").length === 2, String($$(w, ".locard .tbhead [data-snip]").length));
  await toLoadout(w);
  let store = kept(w); w.close();
  ({ w, downloads } = boot(users.shawn, { cache: cacheA, store }));
  await until(() => !!$(w, ".calsw"), 8000); await wait(300);
  ok("A reload remembers Month", tx($(w, '.calsw [aria-pressed="true"]')) === "Month");
  await click(w, '[data-calview="week"]', 300);
  store = kept(w); w.close();
  ({ w, downloads } = boot(users.shawn, { cache: cacheA, store }));
  await until(() => !!$(w, ".calsw"), 8000); await wait(300);
  ok("…and Week, once picked", tx($(w, '.calsw [aria-pressed="true"]')) === "Week" && $$(w, ".wkday").length === 7);
  w.close();

  console.log("--- On mobile data");
  net.kind = "cellular";
  const cacheB = cacheStub();
  ({ w, downloads } = boot(users.shawn, { cache: cacheB }));
  await until(() => $$(w, "#app [data-loopen]").length >= 2, 8000); await wait(1500);
  ok("Nothing downloads in the background", downloads.length === 0, downloads.slice(0, 3).join(", "));
  b = tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418");
  ok("…today's trip says Not saved yet · 0 of 10 on this phone · it saves itself on Wi-Fi", /Not saved yet · 0 of 10 on this phone · it saves itself on Wi-Fi/.test(tx(b)), tx(b).slice(0, 160));
  ok("…and the phone doesn't say it can't tell", !$(w, ".netnote"));
  await click(w, b, 600);
  await until(() => /2 · At the site/.test(txt(w)), 5000); await wait(800);
  ok("Opening a trip on mobile data still loads it, as today", pages418.every(p => downloads.some(x => x.endsWith(p))) && downloads.some(x => x.endsWith(ticket1)), `${downloads.length} downloads`);
  await toLoadout(w);
  net.kind = "wifi"; w.dispatchEvent(new w.Event("online"));
  await showDay(w, TOMORROW);
  await until(() => /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TOMORROW}"]`), "PROJ-00501"))), 8000);
  ok("Back on Wi-Fi, the rest saves itself", /✓ Ready for no signal/.test(tx(tripIn($(w, `.wkday[data-day="${TOMORROW}"]`), "PROJ-00501"))) && downloads.some(x => x.endsWith(site2)));
  w.close();

  console.log("--- A phone that can't tell Wi-Fi from mobile data");
  net.kind = "unknown";
  ({ w, downloads } = boot(users.shawn, { cache: cacheStub() }));
  await until(() => $$(w, "#app [data-loopen]").length >= 2, 8000); await wait(1500);
  ok("It says so above the calendar", /can't tell Wi-Fi from mobile data, so it doesn't save trips by itself/.test(tx($(w, ".netnote"))), tx($(w, ".netnote")));
  ok("…saves nothing by itself", downloads.length === 0, downloads.slice(0, 3).join(", "));
  ok("…and its trips say open it on Wi-Fi to save it", /open it on Wi-Fi to save it/.test(tx(tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418"))));
  row = await showDay(w, day9);
  ok("…a later trip says nothing about saving itself", !!tripIn(row, "PROJ-00099") && !/Saves itself/.test(tx(tripIn(row, "PROJ-00099"))));
  w.close();
  net.kind = "wifi";

  console.log("--- What changed (the phone has seen today's and tomorrow's trips)");
  ({ w, downloads } = boot(users.shawn, { cache: cacheA, store }));
  await until(() => $$(w, "#app [data-loopen]").length >= 2, 8000); await wait(500);
  ok("Before any change, no tags", !$(w, ".calitem .ctag"));
  const was2 = at(1, 15);
  await call("schedule_delivery", { p_job: await job("PROJ-00501"), p_when: at(1, 16, 30).toISOString(), p_note: null, p_loadout: d2, p_client_id: null });
  const site2b = await upload("PROJ-00501", d2, "Gate code.jpg", "site_file");
  const ticket1b = await upload("PROJ-00418", d1, "Ticket v2.jpg", "ticket");
  await call("schedule_delivery", { p_job: await job("PROJ-00418"), p_when: at(0, 9).toISOString(), p_note: "North door", p_loadout: d1, p_client_id: null });
  const d5 = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00502"), p_when: at(0, 14).toISOString(), p_note: "New one", p_loadout: null, p_client_id: d5 });
  await toLoadout(w); await wait(500);
  row = await showDay(w, TOMORROW);
  b = tripIn(row, "PROJ-00501");
  ok("A moved trip says MOVED, from its old time, and sits at its new one", /MOVED\s*from /.test(tx(b)) && tx(b).includes("from " + when(was2) + ", 3:00 pm") && /4:30 pm/.test(tx(b)), tx(b).slice(0, 200));
  ok("…a new site file says NEW SITE FILE, with who added it and when", /NEW SITE FILE\s*Luke H, /.test(tx(b)));
  row = await showDay(w, TODAY);
  b = tripIn(row, "PROJ-00418");
  ok("A replaced ticket says NEW TICKET, with who and when", /NEW TICKET\s*Luke H, /.test(tx(b)), tx(b).slice(0, 200));
  ok("…a changed note says NOTE CHANGED", /NOTE CHANGED/.test(tx(b)));
  ok("A trip first seen after it changed has no tags", !!tripIn(row, "PROJ-00502") && !tripIn(row, "PROJ-00502").querySelector(".ctag"));
  await click(w, b, 600);
  await until(() => /2 · At the site/.test(txt(w)), 5000); await wait(300);
  const box = $(w, ".changed");
  ok("Opening it shows what changed at the top", !!box && /Changed since you last opened it/.test(tx(box)) && /NEW TICKET/.test(tx(box)) && /NOTE CHANGED/.test(tx(box)), tx(box));
  ok("…and the new note in the note box", /North door/.test(tx($(w, ".dlinfo"))));
  await toLoadout(w); await wait(300);
  ok("Back on the calendar its tags are gone", !tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418").querySelector(".ctag"));
  row = await showDay(w, TOMORROW);
  ok("…while the other trip keeps its own until it's opened", /MOVED/.test(tx(tripIn(row, "PROJ-00501"))));
  await click(w, tripIn(row, "PROJ-00501"), 600); await until(() => /1 · At our dock/.test(txt(w)), 5000); await wait(200);
  await toLoadout(w);
  ok("…and once opened, it has none either", !tripIn(await showDay(w, TOMORROW), "PROJ-00501").querySelector(".ctag"));
  ok("A change order says NEW WORK ORDER (what changed, worked out from the sheets)",
     w.tripChangeList({ scheduled_for: "2026-10-23T14:00:00Z", files: [] }, { when: "2026-10-23T14:00:00Z", note: "", ticket: null, files: [], pages: "1:3:a.png" }, [{ sheet_number: 1, qty: 3, png_path: "b.png" }]).some(c => c.tag === "NEW WORK ORDER")
     && !w.tripChangeList({ scheduled_for: "2026-10-23T14:00:00Z", files: [] }, { when: "2026-10-23T14:00:00Z", note: "", ticket: null, files: [], pages: "1:3:a.png" }, [{ sheet_number: 1, qty: 3, png_path: "a.png" }]).length);

  console.log("--- Called off");
  await call("void_loadout", { p_loadout: d2, p_reason: "Delivery cancelled" });
  const d6 = crypto.randomUUID();
  await call("schedule_delivery", { p_job: await job("PROJ-00099"), p_when: at(1, 8).toISOString(), p_note: null, p_loadout: null, p_client_id: d6 });
  await call("void_loadout", { p_loadout: d6, p_reason: "Delivery cancelled" });
  await toLoadout(w); await wait(400);
  row = await showDay(w, TOMORROW);
  const off = row && [...row.querySelectorAll(".calitem.off")].find(x => /PROJ-00501/.test(tx(x)));
  ok("A trip called off after the phone saw it stays on its day, dashed: CALLED OFF, was 4:30 pm, who and when", !!off && /CALLED OFF\s*was 4:30 pm/.test(tx(off)) && /Luke H, /.test(tx(off)) && !tripIn(row, "PROJ-00501"), tx(off));
  ok("…with OK, got it", !!(off && off.querySelector("[data-offok]")));
  ok("A trip called off before the phone ever saw it doesn't show", !(row && [...row.querySelectorAll(".calitem.off")].some(x => /PROJ-00099/.test(tx(x)))));
  await click(w, off.querySelector("[data-offok]"), 300);
  ok("OK, got it takes it off", !(($(w, `.wkday[data-day="${TOMORROW}"]`) || { querySelectorAll: () => [] }).querySelectorAll(".calitem.off").length));
  store = kept(w); w.close();
  ({ w, downloads } = boot(users.shawn, { cache: cacheA, store }));
  await until(() => $$(w, "#app [data-loopen]").length >= 2, 8000); await wait(400);
  row = await showDay(w, TOMORROW);
  ok("…and it stays off after a reload", !!row && !row.querySelector(".calitem.off"));

  console.log("--- The trip bar");
  await click(w, '[data-tab="issues"]', 600);
  ok("Nothing in progress: no bar on Issues either", !$(w, ".tripbar"));
  await click(w, '[data-tab="loadout"]', 600);
  const lo1 = (await admin.query("select id, job_id from loadouts where client_id = $1", [d1])).rows[0];
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, stage, truck, note, storage_path, taken_by_name, shot_at)
                     values ($1, $2, 'delivery', 'loadout', $3, 'dock', 1, 'Truck 1', $4, 'Shawn K', now())`, [crypto.randomUUID(), lo1.job_id, lo1.id, `PROJ-00418/${crypto.randomUUID()}.jpg`]);
  // the phone left on Issues: the trips still refresh there, so the bar comes up without visiting Load-out
  const onIssues = { ...kept(w), sf_tab: JSON.stringify("issues") }; w.close();
  ({ w, downloads } = boot(users.shawn, { cache: cacheA, store: onIssues }));
  await until(() => !!$(w, ".tripbar"), 8000); await wait(300);
  ok("A trip started at our dock puts a LOADING bar on top of Issues, with the phone left there", $(w, '[data-tab="issues"]') && $(w, '[data-tab="issues"]').getAttribute("aria-current") === "true" && /^LOADING/.test(tx($(w, ".tripbar small"))));
  await click(w, '[data-tab="loadout"]', 600);
  let bar = $(w, ".tripbar");
  ok("…and at the top of Load-out", !!bar && /^LOADING/.test(tx(bar.querySelector("small"))) && /PROJ-00418 · Enid's Table/.test(tx(bar)) && /Open/.test(tx(bar)), tx(bar));
  ok("…above the calendar", !!bar && !!bar.compareDocumentPosition && !!(bar.compareDocumentPosition($(w, ".calsw")) & 4));
  for (const tab of ["issues", "tasks", "arrow"]) {
    if (!$(w, `[data-tab="${tab}"]`)) continue;
    await click(w, `[data-tab="${tab}"]`, 500);
    ok(`…and on ${tab[0].toUpperCase() + tab.slice(1)}`, /LOADING/.test(tx($(w, ".tripbar"))));
  }
  await click(w, ".tripbar", 800);
  await until(() => /2 · At the site/.test(txt(w)), 5000);
  ok("Tapping it from another tab opens that trip on Load-out", tx($(w, "#app h1")) === "PROJ-00418" && $(w, '[data-tab="loadout"]').getAttribute("aria-current") === "true");
  ok("…where the bar doesn't show for it", !$(w, ".tripbar"));
  const r = await makeClient(users.shawn).rpc("finish_loadout", { p_loadout: d1, p_note: null });
  if (r.error) console.log("finish_loadout:", r.error.message);
  await toLoadout(w); await wait(500);
  bar = $(w, ".tripbar");
  // the time it left (from the database's clock: with the phone's clock moved, as in a Sunday run, it's another day and gets its date)
  ok("The truck leaves: ON THE ROAD · LEFT and the time", !!bar && /^ON THE ROAD · LEFT ([A-Z]{3} [A-Z]{3} \d{1,2}, )?\d{1,2}:\d\d [AP]M$/.test(tx(bar.querySelector("small"))), tx(bar && bar.querySelector("small")));
  ok("…and on the calendar the trip says On the road", /On the road/.test(tx(tripIn($(w, `.wkday[data-day="${TODAY}"]`), "PROJ-00418"))));
  await click(w, '[data-tab="issues"]', 500);
  await click(w, ".tripbar", 800); await until(() => /2 · At the site/.test(txt(w)), 5000);
  ok("…tapping it from Issues opens the trip", tx($(w, "#app h1")) === "PROJ-00418");
  const lo3 = (await admin.query("select id, job_id from loadouts where client_id = $1", [d3])).rows[0];
  await admin.query(`insert into photos (client_id, job_id, department, kind, loadout_id, stage, truck, note, storage_path, taken_by_name, shot_at)
                     values ($1, $2, 'delivery', 'loadout', $3, 'dock', 1, 'Truck 1', $4, 'Shawn K', now())`, [crypto.randomUUID(), lo3.job_id, lo3.id, `PROJ-00099/${crypto.randomUUID()}.jpg`]);
  await toLoadout(w); await wait(500);
  ok("Two trips in progress get a bar each", $$(w, ".tripbar").length === 2 && /ON THE ROAD/.test(tx($$(w, ".tripbar")[0])) && /LOADING/.test(tx($$(w, ".tripbar")[1])), $$(w, ".tripbar").map(x => tx(x.querySelector("small"))).join(" | "));
  await admin.query("update loadouts set completed_at = now(), completed_by_name = 'Shawn K', signed_name = 'Ann' where client_id = $1", [d1]);
  await admin.query("update photos set voided_at = now() where loadout_id = $1", [lo3.id]);
  await click(w, '[data-tab="issues"]', 300); await click(w, '[data-tab="loadout"]', 700);
  ok("Delivered (and the other photo taken back): no bar", !$(w, ".tripbar"), $$(w, ".tripbar").map(tx).join(" | "));
  w.close();

  console.log("--- A customer pickup");
  const pk = crypto.randomUUID();
  await call("schedule_pickup", { p_job: await job("PROJ-00099"), p_kind: "customer_pickup", p_note: null, p_loadout: null, p_client_id: pk });
  ({ w } = boot(users.shawn, { cache: cacheA, store }));
  await until(() => $$(w, "#app [data-loopen]").some(x => /PROJ-00099/.test(tx(x)) && /ready since/.test(tx(x))), 8000); await wait(300);
  ok("Ready for pickup stays a list under the calendar", /Ready for pickup/.test(txt(w)) && !!$$(w, "#app h2.sec").find(h => tx(h) === "Ready for pickup"));
  await click(w, $$(w, "#app [data-loopen]").find(x => /PROJ-00099/.test(tx(x)) && /ready since/.test(tx(x))), 600);
  await until(() => /Each table as it's handed over/.test(txt(w)) && !/Loading the sheets/.test(txt(w)), 5000);
  ok("…and a pickup's table cards have the drawings", $$(w, ".locard .tbhead [data-snip]").length === 3, String($$(w, ".locard .tbhead [data-snip]").length));
  w.close();

  console.log("--- The calendar's days");
  ({ w } = boot(users.shawn, { cache: cacheStub(), store }));
  const f = w;
  ok("Weeks start on Monday, across a month", f.weekStart && f.weekStart("2026-11-01") === "2026-10-26" && f.weekStart("2026-10-26") === "2026-10-26");
  ok("Adding days across the clocks changing and a new year", f.addDays && f.addDays("2026-03-07", 1) === "2026-03-08" && f.addDays("2026-03-08", 1) === "2026-03-09" && f.addDays("2026-11-01", 1) === "2026-11-02" && f.addDays("2026-12-31", 1) === "2027-01-01");
  ok("A week's dates in words, within and across months", f.rangeLabel && f.rangeLabel("2026-10-19", "2026-10-25") === "Oct 19 – 25" && f.rangeLabel("2026-10-26", "2026-11-01") === "Oct 26 – Nov 1");
  ok("Months forward and back, across the year", f.monthFirst && f.monthFirst("2026-12-15", 1) === "2027-01-01" && f.monthFirst("2026-01-15", -1) === "2025-12-01" && f.monthName("2026-10-22") === "October 2026");
  ok("Wi-Fi only when the phone is sure: wifi saves; cellular, none and unknown don't",
     f.netKindOf && f.netKindOf({ type: "wifi" }) === "wifi" && f.netKindOf({ type: "ethernet" }) === "wifi" && f.netKindOf({ type: "cellular" }) === "cellular"
     && f.netKindOf({ type: "none" }) === "none" && f.netKindOf({ effectiveType: "4g" }) === "unknown" && f.netKindOf(null) === "unknown");
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("CRASH", e.stack || e); console.log(`\n${pass} passed, ${fail + 1} failed`); process.exit(1); });
