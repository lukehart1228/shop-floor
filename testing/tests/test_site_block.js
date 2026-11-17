// 17 Nov: the test environment's site block, read from the files (no database, no browser).
//   OUT=/tmp/allpages node test_site_block.js           (run_all passes the new side's pages)
//   LIVEREPO=/home/claude/sf/repo                        (the live repo: its saved names are the ones that may not change)
// 1. The block (between "THE SITE: LIVE OR TEST" and "END OF THE SITE BLOCK") is word for word the same in index.html,
//    tv.html, sw.js and the newest shared script, once each, and in no other file.
// 2. The address rule: a folder named shop-floor is live, shop-floor-test is test, anything else stops; the names a
//    page saves under end -test on test only; the second lock's answers; the Production TEST folder rule.
// 3. No page reaches its database, the browser's storage or its saved copies any other way: no Supabase address or
//    publishable key outside the block, every createClient guarded, every localStorage / indexedDB / caches name
//    through sfName(), no caches.match (it reads every site's copies), every PDF marked, every folder picker checked.
// 4. Live's names don't change by a letter: the names the new pages use on live are exactly the live repo's.
// 5. Every page, script and the offline helper that changed carries a new version.
const fs = require("fs"), path = require("path"), vm = require("vm");
const OUT = process.env.OUT || "/tmp/allpages";
const LIVE = process.env.LIVEREPO || "/home/claude/sf/repo";
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const read = (dir, f) => fs.readFileSync(path.join(dir, f), "utf8");
const START = "/* ===== THE SITE: LIVE OR TEST", END = "/* ===== END OF THE SITE BLOCK ===== */";

const pages = fs.readdirSync(OUT).filter(f => f.endsWith(".html"));
const commons = fs.readdirSync(OUT).filter(f => /^sf-common-\d{4}-\d\d-\d\d\.\d+\.js$/.test(f)).sort();
const newestCommon = commons[commons.length - 1];
const scripts = ["sw.js", "sf-3d-viewer.js", newestCommon].filter(f => f && fs.existsSync(path.join(OUT, f)));
const files = pages.concat(scripts);
const text = Object.fromEntries(files.map(f => [f, read(OUT, f)]));

// ---- 1. one block, the same everywhere it belongs ----
const blockOf = (s) => { const a = s.indexOf(START), b = s.indexOf(END); return a < 0 || b < a ? null : s.slice(a, b + END.length); };
const HOLDERS = ["index.html", "tv.html", "sw.js", newestCommon];
const blocks = HOLDERS.map(f => blockOf(text[f] || ""));
ok("The site block is in index.html, tv.html, sw.js and the newest shared script (" + newestCommon + ")", blocks.every(Boolean),
   HOLDERS.filter((f, i) => !blocks[i]).join(", "));
ok("…word for word the same in all four", blocks.every(b => b === blocks[0]),
   HOLDERS.filter((f, i) => blocks[i] !== blocks[0]).join(", ") + " differ from index.html's");
ok("…once in each, and in no other file", files.every(f => (text[f].split(START).length - 1) === (HOLDERS.includes(f) ? 1 : 0)),
   files.filter(f => (text[f].split(START).length - 1) !== (HOLDERS.includes(f) ? 1 : 0)).join(", "));
