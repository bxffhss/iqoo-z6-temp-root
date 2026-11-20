// SPDX-License-Identifier: GPL-2.0
/* w1140_polload.c —— #237(B′)：模块侧「整图装载」入口探针。零解析、三道闸、默认全关。
 *
 * 这一件只答一个问题：**外部模块在运行期把一份"用户态算好的完整策略图"交给设备自己的
 *   security_load_policy()，这台 5.4.281 收不收；收下来的是不是我们交进去的那张**。
 *   它不答"社区模块能装"——那一格的真墙仍是厂商类型表里没有 nsfs(§6.528 的"口径不许越线")。
 *
 * ★为什么不走 A 版(把 SS 源码编进模块，w986)：A 版自己解析/重写策略字节＝第 81~85 发那种
 *   "装载后 16~30 秒无 printk 的 PS_HOLD"的头号嫌疑人(归因至今未闭)。B′ **一个字节都不解析**，
 *   与内核相接的只有两处：交进去的字节、以及 security_read_policy() 交出来的字节。
 *
 * 三道闸(裸 insmod 结构上进不到装载那一步)：
 *   ① `pl_key` 必须等于 0x504F4C44('POLD')，且参数是 0444 ⇒ 只在 insmod 那一刻定得下来，
 *     运行期没有任何用户态路径能把"允许装载"打开。
 *   ② ARM 握手：向 /proc/w1140_ctl 写 `ARM <十进制FNV>`；GO 时模块**重新**读一遍活策略、
 *     算同一个 FNV，与武装值不等 ⇒ 拒。⇒ 交进去的图必须是"从这份活策略派生"的，
 *     中途被别处装载过(腿自己写过 /sys/fs/selinux/load 也算)就自动失效。
 *   ③ 边界：长度在 [PL_HDR_MIN, min(pl_cap, PL_MAX)] 内，头四个字节必须等于 SELINUX_MAGIC。
 *     下限 32 是从 ss/policydb.c 里那三段 next_entry 数出来的"最小可解析头"，**不是**按
 *     "手上第一份输入有多大"定的(例 226：那样闸会把自己的合法输入拒掉)。
 *
 * 判据不放 dmesg，只放 0444 参数 ⇒ adb shell(uid 2000) 无需 root 就能读，翻了执法也不瞎(§6.441)。
 * init 一律返回 0(常驻)：返回非 0 会把参数一起摘掉 ⇒ 失败也要读得到。收尾由腿做(读回→rmmod→reboot)。
 *
 * ★正对照(例 224／"三判据+正对照")：`pl_ctrl_ctx`＝装载前后**都**该解得开的现成标签，
 *   `pl_test_ctx`＝只在新图里才有的标签，两条用同一把尺(设备的 security_context_to_sid)各量两次。
 *   `chcon` 的 rc 和 `ls -Z` 读回都不是"类型存不存在"的证人——只有这一把是。
 *
 * ★已知没做的事(证件要按这个口径写，不许宣称"与写 /sys/fs/selinux/load 全等价")：
 *   我们既不调 sel_make_policy_nodes()，也不持 selinuxfs 的 fsi->mutex ⇒ /sys/fs/selinux 下
 *   class/bool 那些节点视图停在旧图上(策略本体与决策路径是新的——avc_ss_reset 在 load 里面)。
 *   ⇒ 下令 GO 那一刻，设备上不该有人正开着 /sys/fs/selinux/policy。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/string.h>
#include <linux/kprobes.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>

/* 设备自己的那一份头：四个原型 + SELINUX_MAGIC(经 linux/magic.h 带进来) 全从这里取，
 * 不凭记忆写原型——KCFI 的 TypeId 是按函数类型算的，抄错要到运行期第一声调用才炸。 */
#include "security.h"

#define PL_KEY_WANT 0x504F4C44u			/* 'POLD' */
#define PL_HDR_MIN  32u				/* magic4 + strlen4 + "SE Linux"8 + (vers 与后 3 个 u32)16
						 * —— 一手 ss/policydb.c:policydb_read 的三段 next_entry */
#define PL_STRLEN   8u				/* strlen(POLICYDB_STRING)：一手 ss/policydb.h:336 的 "SE Linux"。
						 * 这里不 include ss/policydb.h——那条链在 w985 撞过
						 * ss/conditional.h 与 include/conditional.h 共用 guard 的坑。 */
