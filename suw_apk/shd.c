/* shd.c — shell 侧代理 v2(路线乙): 窄接口 + 空闲自杀 + 双通道鉴权。
 *
 * 为什么不是"任意 shell": 装到机器上的 APK 是 world-readable(base.apk 0644), 所以埋在 APK 里的
 * token 对同机任何 app 都不算秘密; 而 loopback 端口是可被扫到的。既然"保密"靠不住, 就把
 * **能做的事**收窄: 本 agent 只认固定动词, 命令由 agent 内部拼, 绝不 exec 客户端给的字符串。
 * ⇒ 最坏情况(别人连上并猜出协议)只是"能触发一次采样/重打", 不是"拿到 uid2000 的 shell"。
 *
 * 两条通道, 两种鉴权:
 *   TCP  127.0.0.1:31339        首行 `AUTH <token>`(第二道, 防误连/防顺手试)
 *   UNIX abstract @suwshd       按 **对端 uid 白名单**(SO_PEERCRED 在 AF_UNIX 上是真身份;
 *                               TCP 上实测拿不到: getsockopt 返回 0 但 uid 是 invalid)
 *   ⇒ 只要 SELinux 允许 app connectto shell 建的 unix socket, 就走 UNIX 通道拿真身份。
 *
 * 生命周期: 空闲 IDLE 秒(默认 120)自动退出 ⇒ 暴露窗口从"整个 boot"缩到"你点重打的那几十秒"。
 *
 * v3 新增(路线 B 收口): `KSUFD` —— 由本 agent(shell 域)拿 KernelSU 驱动 fd, 用 SCM_RIGHTS
 *   交给 unix 对端(白名单里的 app uid)。app 域发不出 `reboot`(§6.20 实测 SIGSYS), 而 KSU 的
 *   权限判定发生在 **ioctl 当时**、按 current_uid 判 ⇒ fd 谁拿的不重要, 谁能授权看收方 uid。
 *   详见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.59。
 *
 * 用法: shd [tcp_port] [idle_sec] [allow_uid ...]
 *   setsid nohup /data/local/tmp/shd 31339 120 10284 </dev/null >>/data/local/tmp/shd.log 2>&1 &
 * 自检: shd --probe        以客户端身份连自己的 unix 通道, 看 uid 白名单有没有生效
 *       shd --ksufd        走一遍 KSUFD: 收 fd → 在**本进程**(不是造 fd 的那个)上做 GET_INFO
 *                          GET_INFO=always_allow 是正对照; GRANT_ROOT 对 uid2000 应当被拒(负对照)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <sys/syscall.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/sockios.h>          /* SO_PEERCRED */

#include <stdbool.h>                    /* supercall.h 里的 uapi 结构用 bool, 得先带进来 */
#include "../kmod/uapi/supercall.h"  /* KSU_INSTALL_MAGIC* / KSU_IOCTL_* / struct ksu_get_info_cmd */

#ifndef SUW_TOKEN
#define SUW_TOKEN "changeme"
#endif
#define DEF_PORT 31339
#define DEF_IDLE 120
#define UNIXNAME "suwshd"
#define LOGF  "/data/local/tmp/shd.log"

static int IDLE = DEF_IDLE;
static time_t last_act = 0;
static unsigned ALLOW[8];
static int NALLOW = 0;

static void logf(const char *fmt, ...) {
  char line[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  int fd = open(LOGF, O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd >= 0) {
    char out[600];
    int n = snprintf(out, sizeof out, "%s\n", line);
    if (write(fd, out, n) < 0) { }
    fsync(fd);
    close(fd);
  }
  fprintf(stderr, "%s\n", line);
  fflush(stderr);
}

static int write_all(int fd, const char *p, size_t n) {
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w <= 0) return -1;
    p += w; n -= (size_t)w;
  }
  return 0;
}
static void say(int c, const char *s) { write_all(c, s, strlen(s)); }

