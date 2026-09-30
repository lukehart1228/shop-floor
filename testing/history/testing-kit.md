# Testing kit — Shop Floor Production System

*Updated 23 Sep 2026: Part 1 is the original kit (steps 1–3 and earlier); Part 2 adds steps 4–9. Both apply.*

*For build chats. Luke doesn't need to read this.*

Every file in this project was tested before delivery against local stand-ins for Supabase, Monday and a browser, running in Claude's sandbox. That setup disappears when a chat ends, so this file holds everything needed to rebuild it and re-run the tests after any change. **Re-run the relevant tests before handing Luke any changed file.**

What the stand-ins can't replace: the real Supabase dashboard, the real Monday API, and the real Android tablet. Say so plainly when delivering, and make each walkthrough's first real run fail safely with a plain message.

---

## 1. Build the environment

```bash
# Postgres 16 and the scheduler extension
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-16-cron \
  libcurl4-openssl-dev postgresql-server-dev-16

# the http extension Supabase uses isn't packaged for Ubuntu — build it from source
cd /tmp && git clone -q --depth 1 https://github.com/pramsey/pgsql-http.git && \
  cd pgsql-http && make -s && make -s install

# a throwaway cluster on port 5433, with pg_cron loaded into the database named 'sync'
mkdir -p /tmp/pg && chown postgres:postgres /tmp/pg
su postgres -c "/usr/lib/postgresql/16/bin/initdb -D /tmp/pg/data -A trust"
cat >> /tmp/pg/data/postgresql.conf <<'EOF'
shared_preload_libraries = 'pg_cron'
cron.database_name = 'sync'
EOF
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg/data -o '-k /tmp/pg -p 5433' -l /tmp/pg/log start"

# browser tests
cd /home/claude && npm install jsdom@24 --silent
pip install pymupdf --break-system-packages -q    # for testing wo_upload.py
```

## 2. Load a database the way Luke's is

Use the database name `sync` if you need pg_cron (it only loads there). Load in this order, with `-v ON_ERROR_STOP=1`:

1. `supabase_stub.sql` — roles `anon` and `authenticated`, the `auth` schema, and `auth.uid()` exactly as Supabase defines it
2. `supabase_stub2.sql` — the `service_role` and `authenticator` roles, and the `storage` schema
3. `vault_stub.sql` — the `extensions` and `vault` schemas
4. Then `create extension http with schema extensions; create extension pg_cron;`
5. The project's own files in build order: `schema.sql` → `people.sql` (test logins for Mike and Luke) → `verify_setup.sql` → `upload_function.sql` → `monday_sync.sql` → `tablet.sql` → then the steps 1–9 files as listed in Part 2. All of them are in `sql-files.md`; the pages are in `site-files.md`.

Every project SQL file must load **twice** without error. Always test that.

## 3. Test as a real login, not as postgres

This matters more than anything else here. Supabase's API connects as `authenticator` and then switches role. A plain `postgres` session sails through the "is this the SQL Editor?" check in `can_upload_work_orders()`, so it makes permission tests meaningless.

```bash
cat > /tmp/as_mike.sql <<'EOF'
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', false) \g /dev/null
-- ...the statement under test...
EOF
su postgres -c "psql -h /tmp/pg -p 5433 -U authenticator -d sync -f /tmp/as_mike.sql"
```

Mike is `1111…`, Luke is `2222…` (from `people.sql`). For the secret key, use `set role service_role` with claims `{"role":"service_role"}`. For someone with no login, use `set role anon`.

**Prove the checks can fail.** `verify_setup()` was tested by breaking the schema seven ways, confirming each break was caught at the right step. Do the same for any new PASS/FAIL check.

## 4. The stand-in Monday

`mock_monday.py` serves pages shaped exactly like the real Orders board. It uses the real rows for PROJ-00099, 00325, 00362 and 00418, padded to the board's 293 jobs, plus planted awkward cases: a missing PROJ number, a duplicate PROJ number, and a PROJ number only in the name. Token: `test-token-123`. Modes, set by the URL path: `/normal`, `/run2` (00099 moves to Delivery; 00325 is deleted), `/empty`, `/error`, `/garbage`, `/401`.

```bash
cd /tmp/mock && (setsid nohup python3 server.py > server.out 2>&1 < /dev/null &) ; sleep 2
su postgres -c "psql -h /tmp/pg -p 5433 -d sync -c \"select vault.create_secret('test-token-123','monday_token')\""
su postgres -c "psql -h /tmp/pg -p 5433 -d sync -c \"select run_monday_sync('http://127.0.0.1:8765/normal')->>'summary'\""
```

To confirm the scheduler really runs it, schedule a one-minute test job (`* * * * *`), wait about 75 seconds, check `cron.job_run_details` and the log, then `cron.unschedule` it. **Unschedule the real 15-minute job afterwards**, or it keeps calling the real api.monday.com, which the sandbox blocks.

## 5. Browser tests (jsdom)

The page files keep their logic in a `/* ---- core ---- */` section with no screen code, ending in a `module.exports` line. `test_*_core.js` pulls the last `<script>` block out and `require`s it. `test_*_page.js` loads the real page into jsdom, with a fake Supabase client.

jsdom's gaps, and how the tests handle them: no `Request` or Cache API (so code must build a `Request` only after checking `"caches" in window`); no `File.text()` (stub it); no `print`, `open`, `URL.createObjectURL` or `scrollTo` (stub them). **`textContent` runs adjacent elements together** — "0" and "of 3" read as "0of 3" — so check elements individually rather than regex-matching screen text.

`/tmp/rows_sanding.json` holds real view rows for Mike, generated by querying `v_floor_sheets` as Mike, with `json_agg` into that file. The page test gives those rows page files, since the local database never uploaded any.

## 6. Gotchas that cost time

- **`pgrep -f` and `pkill -f` match their own command line** — they "find" the server you're checking for, or kill the shell running them. Use a bracket pattern: `pgrep -f "[s]erver.py"`.
- **The sandbox can reset between turns.** Running processes die; files in `/tmp` and `/home/claude` survive. Restart Postgres and the mock server.
- **Never put JSON inline in psql `-c` strings.** Shell quoting strips it. Write the SQL to a file and use `-f`.
- **A test that fails for the wrong reason proves nothing.** When a test fails, look at the actual output before deciding whether the code or the test is wrong. Both happened in this project.
- `test_418.py` needs the real `PROJ-00418_Work_Order_PROD.pdf` — ask Luke to upload it to the chat.

---

## Files (Part 1)

The tablet tests `test_app_core.js` and `test_app_page.js` are in Part 2, updated for steps 4–9.

### supabase_stub.sql

```sql
-- enough of Supabase to test RLS honestly
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid $$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
-- Supabase's default: API roles get full table privileges; RLS is the gate
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
```

### supabase_stub2.sql

```sql
-- the rest of Supabase that step 2 touches
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
-- API requests really arrive as 'authenticator' and then switch role.
-- Testing through it matters: a plain postgres session would pass the
-- "is this the SQL Editor?" check and make every test meaningless.
do $$ begin create role authenticator login noinherit; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to authenticator;
grant usage on schema public, auth to service_role;
alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
```

### vault_stub.sql

```sql
-- enough of Supabase's Vault and extensions schema to test honestly
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, description from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text, new_description text default '') returns uuid
  language sql as $$ insert into vault.secrets (name, secret, description) values (new_name, new_secret, new_description) returning id $$;
revoke all on schema vault from anon, authenticated;
```

### people.sql — the two test logins

```sql
insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, full_name, role, departments) values
  ('11111111-1111-1111-1111-111111111111','Mike B','supervisor','{sanding}'),
  ('22222222-2222-2222-2222-222222222222','Luke H','manager','{}');
```

### mock_monday.py — the stand-in Monday (save as /tmp/mock/server.py)

```python
"""A stand-in for monday.com's API, serving pages shaped exactly like the real Orders board."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "test-token-123"
def item(i, name, pid, date, phase, materials="Not ready to be started"):
    return {"id": str(i), "name": name,
            "column_values": [{"id": "text_mm0wnntf", "text": pid}, {"id": "date_mkwjd2an", "text": date},
                              {"id": "color_mkwqppkb", "text": phase}],
            "subitems": [{"name": "Bring team together for kickoff", "column_values": [{"text": "Done"}]},
                         {"name": "Order materials (wood, hardware)", "column_values": [{"text": materials}]}]}

# four real rows, as read from the board
REAL = [item(11462549625, "PROJ-00099   Oaks Academy Q01092", "PROJ-00099", "2026-10-21 04:30", "In Production", "Ready to be started"),
        item(12362919739, "PROJ-00325   Patch Development", "PROJ-00325", "2026-12-01", "In Production"),
        item(12543970562, "PROJ-00362   Trinitas - Noblesville", "PROJ-00362", "2026-11-02", "In Production", "Done"),
        item(13060952631, "PROJ-00418   Enid's Table Restaurant and Bookstore", "PROJ-00418", "2026-11-17 04:30", "In Production")]
BOARD = list(REAL)
n = 500
for phase, count in [("In Production", 38), ("Delivery", 16), ("Project Closeout", 5), ("100% Complete", 230)]:
    for _ in range(count):
        n += 1
        BOARD.append(item(20000000000 + n, f"PROJ-{n:05d}   Job {n}", f"PROJ-{n:05d}", "2027-01-15", phase))
# the awkward ones
BOARD.append(item(30000000001, "PROJ-00999   Blank ID column", "", "2026-12-10", "100% Complete"))   # number only in the name
BOARD.append(item(30000000002, "Sample table — no project number", "", "", "100% Complete"))       # no PROJ at all
BOARD.append(item(30000000003, "PROJ-00325   Accidental duplicate row", "PROJ-00325", "", "100% Complete"))

def run2():
    b = [dict(x) for x in BOARD if x["id"] != "12362919739"]                   # 00325 deleted from the board
    b[0] = item(11462549625, "PROJ-00099   Oaks Academy Q01092", "PROJ-00099", "2026-10-21", "Delivery", "Done")  # 00099 moved on
    return b

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        q = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["query"]
        with open("/tmp/mock/requests.log", "a") as f: f.write(self.path + " " + q[:60] + "\n")
        if self.headers.get("Authorization") != TOKEN: return self.send(401, {"error_message": "Not Authenticated"})
        mode = self.path.strip("/")
        if mode == "401":     return self.send(401, {"error_message": "Not Authenticated"})
        if mode == "error":   return self.send(200, {"errors": [{"message": "Complexity budget exhausted"}]})
        if mode == "garbage": return self.send(200, "<html>Bad gateway</html>", "text/html")
        if mode == "empty":   return self.send(200, {"data": {"boards": [{"items_page": {"cursor": None, "items": []}}]}})
        board = run2() if mode == "run2" else BOARD
        pages = [board[i:i+100] for i in range(0, len(board), 100)]
        if "next_items_page" in q:
            idx = int(q.split('cursor: "c')[1].split('"')[0])
            cur = f"c{idx+1}" if idx + 1 < len(pages) else None
            return self.send(200, {"data": {"next_items_page": {"cursor": cur, "items": pages[idx]}}})
        cur = "c1" if len(pages) > 1 else None
        return self.send(200, {"data": {"boards": [{"items_page": {"cursor": cur, "items": pages[0]}}]}})

HTTPServer(("127.0.0.1", 8765), H).serve_forever()
```

### test_418.py — packages the real PROJ-00418 PDF and inspects every file

```python
import json, base64, io, sys
sys.path.insert(0, "/home/claude")
import wo_upload, fitz
from PIL import Image

steel = [("BASE", [("Base Material:", "Steel")]), ("BASE FINISHING", [("Color:", "Denim Black"), ("Finish Type:", "Paint")])]
def d(n, code, qty, species, shape, w, l, h='29.75"', cnc="Rectangle_Template", notes="", cnc_notes=(), base=steel):
    return {"project": "PROJ-00418", "project_name": "Enid's Table, Tables and bookcases",
            "item_id": code, "qty": qty, "order_qty": 20, "sheet": f"{n} of 9", "species": species,
            "fin_w": w, "fin_l": l, "fin_t": '1.25"', "shape": shape, "height": h,
            "cnc_template": cnc, "cnc_notes": list(cnc_notes),
            "col_a": [("TOP", [("Species:", species)]), ("TOP FINISHING", [("Stain Color:", "No Stain (Natural)")])],
            "col_b": base,
            "glueup_rows": [{"qty": str(qty), "start_length": '38"', "start_width": '40" - 41"',
                             "optimal_stock": "1st. 10' 2nd. 14'", "notes": notes}]}
powder = [("BASE", [("Base Material:", "Steel")]), ("BASE FINISHING", [("Finish Type:", "Powdercoat")])]
sheets = [
 d(1,"TB-03",1,"Ash","Round",'36"','36"',cnc="Round_Template",notes="NO BISCUITS!"),
 d(2,"TB-03",2,"Maple","Square",'36"','36"'),
 d(3,"TB-03",2,"Ash","Round",'36"','36"',cnc="Round_Template",notes="NO BISCUITS!"),
 d(4,"TB-04",3,"Ash","Rectangle",'24"','36"'),
 d(5,"TB-04",3,"Maple","Rectangle",'24"','36"'),
 d(6,"TB-06",3,"Ash","Square",'36"','36"',base=powder),
 d(7,"WMT-DAN-DIN",4,"Cherry","Rectangle",'36"','72"'),
 d(8,"WMT-DAN-DIN",1,"Cherry","Ellipse",'42"','72"',cnc="Needs custom program written",notes="NO BISCUITS!"),
 d(9,"TB-01",1,"Ash","Rectangle",'36"','96"',h='42"',cnc_notes=["CS set to 0: the drawing shows a live edge. Confirm before running."],
   base=[("BASE",[("Base Material:","metal")]),("BASE FINISHING",[("Finish Type:","powdercoat")])]),
]
import shutil; shutil.copy("/mnt/user-data/uploads/PROJ-00418_Work_Order_PROD.pdf", "/home/claude/PROJ-00418_Work_Order_PROD.pdf")
out = wo_upload.make_upload_file(sheets, "/home/claude/PROJ-00418_Work_Order_PROD.pdf")

pkg = json.load(open(out))
p = pkg["payload"]
print("kind/format:", pkg["kind"], pkg["format"])
print("project:", p["project_id"], "| sheets:", len(p["sheets"]), "| pieces:", sum(s["qty"] for s in p["sheets"]), "| total_items:", p["total_items"])
print("sheet 8 floor notes:", p["sheets"][7]["floor_notes"])
print("sheet 9 floor notes:", p["sheets"][8]["floor_notes"])
print("depts sheet 6:", p["sheets"][5]["departments"])
png_sizes, pdf_sizes = [], []
for f in pkg["files"]:
    png = base64.b64decode(f["png"]); pdf = base64.b64decode(f["pdf"])
    im = Image.open(io.BytesIO(png)); assert im.format == "PNG"
    one = fitz.open(stream=pdf, filetype="pdf"); assert one.page_count == 1
    png_sizes.append(len(png)//1024); pdf_sizes.append(len(pdf)//1024)
print("PNG per sheet (KB):", png_sizes, "size", im.size)
print("PDF per sheet (KB):", pdf_sizes)
Image.open(io.BytesIO(base64.b64decode(pkg["files"][8]["png"]))).save("/home/claude/check_sheet9.png")

# the mismatch guard
try:
    wo_upload.make_upload_file(sheets[:8], "/home/claude/PROJ-00418_Work_Order_PROD.pdf", "/tmp/x.json")
except ValueError as e:
    print("mismatch guard:", str(e)[:70], "...")
```

### test_upload.js — upload page logic

```javascript
const fs = require("fs");
const html = fs.readFileSync("upload.html", "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
fs.writeFileSync("/tmp/core.js", scripts[scripts.length - 1]);
const C = require("/tmp/core.js");
let pass = 0, fail = 0;
const ok = (name, cond, extra = "") => { cond ? pass++ : fail++; console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`); };

