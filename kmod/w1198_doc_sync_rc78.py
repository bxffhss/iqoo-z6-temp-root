#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""§6.582：把 rc78 + hook_mask=0x1a 重打包后的登记值同步进两份文档。
原则：**现行口径句改现值；历史口径句加"当时"标注**（w415 R9 会把"当时/旧/→"前 30 字符内的登记当历史值）。
每条替换都带 count 断言：数不对就整体不写，别半改。"""
import io
import sys

EDITS = {
    "kmod/DELIVERY.md": [
        # ① 包内 stage 现值（原 83283149＝11-09 17:4x 那版；再往前 1ee14343＝11-07）
        ("包内 `z6root/ksu_post.sh`=`83283149`＝源逐字节同；★11-09 17:4x 社区化重打包后的现值（此前为 1ee14343，11-07 那版）",
         "包内 `z6root/ksu_post.sh`=`72484a47`＝源逐字节同；★11-09 19:1x 社区路线重打包后的现值（更早 83283149＝17:4x 那版、1ee14343＝11-07 那版）", 1),
        # ② 资产与凭据那行的 args 现值（原 67199f48）
        ("｜`kmod/ksu_args.txt`＝`67199f48…`｜★**已回归那对＝备份件**",
         "｜`kmod/ksu_args.txt`＝`7f2a8606…`(★11-09 §6.582 起：`ksu_hook_mask` 0x2→**0x1a**，让 access()/stat() 也走 sucompat 伪装；当时 `67199f48…`)｜★**已回归那对＝备份件**", 1),
        # ③ rc74b 那段"args 一个字都不用改"＝当时口径，加标注
        ("⇒ `kmod/ksu_args.txt`＝`67199f48…` 一个字都不用改",
         "⇒ 当时 `kmod/ksu_args.txt`＝`67199f48…` 一个字都不用改", 1),
        # ④ 11-07 那一栏的"现读"三件
        ("`z6root/kernelsu.ko`＝`2b1fd07eacb018296de788aaf0e903fc`(rc77；11-09 17:4x 重打包换出货)、`z6root/ksu_args.txt`＝`67199f4898c98371aa3ad0ef6f649e89`)",
         "`z6root/kernelsu.ko`＝`16b6c7c2a6f2a770c12b53ae03a331bd`(rc78；11-09 19:1x 社区路线重打包换出货)、`z6root/ksu_args.txt`＝`7f2a86067e35ad7f74205738636509c3`)", 1),
        # ⑤ 11-06 那一栏的"现读"三件
        ("`z6root/kernelsu.ko`＝`2b1fd07eacb018296de788aaf0e903fc`(rc77，11-09 换出货)、`z6root/ksu_args.txt`＝`67199f4898c98371aa3ad0ef6f649e89`",
         "`z6root/kernelsu.ko`＝`16b6c7c2a6f2a770c12b53ae03a331bd`(rc78，11-09 换出货)、`z6root/ksu_args.txt`＝`7f2a86067e35ad7f74205738636509c3`", 1),
        # ⑥ 开枪前那句硬要求（原格式 audit 抓不到，但语义已过期，一并改）
        ("**开每一发之前 `md5sum kmod/ksu_args.txt` 必须是 `67199f4898c98371aa3ad0ef6f649e89`**",
         "**开每一发之前 `md5sum kmod/ksu_args.txt` 必须是 `7f2a86067e35ad7f74205738636509c3`**（★11-09 §6.582：`ksu_hook_mask` 0x2→0x1a 之后；当时 67199f48）", 1),
    ],
    "kmod/W345_RC68_WINDOW.md": [
        ("＋ `md5sum kmod/ksu_args.txt`＝`67199f48…`。", "＋（当时）`md5sum kmod/ksu_args.txt`＝`67199f48…`。", 1),
        ("；②`md5sum kmod/ksu_args.txt`＝`67199f48…`", "；②（当时）`md5sum kmod/ksu_args.txt`＝`67199f48…`", 1),
        ("；⑥`md5sum kmod/ksu_args.txt`＝`67199f48…`", "；⑥（当时）`md5sum kmod/ksu_args.txt`＝`67199f48…`", 1),
        ("交付件 `kmod/ksu_args.txt`＝`67199f48…`", "交付件（当时）`kmod/ksu_args.txt`＝`67199f48…`", 1),
        ("- `md5sum kmod/ksu_args.txt` ＝ `67199f48…`", "-（当时）`md5sum kmod/ksu_args.txt` ＝ `67199f48…`", 1),
        ('"未被本轮改动"（`kmod/ksu_args.txt`＝`67199f48`）', '"未被本轮改动"（当时 `kmod/ksu_args.txt`＝`67199f48`）', 1),
    ],
}

bad = 0
for path, edits in EDITS.items():
    s = io.open(path, encoding="utf-8").read()
    orig = s
    for old, new, want in edits:
        got = s.count(old)
        if got != want:
            print("!! %s  count=%d want=%d :: %s" % (path, got, want, old[:60]))
            bad += 1
            continue
        s = s.replace(old, new)
    if s != orig and bad == 0:
        io.open(path, "w", encoding="utf-8", newline="").write(s)
        print("WROTE %s" % path)
    elif bad:
        print("!! %s 未写（上面有断言失败）" % path)

sys.exit(1 if bad else 0)
