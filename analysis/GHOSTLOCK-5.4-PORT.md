# GhostLock (CVE-2026-43499) 5.4.281 移植记录 — PD2220A (iQOO Z6)

日期: 2026-09-22/23 深夜。源: NebuSec/CyberMeowfia IonStack exploit (cm/ = 原版, cm54/ = 5.4 移植)。

## 1. 机制全解码 (对照 5.4.277 源码)

**任意读写原语 = ashmem fake-fops + configfs_buffer 叠置**:
1. 链走 (rt_mutex_adjust_prio_chain) 中 `rt_mutex_dequeue_pi(fake_task, W0)`: W0.pi
   = {pc=fake_fops, right=&ashmem_misc.fops, left=0} 视为 rb 节点从
   fake_task->pi_waiters (root=NULL) 摘除 → 单右子路径 →
   `__rb_set_parent_color(&ashmem_misc.fops节点, fake_fops, black)`
   → **ashmem_misc.fops = fake_fops** (miscdevice.fops @ +0x10)。
2. 新 open("/dev/ashmem") → misc_open → fops_get(ashmem_misc.fops) = fake_fops。
   fake fops: .open=ashmem_open (private_data=ashmem_area*) + .read/.write =
   configfs_read_bin_file / configfs_write_bin_file。
3. ashmem_area.name[11..] 由 ASHMEM_SET_NAME 的 strcpy 写入 (strncpy_from_user,
   NUL 截断 → 需要零字节 dance)。configfs_buffer 叠置于 ashmem_area:
   page@0x10, needs_read_fill@0x40, read_in_progress@0x44, write_in_progress@0x45,
   bin_buffer@0x48, bin_buffer_size@0x50, cb_max_size@0x54。
   blob[i] → as+11+i (字段 F 的 blob 下标 = F-11)。
4. **写**: bin_buffer=target, bin_buffer_size=len, cb_max=0, pwrite(fd,data,len,0)
   → *ppos+count <= bin_buffer_size → 不触发 vmalloc 重分配 →
   simple_write_to_buffer 直写 target ✓ (5.4 与 6.x 关键差异: 必须防 realloc)。
5. **读**: needs_read_fill=0, bin_buffer=target, bin_buffer_size=0x40000000,
   pread → simple_read_from_buffer ✓ (5.4 读路径用 bin_buffer 而非 page, 与 tokay 不同)。
6. mutex@0x20 (owner=0 → lock 走 cmpxchg 快路径; unlock 走 __mutex_unlock_fast
   cmpxchg) — wait_list=NULL 不触碰 ✓ 5.4 有快路径 ✓。
7. 每次 op 重新 SET_NAME → read/write_in_progress 复位 ✓ 同一 fd 可无限读写。

## 2. 5.4.281 偏移 (全部反汇编确认, derive_offsets.py/dis_symbol.py)

