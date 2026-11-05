// 4 Nov: Export counts on the office Inventory page (inventory.html 2026-11-04.2); 5 Nov: lumber one row per bundle (2026-11-05.2). One month's counts as a CSV, every
// list as counted. Part 1, no database: the file's logic from the page itself (which lists go in, steel's note, lumber's
// "count not finished", the file name, the cells). Part 2, real Chromium through the real test database as each login:
// counts sent the real way (Willie, Eric, KP, Luke), the download's name and every line that matters, the 31 Aug starting
// count against the spec (36,440 bd ft of lumber, 207 sheets of plywood), a month with nothing in it, inside the office
// frame, phone width, and a supervisor who gets no export.
//   bash /home/claude/sf/base/fresh.sh
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis OUT=/tmp/allpages node test_inv_export.js
const fs = require("fs"), http = require("http"), path = require("path");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
const pageFile = [path.join(OUT, "inventory.html"), path.join(REPO, "inventory.html")].find(f => fs.existsSync(f));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

// ---------------- part 1: the page's own export code ----------------
const html = fs.readFileSync(pageFile, "utf8");
const script = html.split("<script>").slice(-1)[0].split("</script>")[0];
const mod = { exports: {} };
new Function("module", "document", script)(mod, undefined);
const X = mod.exports;
ok("the page has the export (exportRows, exportCsv, exportName)", typeof X.exportRows === "function" && typeof X.exportCsv === "function" && typeof X.exportName === "function");
if (typeof X.exportRows !== "function") { console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(1); }
const ver = (html.match(/var PAGE_VERSION = "([^"]+)"/) || [])[1];
ok("inventory.html's version was bumped", ver && ver > "2026-11-04.2", ver);

for (const [v, want] of [["-2 legs", "'-2 legs"], ["=SUM(A1)", "'=SUM(A1)"], ["Bolts, 1/4", "\"Bolts, 1/4\""], [-3, "-3"], [12.5, "12.5"], [null, ""], ["Say \"hi\"", "\"Say \"\"hi\"\"\""]])
  ok(`a cell: ${JSON.stringify(v)} → ${JSON.stringify(want)}`, X.csvCell(v) === want, JSON.stringify(X.csvCell(v)));
ok("file name: a closed month", X.exportName({ month_end: "2026-10-31", kind: "count", status: "closed" }) === "inventory-counts-2026-10.csv");
ok("file name: an open month says not closed", X.exportName({ month_end: "2026-11-30", kind: "count", status: "open" }) === "inventory-counts-2026-11-not-closed.csv");
ok("file name: the starting count", X.exportName({ month_end: "2026-08-31", kind: "starting", status: "closed" }) === "inventory-counts-2026-08-starting.csv");
ok("a time in shop time (EDT)", X.shopTime("2026-10-31T19:12:00Z") === "2026-10-31 3:12 PM", X.shopTime("2026-10-31T19:12:00Z"));
ok("a time in shop time (EST, after the clocks change)", X.shopTime("2026-11-30T14:05:00Z") === "2026-11-30 9:05 AM", X.shopTime("2026-11-30T14:05:00Z"));

const lists = [{ key: "other", name: "Other", sort_order: 5 }, { key: "lumber", name: "Lumber", sort_order: 1 }, { key: "plywood", name: "Plywood", sort_order: 2 },
               { key: "metal", name: "Metal", sort_order: 3 }, { key: "finish", name: "Finish", sort_order: 4 }];
