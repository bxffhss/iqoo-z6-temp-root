/* policeprobe —— 实测"vr 还管着的那 22 条桩"会不会挡住交付态的 root 干活。
 * 一份进程里同时跑【未管对照组】和【被管组】：对照组必须不出 EPERM，
 * 否则这一发的 EPERM 就不能归给 vr(可能是能力/SELinux/seccomp 一起拒)。
 * 三种形状各自的含义：
 *   EPERM  = 没进本体 ⇒ vr 在 .cfi_jt 桩里把 escape 过的任务拦下(本项目 #72/#73 的那把枪)
 *   EACCES = 进了本体、被 SELinux 拒 ⇒ 桩没拦(要动的是 sepolicy，不是桩)
 *   0 / 其它 errno = 进了本体 ⇒ 这条对 root 可用(内核自己的错误码也算)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sched.h>
#include <linux/sched.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <asm/unistd.h>
#include <sys/ptrace.h>

static void out(const char *s) { ssize_t r = write(1, s, strlen(s)); (void)r; }

/* ★#77 上机一手：这条探针的 TLS 块只有 errno 那 8 字节，链接期 p_align 就跟着是 8，
 *   而 ARM64 Bionic 的加载器**无条件要求 PT_TLS 对齐 >= 64**(不是"同余就行")：
 *   `error: executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic` ⇒ SIGABRT。
 *   forkprobe/ksuctl88 那两条是链接期拉进了 128 字节的整块 Bionic TLS，p_align 才是 64 —— 别指望"运气好"。
 *   做法：显式放一个 64 对齐的 __thread 变量，并在 main 里真的读写它(否则会被优化掉)。 */
static __thread unsigned long tls_anchor __attribute__((aligned(64), used));

/* kv —— 从一整块文本里取 "key:" 后面的值，**不破坏 buffer**
 *   (截断共享 buffer 会让后面的 key 全找不到 —— #77 一手，见 st() 里那条注释) */
static void kv(const char *raw, const char *key, char *dst, size_t dsz) {
	const char *p = strstr(raw, key);
	size_t i = 0;
	dst[0] = 0;
	if (!p) { snprintf(dst, dsz, "(没这个字段)"); return; }
	p += strlen(key);
	while (*p == ' ' || *p == '\t') p++;
	while (*p && *p != '\r' && *p != '\n' && i + 1 < dsz) dst[i++] = *p++;
	dst[i] = 0;
	/* ★这一发一手：root 任务的 `Groups:` 是**空值**，旧写法把"没有值"和"没找到这行"都印成 `?` ⇒
	 *   读的人无法区分"这个任务确实没有补充组"与"我的解析挂了"。判据的两种"没有"必须分符号。 */
	if (!i) snprintf(dst, dsz, "(空)");
}

