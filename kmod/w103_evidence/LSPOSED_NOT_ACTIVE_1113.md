# LSPosed 未激活 —— 根因诊断（11-13 23:3x，**纯只读、未动设备**）

> 用户报告：「装上模块，使用 rcq 环境，"加载全部模块"，lsposed 还是没激活」。
> 设备：`<DEVICE_SERIAL>`，`boot_id=8434662d-e396-49e6-b1cb-973d99ad639d`
> （＝ B 对照枪那一 boot，中间**没有硬复位**），`uptime=4137~4519s`。
> 全部读数来自 adb shell 只读命令；**没有重启、没有改属性、没有重装模块**。

## 0. 一句话结论

**不是 SELinux 被翻、不是模块没装上、也不是 `lspd` 没起来 —— 是 `zygote` 从来没重启过，
所以 Zygisk 从来没有注入窗口，LSPosed 框架自然不激活。**
"加载全部模块"只做了「挂 overlay + 跑 `service.sh`」，**不含** zygote 重启；
而本该补上这一步的 KSU 软重启（`ksud soft-reboot`）**卡死了 40 分钟没走完**，
`sys.boot_completed` 又被 RCQ 的 `resetprop -w` 按在 0，两边互锁。

⇒ **与 B 方案看门狗正交**：看门狗只管「SELinux 翻回 Enforcing 掐断 su」，
本次 `getenforce=Permissive` 全程没变、su 通道一直活着，看门狗帮不上这个忙。

## 1. 观测事实（编号 = 下文引用）

| # | 读数 | 来源 |
|---|---|---|
| F1 | `getenforce=Permissive` / `kernelsu 204800 11 Live` / `/dev/ksud` (10,78) / `/product/bin/su` 全在 | `getenforce`、`/proc/modules`、`ls` |
| F2 | 模块 4 个全在且**无** `disable`/`remove` 标记：`m_rcq`、`scene_systemless`、`zygisk_lsposed`、`zygisksu` | `ls -la /data/adb/modules/` |
| F3 | `lspd` **在跑**（PID 14006，ETIME 36 min，PPid 13984 = `daemon --force`）；`zn-daemon` **3 个**（13953/25431/28990） | `ps -A -o PID,PPID,ETIME,NAME` |
| F4 | zygisk 与 lspd 的 socket 全在：`@zn_zygote_*`、`@zn_init_*`、`@zn_global_*`、`@lspbridge-*`；`modules_info` 已登记 `zygisk_lsposed` 的 64/32 位 .so（fd=8/9） | `/proc/net/unix`、`/data/adb/zygisksu/modules_info` |
| F5 | **zygote(1022/1023) `starttime=1208` ticks = 开机后 12.08s**（`CLK_TCK=100`），`ETIME=01:11:12`（71 min），与 uptime 75 min 吻合 ⇒ **开机起从未重启**；`system_server`(1623) 同 | `/proc/<pid>/stat`、`ps ETIME` |
| F6 | 模块目录 mtime = **22:59~23:05**，即开机后约 30 分钟才装上（zygote 早 30 分钟就起来了） | `ls -la` |
| F7 | `sys.boot_completed=0`（连读 3 次都是 0）、`sys.bootstat.first_boot_completed=1`；**4 个 `resetprop` 常驻进程**存活 37~42 min | `getprop`、`ps` |
| F8 | RCQ `service.sh` 第 29 行 `resetprop -w sys.boot_completed 0`、第 129 行 `resetprop -w sys.boot_completed 1` | `grep -n` |
| F9 | **2 个 `libksud.so soft-reboot` 卡住**（25190/25354，`State: S`，wchan=0，ETIME 40~41 min） | `/proc/<pid>/status` |
| F10 | `zygisksu/.abort_msg = "❌ User requested to exit!"`；`emulated-soft-reboot.sh` 内容为 `$MODDIR/bin/zygiskd exit` | `cat` |
| F11 | `kmsg.log`：`[I][28990][zn-daemon64]: ** daemon launched` / `** stop klog`；`KernelSU: security_secctx_to_secid u:r:ksu:s0 -> sid:0, error:-22` + `transive domain failed` **98 次**、`avc denied` **279 次**（均 `permissive=1`） | `/data/adb/lspd/log/kmsg.log`(0666) |
| F12 | LSPosed `modules_2026-11-13T23:05:22.log` 仅 **21 B**（空）；`modules_config.db` mtime `02:44`（旧），只有 `-shm`/`-wal` 是 23:05 | `ls -l` |
| F13 | `zygisk_lsposed/service.sh` = `"$MODDIR/daemon" --force &`；`daemon` = `./lspd "$@" &; wait` | `cat` |

## 2. 因果链

```
[F6] 模块在开机 +30min 才挂上
        │
        ├── [F13][F3][F4] 「加载全部模块」= 挂 overlay + 跑 service.sh
        │              ⇒ lspd / zn-daemon / socket / modules_info 全部到位
        │              ⇒ ★但 Zygisk 的注入只发生在 zygote 启动那一刻（fork 前）
        │
        ├── [F5] zygote 开机 12s 就起来了，71 分钟未重启
        │              ⇒ ★没有注入时机；已存在的 zygote 不会被"补注入"
        │
        └── [F9] 本该补这一步的 KSU 软重启卡死 40 min
                   │
                   ├── [F7][F8] RCQ 用 resetprop -w 把 sys.boot_completed 钉在 0，
                   │           4 个常驻进程持续回写；soft-reboot 等它变 1 才收尾
                   │           ⇒ 互锁：永远等不到
                   └── [F10] zygisksu 收到过 exit 请求（emulated-soft-reboot）
                              ⇒ 曾有一轮 daemon 被请退；⚠️ 但 .magic(23:05) 比
                                .abort_msg(23:00) 新、3 个 zn-daemon 仍活着
                                ⇒ **这是旧一轮残留，不是当前「注入者缺席」**
                                  ↓
              [F12] 没有模块被装载 / 框架未注入 ⇒ Manager 显示「未激活」
```

