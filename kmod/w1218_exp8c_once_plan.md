# w1218 — 第 17 枪（Exp-8c「一次性进入」）预登记

> 写于开火**之前**（11-11 19:3x）。判据与结局判定先写死，事后不许圆场。

## 要回答的唯一问题

把"深路次数"从 46~727 次/s 压到 **恰好 1 次**，这台机还会不会在 ~19.5 s 死？

- 第 16 枪给出的形状是「**门槛 + 引信**」：深路 ≳46 次/s ⇒ 一律 ~19.5 s 死（19.32 / 19.50 / 20.75 / 19.6），深路 ~4 次/s ⇒ 活 ≥1384 s。
- 这条曲线**不能区分两种机制**：
  - **(甲) 按次数累积**：跑够 N 次深路才触顶 ⇒ 只跑 1 次应该**活很久**；
  - **(乙) 第一次深路就武装了什么**：某段代码第一次执行时挂了个延迟 ~19.5 s 的状态/定时器/引用 ⇒ 只跑 1 次**照样 ~19.5 s 死**。
- 若是 (乙)，触发点就收敛到"第一次深路的那一段代码"里，**可能是一个可修的 bug** ⇒ 全速 su 才有戏。这是本发唯一的价值，也是它值得花一枪的理由。
- 若是 (甲)，则确认"能活的速率正好是把 su 废掉的速率"，**「可用区间为空」盖棺**，不再留尾巴。

## 形状（与第 16 枪单变量）

- ko：`kmod/kernelsu_once.ko`，以 `kernelsu_serial2.ko`（`47788edb…`）为基线：
  - A) `syscall_event_bridge.c` 的 mode 守卫 —— **逐字相同**
  - B) `sucompat.c` 清 63 行 + 串行闸包装 —— **逐字相同**（本发 `serial=0`，闸默认短路、连原子操作都不做）
  - C) `/proc/ksu_ser` 拉取式见证 —— **同形**，字段扩展
  - **E) 本发唯一增量**：`ksu_exp6_once=1` ⇒ `_common` 入口 `atomic_cmpxchg(&ksu_once_done,0,1)`，
    抢到的那**一个**线程进 inner（`once_enter=1`），之后所有调用直接
    `return ksu_orig_syscall_table[orig_nr](regs)`（`once_skip` 累加）。
    ★放在串行闸**之前** ⇒ 本发深路次数严格 = 1，且不受串行闸影响。
- args：`kmod/ksu_args_once.txt`
  `ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd ksu_exp6_mode=1 ksu_exp6_once=1`
  （**不带** `ksu_exp6_serial`、`rate`、`noslow`、`nouid0`、`quiet`、`cut` ⇒ 与 Exp-6 基线只差"深路次数"一个变量）
- 见证（沿用第 16 枪已证明可靠的通道）：`/proc/ksu_ser` 读时现算一行
  `SERD once=%u once_enter=%lu once_skip=%lu serial=%u mode=%u mask=0x%x enter=%lu skip=%lu busy=%d`
  PC 侧 `kmod/w1219_poll_once.sh` 1 s/拍，**不经 dmesg、不经 stage 日志抽取**。

## 判据（逐条；缺一条就是「未测」，不许当「通过」）

1. **通道成立**：poll 文件里至少出现一行 `SERD`。一行都没有 ⇒ 本发判「未测」，先查 `/proc/ksu_ser` 为什么没建出来。
2. **形状跑对**（正面见证，缺一不可）：
   - `once=1`、`serial=0`、`mode=1`、`mask=0x2` 四条逐字对上；
   - **`once_enter=1` 且全程不增长**（深路严格只有 1 次）；
   - **`once_skip` 持续增长且 >0**（证明后续 execve 真的到达 `_common` 但被挡掉了，而不是"系统根本没流量"）。
   ★这一条是本发的命门：没有 `once_skip>0`，"活下来"就可能是"没流量"而不是"只进一次"，等于空枪。
