/* ksuctl.c —— KernelSU LKM 的用户态控制头 + 授权名单文件生成器(路线 B 的"用户态对接")
 *
 * 两个互不相干的用途，放一个二进制里是为了**同一组数字两头对表**：
 *   1) `mkallow` 生成 /data/adb/ksu/.allowlist —— 内核在 ksu_init 里按**它自己编译期的
 *      sizeof(struct app_profile)** 逐条 kernel_read(见 kernel/policy/allowlist.c:506)，
 *      所以生成端与内核端必须字节一致；`fmt` 打的这行与模块 dmesg 里的 `apfmt:` 行逐项比。
 *   2) `fd/info/allowlist/granted` 走 KSU 的 supercall 通道：
 *      reboot(0xDEADBEEF,0xCAFEBABE,0,&fd) 让内核的 kprobe+task_work 塞一个匿名 fd 回来，
 *      然后 ioctl(fd, _IOC(dir,'K',nr,0))。权限在内核侧按 **current_uid** 判：
 *        GRANT_ROOT=allowed_for_su  GET_INFO=always_allow  NEW_GET_ALLOW_LIST/UID_GRANTED_ROOT
 *        =manager_or_root(⇒ uid 0 可查)  SET_APP_PROFILE=only_manager(我们够不到)
 *      ★所以"能不能查"本身就是判据，不是实现细节。
 *
 * 编译: aarch64-linux-android35-clang -O2 -static -I kmod -o ksuctl cm57/ksuctl.c
 */
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/un.h>
#include <poll.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/stat.h>   /* rc86：cmd_grant 的阶梯要用 stat/access(原来这份头在 655 行，在它后面) */
#include <unistd.h>

#include "uapi/supercall.h"
/* #241：SET_SEPOLICY 的用户态那一头(读文件/本地预解/发不发那道门/填载荷)全在那份头里，
 * 因为它必须同时被 x86 宿主自测跑一遍——写在下面这个函数里就只有一台机器能测到它。 */
#include "w1159_sepol_wire.h"

#define ALLOW_MAGIC 0x7f4b5355u /* ' KSU' —— 逐字抄自 kernel/policy/allowlist.c:28 */
#define ALLOW_VER KSU_APP_PROFILE_VER
#define NS_INHERITED 0 /* infra/su_mount_ns.h:6 KSU_NS_INHERITED */
#define DEF_DOMAIN "u:r:kernel:s0" /* 本机 kthreadd 就在这个域 ⇒ secctx_to_secid 一定解得开 */

/* ★静态链接 + ARM64 Bionic 的加载器要求 PT_TLS 的 p_align >= 64，而 lld 是按"段里最大的节对齐"来定 p_align：
 *   这份源码里的 TLS 对象只有 8 字节对齐 ⇒ 直接编出来的二进制一跑就是
 *   `executable's TLS segment is underaligned: alignment is 8, needs to be at least 64` + Aborted
 *   (第六十五发一手；cm57/ksuctl 与 ksuctl87 两份**能跑**的都是 align=64 ⇒ 差异就在这)。
 *   最省事的修法：放一个 aligned(64) 的占位 TLS 对象，让 lld 把整段抬到 64。 */
#if defined(__aarch64__)
static __thread char ksuctl_tls_pad[64] __attribute__((aligned(64), used));
__attribute__((used)) static volatile char ksuctl_tls_sink;
#define KSUCTL_TLS_KEEP() (ksuctl_tls_pad[0] = ksuctl_tls_sink, ksuctl_tls_pad[63] = 1)
#else
#define KSUCTL_TLS_KEEP() ((void)0)
#endif

static void dump_fmt(void)
{
	printf("apfmt: size=%zu ver@%zu key@%zu curr_uid@%zu allow_su@%zu use_default@%zu "
	       "tmpl@%zu rp@%zu rp_uid@%zu rp_selinux@%zu rp_flags@%zu\n",
	       sizeof(struct app_profile), offsetof(struct app_profile, version),
	       offsetof(struct app_profile, key), offsetof(struct app_profile, curr_uid),
	       offsetof(struct app_profile, allow_su), offsetof(struct app_profile, rp_config.use_default),
	       offsetof(struct app_profile, rp_config.template_name), offsetof(struct app_profile, rp_config.profile),
	       offsetof(struct app_profile, rp_config.profile.uid),
	       offsetof(struct app_profile, rp_config.profile.selinux_domain),
	       offsetof(struct app_profile, rp_config.profile.flags));
}

static int build_profile(struct app_profile *p, uint32_t uid, const char *key, const char *domain)
{
	memset(p, 0, sizeof(*p));
	p->version = ALLOW_VER;
	if (strlen(key) >= sizeof(p->key)) {
		fprintf(stderr, "key 太长(要 < %zu)\n", sizeof(p->key));
		return -1;
	}
	strcpy(p->key, key);
	p->curr_uid = (__s32)uid;
	p->allow_su = 1;

	if (!domain || !strcmp(domain, "-")) {
		p->rp_config.use_default = 1; /* 内核用 default_root_profile(域=u:r:ksu:s0，本机解不开) */
		printf("profile: use_default=1\n");
		return 0;
	}
	/* 自填一份 = 把 init_default_profiles() 抄过来，只把域换成本机存在的 */
	p->rp_config.use_default = 0;
	p->rp_config.profile.uid = 0;
	p->rp_config.profile.gid = 0;
	p->rp_config.profile.groups_count = 1;
	p->rp_config.profile.groups[0] = 0;
	p->rp_config.profile.capabilities.effective = ~(uint64_t)0; /* CAP_FULL_SET = {{~0, ~0}} */
	p->rp_config.profile.namespaces = NS_INHERITED;
	p->rp_config.profile.flags = 0;
	if (strlen(domain) >= sizeof(p->rp_config.profile.selinux_domain)) {
		fprintf(stderr, "domain 太长\n");
		return -1;
	}
	strcpy(p->rp_config.profile.selinux_domain, domain);
	printf("profile: use_default=0 uid=0 gid=0 caps=~0 ns=%d domain=%s\n", NS_INHERITED, domain);
	return 0;
}

static int cmd_mkallow(int argc, char **argv)
{
	const char *out = argv[2];
	uint32_t uid = (uint32_t)strtoul(argv[3], NULL, 0);
	const char *key = argc > 4 ? argv[4] : "manual";
	const char *domain = argc > 5 ? argv[5] : DEF_DOMAIN;
	struct {
		uint32_t magic, version;
	} hdr = { ALLOW_MAGIC, ALLOW_VER };
	struct app_profile p;

	if (argc < 4) {
		fprintf(stderr, "用法: ksuctl mkallow <out> <uid> [key] [domain|-]\n");
		fprintf(stderr, "      ksuctl mkallow <out> <uid> <key> <domain> [<uid> <key> <domain> ...]\n");
		return 2;
	}
	/* ★多条目形态(§6.154：官方 Manager 的 su 子进程要 `domain=u:r:shell:s0`，而 SET_APP_PROFILE 是
	 *   **only_manager** ⇒ root 也发不动(一手：uid=0 ctx=u:r:kernel:s0 发过去 `rc=-1 errno=1`)，
	 *   而"让 Manager 自己发"又正好是坏掉的那条 libsu 路 ⇒ 唯一不依赖运行期 ioctl 的入口就是
	 *   **insmod 时那份 .allowlist 文件**(内核 init 期 load_allowlist 会读 N 条)。)
	 * 三元组个数 = (argc-3)/3；旧的 1~2 个尾巴参数仍走下面那条单条目路，向后兼容。 */
	if (argc >= 6 && (argc - 3) % 3 == 0) {
		int groups = (argc - 3) / 3;
		int i;
		FILE *g = fopen(out, "wb");
		if (!g) {
			perror("open");
			return 1;
		}
		if (fwrite(&hdr, sizeof(hdr), 1, g) != 1) {
			perror("write hdr");
			fclose(g);
			return 1;
		}
		for (i = 0; i < groups; i++) {
			uint32_t u = (uint32_t)strtoul(argv[3 + i * 3], NULL, 0);
			const char *k = argv[3 + i * 3 + 1];
			const char *dm = argv[3 + i * 3 + 2];
			struct app_profile pp;
			if (build_profile(&pp, u, k, dm)) {
				fclose(g);
				return 2;
			}
			if (fwrite(&pp, sizeof(pp), 1, g) != 1) {
				perror("write entry");
				fclose(g);
				return 1;
			}
			printf("  条目 %d: uid=%u key=%s domain=%s\n", i, u, k, dm);
		}
		fclose(g);
		printf("wrote %s: 8 + %d*%zu = %ld 字节\n", out, groups, sizeof(struct app_profile),
		       8L + (long)groups * (long)sizeof(struct app_profile));
		return 0;
	}
	if (build_profile(&p, uid, key, domain))
		return 2;
	FILE *f = fopen(out, "wb");
	if (!f) {
		perror("open");
		return 1;
	}
	if (fwrite(&hdr, sizeof(hdr), 1, f) != 1 || fwrite(&p, sizeof(p), 1, f) != 1) {
		perror("write");
		fclose(f);
		return 1;
	}
	fclose(f);
	printf("wrote %s: 8 + %zu = %ld 字节, uid=%u key=%s\n", out, sizeof(p), 8L + (long)sizeof(p), uid, key);
	dump_fmt();
	return 0;
}

static int g_outp_static = -1; /* 第 2 种目标：静态变量(不在栈上) */

/* 从自己的 fd 表里认出 KSU 装的匿名 inode fd(内核里名字写死 "[ksu_driver]")。
 * 第十二发证明：内核已经把 fd 装进来了(fd=3)，只是"把 fd 号回传给用户态"那一步 copy_to_user 失败，
 * 而且失败路径还会把 fd 关掉 ⇒ 这条扫描是**rc17 之后的兜底**(两条写路都不行时也至少能认出)。 */
