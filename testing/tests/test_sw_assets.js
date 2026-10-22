// sw.js (21 Oct, shell v4): the shop's own scripts and stylesheets are fetched fresh when connected and served from the
// saved copy when not — like pages — so a shared file can change in place. Libraries, icons: saved copy first, as before.
// Runs the real sw.js in Chromium against a local stand-in for GitHub Pages. SW=/home/claude/sf/repo/sw.js fails its
// "changed in place" lines (the 30 Sep worker served the saved copy for ever).
// Run with PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1
const fs = require("fs"), path = require("path"), http = require("http");
const { chromium } = require(process.env.PW || "/home/claude/.npm-global/lib/node_modules/playwright");
const SW = process.env.SW || "/home/claude/sf/out/sw.js", REPO = "/home/claude/sf/repo";
let pass = 0, fail = 0; const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const files = {
  "/sw.js": [fs.readFileSync(SW, "utf8"), "application/javascript"],
  "/manifest.webmanifest": [fs.readFileSync(REPO + "/manifest.webmanifest"), "application/manifest+json"],
  "/icon-192.png": [fs.readFileSync(REPO + "/icon-192.png"), "image/png"],
  "/icon-512.png": [fs.readFileSync(REPO + "/icon-512.png"), "image/png"],
  "/sf-common-test.js": ["window.SF_MARK = 'one';", "application/javascript"],
  "/sf-style-test.css": ["body { --sf-mark: 'one'; }", "text/css"],
  "/index.html": [`<!doctype html><html><head><link rel="stylesheet" href="./sf-style-test.css"><script src="./sf-common-test.js"></script></head>
<body><p id="p">page one</p><script>navigator.serviceWorker.register("./sw.js");</script></body></html>`, "text/html"],
};
let online = true, hits = {};
const server = http.createServer((req, res) => {
  let p = req.url.split("?")[0].replace(/^\/shop-floor/, ""); if (p === "/" || p === "") p = "/index.html";
  hits[p] = (hits[p] || 0) + 1;
  if (!online) { req.socket.destroy(); return; }
  const f = files[p]; if (!f) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": f[1], "Cache-Control": "no-store" }); res.end(f[0]);
});
(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r)); const base = `http://127.0.0.1:${server.address().port}/shop-floor/`;
  const browser = await chromium.launch(); const ctx = await browser.newContext({ serviceWorkers: "allow" }); const page = await ctx.newPage();
  const mark = async () => page.evaluate(() => [window.SF_MARK, getComputedStyle(document.body).getPropertyValue("--sf-mark").trim().replace(/'/g, "")]);
  await page.goto(base); await page.waitForFunction(() => navigator.serviceWorker && navigator.serviceWorker.controller, null, { timeout: 15000 });
  ok("the worker installs and takes the page", true);
  await page.reload(); await page.waitForLoadState("load");
  let [js, css] = await mark(); ok("under the worker the page gets the script and the stylesheet", js === "one" && css === "one", `${js} ${css}`);
  files["/sf-common-test.js"][0] = "window.SF_MARK = 'two';"; files["/sf-style-test.css"][0] = "body { --sf-mark: 'two'; }";
  await page.reload(); await page.waitForLoadState("load"); [js, css] = await mark();
  ok("a script changed in place arrives on the next load with a connection", js === "two", js);
  ok("a stylesheet changed in place arrives too", css === "two", css);
  online = false; const before = hits["/sf-common-test.js"];
  await page.reload().catch(() => {}); await page.waitForLoadState("load").catch(() => {}); [js, css] = await mark().catch(() => ["", ""]);
  ok("with no connection the page still opens from the saved copy", (await page.textContent("#p").catch(() => "")) === "page one");
  ok("and gets the saved script and stylesheet (the newest it saw)", js === "two" && css === "two", `${js} ${css}`);
  online = true; files["/sf-common-test.js"][0] = "window.SF_MARK = 'three';";
  await page.reload(); await page.waitForLoadState("load"); [js] = await mark(); ok("back online, the next change arrives again", js === "three", js);
  const names = await page.evaluate(async () => (await caches.keys()).join(","));
  ok("the saved copies live in shop-floor-shell-v4 only", names === "shop-floor-shell-v4", names);
  await browser.close(); server.close(); console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FAIL  " + e.message); server.close(); process.exit(1); });
