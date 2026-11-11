// 11 Nov: upload.html left GitHub, so it's no longer compared.
// 5 Oct: office, delivery, inventory, pace and upload drawn as Luke, live (repo/) vs new (out/): every screen the same apart from
// the Feedback button, the ☰ Feedback item, the office app's empty section holder and the version label. Seed first.
// PHOTOSPACE=ignore sets aside what the 31 Oct build changed on the Photos tab (below); NAMES=ignore the 4 Nov names.  TZ=America/Indiana/Indianapolis node test_same_office.js
const fs = require("fs"); const { JSDOM } = require("jsdom");
const { makeClient, users } = require("./pgsupa");
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const strip = (h) => h.replace(/<script src="[^"]+"[^>]*><\/script>/g, "");
// same-folder scripts (the shared sf-common file) and the page's own script, run as ONE piece: a browser shares top-level
// settings between a page's scripts, but jsdom keeps each eval separate
const pageScript = (raw, html, dir) => [...raw.matchAll(/<script src="([^"/:]+\.js)"><\/script>/g)].map(m => fs.readFileSync(dir + "/" + m[1], "utf8"))
  .concat([[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1]]).join("\n;\n");

// 11 Nov: the office is drawn one named screen at a time (Operations, OneDrive, Setup), each from a fresh load, because the
// tabs themselves changed (Arrow left; OneDrive went to the ☰ menu). The other pages still walk their tabs.
const OFFICE_SCREENS = ["tasks", "photos", "setup"];
async function draw(file, page, pre) {
  if (page === "office.html" && !pre.__one) { const out = [];
    for (const t of OFFICE_SCREENS) out.push((await draw(file, page, { ...pre, __one: 1, sfo_tab: JSON.stringify(t) }))[0]);
    return out; }
  const raw = fs.readFileSync(file, "utf8"), html = strip(raw); const client = makeClient(users.luke);
  const w = new JSDOM(html, { runScripts: "outside-only", url: "https://lukehart1228.github.io/shop-floor/" + page }).window;
  for (const [k, v] of Object.entries(pre)) if (k !== "__one") w.localStorage.setItem(k, v);
  const fidb = require("fake-indexeddb"); w.indexedDB = new fidb.IDBFactory(); w.IDBKeyRange = fidb.IDBKeyRange;
  w.supabase = { createClient: () => client }; w.Blob = Blob; w.URL.createObjectURL = () => "blob:x"; w.scrollTo = () => {}; w.print = () => {}; w.open = () => {};
  w.eval(pageScript(raw, html, require("path").dirname(file))); await wait(1800);
  const out = [w.document.body.innerHTML];
  if (pre.__one) { w.close(); return out; }
  const tabs = [...w.document.querySelectorAll("[data-tab]")].map(b => b.dataset.tab).filter((v, i, a) => a.indexOf(v) === i && v !== "feedback");
  for (const t of tabs) { const b = w.document.querySelector(`[data-tab="${t}"]`); if (b) { b.click(); await wait(900); out.push(w.document.body.innerHTML); } }
  w.close(); return out;
}
const norm = (h) => h.replace(/<div id="secs" hidden="">[\s\S]*?<\/div>/g, "").replace(/<button data-kind="(dock|task)"[\s\S]*?<\/button>/g, "").replace(/<button[^>]*data-sffb[^>]*>[\s\S]*?<\/button>/g, "").replace(/<button class="mitem" data-tab="feedback"[\s\S]*?<\/button>\s*/g, "")
  .replace(/Version [^<]*</g, "Version X<").replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "ID").replace(/<script[\s\S]*?<\/script>/g, "").replace(/\s+/g, " ").replace(/> </g, "><");