static void st(const char *tag) {
	char b[512];
	char uid[64] = "?", dom[128] = "?", sec[32] = "?", cap[32] = "?";
	char prm[32] = "?", bnd[32] = "?", amb[32] = "?";
	char gid[32] = "?", groups[128] = "?";
	int fd = open("/proc/self/status", O_RDONLY);
	if (fd >= 0) {
		/* ★一次 read() 不保证读全(seq_file 会分块)：第一版只读一次 ⇒ "Seccomp:"/"CapEff:"
		 *   落在后半截就 strstr 不到，印成 `?`，看着像"这任务没 seccomp 信息"。循环读到空为止。 */
		char raw[8192]; ssize_t n = 0, k;
		while (n < (ssize_t)sizeof raw - 1 && (k = read(fd, raw + n, sizeof raw - 1 - n)) > 0) n += k;
		close(fd);
		if (n > 0) {
			/* ★第二版才看到的坑(而且第一版把锅甩给了"读不全")：这里原来用 `*e = 0` 就地截断，
			 *   于是解析完 "Uid:" 之后整个 buffer 就在 Uid 那行末尾断掉，后面 strstr 再也找不到
			 *   Seccomp/CapEff ⇒ 一律印 `?`。判据字段读不出来时必须**出声**，不能悄悄留 `?`。 */
			raw[n] = 0;
			kv(raw, "Uid:", uid, sizeof uid);
			kv(raw, "Gid:", gid, sizeof gid);
			kv(raw, "Groups:", groups, sizeof groups);
			kv(raw, "Seccomp:", sec, sizeof sec);
			kv(raw, "CapEff:", cap, sizeof cap);
			/* ★#77 收尾一手：三个上下文里"被拦/不被拦"唯一对得上的是 cap 的形状，
			 *   所以整组 cap 全印(CapPrm/CapBnd/CapAmb)，下一发好做单变量(改 profile 的 caps)。 */
			kv(raw, "CapPrm:", prm, sizeof prm);
			kv(raw, "CapBnd:", bnd, sizeof bnd);
			kv(raw, "CapAmb:", amb, sizeof amb);
			if (strstr(sec, "没这个字段") || strstr(cap, "没这个字段"))
				out("[警告] /proc/self/status 里没解析出 Seccomp/CapEff ⇒ 这一发的归因不完整\n");
		}
	}
	fd = open("/proc/self/attr/current", O_RDONLY);
	if (fd >= 0) { ssize_t n = read(fd, dom, sizeof dom - 1); close(fd); if (n > 0) { dom[n] = 0; char *e = strpbrk(dom, "\r\n"); if (e) *e = 0; } }
	snprintf(b, sizeof b,
		 "[%s] uid=%s gid=%s groups=%s cap_eff=%s cap_prm=%s cap_bnd=%s cap_amb=%s seccomp=%s dom=%s\n",
		 tag, uid, gid, groups, cap, prm, bnd, amb, sec, dom);
	out(b);
}

/* 一条编号可能在这个 ABI 上不存在(arm64 没有 chmod/chown/lchown) ⇒ 用宏探测，缺就明说。 */
#ifndef __NR_mount
#define __NR_mount (-1)
#endif
#ifndef __NR_ptrace
#define __NR_ptrace (-1)
#endif
#ifndef __NR_fchmod
#define __NR_fchmod (-1)
#endif
#ifndef __NR_fchmodat
#define __NR_fchmodat (-1)
#endif
#ifndef __NR_fchown
#define __NR_fchown (-1)
#endif
#ifndef __NR_fchownat
#define __NR_fchownat (-1)
#endif
#ifndef __NR_setxattr
#define __NR_setxattr (-1)
#endif
#ifndef __NR_lsetxattr
#define __NR_lsetxattr (-1)
#endif
#ifndef __NR_fsetxattr
#define __NR_fsetxattr (-1)
#endif
#ifndef __NR_init_module
#define __NR_init_module (-1)
#endif
#ifndef __NR_finit_module
#define __NR_finit_module (-1)
#endif
#ifndef __NR_setresgid
#define __NR_setresgid (-1)
#endif
#ifndef __NR_setfsuid
#define __NR_setfsuid (-1)
#endif
#ifndef __NR_setfsgid
#define __NR_setfsgid (-1)
#endif
#ifndef __NR_getresuid
#define __NR_getresuid (-1)
#endif
#ifndef __NR_clone3
#define __NR_clone3 (-1)
#endif
#ifndef __NR_syscalls
#define __NR_syscalls (-1)
#endif

