# Testing kit, part 12 — Inventory and scrap rate (25 Sep 2026)
*For build chats. Luke doesn't need to read this.* Parts 1–11 still apply; setup as Part 11 (every live file, twice, into `sync`, snapshot `sync_base`).
## Setup notes (25 Sep)
- `apt-get update` failed on a nodesource repo (403): delete it from `/etc/apt/sources.list.d/` first.
- The sandbox reset Postgres twice mid-build: `pg_isready -h /tmp/pg -p 5433 || pg_ctl … start` before each run.
- `fresh_inv.sh FILES…` = `sync_base` + Part 3 seed + the files (twice) + `inv_seed.sql` (sizes on the seeded sheets, a 1.75" top, an unmatched species, PROJ-00099 sheet 3 unstarted and sheet 2 part-milled, Eric B and Jim W logins).
- `pgsupa.js` needs Part 11's JSON-argument patch (`send_inventory_count` takes jsonb).
- **jsdom: read `#app` (and `#tabs`), never `document.body`** — the body holds the page's own script text, so a regex on it matches before anything renders.
- **Count day in tests:** insert an open `inv_months` row for `2000-03-31`. It becomes the current month (earliest open), its last day has passed, and March makes every list due.
- The tablet shows a toast *before* it reloads after a send; wait for the banner, not the toast.
- `test_inv_office.js` uses Luke; `test_fb_tablet.js` must run on the plain Part 3 seed (`inv_seed.sql` leaves Milling unfinished, which it checks).

## Results when delivered
| Test | Result |
|---|---|
| `inventory.sql` twice on a seeded database; `check_inventory()` | 16/16 PASS each time; nothing left behind |
| Earlier checks after it (verify_setup, check_floor, check_ready_issues, check_finish_by, check_advance, check_test_lane, check_supply_lists, check_deliveries) | All PASS |
| `breaks.py` — 14 broken versions | Each fails at its own step |
| `test_inv_office.js` — real inventory.html | 35/35 |
| `test_inv_tablet.js` — real index.html Inventory tab | 19/19 |
| `test_inv_needs.js` — office menu link + Needs you | 6/6 |
| `test_inv_dept.js` — Department counts tab (25 Sep, evening): preview, not-due, office sends for Metal, tablet sees it, Change the count, Willie re-sends, database refusals | 26/26; `test_inv_office.js` still 35/35 |
| `test_fb_tablet.js` / `test_nav_tablet.js` on the new index.html | 27/27 · 25/25 |
| `test_fb_office.js` on the new office.html | 23/23 |
| `test_office_nav.js` on the new office.html | 33/36: the menu now has five pages (expected); the two grid steps fail on the **live** office.html too (the kit's copy predates finish-by headings) |
| Screens (`snap_inv.js` + shoot.py) | Looked right; tablet steel names repeated their group — trimmed |

Not covered: the real SQL Editor, GitHub Pages, a real tablet.

## Files

#### inv_seed.sql
```sql
-- sizes on the seeded sheets (Part 3's seed has none), plus the awkward ones
update sheets s set shape = 'Rectangle', width = '30"', length = '60"', thickness = '1.25"'
  from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number <= 6;
update sheets s set shape = 'Round', width = '42"', length = null, thickness = '1.5"'
  from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number = 7;
update sheets s set shape = 'Rectangle', width = '30"', length = '48"', thickness = '1.75"'
  from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number = 8;
update sheets s set species = 'Thermally Modified Red Oak', shape = 'Rectangle', width = '24"', length = '48"', thickness = '1.25"'
  from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00418' and s.sheet_number = 9;
update sheets s set shape = 'Rectangle', width = '24"', length = '48"', thickness = '1.25"'
  from work_orders w join jobs j on j.id = w.job_id where s.work_order_id = w.id and j.project_id = 'PROJ-00099';
-- PROJ-00099: sheet 3 not started in Milling
update sheet_progress sp set qty_done = 0 from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
 where sp.sheet_id = s.id and sp.department = 'milling' and j.project_id = 'PROJ-00099' and s.sheet_number = 3;
insert into auth.users (id, email) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','eric@pdindy.com'), ('99999999-9999-9999-9999-999999999999','jim@pdindy.com') on conflict do nothing;
insert into profiles (id, full_name, role, departments) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Eric B','supervisor','{full_custom}'),
  ('99999999-9999-9999-9999-999999999999','Jim W','supervisor','{finishing}') on conflict do nothing;
-- PROJ-00099 sheet 2: Milling part way (1 of 3)
update sheet_progress sp set qty_done = 1 from sheets s join work_orders w on w.id = s.work_order_id join jobs j on j.id = w.job_id
 where sp.sheet_id = s.id and sp.department = 'milling' and j.project_id = 'PROJ-00099' and s.sheet_number = 2;
```

#### fresh_inv.sh
```bash
#!/bin/bash
P="psql -h /tmp/pg -p 5433 -U postgres -q -v ON_ERROR_STOP=1"
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base" >/dev/null || exit 1
$P -d sync -f /home/claude/sf/base/seed.sql >/tmp/seed.out 2>&1 || { echo SEED FAILED; head /tmp/seed.out; exit 1; }
for f in "$@"; do $P -d sync -f "$f" >/dev/null 2>/tmp/load.err || { echo LOAD FAILED $f; cat /tmp/load.err; exit 1; }; $P -d sync -f "$f" >/dev/null 2>&1; done
$P -d sync -f /home/claude/sf/base/inv_seed.sql >/dev/null || exit 1
echo READY
```

#### gen_seed.py
```python
import re, json
from openpyxl import load_workbook
W=load_workbook('/mnt/user-data/uploads/8-31-26_Inventory_Count_-_Wood_Finishing_Other.xlsx',data_only=True)
M=load_workbook('/mnt/user-data/uploads/Inventory_sheet_MFD-_8-31-26.xlsx',data_only=True)
def q(s): return "null" if s is None else "'" + str(s).replace("'","''") + "'"
def n(x): return "null" if x in (None,"") else repr(float(x)) if not float(x).is_integer() else str(int(float(x)))
def clean(s): return re.sub(r'\s+',' ',str(s)).strip()
def lum_name(s):
    s=clean(s); s=re.sub(r'(\d+)\s*/\s*4', r'\1/4', s); return s
def lum_parts(name):
    m=re.search(r'\b(\d+/4)\b',name); stock=m.group(1)
    sp=clean(name.replace(stock,' ')); return sp, stock

items=[]   # (list, section, name, unit, std_len, gl, species, stock, sort, price, aug_qty)
lines=[]   # (name, length, width, rows)
# ---- lumber prices from LOOKUP
lk=W['LOOKUP']; rows=list(lk.iter_rows(values_only=True))
start=[i for i,r in enumerate(rows) if r[0]=='Wood' and r[1]=='Price'][0]
lumber={}
for r in rows[start+1:]:
    if not r[0] or r[0]=='Type': break
    nm=lum_name(r[0]); lumber[nm]=float(r[1] or 0)
# ---- count sheet
cs=W['2. Inventory Count']; crow=list(cs.iter_rows(values_only=True))
sec=None
ply_counts={}; ply_price={}
for r in crow:
    a=r[0]
    if a in ('Lumber (Monthly)','Plywood Rack (Monthly)','Finishing Materials (Quarterly)','Other (Quarterly)'): sec=a; continue
    if a in (None,'Inventory Item','Total'): continue
    if sec=='Lumber (Monthly)':
        nm=lum_name(a); lumber.setdefault(nm, float(r[7] or 0))
        if r[3]: lines.append((nm, r[1], r[2] or 42, r[3]))
    elif sec=='Plywood Rack (Monthly)':
        ply_counts[clean(a)]=r[1]; ply_price[clean(a)]=r[4]
    elif sec=='Finishing Materials (Quarterly)':
        items.append(('finish','Finishing materials',clean(a),clean(r[3]).replace('# of ',''),None,'1208',None,None,r[4],None))
    elif sec=='Other (Quarterly)':
        items.append(('other','Hardware',clean(a),clean(r[3]).replace('# of ',''),None,'1207',None,None,r[4],None))
for nm,p in sorted(lumber.items()):
    sp,st=lum_parts(nm)
    items.append(('lumber','Lumber',nm,'bd ft',None,'1201',sp,st,p,None))
# plywood: LOOKUP list (all plywood items) + rack counts
start=[i for i,r in enumerate(rows) if r[0]=='Item' and r[1]=='PCS Value?'][0]
ply=[]
for r in rows[start+1:]:
    if not r[0] or r[0].startswith('We are'): break
    ply.append((clean(r[0]), r[3]))
seen=set()
for nm,p in ply:
    items.append(('plywood','Plywood rack',nm,'sheets',None,'1201',None,None,ply_price.get(nm,p),ply_counts.get(nm,0))); seen.add(nm)
for nm,c in ply_counts.items():
    if nm not in seen: items.append(('plywood','Plywood rack',nm,'sheets',None,'1201',None,None,ply_price[nm],c))
# ---- metal
ms=M['Metal Inventory Count']; mrow=list(ms.iter_rows(values_only=True))
sec=None; SECS={'Shop Supplies':('Shop supplies',None),'Other Inventory':('Other','1207'),'Pipe Inventory':('Black pipe','1204-01'),'Steel Inventory':('Steel','1204-01')}
for r in mrow:
    a=r[0]
    if a in SECS: sec=a; continue
    if a in (None,'Item #','Steel Type','Total','Metal Shop Inventory','Current Month-end Date'): continue
    if not sec or not r[1]: continue
    section,gl=SECS[sec]
    if sec=='Steel Inventory':
        unit=clean(r[2]).lower(); desc=clean(r[1]); typ=clean(a)
        nm=f"{typ}, {desc}"
        std = r[5] if unit=='feet' else None
        price = r[10] if r[10] not in (None,'') else r[6]
        items.append(('metal', typ if unit=='feet' else typ, nm, 'ft' if unit=='feet' else 'each', std, gl, None, None, price, r[4] or 0))
    else:
        nm=clean(r[1]); grp=clean(a)
        items.append(('metal', section, nm, 'each', None, gl, None, None, r[5], r[4] or 0))

# sort order within list
out=[]; so={}
for it in items:
    so[it[0]]=so.get(it[0],0)+10
    out.append(it+(so[it[0]],))
vals=",\n  ".join(f"({q(i[0])},{q(i[1])},{q(i[2])},{q(i[3])},{n(i[4])},{q(i[5])},{q(i[6])},{q(i[7])},{i[10]},{n(i[8]) if i[8] not in (None,'') else 'null'},{n(i[9]) if i[9] is not None else 'null'})" for i in out)
lv=",\n  ".join(f"({q(l[0])},{n(l[1])},{n(l[2])},{n(l[3])})" for l in lines)
open('seed_items.sql','w').write(vals); open('seed_lines.sql','w').write(lv)
import collections
print(collections.Counter(i[0] for i in out)); print(len(lines),"lumber lines")
tot=sum(l[1]*l[2]*l[3]*int(lum_parts(l[0])[1][0])/4/144 for l in lines); print("aug bf", tot)
for i in out:
    if i[0]=='metal' and i[4]: pass
print([i for i in out if i[0]=='metal'][:3]); print([i for i in out if i[0]=='lumber'][:3])
```

#### breaks.py
```python
import subprocess
src=open('inventory.sql').read()
P=["psql","-h","/tmp/pg","-p","5433","-U","postgres","-q","-v","ON_ERROR_STOP=1"]
B=[
 ("round is square",      "length_in := coalesce(inv_inches(p_length), width_in);", "length_in := coalesce(inv_inches(p_length), width_in * 0.785);"),
 ("finished thickness",   "board_feet := round(width_in * length_in * inv_stock_in(stock)", "board_feet := round(width_in * length_in * thickness_in"),
 ("guess stock",          "  if stock is null then problem := format('No stock size", "  stock := coalesce(stock, '8/4');\n  if stock is null then problem := format('No stock size"),
 ("test jobs in pool",    "   where not j.is_test\n)", "   where true\n)"),
 ("rolled still counts",  "from v_inv_pool where not rolled and problem is null", "from v_inv_pool where problem is null"),
 ("roll started",         "  if p_rolled and p.mill_done > 0 then", "  if false then"),
 ("mistake still counts", "where r.kind = 'lumber' and r.mistake_at is null group by", "where r.kind = 'lumber' group by"),
 ("sticks not feet",      "v_qty := coalesce(v_st, 0) * it.std_length_ft + coalesce(v_lo, 0);", "v_qty := coalesce(v_st, 0) + coalesce(v_lo, 0);"),
 ("any dept sends",       "  if not (office_ok() or owns_dept(v_list.department)) then\n    raise exception 'This login can''t send", "  if false then\n    raise exception 'This login can''t send"),
 ("prices readable",      "create policy inv_read on inv_prices          for select to authenticated using (is_manager());", "create policy inv_read on inv_prices          for select to authenticated using (true);"),
 ("test login sends",     "  if am_test() then\n    raise exception 'Test logins", "  if false then\n    raise exception 'Test logins"),
 ("close missing counts", "  if missing is not null then raise exception 'Still to come", "  if false then raise exception 'Still to come"),
 ("closed month prices",  "round(q.qty * coalesce(case when mo.status = 'closed' then cv.price else pr.price end, 0), 2)", "round(q.qty * coalesce(pr.price, 0), 2)"),
 ("anon reads months",    "create policy inv_read on inv_months   for select to authenticated using (true);", "create policy inv_read on inv_months   for select to authenticated, anon using (true); grant select on inv_months to anon;"),
]
for name,a,b in B:
    assert a in src, name
    s=src.replace(a,b,1)
    # remove the check's self-run so load doesn't print; run separately
    open('/tmp/broken.sql','w').write(s.replace("select * from check_inventory();",""))
    subprocess.run(P+["-d","postgres","-c","drop database if exists sync with (force)","-c","create database sync template sync_base"],capture_output=True)
    subprocess.run(P+["-d","sync","-f","/home/claude/sf/base/seed.sql"],capture_output=True)
    r=subprocess.run(P+["-d","sync","-f","/tmp/broken.sql"],capture_output=True,text=True)
    if r.returncode: print(f"{name:22} LOAD FAILED", r.stderr[-200:]); continue
    r=subprocess.run(P+["-d","sync","-At","-F","|","-c","select step,result from check_inventory()"],capture_output=True,text=True)
    fails=[l.split("|")[0] for l in r.stdout.split() if l.endswith("FAIL")]
    print(f"{name:22} FAIL at steps {fails}")
```

#### test_inv_office.js
```javascript
// The office Inventory page end to end: the real inventory.html in jsdom, against the real test
// database through the login path Supabase uses. Run on a fresh database:
//   ../fresh_inv.sh /home/claude/inv/inventory.sql && node test_inv_office.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const html = fs.readFileSync(process.env.PAGE || "/home/claude/inv/inventory.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
users.eric = { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email: "eric@pdindy.com" };

function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/inventory.html" });
  const w = dom.window;
  w.supabase = { createClient: () => client };
  w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  return w;
}
const txt = (w) => (w.document.getElementById("app").textContent + " " + w.document.getElementById("tabs").textContent).replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const tab = (w, k) => click(w, `#tabs [data-tab="${k}"]`, 60);
function type(w, sel, value, ev = "input") { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = value; el.dispatchEvent(new w.Event(ev, { bubbles: true })); }

(async () => {
  const maple = (await one("select id from inv_items where list_key='lumber' and name='Maple 6/4'")).id;
  const ash = (await one("select id from inv_items where list_key='lumber' and name='Ash 6/4'")).id;
  const month = (await one("select inv_current_month()::text m")).m;

  // ============ Luke ============
  let w = boot(users.luke);
  await until(() => /Before closing the month/.test(txt(w)));
  ok("opens on This month, with five lists", $$(w, ".stat").length === 5, `${$$(w, ".stat").length} cards`);
  ok("the lumber card shows the racks' total so far (nothing counted yet: 0)", /Lumber.*0 bd ft/.test(txt(w)));
  ok("Close is off until everything is in", $(w, "[data-close]") && $(w, "[data-close]").disabled);
  ok("the Month-end tab shows a ! (roll-over not reviewed)", /Month-end!/.test(w.document.getElementById("tabs").textContent));
  ok("Setup shows 2 (two sheets need a stock size or a species match)", /Setup2$/.test(w.document.getElementById("tabs").textContent));

  // ---- lumber: last month's lengths are there, empty ----
  await tab(w, "lumber");
  ok("lumber: every species counted at 31 Aug is listed", $$(w, "details.spec").length >= 20, `${$$(w, "details.spec").length}`);
  const card = $(w, `details.spec[data-item="${maple}"]`);
  ok("Maple 6/4 shows 31 Aug's 8,165 bd ft beside today's 0", card && /31 Aug 8,165/.test(card.textContent) && /0 bd ft/.test(card.querySelector(".bf").textContent));
  card.open = true; card.dispatchEvent(new w.Event("toggle")); await wait(50);
  const lens = [...card.querySelectorAll(".len .lenhead > b")].map(b => b.textContent);
  ok("its three rack lengths from 31 Aug are ready (96\", 114\", 138\")", lens.join(",") === '96",114",138"', lens.join(","));
  // type 13 rows in bundle 1 at 114", add a bundle of 19¼
  let inp = $(w, `[data-b="${maple}|1|0"]`);
  type(w, inp, "13");
  await click(w, `[data-add="${maple}|1"]`);
  type(w, `[data-b="${maple}|1|1"]`, "19");
  await click(w, `[data-frac="${maple}|1|1|1"]`);
  ok("the line reads 32¼ rows = 1,608 bd ft straight away", /32¼ rows = 1,608 bd ft/.test($(w, `[data-tot="${maple}|1"]`).textContent), $(w, `[data-tot="${maple}|1"]`).textContent);
  await until(async () => (await one("select bundles::text b from inv_lumber_lines where item_id=$1 and length_in=114 and month_end=$2", [maple, month]) || {}).b === "{13,19.25}", 4000);
  let row = await one("select bundles::text b, updated_by_name n from inv_lumber_lines where item_id=$1 and length_in=114 and month_end=$2", [maple, month]);
  ok("in the database: one line, both bundles as numbers {13,19.25}, by Luke", row && row.b === "{13,19.25}" && row.n === "Luke H", JSON.stringify(row));
  ok("says All saved", /All saved/.test($(w, "#saving").textContent));

  // offline: typing waits and sends itself
  setOffline(true);
  type(w, `[data-b="${maple}|0|0"]`, "7");
  await wait(900);
  ok("offline: the number is kept and it says waiting to save", /1 line waiting to save/.test($(w, "#saving").textContent), $(w, "#saving").textContent);
  const kept = JSON.parse(w.localStorage.getItem("sfi_pending_lines") || "{}");
  ok("...kept on this computer too", Object.values(kept).some(p => p.length === 96 && p.bundles[0] === 7));
  setOffline(false);
  w.dispatchEvent(new w.Event("online"));
  await until(async () => (await one("select bundles::text b from inv_lumber_lines where item_id=$1 and length_in=96 and month_end=$2", [maple, month]) || {}).b === "{7}", 4000);
  ok("back online: it sends itself", (await one("select bundles::text b from inv_lumber_lines where item_id=$1 and length_in=96 and month_end=$2", [maple, month]) || {}).b === "{7}");

  // a new length
  type(w, `#nl-${maple}`, "144");
  await click(w, `[data-addlen="${maple}"]`, 150);
  ok("Add a length: 144\" (12') appears", [...$(w, `details.spec[data-item="${maple}"]`).querySelectorAll(".len .lenhead")].some(h => /144"/.test(h.textContent) && /12'/.test(h.textContent)));
  // a bad number refused by the database is shown, not swallowed
  const r = await makeClient(users.luke).rpc("set_lumber_line", { p_item: maple, p_length: 90, p_bundles: [1.3], p_width: 42 });
  ok("the database refuses rows that aren't quarters", r.error && /quarters/.test(r.error.message));

  // ---- deliveries ----
  await tab(w, "deliveries");
  type(w, "#rs", "Frank Miller Lumber"); type(w, "#rk", maple, "change"); type(w, "#rb", "1200");
  await click(w, "[data-addrec]", 400);
  await until(() => /Added 1,200 bd ft of Maple 6\/4/.test(txt(w)));
  ok("a lumber slip is added and shows in the list", /Frank Miller Lumber.*Maple 6\/4.*1,200/.test(txt(w)));
  type(w, "#pn", "30"); await click(w, "[data-addply]", 400);
  await until(() => /Plywood · 30 sheets/.test(txt(w)));
  ok("a plywood slip: total 30 sheets", /Plywood · 30 sheets/.test(txt(w)));
  const recId = (await one("select id from inv_receipts where kind='plywood'")).id;
  await click(w, `[data-mistake="${recId}"]`, 400);
  await until(() => /Plywood · 0 sheets/.test(txt(w)));
  ok("Entered by mistake: stops counting, stays on the list crossed out", /Plywood · 0 sheets/.test(txt(w)) && $(w, "tr.mistake") && (await one("select count(*)::int n from inv_receipts")).n === 2);

  // ---- roll-over ----
  await tab(w, "rollover");
  const j99 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  ok("roll-over lists only the sheets still in Milling (PROJ-00099 sheets 2 and 3)", $$(w, ".ro").length === 2 && !!$(w, `[data-roll="${j99}|3"]`), `${$$(w, ".ro").length} rows`);
  ok("a sheet with pieces counted can't be ticked", !$(w, `[data-roll="${j99}|2"]`) && /Pieces counted — lumber is out/.test(txt(w)));
  const box = $(w, `[data-roll="${j99}|3"]`); box.checked = true; box.dispatchEvent(new w.Event("change", { bubbles: true }));
  await until(() => /1 sheet rolls to next month \(36 bd ft\)/.test(txt(w)));
  ok("ticking Not pulled: 1 sheet rolls to next month (36 bd ft)", /1 sheet rolls to next month \(36 bd ft\)/.test(txt(w)));
  ok("...saved", (await one("select rolled from inv_rollovers where job_id=$1 and sheet_number=3", [j99])).rolled === true);
  await click(w, '[data-rodone="1"]', 400);
  await until(() => /Reviewed by Luke H/.test(txt(w)));
  ok("Done — these are right: Reviewed by Luke H, and the ! goes", /Reviewed by Luke H/.test(txt(w)) && !/Month-end!/.test(w.document.getElementById("tabs").textContent));

  // ---- setup: a rule and a match clear both problems ----
  await tab(w, "setup");
  type(w, "#tf", "1.75"); type(w, "#ts", "8/4", "change");
  await click(w, "[data-addrule]", 400);
  await until(() => /now count as 8\/4/.test(txt(w)));
  ok("Setup: a 1.75\" → 8/4 rule is added", /1\.75".*8\/4/.test(txt(w)));
  const sel = $(w, '[data-match="Thermally Modified Red Oak"]');
  ok("the unmatched work order species shows Not matched", sel && /Not matched/.test(sel.closest(".ro").textContent));
  type(w, sel, "Thermally Modified RO", "change");
  await until(() => /now counts as Thermally Modified RO/.test(txt(w)));
  ok("matched: the Setup badge goes", !/ Setup\d/.test(" " + w.document.getElementById("tabs").textContent), w.document.getElementById("tabs").textContent);
  // a price
  const pinp = $(w, `[data-price="${maple}"]`);
  type(w, pinp, "3.95", "change");
  await until(async () => Number((await one("select price from v_inv_prices where item_id=$1", [maple])).price) === 3.95);
  ok("a new price is kept with who set it (and the old one stays)", (await one("select count(*)::int n, max(set_by_name) filter (where price=3.95) nm from inv_prices where item_id=$1", [maple])).n === 2);

  // ---- scrap ----
  await tab(w, "scrap");
  const rowEl = $$(w, "tr.click").find(t => /Maple 6\/4/.test(t.textContent));
  const scr = await one("select * from v_inv_scrap where month_end=$1 and species='Maple' and stock='6/4'", [month]);
  ok("scrap: Maple 6/4 row matches the database's numbers", rowEl && rowEl.textContent.includes(Math.round(scr.used_bf).toLocaleString("en-US")) && rowEl.textContent.includes(Math.round(scr.zero_bf).toLocaleString("en-US")),
     `${rowEl && rowEl.textContent} vs used ${scr.used_bf} zero ${scr.zero_bf}`);
  await click(w, rowEl, 60);
  ok("tapping a row shows its tops, sized at full rectangle × stock", /PROJ-00099/.test(txt(w)) && /counted as 24" × 48" × 1.5" \(6\/4\)/.test(txt(w)));
  await click(w, "button[data-shut]", 60);

  // ---- values ----
  await tab(w, "values");
  ok("values: GL 1201 shows the lumber at today's prices", /1201.*Wood/.test(txt(w)) && /\$\d/.test(txt(w)));

  // ---- close still refused before the tablets send (and before the month's last day) ----
  await tab(w, "month");
  ok("This month: roll-over and Setup ticked; counts still to come", /✓ Month-end roll-over reviewed/.test(txt(w).replace("✓Month", "✓ Month")) || $$(w, ".step.ok").length === 2);
  const c = await makeClient(users.luke).rpc("close_inventory_month", {});
  ok("the database refuses to close with counts missing (or before the last day)", c.error && /(Still to come|can't close before)/.test(c.error.message), c.error && c.error.message);

  // ============ a supervisor ============
  const w2 = boot(users.willie);
  await until(() => /For managers/.test(txt(w2)));
  ok("a supervisor sees 'For managers', no tabs", /For managers/.test(txt(w2)) && w2.document.getElementById("tabs").hidden);
  const wc = makeClient(users.willie);
  const a = await wc.from("inv_prices").select("*"), b2 = await wc.rpc("set_lumber_line", { p_item: maple, p_length: 100, p_bundles: [1], p_width: 42 });
  ok("...and the database gives them no prices and refuses the office's writes", Array.isArray(a.data) && a.data.length === 0 && b2.error && /Only a manager/.test(b2.error.message));

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_inv_tablet.js
```javascript
// The tablet's Inventory tab end to end: the real index.html in jsdom, against the real test database
// through the login path Supabase uses. Run on a fresh database:
//   ../fresh_inv.sh /home/claude/inv/inventory.sql && node test_inv_tablet.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const fidb = require("fake-indexeddb");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const html = fs.readFileSync(process.env.APP || "/home/claude/inv/site/index.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
users.eric = { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email: "eric@pdindy.com" };
users.jim = { id: "99999999-9999-9999-9999-999999999999", email: "jim@pdindy.com" };

function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.URL.createObjectURL = () => "blob:x"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
function type(w, sel, value) { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = value; el.dispatchEvent(new w.Event("input", { bubbles: true })); }
const subtabs = (w) => $$(w, ".subtab").map(b => b.textContent.trim());

(async () => {
  // ---- before count day: no tab ----
  let w = boot(users.willie);
  await until(() => $$(w, ".subtab").length > 0);
  await wait(300);
  ok("before the last day of the month: no Inventory tab (Metal's tabs as before)", subtabs(w).join(",") === "Work orders,Arrow,Tasks,Issues,Supplies", subtabs(w).join(","));

  // ---- pretend count day: an open month whose last day has passed (March: every list is due) ----
  await admin.query("insert into inv_months (month_end) values ('2000-03-31')");
  w = boot(users.willie);
  await until(() => subtabs(w).some(t => /^Inventory/.test(t)));
  ok("count day: Metal gets an Inventory tab with a !", subtabs(w).includes("Inventory!"), subtabs(w).join(","));
  await click(w, '[data-tab="inventory"]', 400);
  await until(() => $$(w, ".invitem").length > 0);
  const nItems = (await one("select count(*)::int n from inv_items where list_key='metal' and not retired")).n;
  ok(`the whole Metal list shows (${nItems} items), in groups`, $$(w, ".invitem").length === nItems && $$(w, ".invgroup").length >= 5, `${$$(w, ".invitem").length} items, ${$$(w, ".invgroup").length} groups`);
  ok("no prices anywhere on the tablet", !/\$\d/.test(txt(w)));
  const steel = await one("select id, name, std_length_ft from inv_items where list_key='metal' and std_length_ft = 24 order by sort_order limit 1");
  const each = await one("select id, name from inv_items where list_key='metal' and std_length_ft is null and gl_account is not null order by sort_order limit 1");
  ok("steel has two boxes: full sticks + loose feet", !!$(w, `[data-inv="${steel.id}|sticks"]`) && !!$(w, `[data-inv="${steel.id}|loose"]`));
  type(w, `[data-inv="${steel.id}|sticks"]`, "5"); type(w, `[data-inv="${steel.id}|loose"]`, "7");
  ok("5 sticks + 7 ft shows = 127 ft", $(w, `[data-inveq="${steel.id}"]`).textContent === "= 127 ft", $(w, `[data-inveq="${steel.id}"]`).textContent);
  type(w, `[data-inv="${each.id}|n"]`, "40");
  ok("the counter says 2 of n counted — blanks count as 0", new RegExp(`2 of ${nItems} counted — blanks count as 0`).test(txt(w)));
  ok("typed numbers are kept on the tablet", /"sticks":"5"/.test(w.localStorage.getItem("sf_invdrafts") || Object.values(w.localStorage).join("")) || JSON.stringify(Object.assign({}, w.localStorage)).includes('\\"sticks\\":\\"5\\"'));
  await click(w, "[data-invsend]");
  ok("Send asks first, saying how many are blank", /Send the Metal count\?/.test(txt(w)) && new RegExp(`${nItems - 2} items are blank and will count as 0`).test(txt(w)));
  await click(w, "[data-confirm]", 200);
  await until(async () => (await one("select count(*)::int n from inv_sends where list_key='metal'")).n === 1, 4000);
  const snd = await one("select * from inv_sends where list_key='metal'");
  const c1 = await one("select qty, sticks, loose_ft from inv_counts where item_id=$1 and month_end='2000-03-31'", [steel.id]);
  const c0 = await one("select count(*)::int n from inv_counts c join inv_items i on i.id=c.item_id where i.list_key='metal' and c.month_end='2000-03-31' and c.qty=0");
  ok("in the database: sent by Willie J, steel 127 ft (5 sticks + 7), the rest 0", snd.sent_by_name === "Willie J" && Number(c1.qty) === 127 && c1.sticks === 5 && Number(c1.loose_ft) === 7 && c0.n === nItems - 2,
     JSON.stringify({ by: snd.sent_by_name, c1, zeros: c0.n }));
  await until(() => /Metal count sent — by Willie J/.test(txt(w)));
  ok("the tab says sent (turquoise), the ! goes, the boxes lock", /Metal count sent — by Willie J/.test(txt(w)) && subtabs(w).includes("Inventory") && $(w, `[data-inv="${steel.id}|sticks"]`).disabled);

  // Change the count
  await click(w, "[data-invreopen]", 400);
  await until(() => !!$(w, "[data-invsend]"));
  ok("Change the count: the boxes open again with the numbers sent", $(w, `[data-inv="${steel.id}|sticks"]`).value === "5" && $(w, `[data-inv="${steel.id}|loose"]`).value === "7" && $(w, `[data-inv="${each.id}|n"]`).value === "40");
  type(w, `[data-inv="${steel.id}|sticks"]`, "6");
  await click(w, "[data-invsend]"); await click(w, "[data-confirm]", 200);
  await until(async () => Number((await one("select qty from inv_counts where item_id=$1 and month_end='2000-03-31'", [steel.id])).qty) === 151, 4000);
  ok("...sent again: 6 sticks + 7 = 151 ft; the first send stays in the history, marked taken back",
     (await one("select count(*)::int n, count(*) filter (where withdrawn_at is not null)::int t from inv_sends where list_key='metal'")).t === 1);

  // ---- Eric, offline: the count waits on the tablet and sends itself ----
  const we = boot(users.eric);
  await until(() => subtabs(we).includes("Inventory!"));
  await click(we, '[data-tab="inventory"]', 300);
  await until(() => $$(we, ".invitem").length > 0);
  const ply = await one("select id from inv_items where list_key='plywood' order by sort_order limit 1");
  type(we, `[data-inv="${ply.id}|n"]`, "12");
  setOffline(true);
  await click(we, "[data-invsend]"); await click(we, "[data-confirm]", 400);
  await until(() => /Waiting to send/.test(txt(we)));
  ok("Full Custom offline: 'Waiting to send', and the ! goes", /Waiting to send/.test(txt(we)) && subtabs(we).includes("Inventory"));
  setOffline(false);
  we.dispatchEvent(new we.Event("online"));
  await until(async () => (await one("select count(*)::int n from inv_sends where list_key='plywood'")).n === 1, 6000);
  ok("back online: it sends itself, once", (await one("select count(*)::int n from inv_sends where list_key='plywood'")).n === 1
     && Number((await one("select qty from inv_counts where item_id=$1 and month_end='2000-03-31'", [ply.id])).qty) === 12);

  // ---- Mike: Inventory only on his Finishing tab, not Sanding ----
  const wm = boot(users.mike);
  await until(() => $$(wm, ".subtab").length > 0); await wait(400);
  const onFirst = subtabs(wm).some(t => /^Inventory/.test(t));
  await click(wm, '[data-dept="finishing"]', 400);
  await until(() => subtabs(wm).some(t => /^Inventory/.test(t)));
  ok("Mike (Sanding + Finishing): Inventory on Finishing only", !onFirst && subtabs(wm).includes("Inventory!"), subtabs(wm).join(","));

  // ---- KP and Jim ----
  const wk = boot(users.kp);
  await until(() => subtabs(wk).some(t => /^Inventory/.test(t)));
  await click(wk, '[data-tab="inventory"]', 300); await until(() => $$(wk, ".invitem").length > 0);
  ok("KP: the Other list (hardware, each)", $$(wk, ".invitem").length === 9 && /Casters/.test(txt(wk)));

  // ---- Test Supervisor: nothing ----
  const wt = boot(users.test);
  await until(() => $$(wt, ".subtab").length > 0 || $$(wt, ".deptbtn").length > 0); await wait(500);
  ok("the Test Supervisor never sees an Inventory tab", !subtabs(wt).some(t => /^Inventory/.test(t)), subtabs(wt).join(","));

  // ---- the office closes the month: the tab goes ----
  await admin.query("update inv_months set status='closed' where month_end='2000-03-31'");
  const w2 = boot(users.willie);
  await until(() => $$(w2, ".subtab").length > 0); await wait(500);
  ok("after the month closes, Metal's tabs are back to normal", !subtabs(w2).some(t => /^Inventory/.test(t)), subtabs(w2).join(","));

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_inv_needs.js
```javascript
// Office page: the Inventory link in the ☰ menu and the Inventory section on Needs you.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.OFFICE || "../out/office.html", "utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  w.supabase = { createClient: () => client };
  w.URL.createObjectURL = () => "blob:x"; w.URL.revokeObjectURL = () => {}; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function signedIn(w) { await until(() => /This is my own computer/.test(txt(w)) || w.document.querySelector(".tab")); const b = w.document.querySelector("[data-nopin]"); if (b) { b.click(); await wait(300); } await until(() => w.document.querySelector(".tab")); await wait(500); }
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
(async () => {
  let w = boot(users.luke);
  await signedIn(w);
  ok("before count day: no Inventory section on Needs you", !w.document.querySelector('[data-need="inventory"]'));
  w.document.querySelector("[data-menu]").click(); await wait(80);
  const link = w.document.querySelector('a[href="inventory.html"]');
  ok("the ☰ menu has Inventory, under Deliveries", link && /Inventory/.test(link.textContent) && link.previousElementSibling && /Deliveries/.test(link.previousElementSibling.textContent));
  const before = Number((w.document.querySelector('.tab[data-tab="tasks"] .n') || {}).textContent || 0);
  // two days after a count day, nothing sent yet
  await admin.query("insert into inv_months (month_end) values ('2000-03-31')");
  w = boot(users.luke);
  await signedIn(w);
  await until(() => !!w.document.querySelector('[data-need="inventory"]'));
  const sec = w.document.querySelector('[data-need="inventory"]');
  ok("counts late: an Inventory section with one line per list (5)", sec && sec.querySelectorAll(".task").length === 5, sec && sec.textContent.replace(/\s+/g, " ").slice(0, 200));
  ok("...each says whose tablet", sec && /Metal count for March isn't in yet — Metal's tablet/.test(sec.textContent) && /Lumber count for March isn't in yet — Lumber count on the Inventory page/.test(sec.textContent));
  const after = Number((w.document.querySelector('.tab[data-tab="tasks"] .n') || {}).textContent || 0);
  ok("...and adds 5 to the Needs you number", after === before + 5, `${before} → ${after}`);
  // a supervisor's office page never reads it (the view gives them nothing anyway)
  const r = await makeClient(users.willie).from("v_inv_needs").select("*");
  ok("the database gives a supervisor no Needs you inventory rows", Array.isArray(r.data) && r.data.length === 0);
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  await admin.end(); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### snap_inv.js
```javascript
const fs=require("fs"); const { JSDOM } = require("jsdom"); const fidb=require("fake-indexeddb"); const { makeClient, admin, users } = require("./pgsupa");
const wait=(ms)=>new Promise(r=>setTimeout(r,ms));
function boot(file,user,url){ const html=fs.readFileSync(file,"utf8").replace(/<script src="[^"]+"[^>]*><\/script>/g,""); const client=makeClient(user);
  const dom=new JSDOM(html,{runScripts:"outside-only",url}); const w=dom.window; w.indexedDB=new fidb.IDBFactory(); w.IDBKeyRange=fidb.IDBKeyRange;
  w.supabase={createClient:()=>client}; w.scrollTo=()=>{}; w.confirm=()=>true; w.URL.createObjectURL=()=>"blob:x";
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]); return w; }
const dump=(w,name)=>{ const d=w.document.cloneNode(true); d.querySelectorAll("script").forEach(s=>s.remove()); fs.writeFileSync(`/tmp/snap_${name}.html`,"<!DOCTYPE html>"+d.documentElement.outerHTML); };
(async()=>{
  const maple=(await admin.query("select id from inv_items where name='Maple 6/4'")).rows[0].id;
  await admin.query(`select 1`);
  const lu=makeClient(users.luke);
  await lu.rpc("set_lumber_line",{p_item:maple,p_length:114,p_bundles:[57,38.25],p_width:42});
  await lu.rpc("set_lumber_line",{p_item:maple,p_length:96,p_bundles:[11,8],p_width:42});
  await lu.rpc("add_inventory_receipt",{p_kind:"lumber",p_date:"2026-09-03",p_supplier:"Frank Miller Lumber",p_item:maple,p_board_feet:1400,p_sheets:null,p_note:null,p_client_id:null});
  let w=boot("/home/claude/inv/inventory.html",users.luke,"https://x/shop-floor/inventory.html"); await wait(1500);
  w.localStorage.setItem("sfi_open", JSON.stringify({[maple]:true}));
  dump(w,"month");
  for (const t of ["lumber","rollover","scrap","setup","deliveries"]) { w.document.querySelector(`#tabs [data-tab="${t}"]`).click(); await wait(400);
    if (t==="lumber") { const c=w.document.querySelector(`details[data-item="${maple}"]`); c.open=true; c.dispatchEvent(new w.Event("toggle")); await wait(100);} dump(w,t); }
  await admin.query("insert into inv_months (month_end) values ('2000-03-31')");
  w=boot("/home/claude/inv/site/index.html",users.willie,"https://x/shop-floor/index.html"); await wait(1500);
  w.document.querySelector('[data-tab="inventory"]').click(); await wait(800);
  const inp=w.document.querySelector('[data-inv$="|sticks"]'); inp.value="5"; inp.dispatchEvent(new w.Event("input",{bubbles:true}));
  dump(w,"tablet");
  await admin.end(); process.exit(0);
})();
```

#### test_inv_dept.js
```javascript
// The office Inventory page's Department counts tab: the real inventory.html (and the real tablet index.html)
// in jsdom, against the real test database through the login path Supabase uses. Fresh database:
//   ../fresh_inv.sh /home/claude/inv/inventory.sql && node test_inv_dept.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const fidb = require("fake-indexeddb");
const { makeClient, admin, users } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/, "");
const page = strip(fs.readFileSync(process.env.PAGE || "/home/claude/inv/inventory.html", "utf8"));
const tablet = strip(fs.readFileSync("/home/claude/inv/site/index.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
function boot(html, user, url) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url });
  const w = dom.window;
  w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.URL.createObjectURL = () => "blob:x"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = (m) => { w.lastConfirm = m; return true; };
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const office = (u) => boot(page, u, "https://lukehart1228.github.io/shop-floor/inventory.html");
const tab = (u) => boot(tablet, u, "https://lukehart1228.github.io/shop-floor/index.html");
const txt = (w) => (w.document.getElementById("app").textContent).replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 120) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
function type(w, sel, value) { const el = typeof sel === "string" ? $(w, sel) : sel; el.value = value; el.dispatchEvent(new w.Event("input", { bubbles: true })); }
const openDept = async (w, list) => {
  await until(() => $(w, '#tabs [data-tab="dept"]'));
  await click(w, '#tabs [data-tab="dept"]');
  if (list) await click(w, `[data-dlist="${list}"]`);
};

(async () => {
  const steel = await one("select id, name, std_length_ft from inv_items where list_key='metal' and std_length_ft = 24 and not retired order by sort_order limit 1");
  const each = await one("select id from inv_items where list_key='metal' and std_length_ft is null and not retired order by sort_order limit 1");
  const nMetal = (await one("select count(*)::int n from inv_items where list_key='metal' and not retired")).n;

  // ===== before count day (25 Sep): a preview =====
  let w = office(users.luke);
  await openDept(w);
  ok("a Department counts tab, with the four department lists", $$(w, "[data-dlist]").map(b => b.dataset.dlist).join(",") === "plywood,metal,finish,other", $$(w, "[data-dlist]").map(b => b.dataset.dlist).join(","));
  await click(w, '[data-dlist="metal"]');
  ok(`Metal: the whole list, grouped as on the tablet (${nMetal} items)`, $$(w, ".invitem").length === nMetal && $$(w, ".invgroup").length >= 5, `${$$(w, ".invitem").length} items`);
  ok("says it's a preview of what Metal sees from 30 Sep", /Preview — this is the list Metal sees on their tablet from 30 Sep/.test(txt(w)), txt(w).slice(0, 200));
  ok("steel rows ask for sticks + loose feet, with last month's count", /24' sticks · last month/.test(txt(w)) && $(w, `[data-dinv="${steel.id}|sticks"]`) && $(w, `[data-dinv="${steel.id}|loose"]`));
  type(w, `[data-dinv="${steel.id}|sticks"]`, "5"); type(w, `[data-dinv="${steel.id}|loose"]`, "7");
  ok("typing works in the preview: = 127 ft, 1 of N counted", /= 127 ft/.test($(w, `[data-deq="${steel.id}"]`).textContent) && new RegExp(`1 of ${nMetal} counted`).test($(w, ".invcount").textContent), $(w, ".invcount").textContent);
  ok("…but Send is off, and says it opens 30 Sep", $(w, "[data-dsend]").disabled && /Opens 30 Sep/.test(txt(w)));
  ok("nothing was sent", (await one("select count(*)::int n from inv_sends")).n === 0);
  await click(w, '[data-dlist="finish"]');
  ok("Finish (due in September) shows its preview too", /Preview — this is the list Finishing sees/.test(txt(w)) && $$(w, ".invitem").length === 9);
  await click(w, '#tabs [data-tab="month"]');
  ok("This month: each department card has 'Open the list'", $$(w, "[data-golist]").length === 4);
  await click(w, '[data-golist="other"]');
  ok("…which opens that list on Department counts", $(w, '#tabs [data-tab="dept"]').getAttribute("aria-current") === "true" && $(w, '[data-dlist="other"]').getAttribute("aria-pressed") === "true");

  // ===== a month where the quarterly lists aren't due =====
  await admin.query("insert into inv_months (month_end) values ('2000-01-31')");
  w = office(users.luke); await openDept(w, "finish");
  ok("January: Finish says Not due — every three months", /Not due in January/.test(txt(w)) && $$(w, ".invitem input:not([disabled])").length === 0 && !$(w, "[data-dsend]"));
  await admin.query("delete from inv_months where month_end = '2000-01-31'");

  // ===== count day (a March month whose last day has passed): the office counts for Metal =====
  await admin.query("insert into inv_months (month_end) values ('2000-03-31')");
  w = office(users.luke); await openDept(w, "metal");
  ok("count day: 'Waiting for Metal's tablet', Send is on", /Waiting for Metal's tablet/.test(txt(w)) && $(w, "[data-dsend]") && !$(w, "[data-dsend]").disabled, txt(w).slice(0, 160));
  type(w, `[data-dinv="${steel.id}|sticks"]`, "3"); type(w, `[data-dinv="${steel.id}|loose"]`, "4.5");
  type(w, `[data-dinv="${each.id}|n"]`, "2");
  await click(w, "[data-dsend]", 50);
  ok("Send asks first: blanks count as 0, recorded as sent by Luke", /Send the Metal count for Metal\?/.test(w.lastConfirm) && /blank and will count as 0/.test(w.lastConfirm) && /sent by Luke H/.test(w.lastConfirm), w.lastConfirm);
  await until(async () => (await one("select count(*)::int n from inv_sends where list_key='metal' and month_end='2000-03-31'")).n === 1);
  const snd = await one("select * from inv_sends where list_key='metal' and month_end='2000-03-31'");
  ok("in the database: sent once, by Luke H", snd && snd.sent_by_name === "Luke H" && snd.withdrawn_at === null, JSON.stringify(snd && snd.sent_by_name));
  const c1 = await one("select qty, sticks, loose_ft from inv_counts where item_id=$1 and month_end='2000-03-31'", [steel.id]);
  ok("steel saved as 3 sticks + 4.5 ft = 76.5 ft; the typed item 2; the blanks 0", Number(c1.qty) === 76.5 && c1.sticks === 3 && Number(c1.loose_ft) === 4.5
     && Number((await one("select qty from inv_counts where item_id=$1 and month_end='2000-03-31'", [each.id])).qty) === 2
     && (await one("select count(*)::int n from inv_counts c join inv_items i on i.id=c.item_id where i.list_key='metal' and c.month_end='2000-03-31' and c.qty=0")).n === nMetal - 2);
  await until(() => /Metal count sent/.test(txt(w)));
  ok("the page shows it sent, numbers locked, with Change the count", /Metal count sent .* by Luke H/.test(txt(w)) && $$(w, ".invitem input:not([disabled])").length === 0 && $(w, "[data-dreopen]"));
  ok("…showing the numbers as sent (3 sticks + 4.5 ft)", $(w, `[data-dinv="${steel.id}|sticks"]`).value === "3" && $(w, `[data-dinv="${steel.id}|loose"]`).value === "4.5");
  ok("the Metal button gets a ✓", /✓/.test($(w, '[data-dlist="metal"]').textContent));

  // Willie's tablet sees it as sent
  let t = tab(users.willie);
  await until(() => $$(t, ".subtab").some(b => /Inventory/.test(b.textContent)));
  await click(t, '[data-tab="inventory"]', 400);
  await until(() => /Metal count sent/.test(txt(t)));
  ok("Willie's tablet shows 'Metal count sent — by Luke H', no ! on the tab", /Metal count sent — by Luke H/.test(txt(t)) && !$$(t, ".subtab").some(b => /Inventory!/.test(b.textContent)));

  // ===== Change the count from the office, then Willie sends his own =====
  await click(w, "[data-dreopen]", 50);
  await until(async () => (await one("select withdrawn_at from inv_sends where id=$1", [snd.id])).withdrawn_at !== null);
  await until(() => /Waiting for Metal's tablet/.test(txt(w)));
  ok("Change the count: open again, keeping the numbers as sent to edit", /Waiting for Metal's tablet/.test(txt(w)) && $(w, `[data-dinv="${steel.id}|sticks"]`).value === "3" && !$(w, `[data-dinv="${steel.id}|sticks"]`).disabled);
  t = tab(users.willie);
  await until(() => $$(t, ".subtab").some(b => /Inventory!/.test(b.textContent)));
  ok("…and Willie's tablet shows the count open again (Inventory!)", $$(t, ".subtab").some(b => /Inventory!/.test(b.textContent)));
  await click(t, '[data-tab="inventory"]', 400);
  await until(() => $(t, "[data-invsend]"));
  type(t, `[data-inv="${steel.id}|sticks"]`, "6");
  await click(t, "[data-invsend]"); await until(() => $(t, ".modal button, [data-yes]"), 1500);
  const yes = $$(t, "button").find(b => /Send it/.test(b.textContent)); if (yes) yes.click();
  await until(async () => (await one("select count(*)::int n from inv_sends where list_key='metal' and withdrawn_at is null and month_end='2000-03-31'")).n === 1, 5000);
  w = office(users.luke); await openDept(w, "metal");
  await until(() => /Metal count sent/.test(txt(w)));
  ok("the office then shows Willie's send and his number (6 sticks)", /by Willie/.test(txt(w)) && $(w, `[data-dinv="${steel.id}|sticks"]`).value === "6", txt(w).slice(0, 160));
  // a second send from the office is refused by the database, not just hidden
  const r = await makeClient(users.luke).rpc("send_inventory_count", { p_list: "metal", p_counts: [], p_client_id: null });
  ok("sending over a count that's in is refused by the database (press Change first)", r.error && /already sent by Willie/.test(r.error.message), r.error && r.error.message);

  // ===== who can use it =====
  w = office(users.willie);
  await until(() => /For managers/.test(txt(w)));
  ok("a supervisor on inventory.html still gets 'For managers', no tabs", /For managers/.test(txt(w)) && w.document.getElementById("tabs").hidden);
  const other = await makeClient(users.willie).from("inv_items").select("id").eq("list_key", "plywood");
  ok("Willie still can't read another department's list (database)", !other.error && other.data.length === 0);
  const ws = await makeClient(users.willie).rpc("send_inventory_count", { p_list: "plywood", p_counts: [], p_client_id: null });
  ok("…or send it", ws.error && /can't send/.test(ws.error.message), ws.error && ws.error.message);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```