const usesCommon = pages.filter(f => /<script src="sf-common-/.test(text[f]));
ok("Every page with the shared script loads the newest one", usesCommon.length >= 8 && usesCommon.every(f => text[f].includes(`<script src="${newestCommon}"></script>`)),
   usesCommon.filter(f => !text[f].includes(`<script src="${newestCommon}"></script>`)).join(", "));

if (!blocks[0]) { console.log(`\n${pass} PASS, ${fail} FAIL  (no site block in index.html: the rest can't run; these are pages from before 17 Nov)`); process.exit(1); }

// ---- 2. the rules, run from the block itself ----
const run = (pathname, extra = "") => {
  const ctx = { location: { pathname, search: "" }, Promise, setTimeout, console };
  vm.createContext(ctx); vm.runInContext(blocks[0] + "\n" + extra, ctx); return ctx;
};
const cases = [
  ["/shop-floor/", "live"], ["/shop-floor/index.html", "live"], ["/shop-floor/office.html", "live"], ["/shop-floor/sw.js", "live"],
  ["/shop-floor-test/", "test"], ["/shop-floor-test/tv.html", "test"], ["/shop-floor-test/sw.js", "test"],
  ["/tmp/x/shop-floor/tv.html", "live"],
  ["/", null], ["/index.html", null], ["/shop-floor", null], ["/Shop-Floor/", null], ["/shop-floor-tests/", null],
  ["/shop-floor-test-old/index.html", null], ["/tmp/allpages/tv.html", null], ["/shop-floor/sub/index.html", null]];
const got = cases.map(([p, want]) => [p, want, run(p).SF_SITE]);
ok("The address rule: a folder named shop-floor is live, shop-floor-test is test, any other stops (" + cases.length + " addresses)",
   got.every(([, w, g]) => w === g), got.filter(([, w, g]) => w !== g).map(([p, w, g]) => `${p}: ${g} not ${w}`).join("; "));
const L = run("/shop-floor/index.html"), T = run("/shop-floor-test/index.html"), N = run("/elsewhere/index.html");
ok("Live keeps its names exactly; test's end -test", L.sfName("sf_outbox") === "sf_outbox" && T.sfName("sf_outbox") === "sf_outbox-test"
   && L.sfName("shop-floor-shell-v4") === "shop-floor-shell-v4" && T.sfName("shop-floor-shell-v4") === "shop-floor-shell-v4-test");
let threw = false; try { N.sfName("sf_outbox"); } catch (e) { threw = /isn't at the live or the test address/.test(e.message); }
ok("At any other address nothing is kept: sfName refuses, and the page says why", threw && /neither the live app/.test(N.sfSiteProblem() || ""));
ok("Live points at the live project; test at its own (never the same address or key)",
   L.SUPABASE_URL === "https://fueyfxjxlicqekaqtydi.supabase.co" && /^sb_publishable_/.test(L.SUPABASE_KEY)
   && T.SUPABASE_URL !== L.SUPABASE_URL && T.SUPABASE_KEY !== L.SUPABASE_KEY && N.SUPABASE_URL === "" && N.SUPABASE_KEY === "");
const testFilled = T.SUPABASE_URL.indexOf("PASTE-") < 0;
ok(testFilled ? "The test project's address and key are filled in, and look like Supabase's"
              : "The test project's address and key aren't filled in yet, and a test page says so (until a chat fills them in)",
   testFilled ? /^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(T.SUPABASE_URL) && /^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(T.SUPABASE_KEY) && !T.sfSiteProblem()
              : /haven't been filled in yet/.test(T.sfSiteProblem() || ""), T.SUPABASE_URL);
const lock = [["live", "live", null], ["live", "missing", null], ["live", null, null], ["live", "test", "is the test database"],
              ["test", "test", null], ["test", null, null], ["test", "live", "doesn't say it is the test database"], ["test", "missing", "doesn't say it is the test database"]];
ok("The second lock: live stops only for a test database; test stops for anything but test (no connection: carry on)",
   lock.every(([site, a, w]) => { const r = (site === "live" ? L : T).sfDatabaseProblem(a); return w ? r && r.includes(w) : r === null; }));
ok("Folders: on live any folder; on test only one named Production TEST",
   L.sfFolderProblem("Production") === null && T.sfFolderProblem("Production TEST") === null
   && /only into a folder named Production TEST/.test(T.sfFolderProblem("Production") || "") && !!T.sfFolderProblem("PD - POs") && !!T.sfFolderProblem("production test"));

// ---- 3. nothing reached any other way ----
const outsideBlock = (f) => { const b = blockOf(text[f]); return b ? text[f].replace(b, "") : text[f]; };
const leaks = files.filter(f => /https:\/\/[a-z0-9]+\.supabase\.co|sb_publishable_/.test(outsideBlock(f)));
ok("No Supabase address or publishable key outside the block", leaks.length === 0, leaks.join(", "));
const bad = [];
const lines = (f) => text[f].split("\n").map((l, i) => [i + 1, l]);
for (const f of files) {
  const consts = new Set([...text[f].matchAll(/const ([A-Z_]+) = sfName\(/g)].map(m => m[1]));
  for (const [n, l] of lines(f)) {
    for (const m of l.matchAll(/localStorage\.(getItem|setItem|removeItem)\(\s*([^,)]*)/g)) if (!/^sfName\(/.test(m[2])) bad.push(`${f}:${n} localStorage.${m[1]}(${m[2]}`);
    if (/localStorage\.(key|clear)\(|localStorage\[|sessionStorage/.test(l)) bad.push(`${f}:${n} ${l.trim().slice(0, 60)}`);
    for (const m of l.matchAll(/indexedDB\.(open|deleteDatabase)\(\s*([^,)]*)/g)) if (!/^sfName\(/.test(m[2])) bad.push(`${f}:${n} indexedDB.${m[1]}(${m[2]}`);
    for (const m of l.matchAll(/caches\.(open|delete|has)\(\s*([^,)]*)/g)) {
      const a = m[2].trim();
      const fine = /^sfName\(/.test(a) || consts.has(a) || (f === "sw.js" && m[1] === "delete" && a === "k" && /ownSite\(k\) && k !== SHELL/.test(l));
      if (!fine) bad.push(`${f}:${n} caches.${m[1]}(${a}`);
    }
    if (/caches\.match\(/.test(l)) bad.push(`${f}:${n} caches.match reads every site's saved copies`);
  }
}
ok("Every name a page keeps on the device goes through sfName(); no caches.match", bad.length === 0, bad.slice(0, 6).join(" | "));
const clients = files.filter(f => /createClient\(/.test(text[f]) && f !== "sw.js");
const unguarded = clients.filter(f => !/window\.supabase\.createClient\(SUPABASE_URL, SUPABASE_KEY\);\n\s*sfGuardDatabase\(db\);[^\n]*\n\s*sfTestBar\(\);/.test(text[f])
                                      || (text[f].match(/createClient\(/g) || []).length !== 1);
ok(`Every page's database client is made from the block's address and guarded at once (${clients.length} pages)`, clients.length >= 9 && unguarded.length === 0, unguarded.join(", "));
ok("The TV checks the site its snapshot names before drawing anything", /var wrong = sfDatabaseProblem\(data\.site \|\| "missing"\);/.test(text["tv.html"] || "") && /sfTestBar\(\);/.test(text["tv.html"] || ""));
const saves = [];
for (const f of files) lines(f).forEach(([n, l], i, all) => { if (/doc\.save\(/.test(l)) saves.push([f, n, /await sfMarkPdf\(PDFLib, doc\);/.test(all[i - 1][1])]); });
ok(`Every PDF the app makes is marked on test (${saves.length} places)`, saves.length >= 6 && saves.every(s => s[2]), saves.filter(s => !s[2]).map(s => s[0] + ":" + s[1]).join(", "));
const pickers = [];
for (const f of files) lines(f).forEach(([n, l], i, all) => { if (/showDirectoryPicker\(\{/.test(l)) pickers.push([f, n, all.slice(i, i + 4).some(x => /sfFolderProblem\(/.test(x[1]))]); });
ok(`Every folder the app saves into is checked on test (${pickers.length} pickers)`, pickers.length >= 3 && pickers.every(p => p[2]), pickers.filter(p => !p[2]).map(p => p[0] + ":" + p[1]).join(", "));

// ---- 4. live's names: exactly the live repo's ----
const namesOld = new Set(), namesNew = new Set();
const liveFiles = fs.readdirSync(LIVE).filter(f => f.endsWith(".html") || f === "sw.js" || f === "sf-3d-viewer.js" || /^sf-common-.*\.js$/.test(f));
for (const f of liveFiles) {
  const s = read(LIVE, f);
  for (const m of s.matchAll(/(?:localStorage\.(?:getItem|setItem|removeItem)|indexedDB\.open|caches\.open)\(\s*"([^"]+)"/g)) namesOld.add(m[1]);
  for (const m of s.matchAll(/const (?:SHELL|KEEP) = "([^"]+)"/g)) namesOld.add(m[1]);
  for (const m of s.matchAll(/const cacheName = \(kind\) => kind === "page" \? "([^"]+)" : "([^"]+)"/g)) { namesOld.add(m[1]); namesOld.add(m[2]); }
}
for (const f of files) {
  const s = text[f];
  for (const m of s.matchAll(/sfName\(\s*"([^"]+)"/g)) namesNew.add(m[1]);
  for (const m of s.matchAll(/const KEEP = "([^"]+)"/g)) namesNew.add(m[1]);
  for (const m of s.matchAll(/const cacheName = \(kind\) => kind === "page" \? "([^"]+)" : "([^"]+)"/g)) { namesNew.add(m[1]); namesNew.add(m[2]); }
}
const missing = [...namesOld].filter(x => !namesNew.has(x)), added = [...namesNew].filter(x => !namesOld.has(x));
ok(`Live's names don't change by a letter (${namesOld.size} names: ${[...namesOld].sort().join(", ")})`,
   namesOld.size >= 15 && missing.length === 0 && added.length === 0, `gone: ${missing.join(", ")}; new: ${added.join(", ")}`);

// ---- 5. versions ----
const verOf = (s) => (s.match(/(?:PAGE_VERSION|OFFICE_VERSION|TV_VERSION|SF_COMMON_VERSION) = "([^"]+)"|const VERSION = "([^"]+)"/) || []).slice(1).find(Boolean) || null;
const stale = [];
for (const f of files) {
  if (!fs.existsSync(path.join(LIVE, f)) || read(LIVE, f) === text[f]) continue;
  if (f === "sw.js") { if (!/v4/.test(text[f])) stale.push(f); continue; }          // the offline helper's name may not change (live's saved copy)
  if (verOf(text[f]) === verOf(read(LIVE, f))) stale.push(`${f} still ${verOf(text[f])}`);
}
ok("Every changed page and script carries a new version (sw.js keeps shop-floor-shell-v4 on purpose)", stale.length === 0, stale.join(", "));

// ---- 6. a real PDF, marked by the real pdf-lib: TEST on test, untouched on live (pdftotext reads it back) ----
(async () => {
  const cp = require("child_process"), PDFLIB = "/tmp/pdflib/package/dist/pdf-lib.min.js";
  if (!fs.existsSync(PDFLIB)) cp.execSync("mkdir -p /tmp/pdflib && cd /tmp/pdflib && npm pack pdf-lib@1.17.1 >/dev/null 2>&1 && tar xzf pdf-lib-1.17.1.tgz");
  const PDFLib = require(PDFLIB);
  const make = async () => { const d = await PDFLib.PDFDocument.create(); d.setTitle("AR-10(99)"); d.addPage([612, 792]).drawText("Arrow PO body", { x: 54, y: 700, size: 12 });
                             d.setCreationDate(new Date(0)); d.setModificationDate(new Date(0)); return d; };
  const words = (bytes) => { fs.writeFileSync("/tmp/site_mark.pdf", bytes); return cp.execSync("pdftotext -layout /tmp/site_mark.pdf - 2>/dev/null").toString(); };
  const plain = await (await make()).save();
  const live = await (await L.sfMarkPdf(PDFLib, await make())).save();
  const tdoc = await T.sfMarkPdf(PDFLib, await make()), test = await tdoc.save();
  ok("A PDF made on live is untouched (byte for byte)", Buffer.compare(Buffer.from(plain), Buffer.from(live)) === 0);
  const w = words(test);
  ok("A PDF made on test says TEST, not the real floor across the top, and its title starts TEST", /TEST, not the real floor/.test(w) && /Arrow PO body/.test(w)
     && /^TEST · AR-10\(99\)$/.test(tdoc.getTitle()), w.trim().slice(0, 80) + " | " + tdoc.getTitle());
  console.log(`\n${pass} PASS, ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  The PDF check stopped: " + e.message); process.exit(1); });
