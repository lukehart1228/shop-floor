// 20 Oct (look_only.sql, index.html 2026-10-20.2): a supervisor looks at another department without changing it.
// Sam (CNC only; made here) is given Milling to look at. His tablet gets a Milling tab next to CNC: Milling's Work orders
// and Recently completed exactly as Donnie sees them, but no − / +, Mark all done, send or Report, and nothing is sent.
// His CNC tab is unchanged; the database refuses a Milling count from him; the old page and the old database are unaffected.
// Run on a seeded copy of the NEW database:
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh && TZ=America/Indiana/Indianapolis node test_look_only.js
// OLDDB=1 on a seeded copy of the old database (no look_only.sql): Sam's tablet is exactly as before.
// PAGE=/home/claude/sf/repo/index.html runs the page before, which fails (no Milling tab).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const NEW = strip(fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8"));
const LIVE = strip(fs.readFileSync(process.env.LIVEPAGE || "/home/claude/sf/repo/index.html", "utf8"));
const OLDDB = !!process.env.OLDDB;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const SAM = { id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", email: "sam@example.com" };

function boot(html, user, dept) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  if (dept) w.localStorage.setItem("sf_dept", JSON.stringify(dept));
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const norm = (h) => h.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "ID");
async function click(w, sel, pause = 120) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const settled = async (w) => { await until(() => /PROJ-|Nothing waiting/.test($(w, "#app").textContent)); await wait(500); };
// the department's own content, without the header and the department's tab strip, which differ by login
const body = (w) => norm([...$$(w, "main > *")].filter(e => !e.matches("nav.subtabs, .foot")).map(e => e.outerHTML).join(""));
const rpcNames = (c) => c.rpcs.map(([fn]) => fn);
const actions = "[data-step], [data-all], [data-send], [data-sendall], [data-unsend], [data-report], [data-taskdone]";