「最自洽的解释」标注：F7/F8/F9 的**互锁因果是推断**，不是直接证据；
可观测到的是「boot_completed 恒 0 + 4 个 resetprop 常驻 + soft-reboot 进程 40 min 不动 + zygote 未重启」这一组同时成立的事实。
⚠️ F10 那条「注入者退场」是 11-13 首版的**过度推断**，11-14 00:1x 已按 §5.1 A′ 更正：
`.abort_msg`(23:00) 早于 `.magic`/`modules_info`(23:05)，daemon 现仍在跑（只是 `status` 超时无响应）。

## 3. 排除掉的假设（别再往这些方向查）

| 假设 | 证否依据 |
|---|---|
| SELinux 又翻回 Enforcing 掐断 su（16:3x 那次） | F1：`Permissive` 全程、`/dev/ksud`+`/product/bin/su` 都在。**这次没翻** |
| 模块没装 / 被 disable | F2：4 个模块齐全、无 disable/remove 标记 |
| `lspd` 守护进程没起来 | F3：确在跑（本次复测推翻了 23:0x 那次「只有 shd/libksud」的读数） |
| ZygiskNext daemon 缺席 | F3/F4：3 个 `zn-daemon` + 全套 socket 在。⚠️ 23:0x 那轮 grep 写成 `zn_` 而进程名是 `zn-daemon`（连字符）⇒ 是**匹配式写错**，不是缺席 |
| AVC 硬拦住注入 | F11：279 条全是 `permissive=1`，Permissive 下不致命；`transive domain failed` 是 KSU 缺 `u:r:ksu:s0` 域（stock sepolicy），已知形态 |
| 模块挂载没生效 | F11 有 `do_mount ... zygisk_lsposed/bin/dex2oat64`、`usap64` 挂 `org.lsposed.manager` 数据镜像；F4 `modules_info` 已登记 |

## 4. 与 16:3x 事故 / B 方案的关系

- **16:3x 事故**＝点「RCQ 环境 → 加载全部模块」后 **SELinux 翻回 Enforcing**，掐断临时 root 的 su 通道；
  B 方案（`ksu_keep_permissive` 看门狗）就是为它设计的。
- **本次**：同一个动作，但 **SELinux 没翻**（F1），暴露的是另一条故障链 —— **zygote 未重启 / 软重启卡死**。
- ⇒ **看门狗救不了 LSPosed 激活**，两者正交。B 对照枪的结论不受本次影响（boot_id 未变、窗口仍活）。
- 但两者有共同源头：**RCQ「加载全部模块」这条动作路径**会触发 KSU 的软重启流程，而该流程在本机不稳定。
  后续若要一起解决，应查这条路径本身，而不是分别给两个症状打补丁。

## 5. ★结构性的坑（为什么不能简单「重启一下」）

- **真 `reboot` 会收窗**：ko 卸载、SELinux 回 Enforcing、bind 消失、stage 退；
  root 只在 stage 活着时存在（项目硬纪律）。而且重启后模块在 boot 时**没有 ko 支撑**，
  Zygisk 依然拿不到 KSU 环境 ⇒ 真重启**不解决**问题，只丢窗口。
- **同 boot 内重启 zygote（不重启内核）＝已实测不伤 ko/root**（见 §5.1）。
  真正的代价不在设备层，而在**当前窗口的 B 线 root 交付会被打断**。
  ⚠️ 命令口径：`setprop ctl.restart zygote` 在这类 vivo/iQOO 机上**被拒**（社区一手注释），
  正确写法是 `kill -9 $(pidof zygote64)`；`stop`/`start` 需要 root（shell 跑返回 `Must be root`）。
- ⇒ 相对可控的切口是 **先解 F7/F8 的 boot_completed 互锁**（让 RCQ 的 `service.sh` 跑到第 129 行置 1、
  或停掉那 4 个常驻 `resetprop`），再重试一次「加载全部模块」，看 F9 的 soft-reboot 能否走完并重启 zygote。
  ⚠️ 但 `boot_completed=0` 很可能是 RCQ **故意的反检测**（伪装未开机完成），改它会削弱隐藏效果。
  ⚠️ 单做「重启 zygote」**不解决根因**：4 个 `resetprop` 在 zygote 树外，杀不掉，`boot_completed` 仍被按 0。
- 🔴 **上面这条「切口」已于 11-14 00:2x 被只读复核证伪，勿再照做**：读完 `m_rcq/service.sh` 全文发现
  **L128 `setenforce 1` 就在 L129 `resetprop -w sys.boot_completed 1` 的前一行**，L131~163 还跟一长串
  `chmod 000 /proc/modules` 等反取证硬化。让脚本从卡住的 L29 继续往下跑＝**主动重演 16:3x 事故**。
  详见 **§5.2**。

## 5.1 ★「手工重启 zygote，最多只是需要硬重启吧」——精确回答（11-14 00:0x）

