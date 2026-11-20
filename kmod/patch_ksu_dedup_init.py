#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 sucompat.c 里 `path[0] = 0;` 那一条**每次构建都会多长一行**的积累收敛成一行。

成因(一手，已定位)：`patch_ksu_decline.py` 的 SD-INIT 那条用
    if "KSUBEAT SD-INIT" in s: continue
做幂等闸，但它插入的那行注释里**没有** `KSUBEAT SD-INIT` 这个串 ⇒ 闸永远不成立，
而锚点(下一行的 `if (execveat && ...)`)每次仍然只命中 1 次 ⇒ 每次构建都往前插一行。
第 68 次构建时数到 64 行(见 §6.246)。语义上是无害的冗余 store，但它是"闸门自己骗自己"的样本。

做法与闸：
  - 只认这一条语句(带 tag 或不带 tag 两种写法)，把**连续**的若干行折成 1 行(带 tag 的那版)；
  - 折完断言：带 tag 的 1 行、不带的 0 行、总数 1 行；对不上就**不写回**；
  - 幂等：第二次跑总数已经是 1 ⇒ 直接 skip；
  - 字节读写(rb/wb) + 严格 UTF-8，绝不做有损 round-trip。
"""
import io
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/feature/sucompat.c"

KEEP = ('    path[0] = 0; /* KSUBEAT SD-INIT：任何一条"放弃"打印都不许读到未初始化栈'
        '(这个函数的 path 是栈上数组) */\n')
PAT = re.compile(r'^    path\[0\] = 0; /\* (?:KSUBEAT SD-INIT：)?任何一条.*\*/\n$')


def main():
    raw = io.open(F, "rb").read()
    try:
        s = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        print("  !! %s 不是合法 UTF-8(%s) ⇒ 停" % (F, e))
        return 2

    lines = s.splitlines(True)
    hits = [i for i, l in enumerate(lines) if PAT.match(l)]
    print("  折叠前：命中 %d 行 @%s..%s，字节=%d" % (len(hits), hits[0] + 1 if hits else "-",
                                                  hits[-1] + 1 if hits else "-", len(raw)))
    if len(hits) <= 1:
        print("  [skip] 已经不超过 1 行，不需要折叠")
        return 0

    # 必须全是连续行；不连续就停(说明我对形状的理解错了，别硬改)
    if hits[-1] - hits[0] + 1 != len(hits):
        print("  !! 命中的 %d 行不连续 ⇒ 停，人工看" % len(hits))
        return 1

    out = lines[:hits[0]] + [KEEP] + lines[hits[-1] + 1:]
    txt = "".join(out)
    n_tag = txt.count("KSUBEAT SD-INIT：")
    n_all = len([l for l in txt.splitlines(True) if PAT.match(l)])
    if n_all != 1 or n_tag != 1:
        print("  !! 折叠后自检 总数=%d 带tag=%d(都应为 1) ⇒ 不写回" % (n_all, n_tag))
        return 1

    nb = txt.encode("utf-8")
    io.open(F, "wb").write(nb)
    print("  ok 已折叠：行 %d -> %d，字节 %d -> %d，SD-INIT tag=1" % (
        len(lines), len(out), len(raw), len(nb)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
