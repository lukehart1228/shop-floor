// Review finding R-12 (6 Oct): a note typed on the floor that starts with = + - @ opens in Excel as text, not a formula.
// The office page's csvCell, taken from the page itself. Run: node test_csv_cell.js   (OUT=… for another folder; the live page fails)
const html = require("fs").readFileSync(`${process.env.OUT || "/home/claude/sf/out"}/office.html`, "utf8");
const src = html.match(/function csvCell\(v\) \{[\s\S]*?\n\}|function csvCell\(v\) \{.*\}/)[0];
const csvCell = new Function(src + "; return csvCell;")();
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const cases = [
  ["-2 legs short", "'-2 legs short"], ["=HYPERLINK(\"http://x\",\"click\")", "\"'=HYPERLINK(\"\"http://x\"\",\"\"click\"\")\""],
  ["+1 extra top", "'+1 extra top"], ["@Jim check this", "'@Jim check this"], ["\tTabbed", "'\tTabbed"],
  ["Plain note", "Plain note"], ["Comma, inside", "\"Comma, inside\""], ["2026-10-06", "2026-10-06"],
  [-3, "-3"], [12, "12"], [null, ""], [undefined, ""], ["", ""], ["Say \"hi\"", "\"Say \"\"hi\"\"\""],
];
for (const [v, want] of cases) { const got = csvCell(v); ok(`${JSON.stringify(v)} → ${JSON.stringify(want)}`, got === want, `got ${JSON.stringify(got)}`); }
console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