> 用户提问原话。**方向对，但「最多」要打折**：设备层最坏确实止于一次硬重启，
> 可**更现实、更贵的代价是「本 boot 的 B 线 root 交付作废且可能救不回来」**，
> 而且这里的「硬重启」＝**一整发 punch**（1 boot 1 枪，本 boot 那发已花），不是免费重试。

### A. 支持「方向对」的证据（设备层不会恶化到变砖）

| # | 证据 | 出处 |
|---|---|---|
| A1 | **同 boot 内软重启不影响 ko/root（已实测）**；社区 `soft_reboot(软重启).sh:6-16` 注释即「让 Zygisk / LSPosed 等会在 zygote 启动时…重新挂钩」，实现 `kill -9 $(pidof zygote64)` | `ROUTE-B-OFFSET-INVERSION.md` **§6.431**（10-25，一手） |
| A2 | ko 在内核态、zygote 在用户态；`/dev/ksud`、`/product/bin/su` bind、`stage`(18364 `shd`／18324 `ksuctl`, PPID=1)、`lspd`、3×`zn-daemon` **全部 PPID=1**，都不在 zygote 树下 | 本轮 `ps -A -o PID,PPID,ETIME,NAME` |
| A3 | `service zygote ... class main` + 多条 `onrestart restart ...`，**无 `oneshot`** ⇒ init 自动拉回；`service adbd ... class core disabled` ⇒ `stop` 只作用于 `class main`，**adbd 保住，adb 通道随时能发 `adb reboot`** | 本轮 `init.zygote*.rc` 只读 |
| A4 | 当前 args `ksu_hook_mask=0x0` ⇒ **不在「sucompat 0x2/0x1a ~19.5s 必死」那条线上**。⚠️ 但 zygote 重启会带来一波密集 execve，**若换成带 `hook_mask` 的 args 做同样动作，就是已钉死的必死形状** | 本轮 `cat /data/local/tmp/ksu_args.txt` + 项目铁律 |
| A5 | BL 锁、stock 分区、无任何持久分区写入 ⇒ 不会变砖、不会丢数据 | 项目已钉死结论 |

⚠️ **A1 的前提差异（11-14 00:1x 补，别把历史结论无条件搬过来）**：账本 §6.431 原文是
「同 boot 内软重启不影响 ko/root（已实测；**`sys.boot_completed` 会保持 1**，不能当就绪闸）」
⇒ 那次实测时 `boot_completed=1`，**本窗是 0**。所以：
- **「不伤 ko/root」这一层仍成立**（ko 在内核态、root 腿全 PPID=1，与 boot_completed 无关）；
- **但「framework 能顺利重启完」这一层未经本形状验证** —— 本窗 4 个 `resetprop` 持续把值按 0，
  zygote 重启后 `system_server` 重走开机流程可能等不到 `boot_completed=1` ⇒ 卡开机动画／反复重启。
  ⇒ **恰恰是「需要硬重启」这一支的概率比历史实测更高**，不是更低。

⇒ 所以「最坏需要硬重启」**成立**；但「通常连硬重启都不用」这句要收回——
init 会自动拉回 zygote、adb 全程在线（这两条确定），**能不能把 framework 走完则取决于 B2**。

### A′. 「重启 zygote 有没有收益」——本轮只读补查（11-14 00:1x）

| 读数 | 结果 | 判法 |
|---|---|---|
| `zygiskd status` | **rc=124（8s 超时被杀）、stdout 0 B、stderr 0 B** | ⚠️ daemon 对 status 请求**不响应**。三个 `zn-daemon` 都 `S(sleeping)`、Threads=3~4，不是僵尸 ⇒ 更像**卡在等某个条件**（很可能是 `boot_completed` 或旧 zygisk 上下文），不是干净待命 |
| `kmsg.log` 注入结果串 | `inject`/`forkAndSpecialize`/`pre specializing`/`module loaded` **0 命中** | ⚠️ 「计数=0 不是否据」（日志被 ratelimit 吞过 29 行），**不能据此断言注入没发生**；但也没有任何「注入成功」的正证据 |
| `.magic`(23:05) vs `.abort_msg`(23:00) | `.magic` 更新、3 个 daemon 活着 | ⇒ `.abort_msg` 是**旧一轮残留**，之前写「注入者退场」过度推断，已按 D 段保留为旁证 |

⇒ **收益仍是未验证的**：即便 zygote 成功重启， daemon 能否重新挂钩并注入，取决于它当前卡的那个条件是否随重启解除。
⇒ 这又给③加了一层：**可能白做一次（root 交付断了、punch 也花了，LSPosed 仍不激活）**。

### B. 但有三处比「硬重启」更烦（这才是真实代价）

