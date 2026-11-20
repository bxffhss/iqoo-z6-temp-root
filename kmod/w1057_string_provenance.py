#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1057_string_provenance.py —— 0 枪（纯本机）：判「我们编进 ko 的那份 SS 源码，与设备内核那份是不是同一出处」。

为什么要问这一格：第 81 发把凶手收窄到 stage3(我们自己那份 policydb_read 解析设备的活策略导出)。
  #216-B 整条路的**前提**是"我们编的这份 SS ＝ 设备里那份 SS 的同一语义"。这前提我一直只是"看着像"
  (两棵树 avtab_key/avtab 逐行相同)，从没拿**设备自己的二进制**核过。
  若设备那份源与本树有版本 delta(序列化格式/字段宽度/顺序不同)，我们就是在用错尺子读字节流：
  读飘 ⇒ 越界 ⇒ 量产机同步复位——那既是机制解释，也直接决定 #216 走 A 还是 B。

★为什么不比"帧大小/指令数"(那是编译器性质)：现读 linux_banner ⇒ 设备 Image 是 Android clang 11.0.2(-Os 系)，
  我们的件是容器里 clang 14，所以"设备 policydb_read 帧=208 / 我们那份=1024"**天然预期不同**，不能当源差异。
  源文件里的**错误消息字面量**是源性质 ⇒ 设备 Image 里有这条串 ⇒ 它那棵树里也有这条串。

★★这次自己踩到的坑(第一版就把它写在这儿，免得第二次)：我第一版**整文件**扫 .ko 的字符串，
  于是把 DWARF 的 `.debug_str`(里面全是 clang 落进去的**标识符名**：BPF_MAP_TYPE_ARRAY…)也算了进来；
  而设备 Image 是 stripped、没有 DWARF ⇒ "缺 150 条"其实是"人家没有调试段"，
  我却按判据句印出了「不同源坐实」。**那是仪器造的假结论，已在落账前收回。**
  本版：①只取 `.rodata*` 段(pyelftools 现读段名＋段大小＋串数，输入面自证)；
        ②候选必须是**像句子的**(含空格、长度>=20)，标识符一律不进；
        ③甲臂(我们的 SS 串)与乙臂(我们自己写的串)两臂必须翻面，同形即判"未测"。

口径(别把判据说过头)：甲臂**缺**一条 ⇒ 确实不同源(必要条件被否，这是硬结论)；
  甲臂**全在** ⇒ "同一出处"的强证据但不是证明(串恰好相同≠没带串的代码相同)。
