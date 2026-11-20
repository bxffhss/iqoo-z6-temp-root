import io
import sys

P = "kmod/ksu_dev_syms.c"
s = io.open(P, encoding="utf-8").read()

if "ksu_sw" in s:
    print("已经改过 rc32 ⇒ 跳过")
    raise SystemExit(0)

# rc31 的"跳过"被证明太粗暴：第六十二发实测 force_sig 的调用点被走 324,577 次/486s(=668/s)，
# 而且被跳过的任务虽然 Uid=0 活着，却卡在 open() 里出不来(vr 大概"等它死")。
# rc32 改成：**不跳过调用，只把参数改掉** —— force_sig(9) 变 force_sig(18=SIGCONT)，
# vr 的调用照常发生、照常返回，它以为杀完了；受害者只收到一个默认动作就是"继续"的信号。
# 判据仍然精确：只有"从 vr 那一处调用点进来的 sig==9"才改。

old_decl = "static unsigned long ksu_fs_addr;   /* force_sig 的地址：跳不跳只看 x8 是不是它 */"
assert s.count(old_decl) == 1, "decl"
new_decl = old_decl + chr(10) + r'''/* rc32：把"跳过调用"换成"改掉信号号"。
 * 第六十二发的现场：rc31 的跳过让被救下来的任务**活着但卡在 open() 里**(State R，
 *   Uid 0 0 0 0，12 分钟没写出第一个文件)——vr 那一处出口被走了 668 次/秒，它大概还在
 *   "等这个任务死"。所以别再吞调用：**照常调、照常返回，只把 SIGKILL 换成 SIGCONT**，
 *   vr 的流程完整走完(它以为杀掉了)，受害者只多吃一个"默认动作=继续"的信号。 */
#define KSU_SIG_KILL   9
#define KSU_SIG_HARMLESS 18   /* SIGCONT：默认动作是 continue，等于什么都没发生 */
static unsigned long ksu_sw_site;      /* 已确认的那个调用点(vr 里的 blr x8) */
static unsigned long ksu_sw_nr;        /* 改写了多少次 */
static unsigned long ksu_sw_pass;      /* 放行了多少次(证明不是乱改) */
'''
s = s.replace(old_decl, new_decl)

# force_sig 上的处理器：只改从 vr 那一处进来的 SIGKILL
old_fs = r'''/* force_sig 上的"只读寄存器"探针：处理器里绝不睡，只把确凿的调用点交给 workqueue。 */
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
}'''
assert s.count(old_fs) == 1, "fs_pre"
new_fs = r'''/* force_sig 上的探针：①认出"是从 vr 那一处调进来的"；②把 SIGKILL 换成 SIGCONT。
 * 返回 0 ⇒ 指令照常执行(这正是 rc32 要的：调用发生、返回值正常、vr 的流程走完)。 */
static int ksu_fs_pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long sig = regs->regs[0];
	unsigned long site = regs->regs[30] - 4;

	if (sig != KSU_SIG_KILL)
		return 0;
	if (!ksu_gk_text || site < ksu_gk_lo || site >= ksu_gk_hi) {
		if ((++ksu_sw_pass & 0xFFFFu) == 1)
			pr_info("KILLSOFT: 放行 %lu 次(不是 %s 那一处：site=%px)%s",
				ksu_sw_pass, scanmod ? scanmod : "?", (void *)site, "\n");
		return 0;
	}
	if (!READ_ONCE(ksu_sw_site))
		WRITE_ONCE(ksu_sw_site, site);
	regs->regs[0] = KSU_SIG_HARMLESS;		/* 就这一笔：9 -> 18 */
	if ((++ksu_sw_nr & 0xFFu) == 1)
		pr_info("KILLSOFT: 已把第 %lu 次 SIGKILL 改成 SIGCONT(site=%px comm=%s uid=%u)%s",
			ksu_sw_nr, (void *)site, current->comm,
			from_kuid(&init_user_ns, current_uid()), "\n");
	return 0;
}'''
s = s.replace(old_fs, new_fs)

# 调用点探针不再需要：ksu_arm_site 里改成只记账，不再 register_kprobe
old_arm = r'''	kp = &ksu_gk;
	kp->pre_handler = ksu_site_skip;
	kp->addr = (kprobe_opcode_t *)(text + off);
	rc = register_kprobe(kp);'''
assert s.count(old_arm) == 1, "arm"
new_arm = r'''	/* rc32：不再在调用点上挂"跳过"探针(那会吞掉 vr 的所有间接调用)，
	 * 这里只把地址记下来给日志用；真正的改信号在 force_sig 的探针里做。
	 * (pre_handler 仍然赋一次值：不引用的话 ksu_site_skip 会变成"定义了没人用"，
	 *  内核带 -Werror 直接编不过。) */
	WRITE_ONCE(ksu_sw_site, (unsigned long)(text + off));
	kp = &ksu_gk;
	kp->pre_handler = ksu_site_skip;
	rc = 0;'''
s = s.replace(old_arm, new_arm)

# force_sig 探针必须无条件注册(rc31 里它被 armed 标志挡住了)
old_reg = "			if (killguard && !atomic_read(&ksu_guard_armed) && !ksu_fs_kp.addr) {"
assert s.count(old_reg) == 1, "reg"
new_reg = "			if (killguard && !ksu_fs_kp.addr) {"
s = s.replace(old_reg, new_reg)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("rc32：改成把 SIGKILL 软成 SIGCONT")
