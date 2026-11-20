# w1222 — 继续排查 sucompat 死因：路线、差集与下一发（11-11 21:1x，纯离线 0 枪）

> 用户明确表示**不接受"社区路线走不了"的现状**，愿意继续花时间排查机制。
> 本文档不再劝收，只给能真正把死因从现象学推到机制的路线。

## 一、本轮 0 枪重审：把"已排除"重新验了一遍

| 结论 | 证据强度 | 复核结果 |
|---|---|---|
| 打印不是因（§6.600 `quiet=1`） | **很牢** | 17 处 `KSUBEAT S…` 全部静音，`SD1` 822→**0**，逻辑一行未改、调用帧不减，仍 **19.3 s** 死 |
| 进 handler 本身不是因（§6.602 `cut=1`） | **很牢** | `path[0]=0` 之后立刻 `return orig`，活 ≥193.5 s；且 `grant` 段 `SD4/SU0..SU4` 死前**零执行**，不必再为它烧枪 |
| 慢路不是因（§6.603 `noslow=1`） | 牢 | `NOSLOW hit=1/100` 见证成立，仍 19.27 s 死 |
| 并发不是因（§6.610 第 16 枪） | 牢 | `serial=1` / `enter↑` / `skip>0`，仍 ~19.6 s 死 |
| 第一次进入不是因（§6.611 第 17 枪） | 牢 | 深路严格 1 次，活 30.95 min |

⇒ **差集被压到极窄**：`cut=1` 与完整 decline 之间只剩

1. `execveat && flags` 检查；2. `!filename_user` 检查；3. `ksu_is_allow_uid_for_current()`；
4. `pr_info(SD1)`（**已否**）；5. `goto do_orig_execve`；6. 标签体的 `ksu_is_allow_uid()` + SD5；
7. **`return ksu_orig_syscall_table[orig_nr](regs)` 在函数尾部的编译形态**。

**★源码层再收紧**：`allowlist.c:275-312` 显示 `__ksu_is_allow_uid()` 对 `forbid_system_uid(uid)`（uid<10000）**直接短路 return false**，不进 RCU、不碰 hash、无分配；`__ksu_is_allow_uid_for_current(0)` → `is_ksu_domain()`，其慢路已被 noslow 否。
⇒ 1/2/3/6 在 C 逻辑层几乎全是平凡分支。**凶手越来越像"调用形态"而不是"哪行逻辑"**（栈 / SCS / CFI / 尾调用 / 从 hook 上下文调用原始 syscall 的约定）。

## 二、本轮新查出的三个事实（有一个直接解释了"为什么一直抓不到机制"）

### ★事实 1：现有"死前 dump"仪器在时间上永远够不到死线
`go.sh:137-146` 的 `RING_END_DUMP=<秒>` 要求 **30..900 秒**（`go.sh:141`），而死线是 **insmod+19.5 s**。
⇒ 这个"死前整环 dump"开关**从建成起就没有任何一发能生效**；第 15 枪的内核日志只覆盖到 insmod+6.4 s，死亡在 +19.3 s，中间 **13 秒盲区**。**这是"机制一直没证到"的直接原因。**

### ★事实 2：`/sys/kernel/tracing` 是挂载且可读的
现读 `drwxr-xr-x root readtracefs /sys/kernel/tracing`、`buffer_size_kb=1410`、`current_tracer` 空（nop）。
⇒ 窗口里（root 侧）可以开 `function_graph`／`function` tracer 抓 `ksu_handle_execve_sucompat*` 的进出；
若挂死是"进去了但没返回"，trace 里会留下**有 enter 无 exit** 的记录 ⇒ 这是定位静默挂死最直接的证据。

### 事实 3：SCS（影子调用栈）假设已离线初查，暂不成立
第 16 枪反汇编里 `_common` 开头 `str x30, [x18], #8` 提示 arm64 SCS。今天核：
- 基线 `rc80` 的 `ksu_handle_execve_sucompat_common`：**1 处 push / 1 处 pop**，配对；
- `ksu_syscall_trampoline`：**1 处 push / 1 处 pop**，配对；
- 全树显式 `x18`／`CONFIG_SHADOW_CALL_STACK`／`scs_` 操作：**0 命中**（都是编译器生成）；
- SLOTTBL 里跳转目标是 `ksu_syscall_trampoline+0x0`（函数入口，未绕开 prologue）。
⇒ "每次调用泄漏 8 字节影子栈"这个具体候选**目前不成立**，但"SCS/CFI/尾调用形态"这一族仍由事实 1/2 的仪器去覆盖。

## 三、下一发（第 18 枪）：`cut=5` —— §6.603 七写了、但**从没打过**的那一格

