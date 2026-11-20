/*
 * forkprobe.c —— #72 第三版：escape 之后的任务**到底是被什么规则拒掉的**。
 * 一手背景(md §6.164/§6.165)：同一个二进制在 escape 前 fork/pthread_create/vfork 全通，
 * escape 之后 `fork/vfork/pthread_create` 一律 errno=1(EPERM)，而**裸 clone3(CLONE_VM) 通过**；
 * 另外 `setuid(0)` 吃 EPERM，而同族的 `setgid`/`setgroups` 却 OK。
 * ⇒ 这版一次跑完四格，并且**每一格都把 syscall 号本身打出来**(判"偏一格"必须先确认号，不能靠记忆)：
 *   ① CL*：clone3 逐 flag 阶梯(裸 CLONE_VM 一路加到线程那一套) ⇒ 钉"是哪一位被拒"。
 *   ② KN*：同一组合改用**旧 clone**再走一遍 ⇒ 分清"拒的是 flag 组合"还是"拒的是 clone 这个号"。
 *   ③ NB*：号电池 —— 一组无害 syscall 逐个 raw 调用并打 errno。
 *      为什么要有这格：我们 ko 往 sys_call_table 写过 dispatcher 槽(42)、read(63)、fstat(80)，
 *      hook 表里还有 setresuid(147)/execve(221)；而观察到的两个 EPERM 号恰好是 **146 和 220**，
 *      也就是 147-1 与 221-1 ⇒ 必须把每一对 (N, N-1) 都读一遍，才能判"表项是不是写偏了一格"
 *      (看 62=lseek=63-1、79=newfstatat=80-1 是不是跟 146/220 同一个形状)。
 *   ④ LC*：库函数那一层(fork())，和 raw 的那几格对照，看 bionic 有没有加戏。
 * ★这一版不依赖 fork 能成：每一格自己打 errno(规矩：判据要读状态本身)。
 * ★链接：必须 -fno-emulated-tls 且段里有一个 aligned(64) 的 TLS 对象(cm57/build_forkprobe.sh 自检)。
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <linux/sched.h> /* struct clone_args(NDK 的这份里有；bionic 的 <sched.h> 没有) */
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static __thread char tls_pad[64] __attribute__((aligned(64), used));
__attribute__((used)) static volatile char tls_sink;

static char TAG[16] = "P";

static void show_file(const char *label, const char *path, const char *keys)
{
	char line[512];
	FILE *f = fopen(path, "r");

	if (!f) {
		fprintf(stderr, "STATE %s %s: 打不开 errno=%d\n", label, path, errno);
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		const char *k = keys;
		size_t n = strlen(line);

		if (!keys || !*keys) {
			fprintf(stderr, "STATE %s %s: %s", label, path, line);
			continue;
		}
		while (*k) {
			const char *sep = strchr(k, ',');
			size_t kl = sep ? (size_t)(sep - k) : strlen(k);

			if (kl && n > kl && !strncmp(line, k, kl))
				fprintf(stderr, "STATE %s: %s", label, line);
			if (!sep)
				break;
			k = sep + 1;
		}
	}
	fclose(f);
}

static void dump_state(void)
{
	struct utsname u;

	fprintf(stderr, "PROBE tag=%s pid=%d ppid=%d\n", TAG, getpid(), getppid());
	if (uname(&u) == 0)
		fprintf(stderr, "STATE uts: %s %s\n", u.sysname, u.release);
	show_file("status", "/proc/self/status",
		  "Uid:,Gid:,Groups:,CapPrm:,CapEff:,CapBnd:,CapAmb:,Seccomp:,NoNewPrivs:,Threads:");
	show_file("attr", "/proc/self/attr/current", NULL);
	show_file("cgroup", "/proc/self/cgroup", NULL);
	show_file("limits", "/proc/self/limits", "Max processes");
	fprintf(stderr, "STATE NR: setgid=%d setreuid=%d setuid=%d setresuid=%d getresuid=%d "
			"setresgid=%d getresgid=%d setfsuid=%d setfsgid=%d "
			"lseek=%d read=%d newfstatat=%d fstat=%d faccessat=%d "
			"clone=%d execve=%d execveat=%d clone3=%d\n",
			SYS_setgid, SYS_setreuid, SYS_setuid, SYS_setresuid, SYS_getresuid,
			SYS_setresgid, SYS_getresgid, SYS_setfsuid, SYS_setfsgid,
			SYS_lseek, SYS_read, SYS_newfstatat, SYS_fstat, SYS_faccessat,
			SYS_clone, SYS_execve, SYS_execveat, SYS_clone3);
	fflush(stderr);
}

/* ---------- ① clone3 逐 flag 阶梯 ---------- */

