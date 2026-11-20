import io, sys

P = "kmod/run_app_window.sh"
s = io.open(P, encoding="utf-8").read()
NL = chr(10)


def sub(old, new, tag):
    global s
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    s = s.replace(old, new)
    print("ok [%s]" % tag)


sub(
    "    case \"$FIRST\" in *\"起点 v2\"*) ;; *) return 1;; esac",
    "    case \"$FIRST\" in *\"起点 v\"*) ;; *) return 1;; esac",
    "accept v30 marker",
)

OLD = (
    "S \"cat /data/local/tmp/suw_cmd.out /data/local/tmp/suw_child.log 2>&1\" > \"$OUTDIR/child_products.txt\" 2>&1" + NL
    + "say \"   子进程产物(exec 输出/子进程日志)：\"" + NL
)
NEW = (
    "# ★v30：那个 SIGKILL 的凶手只能由内核自己回答(signal_generate 的 comm/pid=发送方 + 内核栈)，" + NL
    + "#   而 root 侧的 stage 脚本现在会在 armed 报告之后立刻 dump。这里就是等那份文件，" + NL
    + "#   别抢在它前面收工(上一发就是驱动先跑完、root 侧还没轮到探针)。" + NL
    + "say \"   等 root 侧 dump ftrace(上限 100s)\"" + NL
    + "k=0" + NL
    + "while [ $k -lt 100 ]; do" + NL
    + "    FSZ=$(S \"wc -c < /data/local/tmp/ksu_ftrace.txt 2>/dev/null\" | tr -d '\\r' | tr -d ' ')" + NL
    + "    case \"$FSZ\" in ''|*[!0-9]*) FSZ=0;; esac" + NL
    + "    [ \"$FSZ\" -gt 200 ] && break" + NL
    + "    sleep 4" + NL
    + "    k=$((k + 4))" + NL
    + "done" + NL
    + "say \"   等了 ${k}s ⇒ ksu_ftrace.txt = ${FSZ} 字节\"" + NL
    + "S \"cat /data/local/tmp/ksu_ftrace.txt\" > \"$OUTDIR/ksu_ftrace.txt\" 2>&1" + NL
    + "say \"   SIGKILL 生成点(前 60 行，带内核栈)：\"" + NL
    + "grep -E 'signal_generate|signal_deliver' \"$OUTDIR/ksu_ftrace.txt\" 2>/dev/null | head -60 | sed 's/^/     /'" + NL
    + "S \"cat /data/local/tmp/suw_cmd.out /data/local/tmp/suw_child.log 2>&1\" > \"$OUTDIR/child_products.txt\" 2>&1" + NL
    + "say \"   子进程产物(exec 输出/子进程日志)：\"" + NL
)
sub(OLD, NEW, "wait for ftrace dump")

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