### 形状
在 `SD1` decline 分支里、`pr_info` 与 `goto` **之前**直接 `return ksu_orig_syscall_table[orig_nr](regs)`。
保留 `execveat`/`filename_user`/`ksu_is_allow_uid_for_current()` 三行，跳过 SD1、goto、标签体与函数尾的 return 形态。
- **单变量**：以 `kernelsu_exp6d.ko`（`adb17f7a…`，已有 `quiet` 总闸 + `cut=1`/`cut=2`）为基线，只加 `cut=5`；args 用 `mode=1 + ksu_exp6_cut=5`，不开 rate/serial/once。
- **见证**：沿用已证明可靠的 `/proc/ksu_ser` 拉取式（1 s/拍），带 `cut5_enter`/`cut5_skip` 计数，确认切口真的生效、且后续 execve 确实到达。

### 两种结局（先写死）
- **`cut=5` 仍 ~19.5 s 死** ⇒ 凶手在 `execveat` 检查 / `filename_user` 检查 / `ksu_is_allow_uid_for_current()` 这三行。
  ⇒ 下一发 `cut=6`：在 **`filename_user` 检查之后、`ksu_is_allow_uid_for_current()` 之前** return orig
    （保留前两行检查、跳过名单判定）。★**21:4x 纠正**：原写的「在 `execveat` 检查之前再切一刀」
    是**重复空枪**——`cut=1` 本来就在那个位置切过且活了（§6.602）。
    · `cut=6` 活 ⇒ 凶手是名单判定那个函数调用（或其后的 return 形态）；
    · `cut=6` 仍死 ⇒ 凶手在 `execveat`/`filename_user` 两行，或「从函数中部 return orig」的形态。
- **`cut=5` 活 ≥30 min** ⇒ 凶手在 `goto do_orig_execve` 标签体或**函数尾 `return orig` 的编译形态**（SD1 已被 quiet 否）。
  ⇒ 这时几乎可以锁定"调用形态"而非 C 逻辑：反汇编对比 `cut=1`（prologue 后 return，活）与完整 decline（尾部 return，死）两条 return 的指令序列、栈帧、SCS、CFI；必要时再打一发"把标签体改成与 cut=1 完全同形的 return"。

### 同时带上的死前仪器（本发的关键增量）
`kmod/w1223_deathbed_sampler.sh`：PC 侧**约 3 s/拍**（adb 往返主导，冒烟实测；脚本内 `sleep 1` + 一次 shell 往返）拉一批**只读 /proc** 计数器，覆盖 insmod 前到死亡，落盘。
- `/proc/stat`（CPU 各态计数，若内核挂死会停滞）、`/proc/loadavg`、`/proc/pressure/*`（PSI）
- `/proc/meminfo`（`MemFree`/`Slab`/`SUnreclaim`）、`/proc/slabinfo`（若可读）
- `/proc/ksu_ser`、`/proc/modules`（`mod=1`）
- 每拍自带 `up=` 与 `boot=`（同源时钟，不拿 epoch 夹）
★全部只读、不需要 root、不经 dmesg ⇒ 与第 16/17 枪证明可靠的通道同一族。死前那 19 秒第一次会有数据。

### 可选增强（若 `cut=5` 仍死，下一发加）
窗口 root 侧开 `function_graph` tracer 并 约 3 s/拍拉 `/sys/kernel/tracing/trace`。开销会改变时序，所以**不与 `cut=5` 同一发**，避免引入共变。

## 四、路线图与诚实预算

| 阶段 | 内容 | 枪数 |
|---|---|---|
| 0（本轮，已完成） | 离线重审已排除清单 + 找仪器缺口 + 写采集器与预登记 | **0** |
| 1 | 构建 `cut=5` ko（离线）+ 开火，带死前采集器 | **1** |
| 2 | 按结局 `cut=6` 逐行二分，或反汇编定位"尾部 return 形态" | 1~2 |
| 3 | 若确认是调用形态问题 ⇒ 改 hook 的调用约定（真·修复尝试），再验 | 1~2 |

⇒ 乐观 2 发、保守 4 发能拿到机制级结论。**不承诺"能救活"，但承诺"能定位到具体哪一行/哪种调用形态"**——这正是过去 17 发没做到的。

## 五、纪律
- 一次开机一枪、`I_KNOW=1`、**开枪前现场点头**；`KO=` 显式给。
- `ARGS_FILE=` 带入、`go.sh` EXIT 兜底复原；收口后复证两份 args `fec3d301`。
- 关窗铁律：MAC 恢复排在所有 root 腿之后；窗口不留过夜；活窗口绝不 `rmmod` 出货 ko。
- `RING_END_DUMP` 本发**不给**（下限 30 s > 死线，给了也不会生效，只会污染形状）；死前现场全靠 `w1223`。
