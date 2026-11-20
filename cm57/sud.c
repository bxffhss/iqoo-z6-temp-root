/* sud.c — 运行时 su 层 v2：默认拒绝 + 白名单可热改 + 每连接 fork（不落分区、不 setuid、重启即消失）。
 *
 * 用法:
 *   su [-c CMD] [ARGS...]          : shim(改名成 su 放 /product/bin), 连 daemon 把命令送过去
 *   sud --daemon                   : root 侧服务, 抽象 unix socket "@vivosu"
 *   sud --policy show|add|del|reset <条目>   : 改白名单(root 才能改, 文件 0600 root:root)
 *   sud --who                      : 打印"我这一发会被怎么判"(给测试/取证用)
 *
 * 策略文件格式(一行一条, # 开头是注释, **第一条命中生效**, 命中不了 = 拒绝):
 *   uid=10183          调用方(或其父进程)的 uid
 *   comm=zzygote       调用方 comm 精确匹配
 *   pkg=com.user.app   调用方 cmdline 里出现这个包名(app 侧 Runtime.exec 时 cmdline 常是
 *                      "/system/bin/sh -c su ..." ⇒ 所以匹配的是"整条 cmdline 包含它")
 *   -uid=2000          前面加 - 表示**显式拒绝**(用来在 `*` 之前挖洞)
 *   *                  放行其余所有人(默认不用这行; 加了就退化成"全部放行")
 *
 * 为什么按 uid 而不是只按包名: app 的 `su` 子进程继承 app 的 uid ⇒ uid 是最不会说谎的键;
 * 包名从 cmdline/父进程 cmdline 里读, 会被 app 自己 fork 出的 sh 改掉 cmdline 而失配 ⇒ 只做辅助。
 *
 * 三条一手教训(都烧过真机, 别再退回去):
 * 1. 必须 signal(SIGPIPE, SIG_IGN), 否则调用方提前退出后 daemon 写一下就被静默打死。
 * 2. SO_PEERCRED 的布局是 **pid 在前**(bionic 没有 <sys/ucred.h>, 自己声明时搞错会三值错位)。
 * 3. accept 之后必须 fork 再 serve, 串行 serve 会让一个长会话把别的 app 全卡住。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <stddef.h>
#include <stdarg.h>
#include <ctype.h>
#include <pty.h>
#include <sys/ioctl.h>

#define SUNAME    "vivosu"

/* 报给 libsu 那类客户端的"实现版本"。它们靠 `su -v` / `su -V` 判断对面是哪种 su,
 * 拿不到就退化成"没有 root"。这里给的是**兼容性标识**, 不代表真有对应功能。 */
#ifndef SU_VER_STR
#define SU_VER_STR "25.2:su"
#endif
#ifndef SU_VER_NUM
#define SU_VER_NUM "25200"
#endif
/* 策略文件**不能**放 /data/local/tmp: 那个目录 uid2000 自己就能写 ⇒ 白名单形同不存在。
   放 /data/adb/su/, 由 daemon 以 0700 root 建目录, 只有 root(或已授权的 su)能改。 */
#define POLICYDIR "/data/adb/su"
#define POLICY    POLICYDIR "/su.policy"
#define CTRLLIST  POLICYDIR "/su.ctrl"      /* 允许使用控制面的 uid(每行 uid=N); 缺文件=只认 token */
#define AUDIT     "/data/local/tmp/su.audit"      /* 审计日志放 shell 读得到的地方, 方便回读取证 */
#define MAXRULE   64
/* bionic 没有 <sys/ucred.h>; 内核 SO_PEERCRED 的布局是 **pid 在前** */
struct su_uc { unsigned int pid; unsigned int uid; unsigned int gid; };

/* ---------- 小工具 ---------- */
static void logstamp(const char *fmt, ...) {
  char line[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  int fd = open(AUDIT, O_WRONLY | O_APPEND | O_CREAT, 0600);
  if (fd >= 0) {
    char up[64] = "";
    int r = open("/proc/uptime", O_RDONLY);
    if (r >= 0) { int n = read(r, up, sizeof up - 1); close(r); if (n > 0) up[n] = 0; }
    /* uptime 文件是 "426.17 1571.75\n" 两个数 + 换行: 直接塞进 "[]" 会把审计行劈成两半
       (真机日志里就是 [426.17 1571.75 \n] DAEMON up ...), ⇒ 只取第一个字段并去掉换行 */
    up[strcspn(up, " \n\r\t")] = 0;
    char out[1200];
    int m = snprintf(out, sizeof out, "[%s] %s\n", up, line);
    if (write(fd, out, m) < 0) { /* 审计写不进去不阻塞主流程 */ }
    fsync(fd);
    close(fd);
  }
}

static int read_tok(const char *path, char *buf, size_t n) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  int r = read(fd, buf, n - 1);
  close(fd);
  if (r <= 0) { buf[0] = 0; return -1; }
  buf[r] = 0;
  for (int i = 0; i < r; i++) if (!buf[i]) buf[i] = ' ';   /* cmdline 是 NUL 分隔 */
  char *nl = strchr(buf, '\n'); if (nl) *nl = 0;
  return 0;
}

