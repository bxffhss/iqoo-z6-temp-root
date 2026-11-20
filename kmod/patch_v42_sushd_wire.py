import io
import sys

NL = chr(10)

# ── 1) stage 脚本：insmod 之后、app 触发之前，起 root 侧 su 守护 ──────────
P1 = "kmod/ksu_one_stage.sh"
s = io.open(P1, encoding="utf-8").read()
anchor = '    log "===== 信号探针(必须在 app 触发之前挂，杀发生在触发之后) ====="' + NL
if s.count(anchor) != 1:
    sys.exit("stage anchor count=%d" % s.count(anchor))
if "sushd" in s:
    print("stage 已经有 sushd ⇒ 跳过")
else:
    ins = [
        '    log "===== 起 root 侧 su 守护(§6.69③/§6.72③) ====="',
        '    log "      为什么必须是它：app 那个任务靠 escape 变 uid 0 会被厂商模块 vr 杀掉(§6.69)，"',
        '    log "      就算把杀软成 SIGCONT，它接着 execve 还会被 EPERM(§6.72)；而这个守护是窗口里"',
        '    log "      \\"生下来就是 root\\"的进程 —— 同一个 boot 里它 exec 几千次都没人拦。"',
        '    log "      授权判定不在守护里写规则：它拿 SO_PEERCRED 的发起 uid 问内核 UID_GRANTED_ROOT，"',
        '    log "      也就是**只认 KSU 白名单**(名单说没有就没有)。" ',
        '    ( setsid nohup "$CTL" sushd changeme </dev/null >>/data/local/tmp/sushd.log 2>&1 & )',
        '    sleep 2',
        "    log \"  sushd: pid=[$(pidof ksuctl | tr ' ' ',')] 日志 $(wc -c < /data/local/tmp/sushd.log 2>/dev/null) 字节\"",
        "    head -4 /data/local/tmp/sushd.log 2>/dev/null | sed 's/^/      /'",
        "",
    ]
    s = s.replace(anchor, NL.join(ins) + anchor)
    s = s.replace('log "=== 起点 v41 stage=', 'log "=== 起点 v42 stage=')
    io.open(P1, "w", encoding="utf-8", newline="").write(s)
    print("stage v42：守护已接进去")

# ── 2) 驱动器：④c 让守护代跑 ────────────────────────────────────────────
P2 = "kmod/run_app_window.sh"
t = io.open(P2, encoding="utf-8").read()
a2 = 'S "touch /data/local/tmp/ksu_dump_now"'
i = t.find(a2)
if i < 0:
    sys.exit("driver anchor 找不到")
if "④c" in t:
    print("driver 已经有 ④c ⇒ 跳过")
else:
    lines = [
        'say "④c 第三发：让 root 侧守护代跑(§6.72③ 定下来的可用形态；授权只问 KSU 白名单)"',
        'S "am force-stop $PKG" >/dev/null',
        'sleep 1',
        'S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd \'@sushd:id; echo MARKER_VIA_SUSHD; getenforce; grep -m1 ^Uid: /proc/self/status\'" | tee "$OUTDIR/am_sushd.txt"',
        'sleep 9',
        'S "cat $REPORT" > "$OUTDIR/app_sushd.txt" 2>&1',
        'say "   守护代跑的报告(出现 uid=0(root) 才算原语成立)："',
        'grep -E "SUSHD|uid=|MARKER|Permissive|Enforcing|Uid" "$OUTDIR/app_sushd.txt" 2>/dev/null | tail -12 | sed \'s/^/     /\'',
        'S "cat /data/local/tmp/sushd.log 2>&1" > "$OUTDIR/sushd.log" 2>&1',
        'say "   守护侧日志(它问内核那一行 = 授权判定的真凭据)："',
        'tail -8 "$OUTDIR/sushd.log" 2>/dev/null | sed \'s/^/     /\'',
        "",
    ]
    t = t[:i] + NL.join(lines) + t[i:]
    io.open(P2, "w", encoding="utf-8", newline="").write(t)
    print("driver：④c 已加")
