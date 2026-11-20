# iQOO Z6 临时 Root 研究（KernelSU 外部 .ko）

在 **iQOO Z6（V2220A / SM7325 / 5.4.281-qgki / Android 14 user）** 上，通过 CVE-2026-43499
（GhostLock）临时打开内核窗口，加载自编译的 KernelSU 外部 `.ko`，用**未修改的官方
KernelSU Manager** 授权，配合 Zygisk + LSPosed 形成一套"临时可用、重启即还原"的 root 环境。

> ⚠️ **性质**：仅用于**自有设备的安全研究**。临时 root 不持久（`reboot` 即还原）；
> exploit 有硬复位/变砖风险；请勿用于他人设备或生产环境。

## 核心结论（本项目验证过的）

| 结论 | 说明 |
|---|---|
| 稳定交付形态 | `rc80` ko + `/dev/ksud` + ioctl 授权；manager 加冕走 APK v2 证书 SHA256 比对 |
| sucompat 钩子路**已封存** | `0x2`/`0x1a` 钩子位在本机必然 ~19.5s 硬复位；社区 `ksu_hook_mask` execve 改道同样死 |
| 现行 su 路径 | 真二进制 bind 到 `/product/bin/su` → 连 `@suwshd` 根代理 → agent 持 KSU 驱动 fd 走 ioctl |
| LSPosed 激活 | 依赖 **Zygisk 注入 zygote**（与 su 钩子无关）；干净窗口一次成，脏窗口（残留 `zygiskd64 (deleted)`）会失败 |
| @sushd 通道 | daemon + 子进程侧正常；不稳定点在 app 侧连接/轮询，已加 3 次重试 + 真实状态回报 |

## 目录

```
kmod/           研究脚本、探针、包装（w*.sh / w*.py / *.c）、一手账本
analysis/       漏洞分析与逆向记录（Binder / KGSL / CFI 等）
cm57/           ksuctl / su 工具链源码
suw_apk/        SU 白名单管理器（Java + JNI + 构建脚本）
z6root/         设备侧交付包（脚本层）
z6root_local/   交付包整合版（run.sh + LSPosed 加装）
z6root_v2/      结构化配置版
cheese/         KGSL 探测源码
iqooz5/         iQOO Z5 相关（对照）
.workbuddy/     工作日记忆（已脱敏）
```

## 构建

- **ko**：需要匹配的内核树（`5.4.281-qgki`）+ clang/LLVM，`CONFIG_KSU=m`；
  相关编译包装见 `kmod/remote_ksu_build*.sh`（需自备内核树与工具链）。
- **suw APK**：`suw_apk/build.sh`（aapt2 + javac + d8 + apksigner，纯命令行）
- **设备侧包**：见 `z6root_local/z6root/README.md`

## 免责

本项目所有内容仅供**自有设备的安全研究与学习**。作者不对任何滥用、数据丢失、
设备损坏或违反当地法律的行为负责。使用前请确认你拥有设备的所有权与研究授权。

## License

MIT（见 LICENSE）
