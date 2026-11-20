#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc25：把我们所有 `KSUBEAT *` 诊断行从 `pr_info_ratelimited` 换成普通 `pr_info`（md §6.45）。

第二十二发的含混点就在这里：
  - pid 15723 有 `F sys_enter ... id=221 has_hook=1`（说明 handler 跑了、hook 也在），
    但**没有** `F2`、没有 `E*`、没有 `SD3/SD4/SD5`、也没有子进程被 su 改写成功的痕迹；
  - 而 `F2 / E1 / E2 / E3 / E4 / SD3 / SD5` **全都是 `pr_info_ratelimited`**，
    本机默认 `interval=5*HZ, burst=10` ⇒ 那一发的 F2 恰好停在 **10 条**。
  ⇒ "改道到底有没有生效、调度器从哪个出口出去"这三条判据**被限流吃掉**，一发窗口白花。

★别指望 `/proc/sys/kernel/printk_ratelimit*`：那是 `printk()` 自己的全局限流；
  `pr_*_ratelimited` 用的是**每个调用点各自编译期的 ratelimit_state**，sysctl 改不到它。
  ⇒ 只能改代码。判据行本来就该"要么印出来要么不写"，不该有第三种"可能被吃掉"。
风险核算：普通 pr_info 只在**已打标**任务的 execve 上跑；第二十二发实测这类事件
  ≈10 次/0.3 秒（uid 0 的 sh 风暴），SD1 一条普通 pr_info 就印了 102 次而设备没事 ⇒ 可接受。

幂等：文本级把 `pr_info_ratelimited("KSUBEAT` 换成 `pr_info("KSUBEAT`，做完就是 0 命中。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
FILES = [
    M + "/hook/syscall_hook_manager.c",
    M + "/hook/arm64/syscall_hook.c",
    M + "/feature/sucompat.c",
]
OLD = 'pr_info_ratelimited("KSUBEAT'
NEW = 'pr_info("KSUBEAT'

total = 0
for f in FILES:
    try:
        s = io.open(f, encoding="utf-8", errors="replace").read()
    except IOError as e:
        print("!! 读不到 %s (%s)" % (f, e))
        continue
    c = s.count(OLD)
    if c:
        s = s.replace(OLD, NEW)
        io.open(f, "w", encoding="utf-8", newline="\n").write(s)
        total += c
    print("  %-28s 换掉 %d 处" % (f.split("/")[-1], c))
print("总计 %d 处（0 = 已经换过或本来就没有）" % total)
