# rc82b 开火 runbook（2026-11-14 01:1x，收窗后·待用户点头）

> 上游：`B_CONTROL_PLAN.md` §5（B 对照枪 J1–J6 实质全过 ⇒ 下一步可开 `rc82b` 验五条判据）、
> `RC82KP_RESULT.md` §4/§6（A′ 产物＝`kernelsu_rc82b.ko` 只加 `/proc/ksu_kp_stat` 见证）。
> 前情：`TEARDOWN_20261114_0104.md` —— ① 第一阶段收窗已完成，设备为干净出厂态。
> **本文件只做准备与形状锁定，未开火、未改任何 args、未推任何 ko。**

## 0. 当前起点（01:13:55 独立复核，收窗后）

| 项 | 读数 |
|---|---|
| `boot_id` | `e5b2d9ae-1c15-4516-8cfa-10e5e546e2d0`（原 B 对照枪 `8434662d` 已翻篇） |
| `getenforce` | `Enforcing` |
| `sys.boot_completed` | **`1`** ⇒ `go.sh` L51/L329 的 `until boot_completed=1` 不会死等 |
| `grep -c kernelsu /proc/modules` | `0` ⇒ `NOREBOOT` 的 `MOD0=0` 检查也能过 |
| `/product/bin/su`、`/data/local/tmp/kd`、`/dev/ksud` | 全无 |
| `pbin` 挂载 | `0` |
| 名单/开关 7 件 | 全清（`ksu_two_profiles`／`ksu_args.txt`／`ksu_keep_auto`／`ksu_race_fd`／`b8_keep`／`dmesg2.log`／`b8_keep.log`） |

⇒ **这是一个干净 boot，本 boot 唯一一发 punch 尚未花**（收窗只 reboot，没打枪）。

**01:25:06 二次独立复核**（原始读数落盘 `RC82B_PREFIRE_PROBE_1114.txt`）：`adb get-state=device`、
`boot_id` 仍是 `e5b2d9ae…`（**未变 ⇒ 收窗后没人再 reboot / 没人开过枪**）、`Enforcing`、
`boot_completed=1`、`MOD=0`、`/product/bin/su`／`/dev/ksud`／`/data/local/tmp/kd` 全无；
本机四件 md5 与下表逐字一致。

⚠️ `/data/local/tmp/allow.bin` 是 **v9/v10 时代的历史残留**，不是本发的形状输入：
`push_ksu.sh` L30 推的是 `kmod/ksu_one_stage.sh`（L46 只有 `ALLOW=/data/adb/ksu/.allowlist`，
**无** `ALLOW_SRC`），`ksu_stage.txt` 也无 `allow.bin` 引用 ⇒ 当前链不读它，**不必清**。
真正会污染形状的是 `/data/adb/ksu/.allowlist`（§6.366/#153），收窗 T2.5 已用 root 腿清掉。

## 1. ★开火前必须拍板的形状冲突：args 怎么铺

**冲突**：
- 账本口径（`B_CONTROL_PLAN.md` §5 结论 3、`MEMORY.md` 铁律、`RC82KP_RESULT.md` §1）：
  「args 用 `ksu_args_kp.txt` 含 `ksu_keep_permissive=1`，**两份 `ksu_args.txt` 同改**（go.sh 会拿 bak 覆盖回来）」。
- 脚本现状（`go.sh` L61–72）：已有 **`ARGS_FILE` 机制** ——
  `cp "$ARGS_FILE" kmod/ksu_args.txt`，并挂 `trap … EXIT` 用 `.bak_delivery` 自动还原；
  L61 注释明写「本轮 args 由参数决定，**不靠我手改文件**（§6.226：今天四次『已还原』用嘴说）」。

**判定：用 `ARGS_FILE`，不动 `.bak_delivery`。** 依据（逐行核过）：

