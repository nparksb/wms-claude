import re, subprocess, sys
REPO="/Users/np1076/dev/spk/owl/v2/wms2-api"
REF="origin/develop"
def git(*a): return subprocess.run(["git","-C",REPO,*a],capture_output=True,text=True,check=True).stdout
PRIMS=[".transferUnitLoadToLocation(",".transferUnitLoadToCarrier(",".transferStockToUnitLoad(","stockunitService.transferStock("]
CONST=r'(?:WmsConstants\.)?(?:BusinessObjectLockState\.)?[A-Z_][A-Z0-9_]*|\d+'
def strip_comments(s):
    # blank out comments and string literals, preserving newlines/offsets
    out=list(s); i=0; n=len(s)
    while i<n:
        if s.startswith("//",i):
            j=s.find("\n",i); j=n if j<0 else j
            for k in range(i,j): out[k]=' '
            i=j
        elif s.startswith("/*",i):
            j=s.find("*/",i+2); j=n if j<0 else j+2
            for k in range(i,j):
                if s[k]!='\n': out[k]=' '
            i=j
        elif s[i]=='"':
            j=i+1
            while j<n and s[j]!='"':
                if s[j]=='\\': j+=1
                j+=1
            for k in range(i+1,min(j,n)): 
                if s[k]!='\n': out[k]=' '
            i=j+1
        else: i+=1
    return "".join(out)
def match_paren(s,i,o='(',c=')'):
    d=0
    for j in range(i,len(s)):
        if s[j]==o: d+=1
        elif s[j]==c:
            d-=1
            if d==0: return j
    return -1
def body_after(s,j):
    k=j+1
    while k<len(s) and s[k].isspace(): k+=1
    if k<len(s) and s[k]=='{':
        e=match_paren(s,k,'{','}'); return s[k:e+1]
    e=s.find(';',k); return s[k:e+1]
def top_level_throw(body):
    b=body.strip()
    if not b.startswith('{'): return b.startswith('throw ')
    d=0
    for m in re.finditer(r'[{}]|\bthrow\s',b):
        t=m.group(0)
        if t=='{': d+=1
        elif t=='}': d-=1
        elif d==1: return True
    return False
EXCLUDED=[]
def is_zero(c): return c.endswith("NOT_LOCKED") or c=="0"
def comparisons(cond, localvars):
    comps=[]
    for m in re.finditer(r'getEntityLock\(\)\s*(==|!=)\s*('+CONST+')',cond): comps.append((m.group(1),m.group(2)))
    for m in re.finditer(r'('+CONST+r')\s*(==|!=)\s*[\w.()]*getEntityLock\(\)',cond): comps.append((m.group(2),m.group(1)))
    for m in re.finditer(r'(!?)\s*Integer\.valueOf\(\s*('+CONST+r')\s*\)\.equals\([^;{]*?getEntityLock\(\)\s*\)',cond):
        comps.append(('!=' if m.group(1) else '==',m.group(2)))
    for v in localvars:
        for m in re.finditer(r'\b'+re.escape(v)+r'\s*(==|!=)\s*('+CONST+')',cond): comps.append((m.group(1),m.group(2)))
    return comps
def scan(text, direct_only=False):
    s=strip_comments(text)
    localvars=set(re.findall(r'\b(?:int|Integer)\s+(\w+)\s*=\s*[^;]*getEntityLock\(\)',s))
    hits=[]
    for m in re.finditer(r'\bif\s*\(',s):
        i=m.end()-1; j=match_paren(s,i)
        if j<0: continue
        cond=s[i:j+1]; body=body_after(s,j)
        throws = top_level_throw(body)
        if not throws: continue
        comps=comparisons(cond,localvars)
        if not comps: continue
        if any(is_zero(c) for _,c in comps):
            EXCLUDED.append((s.count("\n",0,m.start())+1," ".join(cond.split())[:90])); continue
        line=s.count("\n",0,m.start())+1
        hits.append((line," ".join(cond.split())[:110]))
    return hits
if __name__=="__main__":
    files=[f for f in git("ls-tree","-r","--name-only",REF,"--","src/main/java").split() if f.endswith(".java")]
    scope=[]
    for f in files:
        t=git("show",f"{REF}:{f}")
        if any(p in strip_comments(t) for p in PRIMS): scope.append((f,t))
    extra="src/main/java/net/aim_ai/wms/util/MoveUnitloadSourceLockPolicy.java"
    print(f"scope: {len(scope)} classes (policy class present on develop: {extra in files})")
    total=0
    for f,t in scope:
        EXCLUDED.clear()
        for line,cond in scan(t):
            total+=1; print(f"  OFFENDER {f.split('/')[-1]}:{line}  {cond}")
        for line,cond in EXCLUDED:
            print(f"  allowlist-conjunct (not an offence) {f.split('/')[-1]}:{line}  {cond}")
    print("offenders:",total)
