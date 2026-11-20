#!/usr/bin/env python3
# w1009_cliteral_check.py —— C 源文件里"字符串字面量没闭合"的静态闸。
# 为什么需要：第 66 发前后我用 python 手术改 kmod/w986_polround.c，把 pr_info 里的 `\n` 吃成了真换行
#   ⇒ 字面量跨行未闭合 ⇒ 整份源文件编不过，而且我一度把"仓库=产物出处"这条链弄断了。
# 判法：先把注释剥掉(状态机，注释里的 ASCII 双引号不算)，再逐行数**未转义**双引号，奇数＝这行开了字面量没关。
# 用法：PYTHONUTF8=1 python kmod/w1009_cliteral_check.py <a.c> [<b.c> ...]
# 退出码：0=全干净；2=有未闭合；3=用法/读文件错误。
import io
import sys


def strip_comments(s):
    out = []
    i, n = 0, len(s)
    state = "code"          # code | line | block | str | chr
    while i < n:
        c = s[i]
        nxt = s[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if c == "/" and nxt == "*":
                state = "block"; i += 2; out.append("  "); continue
            if c == '"':
                state = "str"
            elif c == "'":
                state = "chr"
            out.append(c); i += 1; continue
        if state == "line":
            if c == "\n":
                state = "code"; out.append(c)
            i += 1; continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = "code"; i += 2; out.append("  "); continue
            out.append("\n" if c == "\n" else " "); i += 1; continue
        # 字符串/字符字面量内部：反斜杠吃掉下一个字符
        if c == "\\":
            out.append(c)
            if nxt:
                out.append(nxt); i += 2; continue
            i += 1; continue
        if c in ('"', "'") and (c == '"' if state == "str" else True):
            state = "code"; out.append(c); i += 1; continue
        out.append(c); i += 1
    # 收尾还在 str/chr 里＝某一行的引号没关（strip 后逐行数引号也能抓到，这里是第二道）
    return "".join(out), state


def check(path):
    try:
        raw = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("[x] 读不了 %s：%s" % (path, e))
        return 3
    code, endstate = strip_comments(raw)
    bad = []
    for ln, text in enumerate(code.split("\n"), 1):
        q = 0
        k = 0
        while k < len(text):
            if text[k] == "\\":
                k += 2; continue
            if text[k] == '"':
                q += 1
            k += 1
        if q % 2:
            bad.append(ln)
    if endstate in ("str", "chr"):
        bad.append("EOF(剥完注释后仍停在字面量里)")
    ob, cb = code.count("{"), code.count("}")
    if bad:
        print("[BAD] %s：未闭合字面量在行 %s" % (path, ",".join(map(str, bad))))
        return 2
    print("[ok] %s：无未闭合字面量；花括号 {%d/}%d 差额=%d" % (path, ob, cb, ob - cb))
    return 0


def selftest():
    """双向自测：坏夹具必须被抓到，好夹具必须放过；只跑一遍不算复证 ⇒ 各跑两遍。"""
    import os
    import tempfile
    bad = ('static int x(void)\n{\n\tpr_info("line one => stop\n", v);\n\treturn 0;\n}\n')
    good = ('static int x(void)\n{\n\t/* a "quote" inside a comment, and it\'s fine */\n'
            '\tpr_info("closed\\n", v);\n\treturn 0;\n}\n')
    d = tempfile.mkdtemp()
    ok = True
    for name, text, want in (("bad.c", bad, 2), ("good.c", good, 0)):
        p = os.path.join(d, name)
        io.open(p, "w", encoding="utf-8", newline="\n").write(text)
        for run in (1, 2):
            got = check(p)
            if got != want:
                print("[x] selftest %s run%d got=%d want=%d" % (name, run, got, want))
                ok = False
    for f in ("bad.c", "good.c"):
        os.remove(os.path.join(d, f))
    os.rmdir(d)
    print("[selftest] %s" % ("PASS(坏夹具 2/2 抓到，好夹具 0/0 放过)" if ok else "FAIL ⇒ 这个闸没有牙，别用它"))
    return 0 if ok else 4


if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(3)
if sys.argv[1] == "--selftest":
    sys.exit(selftest())
rc = 0
for p in sys.argv[1:]:
    r = check(p)
    if r == 3:
        sys.exit(3)
    rc = max(rc, r)
sys.exit(rc)
