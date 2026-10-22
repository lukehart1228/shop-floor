// 22 Oct: drawing pictures. Each sheet's LINE DRAWING window, cut by the tablet from its own work order page, beside
// the count on a job's sheets (Work orders and Recently completed) and on the Arrow tab, where each card also gets the
// job's name, the sheet's size, the count in tables and a read-only Work order. The pages are stood in by sheets drawn
// here: orange everywhere except the drawing window, which is one colour per sheet with a black mark in its top-left
// corner and a blue one bottom right. A picture cut from the wrong place shows orange; a mixed-up one, the wrong colour.
// Run on a seeded database:
//   bash /home/claude/sf/base/fresh.sh && cd /home/claude/sf/t && PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_drawing_pictures.js
// PAGE=/home/claude/sf/repo/index.html runs it on the page from before the pictures (2026-10-20.4), where it fails.
const fs = require("fs"), http = require("http"), path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, admin, users } = require("./pgsupa");
const PAGE = process.env.PAGE || "/home/claude/sf/out/index.html";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// the page as the generator makes it: 792 x 612 pt at 180 dpi. The drawing window measured on PROJ-00099 (22 Oct):
// 268 x 195 pt at (483, 136). Worked out here on its own, so a wrong number in the page is caught, not copied.
const PW = 1980, PH = 1530, WIN = { x: Math.round(483 / 792 * PW), y: Math.round(136 / 612 * PH), w: Math.round(268 / 792 * PW), h: Math.round(195 / 612 * PH) };
const colourOf = (p) => { const m = /PROJ-00(\d+)\/v1\/sheet-(\d+)\.png$/.exec(p); return m ? [20 + (Number(m[1]) % 7) * 20, 60 + Number(m[2]) * 18, 30] : [128, 128, 128]; };
const ORANGE = [237, 94, 15];

