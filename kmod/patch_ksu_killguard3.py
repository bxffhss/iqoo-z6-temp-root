import io
import sys

P = "kmod/ksu_dev_syms.c"
s = io.open(P, encoding="utf-8").read()

if "ksu_fs_addr" in s:
    print("已经改过 ⇒ 跳过")
    raise SystemExit(0)


def sub(old, new, tag):
    global s
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    s = s.replace(old, new)
    print("ok [%s]" % tag)


sub(
    "static unsigned long ksu_learn_site;",
    "static unsigned long ksu_learn_site;"
    + chr(10)
    + "static unsigned long ksu_fs_addr;   /* force_sig 的地址：跳不跳只看 x8 是不是它 */",
    "存 force_sig 地址",
)

sub(
    r'''static int ksu_site_skip(struct kprobe *p, struct pt_regs *regs)
{
	static unsigned long nr;
	unsigned long n = ++nr;

	/* 返回非 0 ⇒ 被探的那条指令不执行(等价运行时 NOP，但不改文本、可 unregister) */
	if ((n & 31u) == 1)
		pr_info("KILLGUARD: 已跳过第 %lu 次间接 force_sig(探针 @%px)%s",
			n, p->addr, "\n");
	return 1;
}''',
    r'''static int ksu_site_skip(struct kprobe *p, struct pt_regs *regs)
{
	static unsigned long nr, pass;
	unsigned long n;

	/* ★第六十一发的教训：`ldr x8 / cbz x8 / blr x8` 这一组是 vr 的**通用间接调用出口**
	 *   (开机 690s 里被走了 199,777 次)，force_sig 只是它某一回取到的那个指针。
	 *   无条件返回 1 = 把人家所有间接调用都吞掉 ⇒ 有任务直接挂死、load 稳在 8.0、
	 *   passfd 对照的子进程卡在 waitpid 里回不来。⇒ 必须**按 x8 判**：
	 *   这一次 blr 的目标不是 force_sig，就返回 0 让它照常执行。 */
	if (ksu_fs_addr && regs->regs[8] != ksu_fs_addr) {
		if ((++pass & 0xFFFFu) == 1)
			pr_info("KILLGUARD: 探针 @%px 累计放行 %lu 次(x8=%px 不是 force_sig)%s",
				p->addr, pass, (void *)regs->regs[8], "\n");
		return 0;
	}
	n = ++nr;
	if ((n & 31u) == 1)
		pr_info("KILLGUARD: 已跳过第 %lu 次间接 force_sig(探针 @%px x8=%px)%s",
			n, p->addr, (void *)regs->regs[8], "\n");
	return 1;
}''',
    "有条件跳过",
)

sub(
    "	fs = ksu_sym_addr(\"force_sig\");",
    "	fs = ksu_sym_addr(\"force_sig\");" + chr(10) + "	ksu_fs_addr = fs;",
    "记下地址",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("rc31：killguard 已改成按 x8 判")
