# B 对照枪：预登记（11-13 22:2x 开火，**判据先写、结果后填**）

> 目的（`RC82KP_RESULT.md` §6 修正后的顺序）：rc82_kp 第 1 发在 init 尾段 report 序列中途
> 硬复位；§3.1 的二进制对照已证死点代码在 rc80 与 rc82_kp 里等价、5 个成功窗口里同一段
> 序列都跑完 ⇒ 最自洽的解释是**偶发环境侧事件**。本枪用**现成稳定交付件**重打一发，
> 回答一个二值问题：**这台机现在还能不能满窗活、report 序列还能不能跑完？**
> 判据在开火前写死，防止事后按结果改口径。

## 1. 本枪形状（逐字）

```bash
I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh
```

| 项 | 值 |
|---|---|
| ko | `kmod/kernelsu_rc80.ko` md5 `98bf405273e8652cdb7fffcc3fe42dc2` |
| args | `kmod/ksu_args.txt` md5 `fec3d301ff5a55a19720477f01dc71d9`（`hook_mask=0x0`，**无** `ksu_keep_permissive`）；`ksu_args.txt.bak_delivery` 同值 ⇒ EXIT 兜底不改形状 |
| `ARGS_FILE` | **未给** ⇒ go.sh 用仓库现有 args（§1.5 那条分支） |
| `SU_BIND` | `=1`（与 rc82_kp 第 1 发一致） |
| `NOREBOOT` | 未给 ⇒ go.sh 第 2 步 `adb reboot` 起一个干净新 boot |
| 设备侧开关 | `ksu_two_profiles`(112 B) / `ksa_uids.txt`(12 B) **保留**（rc82_kp 第 1 发铺的，保留才与失败发同形状）；`push_ksu.sh:109` 会现取 uid 覆盖 `ksa_uids.txt` |
| 日志 | `kmod/w103_evidence/go_b_control_<TAG>.log`，TAG 见 `b_control.tag` |

⚠️ **必须显式给 `KO=`**：`push_ksu.sh:9` 的默认是 **`kernelsu_rc74c.ko`（旧版）**，
不带就会推错件、白费一发。

### 1.1 与 rc82_kp 第 1 发的变量表

| 轴 | rc82_kp 第 1 发（失败） | 本枪（B） |
|---|---|---|
| ko | `kernelsu_rc82_kp.ko` `1c2c74b1`（带看门狗） | `kernelsu_rc80.ko` `98bf4052`（稳定交付） |
| args | `ksu_args_kp.txt` `b5db1c0a`（含 `ksu_keep_permissive=1`） | `ksu_args.txt` `fec3d301`（0x0） |
| 其余 | `SU_BIND=1`、非 quiet、默认 AP_KEY/DOM/SHBIN、NOSUW 未给、RACE 开关在、`b8_setup` 铺 6 条名单 | **逐字相同**（含保留的设备侧 `ksu_two_profiles`） |

⇒ 变量收敛到「ko + args」这一组；若本枪满窗活，即可把 17:34 那次硬复位归到
**rc82 侧的偶发/环境事件**，而不是"这台机从那时起就不行了"。

## 2. 开火前设备起点快照（22:2x，纯只读）

```
adb devices            : <DEVICE_SERIAL>  device
sys.boot_completed     : 1
uptime                 : 17567.66          (≈4.9h，未开过窗)
ro.boot.bootreason     : HARD_RESET/PS_HOLD/0x01+0x01
sys.boot.reason        : hard
reason.history[0]      : hard,1794562487   (= 17:34:47，rc82_kp 那次硬复位)
getenforce             : Enforcing
kernelsu in /proc/modules : 0
/dev/ksud              : 不存在
/product/bin/su        : 不存在
uid                    : suw 10342 / 官方 10308 / Termux 10667
```
⇒ 干净出厂态、无过夜窗口、该 boot 唯一一发 punch 未花（且 go.sh 会 reboot 起新 boot）。
`kd`(2.2 MB, 17:34) 与 `w184_sample.out`(17:34) 是 inert 残留，go.sh 会覆盖/清掉。

## 3. ★预登记判据（结果出来前锁定）

| # | 判据 | 通过条件 | 读数来源 |
|---|---|---|---|
| **J1** | go.sh 走完 | 日志末尾 `GO_EXIT=0`，且未走 `exit 5` 空枪分支 | `go_b_control_<TAG>.log` |
| **J2** | 判据⑥到手 | 日志含 `判据⑥ 到了 (t+…)`（agent fd 装好＝root 通道可用） | 同上 |
| **J3** | **report 序列跑完** | 内核日志同时出现 `KILLSCAN enter`、`KSUFDINST 触发口`，`CFI __arm64` 18 条 | `dmesg.live` / `dmesg_full.txt` 归档 |
| **J4** | **没有硬复位** | 不出现 `HARD_RESET_DURING_WAIT`（§6.292 新增分诊）、`boot_id` 前后一致、`go_bootstrap` 等待循环记的 up 单调不回退 | `go_b_control_<TAG>.log` |
| **J5** | su 真出 root | go.sh 后半段 root 复证出 `uid=0(root)` | 同上 / `go_rc.txt` |
| **J6** | 窗口活着 | 分诊时 `mod=1`、`Permissive`、ko 未消失 | 日志 / 采样器 |

