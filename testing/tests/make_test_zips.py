# Test zips for test_zip_drop.js, made the way the Outputs project makes them (Python's zipfile, deflated).
import json, zipfile, base64, sys, os, copy
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
PDF = base64.b64encode(b"%PDF-1.4\n1 0 obj<<>>endobj\n%%EOF\n").decode()
def upload(job, arrow=True):
    sheets = [
      {"sheet_number": 1, "item_code": "X-1", "qty": 2, "departments": ["sanding"], "extras": [],
       "arrow": [{"qty": 4, "base": "DAN", "description": "Angled Post Leg, 3\" x 1.5\" Rectangular Tube", "pd_color": "Denim Black", "arrow_color": "PCU90229 Denim Black"}]},
      {"sheet_number": 2, "item_code": "X-2", "qty": 1, "departments": ["sanding"], "extras": [], "arrow": []}]
    if not arrow: del sheets[1]["arrow"]
    return {"kind": "shop-floor-work-order", "format": 1, "payload": {"project_id": job, "total_items": 3, "sheets": sheets},
            "files": [{"sheet_number": 1, "png": PNG, "pdf": PDF}, {"sheet_number": 2, "png": PNG, "pdf": PDF}]}
def make(name, files, job="PROJ-00502", fmt=1, meta=None, extra_unlisted=None, size_lie=None):
    entries = []
    for path, data, m in files:
        b = data if isinstance(data, bytes) else data.encode()
        e = {"path": path, "what": m.get("what", "file"), "bytes": len(b)}
        e.update({k: v for k, v in m.items() if k != "what"})
        if size_lie == path: e["bytes"] += 1
        entries.append((path, b, e))
    c = {"kind": "shop-floor-zip", "format": fmt, "job": job, "made_at": "2026-11-03T14:05:00-05:00", "files": [e for _, _, e in entries]}
    with zipfile.ZipFile(os.path.join(out, name), "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("contents.json", json.dumps(c, indent=1))
        for path, b, _ in entries: z.writestr(path, b)
        if extra_unlisted: z.writestr(extra_unlisted, b"stray")
J = "PROJ-00502"
base = [
  (f"Floor/{J}_upload.json", json.dumps(upload(J)), {"what": "upload file"}),
  (f"Floor/{J}_Production_Sheets.pdf", b"%PDF-1.4 work order\n", {"what": "work order"}),
  ("Files/Metal drawings/X-1 base.pdf", b"%PDF-1.4 drawing\n", {"what": "metal drawing"}),
  (f"Files/Arrow/{J}_Arrow_PO.xlsx", b"PK fake xlsx " * 50, {"what": "Arrow PO"}),
  ("Router/00502-X1.mpr", "[H\nVERSION=\"4.0\"\n] program r1\n" * 20, {"what": "CNC program", "machine": "homag", "item": "X-1", "part": "Top", "revision": 1}),
  (f"Bend-Tech/{J}_X-1_V-Arm.step", "ISO-10303-21; v-arm\n" * 30, {"what": "STEP file", "machine": "bendtech", "item": "X-1", "part": "V-Arm", "revision": 1}),
  ("Database/Metal/Cut sheets/SAM 30x60.pdf", b"%PDF-1.4 cut sheet\n", {"what": "cut sheet", "replaces": False})]
make("PROJ-00502.zip", base)
make("unlisted.zip", base, extra_unlisted="Files/Other/stray.txt")
make("wrongsize.zip", base, size_lie="Files/Metal drawings/X-1 base.pdf")
noarrow = copy.deepcopy(base); noarrow[0] = (noarrow[0][0], json.dumps(upload(J, arrow=False)), noarrow[0][2]); make("noarrow.zip", noarrow)
wrongitem = copy.deepcopy(base); wrongitem[4] = (wrongitem[4][0], wrongitem[4][1], dict(wrongitem[4][2], item="Z-9")); make("wrongitem.zip", wrongitem)
make("design-v1.zip", base + [("Design/X-1 whole.step", "ISO-10303-21; whole\n", {"what": "3D model", "item": "X-1"})])
rev = copy.deepcopy(base); rev[4] = (rev[4][0], "[H\nVERSION=\"4.0\"\n] program r2\n" * 20, dict(rev[4][2], revision=2))
make("PROJ-00502-rev.zip", rev)
make("PROJ-00502-v2.zip", base + [("Design/X-1 whole.step", "ISO-10303-21; whole\n", {"what": "3D model", "item": "X-1"})], fmt=2)
make("Database 2026-11-03.zip", [("Database/CNC/Other/Round 36.mpr", "program\n", {"what": "CNC program", "replaces": False}),
                                 ("Database/Metal/Cut sheets/SAM 30x60.pdf", b"%PDF-1.4 cut sheet REVISED\n", {"what": "cut sheet", "replaces": True})], job=None)
with open(os.path.join(out, "not-a-zip.zip"), "wb") as f: f.write(b"this is not a zip")
# a zip whose file doesn't match its own checksum (stored, then one byte changed)
make("badcrc.zip", base)
with zipfile.ZipFile(os.path.join(out, "badcrc.zip")) as z: info = z.getinfo("Files/Metal drawings/X-1 base.pdf")
raw = bytearray(open(os.path.join(out, "badcrc.zip"), "rb").read())
with zipfile.ZipFile(os.path.join(out, "stored.zip"), "w", zipfile.ZIP_STORED) as z:
    with zipfile.ZipFile(os.path.join(out, "badcrc.zip")) as src:
        for n in src.namelist(): z.writestr(n, src.read(n))
raw = bytearray(open(os.path.join(out, "stored.zip"), "rb").read())
i = raw.find(b"%PDF-1.4 drawing"); raw[i + 5] = ord("X")
open(os.path.join(out, "badcrc.zip"), "wb").write(raw); os.remove(os.path.join(out, "stored.zip"))
def variant(name, i, path=None, meta=None, data=None, **kw):
    v = copy.deepcopy(base); pth, d, m = v[i]
    v[i] = (path or pth, data if data is not None else d, meta(m) if meta else m); make(name, v, **kw)
variant("format3.zip", 2, fmt=3)
variant("badjob.zip", 2, job="PROJ-512")
variant("loose.zip", 2, path="Files/X-1 base.pdf")
variant("wrongext.zip", 4, path="Router/00502-X1.txt")
variant("nomachine.zip", 4, meta=lambda m: {k: v for k, v in m.items() if k != "machine"})
variant("badname.zip", 2, path="Files/Other/a:b.pdf")
variant("badlib.zip", 6, path="Database/Paint/SAM.pdf")
variant("libjobnull.zip", 2, job=None)
print("made", len(os.listdir(out)))
