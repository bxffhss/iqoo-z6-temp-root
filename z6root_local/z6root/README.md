# iQOO Z6 临时 root · 设备侧包（手机本地跑、无电脑无 adb）

> 目标机：iQOO Z6（V2220A / SM7325 / 5.4.281-qgki / Android 14 user）
> 环境：**Stellar / Shizuku 这类 App 提供的 shell（uid 2000）**。**全程不需要电脑、不需要 adb。**
> 本包 = **B8 核心流程（`run.sh` 开窗 → root/su/越狱模式）** + **LSPosed 加装层（`z6_lsposed_su.sh`，走 `su` 根腿）**。
> B8 核心的原始教程（`run.sh`+`b8_*` 原理/保活/诊断）已并入本 README 末尾**附录**。
> ★**LSPosed 推荐 su 版 `z6_lsposed_su.sh`**（最省心、不用守护）；`z6_lsposed.sh`（@sushd 版）**需先 `start_sushd.sh` 起守护**才稳。

## 准备
1. 整个 `z6root` 目录放到 `/sdcard/z6root`（别改名）。
2. 装 `KernelSU_manager.apk`（官方管理器）；`suw_manager.apk` 也要装（它是 root 腿 / `@sushd` 的宿主）。
3. 手机重启一次（**一次开机只够一次 punch**）。

## 用法

**① 开窗：拿 root + su + 越狱模式**（uid 2000 shell 里；一条命令）
```sh
sh /sdcard/z6root/run.sh
```
- `run.sh` 按序做：`b8_setup.sh`（现取 uid 铺名单：suw+官方Manager+目标app）→ 拷 `b8_*.sh` → `SU_BIND=1` 开 `z6root.sh`（punch+insmod+shd+绑 su）→ `b8_mgr`（管理器抢装重起）。
- 完成后：`/product/bin/su -c id` 出 `uid=0(root)`；管理器首页 `工作中[越狱模式]`；**suw 已进白名单 ⇒ `@sushd` 可用**。
- 自查三样（`run.sh` 末尾也会打）：`★KEEP_AUTO 已起` / 管理器 `工作中[越狱模式]` / `/product/bin/su` 存在。

**② 加装 LSPosed**（已开窗后。二选一，**推荐 su**）

**首选 · 走 su（最省心，不依赖守护）**：termux / 已授权终端里
```sh
su -c 'sh /sdcard/z6root/z6_lsposed_su.sh'
```
（PC/自动化代跑：`adb shell "run-as com.termux /product/bin/su -c 'sh /sdcard/z6root/z6_lsposed_su.sh'"`）

**或者 · @sushd 版**（没有 su/termux 时；装本包新 APK）：
```sh
sh /sdcard/z6root/z6_lsposed.sh
```
- 开窗的 punch 已**自动起 `@sushd` 守护**（`ksu_post.sh` 改成 `ksuctl88` + plain root，稳）⇒ 通常**一行就够**。
- 万一守护没在（`@suwksu` 空 / 派单假成功）：补 `su -c 'sh /sdcard/z6root/start_sushd.sh'` 再跑。

- 两版做的事一样：`w230`(建模块) → `w232`(前置闸) → `z6_launch` 起 `z6_stage4`(踢框架+注入+shd cgroup+抢装+维持件)；长的 `z6_stage4` 由 `z6_launch` `setsid` 脱离。
- 约 2–4 分钟后管理器回 `工作中[越狱模式]`；判活：`lspd` + `zn-zygisk-companion64` + `serial: []`。
- **已实测（干净窗）**：`serial=[]` + `lspd` + `zn-zygisk-companion64` + `mgr` + `keeper` 全绿、管理器 `工作中[越狱模式]`。
- ⚠ **务必干净窗**：先 `reboot` → `run.sh` → 本步；旧窗残留 zn-daemon 会让注入不成功。
- ⚠ **@sushd 版**：守护由**打窗自动起**（`ksu_post.sh` 已改成 `ksuctl88`+plain root）；万一没在，补 `start_sushd.sh`。包内新 APK 已加 3 次重试（实测 5/5）。**su 版则完全不用守护**，所以默认推荐它。

