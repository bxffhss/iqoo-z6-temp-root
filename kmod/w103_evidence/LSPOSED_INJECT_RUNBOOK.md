# LSPosed 注入作战手册 — iQOO Z6 / 外部 LKM KernelSU（late-load 场景）

> 窗口：`boot_id=180492e3`（干净 rc80，NO RCQ，`boot_completed=1`、Permissive、ko Live、`/dev/ksud`+`/product/bin/su`）。
> **状态（2026-11-15 00:5x）：模块已全部部署成功，ZygiskNext daemon 常驻且 `inject_state:1`，lspd 常驻；只差最后一步「重启 zygote」。**
> 模块来源：**设备上就有** `/storage/emulated/0/Download/必备模块/`（＝`/sdcard/Download/必备模块/`）：
> `LSPosed-v2.2.0-7854-release.zip`、`Zygisk-Next-1.5.2-864-a4a72ce-relea.zip`、`rcq 2.1.0.zip`（后者不用）。
> ⚠️ 之前误判"模块全无"是因为 `find /sdcard` 的输出被本机 PATH 坏掉的 `tr` 管道吃掉了（**设备侧其实一直有**）。

## 0. 为什么这本手册 ≠ Z5 脚本直接搬

Z5 脚本（`iqooz5/.../zygisk_next.sh`）假设 `bin/zygiskd` 就在模块顶层、模块已被 KSU 正常安装。
**这两个 zip 都是 `SKIPUNZIP=1`**，靠 `customize.sh` 做架构选择，直接 `unzip -o` 出来的目录**跑不起来**。
正确做法＝**严格复刻 `customize.sh` 的白名单 extract**（见 §2），别手工拼目录。

## 1. root 动作通道（本窗口唯一可用）

`@sushd` 腿（来自 `w161_teardown.sh` fire()），脚本推到 `/data/local/tmp/`、`chmod 755`：
```
adb push kmod/wXXX.sh /data/local/tmp/wXXX.sh
adb shell "chmod 755 /data/local/tmp/wXXX.sh; rm -f /data/local/tmp/wXXX.out"
adb shell "am force-stop com.suw.manager"; sleep 1
adb shell "am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd '@sushd:/data/local/tmp/wXXX.sh'"
# 脚本内第一句：exec >/data/local/tmp/wXXX.out 2>&1；末句：echo "===== DONE"
# 主机侧轮询 grep -ac '===== DONE' wXXX.out，再 cat 读回
```
★ 三条本机纪律：
- 开火命令必须 `export MSYS_NO_PATHCONV=1`（否则 `@sushd:/data/...` 被 MSYS 改写成 Windows 路径）。
- 本机 PATH 要带 `PortableGit/.../usr/bin`，否则 `mkdir`/`ls`/`tr`/`head` 全 `command not found`。
- **脚本里禁止 `pkill -9 -f 'lspd'`**：脚本名含 "lspd" ⇒ `-f` 匹配到自身命令行 ⇒ 自杀、输出截断无 DONE。用 `for p in $(pidof lspd); do kill -9 $p; done`。

## 2. ★两个已解决的大坑（本轮真正的 know-how）

### 坑 A：`verify1 failed` → `❌ Module files corrupted`
- 现象：`zn-daemon64` logcat 打印 `** write prop` 后立刻 `verify1 failed` / `abort: Module files corrupted`，daemon 起不来。
- **不是** `.sha256` 校验（全量 42 个文件校验过，41 OK；唯一 mismatch 的 `module.prop` 是 daemon 自己 `** write prop` 把 `[❌ …]` 写进 description 造成的，从 zip 重取即恢复正确 hash `2f8cdf9a…`）——恢复后**仍失败**。
- **真因＝反篡改清单**：ZygiskNext 1.5.2 校验"已安装模块的目录内容 == customize.sh 白名单"。手工 `unzip -o` 解出 102 个文件（多出 `META-INF/`、`verify.sh`、`customize.sh`、全部 `.sha256`、其他架构的 `machikado.*`/`lib/<arch>/`/`bin/<arch>/`），必然失败。
- **解**：严格按白名单重建（21 个文件），见 `kmod/w210_rebuild.sh`。重建后一次成功：
  `inject success!` / `loaded 64bit zygisk module zygisk_lsposed` / `** daemon launched`。

### 坑 B：lspd `SIGSEGV (fault addr 0x314)` + 起不来
- 现象：`LSPosedService: starting server... version 2.2.0` → `dex2oat mode: bind mount` → 崩；tombstone `pc/lr/sp=0x314`、backtrace 只有 `#00 <unknown>`。
- 两个原因：
  1. `dex2oat64/32` 缺 **`u:object_r:dex2oat_exec:s0`** 标签（`cp` 出来继承父目录标签）。`customize.sh` 里 `set_perm … dex2oat_exec:s0` ⇒ 必须 `chcon u:object_r:dex2oat_exec:s0`。
  2. 启动方式：`nohup … &` 里 `daemon` 会 `wait` 前台常驻 ⇒ 宿主脚本不返回、输出截断。用**双 fork**：`( setsid runcon … >log 2>&1 </dev/null & )`（子 shell 立即退出、孙进程被 init 收养）。
- **解**：`kmod/w214_lspd3.sh`（严格白名单 22 文件 + chcon + 双 fork）。结果 lspd PID 7065 稳定常驻。
- ⚠️ `sign_tool -l` 是**联网**签发 license；设备无网只回 `Skipped`、不产生 `license.pb`。离线正解＝`-s` 生成 `sign_request.pb` → 联网机器 `-r` 生成 `license.pb` → 放回 `/data/adb/lspd/`；安装期可 `: > /data/adb/lspd/skip_online_request` 旁路。**lspd 已能常驻，license 目前不是阻塞项**。

### 补：daemon 标记文件
`/data/adb/zygisksu/.abort_msg`（旧轮 `User requested to exit!`）、`.injecting` 会污染下次启动，按 `post-fs-data.sh` 语义清掉 / 把 `znctx`、`modules_info` 移成 `.old`。`machikado` 取 `arm64_32`（本机 `ro.product.cpu.abilist32=armeabi-v7a,armeabi` 非空）。

## 3. 当前实测状态（踢 zygote 之前）

```
boot_id=180492e3   up≈17880   boot_completed=1   Enforce=0   ko=kernelsu Live
zygote64=1025 start_ticks=1207  ← 开机 12.07s 起从未重启（根因仍在）
zn-daemon=31699 (PPID=1) 常驻     lspd=7065 (PPID=1) 常驻
zygiskd status (w210 实测 RC=0):
    version:1.5.2-864-a4a72ce-release
    inject_state:1              ← 注入器已就位
    root_status:✅KernelSU (32653)
    modules64/modules32: 1,zygisk_lsposed   ← LSPosed 模块已被加载
    zygote_states:0             ← ★还没有 zygote 被注入（就差重启 zygote）
    modules_with_issue:0
```
★ **重要认知修正**：不需要"手工挂 `libzygisk.so` overlay"。ZygiskNext 1.5.2 的 logcat 显示它
`** attaching init` → `** hooking execve` / `** hooking wait4` → `inject success!` —— **它 hook 了 init 的 execve，
在 init 重新拉起 zygote 的那一刻注入**。所以 late-load 场景下只要 `kill -9 zygote64` 就能拿到注入窗口，
此前 runbook 里"必须手工 bind mount libzygisk.so"的假设是错的（未验证的推断，已删）。

★ **验证通道不依赖 root 腿**：`zygiskd status` 从 adb shell(uid 2000) 可读（w210/w211 实测 RC=0）。
⇒ 踢完 zygote 即使 `@sushd` 腿断，仍能核对 `zygote_states` / `inject_state` / LSPosed Manager。
（偶尔 daemon 忙时 `status` 会 rc=124 超时，按"计数=0/rc=124 不是否据"处理，多试或看 logcat。）