### 符号 (off = VA - 0xffffffc010080000)
init_task 0x28AE200, root_task_group 0x2AAB450, selinux_state 0x2A98000
(**enforcing = state+1** — DISABLE=y, sel_write_enforce strb [x21,#1]; 旧脚本 0x2A98000 差 1 字节),
security_hook_heads 0x21AB480, kmalloc_caches 0x21AAFD8, anon_pipe_buf_ops 0x20AADB8,
ashmem_misc 0x29D5960 (fops +0x10), ashmem_fops 0x2152528,
ashmem_ioctl 0xE6E780 / compat 0xE6ECE4 / mmap 0xE6ED38 / open 0xE6EED8 /
release 0xE6EF68 / show_fdinfo 0xE6F0C4 / llseek 0xE66634,
configfs_read_bin_file 0x5BE400, configfs_write_bin_file 0x5BE5B8,
noop_llseek 0x4F97A8, random_table 0x29658A8, nfulnl_logger 0x27BAAE0, loggers 0x27C4A50。
边界: _stext +0x1000, _etext +0x15A0000 (text 21.6MB), _text mod 2MB = 0x80000。

### task_struct (commit_creds/adjust_pi/setprio/copy_process/sched_show_task 等反汇编)
thread_info.flags 0x00 (TIF_SECCOMP=11, 实测 stset #0x800), state 0x60, **usage 0x70**
(adjust_pi 内联 get_task_struct ldxr), atomic_flags 0x658 (prctl PFA_NO_NEW_PRIVS=0),
dl.deadline 0x468, tasks 0x590, pid 0x690, tgid 0x694, group_leader 0x6D0,
sched_class 0xC8, normal_prio 0xBC, **prio 0xB4**, real_cred 0x840, cred 0x848,
comm 0x858, signal 0x888, sighand 0x890, seccomp 0x8F8 (mode@0, filter@8 —
**5.4 无 filter_count**, root.c 已适配), alloc_lock 0x918, **pi_lock 0x91C**,
**pi_waiters 0x928/0x930** (rb_root_cached), **pi_top_task 0x938**,
**pi_blocked_on 0x940**, exit_state 0x630, stack 0xB30, stack_refcount 0xCB8。

### cred
uid 4, securebits 0x24, caps 0x28 (5×8B), **security 0x78** (5.4: KEYS 4 指针后;
无 blob_sizes — root.c 硬编码 lbs_cred=0), user 0x80, user_ns 0x88, group_info 0x90。

### rt_mutex / rt_mutex_waiter (5.4)
rt_mutex: wait_lock 0x00 (u32), waiters{root 0x08, leftmost 0x10}, owner 0x18。
waiter: tree 0x00, **pi 0x18**, task 0x30, lock 0x38, **prio 0x40** (6.x 是
wake_state@0x40/prio@0x44 — 布局不同!), deadline 0x48。无 ww_ctx。

### 关键内核行为 (5.4 rtmutex.c/sched_core.c)
- adjust_pi: orig_waiter=NULL 进链走 → top_waiter=NULL 跳过 has_pi_waiters 检查;
  waiter_equal(waiter,task_to_waiter(task)) 必须 **不等** (伪 prio=119 vs 线程 120);
- [7] enqueue: 伪 waiter prio(119) < W0.prio(130) → leftmost=true → 成为 top ✓;
- [11] dequeue_pi→enqueue_pi→adjust_prio(fake_task): pi_task = 伪 waiter->task =
  text_addr(INIT_TASK); setprio 早退条件: fake.pi_top_task == pi_task &&
  prio == fake.prio (prio = min(normal_prio, pi_task->prio) = min(120,120)) ✓
  → 不触碰 rq/sched_class ✓ (FAKE_TASK_USAGE=0x100 保 get/put 平衡);
- __rb_change_child 写父槽位: fake_fops+0x10 (read 槽) ≠ 被摘节点 → 写 +0x08
  (llseek 槽) = &ashmem_misc.fops — **这就是 repair_fake_fops_llseek 存在的原因**;
  子节点(&ashmem_misc.fops) pc = fake_fops|black = **真正的任意写** ✓。

### slab / futex
mm_struct: sizeof=0x820 (proc_caches_init mov w1,#0x820), SLUB stride =
ALIGN(0x820,64) = **0x840** (HWCACHE_ALIGN), order-3, 15 objs/slab。
kmalloc: SLUB KMALLOC_SHIFT_HIGH=13 → 14 buckets;
5.4 **无 KMALLOC_CGROUP** (NORMAL=0, RECLAIM=1, [DMA]); pipe_buffer 0x28×32=800B
→ kmalloc-1k (index 10, order-3, 32 objs)。5.4 hash_futex =
jhash2(key[0..16), key->both.offset@0x10) — 与 kernelsnitch 用户侧实现一致 ✓
(futex_key 无 randstruct 打乱, key 布局 mm@0/addr@8/off@0x10 由 get_futex_key
反汇编三重确认, hashsize=2048 由 futex_init 反汇编确认)。

### ★★★ KernelSnitch 5.4 移植终判 (2026-09-23, 全链路真机验证)
**成功泄漏 mm=0xffffff8ede3acec0 (15/15 hash 等式全匹配, 假阳性概率 ~1e-50)。**
旧"成功值" 0xffffff8faf558000 = 3 等式判据下的假阳性 (期望 ~5 个/全空间扫描)。
四个致命坑 (全部修复):
1. **cntvct_el0 测量伪影**: 快速 syscall 探测读到 0 tick (baseline "9ns",
   flush 后 "21ns" — syscall 不可能 <100ns) → best-8-of-128 基线崩塌 →
   8×/50× 阈值全部失效。**必须用 CLOCK_MONOTONIC (vDSO)**。
2. **阈值物理**: 4096 pile 的真碰撞对比度 = 全遍历 ~13.7µs / 空桶 ~1.5-2µs
   ≈ 9× (CLOCK_MONOTONIC 实测)。预筛 2× (min-of-2, 尖峰免疫) + 精测 4×。
   50× 会把真碰撞筛掉, 低阈值会把冻结应用 bucket 放进来 → 鲁棒匹配
   (KS_MAX_FOREIGN=3, 15 个中 ≥12 个等式即可命中)。
3. **扫描范围**: mm 落在 VA_START(0xffffff8000000000)+63.9GB, 旧的
   64GB@0x840 网格恰好错过 (mm 不在 order-3 网格点: 0xacec0 mod 0x8000
   = 0x2ec0)。**必须全内核 VA 空间 [VA_START, 2^32-4GB) @ 0x40 步长**
   (SLUB 对齐下限), ~86 亿候选 16 线程 ~10-60s, 覆盖一切内核指针。
4. **成员资格证明 (实验 Z)**: flush pile (FUTEX_WAKE val=INT_MAX) 后
   幸存者延迟 13.1µs → 底噪, 600× 骤降 = pile bucket 成员铁证。
   pile 扩容实验: 4096→8192 等待者, 幸存者 13.7→35µs 线性缩放 ✓。
工具链: ks_test3 (cm54/build) — argv: [step] [order] [coll] [scan_start] [scan_end];
env KS_EXTRA_PILE / KS_FLUSH_PILE = 实验开关。

## §KS-integ. Exploit 集成 KS — exec 方案 (2026-09-24)

### 继承地址空间破坏 KS → exec 解法
exploit child 里跑 KS (无论 clone/fork + setup-in-parent 还是 setup-in-child、
kernelsnitch_param 直调、8/16 线程) **全部 MISS** (幸存者 timing 正确但
hash 等式全不匹配, best 3/13~4/36 = 噪声水平)。同 boot 孤机 ks_test3 命中。
**解法: KS child exec /data/local/tmp/ks_test3, parent 从 stdout 解析
"RESULT mm=" 行** → 每轮都命中 (exec 给全新 mm, 消除继承地址空间干扰)。
代价: 泄漏的是 exec'd 进程的 mm (非 exploit 自身), 但 exploit 只用该地址
作为 SLUB 布局参考 — 可接受。child exec 后即退出, memfd_leak 不可用
(已确认从不读写, 仅 open/close → 安全跳过)。

### post-KS NULL deref 修复 (3 处)
- util.c ~715: `kernelsnitch_cleanup(ks)` → ks=NULL (setup 移到 child) → 加 `if (ks)` 守卫
- util.c: `memfd_leak = open_memfd(child_leak)` → child 已死, Permission denied → 跳过
- util.c:702: `SYSCHK(close(memfd_leak))` → memfd_leak=0 时 close(0) 关 stdin → 加 `if (>0)`

### 匹配判据改进: 绝对阈值 KS_MIN_MATCHES
旧 `misses ≤ KS_MAX_FOREIGN(3)` 在幸存者中混入大量外来碰撞时失效
(exploit 环境 25-41 个幸存者, 真碰撞 ~16, 外来 ~10-25)。
新判据: `matches ≥ KS_MIN_MATCHES(8)` — 真 mm 匹配所有真碰撞 (~16),
错误 mm 匹配 ~0-2, 与外来数量无关。cluster filter 已删除 (外来慢于
pile 时会误删真碰撞)。kernelsnitch_last_addrs[16]→[64] (count>15 越界
写破坏相邻全局变量 = 之前 exploit MISS 的根因之一)。

### 完整流状态 (GL_BENIGN=1 验证 + 真实模式)
| 阶段 | 状态 |
|------|------|
| KASLR perf 泄漏 | ✓ samples≈10700 |
| KS mm 泄漏 (exec) | ✓ 每轮命中 |
| prepare_skb_payload | ✓ |
| main route (waiter/owner/consumer) | ✓ 线程正常 |
| consumer sched_setattr | ✓ ret=0 success=1 |
| pselect 返回 | ✓ ret=78-90 (fd ready, 非 timeout) |
| **ghost rb 写 → ashmem_misc.fops** | **✗ cfi step4: pre_rb=0 pre_fops=0** |
| CFI 任意 R/W | 未达 |
| root | 未达 |

### ghost 写未触发分析 (下一步)
`cfi step4: pre_rb=0 pre_fops=0` = ashmem_misc.fops 未被改写 (如果写了,
configfs_read_once 会返回 fake_fops)。可能原因:
1. consumer sched_setattr(nice→19) 未触发 ghost 的 rt_mutex rb_erase —
   ghost 的 task 字段 = INIT_TASK (fake), 内核 prio 调整可能不关联它
2. fake ptr word 映射偏差: fd_set 全局 word3-12 → waiter struct 偏移
   需要对照 5.4 rt_mutex_waiter 布局重新核验
3. pselect ret=78-90 (fd ready 而非 timeout) — ghost 数据被内核当作
   ready fd 提前返回, 可能破坏了 ghost 的栈存续窗口
4. requeue_pi 后 ghost 可能不在 f_pi_target 的 rb tree 里 (5.4 的
   requeue_pi 路径与 6.x 不同, 需反汇编确认 fixup_pi_state 处理)

## 3. 栈几何 (决定性)
- futex 直通路径: rt_waiter @ S0-(0xC0+0xD0+0x1A0)+0x98 = S0-0x298;
  pselect fd_set 区 @ S0-(0x10+0x90+0x1C0)+0x50 = S0-0x210 → **差 0x88, 直通不可达**
  (旧 0915 版 step=33 零写的根因)。
- **restart 路径**: sys_restart_syscall(0x20) → futex_wait_restart(0x40) →
  do_futex(0xD0) → futex_wait_requeue_pi(0x1A0): W' = S0-0x198 =
  **fd 区起点 +0x18 = 全局 word 3** ✓。waiter 字段映射 (global word):
  g3 tree.pc=fake_w0, g4 tree.right=fake_w0, g5 tree.left=0,
  g6 pi.pc=fake_fops, g7 pi.right=&ashmem_misc.fops, g8 pi.left=0,
  g9 task=INIT_TASK, g10 lock=fake_lock, g11 prio=119, g12 deadline=0。
  (in 组只有 word0-4 → g5+ 落 out/ex 组; open_selected_fds 全部 dup 空读端
  使 pselect 阻塞至超时, 防 out-ready 立即返回清掉 go 标志。)
- KASLR: 滑移阶段删除, 用 **perf_event 软件采样泄漏** (§U): exclude_user=1,
  min/max 内核 IP + 2MB 相位唯一解; **必须按 128KB 块聚类取最密 44 块窗口**
  (模块 text 在 _text 下方 128MB 内, 会污染 span → bmin>bmax)。真机验证
  samples≈10600, base=0xffffffd07ce80000 (boot 内稳定)。

## 4. 运行时问题与修复 (cm54/)
1. KernelSnitch 0x820→0x840 步长 (泄漏成功的前提)。
2. find_collisions+bruteforce 移入 leak 子进程 (同进程测量+扫描, 复刻 standalone);
   父进程状态检查放宽为 state==KERNELSNITCH_MM_FOUND。
3. KS 子进程 reset_cpu_pin() (父进程 pin CORE 0 会导致测量争核)。
4. waitpid(leak_child) 提前到 kill 风暴之前 (测量需安静窗口)。
5. pselect 全部 set-bit fd dup 空读端 → 阻塞 (out 组的 fd 位是伪 waiter 字段,
   若为可写 fd 会立即返回)。
6. **consumer 线程自旋永不退出** → punch_consume_stop 置位退出; 且 adb 超时中断
   不会杀掉设备端进程 → 残留自旋线程把 load 打到 159, 时序信道全毁 (大坑!)。
   每次测试前 killall id + 看 uptime。
7. perf 泄漏聚类 (模块 IP 污染)。

## 5. 待办 (下一步)
- [ ] 干净系统上完整跑通: KS 泄漏 → groom → pipe 物理读写 → ashmem R/W → root
- [ ] ghost 形成率: SIGUSR1 信号 + 循环 requeue 的触发调参 (restart 深度路由)
- [ ] pipe_cache_gate: shell 在 root memcg 时 pipe_buffer 数组来自根 kmalloc-1k ✓;
      若在 memcg 子 cgroup → SLUB memcg 子 cache 指针 → gate 失败 (需放宽)
- [ ] 成功后 KernelSU late-load (libksud.so --allow-shell)
