// Review findings R-1 and R-2 (6 Oct): nothing waiting on a tablet is thrown away, and a count sent after
// a change order lands on the current work order (or is refused in plain words, and kept).
//
//   Part 1  the three senders against every reply the reviewer used (no database): kept and retried,
//           or put on "Couldn't send" with everything needed — never just deleted. The live page is run
//           the same way and must lose things, which proves the test tests something.
//   Part 2  on a seeded database WITH counts_safety.sql: Mike's tablet loaded PROJ-00418, then a change
//           order arrives; a count on an unchanged sheet lands on the new version; a count on a changed
//           sheet goes to Couldn't send (Try again, Dismiss). The live page on the new database: its
//           count on the replaced version is refused (not quietly saved), and on the current one still saves.
//   Part 3  (OLDDB=1) on a database WITHOUT counts_safety.sql: the new page's counts still save.
//
// Run:  bash base/fresh2.sh (TEMPLATE=a template with or without counts_safety.sql), then
//       cd /home/claude/sf/t && TZ=America/Indiana/Indianapolis node test_send_safety.js     (OLDDB=1 for part 3)
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const NEW = strip(fs.readFileSync(process.env.NEWPAGE || "/home/claude/sf/out/index.html", "utf8"));
const LIVE = strip(fs.readFileSync(process.env.LIVEPAGE || "/home/claude/sf/repo/index.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(html, user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {}; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.module = { exports: {} };
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client, api: w.module.exports };
}
const $ = (w, s) => w.document.querySelector(s);
const text = (w) => $(w, "#app").textContent.replace(/\s+/g, " ");
async function click(w, sel, pause = 120) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }

// ---- the replies the reviewer used, as supabase-js hands them over --------------------------------------
const R = {
  network:   { error: { message: "TypeError: Failed to fetch" } },
  reload:    { error: { code: "PGRST002", message: "Could not query the database for the schema cache. Retrying." }, status: 503 },
  missing:   { error: { code: "PGRST202", message: "Could not find the function public.set_count(p_progress, p_qty) in the schema cache" }, status: 404 },
  jwt:       { error: { code: "PGRST301", message: "JWT expired" }, status: 401 },
  s503:      { error: { message: "Service Unavailable" }, status: 503 },
  nologin:   { error: { code: "42501", message: "permission denied for function set_count" }, status: 401 },
  business:  { error: { code: "P0001", message: "PROJ-00418 has a new work order, and sheet 4 changed on it, so this Sanding count wasn't saved." }, status: 400 },
  check:     { error: { code: "23514", message: "new row for relation \"sheet_progress\" violates check constraint" }, status: 400 },
};
// a fake db: rpc answers from a script; the direct count route answers `direct`
function fakeDb(answer, direct = { data: [{ id: "p1", qty_done: 2, state: "in_progress" }], error: null }) {
  const calls = [];
  return { calls, rpc: async (fn, args) => { calls.push(fn); return typeof answer === "function" ? answer(fn, args) : answer; },
    from: () => ({ update: () => ({ eq: () => ({ select: async () => { calls.push("direct"); return direct; } }) }) }),
    storage: { from: () => ({ upload: async () => { calls.push("upload"); return { data: {}, error: null }; } }) } };
}
const memStore = (recs) => { const m = new Map(recs.map(r => [r.id, r])); return { m, list: async () => [...m.values()], put: async (r) => { m.set(r.id, r); }, remove: async (id) => { m.delete(id); } }; };