// PHOTOSPACE=ignore (31 Oct, off_supabase.sql): sets aside the Photos tab's space panel (Photo archive → Space on Supabase)
// and the saving panel's last line (the Production layout), the two things that build changed on purpose
// ARROWPOS=ignore (1 Nov, arrow_pos.sql): sets aside the Arrow tab's Arrow POs panel, which that build added on purpose
const aside = (h) => {
  if (process.env.PHOTOSPACE === "ignore") h = h.replace(/<section class="panel"><h2>(Photo archive|Space on Supabase)<\/h2>[\s\S]*?<\/section>/g, "")
     .replace(/<p class="meta2" style="margin-top:10px">Each job's photos[\s\S]*?<\/p>/g, "");
  if (process.env.ARROWPOS === "ignore") h = h.replace(/<section class="panel"><h2>Arrow POs<\/h2>[\s\S]*?<\/section>/g, "");
  // EXPORT=ignore (4 Nov, inventory.html 2026-11-04.2): sets aside the Export counts section added to Inventory's This month on purpose
  if (process.env.EXPORT === "ignore") h = h.replace(/<h3>Export counts<\/h3>\s*<div class="card">[\s\S]*?<\/p>\s*<\/div>/g, "");
  // NAMES=ignore (4 Nov, the office's names): sets aside the tab strip (Job status joined it; Photos is called OneDrive),
  // the tab's heading and first line, the words naming it, Pace's page heading (now Data) and the app's name (Production). Everything else must match.
  if (process.env.NAMES === "ignore") h = h.replace(/<nav class="tabs">[\s\S]*?<\/nav>/g, "<nav>TABS</nav>")
     .replace(/<h1>(Photos|OneDrive)<\/h1>\s*<p class="sub">[\s\S]*?<\/p>/g, "<h1>TAB</h1>")
     .replace(/the (Photos|OneDrive) tab|Open (Photos|OneDrive)|open it on (Photos|the OneDrive tab)/g, "TAB")
     .replace(/<h1>(Pace|Data)<\/h1>/g, "<h1>PAGE</h1>")
     .replace(/SHOP FLOOR|PRODUCTION/g, "BRAND").replace(/the shop floor's files|the Production app's files/g, "FILES");   // 4 Nov: the app is called Production
  // BUYING=ignore (10 Nov, office.html 2026-11-10.1): buying left Operations for Purchasing › Buy. Sets aside Operations' Supplies to
  // order part (a list to tick before; one line pointing at Purchasing now) and the two supply lists folded under it (Ordered, not
  // received; closed), which that build took away on purpose. Everything else on the office must match.
  if (process.env.BUYING === "ignore") h = h.replace(/<section class="need" id="need-ordering"[\s\S]*?<\/section>/g, "")
     .replace(/<details class="more" data-keep="(ordered|closed)"[^>]*>[\s\S]*?<\/details>/g, "");
  // OFFICE11=ignore (11 Nov, office.html 2026-11-11.1): sets aside what that build moved on purpose. Operations: the Arrow section
  // (the old Arrow tab's lists), and the Inventory line's link (a page of its own then, inside the office now). Setup: its intro line,
  // the jump list, the Arrow alert panel (from the Arrow tab), Supply lists (now Purchasing › Setup) and the Connections heading;
  // the remaining panels are compared one by one, whatever their order. Data: the Setup button that holds Working days.
  if (process.env.OFFICE11 === "ignore") {
    h = h.replace(/(open it on )?(the |The )?OneDrive( tab| \(in the ☰ menu\))/g, "TAB")   // OneDrive moved into the ☰ menu
      .replace(/<section class="ops-flags" id="opsarrow">[\s\S]*?<\/details><\/section>/g, "")
      .replace(/<div class="detail">(<a href="inventory.html">Open the Inventory page<\/a>|<button class="link" data-section="inventory"[^>]*>Open Inventory<\/button>)<\/div>/g, "<div class=\"detail\">INV</div>")
      .replace(/<button class="setupbtn" data-tab="days"[^>]*>Setup<\/button>/g, "")
      .replace(/<button data-tab="days"[^>]*>Working days<\/button>/g, "");
    if (/<h1>Setup<\/h1>/.test(h)) {
      const panels = {}; h.replace(/<section class="panel" id="set-([a-z]+)">[\s\S]*?<\/section>/g, (m, id) => { panels[id] = m; return ""; });
      delete panels.supplies; delete panels.arrow;
      h = h.replace(/<p class="sub">(Things set up once|The floor's rules)[\s\S]*?<\/nav>/, "INTRO")
        .replace(/<section class="panel" id="set-[a-z]+">[\s\S]*?<\/section>/g, "").replace(/<h2 class="sethead" style="margin-top:30px">Connections, set up once<\/h2>/, "")
        + Object.keys(panels).sort().map(k => panels[k]).join("");
    }
  }
  return h;
};
(async () => {
  let bad = 0;
  for (const [page, pre] of [["office.html", { sfo_pin: JSON.stringify({ none: true }) }], ["delivery.html", {}], ["inventory.html", {}], ["pace.html", {}]]) {
    const a = await draw("/home/claude/sf/repo/" + page, page, pre), b = await draw((process.env.OUT || "/home/claude/sf/out") + "/" + page, page, pre);
    const diff = a.map((h, i) => norm(aside(h)) === norm(aside(b[i] || "")) ? null : i).filter(x => x !== null);
    console.log(`${diff.length || a.length !== b.length ? "FAIL" : "PASS"}  ${page}: ${a.length} screens the same apart from the Feedback button${diff.length ? " — differ: " + diff : ""}`);
    if (diff.length) { bad++; const i = diff[0]; const x = norm(a[i]), y = norm(b[i]); let k = 0; while (x[k] === y[k]) k++; console.log("   live: " + x.slice(k - 80, k + 120) + "\n   new:  " + y.slice(k - 80, k + 120)); }
  }
  process.exit(bad ? 1 : 0);
})();