跑法：PYTHONUTF8=1 python kmod/w1057_string_provenance.py
"""
import hashlib
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KO = os.path.join(HERE, "w986_polround_v4_cfi.ko")
IMG = os.path.join(ROOT, "analysis", "kernel_dev_g2a88cd145def.bin")
DEV_KO_MD5 = "f0e8ee245b231d827665b7aed9f30db7"    # 第 77~81 发推上设备那份(腿证件 expect= 同一串)

for p in (KO, IMG):
    if not os.path.exists(p):
        print("!! 缺资产 %s ⇒ 未测退出" % p)
        sys.exit(1)

ko_bytes = open(KO, "rb").read()
img = open(IMG, "rb").read()
ko_md5 = hashlib.md5(ko_bytes).hexdigest()
bi = img.find(b"Linux version ")
print("被测件 %s md5=%s %s bytes=%d" % (os.path.basename(KO), ko_md5,
      "＝设备那发的登记值(同一件)" if ko_md5 == DEV_KO_MD5 else "★与登记值不同！下面读数属于另一件",
      len(ko_bytes)))
print("被照 %s bytes=%d banner=%r" % (os.path.basename(IMG), len(img), img[bi:bi + 78].decode("ascii", "replace")))

# ---------- 1) 只从 .rodata* 段取串(输入面自证) ----------
from elftools.elf.elffile import ELFFile
rof = ELFFile(open(KO, "rb"))
sec_info, blob = [], b""
for s in rof.iter_sections():
    n = s.name
    if "rodata" in n or n in (".init.rodata",):
        try:
            d = s.data()
        except Exception:
            continue
        sec_info.append((n, len(d)))
        blob += d + b"\0"
print("用的段：%s 合计=%d B" % (", ".join("%s(%d)" % (n, sz) for n, sz in sec_info), len(blob)))
if not sec_info:
    print("!! 没取到任何 rodata 段 ⇒ 未测")
    sys.exit(1)

cands = sorted({m.group().decode("ascii", "replace")
                for m in re.finditer(rb"[\x20-\x7e]{20,}", blob)})
print(".rodata 里长度>=20 的串(去重)=%d 条" % len(cands))

# ---------- 2) 分类：像句子的才算；标识符/枚举名一律不进 ----------
SENT = re.compile(r"\s")
OWN = re.compile(r"w98[0-9]|w986|polround|z6ss_|rt_stage|rt_steps|/proc/w986|/data/local/tmp", re.I)
SS = re.compile(r"policydb|avtab|security server|selinux|sidtab|symtab|mls|constraint|boolean|"
                r"class |role |type |permissive|xperm|context|policy", re.I)
IDENT = re.compile(r"^[A-Z0-9_]+$")
sent = [s for s in cands if SENT.search(s) and not IDENT.match(s)]
own = [s for s in sent if OWN.search(s)]
ss = [s for s in sent if not OWN.search(s) and SS.search(s)]
print("像句子的=%d 其中 SS 相关(甲臂)=%d 我们自己写的(乙臂)=%d 其余忽略=%d" % (
    len(sent), len(ss), len(own), len(sent) - len(ss) - len(own)))
if len(ss) < 5 or len(own) < 5:
    print("!! 某一臂条数<5 ⇒ 分类没落地，本发未测(0 命中不能当结论)")
    sys.exit(1)


def n_in_img(s):
    return img.count(s.encode("ascii", "replace"))


ss_hit = [s for s in ss if n_in_img(s) > 0]
ss_miss = [s for s in ss if n_in_img(s) == 0]
own_hit = [s for s in own if n_in_img(s) > 0]
print("\n=== 甲臂：我们编进来的 SS 错误消息，在设备 Image 里 ===")
print("   命中=%d/%d  缺=%d" % (len(ss_hit), len(ss), len(ss_miss)))
for s in ss_miss[:30]:
    print("   [缺] %s" % s[:130])
print("\n=== 乙臂(负对照)：我们自己写的串，设备 Image 里应当一条都找不到 ===")
print("   意外命中=%d/%d" % (len(own_hit), len(own)))
for s in own_hit[:8]:
    print("   [★不该在却在] %s" % s[:120])

print("\n=== 判读 ===")
if len(own_hit) > 0 or len(ss_hit) == 0:
    print("   两臂没翻面 ⇒ 这把尺没牙，本发**未测**")
elif ss_miss:
    print("   ★甲臂缺 %d 条 ⇒ **不同源坐实**(必要条件被否)：我们那份 SS 与设备那份不是同一版本。" % len(ss_miss))
    print("     下一步：先拿到设备真正的 SS 出处(#203 那条 5.4.281 包)，再谈 A/B；在那之前不许再拿这份底料上机。")
else:
    print("   甲臂全命中、乙臂全缺失 ⇒ 尺子有效；『同一出处』拿到强证据(不等于证明：没带串的代码这格看不见)。")
    print("   ⇒ 下一个要问的是『不带串的字段宽度/顺序有没有 delta』：那要反汇编对照或 ASAN 台。")

# ---------- 3) 附：设备 Image 侧同口径数一遍(防"Image 里根本没有 SS 串"这种意外) ----------
dev = sorted({m.group().decode("ascii", "replace")
              for m in re.finditer(rb"[\x20-\x7e]{20,}", img)})
dev_ss = [s for s in dev if SS.search(s) and re.search(r"\s", s) and not IDENT.match(s)]
print("\n附：设备 Image 里像句子且 SS 相关的串(去重)=%d 条(Image 总串=%d)" % (len(dev_ss), len(dev)))
print("   样例 5 条：%s" % " | ".join(x[:44] for x in dev_ss[:5]))