### 3.1 结论映射（**不许事后改**）

- **J1–J6 全过** ⇒ 设备/环境侧没问题；17:34 硬复位判为**偶发事件**。
  ⇒ 按 §6 顺序，下一步可用 `rc82b` 开火验 B 方案预登记的五条判据。
- **J3 或 J4 失败（又硬复位/又死在 report 序列）** ⇒ **与 ko 无关，是设备/环境侧变化**
  ⇒ **暂停 rc82 线**，先查设备状态（温度/电量/网络重传风暴/`CELLULAR_TCP` 压力），
  不要再打 rc82b。
- **J1/J2 失败但无硬复位（真空枪）** ⇒ 提权没成功，按 §6.290 既有口径处理，
  同样**不推进 rc82b**（载体还没证明能活）。
- **部分通过** ⇒ 逐条列出，不合并成"大概能行"；下一发前先补对应判据的读数。

## 4. 纪律

- 一次开机一枪；本枪花掉 reboot 后新 boot 的唯一一发 punch，**不在同 boot 重打**。
- 窗口**零接触**：go.sh 跑期间不做任何额外 adb 操作（会污染窗口）；判读只用落盘日志。
- 窗口不留过夜：本枪判读完即按 `w161_teardown.sh` 口径收窗；无 root 时 reboot 即干净收窗。
- `go.sh` §6.292 本枪首次实战：若发生硬复位，应自动报 `HARD_RESET_DURING_WAIT`
  并强制归档 `hard_<BTAG>_*` ⇒ 这本身也是对该诊断增强的一次验证。

## 5. 结果（11-14 00:0x 补判读，**口径不改**）

> ⚠️ 判读时间晚于开火，但**判据与该表的「结论映射」均在开火前锁定**（§3/§3.1），
> 下面只把读数填进去，没有事后调整任何通过条件。
> ⚠️ 判读时设备仍是**同一 boot**（`boot_id=8434662d` 未变），用户已在该活窗口里
> 装模块并点过「加载全部模块」⇒ J6 是「此刻」读数，不是开火瞬间读数。

| # | 结果 | 证据 |
|---|---|---|
| **J1** | ✅ **过** | `go_b_control_1113-2227.log` 88 行，末尾 `GO_RC=0` / `GO_EXIT=0 at 2026-11-13 22:44:39`，未走 `exit 5` 空枪分支 |
| **J2** | ✅ **过** | 同日志 L43 `判据⑥ 到了 (t+5s)`；L44 `[22:43:30] insmod rc=0 up=799.66 lsmod=[kernelsu 204800 0 ]`；L56 `BIND_RC=0`、L58 `HEALTH=OK` |
| **J3** | ✅ **实质过（附一处字面缺口，见 §5.1）** | ★证据源是 `/data/local/tmp/ksu_stage.log`（L115–L120，up=799.63 与 L44 的 insmod up=799.66 对齐）：`KILLSCAN enter`=1、`KILLSCAN 收工`在、四条 report（LSMHOOK/SLOTTBL/PCODE/UTS）齐全、`CFI __arm64`=**18**（与 5 个成功窗口的固定值一致）、末行 `=== 结束(能到这行=本 boot 活下来了) ===`。⇒ **report 序列完整跑完、没死在 init 尾段** |
| **J4** | ✅ **过** | 日志无 `HARD_RESET_DURING_WAIT`；L41 `#6.292 boot 锚点: boot_id=8434662d`，判读时设备 `boot_id=8434662d-e396-…` **一致**；`sys.boot.reason=reboot,shell`（＝ go.sh 自己那次 `adb reboot`），非 `hard`；uptime 单调增（953 → 4137 → 4519），无回退 |
| **J5** | ✅ **过** | L69 `=== G2 up=945.92 uid=0 mod=1 ===`；L71–72 两个 uid `granted=1`；L75 `现在：mod=1 enf=Permissive up=953`。⚠️ 日志里的是 go.sh 自己的 root 复证（uid=0），不是从 adb shell 手敲 `su`（shell 不在 allowlist，EPERM 是预期） |
| **J6** | ✅ **过** | 判读时：`getenforce=Permissive`、`/proc/modules` 首行 `kernelsu 204800 11 - Live`（124 行）、`/dev/ksud`(10,78)、`/product/bin/su` 全在；`lspd`/`zn-daemon`/`shd`/`ksuctl` 均存活 ⇒ 窗口活着 |

