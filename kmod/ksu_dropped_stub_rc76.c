// SPDX-License-Identifier: GPL-2.0
/* 路线 B 的降级桩 —— rc76 候选：rc75(解码＋待决账)之上**接上装载门**。
 *
 * 三件事，各管一段，互不冒充：
 *   (1) `handle_sepolicy`＝SET_SEPOLICY 那条口：把交进来的命令流**解一遍**并在 `/proc/ksu_sepol`
 *       留一份事后能审计的账(官方 ksud 会把我们的负返回值静默吞掉，#236)。返回值**永远不是正数**：
 *       解干净＝-EOPNOTSUPP，流不合法＝-EINVAL，超容量＝-E2BIG，copy 不全＝-EFAULT，分不出内存＝-ENOMEM。
 *   (2) **装载面**(交图 / ARM / GO)＝这一版新接的那半。判定**只在** `w1161_gate()` 里(那份头已经在
 *       宿主对第 96 发的两张真图判正过：38 断言＋五条变异全被抓)，桩自己**不做任何判断**。
 *   (3) 收尾 `ksu_sepol_put()`＝把两个面的节点与内存都还掉。
 *
 * ★装载面的形状是**逐条搬自第 96 发真跑过的那枚探针** `kmod/w1140_polload.c`(那份证件＝
 *   `post_why=0 / post_load_rc=0`，＝一路走到 `security_load_policy()` 且内核收下)。搬而不重写，
 *   是因为那一发买到的不只是"能装载"，还有这套协议在真机上的行为(交图的流式 FNV、RESET、ARM 握手)。
 *   ⇒ 拒因号(`ld_why`)与探针的 `pl_why` **同一个表**，以后窗里读到"拒在 6"能直接和那一发对表。
 *
 * ★★三道默认关死的锁(裸 insmod 结构上进不到装载那一步)：
 *   ①`ld_key` 必须＝0x504F4C44('POLD')，且参数是 0444 ⇒ 只在 insmod 那一刻定得下来，运行期没有
 *     任何用户态路径能把"允许装载"打开。
 *   ②`ld_cap` 默认 0＝一口图都收不下(交图那一步直接 -ENOSPC)，同时受 LD_MAX 硬顶。
 *   ③ARM 握手：写 `ARM <十进制FNV>`；GO 时**重新**读一遍活策略、算同一个 FNV，与武装值不等 ⇒ 拒。
 *     两个面合起来的总开关还是 rc75 那条 `sp_arm=1`(不给就没有 /proc 节点)。
 * ★这一枚**从没在设备上装过**。它证到的只有：编得过(构建尺)＋"装载只可能从门后面发生"(静态闸＋变异)。
 *   交图→ARM→GO 这条**运行期**链的行为仍由第 96 发那枚探针代证；本件自己的那一格要等一扇窗。
 *
 * ★★签名必须逐字对齐 kernel/selinux/selinux.h:34：`int handle_sepolicy(void __user *, u64)`。
 *   上一版把它写成三参——因为这个文件不 include selinux.h，编译器不报错、链接也不查类型 ⇒ 一个静默的
 *   ABI 错。教训：**桩必须 include 它要实现的那个头**，让编译器替你核对签名(rc67 起一直这么做)。
 * ★装载面同理：`#include "security.h"` 命中的是**树里 SS 那份** include/security.h(现读：
 *   `security_load_policy`＝:198、`security_read_policy`＝:200、`struct selinux_state`＝:100、
 *   SELINUX_MAGIC 经它的 :14 `<linux/magic.h>` 进来＝include/uapi/linux/magic.h:14 的 0xf97cff8c)。
 *   这四个原型**不抄进本文件**——KCFI 的 TypeId 按函数类型算，抄错要到运行期第一声调用才炸。
 *   ★11-07 那一红就是这句话害的：这一行**当时只存在于这段注释里**，代码里没有 ⇒ 两条原型未声明，
 *     而远端那句 `grep -qF '#include "security.h"'` 撞上这段散文就放行了(空回执)。
 *     现在两处都只数**代码行**：`w1162_wire_check.py` 第⑩段(上传前，带一条会红的变异)＋远端回执。
 *   ★反过来，`security_policydb_len` 在这棵树的**任何头里都没有声明**(11-06 现查)⇒ 本件不用它：
 *   装载前后的长度一律取 `security_read_policy` 自己交出来的那个字节数，不凭记忆写原型。 */