| 环节 | 行 | 读到哪份 args |
|---|---|---|
| `go.sh` 1.5 步 | L65 | `cp kmod/ksu_args_kp.txt kmod/ksu_args.txt` ⇒ 现件变 kp 形状 |
| `go.sh` 1.6 步 | L78 | 从现件反推 `ksu_ksud_path` ⇒ 得 `kd`（与交付件同值，不引入共变） |
| `go.sh` 第 2 步 | L308 `bash kmod/push_ksu.sh` | 子进程继承环境；`push_ksu.sh` L31 `ARGS=${ARGS:-kmod/ksu_args.txt}` ⇒ **推的是 kp 现件**；L76 `push "$ARGS" ksu_args.txt` ⇒ 设备侧 `/data/local/tmp/ksu_args.txt` = kp ✅ |
| `go.sh` 第 8 步 / EXIT trap | L634 / L69 | `cp .bak_delivery kmod/ksu_args.txt` ⇒ **本机交付件自动还原**，包括空枪 `exit 5` 与崩溃分支 |

⇒ **设备侧等价、本机更安全**。若照旧口径把 `.bak_delivery` 也改成 kp 形状，反而会**永久污染交付基线**：
下一发不带 `ARGS_FILE` 的交付窗会默认跑 `ksu_keep_permissive=1`（看门狗常态开），这是没有被验证过的形状。
⚠️ 账本那句「两份同改」是**旧口径 / 针对手改现件的情形**（那时没有 trap 兜底，怕 `exit 5` 把现件停在实验形状）。
**口径同步 01:2x 已做**（原文保留划掉＋更正注记，不抹历史）：
`w103_evidence/B_CONTROL_PLAN.md` §5.2 结论 3、`w103_evidence/RC82KP_RESULT.md` §9.5 第 2 条、
`.workbuddy/memory/MEMORY.md` 三处（现状／铁律／工具索引）均已改为 `ARGS_FILE` 口径。

**指纹已核**（01:25:06 复过，开火前再复一次）：
- `kmod/kernelsu_rc82b.ko` → `2807a4cacb6e31796ac3165176050499` ✅ 与账本 `2807a4ca` 一致，5,111,448 B
- `kmod/ksu_args_kp.txt` → `b5db1c0af70d6368c8e67faba6775997` ✅ 与账本 `b5db1c0a` 一致，含 `ksu_keep_permissive=1`
- `kmod/ksu_args.txt` == `.bak_delivery` → `fec3d301ff5a55a19720477f01dc71d9` ✅ 交付件（0x0），**保持不变**

⚠️ **必须显式给 `KO=`**：`push_ksu.sh` L9 默认是 **`kernelsu_rc74c.ko`（旧版）**，不给会推错 ko（B 对照枪 §1 已踩过这条）。
`KO` 通过环境变量继承给 `go.sh` L308 的子进程，B 对照枪就是这么用的。

### 1.1 ★带 `ARGS_FILE` 的这一发，`go_rc.txt` 不会写（01:2x 静态核验新发现）

`go.sh` 里有**两条** `trap … EXIT`：

| 行 | 内容 | 用途 |
|---|---|---|
| L23 | `trap 'rc=$?; echo "GO_RC=$rc …" \| tee -a "$GO_RC_FILE"' EXIT` | #165 立的规矩：`go_rc.txt` 在 ⇒ 件自己退；不在 ⇒ 被外部收掉 |
| L69 | ARGS_FILE 分支里的 `trap '… cp .bak_delivery …' EXIT` | §6.289 的 args 还原兜底 |

**bash 同名 trap 后设覆盖先设** ⇒ 只要给了 `ARGS_FILE`，L23 那条就被吃掉：
本发 `kmod/w103_evidence/go_rc.txt` **完全不会新增行**，`tee` 日志末尾也不会有 `GO_RC=`。
⇒ 事后去 `go_rc.txt` 找本发 rc 必然扑空，别误判成「日志坏了」或「进程被收掉」。

**补偿（不改脚本、不改设备形状，只在开火命令外层兜一层）**：用 `{ …; echo "OUTER_GO_RC=$?"; }`
把真实退出码写进日志（见 §2）。判据与 `go_rc.txt` 原设计同构：
- **有** `OUTER_GO_RC=` 行 ⇒ 脚本自己走完或从分支退出，数值即真实 rc；
- **无**该行 ⇒ 进程被外部收掉或整机硬复位（此时按 §5 分诊，别当空枪）。

⚠️ 若外层加了 `timeout 900`，超时会写出 `OUTER_GO_RC=124`，属于「我们主动收的」，要与硬复位区分。

## 2. 开火命令（逐字，待点头）

