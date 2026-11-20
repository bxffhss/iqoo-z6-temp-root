#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v29.1：清理块**不再删 ksu_post.sh / ksu_args.txt / ksu_stage.txt / ksu_cleanup**。

第四十五发的浪费过程：上一发(四十四)的清理块把 /data/local/tmp/ksu_post.sh 自己删了 ⇒
我在没重推的情况下打链 ⇒ pr 报 `[DONE] 全流程结束(没炸) RC=0`、写也落地了，但**没有 post 可跑**
⇒ ksu_stage.log 一行都没生成 ⇒ 整发白烧。
这些文件本身没有能力(纯脚本+参数)，删它们对"不留持久化"零收益、只埋雷。
"""
import io
import sys

P = "kmod/ksu_one_stage.sh"
L = io.open(P, encoding="utf-8", errors="replace").read().split("\n")

BS = chr(92)          # 反斜杠，避免在字符串里写转义
i = -1
for k, l in enumerate(L):
    if "rm -f /data/local/tmp/kernelsu.ko" in l:
        i = k
        break
if i < 0:
    print("!! 找不到清理块")
    sys.exit(1)
if not any("bn_before.txt" in x for x in L[i:i + 5]):
    print("!! 清理块形状不是预期的 4 行")
    sys.exit(1)

end = i
for k in range(i, i + 6):
    if "bn_before.txt" in L[k]:
        end = k + 1
        break

new = [
    "    rm -f /data/local/tmp/kernelsu.ko /data/local/tmp/susm /data/local/tmp/a10284.bin " + BS,
    "          /data/local/tmp/allow.bin /data/local/tmp/dmesg.live /data/local/tmp/bn_before.txt",
    "    # ★v29.1：**不再删 ksu_post.sh / ksu_args.txt / ksu_stage.txt / ksu_cleanup**。",
    "    #   第四十五发就是被这个脚枪废掉的：上一发的清理把 post 脚本自己删了，而我没重推 ⇒",
    "    #   链打穿、pr 报 [DONE] RC=0，但**没有 post 可跑** ⇒ stage 日志一行都没有，整发白烧。",
    "    #   这些文件没有能力(纯脚本+参数)，删它们对'不留持久化'零收益、只埋雷；要清的是",
    "    #   /data/adb/ksu 与 /data/adb/ksud(名单+ksud)、ko、susm 这些能落地的东西。",
]
L[i:end] = new

s = "\n".join(L)
old_head = "# ksu_one_stage.sh v29 —— v28 + 窗口内模块 runner"
new_head = ("# ksu_one_stage.sh v29.1 —— v29 + 清理块不再自删 post 脚本(md §6.64：第四十五发因此白烧)\n"
            + old_head)
if s.count(old_head) == 1 and "v29.1" not in s:
    s = s.replace(old_head, new_head, 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("清理块已改：原 %d..%d 行 -> %d 行" % (i, end, len(new)))