async function part1(api, live) {
  console.log("--- Part 1: every reply, kept or listed, never dropped");
  const box = (o) => { let b = o; return { get: () => b, set: (n) => { b = n; } }; };
  for (const k of ["network", "reload", "jwt", "s503", "nologin"]) {
    const b = box({ p1: { qty: 2, at: "2026-10-06T10:00:00Z", label: "PROJ-00418 sheet 4 · Sanding: 2 of 3 done" } });
    const r = await api.flushOutbox(b, fakeDb(R[k]));
    ok(`a count answered "${k}" stays waiting on the tablet`, !!b.get().p1 && r.refused.length === 0, JSON.stringify(b.get()));
    if (live) {
      const lb = box({ p1: { qty: 2, at: "x" } });
      await live.flushOutbox(lb, { from: () => ({ update: () => ({ eq: () => ({ select: async () => R[k] }) }) }) });
      if (k !== "network") ok(`  (the live page loses it: proves the test)`, !lb.get().p1);
    }
  }
  { const b = box({ p1: { qty: 2, at: "x" } }); const db = fakeDb(R.missing);
    const r = await api.flushOutbox(b, db);
    ok("on a database without set_count(), the count is written the old way and saved", r.saved.length === 1 && !b.get().p1 && db.calls.join() === "set_count,direct", db.calls.join()); }
  for (const k of ["business", "check"]) {
    const b = box({ p1: { qty: 3, at: "x", label: "PROJ-00418 sheet 4 · Sanding: 3 of 3 done" } });
    const r = await api.flushOutbox(b, fakeDb(R[k]));
    const f = r.refused[0] || {};
    ok(`a count refused for a reason ("${k}") comes back with its label, reason and number, to be kept`,
       !b.get().p1 && f.kind === "count" && /sheet 4/.test(f.label) && f.payload && f.payload.qty === 3 && f.reason.length > 10, JSON.stringify(f));
  }
  { const b = box({ p1: { qty: 2, at: "x", heldSince: "2026-10-01T00:00:00Z" } });
    const r = await api.flushOutbox(b, fakeDb(R.reload));
    ok("a count still held after a day goes to Couldn't send instead of waiting for ever", r.refused.length === 1 && /after a day/.test(r.refused[0].reason) && r.refused[0].payload.qty === 2); }
  { const b = box({ p1: { qty: 2, at: "x" } });
    const r = await api.flushOutbox(b, fakeDb({ data: { id: "p9", qty_done: 2, state: "in_progress", moved: true }, error: null }));
    ok("a count moved to the new work order is reported as moved", r.saved.length === 1 && r.saved[0].moved && r.saved[0].id === "p9"); }

  // entries
  const entries = () => box({
    a: { fn: "send_feedback", args: { p_client_id: "a" }, label: "Feedback", at: "2026-10-06T10:00:00Z" },
    b: { fn: "report_defect", args: { p_client_id: "b" }, label: "Defect", at: "2026-10-06T10:01:00Z" } });
  { const b = entries(); const r = await api.flushLogbox(b, fakeDb((fn) => fn === "send_feedback" ? R.missing : { data: "ok", error: null }));
    ok("an entry whose function isn't in the database yet waits, and the ones after it still send", !!b.get().a && !b.get().b && r.sent.length === 1); }
  for (const k of ["reload", "jwt", "s503", "nologin"]) {
    const b = entries(); const r = await api.flushLogbox(b, fakeDb(R[k]));
    ok(`entries answered "${k}" all stay waiting`, !!b.get().a && !!b.get().b && r.refused.length === 0);
    if (live) { const lb = entries(); await live.flushLogbox(lb, fakeDb(R[k])); ok("  (the live page loses them)", !lb.get().a && !lb.get().b); }
  }
  { const b = entries(); const r = await api.flushLogbox(b, fakeDb(R.business));
    ok("an entry refused for a reason comes back whole (function and what was typed), to be kept", r.refused.length === 2 && r.refused[0].payload.fn === "send_feedback" && r.refused[0].payload.args.p_client_id === "a"); }

  // photos and a signed delivery
  const signed = () => ({ id: "d1", kind: "delivery_done", signed: true, signedName: "Pat", parent: "lo1", projectId: "PROJ-00418", label: "Delivery PROJ-00418", at: "2026-10-06T10:00:00Z", blob: new Blob(["sig"]) });
  for (const k of ["reload", "jwt", "s503"]) {
    const st = memStore([signed()]); const r = await api.flushPhotobox(st, fakeDb(R[k]));
    const rec = st.m.get("d1");
    ok(`a signed delivery answered "${k}" stays waiting, signature and all`, rec && !rec.failed && rec.blob && r.refused.length === 0);
    if (live) { const ls = memStore([signed()]); await live.flushPhotobox(ls, fakeDb(R[k])); ok("  (the live page deletes it)", !ls.m.get("d1")); }
  }
  { const st = memStore([signed(), { id: "x2", kind: "defect", parent: "zz", projectId: "PROJ-00418", label: "Photo", at: "2026-10-06T10:02:00Z", blob: new Blob(["j"]) }]);
    const r = await api.flushPhotobox(st, fakeDb((fn) => fn === "complete_delivery" ? R.business : { data: { ok: true }, error: null }));
    const rec = st.m.get("d1");
    ok("a signed delivery refused for a reason is kept on the device, marked, with the signature", rec && rec.failed && /new work order/.test(rec.failed.reason) && rec.blob && r.refused.length === 1);
    ok("…and the photo after it still sent", !st.m.get("x2"));
    const db = fakeDb({ data: { ok: true }, error: null }); await api.flushPhotobox(st, db);
    ok("a refused one isn't sent again by itself (it waits for Try again)", !db.calls.includes("complete_delivery") && !!st.m.get("d1")); }
  { const st = memStore([{ id: "o1", kind: "defect", parent: "gone", projectId: "PROJ-00418", label: "Photo", at: "x", tries: 2, blob: new Blob(["j"]) }]);
    await api.flushPhotobox(st, fakeDb({ data: { waiting: true }, error: null }));
    const rec = st.m.get("o1");
    ok("a photo whose entry never arrived is kept on Couldn't send after three tries, not deleted", rec && rec.failed && rec.blob); }
  ok("sendOutcome: a raised message is a refusal; a no-login 42501 is a hold", api.sendOutcome(R.business.error, 400) === "refuse"
     && api.sendOutcome({ code: "42501", message: "Test jobs are counted by the Test Supervisor, not this login." }, 403) === "refuse"
     && api.sendOutcome(R.nologin.error, 401) === "hold" && api.sendOutcome({ code: "28000", message: "Not signed in" }) === "hold");
}

