// 17 Nov (partial_sends.sql, index.html 2026-11-17.1): Full Custom sends the pieces it has finished.
// A Full Custom sheet of 80 (made here on PROJ-00501). Eric counts 12: his sheet offers Send 12 to Sanding and
// Send 12 straight to Finishing; he sends 12 to Sanding, and Mike's Sanding sees 12 ready. He counts to 30: one button,
// Send 18 more to Sanding. With no signal the send waits on the tablet and goes when the connection is back.
// Undo takes back the last send (back to 12). The job page's bar sends the rest the same way. At 80 the last send
// sends the sheet in full, shown as before. Then the page now on the floor against the new database, and (OLDDB=1)
// the new page against the database without partial_sends.sql: both exactly as before.
// Run on a seeded copy of the NEW database:
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh && TZ=America/Indiana/Indianapolis node test_partial_sends.js
// OLDDB=1 on a seeded copy of the OLD database. LIVEPAGE= the page now on the floor (run_all passes the repo's).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users, admin, setOffline } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const NEW = strip(fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8"));
const LIVE = strip(fs.readFileSync(process.env.LIVEPAGE || "/home/claude/sf/repo/index.html", "utf8"));
const OLDDB = !!process.env.OLDDB;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 8000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(40); } return false; }

function boot(html, user, dept) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  if (dept) { w.localStorage.setItem("sf_dept", JSON.stringify(dept)); w.localStorage.setItem("sf_tab", JSON.stringify("queue")); }
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return { w, client };
}
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
const app = (w) => $(w, "#app").textContent.replace(/\s+/g, " ");
const btn = (w, re) => $$(w, "#app button").find(b => re.test(b.textContent.replace(/\s+/g, " ").trim()));
async function click(w, el, pause = 150) { if (!el) throw new Error("nothing to click"); el.click(); await wait(pause); }
const settled = async (w) => { await until(() => /PROJ-|Nothing waiting/.test(app(w))); await wait(600); };
async function openSheet(w, code) {
  await click(w, $$(w, "button.qrow").find(b => /PROJ-00501/.test(b.textContent)) || btn(w, /PROJ-00501/));
  await until(() => btn(w, new RegExp(code)));
  await click(w, btn(w, new RegExp(code)), 400);
}
const q = async (sql) => (await admin.query(sql)).rows;
// close a window only once nothing waits to send and its render has settled (README §7)
async function close(w) { await until(() => !/waiting to send/.test(app(w)) && Object.keys(JSON.parse(w.localStorage.getItem("sf_logbox") || "{}")).length === 0); await wait(600); w.close(); }

