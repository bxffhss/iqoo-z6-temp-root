# SU 白名单管理器（`suw.apk` / `com.suw.manager`）—— 使用说明与经验总结

这台机器的现状：iQOO Z6（V2220A / PD2220，SM7325，Android 14 **user** 版，BL 绿锁，
`ro.oem_unlock_allowed=0`，内核 `5.4.281-qgki-g2a88cd145def`）。能拿到的是
**GhostLock（rtmutex 栈 UAF）打出来的"本 boot 一次性"内核 root**，用完重启就没了。

这个 app **不含任何提权逻辑**。它只做两件事：① 用 TCP 让 shell 侧 agent 代它采样/解 slide/发打链命令；
② 用控制面（或退回 `su`）读写那份 root 侧白名单。所以"app 能不能用它"和"这个 boot 有没有 root 窗口"
是同一件事 —— 界面上必须分开显示（su 通道 rc / 策略内容 / 审计尾部），不能给一个笼统绿灯。

目录里已有的详细设计：`DESIGN.md`（架构、SELinux 实测、控制面为什么是提权面）。本文件是**操作面**：
怎么用、什么算成功、踩过什么。

---

## 1. 组成：哪些在 APK 里，哪些必须在设备上

`bash suw_apk/build.sh` 一条命令产出全部（本机没有 gradle，也不需要）：
`aapt2 link` → `javac --release 8` → `d8` → python 把 `classes.dex` 塞回 apk（`resources.arsc`
必须 ZIP_STORED + 4 字节对齐）→ `zipalign` → `apksigner` → NDK clang 编 `shdbin`/`sudbin`。

| 东西 | 在哪 | 作用 | 来源 |
|---|---|---|---|
| UI 全部四页 | **APK 内**（classes.dex） | 首页/超级用户/激活/设置 | `src/com/suw/manager/MainActivity.java` |
| slide 求解器 | **APK 内** | 与 PC 端等价，已交叉验证同一 boot 同值 | `Slide.java` + `SlideTable.java`（`gen_slide_table.py` 从裸 Image 生成常量表） |
| 两个 token | **APK 内** | agent 的 TCP 口令 + daemon 控制面口令 | `build.sh` 生成 `Cfg.java`，与 `-DSUW_TOKEN`/`-DSUW_CTRL_TOKEN` 同源 |
| `shd` | `/data/local/tmp` | **shell 域(uid 2000)代理**：采样、代打链、unix 白名单 | `suw_apk/shd.c` → `shdbin` |
| `sudbin` | `/data/local/tmp` + tmpfs 盖成 `/product/bin/su` | root 侧 daemon + `su` shim（方言/pty/策略/审计/控制面） | `cm57/sud.c` |
| `pr` | `/data/local/tmp` | 打链本体（GhostLock 用户态 payload） | `cm57/pr.c` |
| `perfips` | `/data/local/tmp` | perf 自采样器（shd 调它拿内核 IP） | **只有设备一份**，2026-09-30 才 `pull` 回 `cm57/perfips`；源码是 `cm54/slide.c` |

**本地↔设备文件名不一致的三个**（`bootstrap.sh` 里已显式映射，别按同名找）：
`shd ← suw_apk/shdbin`、`asuid ← cm57/asuidbin`、`pr ← cm57/prbin`。
2026-09-30 才发现这个洞：`round9_cleanup.sh` 会 `rm` 掉 `pr/sudbin/asuid`，而 bootstrap 用
`cm57/pr`、`cm57/asuid` 这种**不存在的同名路径**去找补丁 —— 平时没暴露是因为设备上的旧副本一直没被删干净；
一旦某轮真删了，bootstrap 会直接报"本地没有 cm57/pr"退出。同一天 `perfips` 也差点是同样处境
（它连本地副本都没有）。⇒ **规则：每台设备的独有产物都要在仓库里有一份，push 路径要用显式映射而不是同名拼接。**
| `asuid` | `/data/local/tmp` | 以指定 uid 跑命令，用来证"授权前 126 / 授权后 0" | `cm57/asuid.c` → `asuidbin` |
| `su_layer_install.sh` | `/data/local/tmp` | `pr` 的 `post=` 自动装层脚本 | `cm57/` |
| `bootstrap.sh` | **只在 PC** | 开机后一条命令把上面这些铺好 + 起 shd + 解 slide | `suw_apk/` |
| `su.audit` / `punch.log` / `shd.log` / `sud.log` | `/data/local/tmp` | 证据；审计是 root 0600，只有 su 可用时 manager 才读得到 | 设备侧写 |