### 5.1 J3 的读数缺口（不合并、不假绿）

J3 字面写的是「`KILLSCAN enter`、`KSUFDINST 触发口`、`CFI __arm64` 18 条」三项同时出现。实测：

| 项 | 读数 | 判法 |
|---|---|---|
| `KILLSCAN enter` | 1 | ✅ |
| `CFI __arm64` | 18 | ✅ |
| `KSUFDINST` | **0**（`stage.log`） | ⚠️ **不作否据**：① 项目铁律「计数=0 不是否据」；② `dmesg` 被 RCQ 设了 `dmesg_restrict=1`，shell 读直接 `klogctl: Operation not permitted`；③ `dmesg_full.txt` 是 0 B、`dmesg.live` 是 14:40 那窗的 stale 件；④ **J2 的「判据⑥ 到了」就是 fd 装好的等价读数**，L56 `BIND_RC=0`/L58 `HEALTH=OK` 再佐证 |

⇒ J3 判「**实质过**」：它要回答的问题（report 序列跑完没）由 `KILLSCAN 收工`+`CFI 18`+`=== 结束 ===` 三个独立串敲定。
**下一发前仍应补一个可靠的 `KSUFDINST` 读数**（例如让 go.sh 成功路径也落一份 stage 侧的 dmesg 归档），
别把这一格当作已闭合。

### 5.2 按 §3.1 锁定的结论映射

J1–J6 **实质全过**（J3 带一处字面读数缺口，不影响其判据目的）⇒

1. **设备/环境侧没问题**：这台机现在仍能满窗活、report 序列仍能跑完。
2. **17:34 那次硬复位判为偶发环境事件**（不是「这台机从那时起就不行了」，也不是 rc82 代码的确定性死点）。
3. **不触发 §3.1 的「暂停 rc82 线」分支** ⇒ 按 §6 顺序，**下一步可用 `rc82b` 开火验 B 方案五条判据**
   （`KO=kmod/kernelsu_rc82b.ko`、args 取 `ksu_args_kp.txt` 含 `ksu_keep_permissive=1`，
   ~~两份 `ksu_args.txt` 同改~~）。⚠️ 需**另起一个干净 boot**，本 boot 唯一一发 punch 已花。
   > 🔧 **11-14 01:2x 口径更正（原文保留划掉，见 `RC82B_FIRE_RUNBOOK_1114.md` §1）**：
   > `go.sh` L61–72 已有 `ARGS_FILE` 机制（`cp "$ARGS_FILE" kmod/ksu_args.txt` + `trap … EXIT` 自动还原）。
   > 正确写法是 **`ARGS_FILE=kmod/ksu_args_kp.txt`**，**不动 `.bak_delivery`**；
   > 照旧「两份同改」会把 `ksu_keep_permissive=1` 永久写进交付基线，污染下一发不带参数的交付窗。
   > 静态核验（01:2x）：L65 `cp` 在 1.5 步 ≪ L308 `bash kmod/push_ksu.sh`；两处还原（L69 EXIT trap、L634 第 8 步）
   > 都在 push 之后 ⇒ 设备侧拿到的是 kp 形状，本机交付件自动回 `fec3d301`。
4. `go.sh` §6.292 本枪首次实战：未报 `HARD_RESET_DURING_WAIT`（因为确实没硬复位），
   ⇒ **该增强的「阳性分支」尚未被验证**，不能据此说它已验完；阴性行为（不误报）正常。

## 6. 判读期间发现的另一条独立问题（不并入本枪结论）

判读时用户在同一活窗口里报告「装上模块、RCQ 环境『加载全部模块』，LSPosed 还是没激活」。
已另立 `kmod/w103_evidence/LSPOSED_NOT_ACTIVE_1113.md` 诊断：
根因是 **zygote 从未重启（开机 12.08s 起 71 min 未变）⇒ Zygisk 无注入窗口**，
叠加 `sys.boot_completed` 被 RCQ 按住 0 与 `ksud soft-reboot` 卡死 40 min 的互锁。

- 本次 `getenforce=Permissive` **全程没翻** ⇒ 与 16:3x「点加载模块翻 Enforcing」的事故**不是同一现象**，
  **B 方案看门狗对此正交、救不了**。
- ⇒ 该问题**不改变本枪 J1–J6 的判读**，但提示「加载全部模块」这条动作路径本身不稳定，
  下一发若也要验模块行为，需把「SELinux 翻转」与「zygote 未重启」两类症状分开记。