static int scan_ksu_fd(void)
{
	DIR *d = opendir("/proc/self/fd");
	int found = -1;
	char link[64], buf[64];
	struct dirent *e;
	if (!d)
		return -1;
	while ((e = readdir(d))) {
		int fdno;
		ssize_t n;
		if (e->d_name[0] < '0' || e->d_name[0] > '9')
			continue;
		fdno = atoi(e->d_name);
		if (fdno <= 2)
			continue;
		snprintf(link, sizeof(link), "/proc/self/fd/%d", fdno);
		n = readlink(link, buf, sizeof(buf) - 1);
		if (n <= 0)
			continue;
		buf[n] = 0;
		if (strstr(buf, "ksu_driver")) {
			printf("  scan: fd %d -> %s\n", fdno, buf);
			found = fdno;
			break;
		}
	}
	closedir(d);
	return found;
}

static int drive_fd(void)
{
	/* 四种"回传落点"一次试完：哪个能用就用哪个，同时也是一组**对照**(全是同一个 syscall，
	 * 只有目标内存的种类不同) ⇒ 如果只有 mmap 那个能成，说明限制跟 VMA 种类有关。 */
	struct {
		const char *kind;
		int *slot;
	} targets[] = {
		{ "stack", NULL },
		{ "static", &g_outp_static },
		{ "malloc", NULL },
		{ "mmap", NULL },
	};
	int stackv = -1, *mallocv, *mmapv;
	size_t i;
	int got = -1;
	targets[0].slot = &stackv;
	mallocv = malloc(sizeof(int) * 8);
	if (mallocv) {
		memset(mallocv, 0xff, sizeof(int) * 8);
		targets[2].slot = mallocv + 3; /* 故意不用偏移 0，排掉"分配器头"这种解释 */
	}
	mmapv = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (mmapv != MAP_FAILED) {
		mmapv[0] = -1;
		targets[3].slot = mmapv;
	}
	for (i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
		int v = -1, r, e;
		if (!targets[i].slot) {
			printf("目标种类 %s 拿不到地址，跳过\n", targets[i].kind);
			continue;
		}
		*targets[i].slot = -1;
		r = (int)syscall(SYS_reboot, (int)KSU_INSTALL_MAGIC1, (int)KSU_INSTALL_MAGIC2, 0, targets[i].slot);
		e = errno;
		v = *targets[i].slot;
		printf("reboot(magic) -> ret=%d errno=%d(%s), %s 落点=%p 回传值=%d\n", r, e, strerror(e),
		       targets[i].kind, (void *)targets[i].slot, v);
		if (v >= 0 && got < 0)
			got = v;
	}
	if (got < 0) {
		printf("四种回传都没拿到 ⇒ 扫 /proc/self/fd 兜底:\n");
		got = scan_ksu_fd();
		if (got >= 0)
			printf("  兜底成功: fd=%d\n", got);
	}
	if (got >= 0) {
		char link[64], buf[64];
		ssize_t n;
		snprintf(link, sizeof(link), "/proc/self/fd/%d", got);
		n = readlink(link, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = 0;
			printf("fd %d -> %s  (应当是 [ksu_driver] 或 [ksu_driver_su])\n", got, buf);
		}
	}
	return got;
}

static int cmd_fd(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	int fd = drive_fd();
	return fd >= 0 ? 0 : 1;
}

static int cmd_info(int argc, char **argv)
{
	int fd = argc > 2 ? atoi(argv[2]) : drive_fd();
	if (fd < 0)
		return 1;
	struct ksu_get_info_cmd c;
	memset(&c, 0, sizeof(c));
	int r = ioctl(fd, KSU_IOCTL_GET_INFO, &c);
	printf("GET_INFO rc=%d errno=%d(%s) version=%u flags=0x%x features=%u uapi=%u\n", r, errno, strerror(errno),
	       c.version, c.flags, c.features, c.uapi_version);
	printf("  flags 位: LKM=%d MANAGER=%d LATE_LOAD=%d PR=%d BUNDLED=%d\n", !!(c.flags & KSU_GET_INFO_FLAG_LKM),
	       !!(c.flags & KSU_GET_INFO_FLAG_MANAGER), !!(c.flags & KSU_GET_INFO_FLAG_LATE_LOAD),
	       !!(c.flags & KSU_GET_INFO_FLAG_PR_BUILD), !!(c.flags & KSU_GET_INFO_FLAG_BUNDLED));
	return r ? 1 : 0;
}

static int cmd_allowlist(int argc, char **argv)
{
	int fd = argc > 2 ? atoi(argv[2]) : drive_fd();
	if (fd < 0)
		return 1;
	unsigned cap = 512;
	size_t sz = sizeof(struct ksu_new_get_allow_list_cmd) + sizeof(uint32_t) * cap;
	struct ksu_new_get_allow_list_cmd *c = calloc(1, sz);
	c->count = (__u16)cap;
	int r = ioctl(fd, KSU_IOCTL_NEW_GET_ALLOW_LIST, c);
	printf("NEW_GET_ALLOW_LIST rc=%d errno=%d(%s) count=%u total=%u\n", r, errno, strerror(errno), c->count,
	       c->total_count);
	for (unsigned i = 0; i < c->count && i < cap; i++)
		printf("  allow[%u] uid=%u\n", i, c->uids[i]);
	free(c);

	c = calloc(1, sz);
	c->count = (__u16)cap;
	r = ioctl(fd, KSU_IOCTL_NEW_GET_DENY_LIST, c);
	printf("NEW_GET_DENY_LIST rc=%d errno=%d(%s) count=%u total=%u\n", r, errno, strerror(errno), c->count,
	       c->total_count);
	free(c);
	return r ? 1 : 0;
}

static int cmd_setprof(int argc, char **argv)
{
	/* 用法: ksuctl setprof <uid> <pkg> <domain|-> [fd]
	 * ★为什么要 root 侧这一份(§6.153⑥ 一手)：SET_APP_PROFILE 的 perm_check 是 manager_or_root，
	 *   而"把王座让给官方 Manager"之后我们自己的 suw(uid 10104)发它就是 EPERM
	 *   (`SETPROF uid=10317 allow=1 ... rc=-1 errno=1(Operation not permitted)`)。
	 *   官方 UI 那个开关要经 libsu 的 RootService(root 的 app_process)，而 Manager 自己的 su 子进程
	 *   **uid 已是 0 但域还是 u:r:untrusted_app** ⇒ app_process 起不来 ⇒ toast"更新 App Profile 失败"、
	 *   内核 SET_APP_PROFILE 命中 0 次。要给它换域只能从 root 侧写这条 profile。
	 * 字段设置逐字照 suw_apk/suwksu_jni.c 里那份**本机验过**的(§6.107②)，不自己发明第二套。 */
	if (argc < 5) {
		fprintf(stderr, "用法: ksuctl setprof <uid> <pkg> <domain|-> [fd]\n");
		return 2;
	}
	int fd = argc > 5 ? atoi(argv[5]) : drive_fd();
	if (fd < 0)
		return 1;
	uint32_t who = (uint32_t)strtoul(argv[2], NULL, 0);
	struct ksu_set_app_profile_cmd sp;
	memset(&sp, 0, sizeof(sp));
	sp.profile.version = KSU_APP_PROFILE_VER;
	if (strlen(argv[3]) >= sizeof(sp.profile.key)) {
		fprintf(stderr, "key 太长(要 < %zu)\n", sizeof(sp.profile.key));
		return 2;
	}
	strcpy(sp.profile.key, argv[3]);
	sp.profile.curr_uid = (__s32)who;
	sp.profile.allow_su = true;
	if (!strcmp(argv[4], "-")) {
		sp.profile.rp_config.use_default = true; /* 内核自己那份模板(本机解不开 u:r:ksu:s0，慎用) */
	} else {
		if (strlen(argv[4]) >= sizeof(sp.profile.rp_config.profile.selinux_domain)) {
			fprintf(stderr, "domain 太长(要 < %zu)\n", sizeof(sp.profile.rp_config.profile.selinux_domain));
			return 2;
		}
		sp.profile.rp_config.use_default = false;
		sp.profile.rp_config.profile.uid = 0;
		sp.profile.rp_config.profile.gid = 0;
		sp.profile.rp_config.profile.groups_count = 1;
		sp.profile.rp_config.profile.groups[0] = 0;
		sp.profile.rp_config.profile.capabilities.effective = ~(__u64)0;
		sp.profile.rp_config.profile.namespaces = NS_INHERITED;
		sp.profile.rp_config.profile.flags = 0;
		strcpy(sp.profile.rp_config.profile.selinux_domain, argv[4]);
	}
	int r = ioctl(fd, KSU_IOCTL_SET_APP_PROFILE, &sp);
	int ee = r ? errno : 0; /* ★errno 必须当场存(第 47 发：同句里 strerror 会拿到陈旧 errno) */
	printf("SET_APP_PROFILE uid=%u key=%s domain=%s rc=%d errno=%d(%s)\n", who, sp.profile.key, argv[4], r, ee,
	       strerror(ee));
	struct ksu_uid_granted_root_cmd gc;
	memset(&gc, 0, sizeof(gc));
	gc.uid = (__u32)who;
	int r2 = ioctl(fd, KSU_IOCTL_UID_GRANTED_ROOT, &gc);
	int e2 = r2 ? errno : 0;
	printf("  回读 UID_GRANTED_ROOT uid=%u rc=%d errno=%d(%s) granted=%u\n", gc.uid, r2, e2, strerror(e2), gc.granted);
	return r ? 1 : 0;
}