const items = [
  { id: "m1", list_key: "metal", section: "Square tube", name: "1x1 16ga", unit: "ft", std_length_ft: 24, sort_order: 2 },
  { id: "m2", list_key: "metal", section: "Hardware", name: "Leveler feet", unit: "each", std_length_ft: null, sort_order: 1 },
  { id: "p1", list_key: "plywood", section: "Birch", name: "3/4 Birch ply", unit: "sheets", std_length_ft: null, sort_order: 1 },
  { id: "o1", list_key: "other", section: "", name: "=Glue", unit: "each", std_length_ft: null, sort_order: 1 },
  { id: "w1", list_key: "lumber", section: "", name: "Walnut 8/4", species: "Walnut", stock: "8/4", unit: "bd ft", std_length_ft: null },
  { id: "k1", list_key: "lumber", section: "", name: "Maple 6/4", species: "Maple", stock: "6/4", unit: "bd ft", std_length_ft: null },
];
const M = "2026-10-31";
const d = {
  month: { month_end: M, kind: "count", status: "closed", lumber_done_by: "Luke H", lumber_done_at: "2026-10-31T20:00:00Z" },
  lists, items,
  counts: [{ month_end: M, item_id: "m1", qty: 292, sticks: 12, loose_ft: 4, counted_by_name: "Willie" }, { month_end: M, item_id: "m2", qty: 0, sticks: null, loose_ft: null, counted_by_name: "Willie" },
           { month_end: M, item_id: "p1", qty: 42, counted_by_name: "Eric" }, { month_end: M, item_id: "o1", qty: 3, counted_by_name: "KP" }],
  sends: [{ id: 1, list_key: "metal", month_end: M, sent_by_name: "Willie", sent_at: "2026-10-31T17:40:00Z" },
          { id: 2, list_key: "plywood", month_end: M, sent_by_name: "Eric", sent_at: "2026-10-31T18:00:00Z", withdrawn_at: "2026-10-31T18:30:00Z" },
          { id: 3, list_key: "other", month_end: M, sent_by_name: "KP", sent_at: "2026-10-31T15:00:00Z", withdrawn_at: "2026-10-31T15:10:00Z" },
          { id: 4, list_key: "other", month_end: M, sent_by_name: "Luke H", sent_at: "2026-10-31T16:00:00Z" }],
  lumberLines: [
    { month_end: M, item_id: "k1", length_in: 120, width_in: 42, bundles: [10.25, 9] },      // 120 × 42 × 10.25 × 1.5 ÷ 144 = 538.13; × 9 = 472.5
    { month_end: M, item_id: "k1", length_in: 96, width_in: 42, bundles: [] },               // a length added, nothing counted
    { month_end: M, item_id: "w1", length_in: 96, width_in: 42, bundles: [4] },              // 96 × 42 × 4 × 2 ÷ 144 = 224
    { month_end: "2026-09-30", item_id: "w1", length_in: 96, width_in: 42, bundles: [99] },   // another month
  ],
};
const rows = X.exportRows(d), names = rows.map(r => r[3]);
ok("lists in list order: Lumber, then Metal, then Other", rows.map(r => r[1]).join() === "Lumber,Lumber,Lumber,Metal,Metal,Other", rows.map(r => r[1]).join());
ok("the header has the four bundle columns on the end", X.EXPORT_HEAD.slice(-4).join() === "Length (in),Width (in),Bundle,Rows");
ok("lumber: one row per bundle, its board feet to two decimals, its length, width, number and rows", JSON.stringify(rows[0]) === JSON.stringify(["2026-10", "Lumber", "Maple", "Maple 6/4", 538.13, "bd ft", "", "Luke H", "2026-10-31 4:00 PM", 120, 42, 1, 10.25]), JSON.stringify(rows[0]));
ok("…the second bundle of the same length", JSON.stringify(rows[1].slice(3)) === JSON.stringify(["Maple 6/4", 472.5, "bd ft", "", "Luke H", "2026-10-31 4:00 PM", 120, 42, 2, 9]), JSON.stringify(rows[1]));
ok("…species and thickness in name order, lengths in order; a length with no bundles and another month's lines left out", rows.filter(r => r[1] === "Lumber").map(r => r[3] + " " + r[9]).join() === "Maple 6/4 120,Maple 6/4 120,Walnut 8/4 96");
ok("…a sum of Count still gives the species and thickness's total", Math.abs(rows.filter(r => r[3] === "Maple 6/4").reduce((a, r) => a + r[4], 0) - 1010.63) < 0.01);
ok("other lists leave the four bundle columns blank", rows.filter(r => r[1] !== "Lumber").every(r => r.length === 13 && r.slice(9).every(c => c === "")));
ok("items in their list's order (Leveler feet before 1x1)", names.indexOf("Leveler feet") < names.indexOf("1x1 16ga"));
ok("steel: feet, with sticks + loose feet as counted in the note", JSON.stringify(rows.find(r => r[3] === "1x1 16ga").slice(0, 9)) === JSON.stringify(["2026-10", "Metal", "Square tube", "1x1 16ga", 292, "ft", "12 sticks + 4 ft", "Willie", "2026-10-31 1:40 PM"]));
ok("a blank sent as 0 shows as 0", rows.find(r => r[3] === "Leveler feet")[4] === 0);
ok("a count taken back and not sent again is left out (Plywood)", !rows.some(r => r[1] === "Plywood"));
ok("a list not counted is left out (Finish)", !rows.some(r => r[1] === "Finish"));
ok("taken back and sent again: the latest send's name and time", JSON.stringify(rows.find(r => r[1] === "Other").slice(7, 9)) === JSON.stringify(["Luke H", "2026-10-31 12:00 PM"]));
const csv = X.exportCsv(rows);
ok("the file: a byte-order mark, the header, Windows line ends", csv.startsWith("\ufeffMonth,List,Group,Item,Count,Unit,Note,Sent by,Sent,Length (in),Width (in),Bundle,Rows\r\n") && csv.endsWith("\r\n") && !/[^\r]\n/.test(csv));
ok("a name starting with = opens as text in Excel", csv.includes(",'=Glue,"));
const open = X.exportRows({ ...d, month: { month_end: M, kind: "count", status: "open" } });
ok("an open month's lumber not marked done says count not finished, no sender", open[0][6] === "count not finished" && open[0][7] === "" && open[0][8] === "");
const start = X.exportRows({ ...d, month: { month_end: M, kind: "starting", status: "closed" }, sends: [],
  lumberLines: [{ month_end: M, item_id: "k1", length_in: 120, width_in: 42, bundles: [5], updated_by_name: "From the 31 Aug 2026 workbook", updated_at: "2026-09-25T10:00:00Z" }] });
