import sys,xml.etree.ElementTree as ET
def load(p):
    out={}
    for tc in ET.parse(p).getroot().iter('testcase'):
        st,msg='pass',''
        for t in ('error','failure','skipped'):
            e=tc.find(t)
            if e is not None: st=t; msg=(e.text or e.get('message') or '').strip().splitlines()[:2]
        out[tc.get('class','')+'::'+tc.get('name','')]=(st,' | '.join(msg)[:260] if msg else '')
    return out
a,b=load(sys.argv[1]),load(sys.argv[2])
print('only in',sys.argv[1],len(set(a)-set(b)),' only in',sys.argv[2],len(set(b)-set(a)))
ch=sorted(k for k in set(a)&set(b) if a[k][0]!=b[k][0])
print('changed:',len(ch))
for k in ch: print(f'\n{k}\n   {a[k][0]}: {a[k][1]}\n   {b[k][0]}: {b[k][1]}')