**push 的硬规矩**（Git Bash 会重写以 `/` 开头的远端路径并**谎报成功**）：
每条都写 `MSYS2_ARG_CONV_EXCL='*' adb push …`，**推完两侧 `md5sum` 对齐**再 `chmod 755`；
只看 `ls -l` 会被"旧文件还在"骗过去。

---

## 2. 用法：一轮的完整顺序

```bash
# ① 开机后（唯一需要电脑的一步）
bash suw_apk/bootstrap.sh
#   等 boot_completed → 等 load1<6(等不到直接退出) → 只补缺失/过期的 payload(比 md5)
#   → 按 pidof 停旧 shd 再以 uid2000 起 → 采 25s → slide_pc.py 解 slide
#   → 按 boot_id 缓存到 analysis/slide_cache/<boot_id>.txt（复用前验 uname -s 仍是 Linux）
#   无线：DEV=<ip>:<port> bash suw_apk/bootstrap.sh    连打链：I_KNOW=1 bash suw_apk/bootstrap.sh --punch

# ② 如果要验新界面 —— 必须在打链【之前】装
bash suw_apk/install2.sh          # 会自动点掉 vivo 安装闸；重启后先 dismiss VivoUsbDialog

# ③ 手机上：激活页 ①自检 → ②采样+解slide → ③打链（勾确认才亮）
#    打链后自动跑 post=su_layer_install.sh，界面每 5s 拉 punch.log 直到出现 RC=
#    从一发到自己落地 root ≈ 6 分钟；punch.log 会因块缓冲长时间不动，不代表失败

# ④ 超级用户页：给目标 app 打开 Switch（热生效，daemon 每个请求重读策略）

# ⑤ 用完收尾（趁 root 还活着！）
bash cm57/round9_cleanup.sh       # 第一步就是 su -c "rm -rf /data/adb/su"，删不掉会打 !! 报警
adb reboot                        # 回 enforcing
```

**为什么收尾必须先删 `/data/adb/su`**：permissive、tmpfs 盖的 `/product/bin/su`、daemon 都随重启消失，
只有 `su.policy`/`su.ctrl` 落在真 `/data` 上（0700 root），重启后 shell 连 `stat` 都 EACCES ⇒
看不见也删不掉。忘了删不是安全风险（没有 daemon 和二进制，文件是死的），是**留痕**，与"不留持久化"冲突。

---

## 3. 界面与判据怎么读

- 右上角 chip：`已激活`(su rc=0) / `已装未授权`(rc=126) / `未激活`(rc=127/-1)。
- 首页三判据逐行带色点：`getenforce` / su 通道 / 策略读取。策略读取那行会写明**走的是哪条通道**
  （`(ctrl)` = 控制面两因子，`(su)` = 退回 su，`none` = 两条都不通）。
- **`rc=126` 是被白名单拒，`rc=127/-1` 是 daemon 或 su 不在** —— 混起来看就会把"这个 boot 窗口没了"
  读成"我没点授权"。
