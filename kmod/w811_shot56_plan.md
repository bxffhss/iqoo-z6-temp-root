# w811 —— 第 56 发（10-25 11:4x–）判据（**开枪前写死**）：空窗对照——"没人碰它的时候，窗口会不会自己断"

> 开枪前把要说清的一句话写在最前面：这一发**不是**为了补 #188/#187，是为了回答第 55 发留下的那个问题——
> 窗体自己在 insmod+≈635 秒被 `HARD_RESET/PS_HOLD` 打断（§6.428），而同一支 ko 在第 54 发活到 insmod+2633 秒。
> 死前 100 秒里 **96% 的内核日志是我们自己的 ko 打的**（`KSUBEAT F sys_enter/BN dispatch/SD1 decline` 各约 3100 行），
> `comm=sh`＋`uid=0` 的 execve 以 ~31 次/秒在跑、pid 一直在换 ⇒ fork-exec 风暴形状（§6.198 同族）；vr 的痕迹 **0 行**（不作否据）。

## 这一发的唯一变量

跑完一键后**什么都不派**，只让包自带的 stage/keeper 自己跑，全程 36 分钟（比第 55 发的 635 秒长 3.4 倍、比第 54 发的 2633 秒短）。

**明令禁止（做了这发就作废）**：任何 `su -c`／打字腿、`am start`、`input text`、点 UI、`w745` 看门狗、`rleg`/`@sushd:` 派单、`logcat -c`（只 `-d` 不清）。
PC 侧只允许跑 `kmod/w810_window_watch.sh`——它只读：`/proc/uptime`、`/sys/fs/selinux/enforce`、`/proc/modules`、`/proc/stat`、`pidof`、`tail /data/local/tmp/dmesg2.log`、`w774_keeper.log`、`logcat -b crash -d -t`。

## 判据（每条都要自己的读数，不许互相顶替）

- **T1 一键跑通**（只取甲组①-⑤，同第 55 发形状）：`入口形状=1`、活表 `count=1 uid=10667 granted=1`、`NOSUW_BIND_RC=0`＋`/product/bin/su` 带 x 位、MANIFEST 逐条 `ok`、`Z6ROOT_DONE mod=1`。**⑥⑦两格这一发故意不做**（要派腿），不算失败。
- **T2 空窗采样 ≥34 轮**（60 秒一轮）：每轮记 `up/enforce/mod/fork_processes/ctxt/mgr_pid/fired/尾段 SD1/尾段 sys_enter/keeper 行数/crash 行数`。
- **T3 寿命判定（三分支，提前写死怎么读）**：
  - **(a) 空窗也断**（≤36 分钟内 uptime 倒退／adb 掉线后 `mod=0`＋新 boot）⇒ 结论＝**"不派腿也会死"**，那 §6.428 里"风暴是被我派的动作引起来的"这条解释被判负；下一格才轮到改 ko（把 `sys_enter` 回调的全局成本降下来＋打印限频）做 A/B。断前最后一轮的 `fired`/`SD1` 增量＝**死前速率**，必须写进台账。
  - **(b) 空窗活过 36 分钟** ⇒ 结论＝**"这一发没复现断"**；那第 55 发的断就与"我派出去的动作/UI"相关。⇒ 同一扇窗里**接着**按顺序补：⑥x 位活证人 → ⑦牌子 → #188（只 umount 那一态，`w797_umount_only.sh`）→ #187（包内 `w450_close.sh` 三判据），**每格都记"距 insmod 多少秒"**，且此后不再拿这发的寿命数据做任何"会不会断"的结论（观察已被我污染）。
  - **(c) 中途 adb 掉线但设备没复位**（少见）⇒ 记 UNTESTED，不改判。
- **T4 vr 这一格顺手取但不作否据**：断前／采样末段的环里 `vr`/`cfi`/`violation` 命中数（同一把尺再数一次）。风暴在、vr 0 行 ⇒ vr 降为"无参与证据"；**不许写成"证明与 vr 无关"**（环只覆盖最后 ~100 秒，是自家那条"计数=0 不是否据"）。
- **T5 风暴归因（0 额外枪）**：`logcat -b crash -d` 的 `Fatal signal` 增量＋其中出现的**进程名**（若 `libksud.so`/`crash_dump64` 在窗内持续增长 ⇒ 支持"rc74b 装了 fd ⇒ Manager 反复去起 root 服务 ⇒ 被 seccomp 打死 ⇒ 重启循环"这条链；不增长⇒链断在第一环）。