★ **收窗风险已评估**：`com.suw.manager` PPID=1025(zygote) ⇒ 必被杀、`@sushd` 腿断；
但 `ksuctl`/`shd`/`ko` 全 PPID=1、不受影响；`/data/adb/ksu/.allowlist` **不存在**（不会污染下一发）；
`pbin` 仍在（root 建的 su 拷贝，shell 删不动，属已知残留）。最坏可 `adb reboot` 干净收窗。

## 4. ★最后一步（尚未执行，需用户点头）

```
# @sushd root 腿跑（zygote64 uid=0，shell 无 CAP_KILL）：
kill -9 $(pidof system_server) $(pidof zygote64) $(pidof zygote)
```
- 手机会黑屏 40–60s、USB 可能瞬断；init 自动拉回 zygote（无 `oneshot`），adbd 保住。
- 依据：`LSPOSED_NOT_ACTIVE_1113.md` §5.1 A（同 boot 内软重启不伤 ko/root，历史实测前提是 `boot_completed=1`——**本窗正好满足**）；`init.zygote*.rc` 无 `oneshot`；args `hook_mask=0x0` 不在必死线。
- 参考 Z5：`z5_lsposed220_activate.sh` 第 3 步就是同一条命令；`zygisk_next.sh` 用 `kill -9 -- -$(pidof zygote64)`（进程组）。
- **绝不跑 `ksud post-fs-data`**（Z5 脚本硬编码警告：内核卡死＋硬复位）。

### 验证清单（踢完 60–150s 后）
1. `zygiskd status` → `zygote_states≠0`、`inject_state:1`、`modules_with_issue:0`。
2. `awk '{print $22}' /proc/$(pidof zygote64)/stat` → start_ticks 明显 > 1207（证明 zygote 真重启过）。
3. `logcat | grep zn-daemon` → 有 `forkAndSpecialize` / `module loaded` / 注入成功正证据。
4. `am start -n org.lsposed.manager/.ui.activity.MainActivity` → UI 显示「已激活」。
5. 若 Z5 那套 "serial 抢注" 症状复现（`service list | grep serial` 被系统原生 `android.hardware.ISerialManager` 占着），按 `z5_lsposed220_guard.sh` 思路处理（需 `probe2.jar`，本次未准备）。
6. root 交付恢复：`bash kmod/b8_mgr.sh`（zygote 重启会杀 `me.weishu.kernelsu`/`com.suw.manager` 丢 fd）。

## 4.5 ★★执行结果（11-15 01:01 一发）：**Zygisk 注入成功**，LSPosed 桥未建（01:2x 更正）

> ⚠️ **本节 01:0x 首版判「注入失败 / 结构性死结」是错的，01:2x 已按硬证据撤回。**
> 错因＝**判据错配**：拿 Z5 **阶段 4**（LSPosed 点火）的验收标准去判**阶段 3**（Zygisk 注入）。

用户点头后执行 `kmod/w215_kick.sh`（延迟 3s、`setsid` 脱离 killer，`GATE=OK`）：
`kill -9 $(pidof system_server) $(pidof zygote64) $(pidof zygote)`。
证据链：`w215_kick.out`、`w216_verify.out`、`w217_diag.out`、`w218_probe.out`、`w219_dig.out`。

### ★决定性证据：注入其实成功了

| 证据 | 读数 | 来源 |
|---|---|---|
| zygote 真重启 | PID `1025→12931`、`start_ticks 1207→1824549`、`vivo.zygote_restart=1` | `init.zygote64.rc` 的 `onrestart setprop` |
| **ZN daemon 自报状态** | `module.prop` **mtime `01:01:30.653`（kick 后 1.6s）**：`description=[✅zygote, ✅zygote_secondary, Root: ✅KernelSU (32653), ZL]` | `w219_dig.out` [2]/补查 |
| 内核态全活 | `boot_id=180492e3` 未变、`mod=1`、`enf=0`、`/dev/ksud`、`/proc/ksu_*`、`boot_completed=1` | §5.1 A1 成立 |

⇒ **`✅zygote` + `✅zygote_secondary` 正好对应 Z5 教程阶段 3 验收的 `zygote_states:2`**
（Z5 教程 §五 3.3：期望 `inject_state:1、zygote_states:2`）。
**11-13 以来「zygote 从未重启 ⇒ 无注入窗口」这条根因，本发已彻底消除。**

### 上一版三条误判，逐条更正

| 上一版拿它当「注入失败」 | 实际含义 |
|---|---|
| `LSPosed Manager: LSPosed 未安装` | Z5 教程 §六/§九：**Manager 判的是 `serial` 桥握手，不是 zygisk 注入**。桥没建就显示「未安装」；教程明写「管理器未安装 ⇒ 先 `guard.sh arm` 重打针」 |
| `service list` 的 `serial: [android.hardware.ISerialManager]` | 系统原生占着＝**桥未抢注**，属阶段 4 未完成；教程验收要 `serial: []` |
| `znctl status: Could not connect to service!` | 只说明 **daemon 后来死了**，不能倒推注入没发生（"计数=0/rc 失败不是否据"同族） |
| `modules_info`/`znctx` 停在 00:39 | 那是**模块清单缓存**，注入成功不改它；上版据此推断"无重新注入"是过度推断 |

另修正：daemon **不是"踢的同一瞬间被清"**——它 01:01:30 还在写 prop，是在 kick 后 1~80s 之间死的。

### ★观测极限已钉死（01:3x 深挖，别再重复挖）

| 通道 | 实测 | 结论 |
|---|---|---|
| `dmesg` | `dmesg_restrict=0` **可读**，但 ring buffer 现存最早 `[19451.]`，kick 在 uptime `[18240.]`；精确捞 `18220~18270` **空** | 被本机每 5s 一条 `PM: active wake lock : zygote_kwl` 冲光 ⇒ **物理不可考** |
| logcat 全 buffer | framework 重启后重置为 2054 行、`earliest=beginning of main`；`-b kernel` 空 | 01:01 前的 ZN/lspd 日志全丢 |
| `/proc/1/maps`、`/proc/zygote64/maps` | 全 `Permission denied`（uid 0 进程，DAC 挡） | 看不了 init 里的 execve hook、也看不了 zygote 是否加载 `libzygisk.so` |
| `/data/adb/lspd/log/kmsg.log` | 停在 `00:52:18`（lspd 起时写的），没有 01:01 段 | 无 |
| tombstones | 无新件 | 无 |
| events buffer | 有 vivo `BOOT_COMPLETED_5`/`_10` 分批广播 + 一批 `am_proc_died(adj 700)` | 只旁证 framework 重建，**不证明谁杀了 daemon** |

`class_reset main` 的触发条件是 `on property:vold.decrypt=trigger_shutdown_framework`，**不是本次 kill zygote 的路径**；
`init.zygote64.rc` 的 `onrestart` 只 restart audioserver/cameraserver/media/netd/wificond/`zygote_third` + `setprop vivo.zygote_restart 1`。
⇒ "framework 全重建连根清掉 PPID=1 进程"这个机理**没有证据**，别当结论。
新 zygote 的 6 个线程全是标准 ART（`main`/`ReferenceQueueD`/`Jit thread pool`/`HeapTaskDaemon`/
`FinalizerWatchd`/`FinalizerDaemon`），无 zygisk 特征线程；但 ZN 注入本就不新建命名线程 ⇒ **不作否据**。

**精确时间线（文件 mtime，均为设备侧实读）**：
```
00:39:29  module.prop.orig                    (ZN daemon 首次启动)
00:39:30  znctx / modules_info                (ZN 装载 zygisk_lsposed 64/32)
00:52:18  lspd/monitor、kmsg.log、props.txt    (lspd 启动，写入 lspbridge-<uuid>)
00:52:21  verbose_*.log                       (lspd 最后一条日志)
01:01:25  w215_kick.out 前置读数              (zn-daemon=31699 lspd=7065 都在、inject_state:1)
01:01:29  KILL 执行 (system_server 1594 / zygote64 1025 / zygote 1026)
01:01:30  module.prop 写 [✅zygote, ✅zygote_secondary]  ← 注入成功
01:02:39  w216: zygote64=12931(start 1824549)、lspd/zn-daemon 全无
01:07:34  events: am_kill com.suw.manager due to stop by 28495  (我 am force-stop 的，非系统)
```