// a change order on PROJ-00418: version 2, every sheet carried forward except sheet 5 (its drawing changed)
const CHANGE_ORDER = `do $$
declare v_job uuid; v_old uuid; v_new uuid; s record; ns uuid;
begin
  select id into v_job from jobs where project_id = 'PROJ-00418';
  select id into v_old from work_orders where job_id = v_job and is_current;
  update sheets set spec_hash = 'h' || sheet_number where work_order_id = v_old;
  update work_orders set is_current = false, superseded_at = now() where id = v_old;
  insert into work_orders (job_id, version, is_current) values (v_job, (select max(version) + 1 from work_orders where job_id = v_job), true) returning id into v_new;
  for s in select * from sheets where work_order_id = v_old loop
    insert into sheets (work_order_id, sheet_number, item_code, qty, species, shape, width, length, thickness, png_path, pdf_path, spec_hash)
    values (v_new, s.sheet_number, s.item_code, s.qty, s.species, s.shape, s.width, s.length, s.thickness, s.png_path, s.pdf_path,
            case when s.sheet_number = 5 then 'changed' else s.spec_hash end) returning id into ns;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
    select ns, department, qty_required, case when s.sheet_number = 5 then 0 else qty_done end from sheet_progress where sheet_id = s.id;
  end loop;
end $$;`;
const q = (sql, a) => admin.query(sql, a);
const prog = async (num, current) => (await q(`select sp.id, sp.qty_done from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id
  join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00418' and s.sheet_number = $1 and sp.department = 'sanding' and w.is_current = $2 order by w.version desc limit 1`, [num, current])).rows[0];

async function openSheet(w, progressId) {
  await until(() => /PROJ-00418/.test(text(w)));
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]');
  const jobId = (await q("select id from jobs where project_id = 'PROJ-00418'")).rows[0].id;
  await click(w, `[data-job="${jobId}"]`, 300);
  await click(w, `[data-sheet="${progressId}"]`, 300);
}

