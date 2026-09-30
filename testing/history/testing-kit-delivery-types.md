# Testing kit, part 16 — Delivery types: white glove, BOL pickup, customer pickup (30 Sep 2026)

*For build chats. Luke doesn't need to read this.* Parts 1–15 still apply.

## Setup notes (30 Sep)

- The sandbox had Postgres 16 but not pg_cron or `http`: `rm -f /etc/apt/sources.list.d/nodesource*`, `apt-get update`, install `postgresql-16-cron libcurl4-openssl-dev postgresql-server-dev-16 poppler-utils`, build pgsql-http, cluster on 5433 (`testing-kit.md` §1). npm as Part 8.
- **Live pages come from GitHub**, not the site-files docs: `git clone https://github.com/lukehart1228/shop-floor.git` (public). Commit `72a2196` was live. Copy its `*.html` and `sw.js` over what `extract.py` wrote.
- `kx.py` (below) pulls one code block out of a kit doc by its `####` heading, so helpers aren't retyped: `extract.py`, `load.sh`, `fresh.sh` (Part 11), `stubs.sql`, `people.sql`, `seed.sql`, `pgsupa.js` (Part 3), Part 11's seed additions (appended to `seed.sql`), `routes_seed.sql` / `past_seed.sql` (Part 14), `pngtiny.js`, `test_deliveries.js`, `test_mike_same.js` (Part 8).
- `pgsupa.js`: Part 11's JSON patch, Part 8's `ftypes`, and `users` gains `jim` (`99999999-9999-9999-9999-999999999990`, `finish@`) and `eric` (`aaaa…`, `fullcustom@`). **Jim is not `9999…9999`**: that id is Julia's in `test_deliveries.js`. `people.sql` gets the same two rows.
- Load order for `sync_base`: `load.sh` + `inventory.sql`, `finish_by.sql`, `pace.sql`, `send_routes.sql`, `arrow_pickup.sql`, **then `pace.sql` again**. Without the second `pace.sql`, `check_pace()` step 1 fails (Metal paint arrives with send routes, after pace). That matches the live order (pace was re-run after send routes).
- `checks.sh` runs every live check and prints `n/m` per check.
- **pdf-lib reads a pooled Node Buffer from its start**, not its offset: `fs.readFileSync()` of a small JPEG fails `embedJpg` with "SOI not found". Wrap it: `new Uint8Array(fs.readFileSync(...))`. The pages are fine (they use `new Uint8Array(await blob.arrayBuffer())`).
- `select *` over `loadouts l join jobs j` returns jobs' `id`: use `l.*`.
- `test_mike_same.js` (Part 8) no longer ran: the defect/problem buttons it clicked are gone. The version below walks every tab a login has, opens the first job and sheet, and compares with ids blanked, for Mike, Donnie, Willie, KP, Jim and Eric.

## Results when delivered

