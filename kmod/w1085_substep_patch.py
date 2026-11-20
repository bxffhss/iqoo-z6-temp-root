#!/usr/bin/env python3
# w1085_substep_patch.py —— 给"我们编进模块的那份 SS 源码"打**段内计数器**的补丁(0 枪，主机构建期)。
#
# 为什么要它(§6.506/§6.507/§6.508)：第 81/82/83 三发都死在 `insmod` 内部、零读数；第 83 发证明轮询器能落盘
#   但**抢不到 `insmod` 之后那一格**。而 §6.507 已经拿源码否证了"越界读撞末尾"这一族(`next_entry()` 按 `fp->len`
#   设界)，§6.508 又否证了"分配失败⇒空指针"一族(八个 blob 尺寸驱动的分配点逐条有 NULL 检查)。
#   ⇒ 剩下的问题是**"死在 `policydb_read` 的哪一段、第几条"**，而这件事在设备上只有"代码自己报"才来得及报。
#   `rt_stage` 太粗(只有 2/21/99/-1)，所以把计数器**塞进读循环本身**：进哪一段就写 `rt_sub=N`，循环里就写 `rt_idx=i / rt_idx2=j`。
#   腿那边(下一件)用**紧循环**只读这四个量、只在变化时落盘＋`sync` ⇒ 复位后盘上留的就是"最后一次变化"。
#
# ★规矩(这个脚本自己也当被测对象)：
#   · **锚点必须在函数作用域内且恰好命中 1 次**，多 1 次少 1 次都整体退出非零、**一个字节都不写**(fail-closed)；
#     上一轮教训＝例 191②("改别人源码时注释自己会引入故障")＋例 206("先证明闸会红，再拿命中 0 当凭据")。
#   · 插入的**只有赋值语句，没有注释** ⇒ 不会撞内核块注释(`/*` 在块注释里就是故障)。
#   · 打完**原样打印每一处**(文件/新行号/那一行)给人读，并复跑一遍从盘上现读的 `rt_sub =` 条数(必须＝表长)。
#   · `--self` 是双向夹具：好夹具必须打出 N 条；"锚点重复""锚点缺失""已经打过"三种坏夹具必须**非零退出且不改文件**。
import io
import os
import sys

# (文件, 函数起始行的匹配, 锚点(整行 strip 后**前缀**匹配), 要插入的语句, 插在前/后)
TABLE = [
    ("policydb.c", "^int policydb_read\(", "rc = policydb_init(p);", "rt_sub = 1; rt_note(1, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = ebitmap_read(&p->policycaps, fp);", "rt_sub = 2; rt_note(2, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = ebitmap_read(&p->permissive_map, fp);", "rt_sub = 3; rt_note(3, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = read_f[i](p, p->symtab[i].table, fp);", "rt_sub = 4; rt_idx = i; rt_idx2 = j; rt_note(4, i, j);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = avtab_read(&p->te_avtab, fp, p);", "rt_sub = 5; rt_note(5, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = filename_trans_read(p, fp);", "rt_sub = 7; rt_note(7, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = ocontext_read(p, info, fp);", "rt_sub = 8; rt_note(8, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = genfs_read(p, fp);", "rt_sub = 9; rt_note(9, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = range_read(p, fp);", "rt_sub = 10; rt_note(10, -1, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = ebitmap_read(e, fp);", "rt_sub = 11; rt_idx = i; rt_note(11, i, -1);", "before"),
    ("policydb.c", "^int policydb_read\(", "rc = policydb_bounds_sanity_check(p);", "rt_sub = 12; rt_note(12, -1, -1);", "before"),
    # 每一条 avtab 条目都要留痕。★这份树里**只有一个** avtab 调用在 policydb_read 里(编号 5)——`te_cond_avtab`
    #   不存在(远端 grep=0)，所以编号 6 留空；上一版这里写过"两个 avtab 调用已分开标 5/6"＝**错的**，与 §6.509 冲突。
    ("avtab.c", "^int avtab_read\(", "for (i = 0; i < nel; i++) {", "MARK_LOOP", "after"),
]
SENT = "rt_sub ="
MARKS = ("rt_sub =", "rt_idx =", "rt_idx2 =", "rt_note(")   # ★复证/防重复打按这四个前缀数：avtab 那一处只写 `rt_idx`＋`rt_note`，只数 `rt_sub` 会把好件误判成坏件
EXTERN = "extern int rt_sub; extern int rt_idx; extern int rt_idx2; extern void rt_note(int, int, int);"


def scope(lines, fn_re):
    """返回函数体的 (起, 止) 行下标(含)。止＝函数起始行之后第一个以 `}` 顶格出现的行。"""
    import re
    rx = re.compile(fn_re)
    s = None
    for i, ln in enumerate(lines):
        if rx.match(ln):
            s = i
            break
    if s is None:
        return None
    for j in range(s + 1, len(lines)):
        if lines[j].startswith("}"):
            return (s, j)
    return None


