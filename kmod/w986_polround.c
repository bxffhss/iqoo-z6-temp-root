// SPDX-License-Identifier: GPL-2.0
/* w986_polround.c —— #216-B2：内核态**只读**往返探针（路线 B 的第一块真机凭据）。
 *
 * 形状（依据 §6.463 的定案）：
 *   设备只借两个入口 ＋ 一个不透明指针：
 *     security_read_policy(state, &img, &len)   ← 设备自己那份 policydb_write 吐出的镜像
 *     security_load_policy(state, buf, len)     ← 只有 do_load 显式给钥匙才调
 *   解析/改写/再序列化**全用我们自己编进模块的那份 SS 源码**(w985 已判正：编得出、未解析的那几条全在导出表里)。
 *   ⇒ struct 布局只在"我们读、我们写"的闭环里自洽就够了；与设备相接的只有字节流。
 *
 * ★默认零写入：`do_load` 必须等于 0x4C4F4144('LOAD') 才会碰 security_load_policy，且**写运行期安全策略要用户点头**。
 * ★判据不放 dmesg 只放参数：结果全落在 0444 的模块参数里 ⇒ `/sys/module/w985_probe/parameters/rt_*`
 *   **adb shell(uid 2000) 无需 root 就能读**，执法态变了也不瞎(§6.441 那一族)。
 * ★init 一律返回 0(常驻)：返回非 0 会连带把参数一起摘掉 ⇒ 失败也要读得到。跑完由腿自己 rmmod。
 * ★★`rt_steps` 默认 0＝只解析符号就收。⇒ **腿必须显式传 rt_steps=**，否则这个件结构上跑不到往返那一步
 *   (第 66 发就是这么漏的：`insmod $K` 不带参数，rt_stage 只会停在 99，rt_same 永远是 -1)。
 *   保守默认是故意的(裸 insmod 做的事最少)，但判据不成立的锅在腿，不在默认值。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/string.h>
#include <linux/kprobes.h>
#include <linux/moduleparam.h>
#include <linux/err.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>

#include "security.h"
#include "ss/policydb.h"
#include "ss/avtab.h"

#define LOAD_KEY 0x4C4F4144	/* 'LOAD'：不给这把钥匙，本模块结构上不可能写策略 */

/* ★更正：`avtab_cache_init()` **是有头声明的**——`include/security.h:411` 那句
 *   `extern void avtab_cache_init(void);`。我 §6.463/§6.464 写的"没有任何头声明它"是**错的**
 *   (我只在 ss 目录那批头文件里 grep，没查 include 目录)，是自家编译器以 conflicting types 当场驳掉的。
 *   构建脚本会把它的**定义**整段换成硬化版(唯一 slab 名＋去 panic 旗标)，签名保持 void 不变，
 *   创建结果由我们自己的访问器交回调用方判。 */
int z6ss_avtab_caches_ok(void);

/* 我们重序列化出来的那份镜像留在内存里，用 /proc/w986_wr 让腿把它读走(0400＝root 腿读)。
 * ★为什么必须有这个：`rt_same=0` 只说明"字节不等"，而 §6.456 已经教过——**字节不等≠语义不等**；
 *   没有这份产物，一发枪就只能拿到"红"却拿不到"红在哪"。有了它，同一发就能离线跑 w953b 出三元组四数。 */
static void *wr_buf;
static size_t wr_len;
static struct proc_dir_entry *wr_pde;

static ssize_t wr_read(struct file *file, char __user *ubuf, size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos, wr_buf, wr_len);
}

static const struct file_operations wr_fops = {
	.owner = THIS_MODULE,
	.read = wr_read,
	.llseek = default_llseek,
};