## 收尾（顺序是铁律）

所有 root 腿排在恢复执法之前 → 删维持件开关/源 → `/data/adb` 复证 → 脚印 → **`enforce=1` 最后** → `adb reboot` → 复位后独立读回。★产物权限必须排在写第一行之前（常驻闸 `w795` 会查这条）。

## 代价与不做什么

- 代价：36 分钟纯等（这期间我不碰设备），并且这一发**不补** #188/#187（若走分支 a，那两格还得再等一发）。
- 不做：不重编 ko（重编＝多花一发认证）；不动 cap（#185 已两次判负）；不碰 `NOBIND=1`（#182）；不开 `ksu_fd_keepalive`（§6.400）；不动 seccomp（#110）。
- 交付：本发跑的仍是 `z6root.zip`＝`7c8b32da`；**在补齐甲组⑥⑦＋丙组复证之前，仍不升默认**（快照 `/sdcard/z6root_shot54_24664916` 仍是唯一"认证过的那一份"）。
- 采样器：`kmod/w810_window_watch.sh`（只读；产物 `kmod/w103_evidence/shot56/w810_shot56.csv`）；执法腿 `kmod/w813_enforce_only.sh`。

---

# 读数（10-25 12:0x–12:3x）——★空窗对照在 12:1x 就被用户的正常使用作废（那正是我们要的格），本发改判为「有动作」窗，结果反而拿到了 #184 的机制

## T1 一键＝判正（甲组①-⑥全绿，⑦读到"灭"）

`入口形状=1`（目标包 com.termux 现取 uid=10667）｜`判据⑥ 到了（第 340 秒）`｜`allowlist: NEW_GET_ALLOW_LIST rc=0 count=1 total=1`｜MANIFEST 22 条逐条 `ok`｜`NOSUW_BIND_RC=0`＋`NOSUW_CP_N=4`＋`NOSUW_HEALTH=OK`＋`/product/bin/su`＝`-rwxr-xr-x root root 2241944`｜`Z6ROOT_DONE up=2939.80 mod=1 enforce=Permissive`；insmod 锚点≈**up 2913（12:04:1x）**。
★**甲组⑥（x 位的活证人）＝判正**：`su -c /data/local/tmp/w450_close.sh`（**包自己铺的那条腿**，由新的"从 MANIFEST 现数"chmod 拿到 x 位）被直接 execve 跑通并 `uid=0` ⇒ 第 55 发抓到的那三只没 x 位的缺陷，在真链路上已被修好。

## ★T5 抓到 #184 的机制：64 格 fd 预算被"已死的 helper pid"占满 ⇒ 牌子掉回不支持，而 root 通道照旧

| 一手读数 | 值 |
|---|---|
| 当前 Manager 进程 | `pid=13767`，**`fd_ksu=0`**，`Seccomp=2`（牌子灭的直接原因＝它手里没有 `[ksu_driver]` fd） |
| 预算 | `total=64`（＝上限 64），首次踢在 `up=3643.95` ⇒ **距 insmod ≈731 秒烧光** |
| 拒绝计数 | `KSUBIRTH cap total=64 cap=64 - refusing more birth fds this boot` **1203 行／5.2 秒 ≈ 233 次/秒** |
| 烧预算的是谁 | `logcat -b crash`：`Fatal signal 31 (SIGSYS) syscall 142 … (libksud.so)` 成对出现（12:15:22×2、12:16:10×2、12:16:23×2…），crash 基线 15 → 29 |
| 牌子（焦点 OK） | `up=3953.10` ⇒ **`不支持`**，同窗 `mod=1`、root 腿仍 `uid=0` ＝ **"灭时 su 仍可用"**（用户一手现象逐字对上） |
| 期间 Manager 换过 pid | `18892 → 32020 → 13767`（重进/重启过，仍拿不到 fd ⇒ 耗尽后**重进也救不回来**；用户早前"重进能恢复"＝复用了耗尽前已装过 fd 的旧进程） |

