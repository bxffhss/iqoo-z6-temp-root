# iQOO Z6 临时 root 工具包 v2（go.sh 流程）

> 目标机：iQOO Z6（V2220A / SM7325 / `5.4.281-qgki` / Android 14 user）
> 做的事：**临时 root + KernelSU + su + 管理器「工作中[越狱模式]」[+ LSPosed]**
> 原理：GhostLock(CVE-2026-43499) 开窗 → insmod 自编外部 KSU ko → shd 根代理 + 管理器抢装装 fd。

> ⚠ **这是临时窗口**：收窗/重启后 ko 卸载、窗口消失，需要重开。**机器是量产机，窗口别留过夜。**

---

## 前置
- Windows（Git Bash / MSYS 环境），`bash` 可用
- `adb` 可用、设备已连并授权 USB 调试（`adb devices` 能看到设备）
- 一次开机一枪；punch 偶发空枪（重跑即可）

## 用法

```bash
bash kmod/z6_on.sh               # 完整档：开窗 + 装预置模块(ZN+LSPosed) + 注入 + shd + 主动抢装 + 维持件
                                 #   ⇒ LSPosed + su + 越狱模式
bash kmod/z6_on.sh --no-modules  # 轻量档：开窗 + shd + 主动抢装 + 维持件（不装模块/不踢框架，最稳）
                                 #   ⇒ su + 越狱模式（无 LSPosed）
bash kmod/z6_off.sh              # 收窗（干净回出厂：停维持件 → reboot → 复核 mod=0/Enforcing）
```

- 跑完看管理器：`工作中 [越狱模式]` 即成功（版本 32653-2）。截图：`adb shell screencap -p /sdcard/a.png && adb pull /sdcard/a.png`。
- su：给 App 授权走管理器「超级用户」页（角标＝已授权数）；被授权 App 里 `su` 即 `uid=0`。
- 软重启类（需 root 腿 @sushd 活着、即踢框架前）：`z6_soft.sh` 软重启、`z6_after.sh` 软重启后补。

## 目录结构

```
kmod/       核心脚本
  go.sh              开窗（punch + insmod + 起步）        ← z6_on.sh 调用
  push_ksu.sh        推 ko/args/ksud
  z6_stage4.sh       阶段总控（踢框架 + 注入 + shd + 主动抢装 + 维持件）
  z6_launch.sh       拉起 z6_stage4（经 @sushd 脱离）
  z6_light.sh        轻量总控（shd + 主动抢装 + 维持件，不踢框架）
  w230_rebuild_all.sh  严格白名单重建 ZN+LSPosed 模块 + 补设备原版 ksud
  w232_zn_precheck.sh  ZN 前置闸（ZGATE=PASS + root_status:✅）
  b8_keep.sh         管理器 fd 维持件（管理器重开自动重抢装）
  b8_mgr.sh          单次主动抢装（手动用）
  w161_teardown.sh   收窗（优雅）
  z6_on.sh/z6_off.sh/z6_soft.sh/z6_after.sh   四支入口
  kernelsu_rc80.ko   自编 KSU 外部 LKM（md5 98bf4052…）
  ksu_args.txt       insmod 参数（md5 fec3d301…）
cm57/       设备侧二进制：ksuctl/ksuctl88/ksud_shim/susm/sustatic/sustatic_v4/suwbind/prbin/perfips/asuidbin/su_layer_install.sh
suw_apk/    punch 工具链：bootstrap.sh + sudbin + shdbin
analysis/   slide 解算：slide_pc.py + slide_cache/
apks/       KernelSU 管理器 v3.3.0（有「超级用户/模块」页签；推荐用它）
modules/    预置模块 zip：ZygiskNext 1.5.2 + LSPosed 2.2.0（z6_on.sh 会自动推到设备 /sdcard/Download/必备模块/）
```

## 重要提醒
- **可移植**：`ADB`/`PY` 默认走 `PATH`，设备自动探测（`adb devices` 里第一个在线设备）。特殊环境用环境变量覆盖：`ADB=/path/to/adb PY=/path/to/python DEV=<序列号> bash kmod/z6_on.sh`。`analysis/slide_pc.py` 只用 Python 标准库，任意 `python3` 即可。
- **一般不用预设任何路径**：手机上是安卓标准路径（`/sdcard`、`/data/...`），PC 上 adb/python 走 PATH。唯一可能想预设的是「同时插多台设备、指定哪台」→ `cp config.example.sh config.sh` 并取消 `export DEV=<序列号>` 那行注释即可。
- **punch 有不确定性**：偶发空枪（`Permissive` 没翻、`pr` 没起）→ 重跑 `z6_on.sh`。连发多次仍空枪，停手查环境（USB/供电/内核态），别硬刷。
- **版本红字**「管理器 32601 与驱动 32653 不匹配」**纯提示**，不影响越狱模式/su/LSPosed。别为它重编 ko（`KSU_VERSION_OVERRIDE` 是谎报，重编还有碰 rc80 的风险）。
- LSPosed 模块在管理器里显「0 个进程」是正常口径（Zygisk 模块不经 KSU 记账）；判活看 `lspd` + `zn-zygisk-companion64` + `serial: []`。
- 全套细节与踩坑见 `kmod/w103_evidence/LSPOSED_INJECT_RUNBOOK.md`（如随包附带）。

## 免责
仅用于自有设备的研究性 root。刷机/内核操作有风险，出问题自负。