/* ===== 0) 只读结果面：全部 0444，shell 可读 ===== */
static int rt_stage = -1;	module_param(rt_stage, int, 0444);	/* 走到第几步(先写号再干活) */
static int rt_sym_rc = -1;	module_param(rt_sym_rc, int, 0444);	/* 符号解析：位掩码，见 SYM_* */
static int rt_rd_rc = -1;	module_param(rt_rd_rc, int, 0444);	/* security_read_policy */
static int rt_prs_rc = -1;	module_param(rt_prs_rc, int, 0444);	/* 我们那份 policydb_read */
static int rt_wr_rc = -1;	module_param(rt_wr_rc, int, 0444);	/* 我们那份 policydb_write */
static int rt_load_rc = -1;	module_param(rt_load_rc, int, 0444);	/* 没装载＝-1，装载过才是 rc */
static long rt_pre_len = -1;	module_param(rt_pre_len, long, 0444);	/* 设备导出的字节数 */
static long rt_wr_len = -1;	module_param(rt_wr_len, long, 0444);	/* 我们写出的字节数 */
static int rt_same = -1;	module_param(rt_same, int, 0444);		/* 1＝逐字节相同(主判据) */
static int rt_ver = -1;	module_param(rt_ver, int, 0444);		/* 镜像里的 policyvers */
static int rt_mls = -1;	module_param(rt_mls, int, 0444);		/* 解析出来的 mls_enabled */
static int rt_nel = -1;	module_param(rt_nel, int, 0444);		/* te_avtab 节点数 */
static long rt_sum_pre = -1;	module_param(rt_sum_pre, long, 0444);	/* FNV-1a64，与拉回的原件离线对 */
static long rt_sum_wr = -1;	module_param(rt_sum_wr, long, 0444);
static int rt_slab_rc = -1;	module_param(rt_slab_rc, int, 0444);	/* 硬化版 avtab_cache_init 的返回 */
static int rt_proc = -1;	module_param(rt_proc, int, 0444);		/* /proc/w986_wr 建没建成 */
static int rt_steps;		module_param(rt_steps, int, 0444);	/* 0=只解析符号 1=+读活策略 2=+我们解析 3=+我们重写 4=+复读 9=全跑 */
/* ===== 0b) 第 82 发那一格的新旋钮：**带尾巴的副本**(单变量＝"喂给 reader 的缓冲区末尾还有没有余量") =====
 *   死因收到 stage3(我们那份 policydb_read)之后，剩下两个候选形状：
 *     (甲)**越界读**——reader 在字节流里读飘，飘出 img 之外。vmalloc 的末尾紧接着就是守护页，
 *          所以"多读几百字节"会立刻 fault ⇒ 无 printk 时间 ⇒ PS_HOLD 硬复位(与第 81 发形状相容)；
 *     (乙)不是越界读(野指针/结构体错乱/内核态环境那一族)。
 *   这一格只改一件事：把要解析的字节搬进一块 `len + rt_slack_kb*1024` 的 vmalloc，**`fp.len` 仍然＝len**
 *     (语义一字没改，改的只有"缓冲区有多大")。甲成立 ⇒ 机器应当活着；照样复位 ⇒ (甲)出局。
 *   ★输入面自证：拷完立刻对副本前 len 字节算**同一个** FNV，必须与原件 `rt_sum_pre` 逐位相同
 *     (`rt_cp_same=1`)；不相同就是"我悄悄换了被测对象"，后面所有读数作废。 */
static int rt_slack_kb;		module_param(rt_slack_kb, int, 0444);	/* >0＝解析前先搬进带余量的副本 */
static int rt_copy = -1;	module_param(rt_copy, int, 0444);		/* 1＝这次吃的是副本；−1/0＝原件 */
static int rt_cp_rc = -1;	module_param(rt_cp_rc, int, 0444);		/* 副本 vmalloc 的返回(0/−ENOMEM) */
static long rt_sum_cp = -1;	module_param(rt_sum_cp, long, 0444);	/* 副本前 len 字节的 FNV */
static int rt_cp_same = -1;	module_param(rt_cp_same, int, 0444);		/* 1＝与 rt_sum_pre 相同(对照成立) */
static int rt_abi = 85;		module_param(rt_abi, int, 0444);		/* 件号：活着的窗里证明装的是哪一版(85＝加了 rt_hist 环＋/proc/w986_hist) */
/* ===== 0c) 第 84 发那一格的新旋钮：**读循环自己的段内计数器**(§6.506/§6.507/§6.508 之后) =====
 *   三发(81/82/83)都死在 insmod 内部且零读数；§6.507 拿 `next_entry()` 否证了"飘出缓冲区末尾"、§6.508 拿八个
 *   分配点的 NULL 检查否证了"分配失败⇒空指针"。⇒ 只剩"读循环里某一段/某一条把控制权交给了不该去的地方"，
 *   而这件事**只有代码自己来得及报**。所以构建期由 `w1085_substep_patch.py` 往我们那份 `ss/policydb.c`/`ss/avtab.c`
 *   的读循环里插赋值(**只插赋值、不插注释**，免得撞内核块注释＝例 191②)：
 *     `rt_sub`＝进到哪一段(1..12，编号按补丁表，这份树里没有 te_cond_avtab ⇒ 6 留空)；
 *     `rt_idx`＝那一段的循环下标(symtab 序号 i / avtab 条目 i / type_attr 的 i)；
 *     `rt_idx2`＝symtab 内层第几条 j。
 *   ★这三个是**非 static** 的：SS 那几个 .c 里只有 extern 声明，定义在这里(同一个模块符号)。
 *   ★它们只被读循环写、只被 sysfs 读——**不改变任何解析行为**，所以这一发测的仍是第 81 发那一格。 */
