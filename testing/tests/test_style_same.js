// 20 Oct: the tablet app carries the colour tokens inline (it opens with no Wi-Fi), the office loads them from
// sf-style-<date>.css. This fails when the two drift apart, or when a page still hard-codes a grey the sheet names.
//   node test_style_same.js      (OUT=/home/claude/sf/out by default)
const fs = require("fs"), path = require("path");
const OUT = process.env.OUT || "/home/claude/sf/out";
let pass = 0, fail = 0; const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const tokens = (css) => { const m = css.match(/:root\{([^}]*)\}/); if (!m) return null;
  return Object.fromEntries(m[1].split(";").map(s => s.trim()).filter(Boolean).map(s => s.split(":").map(x => x.trim()))); };
const sheetName = (fs.readdirSync(OUT).filter(f => /^sf-style-\d{4}-\d{2}-\d{2}\.\d+\.css$/.test(f)).sort().pop());
ok("A dated stylesheet is in the build", !!sheetName, sheetName);
const sheet = sheetName ? fs.readFileSync(path.join(OUT, sheetName), "utf8") : "";
const index = fs.readFileSync(path.join(OUT, "index.html"), "utf8"), office = fs.readFileSync(path.join(OUT, "office.html"), "utf8");
const a = tokens(sheet), b = tokens(index);
ok("index.html's inline tokens are the stylesheet's, name for name", a && b && JSON.stringify(a) === JSON.stringify(b),
   a && b ? Object.keys({ ...a, ...b }).filter(k => a[k] !== b[k]).map(k => `${k}: sheet ${a[k]} vs tablet ${b[k]}`).join(", ") || "same" : "a :root block is missing");
ok("office.html loads the stylesheet and has no tokens of its own", office.includes(`href="${sheetName}"`) && !/:root\{/.test(office));
for (const [name, html] of [["index.html", index], ["office.html", office]]) {
  const css = (html.match(/<style>([\s\S]*?)<\/style>/) || ["", ""])[1];
  const stray = [...new Set((css.match(/#(?:9AA0B4|6B7082|5A6178|4A5063)\b/gi) || []))];
  ok(`${name} has no grey the sheet names (dim, ink2)`, !stray.length, stray.join(" "));
  const whiteOnTeal = (css.match(/background:var\(--teal\)[^}]*color:#fff/gi) || []).length;
  ok(`${name} puts dark text on turquoise, never white`, whiteOnTeal === 0, whiteOnTeal ? `${whiteOnTeal} rule(s)` : "");
}
ok("every named colour pair in the sheet's header still passes", /orange-ink:#B5420A/.test(sheet) && /--ink2:#575C6E/.test(sheet) && /--dim:#AEB4C8/.test(sheet));
console.log(`\n${pass} PASS, ${fail} FAIL`);
process.exit(fail ? 1 : 0);
