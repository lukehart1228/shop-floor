// 20 Oct (index.html 2026-10-20.3): Recently completed shows each job's delivery date, in words only (Eric's feedback).
// Run: TEMPLATE=sync_base_new bash base/fresh.sh, then
//      psql -h /tmp/pg -p 5433 -U postgres -d sync -f repo/testing/tests/scenario_handoff_recent.sql, then
//      TZ=America/Indiana/Indianapolis node test_recent_delivery.js
// PAGE=/home/claude/sf/repo/index.html runs it on the page before, where the date lines fail.
const fs = require("fs");
const { execFileSync } = require("child_process");
const { JSDOM } = require("jsdom");
const { makeClient, users } = require("./pgsupa");
const PAGE = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };
const sql = (q) => execFileSync("psql", ["-h", "/tmp/pg", "-p", "5433", "-U", "postgres", "-d", "sync", "-XAtc", q]).toString().trim();
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
const MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const words = (iso) => { const [, m, d] = iso.split("-").map(Number); return `${MON[m - 1]} ${d}`; };
async function recent(user, dept) {
  const w = boot(user, dept); await until(() => /piece|Nothing/.test(txt(w))); await wait(700);
  await click(w, '[data-tab="past"]'); await until(() => /PROJ-00418|Nothing here yet/.test(txt(w))); await wait(400);
  return w;
}
const card = (w, pid) => ([...app(w).querySelectorAll("button.job")].map(b => b.textContent.replace(/\s+/g, " ")).find(c => c.includes(pid)) || "");
(async () => {
  const due = sql("select delivery_date from jobs where project_id = 'PROJ-00418'");
  ok("The scenario's PROJ-00418 has a delivery date", /^\d{4}-\d{2}-\d{2}$/.test(due), due);
  // 1. Mike, Sanding: the card and the job's header
  let w = await recent(users.mike, "sanding");
  let c = card(w, "PROJ-00418");
  ok("Recently completed lists PROJ-00418", !!c, txt(w).slice(0, 300));
  ok(`…its card says "Delivery ${words(due)}"`, c.includes(`Delivery ${words(due)}`), c);
  ok("…in the order Done · Delivery · sheets · Monday", /Done [A-Z][a-z]{2} \d+ · Delivery [A-Z][a-z]{2} \d+ · \d+ sheets? · Monday: /.test(c), c);
  ok("…words only: no days-left countdown and no colour on the card", !/days? (left|past|late)/.test(c) && !/style="[^"]*color/.test(app(w).querySelector("button.job").outerHTML), c);
  await click(w, '[data-job]'); await wait(500);
  let t = txt(w);
  ok("…the job's own page says it in its header too", /← Recently completed/.test(t) && t.includes(`Delivery ${words(due)}`), t.slice(0, 300));
  w.close();
  // 2. Monday moves the date: the card follows
  sql("update jobs set delivery_date = date '2026-12-31' where project_id = 'PROJ-00418'");
  w = await recent(users.mike, "sanding"); c = card(w, "PROJ-00418");
  ok("A new date from Monday shows next time (Delivery Dec 31)", c.includes("Delivery Dec 31"), c); w.close();
  // 3. No date in Monday
  sql("update jobs set delivery_date = null where project_id = 'PROJ-00418'");
  w = await recent(users.mike, "sanding"); c = card(w, "PROJ-00418");
  ok("No date in Monday says \"No delivery date\", as Work orders does", c.includes("No delivery date") && !/Delivery [A-Z]/.test(c), c); w.close();
  sql(`update jobs set delivery_date = date '${due}' where project_id = 'PROJ-00418'`);
  console.log(`${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
