#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MEMORY.md：①把"窗口 17:0x 现态（su 在位）"改成 19:0x 实情；②在硬纪律前插入 §6.582 社区路线块。"""
import io
import sys

P = ".workbuddy/memory/MEMORY.md"
OLD = "窗口 17:0x 现态：mod=1/Permissive/up≈4900s/`/dev/ksud` 0666/`/system/bin/su` 在位/0 不可逆改动。"
NEW = ("窗口 **19:0x 现态**：mod=1/Permissive/up≈12600s/`/dev/ksud` 0666/**无 overlay、`/system/bin/su` 不存在**"
       "（Momo 那条已清）/0 不可逆改动。")

BLOCK = """**★★社区路线（19:0x–20:0x，账本 §6.582）＝正确形状，取代 §6.580 那套静态 su**：用户报 Momo「找到可执行程序 su／分区挂载异常」⇒ 查实**官方 KSU 不放全局静态 su**（`feature/sucompat.c` `#define SU_PATH "/system/bin/su"`，内核在 syscall 入口把这条**路径**改道到 `ksu_ksud_path`）。决定性实验 `w1197`：把 `/system/bin/su` 真删掉后 `asuid 10667 /system/bin/su -c id` 仍 **uid=0**、`asuid 2000` 透出 ENOENT ⇒ 静态 su＋overlay 全撤（`umount -l` + `losetup -d`，lower 未动）。**以前"被迫造文件"的根因**＝`ksu_hook_mask=0x2` 只挂 bit1(execve)，而 `access()` 走 faccessat(48)、`stat()` 走 newfstatat(79)；位表 `hook/syscall_hook_manager.c:190-194`：bit0 setresuid/bit1 execve/bit2 execveat/**bit3 newfstatat/bit4 faccessat**（默认 0x1f）。**faccessat2(439) 不用管**：内核树 grep 不到（5.8 才引入）⇒ ENOSYS ⇒ bionic 回落 48。**但 rc77 的 sucompat 是调试形状**（stat 里 9 条重复 `if (ksu_stat_off)`＋13 条 `KSUBEAT FS0`＋`pr_info_ratelimited`＋每次落空印 FS5；faccessat 6 条 FA*）⇒ 直接开就是打印风暴。⇒ 补丁件 `kmod/patch_sucompat_quiet.py`(md5 `525c57ad…`) 整函数替换成零打印等价实现（远端 496→434 行，diff 只删打印；execve 的 `KSUBEAT SU*/SD*` 证人保留）⇒ 编出 **rc78 `kmod/kernelsu_rc78.ko`＝`16b6c7c2a6f2a770c12b53ae03a331bd`(5,107,568 B)**：`FA0/FA5/FS0/FS5` 各 0、未定义符号 158（只少 `___ratelimit`，零新增依赖）、`__versions` 0x27c0。`ksu_args.txt` 改 **`ksu_hook_mask=0x1a`**(md5 `7f2a8606…`)；`ksu_one_stage.sh` 把 su_deploy **硬关死**（开关在也拒绝，md5 `72484a47…`/1145 行）。重打包 `z6root.zip`＝`2e88ced7…`(17,858,038 B)；`run_z6pack` 79 全绿、`w415` 0 命中。**★rc78 一次没上机**（要干净 boot ＋ 一发枪，需现场点头）；判据脚本 `kmod/w1200_community_su.sh`。★`sucompat` 只改道**绝对路径** `"/system/bin/su"`，`which su`/PATH 查找靠 bit3/bit4 让 access/stat 看得见它。

"""

s = io.open(P, encoding="utf-8").read()
if "社区路线（19:0x–20:0x" in s:
    print("!! 已有该块")
    sys.exit(1)
assert s.count(OLD) == 1, "窗口现态句 count=%d" % s.count(OLD)
s = s.replace(OLD, NEW)
anchor = "## 硬纪律"
assert s.count(anchor) == 1
s = s.replace(anchor, BLOCK + anchor)
io.open(P, "w", encoding="utf-8", newline="").write(s)
print("MEMORY.md 已更新；新长度=%d" % len(s))
