# w1226 — 第 19 枪（Exp-10 `cut=6`）预登记

> 写于开火**之前**（11-11 21:5x）。判据与结局先写死。
> 用户口径：不接受关线、继续排查机制（`w1222`）。上一发结果见 `w1224` / 账本 §6.612。

## 要回答的唯一问题

第 18 枪 `cut=5`（名单判定**之后** return）仍 **18.28 s** 死，而 `cut=1`（函数开头 return）活 ≥193.5 s。
⇒ 凶手落在两者之间的三行：`execveat && flags` 检查 / `!filename_user` 检查 / `ksu_is_allow_uid_for_current()`。
且 `noslow=1` 已短路 `is_ksu_domain()` → `is_sid_match()` 整条慢路、仍 19.27 s 死 ⇒ 三行里最重的一段已否过。

`cut=6` ＝ 在 **`filename_user` 检查之后、`ksu_is_allow_uid_for_current()` 之前** return orig：
- 保留 `execveat && flags`、`!filename_user`（读 `pt_regs` 与空指针检查）；
- **跳过名单判定那个函数调用本身**。

★**21:4x 纠正过的定义**：`cut=1` 本来就在「`execveat` 检查之前」切过且活了，所以"在 execveat 之前再切一刀"是**重复空枪**；`cut=6` 必须切在名单判定之前。`w1222`/`w1224`/账本 §6.612 已同步改。

## 形状（单变量，且消除 ko 差异）

- ko：`kmod/kernelsu_cut56.ko` **5,114,352 B / `8b18775de9e0175bd161b2cc7310f04b`**。
  `build_cut56.py` 由 `build_exp6d.py` 逐字派生（A 补丁 `cd290071…`、quiet 总闸、cut=1/2 框架全不动），加：
  `cut=5` 切口（对照）、`cut=6` 切口（本发）、`/proc/ksu_ser` 见证 `SERD CUT56 cut=%u hits5=%lu hits6=%lu quiet=%u`。
  ★**同一 ko 同时支持 5 和 6** ⇒ 下一发若需复现 cut=5 对照，只换 args 即可，**消除 ko 差异这个共变源**。
- args：`kmod/ksu_args_cut6.txt`：`… ksu_hook_mask=0x2 … ksu_exp6_mode=1 ksu_exp6_cut=6`
  （相对第 18 枪**只把 `cut=5` 改成 `cut=6`**）
- 离线闸：符号 `ksu_exp6_cut5_hits`/`ksu_exp6_cut6_hits`/`ksu_cut56_read` 齐；`SERD CUT56` 串在；未定义符号 **157**（与第 18 枪相同）；vermagic `5.4.281-qgki-g2a88cd145def`；远端两份源与 `kernelsu.ko` 已还原 rc80（`CUT56_KO_OK`）。
  ★首次 `--apply` 撞 WebSocket 代理 **504**，只读核对确认**远端完全未碰**（源＝基线、ko＝rc80、无备份无产物）后重试成功。

## 双证人 / 双仪器（沿用第 18 枪已证明合格的通道）

1. `/proc/ksu_ser` 拉取式：`SERD CUT56 cut=6 hits6=<N> hits5=0 quiet=0`。
   - `cut=6` 逐字回证参数；**`hits6` 单调增长** ⇒ 流量确实到达该切口、不是空枪；
   - **`hits5` 必须恒 0** ⇒ 证明只走了 cut=6 分支、没有串到 cut=5。
2. `kmod/w1223_deathbed_sampler.sh`：约 3 s/拍只读采 `jif / load / MemFree / Slab / SUnreclaim / psi / mod / SERD`，每拍带同源 `up=`/`boot=`。
   ★第 18 枪已交出 8 拍完整死前读数（`仪器=OK`），本发继续。

## 判据（逐条；缺一条就是「未测」）

1. **通道成立**：有 `SERD CUT56` 行，`cut=6`、`hits5=0`、`quiet=0` 逐字对上。
2. **切口生效**：`hits6` 单调增长且 >0。
3. **主判据（存活）**：insmod 后**同一 boot** 活 ≥30 min（`boot=` 不变、`up=` 单调、`mod=1` 持续）；`GO_RC` 不算。死亡时刻只用同源 `up=`。
4. **死前现场**：≥5 拍 `mod=1` 完整读数（仪器合格）。
5. **不是判据**：`which su` / `/system/bin/su`；功能面（本发 su 本就不该通）。

## 两种结局（先写死）

- **`cut=6` 活 ≥30 min**（且判据齐）
  ⇒ **凶手是 `ksu_is_allow_uid_for_current()` 这个调用本身**（或其后的 return 形态）。
  ⇒ 下一步：离线查 `is_ksu_domain()` 的调用约定 / SELinux 钩子 / 它是否触发厂商安全模块；必要时打 `cut=7`（只把 `ksu_is_allow_uid_for_current()` 换成常量 false，其余逐字同形）分离"函数调用"与"判定结果"。
  ⇒ **这才是最可能指向可修 bug 的一支。**
- **`cut=6` 仍 ~19.5 s 死**（且判据齐）
  ⇒ 凶手在 `execveat && flags` / `!filename_user` 两行，或**「从函数中部 `return orig`」的形态**（与 cut=1 的函数开头 return 相对）。
  ⇒ 下一步：反汇编对照 `cut=1`（活）与 `cut=5`/`cut=6`（死）三条 return 的指令序列 / 栈帧 / SCS(x18) / CFI；必要时打一发"把 cut=6 的 return 改成与 cut=1 完全同形的尾调用"。
  ⇒ 这一支若是"调用形态"，同样是**可修方向**（改调用约定，而不是砍功能）。
- **死得明显更早（<5 s）或未拉到 `SERD`** ⇒ 判「未测」，先查仪器/切口。

## 死前曲线怎么用（第 18 枪已给出的基线）
第 18 枪死前：`slab` ≈699 MB、`SUnreclaim` ≈425 MB **全程平稳**、`jif` 单调增长、`psi some_avg10` 4.15→28.70 单调爬升、突然死亡 ⇒ 已否掉"内存按次数泄漏"。
本发若 `cut=6` 活，对照两条曲线可看 `psi` 是否仍爬升；若仍死，看 `psi` 爬升斜率是否与切口位置无关 ⇒ 判断压力来自"进入 hook 本身"还是"名单判定"。

## 现场纪律
- 一次开机一枪、`I_KNOW=1`、**开枪前现场点头**；`KO=kmod/kernelsu_cut56.ko` 显式给。
- args `ARGS_FILE=` 带入；收口后复证两份 md5 = `fec3d301…`。
- **不给 `RING_END_DUMP`**（下限 30 s > 死线 19.5 s，从不生效）。
- 关窗铁律：MAC 恢复排在所有 root 腿之后；窗口不留过夜；活窗口绝不 `rmmod` 出货 ko。
  ★若活过 30 min ⇒ **主动 `adb reboot` 收口**（同第 17 枪）；若 ~19.5 s 死 ⇒ 设备自行复位收口（同第 15/16/18 枪）。
- 全程约 12 分钟到 insmod；死则 +20 s，活则 +30 min ⇒ 总 12~45 分钟。
