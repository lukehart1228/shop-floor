// test_builder_catch.js — no page chains .catch or .finally straight onto a database request (2 Nov 2026).
// supabase-js 2.45.4's requests (db.rpc(...), db.from(...)...) are "thenables": they have then, but no catch and no
// finally, so db.rpc("x").catch(...) throws "catch is not a function" on the real library. That stopped the office's
// save and the zip drop on 2 Nov. The browser tests' pretend Supabase hands back real promises, so they can't see it;
// this reads the pages instead. Wrap a request first: Promise.resolve(db.rpc("x")).catch(...)
const fs = require("fs"), path = require("path");
const DIR = process.env.OUT;
if (!DIR) { console.log("FAIL  OUT (the folder of pages) isn't set"); process.exit(1); }
let pass = 0, fail = 0;
const ok = (what, good, more) => { if (good) pass++; else fail++; console.log(`${good ? "PASS" : "FAIL"}  ${what}${more ? "  — " + more : ""}`); };
/** each db.rpc( / db.from( chain whose next chained call (before any .then) is .catch( or .finally( : [line, call] */
function scan(src) {
  const hits = [], close = (i) => { let depth = 0, q = null; for (let j = i; j < src.length; j++) { const c = src[j];
      if (q) { if (c === "\\") { j++; continue; } if (c === q) q = null; continue; }
      if (c === '"' || c === "'" || c === "`") q = c; else if ("([{".includes(c)) depth++; else if (")]}".includes(c) && --depth === 0) return j; }
    return -1; };
  for (const m of src.matchAll(/\bdb\.(rpc|from)\(/g)) {
    let j = close(m.index + m[0].length - 1);
    while (j > 0) {
      let k = j + 1; while (k < src.length && /\s/.test(src[k])) k++;
      const mm = /^\.(\w+)\(/.exec(src.slice(k, k + 40)); if (!mm) break;
      if (mm[1] === "catch" || mm[1] === "finally") { hits.push([src.slice(0, m.index).split("\n").length, mm[1]]); break; }
      if (mm[1] === "then") break;
      j = close(k + mm[0].length - 1);
    }
  }
  return hits;
}
// the scanner itself, on made-up lines
ok("It finds .catch chained on a request, on one line or over several", scan('await db.rpc("a", { x: 1 }).catch(() => 1);').length === 1
   && scan('const r = await db.from("t")\n  .select("*")\n  .eq("id", 2)\n  .catch(f);').length === 1 && scan('db.rpc("a").finally(f)').length === 1);
ok("…and leaves alone a wrapped request, one turned into a promise by .then, and a .catch on something else", scan('await Promise.resolve(db.rpc("a")).catch(f);').length === 0
   && scan('db.from("t").select().then(r => r.data).catch(f);').length === 0 && scan('loadThing().catch(f); db.storage.from("b").remove(p).catch(f);').length === 0);
// every page
const files = fs.readdirSync(DIR).filter(f => /\.(html|js)$/.test(f)).sort();
ok(`There are pages to read (${files.length})`, files.length >= 5);
for (const f of files) {
  const hits = scan(fs.readFileSync(path.join(DIR, f), "utf8"));
  ok(`${f}: no .catch or .finally chained straight onto a database request`, !hits.length, hits.map(([l, c]) => `line ${l} (.${c})`).join(", "));
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
