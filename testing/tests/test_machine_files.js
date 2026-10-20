// 18 Oct: machine files (machine_files.sql, machine.html, the lab's Machine files card) in Chromium through the bridge.
// Luke sends STEP files and a program from the lab; the Bend-Tech and the Homag router each get only theirs on machine.html,
// into a folder chosen on their computer (Chrome's private folder stands in for the real one), checked byte for byte; the
// file then leaves storage and its record stays; revisions; a file changed on the way is refused; people and the wrong
// machine get nothing. Needs a database built with lab.sql and machine_files.sql (TEMPLATE=sync_base_new bash base/fresh.sh).
// MODE=nofiles: a database with lab.sql but not machine_files.sql (both pages say so plainly).
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers TZ=America/Indiana/Indianapolis node test_machine_files.js
const fs = require("fs"), http = require("http"), path = require("path"), crypto = require("crypto");
const { chromium } = require("/home/claude/.npm-global/lib/node_modules/playwright");
const { makeClient, users, admin, files } = require("./pgsupa");
const OUT = process.env.OUT || "/home/claude/sf/newrepo", REPO = "/home/claude/sf/repo", MODE = process.env.MODE || "new";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const FAKE = (user) => `window.supabase = { createClient: () => {
  const call = (m) => window.__sb(m);
  const builder = (t) => { const calls = []; const p = new Proxy({}, { get(_, k) {
      if (k === "then") return (res, rej) => call({ kind: "from", t, calls }).then(res, rej);
      if (typeof k === "symbol") return undefined;
      return (...a) => { calls.push([k, a]); return p; }; } }); return p; };
  const b64 = async (blob) => { const u = new Uint8Array(await blob.arrayBuffer()); let s = ""; for (let i = 0; i < u.length; i += 8192) s += String.fromCharCode.apply(null, u.subarray(i, i + 8192)); return btoa(s); };
  let session = ${JSON.stringify(user)} ? { user: ${JSON.stringify(user)} } : null;
  return { auth: { getSession: async () => ({ data: { session } }), signOut: async () => { session = null; return {}; }, onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
                   signInWithPassword: async () => ({ data: null, error: { message: "not here" } }) },
    from: builder, rpc: (fn, args) => call({ kind: "rpc", fn, args }),
    storage: { from: (bucket) => ({
      upload: async (path, body, opts) => call({ kind: "storage", op: "upload", bucket, path, b64: await b64(body), opts }),
      download: async (path) => { const r = await call({ kind: "storage", op: "download", bucket, path });
        if (r.error) return r; const bin = atob(r.b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { data: new Blob([u]), error: null }; },
      remove: async (paths) => call({ kind: "storage", op: "remove", bucket, paths }) }) } };
} };`;
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, "");
  const file = [path.join(OUT, p), path.join(REPO, p)].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
  if (!file) { res.writeHead(404); return res.end(); }
  let body = fs.readFileSync(file);
  if (file.endsWith(".html")) body = Buffer.from(body.toString().replace(/(supabase\.js") integrity="[^"]+"/, "$1"));
  res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "application/javascript" : "text/html" }); res.end(body);
});
async function session(browser, user, opts = {}) {
  const client = makeClient(user);
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: "block", acceptDownloads: true });
  await ctx.exposeBinding("__sb", async (_, m) => {
    if (m.kind === "rpc") return JSON.parse(JSON.stringify(await client.rpc(m.fn, m.args || {})));
    if (m.kind === "storage") {
      const st = client.storage.from(m.bucket);
      if (m.op === "upload") return JSON.parse(JSON.stringify(await st.upload(m.path, Buffer.from(m.b64, "base64"), m.opts || {})));
      if (m.op === "remove") return JSON.parse(JSON.stringify(await st.remove(m.paths)));
      const r = await st.download(m.path); if (r.error) return { data: null, error: r.error };
      return { b64: Buffer.from(await r.data.arrayBuffer()).toString("base64"), error: null };
    }
    let b = client.from(m.t); for (const [k, a] of m.calls) b = b[k](...a);
    return JSON.parse(JSON.stringify(await b));
  });
  if (opts.folder) await ctx.addInitScript((name) => {   // the folder picker opens Chrome's private folder instead: same folder API
    window.showDirectoryPicker = async () => (await navigator.storage.getDirectory()).getDirectoryHandle(name, { create: true }); }, opts.folder);
  if (opts.noFolder) await ctx.addInitScript(() => { delete window.showDirectoryPicker; window.showDirectoryPicker = undefined; });
  await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
  await ctx.route(/cdn\.jsdelivr\.net|cdnjs/, r => r.abort());
  await ctx.route(/supabase-js@/, r => r.fulfill({ body: FAKE(user), contentType: "application/javascript", headers: { "Access-Control-Allow-Origin": "*" } }));
  const p = await ctx.newPage(); const errs = [];
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });
  return { ctx, p, errs, client };
}
const q = async (sql, a = []) => (await admin.query(sql, a)).rows;
const tmp = (name, content) => { const f = path.join("/tmp", name); fs.writeFileSync(f, content); return f; };
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const folderFiles = (p, name) => p.evaluate(async (name) => { const out = {}; const root = await (await navigator.storage.getDirectory()).getDirectoryHandle(name, { create: true });
  const walk = async (d, pre) => { for await (const [n, h] of d.entries()) { if (h.kind === "directory") await walk(h, pre + n + "/"); else out[pre + n] = await (await h.getFile()).text(); } };
  await walk(root, ""); return out; }, name);

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const browser = await chromium.launch();
  await admin.query("select lab_allow('luke@example.com')");
  for (const m of ["homag", "bendtech"]) await admin.query(`insert into auth.users (id, email) select gen_random_uuid(), '${m}@example.com' where not exists (select 1 from auth.users where email = '${m}@example.com')`);
  const userOf = async (e) => ({ id: (await q("select id from auth.users where email = $1", [e]))[0].id, email: e });
  const BT = await userOf("bendtech@example.com"), HO = await userOf("homag@example.com");

  if (MODE === "nofiles") {
    let s = await session(browser, users.luke); await s.p.goto(base + "lab.html"); await s.p.waitForSelector("#labArea:not([hidden])");
    await s.p.waitForFunction(() => /machine_files\.sql hasn’t run/.test(document.querySelector("#files").textContent), null, { timeout: 10000 });
    ok("Lab without machine_files.sql: the Machine files card says it isn’t set up yet, and the rest works", true);
    s = await session(browser, BT); await s.p.goto(base + "machine.html"); await s.p.waitForSelector("#notMachine:not([hidden])");
    ok("machine.html without machine_files.sql says so plainly", /aren’t set up in the database yet/.test(await s.p.textContent("#notMachine")), await s.p.textContent("#notMachineBody"));
    await browser.close(); server.close(); console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
  }
  ok("machine_allow() makes the two machine logins; a person's login is refused", (await q("select machine_allow('bendtech@example.com', 'bendtech') r"))[0].r.includes("Bend-Tech")
     && (await q("select machine_allow('homag@example.com', 'homag') r"))[0].r.includes("Homag") && (await q("select machine_allow('mike@example.com', 'homag') r"))[0].r.startsWith("That login belongs to a person"));

  // ---- Luke sends files from the lab ----
  const L = await session(browser, users.luke); let p = L.p;
  await p.goto(base + "lab.html"); await p.waitForSelector("#fSend", { timeout: 15000 });
  const legs = { "Leg-Long.step": "ISO-10303-21; leg long " + "x".repeat(5000), "Leg-Upper-Half.step": "ISO-10303-21; upper", "V-Arm.step": "ISO-10303-21; v arm r1" };
  await p.fill("#fJob", "PROJ-00451"); await p.fill("#fItem", "TA-02"); await p.selectOption("#fMachine", "bendtech"); await p.fill("#fNote", "Starfish base tubes");
  await p.setInputFiles("#fFiles", Object.entries(legs).map(([n, c]) => tmp(n, c)));
  await p.click("#fSend"); await p.waitForFunction(() => /^Sent:/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  let rows = await q("select file_name, machine, rev, stored_at is not null stored, sha256 from machine_files order by file_name");
  ok("Three STEP files sent to the Bend-Tech, named PROJ_item_part_r1, each stored with its fingerprint",
     rows.map(r => r.file_name).join(",") === "PROJ-00451_TA-02_Leg-Long_r1.step,PROJ-00451_TA-02_Leg-Upper-Half_r1.step,PROJ-00451_TA-02_V-Arm_r1.step"
     && rows.every(r => r.stored && r.machine === "bendtech") && rows[2].sha256 === sha(legs["V-Arm.step"]), rows.map(r => r.file_name).join(", "));
  ok("…and the lab lists each as Waiting for the Bend-Tech", (await p.$$eval("#files .tag", els => els.filter(e => /Waiting for the Bend-Tech/.test(e.textContent)).length)) === 3);
  await p.fill("#fJob", "PROJ-00317"); await p.fill("#fItem", "TB-08-RC"); await p.selectOption("#fMachine", "homag"); await p.fill("#fPart", "Program"); await p.fill("#fNote", "Organic top");
  await p.setInputFiles("#fFiles", tmp("tb08.mprx", "<?xml version=\"1.0\"?><Program>r1</Program>"));
  await p.click("#fSend"); await p.waitForFunction(() => /^Sent: PROJ-00317_TB-08-RC_Program_r1\.mprx/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  ok("A program sent to the Homag router, part named as typed", true);
  await p.setInputFiles("#fFiles", tmp("oops.step", "not a program")); await p.click("#fSend");
  await p.waitForFunction(() => /Not sent: oops\.step/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  ok("A STEP file can’t go to the router; the lab says why", /takes \.mprx or \.mpr/.test(await p.textContent("#fMsg")), await p.textContent("#fMsg"));

  // ---- the Bend-Tech's computer ----
  const B = await session(browser, BT, { folder: "dragon" }); let b = B.p;
  await b.goto(base + "machine.html"); await b.waitForSelector("#area:not([hidden])", { timeout: 15000 });
  ok("The Bend-Tech login opens machine.html as the Bend-Tech, with 3 files waiting and none of the router’s", (await b.textContent("#machName")) === "Bend-Tech (Dragon)"
     && (await b.textContent("#waitTitle")) === "Waiting for this machine (3)" && !/TB-08/.test(await b.textContent("#area")));
  ok("…Get files waits until a folder is chosen", await b.$eval("#getBtn", e => e.disabled));
  await b.click("#pickBtn"); await b.waitForSelector("#getBtn:not([disabled])");
  await b.evaluate(async () => { const d = await (await navigator.storage.getDirectory()).getDirectoryHandle("dragon", { create: true });   // someone already made the job's folder, with its name
    await (await d.getDirectoryHandle("400s", { create: true })).getDirectoryHandle("PROJ-00451 Mitsch Design", { create: true }); });
  ok("The folder line says files are sorted into hundreds › job › item", /sorted into hundreds › job › item folders/.test(await b.textContent("#folderCard")));
  ok("…the folder is chosen once (dragon)", /Files go into dragon/.test(await b.textContent("#folderCard")));
  await b.click("#getBtn"); await b.waitForFunction(() => /Nothing waiting/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 20000 });
  let got = await folderFiles(b, "dragon");
  const J = "400s/PROJ-00451 Mitsch Design/TA-02/";
  ok("Get files: all three land in 400s › PROJ-00451 Mitsch Design (the existing folder, not a second one) › TA-02, byte for byte", Object.keys(got).sort().join(",") === [J + "PROJ-00451_TA-02_Leg-Long_r1.step", J + "PROJ-00451_TA-02_Leg-Upper-Half_r1.step", J + "PROJ-00451_TA-02_V-Arm_r1.step"].join(",")
     && got[J + "PROJ-00451_TA-02_V-Arm_r1.step"] === legs["V-Arm.step"] && got[J + "PROJ-00451_TA-02_Leg-Long_r1.step"] === legs["Leg-Long.step"], Object.keys(got).join(", "));
  ok("…and the page says where each went", /Saved into 400s › PROJ-00451 Mitsch Design › TA-02/.test(await b.textContent("#results")));
  rows = await q("select count(*) filter (where picked_up_at is not null and cleared_at is not null and picked_up_by = $1)::int n from machine_files where machine = 'bendtech'", [BT.id]);
  const objs = (await q("select count(*)::int n from storage.objects where bucket_id = 'machine-files' and name like 'bendtech/%'"))[0].n;
  ok("…each recorded as picked up by the Bend-Tech, and cleared from the app’s storage (the records stay)", rows[0].n === 3 && objs === 0, `${rows[0].n} recorded, ${objs} left in storage`);
  await b.reload(); await b.waitForSelector("#area:not([hidden])");
  ok("After a reload the folder is remembered, and the three show under Got lately", /Files go into dragon/.test(await b.textContent("#folderCard")) && (await b.$$("#gotList li .tag.ok")).length === 3);

  // ---- a new revision after the machine has the old one ----
  await p.fill("#fJob", "PROJ-00451"); await p.fill("#fItem", "TA-02"); await p.selectOption("#fMachine", "bendtech"); await p.fill("#fPart", "V-Arm"); await p.fill("#fNote", "Cope stops 1/4 short of centre");
  await p.setInputFiles("#fFiles", tmp("V-Arm.step", "ISO-10303-21; v arm r2")); await p.click("#fSend");
  await p.waitForFunction(() => /^Sent: PROJ-00451_TA-02_V-Arm_r2\.step/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  ok("Sending V-Arm again makes revision 2; the lab shows r1 Replaced by r2, after the machine got it", /Replaced by r2, after the machine got it/.test(await p.textContent("#files")));
  await b.click("#refreshBtn"); await b.waitForFunction(() => /\(1\)/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 10000 });
  ok("The Bend-Tech sees r2 waiting, and r1 under Replaced: don’t use these, telling it to use revision 2", /V-Arm_r2/.test(await b.textContent("#waitList")) && /V-Arm_r1/.test(await b.textContent("#replacedList")) && /Use revision 2/.test(await b.textContent("#replacedList")));

  // ---- a file changed on the way is refused ----
  const p2 = (await q("select path from machine_files where file_name = 'PROJ-00451_TA-02_V-Arm_r2.step'"))[0].path;
  files.set("machine-files/" + p2, Buffer.from("ISO-10303-21; tampered"));
  await b.click("#getBtn"); await b.waitForFunction(() => /Not got/.test(document.querySelector("#results").textContent), null, { timeout: 15000 });
  got = await folderFiles(b, "dragon");
  ok("A file that arrives different from the one sent isn’t saved or counted, and says so", !got[J + "PROJ-00451_TA-02_V-Arm_r2.step"] && /arrived different/.test(await b.textContent("#results"))
     && (await q("select picked_up_at from machine_files where path = $1", [p2]))[0].picked_up_at === null);
  files.set("machine-files/" + p2, Buffer.from("ISO-10303-21; v arm r2"));
  await b.click("#getBtn"); await b.waitForFunction(() => /Nothing waiting/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 15000 });
  got = await folderFiles(b, "dragon");
  ok("…sent right, it arrives; r1 stays on the machine untouched (the page never deletes there)", got[J + "PROJ-00451_TA-02_V-Arm_r2.step"] === "ISO-10303-21; v arm r2" && got[J + "PROJ-00451_TA-02_V-Arm_r1.step"] === legs["V-Arm.step"]);
  await p.fill("#fJob", "PROJ-00451"); await p.fill("#fItem", "TA-02"); await p.selectOption("#fMachine", "bendtech"); await p.fill("#fNote", "Whole base, for fit checking");
  await p.check("#fAssembly");
  ok("Ticking “This is the whole assembly” fills the part as Assembly and locks it", (await p.inputValue("#fPart")) === "Assembly" && await p.$eval("#fPart", e => e.disabled));
  await p.setInputFiles("#fFiles", [tmp("a.step", "1"), tmp("b.step", "2")]); await p.click("#fSend");
  ok("…with two files chosen, it refuses: an item has one whole-assembly file", /one whole-assembly file/.test(await p.textContent("#fMsg")));
  await p.setInputFiles("#fFiles", tmp("starfish-base.step", "ISO-10303-21; assembly")); await p.click("#fSend");
  await p.waitForFunction(() => /^Sent: PROJ-00451_TA-02_Assembly_r1\.step/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  await p.uncheck("#fAssembly");
  await p.fill("#fJob", "PROJ-00317"); await p.fill("#fItem", "TB-05/31-RC"); await p.fill("#fPart", "Cross Rod"); await p.fill("#fNote", "");
  await p.setInputFiles("#fFiles", tmp("rod.step", "ISO-10303-21; rod")); await p.click("#fSend");
  await p.waitForFunction(() => /^Sent: PROJ-00317_TB-05-31-RC_Cross-Rod_r1\.step/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  await b.click("#refreshBtn"); await b.waitForFunction(() => /\(2\)/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 10000 });
  await b.click("#getBtn"); await b.waitForFunction(() => /Nothing waiting/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 15000 });
  got = await folderFiles(b, "dragon");
  ok("The assembly lands beside TA-02’s parts", got[J + "PROJ-00451_TA-02_Assembly_r1.step"] === "ISO-10303-21; assembly");
  ok("A new job gets its own hundreds and job folders, and a / in the item code becomes - (300s › PROJ-00317 › TB-05-31-RC)", got["300s/PROJ-00317/TB-05-31-RC/PROJ-00317_TB-05-31-RC_Cross-Rod_r1.step"] === "ISO-10303-21; rod", Object.keys(got).filter(k => k.startsWith("300s")).join(", "));
  ok("No plain PROJ-00451 folder was made beside the renamed one", !Object.keys(got).some(k => k.startsWith("400s/PROJ-00451/")));
  ok("No page errors on the Bend-Tech’s page", B.errs.length === 0, B.errs.join(" | "));

  // ---- the router: a revision before pickup, then Get files with no folder support (Downloads) ----
  await p.fill("#fJob", "PROJ-00317"); await p.fill("#fItem", "TB-08-RC"); await p.selectOption("#fMachine", "homag"); await p.fill("#fPart", "Program"); await p.fill("#fNote", "Fixed the lead-in");
  await p.setInputFiles("#fFiles", tmp("tb08.mprx", "<?xml version=\"1.0\"?><Program>r2</Program>")); await p.click("#fSend");
  await p.waitForFunction(() => /^Sent: PROJ-00317_TB-08-RC_Program_r2\.mprx/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  const r1 = (await q("select replaced_by is not null rep, cleared_at is not null cleared, (select count(*)::int from storage.objects where name = machine_files.path) obj from machine_files where file_name = 'PROJ-00317_TB-08-RC_Program_r1.mprx'"))[0];
  ok("A new revision before the router got the old one: r1 is replaced and cleared from storage straight away", r1.rep && r1.cleared && r1.obj === 0, JSON.stringify(r1));
  const H = await session(browser, HO, { noFolder: true }); const h = H.p;
  await h.goto(base + "machine.html"); await h.waitForSelector("#area:not([hidden])", { timeout: 15000 });
  ok("The router sees only its own r2, nothing of the Bend-Tech’s, and no r1", (await h.textContent("#waitTitle")) === "Waiting for this machine (1)" && /Program_r2/.test(await h.textContent("#waitList")) && !/PROJ-00451|Program_r1/.test(await h.textContent("#area")));
  ok("…without the folder feature, the page says files go to Downloads", /go to Downloads/.test(await h.textContent("#folderCard")));
  const [dl] = await Promise.all([h.waitForEvent("download"), h.click("#getBtn")]);
  ok("…and Get files downloads it under its name, the right bytes", dl.suggestedFilename() === "PROJ-00317_TB-08-RC_Program_r2.mprx" && fs.readFileSync(await dl.path(), "utf8") === "<?xml version=\"1.0\"?><Program>r2</Program>");
  await h.waitForFunction(() => /Nothing waiting/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 10000 });
  await p.fill("#fJob", "PROJ-00317"); await p.fill("#fItem", "TB-08-RC"); await p.selectOption("#fMachine", "homag"); await p.fill("#fPart", "Program"); await p.fill("#fNote", "Third try");
  await p.setInputFiles("#fFiles", tmp("tb08.mprx", "<Program>r3</Program>")); await p.click("#fSend");
  await p.waitForFunction(() => /^Sent: PROJ-00317_TB-08-RC_Program_r3\.mprx/.test(document.querySelector("#fMsg").textContent), null, { timeout: 15000 });
  const H2 = await session(browser, HO, { folder: "router" }); const h2 = H2.p;
  await h2.goto(base + "machine.html"); await h2.waitForSelector("#area:not([hidden])"); await h2.click("#pickBtn"); await h2.waitForSelector("#getBtn:not([disabled])");
  ok("The router’s folder line doesn’t mention sub-folders", !/sorted into/.test(await h2.textContent("#folderCard")));
  await h2.click("#getBtn"); await h2.waitForFunction(() => /Nothing waiting/.test(document.querySelector("#waitTitle").textContent), null, { timeout: 15000 });
  const rg = await folderFiles(h2, "router");
  ok("The router’s programs go straight into its folder, no sub-folders", Object.keys(rg).join(",") === "PROJ-00317_TB-08-RC_Program_r3.mprx", Object.keys(rg).join(", "));
  ok("No page errors on the router’s page or the lab", H.errs.length === 0 && H2.errs.length === 0 && L.errs.length === 0, H.errs.concat(H2.errs, L.errs).join(" | "));

  // ---- people and other logins ----
  const M = await session(browser, users.mike); await M.p.goto(base + "machine.html"); await M.p.waitForSelector("#notMachine:not([hidden])");
  ok("Mike (a supervisor) on machine.html: told it isn’t a machine’s login", /isn’t a machine’s login/.test(await M.p.textContent("#notMachine")));
  const mc = makeClient(users.mike), dc = makeClient(users.david), bc = makeClient(BT);
  const mr = await mc.from("machine_files").select("*"), dr = await dc.from("machine_files").select("*");
  const dn = await dc.rpc("machine_file_new", { p_project: "PROJ-00451", p_item: "TA-02", p_part: "X", p_machine: "bendtech", p_original_name: "x.step", p_size: 1, p_sha256: "a".repeat(64), p_note: null });
  ok("Mike and David (not in the lab) see no files, and David can’t send one", mr.data.length === 0 && dr.data.length === 0 && !!dn.error, dn.error && dn.error.message);
  const bp = await bc.from("profiles").select("*"), bl = await bc.from("lab_rules").select("*");
  const pid = (await q("select id from sheet_progress limit 1"))[0].id, bs = await bc.rpc("set_count", { p_progress: pid, p_qty: 1 });
  ok("The Bend-Tech login sees no people and nothing of the lab, and can’t change a count", bp.data.length === 0 && bl.data.length === 0 && !!bs.error, bs.error && bs.error.message);
  const an = makeClient(null), aq = await an.from("machine_files").select("*");
  ok("No login sees nothing", (aq.data || []).length === 0);

  await browser.close(); server.close();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
