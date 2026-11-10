// 10 Nov: the simpler Inventory page (inventory.html 2026-11-10.1), in real Chromium through the real test database as Luke.
// Two tabs (This month, Results) and a Setup button. This month: Deliveries in as one line with one form for both kinds of
// slip; the three month-end steps (Lumber count, Department counts, Roll-over) ticking themselves done in turquoise; Close
// saying what's left. The lumber count, a department's list and Setup each take the whole screen, with the way back at the
// top. Results: one month picker, the export beside it, the two headline numbers, the scrap table short with Show the
// working, Value by GL account with See every item, a row's tops in the drawer. Every action still reaches the database the
// way it did. A tab remembered from before opens where its content lives now; phone width; a supervisor; no errors.
//   bash /home/claude/sf/base/fresh.sh
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis OUT=/tmp/allpages node test_inventory_screens.js
const fs = require("fs"), http = require("http"), path = require("path");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

(async () => {
  const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
  const { makeClient, users, admin } = require("./pgsupa");
  const html = fs.readFileSync([path.join(OUT, "inventory.html"), path.join(REPO, "inventory.html")].find(f => fs.existsSync(f)), "utf8");
  const ver = (html.match(/var PAGE_VERSION = "([^"]+)"/) || [])[1];
  ok("inventory.html's version was bumped", ver && ver >= "2026-11-10.1", ver);

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
  async function session(browser, user, opts = {}) {
    const client = makeClient(user);
    const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1366, height: 860 }, serviceWorkers: "block", acceptDownloads: true });
    await ctx.addInitScript((pre) => { if (!localStorage.getItem("sfo_pin")) localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
      for (const [k, v] of Object.entries(pre || {})) if (!sessionStorage.getItem("pre_" + k)) { localStorage.setItem(k, v); sessionStorage.setItem("pre_" + k, "1"); } }, opts.pre || {});
    await ctx.exposeBinding("__sb", async (_, m) => {
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
    p.on("dialog", d => d.accept());
    return { ctx, p, errs };
  }
  const q = async (s, a) => (await admin.query(s, a)).rows;
  const rpcAs = async (who, fn, args) => { const r = await makeClient(users[who]).rpc(fn, args); if (r.error) throw new Error(`${who} ${fn}: ${r.error.message}`); return r.data; };
  const navText = (p) => p.$eval("#tabs", e => e.innerText.replace(/\s+/g, " ").trim());
  const noSideways = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
  const settle = (p, ms = 700) => p.waitForTimeout(ms);

  try {
    await new Promise(r => server.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${server.address().port}/shop-floor`;
    const [{ m: openMonth }] = await q("select inv_current_month()::text as m");
    const browser = await chromium.launch();
    let s = await session(browser, users.luke), p = s.p;
    await p.goto(`${base}/inventory.html`);
    await p.waitForSelector("nav.tabs [data-tab]", { timeout: 15000 });

    // ---- the tabs ----
    const tabs = await p.$$eval("#tabs [data-tab]", bs => bs.map(b => b.textContent.trim()));
    ok("two tabs: This month and Results", tabs.join("|") === "This month|Results", tabs.join("|"));
    ok("Setup is a button beside them, not a tab", !!(await p.$('#tabs [data-go="setup"]')) && /Setup/.test(await navText(p)));
    ok("none of the old tab names are left", !/Lumber count|Department counts|Deliveries in|Month-end|Scrap rate|Values/.test(await navText(p)), await navText(p));

    // ---- This month ----
    await p.click('[data-tab="month"]'); await settle(p, 300);
    const main = () => p.textContent("main");
    let t = await main();
    ok("This month: All month, then Month-end", t.indexOf("All month") >= 0 && t.indexOf("All month") < t.indexOf("Month-end"));
    const steps = await p.$$eval(".steps .srow .tt", es => es.map(e => e.textContent.trim()));
    ok("the steps in order: Deliveries in; Lumber count, Department counts, Roll-over", steps.slice(0, 4).join("|") === "Deliveries in|Lumber count|Department counts|Roll-over", steps.join("|"));
    ok("Close is there but can't be pressed yet, and says what's left", await p.$eval("[data-close]", b => b.disabled) && /Still to do: the lumber count, Plywood's count, .*the roll-over\./.test(t), (t.match(/Still to do:[^.]*\./) || [""])[0]);
    ok("no export on This month any more", !(await p.$("[data-export]")));

    // a lumber slip and a plywood slip through the one form
    const lum = await q("select id, name, stock from inv_items where list_key = 'lumber' and not retired order by name limit 1");
    await p.click('details[data-fold="deliv"] > summary'); await settle(p, 200);
    ok("Deliveries in opens to one form", await p.isVisible("#rkind") && await p.isVisible("#rk") && !(await p.isVisible("#pn")));
    await p.fill("#rs", "Frank Miller Lumber"); await p.selectOption("#rk", lum[0].id); await p.fill("#rb", "1600");
    await p.click("[data-addslip]"); await settle(p, 900);
    let rec = await q("select kind, item_id, board_feet::float as bf, sheets, supplier from inv_receipts where month_end = $1 order by id", [openMonth]);
    ok("a lumber slip lands in the database as before", rec.length === 1 && rec[0].kind === "lumber" && rec[0].item_id === lum[0].id && rec[0].bf === 1600 && rec[0].supplier === "Frank Miller Lumber", JSON.stringify(rec));
    ok("…the form stays open after adding", await p.isVisible("#rkind"));
    await p.selectOption("#rkind", "plywood");
    ok("Plywood swaps species and board feet for sheets", await p.isVisible("#pn") && !(await p.isVisible("#rk")) && !(await p.isVisible("#rb")));
    await p.fill("#rs", "Hood Distribution – DSI"); await p.fill("#pn", "40");
    await p.click("[data-addslip]"); await settle(p, 900);
    rec = await q("select kind, sheets from inv_receipts where month_end = $1 and kind = 'plywood'", [openMonth]);
    ok("a plywood slip lands as plywood with its sheets", rec.length === 1 && rec[0].sheets === 40, JSON.stringify(rec));
    ok("the line adds the slips up", /Lumber 1,600 bd ft on 1 slip · Plywood 40 sheets on 1 slip/.test(await p.textContent('details[data-fold="deliv"] summary')), await p.textContent('details[data-fold="deliv"] summary'));
    ok("both slips listed, each with Entered by mistake", (await p.$$("details[data-fold=deliv] [data-mistake]")).length === 2);
    await p.click("details[data-fold=deliv] [data-mistake]"); await settle(p, 900);
    rec = await q("select count(*) filter (where mistake_at is not null) as n from inv_receipts where month_end = $1", [openMonth]);
    ok("Entered by mistake still marks, never deletes", Number(rec[0].n) === 1);
    ok("…and the line stops counting it", /Lumber 0 bd ft on 0 slips/.test(await p.textContent('details[data-fold="deliv"] summary')));

    // ---- the lumber count, on its own screen ----
    await p.click('[data-go="lumber"]'); await settle(p, 400);
    ok("Lumber count takes the whole screen: no tabs, the way back and its name at the top",
       !(await p.$("#tabs [data-tab]")) && /This month\s*Lumber count/.test(await navText(p)), await navText(p));
    ok("…the saving line sits in the top bar", !!(await p.$("#tabs #saving")));
    ok("the screen's name is what Feedback reads", await p.evaluate(() => sfDescribeScreen(document, true)) === "Lumber count", await p.evaluate(() => sfDescribeScreen(document, true)));
    if (!(await p.$(`details.spec[data-item="${lum[0].id}"]`))) { await p.selectOption("#newkey", lum[0].id); await p.click("[data-addkey]"); await settle(p, 300); }
    const spec = `details.spec[data-item="${lum[0].id}"]`;
    if (!(await p.$eval(spec, d => d.open))) { await p.click(`${spec} > summary`); await settle(p, 200); }
    const box = await p.$(`${spec} [data-b]`);
    await box.fill("10"); await p.waitForTimeout(1600);
    let lines = await q("select bundles from inv_lumber_lines where month_end = $1 and item_id = $2", [openMonth, lum[0].id]);
    ok("a number typed saves itself, as before", lines.some(l => (l.bundles || []).map(Number).includes(10)), JSON.stringify(lines));
    ok("…and the top bar says All saved", /All saved/.test(await p.textContent("#saving")));
    await p.click("[data-lumdone='1']"); await settle(p, 1000);
    let mr = (await q("select lumber_done_at, rollover_done_at from inv_months where month_end = $1", [openMonth]))[0];
    ok("Lumber count is done: saved, and back on This month", !!mr.lumber_done_at && !!(await p.$('#tabs [data-tab="month"][aria-current="true"]')));
    ok("…step 1 turns turquoise with a tick", await p.$eval('.steps [data-go="lumber"]', b => b.classList.contains("done") && !!b.querySelector(".circ.ok svg")));

    // ---- department counts ----
    await rpcAs("willie", "send_inventory_count", { p_list: "metal", p_counts: [] });
    await p.reload(); await p.waitForSelector("nav.tabs [data-tab]"); await settle(p, 400);
    const dept = 'details[data-fold="dept"]';
    ok("Department counts is open while lists are still to come", await p.$eval(dept, d => d.open));
    let sub = await p.textContent(`${dept} .fbody`);
    ok("Metal sent by Willie, Plywood waiting on its tablet", /Metal[\s\S]*Sent[^·]*by Willie/.test(sub) && /Waiting · on [^']*'s tablet now/.test(sub), sub.replace(/\s+/g, " ").slice(0, 200));
    ok("…and the count says 1 of 4 in", /1 of 4 in/.test(await p.textContent(`${dept} summary`)), await p.textContent(`${dept} summary`));
    await p.click(`${dept} [data-golist="metal"]`); await settle(p, 400);
    ok("See the count opens Metal on a screen of its own", !(await p.$("#tabs [data-tab]")) && /Department counts/.test(await navText(p)) && /Metal count sent/.test(await main()));
    ok("…the lists to switch between are still at the top", (await p.$$(".seg [data-dlist]")).length === 4);
    await p.click('.seg [data-dlist="plywood"]'); await settle(p, 300);
    const ply = await q("select id from inv_items where list_key = 'plywood' and not retired order by sort_order, name");
    await p.fill(`[data-dinv="${ply[0].id}|n"]`, "7");
    await p.click('[data-dsend="plywood"]'); await settle(p, 1100);
    let sent = await q("select qty::float as q from inv_counts where month_end = $1 and item_id = $2", [openMonth, ply[0].id]);
    ok("Send for the department reaches the database as before", sent.length === 1 && sent[0].q === 7, JSON.stringify(sent));
    ok("…and comes back to This month with 2 of 4 in", !!(await p.$('#tabs [data-tab="month"][aria-current="true"]')) && /2 of 4 in/.test(await p.textContent(`${dept} summary`)));
    await p.click(`${dept} [data-golist="finish"]`); await settle(p, 300);
    await p.click('#tabs [data-go="month"]'); await settle(p, 300);
    ok("the way back from a list lands on This month", !!(await p.$('#tabs [data-tab="month"][aria-current="true"]')));
    await rpcAs("luke", "send_inventory_count", { p_list: "finish", p_counts: [] });
    await rpcAs("luke", "send_inventory_count", { p_list: "other", p_counts: [] });
    await p.reload(); await p.waitForSelector("nav.tabs [data-tab]"); await settle(p, 400);
    ok("every list in: step 2 is done and folds itself", await p.$eval(`${dept} > summary`, e => e.classList.contains("done")) && !(await p.$eval(dept, d => d.open)));

    // ---- the roll-over ----
    await p.click('details[data-fold="roll"] > summary'); await settle(p, 200);
    ok("Roll-over opens in place", await p.isVisible("[data-rodone='1']"));
    await p.click("[data-rodone='1']"); await settle(p, 1000);
    mr = (await q("select rollover_done_at from inv_months where month_end = $1", [openMonth]))[0];
    ok("Done — these are right is saved; the fold stays open; step 3 ticks", !!mr.rollover_done_at && await p.$eval('details[data-fold="roll"]', d => d.open)
       && await p.$eval('details[data-fold="roll"] > summary', e => e.classList.contains("done")));
    t = await main();
    ok("everything in: Close can be pressed and says so", await p.$eval("[data-close]", b => !b.disabled) && /Everything's in\./.test(t));

    // ---- Results ----
    await p.click('[data-tab="results"]'); await settle(p, 400);
    t = await main();
    ok("Results: the month picker with Export counts beside it", !!(await p.$("#xm")) && await p.$eval("[data-export]", b => b.textContent.trim() === "Export counts" && !!b.querySelector("svg")));
    ok("…the two headline numbers", /Scrap rate, all lumber/.test(t) && /Inventory value/.test(t));
    const [dl] = await Promise.all([p.waitForEvent("download", { timeout: 15000 }), p.click("[data-export]")]);
    ok("Export counts downloads the month picked", dl.suggestedFilename() === `inventory-counts-${openMonth.slice(0, 7)}-not-closed.csv`, dl.suggestedFilename());
    const heads = async () => p.$$eval(".tw thead th", ths => ths.map(h => h.textContent.trim()));
    await p.selectOption("#xm", "2026-08-31"); await settle(p, 300);
    ok("the starting count: no scrap rate, and says why", /The starting count/.test(await main()));
    ok("…picking a month in the picker exports that month", await p.$eval("#xm", e => e.value) === "2026-08-31");
    const scrapMonth = (await q("select month_end::text as m from v_inv_scrap where opening_bf is not null and (used_bf > 0 or received_bf > 0) order by month_end desc limit 1"))[0];
    if (scrapMonth) {
      await p.selectOption("#xm", scrapMonth.m); await settle(p, 300);
      let h = await heads();
      ok("the scrap table is short to start: four columns", h.slice(0, 4).join("|") === "Species and thickness|Used|Scrap|Scrap rate", h.join("|"));
      await p.click("[data-working]"); await settle(p, 200);
      h = await heads();
      ok("Show the working brings back all eight and the formula", h.slice(0, 8).join("|") === "Species and thickness|Last count|Received|This count|Used|0-scrap|Scrap|Scrap rate" && /Used = last count \+ received − this count/.test(await main()), h.join("|"));
      await p.reload(); await p.waitForSelector("#xm"); await p.selectOption("#xm", scrapMonth.m); await settle(p, 300);
      ok("…and it's remembered", (await heads()).length >= 8);
      await p.click("[data-working]"); await settle(p, 200);
      const row = await p.$("tr.click");
      if (row) { await row.click(); await settle(p, 200); ok("tap a row: its tops in the drawer", await p.isVisible(".drawer .pane")); await p.click(".drawer button[data-shut]"); await settle(p, 200); }
    } else ok("a month with scrap numbers to show (the seed has one)", false, "none in v_inv_scrap");
    ok("Value by GL account, items folded away", /Value by GL account/.test(await main()) && !/Lumber · \$/.test(await main()));
    await p.click("[data-valitems]"); await settle(p, 200);
    ok("See every item opens the lists", (await p.$$(".tw")).length > 2 && /Hide the items/.test(await main()));

    // ---- Setup ----
    await p.click('#tabs [data-go="setup"]'); await settle(p, 300);
    ok("Setup from Results: its own screen, and the way back says Results", !(await p.$("#tabs [data-tab]")) && /Results\s*Setup/.test(await navText(p)), await navText(p));
    const folds = await p.$$eval(".steps details.sfold .tt", es => es.map(e => e.textContent.trim()));
    ok("three folded lists: Species matches, Thickness rules, Count lists and prices", folds.join("|") === "Species matches|Thickness rules|Count lists and prices", folds.join("|"));
    await p.click('details[data-fold="rules"] > summary'); await settle(p, 200);
    await p.fill("#tf", "3.5"); await p.selectOption("#ts", "12/4"); await p.click("[data-addrule]"); await settle(p, 900);
    const rule = await q("select stock from inv_thickness_rules where from_in = 3.5 and retired_at is null");
    ok("adding a thickness rule works as before, and the fold stays open", rule.length === 1 && rule[0].stock === "12/4" && await p.$eval('details[data-fold="rules"]', d => d.open));
    await p.click('details[data-fold="lists"] > summary'); await settle(p, 200);
    const priceIn = await p.$("[data-price]");
    const pid = await priceIn.getAttribute("data-price"); await priceIn.fill("4.25"); await priceIn.dispatchEvent("change"); await settle(p, 900);
    const pr = await q("select price::float as p from v_inv_prices where item_id = $1", [pid]);
    ok("a price saves as before", pr.length && pr[0].p === 4.25, JSON.stringify(pr));
    await p.click('#tabs [data-go="results"]'); await settle(p, 300);
    ok("the way back from Setup returns to Results", !!(await p.$('#tabs [data-tab="results"][aria-current="true"]')));

    // ---- Close ----
    await p.click('[data-tab="month"]'); await settle(p, 300);
    await p.click("[data-close]"); await settle(p, 1500);
    const months = await q("select month_end::text as m, status from inv_months order by month_end");
    ok("Close closes the month as before", months.find(m => m.m === openMonth).status === "closed", JSON.stringify(months));
    ok("no errors on the page", s.errs.length === 0, s.errs.join(" | "));
    await s.ctx.close();

    // ---- a tab remembered from before 10 Nov ----
    for (const [old, want] of [["scrap", "results"], ["values", "results"], ["rollover", "month"], ["deliveries", "month"]]) {
      s = await session(browser, users.luke, { pre: { sfi_tab: JSON.stringify(old) } }); p = s.p;
      await p.goto(`${base}/inventory.html`); await p.waitForSelector("nav.tabs [data-tab]"); await settle(p, 300);
      ok(`a remembered "${old}" tab opens ${want === "month" ? "This month" : "Results"}`, !!(await p.$(`#tabs [data-tab="${want}"][aria-current="true"]`)));
      await s.ctx.close();
    }

    // ---- phone width ----
    s = await session(browser, users.luke, { viewport: { width: 390, height: 800 } }); p = s.p;
    await p.goto(`${base}/inventory.html`); await p.waitForSelector("nav.tabs [data-tab]"); await settle(p, 400);
    let wide = [];
    for (const go of ["month", "results", "lumber", "dept", "setup"]) {
      if (go === "lumber" || go === "dept") { await p.click('#tabs [data-tab="month"]'); await settle(p, 300); }
      await p.evaluate((g) => { const b = document.querySelector(`#tabs [data-tab="${g}"], #tabs [data-go="${g}"]`) || document.querySelector(`[data-go="${g}"]`); if (b) b.click(); else if (g === "dept") document.querySelector("[data-golist]").click(); }, go);
      await settle(p, 400);
      if (!(await noSideways(p))) wide.push(go);
      if (go !== "month" && go !== "results") { await p.evaluate(() => { const b = document.querySelector('#tabs [data-go="month"]'); if (b) b.click(); }); await settle(p, 300); }
    }
    ok("phone width: no sideways scroll on any screen", wide.length === 0, wide.join(", "));
    ok("phone: no errors", s.errs.length === 0, s.errs.join(" | "));
    await s.ctx.close();

    // ---- inside the office ----
    s = await session(browser, users.luke); p = s.p;
    await p.goto(`${base}/office.html#inventory`);
    let fr = null; for (let i = 0; i < 40 && !fr; i++) { fr = p.frames().find(f => f.url().includes("inventory.html")); if (!fr) await p.waitForTimeout(250); }
    ok("the office opens Inventory in its frame", !!fr);
    if (fr) {
      await fr.waitForSelector("nav.tabs [data-tab]", { timeout: 15000 });
      await fr.click('[data-tab="month"]'); await fr.click('[data-go="lumber"]'); await p.waitForTimeout(400);
      ok("inside the office: the lumber screen's top bar shows, with the way back", await fr.isVisible('#tabs [data-go="month"]') && await fr.isVisible("#tabs .ttl"));
    }
    ok("office: no errors", s.errs.length === 0, s.errs.join(" | "));
    await s.ctx.close();

    // ---- a supervisor ----
    s = await session(browser, users.willie); p = s.p;
    await p.goto(`${base}/inventory.html`); await p.waitForSelector("main"); await p.waitForTimeout(800);
    ok("Willie: For managers, no tabs", /For managers/.test(await p.textContent("#app")) && await p.$eval("#tabs", e => e.hidden));
    await s.ctx.close();
    await browser.close();
  } catch (e) { ok("the run finished", false, e.stack); }
  server.close(); await admin.end().catch(() => {});
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})();
