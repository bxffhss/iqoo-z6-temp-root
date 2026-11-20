# 新项目可行性侦察：ko 改说标准 KSU 协议 ＋ 重冠官方 App

> 设备：iQOO Z6（SM7325, `5.4.281-qgki`, A14）。目标：让官方 `me.weishu.kernelsu`(v3.3.1-24) 作 manager、用官方 UI 给标准 App（Scene/NP/黑域）授权。
> 侦察日期：2026-11-12（沿项目工作历）。状态：设备当前＝出厂态（诊断 A 已收窗）。

---

## 一、核心结论（颠覆原 premise）

### 1. ko 已经说「标准 KSU manager 协议」——并非自定义协议
- `kmod/ksu_src/dispatch.c` = 标准 KSU ioctl 分发表（`_IOC('K', …)`：GRANT_ROOT/GET_INFO/SET_APP_PROFILE/GET_MANAGER_APPID…），权限检查 `only_manager`/`manager_or_root`/`allowed_for_su` 全是标准实现。
- `kmod/ksu_src/supercall.h`：`KERNEL_SU_UAPI_VERSION = 4`，命令号＝标准 KSU。
- `kmod/ksu_src/app_profile.h`：标准 KSU `app_profile`（ver 4）。
- ⇒ 所谓「自定义 @sushd/@ksuarm 协议」是 **`com.suw.manager` App 端私有通道**（`suw_apk/suwksu_jni.c` 通过 abstract socket `@suwksu` + `@sushd:` 守护代跑），**不是 ko 的 ioctl 协议分叉**。
- 结论：「ko 改说标准协议」这一条**已基本满足**，不是要新写的工程。

### 2. 加冕（crowning）＝按 APK v2 签名证书 SHA256，构建期写死于 Kbuild
- `hermes:/root/k/ksu/kernel/manager/throne_tracker.c`：开机 `track_throne()` 读 `/data/system/packages.list`，遍历 `/data/app` 找 `base.apk`，对每个调 `is_manager_apk()`；命中则 `crown_manager()` → `ksu_set_manager_appid(uid)`。
- `hermes:/root/k/ksu/kernel/manager/apk_sign.c`：`is_manager_apk()` 校验 APK 的 **v2 签名证书 SHA256** == 构建期宏 `EXPECTED_HASH`（可选 `EXPECTED_HASH2`）。
- `manager_identity.h`：`is_manager()` = `current_uid % 100000 == ksu_manager_appid`。
- **Kbuild 第 135–162 行（hermes:/root/k/ksu/kernel/Kbuild）**：
  - `KSU_EXPECTED_SIZE := 0x033b`
  - `KSU_EXPECTED_HASH := c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6`（**＝官方 KernelSU Manager 证书 SHA256，上游默认**）
  - `KSU_MANAGER_PACKAGE` **未设置**（只认证书、不认包名）
  - `KSU_EXPECTED_HASH2` 当前**未启用**（单证书）
- ⇒ **ko 默认就信任官方 KernelSU Manager 证书**。A 开枪 `GET_MANAGER_APPID=10104`（=me.weishu.kernelsu）印证官方 App 已被加冕。
- ⇒ 「重冠官方 App」**大概率已满足**，不是需要新改的点（除非要同时信 suw + 官方，才需启用 `KSU_EXPECTED_HASH2`）。

### 3. A 开枪官方 UI 显『不支持』的根因＝二选一，需一手实测区分（不是加冕/证书配置问题）
- A 开枪实测：官方 Manager v3.3.1「已连、ver 32601-2」但超级用户页签 `tabs=0` 永不渲染 ⇒ 回落 `不支持`。注意它**读到了版本 32601**，故不是彻底连不上 / 版本完全拒读。
- 两种可能：
  - **① 加冕时序**：`track_throne()` 在 boot 时跑；若官方 App 是在 boot **之后**才侧载（A 开枪正是中途装 App），当时未被加冕（或 `pkg_observer` 尚未重冠），⇒ `GET_MANAGER_APPID` ≠ 官方 App 的 uid ⇒ UI 判定「非 manager」不渲染超级用户页签。这与「A 收口 step6 经 suw 读出 appid=10104」不矛盾（那是 App 装好、`pkg_observer` 重冠之后）。
  - **② version/uapi 握手**：v3.3.1 对 ko 报的 `KERNEL_SU_VERSION`(32601) / `KERNEL_SU_UAPI_VERSION`(4) 仍不接受（尽管读到了版本号）。
- 修复路径不同：**①** ＝ 确保官方 App 在 boot 时已装（或 `pkg_observer` 及时重冠），ko 配置无需改（默认证书已信官方）；**②** ＝ 改 `KSU_VERSION_OVERRIDE` 或 bump `KERNEL_SU_UAPI_VERSION`。

---

## 二、构建 / 工具链（已确认可行）
- ko 完整源码 ＋ 交叉编译工具链 ＋ 5.4.281-qgki 内核树**全在 hermes**（`/root/k/ksu/kernel`、`KDIR=/root/k/nothing_sm7325_v_mr`；clang/llvm/aarch64-linux-gnu），**本机无 NDK/toolchain**。
- 本地 `kmod/ksu_src/` 仅 supercall/policy/allowlist 参考子集；`kmod/rc79_src/` 仅 hook/sucompat 补丁片段；**manager 源码（apk_sign/throne_tracker/pkg_observer）只在 hermes**，本次已拉到 `hermes_pull/manager/`。
- 重建流程：`kmod/build_rc80.py`（默认只改 `hook/arm64/syscall_hook.c` 的 BN 静默补丁 ＋ 编译；`hrmt.py` 把本地件 exec 直写容器、编译、拉回 .ko）。

## 三、对原 scope 的修正
原 scope「ko 改说标准 KSU manager 协议 ＋ 重冠官方 App」经侦察可拆为：
- ✅ 改协议：已满足（ko 即标准协议；ioctl / uapi=4 / app_profile v4 全标准）。
- ✅ 重冠官方 App（配置层）：ko 默认 `KSU_EXPECTED_HASH`＝官方 KernelSU Manager 证书，官方 App 装好后即被加冕（A-run 已见 appid=10104），无需改证书。
- ❌ 真正缺口：让官方 App 在 UI 跑的那一刻**确实处于被加冕状态**（加冕时序，或版本握手）——决定官方 UI 能否渲染超级用户页签、给标准 App 授权。
- 若日后要**同时**信 suw + 官方两份证书，才需启用 `KSU_EXPECTED_HASH2`（Kbuild）。

## 四、下一步（待拍板）
- **B（推荐先做，最省钱）**：新开一窗，**确保官方 App 在 boot 前已装**（= `track_throne` 开机即加冕），再驱动官方 UI 看超级用户页签是否渲染、能否给 Scene/NP/黑域 授权。若①时序假设成立 ⇒ 直接可用，**无需改 ko**。
- **A**：若 B 仍『不支持』，定位 v3.3.1 的 version/uapi 门槛，决定改 `KSU_VERSION_OVERRIDE` / bump `KERNEL_SU_UAPI_VERSION`（supercall.h + Kbuild）。
- **C**：若确定同时信 suw + 官方，改 Kbuild 启用 `KSU_EXPECTED_HASH2` + 官方证书 SHA256。

## 五、纪律提醒
一次开机一枪 / `I_KNOW=1` / 设备零接触 / 关窗铁律 / 活窗口不 `rmmod` 出货 ko。改 Kbuild/manager 属改已登记件：hermes 上改 ＋ 重编 ＋ 拉回 ＋ 开一窗验（one boot one shot）。
