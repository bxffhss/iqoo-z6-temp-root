// SPDX-License-Identifier: GPL-2.0
/* w1151 探针(#238 部件①上机前的那一步)：把**宿主自测刚验过的那一份**解码核心，
 * 用出货同款工具链(clang/ld.lld, 5.4.281 头)编进 aarch64 模块，并给它一个喂字节、
 * 读回执的口。目的只有两件，都不碰策略：
 *   (甲)证明这份核心在本机编译器与本机内核头下编得出来、warning=0；
 *   (乙)证明同一段码在 aarch64 内核里跑出来的读数，与 x86 宿主上跑同一份码的读数一致。
 * ★这一件**不解析策略图、不碰 security_load_policy、不写 /sys/fs/selinux 下任何节点** ⇒ 上机风险比 B′ 低一档。
 * ★将来动出货 ko 时，搬过去的就是 w1151_sepolicy_core.h 这同一份(不许"到 ko 里再手写一遍")，
 *   函数签名要用 uapi 那一份 `int handle_sepolicy(void __user *, u64)`(§6.542：
 *   现在 kernel/selinux/dropped_stub.c:11 是 6.x 的旧形状，与 selinux.h:34 不一致，
 *   只因那是**直接调用**才没被 KCFI 拦下——一旦它真要读参数，这个不一致就是雷)。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/errno.h>

#include "w1151_sepolicy_core.h"

/* 与 w1140 同一把哈希(内核里 security_read_policy 那条链上用的 FNV-1a 64、19 位种子)：
 * 这样"腿 push 的文件在 PC 上算的 FNV"与"内核里 staged 那份现算的 FNV"是同一把尺的两端。 */
#define PD_FNV_IST 1469598103934665603ULL
#define PD_FNV_PRIME 1099511628211ULL

static unsigned int pd_abi = 1;			module_param(pd_abi, uint, 0444);
static unsigned int pd_slots = 4369;		module_param(pd_slots, uint, 0444);
static unsigned int pd_verbose;			module_param(pd_verbose, uint, 0444);
MODULE_PARM_DESC(pd_slots, "一次最多解出多少条语句(默认 4369＝IN_MAX/最小一条 15 字节)");

/* ---- 读数(全 0444＝只在 insmod 后由内核写、腿只读) ---- */
static int pd_calls = -1;			module_param(pd_calls, int, 0444);
static int pd_why = -1;				module_param(pd_why, int, 0444);
static int pd_n = -1;				module_param(pd_n, int, 0444);
static long pd_bytes = -1;			module_param(pd_bytes, long, 0444);
static long pd_bad_at = -1;			module_param(pd_bad_at, long, 0444);
static unsigned int pd_max_arg;			module_param(pd_max_arg, uint, 0444);
static int pd_lenmatch = -1;			module_param(pd_lenmatch, int, 0444);
static unsigned long pd_sum;			module_param(pd_sum, ulong, 0444);
static int pd_alloc;				module_param(pd_alloc, int, 0444);
static int pd_rec_bytes = -1;			module_param(pd_rec_bytes, int, 0444);
static int pd_rec_trunc = -1;			module_param(pd_rec_trunc, int, 0444);
static long pd_writes = -1;			module_param(pd_writes, long, 0444);

static unsigned char *pd_buf;			/* 命令流暂存(vmalloc ⇒ 配对 vfree) */
static size_t pd_have;
static unsigned long long pd_h = PD_FNV_IST;
static struct w1151_stmt *pd_st;		/* 解出来的语句(按 insmod 时的 pd_slots 一次分够) */
static char *pd_rec;				/* 给人看的文本记录(截断是明说的，不装完整) */
#define PD_REC_MAX (64 * 1024)

static unsigned long long pd_fnv_upd(unsigned long long h, const unsigned char *p, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++)
		h = (h ^ p[i]) * PD_FNV_PRIME;
	return h;
}

