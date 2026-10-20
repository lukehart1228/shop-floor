// 20 Oct: the floor TV — Coming up (tv_coming.sql), the picture actually drawn, picture on top (Option B), upright photos whole.
//   TEMPLATE=sync_base_new bash /home/claude/sf/base/fresh.sh     (a database with tv_coming.sql), then:
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_tv_coming.js
//   OLDDB=1 … on a seeded sync_base_old (no tv_coming.sql): the new page shows the department rows as before, and the picture
//   PAGE=/home/claude/sf/repo/tv.html … the TV page before: on the new database its rows still work; its picture lines fail (the bug)
//   SHOTS=/tmp/shots … also saves screenshots
// The page runs in real Chromium. Its two requests (tv_snapshot, tv_photo) go to the real test database as anon,
// exactly as Supabase's API runs them, so the base64 the page gets is the database's own (broken into lines).
const fs = require("fs");
const path = require("path");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/out";
const PAGE = process.env.PAGE || `${OUT}/tv.html`;
const OLDDB = !!process.env.OLDDB, SHOTS = process.env.SHOTS;
const NEWPAGE = /function comingWords/.test(fs.readFileSync(PAGE, "utf8"));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const wait = (ms) => new Promise(r => setTimeout(r, ms));

// two small real JPEGs: a wide one and one taken upright
const WIDE = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAB4AKADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDuaKKKgoKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA5P+2NQ/wCfj/xxf8KP7Y1D/n4/8cX/AAqjRXPzM35UXv7Y1D/n4/8AHF/wpf7X1D/n4/8AHF/wqiBS1jKq3szaNJLdF7+2L/8A5+P/ABxf8KP7Yv8A/n4/8cX/AAqjRU88u5XJHsXv7Yv/APn4/wDHF/wo/ti//wCfj/xxf8Ko0Uc8u4ckexe/ti//AOfj/wAcX/Cj+2L/AP5+P/HF/wAKo0Uc8u4ckexe/ti//wCfj/xxf8KP7Yv/APn4/wDHF/wqjRRzy7hyR7F7+2L/AP5+P/HF/wAKP7Yv/wDn4/8AHF/wqjRRzy7hyR7F7+2L/wD5+P8Axxf8KP7Yv/8An4/8cX/CqNFHPLuHJHsXf7X1D/n4/wDHF/wpP7Y1D/n4/wDHF/wqnSEVUarW7JlST2Rd/tjUP+fj/wAcX/Cj+2NQ/wCfj/xxf8Ko0VtzPuY8q7BS5FJRUtXKTsZ+n6r9tnaLydmF3Z3Z7j2960c1zvh//j+f/rkf5iuhp1KUU9BQqSa1FzRmkoqPZov2jFzRmkoo9mg9oxc0ZpKKPZoPaMXNGaSij2aD2jFzRmkoo9mg9oxc0ZpKKPZoPaMXNZ0Oq+bqJtPJxhmXdu9M9se1aFc9af8AIxN/11k/rVwpRadyJVJKx0WRSUUUlGw27hRRRVCOe8P/APH8/wD1yP8AMV0NZWl6bNZ3LSStGQUK/KT6j29q1auo03oRBWQUUUVBYUUUUAFFFFABRRRQAUUUUAFFFFABXPWn/IxN/wBdZP610NZUGmzR6qbpmj2F2bAJzzn296uDSTIkr2NWiiioLCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD/2Q==";
const TALL = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCACgAHgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDuaKKKgoKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKK4Wis/aGnszuqK4YUtZPEWexoqF1udxRXD0UvrHkP6v5ncUVw9FH1jyD6v5ncUVw9FH1jyD6v5ncUVw9FH1jyD6v5ncUVwxpK0jV5lsZypWe53VFcLRVe0F7MKBRS1hOVkbwjdi0UUVzmwUUUUAFFFFABRRRQAUUUUAFNNOpKqMrMUo3QlFFFdBzhWJ4j/wCXf/gX9K26xPEf/Lv/AMC/pV0/iRM/hNSy/wCPG3/65L/Kp6gsv+PG3/65L/Kp6lpXKTdgooopWQXYUUUUWQXYUUUUWQXYUUUUWQXZBe/8eNx/1yb+VZfhz/l4/wCA/wBa1L3/AI8bj/rk38qy/Dn/AC8f8B/rWkV7jIb95G3RRRWZYVieI/8Al3/4F/StusTxH/y7/wDAv6VpT+JET+E1LL/jxt/+uS/yqeoLL/jxt/8Arkv8qnqHuUtgooooGFFFFABRRRQAUUUUAQXv/Hjcf9cm/lWX4c/5eP8AgP8AWtS9/wCPG4/65N/Ksvw5/wAvH/Af61a+BkP4kbdFFFQWFRyQxS482JHx03KDipKKAEUBVCqAABgAdqWiigAooooAKKKKACiiigAooooARgGUqwBBGCD3pkcMUWfKiRM9dqgZqSigAooooA//2Q==";

const MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], DAY = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
function words(iso, today) {
  const n = Math.round((Date.parse(iso) - Date.parse(today)) / 86400000);
  if (n === 0) return "Today"; if (n === 1) return "Tomorrow";
  const d = new Date(iso + "T12:00:00Z"); return `${DAY[d.getUTCDay()]} ${MON[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

(async () => {
  const q = async (sql, a = []) => (await admin.query(sql, a)).rows;
  const today = (await q("select local_today()::text as d"))[0].d;
  const hasComing = !!(await q("select 1 from pg_proc where proname = 'check_tv_coming'")).length;
  ok(`Database as expected: ${OLDDB ? "without" : "with"} tv_coming.sql`, hasComing === !OLDDB);

  // ---- the floor: twelve more jobs with delivery dates, one past, one not In Production, one test ----
  const names = ["Riverside Office", "Maple Clinic", "Northside Library", "Harbor Bank", "Oak Street Cafe", "Summit Church",
                 "Lakeview School", "Pine Dental", "Granite Law", "Elm Hotel Lobby", "Cedar Co-op", "Willow Studio"];
  for (let i = 0; i < names.length; i++)
    await q(`insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date)
             values ($1, $2, $3, true, 'In Production', local_today() + $4::int)`, [-880000 - i, `PROJ-00${600 + i}`, names[i], [0, 1, 2, 2, 4, 6, 8, 9, 13, 15, 21, 30][i]]);
  await q(`insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date) values
           (-880100, 'PROJ-00690', 'Past Date Job', true, 'In Production', local_today() - 2),
           (-880101, 'PROJ-00691', 'Delivered Job', false, 'Delivered', local_today())`);
  await q(`insert into jobs (monday_item_id, project_id, name, is_active, phase, delivery_date, is_test) values
           (-880102, 'TEST-00692', 'Test Lane Job', true, 'In Production', local_today(), true)`);

  // ---- two finished white glove deliveries with a site photo each, and the TV copies the phone made ----
  for (const [pid, b64, mins] of [["PROJ-00362", WIDE, 60], ["PROJ-00325", TALL, 40]]) {
    const j = (await q("select id from jobs where project_id = $1", [pid]))[0].id;
    const l = (await q(`insert into loadouts (job_id, kind, scheduled_for, completed_at, signed_name, signed_at)
                        values ($1, 'delivery', now() - interval '3 hours', now() - interval '20 minutes', 'A Customer', now() - interval '20 minutes') returning id`, [j]))[0].id;
    const cid = (await q("select gen_random_uuid() as u"))[0].u;
    const p = (await q(`insert into photos (client_id, job_id, sheet_number, department, kind, loadout_id, storage_path, taken_by_name, stage, piece, taken_at)
                        values ($1, $2, 1, 'delivery', 'loadout', $3, $4, 'test', 'site', 1, now() - make_interval(mins => $5)) returning id`,
                       [cid, j, l, `${pid}/${cid}.jpg`, mins]))[0].id;
    await q("insert into tv_photo_copies (photo_id, jpeg, bytes) values ($1, decode($2, 'base64'), $3)", [p, b64, Buffer.from(b64, "base64").length]);
  }
  const expected = await q(`select project_id, name, delivery_date::text as d from jobs
                             where is_active and not is_test and monday_item_id is not null and delivery_date >= local_today()
                             order by delivery_date, project_id limit 10`);

  // ---- the TV link, made the way the office makes it ----
  const luke = makeClient(users.luke);
  const link = await luke.rpc("new_tv_link");
  const key = link.data && (link.data.key || (link.data[0] && link.data[0].key));
  ok("A TV link is made from the office", !!key, JSON.stringify(link.error || ""));
  const anon = makeClient(null);

  const browser = await chromium.launch();
  async function open(viewport, pagePath = PAGE) {
    const page = await browser.newPage({ viewport });
    const errors = []; page.on("pageerror", e => errors.push(e.message));
    const fontDir = "/home/claude/sf/node_modules/@fontsource";
    await page.route("**/*", async (route) => {
      const u = route.request().url();
      if (/supabase\.co\/rest\/v1\/rpc\/(tv_snapshot|tv_photo)$/.test(u)) {
        const fn = u.split("/").pop(), args = JSON.parse(route.request().postData() || "{}");
        const r = await anon.rpc(fn, args);
        if (r.error) return route.fulfill({ status: /does not exist/.test(r.error.message) ? 404 : 400, contentType: "application/json", body: JSON.stringify(r.error) });
        let v = r.data; if (Array.isArray(v) && v.length === 1 && v[0][fn] !== undefined) v = v[0][fn];
        return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(v) });
      }
      if (/fonts\.googleapis\.com/.test(u) && fs.existsSync(fontDir)) {
        const face = (fam, dir, w) => `@font-face{font-family:'${fam}';font-weight:${w};src:url(https://fonts.gstatic.com/${dir}/${w}.woff2) format('woff2')}`;
        return route.fulfill({ status: 200, contentType: "text/css", body: [400, 500, 600, 700].map(w => face("Barlow", "barlow", w)).join("") + [500, 600, 700].map(w => face("Barlow Condensed", "barlow-condensed", w)).join("") });
      }
      const g = /fonts\.gstatic\.com\/(barlow(?:-condensed)?)\/(\d+)\.woff2/.exec(u);
      if (g) return route.fulfill({ status: 200, contentType: "font/woff2", body: fs.readFileSync(`${fontDir}/${g[1]}/files/${g[1]}-latin-${g[2]}-normal.woff2`) });
      if (u.startsWith("file:")) return route.continue();
      return route.abort();
    });
    await page.clock.install({ time: new Date(`${today}T15:00:05`) });
    await page.clock.resume();
    await page.goto("file://" + path.resolve(pagePath) + "#k=" + key);
    await page.waitForSelector(".main", { timeout: 20000 }).catch(() => {});      // the first snapshot (a cold database can be slow)
    await page.waitForFunction(() => !document.querySelector(".home .waiting") || !/Loading/.test(document.querySelector(".home .waiting").textContent), null, { timeout: 15000 }).catch(() => {});
    await wait(1500);
    return { page, errors };
  }
  const state = (page) => page.evaluate(() => {
    const img = document.querySelector(".home .img"), home = document.querySelector(".home"), floor = document.querySelector(".floor");
    const coming = document.querySelector(".coming");
    const rows = [...document.querySelectorAll(".crow")].map(r => ({ w: r.querySelector(".cw").textContent, p: r.querySelector(".cp").textContent,
      n: r.querySelector(".cn").textContent, h: r.getBoundingClientRect().height, fs: parseFloat(getComputedStyle(r).fontSize),
      colors: [...r.querySelectorAll("span")].map(s => getComputedStyle(s).color) }));
    return { bg: img ? getComputedStyle(img).backgroundImage.slice(0, 30) : null, tall: img ? img.classList.contains("tall") : null,
             label: img ? img.getAttribute("aria-label") : null, cap: (document.querySelector(".home .cap") || {}).textContent || "",
             picOnTop: !!(home && floor && home.getBoundingClientRect().top < floor.getBoundingClientRect().top),
             picW: home ? home.getBoundingClientRect().width : 0, picH: home ? home.querySelector(".pic").getBoundingClientRect().height : 0,
             bar: (() => { const b = document.querySelector(".floor .bar"); if (!b) return null; const W = b.getBoundingClientRect().width;
               const part = (c) => { const e = b.querySelector("i." + c); return e ? { w: e.getBoundingClientRect().width / W, bg: getComputedStyle(e).backgroundColor } : null; };
               return { done: part("done"), ready: part("ready"), pct: (document.querySelector(".floor .pct") || {}).textContent || "",
                        words: (document.querySelector(".floor .fs") || {}).textContent || "", donut: !!document.querySelector(".donut, svg circle") }; })(),
             coming: !!coming, fits: coming ? coming.scrollHeight <= coming.clientHeight + 1 : null, rows,
             text: document.getElementById("app").textContent };
  });

  const { page, errors } = await open({ width: 1920, height: 1080 });
  let s = await state(page);

  // ---- the picture is drawn: the database's line-broken base64 still makes a picture ----
  ok("The delivered table's picture is drawn (not a blank panel)", !!s.bg && s.bg.startsWith('url("data:image/jpeg;base64,'), `background: ${s.bg}`);
  const first = s;
  await page.clock.fastForward(20000); await wait(400);
  const second = await state(page);
  const shown = [first, second];
  const tallOne = shown.find(x => /00325/.test(x.label || "")), wideOne = shown.find(x => /00362/.test(x.label || ""));
  ok("Both pictures take turns, each drawn", !!tallOne && !!wideOne && shown.every(x => x.bg && x.bg.startsWith('url("data')),
     shown.map(x => x.label + " " + x.bg).join(" | "));
  if (NEWPAGE) {
    ok("An upright photo is shown whole (contain); a wide one fills the panel", tallOne && tallOne.tall === true && wideOne && wideOne.tall === false);
    ok("Option B: the picture is on top of the left column, the floor bar under it", s.picOnTop, `picture ${Math.round(s.picW)}×${Math.round(s.picH)} px`);
    const LIVE = "/home/claude/sf/repo/tv.html";
    if (!OLDDB && path.resolve(LIVE) !== path.resolve(PAGE) && !/function comingWords/.test(fs.readFileSync(LIVE, "utf8"))) {
      const o = await open({ width: 1920, height: 1080 }, LIVE); const b = await state(o.page); await o.page.close();
      ok("The picture is at least twice the size it was on 7 Oct's page", s.picW * s.picH >= 2 * b.picW * b.picH,
         `${Math.round(b.picW)}×${Math.round(b.picH)} → ${Math.round(s.picW)}×${Math.round(s.picH)} px`);
    }
  }
  if (SHOTS) { fs.mkdirSync(SHOTS, { recursive: true }); await page.screenshot({ path: `${SHOTS}/tv-${NEWPAGE ? "new" : "old"}page-${OLDDB ? "old" : "new"}db.png` }); }

  // ---- all work on the floor: one bar in place of the donut ----
  if (NEWPAGE) {
    const sv = (await anon.rpc("tv_snapshot", { p_key: key })).data, dn = sv.donut, waiting = dn.total - dn.finished - dn.ready;
    const b = s.bar, pct = Math.floor(dn.finished / dn.total * 100);
    ok("All work on the floor is one bar, the donut is gone", !!b && !b.donut);
    ok("It says how much is done, in whole percent, never rounded up to 100", b && b.pct.replace(/\s+/g, "") === pct + "%done", `${b && b.pct} (${dn.finished} of ${dn.total})`);
    ok("The bar's done and ready parts match the database's numbers",
       b && Math.abs(b.done.w - dn.finished / dn.total) < 0.01 && Math.abs(b.ready.w - dn.ready / dn.total) < 0.01,
       b && `done ${b.done.w.toFixed(3)} vs ${(dn.finished / dn.total).toFixed(3)}, ready ${b.ready.w.toFixed(3)} vs ${(dn.ready / dn.total).toFixed(3)}`);
    ok("Turquoise for done, Purposeful Orange for ready to work on", b && b.done.bg === "rgb(0, 180, 178)" && b.ready.bg === "rgb(237, 94, 15)");
    ok("In words: pieces ready to work on now, and how many wait on an earlier step",
       b && b.words.replace(/\s+/g, " ").trim() === `${dn.ready} pieces ready to work on now · ${waiting} waiting on an earlier step`, b && b.words);
  }

  // ---- the right-hand panel ----
  if (NEWPAGE && !OLDDB) {
    ok("Coming up replaces the department rows: no Pieces ready, no pace", s.coming && !/Pieces ready|A usual week|This week so far/.test(s.text));
    ok("Coming up lists the next 10 jobs, earliest delivery first, as the database orders them",
       s.rows.length === 10 && s.rows.every((r, i) => expected[i] && r.p === expected[i].project_id.replace(/^PROJ-/, "") && r.n === expected[i].name),
       s.rows.map(r => r.p).join(","));
    ok("Each date is in words: Today, Tomorrow, then Thu Oct 22", s.rows.every((r, i) => r.w === words(expected[i].d, today)), s.rows.map(r => r.w).join(", "));
    ok("Never a past date, a job not In Production or a test job", !/Past Date Job|Delivered Job|Test Lane Job/.test(s.text));
    const allowed = new Set(["rgb(255, 244, 213)", "rgb(163, 169, 188)"]);
    ok("Words only: no deadline colour on any row (Sawdust and gray only)", s.rows.every(r => r.colors.every(c => allowed.has(c))), [...new Set(s.rows.flatMap(r => r.colors))].join(" "));
    ok("All 10 rows fit, none squashed below its text", s.fits && s.rows.every(r => r.h >= r.fs * 1.05), s.rows.map(r => Math.round(r.h)).join(","));
  } else {
    ok("The department rows show as before (Pieces ready and pace)", !s.coming && /Pieces ready/.test(s.text));
  }
  ok("No script errors", errors.length === 0, errors.join(" | "));
  await page.close();

  // ---- with two bands up (a critical flag and work stopped), Coming up still fits; also at a 4K TV's size ----
  if (NEWPAGE && !OLDDB) {
    const j = (await q("select id from jobs where project_id = 'PROJ-00600'"))[0].id;
    await q("insert into flags (job_id, level, note) values ($1, 'critical', 'Hold the top until the new stain sample is approved')", [j]);
    const dept = (await q("select key from departments where is_live and not log_only order by sort_order limit 1"))[0];
    if (dept) await q("insert into problems (job_id, sheet_number, department, body, work_stopped, status) values ($1, 1, $2, 'Waiting on the router bit', true, 'open')", [j, dept.key]);
    for (const vp of [{ width: 1920, height: 1080 }, { width: 3840, height: 2160 }, { width: 1366, height: 768 }]) {
      const o = await open(vp); const t = await state(o.page);
      ok(`${vp.width}×${vp.height} with two bands: all 10 rows fit and the picture still shows`,
         t.fits && t.rows.length === 10 && t.rows.every(r => r.h >= r.fs * 1.05) && t.bg && t.bg.startsWith('url("data') && t.bar && t.bar.done,
         t.rows.map(r => Math.round(r.h)).join(",") + " " + t.bg);
      if (SHOTS && vp.width === 1920) await o.page.screenshot({ path: `${SHOTS}/tv-newpage-newdb-bands.png` });
      await o.page.close();
    }
  }
  await browser.close();
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await admin.end().catch(() => {});
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