def find_anchors(lines, lo, hi, anchor):
    out = []
    for i in range(lo, hi + 1):
        if lines[i].strip().startswith(anchor):
            out.append(i)
    return out


def plan(dirpath):
    """算出每个文件要打的位置。返回 (edits{file:[(line,ins)}], problems[文案]) —— problems 非空就不该写。"""
    edits, problems = {}, []
    byfile = {}
    for (f, fnre, anchor, ins, where) in TABLE:
        byfile.setdefault(f, []).append((fnre, anchor, ins, where))
    for f, items in byfile.items():
        path = os.path.join(dirpath, "ss", f)
        if not os.path.isfile(path):
            problems.append("%s 不在(%s) ⇒ 停" % (f, path))
            continue
        lines = io.open(path, encoding="utf-8", errors="replace").read().split("\n")
        sc = scope(lines, items[0][0])
        if sc is None:
            problems.append("%s: 找不到函数起始行 %s ⇒ 停" % (f, items[0][0]))
            continue
        lo, hi = sc
        print("  作用域 %s: 第 %d~%d 行(共 %d 行)" % (f, lo + 1, hi + 1, hi - lo + 1))
        if any(m in "\n".join(lines[lo:hi + 1]) for m in MARKS):
            problems.append("%s: 作用域里已经有 `%s` ⇒ 这份**已经打过**，不重复打" % (f, SENT))
            continue
        lst = []
        # ★先挂一行 extern 声明(插在函数起始行**前面**，合法且好复证)：SS 那几个 .c 里没有这三个全局的定义，
        #   定义在我们那份主源 `w986_polround.c` 里(非 static)⇒ 链接到同一个模块符号。
        lst.append((lo, EXTERN))
        for (fnre, anchor, ins, where) in items:
            hits = find_anchors(lines, lo, hi, anchor)
            if len(hits) != 1:
                problems.append("%s: 锚点命中 %d 次(要恰好 1)：[%s] ⇒ 停" % (f, len(hits), anchor))
                continue
            idx = hits[0] + (1 if where == "after" else 0)
            indent = " " * (len(lines[hits[0]]) - len(lines[hits[0]].lstrip()))
            if where == "after":
                indent = " " * (len(lines[hits[0]]) - len(lines[hits[0]].lstrip()) + 1)
                lst.append((idx, indent + "rt_idx = i; rt_note(rt_sub, i, -1);"))
            else:
                lst.append((idx, indent + ins))
        edits[f] = sorted(lst, key=lambda t: t[0])
    return edits, problems


def apply_(dirpath):
    edits, problems = plan(dirpath)
    if problems:
        for p in problems:
            print("  [x] %s" % p)
        print("APPLY_RC=1(未写任何字节) FILES_TOUCHED=0")
        return 1
    n = 0
    ne = 0
    for f, lst in edits.items():
        path = os.path.join(dirpath, "ss", f)
        lines = io.open(path, encoding="utf-8", errors="replace").read().split("\n")
        for k, (idx, text) in enumerate(lst):
            lines.insert(idx + k, text)
            if text.strip() == EXTERN:
                ne += 1
            else:
                n += 1
            print("  [INS] %s:%d  %s" % (f, idx + k + 1, text.strip()))
        io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("APPLY_RC=0 赋值插入=%d(表长=%d) extern 声明=%d(文件数=%d)" % (n, len(TABLE), ne, len(edits)))
    # ★复证：从盘上**现读**再数一遍(我自己报的数不算数，例 187③/例 194)
    tot = 0
    tex = 0
    for f in edits:
        path = os.path.join(dirpath, "ss", f)
        txt = io.open(path, encoding="utf-8", errors="replace").read()
        c = sum(1 for ln in txt.split("\n") if ln.strip().startswith(MARKS))
        e = sum(1 for ln in txt.split("\n") if ln.strip() == EXTERN)
        tot += c
        tex += e
        print("  [读回] %s 计数器行=%s extern 行=%s" % (f, c, e))
    if tot != n or tex != ne:
        print("APPLY_RC=1 读回(计数器 %d/赋值 %d，extern %d/文件 %d)对不上 ⇒ 别编这份件" % (tot, n, tex, ne))
        return 1
    print("PATCH_VERDICT=ok(每条插入都能从盘上读回来)")
    return 0


def check(dirpath):
    edits, problems = plan(dirpath)
    for f, lst in sorted(edits.items()):
        print("  %s 计划打 %d 处" % (f, len(lst)))
    if problems:
        for p in problems:
            print("  [x] %s" % p)
        print("CHECK_RC=1")
        return 1
    na = sum(len([x for x in v if x[1].strip() != EXTERN]) for v in edits.values())
    print("CHECK_RC=0 锚点全在位：赋值 %d 处(表长 %d)＋extern %d 处(文件数 %d)"
          % (na, len(TABLE), len(edits), len(edits)))
    return 0


