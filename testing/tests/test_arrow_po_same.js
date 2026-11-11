// 11 Nov: the Arrow PO's PDF and the supply-list helpers live in two pages: office.html's save files the PDF in the Arrow
// folder, and purchasing.html downloads it and edits the supply lists. Both copies must stay word for word the same, or a PO
// downloaded from Purchasing would differ from the one filed. No database.   OUT=/tmp/allpages node test_arrow_po_same.js
const fs = require("fs");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
const read = (f) => fs.readFileSync(fs.existsSync(`${OUT}/${f}`) ? `${OUT}/${f}` : `${REPO}/${f}`, "utf8");
let bad = 0;
const ok = (n, c, x = "") => { if (!c) bad++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
/** a top-level function's text: from its first line to the first line that is just "}" */
function fn(src, head) {
  const i = src.indexOf(head); if (i < 0) return null;
  if (/^function parseOptions/.test(head)) return src.slice(i, src.indexOf("\n", i));
  const j = src.indexOf("\n}\n", i); return j < 0 ? null : src.slice(i, j + 2);
}
const office = read("office.html"), purch = read("purchasing.html");
for (const head of ["async function arrowPoPdf(PDFLib, po) {", "function parseOptions(text)", "function choicesFromForm(groups) {", "function choiceSummary(choices) {", "function supplyListFor(items, dept) {"]) {
  const a = fn(office, head), b = fn(purch, head);
  ok(`${head.replace(/\(.*$/, "").replace(/^(async )?function /, "")}: purchasing.html's copy is word for word office.html's`, !!a && a === b,
     !a ? "not in office.html" : !b ? "not in purchasing.html" : (() => { if (a === b) return ""; let k = 0; while (k < a.length && a[k] === b[k]) k++; return `differ at ${k}: «${a.slice(k, k + 60)}» vs «${b.slice(k, k + 60)}»`; })());
}
process.exit(bad ? 1 : 0);