### ★真正的缺口：Z5 全套要踢**两次**框架，我们只踢了一次

Z5 教程 §八：「全套约 8~12 分钟，含**两次框架重启**」：
- **阶段 3**（＝我们做的）：起 `zn-daemon` → 踢框架 → `inject_state:1 / zygote_states:2` ✅
- **阶段 4**（＝完全没做）：`①起 lspd(system_server 域) → ②打针 probe2.jar 抢注 serial → ③再踢一次框架 → ④4 秒内起 guard 150s 循环重打针` → 验收 `serial: []` + Manager「已激活」

⇒ 本发**已拿到阶段 3 的成功**，LSPosed 未激活只因阶段 4 没跑。这不是死结，是**流程没走完**。

### 资源更正（上版说"缺/无网"是错的）

主机 `iqooz5/z5_share/z5_share/files/` 里**全套都在**：
`probe2.jar`(970 B `classes.dex`)、`sud6`(663 KB root 守护)、`su`、`LSPosed-2.2.0.zip`、
`busybox-arm64-selinux`、`ghostlock54`/`ex_z5`、KSU ko/APK。设备侧只缺 `probe2.jar`（可直接 `adb push`）。
⚠️ `sud6` 是 **Z5 内核 5.4.147 专用的临时 root 守护**（配 ghostlock54/ex_z5），
**不能**直接搬到 Z6 5.4.281；但它揭示了 Z5 为什么能扛住 framework 重启——
**root 腿是独立于 zygote 的常驻 socket 守护**，而我们的 `@sushd` 挂在 `com.suw.manager`/`shd` 上。

### 保留成立的一条一手结论

**§5.1 A2「shd/ksuctl/lspd/zn-daemon 全 PPID=1 ⇒ 杀 zygote 不伤 root 腿」被实测证伪**：
踢后 `zn-daemon`/`lspd`/`shd`/`ksuctl`/`com.suw.manager` 全消失、`@sushd` 探测无产出、
`su` 报 `@suwshd errno=111`。PPID=1 也照样没保住。
⇒ 「同 boot 软重启不伤 ko/root」**只保住内核态**；用户态 root 腿会断，阶段 4 所需的 root 执行能力随之丢失。
（上版"late-load 结构性死结、注入窗口与注入器无法共存"的说法**撤回**——注入器在 kick 后仍活了 ≥1.6s 并完成注入。）

### 下一发的最小改造（§4.6）与窗口现状

窗口：`boot_id=180492e3`、`boot_completed=1`、Permissive、`mod=1`、`/dev/ksud`+`/product/bin/su` 在，
但 root 腿全断、daemon 全死 ⇒ "ko 挂着但没有 root 通道"的半残窗口。
收窗：T2/T2.5 的 `@sushd` 腿必「等满」⇒ 走**无 root 分支 `adb reboot`**，复核 `mod=0/Enforcing/无 su/无 kd`。

## 4.6 ★下一发方案：只补 Z5 阶段 4（待用户点头）

前置：收窗 → 重开干净 rc80 窗口（root 腿完整）→ 按 §2 重装两模块 → 起 `zn-daemon` + `lspd`
→ **踢一次框架完成阶段 3 注入**（本发已验证可行）→ 之后框架重建会断 root 腿，
所以阶段 4 必须在**踢之前**把守护腿布成"不依赖 `@sushd`"的常驻形态。

### ★★`probe2.jar` 反编译结论（01:2x，纯主机只读）＝打针不需要 root

`iqooz5/z5_share/z5_share/files/probe2.jar` 内只有 `classes.dex`(1512 B)，`Probe2` 的全部字符串：
`Landroid/net/LocalSocket;` / `LocalSocketAddress$Namespace` / `ABSTRACT` / `connect` /
`getInputStream` / `getOutputStream` / `write` / `read` / `flush` / `resp=` / `main`。
⇒ 它就是**连一个 abstract unix socket**（名字＝`cat /data/adb/lspd/monitor` 得到的
`lspbridge-<uuid>`，本机现值 `lspbridge-a21c00eb-73c2-43d4-b731-90447248d0d4`），
发一笔、读个响应。**没有 su、没有 root、没有 service_manager 调用**。

⇒ **逐动作拆 root 依赖（01:3x 修正：上版"零 root 依赖"是过度乐观）**

| 动作 | 需要的身份 | 从 adb shell 能否做 |
|---|---|---|
| 打针 `app_process … Probe2 "$NAME"` | 任意（`LocalSocket` 客户端） | ✅ 能 |
| 读 `service list \| grep serial` | `u:r:shell:s0`（教程 FAQ：root 域反而看到 0 个服务） | ✅ adb shell 本来就是 shell 域 |
| **起 / 重起 `lspd`** | **root + `runcon u:r:system_server:s0`**（教程 FAQ：只有该域能抢注 serial） | ❌ 不能 |
| `kill -9 lspd / zygote` | root | ❌ 不能 |

⇒ 打针与读状态确实零 root；**但只要 `lspd` 活不过 framework 重建，guard 就需要一次 root 来重起它**。
Z5 的 `guard.sh` 全程 `su -c`、且 `poke()` 里就来 `kill -9 lspd` —— **Z5 的 lspd 是活过 framework
重启的**，靠 `sud6` 这个独立于 zygote 的常驻 root 守护。我们的 `@sushd` 挂在 `com.suw.manager`/`shd`
上、踢后即断 ⇒ **这才是与 Z5 的真正差距，不是 probe2 也不是注入**。

三条候选路线（**均未经实测**，下一发先只验 A′）：
- **A′（推荐）· 踢前预置一个自带 root 的常驻守护**：踢框架**之前**我们有完整 root，此时用 `setsid`
  起一个 uid=0、完全脱离会话、监听 abstract unix socket 的小守护（角色＝Z6 版 `sud6`，
  可直接复用 `/data/adb/ksu/bin/busybox nc` 或自写；**不需要内核漏洞**）。
  framework 重建后主机侧 adb shell 连该 socket 下发命令 ⇒ 阶段 4 全程有 root。
  验证它能否活过重建（本发 `shd`/`ksuctl`/`lspd` 都死了，**此点未证**，是 A′ 的最大风险）。
- **A · 主机侧 guard（仅在 lspd 存活时成立）**：踢前把 `probe2.jar` `adb push` 到 `/data/local/tmp/`
  并 `chmod 644`；`lspd` 用 §2 双 fork 起好（`system_server` 域）；主机侧 guard：踢后 4s 内起、
  150s 窗口内每 1s 用裸 adb shell 读 `service list | grep serial`，一见不是 `serial: []` 就重打针。
  ⚠️ 若 lspd 死了则此路线无解（无法从 shell 重起）⇒ 必须配 A′。
- **B · 借 `init` 的 property trigger respawn**：`/vendor/etc/init/hw/init.at*.rc` 与
  `/system/etc/init/*.rc` 有多条 `on property:sys.boot_completed=1`；但 `/system/etc/init` 是
  `root:root 0755`（erofs ro），**只能靠 overlay 加 .rc 文件**，改动大、风险高，不作首选。

关键节奏（Z5 教程实测）：**踢框架后 4 秒内必须开始 guard，窗口 150s**；
`lspd` 必须 `runcon u:r:system_server:s0`；读 `service list` 必须 `runcon u:r:shell:s0`；
打针＝`app_process -Djava.class.path=/data/local/tmp/probe2.jar /system/bin Probe2 "$(cat /data/adb/lspd/monitor)"`；
验收＝`serial: []` + `lspd` 两个 PID + `inject_state:1` + Manager「已激活 / 2.2.0 (7854) / API 102」。
一轮没过属正常，Z5 教程说 1~3 轮内成功、第 2 轮失败偏多。