int rt_sub = -1;		module_param(rt_sub, int, 0444);
int rt_idx = -1;		module_param(rt_idx, int, 0444);
int rt_idx2 = -1;		module_param(rt_idx2, int, 0444);
/* ===== 0d) 第 85 发：把"段过渡"记在**被测自己**手里(§6.510／用户记忆例 215) =====
 *   第 84 发买到了通道(用户态在 `init` 运行期间真读到了 `rt_stage=1`)，但"之后没有第四行 CHG"这一枚读数
 *   **没有分母的证人**：轮询器的心跳定在"每 2 万次读"，而"次数→秒"的换算率由被测状态决定(读失败 0.36 ms/轮
 *   vs 读成功只要 ≥0.75 ms/轮就 15 秒一次心跳都打不出) ⇒ 采样器死没死、快过渡有没有被整段跳过，两样都答不了。
 *   ⇒ 这一版把记录搬进被测：**每次过渡往环里追加一项**，用户态哪怕一秒只读一次也拿得到整条轨迹——
 *     采样率不再当判据的上限。环只写内存(不碰文件系统、不 printk、不参与任何 `if`)⇒ 仍不改解析行为。
 *   ★快照读点印成**一行**：设备那把 mksh 的内建 `read` 只吃一行，而且一次读一个文件＝零 fork
 *     (§6.198 那把 fork 风暴的账：一 tick 十个 `cat` 会把仪器自己混进被测)。
 *   ★每一项带 `seq`，读出前后各取一次 `rt_seq`：不相等就在那行末标 `TORN=1`(撕裂我自己报，不瞒)。 */
#define RT_HIST_N 48
struct rt_ev { int seq, stage, sub, idx, idx2; };
static struct rt_ev rt_hist[RT_HIST_N];
int rt_hist_next;			/* 环里下一个要写的位置(对外读数：能看出环有没有绕满) */
module_param(rt_hist_next, int, 0444);
int rt_seq;				/* 过渡总数(非 static：SS 那边也走它) */
module_param(rt_seq, int, 0444);
void rt_note(int sub, int idx, int idx2);
static void rt_stage_set(int s);

void rt_note(int sub, int idx, int idx2)
{
	struct rt_ev *e = &rt_hist[rt_hist_next];

	rt_seq++;
	e->seq = rt_seq;
	e->stage = rt_stage;
	e->sub = sub;
	e->idx = idx;
	e->idx2 = idx2;
	rt_hist_next = (rt_hist_next + 1) % RT_HIST_N;
}

/* stage 换号也算一次过渡：这样即使 `sub` 那一族(SS 里插的赋值)一次都没跑到，环里也留下了"走到第几步"的轨迹 */
static void rt_stage_set(int s)
{
	rt_stage = s;
	rt_note(rt_sub, rt_idx, rt_idx2);
}