```bash
export PATH="/c/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/c/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/bin:/c/adb/platform-tools:$PATH"
cd "G:/项目/Windows管理/usb/临时root" || exit 1

# 开火前只读复核（boot_id 未变 / mod=0 / Enforcing / boot_completed=1 / 单设备）
adb devices
adb -s <DEVICE_SERIAL> shell "cat /proc/sys/kernel/random/boot_id; getenforce; getprop sys.boot_completed; grep -c kernelsu /proc/modules"

# ★唯一变量＝ rc82b ko + keep_permissive=1；其余交付形状逐字不变
# 外层 { …; echo OUTER_GO_RC; } ＝ §1.1 的补偿（带 ARGS_FILE 时 go_rc.txt 不写）
{
  I_KNOW=1 SU_BIND=1 \
    KO=kmod/kernelsu_rc82b.ko \
    ARGS_FILE=kmod/ksu_args_kp.txt \
    bash kmod/go.sh
  echo "OUTER_GO_RC=$?"
} 2>&1 | tee kmod/w103_evidence/RC82B_FIRE_1114.log
```

- 用**默认带 `adb reboot`** 的形状（与 B 对照枪 §1 一致，避免引入 `NOREBOOT` 变量）；
  当前虽已是干净 boot，但保持一致比省一次 reboot 重要。
- `SU_BIND=1`：`RC82KP_RESULT.md` §1 记「其余＝交付形状逐字不变 … `SU_BIND=1`」；五条判据里第 2 条要用 `/product/bin/su`。
- 外层建议 `timeout 900`（GNU coreutils 8.32 已确认可用），防 `go.sh` §6.292 的等待循环死等；
  脚本自身 `I_KNOW=1` 已给。
- **窗口零接触**（`B_CONTROL_PLAN.md` §4）：`go.sh` 跑期间不做任何额外 adb 操作，判读只用落盘日志。

## 3. 五条判据（16:4x 预登记，原文在 `RC82KP_RESULT.md` L5–6，**不许事后改**）

触发动作：窗口活稳后，走「RCQ 环境 → 加载全部模块」把 SELinux 翻回 `Enforcing`，然后逐格验：

| # | 判据 | 读数来源 |
|---|---|---|
| 1 | 模块 apply 后 **`getenforce` 回 0** | `adb shell getenforce` |
| 2 | **`asuid 10342 /product/bin/su -c id` 出 root** | 设备侧 `asuid`（注意：必须从有 root 的上下文发起，shell 直连 `su` 恒 EPERM，见 `LSPOSED_NOT_ACTIVE_1113.md` §5.2 C） |
| 3 | `mountinfo` **仍有 lsposed 挂载** | `grep lsposed /proc/self/mountinfo` |
| 4 | **`lspd` / `zn-daemon` 在跑** | `ps -A -o PID,PPID,NAME` |
| 5 | **LSPosed 显示已激活** | UI / Manager |

★**新增确定性见证（rc82b 的唯一增量）**：窗口活过 init 后
`cat /proc/ksu_kp_stat` → `param / started / hits / now_enforcing`
（`RC82KP_RESULT.md` §4/§240、`verify_rc82b.py` ②）。
- `started=1` ⇒ 看门狗已启动；`hits` 随 `enforcing==1` 增长、`now_enforcing=0` ⇒ **B 方案成立**。
- 它解决的是「窗口活着时 printk 读不到」，**不解决硬复位把内存态抹掉** ⇒ 若再硬复位，仍要靠 `go.sh` §6.292 的
  `HARD_RESET_DURING_WAIT` + `hard_<BTAG>_*` 归档（`B_CONTROL_PLAN.md` §4 说这条增强的阳性分支尚未验过）。

⚠️ 五条判据是「**模块 apply 后**」的场景，别拿「刚开窗、还没翻 Enforcing」的读数当通过。

## 4. 判读纪律（照抄 `B_CONTROL_PLAN.md` §4）

1. **一次开机一枪**：本发花掉 reboot 后新 boot 的唯一一发 punch，**不在同 boot 重打**。
2. **窗口零接触**：`go.sh` 跑期间不额外 adb；判读只用落盘日志。
3. **窗口不留过夜**：判读完即按 `w161_teardown.sh` 收窗；无 root 时 `reboot` 即干净收窗。
4. **判据先写、结果后填**：本文件已在开火前锁定判据与形状，不许按结果改口径。
5. **「计数=0 不是否据」**：`/proc/ksu_kp_stat` 读不到或 `hits=0` 都不自动等于「看门狗没跑」，要连
   `started` / `param` / 日志时序一起判。
