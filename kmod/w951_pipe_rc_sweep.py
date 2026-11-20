#!/usr/bin/env python3
# w951_pipe_rc_sweep.py — 扫"取 rc 的那一句其实取的是**管道末端**的状态"这条形状（第三次犯，例 176→§6.453→第 61 发 w940 v1）。
# 形状（两种，都是"看起来在判被测命令，实际在判 head/wc/tr"）：
#   A) `x=$(cmd … | head -2)` 紧跟一行 `rc=$?`                     ⇒ rc 永远是 head 的
#   B) `cmd … | head …`（或 `; ` 后接）同一行/次行里 `rc=$?`／`echo … rc=$?` ⇒ 同
#   C) `n=$(cmd 2>/dev/null | wc -c)` 紧跟 `rc=$?`                 ⇒ 更坏：cmd 读不到(EACCES)时 n=0 与"空的"同形
# ★误报的代价＝闸被整体忽略（例 186①），所以分级：
#   STRICT 名单＝交付链上的件（包内腿、go/stage/执法腿…），命中⇒exit 1；
#   其余历史台架件⇒只报条数，exit 0（它们多为已花掉的单次腿，改它们没有产出）。
# 用法：`python kmod/w951_pipe_rc_sweep.py [--selftest] [--strict] [glob ...]`
import glob, re, sys

FILTER_END = r"(?:head|tail|tr|cut|sed|wc|awk|grep|sort|uniq|cat|md5sum|sha256sum)\b"
PIPE_TAIL = re.compile(r"\|\s*" + FILTER_END)
RC = re.compile(r"\b[A-Za-z_]*(?:rc|RC)\s*=\s*\$\?")
RC_ECHO = re.compile(r"(?:rc|RC)=\$\?")
ASSIGN_PIPE = re.compile(r"^\s*\w+\s*=\s*\$\([^)]*\|[^)]*\)\s*(?:#.*)?$")
BARE_PIPE = re.compile(r"^\s*[^\n]*\|\s*" + FILTER_END)

STRICT_DEFAULT = [
    "kmod/z6root.sh", "kmod/z6root/*.sh", "kmod/go.sh", "kmod/ui_grant.sh",
    "kmod/w450_close.sh", "kmod/w813_enforce_only.sh", "kmod/push_ksu.sh",
]


def strip_sub(l):
    """去掉平衡的 `$( … )` 组（mksh 里那串先展开、其 rc 不会传给后面的 `$?` 之外的位置）。
    ★不去嵌套会把两种**合法**写法误报：`sz=$(ls|cut); rm $p; echo rc=$?`（rc 属于 rm）与
      `rprobe=$(printf x | grep -c pat; echo "rc=$?")`（末端 grep 就是判据本身，故意取它的 rc）。"""
    out, depth, i = [], 0, 0
    while i < len(l):
        if l.startswith("$(", i):
            depth += 1
            i += 2
            continue
        ch = l[i]
        if depth:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def hits_in_line(l):
    """返回该行的命中理由，或 None。
    ★两个承重条件：①**整行级文本顺序**（`cmd | head; rc=$?` 里 rc 就是末端 head 的——分号正是它有害的原因；
      而 `rm x; echo "rc=$? 复证=[$(ls|head)]"` 里 rc 属于 rm）；②管道必须在 `$( )` **之外**（见 strip_sub）。
      第一版只条件①的前半⇒把交付腿两行好代码报成缺陷(误报＝例 186①)；第二版加"同一段"⇒把真形状放过(漏报)。"""
    s = strip_sub(l)
    m = PIPE_TAIL.search(s)
    if not m:
        return None
    r = re.search(r"\b[A-Za-z_]*(?:rc|RC)\s*=\s*\$\?", s)
    if not r or r.start() < m.end():
        return None
    return "B `$( )` 之外的管道末端在前、rc=$? 在后"


