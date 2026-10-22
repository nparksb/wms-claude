import sys,re
rows=[]
for line in open(sys.argv[1]):
    if '|' not in line: continue
    t,rest=line.strip().split('|',1)
    h,m,s=map(int,t.split(':')); ts=h*3600+m*60+s
    vals={k:list(map(int,v.split('/'))) for k,v in (p.split('=') for p in rest.split())}
    rows.append((ts,t,vals))
a,b=rows[0],rows[-1]; mins=(b[0]-a[0])/60
print(f"window {a[1]}..{b[1]} UTC = {mins:.1f} min, {len(rows)} samples")
for k in sorted(a[2]):
    d=[b[2][k][i]-a[2][k][i] for i in range(4)]
    print(f"{k:24s} seq_scan {d[0]/mins:7.2f}/min  seq_tup {d[1]/mins:13,.0f}/min  idx_scan {d[2]/mins:9,.0f}/min  idx_tup_fetch {d[3]/mins:13,.0f}/min")
# attribute FLA/location seq scans by second-of-minute of the increment
for k in ('fix_location_assignment','location'):
    buckets={}
    for (t0,_,v0),(t1,_,v1) in zip(rows,rows[1:]):
        inc=v1[k][0]-v0[k][0]
        if inc: buckets[(t0%60)//5*5]=buckets.get((t0%60)//5*5,0)+inc
    tot=sum(buckets.values())
    print(k, "seq_scan increments by second-of-minute (sample start):", {f":{s:02d}":n for s,n in sorted(buckets.items())}, "total",tot)
