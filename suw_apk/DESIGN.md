# SU 白名单管理器 —— 设计与原理

> 目录内容：`AndroidManifest.xml`、`src/com/suw/manager/MainActivity.java`、`build.sh`、
> `install2.sh`、`ui_scan.py`、产物 `suw.apk`。本文只讲**为什么这么设计**与**已证/未证**。

## 1. 它解决的问题

这台 iQOO Z6（V2220A，`5.4.281-qgki-g2a88cd145def`，BL 锁着、不能刷任何分区）上，
GhostLock(CVE-2026-43499) 每次开机能换来一个**易失的 uid0 + SELinux permissive 窗口**。
用户要的能力是 KernelSU 那两件事：**内核级 root** + **只有白名单 app 看得见 root**。

本方案的答案是三层，每层职责单一：

```
① 提权链(不在本目录)   cm57/pr.c + cm57/round*.sh
     ↓ 产出 uid0 + permissive 的"窗口"
② su 层(常驻本 boot)   cm57/sud.c → /data/local/tmp/sudbin, 复制一份改名成 /product/bin/su
     ↓ 提供"按 uid 授权"的语义
③ 管理面(本目录)        suw.apk —— 只是 ② 的 CLI 的图形前端
```

**③ 不含任何提权逻辑**，所有动作都是 `su -c /data/local/tmp/sudbin --policy add|del uid=N`。
好处：授权策略只有一份实现（daemon 侧），UI 换掉/写错都不会造成"绕过"；坏处见 §5。

## 2. 为什么授权键是 uid，不是包名

app 调 `su` 时，`su` 进程是**它自己 fork 出来的子进程**，`SO_PEERCRED` 给的 uid 就是该 app 的 uid
⇒ uid 是最不会说谎的键。包名只能从 `/proc/<pid>/cmdline` 或父进程 cmdline 里读，而
`Runtime.exec("su -c id")` 落地时 cmdline 常常是 `/system/bin/sh -c su ...`，会被中间 shell 改掉。
所以 `pkg=` 规则只是**辅助**（按 cmdline 子串匹配），主判据永远是 `uid=`。

策略文件：`/data/adb/su/su.policy`，目录 `0700 root`、文件 `0600 root`。
**故意不放 `/data/local/tmp`** —— 那个目录 uid2000 自己就能写，白名单会形同不存在。
实测判据（真机）：uid2000 对它 `cat`/写/`ls` 全部 `Permission denied`。

## 3. 语义与判据约定（写死，别改）

| 约定 | 值 | 为什么 |
|---|---|---|
| 默认策略 | 只有 `uid=0`，其余**默认拒绝** | 白名单语义；"命中不了=拒绝"而不是"放行" |
| 条目匹配 | 一行一条，**第一条命中生效**，`-` 前缀=显式拒绝 | 允许在 `*` 之前挖洞 |
| 生效时机 | daemon **每个请求重读**策略文件 | 改完立即生效，不需要重启 daemon（实测撤销也立即生效） |
| 被拒退出码 | **126** | libsu 一类 root 客户端靠退出码判有没有授权 |
| 连不上 daemon | 127 | 区分"没授权"与"本 boot 没窗口" |
| 提权语义 | 命令以 root 跑，**调用方进程自身 uid 不变** | 与 KSU/Magisk 相同（KSU 也是给一个 root 子进程） |

已证（证据 `cm57/round6_0929_1253_r1_test.log`、`cm57/round6_0929_1421_r1_test.log`）：
默认拒绝 rc=126 → 热加白名单得 `uid=0(root) … context=u:r:kernel:s0` → 热撤销立刻回 126 →
按 uid 粒度（`uid=10183` 允许、邻近 `10184` 仍拒）→ 并发不排队（两路各睡 3s，耗时 3s）→
SIGPIPE 后 daemon 存活 → `/product/bin/su` 裸名端到端 → **真实安装的 `com.suw.manager`(uid=10284)
被拒→授权→rc=0**。

