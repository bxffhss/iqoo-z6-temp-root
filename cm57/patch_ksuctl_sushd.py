import io
import sys

P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()

if "cmd_sushd" in s:
    print("已经有 sushd ⇒ 跳过")
    raise SystemExit(0)

NL = chr(10)

# 1) 需要的头
old_inc = "#include <sys/socket.h>" + NL
assert s.count(old_inc) >= 1
s = s.replace(
    old_inc,
    old_inc + "#include <sys/un.h>" + NL + "#include <linux/un.h>" + NL + "#include <poll.h>" + NL,
    1,
)

# 2) 守护本体：插在 cmd_passfd 之前(它紧跟 drive_fd 那批 helper 之后)
anchor = "static int cmd_passfd(int argc, char **argv)"
assert s.count(anchor) == 1, "anchor"

BODY = r'''/* cmd_sushd —— **root 侧** su 守护(§6.69③ 定下来、§6.72③ 复证的唯一可用形态)。
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
 *   收  "RUN <token> <一行 shell 命令>"
 *   回  "OK exit=<n>\n<命令的 stdout+stderr>"   或   "DENY <原因>\n"
 */
#define KSU_SUSHD_PATH "@suwksu"

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
	memcpy(a.sun_path + 1, KSU_SUSHD_PATH + 1, strlen(KSU_SUSHD_PATH) - 1);
	if (bind(fd, (struct sockaddr *)&a,
		 (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(KSU_SUSHD_PATH) - 1)) < 0) {
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
		int cl;
		socklen_t alen;
		struct ucred uc;
		socklen_t ulen = sizeof(uc);
		char *p, *cmd;
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
		if (pipe2(sv, O_CLOEXEC) < 0) {
			const char *d = "DENY pipe2 失败\n";
			if (write(cl, d, strlen(d)) < 0) { }
			close(cl);
			continue;
		}
		out[0] = 0;
		kid = fork();
		if (kid == 0) {
			int dn;
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
			{
				/* ★sv[1] 在上面已经关掉了；这里必须写 fd 2(它就是管道写端的副本) */
				const char *m = "sushd-child: exec 失败(见 errno)
";
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
		waitpid(kid, &st, 0);
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
		close(cl);
	}
	return 0;
}

'''
s = s.replace(anchor, BODY + anchor)

# 3) 分发
old_disp = '\tif (!strcmp(argv[1], "passfd"))'
assert s.count(old_disp) == 1, "dispatch"
s = s.replace(old_disp, '\tif (!strcmp(argv[1], "sushd"))\n\t\treturn cmd_sushd(argc, argv);\n' + old_disp)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("cmd_sushd 已加进 ksuctl.c")