ok("the starting count: every list in with no sends, named by where it came from", start.some(r => r[1] === "Plywood" && r[7] === "Eric") && start[0][7] === "From the 31 Aug 2026 workbook" && start[0][6] === "");
ok("a month with nothing in it gives no rows", X.exportRows({ month: { month_end: "2026-12-31", kind: "count", status: "open" }, lists, items, counts: [], sends: [], lumberLines: [] }).length === 0);

// ---------------- part 2: Chromium, the real database ----------------
(async () => {
  const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
  const { makeClient, users, admin } = require("./pgsupa");
  const FAKE = (user) => `window.supabase = { createClient: () => {
    const call = (m) => window.__sb(m);
    const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
        if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
        if (typeof k === "symbol") return undefined;
        return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
    let session = { user: ${JSON.stringify(user)} };
    return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => ({}), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                     signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
      from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
      storage: { from: () => ({ download: async () => ({ data: null, error: { message: "not in this test" } }), createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
  } };`;
  const server = http.createServer((req, res) => {
    let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/office.html";
    const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    if (!file) { res.writeHead(404); return res.end(); }
    let body = fs.readFileSync(file);
    if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
    res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "text/css" });
    res.end(body);
  });
  let offline = false;
  async function session(browser, user, viewport) {
    const client = makeClient(user);
    const ctx = await browser.newContext({ viewport: viewport || { width: 1366, height: 860 }, serviceWorkers: "block", acceptDownloads: true });
    await ctx.addInitScript(() => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true })); });
    await ctx.exposeBinding("__sb", async (_, m) => {
      if (offline) return { data: null, error: { message: "TypeError: Failed to fetch" } };
      if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
      let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
      return JSON.parse(JSON.stringify(await b));
    });
    await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
    await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
    await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
    const p = await ctx.newPage(); const errs = [];
    p.on("pageerror", e => errs.push(e.message));
    p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
    return { ctx, p, errs };
  }
  const q = async (s, a) => (await admin.query(s, a)).rows;
  const rpcAs = async (who, fn, args) => { const r = await makeClient(users[who]).rpc(fn, args); if (r.error) throw new Error(`${who} ${fn}: ${r.error.message}`); return r.data; };
  const read = async (dl) => fs.readFileSync(await dl.path(), "utf8");
  const parse = (text) => text.replace(/^\ufeff/, "").trim().split("\r\n").map(l => { const out = []; let cur = "", inq = false;
    for (let i = 0; i < l.length; i++) { const ch = l[i]; if (inq) { if (ch === '"' && l[i + 1] === '"') { cur += '"'; i++; } else if (ch === '"') inq = false; else cur += ch; }
      else if (ch === '"') inq = true; else if (ch === ",") { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out; });

  try {
    await new Promise(r => server.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${server.address().port}/shop-floor`;
    const [{ m: openMonth }] = await q("select inv_current_month()::text as m");
    const ym = openMonth.slice(0, 7);
    // counts sent the way the floor sends them
    const metal = await q("select id, name, std_length_ft from inv_items where list_key = 'metal' and not retired order by std_length_ft is null, sort_order, name");
    const steel = metal.find(i => i.std_length_ft), each = metal.find(i => !i.std_length_ft);
    await rpcAs("willie", "send_inventory_count", { p_list: "metal", p_counts: [{ item_id: steel.id, sticks: 12, loose_ft: 4 }, { item_id: each.id, qty: 30 }] });
    const ply = await q("select id from inv_items where list_key = 'plywood' and not retired order by sort_order, name limit 1");
    await rpcAs("eric", "send_inventory_count", { p_list: "plywood", p_counts: [{ item_id: ply[0].id, qty: 7 }] });
    await rpcAs("luke", "reopen_inventory_count", { p_list: "plywood" });             // taken back, not sent again
    const lum = await q("select id, name from inv_items where list_key = 'lumber' and not retired order by name limit 1");
    await rpcAs("luke", "set_lumber_line", { p_item: lum[0].id, p_length: 96, p_bundles: [10, 7.75], p_width: 42 });
    const stockS = (await q("select inv_stock_in(stock) as s from inv_items where id = $1", [lum[0].id]))[0].s;
    const lumBf = Math.round(96 * 42 * 10 * stockS / 144 * 100) / 100, lumBf2 = Math.round(96 * 42 * 7.75 * stockS / 144 * 100) / 100;

    const browser = await chromium.launch();
    // ---- Luke on the Inventory page ----
    let s = await session(browser, users.luke), p = s.p;
    await p.goto(`${base}/inventory.html`);
    await p.waitForSelector("nav.tabs [data-tab]", { timeout: 15000 });
    await p.click('[data-tab="month"]');
    await p.waitForSelector("[data-export]", { timeout: 5000 }).catch(() => {});
    ok("This month has an Export counts section", !!(await p.$("[data-export]")) && (await p.textContent("main")).includes("Export counts"));
    const opts = await p.$$eval("#xm option", os => os.map(o => [o.value, o.textContent.trim(), o.selected]));
    ok("the months: the open one (not closed) and the starting count", opts.some(o => o[0] === openMonth && /not closed/.test(o[1])) && opts.some(o => o[0] === "2026-08-31" && /starting count/.test(o[1])), JSON.stringify(opts));
    ok("newest month first, and picked to start with once something is counted", opts[0][0] === openMonth && opts[0][2]);

    let [dl] = await Promise.all([p.waitForEvent("download", { timeout: 15000 }), p.click("[data-export]")]);
    ok("the download's name says the month isn't closed", dl.suggestedFilename() === `inventory-counts-${ym}-not-closed.csv`, dl.suggestedFilename());
    let text = await read(dl), t = parse(text);
    ok("the file starts with a byte-order mark and the header", text.startsWith("\ufeffMonth,List,Group,Item,Count,Unit,Note,Sent by,Sent,Length (in),Width (in),Bundle,Rows\r\n"));
    const st = t.find(r => r[3] === steel.name);
    ok("Willie's steel: feet, with 12 sticks + 4 ft in the note, sent by Willie", st && Number(st[4]) === 12 * Number(steel.std_length_ft) + 4 && st[5] === "ft" && st[6] === "12 sticks + 4 ft" && /Willie/.test(st[7]) && /^\d{4}-\d\d-\d\d \d{1,2}:\d\d (AM|PM)$/.test(st[8]), JSON.stringify(st));
    ok("Willie's blanks are 0, one row per item on the list", t.filter(r => r[1] === "Metal").length === metal.length && t.filter(r => r[1] === "Metal" && r[4] === "0").length === metal.length - 2);
    ok("Plywood, taken back and not sent again, isn't in the file", !t.some(r => r[1] === "Plywood"));
    ok("lists not sent aren't in the file (Finish, Other)", !t.some(r => r[1] === "Finish" || r[1] === "Other"));
    const lr = t.filter(r => r[1] === "Lumber" && r[3] === lum[0].name);
    ok("lumber typed on the page: one row per bundle, board feet, length, width, bundle, rows (¾ as .75), marked count not finished",
       lr.length === 2 && Number(lr[0][4]) === lumBf && lr[0].slice(9).join() === "96,42,1,10" && Number(lr[1][4]) === lumBf2 && lr[1].slice(9).join() === "96,42,2,7.75"
       && lr.every(r => r[5] === "bd ft" && r[6] === "count not finished"), JSON.stringify(lr) + ` want ${lumBf}, ${lumBf2}`);
    ok("no prices or values anywhere in the file", !/\$|price|value|1201|1204/i.test(text));
    ok("the page says what it exported", /Exported inventory-counts-.*-not-closed\.csv — \d+ rows\./.test(await p.textContent("main")));

    // the starting count against the spec's numbers
    await p.selectOption("#xm", "2026-08-31");
    [dl] = await Promise.all([p.waitForEvent("download", { timeout: 15000 }), p.click("[data-export]")]);
    ok("31 Aug: inventory-counts-2026-08-starting.csv", dl.suggestedFilename() === "inventory-counts-2026-08-starting.csv", dl.suggestedFilename());
    t = parse(await read(dl));
    const sum = (k) => t.filter(r => r[1] === k).reduce((a, r) => a + Number(r[4]), 0);
    const [{ n: startRows }] = await q("select (select count(*) from inv_counts where month_end = '2026-08-31') + (select coalesce(sum(cardinality(bundles)), 0) from inv_lumber_lines where month_end = '2026-08-31') as n");
    ok("31 Aug: one row per item counted, and per bundle for lumber (every list, no sends needed)", t.length - 1 === Number(startRows), `${t.length - 1} vs ${startRows}`);
    const perItem = {}; for (const r of t.filter(r => r[1] === "Lumber")) perItem[r[3]] = (perItem[r[3]] || 0) + Number(r[4]);
    const closeRows = await q("select name, board_feet::float as bf from v_inv_lumber_close where month_end = '2026-08-31'");
    ok("31 Aug: each species and thickness's bundles add up to the database's own total (within rounding)", closeRows.every(c => Math.abs((perItem[c.name] || 0) - c.bf) < 0.05) && Object.keys(perItem).length === closeRows.length,
       closeRows.filter(c => Math.abs((perItem[c.name] || 0) - c.bf) >= 0.05).map(c => `${c.name} ${perItem[c.name]} vs ${c.bf}`).join("; "));
    ok("31 Aug: the workbook's lumber is one bundle per length", t.filter(r => r[1] === "Lumber").every(r => r[11] === "1" && Number(r[9]) > 0 && Number(r[12]) > 0));
    ok("31 Aug: lumber adds up to the spec's 36,440 bd ft", Math.round(sum("Lumber")) === 36440, sum("Lumber"));
    ok("31 Aug: plywood adds up to the spec's 207 sheets", sum("Plywood") === 207, sum("Plywood"));
    ok("31 Aug: named by where it came from", t.slice(1).every(r => /workbook/i.test(r[7])), JSON.stringify(t[1]));
    ok("31 Aug: every line has all 13 columns", t.every(r => r.length === 13));
    ok("31 Aug: the month column", t.slice(1).every(r => r[0] === "2026-08"));

    // a month with nothing in it
    await admin.query("insert into inv_months (month_end, kind, status) values ('2026-07-31', 'count', 'open') on conflict do nothing");
    await p.reload(); await p.waitForSelector("[data-export]");
    await p.selectOption("#xm", "2026-07-31");
    let fired = false; p.once("download", () => { fired = true; });
    await p.click("[data-export]"); await p.waitForTimeout(1500);
    ok("a month with nothing counted: no file, and the page says so", !fired && /Nothing has been counted for July 2026 yet/.test(await p.textContent("main")));
    await admin.query("delete from inv_months where month_end = '2026-07-31'");

    // no connection
    offline = true; await p.selectOption("#xm", openMonth).catch(() => {});
    fired = false; p.once("download", () => { fired = true; });
    await p.click("[data-export]"); await p.waitForTimeout(1500);
    ok("no connection: no file, and the page says to try again", !fired && /Can't reach the database right now, so nothing was exported/.test(await p.textContent("main")));
    ok("…and the button is back", await p.$eval("[data-export]", b => !b.disabled && b.textContent.trim() === "Export counts"));
    offline = false;
    ok("Inventory page: no errors", s.errs.length === 0, s.errs.join(" | "));

    // phone width
    await p.setViewportSize({ width: 390, height: 800 }); await p.reload(); await p.waitForSelector("[data-export]");
    ok("phone width: no sideways scroll", await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
    await s.ctx.close();

    // ---- inside the office, the way Luke opens it ----
    s = await session(browser, users.luke); p = s.p;
    await p.goto(`${base}/office.html#inventory`);
    let fr = null; for (let i = 0; i < 40 && !fr; i++) { fr = p.frames().find(f => f.url().includes("inventory.html")); if (!fr) await p.waitForTimeout(250); }
    ok("the office opens Inventory in its frame", !!fr);
    if (fr) {
      await fr.waitForSelector("nav.tabs [data-tab]", { timeout: 15000 }); await fr.click('[data-tab="month"]'); await fr.waitForSelector("[data-export]");
      [dl] = await Promise.all([p.waitForEvent("download", { timeout: 15000 }), fr.click("[data-export]")]);
      ok("inside the office: the download still arrives", dl.suggestedFilename() === `inventory-counts-${ym}-not-closed.csv`, dl.suggestedFilename());
    }
    ok("office: no errors", s.errs.length === 0, s.errs.join(" | "));
    await s.ctx.close();

    // ---- a supervisor ----
    s = await session(browser, users.willie); p = s.p;
    await p.goto(`${base}/inventory.html`); await p.waitForSelector("main"); await p.waitForTimeout(800);
    ok("Willie: For managers, no export", /For managers/.test(await p.textContent("#app")) && !(await p.$("[data-export]")));
    const wc = makeClient(users.willie);
    const r1 = await wc.from("inv_counts").select("item_id").eq("month_end", "2026-08-31");
    const metalIds = new Set((await q("select id from inv_items where list_key = 'metal'")).map(r => r.id));
    const [{ n: allMetal }] = await q("select count(*) as n from inv_counts c join inv_items i on i.id = c.item_id where c.month_end = '2026-08-31' and i.list_key = 'metal'");
    ok("the database, not the page, keeps other lists from Willie: he reads only Metal's counts", !r1.error && r1.data.length === Number(allMetal) && r1.data.every(r => metalIds.has(r.item_id)), `${(r1.data || []).length} rows`);
    const r2 = await wc.from("inv_lumber_lines").select("id").limit(5);
    ok("…and no lumber lines", !r2.error && r2.data.length === 0);
    await s.ctx.close();
    await browser.close();
  } catch (e) { ok("the run finished", false, e.stack); }
  server.close(); await admin.end().catch(() => {});
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})();
