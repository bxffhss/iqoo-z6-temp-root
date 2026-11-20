/* su_static.c —— 给**没有内核改道**的第三方 app 用的静态 `su`（md §6.123）。
 *
 * 为什么需要它：Termux 里手敲 `su` 报"设备上没找到 su"——本机 `/system/bin/su` 这个文件真的不存在，
 *   而 app 是先 `access()`/`stat()` 探测再执行 ⇒ 探测失败就放弃。上游 KernelSU 靠挂
 *   `newfstatat`/`faccessat` 钩子把探测伪装成成功(§6.116①)，但**本机开这两位必整机复位**，
 *   三个候选机制(CFI 桩 / 重定向 / printk 洪印)已被逐个有效否掉(§6.116~§6.121)；
 *   文件级 magic mount 在这台机也有两条独立死因(linker64 在被盖的目录里；bind 会被再盖一层 tmpfs，§6.122)。
 *   ⇒ 这条既不碰 syscall 入口、也不碰挂载：把**静态**的 su 放进 app 自己的 PATH 目录
 *     (Termux: /data/data/com.termux/files/usr/bin ⇒ 在它 PATH 最前面，且 root 可写)。
 *
 * 拿 root 的路子（授权判定仍然在内核，一步没少）：
 *   ① 连本机 abstract unix socket `@suwshd`(常驻 root agent shd)；
 *      shd v4 的放行条件是"白名单 uid **或** 内核 `UID_GRANTED_ROOT` 说这个 uid 被授权"
 *      ⇒ 谁能提权仍由 KSU 名单决定，shd 只是转交驱动 fd。
 *   ② 发 `KSUFD` ⇒ 用 SCM_RIGHTS 收一个 **KernelSU 驱动 fd**；
 *   ③ `ioctl(fd, KSU_IOCTL_GRANT_ROOT)` ⇒ 内核对**我们这个 uid** 跑 escape(在普通 ioctl 上下文，历发安全)；
 *   ④ 自证 `getuid()==0` 才 exec `sh`(不看 ioctl 返回值——记忆里那条口径：ret=0 不算执行过)；
 *   ⑤ 关掉驱动 fd 的 CLOEXEC 之前先设成 close-on-exec ⇒ root shell 里不留着驱动 fd。
 *
 * 用法与真 su 对齐：`su` / `su -c "<cmd>"` / `su <args...>`；`SUW_SU_DEBUG=1` 打诊断。
 *
 * ★版本账：v2(第 98~102 发在跑的那份，2,245,720 B / md5 `9aca0a3e…`，现留在 `cm57/sustatic.v2_9aca0a3e`)
 *   =扫 /proc/self/fd 拿驱动 fd → ioctl 自提权 → 自证 getuid()==0 → exec sh；
 *   v3(本文件现在这份，**已占交付位 `cm57/sustatic`**，2,241,944 B / md5 `f7a441d2…`)
 *   =v2 + exec 前 `unsetenv(LD_PRELOAD)` + `setenv(PATH,"/system/bin:/system/xbin")` + 一行诊断。
 *   ★认版本只认**字节数+md5**，别拿"里面有没有 LD_PRELOAD / /system/bin:/system/xbin 这些串"当判据：
 *     静态 bionic 自己就带这两个串(v2 里各出现 1 次)，我差点把"1 次"当成"没编进去"(例51 的新形态)。
 *   ★v3 上机判据见 md §6.226/#111：执法态下**不带 `LD_PRELOAD=` 前缀**直接 `su -c id` 要出 uid=0。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>          /* dv() 用 va_list（本机 NDK 不会由别的头替我们带进来） */
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <dirent.h>        /* find_driver_fd(): 扫 /proc/self/fd（§6.217/#104） */
#include <stdbool.h>       /* supercall.h 里的 uapi 结构用 bool，但它自己不 include */
#include "../kmod/uapi/supercall.h"

