// 18 Oct: the Prototype lab (lab.sql, lab.html, office.html's ☰ entry) in Chromium, talking to the test database as each
// login through the kit's bridge. Needs a database built with lab.sql (TEMPLATE=sync_base_new bash base/fresh.sh) and
// the three work orders beside this file (PROJ-00212, 00317, 00421). OLDDB=1 on a database without lab.sql.
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_lab.js
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/newrepo", REPO = "/home/claude/sf/repo", OLDDB = !!process.env.OLDDB;
const NM = process.env.NM || "/home/claude/lab/node_modules/pdfjs-dist/legacy/build/";   // pdf.js 3.11.174 from npm
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  let session = { user: ${JSON.stringify(user)} };
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }), storage: { from: () => ({}) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/office.html";
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" }); res.end(body);
});
async function session(browser, user) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 }, serviceWorkers: "block", acceptDownloads: true });
  await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/pdfjs-dist@3\.11\.174\/legacy\/build\/pdf(\.worker)?\.min\.js/, r => r.fulfill({ body: fs.readFileSync(NM + r.request().url().split("/").pop()), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs };
}
const menu = async (p) => { await p.click("[data-menu]"); await p.waitForSelector(".menu"); const it = await p.$$eval(".menu .mitem, .menu a", els => els.map(e => e.childNodes[0].textContent.trim())); await p.keyboard.press("Escape").catch(() => {}); return it; };
const q1 = async (sql, a = []) => (await admin.query(sql, a)).rows;

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const browser = await chromium.launch();
  if (!OLDDB) await admin.query("select lab_allow('luke@example.com')");

  // ---- Luke: the ☰ menu, then the lab inside the office ----
  let s = await session(browser, users.luke), p = s.p;
  await p.goto(base + "office.html"); await p.waitForSelector("header.top [data-tab]", { timeout: 15000 });
  let items = await menu(p);
  if (OLDDB) {
    ok("Old database: Luke's ☰ menu has no Prototype lab, and nothing else changed", !items.includes("Prototype lab") && items.includes("Pace"), JSON.stringify(items));
    const p2 = await s.ctx.newPage(); await p2.goto(base + "lab.html"); await p2.waitForSelector("#notAllowed:not([hidden])", { timeout: 10000 });
    ok("Old database: lab.html says the lab isn’t set up yet, in plain words", /isn’t set up in the database yet. Run lab.sql/.test(await p2.textContent("#notAllowed")));
    ok("No page errors", s.errs.length === 0, s.errs.join(" | "));
    await browser.close(); server.close(); console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
  }
  ok("Luke (let in): ☰ menu shows Prototype lab after Pace", items.indexOf("Prototype lab") === items.indexOf("Pace") + 1, JSON.stringify(items));
  await p.goto(base + "office.html#lab"); await p.waitForSelector("#secs iframe", { timeout: 15000 });
  await p.waitForFunction(() => { const f = document.querySelector("#secs iframe[src^='lab.html']"); return f && f.contentDocument && f.contentDocument.querySelector("#labArea") && !f.contentDocument.querySelector("#labArea").hidden; }, null, { timeout: 15000 });
  let fr = p.frames().find(f => f.url().includes("lab.html?embed=1"));
  ok("The lab opens inside the office, its own title row hidden", await fr.evaluate(() => getComputedStyle(document.querySelector("header")).display === "none"));
  ok("…and starts with nothing learned", /Nothing taught yet/.test(await fr.textContent("#learned")));

  const runJob = async (file, pid) => { await fr.setInputFiles("#pick", file); await fr.waitForFunction((pid) => { const h = document.querySelector("#out h2"); const n = document.querySelector("#savedNote"); return h && h.textContent === pid && n && /Saved|wasn’t saved/.test(n.textContent); }, pid, { timeout: 20000 }); return fr.textContent("#out"); };
  let t = await runJob("PROJ-00317_Work_Order.pdf", "PROJ-00317");
  ok("PROJ-00317 runs: 16 sheets, 14 ready for the upload file", /16 sheets from 17 pages · 14 ready/.test(t));
  ok("…and the run is saved to the lab’s history", /Saved to the lab’s history/.test(t) && (await q1("select count(*)::int n from lab_runs where project_id = 'PROJ-00317'"))[0].n === 1);
  const saved = (await q1("select made, stuck, made_by = (select id from auth.users where email = 'luke@example.com') as mine, jsonb_array_length(stuck_reasons) r from lab_runs where project_id = 'PROJ-00317'"))[0];
  ok("…with its counts, its stuck reasons and Luke as the one who ran it", saved.mine && saved.stuck === 2 && saved.r === 2, JSON.stringify(saved));

  // an answer for one job
  await fr.click('.ctl[data-power="TB-03-RC Power"] .dean');
  await fr.waitForFunction(() => !document.querySelector('.ctl[data-power="TB-03-RC Power"]') && /Saved/.test(document.querySelector("#savedNote").textContent), null, { timeout: 15000 });
  ok("“It’s a Dean” for TB-03 Power is saved as an answer for that job only", (await q1("select count(*)::int n from lab_answers where project_id='PROJ-00317' and item_id='TB-03-RC Power' and field='power_model' and value='Dean'"))[0].n === 1
     && (await q1("select count(*)::int n from lab_rules"))[0].n === 0);
  await fr.fill('.ctl[data-cut="TB-21-RC"] .cutL', "10"); await fr.fill('.ctl[data-cut="TB-21-RC"] .cutW', "4"); await fr.click('.ctl[data-cut="TB-21-RC"] .cut');
  await fr.waitForFunction(() => /16 ready/.test(document.querySelector("#out").textContent) && /Saved/.test(document.querySelector("#savedNote").textContent), null, { timeout: 15000 });
  ok("A cutout for TB-21: all 16 sheets ready for the upload file", true);

  // a reload keeps the answers: they come from the database, not the page
  await p.reload(); await p.waitForSelector("#secs iframe", { timeout: 15000 });
  await p.waitForFunction(() => { const f = document.querySelector("#secs iframe[src^='lab.html']"); return f && f.contentDocument && f.contentDocument.querySelector("#labArea") && !f.contentDocument.querySelector("#labArea").hidden; }, null, { timeout: 15000 });
  fr = p.frames().find(f => f.url().includes("lab.html?embed=1"));
  t = await runJob("PROJ-00317_Work_Order.pdf", "PROJ-00317");
  ok("After a reload, PROJ-00317 comes back with both answers applied (16 ready, nothing asked)", /16 ready/.test(t) && !(await fr.$(".ctl[data-power]")));

  // a rule taught with “Always”, used on the next job
  t = await runJob("PROJ-00212_Work_Order.pdf", "PROJ-00212");
  ok("PROJ-00212 asks whether TB-16’s wood base goes to Full Custom", !!(await fr.$('.ctl[data-fc="TB-16-RC"]')));
  await fr.check('.ctl[data-fc="TB-16-RC"] .always'); await fr.click('.ctl[data-fc="TB-16-RC"] .yes');
  await fr.waitForFunction(() => !document.querySelector('.ctl[data-fc]') && /Saved/.test(document.querySelector("#savedNote").textContent), null, { timeout: 15000 });
  const rule = (await q1("select value::text v, job from lab_rules where rule_set='defaults' and rule_key='wood_base_full_custom'"))[0];
  ok("“Always” saves a rule (wood bases that aren’t slab legs go to Full Custom), noting the job it came from", rule && rule.v === "true" && rule.job === "PROJ-00212", JSON.stringify(rule));
  const tb16 = await fr.evaluate(() => { const d = [...document.querySelectorAll("details.sheet")][5]; d.open = true; return d.textContent; });
  ok("…and TB-16 now goes Milling → … → Full Custom → Assembly / QC", /Finishing → Full Custom → Assembly \/ QC/.test(tb16));
  ok("It’s listed under What it has learned", /A wood base that isn’t a slab leg goes to Full Custom/.test(await fr.textContent("#learned")));

  // a template taught as data from a rule file
  fs.writeFileSync("/tmp/oval_rule.json", JSON.stringify({ kind: "lab-rules", note: "Oval template inputs, from the shop (test values)", job: "PROJ-00212",
    rules: { cnc_templates: { Oval_Template: { shapes: ["oval"], inputs: [{ name: "L", from: "length" }, { name: "W", from: "width" }, { name: "T", from: "thickness" }, { name: "CS", value: 1 }] } } } }));
  await fr.setInputFiles("#rulefile", "/tmp/oval_rule.json");
  await fr.waitForFunction(() => /Oval_Template, for oval tops/.test(document.querySelector("#learned").textContent) && /Saved/.test(document.querySelector("#savedNote").textContent), null, { timeout: 15000 });
  const cncIn = await fr.evaluate(() => { const d = [...document.querySelectorAll("details.sheet")][5]; d.open = true; const t = d.querySelector("table.cncin"); if (!t) return ""; const r = t.querySelectorAll("tr"); return [...r[0].children].map((th, j) => th.textContent + " " + r[1].children[j].textContent).join(" "); });
  ok("A rule file teaches the oval template; TB-16 now prints it", cncIn === "L 46.5 W 22.5 T 1 CS 1", cncIn);
  fs.writeFileSync("/tmp/bad_rule.json", JSON.stringify({ kind: "lab-rules", rules: { run_this: "alert(1)" } }));
  let msg = ""; fr.page().once("dialog", d => { msg = d.message(); d.dismiss(); });
  await fr.setInputFiles("#rulefile", "/tmp/bad_rule.json"); await fr.waitForTimeout(500);
  ok("A rule file with settings the lab doesn’t know is refused whole", /doesn’t know or can’t read: run_this/.test(msg) && (await q1("select count(*)::int n from lab_rules where rule_key='run_this'"))[0].n === 0, msg);

  // stop using a rule: a new row, the old one kept
  fr.page().once("dialog", d => d.accept());
  await fr.click('[data-stop="cnc_templates|Oval_Template"]');
  await fr.waitForFunction(() => !/Oval_Template, for oval tops/.test(document.querySelector("#learned").textContent), null, { timeout: 15000 });
  const hist = await q1("select count(*)::int n, count(*) filter (where value is null)::int stopped from lab_rules where rule_key='Oval_Template'");
  ok("“Stop using” adds a row; the rule’s history is kept", hist[0].n === 2 && hist[0].stopped === 1, JSON.stringify(hist[0]));

  // what I've learned: one file
  await runJob("PROJ-00421_Work_Order.pdf", "PROJ-00421");
  const [dl] = await Promise.all([p.waitForEvent("download"), fr.click("#dlLearned")]);
  const md = fs.readFileSync(await dl.path(), "utf8");
  ok("“Download what I’ve learned” makes one Markdown file", /^lab_learned_\d{4}-\d{2}-\d{2}\.md$/.test(dl.suggestedFilename()) && /^# What the Prototype lab has learned/.test(md), dl.suggestedFilename());
  ok("…listing the rules taught, with why and the job, including the one stopped", /A wood base that isn’t a slab leg goes to Full Custom/.test(md) && /Stopped using: cnc_templates \/ Oval_Template/.test(md) && /from PROJ-00212/.test(md));
  ok("…the answers for single jobs", /PROJ-00317 · TB-03-RC Power: power_model = Dean/.test(md) && /PROJ-00317 · TB-21-RC: port_cutout = 10 x 4/.test(md));
  ok("…what it still gets stuck on, most first, with the jobs", /## What it still gets stuck on \(newest run of each of 3 jobs\)/.test(md) && /\[generator\] No generator for the “chair\/stool” form/.test(md) && /\(jobs: PROJ-00421\)/.test(md));
  ok("…and the rules in use now, as a rule file it can read back", (() => { const m = md.match(/```json\n([\s\S]*?)\n```/); try { const j = JSON.parse(m[1]); return j.kind === "lab-rules" && j.rules.defaults.wood_base_full_custom === true && !j.rules.cnc_templates; } catch (e) { return false; } })());
  ok("No page errors for Luke", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  // ---- David: a manager, not let in ----
  s = await session(browser, users.david); p = s.p;
  await p.goto(base + "office.html"); await p.waitForSelector("header.top [data-tab]", { timeout: 15000 });
  items = await menu(p);
  ok("David (a manager, not let in): no Prototype lab in his ☰ menu", !items.includes("Prototype lab") && items.includes("Pace"), JSON.stringify(items));
  await p.goto(base + "office.html#lab"); await p.waitForSelector("header.top [data-tab]", { timeout: 15000 });
  ok("…and #lab in the address doesn’t open it", !(await p.$("#secs iframe[src^='lab.html']")));
  await p.goto(base + "lab.html"); await p.waitForSelector("#notAllowed:not([hidden])", { timeout: 10000 });
  ok("…opening lab.html directly says he isn’t let in, and how someone would be", /isn’t let into the lab/.test(await p.textContent("#notAllowed")) && /lab_allow\('david@example.com'\)/.test(await p.textContent("#notAllowed")));
  const dc = makeClient(users.david);
  const dr = await dc.from("lab_rules").select("*"), di = await dc.from("lab_rules").insert({ rule_set: "defaults", rule_key: "x", value: 1 });
  ok("…and the database gives him nothing and refuses his writes, whatever the page does", dr.data && dr.data.length === 0 && !!di.error, JSON.stringify(di.error || ""));
  await s.ctx.close();

  // ---- Mike: a supervisor ----
  const mc = makeClient(users.mike);
  const ma = await mc.rpc("lab_allowed", {}), mr = await mc.from("lab_runs").select("*"), mi = await mc.from("lab_runs").insert({ project_id: "PROJ-00317" });
  ok("Mike (a supervisor): not let in, reads no runs, can’t save one", ma.data === false && mr.data.length === 0 && !!mi.error);
  const an = makeClient(null), aa = await an.rpc("lab_allowed", {});
  ok("No login: can’t even ask who’s let in", !!aa.error);

  await browser.close(); server.close();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
