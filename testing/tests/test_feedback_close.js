// 20 Oct (feedback_close.sql, office.html 2026-10-20.1): closing feedback notes on the office's Feedback list.
// Solved / Not relevant move a note to Closed (folded, with who and when); Put it back undoes it; nothing is deleted.
//   TEMPLATE=sync_base_new bash base/fresh.sh, then
//   OUT=/tmp/allpages TZ=America/Indiana/Indianapolis node test_feedback_close.js
//   (OUT: a folder with every page: the live ones plus the changed ones, as test_feedback.js needs)
//   OLDDB=1 on a seeded sync_base_old (no feedback_close.sql): every note listed, no buttons, one line saying what to run.
//   OFFICE=/home/claude/sf/repo/office.html: the office page before; on the new database it lists every note as before.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/tmp/allpages";
const OFFICE = process.env.OFFICE || `${OUT}/office.html`;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x && !c ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const pageScript = (raw, html, dir) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(dir + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");
function boot(file, user) {
  const raw = fs.readFileSync(file, "utf8"), html = strip(raw);
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html", pretendToBeVisual: true });
  const w = dom.window;
  w.localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  const copied = []; Object.defineProperty(w.navigator, "clipboard", { value: { writeText: async (t) => { copied.push(t); } }, configurable: true });
  w.eval(pageScript(raw, html, OUT));
  return { w, copied };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const openLines = (w) => $$(w, "main > .panel .line, main section.panel:not(details section) .line").filter(l => !l.closest("details")).map(l => l.textContent.replace(/\s+/g, " "));
const closedLines = (w) => $$(w, "main details .panel .line").map(l => l.textContent.replace(/\s+/g, " "));
const lineFor = (w, words) => $$(w, "main .panel .line").find(l => l.textContent.includes(words));
async function openFeedback(user, file = OFFICE) {
  const t = boot(file, user);
  await until(() => $(t.w, "[data-menu]"), 8000); await wait(300);
  $(t.w, "[data-menu]").click(); await wait(100);
  await click(t.w, '.menu [data-tab="feedback"]', 800);
  await until(() => $$(t.w, "main .panel .line").length || /No feedback yet/.test(txt(t.w)));
  return t;
}
async function send(user, page, screen, body) {
  const c = makeClient(user);
  const { error } = await c.rpc("send_feedback", { p_client_id: require("crypto").randomUUID(), p_page: page, p_screen: screen, p_version: "2026-10-20.2", p_body: body });
  if (error) throw new Error(error.message);
  await wait(30);
}

(async () => {
  const hasClose = (await admin.query("select to_regclass('public.feedback_closes') is not null as h")).rows[0].h;
  await send(users.eric, "index", "Full Custom › Recently completed", "I can't see delivery dates after I complete them");
  await send(users.mike, "index", "Sanding › Work orders", "The + button is hard to hit with gloves on");
  await send(users.luke, "office", "Operations", "Could Needs you show the oldest first?");
  await send(users.eric, "index", "Full Custom › Recently completed", "Can this page show delivery date?");

  if (process.env.OLDDB || !hasClose) {
    const t = await openFeedback(users.luke); const w = t.w;
    ok("Older database: every note is listed, as before", openLines(w).length === 4, openLines(w).join(" | "));
    ok("…with no Solved, Not relevant or Closed (nothing to save them to)", !$(w, "[data-fbkstate]") && !$(w, "main details"));
    ok("…and one line saying what to run", /run feedback_close\.sql, then install_log\.sql/.test(txt(w)), txt(w).slice(0, 400));
    await click(w, "[data-fbkcopy]", 300);
    ok("…Copy as text still copies all four", t.copied.length === 1 && t.copied[0].split("\n\n").length === 4);
    console.log(`${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  if (process.env.OFFICE) {     // the office page before this change, on the new database
    const t = await openFeedback(users.luke); const w = t.w;
    const c = makeClient(users.luke);
    const ids = (await admin.query("select id from feedback order by created_at")).rows.map(r => r.id);
    await c.rpc("set_feedback_state", { p_feedback_id: ids[0], p_state: "solved" });
    $(w, "[data-menu]").click(); await wait(100); await click(w, '.menu [data-tab="feedback"]', 800);
    ok("The older office page on the new database still lists every note, a closed one too", $$(w, "main .panel .line").length === 4, txt(w).slice(0, 300));
    console.log(`${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  // ---- 1. Luke opens Feedback: four open notes, each with Solved and Not relevant ----
  let t = await openFeedback(users.luke); let w = t.w;
  ok("Four open notes, newest first", openLines(w).length === 4 && /Can this page show/.test(openLines(w)[0]), openLines(w).map(s => s.slice(0, 40)).join(" | "));
  ok("Each has Solved and Not relevant", $$(w, '[data-fbkstate="solved"]').length === 4 && $$(w, '[data-fbkstate="not_relevant"]').length === 4);
  ok("No Closed section while nothing is closed", !$(w, "main details"));
  ok("The page says what closing does, and that nothing is deleted", /close it as Solved or Not relevant/.test(txt(w)) && /Nothing is deleted/.test(txt(w)));

  // ---- 2. Solved ----
  await click(w, lineFor(w, "I can't see delivery dates").querySelector('[data-fbkstate="solved"]'), 900);
  await until(() => $(w, "main details"));
  ok("Solved: it leaves the open list", openLines(w).length === 3 && !openLines(w).some(s => /I can't see delivery dates/.test(s)), openLines(w).join(" | "));
  ok("…and says where it went", /Closed as solved\. It's under Closed at the bottom; Put it back undoes it\./.test(txt(w)), txt(w).slice(0, 400));
  ok("…Closed (1) is folded at the bottom", /Closed \(1\)/.test(txt(w, "main details summary")) && !$(w, "main details").open);
  let cl = closedLines(w)[0] || "";
  ok("…inside: the note as sent, Solved, who closed it and when, and Put it back",
     /Eric B/.test(cl) && /I can't see delivery dates after I complete them/.test(cl) && /Solved · closed by Luke H · [A-Z][a-z]{2} \d+, \d+:\d\d [AP]M/.test(cl) && /Put it back/.test(cl), cl);
  // ---- 3. Not relevant ----
  await click(w, lineFor(w, "Could Needs you show").querySelector('[data-fbkstate="not_relevant"]'), 900);
  await until(() => /Closed \(2\)/.test(txt(w)));
  ok("Not relevant: Closed (2), newest closed first", /Closed \(2\)/.test(txt(w)) && /Not relevant · closed by Luke H/.test(closedLines(w)[0] || ""), closedLines(w).join(" | "));
  // ---- 4. Copy and the page filter cover open notes ----
  await click(w, "[data-fbkcopy]", 300);
  ok("Copy as text copies only the open notes (2)", t.copied.length === 1 && t.copied[0].split("\n\n").length === 2 && !/I can't see delivery dates/.test(t.copied[0]), JSON.stringify(t.copied[0]));
  await click(w, '[data-fbkpage="office"]', 300);
  ok("Filtered to Office: nothing open, and the closed one is under Closed", /Nothing open from this page/.test(txt(w)) && /Closed \(1\)/.test(txt(w)), txt(w).slice(0, 500));
  await click(w, '[data-fbkpage=""]', 300);
  // ---- 5. Put it back ----
  const det = $(w, "main details"); det.open = true; det.dispatchEvent(new w.Event("toggle")); await wait(100);
  await click(w, lineFor(w, "I can't see delivery dates").querySelector('[data-fbkstate="open"]'), 900);
  await until(() => /Closed \(1\)/.test(txt(w)));
  ok("Put it back: the note is open again, with its buttons", openLines(w).some(s => /I can't see delivery dates/.test(s)) && !!lineFor(w, "I can't see delivery dates").querySelector('[data-fbkstate="solved"]'));
  ok("…the Closed section stayed open while working in it", $(w, "main details").open);
  w.close();

  // ---- 6. In the database: nothing deleted, every change kept ----
  const notes = (await admin.query("select body from feedback order by created_at")).rows.map(r => r.body);
  const hist = (await admin.query("select state, by_name from feedback_closes order by id")).rows.map(r => `${r.state}/${r.by_name}`);
  ok("All four notes are still in the feedback table, word for word", notes.length === 4 && notes[0] === "I can't see delivery dates after I complete them", JSON.stringify(notes));
  ok("The history keeps every change, with who", JSON.stringify(hist) === JSON.stringify(["solved/Luke H", "not_relevant/Luke H", "open/Luke H"]), JSON.stringify(hist));

  // ---- 7. David sees the same; Mike can't close one ----
  t = await openFeedback(users.david); w = t.w;
  ok("David (manager) sees the same: three open, Closed (1)", openLines(w).length === 3 && /Closed \(1\)/.test(txt(w)), txt(w).slice(0, 300));
  w.close();
  const id = (await admin.query("select id from feedback order by created_at limit 1")).rows[0].id;
  const r = await makeClient(users.mike).rpc("set_feedback_state", { p_feedback_id: id, p_state: "solved" });
  ok("Mike (a supervisor) is refused by the database", !!r.error && /Only the office/.test(r.error.message), JSON.stringify(r.error));

  console.log(`${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