/* 跑一条**由 agent 自己拼出来的**命令 */
static void run_fixed(int c, const char *cmd) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) return;
  pid_t p = fork();
  if (p == 0) {
    close(sv[0]);
    setsid();
    dup2(sv[1], 1); dup2(sv[1], 2);
    { int z = open("/dev/null", O_RDONLY); dup2(z, 0); if (z > 2) close(z); }
    close(sv[1]);
    setenv("PATH", "/system/bin:/system/xbin:/product/bin:/vendor/bin", 1);
    execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
    _exit(127);
  }
  close(sv[1]);
  if (p < 0) { close(sv[0]); return; }
  char buf[4096];
  ssize_t r;
  while ((r = read(sv[0], buf, sizeof buf)) > 0)
    if (write_all(c, buf, (size_t)r) != 0) break;
  int st = 0;
  waitpid(p, &st, 0);
  int rc = WIFEXITED(st) ? WEXITSTATUS(st) : 200 + WTERMSIG(st);
  char end[32];
  int n = snprintf(end, sizeof end, "RC=%d\n", rc);
  if (write_all(c, end, (size_t)n) != 0) { }
  close(sv[0]);
  time(&last_act);
  logf("EXEC rc=%d cmd=[%.200s]", rc, cmd);
}

static int hex_only(const char *s) {
  int n = 0;
  for (; *s; s++) {
    if (!isxdigit((unsigned char)*s)) return 0;
    n++;
  }
  return n > 0 && n <= 16;
}
static int dec_only(const char *s) {
  int n = 0;
  for (; *s; s++) { if (!isdigit((unsigned char)*s)) return 0; n++; }
  return n > 0 && n <= 3;
}

/* 唯一的"命令表": 动词 -> 固定命令行。加能力必须改这里(便于 review)。 */
static const char *one_line(const char *s) {   /* 把外部输出压成一行, 免得污染协议 */
  static char b[96];
  int i, j = 0;
  for (i = 0; s[i] && j < (int)sizeof b - 1; i++) {
    char ch = (s[i] == '\n' || s[i] == '\r') ? ' ' : s[i];
    if (ch == ' ' && j > 0 && b[j - 1] == ' ') continue;
    b[j++] = ch;
  }
  while (j > 0 && b[j - 1] == ' ') j--;
  b[j] = 0;
  return b;
}

/* ================= KSU 驱动 fd 代理(v3) =================
 * 拿 fd 的口径与 cm57/ksuctl.c: drive_fd() 一致(先按回传出参, 再扫 /proc/self/fd 兜底)。
 * ★fd 只在本进程有效, 但 SCM_RIGHTS 能把它交给别的进程; KSU 的授权判定发生在 **ioctl 当时**、
 *   按收方 current_uid 判(dispatch.c 里 GRANT_ROOT 的 perm_check = allowed_for_su)
 *   ⇒ "由 shell 域拿 fd"完全不影响"谁能被授权", 这正是绕开 app 域 reboot=SIGSYS 的那一步。 */
static int g_ksu_fd = -1;

static int ksu_fd_scan(void) {
  DIR *d = opendir("/proc/self/fd");
  char link[64], buf[128];
  int found = -1;
  struct dirent *e;
  if (!d) return -1;
  while ((e = readdir(d)) != NULL) {
    int fdno;
    ssize_t n;
    if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
    fdno = atoi(e->d_name);
    if (fdno <= 2) continue;
    snprintf(link, sizeof link, "/proc/self/fd/%d", fdno);
    n = readlink(link, buf, sizeof buf - 1);
    if (n <= 0) continue;
    buf[n] = 0;
    if (strstr(buf, "ksu_driver")) { found = fdno; break; }
  }
  closedir(d);
  return found;
}

static int ksu_fd_get(void) {
  int out = -1, r, e;
  r = (int)syscall(SYS_reboot, (int)KSU_INSTALL_MAGIC1, (int)KSU_INSTALL_MAGIC2, 0, &out);
  e = errno;
  logf("KSUFD: reboot(magic) ret=%d errno=%d(%s) 回传 fd=%d", r, e, strerror(e), out);
  if (out >= 0) return out;
  out = ksu_fd_scan();
  logf("KSUFD: /proc/self/fd 兜底扫到 fd=%d", out);
  return out;
}

static void ksu_fd_label(int fd, char *out, size_t cap) {
  char link[64];
  ssize_t n;
  out[0] = 0;
  snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
  n = readlink(link, out, cap - 1);
  if (n > 0) out[n] = 0;
}