/* CLONE_* 一律自己给数(头文件在各家 NDK 里给得不全：这一版编的时候 CLONE_SETTID 就是 undeclared)。
 * 号打出来是判据的一部分——"是不是偏一格"这种结论必须建立在**确认过的号**上。 */
#ifndef CLONE_FS
#define CLONE_FS 0x00000200
#endif
#ifndef CLONE_FILES
#define CLONE_FILES 0x00000400
#endif
#ifndef CLONE_SIGHAND
#define CLONE_SIGHAND 0x00000800
#endif
#ifndef CLONE_VFORK
#define CLONE_VFORK 0x00004000
#endif
#ifndef CLONE_THREAD
#define CLONE_THREAD 0x00010000
#endif
#ifndef CLONE_SYSVSEM
#define CLONE_SYSVSEM 0x00040000
#endif
#ifndef CLONE_SETTLS
#define CLONE_SETTLS 0x00080000
#endif
#ifndef CLONE_PARENT_SETTID
#define CLONE_PARENT_SETTID 0x00100000
#endif
#ifndef CLONE_CHILD_CLEARTID
#define CLONE_CHILD_CLEARTID 0x00200000
#endif
#ifndef CLONE_CHILD_SETTID
#define CLONE_CHILD_SETTID 0x01000000
#endif

static const unsigned long long F_VM = CLONE_VM, F_SIGHAND = CLONE_SIGHAND, F_THREAD = CLONE_THREAD,
				F_FS = CLONE_FS, F_FILES = CLONE_FILES, F_VFORK = CLONE_VFORK,
				F_PSETTID = CLONE_PARENT_SETTID, F_CLEARTID = CLONE_CHILD_CLEARTID,
				F_SYSVSEM = CLONE_SYSVSEM;

/**/

struct step {
	const char *tag;
	unsigned long long flags;
	int exit_signal;
	int use_tid;
};

static void clone3_ladder(void)
{
	struct step steps[] = {
		{ "CL0 裸(0 flag,0 sig)", 0, 0, 0 },
		{ "CL1 VM", F_VM, 0, 0 },
		{ "CL2 VM|SIGHAND", F_VM | F_SIGHAND, 0, 0 },
		{ "CL3 VM|SIGHAND|THREAD", F_VM | F_SIGHAND | F_THREAD, 0, 0 },
		{ "CL4 +FS", F_VM | F_SIGHAND | F_THREAD | F_FS, 0, 0 },
		{ "CL5 +FILES", F_VM | F_SIGHAND | F_THREAD | F_FS | F_FILES, 0, 0 },
		{ "CL6 +PARENT_SETTID",
			F_VM | F_SIGHAND | F_THREAD | F_FS | F_FILES | F_PSETTID, 0, 1 },
		{ "CL7 +CHILD_CLEARTID",
			F_VM | F_SIGHAND | F_THREAD | F_FS | F_FILES | F_PSETTID | F_CLEARTID, 0, 1 },
		{ "CL8 VM+sig=SIGCHLD", F_VM, 17, 0 },
		{ "CL9 0flag+sig=SIGCHLD", 0, 17, 0 },
		{ "CL10 VM|VFORK+sig", F_VM | F_VFORK, 17, 0 },
		{ "CL11 线程全套+自己的栈",
			F_VM | F_SIGHAND | F_THREAD | F_FS | F_FILES | F_SYSVSEM | F_PSETTID |
				F_CLEARTID, 0, 2 },
	};
	unsigned i;
	void *stk = (void *)-1;

	{
		void *p = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

		if (p != MAP_FAILED)
			stk = (char *)p + 65536 - 16; /* 栈从高往低用 */
	}

	for (i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
		struct clone_args ca;
		pid_t rc;
		int e;
		int ptid = 0, ctid = 0;

		memset(&ca, 0, sizeof(ca));
		ca.flags = steps[i].flags;
		ca.exit_signal = (unsigned long long)steps[i].exit_signal;
		if (steps[i].use_tid >= 1) {
			ca.parent_tid = (unsigned long)&ptid;
			ca.child_tid = (unsigned long)&ctid;
		}
		if (steps[i].use_tid == 2 && stk != (void *)-1) {
			ca.stack = (unsigned long)stk;
			ca.stack_size = 32768;
		}
		errno = 0;
		rc = (pid_t)syscall(SYS_clone3, &ca, sizeof(ca));
		e = errno;
		if (rc == 0)
			syscall(SYS_exit, 0); /* 子：立刻退，绝不碰 stdio/栈 */
		fprintf(stderr, "%s nr=%ld rc=%ld errno=%d(%s)\n", steps[i].tag, (long)SYS_clone3,
			(long)rc, rc < 0 ? e : 0, rc < 0 ? strerror(e) : "ok");
		if (rc > 0)
			waitpid(rc, NULL, 0);
		fflush(stderr);
	}
	if (stk != (void *)-1)
		munmap((char *)stk - (65536 - 16), 65536);
}