/* 一条语句印成一行。非可打印字节换成 '.'(记录给人读，字节真值另有 _in 那个口原样读回)。 */
static int pd_fmt_stmt(char *to, size_t cap, const struct w1151_stmt *s, const unsigned char *buf,
		       unsigned int idx)
{
	unsigned int i;
	size_t used;
	int w;

	used = scnprintf(to, cap, "STMT %u cmd=%u sub=%u argc=%u", idx, s->cmd, s->subcmd, s->argc);
	for (i = 0; i < s->argc && used + 8 < cap; i++) {
		char tmp[300];
		unsigned int j, l = s->arg[i].len;

		if (l > W1151_ARG_MAX)
			l = W1151_ARG_MAX;
		for (j = 0; j < l; j++) {
			unsigned char c = buf[s->arg[i].off + j];

			tmp[j] = (c >= 0x20 && c < 0x7f) ? (char)c : '.';
		}
		tmp[l] = '\0';
		w = scnprintf(to + used, cap - used, " a%u=%u:%s", i, s->arg[i].len, tmp);
		used += w;
	}
	if (used + 1 < cap)
		used += scnprintf(to + used, cap - used, "\n");
	return (int)used;
}

/* DECODE：对暂存的字节跑那份核心，并把读数与文本记录一次做完。 */
static void pd_decode(void)
{
	struct w1151_report rep;
	w1151_u64 back;
	size_t used = 0;
	unsigned int i;
	int rc;

	pd_calls++;
	rc = w1151_decode_stream(pd_buf, pd_have, pd_st, pd_slots, &rep);
	pd_why = (rc == 0) ? (int)W1151_OK : (int)rep.why;
	pd_n = (int)rep.n;
	pd_bad_at = (long)rep.bad_at;
	pd_max_arg = rep.max_arg_len;
	pd_bytes = (long)pd_have;
	/* ★长度自洽在核内也过一遍：解出来的 (argc,len) 反推的字节数必须等于喂进去的。
	 *   它是"收下了"与"收下的东西自洽"之间的差别(§231：甲尺曾经拿 md5 相等当证人)。 */
	back = w1151_expect_bytes(pd_st, rep.n);
	pd_lenmatch = (rc == 0 && back == (w1151_u64)pd_have) ? 1 : 0;

	if (pd_rec) {
		used += scnprintf(pd_rec + used, PD_REC_MAX - used,
				  "PD v1 calls=%d why=%d n=%d bytes=%lu bad_at=%lld max_arg=%u lenmatch=%d sum=%llu slots=%u\n",
				  pd_calls, pd_why, pd_n, (unsigned long)pd_have,
				  (long long)pd_bad_at, pd_max_arg, pd_lenmatch,
				  (unsigned long long)pd_h, pd_slots);
		if (pd_why == 0) {
			for (i = 0; i < rep.n && used + 600 < PD_REC_MAX; i++)
				used += pd_fmt_stmt(pd_rec + used, PD_REC_MAX - used, &pd_st[i],
						    pd_buf, i);
			pd_rec_trunc = (i < rep.n) ? 1 : 0;
			if (pd_rec_trunc && used + 40 < PD_REC_MAX)
				used += scnprintf(pd_rec + used, PD_REC_MAX - used,
						  "TRUNC 只印了前 %u 条，一共 %d 条\n", i, pd_n);
		} else {
			pd_rec_trunc = 0;
			if (used + 80 < PD_REC_MAX)
				used += scnprintf(pd_rec + used, PD_REC_MAX - used,
						  "REJECT 未印语句(why=%d 时前 n 条不可当真)\n",
						  pd_why);
		}
		pd_rec_bytes = (int)used;
	}
	if (pd_verbose)
		pr_info("w1151 DECODE calls=%d why=%d n=%d bytes=%lu lenmatch=%d\n", pd_calls,
			pd_why, pd_n, (unsigned long)pd_have, pd_lenmatch);
}

/* ===== /proc/w1151_in：写＝把命令流喂进来(累加)；读＝把内核里这一份原样读回(第三方证人) ===== */
static ssize_t pd_in_write(struct file *f, const char __user *ubuf, size_t count, loff_t *ppos)
{
	size_t old = pd_have;

	if (!count)
		return -EINVAL;
	if (count > W1151_IN_MAX)		/* 一口就超上限的写，直接拒，别悄悄截 */
		return -EFBIG;
	if (!pd_buf) {
		pd_buf = vmalloc(W1151_IN_MAX);
		if (!pd_buf)
			return -ENOMEM;
		pd_alloc = 1;
		pd_have = 0;
		pd_h = PD_FNV_IST;
		old = 0;
	}
	if (pd_have + count > W1151_IN_MAX)
		return -EFBIG;
	if (copy_from_user(pd_buf + pd_have, ubuf, count))
		return -EFAULT;
	pd_h = pd_fnv_upd(pd_h, pd_buf + old, count);
	pd_have += count;
	pd_writes++;
	pd_bytes = (long)pd_have;
	pd_sum = (unsigned long)pd_h;
	return count;
}