// ---- keys ----
const jwt = (role) => "xx." + Buffer.from(JSON.stringify({ role })).toString("base64").replace(/=+$/,"") + ".yy";
ok("placeholder settings are caught", C.keyProblem("PASTE-YOUR-PROJECT-URL-HERE", "PASTE-YOUR-PUBLISHABLE-KEY-HERE")?.secret === false);
ok("new-style secret key refused",     C.keyProblem("https://x.supabase.co", "sb_secret_abc123")?.secret === true);
ok("old-style secret key refused",     C.keyProblem("https://x.supabase.co", jwt("service_role"))?.secret === true);
ok("old-style anon key accepted",      C.keyProblem("https://x.supabase.co", jwt("anon")) === null);
ok("new-style publishable accepted",   C.keyProblem("https://x.supabase.co", "sb_publishable_abc123") === null);
ok("http:// address caught",           C.keyProblem("http://x.supabase.co", "sb_publishable_abc") !== null);

// ---- files ----
const real = fs.readFileSync("PROJ-00418_upload.json", "utf8");
const pkg = C.readPackage(real);
ok("real PROJ-00418 upload file accepted", pkg.payload.sheets.length === 9);
const tryRead = (t) => { try { C.readPackage(t); return null; } catch (e) { return e.message; } };
ok("PDF dropped by mistake is explained",  /not the PDF/.test(tryRead("%PDF-1.4 binary")));
ok("some other JSON file is refused",      /isn't an upload file/.test(tryRead('{"hello":1}')));
const short = JSON.parse(real); short.files.pop();
ok("page/sheet count mismatch caught",     /different number/.test(tryRead(JSON.stringify(short))));
const nopng = JSON.parse(real); delete nopng.files[3].png;
ok("missing page image caught",            /Sheet 4 is missing/.test(tryRead(JSON.stringify(nopng))));

const blob = C.b64ToBlob(pkg.files[0].png, "image/png");
ok("page image decodes to the right size", blob.size === Buffer.from(pkg.files[0].png, "base64").length, `${blob.size} bytes`);

// ---- a fake Supabase ----
function fakeDb({ rpcError = null, failUploadAt = null } = {}) {
  const log = { uploads: [], marked: null, rpcCalls: [] };
  let n = 0;
  return {
    log,
    async rpc(name, args) {
      log.rpcCalls.push(name);
      if (name === "upload_work_order") {
        if (rpcError) return { data: null, error: { message: rpcError } };
        return { data: { ok: true, project_id: "PROJ-00418", version: 1, work_order_id: "wo-1",
                         file_folder: "PROJ-00418/v1", sheets: 9, pieces: 20,
                         carried_forward: [], reset_by_change: [], clamped_to_new_qty: [], removed: [], warnings: [] }, error: null };
      }
      if (name === "mark_sheet_files") { log.marked = args; return { data: args.files.length, error: null }; }
    },
    storage: { from: (bucket) => ({ async upload(path, body, opts) {
      n++;
      if (failUploadAt && n === failUploadAt) return { data: null, error: { message: "Failed to fetch" } };
      log.uploads.push({ bucket, path, type: opts.contentType, upsert: opts.upsert }); return { data: {}, error: null };
    } }) },
  };
}
const steps = [];
const report = (s, st, d) => steps.push(`${s}:${st}`);

(async () => {
  // happy path
  let db = fakeDb();
  const r = await C.runUpload(pkg, db, report);
  ok("saves, then uploads 18 files (a PNG and PDF per sheet)", db.log.uploads.length === 18);
  ok("files go to the work-orders bucket, in the version folder",
     db.log.uploads.every(u => u.bucket === "work-orders" && u.path.startsWith("PROJ-00418/v1/sheet-")), db.log.uploads[0].path);
  ok("records the arrived pages against the right work order",
     db.log.marked.p_work_order === "wo-1" && db.log.marked.files.length === 9 && db.log.marked.files[8].png_path === "PROJ-00418/v1/sheet-9.png");
  ok("order: save first, record last", db.log.rpcCalls.join(",") === "upload_work_order,mark_sheet_files");
  ok("progress ends with all three steps done", ["save:done","pages:done","record:done"].every(s => steps.includes(s)));

  // supervisor tries it: the database refuses
  db = fakeDb({ rpcError: "Only a manager login or the secret key can upload work orders." });
  try { await C.runUpload(pkg, db, () => {}); ok("supervisor refusal surfaces", false); }
  catch (e) {
    ok("supervisor refusal surfaces as the database's plain message", /Only a manager/.test(C.friendlyError(e)));
    ok("...and it's reported as nothing saved", !e.saved);
    ok("...and no files were uploaded", db.log.uploads.length === 0);
  }

  // connection drops on the 5th file (sheet 3's PNG)
  db = fakeDb({ failUploadAt: 5 });
  try { await C.runUpload(pkg, db, () => {}); ok("mid-upload failure surfaces", false); }
  catch (e) {
    ok("connection drop mid-upload is explained", /Couldn't reach the database/.test(C.friendlyError(e)));
    ok("...and flagged as 'work order saved, pages incomplete'", e.saved === true);
    ok("...and pages are NOT recorded as arrived", db.log.marked === null);
  }

  // explaining a revision
  const lines = C.explainResult({ project_id: "PROJ-00418", version: 4, sheets: 4, pieces: 11,
    carried_forward: [1, 2], reset_by_change: [3], clamped_to_new_qty: [2], removed: [], warnings: [] });
  console.log("      " + lines.join("\n      "));
  ok("revision is explained in four plain sentences", lines.length === 4 && /sheets 1 and 2/.test(lines[1]));

  ok("wrong password explained", /didn't match/.test(C.friendlyError({ message: "Invalid login credentials" })));
  ok("storage refusal explained", /Only a manager/.test(C.friendlyError({ message: "new row violates row-level security policy" })));

  console.log(`\n${pass} passed, ${fail} failed`);
})();
```

### test_page.js — upload page screens

```javascript
const fs = require("fs");
const { JSDOM } = require("jsdom");
const base = fs.readFileSync("upload.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const real = fs.readFileSync("PROJ-00418_upload.json", "utf8");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

function page(html, fakeSupabase) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/upload.html" });
  const w = dom.window;
  w.supabase = fakeSupabase;
  w.Blob = Blob;
  const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
  w.eval(script);
  return w;
}
function fakeClient({ session = null, role = "manager", uploadErr = null } = {}) {
  const uploads = [];
  const client = {
    uploads,
    auth: {
      getSession: async () => ({ data: { session } }),
      signInWithPassword: async ({ email, password }) => password === "right"
        ? { data: { user: { id: "u1", email } }, error: null }
        : { data: null, error: { message: "Invalid login credentials" } },
      signOut: async () => ({}),
    },
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: role ? { full_name: "Luke H", role } : null }) }) }) }),
    rpc: async (name, args) => name === "upload_work_order"
      ? (uploadErr ? { error: { message: uploadErr } } : { data: { ok: true, project_id: "PROJ-00418", version: 1, work_order_id: "wo", file_folder: "PROJ-00418/v1", sheets: 9, pieces: 20, carried_forward: [], reset_by_change: [], clamped_to_new_qty: [], removed: [], warnings: [] } })
      : { data: 9 },
    storage: { from: () => ({ upload: async (p) => { uploads.push(p); return { error: null }; } }) },
  };
  return { createClient: () => client, client };
}
const withKeys = base.replace("PASTE-YOUR-PROJECT-URL-HERE", "https://abc.supabase.co").replace("PASTE-YOUR-PUBLISHABLE-KEY-HERE", "sb_publishable_test");
const withSecret = base.replace("PASTE-YOUR-PROJECT-URL-HERE", "https://abc.supabase.co").replace("PASTE-YOUR-PUBLISHABLE-KEY-HERE", "sb_secret_oops");

(async () => {
  // 1. not configured
  let w = page(base, fakeClient());
  ok("unfilled settings: shows the set-up message, not the sign-in", !w.document.getElementById("configProblem").hidden && w.document.getElementById("signIn").hidden);

  // 2. secret key pasted
  w = page(withSecret, fakeClient());
  ok("secret key pasted: page refuses and says stop", /Stop/.test(w.document.getElementById("configTitle").textContent) && w.document.getElementById("signIn").hidden);

  // 3. configured, signed out -> sign-in; wrong then right password
  const f = fakeClient();
  w = page(withKeys, f); await wait(20);
  const d = w.document;
  ok("configured and signed out: shows sign-in", !d.getElementById("signIn").hidden);
  d.getElementById("email").value = "lukehart@pdindy.com";
  d.getElementById("password").value = "wrong";
  d.getElementById("signInForm").dispatchEvent(new w.Event("submit", { cancelable: true })); await wait(20);
  ok("wrong password: plain message, stays on sign-in", /didn't match/.test(d.getElementById("signInError").textContent) && !d.getElementById("signIn").hidden);
  d.getElementById("password").value = "right";
  d.getElementById("signInForm").dispatchEvent(new w.Event("submit", { cancelable: true })); await wait(20);
  ok("right password: shows the upload area with name and role", !d.getElementById("uploadArea").hidden && d.getElementById("whoName").textContent === "Luke H (manager)");
  ok("manager: no role warning", d.getElementById("roleWarning").hidden);

  // 4. drop the real file -> preview -> upload -> result
  const file = new w.File([real], "PROJ-00418_upload.json", { type: "application/json" });
  file.text = async () => real;   // jsdom's File lacks .text()
  Object.defineProperty(d.getElementById("fileInput"), "files", { value: [file] });
  d.getElementById("fileInput").dispatchEvent(new w.Event("change")); await wait(30);
  ok("file chosen: preview shows project, sheets, pieces",
     d.getElementById("pvProject").textContent === "00418" && d.getElementById("pvSheets").textContent === "9" && d.getElementById("pvPieces").textContent === "20");
  d.getElementById("uploadBtn").click(); await wait(150);
  const outcome = d.getElementById("outcome").textContent;
  ok("upload: success message in plain English", /Saved PROJ-00418 — version 1, 9 sheets, 20 pieces/.test(outcome), outcome.slice(0, 60));
  ok("upload: 18 files sent", f.client.uploads.length === 18);
  ok("upload: all three progress steps ticked", d.querySelectorAll("li.done").length === 3);

  // 5. supervisor signed in
  const sup = fakeClient({ session: { user: { id: "u2", email: "sanding@pdindy.com" } }, role: "supervisor" });
  w = page(withKeys, sup); await wait(30);
  ok("supervisor login: warned up front that only managers can upload", !w.document.getElementById("roleWarning").hidden);

  // 6. a supervisor upload is refused -> 'nothing saved'
  const sup2 = fakeClient({ session: { user: { id: "u2", email: "s@x" } }, role: "supervisor", uploadErr: "Only a manager login or the secret key can upload work orders." });
  w = page(withKeys, sup2); await wait(30);
  const f2 = new w.File([real], "x.json"); f2.text = async () => real;
  Object.defineProperty(w.document.getElementById("fileInput"), "files", { value: [f2] });
  w.document.getElementById("fileInput").dispatchEvent(new w.Event("change")); await wait(30);
  w.document.getElementById("uploadBtn").click(); await wait(60);
  const o2 = w.document.getElementById("outcome").textContent;
  ok("refused upload: shows the reason and 'Nothing was saved'", /Only a manager/.test(o2) && /Nothing was saved/.test(o2));

  console.log(`\n${pass} passed, ${fail} failed`);
})();
```

---

# Part 2 — steps 4–9

*For build chats. Luke doesn't need to read this.*

Everything in Part 1 still applies (environment, stubs, "test as a real login"). This file adds what steps 4–9 were tested with. Re-run the relevant suites before handing over any changed file.

### What changed in the setup

- **Load order** after the kit's list: `office.sql` → `test_lane.sql` → `catch_up.sql` → `problems.sql` → `flags.sql` → `routine_tasks.sql` → `supplies.sql` → `arrow_qc.sql` → `tv.sql` → `check_floor.sql`. Each file must load **twice**. Drop the test database with `drop database sync with (force)` — pg_cron keeps a connection open.
- `auth.users` needs an `email` column in the stub (`create table auth.users (id uuid primary key, email text)`), because `set_person()` looks logins up by email.
- **`is_manager_or_editor()` passes for any SQL Editor session, even after `set local role authenticated`** — `session_user` stays `postgres`. So manager-only functions from step 4 on use `office_ok()`, which only lets the SQL Editor through when no JWT claims are set. A check that impersonates a supervisor then meets the real walls. Keep it that way.
- `check_floor()` does all its work inside a block that ends by raising `__check_floor_undo__`, so everything it made is rolled back — including the TV link. Results are collected in a jsonb array and returned after.
- **`pgsupa.js` replaces the hand-written fake Supabase clients** for new tests: a supabase-js stand-in that runs every `.from()` / `.rpc()` through the real test database as `authenticator` → role → JWT claims, exactly like PostgREST. The real pages run in jsdom against it, so RLS, grants and every database check apply. Its `setOffline(true)` simulates the Wi-Fi dropping.
- The original `test_app_core.js` / `test_app_page.js` still run against the new `index.html` (49 PASS). Two expectations changed on purpose: a manager opens **8** departments (Delivery). The page test now derives the unfilled-settings copy by swapping the real URL/key back to placeholders, since the delivered files have them filled in. `/tmp/rows_sanding.json` is made by `mkrows.js` from the seeded database.
- Screenshots: `snap.js` drives the pages in jsdom and saves each screen's HTML; `shoot.js` photographs them with Playwright's Chromium (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`). Check `.rowbtns button` specificity — it once turned an orange `.go` button white-on-white.
- **Don't edit big files with sed or a Python rewrite** in these chats — the harness echoes the whole changed file back. Use the Edit tool.

### Results when delivered (23 Sep)

| Suite | Result |
|---|---|
| `check_floor()` on the stand-in (and proven to catch 8 deliberate breaks, each at its own step) | 18 PASS |
| `db_test.js` — every function through the real login path | 106 PASS |
| `test_app_core.js` + `test_app_page.js` (the original 49) | 49 PASS |
| `test_app_e2e.js` — tablet against the database | 67 PASS |
| `test_office_e2e.js` — office against the database | 37 PASS |
| `test_tv.js` — TV core and page, no login | 21 PASS |

Run order on a fresh database each time: `fresh.sh && node <suite>.js` (the e2e suites write data).

---

### Files (Part 2)

