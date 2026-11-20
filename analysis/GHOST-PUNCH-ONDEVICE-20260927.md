# GhostLock punch 上机首轮: 通道证实 + 一堆一手勘误 (2026-09-27)

目标: 把已证实的 `rt_sigreturn` 覆盖层 + 悬空 rt_waiter 拼成一次真实的内核写(M1)。
今晚跑了 6 次上机实验, 把 4 个"看着像先验其实错"的地方钉死了。全部结论都来自
**设备同构建的反汇编**或**真机返回值**, 不是推算。

## 0. 结论口径(先说结果)

- **覆盖层有效(真机证实)**: 探针实验里 `sched_setattr(受害者 tid)` **返回 0 且设备不炸**,
  而它唯一的退出路径是链走 [3] 的 `rt_mutex_waiter_equal(waiter, task_to_waiter(task))`
  ⇒ 内核确实在 `waiter->prio` 那个位置读到了**我们填的值**。
  ⇒ `rt_sigreturn` 的 fpsimd 回存窗口**够得着**悬空 rt_waiter, 之前"栈覆盖层已被量化关掉"
     的判词对这条通道不成立。
- 写本身还没落地(还在定位窗口内的精确偏移, 见 §6)。

## 1. 勘误一: private futex 的 key 是**页**, 不是地址

```
get_futex_key(): key->both.offset = address % PAGE_SIZE; address -= offset;
                 if (!fshared) { key->private.mm = mm; key->private.address = address; }
```
⇒ 同一个 4K 页里的三个 futex 字 C/PI/N 在内核眼里是**同一个 futex**:
- `futex_wait_requeue_pi` 里 `match_futex(&q.key, &key2)` 命中 ⇒ **-EINVAL**
- `futex_requeue` 的 `lookup_pi_state()` 拿不到 uaddr2 上的 pi_state ⇒ **-EFAULT**

症状(第一轮日志): `WAIT_REQUEUE_PI errno=22`, `requeue errno=14`, 幽灵永远不成形。
修法: 三个 futex 各占一页(`mmap(0x3000, MAP_SHARED|MAP_ANONYMOUS)` 后 +0/+0x1000/+0x2000),
并且**先在用户态真写过一次**(内核用 `get_futex_value_locked()` 的 inatomic 拷贝, 页没实例化
就 EFAULT)。改完立刻拿到 `EDEADLK`(=幽灵成形) + `ETIMEDOUT`(=幽灵留下悬空指针)。

## 2. 勘误二: 本机 futex op 编号不是主线 5.4 的 9/10

NDK `linux/futex.h`(=android uapi)给的是 **FUTEX_WAIT_REQUEUE_PI=11, FUTEX_CMP_REQUEUE_PI=12**,
手写 `#define FW 9 / FCMP 11` 在这台内核上行为不对(9 ⇒ EINVAL, 11 ⇒ EFAULT)。
真机验证: 用头文件常量(11/12) ⇒ W 正常睡 8s 后 ETIMEDOUT, 主线程 CMP_REQUEUE_PI 得到 EDEADLK
⇒ 本内核的 PI requeue 对子在 11/12 上。
另外 `FUTEX_CMP_REQUEUE_PI` 的参数语义(容易踩): arg3=**nr_wake**, arg4=**nr_requeue**(不是 timeout!),
arg6=**cmpval**(要和 N 的当前值相等, 这里 N=0 ⇒ 传 0)。

## 3. 勘误三: 5.4 的 `task_to_waiter()` 用的是**真 prio**, 不是 MAX_PRIO

`kernel/locking/rtmutex.c:231`
```c
#define task_to_waiter(p) \
	&(struct rt_mutex_waiter){ .prio = (p)->prio, .deadline = (p)->dl.deadline }
```
设备反汇编一致(`rt_mutex_adjust_prio_chain+0xbc: ldr w8,[x19,#0xb4]; ldr w9,[x25,#0x40]; cmp; b.ne`)。
⇒ 想让链走在 [3] 就退出, 假 waiter 的 prio 必须等于**受害者当时的 p->prio**。
W 持有 C(futex C 的 pi_state owner), O 阻塞在 C 上 ⇒ W 被 pi 提升 ⇒ p->prio = **120**
(不是我推的 139; 这条也解释了为什么"benign=139"那一跑照样炸 —— 判定条件压根没命中)。

## 4. 勘误四(最贵的一条): 写目标必须"邻居是 0", 否则死在 enqueue 的下潜里

设备反汇编 `rt_mutex_adjust_prio_chain` 的 [7]:
```
[7] rt_mutex_dequeue  : rb_erase(node=栈上假waiter, root=lock+0x08)
      pc=0(parent NULL)/right=T/left=0 ⇒ 0x11544734→0x115447f0: *root = T ; 0x11544754: *(T) = pc
      ⇒ 这一笔就是"任意 8 字节对齐写", 值 = tree.pc 本身(可以不是 0!)
[7] rt_mutex_enqueue  : 内联 rb_add_cached —— **从 root->rb_node 往下走树**
      ldr w12,[node,#0x40]   比 prio ⇒ 选 slot = node+0x08 或 node+0x10
      ldr x13,[node,#off]    若非 0 ⇒ 当作节点指针继续下潜 ⇒ **解引用垃圾 = panic**
      slot=0 ⇒ 就地插入 *(slot)=S(假节点真实地址=受害者内核栈) ← 顺带泄漏栈地址
      且 w8=0 ⇒ rb_leftmost **不更新**
[9] 出口: ldr x8,[lock,#0x10](leftmost) cbz ⇒ **leftmost==NULL 时压根不调 wake_up_process**
      ldr x8,[lock,#0x18](owner) cmp #1 b.ls ⇒ owner==0 干净结束
```
所以**第一版打 sysctl_bootid 必炸**: bootid[8..15] 是随机 ASCII 十六进制, 正是 enqueue 下潜时
被当成"子节点指针"读的东西。⇒ 写目标要挑 **+0x08/+0x10 都是 0** 的可写核内位置。

