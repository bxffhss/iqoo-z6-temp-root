# AGENTS.md — 项目说明与操作纪律

项目：iQOO Z6 (V2220A / PD2220, SM7325, `5.4.281-qgki-g2a88cd145def`, Android 14 **user**)
上跑我们自己编的 KernelSU 外部 `.ko`，用**未修改的官方 KernelSU Manager v3.3.0** 授权，
交付形态是设备包 `z6root/`。**临时 root：reboot 即还原，不改系统分区、不解锁 BootLoader。**

## 1. 从哪看起

1. `README.md` — 项目概览、核心结论、免责
2. `kmod/ROUTE-B-OFFSET-INVERSION.md` — 一手账本：每一发的读数、判据、出处
3. `kmod/DELIVERY.md` — 交付口径与已知限制

> `analysis/` 下与各 `HANDOFF-*.md` 是不同阶段的历史快照/分析记录，按文件头日期阅读。

## 2. 目录地图

| 路径 | 内容 |
|---|---|
| `z6root/` | 设备侧交付包（脚本层） |
| `z6root_local/`、`z6root_v2/` | 交付包的整合版 / 结构化配置版 |
| `kmod/` | 研究脚本、探针、账本（`w*.sh` / `w*.py` / `*.c`） |
| `analysis/` | 逆向分析记录（Binder / KGSL / CFI / SELinux 等） |
| `cm57/` | ksuctl / su 工具链源码 |
| `suw_apk/` | SU 白名单管理器（Java + JNI + 构建脚本） |
| `cheese/` | KGSL 相关探测源码 |

## 3. 操作纪律（研究实践中总结的）

- **一次开机只发一枪**；打靶要显式确认，不许拿历史授权当本次授权。
- **关窗铁律**：恢复 SELinux 执法排在所有 root 腿之后；依赖 `/proc/ksu_*`、`dmesg`、
  `/data/adb`、fd 安装的腿全部排在前面。翻了执法态就回不去。
- **活窗口里绝不**：`rmmod` 出货 ko、跑 `ksud post-fs-data`/`late-load`/`bootstrap`。
  窗口不留过夜。
- **不可逆 / 影响生产的操作**：停下来确认，并给出只读的替代路径。
- 判据纪律：执行类判据要**多判据 + 正对照**；"应为 0/为空"的判据必须配一条会非 0 的
  形状；期望表是模型不是证人；**"没有那一行"不等于"失败了"**，失败路径自己要把回执打出来。

## 4. 构建与使用

- **ko**：需要匹配的 `5.4.281-qgki` 内核树 + clang/LLVM（`CONFIG_KSU=m`）。
- **suw APK**：`suw_apk/build.sh`（aapt2 + javac + d8 + apksigner，纯命令行）。
- **设备侧流程**：见 `z6root_local/z6root/README.md`。

## 免责

仅限自有设备的安全研究。详见 README.md 与 LICENSE。