#define SOCKNAME "suwshd"          /* shd.c: #define UNIXNAME "suwshd"（abstract） */
/* ★v4(#117 那格的第二把生产者，§6.351/runbook §73)：以前 exec 目标是**编译期常量** ⇒
 *   形状词「exec app 自己的静态壳」在工具链里没有任何实现动作，只能重编一支新的才对。
 *   现在：`SU_SHBIN`(env) > `/data/local/tmp/ksu_shbin`(设备侧文件，一行) > 默认 `/system/bin/sh`。
 *   ★两个都不给 ⇒ 目标逐字还是老那个，**交付形状不变**；解析结果**无条件**打进 stderr(不是 dv)，
 *   这样"没提权也跑得动"的那一类 0 枪读数才拿得到(入口证人之外再给一条仪器自证)。 */
#define DEF_SHBIN "/system/bin/sh"
#define SHBIN_FILE "/data/local/tmp/ksu_shbin"

/* #192：`su -v` 的回话。**故意做成 Magisk 那种 `<版本>:<码>` 开头**——app 常用正则从行首取版本，
 *   纯文字串会让它解析失败(＝又一个"没有 root")；但冒号后面紧跟的是**我们自己那一句**，
 *   不冒充 Magisk/KSU 的版本号(那是假话，也是最容易被识破的假话)。 */
#define SUW_VERSION_STRING "1.0:1 suw-su (KernelSU LKM 静态 su 客户端；不是 Magisk，无 mount-master)"

static char shbin[128] = DEF_SHBIN;

/* 只收"看着像绝对路径、没有空格/控制字节"的串：宁可退回默认并明说，也不要静默换形状(例 116) */
static int shbin_ok(const char *s)
{
    size_t i, n = strlen(s);

    if (n < 2 || n >= sizeof(shbin) || s[0] != '/')
        return 0;
    for (i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)s[i];

        if (ch <= ' ' || ch == 0x7f || ch == '"' || ch == '\'' || ch == '\\' || ch == '`' || ch == '$')
            return 0;
    }
    return 1;
}

