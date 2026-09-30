# Which SQL files define the same functions / views / triggers as a LATER file.
# Running the earlier file again would put back its older version of those pieces,
# so the later file must list it in replaces (sql_file_start('new.sql', '{old.sql}')).
# Usage: python3 overlaps.py /home/claude/sf/repo/sql [new.sql]
import re, sys, collections, os
d = sys.argv[1]
order = [r for r in __import__('subprocess').run(
    ["psql", "-h", "/tmp/pg", "-p", "5433", "-U", "postgres", "-d", "sync", "-At", "-c",
     "select file from sql_file_catalog order by run_order"], capture_output=True, text=True).stdout.split()] 
order = [f for f in order if os.path.exists(os.path.join(d, f))] + sys.argv[2:]
pat = re.compile(r'create\s+(?:or\s+replace\s+)?(function|view|trigger)\s+(?:if\s+not\s+exists\s+)?(?:public\.)?"?([a-z_0-9]+)', re.I)
defs = {}
for f in order:
    t = re.sub(r'--[^\n]*', '', open(os.path.join(d, f) if os.path.exists(os.path.join(d, f)) else f).read())
    defs[f] = {n.lower() for k, n in pat.findall(t)}
for i, f in enumerate(order):
    rep = collections.defaultdict(list)
    for g in order[:i]:
        both = defs[f] & defs[g]
        if both: rep[g] = sorted(both)
    if rep: print(f"{f} replaces: " + "; ".join(f"{g} ({', '.join(v)})" for g, v in rep.items()))
