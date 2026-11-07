// 4 Nov: the app is called Production (Luke). No database. Every page in use shows Production, never "Shop Floor",
// in its title, header and messages; the home-screen name is Production. Internal names stay as they are (the repo
// shop-floor, file kinds like shop-floor-zip, the old "shop-floor data" folder the save still looks for, cache names).
// OUT=<folder with every page>  node test_app_name.js
const fs = require("fs"); const OUT = process.env.OUT || "/tmp/allpages";
let pass = 0, fail = 0; const ok = (name, cond, info = "") => { cond ? pass++ : fail++; console.log(`${cond ? "PASS" : "FAIL"}  ${name}${!cond && info ? "  — " + info : ""}`); };
const PAGES = ["index.html", "office.html", "delivery.html", "inventory.html", "pace.html", "drop.html", "status.html", "machine.html", "step.html", "purchasing.html"];   // purchasing.html 7 Nov
const strip = (s) => s.replace(/<!--[\s\S]*?-->/g, "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/[^\n]*/g, "$1")     // comments
  .replace(/shop-floor-[a-z-]+/g, "").replace(/shop-floor data/g, "").replace(/lukehart1228\.github\.io\/shop-floor/g, "");          // internal names
for (const p of PAGES) {
  const s = strip(fs.readFileSync(`${OUT}/${p}`, "utf8"));
  const hits = s.match(/.{0,40}shop[ -]?floor.{0,30}/gi) || [];
  ok(`${p}: says Production, never Shop Floor`, !hits.length, hits.slice(0, 3).join(" | "));
}
ok("index.html: the tablet's header, sign-in and title say Production", (() => { const s = fs.readFileSync(`${OUT}/index.html`, "utf8");
  return /<span class="brand">PRODUCTION<\/span>/.test(s) && /<h1>Production<\/h1>/.test(s) && /<title>Production<\/title>/.test(s); })());
ok("office.html: the header and the ☰ menu say PRODUCTION", (() => { const s = fs.readFileSync(`${OUT}/office.html`, "utf8");
  return /<span class="brand">PRODUCTION<\/span>/.test(s) && /<div class="mhead"><b>PRODUCTION<\/b>/.test(s); })());
const m = JSON.parse(fs.readFileSync(`${OUT}/manifest.webmanifest`, "utf8"));
ok("The home-screen name is Production", m.short_name === "Production" && /^Production/.test(m.name) && !/shop floor/i.test(m.description), JSON.stringify({ n: m.name, s: m.short_name }));
ok("The internal names are untouched (the zip and upload kinds, the old save folder)", /"shop-floor-zip"/.test(fs.readFileSync(`${OUT}/drop.html`, "utf8"))
   && /"shop-floor-work-order"/.test(fs.readFileSync(`${OUT}/drop.html`, "utf8")) && /"shop-floor data"/.test(fs.readFileSync(`${OUT}/office.html`, "utf8")));
console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