/* 状态行 = sendmsg 的 payload ⇒ 行与 fd 是**同一条消息**。
 * 若先发文字、再单独 sendmsg 一个字节, 客户端用 read() 吃掉那个字节时 cmsg 无处安放
 * (会被塞进错误队列) ⇒ 之后 recvmsg 拿不到 fd ⇒ 假阴性。
 * ★★第三十六发的教训：`CMSG_FIRSTHDR(&msg)` 在 `msg.msg_control/msg_controllen` 赋值**之前**调用
 *   会返回 **NULL**(它按 controllen 判有没有控制缓冲)，紧接着 `cm->cmsg_level = ...` 就是空指针 ⇒
 *   agent 的子进程当场 SIGSEGV ⇒ 客户端只看到 EOF("回复:" 空白)。现场是 `install ksu fd: 5/6/7/8`
 *   全成功、`KSUBEAT D reply` 全 rc=0，唯独 fd 没递出去 —— 顺序写对之前，这条链一直"看起来是内核的锅"。
 *   ⇒ 下面把顺序钉死：先 control/controllen，再取 cm，再**显式判 NULL**。 */
static int send_fd_with_line(int c, int fd, const char *kind) {
  char line[256], lab[96], ctl[CMSG_SPACE(sizeof(int))];
  struct msghdr msg;
  struct iovec io;
  struct cmsghdr *cm;
  ssize_t s;
  int n;

  if (fd < 0) {
    n = snprintf(line, sizeof line, "%s ERR no-fd (%s 没装载?)\n", kind, kind);
    if (n > 0) write_all(c, line, (size_t)n);
    return -1;
  }
  ksu_fd_label(fd, lab, sizeof lab);
  n = snprintf(line, sizeof line, "%s ok self_fd=%d label=%s agent_uid=%u agent_gid=%u\n",
               kind, fd, one_line(lab), (unsigned)getuid(), (unsigned)getgid());
  if (n <= 0) return -1;

  memset(&msg, 0, sizeof msg);
  memset(ctl, 0, sizeof ctl);
  io.iov_base = line;
  io.iov_len = (size_t)n;
  msg.msg_iov = &io;
  msg.msg_iovlen = 1;
  msg.msg_control = ctl;                    /* ← 必须在 CMSG_FIRSTHDR 之前 */
  msg.msg_controllen = CMSG_SPACE(sizeof(int));
  cm = CMSG_FIRSTHDR(&msg);
  if (!cm) {                                /* 宁可报错，也不许解引用空指针 */
    say(c, "ERR cmsghdr=NULL (CMSG_SPACE 太小?)\n");
    logf("%s: CMSG_FIRSTHDR 返回 NULL ⇒ 没发", kind);
    return -1;
  }
  cm->cmsg_level = SOL_SOCKET;
  cm->cmsg_type = SCM_RIGHTS;
  cm->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cm), &fd, sizeof(int));
  msg.msg_controllen = CMSG_SPACE(sizeof(int));
  s = sendmsg(c, &msg, 0);
  logf("%s: sendmsg(fd=%d, %d 字节状态行) 返回 %zd errno=%d(%s)",
       kind, fd, n, s, s < 0 ? errno : 0, s < 0 ? strerror(errno) : "ok");
  return s < 0 ? -1 : 0;
}

static void ksu_send_fd(int c) {
  if (g_ksu_fd < 0) g_ksu_fd = ksu_fd_get();
  send_fd_with_line(c, g_ksu_fd, "KSUFD");
}

/* TESTFD：把一个**普通文件**的 fd 递过去 —— 不需要 ko、不需要窗口。
 * 加它的原因就是上面那条 NULL-cm 事故：SCM_RIGHTS 那段代码以前从来没有在"有 fd 可发"的
 * 形态下跑过。现在拿 /data/local/tmp/shd.log 当载体，客户端能收到 fd 并能 read 出来，
 * 就证明整条 sendmsg/recvmsg/cmsg 路径是好的；窗口里唯一的变量就剩"fd 是不是驱动 fd"。 */
static void test_send_fd(int c) {
  int fd = open(LOGF, O_RDONLY | O_CLOEXEC);
  logf("TESTFD: open(%s) -> fd=%d errno=%d", LOGF, fd, fd < 0 ? errno : 0);
  send_fd_with_line(c, fd, "TESTFD");
  if (fd >= 0) close(fd);
}