选中的落点: **`init_uts_ns` 的 sysname 零洞**(`0x1292d350`, 'D'=.data 可写, `uname()` 原样
返回 65 字节 ⇒ 可读回来!). 镜像实测布局: sysname@+0x04 "Linux", nodename@+0x45,
release@+0x86, version@+0xc7, machine@+0x108, domainname@+0x149。
```
L = init_uts_ns+0x20  假 rt_mutex: wait_lock=0, rb_node@+8, leftmost@+0x10=0, owner@+0x18=0
T = L+0x18            写目标(本来就是 0)
*(T+0x40)=sysname 尾=0 ⇒ prio 比不出左子 ⇒ 走右槽 T+8(=0) ⇒ 终止 ⇒ *(T+8)=S 可读
```
(附带把"假 task 也不用准备"这条证实了: leftmost 保持 NULL 就不会 wake_up_process。)

## 5. 观测手段的两项升级(关系到后面每一轮)

1. **panic 也留得住的日志**: 本机没有内核事后日志(`/dev/kmsg` 0660 root:system, pstore 拒读,
   `dmesg` 被 dmesg_restrict 挡), 而 adb shell 的 stderr 在炸的瞬间会丢尾巴(前面几次误判全来自此)。
   ⇒ `say()` 每行 `open(O_APPEND|O_CREAT)+write+fsync` 到 `/data/local/tmp/pr.log`; 重启后仍读得到,
      于是能精确指认"死在哪一行"。本次就是靠它把崩溃点定在 `sched_setattr` 内部。
2. **独立观察线程**: 另起线程每 200us `uname()` 一次, 内容一变就 fsync 落盘 ⇒
   即使打 punch 的线程被炸死, panic 到真正重启之间那几秒足够抓到内核写进 init_uts_ns 的值。

另外新建 **`cm57/auto.py`**: 每轮自动"stat 循环正对照 + perfips 采样 + 簇过滤 + slide.py +
热点语义打分选 slide" → 编译 → 推送 → 跑 → `wait-for-device` → 读设备端日志。
slide 每次开机都变, 手动做这件事太慢; 语义判别这一招本轮再次验证有效:
候选 A 把远端簇映到 `vsnprintf/number/format_decode/mutex_lock`(printk 机器, 合理),
候选 B 映到 `inet6_addr_modify/ip6_route_info_create`(配置变更路径, 不可能这么热) ⇒ 取 A。

## 6. 进行中: 窗口内 prio 字下标的二分(`cm57/bisect.py`)

探针定义: 把覆盖窗口的 64 个 8 字节字里 `[lo,lo+n)` 填 120, 其余填 0。
**该判据与 slide 无关**(未命中时 `pc`/`lock` 读到的只会是 0 或 120 这种小整数 ⇒ 必炸;
命中时链走 [3] 就退出 ⇒ 不解引用任何东西)。存活 ⇔ 真 prio 字在探针区内。
模型预测: prio 字在窗口字节 0x88+0x40 = 0xC8 ⇒ 字下标 25。二分结果见本文末尾追记。

## 7. 本轮确认的设备侧偏移/事实(集中列出, 便于下次直接用)

- task_struct: pi_lock **0x91C**, pi_waiters.rb_node **0x928** / rb_leftmost **0x930**,
  pi_top_task **0x938**, pi_blocked_on **0x940**, prio **0xb4**, dl.deadline **0x468**,
  usage **0x70**(put_task_struct 的 `ldxr/stxr` 就在这)。(全部来自 rt_mutex_adjust_prio_chain 反汇编)
- rt_mutex: wait_lock **0x00**, waiters.rb_node **0x08**, rb_leftmost **0x10**, owner **0x18**。
- rt_mutex_waiter: tree **0x00**(pc/right/left 各 8), pi_tree **0x18**, task **0x30**,
  lock **0x38**, prio **0x40**(u32), deadline **0x48**; sizeof **0x50**。
- 覆盖层帧和(设备构建, 逐个 `sub sp` 实测):
  `__arm64_sys_rt_sigreturn 0x30 + restore_sigframe 0x60 + restore_fpsimd_context 0x250 = 0x340`,
  缓冲 = fpstate 在 `sp+0`(`memset(sp,0,0x210)`; `mov x0,sp; mov w2,#0x200; bl __arch_copy_from_user`),
  ⇒ 覆盖深度 [0x130,0x340];
  `__arm64_sys_futex 0xC0 + do_futex 0xD0 + futex_wait_requeue_pi 0x1A0 = 0x350`,
  `rt_waiter = sp+0x98`(`add x0,sp,#0x98; bl rt_mutex_init_waiter`) ⇒ tree.pc 在深度 0x2B8,
  对象占 [0x269,0x2B8] ⇒ 窗口字节偏移 i 与 waiter 字节 j 的关系 **i = j + 0x88**。
  ⇒ 假 waiter 平铺周期取 0x50(8 的倍数) ⇒ 任意 8 对齐的深度误差都能命中(本轮实测: 命中)。
- CONFIG: **CFI_CLANG=y(CFI_PERMISSIVE 未开)**, SHADOW_CALL_STACK=y, STRICT_KERNEL_RWX=y,
  DEBUG_SPINLOCK/LOCKDEP/KASAN 均未开, SELINUX_DISABLE=y(**enforcing 在 selinux_state+1**)。
- 本机 op 编号: WAIT_REQUEUE_PI=11, CMP_REQUEUE_PI=12(见 §2)。
