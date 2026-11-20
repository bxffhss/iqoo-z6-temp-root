import io
import sys

NL = chr(10)
BS = chr(92)
QT = chr(34)

# ── 1) 守护侧：读输出 + 等子进程都要有截止时间，卡住也不能把守护拖死 ──────────
P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()
if "KSU_SUSHD_DEADLINE" in s:
    print("ksuctl 已经有超时 ⇒ 跳过")
else:
    old = (
        "\t\tksu_read_all(sv[0], out, sizeof(out));" + NL
        + "\t\tclose(sv[0]);" + NL
        + "\t\twaitpid(kid, &st, 0);" + NL
    )
    if s.count(old) != 1:
        sys.exit("ksuctl anchor count=%d" % s.count(old))
    new = (
        "\t\tksu_read_all(sv[0], out, sizeof(out));" + NL
        + "\t\tclose(sv[0]);" + NL
        + "\t\t/* ★必须有截止时间：第六十四发那台机器正是在这一步之后复位的，" + NL
        + "\t\t *   而 waitpid(0) 是无限等 —— 命令挂住就把整个守护拖死，下一个请求都进不来。 */" + NL
        + "\t\t{" + NL
        + "\t\t\tint t;" + NL
        + "\t\t\tfor (t = 0; t < 100; t++) {" + NL
        + "\t\t\t\tif (waitpid(kid, &st, WNOHANG) == kid)" + NL
        + "\t\t\t\t\tbreak;" + NL
        + "\t\t\t\tusleep(100000);" + NL
        + "\t\t\t}" + NL
        + "\t\t\tif (t >= 100) {" + NL
        + "\t\t\t\tkill(kid, SIGKILL);" + NL
        + "\t\t\t\twaitpid(kid, &st, 0);" + NL
        + "\t\t\t\tstrncat(out, " + QT + "(sushd: 命令超时 10s，已 SIGKILL)" + QT + ", sizeof(out) - strlen(out) - 1);" + NL
        + "\t\t\t}" + NL
        + "\t\t}" + NL
    )
    s = s.replace(old, new)
    s = s.replace("#define KSU_SUSHD_PATH", "#define KSU_SUSHD_DEADLINE 100   /* 等子进程的轮询次数(×100ms) */" + NL + "#define KSU_SUSHD_PATH")
    if "#include <signal.h>" not in s:
        s = s.replace("#include <errno.h>" + NL, "#include <errno.h>" + NL + "#include <signal.h>" + NL, 1)
    io.open(P, "w", encoding="utf-8", newline="").write(s)
    print("ksuctl：waitpid 已加 10s 截止")

# ── 2) 驱动器：把守护代跑挪到最前面（窗口只有几分钟，别让它排在最后） ──────────
P2 = "kmod/run_app_window.sh"
t = io.open(P2, encoding="utf-8").read()
i = t.find('say "④c 第三发')
if i < 0:
    sys.exit("找不到 ④c 段")
j = t.find('S "touch /data/local/tmp/ksu_dump_now"', i)
if j < 0:
    sys.exit("找不到 ④c 段结尾")
blk = t[i:j]
t = t[:i] + t[j:]
blk = blk.replace('say "④c 第三发：让 root 侧守护代跑', 'say "②b 先跑 root 侧守护代跑(窗口只有几分钟，这一格才是交付物，排最前')
# 守护是 root 侧脚本在 insmod 之后几十秒才起来的 ⇒ 必须先等它"在听"，不能凭时序猜
blk = (
    'say "   等 root 侧守护起来(它由 stage 脚本在 insmod 之后拉起，上限 150s)"' + NL
    + "z=0" + NL
    + "while [ $z -lt 75 ]; do" + NL
    + "    S 'grep -c \"在听 @suwksu\" /data/local/tmp/sushd.log 2>/dev/null' | tr -d "
    + chr(39) + "\r" + chr(39) + " | grep -qv '^0$' && break" + NL
    + "    sleep 2" + NL
    + "    z=$((z + 1))" + NL
    + "done" + NL
    + 'say "   等了 $((z * 2))s"' + NL
    + blk
)
anchor2 = 'say "② 负对照'
k = t.find(anchor2)
if k < 0:
    sys.exit("找不到 ② 锚点")
t = t[:k] + blk + t[k:]
io.open(P2, "w", encoding="utf-8", newline="").write(t)
print("driver：守护代跑已挪到最前")