static void dispatch(int c, char *verb, char *arg, int is_unix) {
  char cmd[1024];
  if (!strcmp(verb, "STATUS")) {
    run_fixed(c, "echo uid=$(id -u); echo uname=$(uname -r); echo mac=$(getenforce);"
                 "echo uptime=$(cut -d' ' -f1 /proc/uptime); echo load=$(cut -d' ' -f1 /proc/loadavg);"
                 "echo daemon=$(pidof sudbin); echo shd=$(pidof shd);"
                 "for f in pr sudbin perfips su_layer_install.sh; do echo \"have_$f=$([ -f /data/local/tmp/$f ] && echo 1 || echo 0)\"; done");
  } else if (!strcmp(verb, "SAMPLE")) {
    int s = dec_only(arg) ? atoi(arg) : 0;
    if (s < 5 || s > 60) { say(c, "ERR sample 需要 5..60 秒\n"); return; }
    snprintf(cmd, sizeof cmd,
             "rm -f /data/local/tmp/ipk.txt; /data/local/tmp/perfips %d > /data/local/tmp/ipk.txt 2>&1;"
             "echo lines=$(wc -l < /data/local/tmp/ipk.txt)", s);
    run_fixed(c, cmd);
  } else if (!strcmp(verb, "DUMP")) {
    run_fixed(c, "cat /data/local/tmp/ipk.txt");
  } else if (!strcmp(verb, "PUNCH")) {
    if (!hex_only(arg)) { say(c, "ERR slide 必须是 1..16 位十六进制\n"); return; }
    /* ★ 必须 detach, 不能把这一发挂在客户端连接上。
     * 一发要跑 1~4 分钟(实测 round9: 起链到 post 落地约 30~40s, 失败轮要几分钟)。
     * 若同步跑: 客户端超时 → 关连接 → run_fixed 的 write 失败退出读循环 →
     * 命令里 `| tail -c 6000` 的 tail 收到 EPIPE 死掉 → **pr 下一次输出吃到 SIGPIPE 也死**,
     * 于是链可能走到一半被自己掐死。所以: 输出重定向到文件, 立刻返回, 进度靠 PUNCHLOG 轮询。 */
    {
      char pb[128] = {0};
      FILE *pf = popen("pidof pr 2>/dev/null", "r");
      if (pf) { if (fgets(pb, sizeof pb, pf) == NULL) pb[0] = 0; pclose(pf); }
      if (pb[0]) {
        char e[192];
        int n = snprintf(e, sizeof e, "ERR 已经有一个 pr 在跑(PID %s) ⇒ 拒绝重复打\n", one_line(pb));
        if (n > 0) write_all(c, e, (size_t)(n > 190 ? 190 : n));
        return;
      }
    }
    snprintf(cmd, sizeof cmd,
             "cd /data/local/tmp && chmod 755 pr sudbin 2>/dev/null;"
             "rm -f punch.log;"
             "setsid nohup sh -c './pr %s hammer hijack shape2 sen victim shell ph2=0 ncopy5 "
             "shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 "
             "post=/data/local/tmp/su_layer_install.sh > /data/local/tmp/punch.log 2>&1;"
             "echo RC=$? >> /data/local/tmp/punch.log' </dev/null >/dev/null 2>&1 &"
             "echo dispatched slide=%s", arg, arg);
    run_fixed(c, cmd);
  } else if (!strcmp(verb, "PUNCHLOG")) {
    run_fixed(c, "echo \"pr=$(pidof pr 2>/dev/null)\";"
                 "echo '--- punch.log 尾部 ---';"
                 "tail -c 2600 /data/local/tmp/punch.log 2>&1");
  } else if (!strcmp(verb, "LOG")) {
    run_fixed(c, "echo '--- su.audit ---'; tail -n 40 /data/local/tmp/su.audit 2>&1;"
                 "echo '--- shd.log ---'; tail -n 20 /data/local/tmp/shd.log 2>&1");
  } else if (!strcmp(verb, "KSUFD")) {
    /* SCM_RIGHTS 只在 AF_UNIX 上有意义 ⇒ TCP 通道一律拒绝, 免得客户端以为拿到了 fd */
    if (!is_unix) { say(c, "ERR KSUFD 只在 unix 通道(abstract @suwshd)上可用\n"); return; }
    ksu_send_fd(c);
  } else if (!strcmp(verb, "TESTFD")) {
    if (!is_unix) { say(c, "ERR TESTFD 只在 unix 通道(abstract @suwshd)上可用\n"); return; }
    test_send_fd(c);
  } else if (!strcmp(verb, "KSUSTAT")) {
    char line[192];
    int n;
    if (g_ksu_fd < 0) g_ksu_fd = ksu_fd_get();
    {
      char lab[96] = "";
      if (g_ksu_fd >= 0) ksu_fd_label(g_ksu_fd, lab, sizeof lab);
      n = snprintf(line, sizeof line, "KSUSTAT fd=%d label=%s uid=%u\n",
                   g_ksu_fd, one_line(lab), (unsigned)getuid());
      if (n > 0) write_all(c, line, (size_t)n);
    }
  } else if (!strcmp(verb, "QUIT")) {
    say(c, "BYE\n");
  } else {
    say(c, "ERR 未知动词; 可用: STATUS SAMPLE <秒> DUMP PUNCH <hex> PUNCHLOG LOG KSUFD KSUSTAT QUIT\n");
  }
}