static void resolve_shbin(void)
{
    char buf[256];
    const char *from = "默认";
    int kind = 0;   /* 0=没开关 1=env 2=设备侧文件(文案要与状态同源，别用串首字节猜) */
    FILE *f;
    size_t n;

    buf[0] = 0;
    if (getenv("SU_SHBIN") && *getenv("SU_SHBIN")) {
        strncpy(buf, getenv("SU_SHBIN"), sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = 0;
        from = "env SU_SHBIN";
        kind = 1;
    } else if ((f = fopen(SHBIN_FILE, "r")) != NULL) {
        if (!fgets(buf, sizeof(buf), f))
            buf[0] = 0;
        fclose(f);
        from = "文件 " SHBIN_FILE;
        kind = 2;
    }
    n = strlen(buf);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
        buf[--n] = 0;

    if (buf[0] && shbin_ok(buf)) {
        strcpy(shbin, buf);
    } else if (buf[0]) {
        fprintf(stderr, "su: 开关里的 shbin=[%s] 不合格(要绝对路径、无空格/引号) ⇒ **退回默认 " DEF_SHBIN "**\n",
                buf);
        from = "退回默认(开关被拒)";
    } else if (kind != 0) {
        /* 开关在、但是空(半截开关)：不许让"来源"写着文件而目标却是默认——文案要与状态同源 */
        from = "开关为空⇒退回默认";
    }
    /* v6(#210)：这一行**不该每次都打**——真 su 从不往 stderr 吐常规信息，而 app 侧有两类形状会被它伤到
     *   ("把 stderr 当错误显示"、"按行首正则取版本")，一手见 md §6.451 的 v5 热换读数。
     *   要它只有一条：`SUW_SU_DEBUG=1`／`SUW_SHBIN_WITNESS=1`(仪器要的"0 枪也要看得见来源")。
     *   上面那条"开关里的串不合格"**保持无条件**——那是异常，不是常规留痕。 */
    if (getenv("SUW_SU_DEBUG") || getenv("SUW_SHBIN_WITNESS")) {
        fprintf(stderr, "su: shbin=[%s] 来源=%s\n", shbin, from);
        fflush(stderr);
    }
}

static int dbg = 0;
static void dv(const char *fmt, ...)
{
    va_list ap;

    if (!dbg)
        return;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* abstract namespace：sun_path[0]=0，名字从 [1] 开始（与 shd.c 服务端同一套） */
static int connect_agent(void)
{
    struct sockaddr_un u;
    int fd;

    memset(&u, 0, sizeof(u));
    u.sun_family = AF_UNIX;
    u.sun_path[0] = 0;
    strncpy(u.sun_path + 1, SOCKNAME, sizeof(u.sun_path) - 2);

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "su: socket 失败 errno=%d(%s)\n", errno, strerror(errno));
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&u, offsetof(struct sockaddr_un, sun_path) + 1 + strlen(SOCKNAME)) < 0) {
        fprintf(stderr, "su: 连 @%s 失败 errno=%d(%s) ⇒ root agent(shd) 没在跑?\n", SOCKNAME, errno,
                strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int read_line(int fd, char *buf, size_t n)
{
    size_t i = 0;

    while (i + 1 < n) {
        char c;
        ssize_t r = read(fd, &c, 1);

        if (r <= 0)
            break;
        buf[i++] = c;
        if (c == '\n')
            break;
    }
    buf[i] = 0;
    return (int)i;
}

/* 收一个带 SCM_RIGHTS 的报文：返回 fd（没有则 -1），并把随行的文字留在 line 里 */
static int recv_fd(int c, char *line, size_t ln)
{
    struct msghdr msg;
    struct iovec iov;
    char iobuf[CMSG_SPACE(sizeof(int))];
    char data[256];
    struct cmsghdr *cm;
    int fd = -1;
    ssize_t n;

    memset(&msg, 0, sizeof(msg));
    memset(iobuf, 0, sizeof(iobuf));
    iov.iov_base = data;
    iov.iov_len = sizeof(data) - 1;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = iobuf;
    msg.msg_controllen = sizeof(iobuf);

    n = recvmsg(c, &msg, 0);
    if (n <= 0) {
        fprintf(stderr, "su: recvmsg 失败 n=%zd errno=%d(%s)\n", n, errno, strerror(errno));
        return -1;
    }
    data[n] = 0;
    snprintf(line, ln, "%s", data);
    for (cm = CMSG_FIRSTHDR(&msg); cm != NULL; cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS &&
            cm->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(&fd, CMSG_DATA(cm), sizeof(int));
            break;
        }
    }
    return fd;
}

/* 扫自己的 /proc/self/fd 找内核塞进来的驱动 fd（标签里带 `ksu_driver`；§6.111② 一手印过
 *   `SHIM-FD 3 -> anon_inode:[ksu_driver]`）。**不依赖任何 socket** ⇒ 执法态下唯一还能走的那条。 */
static int find_driver_fd(void)
{
    DIR *d = opendir("/proc/self/fd");
    struct dirent *e;
    char path[64], tgt[256];
    ssize_t n;

    if (!d)
        return -1;
    for (e = readdir(d); e != NULL; e = readdir(d)) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        snprintf(path, sizeof(path), "/proc/self/fd/%s", e->d_name);
        n = readlink(path, tgt, sizeof(tgt) - 1);
        if (n <= 0)
            continue;
        tgt[n] = 0;
        if (strstr(tgt, "ksu_driver")) {
            int fd = atoi(e->d_name);

            closedir(d);
            return fd;
        }
    }
    closedir(d);
    return -1;
}

/* ==== #192：su 的参数契约（一手缺口在 md §6.431：Scene 这类 app 调 `su -v`／`su -M -c …`／`su 1000 -c …`，
 *   而旧形状把不认识的参数**原样丢给 sh** ⇒ 设备实测(0 枪)：`sh -M -c id` 报 `-M: unknown option`(id 根本没跑)、
 *   `sh -v` 空输出、`sh 1000 -c id` 把 1000 当脚本文件。⇒ 这里只**认参数**，一步提权判定都没放宽。
 * 三条口径：
 *   ①`-v/--version` 只问"这个 su 是什么" ⇒ 回一串**说实话**的版本并 rc=0，**不碰 fd／不连 agent／不提权**
 *     （这一支与 `--suw-args` 因此都能在 0 枪、没窗、没 root 的设备上双向验收）。
 *   ②我们没有 master mount namespace、不会切 secontext、不会挑 gid/组 ⇒ 这些参数**接受并忽略(no-op)**；
 *     报错在 app 那边等于"没有 root"，所以"能吃不报错"才是对的形状——但**绝不假装做成了**（SUWNOOP 逐条打出来）。
 *   ③前导 uid（`su 1000 -c X`／`su root -c X`）认得出来，但**不冒充那个身份**：提权仍只按调用者自己的 uid 判。 */