/* ---------- 策略 ---------- */
struct rule { int deny, byuid, bycomm, bypkg; unsigned uid; char key[64]; };
static struct rule RULES[MAXRULE];
static int NRULES = 0;

static void rule_parse(const char *s0, struct rule *r) {
  memset(r, 0, sizeof *r);
  while (*s0 == ' ' || *s0 == '\t') s0++;
  const char *s = s0;
  if (*s == '-') { r->deny = 1; s++; }
  if (!strncmp(s, "uid=", 4)) {
    r->byuid = 1;
    r->uid = (unsigned)strtoul(s + 4, 0, 10);
  } else if (!strncmp(s, "comm=", 5)) {
    r->bycomm = 1;
    snprintf(r->key, sizeof r->key, "%s", s + 5);
  } else if (!strncmp(s, "pkg=", 4)) {
    r->bypkg = 1;
    snprintf(r->key, sizeof r->key, "%s", s + 4);
  } else if (*s == '*') {
    r->bypkg = 1;                      /* `*` = cmdline 永远包含空串 => 一律命中 */
    r->key[0] = 0;
  } else {
    r->bypkg = 2;                      /* 裸串当作 pkg 关键字 */
    snprintf(r->key, sizeof r->key, "%s", s);
  }
}

/* 每次请求都重读策略文件 ⇒ 改完立即生效(这就是"管理器"的接口, 不需要重启 daemon) */
static int policy_load(void) {
  NRULES = 0;
  FILE *f = fopen(POLICY, "r");
  if (!f) return -1;
  char ln[128];
  while (fgets(ln, sizeof ln, f) && NRULES < MAXRULE) {
    char *nl = strpbrk(ln, "\r\n"); if (nl) *nl = 0;
    if (ln[0] == '#' || ln[0] == 0) continue;
    rule_parse(ln, &RULES[NRULES++]);
  }
  fclose(f);
  return NRULES;
}

static int rule_hit(const struct rule *r, unsigned uid, const char *comm, const char *cmdline) {
  if (r->byuid) return uid == r->uid;
  if (r->bycomm) return comm[0] && !strcmp(comm, r->key);
  if (r->bypkg) return r->key[0] ? (strstr(cmdline, r->key) != 0) : 1;
  return 0;
}

/* 返回 1=放行 / 0=拒绝; why 填判据说明 */
static int policy_decide(unsigned uid, const char *comm, const char *cmdline,
                         const char *pcmdline, char *why, size_t wn) {
  if (policy_load() < 0) {
    snprintf(why, wn, "策略文件不存在 => **默认拒绝**(不猜)");
    return 0;
  }
  for (int i = 0; i < NRULES; i++) {
    if (rule_hit(&RULES[i], uid, comm, cmdline) ||
        (RULES[i].bypkg && RULES[i].key[0] && pcmdline[0] && strstr(pcmdline, RULES[i].key))) {
      snprintf(why, wn, "第 %d 条 [%s] %s", i + 1, RULES[i].deny ? "deny" : "allow",
               RULES[i].deny ? "=> 拒绝" : "=> 放行");
      return RULES[i].deny ? 0 : 1;
    }
  }
  snprintf(why, wn, "%d 条全不命中 => 默认拒绝", NRULES);
  return 0;
}

/* ---------- 双向接力(沿用 v1 的已验证逻辑) ---------- */
static void relay(int rem, int out, int in) {
  int in_open = 1;
  char buf[4096];
  while (1) {
    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(rem, &rs);
    int hi = rem;
    if (in_open) { FD_SET(in, &rs); if (in > hi) hi = in; }
    if (select(hi + 1, &rs, 0, 0, 0) < 0) { if (errno == EINTR) continue; break; }
    if (FD_ISSET(rem, &rs)) {
      ssize_t r = read(rem, buf, sizeof buf);
      if (r <= 0) break;
      if (write(out, buf, r) <= 0) break;
    }
    if (in_open && FD_ISSET(in, &rs)) {
      ssize_t r = read(in, buf, sizeof buf);
      if (r <= 0) { in_open = 0; shutdown(rem, SHUT_WR); continue; }
      if (write(rem, buf, r) <= 0) break;
    }
  }
}

static int srv_fd(void) {
  struct sockaddr_un a;
  int fd, on = 1;
  memset(&a, 0, sizeof a);
  a.sun_family = AF_UNIX;
  a.sun_path[0] = 0;
  strncpy(a.sun_path + 1, SUNAME, sizeof(a.sun_path) - 2);
  fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
  if (bind(fd, (struct sockaddr *)&a, offsetof(struct sockaddr_un, sun_path) + 1 + strlen(SUNAME)) < 0) {
    perror("bind"); close(fd); return -1; }
  if (listen(fd, 16) < 0) { perror("listen"); close(fd); return -1; }
  return fd;
}

