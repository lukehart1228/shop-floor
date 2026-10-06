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
const ftypes = new Map();                // "bucket/path" -> the type it was uploaded as

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

// Supabase sends every argument as JSON, so a jsonb parameter gets real JSON; node-pg would send a Postgres array instead
const jsonArgs = new Map();
async function jsonParams(fn) {
  if (!jsonArgs.has(fn)) {
    const r = await admin.query(`select a.n from pg_proc p, unnest(p.proargnames, p.proargtypes::oid[]) as a(n, t)
      where p.proname = $1 and p.pronamespace = 'public'::regnamespace and a.t in ('jsonb'::regtype, 'json'::regtype)`, [fn]).catch(() => ({ rows: [] }));
    jsonArgs.set(fn, new Set(r.rows.map(x => x.n)));
  }
  return jsonArgs.get(fn);
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
  const st = { table, kind: "select", cols: "*", where: [], params: [], order: [], limit: null, offset: null, single: null, values: null, returning: null };
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
    range(from, to) { st.offset = from; st.limit = to - from + 1; return b; },      // 6 Oct: paging, as Supabase does it
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
      // SF_MAX_ROWS=1000 caps every select the way Supabase's API does (it returns at most 1,000 rows a request)
      const cap = Number(process.env.SF_MAX_ROWS || 0), lim = cap ? Math.min(st.limit || cap, cap) : st.limit;
      sql = `select ${cols(st.cols)} from ${q(st.table)}${w}${st.order.length ? " order by " + st.order.join(", ") : ""}${lim ? " limit " + lim : ""}${st.offset ? " offset " + st.offset : ""}`;
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
      files.set(key(path), buf); ftypes.set(key(path), type);
      return { data: { path }, error: null };
    },
    async download(path) {
      if (offline) return netErr();
      const r = await runAs(client.user, "select name from storage.objects where bucket_id = $1 and name = $2", [bucket, path]);
      if (bucket === "work-orders") return { data: new Blob(["png"], { type: "image/png" }), error: null };   // sheet pages: never uploaded here
      if (r.error || !r.data.length) return { data: null, error: { message: "Object not found", statusCode: "404" } };
      const buf = files.get(key(path)) || Buffer.from("jpg");
      return { data: new Blob([buf], { type: ftypes.get(key(path)) || "image/jpeg" }), error: null };
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
    const js = await jsonParams(fn);
    const params = names.map(n => js.has(n) && args[n] !== null && args[n] !== undefined && typeof args[n] === "object" ? JSON.stringify(args[n]) : args[n]);
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
           david: { id: "88888888-8888-8888-8888-888888888888", email: "ddart@pdindy.com" },
           jim: { id: "99999999-9999-9999-9999-999999999990", email: "finish@pdindy.com" },
           eric: { id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email: "fullcustom@pdindy.com" } } };