## 4. UI 设计原则：三格分开，不给笼统绿灯

界面顶部三行状态各自独立：`su 通道 rc`、`策略内容`、`账本尾部`。
原因是这套东西有三种不同的"不可用"，混成一个红灯就会误导：

- `rc=127/-1`：本 boot 没打过链（或窗口已结束）⇒ 需要重打，不是 bug；
- `rc=126`：su 层活着，但这个 uid 没被授权 ⇒ 需要 root 侧加白名单；
- `rc=0` 但列表为空：策略文件被 reset 了。

app 列表用 `PackageManager`（不需要 root）拿"包名+uid+显示名"，只有**读写策略**才走 `su` ⇒
没窗口时界面照样能看，不会白屏。

### 4b. 皮肤：KernelSU 式四页（2026-09-29 重写，`MainActivity.java` 全代码搭、无 res/）

顶栏(绿) + 底部四页 + 圆角卡片。右上角一个状态 chip：`已激活 / 已装未授权 / 未激活`。

- **首页** = 三判据逐行(带色点) + "本 boot"卡(uid / slide / agent 通道 / 是否已发过 PUNCH) + 边界卡。
- **超级用户** = KSU 那套"图标 + 名称 + `包名 · uid=N` + Switch"。默认**只列** 本 app / 已授权 /
  请求过 su 的，整机 561 个第三方应用收在
  "显示全部第三方应用(N)" 里；顶部有搜索框(名称/包名/uid)。
  **副标题里的"该 uid 最近一次请求"必须带发起进程**(2026-09-30 改)：一个 uid 背后是几十个包
  (uid=10667 实测摊了三十多个)，只写 `uid=` 就会把别的包的历史读成这一行的(MT 那行显示的其实是
  `com.baiye.h3dpatcher`)。审计行里 `comm=[su]` 是 su 壳自己，发起者在 `parent=[comm/cmdline]`；
  app 侧 `Runtime.exec` 常先起 sh ⇒ 光看 parent 只剩 `sh`，所以 daemon 另记一层
  `gparent=[pid:comm/cmdline]`(**只进审计，不参与策略匹配** —— 参与匹配等于把身份交给进程自己写的 cmdline)。
  渲染优先级：parent cmdline 首 token 像包名(带点) → 直接用；带 `/data/data/<包>/` → `包名(bash)`；
  否则退到 gparent → `bin.mt.plus(经 sh 中转)`；再不行照实写 `sh(看不到发起包)`，**不猜**。
  允许/拒绝各留最近一条 ⇒ 一次授权不会被更早的一次拒绝盖掉。时间用**相对值为主 + 括号里 HH:mm**
  (审计每次激活都重建，日期是常数噪声；设备墙钟实测与 PC 秒级一致，所以 HH:mm 可信)。
  **开关失败要回弹**：`change()` 里若 `rc!=0`，先把 listener 摘掉再把 Switch 拨回去 ——
  否则界面会显示一个策略里根本没有的"已授权"，那就是假绿灯。
- **激活** = 三步一条线：① 自检 ② 采样 25s + 解 slide ③ 打链(红色危险按钮 + 必须勾确认 +
  进度条 + 每 5s 拉 `punch.log` 尾部)。
- **设置** = 最近 su 请求(审计原文) + 说明。

实现上三条硬约束值得记：① 没有 AndroidX/Material ⇒ 卡片/按钮圆角全用 `GradientDrawable` 手搭，
`Button` 要 `setStateListAnimator(null)` 才不被默认 ripple 形状盖掉；② 主题在 manifest 里指
`@android:style/Theme.DeviceDefault.NoActionBar`(自己画顶栏)，深浅色按 `uiMode` 现算调色板；
③ 图标只能 `pm.getApplicationIcon(pkg)` 现取，**没有 res/ 就换不了 app 自己的图标**(仍是默认安卓机器人)。

## 5. 已知边界（这是设计的一部分，不是待办）