#include <linux/err.h>
#include <linux/fs.h>		/* simple_read_from_buffer(交图口那把"原样读回"的尺) */
#include <linux/kernel.h>
#include <linux/kprobes.h> /* register/unregister 在这棵树里是导出的(现查 Module.symvers=1) */
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h> /* proc_create 的声明——rc38/rc40 那个坑，别再犯第二次 */
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

#include "selinux.h"
#include "security.h" /* ★代码行，不是注释：两个装载原型的唯一来源(见上面那段) */
#include "w1151_sepolicy_core.h"
#include "w1155_sepol_record.h"
#include "w1161_polgate.h"

#define SP_SLOTS 512u    /* 一次调用最多收几条(超出＝TOO_MANY，照实记，不静默丢) */
#define SP_REC_CAP 65536u /* 600 条语句的记录就要 ~25K ⇒ 8K 会在自家账上截断(自测抓到过) */ /* 记录缓冲；不够就在尾巴明写 TRUNC，不许悄悄少打一行 */

#define LD_KEY_WANT 0x504F4C44u		/* 'POLD'：与探针同一个号，两张证件才能对表 */
#define LD_STRLEN   8u			/* strlen(POLICYDB_STRING)：一手 ss/policydb.h:336 的 "SE Linux"。
					 * 这里不 include ss/policydb.h——那条链在 w985 撞过
					 * ss/conditional.h 与 include/conditional.h 共用 guard 的坑。 */
#define LD_MAX      (64u * 1024u * 1024u)	/* 与 selinuxfs.c:sel_write_load 的闸同值 */
#define SYM_READ  0x1
#define SYM_LOAD  0x2
#define SYM_STATE 0x4

void ksu_sepol_put(void); /* 给 main.c 的收尾用(见文件末) */

static unsigned int sp_arm;
static unsigned int sp_verbose;
static unsigned int sp_calls;
static unsigned int sp_seq;
static int sp_why = -1;
static int sp_n = -1;
static long sp_bytes = -1;
static long sp_bad_at = -1;
static unsigned int sp_max_arg;
static int sp_rc = -1;    /* W1155_RC_* 小码 */
static int sp_lenmatch = -1;
static int sp_rec_bytes = -1;
static int sp_rec_trunc = -1;
static unsigned long sp_sum; /* FNV-1a64(与内核那把尺同一算式) */
module_param(sp_verbose, uint, 0444);
module_param(sp_calls, uint, 0444);
module_param(sp_seq, uint, 0444);
module_param(sp_why, int, 0444);
module_param(sp_n, int, 0444);
module_param(sp_bytes, long, 0444);
module_param(sp_bad_at, long, 0444);
module_param(sp_max_arg, uint, 0444);
module_param(sp_rc, int, 0444);
module_param(sp_lenmatch, int, 0444);
module_param(sp_rec_bytes, int, 0444);
module_param(sp_rec_trunc, int, 0444);
module_param(sp_sum, ulong, 0444);

/* ===== 装载面的读数(全 0444：执法态翻了也读得到，判据不放 dmesg) ===== */
static unsigned int ld_key;		module_param(ld_key, uint, 0444);
static unsigned int ld_cap;		module_param(ld_cap, uint, 0444);
static unsigned int ld_seq;		module_param(ld_seq, uint, 0444);
static int ld_sym_rc = -1;		module_param(ld_sym_rc, int, 0444);
static int ld_proc = -1;		module_param(ld_proc, int, 0444);
static int ld_armed = -1;		module_param(ld_armed, int, 0444);
static unsigned long ld_arm_want;	module_param(ld_arm_want, ulong, 0444);
static unsigned long ld_arm_live;	module_param(ld_arm_live, ulong, 0444);
static long ld_img_len = -1;		module_param(ld_img_len, long, 0444);
static unsigned long ld_img_sum;	module_param(ld_img_sum, ulong, 0444);
static int ld_writes;			module_param(ld_writes, int, 0444);
static int ld_fault;			module_param(ld_fault, int, 0444);
static int ld_why = -1;			module_param(ld_why, int, 0444);
static int ld_load_rc = -1;		module_param(ld_load_rc, int, 0444);
static long ld_pre_len = -1;		module_param(ld_pre_len, long, 0444);
static unsigned long ld_pre_sum;	module_param(ld_pre_sum, ulong, 0444);
static long ld_post_len = -1;		module_param(ld_post_len, long, 0444);
static unsigned long ld_post_sum;	module_param(ld_post_sum, ulong, 0444);
MODULE_PARM_DESC(ld_key, "必须＝0x504F4C44('POLD') 才允许装载；0444 ⇒ 只在 insmod 时定得下来");
MODULE_PARM_DESC(ld_cap, "交图上限(字节)；0＝一口图都收不下；同时受 64MB 硬顶");