static int cli_fd(void) {
  struct sockaddr_un a;
  memset(&a, 0, sizeof a);
  a.sun_family = AF_UNIX;
  a.sun_path[0] = 0;
  strncpy(a.sun_path + 1, SUNAME, sizeof(a.sun_path) - 2);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  if (connect(fd, (struct sockaddr *)&a, offsetof(struct sockaddr_un, sun_path) + 1 + strlen(SUNAME)) < 0) {
    perror("connect"); close(fd); return -1; }
  return fd;
}

/* /proc/<pid>/status 是**多行**文件, PPid 在第 6 行 ⇒ 不能用 read_tok(它在第一个换行处截断,
   真机上一整轮的 ppid 全是 0 就是这么来的)。这份专门保留换行。 */
static int read_raw(const char *path, char *buf, size_t n) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) { buf[0] = 0; return -1; }
  int r = read(fd, buf, n - 1);
  close(fd);
  if (r <= 0) { buf[0] = 0; return -1; }
  buf[r] = 0;
  return 0;
}

/* ---------- 控制面: manager 改白名单的专用通道 ----------
 * 为什么存在: 白名单管的是"谁能拿 root", 而"改白名单"这件事本身也走 su ⇒ manager 一旦把
 * 自己的 uid 撤掉就**再也改不回来**(真机踩到, 只能重启)。KSU 的语义是"manager 是受信管理端",
 * 与"它自己在不在超级用户列表里"无关, 所以这里给一条独立鉴权的通道。
 * 为什么这样算安全: token 编在 APK 里, 而 base.apk 是 0644 ⇒ 同机 app 拆得出来。
 * **别把这条通道当成"只是改配置"**: 真机实测(2026-09-29)只有 token 时, 不在白名单里的 uid2000
 * 用 `--ctrl add uid=2000` 把自己加进去, 紧接着 `su -c id` 就是 uid=0 ⇒ "能改白名单"就等于提权,
 * 它的能力**不比 agent 通道小**。因此必须再叠一层"调用方 uid 也要在 root-only 的 su.ctrl 里"
 * (见 ctrl_uid_allowed), 让"拿到 token"和"是 manager"两件事缺一不可。
 * 另外: 参数只认 `uid=<数字>`, 不给任意命令; 且窗口外 untrusted_app 连不上这个 unix socket
 * (SELinux EACCES, 已实测) ⇒ 整条通道只在 root 窗口内可达。
 * 没编进 token(-DSUW_CTRL_TOKEN 为空)时整条通道拒绝一切请求 ⇒ 默认关闭。 */
#ifndef SUW_CTRL_TOKEN
#define SUW_CTRL_TOKEN ""
#endif

static int cmd_policy(int argc, char **argv);   /* 定义在下面(策略管理) */

/* token 必须**经过 volatile 读**: -O2 会把定长字符串常量折成立即数, 那样二进制里根本不存在这串
 * 字符 ⇒ 构建脚本"token 有没有编进去"的自检会假阴性(2026-09-29 就是这么抓到的)。
 * 顺带: 逐字节攒差异而不是短路比较, 不做成能被时间差读出前缀的形式。 */
static const char ctrl_tok[] = SUW_CTRL_TOKEN;

static int token_ok(const char *got) {
  const volatile char *want = ctrl_tok;
  size_t lw = sizeof ctrl_tok - 1, lg = strlen(got);
  if (lw == 0 || lw != lg) return 0;
  unsigned diff = 0;
  for (size_t i = 0; i < lw; i++) diff |= (unsigned)(want[i] ^ (unsigned char)got[i]);
  return diff == 0;
}
/* 控制面的第二道闸: 调用方 uid 必须在 /data/adb/su/su.ctrl 里(root 0700 目录下, 别的 uid 写不了)。
 * 为什么要它: token 编在 APK 里, 而 base.apk 是 0644 ⇒ 同机任何 app 拆得出来。真机实测(2026-09-29):
 * 只有 token 时, 不在白名单里的 uid2000 用 `--ctrl add uid=2000` 就能把自己加进去, 紧接着
 * `su -c id` 就是 uid=0 —— 所以"能改白名单"就**等于**提权, 不能说它能力更小。
 * 加上 uid 闸之后, 攻击者还得"正好是 manager 那个 uid"才行, 而 uid 是内核给的、伪造不了。
 * 文件不存在/为空 ⇒ 退回只认 token(并把这件事写进审计, 不静默)。 */