static const char *why(long rc, int e) {
	/* ★归因不在这里下(#77 一手)：EPERM 有三种来源，同一份读数在不同上下文里含义完全不同 ——
	 *   uid 2000 的 shell 里 setuid/setgid/fchown/init_module 本来就是 EPERM(普通 Unix 权限)，
	 *   而 vr 只在"escape 过的任务"上执法。所以这里只报形状，归因交给
	 *   ①起点那行自己印的 uid/cap ②内核侧 /proc/ksu_cfiscan 那份名单(它说这条桩被改道了才算)。 */
	if (rc == 0) return "0 ⇒ 进了本体且成功";
	if (rc < 0 && e == EPERM) return "EPERM ⇒ 三种可能(vr 拦桩 / 这个 uid 本来就不配 / 内核自己 EPERM)，见起点 uid+Cap 与 cfiscan";
	if (rc < 0 && e == EACCES) return "EACCES ⇒ 进了本体、SELinux 拒(桩没拦)";
	if (rc < 0 && e == ENOSYS) return "ENOSYS ⇒ 这个 ABI 没这条";
	if (rc < 0 && e == EFAULT) return "EFAULT ⇒ 进了本体(参数被内核读过了)";
	if (rc < 0 && e == ENOENT) return "ENOENT ⇒ 进了本体，路径查了(没被桩拦)";
	return "进了本体，内核自己给的错误";
}

static void cell(const char *grp, const char *name, int nr, long rc) {
	int e = (rc < 0) ? errno : 0;
	char b[384];
	snprintf(b, sizeof b, "%-4s %-14s nr=%-4d rc=%-12ld errno=%-4d %-6s %s\n",
		 grp, name, nr, rc, e, (e ? strerror(e) : "ok"), why(rc, e));
	out(b);
	fflush(stdout);
}

static long call(const char *grp, const char *name, int nr, long a, long b, long c, long d, long e2, long f) {
	if (nr < 0) {
		char bt[256];
		snprintf(bt, sizeof bt, "%-4s %-14s nr=---- 这个 ABI 的头部没给编号(跳过)\n", grp, name);
		out(bt);
		errno = ENOSYS;
		return -1;
	}
	errno = 0;
	long rc = syscall(nr, a, b, c, d, e2, f);
	cell(grp, name, nr, rc);
	return rc;
}

/* 孩子立刻 syscall(exit) ⇒ 不共享 stdio/父的账(见下面两处 pid==0) */

#define STACK_SZ (1u << 16)