| # | 代价 | 机理 |
|---|---|---|
| **B1** | ★**B 线 root 交付会断** | `me.weishu.kernelsu`(11458) 与 `com.suw.manager`(23166) 的 **PPID=1022**（zygote 子进程）⇒ 必被杀重启。按已钉死的**两条时序铁律**：fd 只属于「那一个进程」、`/proc/ksu_install_fd` 走 `task_work_add`，且「支持/不支持」是**启动时一次性分支** ⇒ 重启后**驱动 fd 全丢、事后补装永远白干**；`su` 缓存成「获取 Root 失败」，重造 Activity 不重查。⇒ 官方 Manager 掉回未激活、三个标准 app 不再出 root。要恢复得重跑 `b8_mgr.sh`（先开抢装循环再 `am start`），**而 `sys.boot_completed=0` 下 `am start` 本身都可能受限** ⇒ 可能救不回来 |
| **B2** | ★**根因没解，白做一次** | 4 个 `resetprop` 的父链＝`13961`/`28999`(PPID=1)、`25219`/`25444`(挂在 `libksud.so` 25190/25354 下)，**全在 zygote 树外** ⇒ 杀 zygote 杀不掉它们，`boot_completed` 仍被按 0。zygote 重启后 framework 反而可能卡在开机流程／反复重启／黑屏 ⇒ **这才是真正「逼出一次硬重启」的来源** |
| **B3** | 「硬重启」＝**再花一发 punch** | 本 boot 唯一一发已花在 B 对照枪；真 reboot ⇒ ko 卸、Enforcing、bind 消失、stage 退，要重走 `go.sh` 全流程（含 reboot、抢装、加冕时序），并再担一次 17:34 那类偶发硬复位风险。**不是零成本重试** |

### C. 低概率但要记一笔

`init.zygote64_32.rc` 里 zygote 带 `critical window=${zygote.critical_window.minute:-off} target=zygote-fatal`
（默认 `off` ⇒ 通常不启用）：若短时间内反复崩，Android 的 critical 机制有触发 `zygote-fatal` 的路径。
**单次 `kill -9` 不触发**；别在同一窗里反复试。

### D. 结论

- **设备层**：你的判断成立 —— 不会变砖、不会丢数据、最坏一次 `adb reboot`，且 adbd 保住能救、init 会自动拉回 zygote。
  ⚠️ 但历史实测前提是 `boot_completed=1`，本窗是 0 ⇒ **「framework 能顺利走完」未验证**，
  所以「连硬重启都不用」这句要收回；「需要硬重启」这一支的概率**比历史实测更高**。
- **窗口层**：不成立 —— 更可能先撞上 **B1（root 交付断、可能救不回）**，B2 让**根因仍在**，
  A′ 说明 **daemon 当前卡住、重启后能否注入未验证** ⇒ 可能白做一次；一旦要硬重启就是 **B3（多花一发）**。
- ⇒ **单做③性价比最低**：本窗按①另起干净 boot 开 `rc82b`（推荐）。
  ⚠️ 本节 11-14 00:0x 首版曾写「先做②解互锁」，**11-14 00:2x 已按 §5.2 证伪并撤回**
  （②的 RCQ `service.sh` L128 `setenforce 1` 会翻 Enforcing 掐断 root，不是可选项）。
  若仍要做③，正确命令是 `kill -9 $(pidof zygote64)`（**不是** `ctl.restart`），且需用户明确点头。

### D′. 一句话给用户

> **「最多只是需要硬重启」——对，但那次硬重启不是免费的：它等于把本 boot 那一发 punch 也一起烧掉。**
> 而且在此之前，更可能先发生的是「窗口里的 B 线 root 交付断掉、LSPosed 仍未激活」。
> 所以③不是「代价可控所以可以试」，而是「代价可控但收益未证、且①更省」。
> ⚠️ 此处首版写的「②或①」已按 §5.2 更正：②的 RCQ 收尾会 `setenforce 1`，不是可选项。

## 5.2 ★回答「先②再③，后面再①吗？」——顺序要改，且②的原方案已被证伪（11-14 00:2x，纯只读）

> 用户提议的执行顺序：「先做②（解 `boot_completed` 互锁）→ 再做③（手工重启 zygote）→ 后面再①（`rc82b` 干净 boot）」。
> **结论：不对。②按原写法做会主动翻 Enforcing 掐断 root，③在本窗解不了根因，而①才是唯一不与"活窗口硬纪律"冲突的路。
> 正确顺序是「① 优先／② 要么不做、要么换成不碰 RCQ 收尾的等价做法／③ 放到干净 boot 里由 Zygisk 自己完成」。**

### A. 新证据：`m_rcq/service.sh` 全文（11-14 00:2x 读全文，此前只 grep 到 L29/L129）

| 行 | 内容 | 含义 |
|---|---|---|
| L20–24 | `kptr_restrict=2`、`dmesg_restrict=1`、`suid_dumpable=0`、`core_pattern=0`、`perf_event_paranoid=2` | 解释了 F11 的 `dmesg: Operation not permitted`、为什么内核读数只能走落盘日志 |
| L26–27 | `chmod 777 I_am_taffy` 并执行 | RCQ 环境自查 |
| **L29** | **`resetprop -w sys.boot_completed 0`** | 4 个进程的 cmdline 实测都是 `resetprop -w sys.boot_completed 0`、S(sleeping) 存活 1h25~1h31、`wchan=0`，配合 `boot_completed` 恒 0 ⇒ **常驻把属性按 0**。⚠️ `-w`＝watch 是**从现象推断**：`/data/adb/ksu/bin/resetprop` 从 shell 是 `Permission denied`、未读其源码，不作确证 |
| L31–126 | 约 90 条 `check_reset_prop`／`force_reset_prop`（伪装 `verifiedbootstate=green`、`flash.locked=1`、`debuggable=0`…）＋ `settings` 写入 | 反检测主体 |
| **L128** | **`setenforce 1`** | 🔴 **★关键**：脚本收尾**主动把 SELinux 翻回 Enforcing** |
| **L129** | **`resetprop -w sys.boot_completed 1`** | 放开 boot_completed；**但它在 L128 之后** |
| L131–163 | `HIDE_PROCS` 循环 `chmod 000 /proc/<root进程>`；`chmod 000 /proc/ksu /proc/kallsyms /proc/modules`；`chmod 640 /sys/fs/selinux/enforce`；`chmod 440 /proc/cmdline`；关 tracing | 反取证硬化；翻 Enforcing 后连观测通道也会被封 |