- 超级用户页副标题 = `包名 · uid=N` + **该 uid 最近一次请求**：
  `允许 su ← com.baiye.h3dpatcher · 3 分钟前 (02:19)`。
  - **必须带发起进程**：一个 uid 背后是几十个包（本机 uid=10667 摊了三十多个），只写 uid 会把别的包的
    历史读成这一行的（真机就这么误判过 MT）。
  - 允许/拒绝各留最近一条，一次授权不会被更早的拒绝盖掉。
  - 时间用**相对值为主 + 括号 HH:mm**，不用日期：审计每次激活都重建，日期是常数噪声
    （设备墙钟实测与 PC 差 1 秒，所以 HH:mm 可信）。
  - `（早于最近一次改策略，可能是旧记录）` = 它比最后一次 `CTRL op=add|del|reset` 更老。
  - 认不出发起包时**照实写** `sh(看不到发起包)`，绝不猜。
- 共享 uid 的行会标 `XX 等 36 个应用`：**授权粒度只能到 uid**，这不是缺陷 —— 拆到包名更弱
  （`comm`/`cmdline` 是进程自己可改的，不是内核身份）。Magisk/KernelSU 也是按 uid。
- 设置页 = 审计原文（要 su 可用才读得到）。
- 只想看"能不能用"时，最快的判据是**首页 `调用方 uid=0(root) … context=u:r:kernel:s0`**，
  而不是界面自己说"已激活"。

不装 APK 也能验审计解析逻辑：
```bash
adb exec-out "su -c 'tail -n 300 /data/local/tmp/su.audit'" > suw_apk/tools/audit.txt
adb shell "cut -d' ' -f1 /proc/uptime" | tr -d '\r' | sed 's/^/UP=/' >> suw_apk/tools/audit.txt
javac -encoding UTF-8 --release 8 -d suw_apk/tools suw_apk/tools/ReqParseTest.java
java -Dfile.encoding=UTF-8 -cp suw_apk/tools ReqParseTest suw_apk/tools/audit.txt
```

---

## 4. 成功过的（都是一手证据，不是"应该可以"）

| 事项 | 证据 |
|---|---|
| GhostLock 真机复现 **11 次**，第 10/11 次全程由这个 APK 驱动（slide + PUNCH + `post=` 自动装层） | `evidence_0929_punch/`、`punch.log RC=0` + `LAYER_READY` |
| slide 求值**跨实现交叉验证**（同一 boot：PC `slide_pc.py` 与 APK 内 Java 解出同一个值） | `1c1ac00000`，两侧都是唯一峰 |
| slide **每 boot 都不同** ⇒ 缓存只按 `boot_id` 复用 | `1c1ac00000/2f04e00000/1289000000/2416000000/1443800000/1c32a00000` |
| 白名单授权点端到端（真 app 拿到 root、撤销立即生效、只给一个 uid 时邻近 uid 仍被拒） | `cm57/round6_*_test.keep.log`（T1–T8 全表） |
| **控制面 CTRL 两因子**（token + `su.ctrl` 里的 uid）；负向对照：uid2000 带**正确 token** 仍被拒 | `c_*.png` + 审计 `CTRL-DENY` |
| **自锁解药**：把自己关掉 → 再开回来，全程不碰电脑以外的东西 | 首页 `调用方 uid=0(root)` 是真的重新拿到 root |
| su 方言兼容（`su -v`/`-V`/`0 id`/`--mount-master`）与 **pty**（裸 `su` 给交互 shell） | 修前 `sh: -c: requires an argument`，修后 `PD2220:/data/local/tmp #` |
| `bootstrap.sh` 实跑两次：首跑解出并缓存，二跑 0 秒复用 | 终端输出 + `analysis/slide_cache/` |
| daemon 热换不碰窗口（`mv` 换路径 + 按 pid kill） | 新审计行 `gparent=[6735:adbd//apex/.../adbd …]` |

---

## 5. 失败与坑（每一条都付过学费）

**构建/安装**
1. `resources.arsc` 被 python 顺手 `ZIP_DEFLATED` ⇒ 安装报 `-124`。必须 STORED + 4 字节对齐。
2. vivo 安装闸的按钮文案在 **content-desc**（`text` 是空的）；复选框可能已经 `checked="true"`，
   再点等于取消 ⇒ 先读 `checked`。
