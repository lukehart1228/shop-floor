import re,sys
src,pre,out=sys.argv[1:4]
lines=open(src).read().split('\n')
for i,l in enumerate(lines):
    if re.match(r'^#{3,4} ',l) and l.lstrip('#').strip().startswith(pre):
        rest='\n'.join(lines[i+1:])
        m=re.search(r'^(```+|~~~+)[a-zA-Z]*\n(.*?)^\1\s*$',rest,flags=re.S|re.M)
        open(out,'w').write(m.group(2)); print(out,len(m.group(2))); break
else: print("NOT FOUND",pre)
