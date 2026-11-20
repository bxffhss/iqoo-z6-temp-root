#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""追加"续九"：社区路线落地（rc78 + hook_mask=0x1a + 重打包）。append-only。"""
import io
import sys

P = ".workbuddy/memory/2026-11-09.md"
BODY = """
## 19:0x–20:0x（续九）★按用户"按照社区路线做"落地：sucompat 去打印编出 **rc78**，`ksu_hook_mask` 0x2→**0x1a**，重打包 + 闸

- **动手前先把位定义与回落路径钉死（都是现读源码/内核树）**：
  - `hook/syscall_hook_manager.c:190-194`：bit0 setresuid／**bit1 execve**／bit2 execveat／**bit3 newfstatat**／**bit4 faccessat**；模块默认 `0x1f`。
  - `ksu_hook_newfstatat→ksu_handle_stat_sucompat`、`ksu_hook_faccessat→ksu_handle_faccessat_sucompat`，两者都先看 `ksu_su_compat_enabled`（`feature/sucompat.c:33` 默认 **true**）。
  - **faccessat2(439) 的坑排掉了**：内核树 `grep faccessat2` **为空**（5.8 才引入）⇒ 439 回 ENOSYS，bionic 的 `g_faccessat2_supported` 静态回落 ⇒ 落回**已挂的 48**。所以 `0x1a` 就够，不必为 439 加钩子。
- **★rc77 的 sucompat 是调试形状，直接开 bit3/bit4 会打印风暴**：stat handler 里 **9 条重复 `if (ksu_stat_off)`**、**13 条一模一样的 `pr_info("KSUBEAT FS0 …")`**、`pr_info_ratelimited`、每次落空都印 `KSUBEAT FS5 decline`；faccessat 里 6 条 `KSUBEAT FA*`。这两个号是全系统 stat/access 热路径。
- **补丁件 `kmod/patch_sucompat_quiet.py`**（md5 `525c57ad23c6c9bf1c9e6135e70fa175`）：大括号配对整函数替换成零打印等价实现。远端备份 `sucompat.c.bak_rc77`(25,244 B)，打完 496→**434 行**，`diff -u` 确认**只删打印/重复判断**；execve 主路径的 `KSUBEAT SU*/SD*` 证人**故意保留**（只在真 su exec 时打）。
- **rc78 出货 ko** `kmod/kernelsu_rc78.ko`＝**`16b6c7c2a6f2a770c12b53ae03a331bd`，5,107,568 B**（远端 make RC=0，版本仍 32653）。与 rc77 对表（全现读）：`KSUBEAT FA0/FA5/FS0/FS5` 各 **0**；`SU0`=1／`SU1`=6／`SD0`=1 仍在；**未定义符号 158 vs 159，差集只有 `___ratelimit` 少**（⇒ 零新增内核依赖，装入门径更松）；`__versions` 0x27c0 vs 0x2800；`.text` −608 B。拉回本地用 `kmod/pull_ko78.py`（`read_bytes('mount/kernelsu_rc78.ko')`，只有这个候选非空）。
- **参数**：`kmod/ksu_args.txt` → `ksu_hook_mask=0x1a`，md5 **`7f2a86067e35ad7f74205738636509c3`**（原 67199f48/0x2）。
- **静态 su 彻底关死**：`ksu_one_stage.sh` 里 su_deploy 那段由"opt-in 可开"改成**开关在也拒绝执行**、只留证人（防以后误开又踩 Momo）。现值 md5 **`72484a47…`／1145 行／CR=0**。
- **重打包**（打包器 md5 `93834a56…`，映射 `[kmod/kernelsu_rc78.ko]=kernelsu.ko`）：`z6root.zip`＝**`2e88ced7eaff7c147d9d54c780a0def3`**（17,858,038 B）；包内 ko=`16b6c7c2…`、args=`7f2a8606…`、`ksu_post.sh`=`72484a47…`（`cmp` 与源同一）、MANIFEST=`bc892625…`、入口件仍 `4c626324…`。
- **闸**：`run_z6pack.sh` **79 全绿**；`w415_doc_audit.py` **0 命中**（先红 12 条：DELIVERY.md 6＋W345 6，同步脚本 `kmod/w1198_doc_sync_rc78.py`＝`a3ef2882…`，原则＝现行句改现值/历史句加"当时"）；**整闸 w413 已启动**（存证 `kmod/w103_evidence/w413_sweep_1109-1915.txt`）。
- **下一发脚本已备**：`kmod/w1200_community_su.sh`（设备侧）——判据：①`/system/bin/su` 必须不存在、overlay=0；②授权 uid 的 `[ -x /system/bin/su ]`=OK、`ls -l` 打出 ksud、`which su`=`/system/bin/su`；③`su -c id`→uid=0；负向 uid 2000 三条全假。
- **设备本栏零接触**：未 insmod／未 reboot／枪数仍 9／`load` 仍 7；窗口还是 16:04 那个（Permissive／mod=1／`/dev/ksud` 0666／up≈12600s／无 overlay 无 su 文件）。
"""

s = io.open(P, encoding="utf-8").read()
if "续九" in s:
    print("!! 已有续九，不重复追加")
    sys.exit(1)
if not s.endswith("\n"):
    s += "\n"
io.open(P, "w", encoding="utf-8", newline="").write(s + BODY.lstrip("\n"))
print("APPENDED 续九")
