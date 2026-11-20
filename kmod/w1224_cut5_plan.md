# w1224 — 第 18 枪（Exp-9 `cut=5`）预登记

> 写于开火**之前**（11-11 21:2x）。用户明确表示不接受"社区路线走不了"、愿意继续花时间排查机制 ⇒ 本发不劝收，只做机制二分。
> 判据与结局先写死，事后不许圆场。路线见 `kmod/w1222_next_probe_plan.md`，归因边界见 `kmod/w1221_mechanism_audit.md`。

## 要回答的唯一问题

`cut=1`（prologue 后立刻 `return orig`）活 ≥193.5 s，完整 decline 段 ~19.5 s 死。两者差集只剩 7 项，其中 SD1 打印（quiet=1）、慢路（noslow=1）、并发（第16枪）、第一次进入（第17枪）都已排除。**凶手在哪半边？**

`cut=5` ＝ 在 `if (!ksu_is_allow_uid_for_current(...))` 分支里、`ksu_hp_pr(SD1)` 与 `goto` **之前**直接 `return orig`：

| 保留（名单判定已跑完） | 跳过 |
|---|---|
| `execveat && flags` 检查 | `pr_info(SD1)`（已否） |
| `!filename_user` 检查 | `goto do_orig_execve` |
| `ksu_is_allow_uid_for_current()` | 标签体 `ksu_is_allow_uid()` + SD5 |
| — | **函数尾 `return ksu_orig_syscall_table[orig_nr](regs)` 的编译形态** |

## 形状（单变量）

- ko：`kmod/kernelsu_cut5.ko` **5,113,568 B / `dead549fbe702a080108e65fa96407ac`**。
  由 `build_cut5.py` 从 `build_exp6d.py` **逐字派生**（A 补丁 `cd290071…` 与历发完全相同；`quiet` 总闸 + `cut=1/2` 框架不改一个字符），只加：
  E-① `ksu_exp6_cut5_hits` 计数；E-② `cut=5` 切口；E-③ `/proc/ksu_ser` 拉取式见证（同名，采集器不用改）。
- args：`kmod/ksu_args_cut5.txt`：`ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd ksu_exp6_mode=1 ksu_exp6_cut=5`
  （`quiet` 缺省 0；**不开** rate / serial / once / noslow ⇒ 相对 Exp-6 基线只差"切口位置"）
- 离线闸：符号 `ksu_exp6_cut5_hits`/`ksu_cut5_read`/`ksu_cut5_fops`/`__param_ksu_exp6_cut` 齐；串 `SERD CUT5 cut=%u hits=%lu quiet=%u` 在；未定义符号 **156→157，只多 `scnprintf`**（与第 16 枪同，5.4 导出符号）；vermagic `5.4.281-qgki-g2a88cd145def`。远端两份源与 `kernelsu.ko` 已还原 rc80（`CUT5_KO_OK`）。

## 双证人 / 双仪器

1. **切口与流量见证**（拉取式，不经 dmesg）：`/proc/ksu_ser` 输出
   `SERD CUT5 cut=5 hits=<N> quiet=0`。`hits` 单调增长 ⇒ 后续 execve 持续到达 decline 分支且被切走；`cut=5` 逐字回证参数生效。
2. **★死前现场（本发最大增量）**：`kmod/w1223_deathbed_sampler.sh`，PC 侧约 **3 s/拍**（adb 往返主导，冒烟实测），只读采 `/proc/stat` jiffies、`loadavg`、`MemFree/Slab/SUnreclaim`、`mod`、`/proc/ksu_ser`，每拍自带同源 `up=` 与 `boot=`。
   - 动机：`go.sh:141` 的 `RING_END_DUMP` 下限 **30 s > 死线 19.5 s** ⇒ 那个"死前整环 dump"从建成起就没生效过；第 15 枪内核日志只到 insmod+6.4 s，中间 **13 秒全盲**。这是机制一直没证到的直接原因。
   - ★**无论本发活还是死，采集器都必须交出至少 5 拍 `mod=1` 的完整读数**（`jif` 单调 / `slab` 趋势 / `hits` 趋势）。少于此 ⇒ 仪器不合格，判"未测"，不许拿"活/死"直接出结论。

## 判据（逐条；缺一条就是「未测」）

