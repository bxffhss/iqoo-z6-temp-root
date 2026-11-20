#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rc35：在 core/init.c 的 init 末尾(killscan 旁边)加一句 ksu_fd_install_run()。

为什么放这里：参数 setter 里不能干活(dev_syms 的符号那时还没解析，task_work_add 转发会返回
-ENOSYS ⇒ rc34 整个 insmod 直接 "Function not implemented")；而 init.c:202 这行的位置是
"符号层已热好 + throne tracker 已经跑完(管理器已加冕) + 还没把模块 sysfs 摘掉"。
幂等：认自己插入的标记串。
"""
import io
import sys

MARK = "ksu_fd_install_run"
ANCHOR = "    { extern void ksu_killscan_run(void); ksu_killscan_run(); }"


def main():
    m = sys.argv[1]
    p = m + "/core/init.c"
    s = io.open(p, encoding="utf-8").read()
    if MARK in s:
        print("init.c 已打过(跳过)")
        return 0
    if s.count(ANCHOR) != 1:
        print("!! 锚点不唯一: %d" % s.count(ANCHOR))
        return 1
    add = ANCHOR + ("\n    /* rc35(md §6.80)：把驱动 fd 补装进 insmod 参数指定的任务(官方 Manager 只靠"
                    "\n     *   扫 /proc/self/fd 找 [ksu_driver]，native 层没有 reboot 超级调用)。 */\n"
                    "    { extern void ksu_fd_install_run(void); ksu_fd_install_run(); }")
    s = s.replace(ANCHOR, add)
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)
    print("init.c 已加 ksu_fd_install_run() 调用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
