import io, re, sys

paths = sys.argv[1:] or ['kmod/w103_evidence/sepolicy/plat_sepolicy.cil',
                         'kmod/w103_evidence/sepolicy/vendor_sepolicy.cil']
for p in paths:
    lines = io.open(p, encoding='utf-8', errors='replace').read().splitlines()
    allow = [l.strip() for l in lines if re.search(r'\(allow\s+\S+\s+\S+\s+\(anon_inode', l)]
    print("### %s : allow on anon_inode = %d 条" % (p, len(allow)))
    for l in allow:
        m = re.match(r'\(allow (\S+) (\S+) \(anon_inode \(([^)]*)\)\)', l)
        if not m:
            continue
        subj, obj, perms = m.group(1), m.group(2), m.group(3)
        if 'ioctl' in perms:
            print("   subj=%-24s obj=%-28s perms=%s" % (subj, obj, perms[:110]))
    # attribute membership for the app domain types we care about
    members = {}
    for l in lines:
        m = re.match(r'\(typeattributeset (\S+) \(([^)]*)\)\)', l.strip())
        if m:
            for t in m.group(2).split():
                members.setdefault(t, []).append(m.group(1))
    for t in ('untrusted_app_25', 'untrusted_app'):
        print("  %s 属于属性: %s" % (t, ' '.join(members.get(t, []))))
    # which attributes contain appdomain / domain as members is not needed; instead
    # list every attribute the app is in, then find allow rules whose subject matches.
    attrs = members.get('untrusted_app_25', []) + ['untrusted_app_25']
    print("  --- 命中 anon_inode:ioctl 的规则(主体或目标是 app 所在属性) ---")
    n = 0
    for l in allow:
        m = re.match(r'\(allow (\S+) (\S+) \(anon_inode \(([^)]*)\)\)', l)
        if not m or 'ioctl' not in m.group(3):
            continue
        if m.group(1) in attrs or m.group(2) in attrs:
            print("   ", l[:230]); n += 1
    print("  命中 %d 条" % n)
