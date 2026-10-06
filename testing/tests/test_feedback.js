// 5 Oct: the Feedback button on every signed-in page, what each note records, the tablet's offline queue,
// the office's Feedback list, and what a page says on a database without feedback.sql.
//   bash /home/claude/sf/base/fresh.sh /home/claude/sf/out/sql/feedback.sql && TZ=America/Indiana/Indianapolis node test_feedback.js
//   OLDDB=1 on a database WITHOUT feedback.sql: only the "not set up yet" messages are tested.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out";
const OFFICE_V = (require("fs").readFileSync(`${process.env.OUT || "/home/claude/sf/out"}/office.html`, "utf8").match(/const OFFICE_VERSION = "([^"]+)"/) || [])[1];   // 6 Oct: read from the page, not written in here
const TABLET_V = (require("fs").readFileSync(`${process.env.OUT || "/home/claude/sf/out"}/index.html`, "utf8").match(/const PAGE_VERSION = "([^"]+)"/) || [])[1];   // the same for the tablet page
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
// same-folder scripts (the shared sf-common file) and the page's own script, run as ONE piece: a browser shares top-level
// settings between a page's scripts, but jsdom keeps each eval separate
const pageScript = (raw, html, dir) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(dir + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");


function boot(page, user, preload = {}) {
  const raw = fs.readFileSync(`${OUT}/${page}`, "utf8"), html = strip(raw);
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: `https://lukehart1228.github.io/shop-floor/${page}`, pretendToBeVisual: true });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true; w.alert = () => {};
  w.HTMLCanvasElement.prototype.getContext = function () { return new Proxy({}, { get: (o, k) => k in o ? o[k] : () => {}, set: (o, k, v) => (o[k] = v, true) }); };
  const copied = []; Object.defineProperty(w.navigator, "clipboard", { value: { writeText: async (t) => { copied.push(t); } }, configurable: true });
  w.eval(pageScript(raw, html, OUT));
  return { w, client, copied };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const txt = (w, sel = "#app") => (($(w, sel) || {}).textContent || "").replace(/\s+/g, " ");
async function click(w, sel, pause = 150) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
function type(w, el, value) { el.value = value; el.dispatchEvent(new w.Event("input", { bubbles: true })); }
const rows = async () => (await admin.query("select f.*, p.full_name from feedback f join profiles p on p.id = f.user_id order by created_at")).rows;
const OFFICE_PIN = { sfo_pin: JSON.stringify({ none: true }) };