3. **重启后第一次安装被 `VivoUsbDialog` 挡**：它抢焦点，脚本对着上一个窗口的旧坐标连点 40 轮空转
   （现象 = 轮数跑满、`install_out.log` 是 0 字节）。装之前先 dump 一次。
4. **打链之后装不了任何 APK**：`uname -s` 被写成 `Linu\x01` ⇒ `artd` 断言
   `strcmp(uts.sysname,"Linux")==0` SIGABRT 循环 ⇒ `adb install` 永不返回、`lastUpdateTime` 不动。
   ⇒ **要验新界面必须先重启**（顺带回 enforcing）。这也意味着"先装 APK 再打链"是**唯一可行顺序**。
5. `adb install` 进程必须活在同一条命令里：丢进 `( … & )` 子壳会被工具调用结束时带走，
   日志变空，看着像"没弹窗"。

**判据与自伤**
6. **`pkill -f` 的模式会匹配到执行它的 shell 自己 / 匹配到监督循环**：
   `pkill -f "/data/local/tmp/sudbin --daemon"` 把 `while :; do …` 一起杀掉 ⇒ daemon 有"必须 uid0 起"的闸，
   `su` 又依赖 daemon ⇒ **窗口自锁，只能重启**。⇒ 一律 `pidof` + 按 pid kill；清理和杀进程不写在同一条命令里。
7. **`_exit()` 不 flush stdio**：`--ctrl show` 一个字节都不回，**但策略其实已经改到了**。
   子进程里必须先 `fflush(stdout)` 再 `_exit(rc)`。（同一族第二次踩的是 punch.log 块缓冲。）
8. **嵌套 `su -c "... su -c id"` 是假绿**：内层 su 以 root 跑 ⇒ 拿"仍被授权"的结论是伪证，撤销要回干净 shell 复测。
9. 共享 uid 的误读（第 3 节那条）：`最近请求: 拒绝 uid=10667` 其实是同 uid 的另一个包的历史。
10. `-O2` 会把 CTRL token 常量折叠 ⇒ "token 有没有编进 sudbin"的自检假阴性。改成
    `static const char[]` + `volatile` 指针读，自检才有效。
11. **覆盖正在执行的 ELF 会 `ETXTBSY`**（`cp` 失败）⇒ 用 `mv -f`（同盘 rename 换路径不换 inode），
    且**先 `chmod 755`**（push 落地是 0664 无执行位，直接 mv 上去监督循环就 exec 不动 = 自锁）。
12. `uiautomator dump` 会把**多行 TextView 的 `text` 报成空串**，还会 `Aborted` 并**留下上一份旧文件**
    ⇒ 判渲染只认 `screencap`；dump 只用来拿按钮坐标，且**每次 tap 前重取**（TextView 变高会整体位移）。
13. `String.format("%x", Long.toHexString(x))` 抛异常且它在子线程里 ⇒ **整个 app 被杀**，取证全丢。
    `bg()` 现在兜 `Throwable` 并显示。
14. `"$PY" - <<'PY'` 的 heredoc 占了 stdin ⇒ 脚本里 `sys.stdin.read()` 拿到空 ⇒ 坐标为空、tap 空转。
    先落文件按 argv 传。
15. 本机 `adb push/pull/shell` 的路径重写 + 谎报成功（见第 1 节规矩）；`adb shell 'cat > 远端' < 二进制`
    会被 pty 改写坏掉（**只有纯文本可以这么传**）。

**兼容层缺口（已知、未修）**
- Termux 裸 `su` 说"没有 su"：它的 PATH 不含 `/product/bin`（可以用 root 写它的 `.bashrc` 解决）。
- Shizuku 的 root 模式只认 **Magisk 接口**，不吃我们的 `su` ⇒ 给了白名单仍"看不到 root"，这不是 su 能修的。
- `sud` 的连接处理器 fork 不回收 ⇒ 遗留一堆 `(deleted)` 的旧进程（只持有各自已建立的连接，不 accept 新连接）。

---

