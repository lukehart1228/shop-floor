// The generator project's reference run (PROJ-00418), rebuilt from its fields, checked line by line.
// 18 Oct: the lab engine, taken from lab.html itself, against the generator project's hand-checked reference run (PROJ-00418)
// and the CNC template reference's hard rules. No database, no browser:  node test_lab_reference.js
const LAB = process.env.LAB || "/home/claude/sf/newrepo/lab.html";
const src = require("fs").readFileSync(LAB, "utf8"); const a = src.indexOf("/* Prototype lab engine"), b = src.indexOf("globalThis);", a) + "globalThis);".length;
const E = (() => { const module = { exports: {} }; new Function("module", src.slice(a, b))(module); return module.exports; })();
let fails = 0; const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
const base = { thickness: '1.25"', species: 'Ash', top_style: 'Plank Style, solid wood', edge_top: 'square', edge_bottom: 'square',
  base_material: 'metal', base_style: 'square plate', base_finish_type: 'powdercoat', power_units: 'none', grommets: 'none', magnets: 'none', total_height: '30"' };
const items = [
  ['TB-03 Round Ash', 1, 36, 36, 'Round'], ['TB-03 Square Maple', 2, 36, 36, 'Square'], ['TB-03 Ash (30 H)', 2, 36, 36, 'Round'],
  ['TB-04 Kitchen Ash', 3, 24, 36, 'Rectangle'], ['TB-04 Kitchen Maple', 3, 24, 36, 'Rectangle'], ['TB-06 Square', 3, 36, 36, 'Square'],
  ['DAN-DIN-36-72', 4, 36, 72, 'Rectangle'], ['DAN-DIN-42-72', 1, 42, 72, 'Ellipse'],
  ['TB-01 Option 2', 1, 36, 96, 'Rectangle', { top_style: 'Live edge slab', power_units: '1', power_model: 'Dean' }]];
const job = { items: items.map(([id, q, w, l, sh, extra], i) => ({ page: i + 2, form: 'TABLE', fields: Object.assign({}, base, { item_id: id, qty: String(q), width: w + '"', length: l + '"', top_shape: sh }, extra || {}) })) };
const S = E.woodTops(job, E.DEFAULT_RULES);
const want = [ // start L, starting W, stock, notes
  [38, '40" - 41"', "1st. 10'  2nd. 14'", 'NO BISCUITS!'], [38, '40" - 41"', "1st. 10'  2nd. 14'", ''], [38, '40" - 41"', "1st. 10'  2nd. 14'", 'NO BISCUITS!'],
  [38, '26" - 27"', "1st. 10'  2nd. 14'", ''], [38, '26" - 27"', "1st. 10'  2nd. 14'", ''], [38, '40" - 41"', "1st. 10'  2nd. 14'", ''],
  [74, '40" - 41"', "1st. 14'  2nd. 8'", ''], [74, '47" - 48"', "1st. 14'  2nd. 8'", 'NO BISCUITS!'], [98, '40" - 41"', "1st. 10'  2nd. 12'", '']];
S.forEach((s, i) => { const p = s.results.cut.pieces[0], w = want[i];
  ok(p.start_length === w[0] && p.starting_width === w[1] && p.optimal_stock === w[2] && s.results.cut.notes === w[3],
    `sheet ${i + 1} ${s.item_id}: ${p.start_length}" · ${p.starting_width} · ${p.optimal_stock} · "${s.results.cut.notes}"`); });