**⇒ 这就是 16:3x 事故的机理**：点「加载全部模块」→ RCQ `service.sh` 跑到 L128 `setenforce 1` → su 通道断。
本窗之所以还 `Permissive`，是因为 4 个脚本**卡在 L29 的 watcher 上没往下走**（见下）。

### B. 4 个卡住的不是孤儿进程，是 4 份 `service.sh` 本体

```
PID      PPID   UID  State  cmdline / name
13961    1      0    S      /data/adb/ksu/bin/busybox sh /data/adb/modules/m_rcq/service.sh
  └13965 13961  0    S      resetprop -w sys.boot_completed 0     (ETIME 01:25:50, wchan=0)
25215    25190  0    S      busybox sh .../m_rcq/service.sh        ← PPID=libksud.so soft-reboot
  └25219 25215  0    S      resetprop -w sys.boot_completed 0     (ETIME 01:31:03, wchan=0)
25437    25354  0    S      busybox sh .../m_rcq/service.sh        ← PPID=libksud.so soft-reboot
  └25444 25437  0    S      resetprop -w sys.boot_completed 0     (ETIME 01:30:57, wchan=0)
28999    1      0    S      busybox sh .../m_rcq/service.sh
  └29008 28999  0    S      resetprop -w sys.boot_completed 0     (ETIME 01:30:02, wchan=0)
```

- 4 份脚本全部 **uid=0、S(sleeping)**，父进程 PPID=1 或挂在 F9 的两个 `libksud.so soft-reboot`(25190/25354) 下
  ⇒ **全在 zygote 树外**，③ 的 `kill -9 zygote64` 一个都碰不到。
- 脚本是**顺序执行**的（无 `&`、无 `wait` 分支；控制流只有 3 个函数定义 + 2 个 for 循环）。
  ⇒ **一旦让 L29 的 watcher 结束，脚本立刻顺序跑到 L128 `setenforce 1`**，中间没有可拦的分支。
- ⇒ **② 的两种原写法都等于"放脚本去翻 Enforcing"**：
  - 「让 RCQ 跑到 L129」：L129 在 L128 **之后**，到得了 129 就必然已经 `setenforce 1` 了；
  - 「停 4 个常驻 `resetprop`」：watcher 被停 ⇒ 4 份脚本各往下一步 ⇒ 同样撞 L128，×4 倍。
  ⚠️ 这正是 B 方案看门狗 `ksu_keep_permissive` 要对付的场景，但**本轮未见看门狗进程/日志证据**
  （`ksu_keep_auto` 是 0 B 空文件；`ps` 无 `keep_perm`/watchdog 用户态进程；`ksu_stage.log` 只有 `sushd` 的
  `w426_enforce.sh` 自检记录）。按「计数=0 不是否据」不断言看门狗没在跑，但**绝不能拿它当保险**。

### C. 顺带复核：`su` 通道当前是"在"但 shell 直接提权不通

- `id`＝`uid=2000(shell)`；`/product/bin/su`(root:root 0755) 与 `/data/local/tmp/kd`(shell) 都在；
  `ksuctl88 info` → `GET_INFO rc=0 version=32653 flags=0x5(LKM=1,LATE_LOAD=1) uapi=2`，`/dev/ksud`(10,78,0666) 活着。
- **但 `/product/bin/su -c '…'` 从 adb shell 返回 `提权失败 uid=2000 ioctl ret=-1 errno=1(Operation not permitted)`**
  ⇒ shell 不是 allowlist 里的 uid（`ksu_two_profiles` 那份名单是 10342/10104/10349/10475/10261），
  符合项目已钉死的「`ksuctl88 granted` 从 adb shell 恒 EPERM」「`asuid` 必须自己是 root 才 setuid 得动」。
  ⇒ **若②把 SELinux 翻成 Enforcing，事后连 `setenforce 0` 都补不回去**（要走 `asuid <授权uid> …` 或 `@sushd` 通道，
  而那两条同样依赖 ko 的 allowlist 还在）。这是②最贵的隐藏代价。
- 当前 args：`ksu_mass_mark=0 ksu_hook_mask=0x0 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd`
  ⇒ **0x0，不在必死线**（§7 那条"动手前必查 hook_mask"本次通过）。

### D. 逐条判「②→③→①」

| 步骤 | 判定 | 理由 |
|---|---|---|
| **② 先做（原写法）** | 🔴 **否决，会自毁窗口** | L128 `setenforce 1` 在 L129 之前；停 watcher／让脚本跑完都会触发；翻 Enforcing 后 shell 无法 `setenforce 0` 补救 ⇒ 直接等价于 16:3x 事故。且 `boot_completed=0` 本身是 RCQ 的**反检测设计**，改它还会削弱隐藏（§5 原注） |
| **② 换成"直接把属性写 1、不碰 RCQ 脚本"** | ⚠️ 理论可行但**收益未证** | 用 `asuid <授权uid> resetprop -n sys.boot_completed 1` 之类绕过 L128；但 4 个 `-w` watcher 会立刻把它按回 0（`-w` 就是干这个的），除非同时停 watcher ⇒ 又回到触发 L128。**死结** |
| **③ 再做** | ⚠️ **根因仍在，且 risk↑** | 4 份 `service.sh` 在 zygote 树外（B 段）⇒ `kill -9 zygote64` 杀不掉 watcher，`boot_completed` 仍 0；§5.1 A1 的历史实测前提是 `boot_completed=1`，本窗是 0 ⇒ framework 能否走完未验证；叠加 §5.1 B1（B 线 root 交付断）＋ B3（硬重启＝再花一发 punch） |
| **① 放最后** | 🔴 **顺序反了** | ① 是另起**干净 boot**，本来就会让②③的对象全部消失（ko 卸、模块未加载前重新按时序走、看门狗随新枪部署）。放在②③之后＝先在本窗担完所有风险，再 reboot 把成果清零。**它应该是下一步，不是兜底** |