3. **存活（主判据）**：insmod 后**同一 boot** 活 ≥ 30 min。双证人：PC poll 的 `up=` 单调无回落 + `boot=` 不变；`GO_RC` 不算（§6.585 已定"假绿"）。死亡时刻只用同源 `up=`。
4. **不是判据**：`which su` / `/system/bin/su` 存不存在；本发 su 从第 2 次起必然被挡，功能面**预期就不通**，不拿它当失败。

## 三种结局对应的结论（先写死）

- **活 ≥30 min 且 `once_enter=1`、`once_skip>0`** ⇒ **1 次深路不足以触发**。
  ★**20:5x `w1221` 审计发现本预登记的假设空间漏了 (丙)「速率／持续度阈值」**（§6.605 原话「要死得持续高频率」）：1 次深路、速率≈0 时 (丙) 同样预测活 ⇒ **本发对 (甲)/(丙)/(丁) 无判别力**，不能据此判「(甲) 成立」。
  ⇒ 但「可用区间为空」是现象学结论（§6.608 曲线两端已独立确立），**不依赖机制、仍然盖棺**；社区 sucompat 路线正式关线，不再以"还没试够"留尾巴。
- **仍 ~19.5 s 死且 `once_enter=1`、`once_skip>0`** ⇒ **(乙) 第一次深路就武装了什么**。
  ⇒ 触发点收敛到第一次深路的代码段（重点查 `filp_open` / fd 安装 / `escape_with_root_profile` / sulog pending / 谁挂了延迟状态）。
  ⇒ **这可能是可修的 bug** ⇒ 另立方向做定点修复，**此时不关线**。
- **死得比 19.5 s 明显更早**（例如 <5 s）⇒ once 门本身引入新问题（或第一次深路立刻炸），先查 `once_enter` 与死亡间隔，不当成 (乙) 的证据。
- **没拉到 `SERD` / `once_skip=0`** ⇒ 「未测」，修仪器或改形状，不许出结论。

## 现场纪律（照旧）

- 一次开机一枪、`I_KNOW=1`、**开枪前现场点头**；`KO=kmod/kernelsu_once.ko` 必须显式给（`push_ksu.sh:9` 默认 rc74c）。
- args 由 `ARGS_FILE=` 带入；收口后手动复读两份 md5 = `fec3d301…`（SIGKILL 会绕过 EXIT 陷阱）。
- 关窗铁律：MAC 恢复排在所有 root 腿之后；窗口不留过夜；活窗口里绝不 `rmmod` 出货 ko。
- poll 只用 `sleep 1`，不开重活。

---

# 结果（11-11 19:44–20:29）—— **第一种结局：(甲) 按次数累积，可用区间为空盖棺**

## 产物与开火
`kmod/kernelsu_once.ko` **5,119,944 B** / **`71e133a3583eb275b5ad2a631dc75a61`**；`build_once.py --apply` ⇒ `EXITCODE=0` / `ONCE_KO_OK`，远端两份源与 `kernelsu.ko` 无条件还原。
离线闸：`ksu_exp6_once`／`ksu_once_done`／`ksu_once_entered`／`ksu_once_skipped`／`__param_ksu_exp6_once` 全在；`SERD` 串含 once 三字段；未定义符号 **157 = 157**（与 serial2 零新增依赖）；vermagic `5.4.281-qgki-g2a88cd145def`。
push 复证 `kernelsu.ko 71e133a3` + `ksu_args.txt b492e4f0`；args 原文 `… ksu_hook_mask=0x2 … ksu_exp6_mode=1 ksu_exp6_once=1`（**无** `serial`）。
新 boot `1ab7726d` → `load1=3 up=401` 放行 → punch → **`insmod rc=0 up=670.13`**（`lsmod=[kernelsu 212992 0]`）。

## 判据逐条（全部命中，且是**同一份拉取式证据**）
`kmod/w103_evidence/exp8c_once_poll.txt` 共 **840 行 `SERD`**，首 `up=669.35`、末 `up=2541.29`；等待器 `w1220` 在 `up=2484.37` 判 `VERDICT=SURVIVED_30MIN`（insmod 后 **1814.24 s**），而全档实际活到 **1857.09 s = 30.95 min**。