struct suw_plan {
    char *cmd;              /* -c 的载荷；NULL=没有 */
    char *script;           /* 裸的非选项参数(旧形状里当脚本文件喂 sh)；只在没有 -c 时才用 */
    int version_only;       /* -v/--version：只问"这个 su 是什么" */
    long req_uid;           /* 前导 uid；-1=没要求；root=0 */
    int n_joined;           /* v6(#210)：把几段 argv 拼成了一条命令；1=没拼(老形状) */
    int n_noop, n_unknown;
    const char *noop[12];
    const char *unknown[12];
    const char *bad;        /* 非 NULL=形状本身说不通(例如 -c 后面没有载荷) */
};

/* v6(#210)：Magisk 的 `su -c ls -l /x` 与 `su 0 id` 里，载荷是**跨多个 argv** 的一条命令。
 * 这里只做拼接，不碰任何提权判定；拼接只在拼出来的东西仍然是一行命令时才有意义。 */
static char suw_joinbuf[4096];

static char *suw_join(char *const *av, int n, int *used)
{
    size_t off = 0;
    int i;

    if (n <= 0)
        return NULL;
    for (i = 0; i < n; i++) {
        size_t l = strlen(av[i]);

        if (off + l + 1 >= sizeof(suw_joinbuf))
            return NULL;
        if (i)
            suw_joinbuf[off++] = ' ';
        memcpy(suw_joinbuf + off, av[i], l);
        off += l;
    }
    suw_joinbuf[off] = 0;
    if (used)
        *used = n;
    return suw_joinbuf;
}

/* 这些选项在 Magisk/上游 su 里**带一个值**；我们要么照做(-c)，要么把它连同值一起吃掉 */
static int suw_opt_takes_value(const char *a)
{
    static const char *const t[] = {
        "-Z", "--context", "-z", "-g", "-G", "-t", "-s", "--shell", "-d", "-e",
        "-p", "-r", "-u", "-x", NULL
    };
    int i;

    for (i = 0; t[i]; i++)
        if (!strcmp(a, t[i]))
            return 1;
    return 0;
}

/* 这些选项我们**接受并忽略**(不带货；`-v/--version` 单独在 parse 里处理) */
static int suw_opt_noop(const char *a)
{
    static const char *const t[] = {
        "-M", "--mount-master", "-m", "-l", "--login", "-i", "-w", "-k", "-L", "--pty", NULL
    };
    int i;

    for (i = 0; t[i]; i++)
        if (!strcmp(a, t[i]))
            return 1;
    return 0;
}

static long suw_uid_word(const char *a)
{
    size_t i, n = strlen(a);

    if (!strcmp(a, "root"))
        return 0;
    if (!n || n > 10)
        return -1;
    for (i = 0; i < n; i++)
        if (a[i] < '0' || a[i] > '9')
            return -1;
    return strtol(a, NULL, 10);
}

static void suw_plan_init(struct suw_plan *p)
{
    memset(p, 0, sizeof(*p));
    p->req_uid = -1;
}

