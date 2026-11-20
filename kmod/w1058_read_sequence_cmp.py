#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1058_read_sequence_cmp.py —— 0 枪（纯本机）：把 #216-B 前提里**最后一格**问到底。

已知：§6.499 用"源性质"的证人(错误消息字面量)给了"我们那份 SS ＝ 设备那份同一出处"的强证据；
但**字符串相同不证明读序相同**，而"读序/字段宽度"正是会不会把 1.36 MB 读飘的承重那一格。
⇒ 这一格不猜：拿**两份编译产物**同法抽"每个函数按顺序调了谁＋传给 size 的立即数"再对齐比。
   甲＝设备裸 Image 里的 `policydb_read`(`analysis/kernel_dev_g2a88cd145def.bin`＋同构建 kallsyms)
   乙＝我们编进 ko 的那份(`kmod/w986_polround_v4_cfi.ko`，md5 现核＝设备那发的 `f0e8ee24…`)

★为什么不比帧大小/指令数/寄存器分配：那些是**编译器性质**(设备 clang 11 -Os／我们 clang 14)，天然不同
  (§6.499 已经因此收回过一次误读)。这里只比**语义形状**：调用目标的名字序列＋size 立即数。
★仪器纪律：
  · **负对照**：两个不同函数(`avtab_read` vs `ebitmap_read`)的序列必须**不相等**；若相等＝抽取把谁都做成同一个
    ⇒ 上面所有对比作废(SEQ_TEETH=0)。
  · 符号名一律从产生者(kallsyms／ELF symtab＋.rela.text)现读；函数边界也现算；
  · 两边取不到的函数**如实记"单边/未对比"**，不计入"全部一致"；
  · 首处分歧要印**两边各自的上下文**(索引＋前后 4 项)。
  · 分支目标**自己按编码算**(capstone 各版本给 target 的属性名不一样；我不用它，避免"属性名不对⇒全 0 命中")。