typedef struct { int fd; char buf[8192]; size_t have, got; } reader;

static int rd_line(reader *r, char *out, size_t cap) {
  for (;;) {
    char *nl = memchr(r->buf + r->got, '\n', r->have - r->got);
    if (nl) {
      size_t len = (size_t)(nl - (r->buf + r->got));
      if (len >= cap) len = cap - 1;
      memcpy(out, r->buf + r->got, len);
      out[len] = 0;
      r->got += (size_t)(nl - (r->buf + r->got)) + 1;
      return 1;
    }
    if (r->have >= sizeof r->buf) {
      if (r->got > 0 && r->got < r->have) {
        memmove(r->buf, r->buf + r->got, r->have - r->got);
        r->have -= r->got; r->got = 0;
      } else return -1;
    }
    ssize_t n = read(r->fd, r->buf + r->have, sizeof r->buf - r->have);
    if (n <= 0) return -1;
    r->have += (size_t)n;
  }
}

static int uid_allowed(unsigned u) {
  if (!NALLOW) return 1;                     /* 没给白名单 = 不启用 uid 过滤(只靠 token) */
  for (int i = 0; i < NALLOW; i++) if (ALLOW[i] == u) return 1;
  return 0;
}

/* shd v4(md §6.123)：unix 通道的第二把钥匙——**问内核**。
 *   为什么要有这条：把 `su` 交付给任意第三方 app(Termux 里手敲 su)时，"谁能提权"这件事
 *   不该由本守护的 uid 白名单说了算(那样每加一个 app 都要重启守护、且和 KSU 的名单两套账)。
 *   KSU 的判定本来就在 ioctl 当时(`allowed_for_su`)，所以这里只做一个**代理查询**：
 *   内核说这个 uid 在名单里 ⇒ 允许它连进来要驱动 fd ⇒ 它自己 ioctl(GRANT_ROOT) 时仍由内核裁决。
 *   ⇒ 安全性没有因为这个放行而变弱：拿到 fd 但不在名单里的 uid，ioctl 只会得到 -EPERM。 */
static int kernel_grants_uid(unsigned u) {
  struct ksu_uid_granted_root_cmd q;
  memset(&q, 0, sizeof q);
  q.uid = u;
  if (g_ksu_fd < 0) g_ksu_fd = ksu_fd_get();
  if (g_ksu_fd < 0) return 0;
  if (ioctl(g_ksu_fd, KSU_IOCTL_UID_GRANTED_ROOT, &q) != 0) return 0;
  return q.granted ? 1 : 0;
}

static void serve(int c, int is_unix, const char *peerlabel) {
  reader rr; memset(&rr, 0, sizeof rr); rr.fd = c;
  char line[2048];

  if (is_unix) {
    struct { unsigned pid, uid, gid; } pc;
    socklen_t l = sizeof pc;
    if (getsockopt(c, SOL_SOCKET, SO_PEERCRED, &pc, &l) != 0) {
      char m[96]; snprintf(m, sizeof m, "ERR peercred %d\n", errno); say(c, m); close(c); return;
    }
    if (!uid_allowed(pc.uid) && !kernel_grants_uid(pc.uid)) {
      logf("DENY unix peer_uid=%u pid=%u 不在白名单且内核也没给它授权", pc.uid, pc.pid);
      say(c, "ERR not-allowed\n"); close(c); return;
    }
    char m[128];
    snprintf(m, sizeof m, "OK unix uid=%u pid=%u\n", pc.uid, pc.pid);
    say(c, m);
    logf("AUTH unix ok peer_uid=%u pid=%u (%s)", pc.uid, pc.pid,
         uid_allowed(pc.uid) ? "白名单" : "内核名单");
  } else {
    char want[64];
    snprintf(want, sizeof want, "AUTH %s", SUW_TOKEN);
    if (rd_line(&rr, line, sizeof line) != 1 || strcmp(line, want) != 0) {
      logf("DENY tcp 首行鉴权失败(收到 [%.24s])", line);
      say(c, "ERR bad-auth\n"); close(c); return;
    }
    say(c, "OK tcp token-ok\n");
    logf("AUTH tcp ok (%s)", peerlabel);
  }
  time(&last_act);

  for (;;) {
    fd_set rs; FD_ZERO(&rs); FD_SET(rr.fd, &rs);
    struct timeval tv = { 30, 0 };
    int s = select(rr.fd + 1, &rs, 0, 0, &tv);
    if (s <= 0) { if (s < 0 && errno == EINTR) continue; break; }
    if (rd_line(&rr, line, sizeof line) != 1) break;
    if (!line[0]) continue;
    char *sp = strchr(line, ' ');
    char *arg = "";
    if (sp) { *sp = 0; arg = sp + 1; }
    if (!strcmp(line, "QUIT")) break;
    dispatch(c, line, arg, is_unix);
    if (!strcmp(line, "QUIT")) break;
  }
  close(c);
}