/* 纯函数：不碰 syscall、不碰 env ⇒ 同一份源码在设备(--suw-args)与宿主真值表上跑得出同样形状 */
static int parse_su_args(int argc, char **argv, struct suw_plan *p)
{
    int i;

    for (i = 1; i < argc; i++) {
        char *a = argv[i];

        if (!strcmp(a, "-c") || !strcmp(a, "--command")) {
            if (i + 1 >= argc) {
                p->bad = "-c 后面没有载荷";
                return -1;
            }
            /* ★只吃**一个** argv——这是 Magisk/AOSP su 的真实契约(`sh -c cmd arg0 arg1`，后面的掉进 $0/$1)，
             *   不是我一开始以为的"拼成一条"(§6.451 那条 v5 读数我读错了语义：`su -c ls -l /x` 只跑 `ls`
             *   就是上游行为，不是我们的缺口)。真要把多词当一条命令，调用方自己加引号(实测两版都通)。 */
            p->cmd = argv[++i];
            p->n_joined = 1;
            continue;
        }
        if (!strcmp(a, "-v") || !strcmp(a, "--version")) {
            p->version_only = 1;
            continue;
        }
        if (!strcmp(a, "--")) {                      /* 之后的都当载荷，不再当选项 */
            if (i + 1 < argc && !p->cmd && !p->script)
                p->script = argv[i + 1];
            break;
        }
        if (suw_opt_takes_value(a)) {                /* 我们不实现的带值选项：连值一起吃掉 */
            if (p->n_noop < 12)
                p->noop[p->n_noop++] = a;
            if (i + 1 < argc)
                i++;
            continue;
        }
        if (suw_opt_noop(a)) {
            if (p->n_noop < 12)
                p->noop[p->n_noop++] = a;
            continue;
        }
        if (a[0] == '-') {                           /* 认不出的选项：忽略并记名，**不报错** */
            if (p->n_unknown < 12)
                p->unknown[p->n_unknown++] = a;
            continue;
        }
        if (p->req_uid < 0) {                        /* 第一个非选项＝Magisk 语义里的目标 uid */
            long u = suw_uid_word(a);

            if (u >= 0) {
                p->req_uid = u;
                continue;
            }
        }
        if (p->req_uid >= 0 && !p->cmd && !p->script) {
            /* v6(#210)：`su 0 id`／`su root ls -l /x`——uid 之后剩下的**全部**当一条命令。
             *   旧形状在这里把 `id` 当成"要喂给 sh 的脚本文件" ⇒ 实测 `sh: id: No such file`(§6.451)。
             *   没有前导 uid 时**不动**这条(保留 `su /path/x.sh` 喂文件的旧形状，交付腿还在用)。 */
            p->cmd = suw_join(&argv[i], argc - i, &p->n_joined);
            if (!p->cmd) {
                p->bad = "载荷过长(>4095B)";
                return -1;
            }
            i = argc;
            continue;
        }
        if (!p->script)
            p->script = a;                           /* 旧形状：非选项就当脚本文件喂 sh */
    }
    return 0;
}

static void suw_plan_print(const struct suw_plan *p)
{
    int i;

    printf("SUWARGS version=%d cmd=%s script=%s req_uid=%ld joined=%d noop=%d unknown=%d bad=%s plan=%s\n",
           p->version_only, p->cmd ? p->cmd : "<none>", p->script ? p->script : "<none>",
           p->req_uid, p->n_joined, p->n_noop, p->n_unknown, p->bad ? p->bad : "<none>",
           p->version_only ? "print-version-and-exit"
                           : (p->cmd ? "elevate+sh -c <cmd>"
                                     : (p->script ? "elevate+sh <script>" : "elevate+sh(interactive)")));
    for (i = 0; i < p->n_noop; i++)
        printf("SUWNOOP %s\n", p->noop[i]);
    for (i = 0; i < p->n_unknown; i++)
        printf("SUWUNKNOWN %s\n", p->unknown[i]);
    if (p->req_uid >= 0)
        printf("SUWREQUID %ld 不冒充(提权只按调用者自己的 uid 判)\n", p->req_uid);
}

