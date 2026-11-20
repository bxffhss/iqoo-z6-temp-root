# GHOST-PUNCH-LEAK-AUDIT — 2026-09-26 (READ-ONLY 汇总)

范围: 只读审计本机 GhostLock 线现有"可观测/已泄漏"能力，为选项 (c)（把 punch 当 read oracle）决策提供依据。标签: 【文档】=写进 md 的结论 · 【代码】=ghostbuild/cm54 源码实现 · 【真机】=hardware 实测证据。

## TL;DR（5 行）
1. **我们现在没有任意内核地址 READ。** 代码里有完整任意读原语 `configfs_read_once`/`kernel_read64`【代码: gb_src/util.c:821, cm54/fops.c:259】，但它以 fake_fops 被写入 `ashmem_misc.fops` 为前提；本机 5.4 该写入从未落地（`cfi step4: pre_rb=0`【真机+文档: GHOSTLOCK-5.4-PORT 流状态表】）。
2. 现有读能力只有两路指针级 side-channel: `perf` 破 KASLR base（2MB 相位）+ KernelSnitch 泄漏 `mm_struct`（linear-map 指针），都是"值泄漏"，不是可寻址的内存读。
3. Ghost 机制、punch 必中、SLUB 喷射 = 真机成立【真机: GHOST-TRIGGER-SOLVED §6】，但 punch 的 oracle 目前是 **1 bit（崩溃/不崩溃 + owner prio 变动）**，粒度远弱于 KS。
4. 卡点不是"缺读"而是"缺写通道"——链走需覆盖栈深 [0x288,0x298] 的 3 个 qword，被证明结构性不可达（death zone）【文档: GHOST-TRIGGER-SOLVED §10/§14/§15】。
5. **判定: (c) 与已有 KS/perf 高度重叠且更脆，不能兑现项目真正缺的东西（受控内核写），不推荐优先投入。**

## Q1 — 链走 hit 伪造 waiter 时的 deref 与决策
`rt_mutex_adjust_pi`→`rt_mutex_adjust_prio_chain`（requeue 分支）【文档: GHOST-TRIGGER-SOLVED §2/§9；GHOSTLOCK-5.4-REVIEW §3】。顺序:
- READ: `waiter = task->pi_blocked_on`；`rt_mutex_waiter_equal()` 仅比 **waiter->prio**（≠ punch 后 task->prio 才继续）；`next_lock = waiter->lock`（第一次 deref 我方数据）；`prerequeue_top = lock->waiters.rb_leftmost`；`if(!rt_mutex_owner(lock))`→读 `lock->owner`；`task = owner`；`raw_spin_lock(&task->pi_lock)`；`task_blocked_on_lock(task)`。
- WRITE: `rt_mutex_dequeue(lock,waiter)`→`rb_erase_cached(&waiter->tree_entry)`→`__rb_change_child`+`rb_set_parent_color`（写 `parent->rb_left/right = child|color`）；`rt_mutex_enqueue`→`rb_link_node` 重写 tree_entry；`rt_mutex_dequeue_pi(task,pre)`→`rb_erase_cached(&pre->pi_tree_entry,&task->pi_waiters)`；`rt_mutex_adjust_prio`；正常退出路径 `remove_waiter` 的 `current->pi_blocked_on=NULL`；fast-path `cmpxchg lock->owner`。
- 结论: 两次 rb 手术 = 两次潜在任意写；被读的 prio/lock/task 字段可作为**探测谓词（READ 侧）**，这正是 (c) 想利用的分支。

## Q2 — punch 必中在实践里怎么被"探测"到
- ghost 存在: `CMP_REQUEUE_PI ret=-1 errno=35(EDEADLK)`【真机: GHOST-TRIGGER-SOLVED §1；ghost_probe.c:251】，owner 释放后 `*f_pi_target == waiter_tid`【ghost_probe.c run_cycle_deadlock "判决性 oracle"】，及 owner `/proc/<tid>/stat` 第18字段 prio 被 PI 提升【GHOSTLOCK-5.4-REVIEW §3】。
- **punch 命中我方数据** = 毒值 oracle: `ghost_scan.c` 每轮在缓冲偏移 k 放 `0x4141414141414141`，punch 后内核 deref → **oops/panic**（`uptime` 复位 + `ro.boot.bootreason=HARD_RESET/PS_HOLD`）【真机: GHOST-TRIGGER-SOLVED §6；ghost_scan.c POISON】。⇒ 当前 oracle 粒度 = **1 bit（崩/不崩）**，附带 owner-prio 的少量值信息。反复 punch 会把设备打崩（§6）。

## Q3 — KernelSnitch 现在给什么
- 区域/粒度: 只泄漏 **`current->mm_struct` 一个内核指针**（arm64 linear/identity map `0xffffff8000000000`，`IDENTITY_START`）【代码: kernelsnitch.h VA_BITS=39；文档: GHOSTLOCK-5.4-PORT §KS终判】。方法 = 用 `futex_hash(futex_addr, mm)` 的 hash-bucket 命中**计时 side-channel**：piled bucket + best-8-of-128 平均延迟（~9× 对比度）+ 15/15 碰撞等式联立解出 mm【文档: §KS 四坑；代码: `__measure`/`__mm_leak`】。非按字节读内存，是**指针反推**。
- 代价: 全 VA `[VA_START, 2^32-4GB)` @0x40 步长 ≈86 亿候选，16 线程 10–60s；每 probe 128 次测量。
- 本机限制: VA_BITS=39+4K 页⇒扫描空间反而缩小（有利）；**SW_TTBR0_PAN/kCFI/SCS/PAC/SLAB_FREELIST_HARDENED 对 KS 无影响**（它不访问内核内存、不解 freelist）；`INIT_ON_ALLOC_DEFAULT_ON=y` 只关闭"页内容残留泄漏"这条路，不影响 KS。**KS 泄漏的是 exec 出去的 ks_test3 的 mm，非 exploit 自身**【文档: §KS-integ】。
- **明确回答: KS ≠ 任意地址读；它只给 1 个指针值。** 真正的任意读（`configfs_read_once` 走 fake_fops+ashmem/configfs 叠置）【代码: util.c:821, fops.c:259-263 leak_kernel_base】**在本机从未跑通**，因为它依赖的写原语就是死亡区卡住的那一步【真机: cm54/fops.c:317-324 step4 fail】。

