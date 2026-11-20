import io
import sys

P = "kmod/ksu_dev_syms.c"
s = io.open(P, encoding="utf-8").read()
BS = chr(92)
NL = chr(10)

if "ksu_killguard" in s:
    print("已经有 killguard ⇒ 跳过")
    raise SystemExit(0)

# 1) 参数 + 探针回调：插在 ksu_killscan_run 之前
anchor = "void ksu_killscan_run(void)"
assert s.count(anchor) == 1, s.count(anchor)

DECL = r'''/* ---- killguard(§6.70③)：把"跳过那一次间接调用"做成运行时探针 ----
 * §6.70 的现场：调用点是 `ldr x8,[xN,#0x240]; cbz x8,+8; blr x8`，即 vr 从某个槽里取出
 *   force_sig 的地址再间接跳。所以扫 `bl` 永远扫不到它。
 * 这里不 NOP 文本(改文本要过 W^X 且不可逆)，而是在那条 `blr x8` 上挂 kprobe，
 *   pre_handler **返回 1** ⇒ kprobes 语义就是"这条指令不执行" ⇒ 等价于运行时 NOP，
 *   但可 unregister、不碰只读页。
 * 认三条一组的签名(缺一不挂)：blr x8 / 前一条 cbz x8,+8 / 再前一条 ldr x8,[xN,#imm]。
 *   cbz 那句本身就是"指针为空就跳过"，所以我们跳过它 = 假装那个槽是空的，语义自洽。
 */
#define KSU_INSN_BLR_X8   0xd63f0100u
#define KSU_INSN_CBZ_X8_8 0xb4000048u
#define KSU_INSN_LDR_X8   0xf9400000u   /* + Rt=8 低 5 位 */

static int killguard;
module_param(killguard, int, 0444);
MODULE_PARM_DESC(killguard, "1=在候选间接调用点挂跳过探针(默认 0=只打印候选)");

static struct kprobe ksu_gk[8];
static int ksu_gk_nr;

static int ksu_guard_pre(struct kprobe *p, struct pt_regs *regs)
{
	/* 返回非 0 ⇒ 被探的那条指令不执行。这里就是"那次 force_sig 没发生"。 */
	static unsigned long nr;
	unsigned long n = ++nr;

	if ((n & 63u) == 1)
		pr_info("KILLGUARD: 已跳过第 %lu 次间接 force_sig(探针 @%px)%s",
			n, p->addr, "\n");
	return 1;
}

static void ksu_guard_arm(struct module *mod, unsigned char *text, unsigned int off)
{
	struct kprobe *kp;
	int rc;

	if (ksu_gk_nr >= (int)ARRAY_SIZE(ksu_gk)) {
		pr_info("KILLGUARD: 位置用完了(%d) ⇒ %s+%#x 不挂%s",
			ksu_gk_nr, mod->name, off, "\n");
		return;
	}
	kp = &ksu_gk[ksu_gk_nr];
	kp->pre_handler = ksu_guard_pre;
	kp->addr = (kprobe_opcode_t *)(text + off);   /* kprobe.addr 是 kprobe_opcode_t* ⇒ 必须这么转 */
	rc = register_kprobe(kp);
	pr_info("KILLGUARD: register_kprobe(%s+%#x) rc=%d%s",
		mod->name, off, rc, rc ? " ⇒ 没挂上" : " ⇒ 已挂，这一处 force_sig 从此不执行" "\n");
	if (!rc)
		ksu_gk_nr++;
}

'''
s = s.replace(anchor, DECL + anchor)

# 2) 在扫描循环里加"三指令签名"识别 + 可选挂探针。挂在 veneer 那段之后、模块循环收尾之前。
old2 = """		first = scan_call_to(text, tsize, (void *)fs);"""
assert s.count(old2) == 1, s.count(old2)
new2 = """		/* killguard 的识别：`ldr x8,[xN,#imm]` + `cbz x8,+8` + `blr x8` 三连。
		 *   §6.70 实测 w59：base+0x1400=f9412108, +0x1404 前一条=b4000048, 调用点=d63f0100。*/
		for (i = 8; i + 4 <= tsize; i += 4) {
			u32 w0 = *(u32 *)(text + i);
			u32 w1 = *(u32 *)(text + i - 4);
			u32 w2 = *(u32 *)(text + i - 8);

			if (w0 != KSU_INSN_BLR_X8)
				continue;
			if (w1 != KSU_INSN_CBZ_X8_8)
				continue;
			if ((w2 & 0xFFC0001Fu) != (KSU_INSN_LDR_X8 | 8))
				continue;
			cand++;
			pr_info("KILLSCAN  \\u25c6 %s+%#x: ldr x8/cbz x8/blr x8 三连 = 候选间接 force_sig 调用点(word=%08x %08x %08x)%s",
				mod->name, i, w2, w1, w0, "\\n");
			if (killguard)
				ksu_guard_arm(mod, text, i);
		}
		first = scan_call_to(text, tsize, (void *)fs);"""
new2 = new2.replace("\\u25c6", BS + "u25c6")
s = s.replace(old2, new2)

# 3) cand 变量声明 + 收工行里带上候选数
old3 = "\t\tunsigned int tsize, i;"
assert s.count(old3) == 1
s = s.replace(old3, "\t\tunsigned int tsize, i;")
old4 = "\tint seen = 0, hits = 0, mods_ok = 0;"
assert s.count(old4) == 1
s = s.replace(old4, "\tint seen = 0, hits = 0, mods_ok = 0, cand = 0;")
old5 = "KILLSCAN 收工："
assert s.count(old5) == 1
s = s.replace(
    '\tpr_info("KILLSCAN 收工：链表里认出名堂 %d 个模块，命中 bl->force_sig 共 %d 处\\n",\n\t\tmods_ok, hits);',
    '\tpr_info("KILLSCAN 收工：链表里认出名堂 %d 个模块，直接 bl->force_sig %d 处，ldr/cbz/blr 三连候选 %d 处，已挂跳过探针 %d 个\\n",\n'
    "\t\tmods_ok, hits, cand, ksu_gk_nr);",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("killguard 已加进 dev_syms.c")