/* ★快照读点＝**整个环印在一行**上(`/proc/w986_hist`，0444＝shell 无需 root 就能读，执法态变了也不瞎)。
 *   一次 `open+read` 拿走"到目前为止的全部过渡"，所以读得慢也不丢轨迹；每项形状 `seq:stage:sub:idx:idx2`。
 *   读出前后各取一次 `rt_seq`：不相等 ⇒ 这行是撕裂的，自己标 `TORN=1`(例 182 那一族：读不到要说"未测")。 */
static struct proc_dir_entry *hist_pde;
static int rt_hist_proc = -1;	module_param(rt_hist_proc, int, 0444);

static int hist_show(struct seq_file *m, void *v)
{
	int i, n, start, s0 = rt_seq;

	n = rt_seq < RT_HIST_N ? rt_seq : RT_HIST_N;
	start = (rt_hist_next - n + RT_HIST_N) % RT_HIST_N;
	seq_printf(m, "HIST abi=%d now_stage=%d now_sub=%d now_idx=%d now_idx2=%d seq=%d cnt=%d",
		   rt_abi, rt_stage, rt_sub, rt_idx, rt_idx2, rt_seq, n);
	for (i = 0; i < n; i++) {
		struct rt_ev *e = &rt_hist[(start + i) % RT_HIST_N];

		seq_printf(m, " %d:%d:%d:%d:%d", e->seq, e->stage, e->sub, e->idx, e->idx2);
	}
	seq_printf(m, " ENDSEQ=%d TORN=%d\n", rt_seq, rt_seq != s0 ? 1 : 0);
	return 0;
}

static int hist_open(struct inode *inode, struct file *file)
{
	return single_open(file, hist_show, NULL);
}

