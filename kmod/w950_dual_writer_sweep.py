#!/usr/bin/env python3
# w950_dual_writer_sweep.py — 静态扫"截断写的组还开着，就又出现 `>> 同一个变量`"的形状。
# 出处＝§6.454：第 61 发 `w940_mlsb.sh` v1 就是它，两份原始读数被打散成两截（标签一坨在上、读数残缺在下）。
# 机理：`{ … } > $O` 打开的是**一个带自己偏移的写者**；组里若再调一个内部用 `>> $O` 的函数，就出现**第二个写者**（O_APPEND），
#       两者交替写同一文件 ⇒ 后写的覆盖先写的。**只有"组还开着"时才有害**：组关掉之后的 `{ } >> $O` 是顺序写，安全（w928/w941）。
# 谓词（两条各代表一种可达形状，缺一会漏）：
#   A) `>> $V` 字面出现在某个 `{ … } > $V`（单 `>`＝截断）组的行区间内；
#   B) 某个**函数体**里有 `>> $V`，而另有一个 `{ … } > $V` 的组体调用（或 `$(` 里出现）该函数名。
# ★第一版只做了 A，拿坏夹具当正对照时**当场判负**（第二个写者在函数里，A 看不见）——已按 B 补齐。
import glob, re, sys

FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*{")
GROUP_CLOSE = re.compile(r"^\s*\}\s*(>>?)\s*(\$\w+)")


def blocks(lines, start):
    """从 start(该行以 '{' 开始) 找到列 0 的 '}'，返回 (正文区间, 收尾行号)。
    ★单行形状（`U() { cut …; }`）先判：整行自带 '}' 时正文＝这一行本身，否则会一路吞到下一个 '}' 造出假命中
      （第一版就是把 `U()` 吞成 9~18 行，把已经修好的 w942 报成"函数里第二个写者"）。"""
    if lines[start].count("{") <= lines[start].count("}") and lines[start].rstrip().endswith("}"):
        return (start + 1, start + 1), start + 1
    for j in range(start + 1, len(lines)):
        if lines[j].strip().startswith("}"):
            return (start + 1, j), j
    return (start + 1, len(lines)), len(lines)


def scan(paths):
    hits = []
    for f in sorted(paths):
        try:
            lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        funcs, groups = {}, []            # 函数名->写入变量集合；组->(区间, 变量, 是否截断)
        for i, l in enumerate(lines):
            m = FUNC.match(l)
            if m:
                (lo, hi), _ = blocks(lines, i)
                body = "\n".join(lines[lo:hi])
                wv = set(re.findall(r">>\s*(\$\w+)", body))
                if wv:
                    funcs[m.group(1)] = wv
            if l.strip() == "{":                              # 只认"整行就是 {"的多行组；单行组另判（下面 A'）
                m2 = None
                (lo, hi), end = blocks(lines, i)
                if end < len(lines):
                    m2 = GROUP_CLOSE.match(lines[end])
                if m2:
                    groups.append(((lo, hi), m2.group(2), m2.group(1) == ">"))
            elif re.match(r"^\s*\{.*\}\s*>\s*(\$\w+)", l) and re.search(r">>\s*\$\w+", l):
                hits.append((f, i + 1, i + 1, l.strip()[:76], "A' 单行组里同现 > 与 >>"))
        for (lo, hi), var, trunc in groups:
            if not trunc:
                continue
            seg = lines[lo:hi]
            for k, t in enumerate(seg, start=lo + 1):          # 谓词 A
                if re.search(r">>\s*" + re.escape(var) + r"\b", t):
                    hits.append((f, lo + 1, hi, t.strip()[:76], "A 组内字面 >>"))
                    break
            for name, wv in funcs.items():                     # 谓词 B
                if var in wv and re.search(r"\b" + re.escape(name) + r"\b", "\n".join(seg)):
                    hits.append((f, lo + 1, hi, "%s() 体内 >>%s，被这组调用" % (name, var), "B 函数里第二个写者"))
    return hits


def scan_text(text, tag="<mem>"):
    lines = text.splitlines()
    tmp = tag + ".sh"
    open(tmp, "w", encoding="utf-8").write(text)
    try:
        return scan([tmp])
    finally:
        import os
        os.unlink(tmp)


BAD = """O=/tmp/x.out
one() {
  echo "  A ls=[$(/bin/ls 2>&1)]" >> $O 2>&1
}
{
  echo "M1_A:"
  one
  echo "MZ_END"
} > $O 2>&1
"""
GOOD_SEQ = """O=/tmp/x.out
{
  echo "S1"
} > $O 2>&1
{
  echo "S2" >> $O 2>&1
} >> $O 2>&1
"""
GOOD_ONE_LINE_FUNC = """A=/tmp/y.out
U() { cut -d' ' -f1 /proc/uptime; }
run() {
  echo "  x rc=$rc" >> $A 2>&1
}
{
  echo "V0 up=$(U)"
} > $A 2>&1
echo "== head ==" >> $A 2>&1
run
"""

SELFTEST = [
    ("正对照：函数体内 >> 被截断组调用 ⇒ 必须命中", BAD, True),
    ("变异：把那个 >> 删掉(组里只剩裸 echo) ⇒ 必须不命中", BAD.replace(' >> $O 2>&1', ''), False),
    ("变异：谓词靠的是 >>，不是别的 ⇒ 改回 > 也不命中", BAD.replace(">> $O", "> $O"), False),
    ("负对照：截断组关掉之后再开追加组(顺序写) ⇒ 不命中", GOOD_SEQ, False),
    ("负对照：单行函数 U(){…} 不许吞掉后面的行(第一版假命中就是这来的)", GOOD_ONE_LINE_FUNC, False),
]


def selftest():
    bad = 0
    for name, src, want in SELFTEST:
        got = bool(scan_text(src, "kmod/_tmp_selftest_rdst/w950_st"))
        ok = (got == want)
        print("  [%s] %s   (命中=%s 期望=%s)" % ("OK" if ok else "BAD", name, got, want))
        bad += 0 if ok else 1
    print("共 %d 项断言，红 %d 项" % (len(SELFTEST), bad))
    if bad == 0:
        print("PASS 双向都有牙：正对照命中，两枚变异与两处顺序/单行形状都不命中")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    pats = [a for a in sys.argv[1:] if not a.startswith("-")] or ["kmod/*.sh", "kmod/z6root/*.sh"]
    files = [p for g in pats for p in glob.glob(g)]
    h = scan(files)
    print("扫描 %d 个 .sh；命中（截断组里又冒出第二个写者）: %d" % (len(files), len(h)))
    for x in h:
        print("  %s 组[%d-%d] %s: %s" % (x[0], x[1], x[2], x[4], x[3]))
    sys.exit(1 if h else 0)