static int mk_tcp(int port) {
  struct sockaddr_in a;
  int fd = socket(AF_INET, SOCK_STREAM, 0), on = 1;
  if (fd < 0) return -1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { logf("tcp bind 失败 errno=%d", errno); close(fd); return -1; }
  listen(fd, 8);
  return fd;
}

static int mk_unix(void) {
  struct sockaddr_un u;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0), on = 1;
  if (fd < 0) return -1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
  memset(&u, 0, sizeof u);
  u.sun_family = AF_UNIX;
  u.sun_path[0] = 0;
  strncpy(u.sun_path + 1, UNIXNAME, sizeof(u.sun_path) - 2);
  if (bind(fd, (struct sockaddr *)&u, offsetof(struct sockaddr_un, sun_path) + 1 + strlen(UNIXNAME)) < 0) {
    logf("unix bind 失败 errno=%d", errno); close(fd); return -1;
  }
  listen(fd, 8);
  return fd;
}

/* 自检用: 以**客户端**身份连一次自己的 unix socket, 把服务端的应答打出来。
   (真机判"uid 白名单有没有生效"要用它 + asuid 换 uid 跑; 判 SELinux 让不让 app 连, 只能由 APK 试) */
static int probe_unix(void) {
  struct sockaddr_un u;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { printf("ERR socket %d\n", errno); return 1; }
  memset(&u, 0, sizeof u);
  u.sun_family = AF_UNIX;
  u.sun_path[0] = 0;
  strncpy(u.sun_path + 1, UNIXNAME, sizeof(u.sun_path) - 2);
  if (connect(fd, (struct sockaddr *)&u, offsetof(struct sockaddr_un, sun_path) + 1 + strlen(UNIXNAME)) < 0) {
    printf("ERR connect errno=%d(%s)\n", errno, strerror(errno));
    close(fd); return 1;
  }
  char b[512];
  ssize_t n = read(fd, b, sizeof b - 1);
  if (n > 0) { b[n] = 0; printf("greeting: %s", b); }
  if (write_all(fd, "STATUS\n", 7) == 0) {
    while ((n = read(fd, b, sizeof b - 1)) > 0) { b[n] = 0; fputs(b, stdout); }
  }
  close(fd);
  return 0;
}

/* ---- 自测客户端(shd --ksufd): 把"app 侧要做的动作"在 shell 域先跑一遍 ----
 * 收 fd 之后做两件事, 一正一负:
 *   GET_INFO   perm_check=always_allow ⇒ rc=0 就证明"换了一个进程, fd 依然活着、ioctl 打得进去"
 *              (这是 app 路径唯一真正依赖的性质; 造 fd 的进程不是用 fd 的进程)
 *   GRANT_ROOT perm_check=allowed_for_su ⇒ 对 uid 2000 **应当**被拒(system uid 一律禁,
 *              见 §6.44 的 forbid_system_uid) ⇒ 若这里竟然 rc=0 且 uid 变 0, 说明闸门算错了。
 * ★读法: 每次 recvmsg 都带 control 缓冲 ⇒ 即使问候行与 KSUFD 回复被合并在同一次投递里,
 *   cmsg 也不会丢(用 read() 才会丢)。 */