static int ctrl_uid_allowed(unsigned uid) {
  char blob[1024];
  int fd = open(CTRLLIST, O_RDONLY);
  if (fd < 0) return -1;                       /* 没配 => 只认 token */
  int r = read(fd, blob, sizeof blob - 1);
  close(fd);
  if (r <= 0) return -1;
  blob[r] = 0;
  char want[32];
  snprintf(want, sizeof want, "uid=%u", uid);
  for (char *s = blob, *e; (e = strchr(s, '\n')) != NULL; s = e + 1) {
    *e = 0;
    char *t = s;
    while (*t == ' ' || *t == '\t') t++;
    if (!strcmp(t, want)) return 1;
  }
  if (strchr(blob, '\n') == NULL) {            /* 末行没换行也要比 */
    char *t = blob;
    while (*t == ' ' || *t == '\t') t++;
    if (!strcmp(t, want)) return 1;
  }
  return 0;
}

static int uid_line_only(const char *s) {       /* 只放行 "uid=<1..7 位数字>" 这一种条目 */
  if (strncmp(s, "uid=", 4) != 0) return 0;
  int n = 0;
  for (const char *q = s + 4; *q; q++) { if (*q < '0' || *q > '9') return 0; n++; if (n > 7) return 0; }
  return n > 0;
}

static void serve_ctrl(int c, struct su_uc *uc, const char *comm) {
  char line[512];
  ssize_t n = 0;
  while (n < (ssize_t)sizeof line - 1) {
    ssize_t r = read(c, line + n, sizeof line - 1 - n);
    if (r <= 0) break;
    n += r;
    if (memchr(line + n - r, '\n', r)) break;
  }
  line[n > 0 ? n : 0] = 0;
  char *nl = strpbrk(line, "\r\n"); if (nl) *nl = 0;

  /* line = "CTRL <token> <verb> [arg]" */
  char *tok = strtok(line + 5, " ");
  char *verb = strtok(NULL, " ");
  char *arg = strtok(NULL, " ");
  if (!tok || !token_ok(tok)) {
    logstamp("CTRL-DENY uid=%u pid=%u comm=[%s] (token 不对或本 daemon 没编进 token)",
             uc->uid, (unsigned)uc->pid, comm);
    const char *m = "CTRL-DENY: token 不对\n";
    if (write(c, m, strlen(m)) < 0) { }
    close(c);
    return;
  }
  {
    int ca = ctrl_uid_allowed(uc->uid);
    if (ca == 0) {
      logstamp("CTRL-DENY uid=%u pid=%u comm=[%s] (token 对但这个 uid 不在 %s 里)",
               uc->uid, (unsigned)uc->pid, comm, CTRLLIST);
      const char *m = "CTRL-DENY: 这个 uid 不在控制面名单里\n";
      if (write(c, m, strlen(m)) < 0) { }
      close(c);
      return;
    }
    if (ca < 0)
      logstamp("CTRL uid=%u pid=%u comm=[%s] (警告: %s 不存在 ⇒ 只认 token)",
               uc->uid, (unsigned)uc->pid, comm, CTRLLIST);
  }
  if (!verb) verb = (char *)"show";
  if (strcmp(verb, "show") && strcmp(verb, "add") && strcmp(verb, "del") &&
      strcmp(verb, "reset") && strcmp(verb, "who")) {
    const char *m = "CTRL-ERR: 只认 policy show|add|del|reset 与 who\n";
    if (write(c, m, strlen(m)) < 0) { }
    close(c);
    return;
  }
  if ((strcmp(verb, "add") == 0 || strcmp(verb, "del") == 0) && (!arg || !uid_line_only(arg))) {
    const char *m = "CTRL-ERR: add/del 的参数必须是 uid=<数字>\n";
    if (write(c, m, strlen(m)) < 0) { }
    close(c);
    return;
  }
  logstamp("CTRL uid=%u pid=%u comm=[%s] op=%s %s", uc->uid, (unsigned)uc->pid, comm,
           verb, arg ? arg : "");

  if (!strcmp(verb, "who")) {                   /* 让 manager 能确认"对面确实是 sud" */
    const char *m = "CTRL-OK sud\n";
    if (write(c, m, strlen(m)) < 0) { }
    close(c);
    return;
  }
  char *av[4] = { (char *)"sud", (char *)"--policy", verb, arg };
  int ac = arg ? 4 : 3;
  pid_t p = fork();
  if (p == 0) {
    dup2(c, 1); dup2(c, 2);
    close(c);
    /* 必须先 fflush 再 _exit: 重定向到 socket 的 stdout 是**全缓冲**, 而 _exit 不走 atexit
     * ⇒ cmd_policy 的 printf 全留在缓冲区里被丢掉(真机表现: `--ctrl show` 一个字节都不回,
     * 但策略文件其实已经改到了)。`who` 那条用 write() 直写所以看着像"只有它 work"。 */
    int rc = cmd_policy(ac, av);
    fflush(stdout);
    fflush(stderr);
    _exit(rc);
  }
  if (p > 0) { int st = 0; waitpid(p, &st, 0); }
  close(c);
}

