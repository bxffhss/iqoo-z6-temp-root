import io
import sys

P = "kmod/ksu_dev_syms.c"
s = io.open(P, encoding="utf-8").read()

if "killguard" in s:
    sys.exit("文件里已经有 killguard ⇒ 先把 dev_syms.c 恢复到 rc28 状态再跑本脚本")

# ── 1) 参数 + 两处保险的实现，插在 ksu_killscan_run 之前 ───────────────────
anchor = "void ksu_killscan_run(void)"
assert s.count(anchor) == 1, "anchor1=%d" % s.count(anchor)

DECL = r'''/* ================= killguard(rc30)：只关那一处间接调用 =================
 * §6.70 的现场：凶手是 vr 里 `ldr x8,[xN,#0x240]; cbz x8,+8; blr x8` 三连的最后一跳，
 *   调用点 = vr.core_layout.base + 0x1404(同一 boot 里 ko 报的 base 与 kprobe 报的 LR 相减)。
 * ★第五十九发的教训：那三条签名是"判空后间接调用"的通用形状，124 个模块里到处都有 ⇒
 *   rc29 用 scanall+killguard 到处挂"返回 1"的探针，等于在别人的热路径上单步，
 *   整机 load 7.7、app 的 armed 分支连 fork 都没走到就没了。所以 rc30 改成两道保险：
 *     ①预置：只在 scanmod 那一个模块里、只验 base+0x1404 那一格，签名对得上才挂；
 *     ②现学：在 force_sig 上挂一个只读寄存器的探针，看见 sig==9 且 LR-4 落在 scanmod 的
 *       text 区间里，就把那个**确凿的**地址交给 workqueue 去挂跳过探针(处理器里不能睡)。
 *   两处都只挂**一个**探针，挂上就置 atomic 标志，绝不重复挂。
 */
#define KSU_INSN_BLR_X8    0xd63f0100u
#define KSU_INSN_CBZ_X8_8  0xb4000048u
#define KSU_INSN_LDR_X8    0xf9400000u  /* + Rt=8；Rn 位不看 */
#define KSU_GUARD_OFF      0x1404u      /* §6.70：LR(=+0x1408) - 4 */

static int killguard;
module_param(killguard, int, 0444);
MODULE_PARM_DESC(killguard, "1=关掉 vr 里那一处间接 force_sig(默认 0=只审计)");

static struct kprobe ksu_gk;                    /* 跳过探针：最多一个 */
static struct kprobe ksu_fs_kp;                 /* 现学用的 force_sig 探针 */
static struct work_struct ksu_guard_work;
static atomic_t ksu_guard_armed = ATOMIC_INIT(0);
static unsigned char *ksu_gk_text;              /* scanmod 的 text 起点 */
static unsigned long ksu_gk_lo, ksu_gk_hi;      /* 它的地址区间 */
static unsigned long ksu_learn_site;

static int ksu_site_skip(struct kprobe *p, struct pt_regs *regs)
{
	static unsigned long nr;
	unsigned long n = ++nr;

	/* 返回非 0 ⇒ 被探的那条指令不执行(等价运行时 NOP，但不改文本、可 unregister) */
	if ((n & 31u) == 1)
		pr_info("KILLGUARD: 已跳过第 %lu 次间接 force_sig(探针 @%px)%s",
			n, p->addr, "\n");
	return 1;
}

static void ksu_arm_site(const char *modname, unsigned char *text, unsigned int off,
			 const char *why)
{
	struct kprobe *kp;
	int rc;

	if (atomic_xchg(&ksu_guard_armed, 1)) {
		pr_info("KILLGUARD: 已经挂过了 ⇒ %s+%#x(%s) 不再挂%s",
			modname, off, why, "\n");
		atomic_set(&ksu_guard_armed, 1);
		return;
	}
	kp = &ksu_gk;
	kp->pre_handler = ksu_site_skip;
	kp->addr = (kprobe_opcode_t *)(text + off);
	rc = register_kprobe(kp);
	if (rc) {
		atomic_set(&ksu_guard_armed, 0);
		pr_info("KILLGUARD: %s 在 %s+%#x 挂失败 rc=%d ⇒ 让 force_sig 探针再学一次%s",
			why, modname, off, rc, "\n");
		return;
	}
	pr_info("KILLGUARD: %s 已在 %s+%#x 挂上跳过探针(word=%08x)%s",
		why, modname, off, *(u32 *)(text + off), "\n");
}

static void ksu_guard_work_fn(struct work_struct *w)
{
	unsigned long site = READ_ONCE(ksu_learn_site);

	if (!site || atomic_read(&ksu_guard_armed) || !ksu_gk_text)
		return;
	ksu_arm_site(scanmod ? scanmod : "?", ksu_gk_text,
		     (unsigned int)(site - ksu_gk_lo), "现学(force_sig 的 LR-4)");
}

/* force_sig 上的"只读寄存器"探针：处理器里绝不睡，只把确凿的调用点交给 workqueue。 */
static int ksu_fs_pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long sig = regs->regs[0];
	unsigned long site = regs->regs[30] - 4;

	if (sig != 9 || atomic_read(&ksu_guard_armed))
		return 0;
	if (!ksu_gk_text || site < ksu_gk_lo || site >= ksu_gk_hi)
		return 0;
	WRITE_ONCE(ksu_learn_site, site);
	schedule_work(&ksu_guard_work);
	return 0;
}

'''
s = s.replace(anchor, DECL + anchor)

