# Testing kit, part 11 — Finish-by dates (25 Sep 2026)

*For build chats. Luke doesn't need to read this.* `testing-kit.md` (environment, "test as a real login") and `testing-kit-nav.md` still apply. This part adds a **faster, more faithful stand-in**: the database is built from **every live SQL file, unchanged**, straight out of the project's `.md` files, each loaded twice.

## Setup that worked (25 Sep)

- `apt-get update` first — the package list was stale and Postgres 16 downloads 404'd without it. Background jobs (`&`) get killed in this sandbox: run installs in the foreground.
- Postgres 16 + pg_cron + the `http` extension built from source, exactly as `testing-kit.md` §1. `npm install jsdom@24 pg fake-indexeddb playwright@1.56.0` in `/home/claude`; Chromium at `/opt/pw-browsers/chromium-1194`.
- `extract.py` pulls every file out of `sql-files*.md` and `site-files.md` into `live/` (the largest code block under each ``## `name` `` heading). Every file round-trips byte for byte.
- `stubs.sql` and `people.sql` = Part 3's (`testing-kit-photos.md`), plus Jim W (9999, Finishing).
- `pgsupa.js` = Part 3's, plus the JSON-argument patch below.
- `load.sh` builds `sync` from every live file (twice each), then unschedules pg_cron's jobs so nothing calls the real Monday. **pg_cron keeps a connection open to `sync`**, so to snapshot it: `select pg_terminate_backend(pid) from pg_stat_activity where datname='sync'` then `create database sync_base template sync` in the same psql call. `fresh.sh` then copies `sync_base` in about a second.
- Before this build, on that database: `check_floor` 18, `check_ready_issues` 14, `check_advance` 10, `check_test_lane` 10 — all PASS.

## Results when delivered

| Test | Result |
|---|---|
| `finish_by.sql` loaded twice on a seeded database; `check_finish_by()` each time | 12/12 PASS both times, nothing left behind |
| Every earlier check after it (`verify_setup` … `check_ready_issues`) | All PASS |
| `breaks.py` — 12 broken versions of the SQL | Each fails the check at its own step |
| `test_fb_tablet.js` — real `index.html`, each login, against the database: cards, words, no colour, sort order, job header, Metal label, managers' menu, Test Supervisor, Monday date moving, a number changed, offline, dates-only failure, file not run | 27/27 |
| `test_fb_office.js` — real `office.html`: grid dates, Done, past, no date, TEST copy, Setup save / refuse / nothing changed / history, supervisor refused by the database, file not run | 23/23 |
| `test_nav_tablet.js` / `test_office_nav.js` (Part 9) on the new pages | 25/25 · 36/36 (one test line changed on purpose: it reads the heading's first text node, since the date now sits under the name) |
| Screens (`snap_fb.js` + `shoot_fb.js`) | Looked right after two fixes: the job header now wraps rather than cut off the date; Setup's number boxes were full width (`input.in` is 100%; the rule needs `.panel .fbrow input.in`) |

**The check's own bug the breaks caught:** step 12 first read all three objects in one statement as no-login; reading `v_finish_by` is refused (no execute on `sees_lane`), and that refusal counted as a pass for the table too. Each object is now read on its own.

Not covered: the real SQL Editor, real GitHub Pages, a real tablet.

## Files

#### extract.py
```python
import re,sys
for src in sys.argv[1:]:
    t=open(src).read()
    parts=re.split(r'^## `([^`]+)`\s*$',t,flags=re.M)
    for i in range(1,len(parts),2):
        name=parts[i]; body=parts[i+1]
        m=re.search(r'^(```+|~~~+)[a-z]*\n(.*?)^\1\s*$',body,flags=re.S|re.M)
        if not m: print("NO BLOCK",name); continue
        # take the largest code block
        blocks=re.findall(r'^(```+|~~~+)[a-zA-Z]*\n(.*?)^\1\s*$',body,flags=re.S|re.M)
        b=max(blocks,key=lambda x:len(x[1]))[1]
        open('live/'+name,'w').write(b); print(name,len(b),len(blocks))
```

#### load.sh
```bash
#!/bin/bash
# the 'sync' test database built from every live SQL file, unchanged, each loaded twice; then any extra files given (twice)
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
L=/home/claude/sf/live
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync" >/dev/null
cd /home/claude/sf/base
$P -d sync -f stubs.sql
$P -d sync -c "create extension http with schema extensions; create extension pg_cron;" >/dev/null
for f in schema verify_setup upload_function monday_sync tablet office test_lane catch_up problems flags routine_tasks supplies arrow_qc tv; do
  $P -d sync -f $L/$f.sql >/dev/null; $P -d sync -f $L/$f.sql >/dev/null; done
$P -d sync -c "select cron.unschedule(jobname) from cron.job" >/dev/null 2>&1 || true
$P -d sync -f people.sql
$P -d sync -c "select set_person('test@example.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true)" >/dev/null
for f in check_floor photos check_photos advance supply_lists loadouts_v2 deliveries deliveries_v2 ready_issues; do
  $P -d sync -f $L/$f.sql >/dev/null; $P -d sync -f $L/$f.sql >/dev/null; done
$P -d sync -c "select cron.unschedule(jobname) from cron.job" >/dev/null 2>&1 || true
for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f" >/dev/null; $P -d sync -f "$f" > /tmp/last_load.out; done
echo LOADED
```

#### fresh.sh
```bash
#!/bin/bash
# fresh database from the snapshot (every live file) + the given files (twice) + seed
P="psql -h /tmp/pg -p 5433 -U postgres -q -v ON_ERROR_STOP=1"
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base" >/dev/null || exit 1
for f in "$@"; do $P -d sync -f "$f" >/dev/null 2>/tmp/load.err || { echo LOAD FAILED $f; cat /tmp/load.err; exit 1; }; $P -d sync -f "$f" >/dev/null 2>&1; done
$P -d sync -f /home/claude/sf/base/seed.sql >/tmp/seed.out 2>&1 || { echo SEED FAILED; head /tmp/seed.out; exit 1; }
echo SEEDED
```

#### seed.sql — additions after Part 3's seed
```sql
-- finish-by cases: a job due soon (so early departments are past), and one with no delivery date
insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages)
values (14000000001,'PROJ-00501','Soon Cafe', local_today()+12,'In Production',true,true,true,'{}'),
       (14000000002,'PROJ-00502','No Date Hotel', null,'In Production',true,true,true,'{}');
do $$
declare w uuid; s uuid; p text; i int;
begin
  foreach p in array array['PROJ-00501','PROJ-00502'] loop
    insert into work_orders (job_id) select id from jobs where project_id=p returning id into w;
    for i in 1..2 loop
      insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
        values (w, i, 2, 'CT-0'||i, 'Oak', format('%s/v1/sheet-%s.png',p,i), format('%s/v1/sheet-%s.pdf',p,i), now()) returning id into s;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done)
        select s, d, 2, case when d in ('milling','cnc') then 2 else 0 end from unnest(array['milling','cnc','sanding','finishing','metal','assembly_qc']) d;
    end loop;
  end loop;
end $$;
```

#### pgsupa.js — the JSON-argument patch (on Part 3's file)
```javascript
// above `const retSet = new Map();`
const jsonCache = new Map();
async function jsonArgs(fn) {
  if (!jsonCache.has(fn)) {
    const r = await admin.query(`select a.n from pg_proc p, unnest(p.proargnames, p.proargtypes::oid[]) as a(n, t)
      where p.proname = $1 and p.pronamespace = 'public'::regnamespace and a.t in ('jsonb'::regtype, 'json'::regtype)`, [fn]).catch(() => ({ rows: [] }));
    jsonCache.set(fn, new Set(r.rows.map(x => x.n)));
  }
  return jsonCache.get(fn);
}
// in client.rpc, replacing `const params = names.map(n => args[n]);`
const jt = await jsonArgs(fn);
const params = names.map(n => (jt.has(n) && args[n] !== null && typeof args[n] === "object") ? JSON.stringify(args[n]) : args[n]);
```

#### breaks.py
```python
import subprocess, re
good = open('/home/claude/sf/out/finish_by.sql').read()
B = {
 "1 missing start number": [("('milling', 21), ('cnc', 18), ", "('cnc', 18), ")],
 "2 days not subtracted": [("j.delivery_date - n.days                       as finish_by", "j.delivery_date                                as finish_by")],
 "3 moved off weekends": [("j.delivery_date - n.days                       as finish_by", "j.delivery_date - n.days - case extract(dow from j.delivery_date - n.days)::int when 6 then 1 when 0 then 2 else 0 end as finish_by")],
 "4 blank date filled": [("j.delivery_date - n.days                       as finish_by", "coalesce(j.delivery_date, local_today()) - n.days as finish_by")],
 "5 done with no pieces": [("(coalesce(p.pieces_required, 0) > 0\n     and coalesce(p.pieces_done, 0) >= p.pieces_required) as all_done", "(coalesce(p.pieces_done, 0) >= coalesce(p.pieces_required, 0)) as all_done")],
 "6 no manager check": [("  if not office_ok() then\n    raise exception 'Only a manager can change the finish-by days.'", "  if false then\n    raise exception 'Only a manager can change the finish-by days.'")],
 "7 direct writes allowed": [("revoke all on finish_by_days from anon;", "revoke all on finish_by_days from anon;\ngrant insert on finish_by_days to authenticated;\ndrop policy if exists w on finish_by_days; create policy w on finish_by_days for insert to authenticated with check (true);")],
 "8 change overwrites history": [("  insert into finish_by_days (department, days, set_by, set_by_name)\n    values (p_department, p_days, auth.uid(), my_name());",
                                  "  update finish_by_days set days = p_days, set_by = auth.uid(), set_by_name = my_name() where department = p_department;")],
 "9 delivery accepted": [("  if v_dept.log_only then", "  if false then"), ("references departments(key),", "references departments(key),")],
 "10 lanes mixed": [("where sees_lane(j.is_test);", ";")],
 "12 table open without login": [("revoke all on finish_by_days from anon;", "grant select on finish_by_days to anon; drop policy if exists a on finish_by_days; create policy a on finish_by_days for select to anon using (true);")],
 "11 open without login": [("revoke all on v_finish_by from anon;", "grant select on v_finish_by to anon;"), ("revoke all on v_finish_by_days from anon;", "grant select on v_finish_by_days to anon;"),
                           ("revoke all on finish_by_days from anon;", "grant select on finish_by_days to anon; drop policy if exists a on finish_by_days; create policy a on finish_by_days for select to anon using (true);")],
}
P = "psql -h /tmp/pg -p 5433 -U postgres -q"
for name, reps in B.items():
    s = good
    for a, b in reps:
        assert a in s, (name, a[:40]); s = s.replace(a, b, 1)
    open('/tmp/broken.sql', 'w').write(s)
    subprocess.run(f'{P} -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base"', shell=True, capture_output=True)
    r = subprocess.run(f'{P} -d sync -v ON_ERROR_STOP=1 -At -F"|" -f /tmp/broken.sql', shell=True, capture_output=True, text=True)
    fails = [l.split('|')[0] for l in r.stdout.splitlines() if '|FAIL|' in l]
    print(f"{name:32} -> failed steps {fails}" + (f"  LOAD ERR {r.stderr[-150:]}" if r.returncode else ""))
```

#### test_fb_tablet.js
```javascript
// Finish-by dates on the tablet: the real index.html in jsdom, against the real test database (pgsupa.js), through each login.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const FILE = process.env.APP || "../out/index.html";
const html = fs.readFileSync(FILE, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client; return w;
}
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const click = async (w, el, p = 120) => { (typeof el === "string" ? $(w, el) : el).click(); await wait(p); };
const card = (w, pid) => $$(w, "button.job").find(b => b.textContent.includes(pid));
const dueOf = (w, pid) => { const c = card(w, pid); const d = c && c.querySelector(".due"); return !d ? null : d.classList.contains("fb") ? [...d.children].map(x => x.textContent.trim()).join(" | ") : d.textContent.trim(); };
const M = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const fmt = (d) => `${M[d.getMonth()]} ${d.getDate()}`;
const today = new Date(); const t0 = new Date(today.getFullYear(), today.getMonth(), today.getDate());
const addDays = (iso, n) => { const [y, m, d] = iso.split("-").map(Number); return new Date(y, m - 1, d + n); };
const left = (dt) => Math.round((dt - t0) / 86400000);
const words = (n) => n > 0 ? `${n} day${n === 1 ? "" : "s"} left` : n === 0 ? "today" : `${-n} day${n === -1 ? "" : "s"} past`;

(async () => {
  // core
  const core = fs.readFileSync(FILE, "utf8"); fs.writeFileSync("/tmp/fb_core.js", [...core.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  const C = require("/tmp/fb_core.js");
  ok("core: words — 4 days left / 1 day left / today / 1 day past / 3 days past",
     [4, 1, 0, -1, -3].map(C.finishWords).join(",") === "4 days left,1 day left,today,1 day past,3 days past");
  const now = new Date(2026, 8, 25);
  ok("core: Done by Oct 1 · 6 days left, Delivery Oct 22", JSON.stringify(C.dateLine({ fb_label: "Done by", finish_by: "2026-10-01", delivery_date: "2026-10-22" }, false, now))
     === JSON.stringify({ main: "Done by Oct 1", when: "6 days left", delivery: "Delivery Oct 22" }));
  ok("core: all pieces done says Done instead of a countdown", C.dateLine({ fb_label: "Done by", finish_by: "2026-09-20", delivery_date: "2026-10-11" }, true, now).when === "Done");
  ok("core: no delivery date", C.dateLine({ fb_label: "Done by", finish_by: null, delivery_date: null }, false, now).main === "No delivery date");
  ok("core: without finish-by data, null (the old line shows)", C.dateLine({ delivery_date: "2026-10-22" }, false, now) === null);

  const d418 = (await one("select delivery_date::text d from jobs where project_id='PROJ-00418'")).d;
  const d501 = (await one("select delivery_date::text d from jobs where project_id='PROJ-00501'")).d;
  const d099 = (await one("select delivery_date::text d from jobs where project_id='PROJ-00099'")).d;

  // ---- Mike, Sanding (14) ----
  let w = boot(users.mike);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00502"));
  let s = addDays(d418, -14);
  ok("Mike, Sanding: PROJ-00418 card says its Sanding date and the delivery date smaller",
     dueOf(w, "PROJ-00418") === `Done by ${fmt(s)} · ${words(left(s))} | Delivery ${fmt(addDays(d418, 0))}`, dueOf(w, "PROJ-00418"));
  ok("...the delivery date is the small line", !!card(w, "PROJ-00418").querySelector(".due small.deliv"));
  s = addDays(d501, -14);
  ok("a job past its Sanding date says days past, in words", dueOf(w, "PROJ-00501") === `Done by ${fmt(s)} · ${words(left(s))} | Delivery ${fmt(addDays(d501, 0))}` && /past/.test(dueOf(w, "PROJ-00501")), dueOf(w, "PROJ-00501"));
  ok("no delivery date on Monday: 'No delivery date'", dueOf(w, "PROJ-00502") === "No delivery date", dueOf(w, "PROJ-00502"));
  const style = [...w.document.querySelectorAll("style")].map(x => x.textContent).join("");
  ok("no colour: the date line has no colour class or inline colour", !/style=/.test(card(w, "PROJ-00501").querySelector(".due").outerHTML) && !/\.due\.fb[^}]*(background|border)/.test(style));
  const order = $$(w, "button.job").map(b => (b.textContent.match(/PROJ-\d+/) || [""])[0]);
  ok("sort order unchanged: soonest delivery first, no date last", order.join(",") === "PROJ-00501,PROJ-00099,PROJ-00418,PROJ-00502", order.join(","));
  // job page
  await click(w, card(w, "PROJ-00418"), 250);
  s = addDays(d418, -14);
  const hsub = $(w, ".hsub").textContent;
  ok("job page header uses the Sanding date the same way", hsub.includes(`Done by ${fmt(s)} · ${words(left(s))} · 5 of 20 pieces done · Delivery ${fmt(addDays(d418, 0))}`), hsub);

  // Mike switches to Finishing (10)
  await click(w, '[data-back="queue"]', 150);
  await click(w, $$(w, "header .tab").find(b => /Finishing/.test(b.textContent)), 400);
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  s = addDays(d418, -10);
  ok("Mike's Finishing tab: Finishing's own date (10 days before)", dueOf(w, "PROJ-00418").startsWith(`Done by ${fmt(s)} · `), dueOf(w, "PROJ-00418"));
  w.close();

  // ---- Willie, Metal: the paint / powdercoat label ----
  w = boot(users.willie);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  s = addDays(d418, -18);
  ok("Willie, Metal: 'To paint / PC by' 18 days before", dueOf(w, "PROJ-00418").startsWith(`To paint / PC by ${fmt(s)} · ${words(left(s))}`), dueOf(w, "PROJ-00418"));
  w.close();

  // ---- a finished job page says Done ----
  await admin.query(`update sheet_progress sp set qty_done = qty_required from sheets s, work_orders wo, jobs j
    where s.id = sp.sheet_id and wo.id = s.work_order_id and j.id = wo.job_id and j.project_id = 'PROJ-00099' and sp.department = 'cnc'`);
  w = boot(users.donnie);
  await until(() => $$(w, "header .tab").length);
  await click(w, $$(w, "header .tab").find(b => /CNC/.test(b.textContent)), 400);
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00418"));
  ok("a job CNC has finished leaves CNC's list, as before", !card(w, "PROJ-00099"));
  await click(w, $$(w, "header .tab").find(b => /Milling/.test(b.textContent)), 400);
  ok("Milling (all done on every job): 'Nothing waiting', as before", /Nothing waiting/.test($(w, "#app").textContent));
  w.close();
  // Mike finishes the last sheet of a job while on its page
  w = boot(users.mike);
  await until(() => card(w, "PROJ-00501") && card(w, "PROJ-00501").querySelector(".due.fb"));
  await click(w, card(w, "PROJ-00501"), 250);
  for (const b of $$(w, "[data-sheet]")) { await click(w, $$(w, "[data-sheet]").find(x => x.dataset.sheet === b.dataset.sheet), 250); if ($(w, "[data-all]")) await click(w, "[data-all]", 250); await click(w, '[data-back="job"]', 200); }
  ok("finishing every piece while on the job page: the header says Done", / · Done · 4 of 4 pieces done/.test($(w, ".hsub").textContent), $(w, ".hsub").textContent);
  w.close();

  // ---- Monday moves the delivery date: every date follows ----
  await admin.query("update jobs set delivery_date = delivery_date + 7 where project_id = 'PROJ-00418'");
  w = boot(users.willie);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  s = addDays(d418, 7 - 18);
  ok("after Monday's date moves a week, Metal's date moves a week", dueOf(w, "PROJ-00418").startsWith(`To paint / PC by ${fmt(s)}`), dueOf(w, "PROJ-00418"));

  // ---- the office changes a number ----
  await makeClient(users.luke).rpc("set_finish_by_days", { p_department: "metal", p_days: 20 });
  w.close(); w = boot(users.willie);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  s = addDays(d418, 7 - 20);
  ok("after Luke sets Metal to 20, Willie's cards follow", dueOf(w, "PROJ-00418").startsWith(`To paint / PC by ${fmt(s)}`), dueOf(w, "PROJ-00418"));

  // ---- no connection: the saved list keeps its dates ----
  const saved = { sf_me: w.localStorage.getItem("sf_me"), sf_rows_metal: w.localStorage.getItem("sf_rows_metal") };
  w.close();
  setOffline(true);
  w = boot(users.willie, saved);
  await until(() => card(w, "PROJ-00418"));
  ok("offline: the saved list still shows the finish-by dates", (dueOf(w, "PROJ-00418") || "").startsWith(`To paint / PC by ${fmt(s)}`), dueOf(w, "PROJ-00418"));
  setOffline(false); w.close();

  // ---- the dates can't be read this time, but could before: keep them ----
  w = boot(users.willie, saved);
  const realFrom = w.client.from;
  w.client.from = (t) => t === "v_finish_by" ? { select: () => ({ eq: () => ({ in: async () => ({ data: null, error: { message: "TypeError: Failed to fetch" } }) }) }) } : realFrom(t);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  ok("if only the dates fail to load, the tablet keeps the dates it last had", (dueOf(w, "PROJ-00418") || "").startsWith(`To paint / PC by ${fmt(s)}`), dueOf(w, "PROJ-00418"));
  w.close();

  // ---- finish_by.sql not run: exactly the old line ----
  await admin.query("revoke select on v_finish_by from authenticated");
  w = boot(users.kp);
  await until(() => card(w, "PROJ-00418"));
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00099"));
  const dd = addDays(d099, 0);
  ok("without the database part, cards keep today's 'Due … · n days' line", dueOf(w, "PROJ-00099") === `Due ${fmt(dd)} · ${left(dd)} days` && !card(w, "PROJ-00099").querySelector(".due.fb"), dueOf(w, "PROJ-00099"));
  ok("...and no warning banner about it", !/isn't set up in the database/.test($(w, "#app").textContent));
  await admin.query("grant select on v_finish_by to authenticated");
  w.close();

  // ---- Luke's Department ▾ menu: the date follows the department picked ----
  w = boot(users.luke);
  await until(() => $(w, "[data-deptmenu]"));
  await click(w, "[data-deptmenu]"); await click(w, '[data-dept="assembly_qc"]', 500);
  if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "PROJ-00418") && card(w, "PROJ-00418").querySelector(".due.fb"));
  s = addDays(d418, 7 - 3);
  ok("Luke picks Assembly / QC: 3 days before delivery", dueOf(w, "PROJ-00418").startsWith(`Done by ${fmt(s)}`), dueOf(w, "PROJ-00418"));
  await click(w, "[data-deptmenu]"); await click(w, '[data-dept="delivery"]', 500);
  ok("Delivery's areas are unchanged (no job cards, no finish-by)", !!$(w, '[data-tab="loadout"]') && !$(w, ".due.fb"));
  w.close();

  // ---- Test Supervisor: the test copy has the same numbers ----
  w = boot(users.test);
  await until(() => $(w, "[data-deptmenu]"));
  await click(w, "[data-deptmenu]"); await click(w, '[data-dept="sanding"]', 500);
  await until(() => $(w, '[data-qmode="all"]')); await click(w, '[data-qmode="all"]', 200);
  await until(() => card(w, "TEST-00418") && card(w, "TEST-00418").querySelector(".due.fb"));
  const tD = (await one("select delivery_date::text d from jobs where project_id='TEST-00418'")).d;
  s = addDays(tD, -14);
  ok("the Test Supervisor's TEST-00418 uses the same Sanding number", dueOf(w, "TEST-00418").startsWith(`Done by ${fmt(s)}`), dueOf(w, "TEST-00418"));
  const asked = w.client.log.filter(l => l.table === "v_finish_by").length;
  ok("the tablet asked the database for the dates (one view, per department)", asked >= 1);
  w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_fb_office.js
```javascript
// Finish-by dates in the office: the job page grid and Setup → Finish-by days. Real office.html, real test database.
// The real office.html in jsdom against the real test database (pgsupa.js), as Luke.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.OFFICE || "../out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, preload = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.supabase = { createClient: () => client };
  w.confirm = () => true; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const badge = (w) => { const n = $(w, '.tab[data-tab="tasks"] .n'); return n ? Number(n.textContent) : 0; };
async function signedIn(w) { await until(() => /This is my own computer/.test(txt(w)) || $(w, ".tab")); if ($(w, "[data-nopin]")) await click(w, "[data-nopin]", 300); await until(() => $(w, ".tab")); await wait(400); }

const M = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const fmt = (iso) => { const [y, m, d] = iso.split("-").map(Number); return `${M[m - 1]} ${d}`; };
async function openJob(w, q) {
  $(w, "[data-jobfind]").focus(); await wait(300);
  const box = $(w, "[data-jobfind]"); box.value = q; box.dispatchEvent(new w.Event("input")); await wait(80);
  box.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" })); await wait(50); await until(() => $(w, ".grid .gh") || /No work order/.test(txt(w))); await wait(150);
}
const heads = (w) => $$(w, ".grid .gh").map(h => ({ name: h.firstChild.textContent, date: h.querySelector(".fbd") ? h.querySelector(".fbd").innerHTML.replace(/<br>/, " | ").replace(/<\/?b>/g, "") : null }));
async function setup(w) { await click(w, "[data-menu]"); await click(w, ".menu [data-tab='setup']", 300); await until(() => /Finish-by days/.test(txt(w)) && ($(w, "[data-fbdays]") || /aren't set up/.test(txt(w)))); await wait(100); }

(async () => {
  const exp = async (proj) => (await admin.query("select department, finish_by::text f, days_left n, all_done, label from v_finish_by where project_id = $1", [proj])).rows;
  let w = boot(users.luke); await signedIn(w);

  // ---- the job page ----
  await openJob(w, "418");
  const e418 = await exp("PROJ-00418"), d418 = (await one("select delivery_date::text d from jobs where project_id='PROJ-00418'")).d;
  const DN = { milling: "Milling", cnc: "CNC", sanding: "Sanding", finishing: "Finishing", metal: "Metal", assembly_qc: "Assembly / QC" };
  const words = (r) => r.all_done ? "Done" : r.n > 0 ? `${r.n} day${r.n === 1 ? "" : "s"} left` : r.n === 0 ? "today" : `${-r.n} day${r.n === -1 ? "" : "s"} past`;
  await until(() => $$(w, ".grid .gh").length); const h = heads(w); if (!h.length) console.log("DEBUG", txt(w).slice(0, 400));
  const bad = h.filter(x => { const r = e418.find(e => DN[e.department] === x.name); return !r || x.date !== `${r.label} ${fmt(r.f)} | ${words(r)}`; });
  ok("PROJ-00418: each department's date and days under its column heading, from the database", h.length === 6 && bad.length === 0, h.map(x => `${x.name}: ${x.date}`).join("; "));
  ok("Milling and CNC (finished on this job) say Done", h.filter(x => /\| Done$/.test(x.date)).map(x => x.name).join(",") === "Milling,CNC");
  ok("Metal's column says 'To paint / PC by'", /^To paint \/ PC by/.test(h.find(x => x.name === "Metal").date));
  ok("the delivery date stays in the header", new RegExp(`due ${fmt(d418)}`).test($(w, ".jobhead .sub").textContent), $(w, ".jobhead .sub").textContent);
  ok("no colour on the dates (plain text)", !$$(w, ".grid .gh .fbd").some(x => x.getAttribute("style")));
  await click(w, "[data-jobback]", 200);
  await openJob(w, "00501");
  ok("PROJ-00501 (due soon): past dates say days past", heads(w).some(x => /days? past$/.test(x.date)), heads(w).map(x => x.date).join("; "));
  await click(w, "[data-jobback]", 200);
  await openJob(w, "00502");
  ok("PROJ-00502: no delivery date on Monday → 'No delivery date' under each column", heads(w).every(x => x.date === "No delivery date"), heads(w).map(x => x.date).join("; "));
  await click(w, "[data-jobback]", 200);
  await openJob(w, "TEST-00418");
  ok("the TEST copy: same numbers as the real job", heads(w).length === 6 && heads(w).every(x => !!x.date));
  await click(w, "[data-jobback]", 200);

  // ---- Setup ----
  await setup(w);
  const rows = $$(w, "[data-fbdays]").map(i => `${i.dataset.fbdays}=${i.value}`).join(",");
  ok("Setup lists seven departments with their numbers, in shop order", rows === "milling=21,cnc=18,sanding=14,finishing=10,full_custom=16,metal=18,assembly_qc=3", rows);
  ok("no Delivery row", !$(w, '[data-fbdays="delivery"]'));
  ok("each says 'Starting number' until changed; no change list yet", $$(w, ".fbrow .who").every(x => x.textContent === "Starting number") && !$$(w, "details.more summary").some(x => x.textContent === "Every change"));
  let box = $(w, '[data-fbdays="metal"]'); box.value = "20";
  await click(w, '[data-fbsave="metal"]', 50);
  await until(async () => (await one("select days from v_finish_by_days where department='metal'")).days === 20);
  await until(() => /now 20 days before delivery \(was 18\)/.test(txt(w)));
  ok("Luke sets Metal to 20: saved, and the answer says so in the panel", /Metal: now 20 days before delivery \(was 18\)/.test($$(w, ".panel").find(p => /Finish-by days/.test(p.textContent)).textContent));
  ok("...the row says who changed it", /Changed by Luke H/.test($(w, '[data-fbdays="metal"]').closest(".fbrow").textContent));
  ok("...both rows kept in the database (nothing overwritten)", (await one("select count(*)::int n from finish_by_days where department='metal'")).n === 2);
  ok("...and 'Every change' lists it", $$(w, "details.more summary").some(x => x.textContent === "Every change") && /Metal: 20 days/.test(txt(w)));
  box = $(w, '[data-fbdays="sanding"]'); box.value = "120";
  await click(w, '[data-fbsave="sanding"]', 50);
  await until(() => /whole number from 0 to 90/.test(txt(w)));
  ok("120 is refused with a plain message", /The days for Sanding must be a whole number from 0 to 90/.test(txt(w)));
  box = $(w, '[data-fbdays="sanding"]'); box.value = "";
  await click(w, '[data-fbsave="sanding"]', 50);
  await until(() => /whole number from 0 to 90/.test(txt(w)));
  ok("a blank box is refused too, nothing saved", (await one("select days from v_finish_by_days where department='sanding'")).days === 14);
  box = $(w, '[data-fbdays="cnc"]'); box.value = "18";
  await click(w, '[data-fbsave="cnc"]', 50);
  await until(() => /Nothing changed/.test(txt(w)));
  ok("saving the same number: 'Nothing changed', no new row", (await one("select count(*)::int n from finish_by_days where department='cnc'")).n === 1);
  // the job page follows
  await openJob(w, "418");
  const r = (await exp("PROJ-00418")).find(x => x.department === "metal");
  ok("the job page follows the new number", heads(w).find(x => x.name === "Metal").date.startsWith(`To paint / PC by ${fmt(r.f)}`));
  w.close();

  // ---- a supervisor, even with the page, can't change a number (the database refuses) ----
  const res = await makeClient(users.mike).rpc("set_finish_by_days", { p_department: "sanding", p_days: 2 });
  ok("Mike calling the function directly is refused by the database", res.error && /Only a manager/.test(res.error.message));

  // ---- finish_by.sql not run ----
  await admin.query("revoke select on v_finish_by, v_finish_by_days, finish_by_days from authenticated");
  w = boot(users.luke); await signedIn(w);
  await openJob(w, "418");
  ok("without the database part the job page grid is exactly as before (names only)", heads(w).length === 6 && heads(w).every(x => x.date === null));
  await click(w, "[data-jobback]", 200);
  await setup(w);
  ok("...and Setup says which file to run", /Finish-by dates aren't set up in the database yet. Run finish_by.sql/.test(txt(w)));
  ok("...while the rest of Setup still works", /TV link/.test(txt(w)) && /Supply lists/.test(txt(w)));
  await admin.query("grant select on v_finish_by, v_finish_by_days, finish_by_days to authenticated");
  w.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### snap_fb.js
```javascript
// Drive the real pages in jsdom against the test database, save each screen's HTML, then photograph in Chromium.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const OUT = "/home/claude/sf/snaps"; fs.mkdirSync(OUT, { recursive: true });
function boot(file, user, url, preload = {}) {
  const html = fs.readFileSync(file, "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "data:image/png;base64,"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
function save(w, name) { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove()); fs.writeFileSync(`${OUT}/${name}.html`, "<!DOCTYPE html>" + d.outerHTML); }
const $ = (w, s) => w.document.querySelector(s), $$ = (w, s) => [...w.document.querySelectorAll(s)];
const click = async (w, s, p = 300) => { (typeof s === "string" ? $(w, s) : s).click(); await wait(p); };
const T = "https://lukehart1228.github.io/shop-floor/";
(async () => {
  const j099 = (await admin.query("select id from jobs where project_id='PROJ-00099'")).rows[0].id;
  await makeClient(users.luke).rpc("set_flag", { p_job: j099, p_level: "priority", p_note: "Customer walkthrough Thursday" });
  for (const [file, tag] of [["../live/index.html", "before"], ["../out/index.html", "after"]]) {
    let w = boot(file, users.mike, T + "index.html");
    await until(() => $$(w, "button.job").length); await wait(300);
    if ($(w, '[data-qmode="all"]')) await click(w, '[data-qmode="all"]');
    save(w, `tablet-${tag}-1-sanding-all`);
    await click(w, $$(w, "button.job").find(b => /PROJ-00418/.test(b.textContent)), 400);
    save(w, `tablet-${tag}-2-jobpage`);
    w.close();
  }
  let w = boot("../out/index.html", users.willie, T + "index.html");
  await until(() => $(w, ".due.fb")); await wait(300); save(w, "tablet-after-3-metal"); w.close();
  await makeClient(users.luke).rpc("set_finish_by_days", { p_department: "metal", p_days: 20 });
  w = boot("../out/office.html", users.luke, T + "office.html", { sfo_pin: JSON.stringify({ none: true }) });
  await until(() => $(w, ".tab")); await wait(600);
  $(w, "[data-jobfind]").focus(); await wait(300);
  const box = $(w, "[data-jobfind]"); box.value = "418"; box.dispatchEvent(new w.Event("input")); await wait(80);
  box.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter" })); await until(() => $(w, ".grid .gh")); await wait(300);
  save(w, "office-1-jobpage");
  await click(w, "[data-jobback]"); await click(w, "[data-menu]"); await click(w, ".menu [data-tab='setup']", 800);
  const b = $(w, '[data-fbdays="full_custom"]'); b.value = "15"; await click(w, '[data-fbsave="full_custom"]', 800);
  save(w, "office-2-setup");
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### shoot_fb.js
```javascript
const { chromium } = require("playwright");
const fs = require("fs");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const f of fs.readdirSync("../snaps").filter(x => x.endsWith(".html"))) {
    const pg = await b.newPage({ viewport: f.startsWith("office") ? { width: 1280, height: 900 } : { width: 1280, height: 800 } });
    await pg.goto("file:///home/claude/sf/snaps/" + f); await pg.waitForTimeout(500);
    if (f === "office-2-setup.html") { const el = await pg.$$("section.panel"); for (const s of el) if (/Finish-by days/.test(await s.textContent())) { await pg.addStyleTag({ content: "header{position:static!important}" }); await s.screenshot({ path: "../snaps/" + f.replace(".html", ".png") }); } }
    else await pg.screenshot({ path: "../snaps/" + f.replace(".html", ".png"), fullPage: false });
    await pg.close();
  }
  await b.close();
})();
```