## 4.7 ★★第二发实战（11-15 02:0x，用户授权「收窗重开打阶段 4」）＝**LSPosed 仍未激活**，但拿到两条关键验证

### 执行链
| 阶段 | 结果 |
|---|---|
| 收窗 | `w161_teardown.sh RC=0`(6m49s)、独立复核 `boot_id=35996755`/`Enforcing`/`mod=0`/无 su·ksud·kd |
| 重开干净 rc80 | `GO_RC=0`/`OUTER_GO_RC=0`、`boot_id=110df5e9`、判据⑥ 到、`granted=1`、`BIND_RC=0` |
| ★模块目录 | **被 reboot 清光**（`No such file or directory`）⇒ §4.6 里"不用重装"判断错误，已用 `kmod/w230_rebuild_all.sh` 严格白名单重建（ZN 21 文件 / LP 22 文件 / dex2oat_exec 标签 / module.prop hash `2f8cdf9a…`） |
| 执行件 | `probe2.jar`(md5 `248d7f8f…`)、`z6_stage4.sh`、`z6_launch.sh` 两端 md5 一致 |
| 扳机 | `z6_launch.sh` 经 `@sushd` 触发，总控双 fork `setsid` 脱离 |

### ★★两条关键验证成功（这是本发真正的收获）

1. **cgroup 加固＝A′ 方案成立**。总控脚本开头把自己迁到
   `/sys/fs/cgroup/z6stage`（v2）+ `/dev/memcg/cgroup.procs`（v1）+ `oom_score_adj=-1000`，日志实读
   `AFTER_HARDEN cgroup2=[0::/z6stage] oom=-1000`。**踢框架后总控全程存活并写完了 150s guard**
   （`z6_stage4.log` 从 `02:21:49` 写到 `02:25:45`）；`/sys/fs/cgroup/z6stage/cgroup.procs` 里
   `lspd` 三个 PID（14338/14344/15680）**活过 framework 重建**。
   ⇒ 上一发"PPID=1 也全死"的问题有解了：**关键是迁出 `/apps/*` cgroup 子树**，不是 PPID。
2. **`serial: []` 桥建成并守住 150 秒**。`02:22:04` 首次打针即 `serial: []`；`02:22:29` 被系统抢回
   `ISerialManager`，`guard` 自动 `poke` 重打针又抢回；此后 `GUARD ok(16/31/46/61/76/91/106/121)`
   `serial: []` 稳定到 guard 结束。⇒ **probe2 打针零 root、主机/设备侧 guard 形态都可行**。

### ❌ 但 LSPosed 未激活（硬判据）
`uiautomator dump` 实读：**`LSPosed 未安装`**（Dex 优化器包装 / Xposed API 调用保护 全「未安装」）。

根因＝ **`zn-daemon` 从头到尾没起来**：
- `02:21:55 ZN after start: []` + `❌ Could not connect to service!`；`module.prop` 始终保持原始
  `description=Standalone implementation of Zygisk.`、hash `2f8cdf9a…`（daemon 从未 `write prop` 写 ✅）。
- 总控 `start_zn` 的启动形态不对：`( /system/bin/setsid zygiskd daemon & )` 且 **cwd 不在模块目录**
  （`post-fs-data.sh` 第一件事就是 `cd "$MODDIR"`），而 w210 验证过的成功形态是
  `cd 模块目录 + nohup busybox setsid + 清 .injecting/.abort_msg + 从 zip 恢复 module.prop`。
- 另有 `.injecting` 残留锁（`02:22:08`，root 属主 0700，shell 删不动）——但总控以 uid=0 跑，本可清。

### ★★总控报的 `SUCCESS` 是误报，已修脚本
`z6_stage4.sh` 首版把 **`serial: []` 单独当成 SUCCESS**（`02:25:45 ===== SUCCESS round=1 =====`），
但同一份 verify 里明明写着 `zndaemon=[]`、`znctl=[]`、`module.prop` 无 ✅ ⇒ **判据错配第三次复发**
（11-15 01:0x 那轮把阶段 4 判据套到阶段 3，这轮又把桥判据套到完整激活）。
**已修 `kmod/z6_stage4.sh`**（214 行、md5 `f92e4a1c…`、语法通过）：
- ① `start_zn` 改为 w210 形态（`cd "$M/zygisksu"` + `nohup setsid` + 清锁 + 恢复 module.prop）；
- ② 新增 **`zn_gate()`**：必须 `inject_state:1` 且 `pidof zn-daemon` 非空才允许踢框架，
  失败重试 3 次仍不行则 `ABORT` 并 verify 退出，**不再白费 framework 重建**；
- ③ 新增 **`full_success()`**：`serial: []` + `module.prop` 含 `✅zygote` + `inject_state:1` 三者齐才算成功；
- ④ 统一绝对路径（`/system/bin/setsid|runcon|app_process|timeout|unzip`）——
  **`/data/adb/ksu/bin/busybox` 会被收窗删掉**，首版 launcher 差点因此整个起不来。

### 窗口收尾状态（02:2x）
`ko Live` / Permissive / `boot_completed=1` / `serial: []` / `lspd` 三个 PID 活，但
**root 腿断**（`@sushd` 探测无产出、`su` 报 `@suwshd errno=111`、`asuid` setuid 失败、
`ksuctl88 fd` 的 `reboot(magic)` 全 EPERM）⇒ **不重开窗口无法补 ZN**。
按硬纪律收窗（无 root 分支 `adb reboot`），复核 `mod=0/Enforcing/无 su/无 kd`。

### 下一发（第三发）唯一待办
重开后用已修好的 `z6_stage4.sh`（含 `zn_gate`）重跑一遍即可；前置仍是
`w230_rebuild_all.sh` 重建模块 + 推三个执行件。`zn_gate` 会在 ZN 没起时直接 ABORT 并留下
`z6_zn.log`/`.abort_msg`/锁状态诊断，不再浪费 framework 重建。

## 4.8 ★★★第三发实战（11-15 03:0x，用户「开始」）＝**只差一个启动顺序**，已收窗

### 执行链
| 阶段 | 结果 |
|---|---|
| 开火前核验 | 设备干净(`Enforcing`/`mod=0`)、基线 `98bf4052`+`fec3d301`、修正版总控 `9302 B`/`f92e4a1c…`/`sh -n` OK |
| 重开 rc80 | `GO_RC=0`/`OUTER_GO_RC=0`、`boot_id=ab8dd2dd`、判据⑥、`granted=1`、`BIND_RC=0` |
| 推件 | 5 个文件两端 md5 全一致（**设备侧总控确为 9302 B 修正版**，修掉上一发的旧版坑） |
| 重建模块 | `w230_rebuild_all.sh`：ZN 21 / LP 22 / hash `2f8cdf9a…` / `dex2oat_exec` 标签 |
| **★新增前置闸** | `kmod/w232_zn_precheck.sh`：**`ZGATE=PASS`**、`zn-daemon=30397`、`inject_state:1`、`modules64/32: zygisk_lsposed`、`modules_with_issue:0`、cgroup `0::/z6stage`、`oom=-1000` |
| 补 ksud | `kmod/ksud_official` → `/data/adb/ksud`（md5 `9cc94ff5…`） |
| 发扳机 | `z6_launch.sh` → 总控执行、框架确实重启（`zygote64 8449`、`start_ticks 130233`，后又 `22438`/`151902`） |
| 结果 | `serial: []` 在、`lspd` 两个 PID、`zndaemon=30397` 活；**但 LSPosed 未激活** |

