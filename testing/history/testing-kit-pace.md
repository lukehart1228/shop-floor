# Testing kit, part 13 — Pace, and the office cleanup (25 Sep 2026)

*For build chats. Luke doesn't need to read this.* Parts 1–12 still apply. Setup as Part 11: every live file, unchanged, twice each, into `sync`, snapshot `sync_base` — **now including `inventory.sql`** at the end of the second loop (pace needs `inv_inches`). `finish_by.sql` is not in the base (not live); load it per test when the late list matters.

## Setup notes (25 Sep)

- `rm /etc/apt/sources.list.d/nodesource*` before `apt-get update` (403 otherwise).
- `/bin/sh` here has no brace expansion or `time`: `mkdir -p a b c`, and run scripts with `bash`.
- `npm install jsdom@24 pg playwright@1.56.0` in `/home/claude`; run node with `NODE_PATH=/home/claude/node_modules`. Chromium: `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.
- `stubs.sql`, `people.sql`, `seed.sql` from Part 3; `people.sql` plus Jim W (`9999…`, finishing) and Eric B (`aaaa…`, full_custom). `pgsupa.js` from Part 3 with Part 11's JSON-argument patch.
- `fresh.sh FILES…` = `sync_base` + Part 3 seed + each file twice; the second load's output (the check) is in `/tmp/last_load.out`.
- **`pace_seed.sql`** (below) gives the seed sizes, a cabinet sheet and a base-only sheet, six weeks of backdated tablet counts, and removes the seed's starting upload rows with counts already in them (a real upload starts at 0; otherwise every sheet looks "started outside the tablet").
- **office.html in jsdom asks for a PIN first** on a new computer: click `[data-k]` 1-2-3-4 until the menu button appears (twice: set, confirm).
- Test times by updating `progress_events.occurred_at` for the check's own rows; the check does the same and undoes it.

## Results when delivered

| Test | Result |
|---|---|
| `pace.sql` twice on a seeded database; `check_pace()` | 13/13 PASS each time; nothing left behind |
| With `finish_by.sql` loaded first | 13/13; `check_finish_by()` 12/12 |
| Earlier checks after it (verify_setup, check_floor, check_ready_issues, check_inventory, check_advance, check_test_lane, check_supply_lists, check_deliveries, check_deliveries_v2, check_photos, check_loadouts) | All PASS |
| `breaks.py` — 18 broken versions | Each fails at its own step |
| Report read as Luke through `authenticator` | Numbers checked by hand (Milling 33+18+55.5+75 over 4 = 45.4; late list 72 sq ft at 11.5/wk → +44 days) |
| `test_pace_page.js` — real pace.html against the database | 40/40 (run twice) |
| `test_pace_core.js` | 16/16 |
| `test_office_menu.js` — office.html menu; only 2 lines differ from live | 6/6 |
| Screens (`shoot.js`, desktop 1280, phone 390, Working days) | Two fixes: the table became cards on a phone (it scrolled sideways, hiding the numbers); working time left out sheets counted in one go (they showed "0 days") |

| **Office cleanup** (same evening): `test_office_ops.js` — Operations, Flags on it, overdue routine tasks, remembered tabs, Setup's sections, Routine tasks and Departments in Setup, the menu, supervisor refusals | 39/39 |
| Earlier office suites on the new office.html | `test_inv_needs.js` 6/6 · `test_office_nav.js` 32/36 with its Flags-tab step pointed at Arrow: the 4 are the tab list and menu (changed on purpose) and the two grid steps that fail on the live page too · `test_fb_office.js` fails its "days past" step and stops at `[data-jobback]` identically on the **live** office.html (the kit's seed dates) |
| Screens (`snap_ops.js` → `shoot_ops.js`) | One fix: "Needs you" and "Flags" read as small group labels (they were the same size as the sections under them). Pre-existing, not changed: on a phone the office's tab strip is off-screen and a stale flag's line squashes |

Not covered: the real SQL Editor, GitHub Pages, real history (the first real weeks will show how noisy Full Custom's pace is).

## Files

#### pace_seed.sql
```sql
-- sizes on the seeded sheets, a cabinet sheet, a base-only sheet, and backdated tablet history
update sheets s set width = '36"', length = null from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number <= 3;
update sheets s set width = '30"', length = '60"' from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number between 4 and 7;
update sheets s set width = '24"', length = '48"' from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00099';
-- 00418 sheet 8: a cabinet (Full Custom + Sanding + Finishing), sheet 9: base only (Metal + Assembly)
insert into sheet_progress (sheet_id, department, qty_required, qty_done)
select s.id, 'full_custom', s.qty, 0 from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
 where j.project_id = 'PROJ-00418' and s.sheet_number = 8 on conflict do nothing;
delete from sheet_progress sp using sheets s, work_orders w, jobs j
 where sp.sheet_id = s.id and s.work_order_id = w.id and w.job_id = j.id and j.project_id = 'PROJ-00418' and s.sheet_number = 9
   and sp.department in ('milling','cnc','sanding','finishing');