| Test | Result |
|---|---|
| `delivery_types.sql` twice on a seeded database; `check_delivery_types()` | 11/11 PASS each time; nothing left behind |
| Every live check after it (verify_setup 10, floor 18, photos 16, advance 10, supply lists 10, load-outs 12, deliveries 16, deliveries v2 6, ready issues 14, finish-by 12, inventory 16, pace 13, send routes 13, Arrow pick-up 10, test lane 10) | All PASS. deliveries v2 row 5 first failed: it looks for "already delivered" in the cancel refusal, so that wording is kept |
| `breaks_pickups.py` — 14 broken versions | Each caught at its own step. "Phone cancels Julia's" was first missed (the started-by rule also blocks it); step 9 now has the Test Supervisor set it up, then lose the scheduler flag, as `check_deliveries_v2` row 2 does |
| `test_pickups.js` | 50/50 |
| `test_deliveries.js`: live pages on the new database / new pages on the old database | 76/76 · 76/76 |
| `test_deliveries_noship.js` (Part 8's without its shipment block): new pages, new database | 73/73. The shipment block now meets the BOL pickup screen, on purpose |
| `test_pickups_nosql.js`: new pages, old database | 2/2 (no kinds on Julia's page; Delivery / Shipping on the phone) |
| `test_mike_same.js` (new version) | 6/6 — every supervisor's screens identical to the live page |
| Screens (`snap_pk.js`): Julia's form and Coming up at 1280 and 390, the phone's list, the BOL pickup, its confirm and done, the customer pickup | Looked right; nothing wider than the screen |

Not covered: the real SQL Editor, GitHub Pages, a real phone's camera and signature, pdf-lib from jsDelivr in a real browser.

## Files

#### kx.py
```python
import re,sys
# kx.py kitfile "heading prefix" outpath  -> first code block under the #### heading starting with prefix
src,pre,out=sys.argv[1:4]
t=open(src).read()
lines=t.split('\n')
for i,l in enumerate(lines):
    if re.match(r'^#{3,4} ',l) and l.lstrip('#').strip().startswith(pre):
        rest='\n'.join(lines[i+1:])
        m=re.search(r'^(```+|~~~+)[a-zA-Z]*\n(.*?)^\1\s*$',rest,flags=re.S|re.M)
        open(out,'w').write(m.group(2)); print(out,len(m.group(2))); break
else: print("NOT FOUND",pre)
```

#### checks.sh
```bash
#!/bin/bash
for c in verify_setup check_floor check_photos check_advance check_supply_lists check_loadouts check_deliveries check_deliveries_v2 check_ready_issues check_finish_by check_inventory check_pace check_send_routes check_arrow_pickup check_test_lane "$@"; do
  r=$(psql -h /tmp/pg -p 5433 -U postgres -d sync -At -c "select count(*) filter (where result='PASS') || '/' || count(*) from $c()" 2>&1 | tail -1); echo "$c $r"; done
```

#### tiny.jpg (in `t/`)
```bash
python3 -c "from PIL import Image; Image.new('RGB',(40,60),(200,190,160)).save('tiny.jpg','JPEG')"
```

#### test_pickups.js
```javascript
// Delivery types: the helpers from test_deliveries.js (pages, stand-ins), then test_pickups_body.js.
// Run: ../base/fresh.sh /home/claude/sf/out/delivery_types.sql && TZ=America/Indiana/Indianapolis node test_pickups.js
const src = require("fs").readFileSync(__dirname + "/test_deliveries.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")) + require("fs").readFileSync(__dirname + "/test_pickups_body.js", "utf8"));
```

#### test_pickups_body.js
```javascript
// Delivery types (30 Sep): Julia's three kinds, Ready for pickup, the phone's BOL and customer pickups, Completed, the office.
// Runs after test_deliveries.js's helpers (see test_pickups.js). Needs delivery_types.sql loaded.
const tinyJpg = new Uint8Array(fs.readFileSync(__dirname + "/tiny.jpg"));
const bootApp2 = (...a) => { const w = bootApp(...a); w.sfShrinkPhoto = async () => ({ blob: new Blob([tinyJpg], { type: "image/jpeg" }), width: 40, height: 60 }); return w; };
const pslot = (w, sheet, piece) => $(w, `[data-loshoot="${sheet}"][data-piece="${piece}"]`);
(async () => {
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  await admin.query("select set_delivery_scheduler($1, true)", [julia.email]);
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-2.png', now()),
      (w, 3, 2, 'TR-03', 'Oval', '42"', '84"', '30"', 'PROJ-00362/v1/sheet-3.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);
  const tdoc = await PDFLib.PDFDocument.create(); tdoc.addPage([612, 792]); tdoc.addPage([612, 792]);
  const ticketBytes = Buffer.from(await tdoc.save());
  const jpg = new Uint8Array(fs.readFileSync(__dirname + "/tiny.jpg"));   // a copy: pdf-lib reads a pooled Buffer from its start

  // ================= the core =================
  const coreOf = (html) => { const m = { exports: {} }; new Function("module", "require", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1])(m, require); return m.exports; };
  const D = coreOf(DLV), C = coreOf(APP), O = coreOf(OFFICE);
  ok("core: three kinds, named White glove · BOL pickup · Customer pickup", C.TRIP_KINDS.map(k => k[1]).join(" · ") === "White glove · BOL pickup · Customer pickup" && C.tripName("shipping") === "BOL pickup");
  const sh = [{ sheet_number: 1, qty: 2 }, { sheet_number: 2, qty: 1 }];
  let pl = C.pickupPlan(sh, { kind: "shipping", pieces_here: ["1:1"], pallets_here: [], bol_here: 0 }, [], 1);
  ok("core: a BOL pickup isn't ready without a pallet and the BOL", !pl.ready && pl.tables.done === 1 && pl.tables.total === 3);
  pl = C.pickupPlan(sh, { kind: "shipping", pieces_here: ["1:1"], pallets_here: [1], bol_here: 0 }, [{ stage: "bol" }], 1);
  ok("core: ...with a pallet photographed and a BOL photo waiting, it is", pl.ready && pl.bolHere === 1 && pl.bolWaiting === 1);
  pl = C.pickupPlan(sh, { kind: "customer_pickup", pieces_here: [] }, [{ kind: "pickup_done", signed: true, signedName: "Pat" }], 1);
  ok("core: a customer pickup marked done on the phone counts as done", pl.done && pl.ready && !pl.bol);
  const blo = { kind: "shipping", pieces_total: 3, pieces_here: ["1:1", "2:1"], pallets_here: [1, 2], bol_here: 1, completed_at: "x" };
  ok("core: the phone's line for a BOL pickup", C.pickupLine(blo, C.pickupPlan(sh, blo, [], 1))
     === "BOL pickup · 2 of 3 tables photographed · 2 pallets · BOL photographed · picked up");
  const sp = D.splitDeliveries([{ is_done: false, kind: "delivery", scheduled_for: "2026-10-05" }, { is_done: false, kind: "shipping", ready_at: "2026-09-30" },
                                { is_done: false, kind: "customer_pickup", ready_at: "2026-09-29" }, { is_done: true, kind: "shipping", completed_at: "2026-09-30" }]);
  ok("Julia core: deliveries by date; pickups on their own list, oldest first; done", sp.up.length === 1 && sp.ready.length === 2 && sp.ready[0].kind === "customer_pickup" && sp.done.length === 1);
  ok("Julia core: the BOL's download is \"PROJ-00362 BOL pickup 2026-10-02.pdf\"", D.bolFileName({ project_id: "PROJ-00362", completed_at: "2026-10-02T18:00:00Z" }) === "PROJ-00362 BOL pickup 2026-10-02.pdf");
  const rec = await D.buildBolRecord(PDFLib, { project_id: "PROJ-00362", completed_at: "2026-10-02T18:00:00Z", carrier: "Estes", tracking: "44812", pallets_photographed: 2 },
                                     { bytes: ticketBytes, mime: "application/pdf" }, [{ bytes: jpg, mime: "image/jpeg" }, { bytes: jpg, mime: "image/jpeg" }]);
  ok("Julia core: the BOL record is the 2-page ticket, a page per BOL photo (2) and the record page", (await PDFLib.PDFDocument.load(rec)).getPageCount() === 5);
  const cp = await D.buildSignedTicket(PDFLib, { kind: "customer_pickup", project_id: "P", completed_at: "2026-10-02T18:14:00Z", signed_name: "Pat" }, { bytes: ticketBytes, mime: "application/pdf" }, png(300, 100));
  const cpo = await O.buildSignedTicket(PDFLib, { kind: "customer_pickup", project_id: "P", completed_at: "2026-10-02T18:14:00Z", signed_name: "Pat" }, { bytes: ticketBytes, mime: "application/pdf" }, png(300, 100));
  ok("core: a customer pickup's signed ticket, same on Julia's page and the office", (await PDFLib.PDFDocument.load(cp)).getPageCount() === 3 && (await PDFLib.PDFDocument.load(cpo)).getPageCount() === 3
     && (await PDFLib.PDFDocument.load(cp)).getTitle() === "P pickup ticket, signed");

  // ================= Julia sets up two pickups =================
  let w = bootPage(DLV, "delivery.html", julia);
  await until(() => $$(w, "[data-kind]").length === 3 && $$(w, "[data-pickjob]").length > 0);
  ok("Julia: What kind? — White glove, BOL pickup, Customer pickup; White glove picked to start", $$(w, "[data-kind]").map(b => b.querySelector("b").textContent).join("|") === "White glove|BOL pickup|Customer pickup"
     && $(w, '[data-kind="delivery"]').getAttribute("aria-pressed") === "true" && !!$(w, "#dd"));
  await click(w, '[data-kind="shipping"]');
  ok("BOL pickup: no date or time; the button says Ready for pickup", !$(w, "#dd") && !$(w, "#dt") && /Put it on Ready for pickup \(BOL pickup\)/.test($(w, "[data-schedule]").textContent) && $(w, "[data-schedule]").disabled);
  type(w, "#jf", "362"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  ok("...a job is all it needs", !$(w, "[data-schedule]").disabled);
  type(w, "#dn", "Estes, sometime this week. 3 pallets.");
  choose(w, "#ticketIn", [new w.File([ticketBytes], "Ticket 5102.pdf", { type: "application/pdf" })]); await wait(50);
  await click(w, "[data-schedule]", 50);
  await until(() => /on Delivery's phone now/.test(txt(w)), 8000);
  const bl = await one("select * from loadouts where kind = 'shipping' and ready_at is not null");
  ok("saved: a BOL pickup, ready, no date, the note, set up by Julia, with its ticket", bl && !bl.scheduled_for && bl.pickup_steps && bl.schedule_note === "Estes, sometime this week. 3 pallets." && bl.scheduled_by_name === "Julia R"
     && (await one("select count(*)::int n from delivery_docs where loadout_id = $1 and kind = 'ticket'", [bl.id])).n === 1, txt(w).slice(0, 200));
  ok("...and says so: \"PROJ-00362: ready for bol pickup\"", /PROJ-00362: ready for bol pickup\. It's on Delivery's phone now\./.test(txt(w)), txt(w).slice(0, 200));
  await click(w, '[data-tab="new"]');
  await click(w, '[data-kind="customer_pickup"]');
  type(w, "#jf", "418"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  await click(w, "[data-schedule]", 50);
  await until(async () => (await one("select count(*)::int n from loadouts where ready_at is not null")).n === 2, 6000);
  await until(() => /Ready for pickup/.test(txt(w)));
  ok("Coming up: Ready for pickup, both, oldest first, with Ready since; the tab counts 2", /Ready for pickup ?BOL pickup ?PROJ-00362.*Ready since.*Note: Estes.*Customer pickup ?PROJ-00418/.test(txt(w)) && /Coming up2/.test($(w, '[data-tab="up"]').textContent), txt(w).slice(0, 300));
  const cu = await one("select * from loadouts where kind = 'customer_pickup'");
  await click(w, `[data-editnote="${cu.id}"]`);
  type(w, "#en", "Pat is coming Thursday with a van.");
  await click(w, `[data-savenote="${cu.id}"]`, 50);
  await until(async () => (await one("select schedule_note n from loadouts where id = $1", [cu.id])).n === "Pat is coming Thursday with a van.");
  ok("Change the note on a pickup: saved (no date asked for)", /PROJ-00418: note saved\./.test(txt(w)));
  // a third, to cancel
  await click(w, '[data-tab="new"]'); await click(w, '[data-kind="customer_pickup"]');
  type(w, "#jf", "099"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  await click(w, "[data-schedule]", 50);
  await until(async () => (await one("select count(*)::int n from loadouts where ready_at is not null")).n === 3, 6000);
  const c99 = await one("select l.* from loadouts l join jobs j on j.id = l.job_id where j.project_id = 'PROJ-00099' and l.ready_at is not null");
  await until(() => $(w, `[data-cancel="${c99.id}"]`));
  await click(w, `[data-cancel="${c99.id}"]`, 50);
  await until(async () => !!(await one("select voided_at from loadouts where client_id = $1", [c99.client_id])).voided_at);
  await until(() => /was ready for customer pickup/.test(txt(w)));
  ok("Cancel this pickup: under Cancelled, \"was ready for customer pickup\"", /The customer pickup of PROJ-00099 is cancelled\./.test(txt(w)) && /Cancelled in the last 60 days.*PROJ-00099.*was ready for customer pickup/.test(txt(w)), txt(w).slice(0, 400));
  await wait(500); w.close();

  // ================= the phone: a BOL pickup =================
  const cachesA = fakeCaches(), idbA = new fidb.IDBFactory();
  w = bootApp2(users.shawn, { caches: cachesA, idb: idbA });
  await until(() => /Ready for pickup/.test(txt(w)));
  ok("Shawn's Load-out: Ready for pickup at the top, both, with Ready since and the line", /^.*Ready for pickup ?PROJ-00362.*ready since.*BOL pickup · 0 of 6 tables photographed · 0 pallets · no BOL photo yet.*PROJ-00418.*Customer pickup · 0 of 20 tables photographed/.test(txt(w))
     && txt(w).indexOf("Ready for pickup") < txt(w).indexOf("Start a load-out") && !/PROJ-00099/.test(txt(w).slice(0, txt(w).indexOf("Start a load-out"))), txt(w).slice(0, 400));
  ok("Start a load-out has the three kinds", $$(w, "[data-lostartkind]").map(b => b.dataset.lostartkind).join() === "delivery,shipping,customer_pickup");
  await click(w, `[data-loopen="${bl.client_id}"]`, 300);
  await until(() => /1 · Every table, before it's wrapped/.test(txt(w)), 6000);
  ok("the BOL pickup: its kind and date line, the note, the ticket; no kind switch", /BOL pickup · ready since/.test($(w, ".dlwhen").textContent) && /Note from Julia R: Estes/.test(txt(w)) && !!$(w, '[data-dlopen][data-name="Ticket"]') && !$(w, "[data-lokind]"));
  ok("...three steps: tables, pallets, the BOL; no truck or site", /2 · Each pallet, once it's wrapped/.test(txt(w)) && /3 · The BOL — a photo of each page/.test(txt(w)) && !$(w, "[data-dltruck]") && !$(w, "[data-dlsite]"));
  ok("...Picked up is off: \"Needs a photo of a wrapped pallet and a photo of the BOL first\"", $(w, "[data-pkdone]").disabled && /Needs a photo of a wrapped pallet and a photo of the BOL first\./.test(txt(w)));
  await click(w, pslot(w, 1, 1)); await snap(w, { lastModified: Date.now() - 3600000 });
  ok("a gallery photo of a table is refused (camera only)", /wasn't just taken/.test(txt(w)) && (await one("select count(*)::int n from photos")).n === 0);
  await click(w, pslot(w, 1, 1)); await snap(w);
  await click(w, "[data-lopallet]"); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos")).n === 2, 6000);
  ok("...a table and a wrapped pallet: still off until the BOL", $(w, "[data-pkdone]").disabled && /Needs a photo of the BOL first/.test(txt(w)));
  await click(w, '[data-pkbol="1"]'); await snap(w, { lastModified: Date.now() - 3600000 });
  ok("a BOL from the gallery is refused too", (await one("select count(*)::int n from photos where stage = 'bol'")).n === 0 && /wasn't just taken/.test(txt(w)));
  await click(w, '[data-pkbol="1"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where stage = 'bol'")).n === 1, 6000);
  await click(w, "[data-pkbolmore]");
  await click(w, '[data-pkbol="2"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where stage = 'bol'")).n === 2, 6000);
  const bp = await all("select note, stage, sheet_number, shot_at from photos where stage = 'bol' order by taken_at");
  ok("the BOL: two pages saved, \"BOL page 1\" and \"BOL page 2\", with the phone's time", bp.map(x => x.note).join("|") === "BOL page 1|BOL page 2" && bp.every(x => x.sheet_number === null && x.shot_at));
  type(w, "#loCarrier", "Estes"); type(w, "#loTracking", "44812"); await click(w, "[data-losavedet]", 100);
  await until(async () => !!(await one("select 1 x from loadouts where id = $1 and carrier = 'Estes' and tracking = '44812'", [bl.id])));
  ok("carrier and BOL number saved", !!(await one("select 1 x from loadouts where id = $1 and carrier = 'Estes' and tracking = '44812'", [bl.id])));
  await until(() => !$(w, "[data-pkdone]").disabled);
  type(w, "#dlNote", "Driver counted 1 pallet");
  await click(w, "[data-pkdone]");
  ok("Picked up asks first, naming the tables not photographed", /PROJ-00362 picked up\?/.test($(w, ".mdl").textContent) && /Not photographed — sheet 1: tables 2, 3 · sheet 2: the table · sheet 3: all 2 tables\./.test($(w, ".mdl").textContent.replace(/\s+/g, " ")), $(w, ".mdl").textContent.replace(/\s+/g, " "));
  setOffline(true);
  await click(w, "[data-confirm]", 300);
  await until(() => /1 pickup waiting to send/.test($(w, ".sync").textContent));
  ok("no signal: picked up on the phone, waiting to send", /1 pickup waiting to send/.test($(w, ".sync").textContent) && /Picked up/.test($(w, ".dldone").textContent) && !(await one("select completed_at from loadouts where id = $1", [bl.id])).completed_at);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => !!(await one("select completed_at from loadouts where id = $1", [bl.id])).completed_at, 8000);
  const bd = await one("select * from loadouts where id = $1", [bl.id]);
  ok("back on signal: picked up, by Shawn, with the note; the load-out finished", bd.completed_by_name === "Shawn K" && bd.customer_note === "Driver counted 1 pallet" && !!bd.finished_at && !bd.signed_name);
  await until(() => /Picked up [A-Z][a-z]{2} /.test($(w, ".dldone").textContent));
  ok("the phone shows it picked up; no buttons left", /Picked up/.test($(w, ".dldone").textContent) && !$(w, "[data-pkbol]") && !$(w, "[data-lopallet]") && !pslot(w, 1, 2));
  await click(w, "[data-loback]", 300);
  await until(() => /Done in the last two weeks/.test(txt(w)));
  ok("the list: under Done, \"Picked up … · Shawn K · BOL pickup · 1 of 6 tables · 1 pallet · BOL photographed · picked up\"",
     /Done in the last two weeks.*PROJ-00362.*Picked up .* · Shawn K · BOL pickup · 1 of 6 tables photographed · 1 pallet · BOL photographed · picked up/.test(txt(w)) && !/Ready for pickup ?PROJ-00362/.test(txt(w)), txt(w).slice(txt(w).indexOf("Done"), txt(w).indexOf("Done") + 200));

  // ================= the phone: the customer pickup, signed =================
  await click(w, `[data-loopen="${cu.client_id}"]`, 300);
  await until(() => /1 · Each table as it's handed over/.test(txt(w)), 6000);
  ok("the customer pickup: tables handed over, then the customer; no pallets or BOL", /2 · The customer/.test(txt(w)) && !$(w, "[data-lopallet]") && !$(w, "[data-pkbol]") && /Note from Julia R: Pat is coming Thursday/.test(txt(w)));
  await click(w, pslot(w, 1, 1)); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where loadout_id = $1", [cu.id])).n === 1, 6000);
  await click(w, '[data-dlnosign="1"]');
  ok("Can't get a signature: only Customer refused and Other", $$(w, "[data-dlreason]").map(b => b.textContent).join("|") === "Customer refused|Other");
  await click(w, '[data-dlnosign="0"]');
  type(w, "#dlName", "Pat Jones"); sign(w); await wait(30);
  await click(w, "[data-dldone]");
  ok("Picked up, signed by Pat Jones? — asks first", /Picked up, signed by Pat Jones\?/.test($(w, ".mdl").textContent));
  await click(w, "[data-confirm]", 300);
  await until(async () => !!(await one("select completed_at from loadouts where id = $1", [cu.id])).completed_at, 8000);
  const cd = await one("select * from loadouts where id = $1", [cu.id]);
  ok("saved: signed by Pat Jones, the signature a PNG in the deliveries bucket", cd.signed_name === "Pat Jones" && !!(await one("select 1 x from delivery_docs where loadout_id = $1 and kind = 'signature' and mime = 'image/png'", [cu.id])));
  await click(w, "[data-loback]", 300);

  // one started on the phone: a customer pickup, not signed
  await until(() => $$(w, "[data-pickjob]").length > 0);
  await click(w, '[data-lostartkind="customer_pickup"]');
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]");
  await click(w, "[data-lostart]", 300);
  await until(() => /1 · Each table as it's handed over/.test(txt(w)), 6000);
  await until(async () => !!(await one("select 1 x from loadouts where kind = 'customer_pickup' and ready_at is null")), 6000);
  ok("started on the phone as a customer pickup: the same steps, the kind switch still there", !!$(w, "[data-lokind]") && /2 · The customer/.test(txt(w)) && $$(w, "[data-lokind]").length === 3);
  await click(w, '[data-dlnosign="1"]'); await click(w, '[data-dlreason="Other"]');
  ok("...Other needs a note", $(w, "[data-dldone]").disabled);
  type(w, '[data-dlsig="reasonNote"]', "Signed the paper copy");
  await click(w, "[data-dldone]"); await click(w, "[data-confirm]", 300);
  await until(async () => !!(await one("select completed_at from loadouts where kind = 'customer_pickup' and ready_at is null")), 8000);
  ok("...picked up, not signed (Other, with the note)", !!(await one("select 1 x from loadouts where kind = 'customer_pickup' and ready_at is null and no_sign_reason = 'Other' and no_sign_note = 'Signed the paper copy'")));
  await wait(500); w.close();

  // Julia's own login on a phone sees Ready for pickup too (she's on Delivery)
  await admin.query("select schedule_pickup(id, 'customer_pickup', null, null, null) from jobs where project_id = 'PROJ-00099'").catch(() => null);
  const jr = await makeClient(julia).rpc("schedule_pickup", { p_job: (await one("select id from jobs where project_id = 'PROJ-00099'")).id, p_kind: "customer_pickup", p_note: null, p_loadout: null, p_client_id: null });
  w = bootApp2(julia);
  await until(() => /Ready for pickup/.test(txt(w)), 6000);
  ok("Julia signed in on the phone: Ready for pickup, PROJ-00099 (she can record it)", !jr.error && /Ready for pickup ?PROJ-00099/.test(txt(w)), jr.error ? jr.error.message : txt(w).slice(0, 200));
  await wait(500); w.close();

  // ================= Julia: Completed =================
  w = bootPage(DLV, "delivery.html", julia, { sfd_tab: JSON.stringify("done") });
  await until(() => /Download the BOL/.test(txt(w)));
  const cardOf = (id) => $$(w, ".card").find(c => c.querySelector(`[data-download="${id}"]`));
  const bc = cardOf(bl.id).textContent.replace(/\s+/g, " ");
  ok("the BOL pickup: New, BOL pickup, picked up, Estes · BOL 44812, 2 BOL photos, 1 pallet, 1 of 6 tables, the note", /New ?PROJ-00362.*BOL pickup.*Picked up.*Shawn K.*Carrier ?Estes · BOL 44812.*BOL ?Photographed \(2 photos\).*Pallets ?1 photographed wrapped.*Tables ?1 of 6 photographed before wrapping.*Note ?Driver counted 1 pallet/.test(bc), bc);
  const cc = cardOf(cu.id).textContent.replace(/\s+/g, " ");
  ok("the customer pickup: Picked up, Signed by Pat Jones, handed over 1 of 20", /Customer pickup.*Picked up.*Signed ?by Pat Jones.*Handed over ?1 of 20 tables photographed.*Download signed ticket/.test(cc), cc);
  await click(w, cardOf(bl.id).querySelector("[data-download]"), 50);
  await until(() => /has downloaded|couldn't|Can't/.test(txt(w)), 8000);
  const bpdf = w.__saved.find(b => b.type === "application/pdf");
  ok("Download the BOL: \"PROJ-00362 BOL pickup ….pdf\" — the 2-page ticket, 2 BOL pages, the record page", bpdf && (await pdfOf(bpdf)).getPageCount() === 5 && /PROJ-00362 BOL pickup \d{4}-\d{2}-\d{2}\.pdf has downloaded/.test(txt(w)), txt(w).slice(0, 160));
  await until(async () => !!(await one("select downloaded_at from loadouts where id = $1", [bl.id])).downloaded_at);
  ok("...then it's marked downloaded by Julia R", (await one("select downloaded_by_name n from loadouts where id = $1", [bl.id])).n === "Julia R");
  w.__saved.length = 0;
  await click(w, cardOf(cu.id).querySelector("[data-download]"), 50);
  await until(() => /Signed ticket .* has downloaded/.test(txt(w)), 8000);
  ok("the customer pickup's signed ticket: no ticket, so the record page alone", (await pdfOf(w.__saved.find(b => b.type === "application/pdf"))).getPageCount() === 1);
  await wait(500); w.close();

  // ================= the office =================
  const o = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => o.document.querySelector("#phJob"), 6000);
  o.document.querySelector("#phJob").value = "362"; o.document.querySelector("[data-phfind]").click();
  await until(() => /What left the building/.test(txt(o)), 6000);
  ok("office Photos: \"BOL pickup · Picked up …\", Estes · BOL 44812, set up by Julia R, BOL photos: 2", /BOL pickup · Picked up/.test(txt(o)) && /Estes · BOL 44812/.test(txt(o)) && /Set up by Julia R/.test(txt(o)) && /BOL photos: 2/.test(txt(o)), txt(o).slice(txt(o).indexOf("What left"), txt(o).indexOf("What left") + 400));
  ok("...captions: \"BOL page 1\", \"Pallet 1, wrapped\"", /BOL page 1/.test(txt(o)) && /Pallet 1, wrapped/.test(txt(o)));
  await click(o, "[data-jobzip]", 50);
  await until(() => /\.zip has downloaded/.test(txt(o)), 10000);
  const zip = await JSZip.loadAsync(Buffer.from(await o.__saved.find(b => b.type === "application/zip").arrayBuffer()));
  const names = Object.keys(zip.files).sort(); if (process.env.SHOW) console.log(names.join("\n"));
  ok("the job zip: BOL/BOL-1.jpg and BOL-2.jpg, Pallets/, Before Wrap, the ticket in a Pickup <date> folder; no signed ticket for the BOL pickup",
     ["PROJ-00362/BOL/BOL-1.jpg", "PROJ-00362/BOL/BOL-2.jpg", "PROJ-00362/Pallets/Pallet-1.jpg", "PROJ-00362/TR-01/TR-01-1 Before Wrap.jpg"].every(n => names.includes(n))
     && names.some(n => /^PROJ-00362\/Pickup \d{4}-\d{2}-\d{2}\/Delivery ticket\.pdf$/.test(n))
     && names.filter(n => /Signed ticket\.pdf$/.test(n)).length === 1, names.join(" | "));   // only the phone-started customer pickup's (not signed) record
  await wait(500); o.close();
  const o2 = bootPage(OFFICE, "office.html", users.luke, { sfo_pin: JSON.stringify({ none: true }), sfo_tab: JSON.stringify("photos") });
  await until(() => o2.document.querySelector("#phJob"), 6000);
  o2.document.querySelector("#phJob").value = "418"; o2.document.querySelector("[data-phfind]").click();
  await until(() => /What left the building/.test(txt(o2)), 6000);
  ok("office: the customer pickup — Picked up …, signed by Pat Jones, with its Signed ticket button", /Customer pickup · Picked up/.test(txt(o2)) && /Picked up .* · signed by Pat Jones/.test(txt(o2)) && !!o2.document.querySelector("[data-signedpdf]"), txt(o2).slice(txt(o2).indexOf("What left"), txt(o2).indexOf("What left") + 300));
  await click(o2, "[data-jobzip]", 50);
  await until(() => /\.zip has downloaded/.test(txt(o2)), 10000);
  const z2 = await JSZip.loadAsync(Buffer.from(await o2.__saved.find(b => b.type === "application/zip").arrayBuffer()));
  const n2 = Object.keys(z2.files);
  const signedName = n2.find(n => /^PROJ-00418\/Pickup \d{4}-\d{2}-\d{2}\/Signed ticket\.pdf$/.test(n));
  ok("...its zip: TB-03-1 Pickup Picture.jpg, and Pickup <date>/Signature.png + Signed ticket.pdf (a pickup record)", n2.includes("PROJ-00418/TB-03/TB-03-1 Pickup Picture.jpg") && !!signedName
     && n2.some(n => /^PROJ-00418\/Pickup \d{4}-\d{2}-\d{2}\/Signature\.png$/.test(n))
     && (await PDFLib.PDFDocument.load(await z2.file(signedName).async("uint8array"))).getTitle() === "PROJ-00418 pickup ticket, signed", n2.join(" | "));
  await wait(500); o2.close();

  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_pickups_nosql.js
```javascript
// New pages on a database without delivery_types.sql: nothing about pickups shows; Delivery keeps Delivery/Shipping.
const src = require("fs").readFileSync(__dirname + "/test_deliveries.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")) + `(async () => {
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  await admin.query("select set_delivery_scheduler($1, true)", [julia.email]);
  let w = bootPage(DLV, "delivery.html", julia);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  ok("Julia's page, no SQL yet: no kind choice, the date and time as before", !$(w, "[data-kind]") && !!$(w, "#dd") && /Schedule this delivery/.test($(w, "[data-schedule]").textContent));
  await wait(500); w.close();
  w = bootApp(users.shawn);
  await until(() => $$(w, "[data-lostartkind]").length > 0);
  ok("Delivery's phone, no SQL yet: Delivery / Shipping, no Ready for pickup", $$(w, "[data-lostartkind]").map(b => b.dataset.lostartkind).join() === "delivery,shipping" && !/Ready for pickup/.test(txt(w)) && !/isn't set up/.test(txt(w)));
  await wait(500); w.close();
  console.log(\`\\n\${pass} PASS, \${fail} FAIL\`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });`);
```

#### test_deliveries_noship.js
```bash
python3 - <<'PY'
s=open('test_deliveries.js').read()
a=s.index('  // a shipment keeps its old screen'); b=s.index('  // ================= Julia: Completed =================')
open('test_deliveries_noship.js','w').write(s[:a]+s[b:])
PY
```

#### test_mike_same.js (replaces Part 8's)
```javascript
// Mike's tablet: every screen he uses is byte-for-byte the same on the new index.html as on the live one.
// Run on a database with deliveries.sql loaded (and again without it).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, users } = require("./pgsupa");
const strip = (h) => h.replace(/<script src="[^"]+"><\/script>/, "");
const NEW = strip(fs.readFileSync("../out/index.html", "utf8")), LIVE = strip(fs.readFileSync("../live/index.html", "utf8"));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
async function until(fn, ms = 5000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
function boot(html, user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const $ = (w, s) => w.document.querySelector(s);
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function screens(html, user) {
  const w = boot(html, user);
  await until(() => /PROJ-00418/.test(w.document.getElementById("app").textContent)); await wait(400);
  const out = [];
  const snap = async (name) => { await wait(350); out.push([name, $(w, "#app").innerHTML]); };
  await snap("queue");
  const job = $(w, "button.job"); if (job) { await click(w, job); await snap("job"); const sh = $(w, "button.sheet"); if (sh) { await click(w, sh); await snap("sheet"); } }
  const back = $(w, "[data-back]"); if (back) { await click(w, back); const b2 = $(w, "[data-back]"); if (b2) await click(w, b2); }
  for (const t of [...w.document.querySelectorAll("[data-tab]")].map(b => b.dataset.tab)) { await click(w, `[data-tab="${t}"]`); await snap("tab " + t); }
  await wait(500);
  w.close();
  return out;
}
(async () => {
  for (const [who, user] of [["Mike", users.mike], ["Donnie", users.donnie], ["Willie", users.willie], ["KP", users.kp], ["Jim", users.jim], ["Eric", users.eric]]) {
    let a, b;
    try { a = await screens(LIVE, user); b = await screens(NEW, user); }
    catch (e) { throw e; }
    if (!a) { console.log(`(skipped ${who}: his screens differ in shape from Mike's)`); continue; }
    const norm = (h) => h.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "ID");
    const diffs = a.filter(([n, h], i) => norm(h) !== norm(b[i][1])).map(([n]) => n);
    ok(`${who}: ${a.length} screens identical, byte for byte, to the live page`, diffs.length === 0 && a.length === b.length, diffs.join(", "));
  }
  console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks_pickups.py
```python
import subprocess
good = open('/home/claude/sf/out/delivery_types.sql').read()
B = {
 "anyone sets up a pickup": (2, 3, [("  if not can_schedule_deliveries() then\n    raise exception 'Only the delivery manager or a manager can set up pickups.'", "  if false then\n    raise exception 'Only the delivery manager or a manager can set up pickups.'")]),
 "pickup lanes mixed":      (3, 3, [("  if not v_job.is_test and am_test() then\n    raise exception 'A test login can only set up test jobs.'", "  if false then\n    raise exception 'A test login can only set up test jobs.'")]),
 "pickup given a date":     (4, 4, [("    if v.kind <> 'delivery' then\n      raise exception 'That''s a % — pickups have no date.", "    if false then\n      raise exception 'That''s a % — pickups have no date.")]),
 "phone changes the kind":  (4, 4, [("    if v.scheduled_for is not null or v.ready_at is not null then\n      raise exception 'This was set up", "    if false then\n      raise exception 'This was set up")]),
 "no BOL needed":           (5, 5, [("    if not exists (select 1 from photos where loadout_id = v.id and stage = 'bol' and voided_at is null) then", "    if false then")]),
 "no pallet needed":        (5, 5, [("    if not exists (select 1 from photos where loadout_id = v.id and pallet is not null and voided_at is null) then", "    if false then")]),
 "BOL on any kind":         (5, 5, [("  if v.kind <> 'shipping' or not v.pickup_steps then raise exception 'A BOL photo is for a BOL pickup.'; end if;", "")]),
 "nobody on site ok":       (6, 6, [("    if p_no_sign_reason not in ('Customer refused', 'Other') then", "    if p_no_sign_reason not in ('Nobody on site', 'Customer refused', 'Other') then")]),
 "signature not needed":    (6, 6, [("    if v_obj.name is null then raise exception 'The signature hasn''t arrived, so the pickup wasn''t marked done. Try again.'; end if;\n    insert into delivery_docs", "    if v_obj.name is null then return jsonb_build_object('ok', false); end if;\n    insert into delivery_docs")]),
 "anyone records":          (7, 7, [("  perform floor_entry_check('delivery', v.job_id);\n  if v.voided_at is not null then raise exception 'That pickup was marked entered by mistake.'; end if;", "  if v.voided_at is not null then raise exception 'That pickup was marked entered by mistake.'; end if;")]),
 "delivery picked up":      (7, 7, [("  if v.kind = 'delivery' then raise exception 'That''s a white glove delivery: it''s marked delivered, not picked up.'; end if;", "")]),
 "phone cancels Julia's":   (9, 9, [("  v_set_up := v.scheduled_for is not null or v.ready_at is not null;", "  v_set_up := v.scheduled_for is not null;")]),
 "BOL filed as Other":      (10, 10, [("              when p.stage = 'bol' then 'BOL'\n              when p.kind = 'loadout' then 'Other'", "              when p.kind = 'loadout' then 'Other'")]),
 "anon can set up":         (11, 11, [("revoke all on function schedule_pickup(uuid, text, text, uuid, uuid) from public, anon;", "grant execute on function schedule_pickup(uuid, text, text, uuid, uuid) to anon;")]),
}
P = "psql -h /tmp/pg -p 5433 -U postgres -q"
for name, (lo, hi, reps) in B.items():
    s = good
    for a, b in reps:
        assert s.count(a) >= 1, (name, a[:60]); s = s.replace(a, b, 1)
    open('/tmp/broken.sql', 'w').write(s)
    subprocess.run(f'{P} -d postgres -c "drop database if exists sync with (force)" -c "create database sync template sync_base"', shell=True, capture_output=True)
    subprocess.run(f'{P} -d sync -f /home/claude/sf/base/seed.sql', shell=True, capture_output=True)
    r = subprocess.run(f'{P} -d sync -v ON_ERROR_STOP=1 -At -F"|" -f /tmp/broken.sql', shell=True, capture_output=True, text=True)
    fails = [int(l.split('|')[0]) for l in r.stdout.splitlines() if '|FAIL|' in l]
    caught = any(lo <= f <= hi for f in fails)
    print(f"{name:26} -> failed steps {fails} {'CAUGHT' if caught else 'MISSED'}" + (f"  LOAD ERR {r.stderr[-150:]}" if r.returncode else ""))
```

#### snap_pk.js
```javascript
const src = require("fs").readFileSync(__dirname + "/test_deliveries.js", "utf8");
eval(src.slice(0, src.indexOf("(async () => {")) + require("fs").readFileSync(__dirname + "/snap_pk_body.js", "utf8"));
```

#### snap_pk_body.js
```javascript
const fontCss = ["barlow/400", "barlow/500", "barlow/600", "barlow/700", "barlow-condensed/600", "barlow-condensed/700"].map(p => {
  const [fam, wt] = p.split("/"); const file = `/home/claude/node_modules/@fontsource/${fam}/files/${fam}-latin-${wt}-normal.woff2`;
  return `@font-face{font-family:'${fam === "barlow" ? "Barlow" : "Barlow Condensed"}';font-weight:${wt};src:url(data:font/woff2;base64,${fs.readFileSync(file).toString("base64")})}`;
}).join("");
const shots = [];
const save = (w, name, vw, focus = null) => { const d = w.document.documentElement.cloneNode(true); d.querySelectorAll("script").forEach(s => s.remove());
  d.querySelectorAll("img").forEach(i => i.removeAttribute("src"));
  shots.push([name, "<!DOCTYPE html>" + d.outerHTML.replace("<style>", "<style>" + fontCss), vw, focus]); };
const tinyJpg = new Uint8Array(fs.readFileSync(__dirname + "/tiny.jpg"));
(async () => {
  await admin.query("insert into auth.users (id, email) values ($1, $2) on conflict do nothing", [julia.id, julia.email]);
  await admin.query("select set_person($1, 'Julia R', 'supervisor', '{delivery}')", [julia.email]);
  await admin.query("select set_delivery_scheduler($1, true)", [julia.email]);
  await admin.query(`do $$ declare w uuid; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    insert into sheets (work_order_id, sheet_number, qty, item_code, shape, width, length, total_height, png_path, pdf_uploaded_at) values
      (w, 1, 3, 'TR-01', 'Round', '36"', '36"', '42"', 'PROJ-00362/v1/sheet-1.png', now()),
      (w, 2, 1, 'TR-02', 'Rectangle', '30"', '60"', '30"', 'PROJ-00362/v1/sheet-2.png', now());
    insert into sheet_progress (sheet_id, department, qty_required, qty_done) select id, 'assembly_qc', qty, qty from sheets where work_order_id = w; end $$;`);
  let w = bootPage(DLV, "delivery.html", julia);
  await until(() => $$(w, "[data-kind]").length === 3 && $$(w, "[data-pickjob]").length > 0);
  await click(w, '[data-kind="shipping"]');
  type(w, "#jf", "362"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  type(w, "#dn", "Estes, sometime this week. 3 pallets.");
  save(w, "j1-bol-form", 1280); save(w, "j1-bol-form-phone", 390);
  await click(w, "[data-schedule]", 50); await until(() => /on Delivery's phone now/.test(txt(w)), 8000);
  await click(w, '[data-tab="new"]'); await click(w, '[data-kind="customer_pickup"]');
  type(w, "#jf", "418"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  type(w, "#dn", "Pat is coming Thursday with a van.");
  await click(w, "[data-schedule]", 50); await until(async () => (await one("select count(*)::int n from loadouts where ready_at is not null")).n === 2, 6000);
  await admin.query("select 1");
  await click(w, '[data-tab="new"]'); await click(w, '[data-kind="delivery"]');
  type(w, "#jf", "099"); await until(() => $$(w, "[data-pickjob]").length === 1); await click(w, "[data-pickjob]");
  type(w, "#dd", "2026-10-06"); type(w, "#dt", "09:30");
  await click(w, "[data-schedule]", 50); await until(() => /on Delivery's phone now/.test(txt(w)), 8000); await wait(300);
  save(w, "j2-coming-up", 1280);
  await wait(500); w.close();
  const bl = await one("select * from loadouts where kind = 'shipping'"), cu = await one("select * from loadouts where kind = 'customer_pickup'");
  w = bootApp(users.shawn, { caches: fakeCaches() });
  w.sfShrinkPhoto = async () => ({ blob: new Blob([tinyJpg], { type: "image/jpeg" }), width: 40, height: 60 });
  await until(() => /Ready for pickup/.test(txt(w))); await wait(300);
  save(w, "p1-list", 390);
  await click(w, `[data-loopen="${bl.client_id}"]`, 300); await until(() => /3 · The BOL/.test(txt(w)), 6000); await wait(300);
  save(w, "p2-bol-top", 390);
  await click(w, '[data-loshoot="1"][data-piece="1"]'); await snap(w);
  await click(w, "[data-lopallet]"); await snap(w);
  await click(w, '[data-pkbol="1"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos")).n === 3, 6000); await wait(300);
  type(w, "#loCarrier", "Estes"); type(w, "#loTracking", "44812");
  save(w, "p3-bol-steps", 390, ".lostep:nth-of-type(2)");
  save(w, "p4-bol-finish", 390, "[data-pkdone]");
  await click(w, "[data-pkdone]"); save(w, "p5-bol-confirm", 390);
  await click(w, "[data-confirm]", 300);
  await until(async () => !!(await one("select completed_at from loadouts where id = $1", [bl.id])), 8000); await wait(500);
  save(w, "p6-bol-done", 390, ".dldone");
  await click(w, "[data-loback]", 300); await wait(300);
  await click(w, `[data-loopen="${cu.client_id}"]`, 300); await until(() => /2 · The customer/.test(txt(w)), 6000); await wait(300);
  save(w, "p7-customer", 390, ".lostep:nth-of-type(2)");
  await wait(500); w.close();
  const b = await (require("playwright").chromium).launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  for (const [n, h, vw, focus] of shots) {
    const p = await b.newPage({ viewport: { width: vw, height: vw < 500 ? 844 : 900 } });
    await p.setContent(h, { waitUntil: "load" }); await p.waitForTimeout(200);
    if (focus) await p.evaluate((f) => { const el = document.querySelector(f); if (el) el.scrollIntoView({ block: "center" }); }, focus);
    const sw = await p.evaluate(() => document.documentElement.scrollWidth);
    await p.screenshot({ path: `/tmp/pk_${n}.png` }); console.log(n, "width", sw, "of", vw); await p.close();
  }
  await b.close(); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```