static int cmd_setsepol(int argc, char **argv)
{
	/* 用法: ksuctl setsepol <文件> [--send|--dry] [fd]
	 * ★为什么要这一条(#241)：我们的窗口里**没有真 ksud** ⇒ `handle_sepolicy` 这条口从来没被自然
	 *   调用过；而 #236 证过官方 ksud 会把桩返回的 -EOPNOTSUPP **静默吞掉**。这一条把"发不发、
	 *   看到什么"收回我们自己手里(读文件→本地预解→ioctl→**我们自己**读 rc/errno)。
	 * ★返回值的口径(第 96 发一手)：SET_SEPOLICY 回的是"内核应用了几条"，**正数不是错误** ⇒
	 *   不能像别的那几条一样"`rc!=0` 就当失败"。只在 rc<0 时才碰 errno。
	 * ★默认**不发**：不带 --send 就只做"读文件＋本地预解＋打记录"，连驱动 fd 都不开 ⇒ 窗口外、
	 *   执法态、基线态都能随手跑。这道门是纯逻辑(w1159_gate)，在宿主自测里双向覆盖过。
	 * ★本地预解只是**证人**不是**闸门**：`why` 再难看也照样允许发——要判的是内核怎么看这批字节。
	 * 退出码：0＝没发(dry)或内核答复 rc>=0；1＝拿不到 fd；2＝用法/文件读不成；4＝内核回了负数。 */
	const char *path = NULL;
	int want_send = 0, fdi = -1, i;
	w1151_u8 *buf = NULL;
	struct w1151_stmt *st = NULL;
	char *rec = NULL;
	struct w1159_load ld;
	struct w1159_view v;
	struct ksu_set_sepolicy_cmd c;
	int dec = -7, gate, fd, r, ee, rv;

	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--send") || !strcmp(argv[i], "send"))
			want_send = 1;
		else if (!strcmp(argv[i], "--dry") || !strcmp(argv[i], "dry"))
			want_send = 0;
		else if (!path)
			path = argv[i];
		else
			fdi = atoi(argv[i]);
	}
	if (!path) {
		fprintf(stderr, "用法: ksuctl setsepol <文件> [--send|--dry] [fd]\n");
		return 2;
	}
	/* ★把这一次实际生效的参数回抄出来：默认关着的分段开关不印出来，事后就分不清"没发"和"忘了发" */
	printf("SETSEPOL path=%s want_send=%d slots=%u in_cap=%llu rec_cap=%d\n", path, want_send,
	       W1159_SLOTS, W1151_IN_MAX, W1159_REC_CAP);

	buf = malloc(W1151_IN_MAX);
	rec = malloc(W1159_REC_CAP + 1);
	st = malloc((size_t)W1159_SLOTS * sizeof(*st));
	if (!buf || !rec || !st) {
		printf("SETSEPOL 内存没分出来 buf=%p rec=%p st=%p\n", (void *)buf, (void *)rec,
		       (void *)st);
		free(buf);
		free(rec);
		free(st);
		printf("VERDICT=setsepol_nomem\n");
		return 1;
	}
	memset(buf, 0, W1151_IN_MAX);
	rec[W1159_REC_CAP] = 0;
	ld.code = w1159_load_file(path, buf, W1151_IN_MAX, &ld);
	printf("SEPLOAD code=%d want=%llu got=%llu fnv=%llu\n", ld.code, ld.want, ld.got, ld.fnv);
	if (ld.code == W1159_F_OK)
		dec = w1159_preview(buf, ld.got, W1159_SLOTS, st, rec, W1159_REC_CAP, 1, 1, &v);
	else
		memset(&v, 0, sizeof(v));
	printf("PREVIEW dec=%d why=%u n=%u bad_at=%llu max_arg=%u lenmatch=%d rec_total=%d rec_trunc=%d\n",
	       dec, v.rep.why, v.rep.n, v.rep.bad_at, v.rep.max_arg_len, v.lenmatch, v.rec_total,
	       v.rec_trunc);
	if (ld.code == W1159_F_OK)
		printf("--- 本地记录(与 ko 里那份同一把尺渲染) ---%s--- 记录结束 ---\n", rec);

	gate = w1159_gate(want_send, ld.code);
	if (gate == W1159_DRY) {
		printf("GATE=dry 没发 ioctl(要发加 --send；读不成 code=%d 时加也没用)\n", ld.code);
		free(buf);
		free(rec);
		free(st);
		if (ld.code != W1159_F_OK)
			printf("VERDICT=setsepol_badfile\n");
		else
			printf("VERDICT=setsepol_dry\n");
		return ld.code == W1159_F_OK ? 0 : 2;
	}
	fd = fdi >= 0 ? fdi : drive_fd();
	if (fd < 0) {
		printf("SETSEPOL 拿不到驱动 fd ⇒ 一个 ioctl 都没发出去(上面那些数只是本地预解)\n");
		free(buf);
		free(rec);
		free(st);
		printf("VERDICT=setsepol_nofd\n");
		return 1;
	}
	w1159_fill_cmd(&c, buf, ld.got);
	r = ioctl(fd, KSU_IOCTL_SET_SEPOLICY, &c);
	ee = (r < 0) ? errno : 0; /* ★errno 必须当场存；且 rc>0 是"应用了几条"，不是错误 */
	printf("SET_SEPOLICY fd=%d rc=%d errno=%d(%s) data=%p data_len=%llu\n", fd, r, ee,
	       strerror(ee > 0 ? ee : 0), (void *)(uintptr_t)c.data, (unsigned long long)c.data_len);
	if (r < 0) {
		printf("  内核拒收：一条都没应用。95=EOPNOTSUPP＝今天那份桩**按设计**不谎报(#236)；"
		       "1=EPERM＝only_root 没过(这条的 perm_check 是 only_root)。\n");
		rv = 4;
	} else {
		printf("  内核回报应用了 %d 条；本地解出 n=%u ⇒ %s(正数＝applied 计数，别当错误码)\n", r,
		       v.rep.n, r == (int)v.rep.n ? "两边同一条数" : "有差");
		rv = 0;
	}
	free(buf);
	free(rec);
	free(st);
	printf("VERDICT=setsepol_fired exit=%d\n", rv);
	return rv;
}

static int cmd_granted(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "用法: ksuctl granted <uid> [fd]\n");
		return 2;
	}
	int fd = argc > 3 ? atoi(argv[3]) : drive_fd();
	if (fd < 0)
		return 1;
	struct ksu_uid_granted_root_cmd c;
	memset(&c, 0, sizeof(c));
	c.uid = (__u32)strtoul(argv[2], NULL, 0);
	int r = ioctl(fd, KSU_IOCTL_UID_GRANTED_ROOT, &c);
	printf("UID_GRANTED_ROOT uid=%u rc=%d errno=%d(%s) granted=%u\n", c.uid, r, errno, strerror(errno), c.granted);
	return r ? 1 : 0;
}

static int cmd_mgr(int argc, char **argv)
{
	/* GET_MANAGER_APPID 的 perm_check = manager_or_root ⇒ root 侧读得到。
	 * 这就是"谁坐在王座上"的内核口径：未 crown 时是 KSU_INVALID_APPID(-1 ⇒ u32 打印 4294967295)，
	 * 被 throne tracker(insmod 时扫 /data/app + 验签)crown 之后应当等于 uid%100000。 */
	int fd = argc > 2 ? atoi(argv[2]) : drive_fd();
	struct ksu_get_manager_appid_cmd c;
	int r;
	if (fd < 0)
		return 1;
	memset(&c, 0, sizeof(c));
	r = ioctl(fd, KSU_IOCTL_GET_MANAGER_APPID, &c);
	printf("GET_MANAGER_APPID rc=%d errno=%d(%s) appid=%u%s\n", r, r ? errno : 0,
	       strerror(errno), c.appid,
	       c.appid == (unsigned)-1 ? " (=KSU_INVALID_APPID ⇒ 还没人坐上王座)" : "");
	return r ? 1 : 0;
}

static int cmd_all(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	char fdstr[32];
	char uidstr[32];
	snprintf(uidstr, sizeof(uidstr), "%d", 2000);
	int fd = drive_fd();
	if (fd < 0)
		return 1;
	printf("-- getuid=%u geteuid=%u\n", (unsigned)getuid(), (unsigned)geteuid());
	snprintf(fdstr, sizeof(fdstr), "%d", fd);
	char *av_info[3] = { (char *)"ksuctl", (char *)"info", fdstr };
	char *av_allow[3] = { (char *)"ksuctl", (char *)"allowlist", fdstr };
	char *av_grant[4] = { (char *)"ksuctl", (char *)"granted", uidstr, fdstr };
	cmd_info(3, av_info);
	cmd_allowlist(3, av_allow);
	cmd_granted(4, av_grant);
	return 0;
}

static int cmd_mark(int argc, char **argv)
{
	/* KSU_IOCTL_MANAGE_MARK = manager_or_root ⇒ **晚加载(late load)时给正在跑的任务补 mark
	 * 的唯一入口**。为什么必须要它：execve/faccessat 那条 hook 只对"打了 mark 的任务"生效
	 * (TIF/SYSCALL_WORK 位)，而晚加载时 ksu_mark_running_process() 一个都没跑过
	 * (boot_complete 被 skip，regfunc kretprobe 又没人触发) ⇒ 不 mark 就永远等不到 su。
	 * get 用来做**可证伪判据**：mark 前 0，mark 后 1。 */
	const struct {
		const char *name;
		uint32_t op;
	} ops[] = { { "get", KSU_MARK_GET }, { "mark", KSU_MARK_MARK }, { "unmark", KSU_MARK_UNMARK },
		    { "all", KSU_MARK_MARK }, { "refresh", KSU_MARK_REFRESH } };
	unsigned i;
	if (argc < 3) {
		fprintf(stderr, "用法: ksuctl mark <get|mark|unmark|all|refresh> [pid] [fd]\n");
		return 2;
	}
	for (i = 0; i < sizeof(ops) / sizeof(ops[0]); i++)
		if (!strcmp(argv[2], ops[i].name))
			break;
	if (i == sizeof(ops) / sizeof(ops[0])) {
		fprintf(stderr, "不认识的 mark 操作: %s\n", argv[2]);
		return 2;
	}
	long pid = argc > 3 ? strtol(argv[3], NULL, 0) : 0;
	if (!strcmp(ops[i].name, "all"))
		pid = 0; /* 内核里 MARK + pid==0 才是"给所有任务打标" */
	int fd = argc > 4 ? atoi(argv[4]) : drive_fd();
	if (fd < 0)
		return 1;
	struct ksu_manage_mark_cmd c;
	memset(&c, 0, sizeof(c));
	c.operation = ops[i].op;
	c.pid = (__s32)pid;
	int r = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &c);
	printf("MANAGE_MARK op=%s pid=%ld rc=%d errno=%d(%s) result=%u\n", ops[i].name, pid, r, errno, strerror(errno),
	       c.result);
	return r ? 1 : 0;
}

