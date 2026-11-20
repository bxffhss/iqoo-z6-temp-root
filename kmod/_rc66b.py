# -*- coding: utf-8 -*-
# _rc66b.py —— 从 remote_ksu_rc65.sh 造 rc66：只动"文件名/日志名/产物名"这三处，外加一条新闸门。
#   锚点必须各命中 1 次，否则不写盘(项目规矩：脚本改代码用唯一锚点，不按行号切)。
import io

src = "kmod/remote_ksu_rc65.sh"
dst = "kmod/remote_ksu_rc66.sh"
s = io.open(src, encoding="utf-8", errors="replace").read()

HEAD_OLD = "# rc65 = rc64 + **#82 的确定性把手 `/proc/ksu_crown`**(运行期改\"王座归属\"，默认不写=与 rc64 逐字相同)。"
HEAD_NEW = ("# rc66 = rc65 + **`/proc/ksu_crown` 的两处健壮性**(§6.188④ 那颗静默地雷)，除此之外与 rc65 逐字相同：\n"
            "#   ① 空写/纯空白/非数字开头 ⇒ 只记 `CROWN 忽略…` 的回执、**不动王座**\n"
            "#      (一手事故：`printf '?\\n' > /proc/ksu_crown` 会产生两次 write，第二次空串被 simple_strtoul 解析成 0\n"
            "#       ⇒ 王座被清零，而那正好发生在\"救窗口\"的中途——下次再撞就是\"王座莫名其妙没了\")\n"
            "#   ② 加 **read 处理器** ⇒ `cat /proc/ksu_crown` 直接回当前 appid\n"
            "#      (能读就没人会用写去问：这比在写口里加解释更对症)\n"
            "#   ★默认不写这个口时，rc66 与 rc63/rc65 行为逐字相同 ⇒ 仍然只是实验版，交付默认是 rc63。")

REPL = [
    (HEAD_OLD, HEAD_NEW, 1),
    ('LOG=/home/lucy/ksu_rc65.log', 'LOG=/home/lucy/ksu_rc66.log', 1),
    ('START(rc65)', 'START(rc66)', 1),
    ('cp /home/lucy/ksu_dev_syms_rc65.c "$M/infra/dev_syms.c"',
     'cp /home/lucy/ksu_dev_syms_rc66.c "$M/infra/dev_syms.c"', 1),
    # ★预检抓到的：这个串在脚本里出现 **3 次**(生成、计数、读回)，不是 1 次 ⇒ 期望值按实测写，别猜
    ('/tmp/und_rc65.txt', '/tmp/und_rc66.txt', 3),
    ('cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc65.ko && md5sum /home/lucy/kernelsu_rc65.ko',
     'cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc66.ko && md5sum /home/lucy/kernelsu_rc66.ko', 1),
    ('strings "$M/kernelsu.ko" | grep -c "CROWN" | sed "s/^/CROWN 串数(必须 >0): /"',
     'strings "$M/kernelsu.ko" | grep -c "CROWN" | sed "s/^/CROWN 串数(必须 >0): /"\n'
     'strings "$M/kernelsu.ko" | grep -c "CROWN 忽略空写" | sed "s/^/rc66 空写守卫串数(必须 1): /"', 1),
]

for a, b, want in REPL:
    c = s.count(a)
    print("锚点命中 %-2d(应 %d)  %s" % (c, want, a[:52].replace("\n", "\\n")))
    if c != want:
        raise SystemExit("[x] 该锚点命中 %d、期望 %d ⇒ 不写盘: %s" % (c, want, a[:52]))

for a, b, _ in REPL:
    s = s.replace(a, b)
io.open(dst, "w", encoding="utf-8", newline="\n").write(s)

t = io.open(dst, encoding="utf-8", errors="replace").read()
print("[ok] 写出 %s：%d 行" % (dst, t.count("\n") + 1))
for pat in ("ksu_dev_syms_rc66.c", "kernelsu_rc66.ko", "START(rc66)", "CROWN 忽略空写", "rc66 空写守卫串数"):
    print("  命中 %-2d  %s" % (t.count(pat), pat))
print("  残留 rc65 字样(应当只剩注释里那句\"rc66 = rc65\")：%d" % t.count("rc65"))