6. **GO_RC=0 可能假绿**：以设备侧 `md5sum` 回读 + 五条判据实测为准，不看脚本退出码。
7. **本发 `go_rc.txt` 不写**（§1.1，L69 trap 覆盖 L23）：判「自己退 / 被收掉」只看日志末尾
   `OUTER_GO_RC=` 行——有行＝自己退（值即 rc），无行＝被收掉或硬复位。**别去 `go_rc.txt` 找本发**。

## 5. 失败分诊（预登记，别事后找解释）

| 现象 | 按 `B_CONTROL_PLAN.md` §3.1 的映射 |
|---|---|
| 又硬复位 / 又死在 report 序列 | **与 ko 无关**，是设备/环境侧变化 ⇒ **暂停 rc82 线**，先查温度/电量/网络重传风暴/`CELLULAR_TCP` 压力，**不要再打** |
| 空枪（J1/J2 失败、无硬复位） | 提权没成功，按 §6.290 处理，**不推进 rc82 线** |
| 部分通过 | 逐条列出，**不合并成「大概能行」**；下一发前先补对应判据读数 |
| 五条全过 + `started=1`/`hits` 增长 | B 方案成立 ⇒ 按 `B-SCOPE.md` 更新交付口径 |

## 6. 收窗（判读后）

`I_KNOW=1 bash kmod/w161_teardown.sh`（本次收窗实测 `RC=0`、8 分 11 秒，形状见 `TEARDOWN_20261114_0104.md`）。
复核：`boot_id` 已变 / `mod=0` / `Enforcing` / 无 `/product/bin/su` / 无 `kd` / `boot_completed=1` / 名单开关全清。

---

## 7. 准备清单（01:2x 全绿）

| 项 | 状态 |
|---|---|
| ① 收窗（teardown） | ✅ `SCRIPT_RC=0`，8min11s，见 `TEARDOWN_20261114_0104.md` |
| 设备干净态 / boot_id 未变 | ✅ 01:25:06 二次复核，`RC82B_PREFIRE_PROBE_1114.txt` |
| ko / args 指纹 | ✅ `2807a4ca` / `b5db1c0a`；交付件 `fec3d301` 未动 |
| `ARGS_FILE` 静态链路 | ✅ L65 → L308 → `push_ksu.sh` L31/L76；还原在 push 之后 |
| `KO=` 显式给定 | ✅ 否则 `push_ksu.sh` L9 默认推旧 `rc74c` |
| `allow.bin` 是否污染 | ✅ 否（历史残留，当前 stage 不读） |
| 三处旧口径同步 | ✅ 已改（原文划掉保留） |
| `go_rc.txt` 缺口 | ✅ 已用外层 `OUTER_GO_RC` 补偿并写进 §4.7 |
| 五条判据预登记 | ✅ §3，未开火前锁定 |
| 开火结果 | ❌ **两发皆 PS_HOLD 硬复位、彻底暂停**（五条判据 + `/proc/ksu_kp_stat` 全 N/A，见下） |

---

**状态：两发硬复位、彻底暂停（02:46 收窗）。** 第一发（01:39，fa7d3139 boot）insmod 阶段硬复位 ⇒ 静置 30min 后用户授权复验（02:34，a4622f7a boot）→ **又硬复位，且本次 ko 一度装上（终态 Permissive 残留）＋收窗 reboot 也触发 PS_HOLD**（`HISTORY` 累计三次 `cold,charger`）。
⇒ **rc82 系列 ko 开火必硬复位、非偶发，已坐实；rc82 线彻底暂停，当前设备连 reboot 都不稳，不建议再打任何枪（含 LSPosed 攻关窗口）。** 判读与恶化证据：第一发 `RC82B_FIRE_RESULT_1114.md`、复验 `RC82B_REFIRE_RESULT_1114.md`。

⚠️ 文档价值保留：本 runbook 的 §1（ARGS_FILE 判定）、§1.1（go_rc.txt 缺口）、§2（退出码兜底）均为可复用方法论，下一发直接套用。