static void serve_conn(int c) {
  struct su_uc uc;
  socklen_t l = sizeof uc;
  char comm[64] = "", cmdline[256] = "", pcomm[64] = "", pcmdline[256] = "", why[160] = "";
  char gcomm[64] = "", gcmdline[256] = "";
  pid_t ppid = 0, gppid = 0;
  if (getsockopt(c, SOL_SOCKET, SO_PEERCRED, &uc, &l) != 0) { close(c); return; }
  char p[64];
  snprintf(p, sizeof p, "/proc/%d/comm", uc.pid);   read_tok(p, comm, sizeof comm);
  snprintf(p, sizeof p, "/proc/%d/cmdline", uc.pid); read_tok(p, cmdline, sizeof cmdline);
  {
    char st[1024] = "";
    snprintf(p, sizeof p, "/proc/%d/status", uc.pid);
    if (read_raw(p, st, sizeof st) == 0) {
      char *q = strstr(st, "PPid:");
      if (q) ppid = (pid_t)strtol(q + 6, 0, 10);
    }
  }
  if (ppid > 0) {
    snprintf(p, sizeof p, "/proc/%d/comm", ppid);    read_tok(p, pcomm, sizeof pcomm);
    snprintf(p, sizeof p, "/proc/%d/cmdline", ppid);  read_tok(p, pcmdline, sizeof pcmdline);
    /* 再往上一层, **只为把日志读得懂**: app 里 Runtime.exec("su") 通常会先起 sh,
     * 于是 parent 是 "sh -c su" 这种中转进程, 光看它分不清是哪个包(共享 uid 时更要命)。
     * 只写进审计, 不参与策略匹配 —— 参与匹配就等于把身份交给进程自己写的 cmdline。 */
    char st[1024] = "";
    snprintf(p, sizeof p, "/proc/%d/status", ppid);
    if (read_raw(p, st, sizeof st) == 0) {
      char *q = strstr(st, "PPid:");
      if (q) gppid = (pid_t)strtol(q + 6, 0, 10);
    }
    if (gppid > 0) {
      snprintf(p, sizeof p, "/proc/%d/comm", gppid);    read_tok(p, gcomm, sizeof gcomm);
      snprintf(p, sizeof p, "/proc/%d/cmdline", gppid);  read_tok(p, gcmdline, sizeof gcmdline);
    }
  }
  /* 控制面走"看前 5 个字节"来分辨: MSG_PEEK 不吃掉数据, 所以不是 CTRL 就原样走老路,
   * 普通 su 请求的判据仍然只来自 SO_PEERCRED(与命令内容无关)。 */
  {
    char head[5];
    /* DONTWAIT: peek 不该把"对方还没发数据"变成阻塞 —— 普通 su 请求的判据只来自 SO_PEERCRED。
     * 拿不到 5 字节(或 EAGAIN)就当不是控制面, 后面正常 read 仍然会读到这些字节(peek 不消费)。 */
    ssize_t hp = recv(c, head, sizeof head, MSG_PEEK | MSG_DONTWAIT);
    if (hp == 5 && !memcmp(head, "CTRL ", 5)) { serve_ctrl(c, &uc, comm); return; }
  }
  int ok = policy_decide(uc.uid, comm, cmdline, pcmdline, why, sizeof why);
  char gpt[300] = "";
  if (gppid > 0) snprintf(gpt, sizeof gpt, " gparent=[%d:%s/%s]", (int)gppid, gcomm, gcmdline);
  logstamp("%s uid=%u pid=%u comm=[%s] ppid=%d parent=[%s/%s]%s why=%s",
           ok ? "ALLOW" : "DENY ", uc.uid, uc.pid, comm, (int)ppid, pcomm, pcmdline, gpt, why);
  if (!ok) {
    /* 行首标记是给 shim 认退出码用的, 别随意改 */
    const char *m = "SU-DENY: 白名单拒绝。需要 root 改 /data/adb/su/su.policy(本目录 0700, 别 uidd 改不了)\n";
    if (write(c, m, strlen(m)) < 0) { /* 对方可能已经走了 */ }
    close(c);
    return;
  }

  char cmd[2048];
  ssize_t n = 0;
  while (n < (ssize_t)sizeof cmd - 1) {
    ssize_t r = read(c, cmd + n, sizeof cmd - 1 - n);
    if (r <= 0) break;
    n += r;
    if (memchr(cmd, 0, n) || memchr(cmd + n - r, '\n', r)) break;
  }
  if (n <= 0) { close(c); return; }
  cmd[n] = 0;
  char *nl = strpbrk(cmd, "\r\n"); if (nl) *nl = 0;
  logstamp("EXEC uid=%u pid=%u cmd=[%.200s]", uc.uid, uc.pid, cmd);

  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { close(c); return; }
  /* 什么时候要 pty: ① 客户端显式要(shim 把 `--pty` 翻译成行首的 "@pty " 标记);
   * ② 没给命令 = 裸 `su` ⇒ 这是"常驻 root shell"用法。
   * 为什么必须给: libsu/Shizuku/MT 这类客户端开了 shell 之后**等提示符**才发第一条命令,
   * 而 sh 只在 stdin 是 tty 时才打提示符 ⇒ 普通管道 = 谁都不说话 = 客户端卡死(真机表现: 卡启动页)。
   * 反过来, 带 `-c` 的一次性命令**不要** pty: pty 会做 ONLCR/换行翻译, 破坏二进制输出。 */
  int want_pty = 0;
  char *xcmd = cmd;
  if (!strncmp(cmd, "@pty ", 5)) { want_pty = 1; xcmd = cmd + 5; }
  else if (!strcmp(cmd, "/system/bin/sh")) want_pty = 1;

  int master = -1;
  pid_t p2;
  struct winsize ws;
  memset(&ws, 0, sizeof ws);
  ws.ws_row = 24; ws.ws_col = 80;
  if (want_pty) {
    p2 = forkpty(&master, NULL, NULL, &ws);
  } else {
    p2 = fork();
  }
  if (p2 == 0) {
    setsid();
    if (!want_pty) { dup2(sv[1], 0); dup2(sv[1], 1); dup2(sv[1], 2); }
    close(sv[0]); if (sv[1] > 2) close(sv[1]); if (master > 2) close(master);
    setenv("PATH", "/product/bin:/apex/com.android.runtime/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin", 1);
    /* 交互壳必须**直接 exec**, 外面不能套一层 `sh -c "/system/bin/sh"`:
     * 套了之后外层 sh 不会 exec 掉自己(ps 里能看到 sh 还活着并 fork 出 bash)⇒ 真正的壳落在
     * **终端的后台进程组**里 ⇒ bash 判定"我不在前台" ⇒ 不打提示符、不读输入 ⇒
     * 客户端整个会话看起来彻底卡死(2026-09-30 实测: 喂 `id` 连一个字节都不回)。 */
    if (want_pty && !strcmp(xcmd, "/system/bin/sh"))
      execl("/system/bin/sh", "-sh", (char *)0);
    execl("/system/bin/sh", "sh", "-c", xcmd, (char *)0);
    _exit(127);
  }
  close(sv[1]);
  if (p2 < 0) { close(sv[0]); if (master >= 0) close(master); close(c); return; }
  if (want_pty) relay(master, c, c);
  else relay(sv[0], c, c);
  close(sv[0]);
  if (master >= 0) close(master);
  close(c);
  int st = 0;
  waitpid(p2, &st, 0);
}

