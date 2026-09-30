// Every supervisor's tablet: each screen byte-for-byte the same on the new index.html as on the live one,
// and the new page reports its version once per start (the live page doesn't).
// Run on a seeded database; set NEWPAGE / LIVEPAGE to compare other files.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const NEW = strip(fs.readFileSync(process.env.NEWPAGE || "/home/claude/sf/out/index.html", "utf8"));
const LIVE = strip(fs.readFileSync(process.env.LIVEPAGE || "/home/claude/sf/repo/index.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(html, user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function screens(html, user) {
  const { w, client } = boot(html, user);
  await until(() => /PROJ-00418/.test(w.document.getElementById("app").textContent)); await wait(400);
  const out = [];
  const snap = async (name) => { await wait(350); out.push([name, $(w, "#app").innerHTML]); };
  await snap("queue");
  const job = $(w, "button.job"); if (job) { await click(w, job); await snap("job"); const sh = $(w, "button.sheet"); if (sh) { await click(w, sh); await snap("sheet"); } }
  const back = $(w, "[data-back]"); if (back) { await click(w, back); const b2 = $(w, "[data-back]"); if (b2) await click(w, b2); }
  for (const t of [...w.document.querySelectorAll("[data-tab]")].map(b => b.dataset.tab)) { await click(w, `[data-tab="${t}"]`); await snap("tab " + t); }
  await wait(500);
  const reports = client.rpcs.filter(([fn]) => fn === "report_device");
  const dev = JSON.parse(w.localStorage.getItem("sf_device") || "null");
  w.close();
  return { out, reports, dev };
}
(async () => {
  const hasFn = (await admin.query("select to_regprocedure('public.report_device(text,text,text,text)') is not null as h")).rows[0].h;
  console.log(hasFn ? "(database has report_device)" : "(database WITHOUT install_log.sql: no report_device)");
  const before = hasFn ? Number((await admin.query("select count(*) n from device_versions")).rows[0].n) : 0;
  for (const [who, user] of [["Mike", users.mike], ["Donnie", users.donnie], ["Willie", users.willie], ["KP", users.kp], ["Jim", users.jim], ["Eric", users.eric], ["Shawn", users.shawn]]) {
    const a = await screens(LIVE, user), b = await screens(NEW, user);
    const norm = (h) => h.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "ID");
    const diffs = a.out.filter(([n, h], i) => !b.out[i] || norm(h) !== norm(b.out[i][1])).map(([n]) => n);
    ok(`${who}: ${a.out.length} screens identical to the live page`, diffs.length === 0 && a.out.length === b.out.length && a.out.length > 0, diffs.join(", "));
    ok(`${who}: the new page reports once (live page: never)`, a.reports.length === 0 && b.reports.length === 1 && b.reports[0][1].p_page === "index" && /^\d{4}-\d\d-\d\d\.\d+$/.test(b.reports[0][1].p_version) && b.dev && b.reports[0][1].p_device === b.dev,
       JSON.stringify(b.reports.map(r => r[1].p_version)));
  }
  if (hasFn) {
    const r = await admin.query("select d.version, p.full_name from device_versions d join profiles p on p.id = d.user_id order by 2");
    ok(`database has a row per tablet (${r.rows.length - before} new)`, r.rows.length - before === 7, r.rows.map(x => x.full_name + " " + x.version).join(", "));
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