/* ---------- ② 同一批 flag 改用旧 clone ---------- */

static void legacy_clone_ladder(void)
{
	const char *tg[4] = { "KN1 clone(只有SIGCHLD)", "KN2 clone(VM|VFORK|SIGCHLD)",
			      "KN3 clone(线程那一套)", "KN4 clone(只有VM)" };
	unsigned long long fl[4] = {
		17,
		CLONE_VM | CLONE_VFORK | 17,
		CLONE_VM | CLONE_SIGHAND | CLONE_THREAD | CLONE_FS | CLONE_FILES,
		CLONE_VM,
	};
	int i;

	/* arm64 legacy: clone(flags, stack, ptid, ctid, tls)。stack=0 ⇒ 子沿用当前栈，子只 exit。 */
	for (i = 0; i < 4; i++) {
		pid_t rc;
		int e;

		errno = 0;
		rc = (pid_t)syscall(SYS_clone, fl[i], 0, 0, 0, 0);
		e = errno;
		if (rc == 0)
			syscall(SYS_exit, 0);
		fprintf(stderr, "%s nr=%d rc=%ld errno=%d(%s)\n", tg[i], (int)SYS_clone, (long)rc,
			rc < 0 ? e : 0, rc < 0 ? strerror(e) : "ok");
		if (rc > 0)
			waitpid(rc, NULL, 0);
		fflush(stderr);
	}
}

/* ---------- ③ 号电池 ---------- */

static void try1(const char *tag, long nr, long a0, long a1, long a2, long a3)
{
	long rc;
	int e;

	errno = 0;
	rc = syscall(nr, a0, a1, a2, a3);
	e = errno;
	fprintf(stderr, "NB %-16s nr=%-4ld rc=%-10ld errno=%d(%s)\n", tag, nr, rc, e,
		e ? strerror(e) : "ok");
	fflush(stderr);
}

static void number_battery(void)
{
	char buf[256];
	struct stat st;
	int fd, e;
	pid_t r;
	uid_t u, su, eu;
	gid_t g, sg, eg;

	fd = (int)syscall(SYS_openat, AT_FDCWD, "/dev/null", O_RDONLY | O_CLOEXEC, 0);
	e = errno;
	fprintf(stderr, "NB openat(/dev/null)   nr=%-4ld rc=%-10d errno=%d(%s)\n", (long)SYS_openat, fd,
		fd < 0 ? e : 0, fd < 0 ? strerror(e) : "ok");

	try1("getpid", SYS_getpid, 0, 0, 0, 0);
	try1("getppid", SYS_getppid, 0, 0, 0, 0);

	/* read/fstat 家族：63/80 是 ko 直接写表的两格 ⇒ 连着它们的 -1 一起看 */
	if (fd >= 0) {
		try1("read", SYS_read, fd, (long)buf, 0, 0);
		try1("lseek", SYS_lseek, fd, 0, 1 /* SEEK_CUR */, 0);
		try1("fstat", SYS_fstat, fd, (long)&st, 0, 0);
	}
	try1("newfstatat", SYS_newfstatat, AT_FDCWD, (long)"/dev/null", (long)&st, 0);
	try1("faccessat", SYS_faccessat, AT_FDCWD, (long)"/dev/null", 0, 0);

	/* setuid 家族：观察到的 EPERM 在 146；把 144~152 整族走一遍 */
	u = getuid();
	g = getgid();
	try1("setgid_self", SYS_setgid, (long)g, 0, 0, 0);
	try1("setreuid_-1", SYS_setreuid, -1, -1, 0, 0);
	try1("setuid_self", SYS_setuid, (long)u, 0, 0, 0);
	try1("setresuid_-1", SYS_setresuid, -1, -1, -1, 0);
	su = eu = u;
	try1("getresuid", SYS_getresuid, (long)&su, (long)&eu, (long)&u, 0);
	try1("setresgid_-1", SYS_setresgid, -1, -1, -1, 0);
	sg = eg = g;
	try1("getresgid", SYS_getresgid, (long)&sg, (long)&eg, (long)&g, 0);
	try1("setfsuid_now", SYS_setfsuid, (long)u, 0, 0, 0);
	try1("setfsgid_now", SYS_setfsgid, (long)g, 0, 0, 0);

	/* dispatcher 那一槽(42=nfsservctl，本机应为 ni_syscall)：
	 * 正常应 ENOSYS；回来的不是 ENOSYS 就说明"改道"被被动触发过。 */
	try1("nr42_dispatcher", 42, 0, 0, 0, 0);

	/* ★这一格专门把 seccomp 与"任务级执法"分开(记忆里"can't fork≠信道断"那一族的正面用法)：
	 *   SECCOMP_GET_ACTION_AVAIL=2, SECCOMP_RET_ACTION_FULL=0x7fff0000, RET_ERRNO(EPERM)=0x00050001
	 *   -ENOSYS  ⇒ 本任务上**没有** filter 在跑 ⇒ EPERM 与 seccomp 无关(与 status 的 Seccomp:0 互相印)
	 *   返回 0   ⇒ filter 会"支持"这个动作 ⇒ 那条 EPERM 很可能就是被改过的 BPF 用 RET_ERRNO(EPERM) 给的 */
	{
		unsigned int act = 0x00050001u; /* SECCOMP_RET_ERRNO | EPERM */

		fprintf(stderr, "NB seccomp(GET_ACTION_AVAIL) nr=%ld rc=%ld errno=%d(%s) ⇒ %s\n",
			(long)SYS_seccomp,
			syscall(SYS_seccomp, 2 /*SECCOMP_GET_ACTION_AVAIL*/, 0, (long)&act),
			errno, strerror(errno),
			"rc=0⇒这个任务的 filter 认得 RET_ERRNO(EPERM)；ENOSYS⇒本任务上根本没有 filter 在跑");
		fflush(stderr);
	}

	/* execve 族：不存在的路径 ⇒ 正常应 ENOENT。若 EPERM 就说明 221/281 自己也不干净。 */
	{
		char *path = (char *)"/data/local/tmp/__no_such__";
		char *av[2] = { path, NULL };
		char *ev[1] = { NULL };

		try1("execve_bogus", SYS_execve, (long)path, (long)av, (long)ev, 0);
	}

	/* clone 那个号单独再来一次(放最后，不影响前面的号) */
	errno = 0;
	r = (pid_t)syscall(SYS_clone, 17ULL, 0, 0, 0, 0);
	e = errno;
	if (r == 0)
		syscall(SYS_exit, 0);
	fprintf(stderr, "NB clone_again      nr=%-4ld rc=%-10d errno=%d(%s)\n", (long)SYS_clone, (int)r,
		r < 0 ? e : 0, r < 0 ? strerror(e) : "ok");
	if (r > 0)
		waitpid(r, NULL, 0);

	if (fd >= 0)
		close(fd);
	fprintf(stderr, "NB DONE\n");
	fflush(stderr);
}