static int cmd_su(int argc, char **argv)
{
	/* 端到端判据：**在这个脚本里**把 su 测完，不依赖 adb 之后还活着。
	 * 用法: ksuctl su <uid> <命令字符串>
	 * 做法: fork → 子进程 setgid/setuid 到 <uid> → execve("/system/bin/su", ["su","-c",cmd])
	 *      KSU 的 execve hook 会对"已授权 uid"把它改写成 /data/adb/ksud(=我们的 shim)，
	 *      并在内核里 escape_with_root_profile() ⇒ 子进程应当变 uid 0。
	 * ★先落一份"我改了哪个 uid"的凭证：/proc/<pid>/status 的 Uid 行在 exec 前后各读一次。 */
	if (argc < 4) {
		fprintf(stderr, "用法: ksuctl su <uid> <命令>\n");
		return 2;
	}
	long uid = strtol(argv[2], NULL, 0);
	int p[2];
	if (pipe(p)) {
		perror("pipe");
		return 1;
	}
	pid_t pid = fork();
	if (pid == 0) {
		dup2(p[1], 1);
		dup2(p[1], 2);
		close(p[0]);
		close(p[1]);
		if (setgroups(0, NULL) && getuid() == 0)
			fprintf(stderr, "setgroups 失败 errno=%d\n", errno);
		if (setgid((gid_t)uid) || setuid((uid_t)uid)) {
			fprintf(stderr, "降权到 %ld 失败 errno=%d(%s)\n", uid, errno, strerror(errno));
			_exit(127);
		}
		char *av[] = { (char *)"/system/bin/su", (char *)"-c", argv[3], NULL };
		char *ev[] = { (char *)"PATH=/system/bin:/system/xbin:/vendor/bin", (char *)"HOME=/tmp", NULL };
		execve("/system/bin/su", av, ev);
		fprintf(stderr, "execve(/system/bin/su) 失败 errno=%d(%s)\n", errno, strerror(errno));
		_exit(126);
	}
	close(p[1]);
	char buf[512];
	ssize_t r;
	printf("---- su(uid=%ld) 输出开始 ----\n", uid);
	while ((r = read(p[0], buf, sizeof(buf))) > 0)
		fwrite(buf, 1, (size_t)r, stdout);
	printf("---- 输出结束 (read errno=%d) ----\n", errno);
	close(p[0]);
	int st = 0;
	waitpid(pid, &st, 0);
	printf("waitpid: exit=%d signal=%d\n", WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);
	return 0;
}

static int cmd_supath(int argc, char **argv)
{
	/* ★为什么非要有这个动词(第二十二发的教训，md §6.124②)：
	 *   cmd_su 写死 execve("/system/bin/su", ...)，而我们 ko 的 execve 钩子(bit1)是在
	 *   **路径解析之前**把它改道到 ksu_ksud_path 的 ⇒ /system/bin/su 这个文件**根本不存在**
	 *   的时候 cmd_su 照样出 uid=0(root)。第二十二发 (a′) 那格"挂载前必须失败"就是这么废的：
	 *   回执里明明印着 `ls: /system/bin/su: No such file`，同一段却出了 root。
	 *   ⇒ 拿 cmd_su 当"su 可见性"的判据 = 假阳性。
	 * 这个动词只做一件事：fork → 降到 <uid> → **execvp(按 PATH 找)**。不碰 ioctl、不碰驱动
	 *   fd、不改任何标位 ⇒ 它和真 app 手敲 `su` 是同一条链：PATH 里没有就是 ENOENT。
	 *   只要 <名字> 解析出来不等于 /system/bin/su，钩子就不插手，测到的就是"文件在不在"。
	 * ★它测不了的那半格：起点域是 root 侧(不是 untrusted_app)，所以 app 域那半仍要靠
	 *   suw app 的 @suprobe: 来证。两者合起来才是完整判据。
	 * 用法: ksuctl supath <uid> <PATH> <名字> [参数...]
	 */
	if (argc < 5) {
		fprintf(stderr, "用法: ksuctl supath <uid> <PATH> <名字> [参数...]\n");
		return 2;
	}
	long uid = strtol(argv[2], NULL, 0);
	int p[2];
	if (pipe(p)) {
		perror("supath: pipe");
		return 1;
	}
	pid_t pid = fork();
	if (pid == 0) {
		dup2(p[1], 1);
		dup2(p[1], 2);
		close(p[0]);
		close(p[1]);
		if (setgroups(0, NULL) && getuid() == 0)
			fprintf(stderr, "supath: setgroups 失败 errno=%d(%s)\n", errno, strerror(errno));
		if (setgid((gid_t)uid) || setuid((gid_t)uid)) {
			fprintf(stderr, "supath: 降到 %ld 失败 errno=%d(%s)\n", uid, errno, strerror(errno));
			_exit(127);
		}
		setenv("PATH", argv[3], 1);
		{
			/* 起点身份先印出来：uid/域不对，后面所有结论都不算 */
			char ctx[128];
			int c = open("/proc/self/attr/current", O_RDONLY);
			int cn = c < 0 ? 0 : (int)read(c, ctx, sizeof(ctx) - 1);
			if (cn > 0) ctx[cn] = 0;
			else ctx[0] = 0;
			if (c >= 0) close(c);
			fprintf(stderr, "SUPATH-START uid=%u euid=%u gid=%u PATH=[%s] ctx=%s\n",
				getuid(), geteuid(), getgid(), argv[3], ctx);
			fflush(stderr);
		}
		char **av = &argv[4];
		execvp(av[0], av);
		fprintf(stderr, "SUPATH-EXECVP-FAIL name=[%s] errno=%d(%s)\n", av[0], errno,
			strerror(errno));
		fflush(stderr);
		_exit(126);
	}
	close(p[1]);
	char buf[512];
	ssize_t r;
	printf("---- supath(uid=%ld) 输出开始 ----\n", uid);
	while ((r = read(p[0], buf, sizeof(buf))) > 0)
		fwrite(buf, 1, (size_t)r, stdout);
	printf("---- 输出结束 (read errno=%d) ----\n", errno);
	close(p[0]);
	int st = 0;
	waitpid(pid, &st, 0);
	printf("SUPATH-WAIT exit=%d signal=%d\n",
		WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);
	return 0;
}

static int cmd_sumark(int argc, char **argv)
{
	/* 为什么要单独一个子命令(第十六发实证)：脚本 `mark mark $$` 之后再 exec 任何二进制
	 * 都会走被改道的 execve ⇒ 当场 "inaccessible or not found" ⇒ 连 ksuctl 自己起不来。
	 * 所以顺序必须是：先起来 → 拿到 fd → **给自己打标** → fork → 子进程(继承标记) execve su。 */
	if (argc < 4) {
		fprintf(stderr, "用法: ksuctl sumark <uid> <命令>\n");
		return 2;
	}
	long uid = strtol(argv[2], NULL, 0);
	int fd = drive_fd();
	if (fd < 0) {
		fprintf(stderr, "拿不到驱动 fd，无法打标\n");
		return 1;
	}
	struct ksu_manage_mark_cmd mk;
	memset(&mk, 0, sizeof(mk));
	mk.operation = KSU_MARK_MARK;
	mk.pid = (__s32)getpid();
	int r = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &mk);
	printf("self-mark pid=%d rc=%d errno=%d(%s)\n", getpid(), r, errno, strerror(errno));

	int p[2];
	if (pipe(p)) {
		perror("pipe");
		return 1;
	}
	pid_t pid = fork();
	if (pid == 0) {
		dup2(p[1], 1);
		dup2(p[1], 2);
		close(p[0]);
		close(p[1]);
		/* ★rc21 起子进程**自己再打一次标**：不拿"fork 继不继承 ti->flags"当判据的前提。
		 * ★第二十章的教训：子进程的 printf 走 stdout，而 stdout 接到了管道 = **全缓冲**，
		 *   紧接着的 execve 直接换掉映像 ⇒ 缓冲里的字**一个都没落进管道**(_exit 也不 flush)，
		 *   所以上一发的 "child-mark" 看着像没跑。⇒ 判据一律 fprintf(stderr)+fflush。 */
		struct ksu_manage_mark_cmd mk2;
		memset(&mk2, 0, sizeof(mk2));
		mk2.operation = KSU_MARK_MARK;
		mk2.pid = (__s32)getpid();
		int r2 = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &mk2);
		fprintf(stderr, "child-mark pid=%d rc=%d errno=%d(%s)\n", getpid(), r2, errno, strerror(errno));
		memset(&mk2, 0, sizeof(mk2));
		mk2.operation = KSU_MARK_GET;
		mk2.pid = (__s32)getpid();
		int r3 = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &mk2);
		fprintf(stderr, "child-markget pid=%d rc=%d result=%u (1=带标,execve 才会被改道)\n", getpid(), r3,
			mk2.result);
		fflush(stderr);
		if (setgid((gid_t)uid) || setuid((uid_t)uid)) {
			fprintf(stderr, "降权到 %ld 失败 errno=%d(%s)\n", uid, errno, strerror(errno));
			_exit(127);
		}
		char *av[] = { (char *)"/system/bin/su", (char *)"-c", argv[3], NULL };
		char *ev[] = { (char *)"PATH=/system/bin:/system/xbin:/vendor/bin", (char *)"HOME=/tmp", NULL };
		execve("/system/bin/su", av, ev);
		fprintf(stderr, "execve(/system/bin/su) 失败 errno=%d(%s)\n", errno, strerror(errno));
		_exit(126);
	}
	close(p[1]);
	char buf[512];
	ssize_t rr;
	printf("---- su(uid=%ld) 输出开始 ----\n", uid);
	while ((rr = read(p[0], buf, sizeof(buf))) > 0)
		fwrite(buf, 1, (size_t)rr, stdout);
	printf("---- 输出结束 ----\n");
	close(p[0]);
	int st = 0;
	waitpid(pid, &st, 0);
	printf("waitpid: exit=%d signal=%d\n", WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);
	return 0;
}