> **越狱模式掉了**（管理器被回收重开）：**不用重跑 z6_lsposed**——维持件（`b8_keep`）会自动重抢装，牌子自己回来（实测 2h 救了 7 次）；`serial` 桥也不随管理器重启丢。
> **要"重新注入"**（LSPosed 真失效 / zygote 整个重建），三条路按可靠度排：
>   1. **termux/终端里 `su -c 'sh /sdcard/z6root/z6_lsposed_su.sh'`** —— 走 `su`(shd)，**绕开 @sushd**，无长度限制、可重复，**最可靠**（`z6_lsposed_su.sh` 直接用 root 跑 w230→w232→z6_launch）。
>   2. `sh /sdcard/z6root/z6_lsposed.sh` —— 走 `@sushd`（suw 那只 app），**只在开窗后第一发可靠**；旧窗上 suw 被回收多了会退化（收到 intent 但假成功），别在旧窗重跑。
>   3. `reboot → run.sh → z6_lsposed.sh` —— 重置窗，最干净。
> 日志：`/data/local/tmp/z6_lsposed*.log`、`/data/local/tmp/z6_stage4.log`。

## 目录
```
run.sh           ★正确入口①：b8_setup → b8_* 拷入 → SU_BIND=1 开窗 → b8_mgr（开窗/越狱模式/suw白名单）
z6root.sh         实际开窗脚本（由 run.sh 以 SU_BIND=1 调；别单独裸跑，会漏前置）
b8_setup.sh / b8_mgr.sh / b8_keep.sh / b8_pin.sh / b8_su.sh / b8_verify.sh   B8 辅助（run.sh 用 + 手动诊断/保活）
z6_lsposed_su.sh ★② LSPosed 加装（**推荐**；root 直跑 w230/w232/z6_launch，走 su）
z6_lsposed.sh    @sushd 版（需先 start_sushd.sh 起守护；su 版更省心）
start_sushd.sh   @sushd 守护启动器（root 跑：ksuctl88 sushd changeme；给 AI 远程派单用）
KernelSU_manager.apk ★先装：官方管理器 v3.3.0（越狱模式 + 给 app 授权的入口）
suw_manager.apk  ★先装：suw app（root 腿/@sushd 宿主；"超级用户"页只读，授权走官方管理器）
kmod/            w230_rebuild_all / w232_zn_precheck / z6_stage4 / z6_launch / b8_keep / z6_lsposed
modules/         预置模块 zip（ZygiskNext 1.5.2 + LSPosed 2.2.0）
probe2.jar       lspd serial 桥打针用
w234_ksud_orig   设备原版 ksud（de059ed8，w230 补 ksud）
pr / perfips / shd / ksu_slide.awk / slide_solve.sh / slide_ctl.txt / ksu_post.sh ...  punch 与运行载荷
ksu_args.txt / ksu_stage.txt / kernelsu.ko   ko 与参数
MANIFEST         载荷清单（z6root.sh 逐条校 md5，缺/改一条就停）
README 附录        ★B8 核心原始教程（run.sh + b8_*）已并入本文件末尾
```

## 硬规矩
- **一次开机只够一次 punch**：本 boot 打过（`/proc/modules` 有 `kernelsu`）就**先重启**再跑。
- **临时 root 不持久**：`reboot` 即回出厂态；窗口别留过夜。
- **设备侧无 adb 观测/兜底**：空枪或卡住只能 `reboot` 重来；KSU 载入后别 `rmmod`、别重跑 punch。
- 授权：B8 名单已含 suw + 官方 Manager + 装上的目标 app；给别的 app 授权走官方管理器。
- LSPosed 管理器 APK 需另装（本包不含，用你现有的）。

## 免责
仅用于自有设备的研究性 root。exploit（GhostLock/CVE-2026-43499）有风险，出问题自负。

---

# 附录：B8 核心原始教程（原 教程.txt 原文，保留供查原理/保活/诊断）

iQOO Z6（V2220A / Android 14 user）免解 BL 临时 root —— B 线教程
（官方 Manager 当管理器 + 标准 root app 可用）