int main(int argc, char **argv)
{
    char line[512];
    struct suw_plan plan;
    int c, fd;
    long r;

    dbg = getenv("SUW_SU_DEBUG") != NULL;
    if (argc > 1 && strcmp(argv[1], "--suw-dump") == 0) {
        printf("su(suw) uid=%u euid=%u pid=%d\n", (unsigned)getuid(), (unsigned)geteuid(),
               (int)getpid());
        return 0;
    }
    /* ★0 枪那一支：把"我这串 argv 被解析成什么形状"打出来就走——排在所有会失败的腿之前，
     *   所以**没有 ko、没有窗、没有 root** 也读得到(入口证人之外再给一条仪器自证)。 */
    if (argc > 1 && strcmp(argv[1], "--suw-args") == 0) {
        suw_plan_init(&plan);
        parse_su_args(argc - 1, argv + 1, &plan);    /* 摘掉 --suw-args 自己，剩下的就是 app 给的那串 */
        suw_plan_print(&plan);
        return plan.bad ? 1 : 0;
    }
    suw_plan_init(&plan);
    if (parse_su_args(argc, argv, &plan) != 0) {
        fprintf(stderr, "su: %s\n", plan.bad);
        return 1;
    }
    if (plan.n_noop || plan.n_unknown)
        dv("suw-args 吃了 %d 条 no-op 选项、%d 条认不出的选项(都忽略，不报错)", plan.n_noop, plan.n_unknown);
    if (plan.req_uid >= 0)
        dv("app 要求的 uid=%ld(调用者自己 uid=%u) ⇒ **不冒充**，提权判定只按调用者", plan.req_uid,
           (unsigned)getuid());
    /* `su -v`/`su --version` 只是问版本(Magisk 语义)：早退，不碰 fd／agent／ioctl */
    if (plan.version_only) {
        printf("%s\n", SUW_VERSION_STRING);
        return 0;
    }
    /* v4：目标解析**无条件**留痕，且排在所有会失败的腿之前 ⇒ 没 root 也打得出来，
     *    这一支的开关能不能用、退没退回默认，0 枪(不 insmod、不开窗)就能双向验收。 */
    resolve_shbin();

    /* 顺序换过来的理由(§6.217/#104)：执法态下 app→root 的 abstract socket **必被拒** ——
     *   这台机真生效的两份 CIL 里没有一条允许 `domain connectto shell:unix_stream_socket`
     *   (上游是靠 `kernel/selinux/rules.c:133~137` 现场注进去的，还得给目标类型打
     *    `mlstrustedobject`(:95) 才过得了 MLS)，而我们的构建里
     *   `kernel/selinux/dropped_stub.c::handle_sepolicy()` 直接返回 `-EOPNOTSUPP` ⇒ **补不了规则**。
     *   所以能走的那条只能是"内核已经把驱动 fd 塞进这个进程" ⇒ 先扫自己，扫不到再问 agent。 */
    fd = find_driver_fd();
    if (fd >= 0)
        dv("自己扫到驱动 fd=%d(没走 agent)", fd);

    if (fd < 0) {
        c = connect_agent();
        if (c < 0) {
            fprintf(stderr,
                    "su: 既没有内核塞进来的驱动 fd，也连不上 @suwshd(errno=%d %s) ⇒ 执法态下这两条都需要策略放行，见 §6.217\n",
                    errno, strerror(errno));
            return 1;
        }
        if (read_line(c, line, sizeof(line)) <= 0 || strncmp(line, "OK", 2) != 0) {
            fprintf(stderr, "su: agent 拒绝: %s", line);
            close(c);
            return 1;
        }
        dv("agent: %s", line);

        if (write(c, "KSUFD\n", 6) != 6) {
            fprintf(stderr, "su: 发 KSUFD 失败 errno=%d(%s)\n", errno, strerror(errno));
            close(c);
            return 1;
        }
        fd = recv_fd(c, line, sizeof(line));
        dv("KSUFD 回: %s fd=%d", line, fd);
        close(c);
        if (fd < 0) {
            fprintf(stderr, "su: 没收到驱动 fd(%s) ⇒ agent 自己也没 fd，或名单没落到这个 uid\n", line);
            return 1;
        }
    }

    r = ioctl(fd, KSU_IOCTL_GRANT_ROOT, NULL);
    dv("ioctl(GRANT_ROOT fd=%d) ret=%ld errno=%d(%s) uid后=%u", fd, r, errno, strerror(errno),
       (unsigned)getuid());
    /* ★自证：不看 ret，只看自己的 uid —— 这是本项目一贯的口径(ret=0 不等于真执行过) */
    if (getuid() != 0) {
        fprintf(stderr, "su: 提权失败 uid=%u ioctl ret=%ld errno=%d(%s)\n", (unsigned)getuid(), r,
                errno, strerror(errno));
        close(fd);
        return 1;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);   /* 别把驱动 fd 带进 root shell */

    /* argv 语义(#192)：一律由 parse_su_args 给形状，**不再把认不出的选项透传给 sh**
     *   （旧写法：`su -M -c id` ⇒ `sh -M -c id` ⇒ `-M: unknown option`，`id` 根本没跑，见 md §6.431）
     *   `su -c CMD` ⇒ `sh -c CMD`；`su <脚本>` ⇒ `sh <脚本>`；`su`/`su -M` ⇒ `sh`(交互，stdin 原样交出去) */
    {
        char **av = calloc(4, sizeof(char *));

        if (!av)
            return 10;
        av[0] = (char *)"sh";
        if (plan.cmd) {
            av[1] = (char *)"-c";
            av[2] = plan.cmd;
        } else if (plan.script) {
            av[1] = plan.script;
        } else {
            /* 交互/管道那一格(KeepShell、Scene 的长根壳靠它)：av 只有 {"sh",NULL}，
             *   stdin 不改编成 sh ⇒ 命令一条条从管道进来。旧注释说"不带 -c 时零输出、rc=1 还没定位"
             *   ⇒ 这里把当时看到的形状无条件打出来，下次真窗一眼能分开"没跑"与"跑了没输出"。 */
            dv("交互形状 isatty(0)=%d argc=%d 剩下没被吃的参数=%d 条", isatty(0), argc, plan.n_unknown);
        }
        /* v3(#111/§6.223⑥)：Termux 的 env 带 `LD_PRELOAD=…/files/usr/lib/libtermux-exec.so`，
     *   而提权后的壳(`u:r:shell:s0`)在**执法下**读不到那个 app 私有目录里的 .so ⇒ linker 报
     *   `CANNOT LINK EXECUTABLE "sh"`(一手读数在 §6.223④，那格不是 SELinux 拦的 exec，是子进程的链接)。
     *   交付形态不该要求用户手打 `LD_PRELOAD=` 前缀 ⇒ exec 之前把它摘掉。 */
    /* v3(#111/§6.225⑤)：两条"壳继承了 app 的环境"的坑，一次修掉。
     *   ① LD_PRELOAD：Termux 的 env 带 `…/files/usr/lib/libtermux-exec.so`，提权后的壳(`u:r:shell:s0`)
     *      执法下读不到那个私有 .so ⇒ `CANNOT LINK EXECUTABLE "sh"`(§6.223④，不是 SELinux 拦 exec)。
     *   ② PATH：同样继承 app 私有目录，执法下 `shell` 域 stat 不了 `/data/data/com.termux/…`
     *      ⇒ 一手读数 `sh: <stdin>[1]: id: inaccessible or not found`(§6.225⑤) —— 命令明明在 /system/bin。
     *   ⇒ 交付形态不该要求用户手打 `LD_PRELOAD=` 前缀，也不该让壳带着读不到的 PATH。 */
    if (getenv("LD_PRELOAD")) {
        dv("摘掉 LD_PRELOAD=[%s]", getenv("LD_PRELOAD"));
        unsetenv("LD_PRELOAD");
    }
    setenv("PATH", "/system/bin:/system/xbin", 1);
    /* 交互壳那一格(不带 -c 时零输出、rc=1)还没定位 ⇒ 先把"我当时打算干什么"打出来(例59)。 */
    dv("exec %s argv0=sh argc=%d isatty(0)=%d uid=%u PATH=%s", shbin, argc, isatty(0),
       (unsigned)getuid(), getenv("PATH"));
    execv(shbin, av);
        fprintf(stderr, "su: execv(%s) 失败 errno=%d(%s)\n", shbin, errno, strerror(errno));
        return 127;
    }
}
