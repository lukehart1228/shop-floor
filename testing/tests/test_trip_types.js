// 5 Oct: dock to dock deliveries and Delivery's tasks — Julia's page (delivery.html) and Shawn's phone (index.html),
// against the test database, plus the photo sender's two new paths and the TV's going-out list.
//   bash /home/claude/sf/base/fresh.sh /home/claude/sf/out/sql/feedback.sql /home/claude/sf/out/sql/trip_types.sql /home/claude/sf/out/sql/install_log.sql
//   TZ=America/Indiana/Indianapolis node test_trip_types.js          (OLDDB=1 on a database without trip_types.sql)
const fs = require("fs"), crypto = require("crypto");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out";
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
// the shared file and the page's own script as ONE piece (a browser shares top-level settings; jsdom keeps evals apart)
const pageScript = (raw, html) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(OUT + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");
function boot(page, user) {
  const raw = fs.readFileSync(`${OUT}/${page}`, "utf8"), html = strip(raw), client = makeClient(user);
  const w = new JSDOM(html, { runScripts: "outside-only", url: `https://lukehart1228.github.io/shop-floor/${page}`, pretendToBeVisual: true }).window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => null; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  w.eval(pageScript(raw, html));
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 200) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
function type(w, sel, v) { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = v; el.dispatchEvent(new w.Event("input", { bubbles: true })); }
const q1 = async (sql, a = []) => (await admin.query(sql, a)).rows[0];
const tomorrow = () => { const d = new Date(Date.now() + 86400000); return d.toISOString().slice(0, 10); };

(async () => {
  const hasTT = (await q1("select to_regclass('public.delivery_tasks') is not null as h")).h;
  // Julia: schedules deliveries, not a manager
  await admin.query("insert into auth.users (id, email) select gen_random_uuid(), 'julia@pdindy.com' where not exists (select 1 from auth.users where email = 'julia@pdindy.com')");
  await admin.query("select set_person('julia@pdindy.com', 'Julia R', 'supervisor', '{finishing}')");
  await admin.query("update profiles set schedules_deliveries = true where id = (select id from auth.users where email = 'julia@pdindy.com')");
  const julia = { id: (await q1("select id from auth.users where email = 'julia@pdindy.com'")).id, email: "julia@pdindy.com" };

  let t = boot("delivery.html", julia), w = t.w;
  await until(() => $$(w, "[data-kind]").length, 8000); await wait(300);
  const kinds = $$(w, "[data-kind]").map(b => b.dataset.kind).join(",");
  if (!hasTT) {
    ok("Older database: Julia sees the three kinds as before, and no error", kinds === "delivery,shipping,customer_pickup" && !/warn/.test(($(w, ".banner") || {}).className || ""), kinds);
    w.close();
    t = boot("index.html", users.shawn); w = t.w;
    await until(() => /Load-out/.test(txt(w)), 8000); await wait(500);
    ok("Older database: Shawn's Load-out works, with no Tasks section", !/Tasks<\/h2>|^Tasks /.test(($(w, "main") || w.document.body).innerHTML) && !/\bTask\b.*Done/.test(txt(w)) && !/isn't set up|wrong/i.test(txt(w)));
    console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }
  ok("Julia's kinds: White glove, Dock to dock, BOL pickup, Customer pickup, Task", kinds === "delivery,dock,shipping,customer_pickup,task", kinds);

  // ---- a dock to dock delivery ----
  await click(w, '[data-kind="dock"]');
  type(w, "#jf", "418"); await wait(200);
  await click(w, $$(w, "[data-pickjob]")[0]);
  type(w, "#dd", tomorrow()); type(w, "#dt", "10:30"); type(w, "#dn", "Dock 4, ask for receiving");
  await click(w, "[data-schedule]", 1200);
  let lo = await q1("select l.* from loadouts l join jobs j on j.id = l.job_id where j.project_id = 'PROJ-00418' and l.kind = 'dock'");
  ok("Julia schedules a dock to dock delivery: kind dock, her time, her note", lo && lo.schedule_note === "Dock 4, ask for receiving" && lo.scheduled_for, lo ? lo.kind : "none");
  ok("…and Coming up shows it as Dock to dock", /Dock to dock/.test(txt(w)) && /PROJ-00418/.test(txt(w)));

  // ---- a task with no PROJ ----
  await click(w, '[data-tab="new"]'); await click(w, '[data-kind="task"]');
  ok("The task form asks what, what it's for, PROJ (optional), where, when — no ticket", !!$(w, "#tw") && !!$(w, "#tf") && !!$(w, "#tl") && !$(w, "#ticketIn") && $(w, "[data-schedule]").disabled);
  type(w, "#tw", "Pick up the damaged chair"); type(w, "#tf", "Smith dining set, quote 1123"); type(w, "#tl", "12 Main St, back door");
  type(w, "#dd", tomorrow()); type(w, "#dt", "14:00"); await wait(100);
  ok("…Schedule lights up once what and when are filled", !$(w, "[data-schedule]").disabled);
  await click(w, "[data-schedule]", 1200);
  let tk = await q1("select * from delivery_tasks where what = 'Pick up the damaged chair'");
  ok("The task is saved with no job, what it's for and where", tk && !tk.job_id && tk.for_text === "Smith dining set, quote 1123" && tk.where_text === "12 Main St, back door" && !tk.is_test);
  ok("…and Coming up lists it under Tasks", /Tasks/.test(txt(w)) && /Pick up the damaged chair/.test(txt(w)) && /Smith dining set/.test(txt(w)));
  // add a PROJ later: a finished job is fine
  await click(w, `[data-edittask="${tk.id}"]`);
  ok("Change it opens the task form filled in", $(w, "#tw").value === "Pick up the damaged chair" && /Change the task/.test(txt(w)));
  type(w, "#jf", "00099"); await wait(200);
  const pj = $$(w, "[data-pickjob]")[0]; if (pj) await click(w, pj);
  await click(w, "[data-schedule]", 1200);
  tk = await q1("select t.*, j.project_id from delivery_tasks t left join jobs j on j.id = t.job_id where t.id = $1", [tk.id]);
  ok("A PROJ can be added to the task later", tk.project_id === "PROJ-00099", tk.project_id);
  // a second task, to cancel and put back
  await click(w, '[data-tab="new"]'); await click(w, '[data-kind="task"]');
  type(w, "#tw", "Drop off touch-up kit"); type(w, "#dd", tomorrow()); type(w, "#dt", "16:00"); await wait(50);
  await click(w, "[data-schedule]", 1200);
  const tk2 = await q1("select * from delivery_tasks where what = 'Drop off touch-up kit'");
  await click(w, `[data-canceltask="${tk2.id}"]`, 1000);
  ok("Cancelling a task moves it to Cancelled, with Put it back", (await q1("select voided_at from delivery_tasks where id = $1", [tk2.id])).voided_at && !!$(w, `[data-restoretask="${tk2.id}"]`));
  await click(w, `[data-restoretask="${tk2.id}"]`, 1000);
  ok("…and Put it back returns it", !(await q1("select voided_at from delivery_tasks where id = $1", [tk2.id])).voided_at);
  w.close();

  // ---- Shawn: the dock to dock trip ----
  t = boot("index.html", users.shawn); w = t.w;
  await until(() => $$(w, "[data-loopen]").length && $$(w, "[data-taskopen]").length, 8000); await wait(300);
  const card = $$(w, "[data-loopen]").find(b => /PROJ-00418/.test(b.textContent));
  ok("Shawn's Load-out lists the dock to dock trip as Dock to dock", card && /Dock to dock/.test(card.textContent), card ? card.textContent.replace(/\s+/g, " ").slice(0, 120) : "");
  ok("…and a Tasks section with both tasks, soonest first", $$(w, "[data-taskopen]").length === 2 && /Pick up the damaged chair/.test($$(w, "[data-taskopen]")[0].textContent));
  await click(w, card, 800);
  const dtx = txt(w);
  ok("The dock to dock screen: each table before it leaves, then the truck", /1 · At our dock — each table before it leaves/.test(dtx) && /Then the loaded truck/.test(dtx) && $$(w, "[data-loshoot]").length > 0);
  ok("…at their dock, a few photos of the drop", /2 · At their dock — a few photos of the drop/.test(dtx) && !!$(w, "[data-dldrop]") && !$(w, "[data-dlsite]"));
  ok("…then the receiver's name and signature", /3 · The receiver/.test(dtx) && /The receiver's name/.test(dtx) && /Dock to dock/.test(txt(w, ".dlwhen")));
  await click(w, "[data-loback]", 600);

  // ---- Shawn: a task ----
  await click(w, $$(w, "[data-taskopen]")[0], 300);
  ok("A task opens: what to do, where, what it's for and its PROJ", /What to do: Pick up the damaged chair/.test(txt(w)) && /Where: 12 Main St/.test(txt(w)) && /PROJ-00099/.test(txt(w)) && /Smith dining set/.test(txt(w)));
  type(w, "#taskNote", "Chair is in the shop, cracked leg");
  await click(w, "[data-taskdone]", 1500);
  if (process.env.DEBUG) console.log("AFTER DONE:", txt(w).slice(0, 300), "| taskView:", w.eval("1") );
  tk = await q1("select * from delivery_tasks where what = 'Pick up the damaged chair'");
  ok("Done marks it done with the note, as Shawn", tk.done_at && tk.done_note === "Chair is in the shop, cracked leg" && tk.done_by_name === "Shawn K");
  ok("…and the screen says Done", /Done · Shawn K/.test(txt(w)));
  await click(w, "[data-taskback]", 800);
  ok("Back on the list it's under Done in the last two weeks", /Done in the last two weeks/.test(txt(w)) && $$(w, "[data-taskopen]").length === 1);
  // no signal: Done waits, then sends once
  await click(w, $$(w, "[data-taskopen]")[0], 300);
  setOffline(true);
  await click(w, "[data-taskdone]", 900);
  ok("No signal: Done waits on the phone (Done · waiting to send)", /Waiting to send/.test(txt(w)) && !(await q1("select done_at from delivery_tasks where id = $1", [tk2.id])).done_at);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => (await q1("select done_at from delivery_tasks where id = $1", [tk2.id])).done_at, 6000);
  ok("Back online, it sends itself", !!(await q1("select done_at from delivery_tasks where id = $1", [tk2.id])).done_at);

  // ---- the photo sender's two new paths, as Shawn ----
  const store = (recs) => ({ list: async () => recs.slice(), remove: async (id) => { const i = recs.findIndex(r => r.id === id); if (i >= 0) recs.splice(i, 1); }, put: async () => {} });
  const tp = crypto.randomUUID(), dp = crypto.randomUUID();
  const jpg = new Blob([Buffer.from([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" });
  let r = await w.flushPhotobox(store([{ id: tp, kind: "task", parent: tk.id, projectId: "TASKS", blob: jpg, at: new Date().toISOString(), label: "Task photo", shotAt: new Date().toISOString() }]), t.client);
  ok("A task photo uploads to TASKS/ and is kept on the task", r.sent.length === 1 && (await q1("select count(*)::int n from task_photos where client_id = $1 and storage_path = $2", [tp, "TASKS/" + tp + ".jpg"])).n === 1, JSON.stringify(r.refused));
  r = await w.flushPhotobox(store([{ id: dp, kind: "loadout", stage: "site", sheet: null, piece: null, parent: lo.client_id, projectId: "PROJ-00418", blob: jpg, at: new Date().toISOString(), label: "At their dock" }]), t.client);
  ok("A drop photo at their dock is kept on the dock to dock trip, noted At their dock", r.sent.length === 1 && (await q1("select count(*)::int n from photos where client_id = $1 and stage = 'site' and note = 'At their dock'", [dp])).n === 1, JSON.stringify(r.refused));
  w.close();

  // ---- the TV's going-out list ----
  await admin.query("insert into delivery_tasks (client_id, what, scheduled_for, is_test) values (gen_random_uuid(), 'TV check task', now() + interval '1 day', false)");
  let tv = null;
  try { const k = await q1("select new_tv_link() as v"); const key = (JSON.stringify(k.v).match(/[A-Za-z0-9_-]{20,}/) || [])[0]; tv = (await q1("select tv_snapshot($1) as s", [key])).s; } catch (e) { tv = { error: e.message }; }
  const trips = (tv && tv.trips) || [];
  ok("The TV's going-out list shows the dock to dock trip and the upcoming task", trips.some(x => x.project_id === "PROJ-00418") && trips.some(x => x.project_id === "Task" && /TV check task/.test(x.job_name)), JSON.stringify(tv && (tv.error || trips.map(x => x.project_id + ":" + x.job_name))).slice(0, 300));

  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
