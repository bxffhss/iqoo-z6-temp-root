#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 §6.582 追加到路线账本末尾（append-only，不搬历史栏）。"""
import io
import sys

P = "kmod/ROUTE-B-OFFSET-INVERSION.md"
BODY = """
## §6.582　11-09 19:0x–20:0x（**★Momo 红字把"②标准 su"判成错形状 ⇒ 改回社区路线：内核 sucompat 伪装 `su`；静态 su ＋ overlay 全部撤掉；rc78＝sucompat 热路径去打印；`ksu_hook_mask` 0x2→0x1a**；包的静态闸 79 全绿、文档审计归零；**设备本栏零接触、枪数不变**）

- **用户一问定的方向**（"momo 提示找到可执行程序 su、分区挂载异常、存在 /system/bin/su，社区不会使用全局静态 su 吧"）⇒ **用户判对了**。§6.580 那套（overlay＋ext4 镜像把静态 `su` 落进 `/system/bin`）是 **Magisk 的形状**，不是 KernelSU 的形状；Momo 的三条红字全部指向它。
- **源码侧事实（不是推测）**：`feature/sucompat.c:30` `#define SU_PATH "/system/bin/su"`；sucompat 在 **syscall 入口**把这条路径改道到 `ksu_ksud_path`。⇒ 社区 `su` 是**内核伪装**，用户态可以一个字节文件都没有。
- **★决定性实验（`kmod/w1197_sucompat2.sh`，一手）**：先 `rm -f /system/bin/su` 让这条路径**真的不存在**，再
  - `asuid 10667 /system/bin/su -c id` ⇒ **`uid=0(root)`**（文件不存在，execve 照样被内核改道成功）；
  - `asuid 2000 …` ⇒ `No such file`（未授权 uid 不改道，报 ENOENT ＝ 负对照）；
  - 裸 `su -c id` ⇒ `inaccessible or not found`。
  ⇒ **静态 su 与 overlay 都不必要**。随后清理：`umount -l /system/bin` rc=0、`umount ext4` rc=0、`losetup -d /dev/block/loop40` rc=0（lower 未动；设备侧 `/system/bin/su` 现读不存在、无 overlay）。
- **★为什么以前"被迫"造文件**（根因）：`ksu_hook_mask=0x2` 只开 bit1(execve)。`app/` 里第一句 `access("/system/bin/su")` 走 **faccessat(48)**、`stat` 走 **newfstatat(79)**，这两个号没挂钩子 ⇒ 内核照实回 ENOENT ⇒ app 判定"没有 su" ⇒ 才去造文件。位表（`hook/syscall_hook_manager.c:190-194` 逐条读过）：**bit0 setresuid／bit1 execve／bit2 execveat／bit3 newfstatat／bit4 faccessat**，模块默认 `0x1f`。
- **faccessat2 的坑先排掉**：Android 11+ bionic 的 `access()` 先试 **`faccessat2`(439)**。本内核 5.4.281 的树里 **grep 不到 faccessat2**（5.8 才引入）⇒ 439 回 ENOSYS，bionic 有 `g_faccessat2_supported` 静态回落 ⇒ 落回**已挂钩的 48**。⇒ 不需要为 439 另加钩子，`0x1a`(bit1+3+4) 就是社区最小正解。
- **★但直接开 bit3/bit4 会炸**：rc77 的 `ksu_handle_stat_sucompat`／`ksu_handle_faccessat_sucompat` 是**调试形状**——stat 里 **9 条重复 `if (ksu_stat_off)`**、**13 条一模一样的 `pr_info("KSUBEAT FS0 enter newfstatat…")`**、外加 `pr_info_ratelimited` 与每次落空都印的 `KSUBEAT FS5 decline`；faccessat 里 6 条 `KSUBEAT FA*`。这两个钩子是全系统 `stat/access` 热路径 ⇒ 开着就是**打印风暴**（§6.118 那族：console 洪印把机器拖死过一次）。
- **补丁件 `kmod/patch_sucompat_quiet.py`**（md5 `525c57ad23c6c9bf1c9e6135e70fa175`）：用大括号配对整函数替换这两个 handler 为**零打印等价实现**（`ksu_stat_off` → allow-uid → `strncpy_from_user_nofault` → `memcmp(su_path)` → `override_creds`+`is_ksud_exists` → 换指针调原实现 → `revert_creds` → 还原指针）。远端先备份 `sucompat.c.bak_rc77`(25,244 B)，打完 496→**434 行**(22,032 B)，`diff -u` 逐条核对＝**只删打印与重复判断**（另把 stat 里 `else{revert_creds}` 提成无条件调用；faccessat 加了一条"抄路径失败就直走原实现"，原版不判返回值但 `memset` 过、memcmp 必然不匹配 ⇒ 结局相同）。execve 主路径的 `KSUBEAT SU*/SD*/M5` 证人**故意保留**（只在真 su 被 exec 时打，不构成风暴）。
- **rc78 出货 ko**：`kmod/kernelsu_rc78.ko`＝**`16b6c7c2a6f2a770c12b53ae03a331bd`，5,107,568 B**（远端 `make` RC=0，版本仍 `32653`＝`30000+2653`；比 rc77 小 8,736 B）。产物核验（与 rc77 对表，全部现读）：
  - 串：`KSUBEAT FA0/FA5/FS0/FS5`、`newfstatat su->ksud` **各 0**；`KSUBEAT SU0`=1／`SU1`=6／`SD0`=1（execve 证人仍在）；
  - 未定义符号 **158**（rc77 159），差集**只有 `___ratelimit` 少掉**（`pr_info_ratelimited` 删了）⇒ **零新增内核依赖**，装入门径只会更松；
  - `__versions` 0x27c0(159 条) vs rc77 0x2800(160 条) ⇒ 正好少那一枚；`.text` 12dc8 vs 13028（−608 B）；`.rodata`/`__param` 不变。
- **参数件**：`kmod/ksu_args.txt`＝`ksu_mass_mark=0 ksu_hook_mask=0x1a ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd`，md5 **`7f2a86067e35ad7f74205738636509c3`**（原 `67199f48…`/`0x2`）。`ksu_su_compat_enabled` 默认 `true`（源码 33 行），不需要额外开关。
- **★静态 su 彻底关死**：`kmod/ksu_one_stage.sh` 里 su_deploy 那段从"opt-in 可开"改成**即使开关文件在也拒绝执行**、只留一行证人（"社区路线已废弃静态 su"）——防止以后误开又踩回 Momo 那条。现值 md5 **`72484a472719e649e25909fa1bc1125f`／1145 行／CR=0**（原 83283149／1149 行）。
- **重打包**（`bash kmod/w431_pack_z6root.sh`；打包器 md5 **`93834a56631dc60389a0568b7fb1c52d`**，映射改指 `[kmod/kernelsu_rc78.ko]=kernelsu.ko`）：`z6root.zip`＝**`2e88ced7eaff7c147d9d54c780a0def3`**（17,858,038 B，23 条）；包内 `kernelsu.ko`＝`16b6c7c2…`(rc78)、`ksu_args.txt`＝`7f2a8606…`、`ksu_post.sh`＝`72484a47…`（与源 stage `cmp` 逐字节同）、`MANIFEST`＝`bc89262526199a25897ae72c73ca571d`；入口件 `z6root/z6root.sh` 仍 `4c626324…`（未动）。
- **闸**：`run_z6pack.sh` **79 项全绿**（⑩a 读出 `kernelsu_rc78`、⑩b 与映射源字节同一、⑧e stage 与源同一）；`w415_doc_audit.py` **合计命中 0**（12 处登记按"现行句改现值／历史句加当时"同步，脚本 `kmod/w1198_doc_sync_rc78.py`＝`a3ef28826c9ff8d0ad5e3cf66adbc5a4`，每条替换带 count 断言）。
- **状态**：**设备本栏零接触**（未 insmod／未 reboot／未写 `/sys/fs/selinux/load`／枪数不变＝9）；窗口仍是 16:04 开的那个（`Permissive`／`mod=1`／`/dev/ksud` 0666(10,78)／`up≈12600s`／**无 overlay、无静态 su**）。本栏所有改动都只在离线侧（ko／参数／stage／包／文档）。
- **★没证到哪（对外口径）**：(甲)**rc78 一次没上机**——`0x1a` 能不能让 `access()/stat()` 真的看见 `su`、`which su` 是否打印 `/system/bin/su`、app 里 `su -c id` 是否出 `uid=0`，**全未测**（这一格要一次干净 boot ＋ 一发枪，需现场点头）；(乙) 本次整闸尚未跑（改动已登记件 ko/args/stage/打包器/包/两份文档 ⇒ **必须**整跑 `w413`）；(丙) `sucompat` 的两条钩子挂上去后对**整机 stat 开销**只有理论判断（零打印版不再有洪印，但仍是一次 `strncpy_from_user_nofault`＋`memcmp`），实测要在枪那一发看 `up` 与是否复位。
- **下一步（需点头）**：新 boot → 一发 `I_KNOW=1 bash kmod/go.sh`（或推 rc78 手工 insmod）→ 判据三条：①`/proc/modules` 里 kernelsu 在；②`su 10667 -c 'which su'` 打印 `/system/bin/su`（＝stat/access 伪装生效，此前为空）；③`asuid 10667 su -c id` 出 `uid=0` 且 `/system/bin/su` **仍不存在**。
"""

s = io.open(P, encoding="utf-8").read()
if "§6.582" in s:
    print("!! 已经存在 §6.582，不重复追加")
    sys.exit(1)
if not s.endswith("\n"):
    s += "\n"
io.open(P, "w", encoding="utf-8", newline="").write(s + BODY.lstrip("\n"))
print("APPENDED §6.582；新行数=%d" % (s.count("\n") + BODY.count("\n")))