/* ---------- 策略管理(root 侧) ---------- */
static int policy_read_file(char *buf, size_t n) {
  int fd = open(POLICY, O_RDONLY);
  if (fd < 0) { buf[0] = 0; return -1; }
  int r = read(fd, buf, n - 1);
  close(fd);
  if (r < 0) r = 0;
  buf[r] = 0;
  return r;
}
/* /data/adb 在本机可能不存在(没装过任何 root 方案), 单层 mkdir 会 ENOENT ⇒ 手搭两级 */
static void ensure_policydir(void) {
  mkdir("/data/adb", 0700);
  mkdir(POLICYDIR, 0700);
  chmod(POLICYDIR, 0700);
}

static int policy_write_file(const char *s) {
  ensure_policydir();
  int fd = open(POLICY, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) { fprintf(stderr, "写不了 %s(errno=%d)\n", POLICY, errno); return 1; }
  int n = strlen(s);
  if (write(fd, s, n) != n) { close(fd); return 1; }
  fsync(fd); close(fd);
  chmod(POLICY, 0600);
  return 0;
}
/* 逐行比较, 不做子串匹配(避免 "uid=0" 被 "uid=0"之外的长行误命中) */
static int has_line(const char *blob, const char *ln) {
  char s[512];
  snprintf(s, sizeof s, "%s", blob);
  char *p = s, *e;
  while ((e = strchr(p, '\n')) != 0) {
    *e = 0;
    if (!strcmp(p, ln)) return 1;
    p = e + 1;
  }
  return *p && !strcmp(p, ln);
}
static int cmd_policy(int argc, char **argv) {
  const char *sub = argc > 2 ? argv[2] : "show";
  char blob[4096];
  int have = policy_read_file(blob, sizeof blob);
  if (!strcmp(sub, "show")) {
    if (have < 0) { printf("(策略文件不存在 ⇒ 全部默认拒绝)\n"); return 2; }
    fputs(blob, stdout);
    return 0;
  }
  if (have < 0) strcpy(blob, "# su 白名单(一行一条, 第一条命中生效, 都不命中=拒绝)\nuid=0\n");
  if (!strcmp(sub, "reset")) return policy_write_file("# su 白名单\nuid=0\n");
  if (argc < 3) { fprintf(stderr, "用法: sud --policy show|add|del|reset <条目>\n"); return 2; }
  char ln[128];
  snprintf(ln, sizeof ln, "%s", argv[3]);
  if (!strcmp(sub, "add")) {
    if (has_line(blob, ln)) { printf("已存在: %s\n", ln); return 0; }
    size_t need = strlen(blob) + strlen(ln) + 4;
    char *nb = malloc(need);
    snprintf(nb, need, "%s%s\n", blob, ln);
    if (blob[0] && blob[strlen(blob) - 1] != '\n') {   /* 末行没换行就拼 => 会和上一条粘成一行 */
      char *fix = malloc(need + 2);
      snprintf(fix, need + 2, "%s\n%s\n", blob, ln);
      int rc = policy_write_file(fix);
      free(fix); free(nb);
      printf("added: %s\n", ln);
      return rc;
    }
    int rc = policy_write_file(nb);
    free(nb);
    printf("added: %s\n", ln);
    return rc;
  }
  if (!strcmp(sub, "del")) {
    char out[4096];
    out[0] = 0;
    char *s = blob, *e;
    while ((e = strchr(s, '\n'))) {
      *e = 0;
      if (strcmp(s, ln) != 0) { strncat(out, s, sizeof out - strlen(out) - 2); strncat(out, "\n", 1); }
      s = e + 1;
    }
    return policy_write_file(out);
  }
  fprintf(stderr, "未知子命令: %s\n", sub);
  return 2;
}

