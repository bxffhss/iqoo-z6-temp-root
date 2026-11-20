import io
import sys

NL = chr(10)
QT = chr(34)
BS = chr(92)


def sub_or_die(s, old, new, tag):
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    print("ok [%s]" % tag)
    return s.replace(old, new)


P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()

if "KSU 的 su 模型" in s and "sushd_pkg_path" in s:
    print("ksuctl 已经改过 v46 ⇒ 跳过")
else:
    # 1) 协议注释 + chown 需要的头
    s = sub_or_die(
        s,
        "#define KSU_SUSHD_DEADLINE 100",
        "#include <sys/stat.h>" + NL + "#include <signal.h>" + NL + NL + "#define KSU_SUSHD_DEADLINE 100",
        "chown 头",
    )
    s = sub_or_die(
        s,
        " * 协议(abstract unix @suwksu，一行一请求，一条连接一次问答)：" + NL
        + " *   收  " + QT + "RUN <token> <一行 shell 命令>" + QT + NL,
        " * 协议(abstract unix @suwksu，一行一请求，一条连接一次问答)：" + NL
        + " *   收  " + QT + "RUN <token> <包名> <一行 shell 命令>" + QT + NL
        + " *   ★包名是 v46 加的：输出要落到**发起者自己的私有目录**，app 只读文件就拿到结果。" + NL
        + " *     为什么不再靠 socket 读：客户端跑在 app 的 **UI 线程**上，第六十六/六十七发那两回" + NL
        + " *     `com.suw.manager` 的 memcg 正被强制回收 ⇒ 阻塞 read 的 UI 线程等不到回包" + NL
        + " *     (守护那边明明" + QT + "已回给 … 102 字节 exit=0" + QT + ")。判据不该挂在这种地方。" + NL,
        "协议注释",
    )

    # 2) 解析出包名
    s = sub_or_die(
        s,
        "\t\t*cmd++ = 0;" + NL + "\t\tif (strcmp(line + 4, tok) != 0) {",
        "\t\t*cmd++ = 0;" + NL
        + "\t\t/* v46：token 后面那一段是**发起者的包名**，再往后才是命令。 */" + NL
        + "\t\tpkg = strsep(&cmd, " + QT + " " + QT + ");" + NL
        + "\t\tif (!pkg || !pkg[0] || !cmd || !cmd[0]) {" + NL
        + "\t\t\tconst char *d = " + QT + "DENY 缺包名或命令(v46 起格式是 RUN <token> <pkg> <cmd>)" + BS + "n" + QT + ";" + NL
        + "\t\t\tif (write(cl, d, strlen(d)) < 0) { }" + NL
        + "\t\t\tclose(cl);" + NL
        + "\t\t\tcontinue;" + NL
        + "\t\t}" + NL
        + "\t\tif (strcmp(line + 4, tok) != 0) {",
        "解析包名",
    )

    # 3) 变量声明 + SIGPIPE
    s = sub_or_die(
        s,
        "\t\tchar *p, *cmd;" + NL,
        "\t\tchar *p, *cmd, *pkg;" + NL,
        "pkg 声明",
    )
    s = sub_or_die(
        s,
        "\tif (kfd < 0) {" + NL + "\t\tfprintf(stderr, " + QT + "sushd: 拿不到驱动 fd ⇒ 内核侧没就绪，起不来" + BS + "n" + QT + ");" + NL,
        "\t/* ★app 提前把连接关掉(它不该在 UI 线程上等)时，我们往 socket 里写会拿到 SIGPIPE ⇒" + NL
        + "\t *   默认动作是**整个守护被杀**。第五十九发那个" + QT + "守护突然不见了" + QT + "很可能就是这么没的。 */" + NL
        + "\tsignal(SIGPIPE, SIG_IGN);" + NL
        + "\tif (kfd < 0) {" + NL + "\t\tfprintf(stderr, " + QT + "sushd: 拿不到驱动 fd ⇒ 内核侧没就绪，起不来" + BS + "n" + QT + ");" + NL,
        "忽略 SIGPIPE",
    )

    # 4) 跑完之后：把输出落到发起者自己的私有目录
    anchor = NL.join([
        "\t\t/* ★判据不能只挂在 app 那条 socket 上：第六十六发守护确实回完了(102 字节、exit=0)，",
        "\t\t *   但 app 侧那一行没落进报告(当时 com.suw.manager 的 memcg 正被强制回收、UI 线程",
        "\t\t *   卡在 read 上) ⇒ 只靠 app 自报会把**成功**读成" + QT + "未知" + QT + "。",
        "\t\t *   所以把命令的输出再落一份到" + QT + "root 才写得动、shell 读得到" + QT + "的地方。 */",
    ])
    if s.count(anchor) != 1:
        sys.exit("ANCHOR FAIL [落盘注释] count=%d" % s.count(anchor))
    app_block = NL.join([
        "\t\t/* v46：再落一份到**发起者自己的私有目录** ⇒ app 只要 read() 一个本地文件就拿到结果，",
        "\t\t *   不再靠 UI 线程上那条阻塞的 socket。目录不存在就替它建(属主要给发起 uid，",
        "\t\t *   否则 app 自己反而进不去自己的 /data/data)。 */",
        "\t\tif (pkg[0] && strnlen(pkg, 128) < 128 && !strchr(pkg, " + QT + "/" + QT + ")) {",
        "\t\t\tchar dir[256], fp[320];",
        "\t\t\tstruct stat sb;",
        "",
        "\t\t\tsnprintf(dir, sizeof dir, " + QT + "/data/data/%s/files" + QT + ", pkg);",
        "\t\t\tsnprintf(fp, sizeof fp, " + QT + "/data/data/%s/files/sushd_out.txt" + QT + ", pkg);",
        "\t\t\tif (mkdir(dir, 0771) == 0) {",
        "\t\t\t\tchown(dir, (uid_t)uc.uid, (gid_t)uc.gid);",
        "\t\t\t\tfprintf(stderr, " + QT + "sushd: 替 %s 建了 %s(uid=%u)" + BS + "n" + QT + ", pkg, dir," + NL
        + "\t\t\t\t\t(unsigned)uc.uid);" + NL
        + "\t\t\t} else if (stat(dir, &sb) == 0 && sb.st_uid != (uid_t)uc.uid) {" + NL
        + "\t\t\t\tchown(dir, (uid_t)uc.uid, (gid_t)uc.gid);" + NL
        + "\t\t\t}" + NL
        + "\t\t\taf = open(fp, O_WRONLY | O_CREAT | O_TRUNC, 0666);" + NL
        + "\t\t\tif (af >= 0) {" + NL
        + "\t\t\t\t/* 文件属主也要给 app：创建者是 root，不给的话 app 只能读 0666 的权限位 */" + NL
        + "\t\t\t\tfchown(af, (uid_t)uc.uid, (gid_t)uc.gid);" + NL
        + "\t\t\t\tif (out[0] && write(af, out, strlen(out)) < 0) { }" + NL
        + "\t\t\t\tclose(af);" + NL
        + "\t\t\t\tfprintf(stderr, " + QT + "sushd: 输出已落 %s(%zu 字节) ⇒ app 读文件即可" + BS + "n" + QT + "," + NL
        + "\t\t\t\t\tfp, strlen(out));" + NL
        + "\t\t\t} else {" + NL
        + "\t\t\t\tfprintf(stderr, " + QT + "sushd: 落 %s 失败 errno=%d(%s)" + BS + "n" + QT + ", fp, errno," + NL
        + "\t\t\t\t\tstrerror(errno));" + NL
        + "\t\t\t}" + NL
        + "\t\t}" + NL
        + "\t\t/* 老地方也留一份(root 才写得动、shell 读得到)：判据不依赖 app 自报。 */",
    ])
    s = s.replace(anchor, anchor + NL + app_block)

    # 5) 循环里那几个局部变量
    s = sub_or_die(
        s,
        "\t\tstatic char line[1400], out[24576], rep[160];" + NL,
        "\t\tstatic char line[1400], out[24576], rep[160];" + NL + "\t\tint af;" + NL,
        "af 声明",
    )
    io.open(P, "w", encoding="utf-8", newline="").write(s)
    print("ksuctl v46：输出落到 app 私有目录 + 忽略 SIGPIPE")
