# -*- coding: utf-8 -*-
# 追加 §6.583：rc78(0x1a) 上机一发的读数、死亡定性、以及"改道从未武装"的否证与根因链。
import io, os, sys

P = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ROUTE-B-OFFSET-INVERSION.md')
assert os.path.exists(P), P
body = u'''
## §6.583　11-09 21:1x–21:5x（**本 boot 一发已打：rc78／`0x1a` 上机 `insmod rc=0`、内核通道 `passfd` 成功拿到 `uid=0`；但 insmod 后 ≈95 秒 PS_HOLD 硬复位；★关键否证＝分发器**零进入**（`KSUBEAT BN`=0）⇒ 社区 su 的 stat/access 改道这一次**从未武装**；根因链三条互证指向本机没有 `sys_enter` 跟踪点**；三判据未达成）

- **授权链**：用户"现在开枪"⇒ `w161_teardown.sh`（`TD_RC=0`，设备回出厂：`up=81 mod=0 Enforcing 挂载=0`）→ 重新 `push`（`kernelsu.ko 16b6c7c2`／`ksu_args.txt 7f2a8606`(0x1a)／`ksud f7a441d2`，三件设备侧 md5 全 `ok`）→ `I_KNOW=1 bash kmod/go.sh KO=kmod/kernelsu_rc78.ko`。**枪数 10**、`load` 累计仍 **7 次**、`/sys/fs/selinux/load` **零写入**。
- **一手读数（全部设备侧现读，不靠推断）**：
  - 起点体检 `id=2000 mod=0 enf=Enforcing uts=Linux 挂载=0`；`Termux=10667 suw=10342`；args 由仓库文件读入＝`ksu_hook_mask=0x1a`（**不再是手改**）。
  - `insmod rc=0 up=928.70 lsmod=[kernelsu 200704 0]`；stage 首行原文 `args=[… ksu_hook_mask=0x1a …]`；`/dev/ksud`＝`crw-rw-rw- 1 root root 10, 78`（★**那条 chmod 顺序的交付 bug 这一发是真的好了**：日志写的是"`★/dev/ksud 权限补正(insmod 后)`"）。
  - 文本补丁 `KSUBEAT P1` ×5（`929.316/929.644/929.681/929.725/930.034`，`len=4/4/4/4/6`，每条后跟 `P4 copy_to_kernel_nofault ret=0`）⇒ 补丁面全部 rc=0。
  - 逃逸腿 `X0…XC` 在 `935.800` 整条走完：`prepare_creds → commit_creds(uid=0) → disable_seccomp → threads marked → setup_mount_ns` ⇒ **bit0 那条超调用路在 rc78 上仍完好**。
  - **内核通道 `passfd` rc=0**：父 `sendmsg(fd=5)` → 子 `recvmsg` 得 `fd=4` → `GRANT_ROOT rc=0` ⇒ `uid=0 euid=0 gid=0`，活到 `t+6s`（`open=9 errno=0`），`exit=0`；`fd 5 -> anon_inode:[ksu_driver]`。⇒ **ko 本身能跑、能授权**。
- **★否证（本栏最重要的读数）：社区改道一次都没发生**。采样器 199 个样本、`up` 从 376 单调到 1016 **无一次回落**（＝窗口内没跨 reboot），`mod` 在 `up=928` 翻 1、`enf` 转 `Permissive`；而整段 dmesg 里 **`KSUBEAT BN dispatcher`=0、`KSUBEAT B dispatcher`=0、`E1`=0、`E2`=0**。★这一条**不是"被筛子滤掉"**：落盘腿用的是 `dd if=/proc/kmsg bs=512 count=1`（**全量逐条**、零过滤），且同窗口内 `P1`(929.3–930.0) 与 `X0..XC`(935.800) 都在，说明环里 5 秒以上的行仍存得住；同时 `grep -ac 'KSUBEAT BN dispatcher' kmod/kernelsu_rc78.ko` = **1**（串在件里）。⇒ 不是件没有这句，是**这句从来没被执行**：`newfstatat`/`faccessat` 的改道在这次窗口里**一次也没有**把任何 syscall 送进分发器。
- **根因链（三条互证，方向一致）**：
  1. `hook/arm64/syscall_hook.c` 里 `ksu_register_syscall_hook()` 的注释是明写的：**"Does not modify the syscall table — the dispatcher slot is shared by all hooks"** ⇒ 钩子**只**靠 `sys_enter` 跟踪点把 `regs->syscallno` 改写成 `ksu_dispatcher_nr` 来生效；表里只装分发器这一个槽。
  2. `infra/dev_syms.c:255 ksu_sys_enter_tp_register()` 是**按名字找跟踪点**再 `tracepoint_probe_register_prio`：`ksu_tracepoint_find("sys_enter")` 找不到就 `return -ENOENT`。
  3. 设备侧两个实测：①`analysis/config_dev.txt` 现读 **`CONFIG_HAVE_SYSCALL_TRACEPOINTS=y` 但 `# CONFIG_FTRACE_SYSCALLS is not set`**；②stage 自己在 root 下读 tracefs 得 **`events/raw_syscall/sys_enter/enable: No such file or directory`**（同一次读数里 `on=[1]`、`kpf组=[1]`、`stacktrace=[1]` 都正常 ⇒ tracefs 本身是好的，缺的就是这一个跟踪点）。
  ⇒ **本机内核没有 `sys_enter` 跟踪点 ⇒ `ksu_sys_enter_tp_register` 拿 -ENOENT ⇒ 分发器永不进入 ⇒ `0x1a` 里 bit3/bit4（连带 bit1）在这台机器上都不可能生效**。这不是"0x1a 开得不对"，是**分发机制与这台内核不匹配**。
- **死亡定性与时间线（带内与带外分开写，按 §6.512 口径）**：带内上界＝采样器最后一条 `up=1016`（`mod=1`、`Permissive`，之后无样本）；带外＝`ro.boot.bootreason=USB_CHARGER/PS_HOLD/0x01+0x01`，且新 boot 起点可由设备钟反算＝**21:39:40**（`date` 21:51:48 − `up` 728.02）⇒ **死亡落在 insmod 后 ≈88–95 秒**（`928.70→≈1016`）。★**不是 0.1 秒、也不是"37 秒"**：`insmod` 之后这台机器至少**活了 88 秒且 ko 在跑**（`mod=1`）；把"复位 epoch 差"当死亡时刻是 §6.512 已经纠过的口径错误，这一发不再犯。
- **★死亡原因的诚实口径：不成立也不排除任何一条**。①`pstore` 三个 `console-ramoops*` 开窗前**全不存在**（硬复位不留 panic 记录），现在 `/sys/fs/pstore` 无 root 不可读；②整个快照窗口只有 **40 条内核行、覆盖 `[929.316, 935.800]`**（阶段在 21:38 就 pull 了），**根本盖不到 986/1016 那一段** ⇒ "异常关键字 0 命中（`BUG`/`Oops`/`Unable to handle`/`watchdog`/`rcu stall`/`Call trace`/`panic`）"**是"没看到"、不是"没有"**；③但**热路径洪印这条假设被 BN=0 抽掉了地基**——改道既然没发生，`stat/access` 就不可能把机器拖死；④本 boot 事故后一直没再复位（`up` 连续到 728、851 进程、`zygote running`），所以也**没有"第二次自发复位"可当基线证据**。
- **★顺手排掉的一条**：`sucompat` 两个 handler 的 **cred 配平是对的**（远端 rc78 源逐行读：每次 `override_creds` 后，`if (is_ksud_exists())` 成功支内 `revert_creds`＋返回，失败支外再 `revert_creds`，无漏路）；去打印也确实落在件里（`grep -ac 'KSUBEAT FA0' / 'KSUBEAT FS0' kmod/kernelsu_rc78.ko` 均 **0**，而 `SU0`=1）。
- **★这一发暴露的两个必须修的 BUG**：
  1. **`KSUBEAT BN` 是裸 `pr_info`**（`hook/arm64/syscall_hook.c`，就在 `ksu_syscall_dispatcher` 入口，注释自己写着"必须限流"）⇒ **一旦改道真的生效，全系统每次 `stat/access` 都打一行**，正是 §6.118 console 洪印那一族的死法。**即使把跟踪点问题解决，也必须先把它改成 `pr_info_ratelimited`（或删掉、改用计数器从 `/proc/ksu_slots` 读）**，否则社区路线一武装就自己打死自己。
  2. **`kmod/ksu_args.txt` 被 go.sh 第 8 步自愈悄悄回滚**：`cp kmod/ksu_args.txt.bak_delivery kmod/ksu_args.txt`，而那份"交付备份"还是 `0x2`（`67199f48`）⇒ 跑完一发后仓库件就与 `DELIVERY.md` 登记的 `7f2a8606`(0x1a) 和出货包 `z6root/ksu_args.txt`(107 B, `7f2a8606`) 不一致。**已修**：从 `z6root.zip` 里 `z6root/ksu_args.txt` 直接取字节写回 `kmod/ksu_args.txt` 与 `kmod/ksu_args.txt.bak_delivery`，两份现均 `7f2a8606`／107 B。★以后别再拿"已还原"当结论，且要记住 go.sh **每次跑完都会重写这个文件**。
- **三判据（对外口径，一条没达成）**：①`su 10667 -c 'which su'` 打印 `/system/bin/su`——**未测**；②`asuid 10667 su -c id` 出 `uid=0` **且** `/system/bin/su` 仍不存在——**未测**；③窗口内可操作——**没做到**：`go.sh` 第 4、6 步各"等满 60s 没有 `[===== DONE]`"，即 `@sushd` 通道在 `21:38:20` 之后就没再应过（与"机器从 `up≈938` 起就在退化"一致）。⇒ **rc78／`0x1a` 这一次是"上机了、通道通了、但路线没武装、机器死了"，判据全空，不能记成任何一侧的正面证据**。
- **下一步（工程优先，不急着再花枪）**：先做**零枪**的两件事——(甲) 把分发机制从"跟踪点改写"换成"直接改 `sys_call_table` 三个条目 + 保存原实现指针"（`ksu_register_syscall_hook` 现在明写不改表；这正是上游在无跟踪点内核上的走法），并把 `ksu_handle_*` 里 `ksu_syscall_table[orig_nr]` 改成调用**保存下来的原指针**，否则改表即自递归；(乙) 同时把 `KSUBEAT BN` 限流/删掉。两件都落完、跑 `w413` 整闸、再次现场点头，才值得花第 11 发去验"`which su` / `su -c id`"。
'''
with io.open(P, 'a', encoding='utf-8') as f:
    f.write(body)
print('APPEND_OK bytes=%d' % len(body.encode('utf-8')))
print('lines_now=%d' % sum(1 for _ in io.open(P, encoding='utf-8', errors='replace')))