async function part2() {
  console.log("--- Part 2: a change order arrives while Mike's tablets have PROJ-00418 open (database with counts_safety.sql)");
  const s4 = await prog(4, true), s5 = await prog(5, true), s6 = await prog(6, true);
  const t1 = boot(NEW, users.mike), t2 = boot(NEW, users.mike), t3 = boot(LIVE, users.mike);
  await openSheet(t1.w, s4.id); await openSheet(t2.w, s5.id); await openSheet(t3.w, s6.id);
  ok("three of Mike's tablets have the job open (two new pages, one live)", !!$(t1.w, "[data-step]") && !!$(t2.w, "[data-step]") && !!$(t3.w, "[data-step]"));
  await q(CHANGE_ORDER);
  ok("the change order is in: version 2 current", !!(await prog(4, true)) && (await prog(4, true)).id !== s4.id);

  // sheet 4 carried forward: the count lands on version 2
  await click(t1.w, '[data-step="1"]', 200);
  await until(async () => (await prog(4, true)).qty_done === 1);
  const n4 = await prog(4, true), o4 = await prog(4, false);
  ok("new page, unchanged sheet: the count is saved on the new work order", n4.qty_done === 1 && o4.qty_done === 0, `v2 ${n4.qty_done}, v1 ${o4.qty_done}`);
  await until(() => /new work order/.test(text(t1.w)), 3000);
  ok("…and the tablet says so", /saved on the job's new work order/.test(text(t1.w)), text(t1.w).slice(0, 200));
  await click(t1.w, '[data-step="1"]', 200);
  await until(async () => (await prog(4, true)).qty_done === 2);
  ok("…the tablet stays on sheet 4, now the new version, and the next tap saves there too", (await prog(4, true)).qty_done === 2 && /Sheet 4/.test(text(t1.w)) && (await prog(4, false)).qty_done === 0);
  const ev = (await q("select source, actor from progress_events where sheet_id = (select sheet_id from sheet_progress where id = $1) order by occurred_at desc limit 1", [n4.id])).rows[0];
  ok("…recorded as a Tablet count by Mike", ev && ev.source === "Tablet" && ev.actor === users.mike.id, JSON.stringify(ev));

  // sheet 5 changed: refused, kept, listed
  await click(t2.w, '[data-step="1"]', 200);
  await until(() => /couldn't be sent/.test(text(t2.w)));
  const tx = text(t2.w);
  ok("new page, changed sheet: nothing saved anywhere", (await prog(5, true)).qty_done === 0 && (await prog(5, false)).qty_done === 0);
  ok("…the tablet shows \"1 thing couldn't be sent\" and the reason", /1 thing couldn't be sent/.test(tx) && /sheet 5 changed/.test(tx), tx.slice(0, 300));
  ok("…and nothing is left waiting to send", !/waiting to send/.test(tx));
  await click(t2.w, "[data-failed]");
  const list = $(t2.w, ".mdl") ? $(t2.w, ".mdl").textContent.replace(/\s+/g, " ") : "";
  ok("the Couldn't send list shows what it was: job, sheet, department, number", /PROJ-00418 sheet 5 · Sanding: 1 of \d+ done/.test(list) && /Try again/.test(list) && /Dismiss/.test(list), list.slice(0, 300));
  const stored = JSON.parse(t2.w.localStorage.getItem("sf_failed") || t2.w.localStorage.getItem("failed") || "null")
               || Object.entries(t2.w.localStorage).filter(([k]) => /failed/.test(k)).map(([, v]) => JSON.parse(v))[0];
  ok("it's kept in the tablet's storage (survives closing the app)", Array.isArray(stored) && stored.length === 1 && stored[0].payload.qty === 1, JSON.stringify(stored));
  await click(t2.w, `[data-failretry]`, 600);
  await until(() => /couldn't be sent/.test(text(t2.w)));
  ok("Try again: refused again for the same reason, still kept (not lost)", /1 thing couldn't be sent/.test(text(t2.w)));
  await click(t2.w, "[data-failed]"); await click(t2.w, "[data-faildismiss]");
  ok("Dismiss asks first", /Dismiss this\?/.test($(t2.w, ".mdl").textContent));
  await click(t2.w, "[data-confirm]", 300);
  ok("…then it's gone from the list and the bar", !/couldn't be sent/.test(text(t2.w)) && !$(t2.w, ".mdl"));

  // the live page on the new database
  await click(t3.w, '[data-step="1"]', 400);
  await until(() => /replaced by a newer version/.test(text(t3.w)));
  ok("live page, replaced version: refused with a plain message instead of quietly saving to the old version",
     /replaced by a newer version/.test(text(t3.w)) && (await prog(6, false)).qty_done === 0 && (await prog(6, true)).qty_done === 0, text(t3.w).slice(0, 200));
  t3.w.close();
  const t4 = boot(LIVE, users.mike); const c6 = await prog(6, true);
  await openSheet(t4.w, c6.id); await click(t4.w, '[data-step="1"]', 400);
  await until(async () => (await prog(6, true)).qty_done === 1);
  ok("live page, current version: the count saves as before", (await prog(6, true)).qty_done === 1);
  for (const t of [t1, t2, t4]) t.w.close();
}

async function part3() {
  console.log("--- Part 3: the new page on a database WITHOUT counts_safety.sql");
  const hasFn = (await q("select to_regprocedure('public.set_count(uuid,integer)') is not null h")).rows[0].h;
  ok("(this database has no set_count())", !hasFn);
  const s4 = await prog(4, true);
  const t = boot(NEW, users.mike); await openSheet(t.w, s4.id);
  await click(t.w, '[data-step="1"]', 400);
  await until(async () => (await prog(4, true)).qty_done === s4.qty_done + 1);
  ok("the count saves (written the old way)", (await prog(4, true)).qty_done === s4.qty_done + 1);
  await wait(400);
  ok("nothing waiting, nothing on Couldn't send", !/waiting to send|couldn't be sent/.test(text(t.w)), text(t.w).slice(0, 200));
  t.w.close();
}

(async () => {
  const a = boot(NEW, users.mike), l = boot(LIVE, users.mike);
  await wait(300);
  await part1(a.api, l.api);
  a.w.close(); l.w.close();
  if (process.env.OLDDB) await part3(); else await part2();
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