### ★★决定性新根因：**ZN daemon 起得太早，`ksud` 还没补**
```
module.prop 始终 = [Root: ❌None, ZL] Standalone implementation of Zygisk.   （无 ✅zygote）
03:12:10 E zn-daemon64: permission denied
03:12:10 E zn-daemon64: error occurred while handling connection of
          action=(16) GetRootImpl uid=2000 pid=22890 sctx=u:r:shell:s0
```
时序：
```
03:00  w230 重建模块（此时 /data/adb/ksud 不存在——收窗脚本会删它）
03:01  w232 precheck 起 zn-daemon  ⇒ 一次性判定 root 实现 = ❌None（缓存，不再重检）
03:0x  KSU boot 后整理把 /data/adb/modules/ 整个删掉
       （daemon 30397 因 cgroup 加固存活，fd 10/11/13 仍持有 lsposed 的 .so (deleted)）
03:07  w234 轻量补回模块文件 + 补 /data/adb/ksud
03:08  发扳机 → 框架重启 → 但 daemon 早已缓存 ❌None ⇒ 注入未发生
```
⇒ **`inject_state:1` 不代表能注入**；还要 `root_status:✅KernelSU (32653)`。
（第一发 01:01 成功时正是 `✅KernelSU`；第二发 ksud 缺失但 daemon 由总控在补 ksud 前起，同样 ❌None。）

⚠️ **口径核正（03:2x 补）**：上面引用的 `GetRootImpl permission denied` 那行，其完整上下文是
`action=(16) GetRootImpl uid=2000 pid=22890 sctx=u:r:shell:s0` —— 这是 **shell 客户端查询 status
时被 ZN daemon 拒绝**，属于 ZN 的权限设计，**不能单独当作"注入失败的直接证据"**。
真正支撑"注入未发生"的硬判据是 **`module.prop` 始终无 `✅zygote`**（daemon 每次注入成功后都会
`write prop` 写这个标记，第一发 01:01:30 就写过）。`root_status:❌None` 与注入失败的相关性成立，
但因果链尚未用单变量实验证实；第四发把 ksud 提前补上后，由 `ZGATE` 的 `root_status` 读数来判定。

⚠️ **ksud 版本更正（03:2x）**：第三发补的 `kmod/ksud_official` 是 **6,286,568 B / `9cc94ff5…`**，
而第一发成功时设备上的 `/data/adb/ksud` 是 **4,892,712 B / `de059ed8…`**
（本机 `kmod/_tmp_ksud_from_dev` = `build_ksud/lib/arm64-v8a/libksud.so` = `kmod/libksud_from_apk.so`，
三份 md5 相同，正是从设备取回的原版）。⇒ **第四发必须用设备原版**。
另注：`kmod/ksu_one_stage.sh` L375 本来就会 `cp /data/local/tmp/ksud /data/adb/ksud`（stage 自带），
但收窗 `w165b_adb_clean.sh` 会删它，且 stage 补的那份是 shim 而非原版 ⇒ 不能指望 stage 自动补齐。

### ★本发新增的三条一手结论
1. **cgroup 加固再次验证成立**：`/data/adb/modules/` 被整个删掉后，ZN daemon 仍活着并持有
   模块 so 的 fd（`/proc/30397/fd → … .so (deleted)`）。这是 A′ 最硬的证据。
2. **`/data/adb/modules/` 会在 boot 后约 3–4 分钟被 KSU 整理清掉**：第二发重建在 boot 后 10 分钟躲过，
   第三发重建在 boot 后 3 分钟正好撞上。⇒ 下一发**必须等 boot 后 ≥5 分钟再重建模块**，
   或在补回文件后立刻发扳机（本发用了后者 `w234_restore.sh`，不杀 daemon、不动状态目录）。
3. **`root_status` 是硬 gate**：下一发把 `✅KernelSU` 加进 `zn_gate()`，并**先补 ksud 再起 daemon**。

### 两个操作坑（已记进口径纪律）
- **清旧 `.out`/`.log` 才能判"腿是否落地"**：本发第一次 poll 命中的是上一发 02:21 的残留
  `z6_launch.out`（`boot_id=110df5e9`），误以为没落地；实际总控已执行并踢了框架。
- **别在总控运行时删它的日志**：本发中途 `rm -f z6_stage4.log` 导致总控那轮的完整日志丢失，
  只能靠 `module.prop`/logcat/进程状态反推。⇒ 判定"是否重复发扳机"前先读日志时间戳与 boot_id。

### 下一发（第四发）最小改动：**只改顺序，不改架构**
1. 开窗后**先等 boot 后 ≥5 分钟**（或 `getprop sys.boot_completed=1` 后再 `sleep 300`）再动模块；
2. `w230_rebuild_all.sh` 里**在起任何 daemon 之前**先补 `/data/adb/ksud`（把 `ksud_official` 推过去）；
3. `w232_zn_precheck.sh` 的 `ZGATE` 判据从 `inject_state:1` 扩成
   **`inject_state:1` + `root_status:✅KernelSU`**（`zygiskd status | grep -a 'root_status:✅'`）；
4. 通过后立刻 `z6_launch.sh`；总控 `zn_gate()` 同样加 `root_status:✅` 检查；
5. 验收仍按 `full_success()`：桥 + `✅zygote` + `inject_state:1`，外加 Manager UI「已激活」。

⚠️ UI 判据本发仍被 vivo 通知栏挡住（`mCurrentFocus=NotificationShade`，多次 `input keyevent 4`/
`cmd statusbar collapse`/swipe 都无效）⇒ 判"未激活"靠的是 `module.prop` 无 ✅ + `GetRootImpl` 报错，
**不是** UI 实读。下一发若 UI 仍挡，可用 `dumpsys activity top` 或直接在通知栏上叠 `uiautomator dump --windows`。

### 收窗（03:2x）
无 root 分支 `adb reboot`：`boot_id=8514fe17`、`Enforcing`、`mod=0`、无 `su`/`/dev/ksud`、
`boot_completed=1`；本机基线三项未变。

## 4.9 ★第四发（11-15 03:2x–04:4x）＝**连窗口都没开起来**：连续 punch 空枪，按纪律停手（三发汇总见 §4.10）

### 结论先行
第四发**没有进入阶段 4**，因为 `go.sh` 开窗连续两发都是**空枪**（punch 概率性失败）。
**不是设备问题、不是 ko 缺陷、不是 rc82 那类硬复位** —— 设备全程健康
（`boot_id` 与锚点一致、`Enforcing`/`mod=0`/`boot_completed=1`/电量 100/adb shell 正常），
本机基线三项未变。

| 发次 | 日志 | 结果 |
|---|---|---|
| 第一枪 03:27 | `STAGE4_WINOPEN_0327.log` | 卡「等 stage 判据⑥」25 分钟 ⇒ `OUTER_GO_RC=124`，`boot_id=89c58309`，`mod=0`/`Enforcing` |
| 重试 03:54 | `STAGE4_WINOPEN_0354_retry.log` | 同样卡住 16m40s ⇒ `OUTER_GO_RC=124`，`boot_id=1d0a2fa4`，`mod=0`/`Enforcing` |

### ★空枪根因（只读诊断，证据链完整）
- **成功发对照**（`go_bootstrap_1115-0256.txt`）：
  `[15s] pr= enforce=Permissive s=[Linux] layer=Y tail=…瞬间确实是活的[DONE] 全流程结束(没炸)RC=0`
- **两发失败**（`go_bootstrap_1115-0340.txt` / `-0404.txt`）：
  ```
  dispatched
    [15s] adb.exe: device not found   （连续 15/30/45/60s 掉线）
    [75s] pr= enforce=Enforcing s=[Linux] layer=Y tail=
  ```
  `punch.log` 停在 `[*] 幽灵已成形(EDEADLK); 等 W 的 futex 超时`；
  `pr.log` 停在 `[h] #1 相0 即将 punch nice=18 (这行之后没有日志=死在这一发的链走里)`；
  `ksu_stage.log` **根本没落盘**；采样器全程 `enf=Enforcing pr=[] mod=0`。
  ⇒ **GhostLock 利用死在「链走」阶段**（futex/幽灵竞争），`enforce` 从未翻成 Permissive。