// the shared piece on office, delivery, inventory, pace and upload
async function sendShared(w, note) {
  await until(() => $(w, "[data-sffb]"));
  await click(w, $(w, "[data-sffb]"));
  await until(() => $(w, "#sf-fb textarea"));
  const where = $(w, "#sf-fb .sf-fb-sub b").textContent;
  const go = $(w, "#sf-fb [data-sffbsend]");
  const wasOff = go.disabled;
  type(w, $(w, "#sf-fb textarea"), note);
  const nowOn = !go.disabled;
  await click(w, go, 50);
  await until(() => /Thanks|isn't set up|No connection|Sign in/.test(txt(w, "#sf-fb")));
  return { where, said: txt(w, "#sf-fb"), wasOff, nowOn };
}

(async () => {
  const hasTable = (await admin.query("select to_regclass('public.feedback') is not null as h")).rows[0].h;

  if (process.env.OLDDB || !hasTable) {
    // ---- a database without feedback.sql: pages say so, keep the note, and change nothing else ----
    let t = boot("index.html", users.mike);
    await until(() => /PROJ-00418/.test(txt(t.w)), 8000); await wait(400);
    await click(t.w, "[data-feedback]"); type(t.w, $(t.w, "[data-mfield=text]"), "Old database note");
    await click(t.w, "[data-savefeedback]", 1200);
    ok("Tablet on an older database: it says the feedback couldn't be kept, in plain words", /Feedback: /.test(txt(t.w)) && /set up|database/i.test(txt(t.w)), txt(t.w).match(/Feedback:[^.]*\./) || "");
    ok("…and nothing is left stuck in the queue", Object.keys(JSON.parse(t.w.localStorage.getItem("sf_logbox") || "{}")).length === 0);
    t.w.close();
    t = boot("office.html", users.luke, OFFICE_PIN); await until(() => $(t.w, "[data-sffb]"), 8000);
    const r = await sendShared(t.w, "Old database office note");
    ok("Office on an older database: \"Feedback isn't set up in the database yet\", note kept in the box", /isn't set up in the database yet/.test(r.said) && $(t.w, "#sf-fb textarea").value === "Old database office note", r.said);
    await click(t.w, "[data-tab]", 50);
    t.w.document.querySelector('[data-menu]').click(); await wait(100);
    await click(t.w, '.menu [data-tab="feedback"]', 600);
    ok("Office Feedback list on an older database: says to run feedback.sql", /Run feedback\.sql, then install_log\.sql/.test(txt(t.w)));
    t.w.close();
    console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  // ---- 1. Mike's tablet, on a sheet ----
  let t = boot("index.html", users.mike), w = t.w;
  await until(() => /PROJ-00418/.test(txt(w)), 8000); await wait(400);
  ok("The tablet header has a Feedback button", !!$(w, "header.top [data-feedback]") && /Feedback/.test($(w, "[data-feedback]").textContent));
  const job = $$(w, "button.job").find(b => /PROJ-00418/.test(b.textContent)); await click(w, job);
  const sheet = $(w, "button.sheet"); const sheetNo = sheet ? (sheet.textContent.match(/\d+/) || [""])[0] : ""; if (sheet) await click(w, sheet);
  await click(w, "[data-feedback]");
  const where = txt(w, ".mdl .sub");
  ok("It opens a box naming the screen: department › tab › job › sheet", /Sanding › Work orders › PROJ-00418 › sheet \d+/.test(where), where);
  ok("Send stays off until something's typed", $(w, "[data-savefeedback]").disabled);
  type(w, $(w, "[data-mfield=text]"), "  The + button is hard to hit with gloves on.  ");
  await wait(50);
  ok("…and lights up once it is", !$(w, "[data-savefeedback]").disabled);
  await click(w, "[data-savefeedback]", 900);
  let f = (await rows()).pop();
  ok("Saved with Mike's login and name, the tablet page, the screen and its version",
     f && f.user_id === users.mike.id && f.person_name === "Mike B" && f.page === "index" && /Sanding › Work orders › PROJ-00418 › sheet/.test(f.screen)
     && f.page_version === TABLET_V && f.body === "The + button is hard to hit with gloves on." && !f.is_test, f && JSON.stringify({ n: f.person_name, s: f.screen, v: f.page_version, b: f.body }));
  ok("The box closes and the tablet says thanks", !$(w, ".mdl") && /Thanks — sent to the office/.test(w.document.body.textContent));
  ok("The screen underneath is where Mike left it", /PROJ-00418/.test(txt(w)) && (!sheetNo || new RegExp("Sheet " + sheetNo).test(txt(w))));
  w.close();

  // ---- 2. no signal: it waits, says so, and sends itself once, when the connection is back ----
  t = boot("index.html", users.jim); w = t.w;
  await until(() => /PROJ-/.test(txt(w)), 8000); await wait(400);
  setOffline(true);
  await click(w, "[data-feedback]"); type(w, $(w, "[data-mfield=text]"), "Sent with no signal");
  await click(w, "[data-savefeedback]", 900);
  ok("No signal: it waits on the tablet (the header says 1 entry waiting to send)", /1 entry waiting to send/.test(txt(w, "header")) && (await rows()).filter(r => r.body === "Sent with no signal").length === 0, txt(w, "header"));
  setOffline(false);
  w.dispatchEvent(new w.Event("online")); await until(async () => (await rows()).some(r => r.body === "Sent with no signal"), 6000); await wait(800);
  w.dispatchEvent(new w.Event("online")); await wait(800);
  ok("Back online: it sends itself, once", (await rows()).filter(r => r.body === "Sent with no signal" && r.person_name === "Jim W").length === 1 && /All saved/.test(txt(w, "header")));
  w.close();

  // ---- 3. Shawn's phone, on a trip ----
  const crypto = require("crypto"), luke = makeClient(users.luke);
  const jid = (await admin.query("select id from jobs where project_id = 'PROJ-00418'")).rows[0].id;
  const when = new Date(Date.now() + 86400000); when.setHours(9, 0, 0, 0);
  await luke.rpc("schedule_delivery", { p_job: jid, p_when: when.toISOString(), p_note: null, p_loadout: null, p_client_id: crypto.randomUUID() });
  t = boot("index.html", users.shawn); w = t.w;
  await until(() => $$(w, "[data-loopen]").some(b => /PROJ-00418/.test(b.textContent)), 8000);
  await click(w, $$(w, "[data-loopen]").find(b => /PROJ-00418/.test(b.textContent)), 500);
  await click(w, "[data-feedback]");
  ok("Shawn's phone names the trip", /Delivery › Load-out › PROJ-00418 white glove/.test(txt(w, ".mdl .sub")), txt(w, ".mdl .sub"));
  await click(w, "[data-close]"); w.close();

  // ---- 4. the Test Supervisor's note is marked test ----
  t = boot("index.html", users.test); w = t.w;
  await until(() => $(w, "[data-feedback]"), 8000); await wait(400);
  await click(w, "[data-feedback]"); type(w, $(w, "[data-mfield=text]"), "Practice note"); await click(w, "[data-savefeedback]", 900);
  ok("A note from the Test Supervisor is kept, marked test", (await rows()).some(r => r.body === "Practice note" && r.is_test));
  w.close();

  // ---- 5. the office: its button, then the Feedback list ----
  t = boot("office.html", users.luke, OFFICE_PIN); w = t.w;
  await until(() => $(w, "header.top [data-sffb]"), 8000); await wait(300);
  ok("The office header has a Feedback button", !!$(w, "header.top [data-sffb]"));
  let r = await sendShared(w, "Could Needs you show the oldest first?");
  ok("Office: the box names the tab, Send lights up only with words, and it says thanks", r.where === "Operations" && r.wasOff && r.nowOn && /Thanks — sent to the office/.test(r.said), JSON.stringify(r));
  f = (await rows()).pop();
  ok("Saved as Luke, from the office, with the office's version", f.person_name === "Luke H" && f.page === "office" && f.screen === "Operations" && f.page_version === OFFICE_V, JSON.stringify({ n: f.person_name, p: f.page, s: f.screen, v: f.page_version }));
  await wait(2700);
  ok("The thanks closes itself", !$(w, "#sf-fb"));
  $(w, "[data-menu]").click(); await wait(100);
  ok("The ☰ menu lists Feedback", !!$(w, '.menu [data-tab="feedback"]'));
  await click(w, '.menu [data-tab="feedback"]', 800);
  await until(() => /Could Needs you show the oldest first/.test(txt(w)));
  const lines = $$(w, "main .panel .line");
  const shown = lines.map(l => l.textContent.replace(/\s+/g, " "));
  ok("The Feedback list shows every note, newest first", lines.length === 4 && /Could Needs you/.test(shown[0]) && /hard to hit with gloves/.test(shown[3]), shown.map(s => s.slice(0, 40)).join(" | "));
  ok("Each note shows who, when, the note, the page, the screen and the version",
     /Mike B · .*The \+ button is hard to hit with gloves on\. Tablets & phone · Sanding › Work orders › PROJ-00418 › sheet \d+ · version /.test(shown[3]) && shown[3].includes("version " + TABLET_V), shown[3]);
  ok("A test note is labelled TEST", shown.some(s => /TEST\s*Test Supervisor|TEST .*Practice note/.test(s)));
  await click(w, '[data-fbkpage="office"]', 200);
  ok("Filtering by page shows just that page's notes", $$(w, "main .panel .line").length === 1 && /Could Needs you/.test(txt(w, "main .panel")));
  await click(w, "[data-fbkcopy]", 300);
  ok("Copy puts the shown notes on the clipboard as plain text, and says so",
     t.copied.length === 1 && /— Luke H — Office: Operations\nCould Needs you show the oldest first\?/.test(t.copied[0]) && /Copied\. Paste it into a chat/.test(txt(w)), JSON.stringify(t.copied[0]));
  await click(w, '[data-fbkpage=""]', 200);
  $(w, "[data-menu]").click(); await wait(100); await click(w, '.menu [data-tab="setup"]', 300);
  ok("Setup and the other office screens open as before", /Setup/.test(txt(w, "main h1")));
  w.close();

  // ---- 6. deliveries, inventory, pace, upload ----
  for (const [page, key, name] of [["delivery.html", "delivery", "Deliveries"], ["inventory.html", "inventory", "Inventory"], ["pace.html", "pace", "Pace"], ["upload.html", "upload", "Work order upload"]]) {
    t = boot(page, users.luke); w = t.w;
    await until(() => $(w, "header [data-sffb]"), 8000); await wait(600);
    ok(`${name}: the header has a Feedback button`, !!$(w, "header [data-sffb]"));
    r = await sendShared(w, `A note from ${key}`);
    f = (await rows()).pop();
    ok(`${name}: it says thanks and keeps who, the page and the screen`, /Thanks/.test(r.said) && f.body === `A note from ${key}` && f.page === key && f.person_name === "Luke H" && f.screen && f.screen.startsWith(name) && f.page_version === (key === "delivery" ? "2026-10-05.2" : "2026-10-05.1"),
       JSON.stringify({ said: r.said, where: r.where, page: f.page, v: f.page_version }));
    w.close();
  }

  // ---- 7. offline on an office page: the note stays in the box ----
  t = boot("pace.html", users.luke); w = t.w;
  await until(() => $(w, "header [data-sffb]"), 8000); await wait(600);
  setOffline(true);
  r = await sendShared(w, "Offline pace note");
  setOffline(false);
  ok("An office page with no connection says so and keeps the note in the box", /No connection\. Your note is still here/.test(r.said) && $(w, "#sf-fb textarea").value === "Offline pace note");
  await click(w, "#sf-fb [data-sffbsend]", 50); await until(() => /Thanks/.test(txt(w, "#sf-fb")));
  ok("…and Send again works, once", (await rows()).filter(x => x.body === "Offline pace note").length === 1);
  w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
