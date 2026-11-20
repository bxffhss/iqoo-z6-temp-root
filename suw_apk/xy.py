import re,sys
s=open(sys.argv[1],encoding='utf-8',errors='replace').read()
want=sys.argv[2]
for m in re.finditer(r'<node\b[^>]*>',s):
    t=m.group(0)
    b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',t)
    if not b: continue
    def a(k):
        r=re.search(k+r'="([^"]*)"',t); return r.group(1) if r else ''
    if (a('text') or a('content-desc')).replace('\n',' ')==want and a('clickable')=='true':
        x1,y1,x2,y2=map(int,b.groups()); print('%d %d'%((x1+x2)//2,(y1+y2)//2)); break
