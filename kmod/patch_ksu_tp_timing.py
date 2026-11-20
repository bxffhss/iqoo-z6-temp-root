#!/usr/bin/env python3
"""patch_ksu_tp_timing.py —— 给 `ksu_mark_running_process_locked()` 装**计时器**（rc70 的唯一改动）。

动机（md §6.266②/③）：那条"遍历整机所有线程、全程 `spin_lock_irqsave`+`read_lock(tasklist_lock)`、
  每线程一条 pr_info"的循环，是本项目里唯一"强度正比于系统线程总数、且由用户态节律(RACE 看门狗 0.4s×75 轮)
  反复触发"的路径。它每轮多少微秒**今天不知道**，所以 (I) 这一族解释既没证实也没判负。
  ⇒ 先把它量出来，再决定第 124/125 发往哪边走。

形状（三条都是硬要求，理由都是付过学费的）：
  · **默认关**：`ksu_tp_timing=0`(默认) ⇒ 只多两次 `ktime_get()` 的判断，不打任何新行、不改控制流；
  · **幂等键在插入文本里**（§6.155/例 72：SD-INIT 那条假幂等闸的根因就是键不在插进去的字里）；
  · **不新增 printk 洪水**：只在结束行多打三个数，绝不在循环体里加行。
用法：python3 patch_ksu_tp_timing.py <tp_marker.c 路径 或 kernel 目录>   # 给目录时自动接 kernel/hook/tp_marker.c
"""
import io
import os
import re
import sys

MARK = "KSUBEAT TPT"

# (1) 参数声明：挂在已有的 module_param 旁边，锚点必须唯一
PARAM_ANCHOR = "static int tracepoint_reg_count = 0;"
PARAM_NEW = (
    "static int tracepoint_reg_count = 0;\n"
    "/* " + MARK + ": 计时开关(默认 0=不打任何新行，只多一次判断) —— md §6.266③ */\n"
    "static bool ksu_tp_timing;\n"
    "module_param(ksu_tp_timing, bool, 0644);\n"
    "static u64 ksu_tp_walk_us_max __read_mostly;\n"
    "static u32 ksu_tp_walk_n;\n"
)

# (2) 循环体：加 walked 计数 + 起止时间
DECL_OLD = """void ksu_mark_running_process_locked(void)
{
    struct task_struct *p, *t;
    read_lock(&tasklist_lock);
"""
DECL_NEW = """void ksu_mark_running_process_locked(void)
{
    struct task_struct *p, *t;
    /* KSUBEAT TPT: 这一轮的耗时与线程数计量(默认不打行) —— §6.266②：这条路径的耗时是本项目现在的未知量。
       ★参数只能在 insmod 那一刻定(本 ko 用 kobject_del 摘了 /sys/module/kernelsu)，别指望运行时开。
       ★措辞注意：这段注释里**不许**出现结束行那个标记串，否则本补丁器"结束行只出现一次"的断言会被自己撞红。 */
    u32 ksu_tp_walked = 0;
    u64 ksu_tp_walk_us = 0;
    ktime_t ksu_tp_t0 = { 0 }, ksu_tp_t1 = { 0 };

    if (READ_ONCE(ksu_tp_timing))
        ksu_tp_t0 = ktime_get();
    read_lock(&tasklist_lock);
"""

LOOP_OLD = """        put_cred(cred);
    }
    read_unlock(&tasklist_lock);
}
"""
LOOP_NEW = """        put_cred(cred);
        ksu_tp_walked++;
    }
    if (READ_ONCE(ksu_tp_timing)) {
        ksu_tp_t1 = ktime_get();
        read_unlock(&tasklist_lock);
        /* ★解锁**之后**再打这行：pr_info 落在 tasklist_lock 里会更糟(例 79：仪器自己就是负载) */
        ksu_tp_walk_us = (u64)ktime_us_delta(ksu_tp_t1, ksu_tp_t0);
        if (ksu_tp_walk_us > READ_ONCE(ksu_tp_walk_us_max))
            WRITE_ONCE(ksu_tp_walk_us_max, ksu_tp_walk_us);
        WRITE_ONCE(ksu_tp_walk_n, READ_ONCE(ksu_tp_walk_n) + 1u);
        pr_info("KSUBEAT TPT walk: tasks=%u us=%llu n=%u max_us=%llu irq_off≈%s\\n",
                ksu_tp_walked, ksu_tp_walk_us, READ_ONCE(ksu_tp_walk_n),
                READ_ONCE(ksu_tp_walk_us_max),
                "spin_lock_irqsave+read_lock(tasklist_lock)");
        return;
    }
    read_unlock(&tasklist_lock);
}
"""