`load.sh` below loads trimmed copies of the step 1–3 files (`office_min.sql`, `catch_up_min.sql`, `upload_and_sync_min.sql`: the same statements minus the functions that call Monday over the network, which steps 4–9 don't touch). In a new chat, load the real files from the project instead — with the `http` extension built as `testing-kit.md` describes — or trim them the same way.

#### load.sh

```bash
#!/bin/bash
# rebuild the 'sync' test database the way Luke's is, then load any extra files given as arguments (each twice)
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync" >/dev/null
cd /home/claude/sf/base
for f in supabase_stub.sql supabase_stub2.sql vault_stub.sql; do $P -d sync -f $f; done
$P -d sync -c "create extension pg_cron;" >/dev/null
for f in schema.sql upload_and_sync_min.sql office_min.sql test_lane.sql catch_up_min.sql; do $P -d sync -f $f; $P -d sync -f $f; done
$P -d sync -f people.sql
$P -d sync -c "select set_person('test@pdindy.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc}',true)" >/dev/null
for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f"; $P -d sync -f "$f"; done
echo LOADED
```

#### fresh.sh

```bash
#!/bin/bash
# a fresh database like Luke's after steps 1–9, with realistic jobs
cd /home/claude/sf/base
./load.sh ../out/problems.sql ../out/flags.sql ../out/routine_tasks.sql ../out/supplies.sql ../out/arrow_qc.sql ../out/tv.sql >/tmp/load.out 2>&1 || { echo LOAD FAILED; grep -i error /tmp/load.out; exit 1; }
psql -h /tmp/pg -p 5433 -U postgres -d sync -q -v ON_ERROR_STOP=1 -f ../out/check_floor.sql >/dev/null 2>&1 || { echo CHECK FILE FAILED; exit 1; }
psql -h /tmp/pg -p 5433 -U postgres -d sync -q -v ON_ERROR_STOP=1 -f seed.sql >/dev/null 2>&1 || { echo SEED FAILED; exit 1; }
echo SEEDED
```

#### seed.sql

```sql
-- realistic data: PROJ-00418 (9 sheets), PROJ-00099 (3 sheets), a Delivery-phase job, a Pre-Production job
insert into jobs (monday_item_id, project_id, name, delivery_date, phase, is_active, materials_ordered, handed_off, monday_stages)
values (13060952631,'PROJ-00418','Enid''s Table Restaurant and Bookstore', local_today()+55,'In Production',true,false,true,'{"wood":"Sanding"}'),
       (11462549625,'PROJ-00099','Oaks Academy Q01092', local_today()+28,'In Production',true,true,false,'{"wood":"CNC"}'),
       (12543970562,'PROJ-00362','Trinitas - Noblesville', local_today()+3,'Delivery',false,true,true,'{}'),
       (12362919739,'PROJ-00325','Patch Development', local_today()+70,'Pre-Production',false,false,false,'{}');
do $$
declare w uuid; s uuid; q int[] := array[1,2,2,3,3,3,4,1,1]; codes text[] := array['TB-03','TB-03','TB-03','TB-04','TB-04','TB-06','WMT-DAN-DIN','WMT-DAN-DIN','TB-01']; i int;
begin
  insert into work_orders (job_id) select id from jobs where project_id='PROJ-00418' returning id into w;
  for i in 1..9 loop
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
      values (w, i, q[i], codes[i], 'Ash', format('PROJ-00418/v1/sheet-%s.png',i), format('PROJ-00418/v1/sheet-%s.pdf',i), now()) returning id into s;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      select s, d, q[i], case when d in ('milling','cnc') then q[i] when d='sanding' and i<=3 then q[i] else 0 end
      from unnest(array['milling','cnc','sanding','finishing','metal','assembly_qc']) d;
  end loop;
  insert into work_orders (job_id) select id from jobs where project_id='PROJ-00099' returning id into w;
  for i in 1..3 loop
    insert into sheets (work_order_id, sheet_number, qty, item_code, species, png_path, pdf_path, pdf_uploaded_at)
      values (w, i, 3, 'DSK-0'||i, 'Maple', format('PROJ-00099/v1/sheet-%s.png',i), format('PROJ-00099/v1/sheet-%s.pdf',i), now()) returning id into s;
    insert into sheet_progress (sheet_id, department, qty_required, qty_done)
      select s, d, 3, case when d='milling' then 3 else 0 end from unnest(array['milling','cnc','sanding','finishing','assembly_qc']) d;
  end loop;
end $$;
select make_test_job('PROJ-00418');
select set_person('test@pdindy.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true);
insert into profiles (id, full_name, role, departments) values ('77777777-7777-7777-7777-777777777777','Shawn K','supervisor','{delivery}') on conflict do nothing;
```

#### pgsupa.js

```javascript
// A stand-in for supabase-js that talks to the real test database the way
// Supabase's API does: connect as `authenticator`, switch to the login's
// role, set the JWT claims, run the statement. So row-level security,
// column grants and every database check apply exactly as on the tablet.
const { Pool, types } = require("pg");
types.setTypeParser(1082, v => v);          // dates stay "YYYY-MM-DD", as PostgREST sends them
types.setTypeParser(20, v => Number(v));     // counts as numbers
const pool = new Pool({ host: "/tmp/pg", port: 5433, database: "sync", user: "authenticator", max: 4 });
const admin = new Pool({ host: "/tmp/pg", port: 5433, database: "sync", user: "postgres", max: 2 });

const q = (s) => '"' + s.replace(/"/g, '""') + '"';
let offline = false;                     // flip to simulate the Wi-Fi dropping
const netErr = () => ({ data: null, error: { message: "TypeError: Failed to fetch" } });

async function runAs(user, sql, params) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query(`set local role ${user ? "authenticated" : "anon"}`);
    await c.query("select set_config('request.jwt.claims', $1, true)",
      [user ? JSON.stringify({ sub: user.id, role: "authenticated" }) : ""]);
    const r = await c.query(sql, params);
    await c.query("commit");
    return { data: r.rows, error: null };
  } catch (e) {
    await c.query("rollback").catch(() => {});
    return { data: null, error: { message: e.message, code: e.code, details: e.detail || null } };
  } finally { c.release(); }
}

const retSet = new Map();
async function isSetReturning(fn) {
  if (!retSet.has(fn)) {
    const r = await admin.query("select proretset from pg_proc where proname = $1 and pronamespace = 'public'::regnamespace", [fn]);
    retSet.set(fn, r.rows.length ? r.rows[0].proretset : false);
  }
  return retSet.get(fn);
}

function builder(client, table) {
  const st = { table, kind: "select", cols: "*", where: [], params: [], order: [], limit: null, single: null, values: null, returning: null };
  const p = (v) => { st.params.push(v); return "$" + st.params.length; };
  const b = {
    select(cols = "*") { if (st.kind === "update") st.returning = cols; else st.cols = cols; return b; },
    update(values) { st.kind = "update"; st.values = values; return b; },
    eq(c, v) { st.where.push(`${q(c)} = ${p(v)}`); return b; },
    neq(c, v) { st.where.push(`${q(c)} <> ${p(v)}`); return b; },
    gt(c, v) { st.where.push(`${q(c)} > ${p(v)}`); return b; },
    gte(c, v) { st.where.push(`${q(c)} >= ${p(v)}`); return b; },
    lt(c, v) { st.where.push(`${q(c)} < ${p(v)}`); return b; },
    lte(c, v) { st.where.push(`${q(c)} <= ${p(v)}`); return b; },
    in(c, arr) { st.where.push(`${q(c)} = any(${p(arr)})`); return b; },
    is(c, v) { st.where.push(`${q(c)} is ${v === null ? "null" : v ? "true" : "false"}`); return b; },
    order(c, o = {}) { st.order.push(`${q(c)} ${o.ascending === false ? "desc" : "asc"}${o.nullsFirst ? " nulls first" : ""}`); return b; },
    limit(n) { st.limit = n; return b; },
    maybeSingle() { st.single = "maybe"; return b; },
    single() { st.single = "one"; return b; },
    then(res, rej) { return exec().then(res, rej); },
  };
  const cols = (s) => s.trim() === "*" ? "*" : s.split(",").map(x => q(x.trim())).join(", ");
  async function exec() {
    if (offline) return netErr();
    let sql;
    const w = st.where.length ? " where " + st.where.join(" and ") : "";
    if (st.kind === "update") {
      const sets = Object.entries(st.values).map(([k, v]) => `${q(k)} = ${p(v)}`).join(", ");
      sql = `update ${q(st.table)} set ${sets}${w}${st.returning ? " returning " + cols(st.returning) : ""}`;
    } else {
      sql = `select ${cols(st.cols)} from ${q(st.table)}${w}${st.order.length ? " order by " + st.order.join(", ") : ""}${st.limit ? " limit " + st.limit : ""}`;
    }
    client.log.push({ table: st.table, kind: st.kind });
    const r = await runAs(client.user, sql, st.params);
    if (r.error) return r;
    let data = r.data.map(norm);
    if (st.kind === "update" && !st.returning) data = null;
    if (st.single === "maybe") return { data: data[0] || null, error: null };
    if (st.single === "one") return data.length === 1 ? { data: data[0], error: null } : { data: null, error: { message: "JSON object requested, multiple (or no) rows returned" } };
    return { data, error: null };
  }
  return b;
}

// dates come back the way PostgREST sends them: "YYYY-MM-DD" and ISO timestamps
function norm(row) {
  const o = {};
  for (const [k, v] of Object.entries(row)) {
    if (v instanceof Date) o[k] = v.toISOString();
    else o[k] = v;
  }
  return o;
}

function makeClient(startUser = null) {
  const client = { user: startUser, log: [], rpcs: [] };
  client.auth = {
    async getSession() { return { data: { session: client.user ? { user: client.user } : null } }; },
    async signInWithPassword({ email, password }) {
      if (offline) return netErr();
      const r = await admin.query("select id, email from auth.users where lower(email) = lower($1)", [email]);
      if (!r.rows.length || password !== "right") return { data: null, error: { message: "Invalid login credentials" } };
      client.user = { id: r.rows[0].id, email: r.rows[0].email };
      return { data: { user: client.user }, error: null };
    },
    async signOut() { client.user = null; return {}; },
  };
  client.from = (t) => builder(client, t);
  client.rpc = async (fn, args = {}) => {
    if (offline) return netErr();
    client.rpcs.push([fn, args]);
    const names = Object.keys(args);
    const params = names.map(n => args[n]);
    const call = `${q(fn)}(${names.map((n, i) => `${q(n)} => $${i + 1}`).join(", ")})`;
    const set = await isSetReturning(fn);
    const r = await runAs(client.user, set ? `select * from ${call}` : `select ${call} as r`, params);
    if (r.error) return r;
    return { data: set ? r.data.map(norm) : r.data[0].r, error: null };
  };
  client.storage = { from: () => ({
    async download() { return offline ? netErr() : { data: new Blob(["png"], { type: "image/png" }), error: null }; },
    async createSignedUrl() { return { data: { signedUrl: "https://abc.supabase.co/signed.pdf" }, error: null }; },
  }) };
  return client;
}

module.exports = { makeClient, admin, pool, setOffline: (v) => { offline = v; },
  users: { mike: { id: "11111111-1111-1111-1111-111111111111", email: "sanding@pdindy.com" },
           luke: { id: "22222222-2222-2222-2222-222222222222", email: "lukehart@pdindy.com" },
           test: { id: "33333333-3333-3333-3333-333333333333", email: "test@pdindy.com" },
           donnie: { id: "44444444-4444-4444-4444-444444444444", email: "donnie@pdindy.com" },
           willie: { id: "55555555-5555-5555-5555-555555555555", email: "willie@pdindy.com" },
           kp: { id: "66666666-6666-6666-6666-666666666666", email: "kp@pdindy.com" },
           shawn: { id: "77777777-7777-7777-7777-777777777777", email: "shawn@pdindy.com" },
           david: { id: "88888888-8888-8888-8888-888888888888", email: "ddart@pdindy.com" } } };
```

#### mkrows.js

```javascript
const { makeClient, users } = require("./pgsupa");
(async () => {
  const c = makeClient(users.mike);
  const r = await c.from("v_floor_sheets").select("*").eq("department", "sanding");
  const rows = r.data.filter(x => x.project_id === "PROJ-00418").map(x => ({ ...x, delivery_date: "2026-11-17", png_path: null, pdf_path: null, pages_ready: false }));
  require("fs").writeFileSync("/tmp/rows_sanding.json", JSON.stringify(rows));
  console.log(rows.length, "rows; done", rows.reduce((a, x) => a + x.qty_done, 0), "of", rows.reduce((a, x) => a + x.qty_required, 0));
  process.exit(0);
})();
```

#### db_test.js

```javascript
// Steps 4–9 through the real login path (authenticator → authenticated + JWT claims).
// Run on a fresh seeded database: ../base/fresh.sh && node db_test.js
const { makeClient, admin, users } = require("./pgsupa");
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const as = (u) => makeClient(u);
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
const uuid = () => require("crypto").randomUUID();

(async () => {
  const mike = as(users.mike), luke = as(users.luke), test = as(users.test), anon = as(null),
        willie = as(users.willie), kp = as(users.kp), shawn = as(users.shawn), david = as(users.david);
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  const j362 = (await one("select id from jobs where project_id='PROJ-00362'")).id;   // in Delivery
  const jT = (await one("select id from jobs where project_id='TEST-00418'")).id;
  const type = async (d, l) => (await one("select id from defect_types where department=$1 and ($2::text is null or label=$2) order by sort_order limit 1", [d, l || null])).id;

  // ---------------- pickers ----------------
  let r = await mike.from("v_pick_jobs").select("*");
  ok("Mike's job picker: real jobs incl. the Delivery-phase one, no test jobs, no Pre-Production",
     r.data.some(j => j.project_id === "PROJ-00362") && !r.data.some(j => j.is_test) && !r.data.some(j => j.project_id === "PROJ-00325"),
     r.data.map(j => j.project_id).join(","));
  r = await test.from("v_pick_jobs").select("*");
  ok("Test Supervisor's picker: test jobs only", r.data.length === 1 && r.data[0].project_id === "TEST-00418");
  r = await mike.from("v_pick_sheets").select("*").eq("job_id", j418);
  ok("sheet picker: PROJ-00418 has 9 sheets, with their departments", r.data.length === 9 && r.data[0].departments.includes("sanding"));
  r = await anon.from("v_pick_jobs").select("*");
  ok("no login: picker refused or empty", !!r.error || r.data.length === 0);

  // ---------------- defects ----------------
  const tSand = await type("sanding");
  const cid = uuid();
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: tSand, p_sheet: 4, p_note: "cross-grain scratch", p_client_id: cid });
  ok("Mike logs a sanding defect on sheet 4", r.data && r.data.ok, r.error && r.error.message);
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: tSand, p_sheet: 4, p_note: "cross-grain scratch", p_client_id: cid });
  ok("sending it again (Wi-Fi retry) doesn't log it twice", r.data && r.data.already && (await one("select count(*)::int n from defects")).n === 1);
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "metal", p_type: await type("metal"), p_sheet: 4 });
  ok("Mike can't log for Metal", r.error && /can't make entries for Metal/.test(r.error.message), r.error && r.error.message);
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: await type("finishing"), p_sheet: 4 });
  ok("a defect from another department's list is refused", r.error && /isn't on Sanding's list/.test(r.error.message));
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: tSand, p_sheet: 12 });
  ok("a sheet that isn't on the work order is refused, in plain words", r.error && /Sheet 12 isn't on PROJ-00418's current work order/.test(r.error.message), r.error && r.error.message);
  r = await mike.rpc("log_defect", { p_job: jT, p_department: "sanding", p_type: tSand, p_sheet: 1 });
  ok("Mike can't log on a test job", r.error && /test job/.test(r.error.message));
  r = await test.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: tSand, p_sheet: 1 });
  ok("Test Supervisor can't log on a real job", r.error && /only make entries on test jobs/.test(r.error.message));
  r = await test.rpc("log_defect", { p_job: jT, p_department: "sanding", p_type: tSand, p_sheet: 1, p_note: "bench" });
  ok("Test Supervisor logs on the test job", r.data && r.data.ok);
  r = await shawn.rpc("log_defect", { p_job: j362, p_department: "delivery", p_type: await type("delivery", "Missing product on site") });
  ok("Shawn logs 'Missing product on site' on a job in Delivery, no sheet", r.data && r.data.ok, r.error && r.error.message);
  r = await mike.from("v_defects").select("*");
  ok("Mike sees real defects (his and Shawn's) but not the test one", r.data.length === 2 && !r.data.some(d => d.is_test));
  ok("...with names on them", r.data.some(d => d.logged_by_name === "Shawn K") && r.data.some(d => d.logged_by_name === "Mike B"));
  r = await luke.from("v_defects").select("*");
  ok("the office sees all three, test one included (labelled)", r.data.length === 3 && r.data.filter(d => d.is_test).length === 1);
  const myDef = (await mike.from("v_defects").select("*").eq("logged_by_name", "Mike B")).data[0].id;
  const shawnDef = (await mike.from("v_defects").select("*").eq("logged_by_name", "Shawn K")).data[0].id;
  r = await mike.rpc("void_defect", { p_defect: shawnDef });
  ok("Mike can't mark Shawn's entry as a mistake", r.error && /Only the person who logged it/.test(r.error.message));
  r = await mike.rpc("void_defect", { p_defect: myDef });
  ok("Mike marks his own as entered by mistake — kept, flagged voided", !r.error && (await one("select voided_at is not null v from defects where id=$1", [myDef])).v);
  r = await mike.from("defects").update({ note: "rewritten" }).eq("id", myDef).select("id");
  ok("nobody can edit a defect directly", !!r.error || r.data.length === 0);
  r = await anon.from("defects").select("*");
  ok("no login sees no defects", !!r.error || r.data.length === 0);

  // defect lists
  r = await mike.rpc("set_defect_type", { p_department: "sanding", p_label: "Burn marks" });
  ok("a supervisor can't change the defect lists", r.error && /Only a manager/.test(r.error.message));
  r = await luke.rpc("set_defect_type", { p_department: "sanding", p_label: "Burn marks" });
  ok("Luke adds 'Burn marks' to Sanding", r.data && /is on the list/.test(r.data), r.error && r.error.message);
  r = await luke.rpc("set_defect_type", { p_department: "sanding", p_label: "Burn marks", p_active: false });
  const burn = await type("sanding", "Burn marks");
  r = await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: burn, p_sheet: 1 });
  ok("a retired defect type can't be picked", r.error && /taken off the list/.test(r.error.message));

  // ---------------- problems ----------------
  r = await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Sheet 8 top has a crack along the glue line.", p_sheet: 8, p_work_stopped: true, p_client_id: uuid() });
  ok("Mike flags a problem with work stopped", r.data && r.data.ok && /work stopped/.test(r.data.summary));
  const prob = r.data.id;
  r = await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "   " });
  ok("an empty problem is refused", r.error && /Say what's wrong/.test(r.error.message));
  r = await luke.from("v_problems").select("*").eq("id", prob);
  ok("the office sees it, open, work stopped", r.data.length === 1 && r.data[0].status === "open" && r.data[0].work_stopped && r.data[0].raised_by_name === "Mike B");
  r = await mike.rpc("answer_problem", { p_problem: prob, p_body: "fixed" });
  ok("Mike can't answer (office only) — through the real login path", r.error && /Only the office/.test(r.error.message));
  r = await luke.rpc("answer_problem", { p_problem: prob, p_body: "Looking now — hold that sheet.", p_close: false });
  r = await mike.from("v_problems").select("*").eq("id", prob);
  ok("an office reply that keeps it open: still open, thread shows it", r.data[0].status === "open" && r.data[0].thread.length === 1 && r.data[0].thread[0].kind === "office_note");
  r = await luke.rpc("answer_problem", { p_problem: prob, p_body: "Reglue it and carry on." });
  r = await mike.from("v_problems").select("*").eq("id", prob);
  ok("Luke answers and closes it", r.data[0].status === "answered" && r.data[0].answered_by_name === "Luke H");
  r = await mike.rpc("reply_problem", { p_problem: prob, p_body: "Reglued, but it opened again overnight.", p_client_id: uuid() });
  r = await luke.from("v_problems").select("*").eq("id", prob);
  ok("Mike's reply sends it back, tagged Came back, whole thread attached",
     r.data[0].status === "open" && r.data[0].came_back && r.data[0].thread.length === 3);
  r = await as(users.donnie).rpc("reply_problem", { p_problem: prob, p_body: "Not mine" });
  ok("Donnie (milling) can't reply on a sanding problem", r.error && /can't make entries for Sanding/.test(r.error.message));
  r = await david.rpc("answer_problem", { p_problem: prob, p_body: "New top it is." });
  ok("David, a manager too, can answer", r.data && r.data.ok);
  r = await test.rpc("flag_problem", { p_job: jT, p_department: "metal", p_body: "bench test problem", p_sheet: 2 });
  const tprob = r.data.id;
  r = await mike.from("v_problems").select("*");
  ok("Mike doesn't see the test problem", r.data.every(p => !p.is_test));
  r = await luke.rpc("answer_problem", { p_problem: tprob, p_body: "bench answer" });
  ok("the office can answer a test-lane problem (so the bench loop closes)", r.data && r.data.ok);
  r = await anon.from("problem_messages").select("*");
  ok("no login sees no messages", !!r.error || r.data.length === 0);

  // log-only
  r = await admin.query("select count(*)::int n from sheet_progress where department='delivery'");
  ok("Delivery has no sheet counts", r.rows[0].n === 0);
  let err = null;
  try { await admin.query("insert into sheet_progress (sheet_id, department, qty_required) select id, 'delivery', 1 from sheets limit 1"); } catch (e) { err = e.message; }
  ok("a work order naming Delivery is refused with a plain message", /Delivery is a log-only department/.test(err || ""), err);

  // ---------------- flags ----------------
  r = await mike.rpc("set_flag", { p_job: j418, p_level: "priority", p_note: "tops through finishing by Wed" });
  ok("Mike can't set a flag (real login path)", r.error && /Only a manager/.test(r.error.message));
  r = await luke.rpc("set_flag", { p_job: j418, p_level: "priority", p_note: "" });
  ok("a flag without a note is refused", r.error && /Write a note/.test(r.error.message));
  r = await luke.rpc("set_flag", { p_job: j418, p_level: "watch", p_note: "Customer may change the base colour", p_department: "finishing" });
  r = await luke.rpc("set_flag", { p_job: j099, p_level: "critical", p_note: "Customer on site Thursday — desks through finishing Wednesday" });
  ok("Luke sets a critical flag", r.data && r.data.ok);
  r = await luke.rpc("set_flag", { p_job: j099, p_level: "priority", p_note: "Walkthrough moved to next week" });
  ok("setting another on the same job replaces it", r.data.replaced === true && (await one("select count(*)::int n from flags where job_id=$1 and cleared_at is null", [j099])).n === 1);
  r = await luke.rpc("set_flag", { p_job: j418, p_level: "watch", p_note: "x", p_department: "delivery" });
  ok("a flag on log-only Delivery is refused", r.error && /has no queue/.test(r.error.message));
  r = await mike.from("v_flags").select("*").eq("is_open", true);
  ok("Mike sees the open flags (2), with notes", r.data.length === 2 && r.data.every(f => f.note));
  r = await luke.rpc("set_flag", { p_job: jT, p_level: "critical", p_note: "bench critical" });
  r = await mike.from("v_flags").select("*").eq("is_open", true);
  ok("...and not the test job's flag", r.data.length === 2);
  r = await test.from("v_flags").select("*").eq("is_open", true);
  ok("the Test Supervisor sees only the test flag", r.data.length === 1 && r.data[0].project_id === "TEST-00418");
  const fid = (await luke.from("v_flags").select("*").eq("job_id", j099).eq("is_open", true)).data[0].id;
  r = await luke.rpc("clear_flag", { p_flag: fid, p_note: "done" });
  ok("Luke clears it; history keeps both, with names", (await one("select count(*)::int n from flags where job_id=$1 and cleared_by_name='Luke H'", [j099])).n === 2);

  // ---------------- routine tasks ----------------
  r = await mike.rpc("add_routine_task", { p_name: "Replace wide belt paper", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 4 });
  ok("Mike can't add a routine task", r.error && /Only a manager/.test(r.error.message));
  r = await luke.rpc("add_routine_task", { p_name: "Replace wide belt paper", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 5 });
  ok("Friday is refused (Monday–Thursday only)", r.error && /Monday to Thursday/.test(r.error.message));
  r = await luke.rpc("add_routine_task", { p_name: "Replace wide belt paper", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 4,
                                           p_week_interval: 1, p_start_date: "2026-09-01", p_assigned_to: users.mike.id });
  ok("Luke adds a weekly Thursday task for Mike", r.data && r.data.ok, r.error && r.error.message);
  const task = r.data.id;
  r = await luke.rpc("add_routine_task", { p_name: "Blow out filters", p_department: "sanding", p_schedule_type: "monthly", p_weekday: 3,
                                           p_monthly_occurrence: -1, p_start_date: "2026-09-01" });
  r = await luke.rpc("add_routine_task", { p_name: "bench task", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 1,
                                           p_assigned_to: users.test.id });
  ok("a real task can't go to the Test Supervisor", r.error && /Tick "test task"/.test(r.error.message));
  r = await luke.rpc("add_routine_task", { p_name: "bench task", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 1,
                                           p_assigned_to: users.test.id, p_is_test: true });
  r = await mike.from("v_routine_tasks").select("*").eq("department", "sanding");
  ok("Mike sees the two real sanding tasks, not the test one", r.data.length === 2 && r.data.every(t => !t.is_test));
  const t1 = r.data.find(t => t.id === task);
  ok("schedule reads 'Every Thursday'; never done so it's overdue from Sep 3", t1.schedule_text === "Every Thursday" && t1.next_due === "2026-09-03" && t1.days_until < 0, `${t1.schedule_text} ${t1.next_due} ${t1.days_until}`);
  r = await mike.rpc("complete_routine_task", { p_task: task, p_client_id: uuid() });
  ok("Mike marks it done; the reply says when it's next due", r.data && /Next due/.test(r.data.summary), r.data && r.data.summary);
  r = await mike.from("v_routine_tasks").select("*").eq("id", task);
  ok("done today, next due is in the future, history has Mike", r.data[0].done_today && r.data[0].days_until > 0 && r.data[0].history[0].by === "Mike B");
  r = await as(users.donnie).rpc("complete_routine_task", { p_task: task });
  ok("Donnie can't complete a sanding task", r.error && /can't complete Sanding tasks/.test(r.error.message));
  const logId = r.data ? null : r.data;
  const lg = (await one("select id from routine_task_logs where task_id=$1", [task])).id;
  r = await mike.rpc("void_task_completion", { p_log: lg });
  r = await mike.from("v_routine_tasks").select("*").eq("id", task);
  ok("undoing it (entered by mistake) makes it due again", !r.data[0].done_today && r.data[0].days_until < 0);
  r = await luke.rpc("retire_routine_task", { p_task: task });
  r = await mike.from("v_routine_tasks").select("*").eq("id", task);
  ok("a retired task leaves the list; its history stays", r.data.length === 0 && (await one("select count(*)::int n from routine_task_logs where task_id=$1", [task])).n === 1);
  // the old app's scheduling, spot-checked
  const due = async (...a) => (await one("select routine_next_due($1,$2,$3,$4,$5::date,$6::date)::text d", a)).d;
  ok("every 2 weeks on Monday from Mon Sep 7, done Sep 7 → Sep 21", await due("weekly", 1, 2, null, "2026-09-07", "2026-09-07") === "2026-09-21");
  ok("every 2 weeks from Wed Sep 2 start → first Monday Sep 7", await due("weekly", 1, 2, null, "2026-09-02", null) === "2026-09-07");
  ok("last Wednesday of the month from Sep 1 → Sep 30", await due("monthly", 3, null, -1, "2026-09-01", null) === "2026-09-30");
  ok("1st Tuesday, done Oct 6 → Nov 3", await due("monthly", 2, null, 1, "2026-09-01", "2026-10-06") === "2026-11-03");
  ok("4th Thursday in a month → Sep 24", await due("monthly", 4, null, 4, "2026-09-01", null) === "2026-09-24");

  // ---------------- supplies ----------------
  r = await mike.rpc("request_supply", { p_department: "sanding", p_item: "120 grit discs, 6\"", p_qty: 2, p_note: "hook and loop", p_client_id: uuid() });
  ok("Mike asks for 120 grit discs", r.data && r.data.ok);
  const req = r.data.id;
  r = await mike.rpc("set_supply_qty", { p_request: req, p_qty: 4 });
  ok("changes the quantity to 4 (the number, not +2)", (await one("select qty from supply_requests where id=$1", [req])).qty === 4);
  r = await as(users.donnie).rpc("cancel_supply", { p_request: req });
  ok("Donnie can't cancel sanding's request", r.error && /Only Sanding/.test(r.error.message));
  r = await mike.rpc("order_supplies", { p_requests: [req] });
  ok("Mike can't mark it ordered", r.error && /Only the office/.test(r.error.message));
  r = await mike.rpc("receive_supply", { p_request: req });
  ok("...or received before it's ordered", r.error && /hasn't ordered this yet/.test(r.error.message));
  r = await luke.rpc("order_supplies", { p_requests: [req] });
  ok("Luke marks it ordered", r.data && r.data.ordered === 1);
  r = await mike.rpc("set_supply_qty", { p_request: req, p_qty: 6 });
  ok("once ordered, the quantity is fixed — plain message", r.error && /already been ordered/.test(r.error.message));
  r = await mike.rpc("receive_supply", { p_request: req });
  r = await mike.from("v_supply_requests").select("*").eq("id", req);
  ok("Mike receives it: closed, with every step named", r.data[0].state === "received" && !r.data[0].is_open && r.data[0].events.length === 4);
  r = await mike.rpc("request_supply", { p_department: "sanding", p_item: "Tack cloths", p_qty: 1 });
  const req2 = r.data.id;
  r = await luke.rpc("not_ordering_supply", { p_request: req2, p_reason: "" });
  ok("not ordering needs a reason", r.error && /Give a reason/.test(r.error.message));
  r = await luke.rpc("not_ordering_supply", { p_request: req2, p_reason: "We have 3 boxes in the back" });
  r = await mike.from("v_supply_requests").select("*").eq("id", req2);
  ok("Mike sees the reason", r.data[0].state === "not_ordering" && r.data[0].not_ordering_reason === "We have 3 boxes in the back");
  r = await test.rpc("request_supply", { p_department: "sanding", p_item: "bench discs", p_qty: 1 });
  r = await mike.from("v_supply_requests").select("*");
  ok("Mike doesn't see the Test Supervisor's request", r.data.every(x => !x.is_test));
  r = await luke.from("v_supply_requests").select("*").eq("is_test", true);
  ok("the office sees it, marked test", r.data.length === 1);

  // ---------------- Arrow ----------------
  r = await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6, 9, 6], p_description: "bases", p_sent_on: "2026-09-01", p_client_id: uuid() });
  ok("Willie sends sheets 6 and 9 to Arrow (duplicate tick ignored)", r.data && r.data.ok && (await one("select sheet_numbers::text s from outside_jobs")).s === "{6,9}", r.error && r.error.message);
  const arr = r.data.id;
  r = await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "paint" });
  ok("nothing ticked and nothing described is refused", r.error && /Tick the sheets that went, or describe/.test(r.error.message));
  r = await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "paint", p_description: "hinges", p_sent_on: "2099-01-01" });
  ok("a future date is refused", r.error && /can't be in the future/.test(r.error.message));
  r = await shawn.rpc("send_to_arrow", { p_job: j362, p_department: "delivery", p_service: "paint", p_description: "touch-up legs" });
  ok("Shawn sends hardware with no sheet, on a job in Delivery", r.data && r.data.ok, r.error && r.error.message);
  r = await mike.rpc("send_to_arrow", { p_job: j418, p_department: "sanding", p_service: "paint", p_description: "x" });
  ok("Mike (sanding) can't send to Arrow", r.error && /sent from Metal, Assembly/.test(r.error.message));
  r = await mike.rpc("return_from_arrow", { p_item: arr });
  ok("...or mark one returned", r.error && /Only Metal, Assembly/.test(r.error.message));
  r = await kp.from("v_outside_jobs").select("*").eq("at_vendor", true);
  ok("KP sees both at Arrow, days out as a number", r.data.length === 2 && r.data.every(x => Number.isInteger(x.days_out)));
  r = await kp.rpc("return_from_arrow", { p_item: arr, p_returned_on: "2026-08-30" });
  ok("coming back before it went is refused", r.error && /can't come back before it went/.test(r.error.message));
  r = await kp.rpc("return_from_arrow", { p_item: arr, p_returned_on: "2026-09-15" });
  ok("KP marks Willie's item returned: 14-day turnaround", r.data && /after 14 days/.test(r.data.summary), r.data && r.data.summary);
  const shawnArr = (await kp.from("v_outside_jobs").select("*").eq("at_vendor", true)).data[0].id;
  r = await kp.rpc("void_arrow", { p_item: shawnArr });
  ok("KP can't void Delivery's item (only the sender's department or a manager)", r.error && /Only Delivery/.test(r.error.message));
  r = await shawn.rpc("void_arrow", { p_item: shawnArr });
  r = await kp.from("v_outside_jobs").select("*").eq("at_vendor", true);
  ok("Shawn marks it entered by mistake: off the list, kept in history", r.data.length === 0 && (await one("select count(*)::int n from outside_jobs")).n === 2);

  // ---------------- QC ----------------
  r = await kp.rpc("record_qc", { p_job: j418, p_sheet: 3, p_result: "pass", p_client_id: uuid() });
  ok("KP records sheet 3 passed", r.data && r.data.ok);
  r = await kp.rpc("record_qc", { p_job: j418, p_sheet: 4, p_result: "fail" });
  ok("a fail with no note is refused", r.error && /Say what failed/.test(r.error.message));
  r = await kp.rpc("record_qc", { p_job: j418, p_sheet: 4, p_result: "fail", p_note: "finish scuffed on one corner" });
  ok("a fail logs a 'Failed QC' defect on sheet 4", r.data && /logged as a defect/.test(r.data.summary));
  r = await mike.from("v_defects").select("*").eq("job_id", j418).eq("sheet_number", 4).eq("voided", false);
  ok("...which Mike sees on the piece", r.data.some(d => d.defect_type === "Failed QC" && d.department === "assembly_qc"));
  r = await mike.rpc("record_qc", { p_job: j418, p_sheet: 4, p_result: "pass" });
  ok("Mike can't record QC", r.error && /can't make entries for Assembly/.test(r.error.message));
  const qcFail = (await one("select id from qc_entries where result='fail'")).id;
  r = await kp.rpc("void_qc", { p_entry: qcFail });
  ok("undoing the failed QC also withdraws its defect", (await one("select voided_at is not null v from defects where defect_type='Failed QC'")).v);

  // ---------------- TV ----------------
  r = await anon.rpc("tv_snapshot", { p_key: "guess" });
  ok("the TV with no link gets nothing but a plain message", r.data && r.data.ok === false && /isn't valid/.test(r.data.reason) && !JSON.stringify(r.data).includes("PROJ"));
  r = await mike.rpc("new_tv_link", {});
  ok("a supervisor can't make the TV link", r.error && /Only a manager/.test(r.error.message));
  r = await luke.rpc("new_tv_link", {});
  const key = r.data.key;
  ok("Luke makes a TV link (64 characters)", key && key.length === 64);
  r = await anon.from("app_settings").select("*");
  ok("the link's fingerprint can't be read, even signed in", (await luke.from("app_settings").select("*")).data.every(s => !s.key.startsWith("secret")));
  r = await anon.rpc("tv_snapshot", { p_key: key });
  const tv = r.data;
  ok("the TV shows live departments only: Sanding", tv.ok && tv.live.length === 1 && tv.live[0].key === "sanding", JSON.stringify(tv.live));
  // PROJ-00418 sanding: 20 pieces, 5 done (sheets 1-3). PROJ-00099: 9 pieces, 0 done
  ok("pieces left in sanding: 15 + 9 = 24", tv.kpis.left === 24, JSON.stringify(tv.kpis));
  // ready: 418 sheets 4-9 cnc done → 15 ready; 099 cnc 0 → 0 ready
  ok("ready to work on: 15 (PROJ-00099 hasn't cleared CNC)", tv.kpis.ready === 15);
  ok("no test job anywhere on the TV", !JSON.stringify(tv).includes("TEST-"));
  ok("table: soonest delivery first, sanding done/total per job",
     tv.table[0].project_id === "PROJ-00099" && tv.table[1].depts[0].done === 5 && tv.table[1].depts[0].total === 20);
  ok("the open work-stopped problem is on the attention strip", tv.attention.some(a => a.kind === "stopped")
     || (await one("select count(*)::int n from problems where status='open' and work_stopped and not is_test")).n === 0);
  r = await luke.rpc("set_flag", { p_job: j418, p_level: "critical", p_note: "Customer on site Thursday" });
  r = await anon.rpc("tv_snapshot", { p_key: key });
  ok("a critical flag gets its own band; the table marks the job", r.data.critical.length === 1 && r.data.table.find(t => t.project_id === "PROJ-00418").flag === "critical");
  await luke.rpc("set_department_live", { p_department: "finishing", p_live: true });
  r = await anon.rpc("tv_snapshot", { p_key: key });
  ok("switching Finishing live adds it to the TV", r.data.live.map(l => l.key).join(",") === "sanding,finishing");
  await luke.rpc("new_tv_link", {});
  r = await anon.rpc("tv_snapshot", { p_key: key });
  ok("a new link switches the old one off", r.data.ok === false);

  // ---------------- earlier checks still pass ----------------
  r = await admin.query("select count(*)::int n from check_test_lane() where result <> 'PASS'");
  ok("check_test_lane() still all PASS", r.rows[0].n === 0);
  r = await admin.query("select count(*)::int n from check_floor() where result <> 'PASS'");
  ok("check_floor() all PASS on this data too", r.rows[0].n === 0);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_app_core.js

```javascript
// The original tablet core tests (testing kit), run against the new index.html.
// Changed on purpose: a manager now opens 8 departments (Delivery added).
const fs = require("fs");
const html = fs.readFileSync(process.env.APP || "../out/index.html", "utf8");
fs.writeFileSync("/tmp/app_core.js", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
delete require.cache["/tmp/app_core.js"];
const C = require("/tmp/app_core.js");
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

const real = JSON.parse(fs.readFileSync("/tmp/rows_sanding.json", "utf8"));
const soon = real.slice(0, 2).map((r, i) => ({ ...r, progress_id: "s" + i, job_id: "job-soon", project_id: "PROJ-00099", job_name: "Oaks Academy Q01092", delivery_date: "2026-10-21", qty_done: 0, qty_required: 3, sheet_number: i + 1, materials_ordered: false }));
const finished = [{ ...real[0], progress_id: "f1", job_id: "job-done", project_id: "PROJ-00362", delivery_date: "2026-09-30", qty_done: 4, qty_required: 4 }];
const rows = [...real, ...soon, ...finished];

const q = C.buildQueue(rows);
ok("queue leaves out the fully finished job", !q.find(j => j.project_id === "PROJ-00362"));
ok("queue puts the soonest delivery first", q[0].project_id === "PROJ-00099" && q[1].project_id === "PROJ-00418");
const j418 = q.find(j => j.project_id === "PROJ-00418");
ok("PROJ-00418 totals match the database: 5 of 20", j418.done === 5 && j418.total === 20, `${j418.done}/${j418.total}`);
ok("materials flag carried onto the card", q[0].materials_ordered === false);

const id4 = real.find(r => r.sheet_number === 4).progress_id;
let box = C.setPending({}, id4, 2);
box = C.setPending(box, id4, 3);
ok("only the latest count per sheet is kept", Object.keys(box).length === 1 && box[id4].qty === 3);
const shown = C.withPending(rows, box);
ok("a waiting count shows straight away", shown.find(r => r.progress_id === id4).qty_done === 3);
ok("...and flows into the job total", C.buildQueue(shown).find(j => j.project_id === "PROJ-00418").done === 8);

const s1 = real.find(r => r.sheet_number === 1), s9 = real.find(r => r.sheet_number === 9);
let p = C.pagerFor(rows, s1.job_id, s1.progress_id);
ok("sheet 1: no previous, next is sheet 2", !p.prev && p.next.sheet_number === 2 && p.count === 9);
p = C.pagerFor(rows, s9.job_id, s9.progress_id);
ok("sheet 9: previous is 8, no next", p.prev.sheet_number === 8 && !p.next);

const today = new Date(2026, 8, 22);
ok("days left: Nov 17 is 56 days from Sep 22", C.daysLeft("2026-11-17", today) === 56);
ok("late jobs say late", C.daysText(C.daysLeft("2026-09-20", today)) === "2 days late");

ok("supervisor sees only their departments", JSON.stringify(C.departmentsFor({ role: "supervisor", departments: ["cnc", "milling"] })) === '["milling","cnc"]');
ok("manager can open every department (8, with Delivery)", C.departmentsFor({ role: "manager", departments: [] }).length === 8);

function fakeDb(behaviour) {
  const sent = [];
  return { sent, from: () => ({ update: (v) => ({ eq: (_c, id) => ({ select: async () => { sent.push([id, v.qty_done]); return behaviour(id, v.qty_done); } }) }) }) };
}
(async () => {
  const holder = (init) => { let v = init; return { get: () => v, set: (n) => { v = n; }, now: () => v }; };
  let db = fakeDb((id, q) => ({ data: [{ id, qty_done: q, state: "in_progress" }], error: null }));
  let h = holder({ a: { qty: 2 }, b: { qty: 4 } });
  let r = await C.flushOutbox(h, db);
  ok("online: both counts sent as the number itself", db.sent.join("|") === "a,2|b,4" && Object.keys(h.now()).length === 0);

  db = fakeDb(() => ({ data: null, error: { message: "TypeError: Failed to fetch" } }));
  h = holder({ a: { qty: 2 }, b: { qty: 4 } });
  r = await C.flushOutbox(h, db);
  ok("no connection: stops at the first failure and keeps everything", r.offline && Object.keys(h.now()).length === 2 && db.sent.length === 1);

  db = fakeDb(() => ({ data: [], error: null }));
  h = holder({ m: { qty: 4 } });
  r = await C.flushOutbox(h, db);
  ok("another department's count: dropped and explained", r.refused.length === 1 && /isn't allowed/.test(r.refused[0].reason) && !h.now().m);

  h = holder({ a: { qty: 2 } });
  db = { from: () => ({ update: (v) => ({ eq: (_c, id) => ({ select: async () => {
          h.set({ ...h.get(), a: { qty: 3 } });
          return { data: [{ id, qty_done: v.qty_done }], error: null }; } }) }) }) };
  r = await C.flushOutbox(h, db);
  ok("a tap made mid-send isn't lost", h.now().a && h.now().a.qty === 3, JSON.stringify(h.now()));

  ok("network errors recognised", C.isNetworkError({ message: "Failed to fetch" }) && !C.isNetworkError({ message: "permission denied" }));
  ok("secret key refused", C.keyProblem("https://x.supabase.co", "sb_secret_x")?.secret === true);
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
```

#### test_app_page.js

```javascript
// The original tablet screen tests (testing kit), run against the new index.html.
// Changed on purpose: a manager gets 8 department tabs (Delivery added).
// The fake client is the kit's, unchanged: it only knows the counting tables,
// which also proves counting still works when the new parts can't load.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const src = fs.readFileSync(process.env.APP || "../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const base = src.replace(/const SUPABASE_URL = "[^"]*";/, 'const SUPABASE_URL = "PASTE-YOUR-PROJECT-URL-HERE";')
                .replace(/const SUPABASE_KEY = "[^"]*";/, 'const SUPABASE_KEY = "PASTE-YOUR-PUBLISHABLE-KEY-HERE";');
const configured = base.replace("PASTE-YOUR-PROJECT-URL-HERE", "https://abc.supabase.co").replace("PASTE-YOUR-PUBLISHABLE-KEY-HERE", "sb_publishable_test");
const realRows = JSON.parse(fs.readFileSync("/tmp/rows_sanding.json", "utf8")).map(r => ({ ...r,
  png_path: `PROJ-00418/v${r.version}/sheet-${r.sheet_number}.png`, pdf_path: `PROJ-00418/v${r.version}/sheet-${r.sheet_number}.pdf`, pages_ready: true }));
realRows.find(r => r.sheet_number === 9).pages_ready = false;
const soon = realRows.slice(0, 2).map((r, i) => ({ ...r, progress_id: "soon" + i, job_id: "job-soon", project_id: "PROJ-00099", job_name: "Oaks Academy Q01092", delivery_date: "2026-10-21", qty_done: 0, qty_required: 3, sheet_number: i + 1, materials_ordered: false }));
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };

function fakeClient({ session = null, profile, rows = [...realRows, ...soon] } = {}) {
  const c = { net: true, updates: [], downloads: 0, rows: JSON.parse(JSON.stringify(rows)) };
  const netErr = { message: "TypeError: Failed to fetch" };
  c.auth = {
    getSession: async () => ({ data: { session } }),
    signInWithPassword: async ({ email, password }) => password === "right" ? { data: { user: { id: "u1", email } } } : { error: { message: "Invalid login credentials" } },
    signOut: async () => ({}),
  };
  c.from = (table) => ({
    select: () => ({
      eq: (col, val) => table === "profiles"
        ? { maybeSingle: async () => c.net ? { data: profile } : { error: netErr } }
        : Promise.resolve(c.net ? { data: c.rows.filter(r => r.department === val) } : { error: netErr }),
    }),
    update: (v) => ({ eq: (_c, id) => ({ select: async () => {
      if (!c.net) return { error: netErr };
      c.updates.push([id, v.qty_done]);
      const r = c.rows.find(x => x.progress_id === id); if (r) r.qty_done = v.qty_done;
      return { data: [{ id, qty_done: v.qty_done, state: v.qty_done ? "in_progress" : "not_started" }] };
    } }) }),
  });
  c.storage = { from: () => ({
    download: async () => { c.downloads++; return c.net ? { data: new Blob(["png"], { type: "image/png" }) } : { error: netErr }; },
    createSignedUrl: async () => ({ data: { signedUrl: "https://abc.supabase.co/signed.pdf" } }),
  }) };
  return c;
}

function boot(html, client, { online = true, preload = {} } = {}) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  Object.defineProperty(w.navigator, "onLine", { get: () => online, configurable: true });
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => { w.__printed = true; }; w.open = (u) => { w.__opened = u; }; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
const readout = (w) => w.document.querySelector(".readout .n").textContent + " of " + w.document.querySelector(".readout .l").textContent.replace(/^of /, "");
const click = async (w, sel) => { const el = w.document.querySelector(sel); if (!el) throw new Error("no " + sel); el.click(); await wait(40); };

(async () => {
  let w = boot(base, fakeClient());
  ok("unfilled settings: explains, doesn't try to run", /isn't set up yet/.test(txt(w)));

  const mike = fakeClient({ profile: { full_name: "Mike B", role: "supervisor", departments: ["sanding"] } });
  w = boot(configured, mike); await wait(30);
  ok("fresh tablet: asks him to sign in", !!w.document.getElementById("f"));
  w.document.getElementById("e").value = "sanding@pdindy.com"; w.document.getElementById("p").value = "wrong";
  w.document.getElementById("f").dispatchEvent(new w.Event("submit", { cancelable: true })); await wait(30);
  ok("wrong password: plain message", /didn't match/.test(w.document.getElementById("err").textContent));
  w.document.getElementById("p").value = "right";
  w.document.getElementById("f").dispatchEvent(new w.Event("submit", { cancelable: true })); await wait(60);
  let t = txt(w);
  ok("queue: his name and department, no tabs (one department)", /Mike B/.test(t) && /Sanding/.test(t) && !w.document.querySelector(".tabs"));
  ok("queue: soonest delivery first — 00099 above 00418", t.indexOf("PROJ-00099") < t.indexOf("PROJ-00418") && t.indexOf("PROJ-00099") > -1);
  ok("queue: PROJ-00418 shows 5 / 20 pieces, due Nov 17", /PROJ-00418.*Due Nov 17.*5\s*\/\s*20 pieces/.test(t));
  ok("queue: materials warning on both jobs — neither is marked ordered", w.document.querySelectorAll(".chip").length === 2);
  ok("status reads 'All saved'", /All saved/.test(t));

  const j418 = realRows[0].job_id;
  await click(w, `[data-job="${j418}"]`);
  ok("job: nine sheets, finished ones in turquoise", w.document.querySelectorAll(".sheet").length === 9 && w.document.querySelectorAll(".sheet.done").length === 3);
  const s4 = realRows.find(r => r.sheet_number === 4);
  await click(w, `[data-sheet="${s4.progress_id}"]`); await wait(40);
  t = txt(w);
  ok("sheet: 0 of 3, previous is sheet 3, next is sheet 5", /^0 of 3 done/.test(readout(w)) && /Sheet 3/.test(t) && /Sheet 5/.test(t) && /4 \/ 9/.test(t), readout(w));
  ok("sheet: the work order page is shown", !!w.document.querySelector("#page img"));
  ok("sheet: print is ready with the same page", !!w.document.querySelector("#printArea img"));

  await click(w, '[data-step="1"]'); await wait(60);
  ok("tap +: shows 1 of 3 and saves it", /^1 of 3/.test(readout(w)) && JSON.stringify(mike.updates.at(-1)) === JSON.stringify([s4.progress_id, 1]));
  ok("...and says All saved", /All saved/.test(txt(w)));

  mike.net = false;
  await click(w, '[data-step="1"]'); await wait(60);
  t = txt(w);
  ok("no Wi-Fi, tap +: still shows 2 straight away", /^2 of 3/.test(readout(w)));
  ok("...says it's waiting to send", /1 count waiting to send/.test(t));
  ok("...and has kept it on the tablet", JSON.parse(w.localStorage.getItem("sf_outbox"))[s4.progress_id].qty === 2);
  ok("...nothing reached the database", mike.updates.length === 1);

  mike.net = true; w.dispatchEvent(new w.Event("online")); await wait(120);
  ok("Wi-Fi back: the waiting count sends by itself", JSON.stringify(mike.updates.at(-1)) === JSON.stringify([s4.progress_id, 2]));
  ok("...and it says All saved again", /All saved/.test(txt(w)));

  await click(w, "[data-all]"); await wait(60);
  ok("Mark all done: Sheet complete", /Sheet complete/.test(txt(w)) && JSON.stringify(mike.updates.at(-1)) === JSON.stringify([s4.progress_id, 3]));
  await click(w, '[data-goto]:not([disabled]):last-of-type');
  ok("Next: moves to sheet 5", /Sheet 5 ·/.test(txt(w)));
  await click(w, "[data-print]");
  ok("Print opens the print dialog", w.__printed === true);
  await click(w, "[data-pdf]");
  ok("Open the PDF opens a secure link", /signed\.pdf/.test(w.__opened || ""));
  const before = mike.downloads;
  await click(w, '[data-goto]:not([disabled])'); await wait(40); await click(w, '[data-goto]:not([disabled]):last-of-type'); await wait(40);
  ok("going back to a page doesn't download it again", mike.downloads === before, `${before} -> ${mike.downloads}`);
  const s9 = realRows.find(r => r.sheet_number === 9);
  w.document.querySelector(".back").click(); await wait(40);
  await click(w, `[data-sheet="${s9.progress_id}"]`); await wait(40);
  ok("a sheet whose page hasn't arrived says so, and can't be printed",
     /hasn't been uploaded yet/.test(w.document.getElementById("page").textContent) && w.document.querySelector("[data-print]").disabled);
  w.close();

  const saved = { "sf_me": JSON.stringify({ id: "u1", email: "s@x", name: "Mike B", role: "supervisor", departments: ["sanding"] }),
                  "sf_rows_sanding": JSON.stringify({ rows: realRows, at: new Date(2026, 8, 22, 7, 5).toISOString() }) };
  const off = fakeClient({ profile: null }); off.net = false;
  w = boot(configured, off, { online: false, preload: saved }); await wait(80);
  t = txt(w);
  ok("restart offline: opens straight to the queue, not sign-in", /PROJ-00418/.test(t) && !w.document.getElementById("f"));
  ok("...and says it's showing the saved list", /No connection — showing the list from/.test(t));
  w.close();

  w = boot(configured, fakeClient({ session: { user: { id: "d", email: "d@x" } }, profile: { full_name: "Donnie E", role: "supervisor", departments: ["milling", "cnc"] } })); await wait(60);
  ok("Donnie: tabs for Milling and CNC only", [...w.document.querySelectorAll(".tab")].map(b => b.textContent).join(",") === "Milling,CNC");
  w.close();
  w = boot(configured, fakeClient({ session: { user: { id: "l", email: "l@x" } }, profile: { full_name: "Luke H", role: "manager", departments: [] } })); await wait(60);
  ok("Luke: a tab for every department (8, with Delivery)", w.document.querySelectorAll(".tab").length === 8);
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_app_e2e.js

```javascript
// The new tablet functions, end to end: the real index.html in jsdom, talking
// to the real test database through the same login path Supabase uses.
// Run on a fresh seeded database: ../base/fresh.sh && node test_app_e2e.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const html = fs.readFileSync(process.env.APP || "../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];

function boot(user, { preload = {} } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:page"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {};
  w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 3000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 60) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
const byText = (w, sel, re) => $$(w, sel).find(e => re.test(e.textContent));
function type(w, sel, value) { const el = $(w, sel); el.value = value; el.dispatchEvent(new w.Event("input")); }

(async () => {
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  const luke = makeClient(users.luke);
  await luke.rpc("set_flag", { p_job: j418, p_level: "critical", p_note: "Customer on site Thursday — tops through finishing Wednesday" });
  await luke.rpc("set_flag", { p_job: j099, p_level: "watch", p_note: "Customer may change the stain" });
  await luke.rpc("add_routine_task", { p_name: "Replace wide belt paper", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 1,
                                       p_week_interval: 1, p_start_date: "2026-09-01", p_assigned_to: users.mike.id });
  await luke.rpc("add_routine_task", { p_name: "Blow out sanding room filters", p_department: "sanding", p_schedule_type: "monthly", p_weekday: 3,
                                       p_monthly_occurrence: -1, p_start_date: "2026-12-01" });

  // ================= Mike =================
  let w = boot(users.mike);
  await until(() => /PROJ-00418/.test(txt(w)));
  ok("Mike: the four areas — Work orders · Problems · Log · Supplies", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Work orders · Problems · Log · Supplies",
     $$(w, ".subtab").map(b => b.textContent).join("|"));
  ok("Mike has two department tabs (Sanding, Finishing)", $$(w, ".tab").map(b => b.textContent).join(",") === "Sanding,Finishing");
  await until(() => $(w, ".flagtag"));
  let cards = $$(w, "button.job");
  ok("critical flag pins PROJ-00418 above the sooner PROJ-00099", /PROJ-00418/.test(cards[0].textContent) && /PROJ-00099/.test(cards[1].textContent));
  ok("...coloured, with its note", cards[0].classList.contains("f-critical") && /Critical — Customer on site Thursday/.test(cards[0].textContent));
  ok("a watch flag is a marker only, not pinned or coloured", /Watch — Customer may change the stain/.test(cards[1].textContent) && !cards[1].className.includes("f-"));
  ok("materials warning still shows (PROJ-00418 not ordered)", /Materials not ordered yet/.test(cards[0].textContent));
  ok("Mike's due routine task is pinned at the top", /Your routine tasks.*Replace wide belt paper.*Overdue by/.test(txt(w)), txt(w).slice(0, 200));
  ok("...and the not-yet-due one isn't", !/Your routine tasks[^]*Blow out sanding room filters/.test($(w, ".pinned").textContent));

  // sheet 4: log a defect, flag a problem
  await click(w, cards[0]);
  ok("job screen: the critical band with the note", /Critical: Customer on site Thursday/.test(txt(w)));
  const s4 = (await one("select sp.id from sheet_progress sp join sheets s on s.id=sp.sheet_id join work_orders wo on wo.id=s.work_order_id where wo.job_id=$1 and s.sheet_number=4 and sp.department='sanding'", [j418])).id;
  await click(w, `[data-sheet="${s4}"]`, 150);
  ok("sheet screen: counter, then Log a defect / Flag a problem", !!$(w, ".readout") && !!$(w, '[data-defect="here"]') && !!$(w, '[data-problem="here"]'));
  await click(w, '[data-defect="here"]');
  ok("defect: Sanding's own list (3 from the old app)", $$(w, "[data-picktype]").length === 3 && /Missed defect — caught after finish/.test(txt(w)));
  ok("...Log it is off until a type is picked", $(w, "[data-savedefect]").disabled);
  await click(w, byText(w, "[data-picktype]", /Caused defect — caught before finish/));
  type(w, '[data-mfield="note"]', "Cross-grain scratch, resanded");
  await click(w, "[data-savedefect]", 50);
  await until(async () => (await one("select count(*)::int n from defects")).n === 1);
  const d = await one("select * from defects");
  ok("logged in the database: sheet 4, sanding, type, note, Mike's name", d.sheet_number === 4 && d.department === "sanding" && d.defect_type === "Caused defect — caught before finish" && d.note === "Cross-grain scratch, resanded" && d.logged_by_name === "Mike B");
  await until(() => /On this piece/.test(txt(w)));
  ok("the sheet shows it under 'On this piece'", /On this piece.*Sanding.*Caused defect — caught before finish.*Logged by Mike B/.test(txt(w)));
  ok("a toast says what happened, in plain words", /Logged Caused defect — caught before finish on PROJ-00418 sheet 4/.test(txt(w)));

  await click(w, '[data-problem="here"]');
  ok("problem: Send it is off until something's typed", $(w, "[data-saveproblem]").disabled);
  type(w, '[data-mfield="text"]', "Top has a crack along the glue line. Reglue or remake?");
  ok("...and on once it is", !$(w, "[data-saveproblem]").disabled);
  $(w, "[data-mstops]").checked = true; $(w, "[data-mstops]").dispatchEvent(new w.Event("change"));
  await click(w, "[data-saveproblem]", 50);
  await until(() => /Work is stopped on this sheet/.test(txt(w)));
  const p = await one("select * from problems");
  ok("problem in the database: sheet 4, work stopped, Mike", p.sheet_number === 4 && p.work_stopped && p.raised_by_name === "Mike B");
  ok("the sheet now carries the work-stopped band", /Work is stopped on this sheet — Top has a crack/.test(txt(w)));

  // Problems tab
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 150);
  await click(w, '[data-tab="problems"]', 50);
  await until(() => /Waiting on an answer/.test(txt(w)) && $$(w, ".li").length > 0);
  ok("Problems tab: the problem, Waiting on the office, Work stopped", /PROJ-00418 · sheet 4.*Work stopped.*Waiting on the office/.test(txt(w)));
  await luke.rpc("answer_problem", { p_problem: p.id, p_body: "Reglue it and send it on." });
  await click(w, '[data-scope="all"]', 50); await click(w, '[data-scope="mine"]', 50);
  await until(() => /Answered — kept/.test(txt(w)) && /Reglue it and send it on/.test(txt(w)));
  ok("after the office answers: under Answered, with Luke's answer", /Answered — kept.*PROJ-00418 · sheet 4.*Answered.*Reglue it and send it on.*Luke H/.test(txt(w)));
  await click(w, "[data-reply]");
  type(w, '[data-mfield="text"]', "Reglued, opened again overnight.");
  await click(w, "[data-savereply]", 50);
  await until(async () => (await one("select came_back from problems")).came_back);
  await until(() => /Came back/.test(txt(w)));
  ok("a reply sends it back: tagged Came back, thread of three", /Waiting on an answer.*Came back/.test(txt(w)) && $$(w, ".li .msg").length >= 3);
  ok("the Problems tab counts it", /Problems1/.test($$(w, ".subtab").map(b => b.textContent).join("")));

  // job-level problem from the Problems tab, using the job picker
  await click(w, '[data-problem="pick"]');
  await until(() => $$(w, "[data-pickjob]").length > 0);
  ok("job picker lists real jobs, incl. PROJ-00362 in Delivery, no test jobs", $$(w, "[data-pickjob]").some(b => /PROJ-00362/.test(b.textContent)) && !$$(w, "[data-pickjob]").some(b => /TEST/.test(b.textContent)));
  type(w, "[data-jobfilter]", "099");
  ok("typing 099 narrows it to PROJ-00099", $$(w, "[data-pickjob]").length === 1 && /PROJ-00099/.test($(w, "[data-pickjob]").textContent));
  await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length === 4);
  ok("then its sheets, plus Whole job", $$(w, "[data-picksheet]").map(b => b.textContent.trim().slice(0, 1)).join("") === "W123");
  type(w, '[data-mfield="text"]', "Drawings for desk 3 are missing the grommet hole.");
  await click(w, "[data-saveproblem]", 50);
  await until(async () => (await one("select count(*)::int n from problems where sheet_number is null")).n === 1);
  ok("a whole-job problem is saved with no sheet", true);

  // Log tab
  await click(w, '[data-tab="log"]', 50);
  await until(() => /Routine tasks/.test(txt(w)) && /Logged this month/.test(txt(w)));
  ok("Log tab: routine tasks, then defects", txt(w).indexOf("Routine tasks") < txt(w).indexOf("Defects"));
  const lines = $$(w, ".countline").map(l => l.children[0].textContent + "=" + l.querySelector(".n").textContent);
  ok("...defect counts for sanding: 1 this month, by type", lines.join("|") === "Logged this month=1|Caused defect — caught before finish=1", lines.join("|"));
  ok("no Arrow or QC in Sanding's log", !/At Arrow/.test(txt(w)) && !/Look up a job/.test(txt(w)));
  const taskId = (await one("select id from routine_tasks where name='Replace wide belt paper'")).id;
  await click(w, `.taskrow [data-taskdone="${taskId}"]`, 50);
  await until(async () => (await one("select count(*)::int n from routine_task_logs")).n === 1);
  await until(() => /Done today by Mike B/.test(txt(w)));
  ok("tap Done: recorded, the row turns complete, the pin goes", /Done today by Mike B/.test(txt(w)) && !$(w, ".pinned"));
  await click(w, `[data-taskhist="${taskId}"]`);
  ok("history shows today, with Mike", new RegExp(`${["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][new Date().getMonth()]} ${new Date().getDate()} — Mike B`).test(txt(w)));
  await click(w, "[data-taskundo]"); await click(w, "[data-confirm]", 50);
  await until(async () => (await one("select count(*)::int n from routine_task_logs where voided_at is null")).n === 0);
  await until(() => !!$(w, ".pinned"));
  ok("'entered by mistake' undoes it; the task is due again and pinned again", !!$(w, ".pinned"));

  // Supplies
  await click(w, '[data-tab="supplies"]', 100);
  ok("Supplies: nothing open yet, then the box", /Nothing on order for Sanding/.test(txt(w)) && !!$(w, "#supItem") && $(w, "[data-ssend]").disabled);
  type(w, "#supItem", "120 grit discs, 6 inch");
  await click(w, '[data-snew="1"]'); await click(w, '[data-snew="1"]');
  ok("quantity with the same plus/minus: 3", $(w, ".card .qty .n").textContent === "3");
  type(w, "#supItem", "120 grit discs, 6 inch");
  await click(w, "[data-ssend]", 50);
  await until(async () => (await one("select count(*)::int n from supply_requests")).n === 1);
  await until(() => /Waiting on the office/.test(txt(w)));
  ok("sent: it sits above the box, 'Waiting on the office · asked … by Mike B'", /120 grit discs, 6 inch.*Waiting on the office · asked .* by Mike B/.test(txt(w)));
  ok("...and the box is cleared for the next one", $(w, "#supItem").value === "" && $(w, ".card .qty .n").textContent === "1");
  const reqId = (await one("select id from supply_requests")).id;
  await click(w, `[data-sqty="${reqId}"][data-d="1"]`, 50);
  await until(async () => (await one("select qty from supply_requests")).qty === 4);
  ok("+ on the open request sends the number itself: 4", (await one("select qty from supply_requests")).qty === 4);
  await luke.rpc("order_supplies", { p_requests: [reqId] });
  await click(w, '[data-tab="log"]', 50); await click(w, '[data-tab="supplies"]', 50);
  await until(() => !!$(w, "[data-sreceive]"));
  ok("once ordered: 'Ordered today by Luke H' and a Received button", /Ordered today by Luke H/.test(txt(w)) && !!$(w, "[data-sreceive]"));
  await click(w, "[data-sreceive]", 50);
  await until(async () => (await one("select state from supply_requests")).state === "received");
  await until(() => /Closed in the last two weeks/.test(txt(w)));
  ok("Received: it leaves the open list", /Closed in the last two weeks.*Received today by Mike B/.test(txt(w)) && /Nothing on order/.test(txt(w)));

  // Wi-Fi drops while logging a defect
  await click(w, '[data-tab="log"]', 50);
  await until(() => !!$(w, '[data-defect="pick"]'));
  setOffline(true);
  await click(w, '[data-defect="pick"]');
  type(w, "[data-jobfilter]", "418"); await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length > 0, 1500);   // the picker was loaded earlier, so sheets are cached
  await click(w, byText(w, "[data-picksheet]", /^\s*2/));
  await click(w, byText(w, "[data-picktype]", /Missed defect/));
  await click(w, "[data-savedefect]", 150);
  ok("no Wi-Fi: the defect waits on the tablet, and says so", /1 entry waiting to send/.test(txt(w)) && /Saved on this tablet/.test(txt(w)));
  ok("...kept in the tablet's storage", Object.keys(JSON.parse(w.localStorage.getItem("sf_logbox"))).length === 1);
  ok("...nothing reached the database", (await one("select count(*)::int n from defects")).n === 1);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => (await one("select count(*)::int n from defects")).n === 2);
  await until(() => /All saved/.test(txt(w)));
  ok("Wi-Fi back: it sends by itself, once, and says All saved", (await one("select count(*)::int n from defects")).n === 2 && /All saved/.test(txt(w)));
  const box = JSON.parse(w.localStorage.getItem("sf_logbox") || "{}");
  ok("sending the same entry again can't double it (its own id)", Object.keys(box).length === 0);
  w.close();

  // ================= Willie: Arrow =================
  w = boot(users.willie);
  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /At Arrow now/.test(txt(w)));
  ok("Metal's log has At Arrow", /At Arrow now.*Nothing at Arrow right now/.test(txt(w)));
  await click(w, "[data-aropen]", 100);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "418"); await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length === 9);
  ok("pick the job, then its nine sheets to tick (no Whole job chip here)", $$(w, "[data-picksheet]").length === 9);
  ok("Send is off until a sheet is ticked or something described", $(w, "[data-arsend]").disabled);
  await click(w, byText(w, "[data-picksheet]", /^\s*6/)); await click(w, byText(w, "[data-picksheet]", /^\s*9/));
  type(w, "#arDesc", "Bases, black");
  await click(w, '[data-arservice="paint"]'); await click(w, '[data-arservice="powdercoat"]');
  await click(w, "[data-arsend]", 50);
  await until(async () => (await one("select count(*)::int n from outside_jobs")).n === 1);
  const oj = await one("select * from outside_jobs");
  ok("sent: sheets 6 and 9, description, powdercoat, today, Willie", JSON.stringify(oj.sheet_numbers) === "[6,9]" && oj.description === "Bases, black" && oj.service === "powdercoat" && oj.sent_by_name === "Willie J");
  await until(() => /0 days out/.test(txt(w)));
  ok("At Arrow now: the item, what went, days out as a plain number", /PROJ-00418.*Powdercoat · sent .* by Willie J.*0 days out.*sheets 6, 9 — Bases, black/.test(txt(w)));
  await admin.query("update outside_jobs set sent_on = sent_on - 5");
  await click(w, '[data-tab="problems"]', 50); await click(w, '[data-tab="log"]', 50);
  await until(() => /5 days out/.test(txt(w)));
  await click(w, "[data-arreturn]"); ok("Mark returned asks to confirm first", /Back from Arrow\?/.test(txt(w)));
  await click(w, "[data-confirm]", 50);
  await until(() => /Returned — last three months/.test(txt(w)));
  ok("returned: under Returned, with a 5-day turnaround", /Returned — last three months.*PROJ-00418.* 5 days · back by Willie J/.test(txt(w)));
  w.close();

  // ================= KP: QC =================
  w = boot(users.kp);
  await until(() => $$(w, ".subtab").length === 4);
  await click(w, '[data-tab="log"]', 150);
  await until(() => /Look up a job/.test(txt(w)) && /At Arrow now/.test(txt(w)));
  ok("Assembly / QC's log has At Arrow and QC", true);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  const qcPick = $$(w, "[data-pickjob]").find(b => /PROJ-00418/.test(b.textContent) && !b.closest(".card").querySelector("#arDesc"));
  await click(w, qcPick, 50);
  await until(() => $$(w, "[data-qcpass]").length === 9);
  ok("QC lookup: PROJ-00418's nine sheets, 'Not checked yet'", $$(w, "[data-qcpass]").length === 9 && /Sheet 1 · TB-03.*Not checked yet/.test(txt(w)));
  await click(w, '[data-qcpass="3"]', 50);
  await until(() => /Passed .* KP/.test(txt(w)));
  ok("sheet 3 passed: shown with KP's name", /Sheet 3 · TB-03 Passed .* · KP/.test(txt(w)));
  await click(w, '.taskrow [data-qcfail="4"]');
  type(w, '[data-mfield="text"]', "Finish scuffed on one corner");
  await click(w, "[data-saveqcfail]", 50);
  await until(async () => (await one("select count(*)::int n from defects where defect_type='Failed QC'")).n === 1);
  ok("sheet 4 failed: a 'Failed QC' defect is logged on it", true);
  w.close();

  // ================= Shawn: Delivery, log-only =================
  w = boot(users.shawn);
  await until(() => $$(w, ".subtab").length > 0);
  ok("Shawn: Problems and Log only — no Work orders, no Supplies", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Problems · Log");
  ok("...and his tablet opens on Problems", $(w, '.subtab[aria-current="true"]').textContent.startsWith("Problems"));
  ok("no counting query is ever made for Delivery", !w.client.log.some(l => l.table === "v_floor_sheets"));
  await click(w, '[data-tab="log"]', 150);
  await until(() => /At Arrow now/.test(txt(w)) && /Defects/.test(txt(w)));
  await click(w, '[data-defect="pick"]');
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]", 50);
  await until(() => /No work order uploaded — this logs against the whole job/.test(txt(w)));
  ok("a job in Delivery with no work order: logs against the whole job", true);
  ok("Delivery's list from the old app (7)", $$(w, "[data-picktype]").length === 7);
  await click(w, byText(w, "[data-picktype]", /Missing product on site/));
  await click(w, "[data-savedefect]", 50);
  await until(async () => (await one("select count(*)::int n from defects where department='delivery' and sheet_number is null")).n === 1);
  ok("'Missing product on site' saved against PROJ-00362, no sheet", true);
  w.close();

  // ================= Test Supervisor =================
  w = boot(users.test);
  await until(() => /Test login/.test(txt(w)));
  ok("Test Supervisor: the test banner, eight department tabs", $$(w, ".tab").length === 8);
  await until(() => /TEST/.test(txt(w)) && /PROJ-00418|00418/.test(txt(w)));
  ok("queue shows the TEST copy only", /TEST-00418/.test(txt(w)) && !$$(w, "button.job").some(b => /PROJ-00099/.test(b.textContent)));
  ok("no real flags leak onto the test queue", !$(w, ".flagtag"));
  await click(w, '[data-tab="supplies"]', 100);
  ok("no real supply requests in the test lane", /Nothing on order/.test(txt(w)));
  w.close();

  // ================= a count still works as before, alongside all this =================
  w = boot(users.mike);
  await until(() => $$(w, "button.job").length === 2);
  await click(w, '[data-tab="work"]', 50);
  await click(w, $$(w, "button.job")[0]); await click(w, `[data-sheet="${s4}"]`, 150);
  await click(w, '[data-step="1"]', 50);
  await until(async () => (await one("select qty_done from sheet_progress where id=$1", [s4])).qty_done === 1);
  ok("counting on the same tablet still saves the number itself", (await one("select source from progress_events where qty_to=1 order by id desc limit 1")).source === "Tablet");
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_office_e2e.js

```javascript
// The office page, end to end against the real test database. Run after test_app_e2e.js
// on the same database (it answers what the floor sent), or on a fresh seeded one.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync("../out/office.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];

function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  w.supabase = { createClient: () => client };
  w.confirm = () => true; w.scrollTo = () => {};
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 3000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 60) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
function type(w, sel, value, ev = "input") { const el = $(w, sel); el.value = value; el.dispatchEvent(new w.Event(ev)); }
async function tab(w, name) { await click(w, `.tab[data-tab="${name}"]`, 30); await until(() => $(w, `.tab[data-tab="${name}"][aria-current="true"]`)); await wait(150); }

(async () => {
  const mike = makeClient(users.mike), willie = makeClient(users.willie);
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  // what the floor has sent
  const pr = (await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Glue line opened on the top overnight.", p_sheet: 7, p_work_stopped: true })).data.id;
  await mike.rpc("flag_problem", { p_job: j099, p_department: "sanding", p_body: "Which grit for the desk edges?" });
  await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: (await one("select id from defect_types where department='sanding' order by sort_order limit 1")).id, p_sheet: 1 });
  const r1 = (await mike.rpc("request_supply", { p_department: "sanding", p_item: "Tack cloths", p_qty: 2 })).data.id;
  const r2 = (await mike.rpc("request_supply", { p_department: "sanding", p_item: "180 grit rolls", p_qty: 1 })).data.id;
  await makeClient(users.test).rpc("request_supply", { p_department: "metal", p_item: "bench wire", p_qty: 1 });
  const ar = (await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6], p_sent_on: "2026-09-01" })).data.id;

  // ---- Luke opens the office on his own computer ----
  const w = boot(users.luke);
  await until(() => /This is my own computer/.test(txt(w)));
  await click(w, "[data-nopin]", 300);
  await until(() => $$(w, ".sum").length > 0);
  ok("eight tabs: Your tasks · Problems · Flags · Ordering · Arrow · Routine tasks · Departments · Setup",
     $$(w, ".tab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Your tasks · Problems · Flags · Ordering · Arrow · Routine tasks · Departments · Setup",
     $$(w, ".tab").map(b => b.textContent).join("|"));
  const sums = () => $$(w, ".sum").map(s => s.querySelector(".n").textContent + " " + s.querySelector(".l").textContent).join(" | ");
  ok("Your tasks: 2 problems waiting, 3 to order, 1 at Arrow over 14 days",
     sums() === "2 problems from the floor waiting for an answer | 3 supply requests to order | 1 item at Arrow over 14 days", sums());
  ok("the handoff list is still there", /Handoffs/.test(txt(w)));

  // ---- Problems ----
  await click(w, '.sum[data-tab="problems"]', 250);
  await until(() => $$(w, ".li").length >= 2);
  const cards = $$(w, ".li");
  ok("work stopped comes first", /PROJ-00418 · sheet 7.*Work stopped.*Waiting for you/.test(cards[0].textContent.replace(/\s+/g, " ")));
  ok("buttons are off until an answer is typed", $(w, `[data-answer="${pr}"]`).disabled);
  type(w, `[data-draft="${pr}"]`, "Looking at it now — hold that sheet.");
  ok("...and on once it is", !$(w, `[data-answer="${pr}"]`).disabled);
  await click(w, `[data-answer="${pr}"][data-close="0"]`, 50);
  await until(async () => (await one("select count(*)::int n from problem_messages where problem_id=$1", [pr])).n === 1);
  await until(() => /You replied — still open/.test(txt(w)));
  ok("Reply, keep it open: still open, marked 'You replied'", /You replied — still open/.test(txt(w)) && (await one("select status from problems where id=$1", [pr])).status === "open");
  type(w, `[data-draft="${pr}"]`, "Remake the top; new blank Monday.");
  await click(w, `[data-answer="${pr}"][data-close="1"]`, 50);
  await until(async () => (await one("select status from problems where id=$1", [pr])).status === "answered");
  await until(() => /Answered in the last 30 days \(1\)/.test(txt(w)));
  ok("Answer and close: it moves to Answered, and the database agrees", /Answered in the last 30 days \(1\)/.test(txt(w)));
  ok("the tablet sees the answer under Luke's name", (await mike.from("v_problems").select("*").eq("id", pr)).data[0].thread.at(-1).by === "Luke H");
  ok("defects logged, by department: Sanding 1 this month", /Sanding — 1/.test(txt(w)));

  // ---- Flags ----
  await tab(w, "flags");
  await until(() => $$(w, "#ffJob option").length > 2);
  ok("the job list includes the test copy, labelled", $$(w, "#ffJob option").some(o => /^TEST · TEST-00418/.test(o.textContent)));
  type(w, "#ffJob", j418, "change");
  ok("Set is off without a note", $(w, "[data-setflag]").disabled);
  await click(w, '[data-fflevel="critical"]');
  type(w, "#ffNote", "Customer on site Thursday — tops through finishing Wednesday");
  await click(w, "[data-setflag]", 50);
  await until(async () => (await one("select count(*)::int n from flags where cleared_at is null")).n === 1);
  await until(() => /Critical flag on PROJ-00418/.test(txt(w)));
  ok("critical flag set: the plain answer at the top, the flag listed with the note and who", /Critical flag on PROJ-00418/.test(txt(w)) && /Open flags Critical PROJ-00418.*whole job.*Customer on site Thursday.*Set by Luke H/.test(txt(w)));
  await admin.query("update flags set set_at = now() - interval '16 days'");
  await tab(w, "tasks");
  await until(() => /flag older than 14 days/.test(txt(w)));
  ok("a flag over two weeks old is raised on Your tasks", /1 flag older than 14 days — still right\?/.test(sums()), sums());
  await tab(w, "flags");
  ok("...and marked on the Flags tab", /over two weeks: still right\?/.test(txt(w)));
  await click(w, "[data-clearflag]", 50);
  await until(async () => (await one("select count(*)::int n from flags where cleared_at is null")).n === 0);
  await until(() => /Cleared in the last 30 days \(1\)/.test(txt(w)));
  ok("Clear it: off the open list, kept under Cleared with both names", /No open flags/.test(txt(w)) && /Cleared in the last 30 days \(1\)/.test(txt(w)));

  // ---- Ordering ----
  await tab(w, "ordering");
  await until(() => $$(w, "[data-otick]").length === 3);
  ok("Need to order: one line per request, by department, test line labelled", /Need to order Sanding.*Tack cloths.*180 grit rolls.*Metal.*TEST bench wire/.test(txt(w)));
  ok("the button waits for a tick", $(w, "[data-order]").disabled);
  const box = $(w, `[data-otick="${r1}"]`); box.checked = true; box.dispatchEvent(new w.Event("change")); await wait(30);
  ok("tick one: 'Mark 1 ticked as ordered'", /Mark 1 ticked as ordered/.test($(w, "[data-order]").textContent) && !$(w, "[data-order]").disabled);
  await click(w, "[data-order]", 50);
  await until(async () => (await one("select state from supply_requests where id=$1", [r1])).state === "ordered");
  await until(() => /Ordered, not received.*Tack cloths/.test(txt(w)));
  ok("it moves to Ordered, not received — 'Ordered today by Luke H'", /Ordered, not received.*Tack cloths.*Ordered today by Luke H/.test(txt(w)));
  await click(w, `[data-noopen="${r2}"]`);
  type(w, "[data-noreason]", "We have 3 rolls in the back");
  await click(w, `[data-nosave="${r2}"]`, 50);
  await until(async () => (await one("select state from supply_requests where id=$1", [r2])).state === "not_ordering");
  ok("Not ordering, with the reason the department will see", (await one("select not_ordering_reason r from supply_requests where id=$1", [r2])).r === "We have 3 rolls in the back");
  await click(w, `[data-oreceive="${r1}"]`, 50);
  await until(async () => (await one("select state from supply_requests where id=$1", [r1])).state === "received");
  await until(() => /Closed in the last 60 days \(2\)/.test(txt(w)));
  ok("the office can mark it received too; both show under Closed", /Closed in the last 60 days \(2\)/.test(txt(w)));

  // ---- Arrow ----
  await tab(w, "arrow");
  await until(() => $(w, "[data-arret]"));
  ok("At Arrow now: days out as a number, flagged as over 14 days", /At Arrow now.*PROJ-00418.*sheet 6.*Powdercoat · sent Sep 1 by Willie J \(Metal\).*over 14 days/.test(txt(w)));
  type(w, "#arDays", "30");
  await click(w, "[data-ardays]", 50);
  await until(async () => (await one("select value::text v from app_settings where key='arrow_alert_days'")).v === "30");
  await until(() => /more than 30 days/.test(txt(w)));
  ok("the TV threshold saves: 30 days", /The TV now shows anything at Arrow for more than 30 days/.test(txt(w)));
  await click(w, `[data-arret="${ar}"]`, 50);
  await until(async () => !!(await one("select returned_on from outside_jobs where id=$1", [ar])).returned_on);
  ok("Mark returned from the office works too", /Returned in the last three months \(1\)/.test(txt(w)) || await until(() => /Returned in the last three months \(1\)/.test(txt(w))));

  // ---- Routine tasks ----
  await tab(w, "routine");
  await until(() => $$(w, "#tfWho option").length > 1);
  ok("assignees: real people only (no Test Supervisor) until 'test task' is ticked", !$$(w, "#tfWho option").some(o => /Test Supervisor/.test(o.textContent)) && $$(w, "#tfWho option").some(o => /Mike B/.test(o.textContent)));
  type(w, "#tfName", "Clean spray booth filters");
  type(w, "#tfDept", "finishing", "change");
  type(w, "#tfType", "monthly", "change"); await wait(30);
  ok("monthly swaps 'every N weeks' for 'which one in the month'", !!$(w, "#tfOcc") && !$(w, "#tfEvery"));
  type(w, "#tfOcc", "-1", "change"); type(w, "#tfDay", "2", "change");
  await click(w, "[data-addtask]", 50);
  await until(async () => (await one("select count(*)::int n from routine_tasks where name='Clean spray booth filters'")).n === 1);
  await until(() => /Last Tuesday of every month/.test(txt(w)));
  ok("added: listed under Finishing, 'Last Tuesday of every month', anyone in Finishing", /Finishing Clean spray booth filters Last Tuesday of every month · anyone in Finishing/.test(txt(w)));
  await click(w, "[data-retiretask]", 50);
  await until(async () => (await one("select active from routine_tasks where name='Clean spray booth filters'")).active === false);
  ok("Remove: off the list, kept in the database", true);

  // ---- Departments ----
  await tab(w, "departments");
  await until(() => /Log-only/.test(txt(w)));
  ok("Delivery is listed as log-only, with no live switch", /Delivery Log-only/.test(txt(w)) && !$(w, '[data-live="delivery"]') && $$(w, "[data-live]").length === 7);

  // ---- Setup: TV link, defect lists ----
  await tab(w, "setup");
  await until(() => /TV link/.test(txt(w)));
  ok("no TV link yet", /No TV link has been made yet/.test(txt(w)));
  await click(w, "[data-tvnew]", 50);
  await until(() => $(w, "#tvUrl"));
  const url = $(w, "#tvUrl").textContent;
  ok("the TV link is shown once: tv.html next to this page, secret after the #", /^https:\/\/lukehart1228\.github\.io\/shop-floor\/tv\.html#k=[0-9a-f]{64}$/.test(url), url);
  const key = url.split("#k=")[1];
  ok("...and it works for the TV", (await makeClient(null).rpc("tv_snapshot", { p_key: key })).data.ok === true);
  fs.writeFileSync("/tmp/tv_key.txt", key);
  await click(w, 'details.more summary', 10);
  const add = $(w, '[data-newtype="sanding"]'); add.value = "Burn marks";
  await click(w, '[data-typeadd="sanding"]', 50);
  await until(async () => (await one("select count(*)::int n from defect_types where label='Burn marks'")).n === 1);
  ok("add 'Burn marks' to Sanding's defect list", true);
  await until(() => $$(w, '[data-typeset="sanding"]').length === 4);
  await click(w, $$(w, '[data-typeset="sanding"]').find(b => b.dataset.label === "Burn marks"), 50);
  await until(async () => (await one("select active from defect_types where label='Burn marks'")).active === false);
  ok("retire it: off the tablets, still in the database", true);
  ok("the test-job and catch-up sections are still on Setup", /Test jobs/.test(txt(w)) && /Catch up from Monday/.test(txt(w)));
  w.close();

  // ---- a supervisor is still turned away ----
  const w2 = boot(users.mike);
  await until(() => /is a supervisor login/.test(txt(w2)));
  ok("Mike is turned away from the office view", /Mike B is a supervisor login/.test(txt(w2)));
  w2.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_tv.js

```javascript
// The floor TV: its core, and the page against the real test database with no login.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const html = fs.readFileSync("../out/tv.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
fs.writeFileSync("/tmp/tv_core.js", [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
const C = require("/tmp/tv_core.js");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
async function until(fn, ms = 3000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }

function boot(hash, { preload = {} } = {}) {
  const client = makeClient(null);                 // no login, as on the real TV
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/tv.html" + hash });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.supabase = { createClient: () => client };
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  w.client = client;
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");

(async () => {
  // ---- core ----
  ok("key read from #k=…", C.tvKey("#k=abc123", null) === "abc123");
  ok("...or from what this screen remembered", C.tvKey("", "zzz") === "zzz" && C.tvKey("", null) === null);
  const now = Date.now();
  ok("fresh numbers: ok", C.freshness(now - 5000, now, false) === "ok");
  ok("a failed refresh within 90 s: reconnecting, numbers kept", C.freshness(now - 40000, now, true) === "reconnecting");
  ok("no good numbers for over 90 s: hidden", C.freshness(now - 91000, now, true) === "lost");
  const m = C.tvModel({ live: [{ key: "sanding", name: "Sanding", left: 24, ready: 15, jobs: 2 }], kpis: { jobs: 2, left: 24, ready: 15, due14: 0 },
                        donut: { finished: 5, ready: 15, total: 29 }, table: [], critical: [], attention: [] });
  ok("one live department: 'Pieces left in Sanding'", m.kpis[1].l === "Pieces left in Sanding" && m.showing === "Sanding");
  ok("donut: finished 5, ready 15, waiting 9, 17%", m.donut.waiting === 9 && m.donut.pct === 17);

  // ---- the page ----
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const luke = makeClient(users.luke);
  const key = (await luke.rpc("new_tv_link", {})).data.key;

  let w = boot("");
  ok("no link: it says how to get one, and asks the database nothing", /needs the TV link/.test(txt(w)) && w.client.rpcs.length === 0);
  w.close();
  w = boot("#k=0000");
  await until(() => /doesn't work any more/.test(txt(w)));
  ok("a wrong link: a plain message, no numbers", /doesn't work any more.*Setup → TV link/.test(txt(w)) && !/PROJ/.test(txt(w)));
  w.close();

  await luke.rpc("set_flag", { p_job: j418, p_level: "critical", p_note: "Customer on site Thursday" });
  await makeClient(users.mike).rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Crack along the glue line", p_sheet: 7, p_work_stopped: true });
  await makeClient(users.test).rpc("flag_problem", { p_job: (await one("select id from jobs where project_id='TEST-00418'")).id, p_department: "sanding", p_body: "bench stop", p_sheet: 1, p_work_stopped: true });
  w = boot("#k=" + key);
  await until(() => /Production Floor/.test(txt(w)));
  const t = txt(w);
  ok("the right link: 'Showing: Sanding'", /Showing: Sanding/.test(t));
  ok("the secret is taken out of the address bar, and remembered on this screen", w.location.hash === "" && w.localStorage.getItem("sftv_key") === key);
  ok("four tiles: 2 jobs, 24 pieces left in Sanding, 15 ready, 0 due in 14 days",
     [...w.document.querySelectorAll(".kpi")].map(k => k.querySelector(".kv").textContent + " " + k.querySelector(".kl").textContent).join(" | ")
       === "2 Jobs on the floor | 24 Pieces left in Sanding | 15 Ready to work on now | 0 Due inside 14 days");
  const crit = w.document.querySelector(".crit");
  ok("the critical flag has its own band", crit && crit.querySelector("b").textContent === "CRITICAL" && crit.querySelector(".t").textContent === "PROJ-00418 — Customer on site Thursday");
  ok("the table: soonest first, a Sanding column with done / total, the flag marked", /00099 Oaks Academy Q01092 0 \/ 9.*00418 Enid's Table.*Critical 5 \/ 20/.test(t), t.slice(t.indexOf("Next"), t.indexOf("Next") + 200));
  const att = [...w.document.querySelectorAll(".attn span")].map(x => x.textContent);
  ok("work stopped shows on the attention strip — the real one, not the test one", att.includes("PROJ-00418 sheet 7 · Sanding: Crack along the glue line") && !/bench stop/.test(t), att.join(" | "));
  ok("no test job anywhere", !/TEST/.test(t));
  ok("no Delivery column (log-only)", !/Delivery/.test(t));

  await luke.rpc("set_department_live", { p_department: "finishing", p_live: true });
  w.close();

  w = boot("", { preload: { sftv_key: key } });
  await until(() => /Showing: Sanding · Finishing/.test(txt(w)));
  ok("a plain reload works from the remembered link; Finishing now live too", /Showing: Sanding · Finishing/.test(txt(w)));
  ok("...with a column per live department", [...w.document.querySelectorAll("th")].map(x => x.textContent).join(",") === "Due,Days,Project,Job,Sanding,Finishing");
  w.close();

  await luke.rpc("new_tv_link", {});
  w = boot("", { preload: { sftv_key: key } });
  await until(() => /doesn't work any more/.test(txt(w)));
  ok("after a new link is made, the old screen stops showing numbers", /doesn't work any more/.test(txt(w)));
  ok("...and forgets the old secret", w.localStorage.getItem("sftv_key") === null);
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### snap.js

```javascript
// Drive the real pages in jsdom against the test database, save each screen's
// rendered HTML (scripts removed), then photograph them in Chromium.
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const OUT = "/home/claude/sf/snaps"; fs.mkdirSync(OUT, { recursive: true });

function boot(file, user, url, preload = {}) {
  const html = fs.readFileSync(file, "utf8").replace(/<script src="[^"]+"><\/script>/, "");
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "data:image/png;base64,"; w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
function save(w, name) {
  const doc = w.document.documentElement.cloneNode(true);
  doc.querySelectorAll("script").forEach(s => s.remove());
  fs.writeFileSync(`${OUT}/${name}.html`, "<!DOCTYPE html>" + doc.outerHTML);
}
const $ = (w, s) => w.document.querySelector(s);
const click = async (w, s, p = 250) => { const el = typeof s === "string" ? $(w, s) : s; el.click(); await wait(p); };

(async () => {
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  const luke = makeClient(users.luke), mike = makeClient(users.mike), willie = makeClient(users.willie);
  await luke.rpc("set_flag", { p_job: j099, p_level: "priority", p_note: "Customer walkthrough Thursday — desks through sanding Wednesday" });
  await luke.rpc("set_flag", { p_job: j418, p_level: "watch", p_note: "Base colour may change" });
  await luke.rpc("add_routine_task", { p_name: "Replace wide belt paper", p_department: "sanding", p_schedule_type: "weekly", p_weekday: 1, p_week_interval: 1, p_start_date: "2026-09-01", p_assigned_to: users.mike.id });
  await luke.rpc("add_routine_task", { p_name: "Blow out sanding room filters", p_department: "sanding", p_schedule_type: "monthly", p_weekday: 3, p_monthly_occurrence: -1, p_start_date: "2026-10-01" });
  const t = (l) => one("select id from defect_types where label=$1", [l]).then(r => r.id);
  await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: await t("Caused defect — caught before finish"), p_sheet: 4, p_note: "Cross-grain scratch, resanded" });
  await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: await t("Missed defect — caught after finish"), p_sheet: 2 });
  const p = (await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Top has a crack along the glue line. Reglue or remake?", p_sheet: 4, p_work_stopped: true })).data.id;
  await luke.rpc("answer_problem", { p_problem: p, p_body: "Looking now — hold that sheet.", p_close: false });
  await mike.rpc("flag_problem", { p_job: j099, p_department: "sanding", p_body: "Which grit for the desk edges?" });
  const r = (await mike.rpc("request_supply", { p_department: "sanding", p_item: "120 grit discs, 6 inch, hook and loop", p_qty: 4 })).data.id;
  await mike.rpc("request_supply", { p_department: "sanding", p_item: "Tack cloths", p_qty: 2, p_note: "the yellow ones" });
  await luke.rpc("order_supplies", { p_requests: [r] });
  await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6, 9], p_description: "Bases, denim black", p_sent_on: "2026-09-08" });
  await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "paint", p_description: "8 brackets", p_sent_on: "2026-09-21" });

  const T = "https://lukehart1228.github.io/shop-floor/";
  let w = boot("../out/index.html", users.mike, T + "index.html");
  await until(() => /PROJ-00418/.test(w.document.body.textContent) && $(w, ".flagtag")); await wait(300);
  save(w, "tablet-1-queue");
  const s4 = (await one("select sp.id from sheet_progress sp join sheets s on s.id=sp.sheet_id join work_orders wo on wo.id=s.work_order_id where wo.job_id=$1 and s.sheet_number=4 and sp.department='sanding'", [j418])).id;
  await click(w, `[data-job="${j418}"]`); await click(w, `[data-sheet="${s4}"]`, 600);
  save(w, "tablet-2-sheet");
  await click(w, '[data-defect="here"]');
  save(w, "tablet-3-defect");
  w.document.querySelector(".ovl").click(); await wait(100);
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]');
  await click(w, '[data-tab="problems"]', 500); save(w, "tablet-4-problems");
  await click(w, '[data-tab="log"]', 500); save(w, "tablet-5-log");
  await click(w, '[data-tab="supplies"]', 500); save(w, "tablet-6-supplies");
  w.close();
  w = boot("../out/index.html", users.willie, T + "index.html");
  await until(() => $(w, '[data-tab="log"]')); await click(w, '[data-tab="log"]', 600);
  await click(w, "[data-aropen]", 400);
  const f = $(w, "[data-jobfilter]"); f.value = "418"; f.dispatchEvent(new w.Event("input")); await wait(100);
  await click(w, "[data-pickjob]", 400);
  $$ = (s) => [...w.document.querySelectorAll(s)];
  await click(w, $$("[data-picksheet]")[5], 80);
  save(w, "tablet-7-arrow");
  w.close();
  w = boot("../out/index.html", users.shawn, T + "index.html");
  await until(() => $(w, ".subtab")); await click(w, '[data-tab="log"]', 600);
  save(w, "tablet-8-delivery");
  w.close();

  w = boot("../out/office.html", users.luke, T + "office.html", { sfo_pin: JSON.stringify({ none: true }) });
  await until(() => $(w, ".sum")); await wait(300);
  save(w, "office-1-tasks");
  await click(w, '.tab[data-tab="problems"]', 600); save(w, "office-2-problems");
  await click(w, '.tab[data-tab="flags"]', 600); save(w, "office-3-flags");
  await click(w, '.tab[data-tab="ordering"]', 600); save(w, "office-4-ordering");
  await click(w, '.tab[data-tab="arrow"]', 600); save(w, "office-5-arrow");
  await click(w, '.tab[data-tab="routine"]', 600); save(w, "office-6-routine");
  w.close();

  await makeClient(users.luke).rpc("set_flag", { p_job: j418, p_level: "critical", p_note: "Customer on site Thursday — tops through finishing Wednesday" });
  const key = (await luke.rpc("new_tv_link", {})).data.key;
  w = boot("../out/tv.html", null, T + "tv.html#k=" + key);
  await until(() => $(w, ".kpi")); await wait(200);
  save(w, "tv-1");
  w.close();
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
var $$;
```

#### shoot.js

```javascript
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" }).catch(async () => chromium.launch());
  const fs = require("fs");
  for (const f of fs.readdirSync("../snaps").filter(x => x.endsWith(".html"))) {
    const tv = f.startsWith("tv");
    const office = f.startsWith("office");
    const pg = await b.newPage({ viewport: tv ? { width: 1920, height: 1080 } : office ? { width: 1280, height: 900 } : { width: 1200, height: 1800 } });
    await pg.goto("file:///home/claude/sf/snaps/" + f); await pg.waitForTimeout(600);
    await pg.screenshot({ path: "../snaps/" + f.replace(".html", ".png"), fullPage: !tv });
    await pg.close();
  }
  await b.close();
})();
```