static ssize_t rx_with_fd(int c, char *acc, size_t cap, size_t *used, int *gotfd) {
  char chunk[512], ctl[128];
  struct msghdr m;
  struct iovec io;
  size_t take;
  ssize_t n;

  memset(&m, 0, sizeof m);
  memset(ctl, 0, sizeof ctl);
  io.iov_base = chunk;
  io.iov_len = sizeof chunk;
  m.msg_iov = &io;
  m.msg_iovlen = 1;
  m.msg_control = ctl;
  m.msg_controllen = sizeof ctl;
  n = recvmsg(c, &m, 0);
  if (n <= 0) return n;
  for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm))
    if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
      memcpy(gotfd, CMSG_DATA(cm), sizeof(int));
  take = (size_t)n;
  if (*used + take >= cap) take = cap - *used - 1;
  if (take) { memcpy(acc + *used, chunk, take); *used += take; acc[*used] = 0; }
  return n;
}

static void dump_capeff(const char *tag) {
  char buf[512], line[128];
  FILE *f = fopen("/proc/self/status", "r");
  ssize_t n;
  if (!f) { printf("%s: 打不开 /proc/self/status errno=%d\n", tag, errno); return; }
  line[0] = 0;
  while (fgets(buf, sizeof buf, f)) {
    if (!strncmp(buf, "CapEff", 6)) { snprintf(line, sizeof line, "%s", buf); break; }
  }
  fclose(f);
  n = (ssize_t)strlen(line);
  while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
  printf("%s: uid=%u euid=%u gid=%u %s\n", tag, (unsigned)getuid(),
         (unsigned)geteuid(), (unsigned)getgid(), line);
}

