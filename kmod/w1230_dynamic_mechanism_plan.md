# w1230 — 动态 trace 定位 sucompat 致死微机制（预登记）

> 上游：§6.614（反汇编证"调用内部无凶手行"）+ §6.615（速率阈值 (0.2,9.7)/s ＋固定引信 19.5 s 收紧为"间接/系统性"）。
> 目的：用 ftrace 在 cut=5 ko 致死窗内抓"死前到底卡在哪"，把"CPU 压力→看门狗"的**推断**升格为**根因**。
> 性质：设备实验（cut=5 必在 ~19.5 s 硬复位）。按 AGENTS.md 铁律：一次开机一枪、I_KNOW=1、设备零接触直到开枪、关窗铁律、不留过夜。

## 0. 假设（待证）
- 允许_uid 调用在 execve 热路径以 >~5/s 执行 → 每发 hook 开销累积成 CPU/调度压力 → psi 单调爬升 → 硬件看门狗 PS_HOLD 复位。
- 证伪方向：若 ftrace 显示调用单发延迟随时间**不涨**（恒 ~1μs）而 psi 仍涨 ⇒ 纯聚合压力（无单点stall）；若延迟**涨到 ms 级** ⇒ 有具体瓶颈（cache/锁/RCU）。

## 1. 仪器
- `kmod/kernelsu_cut5.ko` (`dead549f…`) + `kmod/ksu_args_cut5.txt` (`0aa87e9b…`)：执行 allow_uid 调用、~46/s 深路、~19.5 s 死；`/proc/ksu_ser` 输出 `SERD CUT5`。
- 设备侧 ftrace：`/sys/kernel/tracing`（已核实挂载可读、`buffer_size_kb=1410`、有 `nop`、`function_graph`/`function` 标配）。
- PC 侧：`kmod/w1231_ftrace_capture.sh`（设 tracer＋每 1 s 抓 `/sys/kernel/tracing/trace` 快照环形缓冲）+ `kmod/w1223_deathbed_sampler.sh`（每秒 psi/load/mem/`/proc/ksu_ser`）。

## 2. 步骤（一次开机一枪）
1. **开窗**：GhostLock 临时 root 开窗（同方向连续验证，不需再问；但开枪仍需 I_KNOW=1）。
2. **ftrace 设局（insmod 之前）**：`w1231` 执行
   - `echo 0 > tracing_on`
   - `echo function_graph > current_tracer`
   - `echo 1 > max_graph_depth`        （限深，省缓冲）
   - `echo '__ksu_is_allow_uid_for_current:mod:kernelsu' > set_ftrace_filter`（同加 `__ksu_is_allow_uid` / `ksu_handle_execve_sucompat_common`）
   - `echo 1 > tracing_on`
3. **起 PC 抓取循环**：`w1231` 后台每 1 s `adb shell cat /sys/kernel/tracing/trace` 落盘带时间戳（环形缓冲＝死前最后一瞬）。
4. **开枪**：`ARGS_FILE=kmod/ksu_args_cut5.txt KO=kmod/kernelsu_cut5.ko I_KNOW=1 bash kmod/go.sh`（同时起 `w1223`）。
5. **等待 ~20 s**：cut=5 必在 ~19.5 s 硬复位；`w1231` 抓到 adb 掉线即停（落盘快照已含死前）。
6. **复位后复核**：`adb` 重连 → `lsmod`/`getenforce`/`ls /dev/ksud` ⇒ 期望 `mod=0`/`Enforcing`/无；确认无残留装载。
7. **收口**：按 `w161_teardown.sh` 复核（设备已随复位自然收口；若 go.sh 残留 args 形态，`cp ksu_args.txt.bak_delivery ksu_args.txt` 核 md5）。**不留过夜**。

## 3. 可选安全校准（先跑，不死）
- 用 `ksu_args_cut5.txt` 只把 `ksu_exp6_rate=200`（decline 0.2/s，活 ≥1384 s）跑同样 ftrace，抓调用单发延迟基线（应恒 ~1μs），验证 ftrace 探针不显著改变形状。

## 4. 判据（两种结局都算"测到"）
- **甲｜延迟不涨、psi 涨**：纯聚合 CPU 压力 → 根因＝"arm 该调用的 hook 每发开销在设备自然速率下不可承受"，无单点 bug，关线铁证。
- **乙｜延迟涨到 ms 级 / 死前停在某个子句**：定位到具体瓶颈（cache 行伪共享 / RCU / 某读），给出"哪一行的开销在涨"。
- **失败**：ftrace 缓冲在复位前已全清/不可读 ⇒ 改 `function` tracer 或加大 `buffer_size_kb` 重测（同预登记，不另立）。

## 5. 边界（别外推）
- 本实验只证"改造树里 sucompat 为什么死"，**不改变交付**（0x2 无可用速率窗口，稳定走 rc80+0x0）。
- 看门狗是 hardlockup 探测还是硬件 WDT、引信 19.5 s 对应哪个超时——若 ftrace 抓到死前最后瞬间停在哪，顺带可定。

## 6. 登记值（现读，粘贴）
- ko `kernelsu_cut5.ko` = `dead549fbe702a080108e65fa96407ac`（已 §6.612 登记）
- args `ksu_args_cut5.txt` = `0aa87e9b…`（已 §6.612 登记）
- 设备 `<DEVICE_SERIAL>`、SN 已登记。