static int cmd_who(void) {
  char comm[64] = "", cmdline[256] = "", pcmdline[8] = "", why[160] = "";
  read_tok("/proc/self/comm", comm, sizeof comm);
  read_tok("/proc/self/cmdline", cmdline, sizeof cmdline);
  int ok = policy_decide(getuid(), comm, cmdline, pcmdline, why, sizeof why);
  printf("uid=%d comm=[%s] cmdline=[%s] => %s (%s)\n",
         (int)getuid(), comm, cmdline, ok ? "ALLOW" : "DENY", why);
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  signal(SIGCHLD, SIG_DFL);
  signal(SIGPIPE, SIG_IGN);              /* ★ 见文件头教训 1 */
  if (argc > 1 && !strcmp(argv[1], "--daemon")) {
    if (getuid() != 0) { fprintf(stderr, "[sud] daemon 必须以 uid0 起\n"); return 1; }
    ensure_policydir();
    if (access(POLICY, F_OK) != 0) policy_write_file("# su 白名单(第一条命中生效, 都不命中=拒绝)\nuid=0\n");
    int fd = srv_fd();
    if (fd < 0) { fprintf(stderr, "[sud] daemon 起不来(errno=%d)\n", errno); return 1; }
    logstamp("DAEMON up uid=%d pid=%d rules=%d", (int)getuid(), (int)getpid(), policy_load());
    fprintf(stderr, "[sud] daemon 就位 @%s uid=%d pid=%d\n", SUNAME, (int)getuid(), (int)getpid());
    fflush(stderr);
    for (;;) {
      int c = accept(fd, 0, 0);
      if (c < 0) {
        if (errno == EINTR || errno == ECONNABORTED) continue;
        perror("accept"); break;
      }
      pid_t p = fork();                  /* ★ 每连接 fork(见文件头教训 3) */
      if (p == 0) { close(fd); serve_conn(c); _exit(0); }
      if (p < 0) perror("fork");
      close(c);                          /* 父进程关掉这份, 子进程持有自己的 */
      /* 回收已结束的连接子进程, 否则每个请求留一个 [sudbin] 僵尸(真机 r1 一次跑完就堆了 9 个) */
      { int st; while (waitpid(-1, &st, WNOHANG) > 0) {} }
    }
    fprintf(stderr, "[sud] accept 循环结束(errno=%d) => 退出, 由监督循环重启\n", errno);
    return 1;
  }
  if (argc > 1 && !strcmp(argv[1], "--policy")) return cmd_policy(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "--who")) return cmd_who();
  if (argc > 1 && !strcmp(argv[1], "--ctrl")) {
    /* 控制面客户端(给回归用, 也让 manager 之外的入口能验): 用编译期 token 走 @vivosu。
     * 判据成对看: `--ctrl show` 应当**成功**(控制面不要求调用方在白名单里),
     * 而同一个 uid 的 `su -c id` 应当被拒(rc=126) —— 这才说明控制面没有变成第二条提权路。 */
    int fd = cli_fd();
    if (fd < 0) { printf("CTRL-ERR: 连不上 @%s(daemon 没起?)\n", SUNAME); return 1; }
    char cl[256];
    int cn = snprintf(cl, sizeof cl, "CTRL %s %s %s\n",
                      SUW_CTRL_TOKEN, argc > 2 ? argv[2] : "show", argc > 3 ? argv[3] : "");
    if (cn <= 0) { close(fd); return 1; }
    if (write(fd, cl, (size_t)cn) <= 0) { perror("write"); close(fd); return 1; }
    relay(fd, 1, 0);
    close(fd);
    return 0;
  }

  /* shim: 把标准 su 方言翻成一条命令。
   * 为什么必须做: libsu(Magisk/KSU 客户端库, Shizuku / LSPatch 系 / AGG 等都在用)第一步是
   * `su -v` 或 `su --mount-master` 探实现与能力, 拿不到合理回应就判定"没有可用 root",
   * 之后连请求都不发 ⇒ 真机表现是"白名单里已经给了它、app 还是说没 root"。
   * 规则: 跳过已知开关(含带值的), 认 Magisk/KSU 的"目标 uid"位置参数(我们只给 root, 记下但忽略),
   *      剩下的是命令; 只给了 `-v` 没给命令 ⇒ 回一个版本号。 */
  char cmd[2048];
  cmd[0] = 0;
  {
    int o = 0, want_ver = 0, want_num = 0, saw_c = 0, cli_pty = 0;
    int i = 1;
    for (; i < argc; i++) {
      char *a = argv[i];
      if (!strcmp(a, "-c") || !strcmp(a, "--command")) { saw_c = 1; continue; }
      if (!strcmp(a, "-v") || !strcmp(a, "--version")) { want_ver = 1; continue; }
      if (!strcmp(a, "-V")) { want_num = 1; continue; }
      if (!strcmp(a, "--pty")) { cli_pty = 1; continue; }
      if (!strcmp(a, "--")) { i++; break; }   /* 标准"选项结束": 后面整段都是命令 */
      if (!strcmp(a, "--mount-master") || !strcmp(a, "-d") ||
          !strcmp(a, "--debug") || !strcmp(a, "-E") || !strcmp(a, "--no-db") ||
          !strcmp(a, "--login") || !strcmp(a, "-") || !strcmp(a, "--current") ||
          !strcmp(a, "-i") || !strcmp(a, "--verbose")) continue;
      if (!strcmp(a, "-t") || !strcmp(a, "-g") || !strcmp(a, "-G") || !strcmp(a, "-Z") ||
          !strcmp(a, "-u") || !strcmp(a, "--uid") || !strcmp(a, "--request-code")) { i++; continue; }
      /* Magisk/KSU 的位置参数目标 uid: "0" / "10462" / "u0_a142" */
      if (!saw_c && (isdigit((unsigned char)a[0]) ||
                     (a[0] == 'u' && strcspn(a, "0123456789") > 0 && a[strcspn(a, "0123456789")] == '_'))) {
        logstamp("(shim 忽略目标 uid 参数 [%s] ⇒ 一律给 root)", a);
        continue;
      }
      break;                                   /* 剩下的都算命令 */
    }
    if (i < argc) {
      for (; i < argc && o < (int)sizeof cmd - 64; i++)
        o += snprintf(cmd + o, sizeof cmd - o, o ? " %s" : "%s", argv[i]);
    } else if (want_ver) {
      snprintf(cmd, sizeof cmd, "echo %s", SU_VER_STR);
    } else if (want_num) {
      snprintf(cmd, sizeof cmd, "echo %s", SU_VER_NUM);
    } else {
      snprintf(cmd, sizeof cmd, "/system/bin/sh");
    }
    if (cli_pty) {                       /* 把 `--pty` 翻成给 daemon 的行首标记 */
      char tmp[2100];
      snprintf(tmp, sizeof tmp, "@pty %s", cmd);
      snprintf(cmd, sizeof cmd, "%s", tmp);
    }
    (void)saw_c;
  }

  int fd = cli_fd();
  if (fd < 0) { fprintf(stderr, "su: 连不上 root daemon(先跑 sud --daemon)\n"); return 127; }
  strcat(cmd, "\n");
  if (write(fd, cmd, strlen(cmd)) <= 0) { perror("write cmd"); return 1; }
  /* 被拒时要把退出码做成 126(libsu/常见 root 客户端靠 rc 判断有没有授权成功);
     用 MSG_PEEK 先看头 8 字节, 不改后续 relay 的数据流。 */
  {
    char pk[16];
    ssize_t r = recv(fd, pk, sizeof pk - 1, MSG_PEEK);
    if (r >= 8 && !memcmp(pk, "SU-DENY:", 8)) {
      char dbuf[512];
      ssize_t n2 = read(fd, dbuf, sizeof dbuf - 1);
      if (n2 > 0) { dbuf[n2] = 0; fputs(dbuf, stderr); }
      close(fd);
      return 126;
    }
  }
  relay(fd, 1, 0);
  fflush(stdout);
  close(fd);
  return 0;
}