static int ksu_fd_client(const char *verb, int try_grant, int expect_driver) {
  struct sockaddr_un u;
  char acc[2048], req[32];
  size_t used = 0, seen;
  int got = -1, rounds, fd;

  snprintf(req, sizeof req, "%s\n", verb);
  fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { printf("ERR socket %d\n", errno); return 1; }
  memset(&u, 0, sizeof u);
  u.sun_family = AF_UNIX;
  u.sun_path[0] = 0;
  strncpy(u.sun_path + 1, UNIXNAME, sizeof(u.sun_path) - 2);
  if (connect(fd, (struct sockaddr *)&u,
              offsetof(struct sockaddr_un, sun_path) + 1 + strlen(UNIXNAME)) < 0) {
    printf("ERR connect @%s errno=%d(%s) ⇒ agent 没在跑\n", UNIXNAME, errno, strerror(errno));
    close(fd);
    return 1;
  }
  acc[0] = 0;
  /* 问候行 */
  if (rx_with_fd(fd, acc, sizeof acc, &used, &got) <= 0) { printf("ERR 问候行没收到\n"); close(fd); return 1; }
  printf("greeting: %.120s", acc);
  if (write_all(fd, req, strlen(req)) != 0) { printf("ERR 发 %s 失败\n", verb); close(fd); return 1; }
  seen = used;
  for (rounds = 0; rounds < 20; rounds++) {
    ssize_t n = rx_with_fd(fd, acc, sizeof acc, &used, &got);
    if (n <= 0) break;
    if (got >= 0) break;
    if (strstr(acc + seen, "ERR") || strstr(acc + seen, "\n")) break;
  }
  printf("回复: %.200s\n收到 fd=%d\n", acc + seen, got);
  if (got < 0) { printf("=> 没收到 fd(agent 那边没拿到，或 cmsg 路径坏了)\n"); close(fd); return 2; }
  if (!expect_driver) {
    /* TESTFD：递的是普通文件 ⇒ 判据是"收方能读它"，ioctl 反而**应当**失败(ENOTTY) */
    char buf[64];
    ssize_t r = read(got, buf, sizeof buf - 1);
    printf("离线闸门 read(收到的 fd) = %zd errno=%d(%s) 前若干字节=[%.48s]\n",
           r, errno, strerror(errno), r > 0 ? (buf[r] = 0, buf) : "");
    {
      struct ksu_get_info_cmd gi;
      memset(&gi, 0, sizeof gi);
      printf("  对照: 对普通文件发 GET_INFO 应当失败: rc=%d errno=%d(%s)\n",
             ioctl(got, KSU_IOCTL_GET_INFO, &gi), errno, strerror(errno));
    }
  } else {
    struct ksu_get_info_cmd gi;
    int r;
    memset(&gi, 0, sizeof gi);
    r = ioctl(got, KSU_IOCTL_GET_INFO, &gi);
    printf("正对照 GET_INFO(换进程后 ioctl 打得进去?): rc=%d errno=%d(%s) "
           "version=%u flags=0x%x features=%u uapi=%u\n",
           r, errno, strerror(errno), gi.version, gi.flags, gi.features, gi.uapi_version);
  }
  if (try_grant) {
    int r;
    dump_capeff("授权前");
    r = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
    printf("GRANT_ROOT(名单外 uid 应当被拒): rc=%d errno=%d(%s)\n", r, errno, strerror(errno));
    dump_capeff("授权后");
  }
  close(got);
  close(fd);
  return 0;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  signal(SIGCHLD, SIG_DFL);
  if (argc > 1 && !strcmp(argv[1], "--probe")) return probe_unix();
  if (argc > 1 && !strcmp(argv[1], "--ksufd")) return ksu_fd_client("KSUFD", 0, 1);
  if (argc > 1 && !strcmp(argv[1], "--ksugrant")) return ksu_fd_client("KSUFD", 1, 1);
  /* ★离线闸门(不花窗口)：TESTFD 递的是普通文件 fd ⇒ 单验"SCM_RIGHTS 这条路走得通不通"。
   *   第三十六发就是这段代码里 CMSG_FIRSTHDR 在 msg_control 赋值之前调 ⇒ cm=NULL ⇒ 子进程 SIGSEGV，
   *   而现场看着像"内核没给 fd"。有这条闸门就能在干净 boot 上直接抓到。 */
  if (argc > 1 && !strcmp(argv[1], "--fdtest")) return ksu_fd_client("TESTFD", 0, 0);
  int port = DEF_PORT;
  if (argc > 1) port = atoi(argv[1]);
  if (argc > 2) IDLE = atoi(argv[2]);
  for (int i = 3; i < argc && NALLOW < 8; i++) {
    unsigned u = (unsigned)strtoul(argv[i], 0, 10);
    if (argv[i][0] >= '0' && argv[i][0] <= '9') ALLOW[NALLOW++] = u;
  }
  /* 白名单里永远允许 root 与 shell 自己(便于调试/收尾) */
  if (NALLOW) {
    int has0 = 0, has2000 = 0;
    for (int i = 0; i < NALLOW; i++) { if (ALLOW[i] == 0) has0 = 1; if (ALLOW[i] == 2000) has2000 = 1; }
    if (!has0 && NALLOW < 8) ALLOW[NALLOW++] = 0;
    if (!has2000 && NALLOW < 8) ALLOW[NALLOW++] = 2000;
  }
  int tfd = mk_tcp(port), ufd = mk_unix();
  if (tfd < 0 && ufd < 0) { logf("两个通道都起不来, 退出"); return 1; }
  time(&last_act);
  logf("shd v2 就位 uid=%d pid=%d tcp=%d(%s) unix=@%s(%s) idle=%ds nallow=%d",
       (int)getuid(), (int)getpid(), port, tfd >= 0 ? "on" : "off",
       UNIXNAME, ufd >= 0 ? "on" : "off", IDLE, NALLOW);

  for (;;) {
    fd_set rs; FD_ZERO(&rs);
    int hi = -1;
    if (tfd >= 0) { FD_SET(tfd, &rs); if (tfd > hi) hi = tfd; }
    if (ufd >= 0) { FD_SET(ufd, &rs); if (ufd > hi) hi = ufd; }
    struct timeval tv = { 5, 0 };
    int s = select(hi + 1, &rs, 0, 0, &tv);
    if (s < 0) { if (errno == EINTR) continue; break; }
    if (s == 0) {
      if (IDLE > 0 && time(0) - last_act > IDLE) { logf("空闲 %lds ⇒ 自动退出", (long)(time(0) - last_act)); break; }
      continue;
    }
    int which_unix = (ufd >= 0 && FD_ISSET(ufd, &rs));
    int lfd = which_unix ? ufd : tfd;
    int c = accept(lfd, 0, 0);
    if (c < 0) { if (errno == EINTR || errno == ECONNABORTED) continue; break; }
    time(&last_act);
    pid_t p = fork();
    if (p == 0) { close(tfd >= 0 ? tfd : -1); if (ufd >= 0) close(ufd); serve(c, which_unix, "127.0.0.1"); _exit(0); }
    if (p < 0) perror("fork");
    close(c);
    { int st; while (waitpid(-1, &st, WNOHANG) > 0) {} }
  }
  return 0;
}