static const struct file_operations hist_fops = {
	.owner = THIS_MODULE,
	.open = hist_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

MODULE_PARM_DESC(rt_slack_kb, "解析前把待解析字节搬进 len+N*1024 的 vmalloc(0=不搬，喂原件)");
static int do_load;		module_param(do_load, int, 0444);
MODULE_PARM_DESC(do_load, "只有 ==" __stringify(0x4C4F4144) " 才调 security_load_policy；写运行期策略要用户点头");

/* ===== 1) 符号解析：文本走 kprobe；数据符号 kprobe 取不到 ⇒ 先 kprobe 拿到 kallsyms_lookup_name 再问它 =====
 * (§6.24 那一手的就地复刻；不依赖我们出货 ko 的 dev_syms，这个探针要能单独上机) */
#define SYM_READ	0x1
#define SYM_LOAD	0x2
#define SYM_STATE	0x4
#define SYM_KLN		0x8

static unsigned long kp_addr(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	unsigned long addr;
	int ret = register_kprobe(&kp);

	if (ret < 0) {
		pr_warn("w986: register_kprobe(%s)=%d\n", name, ret);
		return 0;
	}
	addr = (unsigned long)kp.addr;	/* ★本树 kprobe.addr 是 kprobe_opcode_t*，不转就是 -Wint-conversion */
	unregister_kprobe(&kp);
	return addr;
}

static unsigned long (*p_kln)(const char *name);

static unsigned long sym_addr(const char *name)
{
	unsigned long a = 0;

	if (!p_kln)
		p_kln = (void *)kp_addr("kallsyms_lookup_name");
	if (p_kln)
		a = p_kln(name);
	if (!a)
		a = kp_addr(name);		/* 退化成只认文本符号的老办法 */
	return a;
}

/* 原型一律 __typeof__(头里的声明)，不凭记忆写 —— KCFI 的 TypeId 由函数类型算出来，抄错要到运行期才炸
 * ★一手：设备 vmlinux 里确实有 `__cfi_check`(T)/`__cfi_slowpath`(T)/`__cfi_check_fail`(t)
 *   ⇒ 这台机开着 clang CFI。我们出货 ko 早就在用"逐字抄头文件的 __typeof__ + 函数指针"这套并且跑得通，
 *   那是**归纳证据**不是保证：`security_load_policy` 的**第一声调用**是整条路线里最贵的一条指令。
 *   ⇒ 降风险的做法不是跳过它，是让它第一次调用时交回去的件＝**与设备自己导出的那份逐字节相同**(rt_same=1)
 *     ——语义等价、失败也只是 rc≠0(§6.463 读过失败面)。这一步仍然要用户点头。 */
static __typeof__(security_read_policy) *p_read_policy;
static __typeof__(security_load_policy) *p_load_policy;
static struct selinux_state *state;

static unsigned long fnv64(const unsigned char *p, size_t n)
{
	unsigned long h = 1469598103934665603UL;

	while (n--) {
		h ^= *p++;
		h *= 1099511628211UL;
	}
	return h;
}

static int __init wr_init(void)
{
	void *img = NULL;
	void *cp = NULL;	/* ★第 82 发：带余量的副本＝解析真正吃的那块 */
	void *buf = NULL;
	struct policydb *db = NULL, *db2 = NULL;
	struct policy_file fp, fp2;
	size_t len = 0, cap;
	unsigned long a;
	int rc;

	pr_info("w986 polround start (do_load=%d steps=%d)\n", do_load, rt_steps);

	/* 0) ★口先开：快照读点在**任何有风险的动作之前**挂上——这一步之前的轨迹也是要被看的对象。
	 *    (`/proc/w986_hist`＝0444，shell 无需 root；建没建成落在 `rt_hist_proc`，读不到口就等于没仪器) */
	hist_pde = proc_create("w986_hist", 0444, NULL, &hist_fops);
	rt_hist_proc = hist_pde ? 1 : 0;

	/* 1) 解析符号 */
	rt_stage_set(1);
	p_kln = NULL;
	a = sym_addr("kallsyms_lookup_name");
	if (a)
		p_kln = (void *)a;
	rt_sym_rc = p_kln ? SYM_KLN : 0;

	a = sym_addr("security_read_policy");
	if (a) { p_read_policy = (void *)a; rt_sym_rc |= SYM_READ; }
	a = sym_addr("security_load_policy");
	if (a) { p_load_policy = (void *)a; rt_sym_rc |= SYM_LOAD; }
	a = sym_addr("selinux_state");
	if (a) { state = (void *)a; rt_sym_rc |= SYM_STATE; }
	pr_info("w986 sym_rc=%d state=%ps\n", rt_sym_rc, state);
	if ((rt_sym_rc & (SYM_READ | SYM_STATE)) != (SYM_READ | SYM_STATE)) {
		pr_err("w986: missing read/state symbol, stop without touching anything\n");
		return 0;	/* ★常驻：让参数面读得到为什么没跑 */
	}

	/* 1b) 建我们自己的 avtab slab(硬化版：唯一名＋不 panic；结果用访问器判) */
	avtab_cache_init();
	rt_slab_rc = z6ss_avtab_caches_ok();
	if (rt_slab_rc) {
		pr_err("w986: z6ss_avtab_caches_ok=%d, stop (policydb_read needs that cache)\n",
		       rt_slab_rc);
		return 0;
	}

	if (rt_steps < 1) {
		pr_info("w986 steps=%d => symbols only, stop here\n", rt_steps);
		rt_stage_set(99);
		return 0;
	}

	/* 2) 让设备自己把活策略序列化出来 */
	rt_stage_set(2);
	rc = p_read_policy(state, &img, &len);
	rt_rd_rc = rc;
	rt_pre_len = rc ? -1 : (long)len;
	if (rc || !img || !len) {
		pr_err("w986: read_policy rc=%d img=%ps len=%zu, stop\n", rc, img, len);
		return 0;
	}
	rt_sum_pre = (long)fnv64(img, len);
	pr_info("w986 read_policy ok len=%zu sum_pre=%lx\n", len, (unsigned long)rt_sum_pre);

	/* 2b) ★带余量的副本：本发唯一变量＝"喂给 reader 的缓冲区末尾有没有余量"。
	 *     (甲)越界读 ⇒ 飘出 img 就撞上 vmalloc 末尾的守护页 ⇒ 当场 fault ⇒ 无 printk 的 PS_HOLD 复位；
	 *     (乙)不是越界读 ⇒ 搬进大缓冲区照样复位。fp.len 仍然＝len ⇒ 语义一字没改。
	 *     ★输入面自证：对副本前 len 字节算同一个 FNV，必须与 rt_sum_pre 逐位相同(rt_cp_same=1)，
	 *       不相同＝我悄悄换了被测对象，后面所有读数作废。 */
	if (rt_slack_kb > 0) {
		size_t slack = (size_t)rt_slack_kb * 1024;

		rt_stage_set(21);	/* 21＝"正在搬副本"，与"已在 policydb_read 里"(3)分得开 */
		cp = vmalloc(len + slack);
		rt_cp_rc = cp ? 0 : -ENOMEM;
		if (!cp) {
			pr_err("w986: slack vmalloc failed => 退化成喂原件，这一格读数不可比\n", len, slack);
		} else {
			memcpy(cp, img, len);
			memset((char *)cp + len, 0xA5, slack);	/* 尾巴填可辨认字节：飘出去读到的是它，不是别人的料 */
			rt_sum_cp = (long)fnv64(cp, len);
			rt_cp_same = (rt_sum_cp == rt_sum_pre) ? 1 : 0;
			rt_copy = 1;
			pr_info("w986 slack copy len=%zu slack=%zu sum_pre=%lx sum_cp=%lx cp_same=%d\n",
				len, slack, (unsigned long)rt_sum_pre, (unsigned long)rt_sum_cp, rt_cp_same);
			if (!rt_cp_same)
				pr_err("w986: copy differs from img (cp_same=0) => 对照不成立，别看后面的读数\n");
		}
		rt_stage_set(2);	/* 搬完了：下面 stage 3 才是"进 policydb_read"的号 */
	}

	/* 3) 我们那份 reader 解析它 */
	if (rt_steps < 2) {
		pr_info("w986 steps=%d => stop after read_policy (len=%zu)\n", rt_steps, len);
		rt_stage_set(99);
		vfree(img);
		return 0;
	}

	rt_stage_set(3);
	db = kzalloc(sizeof(*db), GFP_KERNEL);
	if (!db) {
		rt_prs_rc = -ENOMEM;
		vfree(img);
		return 0;
	}
	memset(&fp, 0, sizeof(fp));
	fp.data = cp ? cp : img;	/* ★旋钮没拧(rt_slack_kb=0)时＝与第 81 发完全同一条路 */
	fp.len = len;			/* ★不改：本发变的只有"缓冲区有多大"，不是"喂进去的料" */
	pr_info("w986 parsing from %s copy=%d cp_same=%d slack_kb=%d abi=%d\n",
		cp ? "SLACK_COPY" : "ORIGINAL_IMG", rt_copy, rt_cp_same, rt_slack_kb, rt_abi);
	rc = policydb_read(db, &fp);
	rt_prs_rc = rc;
	if (rc) {
		pr_err("w986: our policydb_read rc=%d => device export not readable by us (suspect subset/shape first)\n",
		       rc);
		kfree(db);
		vfree(img);
		return 0;
	}
	rt_ver = db->policyvers;
	rt_mls = db->mls_enabled ? 1 : 0;
	rt_nel = (int)db->te_avtab.nel;
	pr_info("w986 our parse ok ver=%d mls=%d nel=%d\n", rt_ver, rt_mls, rt_nel);

	if (rt_steps < 3) {
		pr_info("w986 steps=%d => stop after our parse (nel=%d ver=%d)\n",
			rt_steps, rt_nel, rt_ver);
		rt_stage_set(99);
		goto out_free;
	}

	/* 4) 空 delta：我们那份 writer 再序列化一次(不碰任何规则) */
	rt_stage_set(4);
	cap = len + 65536;		/* writer 只会越写越少，给足余量 */
	buf = vmalloc(cap);
	if (!buf) {
		rt_wr_rc = -ENOMEM;
		goto out_free;
	}
	memset(&fp2, 0, sizeof(fp2));
	fp2.data = buf;
	fp2.len = cap;
	rc = policydb_write(db, &fp2);
	rt_wr_rc = rc;
	if (rc) {
		pr_err("w986: our policydb_write rc=%d, stop (nothing handed to the device)\n", rc);
		goto out_free;
	}
	rt_wr_len = (long)((unsigned long)fp2.data - (unsigned long)buf);
	rt_sum_wr = (long)fnv64(buf, (size_t)rt_wr_len);

	/* 5) 主判据：与设备自己导出的那份**逐字节**比 */
	rt_stage_set(5);
	rt_same = (rt_wr_len == (long)len) && !memcmp(img, buf, len) ? 1 : 0;
	pr_info("w986 empty delta round trip: pre=%ld wr=%ld same=%d nel=%d ver=%d mls=%d\n",
		rt_pre_len, rt_wr_len, rt_same, rt_nel, rt_ver, rt_mls);
	if (!rt_same)
		pr_warn("w986 same=0: byte-level mismatch (6.456 precedent: kernel serialization != ours). "
			"Must run w953b on both exports before any load; byte equality is the strongest positive control\n");

	/* 5b) 二级判据：把我们写出的那份**再读一遍**，数应与第一次解析一致(自循环一致性) */
	if (rt_steps < 4)
		goto skip_reparse;
	rt_stage_set(6);
	db2 = kzalloc(sizeof(*db2), GFP_KERNEL);
	if (db2) {
		memset(&fp, 0, sizeof(fp));
		fp.data = buf;
		fp.len = (size_t)rt_wr_len;
		rc = policydb_read(db2, &fp);
		pr_info("w986 reparse our own blob rc=%d nel=%d (first pass %d)\n",
			rc, db2->te_avtab.nel, rt_nel);
		if (!rc)
			policydb_destroy(db2);
		kfree(db2);
	}

skip_reparse:
	if (rt_steps < 5) {
		pr_info("w986 steps=%d => no /proc, no load, wrapping up\n", rt_steps);
		rt_stage_set(98);
		goto out_free;
	}

	/* 6) 装载那一步：**双闸**——参数存在 + 值等于钥匙 */
	rt_stage_set(7);
	if (do_load != LOAD_KEY) {
		pr_info("w986 do_load=%d != key => security_load_policy NOT called (this run structurally cannot write policy)\n",
			do_load);
	} else if (!p_load_policy) {
		rt_load_rc = -ENOSYS;
		pr_err("w986: key given but security_load_policy unresolved\n");
	} else {
		pr_warn("w986 ABOUT TO WRITE RUNTIME SECURITY POLICY (load) - this needs the user's explicit nod\n");
		rt_load_rc = p_load_policy(state, buf, (size_t)rt_wr_len);
		pr_warn("w986 load rc=%d\n", rt_load_rc);
	}
	rt_stage_set(8);

	/* 9) 把我们写出的那份留给 /proc/w986_wr，让腿把它读走做**语义**比对。
	 *    §6.456 已经教过：字节不等≠语义不等；没有这份产物，一发枪只拿到"红"拿不到"红在哪"。 */
	if (buf && rt_wr_len > 0) {
		wr_buf = buf;
		wr_len = (size_t)rt_wr_len;
		buf = NULL;	/* 移交给模块持有，out_free 那条不再 vfree */
		wr_pde = proc_create("w986_wr", 0400, NULL, &wr_fops);	/* ★把 fops 交给内核＝下一次被间接调用时才会走到我们 */
		rt_proc = wr_pde ? 1 : 0;
		pr_info("w986 /proc/w986_wr created=%d size=%zu => root leg: cat /proc/w986_wr > file, pull back, run w953b\n",
			rt_proc, wr_len);
	}

out_free:
	policydb_destroy(db);
	kfree(db);
	vfree(img);
	if (cp)
		vfree(cp);
	if (buf)
		vfree(buf);
	return 0;		/* ★常驻，参数面才是判据 */
}

static void __exit wr_exit(void)
{
	if (hist_pde) {
		proc_remove(hist_pde);
		hist_pde = NULL;
	}
	if (wr_pde) {
		proc_remove(wr_pde);
		wr_pde = NULL;
	}
	if (wr_buf) {
		vfree(wr_buf);
		wr_buf = NULL;
		wr_len = 0;
	}
	pr_info("w986 exit (stage=%d same=%d pre=%ld wr=%ld)\n", rt_stage, rt_same, rt_pre_len, rt_wr_len);
}

module_init(wr_init);
module_exit(wr_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("w986 in-kernel read-only policy round trip (#216-B2)");
