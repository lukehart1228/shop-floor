// 4 Nov: Arrow is a department of its own on the tablets. Who gets it, which tabs each department has, and which
// department a "Send something to Arrow" goes in under. The core functions, taken from the page itself; no database.
// Run: node test_arrow_dept.js   (PAGE=… for another tablet page; the live page from before 4 Nov fails)
const html = require("fs").readFileSync(process.env.PAGE || "/home/claude/sf/out/index.html", "utf8");
const core = html.slice(html.indexOf("const DEPTS = ["), html.indexOf("/* ---- Send routes"));
const m = new Function("atob", core + "; return { departmentsFor, tabsFor, arrowFromDefault: typeof arrowFromDefault === 'function' ? arrowFromDefault : null, DEPT_NAME };")(s => Buffer.from(s, "base64").toString());
let pass = 0, fail = 0;
const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${x ? "  — " + x : ""}`); };
const sup = (departments, look = []) => ({ role: "supervisor", departments, look });
const J = JSON.stringify;
const d = (me) => J(m.departmentsFor(me));
ok("Willie (Metal): Metal and Arrow", d(sup(["metal"])) === J(["metal", "arrow"]), d(sup(["metal"])));
ok("KP (Assembly / QC): Arrow and Assembly / QC, in the floor's order", d(sup(["assembly_qc"])) === J(["arrow", "assembly_qc"]), d(sup(["assembly_qc"])));
ok("Shawn (Delivery): Arrow and Delivery", d(sup(["delivery"])) === J(["arrow", "delivery"]), d(sup(["delivery"])));
ok("Eric (Full Custom + Assembly / QC): Full Custom, Arrow, Assembly / QC", d(sup(["full_custom", "assembly_qc"])) === J(["full_custom", "arrow", "assembly_qc"]), d(sup(["full_custom", "assembly_qc"])));
ok("Mike (Sanding + Finishing): no Arrow", !m.departmentsFor(sup(["sanding", "finishing"])).includes("arrow"));
ok("Sam (CNC, looking at Milling): no Arrow; looking at Metal doesn't give Arrow either", !m.departmentsFor(sup(["cnc"], ["milling", "metal"])).includes("arrow"));
ok("A manager: every department, Arrow after Metal", d({ role: "manager", departments: [] }) === J(["milling", "cnc", "sanding", "finishing", "full_custom", "metal", "arrow", "assembly_qc", "delivery"]));
ok("The Arrow department's name is Arrow", m.DEPT_NAME.arrow === "Arrow");
ok("Arrow has only the Arrow list", J(m.tabsFor("arrow")) === J(["arrow"]), J(m.tabsFor("arrow")));
ok("Metal, Assembly / QC and Delivery no longer have an Arrow tab", ["metal", "assembly_qc", "delivery"].every(k => !m.tabsFor(k).includes("arrow")),
   ["metal", "assembly_qc", "delivery"].map(k => k + ":" + m.tabsFor(k).join("/")).join(" "));
ok("…and keep the rest: Metal's Work orders and Recently completed, Delivery's Load-out", m.tabsFor("metal").includes("work") && m.tabsFor("metal").includes("past") && m.tabsFor("delivery")[0] === "loadout");
const f = m.arrowFromDefault || (() => "missing");
ok("Send something to Arrow from Metal's tablet goes in under Metal", f(sup(["metal"]), "metal") === "metal");
ok("…from Arrow, under the Arrow department the login works in (Eric: Assembly / QC; Shawn: Delivery)",
   f(sup(["full_custom", "assembly_qc"]), "arrow") === "assembly_qc" && f(sup(["delivery"]), "arrow") === "delivery");
ok("…a manager on Arrow: Metal unless they choose (the form offers the three)", f({ role: "manager", departments: [] }, "arrow") === "metal");
console.log(`\n${pass} PASS, ${fail} FAIL`); process.exit(fail ? 1 : 0);
