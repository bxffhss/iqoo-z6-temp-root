# 现状对账 (STATUS RECON) — 2026-09-26 · READ-ONLY 汇总

**TL;DR 现状**
1. 权威入口 = `CONTINUE_HERE.md` + `CURRENT-STATUS.md` + `GAP-TO-ROOT-20260924.md`；`HANDOVER-20260925.md` 顶部自带"⛔ 本文已失效"横幅，根目录 `README.md`(09-09) 已过期 ⇒ 两者都不可当现状 (`MEMORY.md` 焦点节、`REACHABILITY-PIVOT` 顶部自我纠正)。
2. A GhostLock：ghost 机制/KASLR/KernelSnitch/SLUB 喷射全部真机成立；卡点 = **栈覆盖通道结构性不可达** (`GHOST-TRIGGER-SOLVED` §14/§15)。
3. B CVE-2025-38352：窗口稳定复现 (20/200k)，但 300k 长跑 30 次 probe 全健康 ⇒ **判死"分支无害"** (`CVE38352-PORT-PLAN` §57/§59.5)。
4. C HID OOB = 受控**零写**，六条升级路径逐一关闭 ⇒ 辅助资产，不能单独提权 (`kgsl_audit_03` §71)。
5. D KGSL：**CP 永不访问属于我方上下文的 GPU 内存** ⇒ 判死 (`CURRENT-STATUS` §AI、`KGSL-NOEXEC-P0` §12 P21)。
6. 活跃战线 = **GhostLock + binder CVE-2026-64468/64469 双主线**，落点换 ION dma-buf (`REACHABILITY-PIVOT` §15/§6)。

## 1. 战线清单
| 线 | 真机已证 (工件) | 精确卡点 | 终判 |
|---|---|---|---|
| **A GhostLock / CVE-2026-43499** | perf 破 KASLR slide `0x264f200000` + 全符号标定 (`CURRENT-STATUS` §3.1/3.2)；KS 泄漏 `mm=0xffffff8ede3acec0` 15/15 (`GHOSTLOCK-5.4-PORT` §KS 终判)；**pselect ghost = 悬空 `task->pi_blocked_on`**，真机 `CMP_REQUEUE_PI errno=35(EDEADLK)` (`GHOST-TRIGGER-SOLVED` §1)；punch 确会 deref 我方数据、已能把内核打崩 (`§6`, `ghost_probe`/`ghost_scan`) | 覆盖层深度无交集 (§2) ⇒ 无受控写 | **alive-but-parked**：stack-overlay 版判死，须走非栈写通道 |
| **B CVE-2025-38352** | 触发可复现：`cve38352b` 6 实例 40–60s 必崩 + 严格 A/B (`analysis/SESSION_HANDOFF` §A/B 实验)；首次合法 UAF **WIN=1** (`PORT-PLAN` §40)；窗口 20/200k、窄带 372–608µs 稳定 (`§57.1`) | 收割语义已解决；剩"腐坏静默"：del 写的是 freed-but-intact 内存，probe (同 slab 复用校验) 30/30 健康 | **dead** (`§57.2`)；复活条件 = 证明腐坏点在 fire 侧 |
| **C HID OOB write** (`uhid`→`mt_get_feature`) | memset(0) 越界精确清零相邻 kmalloc-128 前 K 字节、37%/发；`/proc/net/unix` 消失 + bind 抢占双 oracle；已触及 SELinux `sk_security_struct` (`analysis/SESSION_HANDOFF` 第二/三轮) | 只能写零；`selinux_socket_sendmsg` 的 sid==1 放行快路径需写非零 | **dead as priv-esc / alive as aux asset** (`kgsl_audit_03` §71.3) |
| **D KGSL/Adreno** | app 域全链 ioctl (ctxt `flags=0x12`/gpuobj/mmap/submit len 0x38) + **IB 边界不校验源码级确认** (`CURRENT-STATUS` §AD/§AF.6) | retire 纯软件记账、`gpubusy=0/0`、marker 0 命中；P21 用驱动自身合法 244B 命令流重定向仍失败 ⇒ 对象归属 (`KGSL-NOEXEC-P0` §12) | **dead**；复活条件见 §12.3 |
| CVE-2026-21385 | gpuaddr=0x0 异常可复现 (`CURRENT-STATUS` §3.5) | 需 GPU 访问被破坏 VA (回落到 D)；设备已有 align clamp | **归档** (`PORT-PLAN` §95, Day 39) |
| CVE-2025-37804 io_uring | — | NVD REJECTED (KCSAN 数据竞争)；app 域 `io_uring_setup` 被 seccomp SIGSYS | **dead** (`PORT-PLAN` §58.1；`REACHABILITY-PIVOT` §12) |
| CVE-2025-37790 mctp | 只列"待查" (`HID-MT-AUDIT` §28.4；`GAP-TO-ROOT` §1-D) | `devinfo/config-5.4.281-qgki.txt` 无任何 `CONFIG_MCTP` 项 ⇒ 未编译 | 未按正式流程判死；配置层面不适用 |
| CVE-2025-27038 | — | 高通 2025-06 受影响列表不含 SM7325 | **dead for this device** (`§58.2`) |
| CVE-2025-21479/21480 | Day1-16 逆向、`[entry+0xf0]` 语义+写入点全定位 (`§66–§70`) | 两条 UAF 时序被同锁+refcount 封死；腐坏点疑在闭源固件 | **parked** (`§71`) |
| CVE-2024-36971 dst UAF | — | 清除窗 ~2ns vs RCU µs-ms | **dead** (`CONTINUE_HERE` §69) |
| **binder CVE-2026-64468/64469** | 静态：`binder_free_transaction@0x10f5eff8` 首条即 `ldr x22,[x0,#0x38]` 且不持 `t->lock`；回移矩阵不含 5.4 (`BINDER-2026-…`) | 竞态窗口/spray 未评估，未触发；触发有 oops 风险需批准 | **ALIVE — 并行第二条** (`REACHABILITY-PIVOT` §15) |
| 2024-46740 / 2026-31415 / 64563 / 74567 | guard 在 / 码在 | 已修 / `ns_capable(CAP_NET_RAW)` 且上限只 `skb_under_panic` / sock_diag+TIPC 被 SELinux 拒 / keyctl 被 seccomp 杀 | **dead** (`REACHABILITY-PIVOT` §11/§14/§12) |