/* ---------- ④ 库函数那一层 ---------- */

static void *noop_body(void *a)
{
	(void)a;
	return 0;
}

static void libc_layer(void)
{
	pid_t p;
	int e, st = 0;
	pthread_t th;
	int rc;

	fprintf(stderr, "LC enter\n");
	fflush(stderr);
	errno = 0;
	p = fork();
	e = errno;
	if (p < 0)
		fprintf(stderr, "LC1 fork rc=-1 errno=%d(%s)\n", e, strerror(e));
	else if (p == 0)
		syscall(SYS_exit, 0);
	else {
		waitpid(p, &st, 0);
		fprintf(stderr, "LC1 fork OK pid=%d\n", p);
	}
	fflush(stderr);

	errno = 0;
	rc = pthread_create(&th, NULL, noop_body, NULL);
	e = errno;
	fprintf(stderr, "LC2 pthread_create rc=%d errno=%d(%s)\n", rc, rc ? e : 0,
		rc ? strerror(e) : "ok");
	if (rc == 0)
		pthread_join(th, NULL);

	errno = 0;
	p = vfork();
	e = errno;
	if (p < 0)
		fprintf(stderr, "LC3 vfork rc=-1 errno=%d(%s)\n", e, strerror(e));
	else if (p == 0)
		syscall(SYS_exit, 0);
	else {
		waitpid(p, NULL, 0);
		fprintf(stderr, "LC3 vfork OK pid=%d\n", p);
	}
	fflush(stderr);
}

int main(int argc, char **argv)
{
	tls_pad[0] = tls_sink;
	tls_pad[63] = 1; /* 留引用，否则链接器把那个 TLS 对象丢掉 ⇒ 段对齐又掉回 8 */
	if (argc > 1)
		snprintf(TAG, sizeof(TAG), "%s", argv[1]);
	dump_state();
	fprintf(stderr, "STAGE 1 状态打完了\n");
	fflush(stderr);
	clone3_ladder();
	fprintf(stderr, "STAGE 2 clone3 阶梯跑完了\n");
	fflush(stderr);
	legacy_clone_ladder();
	fprintf(stderr, "STAGE 3 旧 clone 跑完了\n");
	fflush(stderr);
	number_battery();
	fprintf(stderr, "STAGE 4 号电池跑完了\n");
	fflush(stderr);
	libc_layer();
	fprintf(stderr, "STAGE 5 库函数那一层跑完了\n");
	fflush(stderr);
	fprintf(stderr, "=== PROBE_END tag=%s\n", TAG);
	return 0;
}
