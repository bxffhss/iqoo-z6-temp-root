import io
import sys

NL = chr(10)
QT = chr(34)
BS = chr(92)

# ── 1) 守护：回完要留一行回执 ────────────────────────────────────────────
P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()
old = NL.join(["\t\tfflush(stderr);", "\t\tclose(cl);", "\t}", "\treturn 0;", "}"]) + NL
if s.count(old) != 1:
    sys.exit("ksuctl anchor count=%d" % s.count(old))
if "sushd: 已回给" in s:
    print("回执行已存在 ⇒ 跳过")
else:
    new_lines = [
        "\t\tfflush(stderr);",
        "\t\t/* ★回执行：没有这一行，" + QT + "守护日志里没下文" + QT + "分不清是卡住还是正常回完了",
        "\t\t *   (第六十五发就是这么把自己读成失败的)。 */",
        "\t\tfprintf(stderr, " + QT + "sushd: 已回给 uid=%u 输出 %zu 字节 exit=%d%s" + BS + "n" + QT + ",",
        "\t\t\t(unsigned)uc.uid, strlen(out),",
        "\t\t\tWIFEXITED(st) ? WEXITSTATUS(st) : -1,",
        "\t\t\tout[0] ? " + QT + "(有输出)" + QT + " : " + QT + "(空)" + QT + ");",
        "\t\tfflush(stderr);",
        "\t\tclose(cl);",
        "\t}",
        "\treturn 0;",
        "}",
    ]
    s = s.replace(old, NL.join(new_lines) + NL)
    io.open(P, "w", encoding="utf-8", newline="").write(s)
    print("ksuctl：加了回执行")

# ── 2) 驱动器：②b 之后等够再读 ──────────────────────────────────────────
P2 = "kmod/run_app_window.sh"
t = io.open(P2, encoding="utf-8").read()
old2 = "sleep 9" + NL + 'S "cat $REPORT" > "$OUTDIR/app_sushd.txt" 2>&1'
if t.count(old2) != 1:
    sys.exit("driver anchor count=%d" % t.count(old2))
if "sleep 35" in t:
    print("driver 已改过 ⇒ 跳过")
else:
    new2 = (
        "# ★必须等够再读：报告文件每次触发都是 O_TRUNC 重写的 ⇒ 这一格读晚了会被后面几发覆盖，"
        + NL
        + "#   读早了又看不见守护的回执(守护那边最坏 8s 读 + 10s 等子进程)。"
        + NL
        + "sleep 35"
        + NL
        + 'S "cat $REPORT" > "$OUTDIR/app_sushd.txt" 2>&1'
    )
    t = t.replace(old2, new2)
    io.open(P2, "w", encoding="utf-8", newline="").write(t)
    print("driver：②b 改成等 35s")