| # | 判据 | 读数 | 结论 |
|---|---|---|---|
| 1 | 通道成立 | 840 行 `SERD`，无"收工/掉线"行（早期 OFFLINE 是开火 reboot，未误判） | ✅ |
| 2a | 形状对上 | `once=1 serial=0 mode=1 mask=0x2` **全程 840 行恒值** | ✅ |
| 2b | 深路严格 1 次 | **`once_enter` 取值集合 = {1}**（全程不动） | ✅ |
| 2c | 不是"没流量" | **`once_skip` 7 → 26555**，单调不降、>0 | ✅ |
| 3 | 活 ≥30 min 同一 boot | `boot` 集合 = {`1ab7726d`}、`mod` 集合 = {1}、`up` 单调不降；**1857.09 s** | ✅ |
| — | 不是判据 | `enter/skip/busy` 全程 0（serial=0，串行闸短路，符合设计） | — |

★第 2c 条是命门：后续 execve 真的持续到达 `_common` 并被挡（约 14 次/s），**不是"系统没流量所以看起来活着"**。

## 结论（★20:5x 经 `w1221` 审计收紧：主判据通过，但**归因判「未测」**）
> **1 次深路不足以触发。** 判据（同一 boot 活 ≥30 min）满格通过，但预登记漏了 (丙) 速率阈值，
> 因此不能执行第一种结局里「(甲) 按次数累积成立」那半句。**只保留现象学结论。**

- 各发**实测**口径（原表的 727/199/4 次/s 是单位错误，见 `w1221`）：深路 1 次 ⇒ 活 ≥30.95 min；0.2 次/s ⇒ ≥1384 s；9.7 次/s ⇒ 20.75 s 死；≈38/≈46 次/s ⇒ 19.50/19.6 s 死。
- 「第一次深路就武装了什么」(乙) **被排除** ⇒ 不存在"第一次进入里的可修 bug"这条捷径，定点修复方向不成立。
- **「可用区间为空」盖棺**：要能用就必须全速深路，全速深路就必在 ~19.5 s 死；能活的形状（0 / 1 次 / 0.2 次/s）恰好把 su 废掉 ⇒ 社区 sucompat 路线**正式关线**。★该结论**不依赖机制**，不受归因修正影响。
- **并发交错不是死因**（第 16 枪 `serial=1`/`enter` 增长/`skip>0` 仍 ~19.6 s 死）继续有效。
- ★**机制仍未证到，而且比原先写的更弱**：不但没证到"具体是什么资源/状态"，连「**是否存在按次数的累积**」都没证到——深路源码无显式分配/引用计数、全树无定时器、崩溃签名无 OOM/panic、历发从未量过 slab/fd/cred 计数；(甲) 次数阈值 / (丙) 速率阈值 / (丁) 阈值+固定延迟 **三格都还自洽**，正交判别发 `rate=20` 在 §6.606 废枪 4 次从未拿到数据。详见 `kmod/w1221_mechanism_audit.md`。

## 收口（关窗铁律）
`go.sh` 自行走完第 8 步并 `[EXIT 兜底]` 复原两份 args = `fec3d301`。窗口本发**是活的**（`enf=Permissive`），故主动 `adb reboot` 收口：
复位后复证 **`boot=d6939ad5`、`mod=0`、`Enforcing`、无 `/dev/ksud`** ⇒ MAC 随复位恢复，与第 15/16 枪同路。poll 见到 mod=1 后连续 OFFLINE，自行写"收工"行退出（840 行）。
残留 `/data/local/tmp/kd`、`/data/adb/ksu/.allowlist` 未清（惰性、无模块即无意义，下次开窗顺手清）。

## 状态
真机 **1 枪**（本会话 sucompat 实验序列第 17 枪）；`/sys/fs/selinux/load` 累计 **0 写入**；出货包 `z6root.zip` 与交付两件**一字未动**（仍是 rc78+0x1a 的旧形状，待换包）。