update sheets s set width = null, length = null from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number = 9;
update sheets s set width = '24"', length = '60"' from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number = 8;
-- history: tablet counts spread over the last 6 weeks, as real supervisors would make them
do $$
declare r record; i int := 0; t timestamptz;
begin
  for r in select sp.sheet_id, sp.department, sp.qty_required from sheet_progress sp join sheets s on s.id = sp.sheet_id
             join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
            where not j.is_test and j.project_id in ('PROJ-00418','PROJ-00099') and sp.department in ('milling','cnc')
            order by j.project_id, s.sheet_number, sp.department loop
    i := i + 1;
    t := now() - make_interval(days => 42 - i * 2);
    -- reset to 0 then count on the tablet at time t
    perform set_config('shopfloor.source', 'Work order upload', true);
    update sheet_progress set qty_done = 0 where sheet_id = r.sheet_id and department = r.department;
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = r.qty_required where sheet_id = r.sheet_id and department = r.department;
    update progress_events set occurred_at = t where id = (select max(id) from progress_events where sheet_id = r.sheet_id and department = r.department);
  end loop;
  -- sanding on 00418 sheets 1–3 counted over the last two weeks; the cabinet sheet sanded
  for r in select sp.sheet_id, sp.department, sp.qty_required, s.sheet_number from sheet_progress sp join sheets s on s.id = sp.sheet_id
             join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
            where not j.is_test and j.project_id = 'PROJ-00418' and sp.department = 'sanding' and s.sheet_number in (1,2,3,8) loop
    perform set_config('shopfloor.source', 'Work order upload', true);
    update sheet_progress set qty_done = 0 where sheet_id = r.sheet_id and department = r.department;
    perform set_config('shopfloor.source', '', true);
    update sheet_progress set qty_done = r.qty_required where sheet_id = r.sheet_id and department = r.department;
    update progress_events set occurred_at = now() - make_interval(days => 3 + r.sheet_number) where id = (select max(id) from progress_events where sheet_id = r.sheet_id and department = r.department);
  end loop;
  perform set_config('shopfloor.source', '', true);
end $$;
-- the upload resets above left "Work order upload" events at now(); push them back before the counts so they don't look like carried-over starts
update progress_events set occurred_at = occurred_at - interval '60 days' where source = 'Work order upload';
update sheets set created_at = now() - interval '50 days';
-- the stand-in seed made its sheets already counted; real uploads start at 0, so drop those starting rows
delete from progress_events where source = 'Work order upload' and qty_to > 0 and qty_from is null;
```

#### breaks.py
```python
import subprocess
good = open('out/pace.sql').read()
B = {
 "round not squared": [("then round(inv_inches(s.width) * coalesce(inv_inches(s.length), inv_inches(s.width)) / 144, 3)", "then round(inv_inches(s.width) * coalesce(inv_inches(s.length), inv_inches(s.width) * 0.785) / 144, 3)")],
 "cabinets not counted": [("    when sp.department in ('sanding', 'finishing') and f.has_fc then 1\n", "")],
 "bases as sq ft": [("    when sp.department = 'assembly_qc' and not f.has_wood then 0\n", "")],
 "every source counted": [("where e.source = 'Tablet' or (e.source is null and e.qty_from is not null);", ";")],
 "increments not absolute": [("(e.qty_to - coalesce(e.qty_from, 0)) * u.main_each   as main", "e.qty_to * u.main_each   as main")],
 "workdays ignore schedule": [("    if extract(isodow from d)::int = any(p_days) then", "    if true then")],
 "wait in calendar days": [("then pace_workdays(b.ready_at, b.first_at, b.schedule) end as wait_days", "then pace_workdays(b.ready_at, b.first_at, array[1,2,3,4,5,6,7]) end as wait_days")],
 "catch-up start kept": [("and b.first_at is not null and not b.started_outside\n       then pace_workdays(b.ready_at", "and b.first_at is not null\n       then pace_workdays(b.ready_at"),
                         ("and b.done_at is not null and not b.started_outside and", "and b.done_at is not null and")],
 "one-go counts timed": [("not b.started_outside and b.done_at > b.first_at", "not b.started_outside and b.done_at >= b.first_at")],
 "test jobs included": [("join jobs j        on j.id = w.job_id and not j.is_test", "join jobs j        on j.id = w.job_id")],
 "report open to all": [("  if not office_ok() then\n    raise exception 'Only a manager can see pace.'", "  if false then\n    raise exception 'Only a manager can see pace.'")],
 "views readable": [("revoke all on v_pace_times from anon, authenticated;", "revoke all on v_pace_times from anon; grant select on v_pace_times to authenticated;")],
 "schedule open to all": [("  if not office_ok() then\n    raise exception 'Only a manager can change working days.'", "  if false then\n    raise exception 'Only a manager can change working days.'")],
 "history overwritten": [("  insert into pace_schedules (department, days, set_by, set_by_name) values (p_department, v_new, auth.uid(), my_name());",
                          "  update pace_schedules set days = v_new, set_by = auth.uid(), set_by_name = my_name() where department = p_department;")],
 "delivery accepted": [("  if v_dept.log_only then\n    raise exception '% isn''t counted", "  if false then\n    raise exception '% isn''t counted")],
 "queue backwards": [("order by j.delivery_date nulls last, j.project_id, j.job_id) as ahead_main", "order by j.delivery_date desc nulls last, j.project_id, j.job_id) as ahead_main")],
 "clears in working weeks": [("ceil(greatest(p_amount, 0) / p_per_week * 7)::int", "ceil(greatest(p_amount, 0) / p_per_week * 4)::int")],
 "report open without login": [("revoke all on function pace_report(int) from public, anon;\ngrant execute on function pace_report(int) to authenticated;",
                                "revoke all on function pace_report(int) from public;\ngrant execute on function pace_report(int) to anon, authenticated;"),
                               ("  if not office_ok() then\n    raise exception 'Only a manager can see pace.'", "  if not (office_ok() or auth.uid() is null) then\n    raise exception 'Only a manager can see pace.'")],
}
for name, reps in B.items():
    s = good
    for a, b in reps:
        assert a in s, (name, a[:60]); s = s.replace(a, b)
    open('/tmp/broken.sql', 'w').write(s)
    r = subprocess.run("bash base/fresh.sh /tmp/broken.sql >/tmp/b.out 2>&1; psql -h /tmp/pg -p 5433 -U postgres -At -d sync -c \"select string_agg(step::text, ',') from check_pace() where result <> 'PASS'\"", shell=True, capture_output=True, text=True)
    print(f"{name:28s} failing steps: {r.stdout.strip() or '(none!)'} {r.stderr.strip()[:100]}")