def selftest():
    """双向夹具：好件必须打出条数；三种坏件必须**非零退出且没改文件**。"""
    import shutil
    import tempfile
    rc = 0
    def good_file():
        return "\n".join([
            "int policydb_read(struct policydb *p, void *fp)",
            "{",
            "\trc = policydb_init(p);",
            "\trc = ebitmap_read(&p->policycaps, fp);",
            "\trc = ebitmap_read(&p->permissive_map, fp);",
            "\t\t\trc = read_f[i](p, p->symtab[i].table, fp);",
            "\trc = avtab_read(&p->te_avtab, fp, p);",
            "\trc = avtab_read(&p->te_cond_avtab, fp, p);",
            "\trc = filename_trans_read(p, fp);",
            "\trc = ocontext_read(p, info, fp);",
            "\trc = genfs_read(p, fp);",
            "\trc = range_read(p, fp);",
            "\t\t\trc = ebitmap_read(e, fp);",
            "\trc = policydb_bounds_sanity_check(p);",
            "\treturn rc;",
            "}",
            "",
        ])
    def avtab_file():
        return "\n".join([
            "int avtab_read(struct avtab *a, void *fp, struct policydb *pol)",
            "{",
            "\tfor (i = 0; i < nel; i++) {",
            "\t\trc = next_entry(buf, fp, sizeof(u32)*4);",
            "\t}",
            "\treturn rc;",
            "}",
            "",
        ])
    cnt = [0]
    def mk(tmp, pol, avt):
        cnt[0] += 1
        d = os.path.join(tmp, "x%d" % cnt[0])
        os.makedirs(os.path.join(d, "ss"))
        io.open(os.path.join(d, "ss", "policydb.c"), "w", encoding="utf-8", newline="").write(pol)
        io.open(os.path.join(d, "ss", "avtab.c"), "w", encoding="utf-8", newline="").write(avt)
        return d

    def snap(d):
        o = {}
        for f in ("policydb.c", "avtab.c"):
            o[f] = io.open(os.path.join(d, "ss", f), encoding="utf-8").read()
        return o

    def chk(name, want_zero, d):
        r = apply_(d)
        ok = (r == 0) if want_zero else (r != 0)
        print(("  [OK] " if ok else "  [BAD] ") + name + " ⇒ rc=%s(期望 %s)" % (r, "0" if want_zero else "非 0"))
        return 0 if ok else 1

    tmp = tempfile.mkdtemp(prefix="w1085self")
    d = mk(tmp, good_file(), avtab_file())
    before = None
    if chk("① 好夹具：全部锚点在位 ⇒ 必须打成功", True, d):
        rc = 1
    # 打完必须能从盘上读回 13 条(apply_ 里已复证)；再自己数一遍
    tot = 0
    for f in ("policydb.c", "avtab.c"):
        t = io.open(os.path.join(d, "ss", f), encoding="utf-8").read()
        tot += sum(1 for ln in t.split("\n") if ln.strip().startswith(MARKS))
    if tot == len(TABLE):
        print("  [OK] ② 盘上现读计数器条数=%d(＝表长 %d，条数由 TABLE 现数不写死)" % (tot, len(TABLE)))
    else:
        print("  [BAD] ② 盘上现读条数=%d(应为表长 %d) ⇒ 上面那句 ok 是假的" % (tot, len(TABLE)))
        rc = 1
    d2 = mk(tmp, good_file().replace("\trc = genfs_read(p, fp);", "\trc = genfs_read(p, fp);\n\trc = genfs_read(p, fp);"), avtab_file())
    s2 = snap(d2)
    if chk("③ 坏夹具(锚点重复)：必须非零", False, d2):
        rc = 1
    if snap(d2) == s2:
        print("  [OK] ④ 坏件退出时**一个字节都没改**")
    else:
        print("  [BAD] ④ 坏件退出却把文件改了 ⇒ fail-closed 没做到")
        rc = 1
    d3 = mk(tmp, good_file().replace("\trc = range_read(p, fp);", "\trc = range_read_v2(p, fp);"), avtab_file())
    if chk("⑤ 坏夹具(锚点缺失)：必须非零", False, d3):
        rc = 1
    d4 = mk(tmp, good_file(), avtab_file())
    apply_(d4)
    d4b = mk(tmp, io.open(os.path.join(d4, "ss", "policydb.c"), encoding="utf-8").read(),
             io.open(os.path.join(d4, "ss", "avtab.c"), encoding="utf-8").read())
    if chk("⑥ 坏夹具(已打过的件再打)：必须非零(不重复打)", False, d4b):
        rc = 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("=== w1085 selftest %s ===" % ("PASS" if rc == 0 else "FAIL"))
    return rc


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode == "--self":
        sys.exit(selftest())
    path = sys.argv[2] if len(sys.argv) > 2 else "/home/lucy/w985_ssport"
    if mode == "--check":
        sys.exit(check(path))
    if mode == "--apply":
        sys.exit(apply_(path))
    print("用法：--self | --check DIR | --apply DIR")
    sys.exit(2)