(async () => {
  const hasFile = (await q("select count(*)::int n from information_schema.columns where table_name = 'sheet_sends' and column_name = 'qty_sent'"))[0].n === 1;
  console.log(hasFile ? "(new database: partial_sends.sql)" : "(old database: no partial_sends.sql)");
  // 17 Nov (README §8, after a release is on GitHub): once partial_sends.sql is live the kit's old database has it too, so
  // this mode can't be shown any more. It skips itself then, and says why; never left to fail.
  if (OLDDB && hasFile) {
    console.log("SKIP  The new page on a database without partial_sends.sql, exactly as before: partial_sends.sql is live, so the old database has it too (shown passing 17 Nov, before it went live)");
    console.log(`\n0 PASS, 0 FAIL, 1 SKIP`); process.exit(0);
  }
  if (OLDDB === hasFile) { console.log("Wrong database for this mode."); process.exit(1); }

  // two Full Custom sheets on PROJ-00501: 80 of one item (cabinet, no top), and 4 for the old page
  const [{ wo }] = await q("select w.id wo from work_orders w join jobs j on j.id = w.job_id where j.project_id = 'PROJ-00501' and w.is_current");
  const mk = async (no, qty, code) => {
    const [{ id }] = await q(`insert into sheets (work_order_id, sheet_number, qty, item_code, spec_hash) values ('${wo}', ${no}, ${qty}, '${code}', 'h${code}') returning id`);
    await q(`insert into sheet_progress (sheet_id, department, qty_required, qty_done) values ('${id}', 'full_custom', ${qty}, 0), ('${id}', 'finishing', ${qty}, 0), ('${id}', 'assembly_qc', ${qty}, 0)`);
    const [{ pid }] = await q(`select id pid from sheet_progress where sheet_id = '${id}' and department = 'full_custom'`);
    return { sheet: id, pid };
  };
  const A = await mk(9, 80, "FC-80"), B = await mk(10, 4, "FC-4");
  const eric = makeClient(users.eric);
  const count = async (pid, n) => { const r = await eric.rpc("set_count", { p_progress: pid, p_qty: n }); if (r.error) console.log("count:", r.error.message); };
  const sends = async (sheet) => q(`select ${hasFile ? "qty_sent" : "null::int qty_sent"}, route, undone_at is not null undone from sheet_sends where sheet_id = '${sheet}' order by sent_at`);

  if (OLDDB) {
    // the new page on the database without the file: as before
    await count(A.pid, 12);
    let e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-80");
    ok("Old database: 12 of 80 counted, no send button (as before)", !$(e.w, "[data-send], [data-sendpart]") && /12\s?of 80 done/.test(app(e.w)), app(e.w).slice(0, 200));
    await close(e.w);
    await count(B.pid, 4);
    e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-4");
    ok("Old database: a finished sheet asks where it goes, as before", /Done — where does it go next\?/.test(app(e.w)) && !!$(e.w, '[data-send="sanding"]') && !$(e.w, "[data-sendpart]"));
    await click(e.w, $(e.w, '[data-send="sanding"]'), 300);
    ok("Old database: the whole-sheet send goes, and the sheet says Sent to Sanding", await until(async () => (await sends(B.sheet)).length === 1) && await until(() => /Sent to Sanding/.test(app(e.w))));
    ok("Old database: the page sent it with send_sheet (send_pieces isn't there)", e.client.rpcs.some(([fn]) => fn === "send_sheet") && !e.client.rpcs.some(([fn]) => fn === "send_pieces"));
    await close(e.w);
    console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
  }

  // ---- Eric counts 12 of 80 ----
  await count(A.pid, 12);
  let e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-80");
  ok("12 of 80 counted: the sheet asks whether to send them on now", /12 of 80 done\. Send them on now, or keep going\./.test(app(e.w)), app(e.w).slice(0, 300));
  ok("Two buttons: Send 12 to Sanding and Send 12 straight to Finishing",
     $$(e.w, "[data-sendpart]").map(b => b.textContent.trim()).join("|") === "Send 12 to Sanding|Send 12 straight to Finishing",
     $$(e.w, "[data-sendpart]").map(b => b.textContent.trim()).join("|"));
  await click(e.w, btn(e.w, /^Send 12 to Sanding$/), 300);
  ok("Send 12 to Sanding: the database has one send of 12 to Sanding", await until(async () => { const s = await sends(A.sheet); return s.length === 1 && s[0].qty_sent === 12 && s[0].route === "sanding"; }));
  ok("It went through send_pieces with the count itself (12), not an increment",
     e.client.rpcs.some(([fn, a]) => fn === "send_pieces" && a.p_qty === 12 && a.p_route === "sanding"));
  ok("The sheet then reads Sent 12 of 80 to Sanding, with Undo, and no send button",
     await until(() => /Sent 12 of 80 to Sanding/.test(app(e.w)) && !!$(e.w, "[data-unsend][data-unsendpart]") && !$(e.w, "[data-sendpart]")), app(e.w).slice(0, 300));
  ok("…and says to count more to send them on", /Count more done to send them on\./.test(app(e.w)));
  await close(e.w);

  // ---- Mike's Sanding sees 12 ready ----
  const mike = makeClient(users.mike);
  const rd = await mike.from("v_ready_to_work").select("*").eq("sheet_id", A.sheet).eq("department", "sanding");
  ok("Mike's Sanding has 12 ready on the sheet (the database, through his login)", rd.data && rd.data[0] && rd.data[0].ready === 12, JSON.stringify(rd.data || rd.error));
  const m = boot(NEW, users.mike, "sanding"); await settled(m.w);
  const card = $$(m.w, "button.qrow").find(b => /PROJ-00501/.test(b.textContent));
  ok("PROJ-00501 is on Mike's Sanding Ready list", !!card, app(m.w).slice(0, 300));
  if (card) { await click(m.w, card, 400); ok("Its job page shows the sheet with 12 ready", /FC-80[^]*?12 ready/.test(app(m.w)), app(m.w).slice(0, 400)); }
  await close(m.w);

  // ---- Eric counts to 30: one button, Send 18 more to Sanding; with no signal it waits ----
  await count(A.pid, 30);
  e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-80");
  ok("30 counted, 12 sent: one button, Send 18 more to Sanding",
     $$(e.w, "[data-sendpart]").map(b => b.textContent.trim()).join("|") === "Send 18 more to Sanding" && /18 more done, not sent yet\./.test(app(e.w)),
     $$(e.w, "[data-sendpart]").map(b => b.textContent.trim()).join("|"));
  setOffline(true);
  await click(e.w, btn(e.w, /^Send 18 more to Sanding$/), 500);
  const box = JSON.parse(e.w.localStorage.getItem("sf_logbox") || "{}");
  ok("No signal: the send waits on the tablet (30 in all) and the sheet shows it, waiting to send",
     Object.values(box).some(x => x.fn === "send_pieces" && x.args.p_qty === 30) && /Sent 30 of 80 to Sanding[^]*waiting to send/.test(app(e.w)), app(e.w).slice(0, 300));
  ok("…and nothing reached the database yet", (await sends(A.sheet)).length === 1);
  setOffline(false); e.w.dispatchEvent(new e.w.Event("online"));
  ok("Back online: it goes, and the database has 30 sent", await until(async () => (await sends(A.sheet)).filter(s => !s.undone).map(s => s.qty_sent).join(",") === "12,30"));

  // ---- Undo the last send ----
  ok("Undo is offered on the newest send", await until(() => !!$(e.w, "[data-unsend][data-unsendpart]") && /Sent 30 of 80/.test(app(e.w))), app(e.w).slice(0, 300));
  await click(e.w, $(e.w, "[data-unsend][data-unsendpart]"), 200);
  ok("Undo asks first, saying it goes back to what was sent before", /The last send on sheet 9 is taken back, to what was sent before it\./.test(app(e.w)));
  await click(e.w, $(e.w, "[data-confirm]"), 400);
  ok("Undone: the database keeps the send, marked undone, and the sheet reads Sent 12 of 80 with Send 18 more",
     await until(async () => { const s = await sends(A.sheet); return s.length === 2 && s[1].undone && !s[0].undone; })
     && await until(() => /Sent 12 of 80 to Sanding/.test(app(e.w)) && !!btn(e.w, /^Send 18 more to Sanding$/)), app(e.w).slice(0, 300));

  // ---- the job page: its line and the bar ----
  await click(e.w, $(e.w, '[data-back="job"]'), 400);
  ok("The job page's line for the sheet: Sent 12 to Sanding · 18 to send", /Sent 12 to Sanding · 18 to send/.test(app(e.w)), app(e.w).slice(0, 400));
  ok("The bar: 1 sheet with pieces done and not sent, Send it on", /1 sheet with pieces done and not sent/.test(app(e.w)) && !!btn(e.w, /^Send it on$/));
  await click(e.w, btn(e.w, /^Send it on$/), 200);
  ok("The box sends the rest the way the sheet is already going, with no choice of route",
     !!$(e.w, '[data-sendallroute="same"]') && !$(e.w, '[data-sendallroute="finishing"]') && /Sheet 9: 18 to Sanding/.test(app(e.w)), app(e.w).slice(-300));
  await click(e.w, $(e.w, '[data-sendallroute="same"]'), 400);
  ok("…and the database has 30 sent again", await until(async () => (await sends(A.sheet)).filter(s => !s.undone).map(s => s.qty_sent).join(",") === "12,30"));
  await close(e.w);

  // ---- the last pieces: the sheet is sent in full, shown as before ----
  await count(A.pid, 80);
  e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-80");
  await click(e.w, btn(e.w, /^Send 50 more to Sanding$/), 400);
  ok("Sending the last 50 sends the sheet in full (stored as the whole sheet)",
     await until(async () => { const s = (await sends(A.sheet)).filter(x => !x.undone); return s.length === 3 && s[2].qty_sent === null; }));
  ok("…and the sheet shows Sent to Sanding as a whole sheet always has", await until(() => /Sent to Sanding/.test(app(e.w)) && !/Sent \d+ of 80/.test(app(e.w))), app(e.w).slice(0, 300));
  const all = await mike.from("v_ready_to_work").select("*").eq("sheet_id", A.sheet).eq("department", "sanding");
  ok("Mike's Sanding has all 80 ready", all.data && all.data[0] && all.data[0].ready === 80);
  await close(e.w);

  // ---- a sheet not started shows nothing to send ----
  e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-4");
  ok("Nothing counted on a sheet: no send block at all, as before", !$(e.w, "[data-sendpart], [data-send], .sendto, .sent"));
  await close(e.w);

  // ---- the page now on the floor, against the new database ----
  // 17 Nov (README §8): once index.html 2026-11-17.1 is live, "the page now on the floor" IS this page (it already sends
  // pieces), so these lines can't show the page from before. They skip themselves then, and say why.
  let skipped = 0;
  if (/send_pieces/.test(LIVE)) {
    for (const n of ["Page now on the floor, new database: 2 of 4 counted, no send button (as today)", "Page now on the floor: a finished sheet asks where it goes, as today", "…its whole-sheet send goes (send_sheet) and it shows Sent straight to Finishing", "Page now on the floor, sheet partly sent straight to Finishing: Send to Sanding is refused and kept on Couldn't send, with the reason", "…and Send straight to Finishing finishes it"]) {
      console.log(`SKIP  ${n}: the page now on the floor is this release's (index.html 2026-11-17.1 went live 17 Nov; shown passing before it did)`); skipped++;
    }
  } else {
    await count(B.pid, 2);
    let o = boot(LIVE, users.eric, "full_custom"); await settled(o.w); await openSheet(o.w, "FC-4");
    ok("Page now on the floor, new database: 2 of 4 counted, no send button (as today)", !$(o.w, "[data-send]") && /2\s?of 4 done/.test(app(o.w)), app(o.w).slice(0, 300));
    await close(o.w);
    await count(B.pid, 4);
    o = boot(LIVE, users.eric, "full_custom"); await settled(o.w); await openSheet(o.w, "FC-4");
    ok("Page now on the floor: a finished sheet asks where it goes, as today", /Done — where does it go next\?/.test(app(o.w)) && !!$(o.w, '[data-send="finishing"]'));
    await click(o.w, $(o.w, '[data-send="finishing"]'), 300);
    ok("…its whole-sheet send goes (send_sheet) and it shows Sent straight to Finishing",
       await until(async () => { const s = await sends(B.sheet); return s.length === 1 && s[0].qty_sent === null && s[0].route === "finishing"; })
       && await until(() => /Sent straight to Finishing/.test(app(o.w))));
    await close(o.w);
    // and a sheet the new page partly sent, finished from the page now on the floor
    const C = await mk(11, 3, "FC-3");
    await count(C.pid, 1);
    e = boot(NEW, users.eric, "full_custom"); await settled(e.w); await openSheet(e.w, "FC-3");
    await click(e.w, btn(e.w, /^Send 1 straight to Finishing$/), 300);
    await until(async () => (await sends(C.sheet)).length === 1);
    await close(e.w);
    await count(C.pid, 3);
    o = boot(LIVE, users.eric, "full_custom"); await settled(o.w); await openSheet(o.w, "FC-3");
    await click(o.w, $(o.w, '[data-send="sanding"]'), 500);
    await until(() => JSON.parse(o.w.localStorage.getItem("sf_failed") || "[]").length > 0);
    const failed = JSON.parse(o.w.localStorage.getItem("sf_failed") || "[]");
    ok("Page now on the floor, sheet partly sent straight to Finishing: Send to Sanding is refused and kept on Couldn't send, with the reason",
       await until(() => JSON.parse(o.w.localStorage.getItem("sf_failed") || "[]").some(f => /already going straight to Finishing \(1 sent\)/.test(f.reason))),
       JSON.stringify(failed).slice(0, 200));
    await close(o.w);
    o = boot(LIVE, users.eric, "full_custom"); await settled(o.w); await openSheet(o.w, "FC-3");
    await click(o.w, $(o.w, '[data-send="finishing"]'), 300);
    ok("…and Send straight to Finishing finishes it", await until(async () => (await sends(C.sheet)).some(s => s.qty_sent === null && s.route === "finishing")));
    await close(o.w);
  }

  console.log(`\n${pass} PASS, ${fail} FAIL${skipped ? `, ${skipped} SKIP` : ""}`);
  process.exit(fail ? 1 : 0);
})().catch((err) => { console.log("FAIL  the test stopped: " + (err && err.stack || err)); process.exit(1); });