static DEFINE_MUTEX(sp_lock);		/* 两个面共用一把锁：这里没有可以并行的读者 */
static unsigned char *sp_in;		/* 命令流暂存(vmalloc ⇒ 必须配对 vfree) */
static struct w1151_stmt *sp_st;
static char *sp_rec;
static struct proc_dir_entry *sp_pe;

static void *ld_buf;			/* 整图暂存。一次按上限分配：中途 remap 容易留下半张图 */
static size_t ld_have;
static unsigned long ld_h;		/* 流式 FNV 中间值(只对 ld_buf 里那 ld_have 个字节有效) */
static struct proc_dir_entry *ld_img_pde;
static struct proc_dir_entry *ld_ctl_pde;

static __typeof__(security_read_policy) *p_ld_read;
static __typeof__(security_load_policy) *p_ld_load;
static struct selinux_state *ld_state;
static unsigned long (*p_kln)(const char *name);

/* 种与素数就是那把尺本身：与探针/腿/宿主同一个 19 位数，改一个数就等于换了一把尺。 */
#define FNV64_IST   1469598103934665603ull
#define FNV64_PRIME 1099511628211ull

static unsigned long sp_fnv_upd(unsigned long h, const unsigned char *b, u64 len)
{
	u64 i;

	for (i = 0; i < len; i++) {
		h ^= b[i];
		h *= FNV64_PRIME;
	}
	return h;
}

static unsigned long sp_fnv(const unsigned char *b, u64 len)
{
	return sp_fnv_upd(FNV64_IST, b, len);
}

/* ★小码 → errno。这一张表就是"不谎报"那件事唯一的落点，所以自测里逐条打(T2)。
 *   四条分支没有一个返回值 > 0；default 也不给正数。 */
static int sp_errno(unsigned int rcc)
{
	switch (rcc) {
	case W1155_RC_PENDING:
		return -EOPNOTSUPP;
	case W1155_RC_E2BIG:
		return -E2BIG;
	case W1155_RC_EINVAL:
		return -EINVAL;
	case W1155_RC_EFAULT:
		return -EFAULT;
	case W1155_RC_ENOMEM:
		return -ENOMEM;
	default:
		return -EOPNOTSUPP; /* 没认领的码退回"什么都没做"，绝不给正数 */
	}
}

/* ===== 符号解析：文本走 kprobe；数据符号 kprobe 取不到 ⇒ 先用 kprobe 拿到 kallsyms_lookup_name
 *   再问它(§6.24 一手：`selinux_state` 在设备 kallsyms 里是 B)。
 *   ★这三个都不在 Module.symvers 里(现查＝0)⇒ 不许在链接期引用它们，否则构建尺那条
 *     "SS/security_* 外流=0"会红，而红了的那次真正说明的是我写错了接法。 */
static unsigned long ld_kp_addr(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	unsigned long addr;
	int ret = register_kprobe(&kp);

	if (ret < 0) {
		pr_warn("ksu_sepol: register_kprobe(%s)=%d\n", name, ret);
		return 0;
	}
	addr = (unsigned long)kp.addr;	/* 本树 kprobe.addr 是 kprobe_opcode_t*，不转就是 -Wint-conversion */
	unregister_kprobe(&kp);
	return addr;
}