static ssize_t pd_in_read(struct file *f, char __user *ubuf, size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos, pd_buf, pd_have);
}

static const struct file_operations pd_in_fops = {
	.owner = THIS_MODULE,
	.read = pd_in_read,
	.write = pd_in_write,
	.llseek = default_llseek,
};

/* ===== /proc/w1151_ctl：写＝命令(DECODE/RESET)；读＝文本记录 ===== */
static ssize_t pd_ctl_write(struct file *f, const char __user *ubuf, size_t count, loff_t *ppos)
{
	char buf[64];

	if (count >= sizeof(buf))
		return -E2BIG;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';
	if (count && buf[count - 1] == '\n')
		buf[count - 1] = '\0';

	if (!strcmp(buf, "DECODE")) {
		if (!pd_have)
			return -EINVAL;		/* 没喂过东西就解＝拿空当读数 */
		pd_decode();
		return count;
	}
	if (!strcmp(buf, "RESET")) {
		pd_have = 0;
		pd_h = PD_FNV_IST;
		pd_why = -1;
		pd_n = -1;
		pd_bytes = -1;
		pd_bad_at = -1;
		pd_max_arg = 0;
		pd_lenmatch = -1;
		pd_sum = 0;
		pd_rec_bytes = -1;
		pd_rec_trunc = -1;
		return count;
	}
	return -EINVAL;
}

static ssize_t pd_ctl_read(struct file *f, char __user *ubuf, size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos, pd_rec,
				       pd_rec_bytes < 0 ? 0 : (size_t)pd_rec_bytes);
}

static const struct file_operations pd_ctl_fops = {
	.owner = THIS_MODULE,
	.read = pd_ctl_read,
	.write = pd_ctl_write,
	.llseek = default_llseek,
};

static struct proc_dir_entry *pd_in_pde, *pd_ctl_pde;

static int __init pd_init(void)
{
	if (!pd_slots || pd_slots > 8192)
		pd_slots = 4369;		/* 夹到"最小一条 15 字节装满 IN_MAX"那一档，再多也没意义 */
	/* ★这棵树(5.4.281)的 vmalloc.h 里**没有** vmalloc_array(那是 5.10 才进来的)，
	 *   clang 把 implicit declaration 当 error ⇒ 只能自己乘。上面已把 pd_slots 夹死，乘不爆。 */
	pd_st = vmalloc((size_t)pd_slots * sizeof(*pd_st));
	if (!pd_st)
		return -ENOMEM;
	pd_rec = vmalloc(PD_REC_MAX);		/* 记录口分不到也不致命：读数全在参数里 */
	if (!pd_rec)
		pr_info("w1151 记录口没分到(64KB) ⇒ 只走参数读数\n");
	pd_in_pde = proc_create("w1151_in", 0600, NULL, &pd_in_fops);
	pd_ctl_pde = proc_create("w1151_ctl", 0600, NULL, &pd_ctl_fops);
	if (!pd_in_pde || !pd_ctl_pde) {
		if (pd_in_pde)
			proc_remove(pd_in_pde);
		if (pd_ctl_pde)
			proc_remove(pd_ctl_pde);
		vfree(pd_st);
		vfree(pd_rec);
		pd_st = NULL;
		return -ENODEV;
	}
	pr_info("w1151 in ab=%d slots=%u rec=%d\n", 1, pd_slots, pd_rec ? 1 : 0);
	return 0;
}

static void __exit pd_exit(void)
{
	proc_remove(pd_in_pde);
	proc_remove(pd_ctl_pde);
	vfree(pd_buf);
	vfree(pd_st);
	vfree(pd_rec);
}

module_init(pd_init);
module_exit(pd_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("w1151 in-kernel decoder probe for ksud SET_SEPOLICY stream (#238 part1)");