1. **通道成立**：采集器里有 `SERD CUT5` 行，`cut=5`、`quiet=0` 逐字对上。
2. **切口真的生效**：`hits` 单调增长且 >0（不是"没流量"的假活）；同时 `SD1` 在 dmesg 里应为 0（辅助，不作主判据——第 15 枪已证 dmesg 是被过滤子集）。
3. **主判据（存活）**：insmod 后**同一 boot** 活 ≥30 min；`boot=` 不变、`up=` 单调、`mod=1` 持续。`GO_RC` 不算（§6.585 假绿）。死亡时刻只用同源 `up=`。
4. **死前现场交付**：第 2 条仪器的 ≥5 拍 `mod=1` 读数。
5. **不是判据**：`which su` / `/system/bin/su` 存在与否；功能面（本发 su 本就不该通）。

## 两种结局（先写死）

- **仍 ~19.5 s 死**（且判据 1/2/4 齐）
  ⇒ 凶手在**前三行**：`execveat && flags` 检查 / `!filename_user` 检查 / `ksu_is_allow_uid_for_current()`。
  ⇒ 下一发 `cut=6`：在 **`filename_user` 检查之后、`ksu_is_allow_uid_for_current()` 之前** return orig
    （保留前两行检查、跳过名单判定）。★**21:4x 纠正**：原写的「在 `execveat` 检查之前再切一刀」
    是**重复空枪**——`cut=1` 本来就在那个位置切过且活了（§6.602）。
    · `cut=6` 活 ⇒ 凶手是名单判定那个函数调用（或其后的 return 形态）；
    · `cut=6` 仍死 ⇒ 凶手在 `execveat`/`filename_user` 两行，或「从函数中部 return orig」的形态。
  ⇒ 同时读死前采集器：`jif` 是否在死亡前停滞、`slab/SUnreclaim` 是否单调涨、`hits` 到多少触顶 ⇒ 第一次给出"挂死前资源曲线"。
- **活 ≥30 min**（且 `hits` 持续增长）
  ⇒ 凶手在 `goto do_orig_execve` 标签体，或**函数尾 `return orig` 的调用形态**（SD1 已被 quiet 否）。
  ⇒ 这时几乎可以锁定"调用形态而非 C 逻辑"：离线反汇编对比 `cut=1`（prologue 后 return，活）与完整 decline（尾部 return，死）两条 return 的指令序列 / 栈帧 / SCS(x18) / CFI；必要时再打一发"把标签体改成与 cut=1 完全同形的 return"验证。
  ⇒ **这一支如果成立，就是可修的方向**（改调用约定，而不是砍功能）。

## 现场纪律

- 一次开机一枪、`I_KNOW=1`、**开枪前现场点头**；`KO=kmod/kernelsu_cut5.ko` 必须显式给（`push_ksu.sh:9` 默认 rc74c）。
- args 由 `ARGS_FILE=` 带入；收口后手动复读两份 md5 = `fec3d301…`（SIGKILL 会绕过 EXIT 陷阱）。
- **本发不给 `RING_END_DUMP`**（下限 30 s > 死线，给了也不生效、只会污染形状）；死前现场全靠 `w1223`。
- 关窗铁律：MAC 恢复排在所有 root 腿之后；窗口不留过夜；活窗口绝不 `rmmod` 出货 ko。
  ★**若活过 30 min**（像第 17 枪那样窗口是活的、MAC 仍 `Permissive`）⇒ **主动 `adb reboot` 收口**，复证 `mod=0 / Enforcing / 无 /dev/ksud`。若 ~19.5 s 死 ⇒ 设备自行复位收口（同第 15/16 枪）。
- 全程约 **12 分钟到 insmod**；死则 +20 s，活则 +30 min 存活观察 ⇒ 总时长 12~45 分钟。


---

# 结果（11-11 21:29–21:44）—— **`cut=5` 仍死：凶手收敛到「前三行」**

## 装载与死亡
- push 复证 `kernelsu.ko dead549f…` / `ksu_args.txt 0aa87e9b…`；args 原文含 `ksu_exp6_cut=5`（`quiet` 缺省 0）。
- 新 boot `620ff03e` → `load1=3 up=489` 放行 → punch → `mod=1` 首拍 `up=753.96`。
- 判据等待器 `w1225`：**`VERDICT=DIED`**，第一拍 `mod=1 up=753.96` → 最后读数 `up=772.24` ⇒ **约 18.28 s**（同源 `up=`；与历发 19.27~20.75 s 同一窄带）。
- 复位后复证 **`boot=fddf7ac5`、`mod=0`、`Enforcing`、无 `/dev/ksud`** ⇒ 设备自行复位收口（同第 15/16 枪）。

