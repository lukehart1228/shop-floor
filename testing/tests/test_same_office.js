// 5 Oct: office, delivery, inventory, pace and upload drawn as Luke, live (repo/) vs new (out/): every screen the same apart from
// the Feedback button, the ☰ Feedback item, the office app's empty section holder and the version label. Seed first.  TZ=America/Indiana/Indianapolis node test_same_office.js
const fs = require("fs"); const { JSDOM } = require("jsdom");
const { makeClient, users } = require("./pgsupa");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
// same-folder scripts (the shared sf-common file) and the page's own script, run as ONE piece: a browser shares top-level
// settings between a page's scripts, but jsdom keeps each eval separate
const pageScript = (raw, html, dir) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(dir + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");

async function draw(file, page, pre) {
  const raw = fs.readFileSync(file, "utf8"), html = strip(raw); const client = makeClient(users.luke);
  const w = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/" + page }).window;
  for (const [k, v] of Object.entries(pre)) w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client }; w.Blob = Blob; w.URL.createObjectURL = () => "blob:x"; w.scrollTo = () => {}; w.print = () => {}; w.open = () => {};
  w.eval(pageScript(raw, html, require("path").dirname(file))); await wait(1800);
  const out = [w.document.body.innerHTML];
  const tabs = [...w.document.querySelectorAll("[data-tab]")].map(b => b.dataset.tab).filter((v, i, a) => a.indexOf(v) === i && v !== "feedback");
  for (const t of tabs) { const b = w.document.querySelector(`[data-tab="${t}"]`); if (b) { b.click(); await wait(900); out.push(w.document.body.innerHTML); } }
  w.close(); return out;
}
const norm = (h) => h.replace(/<div id="secs" hidden="">[\s\S]*?<\/div>/g, "").replace(/<button data-kind="(dock|task)"[\s\S]*?<\/button>/g, "").replace(/<button[^>]*data-sffb[^>]*>[\s\S]*?<\/button>/g, "").replace(/<button class="mitem" data-tab="feedback"[\s\S]*?<\/button>\s*/g, "")
  .replace(/Version [^<]*</g, "Version X<").replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "ID").replace(/<script[\s\S]*?<\/script>/g, "").replace(/\s+/g, " ").replace(/> </g, "><");
(async () => {
  let bad = 0;
  for (const [page, pre] of [["office.html", { sfo_pin: JSON.stringify({ none: true }) }], ["delivery.html", {}], ["inventory.html", {}], ["pace.html", {}], ["upload.html", {}]]) {
    const a = await draw("/home/claude/sf/repo/" + page, page, pre), b = await draw((process.env.OUT || "/home/claude/sf/out") + "/" + page, page, pre);
    const diff = a.map((h, i) => norm(h) === norm(b[i] || "") ? null : i).filter(x => x !== null);
    console.log(`${diff.length || a.length !== b.length ? "FAIL" : "PASS"}  ${page}: ${a.length} screens the same apart from the Feedback button${diff.length ? " — differ: " + diff : ""}`);
    if (diff.length) { bad++; const i = diff[0]; const x = norm(a[i]), y = norm(b[i]); let k = 0; while (x[k] === y[k]) k++; console.log("   live: " + x.slice(k - 80, k + 120) + "\n   new:  " + y.slice(k - 80, k + 120)); }
  }
  process.exit(bad ? 1 : 0);
})();
