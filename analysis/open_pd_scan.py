#!/usr/bin/env python
# open_pd_scan.py —— §7(B)：在 open/release 那张同类型表(n=131)里，找
#   **“把 filp->private_data(偏移 +0xd8) 写成一个新分配/可塑形的堆对象”** 的成员。
# 为什么要它：`CFI-FOPS-TARGETS-20260927.md` §2/§3 证明了 `.read→stats_read` 的窗口基址
#   **固定在静态 .data**，够不到 cred/task_struct；要把窗口搬到堆上，唯一干净的路是让
#   `private_data` 指向一个**内容可被用户塑造**的堆对象。这张表里有没有这种成员 = 那条路存不存在。
#
# ★诚实约定(都是这个项目付过学费的)：
#   · 不写"可利用/任意读写"，只报指令形状；
#   · 筛子是**粗筛**：先找 `str xD,[xF,#0xd8]`(以及 `add x*,x*,#0xd8` 紧跟 `str`)，
#     再在同一函数里独立报"有没有调用分配器/有没有 copy_from_user"——两栏**不要求因果相连**，
#     所以命中是"值得人工读一眼"，不是"这就是原语"。谁把两栏连成一条链，得人工读；
#   · 每个函数整段反汇编(上限 8000 条)，被截断的必须列名，不许把"没看完"写成"没有"。
import importlib.util, io, sys, re, json, os, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sc", os.path.join(HERE, "ioctl_arg_scan.py"))
m = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):   # 复用 ioctl_arg_scan 的**已验证**映射，不自己发明地址算术
    spec.loader.exec_module(m)

BASE, data, md, by_name = m.BASE, m.data, m.md, m.by_name
TB = os.path.join(HERE, "cfi_type_tables.txt")
WANT_BASE = 0xffffffc011588684
CAP = 8000

HDR = re.compile(r"^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$")
names, line_no = [], None
for i, l in enumerate(io.open(TB, encoding="utf-8", errors="replace")):
    mm = HDR.match(l.strip())
    if mm and int(mm.group(2)) == 131 and int(mm.group(1), 16) == WANT_BASE:
        line_no, names = i + 1, [x.strip() for x in l.split("  ", 1)[1].split("|") if x.strip()]
        break
assert names, "没找到 base=0x%x n=131 那张表" % WANT_BASE
print("表行 %d  base=0x%x  n=%d" % (line_no, WANT_BASE, len(names)))

ALLOC = re.compile(r"(kmalloc|kzalloc|kmalloc_array|kcalloc|kmem_cache_alloc|alloc_pages|"
                   r"devm_k\w*alloc|kvzalloc|kvmalloc|__vmalloc|sock_kmalloc)\w*", re.I)
UACCESS = re.compile(r"(copy_from_user|_copy_from_user|copy_in_user|memdup_user|"
                     r"strdup_user|memdup_user_nul|import_single_buffer|move_addr_to_kernel)", re.I)
PD = "#0xd8"

out = {}
for nm in names:
    rec = by_name.get(nm.split("$")[0])
    if not rec:
        out[nm] = {"error": "no-symbol"}
        continue
    a = rec[0]
    end = min(m.func_end(a), a + 4 * CAP)
    size = (m.func_end(a) - a) // 4
    off = a - BASE
    hits, allocs, uaccs = [], [], []
    if 0 <= off and off + 4 * ((end - a) // 4) <= len(data):
        texts = []
        for ins in md.disasm(data[off:off + 4 * ((end - a) // 4)], a):
            texts.append((ins.address, ins.mnemonic, ins.op_str))
        for k, (pc, mnem, ops) in enumerate(texts):
            if mnem.startswith("str") and PD in ops:          # str xD,[xF,#0xd8]
                hits.append((hex(pc), mnem + " " + ops))
            if mnem == "add" and PD in ops:                   # add xF,xF,#0xd8 之后再 str
                for j in range(k + 1, min(k + 6, len(texts))):
                    if texts[j][1].startswith("str") and ("[" + texts[j][2].split(",")[0].strip() + "]") in texts[j][2]:
                        hits.append((hex(texts[j][0]), "间接: " + texts[k][1] + " " + texts[k][2]
                                     + " | " + texts[j][1] + " " + texts[j][2]))
                        break
            blob = ops
            if ALLOC.search(blob):
                allocs.append((hex(pc), mnem + " " + blob))
            if UACCESS.search(blob):
                uaccs.append((hex(pc), mnem + " " + blob))
        # 调用型分配器：`bl #addr` → 用 by_name 反查名字(指令里没有助记符名字)
        for pc, mnem, ops in texts:
            if mnem in ("bl", "b") and ops.startswith("#"):
                t = int(ops[1:], 16)
                got = m.name_at(t) if hasattr(m, "name_at") else None
                rn = got[0] if got else None      # name_at 回的是 (名字, 距符号起点的字节差)
                if rn:
                    if ALLOC.search(rn):
                        allocs.append((hex(pc), "bl→" + rn))
                    elif UACCESS.search(rn):
                        uaccs.append((hex(pc), "bl→" + rn))
    out[nm] = {"addr": hex(a), "size": size, "full": size <= CAP,
               "pd_store": hits, "alloc": allocs, "uacc": uaccs}

resolved = [n for n in names if "error" not in out[n]]
unres = [n for n in names if "error" in out[n]]
trunc = [n for n in resolved if not out[n]["full"]]
cand = [n for n in resolved if out[n]["pd_store"]]
both = [n for n in cand if out[n]["alloc"] and out[n]["pd_store"]]
print("解析 %d/%d，无法解析 %d，整段看完的截断函数 %d" % (len(resolved), len(names), len(unres), len(trunc)))
if unres: print("  无法解析:", unres)
if trunc: print("  仍截断(>8000 条):", trunc)
print("== 栏1：函数里出现 `str *,[x*,#0xd8]`(疑似写 private_data)的成员 %d 个 ==" % len(cand))
for n in cand:
    o = out[n]
    print("  %-34s %s  size=%d  pd写=%d  分配=%d  收用户数据=%d" %
          (n, o["addr"], o["size"], len(o["pd_store"]), len(o["alloc"]), len(o["uacc"])))
    for pc, ln in o["pd_store"][:2]:
        print("        %s  %s" % (pc, ln))
print("== 栏1∩栏2(同一函数里既写 +0xd8 又调分配器)： %d 个 ⇒ %s" % (len(both), both))
io.open(os.path.join(HERE, "open_pd_scan_out.json"), "w", encoding="utf-8").write(
    json.dumps(out, ensure_ascii=False, indent=1))
print("[ok] 明细落 analysis/open_pd_scan_out.json")