static unsigned long ld_sym_addr(const char *name)
{
	unsigned long a = 0;

	if (!p_kln)
		p_kln = (void *)ld_kp_addr("kallsyms_lookup_name");
	if (p_kln)
		a = p_kln(name);
	if (!a)
		a = ld_kp_addr(name);	/* 退化成只认文本符号的老办法 */
	return a;
}

/* 读活策略→算指纹→松手。
 * ★free 的配对是一手数出来的：ss/services.c:3794 用 `vmalloc_user(*len)` 分配，而
 *   selinuxfs.c 的 sel_open_policy/sel_release_policy 两侧都用 `vfree()` ⇒ 这里也必须 vfree。
 *   搞错 free 不是"读数不准"，是内存破坏。 */
static int ld_live(unsigned long *sum, size_t *len)
{
	void *img = NULL;
	size_t n = 0;
	int rc;

	if (!p_ld_read || !ld_state)
		return -ENXIO;
	rc = p_ld_read(ld_state, &img, &n);
	if (rc) {
		pr_warn("ksu_sepol: read_policy=%d\n", rc);
		return rc;
	}
	*sum = sp_fnv(img, (u64)n);
	*len = n;
	vfree(img);
	return 0;
}

/* ===== GO：判定只在 w1161_gate() 里；这一句之后才允许有第一声 load ===== */
static void ld_go(void)
{
	struct w1161_req r;
	size_t cap = min_t(size_t, ld_cap, LD_MAX);
	size_t n0 = 0;
	unsigned long live = 0, post = 0;
	int why, rc;

	ld_seq++;
	memset(&r, 0, sizeof(r));
	r.key_ok = (ld_key == LD_KEY_WANT);
	r.syms_ok = (p_ld_read && p_ld_load && ld_state);
	r.have_img = (ld_buf && ld_have);
	r.fault = ld_fault;
	r.len = ld_have;
	r.cap = cap;
	r.magic_want = SELINUX_MAGIC;	/* 从树里的头取，不凭记忆(记忆里那个 0x3000012 已被做成变异) */
	r.taglen_want = LD_STRLEN;
	r.head = (const w1161_u8 *)ld_buf;

	/* 甲尺：门要求"当下重读的活策略指纹"，所以这一步必须在调用门**之前**做；
	   读不到就照实记 READPOL，不许拿上一次的值冒充"读到了"。 */
	rc = ld_live(&live, &n0);
	r.readpol_ok = (rc == 0);
	r.live_sum = live;
	ld_pre_sum = live;
	ld_pre_len = (rc == 0) ? (long)n0 : -1;
	r.armed = (ld_armed == 1);
	r.armed_sum = ld_arm_want;

	why = w1161_gate(&r);
	ld_why = why;
	if (why != W1161_OK) {
		if (sp_verbose)
			pr_info("ksu_sepol: refuse seq=%u why=%d(%s)\n", ld_seq, why,
				w1161_why_name(why));
		return;
	}
	if (sp_verbose)
		pr_info("ksu_sepol: go seq=%u img=%zu\n", ld_seq, ld_have);
	rc = p_ld_load(ld_state, ld_buf, ld_have);	/* 整条路线里最贵的一条指令 */
	ld_load_rc = rc;
	if (rc) {
		pr_warn("ksu_sepol: load_policy(%zu)=%d\n", ld_have, rc);
		return;
	}
	/* ★装后同一把尺再读一遍。读不到＝这一格记"未测"(post_len=-1/post_sum=0)，不许留旧值冒充。 */
	if (ld_live(&post, &n0)) {
		ld_post_len = -1;
		ld_post_sum = 0;
	} else {
		ld_post_len = (long)n0;
		ld_post_sum = post;
	}
}