/* cmd_grant —— 只测 `escape_with_root_profile()` 这一件事（md §6.50）。
 * 依据(一手)：`supercall/dispatch.c: do_grant_root(void __user *arg)` **不看 arg**，
 *   直接 `escape_with_root_profile()` 给**当前进程**换 cred；perm 是 `allowed_for_su`
 *   ⇒ 调用者的 **ruid** 必须在名单里（`__ksu_is_allow_uid()` 第一行 `forbid_system_uid`
 *   会把 uid 0/2000 直接拒掉，见 §6.44/§6.48）。
 * ⇒ 这条路**不经过 sucompat**：没有 `filp_open(/data/adb/ksud)`、没有改 execve 寄存器、
 *   没有嵌套 `execveat` ⇒ 如果设备在这一步死，凶手就被单独关在 escape 里面；
 *   如果活了且 uid 变 0，则 escape 是好的，之前四发的死因在 sucompat 那半段。
 * ★判据全部走 stderr(无缓冲)——第二十四发的教训：stdout 接管道是全缓冲，
 *   紧接着 _exit 不会 flush，字会丢。 */
static int cmd_grant(int argc, char **argv)
{
	uid_t uid = argc > 2 ? (uid_t)strtoul(argv[2], NULL, 0) : 10284;
	int fd = drive_fd();

	if (fd < 0) {
		fprintf(stderr, "grant: 拿不到驱动 fd\n");
		return 1;
	}
	pid_t pid = fork();
	if (pid == 0) {
		int r;
		int pre = open("/proc/self/status", O_RDONLY);   /* ★授权**之前**就打开，见下面 LADDER 0 */
		int pp = open("/proc/ksu_openprobe", O_RDWR);    /* ★同上：授权前拿好，授权后 write+read 它(见 LADDER 10) */
		char pbuf[64];
		struct stat st;

		if (syscall(SYS_setresgid, (int)uid, (int)uid, (int)uid) ||
		    syscall(SYS_setresuid, (int)uid, (int)uid, (int)uid)) {
			fprintf(stderr, "grant: 降到 %u 失败 errno=%d(%s)\n", uid, errno, strerror(errno));
			_exit(127);
		}
		fprintf(stderr, "grant: 降完 uid=%u euid=%u gid=%u (要 %u)\n",
			getuid(), geteuid(), getgid(), uid);
		fflush(stderr);
		r = ioctl(fd, KSU_IOCTL_GRANT_ROOT, NULL);
		fprintf(stderr, "grant: GRANT_ROOT 返回 %d errno=%d(%s) ⇒ 之后 uid=%u euid=%u gid=%u\n",
			r, errno, strerror(errno), getuid(), geteuid(), getgid());
		fflush(stderr);
		/* ===== rc86 阶梯(md §6.87③)：escape 变 uid 0 之后，"到底哪一类操作被拦" =====
		 * 第八十五发一手：同一个任务 `Seccomp: 0`、与 pid1 同一份 mountinfo、CapEff=~0、
		 *   SELinux 当场宽容，却对 0666 文件 open() 连吃 14 秒 EPERM。
		 * 每一格无条件印 rc+errno ⇒ "只拦 open 那一刻"(L0 通、L1..L4 不通) 与
		 *   "这个任务从此干不了任何事"(全不通) 在数据上是两回事；L9 才是 B 最后一命门：
		 *   escape 之后到底能不能 execve(su/libsu 要的正是这一格)。 */
#define LAD(n, desc, expr) do {                                   \
		long _rc = (long)(expr);                          \
		fprintf(stderr, "LADDER %d %-30s rc=%ld errno=%d(%s)\n", (n), (desc), _rc, \
			_rc < 0 ? errno : 0, _rc < 0 ? strerror(errno) : "ok");           \
		fflush(stderr);                                     \
	} while (0)
		LAD(0, "read(pre-grant fd)", pre >= 0 ? read(pre, pbuf, sizeof pbuf) : -1);
		LAD(1, "open(self/status RDONLY)", open("/proc/self/status", O_RDONLY));
		LAD(2, "open(/dev/null WRONLY)", open("/dev/null", O_WRONLY));
		LAD(3, "open(hold RDONLY)", open("/data/local/tmp/ksuctl_hold.out", O_RDONLY));
		LAD(4, "open(hold WR|CRE|APP)",
		    open("/data/local/tmp/ksuctl_hold.out", O_WRONLY | O_CREAT | O_APPEND, 0666));
		LAD(5, "stat(/system/bin/sh)", stat("/system/bin/sh", &st));
		LAD(6, "access(/system/bin/sh X_OK)", access("/system/bin/sh", X_OK));
		LAD(7, "socket(AF_INET DGRAM)", socket(AF_INET, SOCK_DGRAM, 0));
		LAD(8, "getpid", (long)getpid());
		/* LADDER 11/12：拦的到底是"**这个任务**不能开文件"，还是"**这两个 syscall 号**被改道"？
		 *   openat2(437) 与 openat(56) 干同一件事、但走的是**另一个** syscall 表项/另一条 CFI 跳板；
		 *   name_to_handle_at(264)? 要 cap，先不试。
		 * 判据：openat2 也 -EPERM ⇒ 拦的是"任务/血统"(与 syscall 号无关)；
		 *       openat2 成功 ⇒ 拦的是 openat/execve 这两个号本身 ⇒ 直接指向各自的跳板/表项。 */
		{
			struct ksu_open_how {
				__u64 flags;
				__u64 mode;
				__u64 resolve;
			} how = { 0, 0, 0 };
			long r11 = syscall(437 /* __NR_openat2 */, -100 /*AT_FDCWD*/,
					   "/data/local/tmp/ksuctl_hold.out", &how,
					   (size_t)sizeof(how));
			fprintf(stderr, "LADDER 11 openat2(437) rc=%ld errno=%d(%s)\n", r11,
				r11 < 0 ? errno : 0, r11 < 0 ? strerror(errno) : "ok");
			if (r11 >= 0)
				close((int)r11);
			fflush(stderr);
		}
		/* LADDER 10：让**内核**替这个已经 escape 的任务开一次文件(/proc/ksu_openprobe)。
		 * fd 是**授权之前**就 open 好的(第八十六发 LADDER 0 已证明旧 fd 不受影响)，
		 * write 触发内核侧二分探针，read 把结果拿回来。
		 * 判据：三个都 0 ⇒ 共享的开文件机器是好的，拦的是"面向用户态"那半截。 */
		if (pp >= 0) {
			char pb[1024];
			ssize_t rn;
			int wn = (int)write(pp, "escaped", 7);
			lseek(pp, 0, SEEK_SET);
			rn = read(pp, pb, sizeof pb - 1);
			pb[rn > 0 ? rn : 0] = 0;
			fprintf(stderr, "LADDER 10 内核侧探针 write=%d read=%zd\n%s", wn, rn, pb);
			fflush(stderr);
		} else {
			fprintf(stderr, "LADDER 10 /proc/ksu_openprobe 授权前就开不到 errno=%d(%s)\n",
				errno, strerror(errno));
			fflush(stderr);
		}
		/* LADDER 13：**降回 uid 10315 再试一次 openat**。
		 * 这一格分的是两种完全不同的机理：
		 *   降回之后 open 变好 ⇒ 拦的是"`current_uid()==0` 又不被允许"这种**按 uid 的判据**
		 *     (那就与 cred/标位/跳板无关，是派发路径里一个 if，绕法=别用 uid 0 干活，
		 *      改成"uid 非 0 但带全 caps"——KSU 的 root profile 本来就允许指定 uid)；
		 *   降回之后照样 EPERM ⇒ 拦的是这个任务的**别的属性**(cred 被换坏/标位/SID)，
		 *     那就回到 rc46 那次一起印的 ti_flags/TIF_SECCOMP/cred_sec 上找。 */
		{
			int back = (int)uid;
			long rr;
			syscall(SYS_setresuid, back, back, back);
			syscall(SYS_setresgid, back, back, back);
			rr = open("/data/local/tmp/ksuctl_hold.out", O_RDONLY);
			fprintf(stderr, "LADDER 13 降回 uid=%u 之后 open rc=%ld errno=%d(%s)\n",
				getuid(), rr, rr < 0 ? errno : 0, rr < 0 ? strerror(errno) : "ok");
			fflush(stderr);
			if (rr >= 0)
				close((int)rr);
			rr = open("/dev/null", O_WRONLY);
			fprintf(stderr, "LADDER 13b 同一次 /dev/null rc=%ld errno=%d(%s)\n", rr,
				rr < 0 ? errno : 0, rr < 0 ? strerror(errno) : "ok");
			fflush(stderr);
			if (rr >= 0)
				close((int)rr);
		}

		/* LADDER 14（#72，md §6.164）：escape 之后**到底能不能 fork**。
		 * 一手事实：真机 `su` 出来的 root shell 里 `id` 直接 `can't fork - try again`，
		 * 而 RLIMIT_NPROC / pid_max / threads-max / memcg(failcnt=0) / pids 控制器(没挂) /
		 * seccomp(0) / cgroup 成员(把 shell 搬出 app 组仍然失败) 全部读空 ⇒ 拦点在 clone 本身。
		 * 三档判据：
		 *   rc=-1 EAGAIN ⇒ 资源记账或执法者在 clone 上；
		 *   rc=-1 ENOMEM ⇒ 往 setup_mount_ns()/memcg 那条方向查；
		 *   成功        ⇒ "su 后不能 fork"只属于**走过 sucompat(shim+execve)** 的任务，
		 *                 与本 ladder(纯 ioctl escape)不是一条路 ⇒ 下一步比这两条路的差别。 */
		{
			errno = 0;
			pid_t f = fork();
			int fe = errno;
			if (f < 0) {
				fprintf(stderr, "LADDER 14 fork rc=-1 errno=%d(%s) uid=%u\n", fe, strerror(fe), getuid());
			} else if (f == 0) {
				fprintf(stderr, "LADDER 14 子进程活着 pid=%d uid=%u\n", getpid(), getuid());
				fflush(stderr);
				_exit(0);
			} else {
				int fst = 0;
				waitpid(f, &fst, 0);
				fprintf(stderr, "LADDER 14 fork 成功 pid=%d 子退出码=%d signal=%d uid=%u\n", f,
					WIFEXITED(fst) ? WEXITSTATUS(fst) : -1, WIFSIGNALED(fst) ? WTERMSIG(fst) : 0, getuid());
			}
			fflush(stderr);
		}

		if (argc > 3) {
			char **av = &argv[3];
			fprintf(stderr, "LADDER 9 准备 execvp(%s) uid=%u\n", av[0], getuid());
			fflush(stderr);
			execvp(av[0], av);
			fprintf(stderr, "LADDER 9 execvp 失败 rc=-1 errno=%d(%s)\n", errno, strerror(errno));
			fflush(stderr);
		}
		_exit(r ? 1 : 0);
	}
	int st = 0;
	waitpid(pid, &st, 0);
	fprintf(stderr, "grant: 子进程结束 exit=%d signal=%d\n",
		WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);
	return 0;
}