# ── 2) 扫描循环里：记下 scanmod 的 text 区间；①预置偏移验签名；②注册 force_sig 学习探针 ──
old2 = "\t\tfirst = scan_call_to(text, tsize, (void *)fs);"
assert s.count(old2) == 1, "anchor2"
new2 = r'''		if (!strcmp(mod->name, scanmod ? scanmod : "?")) {
			ksu_gk_text = text;
			ksu_gk_lo = (unsigned long)text;
			ksu_gk_hi = (unsigned long)(text + tsize);
			INIT_WORK(&ksu_guard_work, ksu_guard_work_fn);
			/* ①预置：只验 §6.70 算出来的那一格，三条签名全对才挂 */
			if (killguard && tsize > KSU_GUARD_OFF + 8) {
				u32 a = *(u32 *)(text + KSU_GUARD_OFF - 8);
				u32 b = *(u32 *)(text + KSU_GUARD_OFF - 4);
				u32 c = *(u32 *)(text + KSU_GUARD_OFF);

				pr_info("KILLGUARD: 预置检查 %s+%#x 三连=%08x %08x %08x (要 %08x %08x 低位 %08x)%s",
					mod->name, KSU_GUARD_OFF, a, b, c,
					KSU_INSN_LDR_X8 | 8, KSU_INSN_CBZ_X8_8, KSU_INSN_BLR_X8,
					"\n");
				if (c == KSU_INSN_BLR_X8 && b == KSU_INSN_CBZ_X8_8 &&
				    (a & 0xFFC0001Fu) == (KSU_INSN_LDR_X8 | 8))
					ksu_arm_site(mod->name, text, KSU_GUARD_OFF, "预置偏移");
				else
					pr_info("KILLGUARD: 预置偏移签名不符 ⇒ 不挂，等 force_sig 现学%s",
						"\n");
			}
			/* ②现学：force_sig 上挂个只读探针(它本来就只在被杀时走一次，不是热路径) */
			if (killguard && !atomic_read(&ksu_guard_armed) && !ksu_fs_kp.addr) {
				ksu_fs_kp.pre_handler = ksu_fs_pre;
				ksu_fs_kp.addr = (kprobe_opcode_t *)fs;
				if (register_kprobe(&ksu_fs_kp))
					pr_info("KILLGUARD: force_sig 学习探针没挂上%s", "\n");
				else
					pr_info("KILLGUARD: 已挂 force_sig 学习探针(等第一次 sig==9 现学报址)%s",
						"\n");
			}
		}
		first = scan_call_to(text, tsize, (void *)fs);'''
s = s.replace(old2, new2)

# ── 3) 收尾行里说清楚挂没挂上 ───────────────────────────────────────────
old3 = '\tpr_info("KILLSCAN 收工：链表里认出名堂 %d 个模块，命中 bl->force_sig 共 %d 处\\n",\n\t\tmods_ok, hits);'
assert s.count(old3) == 1, "anchor3"
new3 = ('\tpr_info("KILLSCAN 收工：链表里认出名堂 %d 个模块，命中 bl->force_sig 共 %d 处，'
        'killguard=%d armed=%d scanmod=[%s] base=%px..%px\\n",\n'
        '\t\tmods_ok, hits, killguard, atomic_read(&ksu_guard_armed),\n'
        '\t\tscanmod ? scanmod : "(空)", (void *)ksu_gk_lo, (void *)ksu_gk_hi);')
s = s.replace(old3, new3)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("rc30 killguard 已写进 dev_syms.c")