## 2. A 线覆盖层卡点（精确）
- 需求：悬空 waiter 在 `S0-0x298`；**最小需覆盖深度 [0x288,0x298] 的 3 个 qword (tree.pc/right/left)**，保险 [0x258,0x298] 共 0x40 字节 (`GHOST-TRIGGER-SOLVED` §3/§9/§14.1；`GHOSTLOCK-5.4-REVIEW` §1 实测端点差 0x88)。
- 已枚举通道最大 δ (`§7/§10/§14.2`)：readv 0xE8 · vmsplice 0xC8 · `do_timer_create` sigevent ≈0xD0 · uinput `UI_DEV_SETUP` ≈0x168 · kgsl ioctl ≈0x178 · sendmsg ≤0x1B0 · recvmsg 0x170 / recvmmsg ≈0x1D0 · select 0x1F0 · tty `TCSETS` ≈0x208 · **pselect6 0x210（可控仅 0x78，n 再大转 kmalloc ⇒ 结构性上限）** · ppoll 0x3D0 **够深但不可用**（`do_pollfd` 无条件写 revents ⇒ 指针高 2 字节被毁，`k54src/fs/select.c:870`）。
- 32-bit compat 被证伪：`__arm64_sys_futex_time32` 帧 0xC0 (同 native)、`compat_core_sys_select` 帧 0x1C0 (同)、compat pselect6 只是 0x10+0x10 薄壳 ⇒ waiter 仍 0x298、fd 区 ≤0x220，几何零收益 (`§12/§15`)；"restart 深度路径"在 5.4 不存在 (`futex_wait_requeue_pi` 无 restart 武装，被打断走 `-ERESTARTNOINTR` 同深度重放, `GHOSTLOCK-5.4-REVIEW` §2)。
- **GAP-TO-ROOT §2 的 (a)–(d) 现状**：**(a)** 09-24"未系统排查"，09-26 由 binder 64468/64469（kmalloc-192 slab UAF + Write of size 8，`/dev/binder` 零特权）**认领为候选实现，仅静态、未触发** (`REACHABILITY-PIVOT` §15；`MEMORY.md` 焦点)。**(b)** 换产生悬空 `pi_blocked_on` 的路径：未做，只留 TODO"审计 `remove_waiter` 清错任务的其他调用点"(`§13-D`)。**(c)** 把 punch 当 info-leak：明确"未探索"，且已实测反复 punch 会 panic (`§6`)；`MEMORY.md` 判定 **`p26_gl` 检测器不必再跑（信号已知 + oops 风险）**。**(d)** 系统排查剩余内核对象的函数指针：未做。**已否决的变体**：只覆盖 prio/deadline 不动指针的兜底 (`§11-C`)、"找 ≥3 层嵌套深栈拷贝驱动" (`§11-B/§13`，kgsl/uinput 实测太浅)。

