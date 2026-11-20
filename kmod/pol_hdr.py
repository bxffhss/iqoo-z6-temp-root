import hashlib, itertools, os, struct, sys

arg = sys.argv[1] if len(sys.argv) > 1 else "pol"
cand = sys.argv[2] if len(sys.argv) > 2 else None
if os.path.isfile(arg):
    p = arg
    d = os.path.dirname(arg) or "."
else:
    d = arg
    p = cand or os.path.join(d, "precompiled_sepolicy")
b = open(p, "rb").read(8)
magic, ver = struct.unpack("<II", b)
print("precompiled_sepolicy bytes(first8) magic=0x%08x version=%u" % (magic, ver))
print("  SELINUX_MAGIC expected 0xf97cff8f -> match=%s" % (magic == 0xF97CFF8F))

def sha(paths):
    h = hashlib.sha256()
    for q in paths:
        h.update(open(q, "rb").read())
    return h.hexdigest()

plat = os.path.join(d, "plat_sepolicy.cil")
mdir = os.path.join(d, "mapping_system")
if not os.path.isdir(mdir):
    mdir = os.path.join(d, "mapping")
want = open(os.path.join(d, "plat_sepolicy_and_mapping.sha256")).read().strip()[:64]
print("target plat_sepolicy_and_mapping.sha256 =", want)
vers = sorted({f.split(".")[0] + "." + f.split(".")[1] for f in os.listdir(mdir) if f.endswith(".cil")})
hits = []
for v in vers:
    main = os.path.join(mdir, v + ".cil")
    comp = os.path.join(mdir, v + ".compat.cil")
    cands = []
    if os.path.exists(main):
        cands.append([plat, main])
        if os.path.exists(comp):
            cands.append([plat, main, comp])
            cands.append([plat, comp, main])
    for c in cands:
        h = sha(c)
        tag = "+".join(os.path.basename(x) for x in c)
        if h == want:
            hits.append(tag)
        print("  try %-52s -> %s %s" % (tag, h[:16], "MATCH" if h == want else ""))
print("MATCHES =", hits if hits else "none of the tried orders (Soong adds more inputs; see note)")
