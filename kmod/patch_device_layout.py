#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_device_layout.py —— 给"与设备同 config"的构建树打**布局补丁**（路线 B 的第一块砖）。

为什么只补三处（都有设备一手证据，见 kmod/ROUTE-B-OFFSET-INVERSION.md）：
  ① `arch/arm64/include/asm/thread_info.h`：设备 ti = 0x60 字节、`stack_canary @ 0x50`
     （`mrs SP_EL0` 之后 `[xN,#0x50]` 在全 text 出现 **5194 次** = 每函数序言的 per-task canary）
  ② `include/linux/sched.h`：task_struct 未知区 (树132..984) 里那 **+8** —— KSU 不读这一段里的
     任何字段，所以**插在哪儿都无害**，插在 `normal_prio` 之后
  ③ `include/linux/module.h`：设备 `struct module` = 960/init@392/exit@888，QC 树 896/368/824
     ⇒ `init` 前 +24、`init..exit` 之间 +40（exit 之后两边字节数相同，已核对）
合起来正好复现"尾部 δ=+64"：56(ti) + 8(中段) = 64 ✓

纪律（[[feedback-scripted-edits-anchors]]）：**只用唯一文本锚点**定位，锚点不唯一就当场报错退出，
绝不按行号切片。撤销 = `git -C <树> checkout -- <三个头文件>`（树是 git clone，改完会打印 git diff --stat）。

用法：python3 patch_device_layout.py <树目录> [--dry-run]
"""
import os, re, sys

DRY = "--dry-run" in sys.argv
tree = sys.argv[1]


def block_span(text, header_re):
    """返回 (start, end)：从 header_re 命中的 `{` 起，到配对的最外层 `};` 结束。"""
    m = re.search(header_re, text)
    if not m:
        raise SystemExit("找不到块起始: " + header_re)
    i = text.index("{", m.end() - 1)
    depth, j = 0, i
    while j < len(text):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i, j          # j 指向配对的 }
        j += 1
    raise SystemExit("块没有配对的 }")


def sub_in_block(text, header_re, pat, rep, label):
    a, b = block_span(text, header_re)
    seg = text[a:b]
    n = len(re.findall(pat, seg))
    if n != 1:
        raise SystemExit(f"[{label}] 锚点在块内出现 {n} 次(要求恰好 1 次) ⇒ 拒绝猜测，退出：{pat}")
    return text[:a] + re.sub(pat, rep, seg, count=1) + text[b:]


def append_in_block(text, header_re, add, label):
    a, b = block_span(text, header_re)
    return text[:b] + add + text[b:]


def patch(path, edits):
    p = os.path.join(tree, path)
    if not os.path.isfile(p):
        raise SystemExit("没有这个文件: " + p)
    s = open(p, encoding="utf-8", errors="replace").read()
    orig = s
    if "__pad_vivo_" in s:
        # 幂等闸门：锚点在打过补丁的文件里**依然唯一**，所以不挡就会二次插桩
        # (2026-09-30 就这么把 module 打成 1024：+64 被加了两遍)
        print("已打过补丁，跳过 " + path)
        return
    for kind, *args in edits:
        if kind == "append":
            hdr, add, label = args
            s = append_in_block(s, hdr, add, label)
        else:
            hdr, pat, rep, label = args
            s = sub_in_block(s, hdr, pat, rep, label)
    print(("已改 " if s != orig else "无变化 ") + path + f"  (+{len(s) - len(orig)} 字节)")
    if not DRY and s != orig:
        open(p, "w", encoding="utf-8", newline="\n").write(s)


TI_PAD = (
    "\n\t/* === 布局补丁(vivo 设备实测, kmod/ROUTE-B-OFFSET-INVERSION.md) === */\n"
    "\tchar\t\t__pad_vivo_ti1[0x50 - 40];\t/* 设备 ti=0x60: 把 canary 顶到 +0x50 */\n"
    "\tu64\t\tstack_canary;\t\t/* 实测: mrs SP_EL0 之后 [xN,#0x50] 共 5194 次 */\n"
    "\tchar\t\t__pad_vivo_ti2[0x60 - 0x58];\n"
)
TS_PAD = (
    "\n\t/* === 布局补丁: 未知区(+8) —— KSU 不读这一段里的任何字段, 插这里无害 === */\n"
    "\tchar\t\t__pad_vivo_ts[8];\n"
)
MD_PAD_A = "\n\t/* === 布局补丁: 设备 init@392 (树 368) ⇒ 前面多 24 字节 === */\n\tchar\t\t__pad_vivo_mod_a[24];\n"
MD_PAD_B = "\n\t/* === 布局补丁: 设备 exit@888 (平移后 848) ⇒ 这里再多 40 字节 === */\n\tchar\t\t__pad_vivo_mod_b[40];\n"

patch("arch/arm64/include/asm/thread_info.h", [
    ("append", r"struct thread_info", TI_PAD, "thread_info 尾部"),
])
patch("include/linux/sched.h", [
    ("sub", r"struct task_struct \{", r"(\n[ \t]*int[ \t]+normal_prio;)",
     r"\1" + TS_PAD, "task_struct 中段"),
])
patch("include/linux/module.h", [
    ("sub", r"struct module \{", r"([ \t]*/\* Startup function\. \*/)",
     MD_PAD_A.strip("\n") + "\n\\1", "module init 前"),
    # ★不打第二条：`core_layout` 是 64 字节对齐的(__module_layout_align)。
    # 树里 init@368(正好 64 对齐, 到 core_layout@384 只差 8)；加了 24 之后 init@392 ⇒
    # 对齐强制 core_layout 跳到 448，**自动产生 40 字节空隙** ⇒
    #   exit: 824 + 24 + 40 = 888 ✓   sizeof: 896 + 64 = 960 ✓   (与设备逐字吻合)
    # 所以设备的 960 主要是"对齐 + 24 字节前缀"，不是厂商在 exit 之前塞了 40 字节字段。
    # （2026-09-30 我先按 +24/+40 两条打，结果 1024/928 —— 就是这个对齐效应没算进去。）
])
print("完成。撤销：git -C %s checkout -- <上面三个文件>" % tree)