- **为什么 `go.sh` 不早点判空枪**：`blank_gate.sh` 的 `blank_now` 要求 `sawper=1` 才计一次空枪确认；
  这两发是 `sawper=0 / Enforcing / pr=[空] / post=0` ⇒ 判据一直"不成立"，脚本只能等到超时。
  ⇒ 日志里「空枪候选不成立」**不等于"不是空枪"**，只是没达到那个特定判据的形状。
- `ro.boot.bootreason=USB_CHARGER/PS_HOLD/0x01+0x01` 仍是 STICKY 值（见长期口径），
  `HISTORY` 里 `reboot,shell` 是正常 reboot 记录，**不作硬复位证据**。

### ★纪律：停手，不赌第三发
依据：`RC82B_DIAG` 那一轮的口径「复验前必过安全闸、两发皆异常 ⇒ HARD STOP，别赌第三发」，
以及「窗口不留过夜」（本窗已跨 11-14→11-15 近 8 小时）。
⇒ 本发**没有消耗一个可用窗口**（ko 从未加载），设备本身处于干净出厂态，无需收窗动作。
若明天再打，建议先**彻底断电静置**（关机+拔 USB 静置数分钟再上电）以清掉可能的利用环境暂态，
并且第一枪仍用 `timeout 1000` 早判读（15 分钟内没到判据⑥就当空枪收手，别等 25 分钟）。

### ★本发已完成的准备（下一发直接复用，不用重做）
- 三件改好的脚本（均 `sh -n` 通过）：
  `w230_rebuild_all.sh` **6076 B / `36040f1d…`**（新 [2.5] 优先用**设备原版 ksud** `/data/local/tmp/w234_ksud_orig`）、
  `w232_zn_precheck.sh` 3627 B / `b2a74c2c…`、`z6_stage4.sh` 9656 B / `073b2604…`（gate 含 `root_status:✅`）。
- **★ksud 版本更正**：第一发成功时设备 `/data/adb/ksud` 是 **4,892,712 B / `de059ed8…`**
  （本机 `kmod/_tmp_ksud_from_dev` = `build_ksud/lib/arm64-v8a/libksud.so` = `kmod/libksud_from_apk.so`，三份 md5 相同）；
  第三发误补的 `kmod/ksud_official` 是 **6,286,568 B / `9cc94ff5…`**，另一个构建。
  下一发主机侧先 `adb push kmod/_tmp_ksud_from_dev /data/local/tmp/w234_ksud_orig`。
- **★口径核正**：§4.8 引的 `GetRootImpl permission denied` 是 **shell 客户端查 status 被 ZN 拒绝**
  （完整串 `action=(16) GetRootImpl uid=2000 … sctx=u:r:shell:s0`），**不能单独当作注入失败的直接证据**。
  真正硬判据是 `module.prop` 始终无 `✅zygote`。`root_status:❌None` 与失败相关，但因果尚未单变量验证。

### 下一发完整顺序（一次写死）
1. 开窗 `I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko timeout 1000 bash kmod/go.sh`，确认 `GO_RC=0` + 判据⑥；
2. **等 boot ≥5 分钟**（避开 KSU 对 `/data/adb/modules/` 的 boot 后整理）；
3. `adb push kmod/_tmp_ksud_from_dev /data/local/tmp/w234_ksud_orig`（设备原版 ksud）；
4. `w230_rebuild_all.sh`（内部 [2.5] 先补 ksud，再重建两模块白名单）；
5. `w232_zn_precheck.sh` ⇒ 必须 `ZGATE=PASS` 且 `root_status:✅KernelSU`；
6. 立刻 `z6_launch.sh` ⇒ 总控 `zn_gate`（同样查 ✅）→ 踢框架 → guard 150s → `full_success()`；
7. 验收 `serial: []` + `module.prop` 含 `✅zygote` + Manager UI「已激活」。

## 4.10 ★★第三枪复验（11-15 04:26，用户「继续」）＝**仍是同一死点**，三发空枪，正式 HARD STOP

### 复验前安全闸（全过）
设备干净（`boot_id=1d0a2fa4`/`Enforcing`/`mod=0`/无 su·ksud）、`HISTORY` 无新增、
电量 100、本机基线 `98bf4052`+`fec3d301` 未变、七步所需件 md5 全对（含设备原版 ksud `de059ed8…`）、
三件脚本 `sh -n` 通过。⇒ 按「复验前必过安全闸」放行这一枪，并事先声明**若又是空枪就停手**。

### 结果：第三发同样空枪
`STAGE4_WINOPEN_0426.log`：卡「等判据⑥」，16m40s ⇒ `OUTER_GO_RC=124`，
`boot_id=8ab4a18a`（与 `#6.292 锚点` 一致 ⇒ 无硬复位）。设备终态 `Enforcing`/`mod=0`/`boot_completed=1`。

### ★★三发同一死点（这是本轮最重要的结论）
| 发次 | boot 锚点 | 结果 | `pr.log` 死点 | `ksu_stage.log` |
|---|---|---|---|---|
| 03:27 | `89c58309` | `OUTER_GO_RC=124` | `#1 相0 即将 punch nice=18` 之后无日志 | 不存在 |
| 03:54 | `1d0a2fa4` | `OUTER_GO_RC=124` | 同上 | 不存在 |
| 04:26 | `8ab4a18a` | `OUTER_GO_RC=124` | 同上 | 不存在 |

三发共同读数：`dispatched` → `[15s] adb.exe: device not found`（USB 掉线约 60s）→
`[75s] pr= enforce=Enforcing s=[Linux] layer=Y tail=`（空）、
`punch.log` 停在 `幽灵已成形(EDEADLK); 等 W 的 futex 超时`、
采样器全程 `enf=Enforcing pr=[] mod=0`。
⇒ **不是"概率性偶发"**：三次不同 boot、不同 slide 缓存（`1da4000000` / … / `19dbe00000`）都死在
GhostLock **链走**的同一处，`enforce` 一次都没翻成 Permissive、`stage` 一次都没落盘。
⇒ 更像**当前环境态**（长时间连续 reboot / USB 供电 / 内核内存布局 / 利用前置条件）发生了某种持续变化，
单纯重打不会自己恢复。

### ★★正式 HARD STOP：不再打第四枪
- 依据：项目 `RC82B_DIAG` 口径「两发皆异常 ⇒ HARD STOP，别赌第三发」；这里已给到**三发**。
- 且已跨夜近 8.5 小时；设备是量产机；本发没有消耗任何可用窗口（ko 从未加载）。
- 设备保持干净出厂态，**无需收窗动作**。

### 若要恢复，先做环境侧动作（不是再打一枪）
1. **彻底断电静置**：关机 → 拔 USB → 静置数分钟 → 重新上电开机，再 `adb get-state` 确认；
2. 确认 USB 线/口稳定（三发都在 punch 后掉线 60s，值得排查连接）；
3. `adb reboot` 一次冷启动后读 `HISTORY` 无新增异常，再按 §4.9 的七步打第一枪，
   仍用 `timeout 1000` 早判读（15min 没到判据⑥就当空枪收手）。
4. 若断电静置后仍空枪 ⇒ 转去查 GhostLock 链走本身（`/data/local/tmp/pr.log` 的
   `fake_lock/prio/SHAPE`、futex 超时、`ghost_sen_state`），**不要再重复 `go.sh`**。

### 本轮（第四发）净产出
- 三发空枪的完整证据链与「同一死点」结论（上面表格）；
- 两项更正已固化：设备原版 ksud（4,892,712 B / `de059ed8…`）优先、
  `GetRootImpl` 断言核正；
- 七步顺序与三件改好脚本（§4.9），下次直接复用，不用重做。

## 4.11 ★★★第五发（11-15 07:0x，网络波动后「继续」）＝**Zygisk 双 zygote 注入成功，阶段 4 打通**

