import sys, zipfile
descs = {
 b"Lorg/springframework/security/access/annotation/Secured;":"@Secured",
 b"Ljakarta/annotation/security/RolesAllowed;":"@RolesAllowed(jakarta)",
 b"Ljakarta/annotation/security/DenyAll;":"@DenyAll(jakarta)",
 b"Ljakarta/annotation/security/PermitAll;":"@PermitAll(jakarta)",
 b"Ljavax/annotation/security/RolesAllowed;":"@RolesAllowed(javax)",
 b"Ljavax/annotation/security/DenyAll;":"@DenyAll(javax)",
 b"Ljavax/annotation/security/PermitAll;":"@PermitAll(javax)",
 b"Lorg/springframework/security/access/prepost/PreAuthorize;":"@PreAuthorize(CONTROL)",
}
jars = [j for j in open(sys.argv[1]).read().strip().split(':') if j.endswith('.jar')]
print("jars scanned:", len(jars))
hits = {}
for j in jars:
    try: z = zipfile.ZipFile(j)
    except Exception as e: print("SKIP",j,e); continue
    for n in z.namelist():
        if not n.endswith('.class'): continue
        try: b = z.read(n)
        except Exception: continue
        for d,label in descs.items():
            if d in b:
                # exclude the annotation's own declaration class
                hits.setdefault(label, []).append(j.split('/')[-1] + " :: " + n)
for label in sorted(descs.values()):
    v = hits.get(label, [])
    print(f"\n{label}: {len(v)} carrier class(es)")
    for x in v[:40]: print("   ", x)
    if len(v)>40: print("    ... +", len(v)-40)