static ssize_t ld_ctl_write(struct file *f, const char __user *ubuf, size_t count, loff_t *ppos)
{
	char buf[128];
	unsigned long long v = 0;
	ssize_t ret = -EINVAL;
	unsigned long want;
	int rc, cmd;		/* 1=ARM 2=GO 3=RESET */

	if (count >= sizeof(buf))
		return -E2BIG;		/* 命令是短文；往这个口写长东西不算命令 */
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';
	if (count && buf[count - 1] == '\n')
		buf[count - 1] = '\0';

	/* 先解析再动状态：三个词元之外一律 -EINVAL，且**不碰**任何共享变量。 */
	if (!strncmp(buf, "ARM ", 4)) {
		rc = kstrtoull(buf + 4, 10, &v);
		if (rc)
			return rc;
		cmd = 1;
	} else if (!strcmp(buf, "GO")) {
		cmd = 2;
	} else if (!strcmp(buf, "RESET")) {
		cmd = 3;
	} else {
		return -EINVAL;
	}
	want = (unsigned long)v;

	/* ★整段在一个锁里：GO 会读 ld_buf/ld_have，而交图那一腿随时可能在追加同一块缓冲。
	   探针没有这把锁(它只有一条腿在写)，这里是两个口共用一块内存，就必须有。 */
	mutex_lock(&sp_lock);
	switch (cmd) {
	case 1: {
		unsigned long live = 0;
		size_t n = 0;

		rc = ld_live(&live, &n);
		if (rc) {
			ld_armed = 0;	/* 甲尺读不到＝"没量到"，与"量到但不符"(－1)是两个答案 */
			ret = rc;
			break;
		}
		ld_arm_live = live;
		ld_arm_want = want;
		ld_armed = (live == want) ? 1 : -1;
		ld_seq++;
		ret = count;
		break;
	}
	case 2:
		ld_go();		/* ★本文件里 p_ld_load 的第一声、也是唯一一声调用在这条语句下游 */
		ret = count;
		break;
	default:
		vfree(ld_buf);
		ld_buf = NULL;
		ld_have = 0;
		ld_h = FNV64_IST;
		ld_fault = 0;
		ld_armed = -1;
		ld_img_len = -1;
		ld_img_sum = 0;
		ld_seq++;
		ret = count;
		break;
	}
	mutex_unlock(&sp_lock);
	return ret;
}

static const struct file_operations ld_ctl_fops = {
	.owner = THIS_MODULE,
	.write = ld_ctl_write,
	.llseek = default_llseek,
};

/* ===== 交图口：写＝追加(流式记 FNV)，读＝把暂存的图**原样**读回 =====
 *   读回去不是多余的：那是"内核里那块缓冲里的东西＝我交进去的"唯一一把独立的尺(第 96 发就是这么
 *   对表 md5 的)。图和命令流分两个口 ⇒ 两边不会互相冒充。 */
static ssize_t ld_img_write(struct file *f, const char __user *ubuf, size_t count, loff_t *ppos)
{
	size_t cap = min_t(size_t, ld_cap, LD_MAX);
	size_t old;

	if (!count)
		return -EINVAL;
	if (ld_fault)
		return -EIO;		/* 只有 RESET 能清；半张图绝不允许被装上去 */
	if (!cap)
		return -ENOSPC;		/* ld_cap 默认 0＝这一面根本没打开 */
	mutex_lock(&sp_lock);
	old = ld_have;			/* ★这块必须在锁里读：锁外读到的可能正被人追加 */
	if (!ld_buf) {
		ld_buf = vmalloc(cap);
		if (!ld_buf) {
			ld_why = W1161_ALLOC;
			mutex_unlock(&sp_lock);
			return -ENOMEM;
		}
		ld_have = 0;
		ld_h = FNV64_IST;
		old = 0;
	}
	if (ld_have + count > cap) {
		mutex_unlock(&sp_lock);
		return -EFBIG;
	}
	if (copy_from_user((unsigned char *)ld_buf + ld_have, ubuf, count)) {
		ld_fault = 1;
		ld_why = W1161_FAULT;
		mutex_unlock(&sp_lock);
		return -EFAULT;
	}
	ld_h = sp_fnv_upd(ld_h, (const unsigned char *)ld_buf + old, count);
	ld_have += count;
	ld_writes++;
	ld_img_len = (long)ld_have;
	ld_img_sum = ld_h;
	mutex_unlock(&sp_lock);
	return count;
}

static ssize_t ld_img_read(struct file *f, char __user *ubuf, size_t count, loff_t *ppos)
{
	ssize_t rc;

	mutex_lock(&sp_lock);
	rc = simple_read_from_buffer(ubuf, count, ppos, ld_buf, ld_have);
	mutex_unlock(&sp_lock);
	return rc;
}