int main(int argc, char **argv)
{
	char b[256];
	const char *tag = (argc > 1) ? argv[1] : "pp";
	tls_anchor = 1234;                      /* ★必须真的用这个变量，不然 PT_TLS 又退回 8 对齐 */
	if (tls_anchor != 1234) out("TLS 自检坏了(不该出现)\n");
	snprintf(b, sizeof b, "=== policeprobe 起点 ctx=%s ===\n", tag);
	out(b);
	st("起点");

	/* ---------- 对照组：#73 之后这些**不该**是 EPERM ---------- */
	uid_t r_ruid = 0, r_euid = 0, r_suid = 0;
	call("CTRL", "getresuid", __NR_getresuid, (long)&r_ruid, (long)&r_euid, (long)&r_suid, 0, 0, 0);
	call("CTRL", "setfsuid", __NR_setfsuid, 0, 0, 0, 0, 0, 0);
	call("CTRL", "setfsgid", __NR_setfsgid, 0, 0, 0, 0, 0, 0);
	call("CTRL", "setgid", __NR_setgid, 0, 0, 0, 0, 0, 0);
	call("CTRL", "setresgid", __NR_setresgid, 0, 0, 0, 0, 0, 0);
	/* c=4 写回的三条里的两条(uid 族)：这一发必须还是通的，否则说明写回掉了 */
	call("CTRL", "setuid", __NR_setuid, 0, 0, 0, 0, 0, 0);
	call("CTRL", "setresuid", __NR_setresuid, 0, 0, 0, 0, 0, 0);

	/* ---------- 文件载体：被管组要用的 fd/路径都在这儿现造 ---------- */
	char path[128];
	snprintf(path, sizeof path, "/data/local/tmp/pp_%s_file", tag);
	int fdo = open(path, O_RDONLY | O_CREAT | O_TRUNC, 0644);
	snprintf(b, sizeof b, "CTRL载体 open(%s) fd=%d errno=%d\n", path, fdo, fdo < 0 ? errno : 0);
	out(b);

	/* ---------- 被管组：逐条只喂"就算进了本体也绝不会真干活"的参数 ---------- */
	call("POL", "fchmod", __NR_fchmod, fdo, 0644, 0, 0, 0, 0);
	call("POL", "fchmodat", __NR_fchmodat, -100 /*AT_FDCWD*/, (long)path, 0644, 0, 0, 0);
	call("POL", "fchown", __NR_fchown, fdo, 0, 0, 0, 0, 0);
	call("POL", "fchownat", __NR_fchownat, -100, (long)path, 0, 0, 0, 0);
	call("POL", "setxattr", __NR_setxattr, (long)"/nonexistent_pp_path", (long)"user.pp", 0, 0, 0, 0);
	call("POL", "lsetxattr", __NR_lsetxattr, (long)"/nonexistent_pp_path", (long)"user.pp", 0, 0, 0, 0);
	call("POL", "fsetxattr", __NR_fsetxattr, fdo, (long)"user.pp", 0, 0, 0, 0);
	/* mount：源不存在 + 文件系统类型不存在 ⇒ 真进本体最多 ENOENT/ENODEV，绝不会挂上东西 */
	call("POL", "mount", __NR_mount, (long)"none", (long)"/nonexistent_pp_mnt", (long)"pp_no_such_fs", 0, 0, 0);
	/* init_module：喂一份绝不是 ELF 的 64 字节 ⇒ 真进本体只会 ENOEXEC，不会装任何模块 */
	static char junk[64];
	call("POL", "init_module", __NR_init_module, (long)junk, 64, 0, 0, 0, 0);
	int fdn = open("/dev/null", O_RDONLY);
	call("POL", "finit_module", __NR_finit_module, fdn, (long)"", 0, 0, 0, 0);

	/* ---------- fork 族：#73 的主判据，顺手复验写回还在不在 ---------- */
	{
		void *stk = mmap(NULL, STACK_SZ, PROT_READ | PROT_WRITE,
				 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (stk == MAP_FAILED) { out("CTRL clone: mmap 失败，跳过\n"); }
		else {
			unsigned long long sp = (unsigned long long)stk + STACK_SZ - 16;
			errno = 0;
			long pid = syscall(__NR_clone, (long)SIGCHLD, (long)sp, 0, 0, 0);
			if (pid == 0) { syscall(SYS_exit, 0); }   /* 孩子立刻走：不许碰 stdio/父的账 */
			cell("CTRL", "clone_sigchld", __NR_clone, pid);
			if (pid > 0) { int status; wait4(pid, &status, 0, NULL); }
			struct clone_args ca;
			memset(&ca, 0, sizeof ca);
			ca.flags = 0; ca.pidfd = 0; ca.child_tid = 0; ca.parent_tid = 0;
			ca.exit_signal = SIGCHLD; ca.stack = (unsigned long long)stk + STACK_SZ - 16;
			ca.stack_size = STACK_SZ - 16;
			errno = 0;
			long p2 = syscall(__NR_clone3, &ca, sizeof ca);
			if (p2 == 0) { syscall(SYS_exit, 0); }
			cell("CTRL", "clone3", __NR_clone3, p2);
			if (p2 > 0) { int status; wait4(p2, &status, 0, NULL); }
			munmap(stk, STACK_SZ);
		}
	}

	/* ptrace 放最后：TRACEME 真成功了也只是"下一次 execve 会停"，这一发之后不再 exec */
	call("POL", "ptrace_traceme", __NR_ptrace, 0 /*PTRACE_TRACEME*/, 0, 0, 0, 0, 0);

	if (fdo >= 0) close(fdo);
	unlink(path);
	if (fdn >= 0) close(fdn);
	st("终点");
	out("===== policeprobe DONE =====\n");
	fflush(stdout);
	return 0;
}