### E. 结论 / 修正后的顺序

**不是「②→③→①」，而是：**

1. **① 直接做（推荐）**：按 `B_CONTROL_PLAN.md` §5 结论收窗 → 干净 boot 打 `rc82b`。
   在**模块按时序于 zygote 启动前加载**的前提下，Zygisk 天然拿到注入窗口，LSPosed 未激活这条根因
   **不需要②③里的任何手工动作**就消失；同时 `boot_completed` 会自然走到 1（§6.431 的一手前提成立）。
2. **② 从「待办」降级为「不做」**：`boot_completed=0` 是 RCQ 反检测设计，不是本窗 bug；
   解开它既危险（L128）又削弱隐藏。若将来确实验 RCQ 收尾，应放到**专门的一枪**里，且预先确认
   `ksu_keep_permissive` 看门狗已部署并实测能抗住 `setenforce 1`。
3. **③ 从「本窗动手」降级为「观察项」**：干净 boot 里由 Zygisk 自己完成注入即可；
   若仍要验「同 boot 内 kill zygote 重挂钩」，按 §5.1 A1 在 `boot_completed=1` 的新窗里做，
   并先确认 args 仍是 `0x0`。

⚠️ **窗口时长**：本轮复核 `uptime=7297s`（**≈2h02m**）、`boot_id=8434662d` 未变、`Permissive`、
`sys.boot_completed=0`、ko `kernelsu 204800 11 Live`。按项目硬纪律「窗口不留过夜」，**应尽快收窗**
（`I_KNOW=1 bash kmod/w161_teardown.sh`；无 root 时 `reboot` 即干净收窗），收窗后复核
`mod=0 / Enforcing / 无 /product/bin/su / 无 kd`，并删 `/data/local/tmp/ksu_two_profiles`（它改名单形状）。

**本轮全程只读，未对设备做任何写操作；所有选项仍需用户明确点头才动设备。**

## 5.3 ★回答「要先试下③，再走①吗？」——③不是免费试错，它会打瘫①的收窗链（11-14 00:4x，纯只读）

> 提议背后的算法：「① 反正要 reboot，先在本窗试③，成了赚到、不成 reboot 也会把痕迹清掉 ⇒ 免费期权」。
> **结论：不成立。③ 的代价不是「本窗多一次软重启」，而是毁掉 ① 的前置条件。
> `reboot` 清的是『正常收窗之后』的状态；③ 先把收窗能力打瘫，再 reboot ⇒ 把「干净收窗」换成「带残留复位」。**

### A. 决定性证据：① 的收窗脚本依赖的，正是③要杀掉的那个进程

`kmod/w161_teardown.sh` 全文（本轮新增核对）：