## 6. ★"依赖文件要不要放进 APK？只装 APK 能不能就临时 root？"

**结论：不能。** APK 里现在**没有** `assets/` 和 `lib/`（条目只有
`AndroidManifest.xml / resources.arsc / classes.dex / META-INF/*`），而且**故意不放**。
把 payload 塞进 APK 只能省掉"push"这一步，省不掉"每次开机要有一次 shell 域的介入"——
后者才是本质门槛，三条都是一手实测：

1. **求 slide 必须以 uid 2000 起。** 正对照靠 perf 自采样（`PERF_TYPE_SOFTWARE/CPU_CLOCK` +
   `exclude_user=1` + `PERF_SAMPLE_IP`），而 app 域这个 attr 直接 **EACCES**
   （`analysis/CFI-SAMETYPE-TABLES-20260926.md`：`paranoid=-1` 也拦不住 SELinux）。
   没有 slide 就不能打链 —— KASLR 猜不得。
   注意：**slide 的计算本身已经在 APK 里了**（`Slide.java`/`SlideTable.java`，与 PC 端解出同值）；
   卡在 APK 外的是**采样**那个动作。
2. **enforcing 下 app 连不到 shell 域的 abstract unix socket**（EACCES，且这条 denial 被 dontaudit 吞了，
   logcat 搜不到）⇒ app↔agent 只能 TCP + token。可是 **`shd` 这个进程总得有人以 shell 身份起来**，
   而 APK 没有 `BOOT_COMPLETED` 接收者（manifest 只有 `QUERY_ALL_PACKAGES` + `INTERNET`）。
3. **顺序反过来**：装 APK 必须排在打链之前（第 5 节第 4 条）。所以"先有一个 APK，其它都自举"这条路
   在时间轴上就不成立。

如果非打包不可（技术上能做的）：
- `assets/` 解到 `/data/data/com.suw.manager/files/` 再执行 —— **app 能否 exec 自己 data 目录里的文件，
  本机没测过**（这是 Android 10+ W^X 的范围，untrusted_app 通常被拒；要做得先写一个 execve 探针）。
  即使能 exec，跑起来还是 app 的 uid ⇒ 第 1 条的 EACCES 一字不改。
- 编成 `lib/arm64-v8a/libshd.so` 用 `System.load` 在 app 进程内跑 —— 同样卡在 uid，而且把提权二进制
  和"我在管 root"的界面装进同一个包，是本机上**最容易被检测**的形态（当前形态只有 `/data/local/tmp`
  的文件 + 一个挂载点，见 `DESIGN.md` 的"合并的代价"）。

**所以真正的分界是**：per-boot 一次 adb（现在就一条 `bash suw_apk/bootstrap.sh`）属于设计的一部分，
不是缺憾。要彻底脱离电脑，只有"常驻内核代码"这条路（外部 `.ko` 或刷 boot），
前者见 [[kernel-module-loading-gate]]（本 boot 内可激活，跨重启仍不行），后者本机是死门（绿锁 + verity enforcing）。

---

## 7. 已知未做

- **KernelSU / 外部 .ko 这条线已经立项并实测通过三道门**（自研 .ko 能装、能被内核回调、能用
  kprobe 捞非导出符号地址）⇒ 全部配方与判据链在 **`kmod/PLAN.md`**，本文件不再重复。
  它相对本 su 层的唯一硬收益是"**能把 `setenforce 1` 关回去**"，不是"授权更好用"。
- 打链前预编译（`PREP`）以缓解 artd 侧的可用性缺口 —— 已评估、暂缓。
- 相0 落点从 `sysname` 挪到 `nodename` 的**重排**：`TG_OFF=0x50` 那一版已判定不是改一个常数的事
  （窗口内所有假锁是 S 相对的，挪 T 会带动 S ⇒ 要重做整套相表），当前仍是 `0x08`。
- Termux PATH、`sud` 连接处理器回收、MT/NP"自定义 su 路径"握手。
- 图标（用户判过：影响极小，不管）。
