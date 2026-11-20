#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把"设备实测偏移"与"各构建树 DWARF 算出的偏移"逐字段对齐，把厂商多出来的字节**夹到区间里**。

为什么这么做：路线 B 卡在"四棵公开树都对不上设备布局"，但需要的信息只是**偏移**，不是源码；
而"差 N 字节"这件事只要有两个以上锚点就能定位到"洞在哪个字段之间"。一旦区间定了，
要么是能枚举的 CONFIG 块(配置反演)，要么直接插 `char __padN[]`(padded header) ⇒ 布局逐字节复现。

输入：
  kmod/device_offsets.txt          设备侧一手实测偏移(没量过的不写)
  kmod/layout/layout2_<树名>.txt   远端 pahole 的完整布局(见 kmod/remote_layout2.sh)

用法：python kmod/off_diff.py [task_struct|module|cred|kprobe|...]
"""
import os, re, sys, glob, collections

if hasattr(sys.stdout, "reconfigure"):      # 本机控制台是 GBK，⇒ 强制 UTF-8(输出请落文件再读)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = os.path.join(HERE, "layout")

FIELD_RE = re.compile(r"^(?P<indent>\t)(?P<decl>[^\t].*?);(?P<tail>\s*/\*\s*(?P<off>-?\d+)\s+(?P<size>\d+)\s*\*/)\s*$")


def parse_pahole(path):
    """→ {struct_name: OrderedDict{field: (off, size)}}，只收每个 struct 的**顶层**(一层缩进)字段。"""
    out = collections.OrderedDict()
    cur = None
    depth = 0
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        m = re.match(r"^===== (\w+) \((.+)\)$", line)
        if m:
            cur = None
            continue
        sm = re.match(r"^(?:typedef\s+|asm\s+|static\s+)?(?:struct|union|enum)\s+(\w+)\s*\{$", line)
        if sm:
            cur = sm.group(1)
            out.setdefault(cur, collections.OrderedDict())
            depth = 0
            continue
        if cur is None:
            continue
        if line.startswith("};") or line.strip() == "}":
            cur = None
            continue
        fm = FIELD_RE.match(line)
        if not fm:
            continue
        decl = fm.group("decl")
        off, size = int(fm.group("off")), int(fm.group("size"))
        if off < 0:
            continue
        # 字段名 = 去掉参数表与数组维之后的最后一个标识符
        # (否则 `int (* init)(void)` 会被取成 'void'、`char name[56]` 被取成 '56')
        fp = re.search(r"\(\s*\*\s*(\w+)\s*\)", decl)      # 函数指针字段：名字在括号里
        if fp:
            name = fp.group(1)
        else:
            core = re.sub(r"\([^()]*\)", " ", decl)
            core = re.sub(r"\[[^\]]*\]", " ", core)
            found = re.findall(r"[A-Za-z_]\w*", core)
            if not found:
                continue
            name = found[-1]
        if name in out[cur]:
            # 同名可能多次出现(匿名 union / 嵌套重名)：全部留着，让读的人自己判
            out[cur][name].append((off, size))
            continue
        out[cur][name] = [(off, size)]
    return out


def load_device(path):
    d = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if "." not in parts[0] and "__" not in parts[0]:
            continue
        try:
            val = int(parts[1], 0)
        except (ValueError, IndexError):
            continue
        d[parts[0]] = val
    return d


NEST_TYPES = ("dl_task_struct", "sched_dl_entity", "sched_entity", "thread_info",
              "module_kobject", "module_layout", "signal_struct", "fs_struct",
              "files_struct", "nsproxy", "sched_rt_entity", "posix_cpu_timers",
              "restart_block", "callback_head", "list_head", "rb_node", "plist_node")


def tree_cands(tbl, sname, field):
    """该字段在树里的**所有候选偏移**(升序)。点号 = 嵌套：dl.deadline → dl + dl_task_struct.deadline"""
    if "." not in field:
        return sorted({o for o, s in tbl.get(sname, {}).get(field, [])})
    head, rest = field.split(".", 1)
    bases = [o for o, s in tbl.get(sname, {}).get(head, [])]
    res = []
    for cand in NEST_TYPES:
        for b in bases:
            for o, s in tbl.get(cand, {}).get(rest, []):
                res.append(b + o)
    return sorted(set(res))


def tree_sizeof(tbl, sname):
    f = tbl.get(sname)
    if not f:
        return None
    return max(o + s for lst in f.values() for o, s in lst)


def align(fields, dev, cands, want):
    """按"洞只会往结构体里加字节"这条单调模型对齐：
    每个字段的候选必须比上一个**靠后**，且 delta(设备−树) 不小于上一个 delta；
    优先选 delta 不变的那个，不得不跳时记下跳变 = 洞的位置。"""
    out = []
    prev_off, prev_delta = None, None
    for f in fields:
        dv = dev[f"{want}.{f}"]
        cl = cands[f]
        if not cl:
            out.append((f, dv, None, None, []))
            continue
        ok = [c for c in cl if prev_off is None or c > prev_off]
        broke = not ok
        if broke:
            ok = cl                                  # 单调性在这里断了(名字对不上/树里少字段)
        if prev_delta is not None:
            pref = [c for c in ok if (dv - c) >= prev_delta]
            ok2 = pref or ok
        else:
            ok2 = ok
        pick = min(ok2, key=lambda c: abs(dv - c - (prev_delta if prev_delta is not None else 0)))
        out.append((f, dv, pick, dv - pick,
                    [c for c in cl if c != pick] + (["!非单调"] if broke else [])))
        prev_off, prev_delta = pick, dv - pick
    return out


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else "task_struct"
    dev = load_device(os.path.join(HERE, "device_offsets.txt"))
    trees = {}
    for p2 in sorted(glob.glob(os.path.join(LAYOUT, "layout2_*.txt"))):
        name = os.path.basename(p2)[len("layout2_"):-len(".txt")]
        trees[name] = parse_pahole(p2)
    if not trees:
        print("没有 layout2_*.txt，先跑 kmod/remote_layout2.sh 并取回 kmod/layout/")
        return 1

    fields = sorted([k.split(".", 1)[1] for k in dev if k.startswith(want + ".")],
                    key=lambda f: dev[f"{want}.{f}"])
    for t in trees:
        cands = {f: tree_cands(trees[t], want, f) for f in fields}
        rows = align(fields, dev, cands, want)
        print("\n" + "#" * 70)
        print(f"### 树 {t}   sizeof({want}) 树算到 = {tree_sizeof(trees[t], want)}")
        print(f"{'字段':<20}{'设备':>7}{'树':>7}{'设备-树':>8}   备注")
        last = None
        for f, dv, tv, delta, alt in rows:
            if tv is None:
                print(f"{f:<20}{dv:>7}{'—':>7}{'':>8}   树里没有这个字段名/config 关掉了")
                continue
            note = ""
            if last is not None and delta != last:
                note = f"*** delta 从 +{last} 跳到 +{delta} => 洞在上一锚点与本锚点之间 ({delta - last:+d} 字节)"
            if alt:
                note += f"   [同名候选 {alt}]"
            print(f"{f:<20}{dv:>7}{tv:>7}{delta:>+8}   {note}")
            last = delta
        # 详细列出每个跳变段在树里的字段序列
        print(f"\n--- {t}: 跳变段内的树字段明细 ---")
        seq = [(f, dv, tv, delta) for f, dv, tv, delta, alt in rows if tv is not None]
        for (f1, d1, t1, del1), (f2, d2, t2, del2) in zip(seq, seq[1:]):
            if del2 == del1:
                continue
            inside = sorted({(k, o) for k, lst in trees[t][want].items()
                            for o, s in lst if t1 < o < t2})
            print(f"  [{f1}@{t1} -> {f2}@{t2}] delta {del1:+d}->{del2:+d} (差 {del2-del1:+d})")
            print(f"     树里这段有 {len(inside)} 个字段: " +
                  ", ".join(f"{k}@{o}" for k, o in inside)[:700])
    return 0


if __name__ == "__main__":
    sys.exit(main())