跑法：PYTHONUTF8=1 python kmod/w1058_read_sequence_cmp.py
"""
import bisect
import hashlib
import os
import re
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KS = os.path.join(ROOT, "analysis", "kallsyms_g2a88cd145def.txt")
IMG = os.path.join(ROOT, "analysis", "kernel_dev_g2a88cd145def.bin")
KO = os.path.join(HERE, "w986_polround_v4_cfi.ko")
BASE = 0xffffffc010080000
DEV_KO_MD5 = "f0e8ee245b231d827665b7aed9f30db7"
WANT = ["policydb_read", "policydb_write", "policydb_init", "avtab_read", "avtab_init",
        "avtab_search", "avtab_insert", "ebitmap_read", "ebitmap_init", "ebitmap_set_bit",
        "symtab_read", "symtab_init", "mls_read", "mls_range_read", "mls_level_read",
        "sidtab_init", "cond_read_list", "cond_read_avtab_link", "role_read", "type_read",
        "class_read", "user_read", "bounds_read", "read_isids", "filename_trans_read"]

for p in (KS, IMG, KO):
    if not os.path.exists(p):
        print("!! 缺资产 %s ⇒ 未测退出" % p)
        sys.exit(1)
m = hashlib.md5(open(KO, "rb").read()).hexdigest()
print("乙(我们的件) %s md5=%s %s" % (os.path.basename(KO), m,
      "＝设备那发登记值" if m == DEV_KO_MD5 else "★与登记值不同！"))
print("甲(设备 Image) %s bytes=%d" % (os.path.basename(IMG), os.path.getsize(IMG)))

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)


def norm(name):
    """①摘掉 clang 产生的 `.llvm.N/.cold/.constprop.N` 后缀(优化器的事，不是语义)；
       ②把内核的 **`__pi_` 前缀**(受保护的 inline 包装别名，`__pi_memcpy`≡`memcpy`)折回本名——
         第一版没做这一步，于是"甲=`__pi_memset` vs 乙=`memset`"被数成了 9 处差异，
         全是**名字马甲**不是语义(例 187②那条"文本差≠语义差"的二进制版)。"""
    n = re.sub(r"\.(llvm|cold|constprop|part|clone)\.[0-9a-zA-Z_]+$", "", name)
    n = re.sub(r"^__pi_", "", n)
    return n


def bl_target(word, pc):
    """B/BL：imm26 有符号，单位 4 字节 ⇒ target = pc + (sext(imm26) << 2)。自己算，不靠绑定。"""
    if (word >> 26) != 0x25:          # 不是 B/BL
        return None
    imm = word & 0x03FFFFFF
    if imm & (1 << 25):
        imm -= (1 << 26)
    return (pc + (imm << 2)) & 0xFFFFFFFFFFFFFFFF


# ---------------- 甲：设备裸 Image + kallsyms ----------------
syms = []
for ln in open(KS, encoding="utf-8", errors="replace"):
    p = ln.split()
    if len(p) >= 3 and re.fullmatch(r"[0-9a-f]{16}", p[0]) and p[1] in "tT":
        syms.append((int(p[0], 16), p[2]))
syms.sort()
addrs = [a for a, _ in syms]
img = open(IMG, "rb").read()



# ★SS 代码块：厂商那份把 role_read/type_read/class_read 都**内联**掉了(kallsyms 里查无此名)，
#   而内核里**别的文件**也有叫 `user_read` 的 static ⇒ 只按名字挑，会挑到别人家那个(第一版就差点把
#   "项数不同 甲1/乙8"当成语义差异)。这里用一批**必然在 SS 里**的名字把地址范围夹出来，块外的候选一律不算。
SS_ANCHOR = ["policydb_read", "policydb_write", "policydb_destroy", "policydb_load_isids",
             "sidtab_context_to_sid", "avtab_search", "ebitmap_get_bit", "symtab_search",
             "mls_context_cpy", "hashtab_map"]
_anchors = sorted(a for a, n in syms if norm(n) in SS_ANCHOR)
SS_WIN = 262144          # ±256KB：SS 那些 .o 是连着排的，但**不同文件**的函数会散开一点
def in_ss(a):
    return bool(_anchors) and min(abs(a - x) for x in _anchors) <= SS_WIN
print("SS 锚点=%d 个 ⇒ 0x%x..0x%x (跨度 %d B)，判定用**距任一锚点 <= %d B**" % (
    len(_anchors), _anchors[0] if _anchors else 0, _anchors[-1] if _anchors else 0,
    (_anchors[-1] - _anchors[0]) if _anchors else 0, SS_WIN))
print("   ★为什么不用 min..max 一整块：第一版那么做把 `cond_read_list`(在 conditional.c，另段)判成『块外』，"
      "于是**把上一轮明明匹配过的一行踢掉了**＝筛子过紧会自己制造『未对比』。改成距离规则后要用这条回归自检。")

def dev_name(tgt, pc):
    if tgt is None:
        return "非直调"
    i = bisect.bisect_right(addrs, tgt) - 1
    if i < 0:
        return "界外"
    if addrs[i] != tgt:               # ★只认恰好落在符号起点：落到别人函数中间的名字是**假名字**
        return "非表内目标"
    return norm(syms[i][1])


def dev_seq(target):
    """★kallsyms 里 **static 函数可以同名**(不同 .c 各有一个 `user_read`/`role_read` 很正常)。
       第一版取 `hits[0]`(地址最低那个)⇒ 可能比的是**别人家那个函数**，于是"项数不同"是仪器挑错对象。
       本版：多解就明说 AMBIG，不猜、也不计入判据(与"'未测'不许改写成通过"同一条规矩)。"""
    all_hits = [(a, n) for a, n in syms if norm(n) == target]
    hits = [(a, n) for a, n in all_hits if in_ss(a)]
    if not hits:
        return None, 0
    if len(hits) > 1:
        return None, len(hits)          # 多解 ⇒ 交给调用侧标"未对比(同名多解)"
    if len(all_hits) > len(hits):
        print("   [%s] ★丢掉 %d 个**块外**同名候选(别人家的同名 static)" % (target, len(all_hits) - len(hits)))
    a0 = hits[0][0]
    i = bisect.bisect_right(addrs, a0)
    end = addrs[i] if i < len(addrs) else a0 + 4096
    off = a0 - BASE
    if off < 0 or off >= len(img):
        return None, 1
    return walk(img[off:off + (end - a0)], a0, dev_name, "设备"), 1


# ---------------- 乙：我们的 .ko（ELF symtab ＋ .rela.text）----------------
from elftools.elf.elffile import ELFFile
ef = ELFFile(open(KO, "rb"))
SECS = list(ef.iter_sections())   # pyelftools 没有 ef.sections；按迭代顺序自己存一份(索引＝段号)
text = ef.get_section_by_name(".text")
if text is None:
    print("!! .ko 里没有 .text ⇒ 未测")
    sys.exit(1)
tdata = text.data()
taddr = int(text["sh_addr"])
# ★符号在 .symtab 里，不在 .text 这个 Section 对象上(pyelftools 的 Section 没有 symbol_iter)；
#   用 st_shndx 把符号绑回 .text 那段，别按"名字像"就收。
st = ef.get_section_by_name(".symtab")
if st is None:
    print("!! 没有 .symtab(件被 strip 了?) ⇒ 本发未测：乙侧没有符号可对照")
    sys.exit(1)
TEXT_IDX = [i for i, s in enumerate(SECS) if s.name == ".text"][0]
kSym, kSize = {}, {}
for s in st.iter_symbols():
    if s["st_info"]["type"] == "STT_FUNC" and int(s["st_shndx"]) == TEXT_IDX and s.name:
        kSym[int(s["st_value"])] = s.name
        kSize[s.name] = int(s["st_size"])
kAddrs = sorted(kSym)
print("乙侧 .symtab 里绑回 .text 的函数符号=%d 条" % len(kSym))
# ★reloc 的符号名在**它自己链接的那张符号表**里(sh_link)，不是 .text 的；上一版直接问 sec.symbol_at
#   结果一条名字都没取到 ⇒ 所有外部调用退化成"bl 到自己"(target 是占位 0)。这就是那批"乙全是自己"的成因。
rel, rel_total = {}, 0
for i, sec in enumerate(ef.iter_sections()):
    if not sec.name.startswith(".rela.text"):
        continue
    link = int(sec["sh_link"])
    syms_sec = SECS[link]
    for r in sec.iter_relocations():
        rel_total += 1
        idx = r["r_info_sym"]
        nm = ""
        try:
            nm = syms_sec.get_symbol(idx).name
        except Exception:
            nm = ""
        if not nm:                      # 有些是对**段**的重定位(段名字在 sh_name 里)
            try:
                sh = SECS[idx]
                nm = "SEG:" + sh.name
            except Exception:
                nm = ""
        if nm:
            rel[int(r["r_offset"])] = norm(nm)
print("乙侧：函数符号=%d 条 .rela.text 重定位=%d 条 其中有名=%d 条" % (len(kSym), rel_total, len(rel)))
if rel_total and len(rel) == 0:
    print("!! 有名=0 ⇒ 乙侧名字全不可用，本发未测")
    sys.exit(1)


def ko_name(tgt, pc):
    # 顺序很重要：**先查这条 bl 位置上的重定位**(它就是"要调谁"的权威)，再退回按地址查符号。
    ro = rel.get(pc)
    if ro:
        return ro
    if tgt is None or tgt == pc:      # 占位 0 ⇒ 没名字可用，绝不许回落成"自己"
        return "无名(reloc 缺)"
    i = bisect.bisect_right(kAddrs, tgt) - 1
    if i < 0 or kAddrs[i] != tgt:     # 只认**恰好落在符号起点**的目标
        return "非表内目标"
    return norm(kSym[kAddrs[i]])


def ko_seq(target):
    cand = [v for v, n in kSym.items() if norm(n) == target]
    if not cand:
        return None, 0
    if len(cand) > 1:                 # 我们这份是单个 .ko，同名多解同样是挑错对象
        return None, len(cand)
    v0 = min(cand)
    off = v0
    sz = kSize.get(target, 0) or 8192
    if off < 0 or off >= len(tdata):
        return None, 1
    return walk(tdata[off:off + sz], off, ko_name, "我们"), 1


# ---------------- 同一条抽取通道 ----------------
def walk(code, pc0, name_of, side):
    """pc0：这段代码的"地址"。设备侧＝真实内核地址；.ko 侧＝.text 内偏移(ET_REL 的 st_value/r_offset 都是偏移)。"""
    seq = []
    pend = {}
    n = len(code) - (len(code) % 4)
    for k in range(0, n, 4):
        word = struct.unpack_from("<I", code, k)[0]
        pc = pc0 + k
        t = bl_target(word, pc)
        if (word >> 26) == 0x25:
            mn = "bl" if ((word >> 31) & 1) else "b"
            seq.append((mn, name_of(t, pc), pend.get("w1", "-"), pend.get("w2", "-")))
            pend = {}
            continue
        try:
            ins = list(md.disasm(code[k:k + 4], pc))
        except Exception:
            ins = []
        if not ins:
            continue
        x = ins[0]
        o = x.op_str
        if x.mnemonic in ("mov", "movz") and re.match(r"^w\d+, #", o):
            r = o.split(",")[0].strip()
            mv = re.search(r"#(0x[0-9a-fA-F]+|\d+)", o)
            if mv:
                pend[r] = int(mv.group(1), 0)
        elif x.mnemonic == "ret":
            break
        elif x.mnemonic in ("br", "blr"):
            seq.append((x.mnemonic, "间接", "-", "-"))
    return seq


rows = []
print("\n=== 逐个函数抽序列（两边都取到的才比） ===")
for fn in WANT:
    a, na = dev_seq(fn)
    b, nb = ko_seq(fn)
    if a is None and b is None:
        continue
    if (a is None and na > 1) or (b is None and nb > 1):
        print("   %-22s 甲候选=%d 乙候选=%d ⇒ **未对比(同名多解，挑不出是哪个文件那个)**" % (fn, na, nb))
        rows.append((fn, a, b, "多解"))
        continue
    if a is None or b is None:
        print("   %-22s 甲=%s(%d) 乙=%s(%d) ⇒ **未对比**(只有一侧有)" % (fn, "有" if a else "无", na, "有" if b else "无", nb))
        rows.append((fn, a, b, "单边"))
        continue
    diff = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
    first = diff[0] if diff else None
    if len(a) == len(b) and not diff:
        verdict = "完全同(项数＋目标＋size)"
    elif len(a) == len(b):
        verdict = "项数同，%d 处不同" % len(diff)
    else:
        verdict = "项数不同 甲%d/乙%d" % (len(a), len(b))
    print("   %-22s 甲=%3d 乙=%3d 首个不同=%s ⇒ %s" % (fn, len(a), len(b), first, verdict))
    rows.append((fn, a, b, verdict))
    if first is not None:
        lo = max(0, first - 4)
        print("      甲[%d:]: %s" % (lo, a[lo:first + 5]))
        print("      乙[%d:]: %s" % (lo, b[lo:first + 5]))

pr_a, _n1 = dev_seq("policydb_read")
pr_b, _n2 = ko_seq("policydb_read")
print("\n=== ★`policydb_read` 两边的完整调用序列(逐项并排，给人眼看的证据) ===")
if pr_a and pr_b:
    for i in range(max(len(pr_a), len(pr_b))):
        x = pr_a[i] if i < len(pr_a) else ("-", "-", "-", "-")
        y = pr_b[i] if i < len(pr_b) else ("-", "-", "-", "-")
        print("   %2d  甲 %-26s w1=%-5s w2=%-5s | 乙 %-26s w1=%-5s w2=%-5s %s" % (
            i, x[1], x[2], x[3], y[1], y[2], y[3], "" if x == y else "  <<< 不同"))
_known = [fn for fn in ("policydb_read", "avtab_read", "ebitmap_read", "cond_read_list", "symtab_init")
          if any(r[0] == fn and r[3] == "单边" for r in rows)]
print("\n=== ★筛子回归自检：这些名字**应当**在设备侧找得到；被踢成『单边』＝筛子过紧 ===")
print("   被踢的：%s" % (", ".join(_known) or "无(筛子没有误踢)"))
both = [r for r in rows if r[3] not in ("单边", "多解")]
print("\n=== 判读 ===")
if not both:
    print("   两侧都有且**没有同名多解**的函数=0 ⇒ 本发未测")
    sys.exit(1)
same = [r[0] for r in both if r[3].startswith("完全同")]
cntdiff = [r[0] for r in both if r[3].startswith("项数不同")]
print("   可对比=%d 完全同=%d 项数不同=%d 项数同但有差异=%d" % (
    len(both), len(same), len(cntdiff), len(both) - len(same) - len(cntdiff)))
print("   项数不同的函数：%s" % (", ".join(cntdiff) or "无"))

print("\n=== ★负对照(SEQ_TEETH)：不同函数的序列必须不相等 ===")
x, _nx = dev_seq("avtab_read"); y, _ny = dev_seq("ebitmap_read")
if x is None or y is None:
    print("   夹具取不到(avtab_read/ebitmap_read 之一不在 kallsyms) ⇒ 这一臂未测")
else:
    print("   avtab_read(%d 项) vs ebitmap_read(%d 项) 相等? %s" % (len(x), len(y), x == y))
    print("   SEQ_TEETH=%s" % ("1" if x != y else "0(★抽取把不同函数做成同一个 ⇒ 上面所有对比作废)"))
print("\n口径：size 只看 w1/w2 两个位(内核 `file_read(buf, fp, size)` 的 size 一般在 w2)；"
      "放别的寄存器时这格会是 '-'——那是抽取的盲点，不是设备的差异。")