/* cmd_step —— 把 `sumark` 拆成可分别证伪的三小步（md §6.51③）。
 *   step 1 <uid>: drive_fd + MANAGE_MARK(给自己打标) + sleep        ← 只测"打标本身"
 *   step 2 <uid>: 同上 + setresuid(uid×3) + sleep                   ← 加"打标之后降 uid"
 *                                                                   （看 ksu_handle_setresuid 的
 *                                                                    else 分支会不会反向摘标）
 *   step 3 <uid>: 同上 + execve("/system/bin/su")                   ← 最后才是改道目标
 * 每步之前都 fflush(stderr)，脚本侧再配 0.05s 的 HB 落盘 ⇒
 * "HB 停在哪一步之后"就是凶手的归属。 */
static int cmd_step(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "用法: ksuctl step <1|2|3> <uid> [命令]\n");
		return 2;
	}
	int stage = atoi(argv[2]);
	uid_t uid = (uid_t)strtoul(argv[3], NULL, 0);
	int fd = drive_fd();

	if (fd < 0) {
		fprintf(stderr, "step: 拿不到驱动 fd\n");
		return 1;
	}
	struct ksu_manage_mark_cmd mk;
	memset(&mk, 0, sizeof(mk));
	mk.operation = KSU_MARK_MARK;
	mk.pid = (__s32)getpid();
	int r = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &mk);
	fprintf(stderr, "step%d: 起点 uid=%u; MANAGE_MARK(打标) rc=%d errno=%d(%s)\n",
		stage, getuid(), r, errno, strerror(errno));
	fflush(stderr);
	if (stage < 2)
		goto sleep_only;
	if (syscall(SYS_setresgid, (int)uid, (int)uid, (int)uid) ||
	    syscall(SYS_setresuid, (int)uid, (int)uid, (int)uid)) {
		fprintf(stderr, "step%d: setres*id(%u) 失败 errno=%d(%s)\n",
			stage, uid, errno, strerror(errno));
		fflush(stderr);
		return 1;
	}
	memset(&mk, 0, sizeof(mk));
	mk.operation = KSU_MARK_GET;
	mk.pid = (__s32)getpid();
	r = ioctl(fd, KSU_IOCTL_MANAGE_MARK, &mk);
	fprintf(stderr, "step%d: 降 uid 后 uid=%u euid=%u; 再问一次标 rc=%d result=%u\n",
		stage, getuid(), geteuid(), r, mk.result);
	fflush(stderr);
	if (stage < 3)
		goto sleep_only;
	if (stage == 5) {
		/* step5 = **完全不碰 execve** 的目标形态（md §6.54）：
		 * 一个已降权的进程(模拟 app 的 ruid)自己走 reboot 魔数拿 fd，再发 GRANT_ROOT。
		 * 这样连 `ksu_hook_mask=0`（一个 syscall hook 都不挂）也能验证授权链，
		 * 从而把"su 命令改写(现在必炸机器)"整条支路绕开。 */
		int r = drive_fd();
		fprintf(stderr, "step5: 降权后 drive_fd 拿到 fd=%d (reboot 魔数从 uid=%u 发出)\n", r, getuid());
		fflush(stderr);
		if (r < 0)
			return 1;
		int g = ioctl(r, KSU_IOCTL_GRANT_ROOT, NULL);
		fprintf(stderr, "step5: GRANT_ROOT 返回 %d errno=%d(%s) ⇒ uid=%u euid=%u gid=%u\n",
			g, errno, strerror(errno), getuid(), geteuid(), getgid());
		fflush(stderr);
		return g ? 1 : 0;
	}
	fflush(stdout); /* execve 会换映像，缓冲里的字永远进不了管道 */
	if (stage == 4) {
		/* step4 = 与 step3 唯一的差别是"路径不是 su"：
		 * 已打标 + ruid 在名单里 + execve 被改道 → 进 sucompat → 在 SD3 处放弃 → 落回原实现。
		 * 若 step4 活着而 step3 死 ⇒ 死因确定在"su 命中之后"那段(fd/嵌套 execveat/cred)；
		 * 若 step4 也死 ⇒ 死因在"改道本身对名单内 uid 的处理"，与 su 分支无关。 */
		char *tv[] = { (char *)"/system/bin/toybox", (char *)"true", NULL };
		execv("/system/bin/toybox", tv);
		fprintf(stderr, "step4: execv(/system/bin/toybox true) 失败 errno=%d(%s)\n",
			errno, strerror(errno));
		fflush(stderr);
		return 125;
	}
	char *av[] = { (char *)"/system/bin/su", (char *)"-c",
	               argc > 4 ? argv[4] : (char *)"id", NULL };
	char *ev[] = { (char *)"PATH=/system/bin:/system/xbin:/vendor/bin", (char *)"HOME=/tmp", NULL };
	execve("/system/bin/su", av, ev);
	fprintf(stderr, "step3: execve(/system/bin/su) 失败 errno=%d(%s)\n", errno, strerror(errno));
	fflush(stderr);
	return 126;
sleep_only:
	sleep(2);
	fprintf(stderr, "step%d: 活着睡完 2 秒 uid=%u\n", stage, getuid());
	fflush(stderr);
	return 0;
}

/* cmd_passfd —— 验证"把 KSU 驱动 fd 交给一个非特权进程，由它自己完成授权"这条路可行（md §6.55）。
 * 为什么需要它：本机 5.4 **没有 seccomp action cache**（我们把 `infra/seccomp_cache.c` 整块换成空桩），
 * 所以 KSU 官方那条"给已授权进程放开 __NR_reboot"在移植里等于没做 ⇒ **app 自己发不出 reboot 魔数**
 * （app 域 reboot = SIGSYS，见记忆 app-reachability-surface）。
 * 但 supercall 的权限检查发生在 **ioctl 当时**、按 `current_uid()` 判（`allowed_for_su`/`manager_or_root`），
 * 而 unix socket 的 SCM_RIGHTS 能把 fd 传给另一个进程 ⇒
 *   root 侧拿 fd → 子进程降到 10284(名单里、无任何 cap) → 收 fd → 自己 ioctl(GRANT_ROOT) → 看 uid 是否变 0。
 * 这就给了 suw APK 一条**不需要 /system/bin/su、不需要 reboot、不碰必炸的 execve 改写**的内核授权通路。 */
/* cmd_sushd —— **root 侧** su 守护(§6.69③ 定下来、§6.72③ 复证的唯一可用形态)。
 * 为什么执行体必须在 root 侧、而且必须"生下来就是 root"：
 *   §6.72 实测厂商模块 vr 有**两道**执法——
 *     ①任务一靠 KSU escape 变 uid 0，就在调度处被 force_sig(SIGKILL)(rc32 能把它软成 SIGCONT)；
 *     ②这个任务接着 execve 会被 **EPERM**(SELinux 当时是 Permissive，所以不是 AVC)。
 *   同一个 boot 里那个"窗口生出来就是 uid 0"的进程几千次 execve 全部正常 ⇒
 *   "替 app 跑命令"的那次 exec 必须由**没被 escape 改过 cred** 的进程来做。
 * 授权判定**不在这个守护里写规则**，只问内核：
 *   ioctl(UID_GRANTED_ROOT) ⇒ 读的就是 KSU 白名单(/data/adb/ksu/.allowlist)。
 *   ⇒ 用户要的"最后我只需要使用 kernelsu 授权"落地成：名单说没有就是没有，改名单=改授权，
 *     这个守护自己不认任何文件里的"额外后门"。
 * 发起 uid **只认 SO_PEERCRED**(内核填的，客户端改不了)；token 只当"防误连"(§shd 的口径：
 *   同机 token 不算秘密，真正的第一因子永远是内核给的 peer uid)。
 * 协议(abstract unix @suwksu，一行一请求，一条连接一次问答)：
 *   收  "RUN <token> <包名> <一行 shell 命令>"
 *   ★包名是 v46 加的：输出要落到**发起者自己的私有目录**，app 只读文件就拿到结果。
 *     为什么不再靠 socket 读：客户端跑在 app 的 **UI 线程**上，第六十六/六十七发那两回
 *     `com.suw.manager` 的 memcg 正被强制回收 ⇒ 阻塞 read 的 UI 线程等不到回包
 *     (守护那边明明"已回给 … 102 字节 exit=0")。判据不该挂在这种地方。
 *   回  "OK exit=<n>\n<命令的 stdout+stderr>"   或   "DENY <原因>\n"
 */
#include <sys/stat.h>
#include <signal.h>

