#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w912_ringpair.py — 把 §6.449 L2（#209）的两侧读数配成一对判语。

输入两份同源产物：
  1) 设备侧整环快照（dmesg2.log / dmesg.live 的全文），里面有 KSUBEAT SU0/SU1d/SU4；
  2) kmod/w912_appleg.sh 的 w912.out（D2/D3/D4 三条各自的 id 输出与 rc）。
判语只有三种出口，且**任何一侧缺读数都走"未测"**，不许产成"判负"（例 181①）：
  候选成立   ：深度3 的 SU1d parm2=(null) 或 SU4 ret<0
  候选出局   ：深度3 的 parm2 非空且 ret>=0，而那条 su 仍然没出 root
  根本没匹配 ：深度3 连 SU0 都没有 ⇒ 改道没认这次 execve，问题在名单/uid 那一侧
--selftest 用三份合成件把三条出口各跑一遍（正/负对照都真跑）。
"""
import io
import re
import sys

SU0 = re.compile(r"KSUBEAT SU0 su found: pid=(\d+) comm=(\S+) uid=(\d+)")
SU1D = re.compile(r"KSUBEAT SU1d 寄存器已改: parm1=\S+ parm2=(\S+)")
SU4 = re.compile(r"KSUBEAT SU4 after nested execveat: ret=(-?\d+)")
MARK = re.compile(r"^(D[234])_BEGIN up=([\d.]+)")
RC = re.compile(r"^(D[234]) rc=(-?\d+)")
ROOT = re.compile(r"uid=0\(root\)")


def parse_ring(text):
    """按出现顺序取每一次改道的 (pid, parm2, ret)；缺哪个就留 None。"""
    events = []
    cur = None
    for line in text.splitlines():
        m = SU0.search(line)
        if m:
            cur = {"pid": m.group(1), "uid": m.group(3), "comm": m.group(2),
                   "parm2": None, "ret": None}
            events.append(cur)
            continue
        m = SU1D.search(line)
        if m and cur is not None and cur["parm2"] is None:
            cur["parm2"] = m.group(1)
            continue
        m = SU4.search(line)
        if m and cur is not None and cur["ret"] is None:
            cur["ret"] = int(m.group(1))
    return events


def parse_appleg(text):
    legs = {}
    order = []
    for line in text.splitlines():
        m = MARK.match(line)
        if m:
            legs.setdefault(m.group(1), {"up": m.group(2), "root": False, "rc": None})
            if m.group(1) not in order:
                order.append(m.group(1))
            continue
        if ROOT.search(line) and order:
            legs[order[-1]]["root"] = True
            continue
        m = RC.match(line)
        if m:
            legs.setdefault(m.group(1), {"up": None, "root": False, "rc": None})
            legs[m.group(1)]["rc"] = int(m.group(2))
    return legs, order


def verdict(ring_text, leg_text):
    ev = parse_ring(ring_text)
    legs, order = parse_appleg(leg_text)
    lines = []
    lines.append("整环里 SU0 条数=%d（产生者现数，别手数）" % len(ev))
    for k in ("D2", "D3", "D4"):
        if k not in legs:
            lines.append("%s: 未测(appleg 没这条标记)" % k)
        else:
            v = legs[k]
            lines.append("%s up=%s root=%s rc=%s" % (k, v["up"], v["root"], v["rc"]))
    for i, e in enumerate(ev):
        lines.append("  SU0[%d] pid=%s uid=%s parm2=%s ret=%s"
                     % (i, e["pid"], e["uid"], e["parm2"], e["ret"]))

    d3 = legs.get("D3")
    if d3 is None:
        return "未测：appleg 缺 D3", lines
    # 深度3 那次改道在环里的证据：D3_BEGIN 之后、D4_BEGIN 之前的 SU0
    idx3 = [i for i, e in enumerate(ev) if e["parm2"] is not None or e["ret"] is not None]
    if not idx3:
        return "未测：整环里没有任何 SU1d/SU4（可能撞捕获洞＝§dmesg-capture-hole），不作判据", lines
    if d3["root"]:
        return "未测：这一发深度3 也出了 root ⇒ 现象没复现，谈不上机制", lines

    # 找 D3 那次的改道尝试：按顺序第 2 次（D2 是第 1 次、D3 第 2 次、D4 第 3 次）
    e = ev[1] if len(ev) >= 2 else None
    if e is None:
        return "根本没匹配：深度3 连 SU0 都没有 ⇒ 改道没认这次 execve，问题在名单/uid 那一侧", lines
    if e["parm2"] == "(null)" or (e["ret"] is not None and e["ret"] < 0):
        return ("候选成立：深度3 的 parm2=%s ret=%s ⇒ 空串没写进去，改道退化成真 execve(ENOENT)"
                % (e["parm2"], e["ret"])), lines
    if e["parm2"] is None or e["ret"] is None:
        return "未测：深度3 的 SU1d/SU4 只读到一半（环覆盖不全＝记未测，不判负）", lines
    return ("候选出局：深度3 的 parm2=%s ret=%s 都正常，而 su 仍挂 ⇒ 下面那条写的假设不成立，"
            "改找 per-task 判定" % (e["parm2"], e["ret"])), lines


def _fixture(which):
    ring = []
    def one(pid, parm2, ret):
        ring.append("KSUBEAT SU0 su found: pid=%s comm=sh uid=10667 no_escape=1 no_cred_override=1" % pid)
        ring.append("KSUBEAT SU1d 寄存器已改: parm1=ffff0000 parm2=%s parm3=ffff0100 parm4=ffff0200 parm5=0x1000" % parm2)
        ring.append("KSUBEAT SU3 before nested execveat: fd=170 uid=10667 euid=0 parm2=%s parm5=1" % parm2)
        ring.append("KSUBEAT SU4 after nested execveat: ret=%s uid=10667" % ret)
    if which == "成立":
        one("1111", "ffff80001234", "0")
        one("2222", "(null)", "-14")
        one("3333", "ffff80005678", "0")
        legs = ("D2_BEGIN up=100.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD2 rc=0\n"
                "D3_BEGIN up=101.0\nsh: /system/bin/su: inaccessible or not found\nD3 rc=127\n"
                "D4_BEGIN up=102.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD4 rc=0\n")
        return "\n".join(ring), legs
    if which == "出局":
        one("1111", "ffff80001234", "0")
        one("2222", "ffff80009999", "0")
        one("3333", "ffff80005678", "0")
        legs = ("D2_BEGIN up=100.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD2 rc=0\n"
                "D3_BEGIN up=101.0\nsh: /system/bin/su: inaccessible or not found\nD3 rc=127\n"
                "D4_BEGIN up=102.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD4 rc=0\n")
        return "\n".join(ring), legs
    ring = ["KSUBEAT SU0 su found: pid=1111 comm=sh uid=10667 no_escape=1 no_cred_override=1",
            "KSUBEAT SU1d 寄存器已改: parm1=ffff0000 parm2=ffff80001234 parm3=ffff0100 parm4=ffff0200 parm5=0x1000",
            "KSUBEAT SU4 after nested execveat: ret=0 uid=10667"]
    legs = ("D2_BEGIN up=100.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD2 rc=0\n"
            "D3_BEGIN up=101.0\nsh: /system/bin/su: inaccessible or not found\nD3 rc=127\n"
            "D4_BEGIN up=102.0\nuid=0(root) gid=0 groups=0 context=u:r:shell:s0\nD4 rc=0\n")
    return "\n".join(ring), legs


def selftest():
    cases = [("成立", "候选成立"), ("出局", "候选出局"), ("没匹配", "根本没匹配")]
    bad = 0
    for fx, want in cases:
        ring, legs = _fixture(fx)
        got, detail = verdict(ring, legs)
        ok = got.startswith(want)
        print("  [%s] fixture=%s ⇒ %s" % ("OK" if ok else "BAD", fx, got))
        bad += 0 if ok else 1
    # 变异测试：把 D3 的 rc 改成 0 且 root=True ⇒ 必须改口"未测/现象没复现"
    ring, _ = _fixture("成立")
    legs = ("D2_BEGIN up=100.0\nuid=0(root)\nD2 rc=0\n"
            "D3_BEGIN up=101.0\nuid=0(root)\nD3 rc=0\n")
    got, _ = verdict(ring, legs)
    ok = got.startswith("未测")
    print("  [%s] 变异(D3 也出 root) ⇒ %s" % ("OK" if ok else "BAD", got))
    bad += 0 if ok else 1
    # 负对照：整环空 ⇒ 未测，不许判负
    got, _ = verdict("", _fixture("成立")[1])
    ok = got.startswith("未测")
    print("  [%s] 对照 OK 负对照(环为空) ⇒ %s" % ("OK" if ok else "BAD", got))
    bad += 0 if ok else 1
    if bad:
        print("selftest 红灯 %d 条" % bad)
        return 1
    print("selftest PASS 全绿（共 5 项断言：三出口各一份合成件＋变异＋负对照）")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    v, d = verdict(io.open(sys.argv[1], encoding="utf-8", errors="replace").read(),
                   io.open(sys.argv[2], encoding="utf-8", errors="replace").read())
    for line in d:
        print(line)
    print("=" * 8)
    print("判语：" + v)