## 3. B 线现状
"收割语义"**已不再是卡点**：`§36` 诊断 `waitpid(leader_tid,__WALL|WNOHANG)` 立即 ECHILD ⇒ `§37` 根因 **`delay_group_leader()`**（组 leader 退出而组内有存活线程 ⇒ 内核不报告僵尸）⇒ 收割对象必须是**非 leader 线程**；`§39` 改**阻塞式 `waitpid`** 使收割延迟 424ms→0ms；`§40` 拿到真 WIN=1 (p≈0.08%)。未决项转为 `§52.2/§55.1` 的"**腐坏在哪一侧**"：fix 仅加 `if (tsk->exit_state) return;` ⇒ 被修路径是 zombie 上 fire 继续 + 周期定时器 re-arm 写回 freed `signal_struct` bases；del 侧可能只是安全返回。probe 30 次采样全健康 ⇒ 终判 dead (`§57.2`)。**chronomaly 原版 `exploit.c` 已读过**：`§18`（第九轮，三处关键差异），其 `sigqueue_crosscache_preallocs/postallocs` 亦在 `§788/§1076` 被引用为照抄对象 ⇒ `GAP-TO-ROOT` §3 的"去读原版 do_wait/ptrace"已执行完毕，勿再列为待办。

## 4. 配置地雷（已定论）
- `DEBUG_LIST=y` + `BUG_ON_DATA_CORRUPTION=y` (`devinfo/config-…txt:6890/6999`) ⇒ list 操作型 UAF 的写原语先触发校验 ⇒ chronomaly 打法被封 (`CONTINUE_HERE` §E)；LG webOS"单次任意写"变体仍需过校验，**未实测** (`GAP-TO-ROOT` §5)。
- `SLAB_FREELIST_RANDOM+HARDENED=y` ⇒ 同 cache poisoning 需 `s->random`，本机无内核读通道 ⇒ 死锁 (`§H`)。
- `# SLAB_MERGE_DEFAULT is not set` ⇒ **有利**；`CONFIG_HZ=250` ⇒ tick 4ms，用投递成本不等式"信号数×entries×32ns ≪ tick"补偿 (`PORT-PLAN` §30)。
- `POSIX_CPU_TIMERS_TASK_WORK` 在本树不存在 ⇒ 5.4 必走 IRQ 内联路径 ⇒ B 结构上可触发（有利），亦是"未修复三重证据"第 2 条 (`NEW_SESSION_BRIEFING` §2.2)。
- `INIT_ON_ALLOC_DEFAULT_ON=y` ⇒ ION/页池不是泄漏源，**别再试** (`REACHABILITY-PIVOT` §9)；`ARCH_DMA_MINALIGN=128` ⇒ kmalloc 最小 cache 128B；CFI/SHADOW/SCS/PAN/PAC/RANDBASE 全在、**无** `randomize_kstack_offset`（对攻击者有利）、**无** `USER_NS` (`§4`)。
- 矛盾记录：`analysis/SESSION_HANDOFF` 第九轮实测 **panic_on_warn 未生效**，而 `kgsl_audit_03` §71.2 的部分判死以"WARN→panic 重启"为前提 ⇒ 引用时只采信其源码级推导。