static const struct file_operations ld_img_fops = {
	.owner = THIS_MODULE,
	.read = ld_img_read,
	.write = ld_img_write,
	.llseek = default_llseek,
};

void apply_kernelsu_rules(void)
{
	/* 6.x 版会往策略里塞 allow 规则；5.4 这条路不通 ⇒ 什么都不做。
	 * 影响面 = KSU 的"自定义 sepolicy 规则"特性，不参与 uid/cap 授权路径。 */
}

static ssize_t sp_read(struct file *f, char __user *buf, size_t len, loff_t *off)
{
	ssize_t rc = 0;
	size_t n;

	mutex_lock(&sp_lock);
	if (sp_rec && *off >= 0 && (int)*off < sp_rec_bytes) {
		n = (size_t)(sp_rec_bytes - (int)*off);
		if (n > len)
			n = len;
		rc = copy_to_user(buf, sp_rec + (size_t)*off, n) ? -EFAULT : (ssize_t)n;
		if (rc > 0)
			*off += rc;
	}
	mutex_unlock(&sp_lock);
	return rc;
}

static const struct file_operations sp_fops = {
	.owner = THIS_MODULE,
	.read = sp_read,
	.llseek = generic_file_llseek,
};

/* 分配暂存＋建 proc 节点。调用者持锁。返回 0=可用 */
static int sp_setup(void)
{
	if (!sp_in)
		sp_in = vmalloc(W1151_IN_MAX);
	/* 5.4 的 vmalloc.h **没有** vmalloc_array(5.10 才进来) ⇒ 自己乘，并先夹住条数防乘爆 */
	if (!sp_st)
		sp_st = vmalloc((size_t)SP_SLOTS * sizeof(*sp_st));
	if (!sp_rec)
		sp_rec = vmalloc(SP_REC_CAP);
	if (!sp_in || !sp_st || !sp_rec)
		return -ENOMEM;
	if (!sp_pe)
		sp_pe = proc_create("ksu_sepol", 0400, NULL, &sp_fops);
	if (!sp_pe)
		return -ENOMEM;
	return 0;
}

/* 装载面的武装：解三个符号＋建两个口。
 * ★符号解不到**不算失败**(ld_sym_rc 会少一位，门在 GO 时报 SYM＝2)：这一面是"给门用的"，
 *   口没建起来才是失败——口没了就既进不去也读不到，等于把仪器拆了。 */
static int ld_setup(void)
{
	unsigned long a;

	ld_sym_rc = 0;
	a = ld_sym_addr("security_read_policy");
	if (a) {
		p_ld_read = (void *)a;
		ld_sym_rc |= SYM_READ;
	}
	a = ld_sym_addr("security_load_policy");
	if (a) {
		p_ld_load = (void *)a;
		ld_sym_rc |= SYM_LOAD;
	}
	a = ld_sym_addr("selinux_state");
	if (a) {
		ld_state = (void *)a;
		ld_sym_rc |= SYM_STATE;
	}
	if (!ld_img_pde)
		ld_img_pde = proc_create("ksu_sepol_img", 0600, NULL, &ld_img_fops);
	if (!ld_ctl_pde)
		ld_ctl_pde = proc_create("ksu_sepol_ctl", 0600, NULL, &ld_ctl_fops);
	ld_proc = (ld_img_pde ? 1 : 0) + (ld_ctl_pde ? 2 : 0);
	if (!ld_img_pde || !ld_ctl_pde)
		return -ENOMEM;
	return 0;
}

/* insmod 时 `sp_arm=1` ⇒ 把两个面一起武装起来，并**把结果读回参数本身**
 * (0=没武装，1=两面都起来了，2=武装失败)。腿只认这个读数，不认"我写了参数"。
 * ★注意语义比 rc75 宽了一格：现在 1 要求**装载面的两个口也建起来了**。 */