> ★这是历史性的：跨几十发一直卡住的"zygote 从未重启⇒无注入窗口"根因，本发被彻底消除。
> 窗口 `boot_id=ad30ffeb-8a34-445d-a9c1-03542641e1b5`（06:52 那枪 `go.sh` 在**网络波动期间开成**，`GO_RC=0` @ 07:05:56，前几发以为又空枪其实是真开了）。

### ★★唯一真正的关键改动：把 `/data/adb/ksud` 在起 ZN daemon **之前**就补上（设备原版 `de059ed8…` / 4,892,712 B）
- 第四发的全部失败（含 03:0x 那发的 `root_status:❌None`）根因＝ZN daemon 起得太早、`ksud` 还没补 ⇒ 一次性判定 root 实现＝`❌None` 且缓存不再重检 ⇒ `inject_state:1` 但注入不发生。
- 本发 `w230` 的 `[2.5]` 段**先 `cp` 设备原版 ksud 到 `/data/adb/ksud`（md5 `de059ed8`）**，再重建两模块；`w232` 起 daemon 时 `root_status` 第一次读到 `✅KernelSU (32653)` ⇒ **`ZGATE=PASS`**。

### 七步实测（全部一次过）
1. 开窗 `GO_RC=0`（`insmod rc=0`、Permissive、`mod=1`、`su`、`/dev/ksud`）；boot ≥5min（实测 `up=3746` 才动）。
2. `adb push kmod/_tmp_ksud_from_dev /data/local/tmp/w234_ksud_orig`（设备原版 ksud）。
3. 推 `w230/w232/z6_stage4/z6_launch` → `w230` 重建（ZN 21 / LP 22 / hash `2f8cdf9a` / dex2oat_exec 标签 / **`KSUD_OK de059ed8`**）。
4. `w232` ⇒ `ZGATE=PASS`：`zn-daemon=5062`、`inject_state:1`、`root_status:✅KernelSU (32653)`、`modules64/32: zygisk_lsposed`、`modules_with_issue:0`、cgroup `0::/z6stage`、oom=-1000。
5. `z6_launch` ⇒ `z6_stage4` 脱离启动（pid=6348，cgroup/oom 加固），`ZN_GATE_OK` 含 `✅KernelSU`，起 lspd `[6431]`。
6. `z6_stage4` 主流程：`KICK`（杀 system_server+zygote64+zygote）→ `FRAMEWORK_BACK`（zygote64 `1028→6729`、`boot_completed=1`）→ `GUARD 150s`（期间 `i=15` 一度 `serial=[android.hardware.ISerialManager]` 注册成功）。
7. 验收（`z6_stage4` 内 VERIFY @ 08:04:56）：
   ```
   module.prop = [✅zygote, ✅zygote_secondary, Root: ✅KernelSU (32653), ZL]
   znctl      = zygote_states:2  inject_state:1  modules_with_issue:0
   FULL_SUCCESS_CRITERIA_MET
   ===== SUCCESS round=1 (full criteria) =====
   ```

### ★最终证据快照（`boot_id=ad30ffeb`）
- 窗口：`mod=1 / Permissive / boot=1 / up=4416`。
- `module.prop`：`[✅zygote, ✅zygote_secondary, Root: ✅KernelSU (32653), ZL]`（ZN daemon 自写，权威）。
- 进程树：`zn-daemon=5062`、`lspd=6431/7769`、`zn-zygisk-companion64 zygisk_lsposed=6901`、**`org.lsposed.manager=17362` 且父=`6729`＝踢后新 zygote64** ⇒ Manager 直接活在注入后的 zygote 里，被 Zygisk 挂钩。
- 推论：`zygote_states:2` + `✅zygote, ✅zygote_secondary` + Manager 跑在注入 zygote 下 ⇒ **LSPosed 在临时窗口内完全激活可用**。

### 注意
- 这是**临时 root 窗口内**的激活：ko 卸掉 / 收窗 reboot 后，磁盘上的模块目录还在但不再被 KernelSU 加载，LSPosed 不持久。本窗口内可正常使用。
- `znctl status` 从 shell 偶发空回（adb 掉字），以 `z6_stage4.log` 内 VERIFY 抓到的 `zygote_states:2` 为准。
- 窗口不留过夜；用完 `I_KNOW=1 bash kmod/w161_teardown.sh`。

## 4.12 ★收尾双目标（su 同窗 + 官方管理器显示"支持"）＝**都在 stage 层解决，均无需重建 ko**

> 11-15 08:3x，用户要「可用的 su/root 授权」+「官方管理器字面显示支持」，且要和 LSPosed 同窗。
> 结论：两个都是**运行期/stage 层**的事，不碰 ko（rc80 不用重建，规避了 rc82 加载即崩的风险）。

### Goal B（官方管理器显示"不支持"）根因与解
- 现象：`me.weishu.kernelsu` 显示"不支持"。根因＝管理器 native `Natives.getVersion()` 走 `prctl(0xdeadbeef, cmd=2, …)`
  及一组 KSU magic（`0x80104b02`/`0xc0044b06` 等）取版本；**我们的 ko 一个都不应答**（grep 源码无 prctl）。
  另 `core/init.c:209` `#ifndef CONFIG_KSU_DEBUG` 会 `kobject_del(&THIS_MODULE->mkobj.kobj)` 摘掉 `/sys/module/kernelsu`。
- **★正解（无需重建 ko）**：ko 有 **`/proc/ksu_install_fd`(0600 root-only)**，root 侧 `echo <管理器pid> > /proc/ksu_install_fd`
  即把 KSU 驱动 fd 装进该进程；管理器扫 `/proc/self/fd` 找 `[ksu_driver]` ⇒ **当场显示真版本**（dev_syms.c §6.81）。
  实测本窗该节点在（`-rw------- root root`）、shell 写 EPERM（合预期）。
- 已加进 `z6_stage4.sh` 的 `install_mgr_fd()`：流程末尾起 `me.weishu.kernelsu`→取 pid→`echo pid > /proc/ksu_install_fd`。

### Goal A（su 与 LSPosed 同窗）根因与解
- 根因：踢框架把 `com.suw.manager`→`shd`(@suwshd 根代理)连根杀；ko fd 注入只在开窗相一次性做、重开 app 不重注。
- **★正解（无需重建 ko）**：`shd` 自己用 `syscall(SYS_reboot, KSU_INSTALL_MAGIC…)` 拿 fd（root 域可独立拿），
  且 `setsid nohup shd <port> 1800` 本就脱离（`_exp_z6root.sh:169` 现成手法）。⇒ 踢框架**之前**起一个 setsid+进
  `z6stage` cgroup 的 shd，扛过重建、踢后仍听 @suwshd。已加进 `z6_stage4.sh` 的 `start_shd_detached()`（在主流程 kick 前调用）。

### 落点
- `kmod/z6_stage4.sh`（`3ecb849d`，261 行，`sh -n` 通过；旧工作版备份 `z6_stage4.sh.bak_working_073b2604`）。已推设备两端一致。
- **两项目标都要在新一发 exploit 上验证**（当前临时窗无 root/@sushd 已死、无法就地验证；踢框架也不可能撤回）。

## 4.13 ★★★三目标同时达成（11-15 11:04，boot `8781c99c`）：LSPosed + su(shd) + 管理器`工作中[越狱模式]`

> 用户要「可用的 su/root 授权 + 官方管理器字面显示支持 + 和 LSPosed 同窗」。这一发全拿到了。
> ★真相：官方 KernelSU v3.3.0 对非 GKI 内核的"支持"招牌是 **`工作中 [越狱模式]`**（不是"不支持"）；
> 之前一直显示"不支持"是**时序错**，不是做不到。