⇒ **结论：这不是"cap 设小了"，是槽位泄漏**——每个活不到 1 秒的 helper（`libksud.so`／`crash_dump64`）都占一格且死后不还。#185 里我判的"A（抬 cap）出局、B 只是卫生"**要改**：B（把 helper 排出预算／释放死 pid 的槽）是治因，A 是续命。

## T2 被动成本（23 轮、跨度 1425 秒，纯只读采样）

- 我们 ko 那行 `fired#`：**54,808,764 → 202,927,378 ⇒ 平均 103,901 次/秒**；用户风暴退去之后仍 **≈79,934 次/秒** ⇒ `sys_enter` 回调是**全局每次 syscall 都进**（这才是被动成本的主体，打印只是它的尾巴）。
- `/proc/stat processes`：51,042 → 81,609 ⇒ **21.4 fork/秒**（12:21 之后降到 **6.6/秒**）；`ctxt` ≈5,516/秒。
- 每轮尾段 `KSUBEAT` 打印计数 ~360 行／轮（风暴段）→ ~155（退去后）。

## T3/T4 寿命与 vr

- **这扇窗没自己断**：从 insmod(up≈2913) 到我命令 reboot(up≈4664)＝**insmod+1751 秒 ≈29 分钟**，期间带着崩溃风暴与 cap 耗尽 ⇒ 第 55 发那次 `insmod+635 秒` 的 `HARD_RESET/PS_HOLD` **仍未归因**，且"风暴→复位"这条嫌疑**没有在这发被证实**（但不排除：样本各 1）。
- vr：整段环里 `vr`/`cfi` 命中 **0 行**（★不作否据：环只覆盖最后 ~100 秒，且 vr 平时不说话）。

## 丙组＝#187 判正（包内收尾腿修正版第一次上机，三判据齐）

产物 `/sdcard/w450_close.txt` **PC 侧 `adb pull` 读得到**（＝第 54 发那处"权限排在执法之后"的缺陷已修的直接证人）；七个键全在：`killswitch_rm_rc=0`／`KEEPER_LEFT=退了`（keeper 自己那行 `开关被删 ⇒ 自退(第 68 轮)，不留孤儿`）／`umount_rc=1`＋`MOUNT_LEFT=0`／`rm_allow_rc=0`／`ALLOW_LEFT=[…No such file…]`／`rm_pbin_src_rc=0`（`/data/adb/ksu/pbin` 与 `sustatic` 复证都不在）／`KEEPER_NAMES=[]`。
★顺带证到那道新闸**按可观察状态判、不按 rc 判**：`umount` 返回 `Invalid argument`(rc=1) 而挂载行已是 0 ⇒ 闸门放行删源，符合设计。
★另一条一手：恢复执法之后同一个 root 壳里 `grep`/`tr`/`sync`/`cut` 全部 `inaccessible or not found` ⇒ **关窗铁律**（恢复执法必须排在所有 root 腿之后）再次实测，且这次连 `sync` 都没跑到（靠 reboot 兜住）。

## 乙组＝#188 **判负（维持件不覆盖"被 umount"这一态）**

探针真跑通：`umount rc1=0` ⇒ 它自己 ns 里 `挂载行=0`、`su 没了`、**`源内文件=4`（源还在＝形状对）**；**60 秒没回来**，`重建=0 修好了=0`；同期 keeper 每轮都写 `好(su 在…)`——因为它和我在的那个 ns 里挂载**根本没动**（我这侧全程 `pbin行=1`、`su=在`）。
⇒ 不是维持件坏，是**它和被保护对象不在同一 mount namespace**（root 壳的 umount 没跨 ns 传播）。所以覆盖范围要说准：**维持件只覆盖"源被 unlinked"（跨 ns 可见）这一类；"被 umount"不覆盖** ⇒ 记为**判负**，不是"未测"。

## 复位后与本轮枪账

`Enforcing`、`mod=0`、pbin 挂载行=0、`/product/bin/su` 不存在。★注意：history 最新一条这次记成 `cold,charger,1792903061`（我们命令的 reboot 却打成 cold）——**这条 property 的标签不能用来区分"我们收尾的复位"与"异常冷启动"**（记忆那条的又一实例），区分只能靠时刻对齐。10-25 枪数＝**3**（第 54/55/56 发）。