static int sp_arm_set(const char *v, const struct kernel_param *kp)
{
	unsigned int n;
	int r;

	if (kstrtouint(v, 10, &n))
		return -EINVAL;
	mutex_lock(&sp_lock);
	sp_arm = n;
	if (n == 1) {
		r = sp_setup();
		if (!r)
			r = ld_setup();
		sp_arm = (r == 0) ? 1u : 2u;
	}
	mutex_unlock(&sp_lock);
	return 0;
}
static const struct kernel_param_ops sp_arm_ops = {
	.set = sp_arm_set,
	.get = param_get_uint,
};
module_param_cb(sp_arm, &sp_arm_ops, &sp_arm, 0444); /* arg 必须给真变量：param_get_uint 会去读它 */

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	struct w1151_report rep;
	unsigned int rcc;
	unsigned long long sum_len = 0;
	int trunc = 0, total, have;

	mutex_lock(&sp_lock);
	if (sp_setup() != 0) {
		sp_rc = W1155_RC_ENOMEM;
		mutex_unlock(&sp_lock);
		return -ENOMEM; /* 暂存都分不出来＝什么都没看过，也不碰策略 */
	}
	sp_calls++;
	sp_seq++;
	memset(&rep, 0, sizeof(rep));
	have = (data_len > 0 && data_len <= W1151_IN_MAX && user_data &&
		copy_from_user(sp_in, user_data, (size_t)data_len) == 0);
	sp_bytes = (long)data_len;
	if (!have) {
		/* 超容量＝整条流都没读进来看过；空流与 copy 失败分开记(它们是两种答案) */
		if (data_len > W1151_IN_MAX) {
			rcc = W1155_RC_E2BIG;
			rep.why = W1151_E_INPUT_BIG;
		} else if (data_len == 0) {
			rcc = W1155_RC_EINVAL;
			rep.why = W1151_E_EMPTY;
		} else {
			rcc = W1155_RC_EFAULT;
			rep.why = W1151_E_TRUNC_HDR;
		}
	} else {
		sum_len = data_len;
		w1151_decode_stream(sp_in, data_len, sp_st, SP_SLOTS, &rep);
		rcc = w1155_rc_for(rep.why);
	}
	sp_sum = sp_fnv(sp_in, (u64)sum_len);
	sp_why = (int)rep.why;
	sp_n = (int)rep.n;
	sp_bad_at = (long)rep.bad_at;
	sp_max_arg = rep.max_arg_len;
	sp_rc = (int)rcc;
	/* ★第三方证人：期望字节数那条独立算式(不走解码的逐字节路径) vs 交进来的长度。
	   没 copy 进来看过的流不作数(那时 st 里是上一轮的旧东西)。 */
	sp_lenmatch = have && w1151_expect_bytes(sp_st, rep.n) == data_len ? 1 : 0;
	memset(sp_rec, 0, SP_REC_CAP);
	total = w1155_render(sp_rec, (int)SP_REC_CAP, &trunc, sp_seq, sp_calls, sp_in,
			     (w1151_u64)data_len, (w1151_u64)sp_sum, sp_st, &rep,
			     sp_lenmatch);
	sp_rec_trunc = trunc;
	sp_rec_bytes = total >= (int)SP_REC_CAP ? (int)SP_REC_CAP - 1 : total;
	if (sp_verbose)
		pr_info("ksu_sepol: seq=%u bytes=%ld why=%d n=%d rc=%u trunc=%d\n", sp_seq,
			sp_bytes, sp_why, sp_n, rcc, trunc);
	mutex_unlock(&sp_lock);
	return sp_errno(rcc);
}

/* ★收尾：main.c 的 cleanup 里加一行 `ksu_sepol_put();`(构建脚本现 sed＋读回计数)。
 *   两个面的节点与四块 vmalloc 都得还——rmmod 之后留着节点，下一次装载就会撞上一个不属于本轮的读数。 */
void __exit ksu_sepol_put(void)
{
	mutex_lock(&sp_lock);
	if (sp_pe)
		proc_remove(sp_pe);
	sp_pe = NULL;
	if (ld_img_pde)
		proc_remove(ld_img_pde);
	ld_img_pde = NULL;
	if (ld_ctl_pde)
		proc_remove(ld_ctl_pde);
	ld_ctl_pde = NULL;
	vfree(sp_in);
	vfree(sp_st);
	vfree(sp_rec);
	vfree(ld_buf);
	sp_in = NULL;
	sp_st = NULL;
	sp_rec = NULL;
	ld_buf = NULL;
	ld_have = 0;
	mutex_unlock(&sp_lock);
}