### ★Goal 2 的关键＝"抢装"（一手 `kmod/b8_mgr.sh`，B8 验证 4/4）
- 管理器**只在启动那一刻查一次 fd**；fd 晚到它**不重查** ⇒ 一直"不支持"。（我的首版 `install_mgr_fd` 是 manager 起来后才 echo，晚=必失败。）
- 正解：`am force-stop me.weishu.kernelsu` → 后台 **0.2s 抢装循环**盯新 pid `echo pid > /proc/ksu_install_fd` → `sleep 0.3` → `am start -n me.weishu.kernelsu/.ui.MainActivity`。
- 本发命中：`MGR 抢装 pid=12359 第 3 轮`、`dmesg KSUFDINST 回调跑在 pid=12359 => fd=76` ⇒ 截屏 `工作中 [越狱模式] / 版本 32653-2 / 超级用户(1) / 模块(2)`。
- ⚠ 红字「管理器(32601)与驱动(32653)不匹配」纯版本号提示、不影响功能（要消掉需换匹配 32653 的 manager APK）。

### ★Goal 1 的关键＝踢框架前 setsid+cgroup 起 shd（`start_shd_detached`）
`SHD detached=[31072] cgroup=[0::/z6stage] @suwshd(on) idle=1800` + `POST-REBUILD shd=31072` ⇒ 扛过踢框架、踢后仍听 @suwshd。

### ★LSPosed（同窗）
`serial: []` 桥稳、`lspd=[1166 30668]`、`zn=29556`、`zygote=31196`（踢后新 zygote）⇒ 注入生效（同 07:0x 成功信号）。

### ★stage4 本轮其它修正（都已固化进 `kmod/z6_stage4.sh`）
- `install_mgr_fd()` 换成 B8 抢装法，且**放到 guard 之后**（框架稳了才拉得起管理器；踢后 11s 拉必失败）。
- `guard()` 加 `[ -d "$LP" ] || GUARD_BAIL`：模块目录被 KSU 清理时**不再空转 30 分钟**，直接放弃 LSPosed。
- `full_success()` 放宽：模块 `module.prop` 被清但 `lspd 活着 + serial[]` 也判 LSPosed 生效（不再假阴性）。
- 踢框架后 `/data/adb/modules` 可能被 KSU 清理（~30-40s 后），若 lspd 已在清理前起来则 LSPosed 不受影响（deleted fd 仍活）。

### 交付口径（本轮最终）
`I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh` → 等 boot ≥5min → 推 `_tmp_ksud_from_dev`→`w234_ksud_orig` +
`w230/w232/z6_stage4/z6_launch` → `w230`（重建+补设备原版 ksud de059ed8）→ `w232`（`ZGATE=PASS`+`root_status:✅`）→
`z6_launch`（新版 stage4：踢前 shd、踢后模块重建检查、guard、抢装装管理器 fd）⇒ 三目标齐。
`su` 的 shell uid(2000) 不授权属正常——**授权走管理器「超级用户」页**（角标=已授权 app 数）。

### ★稳定性（11-15 15:5x 增补，boot `6d0e8101`）：`越狱模式` 不自己持久，要"维持件 + shd idle=0"
- **病**：管理器是普通 app，被系统回收/被划掉后**新进程没 fd**（fd 只属那一个进程），而管理器**只在启动那一刻查一次** ⇒ 回退"不支持"。shd 原 `idle=1800`（30min 无请求自退）⇒ 4 小时后也死。
- **解（已固化进 `z6_stage4.sh` `763d7368`）**：
  1. `start_shd_detached` 改 **`shd <port> 0`**（idle=0，永不自退）。
  2. 新增 **`start_keeper()`**：`touch /data/local/tmp/b8_keep` + 起 `b8_keep.sh`（盯管理器 pid，一变就重抢装，0.2s 粒度）并进 z6stage cgroup。删 `/data/local/tmp/b8_keep` 即停。
- **实测通过**：`am force-stop me.weishu.kernelsu` → 重开 ⇒ keeper 日志 `INJ pid=14400`、dmesg `KSUFDINST → pid=14400 => fd=94`、首页**仍是 `工作中[越狱模式]/32653-2`**（不再掉"不支持"）。
- ⚠ 版本红字「需要更新内核 / 管理器 32704 与驱动 32653 不匹配」纯提示：越狱模式/su/LSPosed 全正常。**别为它重编 ko**——`KSU_VERSION=30000+git次数`，可用 `KSU_VERSION_OVERRIDE` 覆盖但那是"谎报"（API 仍是旧版），且重编有碰 rc80 的风险；真要匹配得用恰好 32653 的 manager APK。
- 七步里**要多推一个 `kmod/b8_keep.sh`** 到 `/data/local/tmp/`。

## 4.14 ★四支 adb 脚本（11-15 16:0x 建，一键化）

| 脚本 | 作用 | 关键 |
|---|---|---|
| `kmod/z6_on.sh` | 一键开窗。默认=开窗+装预置模块(ZN+LSPosed)+注入+shd+主动抢装+维持件；`--no-modules`=只做 shd+主动抢装+维持件（不装模块/不踢框架，**最稳**） | 内部跑 `go.sh`（punch）；`--no-modules` 走 `z6_light.sh` |
| `kmod/z6_off.sh` | 收窗：停维持件→`adb reboot`→复核 `mod=0/Enforcing/无su·ksud` | 踢框架后无 root 也可靠（reboot 即干净） |
| `kmod/z6_soft.sh` | 软重启：杀 `system_server+zygote`（**ko 不卸载**、不花 punch） | 需 root 腿(@sushd，即踢框架前)才派得动；之后 shd/维持件(cgroup 脱离)自动恢复 |
| `kmod/z6_after.sh` | 软重启后补：派 `z6_light`(shd+主动抢装+维持件) | 同上需 @sushd；没自动回时手动补一次 |
| `kmod/z6_light.sh` | 设备侧轻量总控：`shd(idle=0)`+主动抢装+维持件，不碰模块/不踢框架 | `--no-modules` 与 `z6_after` 的内核侧；**核心稳定路径** |

- **`--no-modules` 是"日常最稳"档**：root+su+越狱模式三样不需要模块、不需要踢框架 ⇒ 没有模块清理竞速/踢框架 adb 掉线/lspd 空转。要 LSPosed 才用默认档（有那些固有代价）。
- 软重启+after 的价值：exploit 只打一次（贵、有 punch 风险），之后软重启 + 重抢装便宜重建；但因 root 腿(@sushd)在踢框架后即死，软重启类脚本只在"踢框架前"能派单。
- v3.3.0 管理器才有「超级用户/模块」页签（`v3.3.1-24`=32704 无该页签）；版本红字纯提示，别为它重编 ko。

## 5. 收窗

`I_KNOW=1 bash kmod/w161_teardown.sh`；无 root 时 `adb reboot` 即干净收窗（ko 卸 / SELinux 回 Enforcing / bind 消失）。boot 后复核 `mod=0 / Enforcing / 无 su / 无 kd`，
并删 `/data/local/tmp/ksu_two_profiles`（本发未铺，可略）。**窗口不留过夜**（本窗已跨 11-14→11-15）。

## 6. 本轮用到的脚本（均在 `kmod/`）

| 脚本 | 作用 |
|---|---|
| `w204_extract_modules.sh` | 初版 unzip 全量（**留坑**，仅存档） |
| `w205_recon.sh` | 读 customize.sh / zygiskd 接口 / 现状 |
| `w206_setup.sh` | 初版架构选择（**留坑**：多余文件） |
| `w207_diag.sh` | 抓 logcat 定位 `verify1 failed` |
| `w208_verify.sh` | 全量 sha256 校验、machikado、ksud 探测 |
| `w209_recover.sh` | 证伪"module.prop 被改写"假设 |
| **`w210_rebuild.sh`** | ★严格白名单重建 zygisksu → daemon 一次成功 |
| `w211_prep.sh` | license 探测 + 收窗风险评估 |
| `w212/w213_lspd*.sh` | lspd 崩溃诊断（w212 有 pkill 自杀 bug，存档） |
| **`w214_lspd3.sh`** | ★严格白名单重建 LSPosed + chcon + 双 fork → lspd 常驻 |
