#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# w361_dmesg_check.py —— 在"会被切半行/整段吞掉"的 dmesg.live 流上做**双向**取证（md §6.280）。
#   为什么不是 grep 一把梭：这条通道是 `dd if=/proc/kmsg bs=512 count=1` 一轮轮读的产物
#     ⇒ ①行会被切成半行(`KernelSU: tp_mark` 这种碎片)；②装载期那一整段可能被割掉
#     ⇒ 所以"某串计数=0"**永远不能当否据**，必须同时看：这一发**一定打过**的那组串是不是也 0。
#   用法：python3 kmod/w361_dmesg_check.py <文件> [词1 词2 ...]
#     不带词时用内置的默认对照表(装载/初始化必打 + 高频重复打)。
import io
import re
import sys

DEFAULT_MUST = [
    ("ADD_TRY_UMOUNT", "装载期", "ioctl 表转储，ko 一定打"),
    ("reboot kprobe registered", "装载期", "kprobe 注册回执"),
    ("KSUBEAT L5 before ksu_load_allow_list()", "装载期", "就在读名单之前"),
    ("allowlist version:", "装载期", "打开了文件才会打"),
    ("load_allow_uid", "装载期", "每条记录一次"),
    ("ksu_show_allow_list", "装载期", "装载收尾"),
    ("Crowning manager", "条件性", "只有真的加冕才打(126/130 都是 0，别当否据)"),
    ("tp_marker:", "装载期高频", "每任务一行"),
    ("KSUBEAT BN dispatcher entered", "运行期高频", "每 syscall 一行"),
    ("r72=", "运行期高频", "★rc72 的参数现值(正对照)"),
]


def main():
    path = sys.argv[1]
    words = sys.argv[2:]
    raw = io.open(path, encoding="utf-8", errors="replace").read()
    print("文件=%s 字符=%d 行数=%d" % (path, len(raw), raw.count("\n")))
    # 行被 HB 标记插坏过，先去标记再算
    clean = re.sub(r"--- HB up=[\d.]+ ---", "", raw)
    print("\n== 1) 逐词计数（**同一份文件里‘一定打过’的那些也一起数**：只有它们都在，0 才算否据）==")
    items = [(w, "", "") for w in words] if words else DEFAULT_MUST
    zero_must = []
    for w, phase, why in items:
        n = clean.count(w)
        print("   %-38s %6d   %s %s" % (w, n, ("[%s]" % phase) if phase else "", why))
        if n == 0 and phase == "装载期":
            zero_must.append(w)
    print("\n== 2) 命中行样本（每词最多 2 行，截 150 字符）==")
    lines = clean.splitlines()
    for w, _p, _y in items:
        hits = [L for L in lines if w in L]
        if not hits:
            continue
        print("   -- %s（共 %d 行）" % (w, len(hits)))
        for L in hits[:2]:
            print("      ", L[:150])
    print("\n== 3) 时间戳覆盖与空洞（>0.3 秒的空隙=通道漏读的那段）==")
    ts = []
    for m in re.finditer(r"\[\s*(\d+)\.(\d+)\]", clean):
        ts.append(int(m.group(1)) + int(m.group(2)[:3]) / 1000.0)
    ts.sort()
    if len(ts) < 2:
        print("   带时间戳的行不足 2 条 ⇒ 这条腿没送到东西(它自己就是被数的对象)")
    else:
        print("   带时间戳=%d 首=%.3f 末=%.3f" % (len(ts), ts[0], ts[-1]))
        holes = [(a, b) for a, b in zip(ts, ts[1:]) if b - a > 0.3]
        print("   >0.3 秒的空洞数=%d" % len(holes))
        for a, b in holes[-10:]:
            print("      %.3f -> %.3f (缺 %.3f s)" % (a, b, b - a))
    print("\n== 4) 判读规矩（写死，不许事后改）==")
    print("   a) 上面标'装载期'的那组里**有非 0 的**，才说明这段被送到过 ⇒ 此时某个具体串=0 才是否据；")
    print("   b) 那一组**全是 0** ⇒ 装载期整段没被送到(§6.280 的一手形状) ⇒ 任何'装载期串计数=0'都**不作数**；")
    print("   c) 参数/补丁的正对照只认**运行期高频**那一族(`r72=` 在 dispatcher 行里)——它不依赖装载期的时机。")
    if zero_must:
        print("   本机这份：装载期里数到 0 的词=%s" % zero_must)
        print("   ⇒ 若‘运行期高频’那几个也是 0，这份文件对装载期**没有任何否决力**。")


if __name__ == "__main__":
    main()