## 5. 已 SETTLED + 设备工件
已定论（勿重推）：userns/CapEff=0/SYSV ENOSYS/af_alg/RDS/nft 五门禁；DirtyPipe 已修 (`kernel-lpe-conclusions` §S.4)；反向补丁重筛 5.4.282→302 与 278→281 双闭环 (`CONTINUE_HERE` §69.5/§70)；vendor ioctl ~320 万次模糊零崩溃 (§72)；netlink/genl 被 SELinux 拦 (§73)；kgsl 43 handler 测绘 + fence 生命周期干净无双重释放 (§3.4/§Y)；`file = VA − 0xffffffc010080000`；2026 热门 LPE 家族批量排除；铁律（阴性对照 / O_SYNC+fsync / uptime+`ro.boot.bootreason` / push 后 chmod 755）；`kill_tests.sh` 会删测试文件；换设备清单 = `vendor-old-retry-checklist.md`。
前任工件（`/data/local/tmp`，626 文件）：`ghostlock*`、`ghost_probe`、`ghost_scan`、`ghostbuild/src/core/{main.c,fops.c,pipe.c,root.c,common.h,offset.h,miniadb.c,kernelsnitch/}`、`gl54.so`、`preload.so`、`kgsl_root1/2/3`、`.ghostlock_root.sh`、`.ghostlock_fixpol.sh`、`ks_test3`、`cve38352*`。
日志：**文档点名过的只有** `ACC.log`/`ACC2.log`（38352d/e 累积，`PORT-PLAN` §885/§1414，结论已汇总在 §40）、`e1.log`/`e2.log`/`d1.log`（38352f 100k/200k 长跑，**数字已完整写入 §53–§59**）、`gs.log`（ghost 覆盖层/punch，`GHOST-TRIGGER-SOLVED` §6）、`gl.log`/`glRUN.log`/`kst.log`（GhostLock 运行，判读口径在根 `SESSION_HANDOFF.md` §10）、app 域 `trace5.txt`（`run-as com.poc.probe`）。`A.log`…`FINAL.log` 与 `bal.log` **在任何文档中都没按名字引用** ⇒ 需靠内容识别；若属 38352 长跑族则已被 §57 汇总，优先读 `gs.log` 与 `glRUN.log`（覆盖层与 KS 一手行）。

## 6. 文档间矛盾（不抹平）
1. `HANDOVER-20260925`（KGSL in-flight 为战线）vs `GAP-TO-ROOT`（A/B 双线）：作者用顶部失效横幅自行撤销前者并改指 `KGSL-NOEXEC-P0`。两位作者意图的权威 = `CONTINUE_HERE`+`CURRENT-STATUS`+`GAP-TO-ROOT` (`MEMORY.md` 第 6 行、`REACHABILITY-PIVOT` 顶部)。
2. B 线三口径：`CONTINUE_HERE` §E–H（09-22）称 cross-cache 已封死/38352 全套证伪；`GAP-TO-ROOT`（09-24）称 B 为主战场、距 root 6–9 会话；`PORT-PLAN` §57（09-25）终判 dead ⇒ 一手文本是 `PORT-PLAN`。其内部 §38"正式归档"与 §40"改回活跃"、重复的 §37.3 编号亦属自我推翻 ⇒ 按最大编号读。
3. A 线：`GHOST-TRIGGER-SOLVED` §14/§15 关闭 stack-overlay，但 09-26 的 `MEMORY.md`/`REACHABILITY-PIVOT` 仍称 GhostLock 为"主链"并沿用 pselect 栈回收 ⇒ **未调和**；合规读法：A 仅当接上 §2(a) 非栈写通道（现指 binder）才成立。
4. 环境：`CURRENT-STATUS`/`NEW_SESSION_BRIEFING` 记 vendor SPL 2024-02，`PORT-PLAN` §58.3 修正为 **SPL 2025-04-01** 且 `CONFIG_IO_URING=y`（非"被裁剪"）⇒ 采后者的校准（判据"修于 5.4 EOL 之后 + app 零特权可达"见 `REACHABILITY-PIVOT` §11）。
5. 根 `README.md`(09-09) 的"race 10/10 成功 / `fake_fops` 已写 `ashmem_misc.fops` / slide=0x28000000 / `oem_unlock_allowed=1`"均被后续推翻（slide=0x264f200000；app 侧 ashmem mmap 一律 EPERM ⇒ 落点须换 ION；BL locked 且 `oem_unlock_allowed=0`）⇒ 只可当历史。