| 段 | 行 | 做什么 | 靠哪条腿 |
|---|---|---|---|
| `fire()` | L8–14 | `am force-stop com.suw.manager` ＋ `am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:…"` | **`@sushd` root 腿，入口就是 `com.suw.manager`** |
| T2 | L24–29 | push `w135_off.sh` → `fire "@sushd:…"` → 等 `===== DONE` | root 侧 umount＋删源（含 `/data/local/tmp/pbin`） |
| T2.5 | L30–36 | `w165b_adb_clean.sh` 清 `/data/adb` 脚印（allowlist） | 同上 |
| **T2.5b** | **L37–68** | ★脚本自己明写：「**B 入口(免 suw)下上面两条 @sushd 腿必『等满』⇒ 名单文件会偷换下一发的形状**(§6.366／#153)」；`/data/adb/ksu/.allowlist` 若还留着，**下一发 insmod 时 ko 会把它读进活表** | — |
| T3 | L159–173 | shell 侧删 `/data/local/tmp/` 载荷（含 `ksu_two_profiles`） | shell 属主可删 |
| T3 注 | L174–184 | ★「`pbin` 是 stage 用 root 身份建的…**shell 删不动**…本发 root 通道没有 ⇒ 只能如实登记它还在」 | — |
| T4 | L185–190 | `adb reboot` → `until sys.boot_completed=1` → 复核 `mod=0/Enforcing/无 pbin/无 su` | — |

**本轮 00:4x 只读复核**：`me.weishu.kernelsu`(11458) 与 **`com.suw.manager`(23166) 仍是 PPID=1022**(zygote)；
`shd`(18364)/`ksuctl`(18324) PPID=1；`zygiskd status` **仍 rc=124**（无输出）；4 个 `resetprop -w` 与 4 份 `service.sh` 全在；
`up=8343s`(≈2h19m)、`boot_id=8434662d` 未变、`Permissive`、`boot_completed=0`、ko `Live`、args `0x0`。

⇒ ③ `kill -9 zygote64` **必杀 23166**（`@sushd` 的入口）。按已钉死的**两条时序铁律**
（fd 只属于「那一个进程」＋「支持/不支持」是启动时一次性分支）⇒ 重启后 fd 全丢、事后补装白干、
`su` 缓存成「获取 Root 失败」⇒ **T2/T2.5 的 `@sushd` 腿等满 120s/60s 拿不到 DONE**
⇒ `pbin`、`.allowlist`、`ksu_two_profiles`(若 T3 也来不及) 残留
⇒ **① 的 `rc82b` 在 insmod 时把上一发名单读进活表，形状被远程设定** ⇒ 看门狗五条判据从起跑线就不干净。

### B. ③ 自己都得先借那条腿（自相矛盾）

`zygote64` 是 uid=0 进程，shell(uid=2000) 无 `CAP_KILL` 杀不动；本轮 `/product/bin/su -c` 实测
`提权失败 uid=2000 ioctl ret=-1 errno=1(Operation not permitted)`（§5.2 C）。
⇒ ③ 必须先经 `asuid <授权uid>` 或 `@sushd` 拿 root —— **先借用、再亲手打断同一条腿**。
且 `boot_completed=0` 下 framework 重启期间 `am start` 可能直接发不出去，`fire()` 更没戏
（T2.5b 那句「必等满」本来就是为这种形状写的）。

### C. ③ 在本窗的收益仍不成立（本轮复核全部照旧）

- 4 份 `m_rcq/service.sh` ＋ 4 个 `resetprop -w` **全在 zygote 树外**（§5.2 B）⇒ 杀不掉，`boot_completed` 仍 0。
- `zygiskd status` **本轮仍 rc=124**、零输出 ⇒ daemon 卡住的条件没解除，重启后能否注入未验证（§5.1 A′）。
- §6.431 的一手实测前提是 **`boot_completed=1`**，本窗是 0 ⇒ framework 能否走完未验证；
  「需要硬复位」概率更高，而真硬复位连 T2/T2.5 的执行窗口都没有。
- ③ 即便侥幸激活了 LSPosed，产出也只是一次**观察**，带不到 ① 的新 boot（模块每 boot 重新 apply）。

### D. 结论 / 修正后的顺序

**不是「先③再①」。两者不是『试完再走』，而是「③ 会让 ① 走不干净」。**

1. **直接 ①**（收窗 → 干净 boot 打 `rc82b`），中间**不插 ③**。① 的正当性来自 B 主线（验看门狗五条判据）
   与「不与活窗口硬纪律冲突」，**不依赖**「顺带治好 LSPosed」这条。
2. **③ 要试，放到 ① 之后那个干净 boot 里**：那时 `boot_completed=1`（§6.431 前提成立）、root 腿完整、
   试完还能正常 `w161_teardown.sh` 收窗；动手前先确认 args 仍是 `0x0`。
3. 若坚持本窗试 ③：**需用户明确点头**，且必须先把 T2/T2.5/T3 的清理人工做完并读回复证
   （＝提前把 ① 的前置手动补上），性价比比直接走 ① 更低。

### E. ★顺带修正 §5.2 E 的一处过度承诺（本轮自查）

§5.2 E 写「干净 boot 里模块按时序在 zygote 启动前加载 ⇒ Zygisk 天然拿到注入窗口」是**带前提的条件句，
不是已验证结论**：`go.sh` **L51／L329** 的形状是「`adb reboot` → `until sys.boot_completed=1` → punch → insmod ko」，
即 **ko 与模块都在 zygote 起来之后才加载**；模块系统是否有 `post-fs-data` 补跑、能否补出注入窗口，本轮未核实。
⇒ **「① 能顺带根治 LSPosed 未激活」属待验证预期，不能当既得收益记**。① 该做仍然该做，但理由要换成上面 D.1。
（⚠️ 又一次「把条件句读成结论」——与 §5.1 A1 漏搬 `boot_completed=1` 前提、§5 首版漏读 L128 是同一类错。）

**本轮全程只读，未对设备做任何写操作；所有选项仍需用户明确点头才动设备。**

## 6. 可选下一步（三选一，**都需用户点头才动设备**）

| 选项 | 动作 | 风险 / 收益 |
|---|---|---|
| **① 先推进 B 主线** ★**推荐、且应最先做** | 不动 LSPosed，按 `B_CONTROL_PLAN.md` §5 结论收窗 → 干净 boot 另起一发 `rc82b` 验看门狗五条判据 | 与本次问题正交，但**恰恰能根治它**：干净 boot 里模块按时序在 zygote 启动前加载 ⇒ Zygisk 天然拿到注入窗口，`boot_completed` 自然到 1（§6.431 的一手前提成立）。不与"活窗口硬纪律"冲突 |
| **② 解互锁后重试模块加载** 🔴 **原写法已证伪，见 §5.2** | ~~停 4 个 `resetprop` 常驻 / 让 RCQ 跑到 `sys.boot_completed=1`，再点「加载全部模块」~~ ⇒ **不要做**；`service.sh` **L128 `setenforce 1` 在 L129 之前**，且 4 份脚本 uid=0 卡在 L29 watcher 上、顺序执行无分支，停 watcher／跑完都会翻 Enforcing 掐断 su；事后 shell 无法 `setenforce 0` 补救 | ~~最贴根因~~ ⇒ **会自毁窗口**＝主动重演 16:3x 事故；且 `boot_completed=0` 是 RCQ 反检测设计，改它削弱隐藏。降级为「不做」；将来要验 RCQ 收尾须另起一枪并先实测看门狗 |
| **③ 手工重启 zygote** ⚠️ **降级为观察项** | ★`kill -9 $(pidof zygote64)`（**不是** `setprop ctl.restart zygote`，这类机被拒；`stop`/`start` 需 root） | **设备层风险不高**（§5.1 A：同 boot 内已实测不伤 ko/root、init 自动拉回、adbd 保住、不变砖）。真实代价是 §5.1 B：**B 线 root 交付断且可能救不回**＋**根因没解**（4 份 `service.sh` 在 zygote 树外，杀不掉 watcher，§5.2 B）＋一旦硬重启＝多花一发 punch。⇒ **不在本窗做**，留到 `boot_completed=1` 的干净 boot 里由 Zygisk 自行完成 |

> **顺序判读（用户问「先②再③，后面再①吗？」）→ 否，见 §5.2 E**：
> **① 直接做**；② 不做；③ 降级为观察项。把①放最后是反的——① 会 reboot 清零②③的一切对象，
> 等于先在本窗担完风险再把成果清掉。
>
> **追加判读（用户问「要先试下③，再走①吗？」）→ 仍然否，见 §5.3**：
> 「反正①要 reboot，③是免费试错」不成立 —— `w161_teardown.sh` 的 T2/T2.5 全靠 `@sushd` root 腿，
> 而③必杀 `com.suw.manager`(23166, PPID=1022) ⇒ fd 全丢、收窗腿断、`pbin`/`.allowlist` 残留
> ⇒ **① 的 rc82b 名单形状被上一发污染**。③要试放到①之后的干净 boot（那时 `boot_completed=1`、root 腿完整）。

## 7. 复现 / 复核命令（只读）

```bash
A="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"

# F5 关键判据：zygote 有没有重启过（starttime 单位 = CLK_TCK，本机 100）
$A shell "getconf CLK_TCK; cat /proc/uptime; \
  for p in 1022 1023; do printf 'PID=%s start=' \$p; awk '{print \$22}' /proc/\$p/stat; done; \
  ps -A -o PID,PPID,ETIME,NAME | grep -aiE 'zygote|system_server|lspd|zn-daemon|soft-reboot'"

# F7/F9 互锁
$A shell "getprop sys.boot_completed; \
  ps -A -o PID,PPID,ETIME,NAME | grep -aiE 'resetprop|soft-reboot'"

# F3 ★注意进程名是 zn-daemon（连字符），别用 zn_ 去 grep
$A shell "ps -A -o PID,PPID,ETIME,NAME | grep -aiE 'lspd|zn-daemon|zygisk'"

# F11 0666 可读的内核侧日志（verbose_*.log 是 0770，shell 读不了）
$A shell "grep -aiE 'zn-daemon|LSPosed|transive' /data/adb/lspd/log/kmsg.log | tail -30"

# §5.1 A：zygote 会不会自动拉回 / adbd 会不会被 stop 一起停
$A shell "for f in /system/etc/init/hw/init.zygote*.rc; do \
    grep -aE '^(service|    (class|oneshot|critical))' \$f | head -12; done"
$A shell "grep -aA6 '^service adbd' /system/etc/init/hw/*.rc 2>/dev/null | head -8"

# §5.1 B1：谁会被杀（PPID=zygote 的全是）；B2：resetprop 在不在 zygote 树外
$A shell "ps -A -o PID,PPID,ETIME,NAME | grep -aiE 'kernelsu|manager|suw|shd|ksuctl|adbd|resetprop'"
$A shell "for p in \$(ps -A -o PID,NAME | grep -a resetprop | awk '{print \$1}'); do \
    printf 'PID=%s ' \$p; awk '{print \"ppid=\" \$4}' /proc/\$p/stat; done"

# ★动手前必查：当前 args 的 hook_mask（0x2/0x1a 遇 zygote 重启的密集 execve 是必死形状）
$A shell "cat /data/local/tmp/ksu_args.txt"

# §5.1 A′：daemon 是否干净待命（★必须带 timeout，裸跑会挂住）
$A shell "timeout 8 /data/adb/modules/zygisksu/bin/zygiskd status 2>&1; echo rc=\$?"
$A shell "ls -la --full-time /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/.magic"
$A shell "for p in \$(ps -A -o PID,NAME | grep -a 'zn-daemon' | awk '{print \$1}'); do \
    printf 'PID=%s ' \$p; grep -aE '^(State|Threads)' /proc/\$p/status | tr '\n' ' '; echo; done"
```

## 8. 口径纪律（本项目通用，本次又验证了一遍）

- **「计数=0 不是否据」**：`/proc/<root 进程>/maps` 全部 0 行是 DAC 挡住（F5 的 `stat` 可读、`maps` 不可读），
  不能拿它判「zygote 没被注入」；本次改用 `starttime` + `ETIME` 这两个**可读且带时间**的硬证据。
- **grep 匹配式要先验**：`zn_` 匹配不到 `zn-daemon` 曾导致「zygiskd 缺席」的误判（见 §3）。
- **日志源别只认一个**：B 对照枪 J3 的 `KILLSCAN enter`/`CFI 18` 一直在 `/data/local/tmp/ksu_stage.log`，
  之前只查 `dmesg_full.txt`(0 B) 和 stale 的 `dmesg.live` 才误判成「证据缺口」。
- **`dmesg` 被 RCQ 加了 `dmesg_restrict=1`** ⇒ shell `klogctl: Operation not permitted`，
  内核读数走 `stage.log` / `lspd/log/kmsg.log` 这类落盘文件。
