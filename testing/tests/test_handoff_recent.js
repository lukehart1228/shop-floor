// Run: bash base/fresh.sh /abs/handoff_recent.sql && psql -h /tmp/pg -p 5433 -U postgres -d sync -f testing/tests/scenario_handoff_recent.sql, then MODE=new node test_handoff_recent.js (MODE=old without the file)
// 2 Oct: started jobs stay on Ready, jobs not handed off are hidden from Milling/Metal/Full Custom,
// and Recently completed. MODE=new (new database) or MODE=old (live database, no handoff_recent.sql).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const MODE = process.env.MODE || "new";
const PAGE = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(user, dept) {
  const client = makeClient(user);
  const dom = new JSDOM(PAGE, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  if (dept) w.localStorage.setItem("sf_dept", JSON.stringify(dept));
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...PAGE.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const app = (w) => w.document.getElementById("app");
const txt = (w) => app(w).textContent.replace(/\s+/g, " ");
async function click(w, sel) { const el = w.document.querySelector(sel); if (!el) throw new Error("no " + sel); el.click(); await wait(400); }
async function open(user, dept) { const w = boot(user, dept); await until(() => /piece|Nothing/.test(txt(w))); await wait(700); return w; }
(async () => {
  console.log("database:", MODE);
  // 1. Mike, Sanding: PROJ-00099 is started (sheet 1 done) with nothing ready -> stays on Ready
  let w = await open(users.mike, "sanding");
  let t = txt(w);
  const readyCards = [...app(w).querySelectorAll("button.job")].map(b => b.textContent.replace(/\s+/g, " "));
  const c99 = readyCards.find(c => /PROJ-00099/.test(c)) || "";
  ok("Sanding: a started job with nothing ready stays on Ready", !!c99, readyCards.join(" | "));
  ok("…its card says what it's waiting on", /Started · waiting on CNC/.test(c99), c99);
  ok("…and the header counts it", /started, waiting/.test(t), t.slice(0, 300));
  ok("Sanding: a job it has finished leaves Work orders (PROJ-00418)", !readyCards.some(c => /PROJ-00418/.test(c)), readyCards.join(" | "));
  // Recently completed
  ok("Sanding has a Recently completed tab", !!w.document.querySelector('[data-tab="past"]') && /Recently completed/.test(w.document.querySelector('[data-tab="past"]').textContent));
  await click(w, '[data-tab="past"]'); await wait(600); t = txt(w);
  if (MODE === "new") {
    ok("Recently completed lists PROJ-00418, finished on the tablet today", /PROJ-00418/.test(t) && /Done /.test(t), t.slice(0, 400));
    ok("…and not PROJ-00099 (half done)", !/PROJ-00099/.test(t));
    await click(w, "button.job"); t = txt(w);
    ok("…opening it shows its sheets, read only", /← Recently completed/.test(t) && /9 \/ |1 \/ 1|3 \/ 3/.test(t), t.slice(0, 300));
  } else ok("Old database: Recently completed says its SQL file needs running", /isn't set up in the database yet/.test(t), t.slice(0, 300));
  w.close();

  // 2. Donnie, Milling: PROJ-00600 not handed off
  w = await open(users.donnie, "milling"); t = txt(w);
  if (MODE === "new") {
    ok("Milling: a job not handed off is hidden", !/PROJ-00600/.test(t), t.slice(0, 300));
    ok("…and the header says so", /1 not handed off yet/.test(t), t.slice(0, 300));
  } else ok("Old database: Milling hides nothing (PROJ-00600 shows)", /PROJ-00600/.test(t), t.slice(0, 300));
  w.close();
  w = await open(users.willie, "metal"); t = txt(w);
  ok(MODE === "new" ? "Metal: hidden too" : "Old database: Metal hides nothing", MODE === "new" ? !/PROJ-00600/.test(t) : /PROJ-00600/.test(t), t.slice(0, 300)); w.close();
  w = await open(users.eric, "full_custom"); t = txt(w);
  ok(MODE === "new" ? "Full Custom: hidden too" : "Old database: Full Custom hides nothing", MODE === "new" ? !/PROJ-00600/.test(t) : /PROJ-00600/.test(t), t.slice(0, 300)); w.close();
  // CNC isn't held (it waits on Milling as before)
  w = await open(users.donnie, "cnc"); await click(w, '[data-qmode="all"]'); t = txt(w);
  ok("CNC: the job is on All as before (it waits on Milling, not on handoff)", /PROJ-00600/.test(t), t.slice(0, 300)); w.close();

  if (MODE === "new") {
    // 3. Milling counts a piece (say the job was started before Monday flipped back): it stays
    await admin.query("update sheet_progress set qty_done = 1 where department='milling' and sheet_id in (select s.id from sheets s join work_orders w on w.id=s.work_order_id join jobs j on j.id=w.job_id where j.project_id='PROJ-00600')");
    w = await open(users.donnie, "milling"); t = txt(w);
    ok("Milling: once it has counted a piece, the job shows", /PROJ-00600/.test(t) && !/not handed off yet/.test(t), t.slice(0, 300)); w.close();
    w = await open(users.willie, "metal"); t = txt(w);
    ok("Metal: still hidden (Metal hasn't started it)", !/PROJ-00600/.test(t), t.slice(0, 300)); w.close();
    // 4. Monday sets Handed Off to Yes: it shows for Metal within the next refresh
    await admin.query("update jobs set handed_off = true where project_id='PROJ-00600'");
    w = await open(users.willie, "metal"); t = txt(w);
    ok("Metal: shows once Monday says handed off", /PROJ-00600/.test(t), t.slice(0, 300)); w.close();
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