★这一版与旧版（rc78 + ksu_hook_mask=0x1a）**互不兼容**，本包**只有这一份教程**。
  旧版教程没有随包发：它依赖的内核 sucompat 改道在现形状里不存在，留着只会让人照错。
  要查当年的细节，去仓库 kmod/_tutorial_rc78_旧版留档_勿照做.txt（那份带警示头）。
  旧版必须废弃的原因：0x1a = execve 改道 + 可见性钩子（bit1+bit3+bit4），本机实测 ~19.5 秒固定引信硬复位
  （PMIC watchdog，非代码 bug、是聚合压力）。本版的参数是 ksu_hook_mask=0x0。

一、这一版的形状（一句话）
  名单在 insmod 那一刻写进内核（suw + 官方 Manager + 若干目标 app：Scene / NP管理器 / 黑域 / Termux），
  su 绑在 /product/bin/su，
  官方 Manager 因为"fd 与 su 都在它出生前就位"而正常显示【工作中 [越狱模式]】，并可给 app 授权。

二、准备
  1. 整个 z6root 目录拷到 /sdcard/（文件名保持原样，别改名）
  2. 装 KernelSU_manager.apk（官方管理器）；suw_manager.apk 保留（它是 root 腿）
  3. 手机重启一次（一次开机只够一次开窗）

三、开窗（一条命令）
  0) 前提：整个 z6root 目录在 /sdcard/z6root（别改名），两个 APK 已装，手机刚重启过。
  1) 跑：
       /system/bin/sh /sdcard/z6root/run.sh
     它按顺序做四件事（漏任一件都不会报错、只会静默降级，所以别再手工拆开）：
       ① b8_setup.sh  现取 uid 铺 ksu_two_profiles / ksa_uids.txt / ksu_keep_auto
       ② 把 b8_*.sh 拷进 /data/local/tmp（**必须在开窗之前**——stage 是在装载过程中去那儿拉补装的）
       ③ SU_BIND=1 开窗（不带 SU_BIND ⇒ su 不绑 ⇒ 管理器永远「获取 Root 失败」）
       ④ 等开窗完成后，用 b8_mgr 把管理器重起一次（先开抢装循环再 am start，
          让 fd 与 su 都赶在它出生之前；否则它会把 stage 那次「获取 Root 失败」缓存一辈子）
  2) 开窗过程中你会看到装载日志；**结束后**自查三样：
       · stage 日志里 ★KEEP_AUTO 已起：pid=[…]
       · 管理器首页 工作中 [越狱模式]
       · /product/bin/su 存在
     任何一条不对，先看第四节"三条硬读数"，别急着重开。
  ★为什么做不到"旧的版本那样彻底一条命令、什么都不用管"：
    旧版是 0x1a 形状，su 由内核 sucompat 改道、管理器靠那 30 秒抢装；新版是 0x0，
    必须靠"名单在装载前铺好 + su 绑成文件 + fd 在 App 出生前就位"这三件事按序发生。
    run.sh 就是把这三件的顺序固定下来，代价是它得知道你目录在哪（默认 /sdcard/z6root）。
  6) 把管理器钉住（防低内存回收，见第五节）：
       同上一条，把脚本名换成 b8_pin.sh

四、怎么确认成功（三条硬读数，缺一不算）
  1. 内核名单：派单 b8_verify.sh，看 /data/local/tmp/b8_verify.out
     期望：NEW_GET_ALLOW_LIST 的 count 与"开关里写的条数"一致，
           且脚本开头那行 `uid 列表(取自开关)` 里的**每一个** uid 都是 granted=1。
     ★不要死记 count=4：**没装的目标 app 不会进名单**（b8_setup 会打 `[!] 没装 ⇒ 不进名单：…`），
       正常窗口可能是 3~5 条。判据永远是"装了的都在、且都 granted=1"。
  2. 真出 root：派单 b8_su.sh，看 /data/local/tmp/b8_su.out
     期望：每个 uid 后面是 uid=0(root) gid=0(root) groups=0(root)
  3. 官方 App：首页【工作中 [越狱模式]】＋四个页签＋『超级用户』角标 4，且没有【获取 Root 失败】
  ★别用 adb shell 直接跑 ksuctl88 granted —— 它的权限是 manager_or_root，shell(uid=2000) 发必然
    rc=-1 EPERM granted=0，那不是名单读数，是"调用者无权"。