#define PL_VER_OFF  16u
#define PL_MAX      (64u * 1024u * 1024u)	/* 与 selinuxfs.c:sel_write_load 的闸同值 */

/* pl_why：在哪一步拒的。0＝GO 一路走到 security_load_policy(成败看 pl_load_rc，别看这里)。 */
#define W_OK          0
#define W_NOKEY       1	/* pl_key != 'POLD' */
#define W_SYM         2	/* 符号没解全 */
#define W_NOIMG       3	/* 还没交图，或那块缓冲出过事 */
#define W_TOOSMALL    4
#define W_TOOLONG     5
#define W_BADMAGIC    6
#define W_BADSTR      7	/* 头里那个"串长"字段不等于 strlen(POLICYDB_STRING) */
#define W_ARMMISMATCH 8	/* 没武装，或 GO 时重读的活策略 FNV ≠ 武装值 */
#define W_ALLOC       9
#define W_FAULT      10	/* copy_from_user 出过事 ⇒ 缓冲不再可信，只能 RESET 重交 */
#define W_READPOL    11	/* security_read_policy 自己就红了 ⇒ 甲尺读不到，判据不成立 */

/* ===== 读数(全 0444：执法态翻了也读得到) ===== */
static unsigned int pl_key;				module_param(pl_key, uint, 0444);
static unsigned int pl_cap;				module_param(pl_cap, uint, 0444);
static int pl_abi = 1;					module_param(pl_abi, int, 0444);
static int pl_why = -1;					module_param(pl_why, int, 0444);
static int pl_seq;					module_param(pl_seq, int, 0444);
static int pl_sym_rc;					module_param(pl_sym_rc, int, 0444);
static int pl_proc;					module_param(pl_proc, int, 0444);
static int pl_armed = -1;				module_param(pl_armed, int, 0444);
static unsigned long pl_arm_want;			module_param(pl_arm_want, ulong, 0444);
static unsigned long pl_arm_live;			module_param(pl_arm_live, ulong, 0444);
static long pl_img_len = -1;				module_param(pl_img_len, long, 0444);
static unsigned long pl_img_sum;			module_param(pl_img_sum, ulong, 0444);
static int pl_img_wvers = -1;				module_param(pl_img_wvers, int, 0444);
static int pl_writes;					module_param(pl_writes, int, 0444);
static int pl_load_rc = -1;				module_param(pl_load_rc, int, 0444);
static long pl_pre_len = -1;				module_param(pl_pre_len, long, 0444);
static long pl_post_len = -1;				module_param(pl_post_len, long, 0444);
static unsigned long pl_pre_sum;			module_param(pl_pre_sum, ulong, 0444);
static unsigned long pl_post_sum;			module_param(pl_post_sum, ulong, 0444);
static int pl_rc_pre = -1;				module_param(pl_rc_pre, int, 0444);
static int pl_rc_post = -1;				module_param(pl_rc_post, int, 0444);
static int pl_kc_pre = -1;				module_param(pl_kc_pre, int, 0444);
static int pl_kc_post = -1;				module_param(pl_kc_post, int, 0444);
static int pl_sid_pre;					module_param(pl_sid_pre, int, 0444);
static int pl_sid_post;					module_param(pl_sid_post, int, 0444);
static int pl_ksid_pre;					module_param(pl_ksid_pre, int, 0444);
static int pl_ksid_post;				module_param(pl_ksid_post, int, 0444);
static char *pl_test_ctx;				module_param(pl_test_ctx, charp, 0444);
static char *pl_ctrl_ctx = "u:object_r:shell_data_file:s0";
module_param(pl_ctrl_ctx, charp, 0444);
MODULE_PARM_DESC(pl_key, "必须＝0x504F4C44('POLD') 才允许装载；只在 insmod 时定得下来(0444)");
MODULE_PARM_DESC(pl_cap, "交图上限(字节)；0＝一口图都收不下；同时受 64MB 硬顶");
MODULE_PARM_DESC(pl_test_ctx, "装载后才该解得开的那个上下文，例 u:object_r:z6_probe_file:s0");
MODULE_PARM_DESC(pl_ctrl_ctx, "装载前后都该解得开的现成上下文(正对照)；空串＝这一格不量");