def scan(paths):
    hits = []
    for f in sorted(paths):
        try:
            lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for i, l in enumerate(lines):
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            why = None
            if ASSIGN_PIPE.match(l) and re.match(r"^(?:local\s+)?[A-Za-z_]*(?:rc|RC)\s*=\s*\$\?\s*(?:;.*)?(?:#.*)?$", nxt):
                why = "A 整行就是 `x=$(…|过滤器)`，下一行**裸取** rc=$?"
            if not why:
                why = hits_in_line(l)
            if why and "w951-ok" not in l and "w951-ok" not in nxt:
                hits.append((f, i + 1, why, l.strip()[:80]))
    return hits


SELF = [
    ("正对照 A：`ls|head` 之后取 rc ⇒ 必须命中",
     'ls=$(/system/bin/ls -l "$2" 2>&1 | head -2)\nrc=$?\n', True),
    ("正对照 B：同一行 `; rc=$?` ⇒ 必须命中",
     '/system/bin/dmesg | tail -3; rc=$?\n', True),
    ("变异：rc 取在裸命令上(管道去掉) ⇒ 必须不命中",
     'out=$(/system/bin/ls -l "$2" 2>&1)\nrc=$?\n', False),
    ("变异：末端就是要判的程序且已注明 w951-ok ⇒ 不命中",
     'x=$(printf a | grep a)  # w951-ok\nrc=$?\n', False),
    ("负对照：管道但没取 rc ⇒ 不命中",
     '/system/bin/ls -l /x 2>&1 | head -2\necho done\n', False),
    ("负对照：取 rc 但没管道 ⇒ 不命中",
     '/system/bin/ls -l /x >/dev/null 2>&1\nrc=$?\n', False),
    ("负对照(一手形状，交付腿 w450_close:43)：`rm …; echo \"rc=$? 复证=[$(… | head -1)]\"` ⇒ 不命中",
     'rm -rf /x/y; echo "rm_rc=$? 复证=[$(/system/bin/ls -d /x 2>&1 | head -1)]"\n', False),
    ("负对照(一手形状，交付腿 w450_close:36→37)：管道那行**不取** rc，下一行是别的命令的 rc ⇒ 不命中",
     'echo "清之前 [$(/system/bin/ls -a /x 2>&1 | head -1)]"\nrm -f /x/a; echo "rm_allow_rc=$?"\n', False),
    ("负对照(一手形状，w300b:12)：管道在 `$( )` 里、rc 属于后面的 rm ⇒ 不命中",
     'sz=$(/system/bin/ls -l "$p" | cut -d" " -f5); /system/bin/rm "$p"; echo "rm_rc=$?"\n', False),
    ("负对照(一手形状，w419:97)：`$(printf x | grep -c pat; echo rc=$?)` 末端 grep 就是判据本身 ⇒ 不命中",
     'rprobe=$(printf "x\\n" | grep -acE nomatch; echo "rc=$?")\n', False),
]


def selftest():
    import os
    bad = 0
    tmp = "kmod/_tmp_selftest_rdst/w951_st.sh"
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    for name, src, want in SELF:
        open(tmp, "w", encoding="utf-8").write(src)
        got = bool(scan([tmp]))
        ok = (got == want)
        print("  [%s] %s   (命中=%s 期望=%s)" % ("OK" if ok else "BAD", name, got, want))
        bad += 0 if ok else 1
    os.unlink(tmp)
    print("共 %d 项断言，红 %d 项" % (len(SELF), bad))
    if bad == 0:
        print("PASS 双向都有牙：两枚正对照命中、三枚变异/负对照不命中")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    strict = "--strict" in sys.argv
    pats = [a for a in sys.argv[1:] if not a.startswith("-")] or (STRICT_DEFAULT if strict else ["kmod/*.sh"])
    files = [p for g in pats for p in glob.glob(g)]
    h = scan(files)
    print("扫描 %d 个文件；命中" % len(files), len(h), "（strict=%s）" % strict)
    for x in h:
        print("  %s:%d  %s\n      %s" % x)
    sys.exit(1 if (h and strict) else 0)