```

#### test_pace_page.js
```javascript
// The office Pace page end to end: the real pace.html in jsdom, against the real test database
// through the login path Supabase uses. Run on:  fresh.sh finish_by.sql pace.sql + pace_seed.sql
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/pace.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(user, store = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/pace.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(store)) w.localStorage.setItem("sfp_" + k, JSON.stringify(v));
  w.supabase = { createClient: () => client };
  w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  return w;
}
const txt = (w) => (w.document.getElementById("app").textContent + " " + w.document.getElementById("tabs").textContent).replace(/\s+/g, " ");
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 120) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const row = (w, key) => $(w, `[data-dept="${key}"]`).closest("tr");
const cells = (w, key) => [...row(w, key).children].map(td => td.querySelector("b") ? td.querySelector("b").textContent : td.textContent.trim());
const small = (w, key, i) => { const s = row(w, key).children[i].querySelector("small"); return s ? s.textContent : ""; };

(async () => {
  // ============ Luke ============
  let w = boot(users.luke, { dept: "sanding" });
  await until(() => $$(w, "table.pace tbody tr").length === 7);
  ok("seven departments in the table, in floor order", $$(w, "table.pace tbody tr").map(r => r.querySelector("button").textContent).join(",") === "Milling,CNC,Sanding,Finishing,Full Custom,Metal,Assembly / QC",
     $$(w, "table.pace tbody tr").map(r => r.querySelector("button").textContent).join(","));
  ok("Milling: 45.4 sq ft a week (33 + 18 + 55.5 + 75 over 4 weeks)", cells(w, "milling")[2] === "45.4 sq ft", cells(w, "milling")[2]);
  ok("measured in: sq ft of top / sq ft + cabinets / sq ft + bases / pieces",
     cells(w, "milling")[1] === "sq ft of top" && cells(w, "sanding")[1] === "sq ft + cabinets" && cells(w, "assembly_qc")[1] === "sq ft + bases" && cells(w, "metal")[1] === "pieces");
  ok("Sanding pace shows cabinets beside the square feet", small(w, "sanding", 2) === "+ 0.3 cabinets", small(w, "sanding", 2));
  ok("Sanding ready: 235 sq ft on 7 sheets", cells(w, "sanding")[3] === "235 sq ft" && small(w, "sanding", 3) === "on 7 sheets", cells(w, "sanding")[3] + " / " + small(w, "sanding", 3));
  ok("Finishing ready shows the cabinet: + 1 cabinet, on 4 sheets", small(w, "finishing", 3) === "+ 1 cabinet, on 4 sheets", small(w, "finishing", 3));
  ok("Metal ready in pieces", cells(w, "metal")[3] === "20 pieces", cells(w, "metal")[3]);
  ok("Queue ≈ ready ÷ weekly pace: Sanding 20.4 weeks", cells(w, "sanding")[4] === "20.4 weeks", cells(w, "sanding")[4]);
  ok("no pace yet: Finishing's queue is a dash, with a word why", cells(w, "finishing")[4] === "—" && small(w, "finishing", 4) === "no pace yet");
  ok("wait to start for Milling in working days, with the sheet count", /day/.test(cells(w, "milling")[5]) && /sheets/.test(small(w, "milling", 5)), cells(w, "milling")[5] + " " + small(w, "milling", 5));
  ok("the selected row is marked", row(w, "sanding").classList.contains("sel") && $(w, '[data-dept="sanding"]').getAttribute("aria-pressed") === "true");
  ok("detail: Sanding — done each week, Mon–Thu, 4 weeks + this week", /Sanding — done each week/.test(txt(w)) && /works Mon–Thu/.test(txt(w)) && $$(w, ".bar").length === 5, `${$$(w, ".bar").length} bars`);
  ok("this week's bar is the lighter one, labelled 'this week'", $$(w, ".bar")[4].classList.contains("now") && $$(w, ".barlbl div")[4].textContent === "this week");
  ok("cabinet note under Sanding's chart", /Cabinets are counted beside the square feet/.test(txt(w)));
  const waitRows = $$(w, ".two .card")[1].querySelectorAll(".lrow");
  ok("ready and not started, longest first: PROJ-00099 sheet 1 on top", waitRows.length === 5 && /PROJ-00099/.test(waitRows[0].textContent) && /Sheet 1 · DSK-01/.test(waitRows[0].textContent), waitRows[0] && waitRows[0].textContent);
  const late = [...$$(w, ".two .card")[2].querySelectorAll(".lrow")].map(r => r.textContent.replace(/\s+/g, " ").trim());
  ok("late list rows (by finish-by date)", late.length === 2 && /PROJ-00099.*Done by Oct 9 · its turn clears about Nov 8/.test(late[0]) && /PROJ-00418.*Done by Nov 5/.test(late[1]), late.join(" | "));

  // ---- another department ----
  await click(w, '[data-dept="finishing"]');
  ok("Finishing selected: works every day", /Finishing — done each week/.test(txt(w)) && /works every day/.test(txt(w)));
  ok("Finishing has no pace, so no late dates — said in words", /No pace yet for Finishing, so no dates to compare/.test(txt(w)));
  const fw = $$(w, ".two .card")[1].querySelectorAll(".lrow")[0];
  ok("the cabinet sheet waits with its square feet and its cabinet", fw && /10 sq ft \+ 1 cabinet/.test(fw.textContent), fw && fw.textContent);
  ok("remembers the department", w.localStorage.getItem("sfp_dept") === '"finishing"');

  // ---- 8 weeks ----
  await click(w, '[data-weeks="8"]', 400);
  ok("8 weeks asks the database for 8", w.client.rpcs.some(([f, a]) => f === "pace_report" && a.p_weeks === 8));
  ok("…and shows 9 bars", $$(w, ".bar").length === 9, `${$$(w, ".bar").length}`);
  ok("only 6 full weeks of counts: the page says so", /Based on 6 weeks, not 8/.test(txt(w)) && /start the week of Aug 10/.test(txt(w)), (txt(w).match(/Based on[^.]*/) || [""])[0]);
  ok("no red, no turquoise anywhere on the page", !/#f00\b|#ff0000|\bred\b|#00B4B2|var\(--teal/i.test(w.document.getElementById("app").innerHTML));

  // ---- working days ----
  await click(w, '#tabs [data-tab="days"]');
  ok("Working days: seven rows", $$(w, ".schrow").length === 7);
  const finRow = $(w, '[data-save="finishing"]').closest(".schrow");
  ok("Finishing shows every day pressed; Save off until something changes",
     [...finRow.querySelectorAll("[data-day]")].every(b => b.getAttribute("aria-pressed") === "true") && $(w, '[data-save="finishing"]').disabled);
  await click(w, '[data-day="finishing|6"]');
  ok("un-ticking Saturday turns Save on", !$(w, '[data-save="finishing"]').disabled);
  await click(w, '[data-save="finishing"]', 500);
  ok("saved: the page says what changed", /Finishing now works Mon Tue Wed Thu Fri Sun/.test(txt(w)), (txt(w).match(/Finishing now[^.]*/) || [""])[0]);
  const last = await one("select days::text d, set_by_name from v_pace_schedules where department='finishing'");
  ok("the database has it, under Luke's name", last.d === "{1,2,3,4,5,7}" && last.set_by_name === "Luke H", JSON.stringify(last));
  ok("the old schedule is kept", (await one("select count(*)::int n from pace_schedules where department='finishing'")).n === 2);
  for (const d of [1, 2, 3, 4]) await click(w, `[data-day="milling|${d}"]`, 40);
  await click(w, '[data-save="milling"]', 400);
  ok("no days at all is refused, in plain words", /Pick at least one day for Milling/.test(txt(w)));
  ok("…and nothing was saved", (await one("select days::text d from v_pace_schedules where department='milling'")).d === "{1,2,3,4}");

  // ============ a supervisor ============
  const wm = boot(users.mike);
  await until(() => /For managers/.test(txt(wm)));
  ok("a supervisor sees 'For managers' and the page asks nothing of the database", /For managers/.test(txt(wm)) && !wm.client.rpcs.length);
  const direct = await makeClient(users.mike).rpc("pace_report", { p_weeks: 4 });
  ok("…and the database refuses the report to a supervisor directly", !!direct.error && /Only a manager/.test(direct.error.message), direct.error && direct.error.message);
  const direct2 = await makeClient(users.mike).rpc("set_pace_schedule", { p_department: "sanding", p_days: [1, 2, 3, 4, 5] });
  ok("…and refuses a supervisor changing working days", !!direct2.error, direct2.error && direct2.error.message);
  const anon = await makeClient(null).rpc("pace_report", { p_weeks: 4 });
  ok("no login: refused", !!anon.error, anon.error && anon.error.message);

  // ============ before finish-by is set up ============
  await admin.query("drop view if exists v_finish_by; drop view if exists v_finish_by_days");
  w = boot(users.luke, { dept: "sanding", tab: "pace", weeks: 4 });
  await until(() => $$(w, "table.pace tbody tr").length === 7);
  ok("without finish-by dates the late panel says what's needed", /Shows once finish-by dates are set up/.test(txt(w)));
  ok("…and everything else still shows", cells(w, "milling")[2] === "45.4 sq ft");

  // ============ no counts yet ============
  await admin.query("update progress_events set source = 'Work order upload' where source = 'Tablet' or source is null");
  w = boot(users.luke, { dept: "sanding", tab: "pace", weeks: 4 });
  await until(() => /No tablet counts/.test(txt(w)));
  ok("no tablet counts yet: said plainly, pace is a dash", /No tablet counts to go on yet/.test(txt(w)) && cells(w, "milling")[2] === "—");

  // ============ file not run ============
  await admin.query("drop function pace_report(int)");
  w = boot(users.luke);
  await until(() => /isn't set up/.test(txt(w)));
  ok("pace.sql not run: the page says which file to run", /Pace isn't set up in the database yet/.test(txt(w)) && /pace\.sql/.test(txt(w)) && /Walkthrough 16/.test(txt(w)));

  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(async (e) => { console.error(e); process.exit(1); });
```

#### test_pace_core.js
```javascript
const fs = require("fs");
const html = fs.readFileSync("/home/claude/sf/out/pace.html", "utf8");
const code = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
fs.writeFileSync("/tmp/pace_core.js", code); const C = require("/tmp/pace_core.js");
let p = 0, f = 0; const ok = (n, c, x = "") => { c ? p++ : f++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
ok("Mon–Thu", C.daysLabel([1,2,3,4]) === "Mon–Thu");
ok("every day", C.daysLabel([7,6,5,4,3,2,1]) === "Every day");
ok("gaps listed", C.daysLabel([1,3,5]) === "Mon Wed Fri");
ok("two days listed", C.daysLabel([1,2]) === "Mon Tue");
ok("numbers: 1,235 / 45.4 / 0", C.num(1234.5) === "1,235" && C.num(45.44) === "45.4" && C.num(0) === "0");
ok("1 piece, 3 pieces, sq ft", C.amount({ measure: "pieces" }, 1) === "1 piece" && C.amount({ measure: "pieces" }, 3) === "3 pieces" && C.amount({ measure: "sqft" }, 9) === "9 sq ft");
ok("extras: + 1 cabinet / + 4 cabinets / + 1 piece without a top / none",
   C.extraText({ extra_label: "cabinets" }, 1) === "+ 1 cabinet" && C.extraText({ extra_label: "cabinets" }, 4) === "+ 4 cabinets"
   && C.extraText({ extra_label: "pieces without a top" }, 1) === "+ 1 piece without a top" && C.extraText({ extra_label: null }, 3) === "");
ok("queue weeks", C.queueWeeks(100, 40) === 2.5 && C.queueWeeks(10, 0) === null && C.queueWeeks(10, null) === null);
ok("weeks words", C.weeksText(null) === "—" && C.weeksText(1) === "1 week" && C.weeksText(0) === "nothing ready");
ok("days words", C.daysText(null) === "—" && C.daysText(1) === "1 day" && C.daysText(2.44) === "2.4 days");
ok("date", C.dateShort("2026-09-14") === "Sep 14");
const dep = { weekly: [1,2,3,4,5,6,7,8,9].map((m, i) => ({ week: "w" + i, main: m * 10, extra: 0 })) };
const b4 = C.barsFor(dep, 4);
ok("bars: last 4 finished weeks + this week", b4.length === 5 && b4[0].week === "w4" && b4[4].now && b4[4].pct === 100 && b4[0].pct === 56, JSON.stringify(b4.map(b => b.pct)));
ok("Metal's label", C.finishLabel("metal") === "To paint / PC by" && C.finishLabel("sanding") === "Done by");
ok("secret key refused", C.keyProblem("https://x.supabase.co", "sb_secret_abc").secret === true);
ok("the file's own key is the publishable one", /const SUPABASE_KEY = "sb_publishable_/.test(html) && !/sb_secret_[A-Za-z0-9]/.test(html.replace(/key\.startsWith\("sb_secret_"\)/, "")));
ok("the library address carries its integrity hash, same as inventory.html",
   html.includes('supabase-js@2.45.4/dist/umd/supabase.js" integrity="sha384-0w2KAL2YHP6wKOkUDzkCDGgVvfmHnj02DHeQ6XcHOgTfFsGyonKOpShMH1x6nk9o"'));
console.log(`\n${p} passed, ${f} failed`); process.exit(f ? 1 : 0);
```

#### test_office_menu.js
```javascript
// office.html: the menu gains a Pace link; nothing else on the page moves
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(30); } return false; }
(async () => {
  const client = makeClient(users.luke);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  w.supabase = { createClient: () => client };
  w.scrollTo = () => {}; w.confirm = () => true; w.print = () => {}; w.open = () => {};
  w.URL.createObjectURL = () => "blob:x";
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  // set the office PIN (first use on this computer), then enter it
  for (let round = 0; round < 3 && !w.document.querySelector('[data-menu="1"]'); round++) {
    await until(() => w.document.querySelector('[data-k="1"]'), 3000);
    for (const k of ["1", "2", "3", "4"]) { const b = w.document.querySelector(`[data-k="${k}"]`); if (b) b.click(); await wait(40); }
    await wait(300);
  }
  w.addEventListener("error", e => console.log("PAGE ERROR", e.message));
  const got = await until(() => w.document.querySelector('[data-menu="1"]'));
  if (!got) console.log("BODY:", w.document.body.innerHTML.slice(0, 600), "RPCS", JSON.stringify(client.rpcs).slice(0,300));
  ok("the office opens for Luke", got);
  w.document.querySelector('[data-menu="1"]').click(); await wait(150);
  const links = [...w.document.querySelectorAll("nav.menu a")].map(a => a.getAttribute("href"));
  ok("the menu lists six pages, Pace after Inventory", links.join(",") === "office.html,upload.html,delivery.html,inventory.html,pace.html,index.html", links.join(","));
  const a = w.document.querySelector('nav.menu a[href="pace.html"]');
  ok("the Pace link says what it's for", a && /Pace/.test(a.textContent) && /Square feet a week, time in stage/.test(a.textContent), a && a.textContent);
  ok("the version says pace", /25 Sep 2026 · pace/.test(w.document.querySelector("nav.menu .ver").textContent));
  ok("Setup and Sign out still in the menu", !!w.document.querySelector('nav.menu [data-tab="setup"]') && !!w.document.querySelector("nav.menu [data-signout]"));
  const live = fs.readFileSync("/home/claude/sf/live/office.html", "utf8"), mine = fs.readFileSync("/home/claude/sf/out/office.html", "utf8");
  const dl = live.split("\n"), dm = mine.split("\n");
  const changed = dm.filter(l => !dl.includes(l));
  ok("only two lines differ from the live office.html (the link and the version)", changed.length === 2 && dm.length === dl.length + 1, changed.join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### shoot.js (the page with a stub client holding a captured `pace_report(4)`, saved as /tmp/pace_shot.html)
```javascript
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [name, vp, dept, tab] of [["desk", { width: 1280, height: 1000 }, "sanding", "pace"], ["phone", { width: 390, height: 844 }, "finishing", "pace"], ["days", { width: 1280, height: 800 }, "sanding", "days"]]) {
    const p = await b.newPage({ viewport: vp });
    await p.addInitScript(([d, t]) => { localStorage.setItem("sfp_dept", JSON.stringify(d)); localStorage.setItem("sfp_tab", JSON.stringify(t)); }, [dept, tab]);
    await p.goto("file:///tmp/pace_shot.html"); await p.waitForTimeout(1200);
    await p.screenshot({ path: `/tmp/shot_${name}.png`, fullPage: true });
  }
  await b.close();
})();
```

#### test_office_ops.js
```javascript
// office.html after the cleanup: Operations (Needs you + Flags), Setup with Routine tasks and Departments.
// The real page in jsdom, against the real test database through the login path Supabase uses.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.PAGE || "/home/claude/sf/out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
async function until(fn, ms = 6000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(30); } return false; }
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 250) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function boot(user, tab) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  if (tab) w.localStorage.setItem("sfo_tab", JSON.stringify(tab));
  w.supabase = { createClient: () => client };
  w.scrollTo = () => {}; w.confirm = () => true; w.print = () => {}; w.open = () => {}; w.URL.createObjectURL = () => "blob:x";
  w.HTMLElement.prototype.scrollIntoView = function () { w.__jumped = this.id; };
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  for (let round = 0; round < 3 && !$(w, '[data-menu="1"]'); round++) {
    await until(() => $(w, '[data-k="1"]') || $(w, '[data-menu="1"]'), 3000);
    if ($(w, '[data-menu="1"]')) break;
    for (const k of ["1", "2", "3", "4"]) { const b = $(w, `[data-k="${k}"]`); if (b) b.click(); await wait(40); }
    await wait(300);
  }
  await until(() => $(w, "main h1"));
  // the page draws first, then loads; wait for the database calls to stop
  let n = -1; for (let i = 0; i < 60 && n !== w.client.log.length + w.client.rpcs.length; i++) { n = w.client.log.length + w.client.rpcs.length; await wait(150); }
  await wait(200);
  return w;
}
const tabs = (w) => $$(w, "nav.tabs .tab").map(b => b.childNodes[0].textContent.trim());
const badge = (w) => { const n = $(w, 'nav.tabs .tab[data-tab="tasks"] .n'); return n ? Number(n.textContent) : 0; };

(async () => {
  // what the office will see: a two-week-old flag, an open flag set today, a routine task overdue and one done today
  const job = (await one("select id from jobs where project_id='PROJ-00418' and not is_test")).id;
  const job2 = (await one("select id from jobs where project_id='PROJ-00099' and not is_test")).id;
  await admin.query(`insert into flags (job_id, level, note, set_by_name, set_at) values ($1, 'priority', 'Old note: still right?', 'Luke H', now() - interval '20 days'),
                                                                                   ($2, 'watch', 'Keep an eye on the maple', 'Luke H', now())`, [job, job2]);
  const late = (await one(`insert into routine_tasks (name, department, schedule_type, weekday, week_interval, start_date, created_by_name)
                          values ('Change dust collector filter', 'milling', 'weekly', 1, 1, local_today() - 20, 'Luke H') returning id`)).id;
  const done = (await one(`insert into routine_tasks (name, department, schedule_type, weekday, week_interval, start_date, created_by_name)
                          values ('Sweep the spray booth', 'finishing', 'weekly', 1, 1, local_today() - 20, 'Luke H') returning id`)).id;
  await admin.query("insert into routine_task_logs (task_id, completed_on, completed_by_name) values ($1, local_today(), 'Jim W')", [done]);

  // ============ Operations ============
  let w = await boot(users.luke);
  ok("three tabs: Operations, Arrow, Photos", tabs(w).join(",") === "Operations,Arrow,Photos", tabs(w).join(","));
  ok("opens on Operations", $(w, "main h1").textContent === "Operations");
  ok("Needs you is a heading on it", /Needs you/.test($(w, "h2.opshead").textContent));
  const secs = $$(w, "section.need").map(s => s.dataset.need);
  ok("the two-week-old flag waits there", secs.includes("flags") && /Old note: still right\?/.test($(w, '[data-need="flags"]').textContent));
  ok("the overdue routine task waits there, with its department", secs.includes("routine") && /Change dust collector filter/.test($(w, '[data-need="routine"]').textContent) && /Milling/.test($(w, '[data-need="routine"]').textContent),
     secs.join(","));
  ok("the task done today doesn't", !/Sweep the spray booth/.test(txt(w)));
  ok("overdue by how many days, in words", /Overdue by \d+ days?/.test($(w, '[data-need="routine"]').textContent));
  ok("the routine section comes after flags and before Arrow / handoffs", secs.indexOf("routine") === secs.indexOf("flags") + 1, secs.join(","));
  const c1 = badge(w);
  ok("the Operations number includes the overdue task and the old flag", c1 >= 2, `${c1}`);
  ok("Flags section below Needs you, with both open flags", !!$(w, "#opsflags") && /2 open/.test($(w, "#opsflags h2").textContent) && /Keep an eye on the maple/.test($(w, "#opsflags").textContent));
  ok("the Set a flag form stays folded until asked for", !$(w, "#ffJob") && !!$(w, '[data-flagform="1"]'));
  await click(w, '[data-jump="opsflags"]', 60);
  ok("'See it under Flags' jumps down to the flags", w.__jumped === "opsflags");

  // set a flag
  await click(w, '[data-flagform="1"]');
  ok("Set a flag opens the form", !!$(w, "#ffJob") && !!$(w, "#ffNote"));
  const sel = $(w, "#ffJob"); sel.value = job2; sel.dispatchEvent(new w.Event("change", { bubbles: true }));
  const note = $(w, "#ffNote"); note.value = "Customer walk-through Friday"; note.dispatchEvent(new w.Event("input", { bubbles: true }));
  await click(w, '[data-fflevel="critical"]');
  await click(w, "[data-setflag]", 900);
  const f = await one("select level, note, set_by_name from flags where job_id = $1 and cleared_at is null and department is null", [job2]);
  ok("the flag is set in the database, replacing the old one", f && f.level === "critical" && f.note === "Customer walk-through Friday" && f.set_by_name === "Luke H", JSON.stringify(f));
  ok("the answer shows in the Flags section, and the form folds away", !!$(w, "#opsflags .banner") && !$(w, "#ffJob"), $(w, "#opsflags .banner") && $(w, "#opsflags .banner").textContent);
  ok("the old one is in the cleared history", /Flags cleared in the last 30 days \(1\)/.test(txt(w)));
  // clear one
  const clr = [...$$(w, "#opsflags [data-clearflag]")].find(b => /Customer walk-through/.test(b.closest(".li").textContent));
  await click(w, clr, 900);
  ok("clearing a flag works from Operations", (await one("select count(*)::int n from flags where job_id = $1 and cleared_at is null", [job2])).n === 0);

  // the task gets done on the tablet → it leaves Operations
  await admin.query("insert into routine_task_logs (task_id, completed_on, completed_by_name) values ($1, local_today(), 'Donnie E')", [late]);
  w = await boot(users.luke);
  ok("ticked off on the tablet: gone from Operations, and from the number", !$(w, '[data-need="routine"]') && badge(w) === c1 - 1, `${badge(w)}`);

  // ============ remembered tabs ============
  w = await boot(users.luke, "flags");
  ok("a computer that last had Flags open lands on Operations", $(w, "main h1").textContent === "Operations");
  w = await boot(users.luke, "routine");
  ok("…Routine tasks → Setup", $(w, "main h1").textContent === "Setup");
  w = await boot(users.luke, "departments");
  ok("…Departments → Setup", $(w, "main h1").textContent === "Setup");

  // ============ Setup ============
  const jumps = $$(w, "nav.jumps [data-jump]").map(b => b.textContent);
  ok("Setup has a row of section buttons, Routine tasks and Departments first", jumps.length === 9 && jumps[0] === "Routine tasks" && jumps[1] === "Departments", jumps.join(" · "));
  ok("every section button has somewhere to go", $$(w, "nav.jumps [data-jump]").every(b => !!w.document.getElementById(b.dataset.jump)));
  await click(w, '[data-jump="set-finishby"]', 60);
  ok("a section button jumps to its section", w.__jumped === "set-finishby");
  ok("routine tasks listed by department in Setup", /Change dust collector filter/.test($(w, "#set-routine").textContent) && /Sweep the spray booth/.test($(w, "#set-routine").textContent));
  ok("the routine text says Tasks tab, not the old Log tab", /Tasks tab/.test($(w, "#set-routine").textContent) && !/Log tab/.test($(w, "#set-routine").textContent));
  const nm = $(w, "#tfName"); nm.value = "Oil the jointer"; nm.dispatchEvent(new w.Event("input", { bubbles: true }));
  const dp = $(w, "#tfDept"); dp.value = "milling"; dp.dispatchEvent(new w.Event("change", { bubbles: true }));
  await click(w, "[data-addtask]", 900);
  ok("adding a routine task from Setup works", (await one("select count(*)::int n from routine_tasks where name = 'Oil the jointer' and active")).n === 1);
  ok("its answer shows in the Routine tasks section", !!$(w, "#set-routine .banner"), $(w, "#set-routine .banner") && $(w, "#set-routine .banner").textContent);
  ok("…and only there", $$(w, "main .banner.ok").length === 1, `${$$(w, "main .banner.ok").length}`);
  const rt = [...$$(w, "#set-routine [data-retiretask]")].find(b => /Oil the jointer/.test(b.closest(".line").textContent));
  await click(w, rt, 900);
  ok("removing one works, and it's kept as history", (await one("select active, retired_at is not null r from routine_tasks where name = 'Oil the jointer'")).r === true);
  const live0 = (await one("select is_live from departments where key = 'full_custom'")).is_live;
  ok("Departments in Setup: a switch per counted department", $$(w, "#set-departments [data-live]").length === 7, `${$$(w, "#set-departments [data-live]").length}`);
  await click(w, '#set-departments [data-live="full_custom"]', 900);
  ok("flipping a switch works from Setup (and is logged)", (await one("select is_live from departments where key = 'full_custom'")).is_live === !live0
     && (await one("select count(*)::int n from department_live_log where department = 'full_custom'")).n >= 1);
  await click(w, '#set-departments [data-live="full_custom"]', 900);
  ok("…and back", (await one("select is_live from departments where key = 'full_custom'")).is_live === live0);
  ok("the rest of Setup is still there (Monday, catch-up, TV, defect lists, finish-by, supplies, test jobs)",
     ["set-monday", "set-catchup", "set-tv", "set-defects", "set-finishby", "set-supplies", "set-test"].every(id => !!w.document.getElementById(id)));

  // ============ the menu ============
  await click(w, '[data-menu="1"]', 150);
  const links = $$(w, "nav.menu a").map(a => a.getAttribute("href"));
  ok("the menu still has every page, Pace included", links.join(",") === "office.html,upload.html,delivery.html,inventory.html,pace.html,index.html", links.join(","));
  ok("Setup's line in the menu names routine tasks and departments", /Routine tasks, departments/.test($(w, 'nav.menu [data-tab="setup"]').textContent));
  ok("version: operations", /25 Sep 2026 · operations/.test($(w, "nav.menu .ver").textContent));

  // ============ the database still decides ============
  const mike = makeClient(users.mike);
  const r1 = await mike.rpc("set_flag", { p_job: job, p_level: "critical", p_note: "sneaky", p_department: null });
  ok("a supervisor still can't set a flag", !!r1.error, r1.error && r1.error.message);
  const r2 = await mike.rpc("set_department_live", { p_department: "full_custom", p_live: !live0 });
  ok("…or flip a department", !!r2.error, r2.error && r2.error.message);

  console.log(`\n${pass} passed, ${fail} failed`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(async (e) => { console.error(e); process.exit(1); });
```

#### snap_ops.js (draws Operations and Setup in jsdom, saves the page for Chromium)
```javascript
// render Operations and Setup in jsdom against the database, then save the drawn page for Chromium
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync("/home/claude/sf/out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
(async () => {
  const job = (await admin.query("select id from jobs where project_id='PROJ-00418' and not is_test")).rows[0].id;
  const job2 = (await admin.query("select id from jobs where project_id='PROJ-00099' and not is_test")).rows[0].id;
  await admin.query(`insert into flags (job_id, level, note, set_by_name, set_at) values ($1,'priority','Customer moved the date up — tops through finishing by Wednesday','Luke H', now() - interval '20 days'),($2,'watch','Keep an eye on the maple','Luke H', now())`, [job, job2]);
  await admin.query(`insert into routine_tasks (name, department, schedule_type, weekday, week_interval, start_date, created_by_name) values ('Change dust collector filter','milling','weekly',1,1,local_today()-20,'Luke H')`);
  for (const [tab, out] of [["tasks", "/tmp/ops.html"], ["setup", "/tmp/setup.html"]]) {
    const client = makeClient(users.luke);
    const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://x/office.html" });
    const w = dom.window;
    w.localStorage.setItem("sfo_tab", JSON.stringify(tab));
    w.supabase = { createClient: () => client }; w.scrollTo = () => {}; w.confirm = () => true;
    w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
    for (let r = 0; r < 3 && !w.document.querySelector('[data-menu="1"]'); r++) { await wait(400); for (const k of "1234") { const b = w.document.querySelector(`[data-k="${k}"]`); if (b) b.click(); await wait(40); } }
    await wait(2500);
    const doc = dom.serialize().replace(/<script[\s\S]*?<\/script>/g, "");
    fs.writeFileSync(out, doc);
  }
  await admin.end(); process.exit(0);
})();
```

#### shoot_ops.js
```javascript
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [f, o, vp] of [["/tmp/ops.html", "/tmp/shot_ops.png", { width: 1280, height: 900 }], ["/tmp/setup.html", "/tmp/shot_setup.png", { width: 1280, height: 900 }], ["/tmp/ops.html", "/tmp/shot_ops_phone.png", { width: 390, height: 844 }]]) {
    const p = await b.newPage({ viewport: vp }); await p.goto("file://" + f); await p.waitForTimeout(500);
    await p.screenshot({ path: o, fullPage: true });
  }
  await b.close();
})();
```