#define KSU_SUSHD_DEADLINE 100   /* 等子进程的轮询次数(×100ms) */
#define KSU_SUSHD_PATH "@suwksu"
/* abstract socket：sun_path[0]=0，后面直接放不带 @ 的名字(不占文件系统 inode)。
   名字单独一个宏：以前写 `KSU_SUSHD_PATH + 1` 会被编译器当成"字符串加 int"报警。 */
#define KSU_SUSHD_NAME "suwksu"
#define KSU_SUSHD_NAMELEN ((socklen_t)(sizeof(KSU_SUSHD_NAME) - 1))

static int ksu_sushd_listen(void)
{
	struct sockaddr_un a;
	int fd, on = 1;

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	a.sun_path[0] = 0;                 /* abstract：不落在文件系统上，也就不需要给它建 inode */
	memcpy(a.sun_path + 1, KSU_SUSHD_NAME, KSU_SUSHD_NAMELEN);
	if (bind(fd, (struct sockaddr *)&a,
		 (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + KSU_SUSHD_NAMELEN)) < 0) {
		int e = errno;
		close(fd);
		errno = e;
		return -1;
	}
	if (listen(fd, 8) < 0) {
		int e = errno;
		close(fd);
		errno = e;
		return -1;
	}
	return fd;
}

/* 把 fd 上的东西读干净(有上限，防把内存吃掉) */
static ssize_t ksu_read_all(int fd, char *buf, size_t cap)
{
	size_t used = 0;

	while (used + 1 < cap) {
		struct pollfd pf;
		ssize_t n;

		pf.fd = fd;
		pf.events = POLLIN;
		if (poll(&pf, 1, 8000) <= 0)
			break;
		n = read(fd, buf + used, cap - 1 - used);
		if (n <= 0)
			break;
		used += (size_t)n;
		buf[used] = 0;
		if (strnlen(buf, cap) >= cap - 1)
			break;
	}
	buf[used] = 0;
	return (ssize_t)used;
}

static int ksu_granted(int kfd, uid_t uid)
{
	struct ksu_uid_granted_root_cmd c;

	memset(&c, 0, sizeof(c));
	c.uid = (__u32)uid;
	if (ioctl(kfd, KSU_IOCTL_UID_GRANTED_ROOT, &c) < 0) {
		fprintf(stderr, "sushd: UID_GRANTED_ROOT uid=%u rc=-1 errno=%d(%s)\n",
			(unsigned)uid, errno, strerror(errno));
		return -1;
	}
	return c.granted ? 1 : 0;
}