static void *pl_buf;			/* 交图暂存。vmalloc ⇒ 配对必须 vfree(见 live_fingerprint 的注释) */
static size_t pl_have;
static unsigned long pl_h;		/* FNV 的流式中间值(只对 pl_buf 里那 pl_have 个字节有效) */
static int pl_fault;			/* 出过 copy_from_user 事 ⇒ 这块不再可信 */
static struct proc_dir_entry *pl_data_pde;
static struct proc_dir_entry *pl_ctl_pde;

/* ===== 符号解析：文本走 kprobe；数据符号 kprobe 取不到 ⇒ 先用 kprobe 拿到 kallsyms_lookup_name 再问它(§6.24) ===== */
#define SYM_READ  0x1
#define SYM_LOAD  0x2
#define SYM_LEN   0x4
#define SYM_CTX   0x8
#define SYM_STATE 0x10

static unsigned long kp_addr(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	unsigned long addr;
	int ret = register_kprobe(&kp);

	if (ret < 0) {
		pr_warn("z6polload: register_kprobe(%s)=%d\n", name, ret);
		return 0;
	}
	addr = (unsigned long)kp.addr;	/* 本树 kprobe.addr 是 kprobe_opcode_t*，不转就是 -Wint-conversion */
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
		a = kp_addr(name);	/* 退化成只认文本符号的老办法 */
	return a;
}

static __typeof__(security_read_policy) *p_read_policy;
static __typeof__(security_load_policy) *p_load_policy;
static __typeof__(security_policydb_len) *p_pol_len;
static __typeof__(security_context_to_sid) *p_ctx_to_sid;
static struct selinux_state *state;

/* ===== 指纹：与 w986_polround.c:236 逐字节同一把尺(FNV-1a 64)，PC 侧腿也算同一把 ⇒ 两边可比 ===== */
#define FNV64_IST   1469598103934665603UL
#define FNV64_PRIME 1099511628211UL

static unsigned long fnv64_upd(unsigned long h, const unsigned char *p, size_t n)
{
	while (n--) {
		h ^= *p++;
		h *= FNV64_PRIME;
	}
	return h;
}

/* 读活策略→算指纹→松手。
 * ★free 的配对是一手数出来的：ss/services.c:3794 用 `vmalloc_user(*len)` 分配，而
 *   selinuxfs.c 的 sel_open_policy/sel_release_policy 两侧都用 `vfree()` ⇒ 这里也必须 vfree。
 *   搞错 free 不是"读数不准"，是内存破坏。 */
static int live_fingerprint(unsigned long *sum, size_t *len)
{
	void *img = NULL;
	size_t n = 0;
	int rc;

	if (!p_read_policy || !state)
		return -ENXIO;
	rc = p_read_policy(state, &img, &n);
	if (rc) {
		pr_warn("z6polload: read_policy=%d\n", rc);
		return rc;
	}
	*sum = fnv64_upd(FNV64_IST, img, n);
	*len = n;
	vfree(img);
	return 0;
}

/* 行为尺：设备自己解不解得开这个名字(与 /sys/fs/selinux/context 那条写是同一个入口)。
 * 空串＝这一格不量，记 RES_SKIP ⇒ 不许把"没量"读成"解不开"，也不许读成"解开了"。 */
#define RES_SKIP (-1000)

static int resolve_ctx(const char *ctx, int *sid)
{
	u32 s = 0;
	int rc;

	if (!ctx || !ctx[0] || !p_ctx_to_sid || !state)
		return RES_SKIP;
	rc = p_ctx_to_sid(state, ctx, (u32)strlen(ctx), &s, GFP_KERNEL);
	*sid = (int)s;
	return rc;
}

static __le32 le32_at(const void *p, unsigned off)
{
	__le32 v;

	memcpy(&v, (const unsigned char *)p + off, sizeof(v));
	return v;
}

