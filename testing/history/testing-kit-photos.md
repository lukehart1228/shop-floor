# Testing kit, Part 3 — photos

*For build chats. Luke doesn't need to read this.* Parts 1 and 2 are in `testing-kit.md` and still apply (environment, "test as a real login", jsdom gaps). This part adds what the photos build (23 Sep) was tested with. Re-run the relevant suites before handing over any changed file.

### What changed in the setup

- **One stub file**, `stubs.sql`, replaces the kit's three. `storage.objects` gains `owner`, `owner_id`, `metadata` and a unique `(bucket_id, name)`; `storage.buckets` gains `file_size_limit` and `allowed_mime_types`, as real Supabase has them. `auth.users` has `email`.
- **`pgsupa.js` now does storage too**: `upload`, `download`, `remove` and `createSignedUrl` run against `storage.objects` **as the login** (RLS applies), honour the bucket's size and type limits, and keep the bytes in memory (`files`). Uploading an existing name answers "The resource already exists" (409), like Supabase. `remove` silently skips what the login may not delete, like Supabase.
- **`load.sh` loads the step 1–9 files from `base/`.** In this chat they were copied from `sql-files.md` without their comments, and the Monday-calling functions were left out (`office_min.sql`, `catch_up_min.sql`, `upload_min.sql`). In a new chat, take them from `sql-files.md` the same way. `check_floor()` gave 18/18 on that database, before and after `photos.sql`.
- **jsdom needs**: `fake-indexeddb` (the tablet keeps waiting photos in IndexedDB), `w.TextEncoder = TextEncoder` and `w.Blob = Blob` (the office zip). The camera is stood in for with `window.sfShrinkPhoto` — the page's only test hook; it replaces the shrink step, and everything after it is real. The real shrink is tested in Chromium instead (`test_shrink_chromium.js`).
- **`textContent` runs adjacent elements together** (Part 1 warned). Twice it hid a real screen: the load-out count and the batch list now have a space between their parts.
- `test_app_e2e.js` and `test_office_e2e.js` (Part 2's, retyped) take `PHOTOS=1`, which switches on the three expectations that changed on purpose: Delivery's areas are *Load-out · Problems · Log* and it opens on Load-out; the office has a *Photos* tab.
- **Direct SQL deletes on `storage.objects`:** newer Supabase may refuse them ("Direct deletion from storage tables is not allowed"). `check_photos()` sets `storage.allow_delete_query` first, and if the delete is still refused it falls back to checking the rule itself (`photo_file_released()`), so the check can't fail for that reason alone.
- **Two batches made in one transaction** got the same `now()`, so the older one never released. `made_at` now defaults to `clock_timestamp()`. `check_photos()` row 15 caught it.

### Results when delivered (23 Sep)

| Suite | Result |
|---|---|
| `check_photos()` on the stand-in, loaded twice | 16 PASS, nothing left behind |
| `check_photos()` against 8 deliberate breaks (`breaks.py`) | each caught, at its own row |
| `check_floor()` after `photos.sql` | 18 PASS |
| `test_app_e2e.js` (Part 2's tablet suite, `PHOTOS=1`) on the new `index.html` | 67 PASS |
| `test_office_e2e.js` (Part 2's office suite, `PHOTOS=1`) on the new `office.html` | 37 PASS |
| `test_photos_e2e.js` — tablet photos and load-outs against the database | 41 PASS |
| `test_office_photos.js` — office photos and the archive; zips checked with `unzip -t` and Python's `zipfile` | 27 PASS |
| `test_shrink_chromium.js` — the real `shrinkPhoto()` in Chromium on 4000×3000 JPEGs (plain, EXIF-rotated, pure noise) | 3 PASS: 105, 106 and 377 KB; portrait comes out 1200×1600 |

Run order: `cd t && ../base/fresh.sh ../out/photos.sql && node <suite>.js`. A fresh database for each suite.

Not covered: a real Android camera, real Supabase Storage, and the real SQL Editor. Walkthrough 7's bench steps cover those.

---

### Files (Part 3)

#### stubs.sql
```sql
-- enough of Supabase to test RLS honestly (testing kit stubs, combined; storage gets owner/metadata and bucket limits for photos)
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid $$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
do $$ begin create role authenticator login noinherit; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to authenticator;
grant usage on schema public, auth to service_role;
alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text,
  owner uuid, owner_id text, metadata jsonb, created_at timestamptz default now(), unique (bucket_id, name));
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, description from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text, new_description text default '') returns uuid
  language sql as $$ insert into vault.secrets (name, secret, description) values (new_name, new_secret, new_description) returning id $$;
revoke all on schema vault from anon, authenticated;
```

#### people.sql
```sql
insert into auth.users (id, email) values
 ('11111111-1111-1111-1111-111111111111','sanding@pdindy.com'), ('22222222-2222-2222-2222-222222222222','lukehart@pdindy.com'),
 ('33333333-3333-3333-3333-333333333333','test@pdindy.com'), ('44444444-4444-4444-4444-444444444444','donnie@pdindy.com'),
 ('55555555-5555-5555-5555-555555555555','willie@pdindy.com'), ('66666666-6666-6666-6666-666666666666','kp@pdindy.com'),
 ('77777777-7777-7777-7777-777777777777','shawn@pdindy.com'), ('88888888-8888-8888-8888-888888888888','ddart@pdindy.com')
on conflict do nothing;
insert into profiles (id, full_name, role, departments) values
  ('11111111-1111-1111-1111-111111111111','Mike B','supervisor','{sanding,finishing}'),
  ('22222222-2222-2222-2222-222222222222','Luke H','manager','{}'),
  ('44444444-4444-4444-4444-444444444444','Donnie E','supervisor','{milling,cnc}'),
  ('55555555-5555-5555-5555-555555555555','Willie J','supervisor','{metal}'),
  ('66666666-6666-6666-6666-666666666666','KP','supervisor','{assembly_qc}'),
  ('88888888-8888-8888-8888-888888888888','David D','manager','{}')
on conflict do nothing;
```

#### seed.sql
```sql
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

#### load.sh
```bash
#!/bin/bash
# rebuild the 'sync' test database the way Luke's is, then load any extra files given as arguments (each twice)
set -e
P="psql -h /tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists sync with (force)" -c "create database sync" >/dev/null
cd /home/claude/sf/base
$P -d sync -f stubs.sql
$P -d sync -c "create extension pg_cron;" >/dev/null
for f in schema.sql upload_min.sql office_min.sql test_lane.sql catch_up_min.sql problems.sql flags.sql routine_tasks.sql supplies.sql arrow_qc.sql tv.sql; do $P -d sync -f $f; $P -d sync -f $f; done
$P -d sync -f people.sql
$P -d sync -c "select set_person('test@pdindy.com','Test Supervisor','supervisor','{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc,delivery}',true)" >/dev/null
$P -d sync -f check_floor.sql
for f in "$@"; do echo "== loading $f (twice)"; $P -d sync -f "$f"; $P -d sync -f "$f"; done
echo LOADED
```

#### fresh.sh
```bash
#!/bin/bash
cd /home/claude/sf/base
./load.sh "$@" >/tmp/load.out 2>&1 || { echo LOAD FAILED; grep -i -B2 -A3 error /tmp/load.out | head -30; exit 1; }
psql -h /tmp/pg -p 5433 -U postgres -d sync -q -v ON_ERROR_STOP=1 -f seed.sql >/tmp/seed.out 2>&1 || { echo SEED FAILED; cat /tmp/seed.out | head; exit 1; }
echo SEEDED
```

#### pgsupa.js
```javascript
// A stand-in for supabase-js that talks to the real test database the way
// Supabase's API does: connect as `authenticator`, switch to the login's
// role, set the JWT claims, run the statement. So row-level security,
// column grants and every database check apply exactly as on the tablet.
// Storage is emulated the same way: every upload / download / remove runs
// against storage.objects AS THE LOGIN, so the bucket's policies decide.
const { Pool, types } = require("pg");
types.setTypeParser(1082, v => v);          // dates stay "YYYY-MM-DD", as PostgREST sends them
types.setTypeParser(20, v => Number(v));     // counts as numbers
const pool = new Pool({ host: "/tmp/pg", port: 5433, database: "sync", user: "authenticator", max: 4 });
const admin = new Pool({ host: "/tmp/pg", port: 5433, database: "sync", user: "postgres", max: 2 });

const q = (s) => '"' + s.replace(/"/g, '""') + '"';
let offline = false;                     // flip to simulate the Wi-Fi dropping
const netErr = () => ({ data: null, error: { message: "TypeError: Failed to fetch" } });
const files = new Map();                 // "bucket/path" -> Buffer: the bytes storage would hold

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

function norm(row) {
  const o = {};
  for (const [k, v] of Object.entries(row)) o[k] = v instanceof Date ? v.toISOString() : v;
  return o;
}

async function toBuffer(body) {
  if (Buffer.isBuffer(body)) return body;
  if (body && typeof body.arrayBuffer === "function") return Buffer.from(await body.arrayBuffer());
  if (body instanceof ArrayBuffer) return Buffer.from(body);
  return Buffer.from(String(body));
}

function storageFor(client, bucket) {
  const key = (path) => bucket + "/" + path;
  return {
    async upload(path, body, opts = {}) {
      if (offline) return netErr();
      const buf = await toBuffer(body);
      const type = opts.contentType || (body && body.type) || "application/octet-stream";
      const b = (await admin.query("select * from storage.buckets where id = $1", [bucket])).rows[0];
      if (!b) return { data: null, error: { message: "Bucket not found", statusCode: "404" } };
      if (b.file_size_limit && buf.length > Number(b.file_size_limit))
        return { data: null, error: { message: "The object exceeded the maximum allowed size", statusCode: "413" } };
      if (b.allowed_mime_types && b.allowed_mime_types.length && !b.allowed_mime_types.includes(type))
        return { data: null, error: { message: `mime type ${type} is not supported`, statusCode: "415" } };
      client.uploads.push(path);
      const r = await runAs(client.user,
        "insert into storage.objects (bucket_id, name, owner, owner_id, metadata) values ($1, $2, $3, $4, $5)",
        [bucket, path, client.user ? client.user.id : null, client.user ? client.user.id : null,
         JSON.stringify({ size: buf.length, mimetype: type })]);
      if (r.error) {
        if (r.error.code === "23505") return { data: null, error: { message: "The resource already exists", statusCode: "409", error: "Duplicate" } };
        return { data: null, error: { message: "new row violates row-level security policy", statusCode: "403" } };
      }
      files.set(key(path), buf);
      return { data: { path }, error: null };
    },
    async download(path) {
      if (offline) return netErr();
      const r = await runAs(client.user, "select name from storage.objects where bucket_id = $1 and name = $2", [bucket, path]);
      if (bucket === "work-orders") return { data: new Blob(["png"], { type: "image/png" }), error: null };   // sheet pages: never uploaded here
      if (r.error || !r.data.length) return { data: null, error: { message: "Object not found", statusCode: "404" } };
      const buf = files.get(key(path)) || Buffer.from("jpg");
      return { data: new Blob([buf], { type: "image/jpeg" }), error: null };
    },
    async remove(paths) {
      if (offline) return netErr();
      const r = await runAs(client.user, "delete from storage.objects where bucket_id = $1 and name = any($2) returning name", [bucket, paths]);
      if (r.error) return { data: null, error: { message: r.error.message } };
      for (const x of r.data) files.delete(key(x.name));
      return { data: r.data.map(x => ({ name: x.name })), error: null };   // like Storage: silently skips what you may not delete
    },
    async createSignedUrl(path) {
      if (offline) return netErr();
      if (bucket === "work-orders") return { data: { signedUrl: "https://abc.supabase.co/signed.pdf" }, error: null };
      const r = await runAs(client.user, "select name from storage.objects where bucket_id = $1 and name = $2", [bucket, path]);
      if (r.error || !r.data.length) return { data: null, error: { message: "Object not found", statusCode: "404" } };
      return { data: { signedUrl: "https://abc.supabase.co/storage/v1/object/sign/" + bucket + "/" + path + "?token=t" }, error: null };
    },
  };
}

function makeClient(startUser = null) {
  const client = { user: startUser, log: [], rpcs: [], uploads: [] };
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
  client.storage = { from: (bucket) => storageFor(client, bucket) };
  return client;
}

module.exports = { makeClient, admin, pool, files, setOffline: (v) => { offline = v; },
  users: { mike: { id: "11111111-1111-1111-1111-111111111111", email: "sanding@pdindy.com" },
           luke: { id: "22222222-2222-2222-2222-222222222222", email: "lukehart@pdindy.com" },
           test: { id: "33333333-3333-3333-3333-333333333333", email: "test@pdindy.com" },
           donnie: { id: "44444444-4444-4444-4444-444444444444", email: "donnie@pdindy.com" },
           willie: { id: "55555555-5555-5555-5555-555555555555", email: "willie@pdindy.com" },
           kp: { id: "66666666-6666-6666-6666-666666666666", email: "kp@pdindy.com" },
           shawn: { id: "77777777-7777-7777-7777-777777777777", email: "shawn@pdindy.com" },
           david: { id: "88888888-8888-8888-8888-888888888888", email: "ddart@pdindy.com" } } };
```

#### test_photos_e2e.js
```javascript
// Photos on the tablet, end to end: the real index.html in jsdom, against the real test
// database through the login path Supabase uses, with storage run as the login too.
// The camera is stood in for (sfShrinkPhoto); everything after it is the real code.
// Run on a fresh database with photos.sql: ../base/fresh.sh ../out/photos.sql && node test_photos_e2e.js
const fs = require("fs");
const { JSDOM } = require("jsdom");
const fidb = require("fake-indexeddb");
const { makeClient, admin, users, setOffline, files } = require("./pgsupa");
const html = fs.readFileSync(process.env.APP || "../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
const all = async (sql, p = []) => (await admin.query(sql, p)).rows;
let shotSize = 350000;

function boot(user, { idb } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  w.indexedDB = idb || new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client };
  w.Blob = Blob; w.URL.createObjectURL = () => "blob:local-preview"; w.URL.revokeObjectURL = () => {};
  w.print = () => {}; w.open = () => {}; w.scrollTo = () => {}; w.confirm = () => true;
  w.sfShrinkPhoto = async () => ({ blob: new Blob([Buffer.alloc(shotSize, 7)], { type: "image/jpeg" }), width: 1600, height: 1200 });
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
async function snap(w) {             // the person takes the photo
  const cam = w.document.getElementById("camera");
  Object.defineProperty(cam, "files", { value: [new w.File(["x"], "IMG_0001.jpg", { type: "image/jpeg" })], configurable: true });
  cam.dispatchEvent(new w.Event("change")); await wait(120);
}

(async () => {
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j362 = (await one("select id from jobs where project_id='PROJ-00362'")).id;
  // PROJ-00362 is in Delivery; give it a 4-sheet work order for the load-out
  await admin.query(`do $$ declare w uuid; s uuid; i int; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    for i in 1..4 loop insert into sheets (work_order_id, sheet_number, qty, item_code, pdf_uploaded_at) values (w, i, 2, 'TR-0'||i, now()) returning id into s;
      insert into sheet_progress (sheet_id, department, qty_required, qty_done) values (s, 'assembly_qc', 2, 2); end loop; end $$;`);
  const luke = makeClient(users.luke);

  // ================= Mike: a defect with a photo =================
  let w = boot(users.mike);
  await until(() => /PROJ-00418/.test(txt(w)));
  await click(w, `[data-job="${j418}"]`);
  const s4 = (await one("select sp.id from sheet_progress sp join sheets s on s.id=sp.sheet_id join work_orders wo on wo.id=s.work_order_id where wo.job_id=$1 and s.sheet_number=4 and sp.department='sanding'", [j418])).id;
  await click(w, `[data-sheet="${s4}"]`, 150);
  await click(w, '[data-defect="here"]');
  ok("defect form: an optional 'Add a photo' button", /Add a photo optional/.test(txt(w)) && !!$(w, "[data-addshot]"));
  await click(w, byText(w, "[data-picktype]", /Caused defect — caught before finish/));
  ok("Log it works without a photo (logging stays one tap after the type)", !$(w, "[data-savedefect]").disabled);
  await click(w, "[data-addshot]"); await snap(w);
  ok("after the camera: the photo shows in the form, with a remove button", $$(w, ".mdl .ph").length === 1 && !!$(w, "[data-dropshot]"));
  ok("...and says 1 of 3", /optional · 1 of 3/.test(txt(w)));
  await click(w, "[data-savedefect]", 50);
  await until(async () => (await one("select count(*)::int n from photos")).n === 1, 4000);
  const ph = await one("select p.*, d.sheet_number dsheet from photos p join defects d on d.id = p.defect_id");
  ok("in the database: a photo on the defect, sheet 4, sanding, Mike, 350 KB", ph && ph.kind === "defect" && ph.sheet_number === 4 && ph.department === "sanding" && ph.taken_by_name === "Mike B" && Number(ph.bytes) === 350000,
     JSON.stringify(ph && { k: ph.kind, s: ph.sheet_number, b: ph.bytes }));
  ok("the file is in storage, in the job's folder, named by the photo's own id", ph && ph.storage_path === `PROJ-00418/${ph.client_id}.jpg` && files.has("photos/" + ph.storage_path));
  await until(() => $$(w, ".phs img[data-photopath]").length === 1 && $(w, ".phs img[data-photopath]").getAttribute("src"));
  ok("'On this piece' shows the photo with the defect, through a private link", /On this piece.*Caused defect/.test(txt(w)) && /\/object\/sign\/photos\//.test($(w, ".phs img").getAttribute("src")));
  ok("the badge is back to All saved", /All saved/.test(txt(w)));

  // viewer and entered by mistake
  await click(w, "[data-viewphoto]", 100);
  ok("tapping it opens the photo: job, sheet, what, who", /PROJ-00418 · sheet 4 · Sanding.*Caused defect — caught before finish.*Taken by Mike B/.test(w.document.querySelector(".viewer").textContent.replace(/\s+/g, " ")));
  await click(w, "[data-voidphoto]", 50);
  await until(async () => (await one("select voided_at is not null v from photos")).v);
  ok("'Entered by mistake' marks it — kept, not deleted", (await one("select count(*)::int n from photos")).n === 1 && files.has("photos/" + ph.storage_path));
  await until(() => !$(w, "[data-viewphoto]"));
  ok("...and it's gone from the piece", !$(w, "[data-viewphoto]"));

  // a problem with two photos, then the limit
  await click(w, '[data-problem="here"]');
  type(w, '[data-mfield="text"]', "Crack along the glue line.");
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-dropshot]"); ok("a photo can be taken out again before sending", $$(w, ".mdl .ph").length === 1);
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-addshot]"); await snap(w);
  ok("three photos: the Add button goes (3 is the most from the tablet)", $$(w, ".mdl .ph").length === 3 && !$(w, "[data-addshot]"));
  await click(w, "[data-dropshot]");
  await click(w, "[data-saveproblem]", 50);
  await until(async () => (await one("select count(*)::int n from photos where kind='problem'")).n === 2, 4000);
  const probId = (await one("select id from problems")).id;
  ok("the problem arrives with its two photos", (await one("select count(*)::int n from photos where problem_id=$1", [probId])).n === 2);
  await click(w, '[data-back="job"]'); await click(w, '[data-back="queue"]', 150);
  await click(w, '[data-tab="problems"]', 50);
  await until(() => $$(w, ".li [data-viewphoto]").length === 2);
  ok("Problems tab: the card shows both photos", $$(w, ".li [data-viewphoto]").length === 2);
  await click(w, "[data-reply]");
  type(w, '[data-mfield="text"]', "Here's the other side.");
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-savereply]", 50);
  await until(async () => (await one("select count(*)::int n from photos where problem_id=$1", [probId])).n === 3, 4000);
  ok("a reply's photo joins the same problem thread", true);

  // no Wi-Fi: a defect and its photo wait together, and send in the right order
  await click(w, '[data-tab="log"]', 100);
  await until(() => !!$(w, '[data-defect="pick"]'));
  setOffline(true);
  await click(w, '[data-defect="pick"]');
  type(w, "[data-jobfilter]", "418"); await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length > 0, 1500);
  await click(w, byText(w, "[data-picksheet]", /^\s*2/));
  await click(w, byText(w, "[data-picktype]", /Missed defect/));
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-savedefect]", 200);
  ok("no Wi-Fi: '1 entry and 1 photo waiting to send'", /1 entry and 1 photo waiting to send/.test(txt(w)), txt(w).slice(0, 120));
  ok("...nothing reached the database or storage", (await one("select count(*)::int n from defects")).n === 1 && (await one("select count(*)::int n from photos")).n === 4);
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => (await one("select count(*)::int n from photos")).n === 5, 5000);
  const late = await one("select p.sheet_number, d.defect_type from photos p join defects d on d.id = p.defect_id order by p.taken_at desc limit 1");
  ok("Wi-Fi back: the defect, then its photo, attached to it (sheet 2)", late && late.sheet_number === 2 && /Missed defect/.test(late.defect_type));
  await until(() => /All saved/.test(txt(w)));
  ok("...and All saved", /All saved/.test(txt(w)));

  // a photo storage won't take is dropped with a plain reason, not retried for ever
  shotSize = 3 * 1024 * 1024;
  await click(w, '[data-defect="pick"]');
  type(w, "[data-jobfilter]", "418"); await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length > 0, 1500);
  await click(w, byText(w, "[data-picktype]", /Missed defect/));
  await click(w, "[data-addshot]"); await snap(w);
  await click(w, "[data-savedefect]", 50);
  await until(() => /too large/.test(txt(w)), 4000);
  ok("a photo storage refuses (3 MB): a plain message, the defect itself still saved", /too large/.test(txt(w)) && (await one("select count(*)::int n from defects")).n === 3);
  await until(() => /All saved/.test(txt(w)));
  ok("...and it isn't left waiting", /All saved/.test(txt(w)));
  shotSize = 350000;
  w.close();

  // ================= Shawn: a load-out =================
  w = boot(users.shawn);
  await until(() => /Start a load-out/.test(txt(w)));
  ok("Shawn's tablet opens on Load-out", /Start a load-out/.test(txt(w)) && $(w, '.subtab[aria-current="true"]').textContent.startsWith("Load-out"));
  ok("Start is off until a job is picked", $(w, "[data-lostart]").disabled);
  await until(() => $$(w, "[data-pickjob]").length > 0);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]", 50);
  await click(w, "[data-lostart]", 100);
  await until(async () => (await one("select count(*)::int n from loadouts")).n === 1, 4000);
  await until(() => $$(w, "[data-loshoot]").length === 4);
  ok("started: PROJ-00362's four sheets to photograph, 0 of 4", /PROJ-00362/.test(txt(w)) && /0 of 4 sheets photographed/.test(txt(w)) && $$(w, "[data-loshoot]").length === 4);
  await click(w, '[data-loshoot="1"]'); await snap(w);
  await until(() => /1 of 4 sheets photographed/.test(txt(w)));
  ok("sheet 1 photographed: 1 of 4, the tile turns complete", /1 of 4 sheets photographed/.test(txt(w)) && $(w, '[data-loshoot="1"]').classList.contains("here"));
  await until(async () => (await one("select count(*)::int n from photos where kind='loadout'")).n === 1, 4000);
  const lp = await one("select p.*, l.job_id from photos p join loadouts l on l.id = p.loadout_id");
  ok("in the database: the load-out photo on sheet 1, Delivery, Shawn", lp.sheet_number === 1 && lp.department === "delivery" && lp.taken_by_name === "Shawn K" && lp.job_id === j362);
  ok("Photograph it (no sheet) is off until it's described", $(w, "[data-loshootitem]").disabled);
  type(w, "#loItem", "hardware box, 1 of 1");
  ok("...on once it is", !$(w, "[data-loshootitem]").disabled);
  await click(w, "[data-loshootitem]"); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where kind='loadout'")).n === 2, 4000);
  await until(() => /1 other item/.test(txt(w)));
  ok("the item with no sheet is saved with its description, counted as 1 other item", (await one("select note from photos where kind='loadout' and sheet_number is null")).note === "hardware box, 1 of 1" && /1 other item/.test(txt(w)));
  await click(w, "[data-lofinish]");
  ok("finishing warns about the sheets not photographed", /sheets 2, 3, 4 aren't photographed/.test(txt(w)));
  await click(w, "[data-confirm]", 50);
  await until(async () => !!(await one("select finished_at from loadouts")).finished_at, 4000);
  await until(() => /Left in the last two weeks/.test(txt(w)));
  ok("finished: recorded as left, listed with its count", /Left in the last two weeks.*PROJ-00362.*1 of 4 sheets photographed · 1 other item/.test(txt(w)));

  // a second truck for the same job, started with no Wi-Fi
  setOffline(true);
  type(w, "[data-jobfilter]", "362"); await click(w, "[data-pickjob]", 50);
  await click(w, "[data-lostart]", 100);
  ok("no Wi-Fi: the load-out opens anyway, marked waiting to send", /PROJ-00362/.test(txt(w)) && /waiting to send/.test(txt(w)));
  await until(() => $$(w, "[data-loshoot]").length === 4, 2000);
  ok("sheet 1 shows it went on the earlier truck (from the list on the tablet)", $$(w, "[data-loshoot]").length === 4);
  await click(w, '[data-loshoot="2"]'); await snap(w);
  ok("sheet 2 photographed offline: 'waiting to send' on its tile", /Photographed · waiting to send/.test($(w, '[data-loshoot="2"]').textContent));
  ok("the badge counts the entry and the photo", /1 entry and 1 photo waiting to send/.test(txt(w)), txt(w).slice(0, 100));
  setOffline(false); w.dispatchEvent(new w.Event("online"));
  await until(async () => (await one("select count(*)::int n from loadouts")).n === 2 && (await one("select count(*)::int n from photos where kind='loadout'")).n === 3, 5000);
  ok("Wi-Fi back: the second load-out and its photo arrive", (await one("select count(*)::int n from photos p join loadouts l on l.id=p.loadout_id where l.finished_at is null and p.sheet_number=2")).n === 1);
  await click(w, "[data-loback]", 100); await until(() => $$(w, "button[data-loopen]").length === 1);
  await click(w, "button[data-loopen]", 300);
  await until(() => /went earlier: sheet 1/.test(txt(w)));
  ok("on the second truck: sheet 1 went earlier, sheet 2 is on this one — 2 of 4 overall", /2 of 4 sheets photographed/.test(txt(w)) && /went earlier: sheet 1/.test(txt(w)) && $(w, '[data-loshoot="1"]').classList.contains("earlier"));
  w.close();

  // ================= the test lane =================
  w = boot(users.test);
  await until(() => $(w, '[data-dept="delivery"]'));
  await click(w, '[data-dept="delivery"]', 200);
  await until(() => /Start a load-out/.test(txt(w)));
  await until(() => $$(w, "[data-pickjob]").length > 0);
  ok("the Test Supervisor's load-out picker: test jobs only", $$(w, "[data-pickjob]").every(b => /TEST/.test(b.textContent)));
  await click(w, "[data-pickjob]", 50); await click(w, "[data-lostart]", 100);
  await until(() => $$(w, "[data-loshoot]").length === 9, 3000);
  await click(w, '[data-loshoot="3"]'); await snap(w);
  await until(async () => (await one("select count(*)::int n from photos where is_test")).n === 1, 4000);
  ok("a test load-out photo goes into the TEST folder, marked test", /^TEST-00418\//.test((await one("select storage_path from photos where is_test")).storage_path));
  w.close();
  const mike = makeClient(users.mike);
  ok("Mike can't see it — neither the photo nor its file", (await mike.from("v_photos").select("*").eq("is_test", true)).data.length === 0
     && !!(await mike.storage.from("photos").createSignedUrl((await one("select storage_path from photos where is_test")).storage_path)).error);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_office_photos.js
```javascript
// Photos in the office, end to end, against the real test database: problem threads, the Photos
// tab, and the archive — with the zip written out and checked by an independent unzip.
// Run on a fresh database with photos.sql: ../base/fresh.sh ../out/photos.sql && node test_office_photos.js
const fs = require("fs");
const { execSync } = require("child_process");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, files } = require("./pgsupa");
const html = fs.readFileSync(process.env.OFFICE || "../out/office.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];
const uuid = () => require("crypto").randomUUID();
let saved = [];

function boot(user) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/office.html" });
  const w = dom.window;
  w.localStorage.setItem("sfo_pin", JSON.stringify({ none: true }));
  w.supabase = { createClient: () => client };
  w.confirm = () => true; w.scrollTo = () => {}; w.TextEncoder = TextEncoder; w.Blob = Blob;
  w.URL.createObjectURL = (b) => { saved.push(b); return "blob:zip"; }; w.URL.revokeObjectURL = () => {};
  w.HTMLAnchorElement.prototype.click = function () { this.ownerDocument.defaultView.__downloaded = this.download; };
  w.eval([...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]);
  return w;
}
const txt = (w) => w.document.getElementById("app").textContent.replace(/\s+/g, " ");
async function until(fn, ms = 4000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(25); } return false; }
const $ = (w, s) => w.document.querySelector(s);
const $$ = (w, s) => [...w.document.querySelectorAll(s)];
async function click(w, sel, pause = 80) { const el = typeof sel === "string" ? $(w, sel) : sel; if (!el) throw new Error("no " + sel); el.click(); await wait(pause); }
async function tab(w, name) { await click(w, `.tab[data-tab="${name}"]`, 30); await until(() => $(w, `.tab[data-tab="${name}"][aria-current="true"]`)); await wait(200); }

// a photo from a tablet, the way the tablet sends it: file first, then add_photo
async function photo(client, project, kind, parent, sheet = null, note = null, size = 1000) {
  const id = uuid();
  const up = await client.storage.from("photos").upload(`${project}/${id}.jpg`, new Blob([Buffer.alloc(size, id.charCodeAt(0))], { type: "image/jpeg" }), { contentType: "image/jpeg" });
  if (up.error) throw new Error(up.error.message);
  const r = await client.rpc("add_photo", { p_client_id: id, p_kind: kind, p_parent: parent, p_sheet: sheet, p_note: note });
  if (r.error || !r.data.ok) throw new Error(JSON.stringify(r.error || r.data));
  return id;
}

(async () => {
  const mike = makeClient(users.mike), shawn = makeClient(users.shawn);
  const j418 = (await one("select id from jobs where project_id='PROJ-00418'")).id;
  const j099 = (await one("select id from jobs where project_id='PROJ-00099'")).id;
  const j362 = (await one("select id from jobs where project_id='PROJ-00362'")).id;
  await admin.query(`do $$ declare w uuid; i int; begin
    insert into work_orders (job_id) select id from jobs where project_id='PROJ-00362' returning id into w;
    for i in 1..2 loop insert into sheets (work_order_id, sheet_number, qty, item_code) values (w, i, 1, 'TR-0'||i); end loop; end $$;`);
  const sandType = (await one("select id from defect_types where department='sanding' order by sort_order limit 1")).id;
  const prob = (await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Crack along the glue line.", p_sheet: 4, p_work_stopped: true })).data.id;
  const pp = await photo(mike, "PROJ-00418", "problem", prob, null, null, 2000);
  const lo = (await shawn.rpc("start_loadout", { p_job: j362, p_client_id: uuid() })).data.id;
  await photo(shawn, "PROJ-00362", "loadout", lo, 1, null, 3000);
  await photo(shawn, "PROJ-00362", "loadout", lo, null, "hardware box, 1 of 1", 4000);
  await shawn.rpc("finish_loadout", { p_loadout: lo });

  const w = boot(users.luke);
  await until(() => $$(w, ".tab").length > 0);
  await tab(w, "problems");
  await until(() => $(w, ".li [data-viewphoto] img[src]"));
  ok("Problems: the photo shows in the problem's thread, through a private link", /\/object\/sign\/photos\/PROJ-00418\//.test($(w, ".li [data-viewphoto] img").getAttribute("src")));
  await click(w, ".li [data-viewphoto]");
  ok("tapping it opens it large, with who and when", /PROJ-00418 · sheet 4 · Sanding.*Problem: Crack along the glue line.*Taken by Mike B/.test($(w, ".viewer").textContent.replace(/\s+/g, " ")));
  await click(w, ".viewer [data-closeviewer]:not(.ovl)");
  ok("...and closes", !$(w, ".viewer"));

  await tab(w, "photos");
  ok("Photos tab: nothing old enough to archive yet", /Nothing is old enough to archive yet/.test(txt(w)));
  ok("...storage used is shown against the free plan's 1 GB", /Storage used: .* of about 1 GB/.test(txt(w)));
  $(w, "#phJob").value = "362"; await click(w, "[data-phfind]", 300);
  await until(() => /What left the building/.test(txt(w)));
  ok("look up '362': what left the building, when, and what was on the truck",
     /PROJ-00362.*What left the building.*Left .*started .* by Shawn K.*On this truck: sheet 1 · 1 other item · 1 of 2 sheets photographed so far/.test(txt(w)), txt(w).slice(txt(w).indexOf("Look up"), txt(w).indexOf("Look up") + 300));
  ok("...its two photos, captioned by sheet or description", $$(w, ".phs .cap").map(c => c.textContent).join("|") === "Sheet 1|hardware box, 1 of 1");

  // ---- the archive: PROJ-00362 has been delivered for 61 days ----
  await admin.query("update jobs set phase = '100% Complete' where id = $1", [j362]);
  await admin.query("update jobs set floor_left_at = now() - interval '61 days' where id = $1", [j362]);
  await admin.query("update photos set taken_at = now() - interval '61 days' where job_id = $1", [j362]);
  await tab(w, "tasks");
  await until(() => /photos ready to archive/.test(txt(w)));
  const card = $$(w, ".sum").find(c => /ready to archive/.test(c.textContent));
  ok("Your tasks: a reminder card — 2 photos ready to archive", card && card.querySelector(".n").textContent === "2" && card.querySelector(".l").textContent === "photos ready to archive");
  await tab(w, "photos");
  ok("Photos tab: 2 photos ready, with a Download archive button", /2 photos \(7 KB\) are ready to move off/.test(txt(w)) && !!$(w, "[data-archstart]"));
  await click(w, "[data-archstart]", 50);
  await until(() => /has downloaded/.test(txt(w)));
  const b1 = (await one("select id from photo_archive_batches order by made_at limit 1")).id;
  ok(`the zip downloads as photo-archive-${b1}.zip`, w.__downloaded === `photo-archive-${b1}.zip` && saved.length === 1, w.__downloaded);
  fs.writeFileSync("/tmp/archive1.zip", Buffer.from(await saved[0].arrayBuffer()));
  let t = execSync("unzip -t /tmp/archive1.zip").toString();
  ok("an independent unzip opens it with no errors", /No errors detected/.test(t), t.split("\n").slice(-2).join(" "));
  const names = execSync("unzip -Z1 /tmp/archive1.zip").toString().trim().split("\n");
  const day = (await one("select to_char((now() - interval '61 days') at time zone 'America/Indiana/Indianapolis', 'YYYY-MM-DD') d")).d;
  ok("inside: a folder per job, files named by sheet, department and date, plus the spreadsheet",
     names.join("|") === `PROJ-00362/job_delivery_${day}.jpg|PROJ-00362/sheet-01_delivery_${day}.jpg|photos.csv`, names.join("|"));
  const size = Number(execSync(`python3 -c "import zipfile; print(zipfile.ZipFile('/tmp/archive1.zip').getinfo('PROJ-00362/sheet-01_delivery_${day}.jpg').file_size)"`).toString().trim());
  ok("...each photo whole (3,000 bytes in, 3,000 out)", size === 3000, String(size));
  const csv = execSync("unzip -p /tmp/archive1.zip photos.csv").toString();
  ok("the spreadsheet lists every photo: job, sheet, who, what", /File,Project,Job,Sheet,Department,Kind,What,Note,Taken by,Taken at/.test(csv)
     && /PROJ-00362\/job_delivery_.*PROJ-00362,Trinitas - Noblesville,,Delivery,Load-out,.*hardware box, 1 of 1.*Shawn K/.test(csv), csv.split("\r\n")[1]);
  ok("nothing is marked saved until you say so", (await one("select state from photo_archive_batches")).state === "building");
  await click(w, "[data-archsaved]", 50);
  await until(async () => (await one("select state from photo_archive_batches")).state === "saved");
  await until(() => /stay in Supabase until next month/.test(txt(w)));
  ok("'Yes — it's saved': batch saved, and its files stay in Supabase for now", /Its files stay in Supabase until next month's batch is saved too/.test(txt(w))
     && (await one("select count(*)::int n from storage.objects where bucket_id='photos' and name like 'PROJ-00362/%'")).n === 2);
  ok("the reminder goes", !/ready to archive/.test(txt(w)) && !$(w, ".tab[data-tab='photos'] .n"));

  // Mike can't take a file off, even an archived one
  const f362 = (await one("select storage_path from photos where job_id = $1 limit 1", [j362])).storage_path;
  await mike.storage.from("photos").remove([f362]);
  await luke_try();
  async function luke_try() {}
  ok("a supervisor can't remove a photo file", (await one("select count(*)::int n from storage.objects where name = $1", [f362])).n === 1);
  const lr = await makeClient(users.luke).storage.from("photos").remove([f362]);
  ok("...nor can a manager while the batch is still inside its month", (await one("select count(*)::int n from storage.objects where name = $1", [f362])).n === 1);

  // ---- a month later: PROJ-00099's photos make the next batch ----
  const d99 = (await mike.rpc("log_defect", { p_job: j099, p_department: "sanding", p_type: sandType, p_sheet: 1 })).data.id;
  await photo(mike, "PROJ-00099", "defect", d99, null, null, 5000);
  await admin.query("update jobs set phase = '100% Complete', is_active = false where id = $1", [j099]);
  await admin.query("update jobs set floor_left_at = now() - interval '61 days' where id = $1", [j099]);
  await admin.query("update photos set taken_at = now() - interval '61 days' where job_id = $1", [j099]);
  await tab(w, "tasks"); await tab(w, "photos");
  ok("next month: 1 photo ready", /1 photo \(5 KB\) is ready to move off/.test(txt(w)));
  saved = [];
  await click(w, "[data-archstart]", 50);
  await until(() => /has downloaded/.test(txt(w)));
  fs.writeFileSync("/tmp/archive2.zip", Buffer.from(await saved[0].arrayBuffer()));
  t = execSync("unzip -t /tmp/archive2.zip").toString();
  ok("the second zip is sound too, and holds only the new photo", /No errors detected/.test(t) && execSync("unzip -Z1 /tmp/archive2.zip").toString().trim().split("\n").length === 2);
  await click(w, "[data-archsaved]", 50);
  await until(() => /is off Supabase/.test(txt(w)), 5000);
  ok(`saving batch 2 releases batch ${b1}: its files come off Supabase`,
     (await one("select count(*)::int n from storage.objects where bucket_id='photos' and name like 'PROJ-00362/%'")).n === 0 && ![...files.keys()].some(k => k.startsWith("photos/PROJ-00362/")));
  ok("...its records stay, marked archived, the batch 'Off Supabase'", (await one("select count(*)::int n from photos where job_id=$1 and file_removed_at is not null and archive_batch=$2", [j362, b1])).n === 2
     && (await one("select state from photo_archive_batches where id=$1", [b1])).state === "removed");
  ok("batch 2's own file is still there, for its month", (await one("select count(*)::int n from storage.objects where bucket_id='photos' and name like 'PROJ-00099/%'")).n === 1);
  ok("the page says so in plain words", new RegExp(`Batch ${b1} is off Supabase`).test(txt(w)));

  $(w, "#phJob").value = "PROJ-00362"; await click(w, "[data-phfind]", 300);
  await until(() => /photo-archive-/.test(txt(w)));
  ok("looking up PROJ-00362 now says which zip and folder hold its photos",
     new RegExp(`Archived in batch ${b1}.*photo-archive-${b1}\\.zip, folder PROJ-00362`).test(txt(w)));
  await click(w, "details.more summary", 20);
  ok("the batch list: states in words, and Download again only while files remain",
     new RegExp(`${b1} Off Supabase — in the zip only`).test(txt(w)) && /Saved — its files are still in Supabase too/.test(txt(w)) && $$(w, "[data-archagain]").length === 1);
  w.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```

#### test_shrink_chromium.js
The test images are made with PIL: a 4000×3000 "photo" (shapes, blur, sensor noise) saved at quality 92, the same with EXIF orientation 6, and 4000×3000 of pure noise.

```javascript
// The real shrinkPhoto() from index.html, run in real Chromium on camera-sized JPEGs.
const fs = require("fs");
const { chromium } = require("playwright");
const html = fs.readFileSync(process.env.APP || "../out/index.html", "utf8");
const core = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
const fit = /function fitSize[\s\S]*?\n}\n/.exec(core)[0];
const shrink = /  async function shrinkPhoto[\s\S]*?\n  }\n/.exec(core)[0];
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
(async () => {
  const b = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const pg = await b.newPage();
  await pg.setContent(`<input type="file" id="f"><script>${fit}${shrink}
    window.run = async () => { const out = await shrinkPhoto(document.getElementById("f").files[0]); return { size: out.blob.size, type: out.blob.type, w: out.width, h: out.height }; };</script>`);
  for (const [file, want] of [["/tmp/cam_landscape.jpg", [1600, 1200]], ["/tmp/cam_portrait_exif.jpg", [1200, 1600]], ["/tmp/cam_noise.jpg", null]]) {
    await pg.setInputFiles("#f", file);
    const t0 = Date.now();
    const r = await pg.evaluate(() => window.run());
    const inKB = Math.round(fs.statSync(file).size / 1024);
    ok(`${file.split("/").pop()} (${inKB} KB, 4000×3000) → ${r.w}×${r.h}, ${Math.round(r.size / 1024)} KB JPEG in ${Date.now() - t0} ms`,
       r.type === "image/jpeg" && (want ? r.w === want[0] && r.h === want[1] && r.size <= 560000 : r.size < 2097152));
  }
  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
})().catch(e => { console.error(e); process.exit(1); });
```

#### breaks.py
```python
import subprocess, re
src = open('/home/claude/sf/out/photos.sql').read()
breaks = {
 "bucket made public": ("  set public = false, file_size_limit", "  set public = true, file_size_limit", 1),
 "lanes not checked on upload": ("and (name like 'TEST-%') = public.am_test());", ");", 7),
 "file existence not checked": ("  if not found then\n    raise exception 'The photo file hasn''t arrived", "  if false then\n    raise exception 'The photo file hasn''t arrived", 5),
 "department not checked on defect photos": ("    v_job := floor_entry_check(v_def.department, v_def.job_id);", "    select * into v_job from jobs where id = v_def.job_id;", 6),
 "photos readable across lanes": ("create policy read_photos on photos for select to authenticated using (sees_lane(is_test));", "create policy read_photos on photos for select to authenticated using (true);", 7),
 "files deletable before release": ("using (bucket_id = 'photos' and public.is_manager() and public.photo_file_released(name));", "using (bucket_id = 'photos' and public.is_manager());", 15),
 "floor clock not stamped": ("create trigger jobs_floor_left_trg before insert or update of is_active, phase, is_test on jobs\n  for each row execute function jobs_floor_left_stamp();", "", 12),
 "archive ignores the 60 days": ("     and j.floor_left_at <= now() - interval '60 days'\n     and p.taken_at <= now() - interval '60 days';", "     ;", 14),
}
for name,(a,b,row) in breaks.items():
    assert src.count(a)==1, name
    open('/tmp/broken.sql','w').write(src.replace(a,b))
    r = subprocess.run("./fresh.sh /tmp/broken.sql /home/claude/sf/out/check_photos.sql >/dev/null && psql -h /tmp/pg -p 5433 -U postgres -d sync -tA -c \"select step from check_photos() where result='FAIL'\"", shell=True, capture_output=True, text=True, cwd='/home/claude/sf/base')
    failed = [int(x) for x in r.stdout.split()]
    print(("CAUGHT " if failed and failed[0]==row else "MISSED ")+f"{name}: first FAIL at row {failed[0] if failed else '-'} (expected {row}); all failing {failed}")
```

#### test_app_e2e.js (Part 2's, retyped, with `PHOTOS=1`)
```javascript
// The tablet functions, end to end (testing kit Part 2): the real index.html in jsdom, talking
// to the real test database through the same login path Supabase uses.
// Run on a fresh seeded database: ../base/fresh.sh && node test_app_e2e.js
// PHOTOS=1 switches on the expectations that changed on purpose with the photos build
// (Delivery gains a Load-out area and opens on it).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users, setOffline } = require("./pgsupa");
const html = fs.readFileSync(process.env.APP || "../out/index.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const PHOTOS = !!process.env.PHOTOS;
const wait = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const one = async (sql, p = []) => (await admin.query(sql, p)).rows[0];

function boot(user, { preload = {} } = {}) {
  const client = makeClient(user);
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/index.html" });
  const w = dom.window;
  for (const [k, v] of Object.entries(preload)) w.localStorage.setItem(k, v);
  if (PHOTOS) { const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange; }
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

  await click(w, '[data-tab="log"]', 50);
  await until(() => !!$(w, '[data-defect="pick"]'));
  setOffline(true);
  await click(w, '[data-defect="pick"]');
  type(w, "[data-jobfilter]", "418"); await click(w, "[data-pickjob]", 50);
  await until(() => $$(w, "[data-picksheet]").length > 0, 1500);
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
  if (PHOTOS) {
    ok("Shawn: Load-out, Problems and Log — no Work orders, no Supplies", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Load-out · Problems · Log",
       $$(w, ".subtab").map(b => b.textContent).join("|"));
    ok("...and his tablet opens on Load-out", $(w, '.subtab[aria-current="true"]').textContent.startsWith("Load-out"));
  } else {
    ok("Shawn: Problems and Log only — no Work orders, no Supplies", $$(w, ".subtab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === "Problems · Log");
    ok("...and his tablet opens on Problems", $(w, '.subtab[aria-current="true"]').textContent.startsWith("Problems"));
  }
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

  // ================= a count still works as before =================
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

#### test_office_e2e.js (Part 2's, retyped, with `PHOTOS=1`)
```javascript
// The office page, end to end against the real test database (testing kit Part 2).
// PHOTOS=1: the tab list gains "Photos" (changed on purpose with the photos build).
const fs = require("fs");
const { JSDOM } = require("jsdom");
const { makeClient, admin, users } = require("./pgsupa");
const html = fs.readFileSync(process.env.OFFICE || "../out/office.html", "utf8").replace(/<script src="[^"]+"><\/script>/, "");
const PHOTOS = !!process.env.PHOTOS;
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
  const pr = (await mike.rpc("flag_problem", { p_job: j418, p_department: "sanding", p_body: "Glue line opened on the top overnight.", p_sheet: 7, p_work_stopped: true })).data.id;
  await mike.rpc("flag_problem", { p_job: j099, p_department: "sanding", p_body: "Which grit for the desk edges?" });
  await mike.rpc("log_defect", { p_job: j418, p_department: "sanding", p_type: (await one("select id from defect_types where department='sanding' order by sort_order limit 1")).id, p_sheet: 1 });
  const r1 = (await mike.rpc("request_supply", { p_department: "sanding", p_item: "Tack cloths", p_qty: 2 })).data.id;
  const r2 = (await mike.rpc("request_supply", { p_department: "sanding", p_item: "180 grit rolls", p_qty: 1 })).data.id;
  await makeClient(users.test).rpc("request_supply", { p_department: "metal", p_item: "bench wire", p_qty: 1 });
  const ar = (await willie.rpc("send_to_arrow", { p_job: j418, p_department: "metal", p_service: "powdercoat", p_sheets: [6], p_sent_on: "2026-09-01" })).data.id;

  const w = boot(users.luke);
  await until(() => /This is my own computer/.test(txt(w)));
  await click(w, "[data-nopin]", 300);
  await until(() => $$(w, ".sum").length > 0);
  const tabsWanted = "Your tasks · Problems · Flags · Ordering · Arrow · Routine tasks · Departments · " + (PHOTOS ? "Photos · Setup" : "Setup");
  ok("tabs: " + tabsWanted, $$(w, ".tab").map(b => b.textContent.replace(/\d+$/, "")).join(" · ") === tabsWanted, $$(w, ".tab").map(b => b.textContent).join("|"));
  const sums = () => $$(w, ".sum").map(s => s.querySelector(".n").textContent + " " + s.querySelector(".l").textContent).join(" | ");
  ok("Your tasks: 2 problems waiting, 3 to order, 1 at Arrow over 14 days",
     sums() === "2 problems from the floor waiting for an answer | 3 supply requests to order | 1 item at Arrow over 14 days", sums());
  ok("the handoff list is still there", /Handoffs/.test(txt(w)));

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

  await tab(w, "departments");
  await until(() => /Log-only/.test(txt(w)));
  ok("Delivery is listed as log-only, with no live switch", /Delivery Log-only/.test(txt(w)) && !$(w, '[data-live="delivery"]') && $$(w, "[data-live]").length === 7);

  await tab(w, "setup");
  await until(() => /TV link/.test(txt(w)));
  ok("no TV link yet", /No TV link has been made yet/.test(txt(w)));
  await click(w, "[data-tvnew]", 50);
  await until(() => $(w, "#tvUrl"));
  const url = $(w, "#tvUrl").textContent;
  ok("the TV link is shown once: tv.html next to this page, secret after the #", /^https:\/\/lukehart1228\.github\.io\/shop-floor\/tv\.html#k=[0-9a-f]{64}$/.test(url), url);
  const key = url.split("#k=")[1];
  ok("...and it works for the TV", (await makeClient(null).rpc("tv_snapshot", { p_key: key })).data.ok === true);
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

  const w2 = boot(users.mike);
  await until(() => /is a supervisor login/.test(txt(w2)));
  ok("Mike is turned away from the office view", /Mike B is a supervisor login/.test(txt(w2)));
  w2.close();

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
```