五、怎么让它一直亮（不重启手机）
  ★先说结论：**不能保证永远**。牌子存在与否＝管理器进程里有没有那个驱动 fd。
    · 进程活着 ⇒ 一直是【工作中】。实测连续十几分钟不动它就一直亮。
    · 进程一换（低内存回收 / 从最近任务划掉 / 崩溃 / 框架重启）时，**取决于当时有没有"补装者"在场**：
        － 没有任何补装者在跑 ⇒ 一定回【不支持】，而且不会自愈（启动时一次性查询）。
          这就是旧教程"不带这条腿只重开管理器 ⇒ 一定退回不支持"的那两格反向实测。
        － 有补装者在跑（stage 的 RACE 30 秒窗 / b8_keep.sh / w625_seedrestart.sh）⇒ 重开**大概率仍是【工作中】**，
          因为它在 0.1~0.2 秒节拍上盯着 pid，一变就写触发口。B9 实测：force-stop 后重开，**第 1 轮就命中**。
          ★但这是**竞态**不是保证：抢在 App 首次查询之前就亮，晚一步就仍是【不支持】（同一发里另一轮就输过）。
      · 两种情况都记住：/product/bin/su -c id 照样出 uid=0(root) —— root 没坏，暗的只是那屏。
  提高稳定性的三件（都在包里）：
    1. b8_pin.sh   把管理器 oom_score_adj 钉到 -1000 ⇒ 低内存杀手不再回收它。
                   ★只挡 LMK，**挡不住你从最近任务划掉**（那是 force-stop）。
                   ★★实测会失效：23:16 读回是 -1000，23:17 再读已经是 700（被系统/厂商服务改回去了）
                     ⇒ 它只能算"缓解"，别当成保证；真被回收了就靠 b8_keep.sh 补 fd。
    2. b8_keep.sh  常驻循环：每 0.2 秒看一次 pid，pid 一变就补 fd。
                   ★它是"抢"，不是"保证"——抢在 App 启动检查之前就成功，晚了就仍是【不支持】。
    3. **w625_seedrestart.sh**  掉回【不支持】后的恢复腿（**首选，从 root 壳里跑**）：
         /product/bin/su -c /data/local/tmp/w625_seedrestart.sh
       它做 force-stop → 以 0.1 秒节拍盯新 pid → 立刻写触发口 → 最多 6 轮；判据看它打的
         SR-ROUND r=1 pid=<新pid> fd=1
       三道闸都在（凭据 /data/local/tmp/w625_lock）：
         SR-ALREADY＝现在这个实例就是上次种过 fd 的、什么都没做（**亮着就别再敲**）；
         SR-COOL   ＝距上次重启管理器不足 150 秒，本次不 force-stop（等它报的剩余秒数）；
         SR-BUDGET ＝本 boot 已重启管理器 6 次，不再动进程。
       ★★为什么必须有闸：这条腿每次调用最坏 fork≈90 次，而牌子只亮约 30 秒、比人的反应快
         ⇒ 看见暗了就反复敲 = 越敲越密 = fork 风暴（历史上一手事故：PS_HOLD 硬复位）。
    4. b8_mgr.sh   同上功能，但**没有闸**——只适合在窗口里快速迭代用；日常请用 w625。
  ⇒ 日常用法：**别划掉 KernelSU 的后台任务**；万一暗了，跑一次 w625_seedrestart.sh，被 SR-COOL 拒就等它报的秒数。

六、不要用软重启（stop/start、restart zygote）来"救"或"收窗"
  1. 它救不了牌子：软重启会杀掉包括管理器在内的所有 app ⇒ fd 全丢、root 腿（suw）也死，
     之后还得重起两个东西，比直接跑 b8_mgr.sh 更贵。
  2. 它更收不了窗：软重启不卸载 ko、不把 SELinux 拉回 Enforcing，窗口照旧开着，
     却把唯一能补 fd / 能读名单的 root 腿弄没了 ⇒ 变成"半死窗口"，比现在更糟。
  收窗只有一条路：先跑 w450_close.sh，再 **reboot**（见第七节）。

