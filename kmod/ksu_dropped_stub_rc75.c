// SPDX-License-Identifier: GPL-2.0
/* 路线 B 的降级桩 —— rc75 候选：**把 `SET_SEPOLICY` 那条口接上"解码＋待决记录"**(装载门另发)。
 *
 * 被剔掉的原实现(selinux/sepolicy.c、selinux/rules.c)依赖 6.x 的 SELinux SS 内部结构
 *   (filename_trans_key / filename_trans_datum.stypes / sidtab / selinux_state.policy)，本树 5.4 里
 *   不存在(依据见 md §6.6/§6.7)。§344 一手读源码之后知道：那条口的载荷**不是整张策略图**，
 *   而是 ksud 的**原子规则命令流** ⇒ 解码这一层根本不需要 SS，一份可移植的字节码就够(w1151 核心)。
 *
 * ★这一版**仍然不落地任何规则**，它只做两件诚实的事：
 *   (1) 把交进来的命令流**解一遍**(拒收的形状照实记下来)，
 *   (2) 在 `/proc/ksu_sepol` 留一份**事后能审计**的账——官方 ksud 会把我们的负返回值静默吞掉(#236)，
 *       没有这份账，"那个模块的 sepolicy.rule 到底走到哪一步"就没有任何读数。
 *   返回值口径(§344：ksud 把它当"应用了几条")：**永远不是正数**。解干净＝-EOPNOTSUPP(有账)，
 *   流不合法＝-EINVAL(账里写 why)，超容量＝-E2BIG，copy 不全＝-EFAULT，分不出内存＝-ENOMEM。
 * ★装载那一半(第 96 发验过的 `security_load_policy` 门控入口)刻意**没接进来**：它要的是"用户态算好的
 *   整图"，那道门要三把闸一起装才安全(钥匙＋活策略基线指纹＋尺寸/魔数)。两件一起改会把两种失败
 *   混成一件，所以分开发(账在 md §6.546)。
 *
 * ★★签名必须逐字对齐 kernel/selinux/selinux.h:34：`int handle_sepolicy(void __user *, u64)`。
 *   上一版把它写成三参——因为这个文件不 include selinux.h，编译器不报错、链接也不查类型 ⇒ 一个静默的
 *   ABI 错。教训：**桩必须 include 它要实现的那个头**，让编译器替你核对签名(rc67 起一直这么做)。
 * ★建节点/分配走 `sp_arm` 这个参数写回口(insmod 时显式给 1 才建)，而不是偷 `module_init`：
 *   一个模块只能有一个 init，那是 main.c 的。⇒ 装的时候不给 `sp_arm=1` 就没有节点也没有暂存，
 *   这条与 §293 那条纪律同形：**被测自己带的开关，调用方要显式传值并把参数本身读回来**。 */
#include <linux/err.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h> /* proc_create 的声明——rc38/rc40 那个坑，别再犯第二次 */
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

#include "selinux.h"
#include "w1151_sepolicy_core.h"
#include "w1155_sepol_record.h"

#define SP_SLOTS 512u    /* 一次调用最多收几条(超出＝TOO_MANY，照实记，不静默丢) */
#define SP_REC_CAP 65536u /* 600 条语句的记录就要 ~25K ⇒ 8K 会在自家账上截断(自测抓到过) */ /* 记录缓冲；不够就在尾巴明写 TRUNC，不许悄悄少打一行 */

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

static DEFINE_MUTEX(sp_lock);
static unsigned char *sp_in; /* 命令流暂存(vmalloc ⇒ 必须配对 vfree) */
static struct w1151_stmt *sp_st;
static char *sp_rec;
static struct proc_dir_entry *sp_pe;

void apply_kernelsu_rules(void)
{
	/* 6.x 版会往策略里塞 allow 规则；5.4 这条路不通 ⇒ 什么都不做。
	 * 影响面 = KSU 的"自定义 sepolicy 规则"特性，不参与 uid/cap 授权路径。 */
}

static unsigned long sp_fnv(const unsigned char *b, u64 len)
{
	u64 h = 1469598103934665603ull, i;

	for (i = 0; i < len; i++) {
		h ^= b[i];
		h *= 1099511628211ull;
	}
	return (unsigned long)h;
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

/* insmod 时 `sp_arm=1` ⇒ 立刻把暂存与 /proc 节点立起来，并**把结果读回参数本身**
 * (0=没武装，1=已武装，2=武装失败)。腿只认这个读数，不认"我写了参数"。 */
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
 *   proc 节点与三块 vmalloc 都得还——rmmod 之后留着节点，下一次装载就会撞上一个不属于本轮的读数。 */
void __exit ksu_sepol_put(void)
{
	mutex_lock(&sp_lock);
	if (sp_pe)
		proc_remove(sp_pe);
	sp_pe = NULL;
	vfree(sp_in);
	vfree(sp_st);
	vfree(sp_rec);
	sp_in = NULL;
	sp_st = NULL;
	sp_rec = NULL;
	mutex_unlock(&sp_lock);
}
