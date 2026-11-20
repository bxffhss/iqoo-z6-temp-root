import io
import sys

NL = chr(10)
QT = chr(34)
BS = chr(92)
BR = BS + "n" + QT  # 反斜杠 n 在引号**内**，再闭合字符串


def sub_or_die(s, old, new, tag):
    n = s.count(old)
    if n != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, n))
    print("ok [%s]" % tag)
    return s.replace(old, new)


P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()

if "cmd_supath" in s:
    print("ksuctl 已经有 supath ⇒ 跳过")
    sys.exit(0)

T = []   # 一行一条，最后 join 成 C 源码
T.append("static int cmd_supath(int argc, char **argv)")
T.append("{")
T.append("\t/* ★为什么非要有这个动词(第二十二发的教训，md §6.124②)：")
T.append("\t *   cmd_su 写死 execve(\"/system/bin/su\", ...)，而我们 ko 的 execve 钩子(bit1)是在")
T.append("\t *   **路径解析之前**把它改道到 ksu_ksud_path 的 ⇒ /system/bin/su 这个文件**根本不存在**")
T.append("\t *   的时候 cmd_su 照样出 uid=0(root)。第二十二发 (a′) 那格\"挂载前必须失败\"就是这么废的：")
T.append("\t *   回执里明明印着 `ls: /system/bin/su: No such file`，同一段却出了 root。")
T.append("\t *   ⇒ 拿 cmd_su 当\"su 可见性\"的判据 = 假阳性。")
T.append("\t * 这个动词只做一件事：fork → 降到 <uid> → **execvp(按 PATH 找)**。不碰 ioctl、不碰驱动")
T.append("\t *   fd、不改任何标位 ⇒ 它和真 app 手敲 `su` 是同一条链：PATH 里没有就是 ENOENT。")
T.append("\t *   只要 <名字> 解析出来不等于 /system/bin/su，钩子就不插手，测到的就是\"文件在不在\"。")
T.append("\t * ★它测不了的那半格：起点域是 root 侧(不是 untrusted_app)，所以 app 域那半仍要靠")
T.append("\t *   suw app 的 @suprobe: 来证。两者合起来才是完整判据。")
T.append("\t * 用法: ksuctl supath <uid> <PATH> <名字> [参数...]")
T.append("\t */")
T.append("\tif (argc < 5) {")
T.append("\t\tfprintf(stderr, " + QT + "用法: ksuctl supath <uid> <PATH> <名字> [参数...]" + BR + ");")
T.append("\t\treturn 2;")
T.append("\t}")
T.append("\tlong uid = strtol(argv[2], NULL, 0);")
T.append("\tint p[2];")
T.append("\tif (pipe(p)) {")
T.append("\t\tperror(" + QT + "supath: pipe" + QT + ");")
T.append("\t\treturn 1;")
T.append("\t}")
T.append("\tpid_t pid = fork();")
T.append("\tif (pid == 0) {")
T.append("\t\tdup2(p[1], 1);")
T.append("\t\tdup2(p[1], 2);")
T.append("\t\tclose(p[0]);")
T.append("\t\tclose(p[1]);")
T.append("\t\tif (setgroups(0, NULL) && getuid() == 0)")
T.append("\t\t\tfprintf(stderr, " + QT + "supath: setgroups 失败 errno=%d(%s)" + BR + ", errno, strerror(errno));")
T.append("\t\tif (setgid((gid_t)uid) || setuid((gid_t)uid)) {")
T.append("\t\t\tfprintf(stderr, " + QT + "supath: 降到 %ld 失败 errno=%d(%s)" + BR + ", uid, errno, strerror(errno));")
T.append("\t\t\t_exit(127);")
T.append("\t\t}")
T.append("\t\tsetenv(" + QT + "PATH" + QT + ", argv[3], 1);")
T.append("\t\t{")
T.append("\t\t\t/* 起点身份先印出来：uid/域不对，后面所有结论都不算 */")
T.append("\t\t\tchar ctx[128];")
T.append("\t\t\tint c = open(" + QT + "/proc/self/attr/current" + QT + ", O_RDONLY);")
T.append("\t\t\tint cn = c < 0 ? 0 : (int)read(c, ctx, sizeof(ctx) - 1);")
T.append("\t\t\tif (cn > 0) ctx[cn] = 0;")
T.append("\t\t\telse ctx[0] = 0;")
T.append("\t\t\tif (c >= 0) close(c);")
T.append("\t\t\tfprintf(stderr, " + QT + "SUPATH-START uid=%u euid=%u gid=%u PATH=[%s] ctx=%s" + BR + ",")
T.append("\t\t\t\tgetuid(), geteuid(), getgid(), argv[3], ctx);")
T.append("\t\t\tfflush(stderr);")
T.append("\t\t}")
T.append("\t\tchar **av = &argv[4];")
T.append("\t\texecvp(av[0], av);")
T.append("\t\tfprintf(stderr, " + QT + "SUPATH-EXECVP-FAIL name=[%s] errno=%d(%s)" + BR + ", av[0], errno,")
T.append("\t\t\tstrerror(errno));")
T.append("\t\tfflush(stderr);")
T.append("\t\t_exit(126);")
T.append("\t}")
T.append("\tclose(p[1]);")
T.append("\tchar buf[512];")
T.append("\tssize_t r;")
T.append("\tprintf(" + QT + "---- supath(uid=%ld) 输出开始 ----" + BR + ", uid);")
T.append("\twhile ((r = read(p[0], buf, sizeof(buf))) > 0)")
T.append("\t\tfwrite(buf, 1, (size_t)r, stdout);")
T.append("\tprintf(" + QT + "---- 输出结束 (read errno=%d) ----" + BR + ", errno);")
T.append("\tclose(p[0]);")
T.append("\tint st = 0;")
T.append("\twaitpid(pid, &st, 0);")
T.append("\tprintf(" + QT + "SUPATH-WAIT exit=%d signal=%d" + BR + ",")
T.append("\t\tWIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0);")
T.append("\treturn 0;")
T.append("}")
T.append("")
NEWFN = NL.join(T) + NL

s = sub_or_die(
    s,
    "static int cmd_sumark(int argc, char **argv)" + NL + "{",
    NEWFN + "static int cmd_sumark(int argc, char **argv)" + NL + "{",
    "插入 cmd_supath",
)

s = sub_or_die(
    s,
    NL + "	if (!strcmp(argv[1], " + QT + "sumark" + QT + "))",
    NL + "	if (!strcmp(argv[1], " + QT + "supath" + QT + "))" + NL + "		return cmd_supath(argc, argv);" +
    NL + "	if (!strcmp(argv[1], " + QT + "sumark" + QT + "))",
    "派发 supath",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("已写入", P)
