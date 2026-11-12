// 11 Nov: the office's job page and item pages say where a job is in the same words as status.html (the sales logins'
// Job status page), from a copy of status.html's two blocks of that logic inside office.html. This keeps the copy word for
// word the same, so the office and sales never read different sentences. No database.   OUT=/tmp/allpages node test_job_status_same.js
const fs = require("fs");
const OUT = process.env.OUT || "/home/claude/sf/out", REPO = "/home/claude/sf/repo";
const read = (f) => fs.readFileSync(fs.existsSync(`${OUT}/${f}`) ? `${OUT}/${f}` : `${REPO}/${f}`, "utf8");
let bad = 0;
const ok = (n, c, x = "") => { if (!c) bad++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const st = read("status.html"), of = read("office.html");
const cutOut = (src, a, b) => { const i = src.indexOf(a), j = src.indexOf(b, i); return i < 0 || j < 0 ? null : src.slice(i, j); };
const blocks = [["dates and the job's sentence (summary, tripFact)", "  // ---------- dates, in the words the shop pages already use ----------", "  // ---------- the screens ----------"],
                ["one item's sentence and departments (itemSentence, itemWhy, itemTripFact)", "  // ---------- one item (one work order sheet): 4 Nov ----------", "  function arrowLine(s) {"]];
for (const [name, a, b] of blocks) {
  const want = cutOut(st, a, b);
  ok(`status.html has its block: ${name}`, !!want);
  ok(`…and office.html carries it word for word`, !!want && of.includes(want),
     !want || of.includes(want) ? "" : (() => { const i = of.indexOf(a); if (i < 0) return "not in office.html"; const got = of.slice(i, i + want.length); let k = 0; while (k < want.length && got[k] === want[k]) k++; return `differ at ${k}: «${want.slice(k, k + 60)}» vs «${got.slice(k, k + 60)}»`; })());
}
ok("office.html's copy sits inside the JS block that hands the functions out", /const JS = \(\(\) => \{[\s\S]*return \{ summary, tripFact, itemDepts, itemComplete, itemWhy, itemSentence, itemTripFact \};/.test(of));
process.exit(bad ? 1 : 0);