/* ===== GO：三道闸全过才走到 security_load_policy(第一声调用是整条路线里最贵的一条指令) ===== */
static void pl_go(void)
{
	size_t cap = min_t(size_t, pl_cap, PL_MAX);
	size_t n0 = 0;
	int rc;

	pl_seq++;
	pl_why = W_OK;

	if (pl_key != PL_KEY_WANT) {
		pl_why = W_NOKEY;
		return;
	}
	if (!p_read_policy || !p_load_policy || !p_pol_len || !p_ctx_to_sid || !state) {
		pl_why = W_SYM;
		return;
	}
	if (!pl_buf || pl_fault || !pl_have) {
		pl_why = W_NOIMG;
		return;
	}
	if (pl_have < PL_HDR_MIN) {
		pl_why = W_TOOSMALL;
		return;
	}
	if (pl_have > cap) {		/* 收的时候已经拦过；这里是"闸自己也要复核一遍" */
		pl_why = W_TOOLONG;
		return;
	}
	if (le32_to_cpu(le32_at(pl_buf, 0)) != SELINUX_MAGIC) {
		pl_why = W_BADMAGIC;
		return;
	}
	if (le32_to_cpu(le32_at(pl_buf, 4)) != PL_STRLEN) {
		pl_why = W_BADSTR;
		return;
	}
	pl_img_wvers = (int)le32_to_cpu(le32_at(pl_buf, PL_VER_OFF));

	/* ②武装不是只信当初写进来的值：装载**当下**重读活策略、重算、再比 */
	rc = live_fingerprint(&pl_pre_sum, &n0);
	if (rc) {
		pl_why = W_READPOL;
		return;
	}
	pl_arm_live = pl_pre_sum;
	pl_pre_len = (long)p_pol_len(state);
	if (pl_armed != 1 || pl_pre_sum != pl_arm_want) {
		pl_why = W_ARMMISMATCH;
		return;
	}

	pl_kc_pre = resolve_ctx(pl_ctrl_ctx, &pl_ksid_pre);
	pl_rc_pre = resolve_ctx(pl_test_ctx, &pl_sid_pre);

	rc = p_load_policy(state, pl_buf, pl_have);
	pl_load_rc = rc;
	if (rc) {
		pr_warn("z6polload: load_policy(%zu bytes)=%d\n", pl_have, rc);
		return;
	}

	pl_post_len = (long)p_pol_len(state);
	/* ★p->len 是装载那一刻记下的**输入**长度(ss/services.c 里 `newpolicydb->len = len`) ⇒
	 *   `post_len == img_len` 只证明"新 db 上了台"，不证明内容对；内容对要靠 post_sum 与 PC 那把尺。 */
	if (live_fingerprint(&pl_post_sum, &n0))
		pl_post_sum = 0;	/* 甲尺装后读不到＝这一格记"未测"，不许留旧值冒充 */
	pl_kc_post = resolve_ctx(pl_ctrl_ctx, &pl_ksid_post);
	pl_rc_post = resolve_ctx(pl_test_ctx, &pl_sid_post);
}

/* ===== /proc/w1140_pol：交图(写)／把暂存的图原样读回(读)——0600，root 腿用 ===== */
static ssize_t pl_data_write(struct file *file, const char __user *ubuf, size_t count,
			     loff_t *ppos)
{
	size_t cap = min_t(size_t, pl_cap, PL_MAX);
	size_t old = pl_have;

	if (!count)
		return -EINVAL;
	if (pl_fault)
		return -EIO;		/* RESET 才能清；半张图绝不允许被装进去 */
	if (!cap)
		return -ENOSPC;
	if (!pl_buf) {
		pl_buf = vmalloc(cap);	/* 一次按上限分配：中途 remap 容易留下半张图 */
		if (!pl_buf) {
			pl_why = W_ALLOC;
			return -ENOMEM;
		}
		pl_have = 0;
		pl_h = FNV64_IST;
		old = 0;
	}
	if (pl_have + count > cap)
		return -EFBIG;
	if (copy_from_user((unsigned char *)pl_buf + pl_have, ubuf, count)) {
		pl_fault = 1;
		pl_why = W_FAULT;
		return -EFAULT;
	}
	pl_h = fnv64_upd(pl_h, (const unsigned char *)pl_buf + old, count);
	pl_have += count;
	pl_writes++;
	pl_img_len = (long)pl_have;
	pl_img_sum = pl_h;
	return count;
}

static ssize_t pl_data_read(struct file *file, char __user *ubuf, size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos, pl_buf, pl_have);
}

static const struct file_operations pl_data_fops = {
	.owner = THIS_MODULE,
	.read = pl_data_read,
	.write = pl_data_write,
	.llseek = default_llseek,
};