const row = (s) => s.results.cnc.template + ' ' + (s.results.cnc.inputs || []).map(([k, v]) => k + ' ' + v).join(' ');
const cncWant = [
  'Round_Template D 36 T 1.25 BEV 0 KN 0 BA 0 SDP 0 CDP 0 SG 0',
  'Rectangle_Template L 36 W 36 T 1.25 RC 0.04 CS 1 BEV 0 JFE 0 BA 0 SDP 0 SG 0 CDP 0',
  'Round_Template D 36 T 1.25 BEV 0 KN 0 BA 0 SDP 0 CDP 0 SG 0',
  'Rectangle_Template L 36 W 24 T 1.25 RC 0.04 CS 1 BEV 0 JFE 0 BA 0 SDP 0 SG 0 CDP 0',
  'Rectangle_Template L 36 W 24 T 1.25 RC 0.04 CS 1 BEV 0 JFE 0 BA 0 SDP 0 SG 0 CDP 0',
  'Rectangle_Template L 36 W 36 T 1.25 RC 0.04 CS 1 BEV 0 JFE 0 BA 0 SDP 0 SG 0 CDP 0',
  'Rectangle_Template L 72 W 36 T 1.25 RC 0.04 CS 1 BEV 0 JFE 0 BA 0 SDP 0 SG 0 CDP 0',
  null, // ellipse: the reference says custom; Luke says a template exists now
  'Rectangle_Template L 96 W 36 T 1.25 RC 0.04 CS 0 BEV 0 JFE 0 BA 0 SDP 1 SG 0 CDP 0'];
S.forEach((s, i) => { if (cncWant[i]) ok(row(s) === cncWant[i], `CNC sheet ${i + 1}: ${row(s)}`); });
ok(S[7].results.cnc.state === 'stuck' && /ellipse template/.test(S[7].results.cnc.missing), 'ellipse: stuck on the template inputs, not printed as a custom program');
ok(S[8].results.cnc.notes.some(n => /Live edge/.test(n)), 'live edge: CS 0 with a note to confirm');
ok(S[1].results.departments.departments.join(',') === 'milling,cnc,sanding,finishing,metal,assembly_qc', 'departments: metal base adds Metal');
// rules that the reference names
const one = (f) => E.woodTops({ items: [{ page: 2, form: 'TABLE', fields: Object.assign({}, base, { item_id: 'X', qty: '1' }, f) }] }, E.DEFAULT_RULES)[0];
let s = one({ width: '20"', length: '20"', top_shape: 'Round', grommets: '1' });
ok(row(s).includes('SG 1') && s.results.cnc.notes.some(n => /pod clearance/.test(n)), 'small round with a grommet: SG 1 and the pod-clearance note');
s = one({ width: '30"', length: '150"', top_shape: 'Rectangle', power_units: '1', port_cutout: '10 x 4' });
ok(s.results.cut.pieces[0].qty === 2 && row(s).includes('CDP 3') && !row(s).includes('CDPDL'), 'length split with a custom port: CDP 3, no CDPDL');
s = one({ width: '30"', length: '60"', top_shape: 'Rectangle', power_units: '1', power_config: '2 power' });
ok(s.results.cnc.state === 'stuck' && s.results.cnc.ask === 'power_unit', 'a power unit with no model: asks instead of guessing');
s = one({ width: '30"', length: '60"', top_shape: 'Rectangle', power_units: '1', power_model: 'Dean', port_cutout: '10 x 4' });
ok(row(s).includes('SDP 0') && row(s).includes('CDP 1'), 'both port kinds called for: keeps the custom port');
s = one({ width: '36"', length: '36"', top_shape: 'Round', grommets: '1 at back' });
ok(s.results.cnc.state === 'stuck', 'a grommet at the back of a round: asks');
s = one({ width: '30"', length: '60"', top_shape: 'Square with 1" Radius' });
ok(row(s).includes('RC 1') && s.results.cut.notes === 'NO BISCUITS!', 'radius corners: RC from the shape, NO BISCUITS!');
s = one({ width: '36"', length: '108"', top_shape: 'rectangle', base_material: 'wood', base_style: 'Slab leg - Mitered Joint', base_finish_type: 'stain', total_height: '36"' });
ok(row(s).includes('BEV 1') && s.results.departments.departments.indexOf('metal') < 0, 'slab leg: BEV 1, no Metal');
ok(!row(s).includes('LO') && !row(s).includes('CP ') && !row(s).includes('PWARN'), 'never prints LO, WO, CP or PWARN');
console.log(fails ? fails + ' FAILED' : 'ALL PASS');