(async () => {
  await admin.query(`insert into auth.users (id, email) values ('${SAM.id}', '${SAM.email}') on conflict do nothing;
                     insert into profiles (id, full_name, role, departments) values ('${SAM.id}', 'Sam D', 'supervisor', '{cnc}') on conflict do nothing`);
  const hasCol = (await admin.query("select count(*)::int n from information_schema.columns where table_name = 'profiles' and column_name = 'look_departments'")).rows[0].n === 1;
  console.log(hasCol ? "(new database: look_only.sql)" : "(old database: no look_only.sql)");
  if (OLDDB !== !hasCol) { console.log("Wrong database for this mode."); process.exit(1); }

  // a Milling job finished on Donnie's tablet, so Recently completed has something
  // (the seed's Milling is all done: open two jobs up again, then Donnie finishes one of them on his tablet)
  await admin.query(`update sheet_progress sp set qty_done = 0 from v_floor_sheets f
                      where f.progress_id = sp.id and f.department = 'milling' and f.project_id in ('PROJ-00501', 'PROJ-00502')`);
  const don = makeClient(users.donnie);
  const mill = (await admin.query(`select progress_id, qty_required, job_id, project_id from v_floor_sheets where department = 'milling' and project_id in ('PROJ-00501', 'PROJ-00502') order by project_id, sheet_number`)).rows;
  const doneJob = "PROJ-00501";
  for (const r of mill.filter(x => x.project_id === doneJob)) { const x = await don.rpc("set_count", { p_progress: r.progress_id, p_qty: r.qty_required }); if (x.error) console.log("seed count:", x.error.message); }

  if (OLDDB) {
    // the old database: the new page shows Sam exactly what the live page does
    const a = boot(LIVE, SAM), b = boot(NEW, SAM); await settled(a.w); await settled(b.w);
    ok("Old database: Sam's CNC screen on the new page is identical to the live page", norm($(a.w, "#app").innerHTML.replace(/2026-10-\d\d\.\d/g, "V")) === norm($(b.w, "#app").innerHTML.replace(/2026-10-\d\d\.\d/g, "V")));
    ok("Old database: no Milling tab", !$(b.w, '[data-dept="milling"]'));
    a.w.close(); b.w.close();
    console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  // before: Sam with no look list, on the new page and on the live page
  const plain = boot(NEW, SAM); await settled(plain.w);
  const cncBefore = body(plain.w);
  ok("Sam with nothing to look at: no department tabs", !$(plain.w, "nav.tabs") && !!$(plain.w, "button.job, .empty"));
  plain.w.close();

  const r = await admin.query("select set_look_only('sam@example.com', '{milling}') m");
  ok("set_look_only() gives Sam Milling to look at", /look at Milling/.test(r.rows[0].m), r.rows[0].m);

  // the live page on the new database ignores the list
  const old = boot(LIVE, SAM); await settled(old.w);
  ok("The live page on the new database: Sam sees only CNC, as before", !$(old.w, '[data-dept="milling"]') && body(old.w) === cncBefore);
  old.w.close();

  // the new page
  const s = boot(NEW, SAM); await settled(s.w);
  const deptTabs = $$(s.w, "nav.tabs [data-dept]").map(b => b.textContent.trim());
  ok("Sam's tablet has Milling and CNC tabs, and opens on CNC", JSON.stringify(deptTabs) === '["Milling","CNC"]' && $(s.w, '[data-dept="cnc"]').getAttribute("aria-current") === "true", JSON.stringify(deptTabs));
  ok("His CNC screen is unchanged", body(s.w) === cncBefore);
  ok("No 'look only' wording anywhere", !/look only|looking at/i.test($(s.w, "#app").textContent));
  await click(s.w, '[data-dept="milling"]'); await settled(s.w);
  const subt = $$(s.w, "nav.subtabs [data-tab]").map(b => b.dataset.tab);
  ok("On Milling: Work orders and Recently completed only", JSON.stringify(subt) === '["work","past"]', JSON.stringify(subt));

  const d = boot(NEW, users.donnie, "milling"); await settled(d.w);
  ok("Milling's Work orders list is exactly Donnie's", body(s.w) === body(d.w) && $$(s.w, "button.job").length > 0, `${$$(s.w, "button.job").length} jobs`);
  // the same job, then the same sheet
  await click(s.w, "button.job"); await click(d.w, "button.job"); await wait(300);
  ok("A Milling job page is exactly Donnie's", body(s.w) === body(d.w));
  await click(s.w, "button.sheet"); await click(d.w, "button.sheet"); await wait(400);
  ok("A Milling sheet: the count as a number, and nothing to press", !$(s.w, actions) && /of \d+ done/.test($(s.w, ".counter").textContent) && !!$(s.w, "[data-print]") && !!$(s.w, "#page"),
     $$(s.w, actions).map(e => e.outerHTML.slice(0, 50)).join(" | "));
  ok("…while Donnie's same sheet has its − / + (the comparison is fair)", !!$(d.w, "[data-step]"));
  const sheetName = $(s.w, "h1").textContent;
  ok("…on the same sheet as Donnie's", sheetName === $(d.w, "h1").textContent, sheetName);

  // Recently completed
  await click(s.w, '[data-back="job"]'); await click(s.w, '[data-back="queue"]');
  await click(s.w, '[data-tab="past"]'); await until(() => $(s.w, "button.job")); await wait(300);
  await click(d.w, '[data-back="job"]'); await click(d.w, '[data-back="queue"]');
  await click(d.w, '[data-tab="past"]'); await until(() => $(d.w, "button.job")); await wait(300);
  const pj = $$(s.w, "button.job").length; if (!pj) console.log("DBG", $(s.w, "main").textContent.replace(/\s+/g, " ").slice(0, 300));
  ok("Recently completed is exactly Donnie's", body(s.w) === body(d.w) && pj > 0, `${pj} jobs (${doneJob})`);
  if (pj) {
    await click(s.w, "button.job"); await wait(300);
    if ($(s.w, "button.sheet")) await click(s.w, "button.sheet", 400);
    ok("A finished Milling sheet: no Report or Undo", !$(s.w, actions));
  }

  // nothing was ever sent, and the database refuses it anyway
  ok("Sam's tablet sent no counts or entries", !rpcNames(s.client).some(n => n !== "report_device" && /set_count|log_|report|send/.test(n)) && [null, "{}"].includes(s.w.localStorage.getItem("sf_outbox")),
     rpcNames(s.client).join(", "));
  const sam = makeClient(SAM);
  const ref = await sam.rpc("set_count", { p_progress: mill.find(x => x.project_id === "PROJ-00502").progress_id, p_qty: 1 });
  ok("The database refuses a Milling count from Sam's login", !!ref.error && /isn't allowed to change/.test(ref.error.message), ref.error ? ref.error.message : "saved!");
  const cnc = (await admin.query(`select progress_id from v_floor_sheets where department = 'cnc' and not is_test limit 1`)).rows[0];
  const own = await sam.rpc("set_count", { p_progress: cnc.progress_id, p_qty: 1 });
  ok("…and still takes his CNC counts", !own.error, own.error && own.error.message);

  // switching back to CNC: his own tab, counters and all
  await click(s.w, '[data-dept="cnc"]'); await settled(s.w);
  ok("Back on CNC: his own Work orders, Tasks, Issues and Supplies", ["work", "tasks", "issues", "supplies"].every(t => $(s.w, `[data-tab="${t}"]`)));
  s.w.close(); d.w.close();

  // the list cleared: as before
  await admin.query("select set_look_only('sam@example.com', '{}')");
  const after = boot(NEW, SAM, "milling"); await settled(after.w);
  ok("With the list cleared, Sam is back to CNC alone, even if the tablet was left on Milling", !$(after.w, '[data-dept="milling"]') && body(after.w) === cncBefore);
  after.w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