/* ===== /proc/w1140_ctl：命令口(短文本)。图走另一个口 ⇒ 两边不会互相冒充 ===== */
static ssize_t pl_ctl_write(struct file *file, const char __user *ubuf, size_t count,
			    loff_t *ppos)
{
	char buf[128];
	unsigned long long v;
	size_t n0 = 0;
	int rc;

	if (count >= sizeof(buf))
		return -E2BIG;		/* 命令是短文；往这个口写长东西不算命令 */
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';
	if (count && buf[count - 1] == '\n')
		buf[count - 1] = '\0';

	if (!strncmp(buf, "ARM ", 4)) {
		rc = kstrtoull(buf + 4, 10, &v);
		if (rc)
			return rc;
		pl_arm_want = (unsigned long)v;
		rc = live_fingerprint(&pl_arm_live, &n0);
		if (rc) {
			pl_armed = 0;
			return rc;
		}
		pl_armed = (pl_arm_live == pl_arm_want) ? 1 : -1;
		pl_seq++;
		return count;
	}
	if (!strcmp(buf, "GO")) {
		pl_go();
		return count;
	}
	if (!strcmp(buf, "RESET")) {
		vfree(pl_buf);
		pl_buf = NULL;
		pl_have = 0;
		pl_h = FNV64_IST;
		pl_fault = 0;
		pl_armed = -1;
		pl_img_len = -1;
		pl_img_sum = 0;
		pl_img_wvers = -1;
		pl_seq++;
		return count;
	}
	return -EINVAL;
}

static const struct file_operations pl_ctl_fops = {
	.owner = THIS_MODULE,
	.write = pl_ctl_write,
	.llseek = default_llseek,
};

static int __init pl_init(void)
{
	unsigned long a;

	pl_sym_rc = 0;
	a = sym_addr("security_read_policy");
	if (a) {
		p_read_policy = (void *)a;
		pl_sym_rc |= SYM_READ;
	}
	a = sym_addr("security_load_policy");
	if (a) {
		p_load_policy = (void *)a;
		pl_sym_rc |= SYM_LOAD;
	}
	a = sym_addr("security_policydb_len");
	if (a) {
		p_pol_len = (void *)a;
		pl_sym_rc |= SYM_LEN;
	}
	a = sym_addr("security_context_to_sid");
	if (a) {
		p_ctx_to_sid = (void *)a;
		pl_sym_rc |= SYM_CTX;
	}
	/* selinux_state 在设备 kallsyms 里是 **B(数据)** ⇒ 只能问 kallsyms_lookup_name；
	 * 对它直接 register_kprobe 会 -EINVAL(§6.24 一手)。 */
	a = sym_addr("selinux_state");
	if (a) {
		state = (void *)a;
		pl_sym_rc |= SYM_STATE;
	}

	/* 口先开：在任何有风险的动作之前挂上——读不到口就等于没仪器 */
	pl_data_pde = proc_create("w1140_pol", 0600, NULL, &pl_data_fops);
	pl_ctl_pde = proc_create("w1140_ctl", 0600, NULL, &pl_ctl_fops);
	pl_proc = (pl_data_pde ? 1 : 0) + (pl_ctl_pde ? 2 : 0);	/* 3＝两个口都在 */

	pr_info("z6polload: abi=%d sym_rc=0x%x proc=%d key=0x%x cap=%u why=%d test=[%s] ctrl=[%s]\n",
		pl_abi, pl_sym_rc, pl_proc, pl_key, pl_cap, pl_why,
		pl_test_ctx ? : "", pl_ctrl_ctx ? : "");
	return 0;	/* ★常驻：失败也返回 0，否则参数被一起摘掉，读数就没了 */
}

static void __exit pl_exit(void)
{
	proc_remove(pl_data_pde);
	proc_remove(pl_ctl_pde);
	vfree(pl_buf);
	pr_info("z6polload: exit abi=%d load_rc=%d why=%d img=%ld pre=%ld post=%ld seq=%d\n",
		pl_abi, pl_load_rc, pl_why, pl_img_len, pl_pre_len, pl_post_len, pl_seq);
}

module_init(pl_init);
module_exit(pl_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("w1140 module-side whole-image policy load probe (#237 B-prime)");