1. **准入条件是本 boot 全局 permissive**：MAC 关掉之后 exec 那道门才开。所以这台机器上
   "enforcing 下的按 app 策略"拿不到 —— 那是 KernelSU 内核部件才有的东西。
2. **一切易失 —— 但有两个例外，必须主动清**：permissive、`/product/bin` 的 tmpfs 覆盖、daemon 都随重启
   消失（这是刻意的，与"不留持久化"一致）。**不**随重启消失的是
   `/data/adb/su/su.policy` 和 `/data/adb/su/su.ctrl` —— 它们在真 `/data` 上，而且目录 0700 root，
   shell 连 `stat` 都 EACCES，所以重启后既看不见也删不掉。
   ⇒ 收尾规矩：**趁 root 窗口还活着**跑 `cm57/round9_cleanup.sh`（它第一步就是
   `su -c "rm -rf /data/adb/su"`，删不掉会明确报警而不是静默跳过）。
   忘了做的后果不是安全风险（没有 daemon 和 su 二进制，这两份文件是死的），而是留痕。
3. **改白名单需要一个 root 窗口**：撤销也一样。窗口一死，UI 上的按钮全部不可用，只能先重打。
   （想改成"无 root 也能改"就得把策略挪到 shell 可写，那等于放弃 §2 的隔离。）
4. **配对写污染**：GhostLock 的泄漏弹会把 `init_uts_ns.name.sysname[4]` 写成 `0x01`，本 boot 内
   `uname().sysname != "Linux"` ⇒ `art::IsKernelVersionAtLeast` 里的 `Check failed` 让 **artd SIGABRT
   并且是每秒一次的崩溃循环**（23:02 实测 5 连击）。影响面比原先记的更宽：不只是"新装/刚更新的 app"，
   **已装 app 被 force-stop 后重新拉起也会起不来**（MT管理器就这样消失，logcat 里全是 artd 而不是它自己）。
   ⇒ 推论：**凡是"要装 APK 或要验第三方 app 行为"的活，都不能安排在已 punch 的 boot 上**。
   唯一复位是 reboot。缓解办法是把相0 落点挪到 `nodename/domainname`（`pr.c` 的 `tgt=` 支持），
   但**改动必须重跑真机验证**。
5. **②屏的鉴权是"秘密"不是"身份"**（2026-09-29 实测）：enforcing 下 `untrusted_app` 连 shell 建的
   abstract unix socket 直接 **EACCES**（`IOException(Permission denied)`；不是 ECONNREFUSED，所以
   不是"没人 listen"），而 **TCP 127.0.0.1:31339 可通**。⇒ agent 拿不到对端 uid，只能认 token；
   token 埋在 0644 的 base.apk 里，同机 app 拆得出来。防线因此**全压在"能力面窄"上**：
   动词只有 `STATUS/SAMPLE/DUMP/PUNCH/PUNCHLOG/LOG/QUIT`、命令行由 agent 自己拼、PUNCH 还要界面上先勾确认、
   agent 空闲自杀。反过来说：`su` 那条通道(`shim→sud` 的 `@vivosu`)是在 permissive 窗口里用的，
   不受这条限制，仍然能按真实 uid 判（窗口内 app 连 `@suwshd` 也确实通了，agent 打出 `OK unix uid=10284`）。
6. **控制面 = 提权面，必须两因子**（2026-09-29 真机实测后修正）。我最初写的是"控制面只让改白名单、
   能力严格小于 agent 通道"——**这句话是错的**：不在白名单里的 uid2000 只要拿到 APK 里的 token，
   `--ctrl add uid=2000` 把自己加进去，紧接着 `su -c id` 就是 `uid=0(root)`。能改白名单就等于提权。
   现在 `sud` 要求两件事同时成立：**token 对** 且 **调用方 uid 在 `/data/adb/su/su.ctrl`(0700 目录下
   的 0600 root 文件)里**；后者由 `su_layer_install.sh` 在装层时写入 manager 的 uid。
   uid 是内核给的、app 伪造不了，所以"拆到 token"和"冒充 manager"缺一不可。
   `su.ctrl` 不存在时退回"只认 token"，但会在审计里写明这条警告，不静默降级。
   另外控制面只在 root 窗口内可达（窗口外 untrusted_app 连 `@vivosu` 是 EACCES，见上面第 5 条）。