## Q4 — KASLR/base-text 泄漏
`perf_event_open` 软件采样（`PERF_TYPE_SOFTWARE/CPU_CLOCK`, `exclude_user=1`, `PERF_SAMPLE_IP`）采内核 IP，按 128KB 块聚类取最密 44 块窗（避开 module text 污染），解 `[stext,etext)`→ 2MB 相位唯一 base【代码: cm54/slide.c:144-270；文档: GHOSTLOCK-5.4-PORT §3；STATUS-RECON §1-A】。**粒度 = base kernel text（2MB 对齐 slide）+ 全部符号（用 `embedded-kallsyms.txt` 偏移推导）**；真机 `slide=0x264f200000`【STATUS-RECON §1】。注意 slide.c 只给 base，不含堆/mm——那是 KS 的活。（另 `gb_src/main.c:348 perf_find_task()` 用 `PERF_SAMPLE_REGS_INTR` 采寄存器值反推 task_struct 指针【代码，未在本机验证，且受 seccomp 阻断风险】。）

## Q5 — 到"受控内核写改 cred"的缺口
| SOLVED（真机） | MISSING（真正卡点） |
|---|---|
| KASLR base + 全符号（perf） | 把攻击者字节写进栈深 [0x288,0x298] 的**通道**（death zone，已证结构性不可达 §14/15） |
| mm/linear-map 指针（KS） | 因而 fake_fops 从未安装 ⇒ **任意读 & 任意写两把原语都没到手** |
| ghost 形成 + punch 必中（1-bit oracle） | 跨-cache 目标对象堆地址确定性（KS 只给 mm，不给 cred/task 目标） |
| SLUB 喷射、工具链 elf_reloc_lookup | 一个 value-controllable 的写 *channel*（非栈）——现由 binder 64468/64469 认领，仅静态、未触发【STATUS-RECON §15】 |
⇒ 缺的不是"读"，是"能落位的写"。(c) 试图补的正是**已经不缺的**读侧。

## Q6 — 文档 vs 代码 vs 真机 的矛盾（不抹平）
1. 根 `README.md`(ghostbuild, 09-09) 声称 "race 10/10 / fake_fops 已写入 ashmem_misc.fops / slide=0x28000000" → 已被 §14/§15 与 STATUS-RECON §5 推翻（slide=0x264f200000，app 域 ashmem mmap 一律 EPERM，step4 从未过）【文档自我声明为"仅史料"】。
2. 设备侧 `ghostbuild/src/core/*` 时间戳 09-08/09 = **原版(6.x) exploit**（main.c W1/W2 + configfs read/write 全套），非 5.4 移植（`cm54/`, 09-24）。凡引"任意读已实现"须限定为**原版代码存在、本机未运行**。
3. `kernel_read64` 失败返回 0 与真值 0 不可区分——正是项目老坑"读不到 ≠ 值为0"的复现点（`util.c:849` 用 `n!=sizeof` 才判失败，但 `leak_kernel_base` 对返回 0 走 `kaslr_step=1` 静默重试）；(c) 的 oracle 设计必须先解决这一歧义。
4. slide.c 头部把 perf 记为 "KASLR 泄漏"，而 `kernel-lpe-conclusions §44` 对同一手法标注"非 KASLR infoleak"——两处口径冲突，采 cm54/slide.c 的实际行为（确为 base 解算）。
5. ghost_probe "prio 提升即 ghost 存活" 是旁证非直证【GHOST-TRIGGER-SOLVED §5 自述"还缺不破坏 ghost 的 oracle"】——(c) 想要的恰恰是这个 oracle，但 §6 已示: 反复 punch 会 panic。

## 对 (c) 的判定
**与已有能力重复、且兑现不了缺口 → 不推荐优先投。** 理由: (a) KS+perf 已覆盖"指针/base 泄漏"，punch-read 至多给一个比 KS 更脆、有 panic 风险的 1-bit/prio-值 oracle；(b) 项目真缺的是**非栈写通道**（fake_fops 未落地才导致读写两把都缺），(c) 不补这一步；(c) 唯一独立价值 = "若把 waiter->lock/task 指向候选内核地址、用 owner-prio 是否被提升当谓词"可作**粗粒度指针 probe**，但这恰好需要 ghost 存活 oracle（§5 未解）且与 KS 的 hash-probe 目标重叠。
**建议顺序**: 先补 §Q6.3（区分"读不到/0"的判据）与 §5 "ghost 存活不崩 oracle"这两块前置；若只是为了拿基址/堆指针，**继续用 KS/perf 而非 (c)**；把工程预算留给 binder 非栈写通道（STATUS-RECON §15 / REACHABILITY-PIVOT §15）。