## 判据逐条
| # | 判据 | 读数 | 结论 |
|---|---|---|---|
| 1 | 通道成立 | 8 行 `SERD CUT5 cut=5 hits=… quiet=0` | ✅ |
| 2 | 切口生效、不是空枪 | **`hits` 5→168→263→384→491→599→723→846**，单调、>0（≈46 次/s） | ✅ |
| 3 | 活 ≥30 min 同一 boot | `boot` 恒 `620ff03e`、`mod=1` 8 拍、`up` 单调；**18.28 s 死** | ❌ 不成立 |
| 4 | **死前现场交付** | **8 拍 `mod=1` 完整读数，`仪器=OK`** | ✅ **本项目第一次拿到死前 19 秒数据** |

## ★死前 8 拍曲线（本发最大价值，`kmod/w103_evidence/exp9_deathbed.txt`）
| 量 | 装载前 → 死亡前 | 读法 |
|---|---|---|
| `jif`（CPU jiffies） | 127568… → 132304… **单调增长** | 死前 CPU 没有锁死 |
| `load` | 5.74/5.86/4.50 → 5.57/5.81/4.52 | 稳定 |
| **`slab`** | 699044 → 700268 → **699904 kB**（±0.2%） | **全程平稳 ⇒ 无 slab 泄漏** |
| **`SUnreclaim`** | 425080 → 426268 → **425764 kB**（±0.3%） | **全程平稳 ⇒ 无不可回收内存累积** |
| `MemFree` | 1537248 → 1508904 kB（≈−28 MB） | 正常波动（装载 + 缓存） |
| **`psi some_avg10`** | **4.15 → 10.61 → 15.57 → 19.09 → 23.42 → 25.34 → 24.91 → 28.70 → 27.30** | **CPU 压力单调爬升** |
| `psi total` | 110827727 → 117898566 | 同步增长 |
| `hits` | 5 → 846（≈46 次/s） | 与第 16 枪同量级 |
| 死亡形态 | `21:42:53` 还是完整一拍，`21:42:56` 即 OFFLINE | **突然死亡，非渐进耗尽** |

⇒ **直接否掉"内存/slab 按次数泄漏"这支机制**：内存曲线全程平的，CPU 也一直有进度；但 CPU 压力持续爬升，到 ~28% 时一次性挂死。
⇒ 更贴合"**某个计数/状态或每 CPU 状态到点触发一次性动作**"，而不是资源耗尽。仍**未定位到具体名字**。

## 结论（按预登记第一种结局）
> **`cut=5` 跳过了 SD1 打印、`goto do_orig_execve` 标签体、以及「函数尾 `return orig` 的编译形态」，仍然 ~18.28 s 死**
> ⇒ 这三样（含先前推测的"尾部 return 调用形态"）**全部排除**；**凶手在 `cut=1` 与 `cut=5` 之间的三行**：
> `execveat && flags` 检查 / `!filename_user` 检查 / `ksu_is_allow_uid_for_current()`。

补充离线查证：`is_ksu_domain()` → `is_task_ksu_domain(current_cred())` → `is_sid_match(...)`，而 `noslow=1` 正是在 `is_ksu_domain()` 入口把整个 `is_sid_match` 短路掉、仍 19.27 s 死 ⇒ 三行里**最重的慢路也已被否过**。剩下的是更底层的动作：读 `pt_regs`、空指针检查、**调用 `is_ksu_domain()` 本身**、或"从函数中部 return orig"的形态。

## 下一发 `cut=6`（定义已在上面纠正，不是重复空枪）
在 `filename_user` 检查之后、`ksu_is_allow_uid_for_current()` **之前** return orig：
- 活 ⇒ 凶手是名单判定那个函数调用（或它之后的 return 形态）⇒ 继续查 `is_ksu_domain()` 的调用约定与 SELinux 钩子；
- 仍死 ⇒ 凶手在 `execveat`/`filename_user` 两行，或"从函数中部 return orig"的形态 ⇒ 用反汇编对照 `cut=1`（函数开头 return，活）与 `cut=5`（函数中部 return，死）的指令序列。
同样带 `w1223` 死前采集器（本发已证明仪器合格）。