## 6. 构建与安装（本机非显然点，踩过）

- 无 gradle：`aapt2 link`（只有 manifest，无 res）→ `javac --release 8 -cp android.jar` →
  `d8 --release --lib android.jar --min-api 34` → python 把 `classes.dex` 塞回 apk →
  `zipalign -f 4` → `apksigner sign`（`suw.keystore` 自签）。
- **`resources.arsc` 必须 ZIP_STORED 且 4 字节对齐**，否则安装报
  `-124: Targeting R+ requires the resources.arsc ... stored uncompressed and aligned`。
- vivo 安装闸：`adb install` / `pm install` 都会 `INSTALL_FAILED_ABORTED: User rejected permissions`，
  必须**先勾「已了解应用的风险检测结果」再点「继续安装」**；且 `adb install` 必须活在**同一条命令**里
  （丢进 `( ... & )` 子壳会被工具调用结束时带走，日志变空，看着像"没弹窗"）。
- UI 取证只认 `screencap` 图：`uiautomator dump` 会把**多行 TextView 的 `text` 报成空串**（实测
  屏幕上明明有 `su 通道 : rc=-1 不可用…`，dump 里是 `text=""`）；而 PNG 只能用 `adb pull`/`exec-out`
  回读，`adb shell cat x.png > f` 会被 pty 做行转换而损坏。
- **点按钮前必须重新 dump 坐标**：状态 TextView 变长会把整排按钮往下推（实测同一按钮 y 从 1433 → 1997），
  复用旧坐标 = 点空。
- **`install2.sh` 已能把 vivo 闸全自动点掉**（读 `content-desc`、只在未 checked 时勾、一轮一动作后重 dump），
  所以"改代码 → 重装 → 取证"可以在一条无手工介入的循环里跑。
- 后台线程里没兜住的异常会**直接杀掉整个 app**（实测 `String.format("%x", Long.toHexString(x))` 抛
  `IllegalFormatConversionException` ⇒ 进程没了、屏幕只剩桌面、这一轮取证全丢）。`bg()` 现在 catch
  `Throwable` 并把异常显示到界面上。

## 7. 下一步（按性价比）

1. **PUNCH 上机**（②屏最后一环）：slide 这一环已经双向交叉验证过 —— 同一 boot，PC 端
   `analysis/slide_pc.py` 与 APK 端 `Slide.java` 各自吃**独立**的 25s 采样，都给出
   `SLIDE = 0x1c1ac00000`（正对照 16 / 27 命中，次名 0 ⇒ 唯一峰）。
   没证的是 `shd` 里那句 `victim shell post=su_layer_install.sh`：**`post=` 分支从未上过机**
   （真机验证过的节拍是 `victim ishell … kids`）。⇒ 打之前要么先用一条已知节拍把 `post=` 单独验掉，
   要么接受"这一发的判据只能看 `/data/local/tmp/su.audit` 与 `su` 是否出现"。
2. **UI 端到端截图取证**：`cm57/round9.sh`（已修：先唤醒解屏、改用 `adb pull`）——
   证明"在 app 上点按钮"这条路真的能改到策略（需要一次 root 窗口，可与 1 同一发）。
3. **N2**：非白名单 uid 走 `@vivosu` 被拒 —— 同样要 root 窗口里的 `asuid`。
4. **真 KernelSU**：本机外部 `.ko` 准入已实测开着（能加载也能卸载，无 LKM 白名单），
   CRC 表也能离线抽全（`analysis/Module.symvers_dev`，厂商 .ko 逐条验证 22/22、80/80、17/17）；
   缺的是 **Linux 侧构建环境**（本机无 WSL/docker/make）与 KSU 对 5.4 非 GKI 的移植可行性。