EDITS = [("param", PARAM_ANCHOR, PARAM_NEW), ("decl", DECL_OLD, DECL_NEW), ("loop", LOOP_OLD, LOOP_NEW)]


def patch(path: str) -> int:
    s = io.open(path, encoding="utf-8", errors="replace").read()
    orig = s                      # ★全文件不变式的比对基准(大括号计数)
    if MARK in s:
        print(f"已打过(幂等跳过)：{path}  MARK 出现 {s.count(MARK)} 次")
        return 0
    for tag, old, new in EDITS:
        n = s.count(old)
        if n != 1:
            print(f"[x] 锚点 {tag} 命中 {n} 次(必须=1) ⇒ 不写文件")
            return 2
        s = s.replace(old, new, 1)

    # —— 形状断言（**位置类判据按行找**、-1 直接算 FAIL：例 75）——
    lines = s.split("\n")

    def lno(pat):
        hits = [i for i, l in enumerate(lines) if re.search(pat, l)]
        return hits

    checks = [
        ("module_param(ksu_tp_timing", lno(r"module_param\(ksu_tp_timing")),
        ("walked++", lno(r"ksu_tp_walked\+\+")),
        ("TPT walk 结束行", lno(r"KSUBEAT TPT walk:")),
        ("ktime_us_delta", lno(r"ktime_us_delta")),
    ]
    for name, h in checks:
        if len(h) != 1:
            print(f"[x] 断言失败：{name} 命中 {len(h)} 处(必须=1) ⇒ 不写文件")
            return 3
    li_decl = lno(r"void ksu_mark_running_process_locked\(void\)")[0]
    # ★位置类断言**只在本函数体内比**：全文里 `for_each_process_thread`/`read_lock(&tasklist_lock)`
    #   各有两处(上面 `handle_process_mark()` 里也有一份)，取"全文第一处"会拿到错的行号(2026-10-13 自测抓到)。
    def lno_in(pat, start):
        return [i for i in range(start, len(lines)) if re.search(pat, lines[i])]

    h_walk = lno_in(r"for_each_process_thread", li_decl)
    h_unlock = lno_in(r"read_unlock\(&tasklist_lock\);", li_decl)
    h_end = lno_in(r"KSUBEAT TPT walk:", li_decl)
    if not (h_walk and h_unlock and h_end):
        print(f"[x] 函数体内没找齐 walk/unlock/end 三行(walk={h_walk} unlock={h_unlock} end={h_end})⇒ 不写文件")
        return 3
    li_walk, li_unlock, li_end = h_walk[0], h_unlock[0], h_end[0]
    if not (li_decl < li_walk < li_unlock < li_end):
        print(f"[x] 顺序错：decl={li_decl} walk={li_walk} unlock={li_unlock} end={li_end} ⇒ 不写文件")
        return 3
    # 大括号**开闭之差**必须与打之前一致。("计数不变"是过严的错断言：补丁本来就要加一个 `if{…}`，
    #  今天自测里它把一次**正确**的补丁判成失败 ⇒ 会拒绝好东西的闸同样不可信，判据要挑结构上不可能看错的那种)
    d_before = orig.count("{") - orig.count("}")
    d_after = s.count("{") - s.count("}")
    if d_before != d_after:
        print(f"[x] 大括号开闭之差变了：打前 {d_before} → 打后 {d_after}"
              f"(新增 {s.count(chr(123)) - orig.count(chr(123))} 个开、{s.count(chr(125)) - orig.count(chr(125))} 个闭) ⇒ 不写文件")
        return 3
        return 3
    # 循环体内**不许**新增 pr_info（防自己造洪水）
    body = "\n".join(lines[li_walk:li_unlock])
    n_body_pr = len(re.findall(r"pr_info\(", body))
    if n_body_pr != 2:
        print(f"[x] 循环体里 pr_info 条数={n_body_pr}（应为原有的 2 条）⇒ 不写文件")
        return 3

    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print(f"打过：{path}  行数 {len(io.open(path, encoding='utf-8').read().split(chr(10)))}  MARK×{s.count(MARK)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(patch(sys.argv[1]))
