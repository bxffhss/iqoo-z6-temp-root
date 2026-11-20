#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
5.4 移植补缺(2026-11-09)：让当前 ksu 树能在这个 5.4.281 内核树上编译。
只修两类 6.x-only 头文件缺口（现代 KernelSU HEAD#3755 引入，5.4 没有）：
  1) sulog/event.c 的 #include <linux/minmax.h> -> <linux/kernel.h>
     （5.4 的 min()/min_t()/max() 都在 kernel.h 里；minmax.h 是 5.8+ 才拆出来的）
  2) feature/sucompat.c 的 #include <linux/pgtable.h> 直接删除
     （该文件 grep 过零处 pgtable 符号使用，纯历史残留；linux/pgtable.h 是 5.8+ 才有）
两处都不动任何逻辑，纯 include 层适配，与既有 5.4 移植风格一致。
幂等：已应用则直接报错退出。
"""
import os
import sys

FILES = {
    "/root/k/ksu/kernel/sulog/event.c": ("#include <linux/minmax.h>",
                                         "#include <linux/kernel.h>"),
    "/root/k/ksu/kernel/feature/sucompat.c": ("#include <linux/pgtable.h>\n", ""),
}


def backup(p):
    b = p + ".ksud_bak"
    if not os.path.exists(b):
        os.system("cp -p '%s' '%s'" % (p, b))
        print("BACKUP -> " + b)


def main():
    for path, (old, new) in FILES.items():
        if not os.path.exists(path):
            sys.exit("FATAL: %s not found" % path)
        backup(path)
        with open(path, "r", encoding="utf-8") as f:
            txt = f.read()
        if old not in txt:
            # 可能已修过、或形态变了
            if new.strip() and new.strip() in txt:
                print("SKIP (already applied): " + path)
                continue
            sys.exit("GUARD: anchor not found in %s -> %r" % (path, old))
        if new == "":
            # 删除整行：去掉 old（含末尾换行）
            txt2 = txt.replace(old, "")
            print("REMOVED line in " + path)
        else:
            txt2 = txt.replace(old, new)
            print("REPLACED in " + path)
        with open(path, "w", encoding="utf-8") as f:
            f.write(txt2)
    print("BUILDFIX_APPLIED ok")


if __name__ == "__main__":
    main()