七、收窗（必做，窗口不留过夜）
  · 先跑收尾件（root 腿）：w450_close.sh，读数在 /sdcard/w450_close.txt
  · 再 reboot
  · boot 后复核：mod=0、Enforcing、/product/bin/su 不存在 —— 三条都对才算回到出厂态
  ★收窗后务必删 /data/local/tmp/ksu_two_profiles：
       adb shell rm -f /data/local/tmp/ksu_two_profiles
     它是"换形状"的开关，留着会让下一次开窗静悄悄换掉名单。

八、已知边界（不是坏了）
  · 只有 /product/bin/su 这一条 su 路径；/system/bin/su、/system/xbin/su、/sbin/su 都不存在。
    有些文件管理器会按固定路径探 su，探不到就只给"半 root"（NP管理器就是这一类）；
    它的 root 权限本身是够的（实测 uid=10475 能读 /data/adb、/data/data、/data/system）。
  · 窗口内 SELinux=Permissive，reboot 自动回 Enforcing。
  · 管理器的「管理器版本(32601) 与驱动版本(32653) 不匹配」只是版本号横幅，不影响功能。

九、管理器的 UI 会卡（长期存在的现象，不是这一版引入的）
  · 表现：切窗口、在搜索框里搜包名、退出再进，界面会卡住一会；**卡完能自己恢复**。
  · 所以：**不要依赖 UI 去授权**。搜索框那条路（ui_grant 走的就是它）正好踩在最容易卡的操作上。
    本版的授权是"名单在 insmod 那一刻就写死"，不需要点任何开关——这是它比走 UI 稳的地方。
  · 想把它查实（需要在窗口里、要 root），卡住的当口抓三样：
       adb shell "kill -3 $(pidof me.weishu.kernelsu)"      # 抓 Java 线程栈 -> /data/anr/
       adb shell "ls /proc/$(pidof me.weishu.kernelsu)/fd | wc -l"   # fd 数量（看有没有涨）
       adb logcat -d | grep -aiE "ANR in me.weishu|KsuCli"  # 看是不是主线程被 su/ksud 调用拖住
    目前只是"待查"，没有任何结论；别把"卡"归因到 ko 头上，也别说它不影响功能以外的事。

铁律：不要 rmmod；同一次开机只开一次窗；要重来先重启；窗口不收过夜；别用软重启代替收窗；恢复腿被闸拒不是坏。

---

## 更新：@sushd flaky 已修（suw APK 重编）
- 包内 `suw_manager.apk` 已换成**修好的版本**：`suwksu_jni.c` 的 `run_via_sushd` 加了 **3 次重试 + 真状态回报**（去掉盲 `status=0`），实测**稳态 5/5**。
- 新增 `start_sushd.sh`：以 root 起 `@suwksu` 守护（`ksuctl88 sushd changeme`）。
- ★**@sushd 要用，得先起守护**：开窗、root 可用后跑一次 `su -c 'sh /sdcard/z6root/start_sushd.sh'`；之后 AI/自动化 `am start ... --es cmd '@sushd:<脚本>'` 就稳了。
- 手用/重注入仍推荐 **su 版 `z6_lsposed_su.sh`**（不依赖 @sushd，最省心）。

## suw_manager.apk（suw app）说明
- **它是干什么的**：① **root 腿**——`@sushd` 通道的宿主（AI/自动化 `am start ... --es cmd '@sushd:<脚本>'` 借它拿 root）；② 开窗名单会给它 uid（10342）授权。
- **它的"超级用户"页别用来授权**：实测它调内核 `SETPROF/LIST` → **EPERM**（被加冕的 manager 是官方 `me.weishu.kernelsu`，不是它）；"认不出真包名"是它的拒写保护。
  ⇒ **给 app 授权一律用官方管理器的"超级用户"页**。
- **它的"本 boot 已发过 PUNCH"**：是**它自己那个"打链(PUNCH)"按钮**的状态，**不是**读我们 `run.sh` 的 punch —— 别拿它判断窗口。
- **要用 @sushd（AI 远程派单）**：装本包 APK → 开窗 → `su -c 'sh /sdcard/z6root/start_sushd.sh'` 起守护 → 之后 `@sushd:` 单发才稳（包内 APK 已加 3 次重试，实测 5/5）。