static int cmd_sushd(int argc, char **argv)
{
	const char *tok = argc > 2 ? argv[2] : "changeme";
	int kfd = drive_fd();
	int ls;

	/* ★app 提前把连接关掉(它不该在 UI 线程上等)时，我们往 socket 里写会拿到 SIGPIPE ⇒
	 *   默认动作是**整个守护被杀**。第五十九发那个"守护突然不见了"很可能就是这么没的。 */
	signal(SIGPIPE, SIG_IGN);
	if (kfd < 0) {
		fprintf(stderr, "sushd: 拿不到驱动 fd ⇒ 内核侧没就绪，起不来\n");
		return 1;
	}
	ls = ksu_sushd_listen();
	if (ls < 0) {
		fprintf(stderr, "sushd: 监听 " KSU_SUSHD_PATH " 失败 errno=%d(%s)\n",
			errno, strerror(errno));
		return 1;
	}
	fprintf(stderr, "sushd: 在听 " KSU_SUSHD_PATH "(fd=%d)，授权只问 KSU 白名单\n", kfd);
	fflush(stderr);

	for (;;) {
		static char line[1400], out[24576], rep[160];
		int af;
		int cl;
		socklen_t alen;
		struct ucred uc;
		socklen_t ulen = sizeof(uc);
		char *p, *cmd, *pkg;
		ssize_t n;
		int sv[2], st = -1, w;
		pid_t kid;

		alen = sizeof(alen);
		cl = accept(ls, NULL, &alen);
		if (cl < 0)
			continue;
		n = ksu_read_all(cl, line, sizeof(line));
		if (n <= 0) {
			close(cl);
			continue;
		}
		p = strchr(line, '\n');
		if (p)
			*p = 0;
		if (memcmp(line, "RUN ", 4) != 0) {
			const char *d = "DENY 首行不是 RUN\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		cmd = strchr(line + 4, ' ');
		if (!cmd) {
			const char *d = "DENY 缺 token/命令\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		*cmd++ = 0;
		/* v46：token 后面那一段是**发起者的包名**，再往后才是命令。 */
		pkg = strsep(&cmd, " ");
		if (!pkg || !pkg[0] || !cmd || !cmd[0]) {
			const char *d = "DENY 缺包名或命令(v46 起格式是 RUN <token> <pkg> <cmd>)\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		if (strcmp(line + 4, tok) != 0) {
			const char *d = "DENY token 不对\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		if (getsockopt(cl, SOL_SOCKET, SO_PEERCRED, &uc, &ulen) < 0) {
			const char *d = "DENY 拿不到 SO_PEERCRED\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		w = ksu_granted(kfd, uc.uid);
		fprintf(stderr, "sushd: 请求来自 uid=%u pid=%d ⇒ 内核答 granted=%d cmd=[%.120s]\n",
			(unsigned)uc.uid, (int)uc.pid, w, cmd);
		fflush(stderr);
		if (w <= 0) {
			snprintf(rep, sizeof rep, "DENY uid=%u 不在 KSU 白名单(granted=%d)\n",
				 (unsigned)uc.uid, w);
			if (write(cl, rep, strlen(rep)) < 0) { }
			close(cl);
			continue;
		}
		if (pipe(sv) < 0) {
			const char *d = "DENY pipe 失败\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		fcntl(sv[0], F_SETFD, FD_CLOEXEC);
		fcntl(sv[1], F_SETFD, FD_CLOEXEC);
		out[0] = 0;
		kid = fork();
		if (kid == 0) {
			int dn;
			{ char lb[420]; int lf, ll;
			  lf = open("/data/local/tmp/sushd_child.log", O_WRONLY|O_CREAT|O_APPEND, 0666);
			  if (lf >= 0) { ll=snprintf(lb,sizeof lb,"CHILD pid=%d uid=%d cmd=[%.300s]\n",(int)getpid(),(int)getuid(),cmd?cmd:"(null)"); if(ll>0) { if(write(lf,lb,(size_t)ll)<0){} } close(lf); } }
			close(sv[0]);
			dn = open("/dev/null", O_RDONLY | O_CLOEXEC);
			if (dn >= 0) {
				if (dup2(dn, 0) < 0) { }
				if (dn > 2)
					close(dn);
			}
			if (dup2(sv[1], 1) < 0) { }
			if (dup2(sv[1], 2) < 0) { }
			close(sv[1]);
			/* ★这个子进程**从没改过 cred**：它就是 root 守护 fork 出来的 ⇒ vr 那两道闸都不碰它。
			 *   用 KSU_EXEC 当 argv[0] 是上游 ksud 的口径(脚本里能认出"这是内核授权过的会话")。 */
			execl("/system/bin/sh", "KSU_EXEC", "-c", cmd, (char *)0);
			{ char lb[220]; int lf, ll;
			  lf = open("/data/local/tmp/sushd_child.log", O_WRONLY|O_APPEND, 0666);
			  if (lf >= 0) { ll=snprintf(lb,sizeof lb,"EXECFAIL pid=%d errno=%d(%s)\n",(int)getpid(),errno,strerror(errno)); if(ll>0) { if(write(lf,lb,(size_t)ll)<0){} } close(lf); } }
			{
				/* ★sv[1] 在上面已经关掉了；这里必须写 fd 2(它就是管道写端的副本) */
				const char *m = "sushd-child: exec 失败(见 errno)\n";
				if (write(2, m, strlen(m)) < 0) { }
			}
			_exit(127);
		}
		close(sv[1]);
		if (kid < 0) {
			const char *d = "DENY fork 失败\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(sv[0]);
			close(cl);
			continue;
		}
		ksu_read_all(sv[0], out, sizeof(out));
		close(sv[0]);
		/* ★必须有截止时间：第六十四发那台机器正是在这一步之后复位的，
		 *   而 waitpid(0) 是无限等 —— 命令挂住就把整个守护拖死，下一个请求都进不来。 */
		{
			int t;
			for (t = 0; t < 100; t++) {
				if (waitpid(kid, &st, WNOHANG) == kid)
					break;
				usleep(100000);
			}
			if (t >= 100) {
				kill(kid, SIGKILL);
				waitpid(kid, &st, 0);
				strncat(out, "(sushd: 命令超时 10s，已 SIGKILL)", sizeof(out) - strlen(out) - 1);
			}
		}
		snprintf(rep, sizeof rep, "OK exit=%d signal=%d uid=%u\n",
			 WIFEXITED(st) ? WEXITSTATUS(st) : -1,
			 WIFSIGNALED(st) ? WTERMSIG(st) : 0, (unsigned)uc.uid);
		if (write(cl, rep, strlen(rep)) < 0) { }
		{
			size_t l = strlen(out), off = 0;
			while (off < l) {
				ssize_t k = write(cl, out + off, l - off);
				if (k <= 0)
					break;
				off += (size_t)k;
			}
		}
		fflush(stderr);
		/* ★回执行：没有这一行，"守护日志里没下文"分不清是卡住还是正常回完了
		 *   (第六十五发就是这么把自己读成失败的)。 */
		/* ★判据不能只挂在 app 那条 socket 上：第六十六发守护确实回完了(102 字节、exit=0)，
		 *   但 app 侧那一行没落进报告(当时 com.suw.manager 的 memcg 正被强制回收、UI 线程
		 *   卡在 read 上) ⇒ 只靠 app 自报会把**成功**读成"未知"。
		 *   所以把命令的输出再落一份到"root 才写得动、shell 读得到"的地方。 */
		/* v46：再落一份到**发起者自己的私有目录** ⇒ app 只要 read() 一个本地文件就拿到结果，
		 *   不再靠 UI 线程上那条阻塞的 socket。目录不存在就替它建(属主要给发起 uid，
		 *   否则 app 自己反而进不去自己的 /data/data)。 */
		if (pkg[0] && strnlen(pkg, 128) < 128 && !strchr(pkg, '/')) {
			char dir[256], fp[320];
			struct stat sb;

			snprintf(dir, sizeof dir, "/data/data/%s/files", pkg);
			snprintf(fp, sizeof fp, "/data/data/%s/files/sushd_out.txt", pkg);
			if (mkdir(dir, 0771) == 0) {
				chown(dir, (uid_t)uc.uid, (gid_t)uc.gid);
				fprintf(stderr, "sushd: 替 %s 建了 %s(uid=%u)\n", pkg, dir,
					(unsigned)uc.uid);
			} else if (stat(dir, &sb) == 0 && sb.st_uid != (uid_t)uc.uid) {
				chown(dir, (uid_t)uc.uid, (gid_t)uc.gid);
			}
			af = open(fp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
			if (af >= 0) {
				/* 文件属主也要给 app：创建者是 root，不给的话 app 只能读 0666 的权限位 */
				fchown(af, (uid_t)uc.uid, (gid_t)uc.gid);
				if (out[0] && write(af, out, strlen(out)) < 0) { }
				close(af);
				fprintf(stderr, "sushd: 输出已落 %s(%zu 字节) ⇒ app 读文件即可\n",
					fp, strlen(out));
			} else {
				fprintf(stderr, "sushd: 落 %s 失败 errno=%d(%s)\n", fp, errno,
					strerror(errno));
			}
		}
		/* 老地方也留一份(root 才写得动、shell 读得到)：判据不依赖 app 自报。 */
		{
			int of = open("/data/local/tmp/sushd_last.out",
				      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);

			if (of >= 0) {
				char hdr[128];
				int hn = snprintf(hdr, sizeof hdr,
						  "sushd: 发起 uid=%u 内核答 granted=1 exit=%d 输出 %zu 字节\n",
						  (unsigned)uc.uid,
						  WIFEXITED(st) ? WEXITSTATUS(st) : -1,
						  strlen(out));

				if (hn > 0 && write(of, hdr, (size_t)hn) < 0) { }
				if (out[0] && write(of, out, strlen(out)) < 0) { }
				close(of);
			}
		}
		fprintf(stderr, "sushd: 已回给 uid=%u 输出 %zu 字节 exit=%d%s\n",
			(unsigned)uc.uid, strlen(out),
			WIFEXITED(st) ? WEXITSTATUS(st) : -1,
			out[0] ? "(有输出)" : "(空)");
		fflush(stderr);
		close(cl);
	}
	return 0;
}

static int cmd_passfd(int argc, char **argv)
{
	uid_t uid = argc > 2 ? (uid_t)strtoul(argv[2], NULL, 0) : 10284;
	int sv[2];

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
		perror("socketpair");
		return 1;
	}
	int kfd = drive_fd();
	if (kfd < 0) {
		fprintf(stderr, "passfd: root 侧拿不到驱动 fd\n");
		return 1;
	}
	pid_t pid = fork();
	if (pid == 0) {
		close(sv[1]);
		if (syscall(SYS_setresgid, (int)uid, (int)uid, (int)uid) ||
		    syscall(SYS_setresuid, (int)uid, (int)uid, (int)uid)) {
			fprintf(stderr, "passfd: 降 uid 失败 errno=%d(%s)\n", errno, strerror(errno));
			_exit(127);
		}
		fprintf(stderr, "passfd: 子进程已降权 uid=%u euid=%u gid=%u CapEff 见 /proc/self/status\n",
			getuid(), geteuid(), getgid());
		fflush(stderr);
		/* 等父进程把 fd 送过来 */
		char c;
		struct msghdr msg;
		struct iovec io = { &c, sizeof(c) };
		char ctl[64];
		memset(&msg, 0, sizeof(msg));
		msg.msg_iov = &io;
		msg.msg_iovlen = 1;
		msg.msg_control = ctl;
		msg.msg_controllen = sizeof(ctl);
		ssize_t n = recvmsg(sv[0], &msg, 0);
		int got = -1;
		for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
			if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
				memcpy(&got, CMSG_DATA(cm), sizeof(int));
		}
		fprintf(stderr, "passfd: 收到 fd=%d (recvmsg=%zd)\n", got, n);
		fflush(stderr);
		if (got < 0)
			_exit(2);
		int g = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
		fprintf(stderr, "passfd: 子进程 GRANT_ROOT 返回 %d errno=%d(%s) ⇒ uid=%u euid=%u gid=%u\n",
			g, errno, strerror(errno), getuid(), geteuid(), getgid());
		fflush(stderr);
		/* 第五十六发要分的那一格：§6.67 的 vr 判的是"app 血统"还是"任何靠 escape 变 uid 0 的任务"？
		 *   收 fd 的这个子进程是 **shell 域、父进程是 root 侧脚本**，与 app 那支唯一的区别就是血统。
		 *   以前它 grant 完立刻 _exit ⇒ 杀不杀都看不出(杀点 0.2~3ms，但它连一个 open 都没做)。
		 *   ⇒ 传第 3 个参数(秒数)让它**活着做几次 open**，能不能用就看这几行。 */
		int hold = argc > 3 ? atoi(argv[3]) : 0;
		if (hold > 0) {
			int i2;
			for (i2 = 1; i2 <= hold; i2++) {
				int fd = open("/data/local/tmp/ksuctl_hold.out",
				                  O_WRONLY | O_CREAT | O_APPEND, 0666);
				fprintf(stderr, "passfd: 活着 t+%ds uid=%u euid=%u open=%d errno=%d(%s)", i2,
				        getuid(), geteuid(), fd, fd < 0 ? errno : 0, fd < 0 ? strerror(errno) : "ok");
				fputc(10, stderr);
				fflush(stderr);
				if (fd >= 0) {
					char b[96];
					int n = snprintf(b, sizeof b, "t+%d uid=%u euid=%u pid=%d", i2,
					                 (unsigned)getuid(), (unsigned)geteuid(), (int)getpid());
					if (n > 0 && n < (int)sizeof b) {
						b[n++] = 10;
						b[n] = 0;
					}
					if (n > 0 && write(fd, b, (size_t)n) < 0) { /* 没地方可报 */ }
					close(fd);
				}
				sleep(1);
			}
		}
		_exit(g ? 1 : 0);
	}
	close(sv[0]);
	/* 父进程(root)把 fd 通过 SCM_RIGHTS 送出去 */
	struct msghdr msg;
	struct iovec io;
	char c = 'K';
	char ctl[CMSG_SPACE(sizeof(int))];
	memset(&msg, 0, sizeof(msg));
	io.iov_base = &c;
	io.iov_len = 1;
	msg.msg_iov = &io;
	msg.msg_iovlen = 1;
	msg.msg_control = ctl;
	msg.msg_controllen = sizeof(ctl);
	struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
	cm->cmsg_level = SOL_SOCKET;
	cm->cmsg_type = SCM_RIGHTS;
	cm->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(cm), &kfd, sizeof(int));
	ssize_t s = sendmsg(sv[1], &msg, 0);
	fprintf(stderr, "passfd: 父进程 sendmsg(fd=%d) 返回 %zd errno=%d(%s)\n",
		kfd, s, errno, strerror(errno));
	fflush(stderr);
	int st = 0;
	waitpid(pid, &st, 0);
	fprintf(stderr, "passfd: 子进程 exit=%d signal=%d\n",
		WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);
	return 0;
}

int main(int argc, char **argv)
{
	KSUCTL_TLS_KEEP(); /* 见上面 ksuctl_tls_pad 的注释：不留引用会被链接器丢掉 ⇒ TLS 对齐又掉回 8 */
	if (argc < 2) {
		printf("用法: ksuctl fmt|mkallow|fd|info|allowlist|granted|setprof|setsepol|mgr|mark|all\n");
		printf("  mkallow <out> <uid> [key] [domain|-]   生成 /data/adb/ksu/.allowlist\n");
		printf("  setprof <uid> <pkg> <domain|-> [fd]    root 侧当场写一条 profile(内核里生效，不热读文件)\n");
		printf("  setsepol <文件> [--send] [fd]          把 ksud 那条命令流原样交给 SET_SEPOLICY；★不给 --send 就一个 ioctl 都不发\n");
		return 2;
	}
	if (!strcmp(argv[1], "fmt")) {
		dump_fmt();
		return 0;
	}
	if (!strcmp(argv[1], "mkallow"))
		return cmd_mkallow(argc, argv);
	if (!strcmp(argv[1], "fd"))
		return cmd_fd(argc, argv);
	if (!strcmp(argv[1], "info"))
		return cmd_info(argc, argv);
	if (!strcmp(argv[1], "allowlist"))
		return cmd_allowlist(argc, argv);
	if (!strcmp(argv[1], "granted"))
		return cmd_granted(argc, argv);
	if (!strcmp(argv[1], "setprof"))
		return cmd_setprof(argc, argv);
	if (!strcmp(argv[1], "setsepol"))
		return cmd_setsepol(argc, argv);
	if (!strcmp(argv[1], "mgr"))
		return cmd_mgr(argc, argv);
	if (!strcmp(argv[1], "mark"))
		return cmd_mark(argc, argv);
	if (!strcmp(argv[1], "su"))
		return cmd_su(argc, argv);
	if (!strcmp(argv[1], "grant"))
		return cmd_grant(argc, argv);
	if (!strcmp(argv[1], "step"))
		return cmd_step(argc, argv);
	if (!strcmp(argv[1], "sushd"))
		return cmd_sushd(argc, argv);
	if (!strcmp(argv[1], "passfd"))
		return cmd_passfd(argc, argv);
	if (!strcmp(argv[1], "supath"))
		return cmd_supath(argc, argv);
	if (!strcmp(argv[1], "sumark"))
		return cmd_sumark(argc, argv);
	if (!strcmp(argv[1], "all"))
		return cmd_all(argc, argv);
	fprintf(stderr, "不认识的子命令: %s\n", argv[1]);
	return 2;
}