const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  const blob = (b64, type) => { const s = atob(b64), u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return new Blob([u], { type }); };
  return { auth: { getSession: async () => ({ data: { session: { user: ${JSON.stringify(user)} } } }), signOut: async () => ({}),
                   onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (bucket) => ({
      download: async (path) => { const r = await window.__st(bucket, path); return r.error ? { data: null, error: r.error } : { data: blob(r.b64, r.type), error: null }; },
      createSignedUrl: async () => ({ data: null, error: { message: "not in this test" } }),
      upload: async () => ({ data: null, error: { message: "not in this test" } }) }) } };
} };`;

const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  const file = p === "/index.html" ? PAGE : path.join("/home/claude/sf/repo", p);
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (p === "/index.html") body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  res.end(body);
});

const PAGES = new Map();                 // page path -> base64 PNG, drawn in Chromium below
const MISSING = new Set();               // pages storage doesn't have
const downloads = [];                    // every page asked for: [path, offline?]
async function session(browser, user, viewport = { width: 1280, height: 800 }, ctx = null) {
  const client = makeClient(user); const st = { offline: false };
  ctx = ctx || await browser.newContext({ viewport, serviceWorkers: "block", hasTouch: true });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (st.offline) return { data: null, error: { message: "Failed to fetch" } };
    if (m.kind === "rpc") { const r = await client.rpc(m.fn, m.args || {}); return JSON.parse(JSON.stringify(r)); }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  await ctx.exposeBinding("__st", async (_, bucket, p) => {
    downloads.push([p, st.offline]);
    if (st.offline) return { error: { message: "Failed to fetch" } };
    if (bucket !== "work-orders" || MISSING.has(p) || !PAGES.has(p)) return { error: { message: "Object not found", statusCode: "404" } };
    return { b64: PAGES.get(p), type: "image/png" };
  });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/jsdelivr|unpkg|cdnjs/, r => /supabase-js@2\.45\.4/.test(r.request().url())
    ? r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }) : r.abort());
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  return { ctx, p, st, errs };
}
const loaded = (p) => p.waitForFunction(() => document.querySelector(".subtabs") || document.querySelector(".head"), null, { timeout: 15000 });
const text = (p, sel) => p.evaluate((s) => [...document.querySelectorAll(s)].map(e => e.innerText.replace(/\s+/g, " ").trim()), sel);
// every frame on screen filled in (or given up on), within a few seconds
const settled = (p) => p.waitForFunction(() => { const f = [...document.querySelectorAll("#app [data-snip]")];
  return f.length && f.every(e => e.style.backgroundImage || e.classList.contains("none")); }, null, { timeout: 15000 }).then(() => true, () => false);

// the colours inside a picture on screen: middle, the two corner marks, and a ring 3 pixels in from the edge
async function look(p, how) {
  return p.evaluate(async (how) => {
    const e = how.row ? ([...document.querySelectorAll("#app .sheet")].find(b => (b.querySelector(".no") || {}).innerText.trim() === String(how.row)) || { querySelector: () => null }).querySelector(".snip")
            : how.arrow ? ([...document.querySelectorAll("#app .arpic")].find(b => new RegExp("^Sheet " + how.arrow + " ").test((b.querySelector(".arlab b") || {}).innerText || "")) || { querySelector: () => null }).querySelector(".snip")
            : document.querySelector(how.sel);
    if (!e) return null;
    const m = /url\(["']?(blob:[^"')]+)/.exec(e.style.backgroundImage || ""); if (!m) return null;
    const bmp = await createImageBitmap(await (await fetch(m[1])).blob());
    const c = document.createElement("canvas"); c.width = bmp.width; c.height = bmp.height;
    const g = c.getContext("2d"); g.drawImage(bmp, 0, 0);
    const px = (x, y) => [...g.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const W = bmp.width, H = bmp.height, ring = [];
    for (let k = 0; k <= 20; k++) { const f = k / 20;
      ring.push(px(3 + f * (W - 7), 3), px(3 + f * (W - 7), H - 4), px(3, 3 + f * (H - 7)), px(W - 4, 3 + f * (H - 7))); }
    return { W, H, mid: px(W / 2, H / 2), tl: px(W * 0.02, H * 0.03), br: px(W * 0.98, H * 0.97), ring, css: e.getBoundingClientRect().width };
  }, how);
}
const near = (a, b, t = 8) => a && b && a.every((v, i) => Math.abs(v - b[i]) <= t);
const isOrange = (c) => c[0] > 180 && c[1] < 150 && c[2] < 90;
function judge(name, l, pathOfPage) {
  if (!l) return ok(`${name}: the picture is there`, false, "no picture");
  const want = colourOf(pathOfPage);
  ok(`${name}: it's this sheet's drawing window (its own colour in the middle)`, near(l.mid, want), `${l.mid} vs ${want}`);
  ok(`${name}: the window's top-left corner is the picture's top-left corner`, near(l.tl, [0, 0, 0], 40), String(l.tl));
  ok(`${name}: the window's bottom-right corner is the picture's bottom-right corner`, near(l.br, [0, 0, 255], 60), String(l.br));
  const bad = l.ring.filter(isOrange);
  ok(`${name}: nothing from outside the window, all round the edge`, bad.length === 0, `${bad.length} of ${l.ring.length} edge points orange`);
}

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/index.html`;
  const browser = await chromium.launch();

  // ---- the stand-in pages, drawn in Chromium so the test needs no image library ----
  const draw = await browser.newPage();
  const paths = [...Array(9)].map((_, i) => `PROJ-00418/v1/sheet-${i + 1}.png`).concat([1, 2, 3].map(i => `PROJ-00099/v1/sheet-${i}.png`));
  for (const p of paths) PAGES.set(p, await draw.evaluate(({ PW, PH, WIN, col }) => {
    const c = document.createElement("canvas"); c.width = PW; c.height = PH; const g = c.getContext("2d");
    g.fillStyle = "rgb(237,94,15)"; g.fillRect(0, 0, PW, PH);
    g.fillStyle = `rgb(${col})`; g.fillRect(WIN.x, WIN.y, WIN.w, WIN.h);
    g.fillStyle = "#000"; g.fillRect(WIN.x, WIN.y, 60, 44);
    g.fillStyle = "#00f"; g.fillRect(WIN.x + WIN.w - 60, WIN.y + WIN.h - 44, 60, 44);
    return c.toDataURL("image/png").split(",")[1];
  }, { PW, PH, WIN, col: colourOf(p).join(",") }));
  await draw.close();

  // ---- the floor: sizes on two sheets, a page not uploaded, a page storage lost, three Arrow items, a job Sanding finished ----
  const q = async (sql, args = []) => (await admin.query(sql, args)).rows;
  const job = (await q("select id from jobs where project_id = 'PROJ-00418'"))[0].id;
  const job99 = (await q("select id from jobs where project_id = 'PROJ-00099'"))[0].id;
  const sheet = async (pid, n) => (await q(`select s.* from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
                                             where j.project_id = $1 and w.is_current and s.sheet_number = $2`, [pid, n]))[0];
  await q(`update sheets s set width = '30', length = '72', total_height = '29.5', shape = 'Rectangle' from work_orders w, jobs j
           where w.id = s.work_order_id and j.id = w.job_id and j.project_id = 'PROJ-00418' and s.sheet_number in (2, 5)`);
  await q(`update sheets s set pdf_uploaded_at = null from work_orders w, jobs j
           where w.id = s.work_order_id and j.id = w.job_id and j.project_id = 'PROJ-00418' and s.sheet_number = 9`);
  MISSING.add("PROJ-00418/v1/sheet-8.png");
  const willie = makeClient(users.willie), mike = makeClient(users.mike);
  const s5 = await sheet("PROJ-00418", 5);
  const prog5 = (await q("select id, qty_required from sheet_progress where sheet_id = $1 and department = 'metal'", [s5.id]))[0];
  const setup = [];
  setup.push(await willie.rpc("set_count", { p_progress: prog5.id, p_qty: prog5.qty_required }));
  setup.push(await willie.rpc("send_sheet", { p_sheet: s5.id, p_from: "metal", p_route: "arrow" }));
  const today = new Date(), back = (d) => new Date(today - d * 864e5).toISOString().slice(0, 10);
  setup.push(await willie.rpc("send_to_arrow", { p_job: job, p_department: "metal", p_service: "powdercoat", p_sheets: [2, 3], p_description: null, p_sent_on: back(6), p_client_id: null }));
  setup.push(await willie.rpc("send_to_arrow", { p_job: job, p_department: "metal", p_service: "paint", p_sheets: [], p_description: "12 grommet covers, black", p_sent_on: back(5), p_client_id: null }));
  for (const r of await q(`select sp.id, sp.qty_required from sheet_progress sp join sheets s on s.id = sp.sheet_id join work_orders w on w.id = s.work_order_id
                           where w.job_id = $1 and w.is_current and sp.department = 'sanding'`, [job99]))
    setup.push(await mike.rpc("set_count", { p_progress: r.id, p_qty: r.qty_required }));
  const setupErr = setup.filter(r => r.error).map(r => r.error.message);
  ok("setup: the counts and Arrow items went in through the tablet's own functions", setupErr.length === 0, setupErr.join(" | "));
  const jobName = (await q("select name from jobs where id = $1", [job]))[0].name;

  // ---- 1. Mike, Sanding: a job's sheets ----
  let m = await session(browser, users.mike);
  await m.p.goto(base); await loaded(m.p);
  ok("the page is 2026-10-22.1", await m.p.evaluate(() => typeof PAGE_VERSION !== "undefined" && PAGE_VERSION) === "2026-10-22.1");
  await m.p.waitForSelector(`[data-job="${job}"]`, { timeout: 15000 }).catch(() => {});
  await m.p.click(`[data-job="${job}"]`).catch(() => {});
  await m.p.waitForSelector(".sheet", { timeout: 10000 }).catch(() => {});
  ok("Mike: every sheet whose page is uploaded has its picture frame, and no other does", await m.p.evaluate(() =>
    [...document.querySelectorAll("#app .sheet")].map(b => [b.querySelector(".no").innerText.trim(), !!b.querySelector(".snip")]).every(([n, has]) => has === (n !== "9"))),
    JSON.stringify(await m.p.evaluate(() => [...document.querySelectorAll("#app .sheet")].map(b => b.querySelector(".no").innerText.trim() + (b.querySelector(".snip") ? "+" : "-")))));
  ok("Mike: each picture sits between the sheet's words and its count", await m.p.evaluate(() =>
    [...document.querySelectorAll("#app .sheet .snip")].every(s => s.previousElementSibling && s.previousElementSibling.classList.contains("meta") && s.nextElementSibling && s.nextElementSibling.classList.contains("cnt"))));
  ok("Mike: the pictures fill in on their own", await settled(m.p));
  const nums = await m.p.evaluate(() => [...document.querySelectorAll("#app .sheet")].map(b => b.querySelector(".no").innerText.trim()));
  for (const n of nums) {
    const state = await m.p.evaluate((n) => { const b = [...document.querySelectorAll("#app .sheet")].find(b => b.querySelector(".no").innerText.trim() === n);
      const f = b && b.querySelector(".snip"); return !f ? "-" : f.classList.contains("none") ? "none" : f.style.backgroundImage ? "pic" : "empty"; }, n);
    if (state === "-") continue;
    if (n === "8") { ok("Mike: a page storage hasn't got leaves an empty space, no error", state === "none", state); continue; }
    const l = await look(m.p, { row: n });
    if (["1", "5", "7"].includes(n)) judge(`Mike, sheet ${n}`, l, `PROJ-00418/v1/sheet-${n}.png`);
    else ok(`Mike, sheet ${n}: its own colour`, l && near(l.mid, colourOf(`PROJ-00418/v1/sheet-${n}.png`)), l ? String(l.mid) : "none");
    if (n === "1") {
      ok("Mike: the picture is 136 wide on the tablet, in the window's proportions", l && Math.abs(l.css - 136) < 1 && Math.abs(l.W / l.H - 268 / 195) < 0.02, l && `${l.css}px, ${l.W}x${l.H}`);
      ok("Mike: the picture is made at 480 pixels (sharp, small to keep)", l && l.W === 480, l && String(l.W));
    }
  }
  ok("Mike: no error message on the screen", !(await m.p.evaluate(() => !!document.querySelector("#app .banner.warn, #app .notice"))));
  const rowH = await m.p.evaluate(() => Math.round(document.querySelector("#app .sheet").getBoundingClientRect().height));
  ok("Mike: a row is about 1 1/4 inches tall with its picture (was about 3/4)", rowH > 110 && rowH < 140, rowH + "px");
  await m.p.screenshot({ path: "/tmp/pictures_job.png", fullPage: true });

  const kept = await m.p.evaluate(async () => (await (await caches.open("sheet-pages-v1")).keys())
    .map(r => decodeURIComponent(new URL(r.url).pathname)).filter(u => u.startsWith("/__sheet-snips__/")));
  ok("Mike: each picture is kept on the tablet beside its page, so it's made only once", [1, 2, 3, 4, 5, 6, 7].every(n => kept.some(k => k.endsWith(`PROJ-00418/v1/sheet-${n}.png`)))
     && !kept.some(k => /sheet-[89]\.png$/.test(k)), `${kept.length} kept`);

  // tapping the row still opens the sheet with its counter, as before
  await m.p.click("#app .sheet >> nth=0"); await m.p.waitForSelector(".counter", { timeout: 5000 }).catch(() => {});
  ok("Mike: tapping a row still opens the sheet and its counter", !!(await m.p.$(".counter")));
  await m.p.click("[data-back=job]").catch(() => {}); await m.p.waitForSelector("#app .sheet", { timeout: 5000 }).catch(() => {});
  ok("Mike: back on the job, the pictures are there straight away (made once, kept)", await m.p.evaluate(() =>
    [...document.querySelectorAll("#app .sheet .snip")].filter(e => !e.classList.contains("none")).every(e => e.style.backgroundImage)));

  // Recently completed: PROJ-00099, all three Sanding sheets counted just now
  await m.p.click("[data-back=queue]").catch(() => {});
  await m.p.click('[data-tab="past"]').catch(() => {});
  await m.p.waitForSelector(`#app [data-job="${job99}"]`, { timeout: 10000 }).catch(() => {});
  await m.p.click(`#app [data-job="${job99}"]`).catch(() => {});
  await m.p.waitForSelector("#app .sheet", { timeout: 8000 }).catch(() => {});
  await settled(m.p);
  const pastN = await m.p.evaluate(() => document.querySelectorAll("#app .sheet .snip").length);
  ok("Mike, Recently completed: each sheet has its picture too", pastN === 3, `${pastN} pictures`);
  const lp = await look(m.p, { row: 2 });
  ok("Mike, Recently completed: sheet 2's own drawing", lp && near(lp.mid, colourOf("PROJ-00099/v1/sheet-2.png")), lp ? String(lp.mid) : "none");

  // no signal: the pictures were made once, so they show again without the pages
  m.st.offline = true; const before = downloads.length;
  await m.p.reload(); await loaded(m.p);
  await m.p.click('[data-tab="work"]').catch(() => {});
  await m.p.waitForSelector(`[data-job="${job}"]`, { timeout: 10000 }).catch(() => {});
  await m.p.click(`[data-job="${job}"]`).catch(() => {});
  await m.p.waitForSelector("#app .sheet", { timeout: 8000 }).catch(() => {});
  await settled(m.p);
  const off = await m.p.evaluate(() => [...document.querySelectorAll("#app .sheet")].map(b => { const s = b.querySelector(".snip");
    return [b.querySelector(".no").innerText.trim(), s ? (s.style.backgroundImage ? "pic" : s.classList.contains("none") ? "none" : "empty") : "-"]; }));
  ok("no signal: after reopening the app, every picture made before still shows", off.filter(([n]) => !["8", "9"].includes(n)).every(([, v]) => v === "pic"), JSON.stringify(off));
  ok("no signal: they came from the tablet, without asking for a single page", downloads.slice(before).filter(([p]) => !/sheet-8/.test(p)).length === 0,
     JSON.stringify(downloads.slice(before)));
  ok("Mike: no errors on the page", m.errs.length === 0, m.errs.join(" | "));
  await m.ctx.close();

  // ---- 2. Willie, Metal: the Arrow tab ----
  const w = await session(browser, users.willie);
  await w.p.goto(base); await loaded(w.p);
  await w.p.click('[data-tab="arrow"]'); await w.p.waitForSelector("#app .arpic", { timeout: 10000 }).catch(() => {});
  ok("Willie: the pictures fill in on their own", await settled(w.p));
  const info = await w.p.evaluate(() => [...document.querySelectorAll("#app .li")].map(c => ({ text: c.innerText.replace(/\s+/g, " ").trim(),
    pics: c.querySelectorAll(".arpic").length, gone: !!c.querySelector("[data-argone]"), wo: c.querySelector(".arwo") ? c.querySelector(".arwo").innerText.trim() : null,
    ret: !!c.querySelector("[data-arreturn]"), voidb: !!c.querySelector("[data-arvoid]"), arwo: !!c.querySelector("[data-arwo]"),
    w: c.querySelector(".snip") ? c.querySelector(".snip").getBoundingClientRect().width : 0 })));
  const names = await text(w.p, "#app .li-top .jn");
  ok("Willie: each open item shows the job's name beside its PROJ", names.filter(n => n === jobName).length >= 3, JSON.stringify(names));
  const waitC = info.find(c => c.gone) || { text: "" };
  ok("Willie: the waiting item is one picture, 'Sheet 5 · TB-04', its size and × 3 tables",
     waitC.pics === 1 && /Sheet 5 · TB-04/.test(waitC.text) && /30 × 72 · 29\.5 H/.test(waitC.text) && /× 3 tables/.test(waitC.text), waitC.text);
  ok("Willie: Gone to Arrow is still there, beside a Work order button", waitC.gone && waitC.wo === "Work order", String(waitC.wo));
  judge("Willie, the waiting item", await look(w.p, { arrow: 5 }), "PROJ-00418/v1/sheet-5.png");
  ok("Willie: an Arrow picture is 236 wide on the tablet", Math.abs(waitC.w - 236) < 1, String(waitC.w));
  const two = info.find(c => c.pics === 2) || { text: "" };
  ok("Willie: the two-sheet item shows both sheets, each with its count, and 'Work order · 2 sheets'",
     /Sheet 2 · TB-03/.test(two.text) && /Sheet 3 · TB-03/.test(two.text) && (two.text.match(/× 2 tables/g) || []).length === 2 && two.wo === "Work order · 2 sheets", two.text);
  ok("Willie: a sheet with no size says nothing about size (sheet 3)", /Sheet 3 · TB-03 × 2 tables/.test(two.text) && /Sheet 2 · TB-03 30 × 72 · 29\.5 H × 2 tables/.test(two.text), two.text);
  const hw = info.find(c => /12 grommet covers, black/.test(c.text)) || {};
  ok("Willie: hardware with no sheet is words only, as before: no picture, no Work order", hw.pics === 0 && !hw.arwo && hw.ret, hw.text);
  ok("Willie: Mark returned and Entered by mistake are still on the items at Arrow", two.ret && two.voidb);
  await w.p.screenshot({ path: "/tmp/pictures_arrow.png", fullPage: true });

  // the item's work order: tap a picture, move between its sheets, back to the list
  await w.p.click('#app .arpic:has-text("Sheet 2 ·")');
  await w.p.waitForSelector("#arpage img", { timeout: 8000 }).catch(() => {});
  const sub1 = (await text(w.p, "#app p.sub"))[0] || "";
  ok("Willie: tapping a picture opens that sheet's page, read-only", (await text(w.p, "#app h1"))[0] === "Work order" && /PROJ-00418 · .*Sheet 2 · TB-03 · 30 × 72 · 29\.5 H · 2 tables/.test(sub1)
     && /^blob:/.test(await w.p.$eval("#arpage img", e => e.getAttribute("src")).catch(() => "")) && !(await w.p.$("#app [data-step], #app [data-argone], #app [data-arreturn]")), sub1);
  ok("Willie: the viewer offers only the item's two sheets", JSON.stringify(await text(w.p, "#app .wopick button")) === '["2","3"]');
  ok("Willie: no Sign out under the viewer", !(await w.p.$("#app [data-signout]")));
  await w.p.click('#app .wonav button:has-text("Sheet 3")'); await w.p.waitForTimeout(300);
  ok("Willie: Sheet 3 › goes to the next sheet", /Sheet 3 · TB-03/.test((await text(w.p, "#app p.sub"))[0] || ""));
  // a one-finger swipe right goes back to sheet 2
  await w.p.waitForSelector("#arpage img", { timeout: 5000 }).catch(() => {});
  await w.p.evaluate(() => { const el = document.getElementById("arpage"), t = (x) => new Touch({ identifier: 1, target: el, clientX: x, clientY: 300 });
    el.dispatchEvent(new TouchEvent("touchstart", { touches: [t(200)], changedTouches: [t(200)], bubbles: true }));
    el.dispatchEvent(new TouchEvent("touchend", { touches: [], changedTouches: [t(420)], bubbles: true })); });
  await w.p.waitForTimeout(300);
  ok("Willie: a swipe right goes back a sheet", /Sheet 2 · TB-03/.test((await text(w.p, "#app p.sub"))[0] || ""));
  await w.p.click("[data-arwoback]"); await w.p.waitForSelector("#app .arpic", { timeout: 5000 }).catch(() => {});
  ok("Willie: ← Arrow comes back to the list, tabs and all", !!(await w.p.$("#app .subtabs")) && (await text(w.p, "#app h2.sec")).includes("At Arrow now"));
  await w.p.click("#app .arwo >> nth=0"); await w.p.waitForSelector("#arpage", { timeout: 5000 }).catch(() => {});
  ok("Willie: the Work order button opens the item's first sheet", /Sheet 5 · TB-04/.test((await text(w.p, "#app p.sub"))[0] || ""));
  await w.p.click("[data-arwoback]"); await w.p.waitForSelector("#app .arpic", { timeout: 5000 }).catch(() => {});
  ok("Willie: no errors on the page", w.errs.length === 0, w.errs.join(" | "));
  await w.ctx.close();

  // ---- 2b. Eric, Assembly / QC beside Full Custom: the same Arrow tab, and switching department leaves the viewer ----
  const e = await session(browser, users.eric);
  await e.p.goto(base); await loaded(e.p);
  await e.p.click('.top [data-dept="assembly_qc"]').catch(() => {});
  await e.p.waitForSelector('[data-tab="arrow"]', { timeout: 8000 }).catch(() => {});
  await e.p.click('[data-tab="arrow"]'); await e.p.waitForSelector("#app .arpic", { timeout: 10000 }).catch(() => {});
  ok("Eric, Assembly / QC: the same pictures on his Arrow tab", await settled(e.p) && (await e.p.$$("#app .arpic")).length === 3);
  await e.p.click("#app .arwo >> nth=0"); await e.p.waitForSelector("#arpage", { timeout: 5000 }).catch(() => {});
  ok("Eric: the viewer opens", !!(await e.p.$("#arpage")));
  ok("Eric: no errors on the page", e.errs.length === 0, e.errs.join(" | "));
  await e.ctx.close();

  // ---- 2c. Luke, a manager: from Metal's Arrow viewer straight to Assembly / QC (both have an Arrow tab) ----
  const k = await session(browser, users.luke);
  await k.p.goto(base); await loaded(k.p);
  const pick = async (d) => { await k.p.click("[data-deptmenu]").catch(() => {}); await k.p.click(`.deptmenu [data-dept="${d}"]`).catch(() => {}); await k.p.waitForTimeout(600); };
  await pick("metal");
  await k.p.click('[data-tab="arrow"]').catch(() => {}); await k.p.waitForSelector("#app .arwo", { timeout: 10000 }).catch(() => {});
  await k.p.click("#app .arwo >> nth=0").catch(() => {}); await k.p.waitForSelector("#arpage", { timeout: 5000 }).catch(() => {});
  ok("Luke: the viewer opens from Metal's Arrow tab", !!(await k.p.$("#arpage")));
  await pick("assembly_qc");
  await k.p.waitForSelector("#app .subtabs", { timeout: 5000 }).catch(() => {});
  ok("Luke: switching department, still on Arrow, opens on the list, not the old viewer", !(await k.p.$("#arpage")) && !!(await k.p.$("#app .subtabs")) && !!(await k.p.$("#app .arpic, #app .li")));
  ok("Luke: no errors on the page", k.errs.length === 0, k.errs.join(" | "));
  await k.ctx.close();

  // ---- 3. Shawn's phone: the same Arrow items, the same pictures, nothing wider than the screen ----
  const s = await session(browser, users.shawn, { width: 412, height: 915 });
  await s.p.goto(base); await loaded(s.p);
  await s.p.click('[data-tab="arrow"]'); await s.p.waitForSelector("#app .arpic", { timeout: 10000 }).catch(() => {});
  ok("Shawn: the pictures fill in on his phone too", await settled(s.p) && (await s.p.$$("#app .arpic")).length === 3);
  ok("Shawn: nothing wider than the phone", await s.p.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), String(await s.p.evaluate(() => document.documentElement.scrollWidth)));
  judge("Shawn, a picture", await look(s.p, { arrow: 5 }), "PROJ-00418/v1/sheet-5.png");
  await s.p.screenshot({ path: "/tmp/pictures_phone.png", fullPage: true });
  ok("Shawn: no errors on the page", s.errs.length === 0, s.errs.join(" | "));
  await s.ctx.close();

  await browser.close(); server.close(); await admin.end().catch(() => {});
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); console.log(`FAIL  the test itself stopped: ${e.message}`); process.exit(1); });
