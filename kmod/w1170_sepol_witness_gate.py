#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1170_sepol_witness_gate.py — #236 的固化闸（0 枪、纯离线、不碰设备、不动货）

守什么
======
md §6.533 的一手结论：本 ko 的 handle_sepolicy 恒 -EOPNOTSUPP，而官方 ksud 的
apply_rules_batch(&result, false) 只在日志里留一条 warn、函数仍回 Ok(())；
`sepolicy check` 是纯用户态语法解析，一次都不问内核。
⇒ ksud 侧 rc / check rc / apply rc / 模块安装 rc **全绿时，内核里可能一条规则都没落**。
⇒ 判"规则落没落"永远不许拿 ksud 的 rc 或 check 当证人。

本闸**不复证这条事实**（事实的一手在 md §6.530 / §6.531 / §6.533），只做两件可复跑的事：
  (甲) 证据链自洽：把那三格的一手读数锚在**本地真件**上现读一遍，任一格变形即报红。
  (乙) 证人资格判语器：喂一份"规则落地"读数，只认内核侧证人；用户态 rc 一律不参与判语。

边界（照抄 §6.541 的口径，不许越线）
==================================
- 甲锚的是**本地源码副本**（kmod/ksu_dropped_stub.c、kmod/ksu_dispatch.c、kmod/ksud_official），
  不是构建机 /root/k/ 那棵真树，**更不是 z6root/kernelsu.ko 的字节**。
  三份 dispatch 副本 md5 同值只证明"副本彼此一致"，不证明"出货 ko 与它一致"（那格是 §6.530 的链接级凭据）。
- 乙是**判据纪律的模型，不是事实证人**：它守的是"以后写判据时别把 ksud 的 0 当成规则落了"，
  不回答"这台机上这条规则落没落"。
- 要判设备侧"落没落"，只能用内核侧证人：导出件的结构尺（§6.541 甲）
  或 security_context_to_sid 行为尺（§6.541 乙）。

为什么要有牙（§6.551）
======================
一把反夹具如果从没红过，它那句"查不到"不算证据。
⇒ (甲) 四把尺**每把**都配一条变异副本，必须报红；其中"应为 0"那把（selinux/load 不在场）
  配的是**会非 0 的形状**（把字节插进副本）。
⇒ (乙) 配正对照、#236 那一格、"用户态 rc 全翻仍同形"格、非法形状自己打回执的失败路径，
  以及一条锚在 `co_varnames` 上的静态牙（用户态 rc 不许出现在判语器参数表里）。

跑法
====
  python kmod/w1170_sepol_witness_gate.py --self   # 进 w413 名册的那一格
  python kmod/w1170_sepol_witness_gate.py          # 只跑(甲) 现读本地真件，命中 0 才 PASS
"""
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
P_STUB = ROOT / "kmod" / "ksu_dropped_stub.c"
P_DISPATCH = ROOT / "kmod" / "ksu_dispatch.c"
P_KSUD = ROOT / "kmod" / "ksud_official"

# §6.533 的"版本证人"：四条独有文案全数命中同一支代码，再加 §6.531 的解析器串。
KSUD_UNIQUE = (
    b"apply sepolicy batch failed",
    b"apply sepolicy batch partially succeeded",
    b"Failed to load sepolicy.rule for",
    b"kernel returned negative sepolicy applied count",
    b"unknown sepolicy cmd",
)
# §6.532 那半：这份 ksud 二进制里两个串命中 0。
KSUD_FORBIDDEN = (b"selinux/load", b"selinux/enforce")

DISCIPLINE = ("DISCIPLINE: ksud_rc/check_rc/apply_rc/module_install_rc = 不合格证人; "
              "判'规则落没落'只认内核侧结构尺或行为尺 (md 6.533/6.541)")


# ---------------------------------------------------------------- (甲) 四把尺
def rule_stub(text):
    """A: handle_sepolicy 的函数体内恒 return -EOPNOTSUPP。锚函数体，不全文 grep。"""
    m = re.search(r"int\s+handle_sepolicy\s*\([^)]*\)\s*\{(?P<body>[^{}]*)\}", text, re.S)
    if not m:
        return False, "RULE_STUB=NO_FUNC (函数体没找到；不是'值为 0')"
    body = m.group("body")
    if not re.search(r"return\s+-EOPNOTSUPP\s*;", body):
        return False, "RULE_STUB=BODY_NO_EOPNOTSUPP body=%r" % body.strip()[:90]
    if re.search(r"return\s+0\s*;", body):
        return False, "RULE_STUB=BODY_ALSO_RETURNS_0 (会谎报成功)"
    return True, "RULE_STUB=-EOPNOTSUPP (函数体内，非全文)"


def rule_dispatch(text):
    """B: 分发按整个 32 位命令字比较，并把 handler 返回值原样回传（§6.530 两条）。"""
    lines = text.splitlines()
    anchor = None
    for i, line in enumerate(lines):
        if "cmd == ksu_ioctl_handlers[i].cmd" in line:
            anchor = i
            break
    if anchor is None:
        return False, "RULE_DISPATCH=NO_CMD_ANCHOR (整值比较那行没找到；不是'值为 0')"
    window = "\n".join(lines[anchor:anchor + 14])
    if not re.search(r"return\s+ksu_ioctl_handlers\[i\]\.handler\(argp\)\s*;", window):
        return False, "RULE_DISPATCH=NO_PASSTHRU (锚行后 14 行内没有原样回传)"
    if re.search(r"return\s+0\s*;", window):
        return False, "RULE_DISPATCH=RETURN_0_IN_WINDOW (把 handler 返回值吞了)"
    return True, "RULE_DISPATCH=line%d 整值比较 + 原样回传" % (anchor + 1)


def rule_ksud_strings(blob):
    """C: 五条独有文案各恰好 1 次＝"读的是同一支 ksud"的版本证人。"""
    bad = {s.decode(): blob.count(s) for s in KSUD_UNIQUE if blob.count(s) != 1}
    if bad:
        return False, "RULE_KSUD_STRINGS=BAD counts=%r" % bad
    return True, "RULE_KSUD_STRINGS=5/5 独有文案各 1 次"


def rule_ksud_forbidden(blob):
    """D: 两个串命中 0（§6.532）。"应为 0"这把尺的牙由 M4 变异现场证明。"""
    hits = {s.decode(): blob.count(s) for s in KSUD_FORBIDDEN if blob.count(s) != 0}
    if hits:
        return False, "RULE_KSUD_NO_LOAD=HIT %r" % hits
    return True, "RULE_KSUD_NO_LOAD=0/2 (selinux/load, selinux/enforce 均不在场)"


def load_evidence():
    return (P_STUB.read_text(encoding="utf-8", errors="replace"),
            P_DISPATCH.read_text(encoding="utf-8", errors="replace"),
            P_KSUD.read_bytes())


# ---------------------------------------------------------------- (乙) 判语器
KERNEL_STATES = {"ok", "bad", "missing"}


def verdict(kernel_struct, kernel_behavior):
    """只认内核侧证人。★用户态 rc 根本不进参数表＝纪律的代码形状。"""
    miss, bad, good = [], [], []
    for name, val in (("struct", kernel_struct), ("behavior", kernel_behavior)):
        if val not in KERNEL_STATES:
            return "untested", "BAD_SHAPE=%s:%r (只认 ok/bad/missing)" % (name, val)
        if val == "missing":
            miss.append(name)
        elif val == "bad":
            bad.append(name)
        else:
            good.append(name)
    if bad:
        return "not_landed", "KERNEL_BAD=%s" % ",".join(sorted(bad))
    if good:
        return "landed", "KERNEL_OK=%s" % ",".join(sorted(good))
    return "untested", "WITNESS_MISSING=struct,behavior (#236: ksud 全绿也不许判 landed)"


def extract_kernel_witness(payload):
    """从一份实验读数里**只**取内核侧两把证人；用户态四个 rc 显式不取。"""
    return payload.get("kernel_struct", "missing"), payload.get("kernel_behavior", "missing")


# ---------------------------------------------------------------- 自测
def selftest():
    n = 0

    def must(cond, label):
        nonlocal n
        if not cond:
            print("[BAD] " + label)
            raise SystemExit(1)
        n += 1
        print("[OK] " + label)

    stub, dispatch, ksud = load_evidence()

    # -- 甲：四把尺的正对照（现读本地真件）
    for fn, arg, name in ((rule_stub, stub, "A 桩"),
                          (rule_dispatch, dispatch, "B 分发"),
                          (rule_ksud_strings, ksud, "C ksud 文案"),
                          (rule_ksud_forbidden, ksud, "D ksud 两串为 0")):
        good, why = fn(arg)
        must(good, "甲正对照 %s ⇒ %s" % (name, why))

    # -- 甲：四把尺各自的变异，必须报红（红的是尺，不是件）
    m1 = stub.replace("return -EOPNOTSUPP;", "return 0;")
    must(m1 != stub and not rule_stub(m1)[0], "甲变异 M1 桩改谎报成功 ⇒ 必须报红")
    m2 = dispatch.replace("return ksu_ioctl_handlers[i].handler(argp);", "return 0;")
    must(m2 != dispatch and not rule_dispatch(m2)[0], "甲变异 M2 分发吞掉返回值 ⇒ 必须报红")
    m3 = ksud.replace(KSUD_UNIQUE[0], b" " * len(KSUD_UNIQUE[0]), 1)
    must(m3 != ksud and not rule_ksud_strings(m3)[0], "甲变异 M3 删一条独有文案 ⇒ 必须报红")
    m4 = ksud + b"selinux/load"
    must(not rule_ksud_forbidden(m4)[0],
         "甲变异 M4 插入 selinux/load ⇒ '查 0'这把尺必须红过一次（§6.551）")
    m5 = stub.replace(re.search(r"int\s+handle_sepolicy\s*\([^)]*\)\s*\{[^{}]*\}",
                                stub, re.S).group(0), "")
    v5, why5 = rule_stub(m5)
    must(not v5 and why5.startswith("RULE_STUB=NO_FUNC"),
         "甲失败路径 M5 函数体没了 ⇒ 自己打 NO_FUNC 回执，不当静默失败")

    # -- 乙：正对照
    must(verdict("ok", "missing")[0] == "landed", "乙正对照 P1 结构尺 ok ⇒ landed")
    must(verdict("missing", "ok")[0] == "landed", "乙正对照 P2 行为尺 ok ⇒ landed")

    # -- 乙：★#236 那一格 —— 用户态四样全绿，内核侧没证人 ⇒ 不许判 landed
    green = {"ksud_rc": 0, "check_rc": 0, "apply_rc": 0, "module_install_rc": 0}
    v, why = verdict(*extract_kernel_witness(green))
    must(v == "untested" and "WITNESS_MISSING" in why,
         "乙核心格 C1 ksud 四样全绿但内核侧缺证人 ⇒ untested 且打回执（#236）")

    # -- 乙：把用户态 rc 全翻非 0，判语必须逐格同形（它们不参与判语）
    red = {k: 1 for k in green}
    v2, why2 = verdict(*extract_kernel_witness(red))
    must(v2 == v and why2 == why, "乙同形格 C2 用户态 rc 全翻 ⇒ verdict 与回执逐字不变")

    must(verdict("bad", "missing")[0] == "not_landed", "乙 C3 内核侧判坏 ⇒ not_landed")
    vb, whyb = verdict("maybe", "missing")
    must(vb == "untested" and whyb.startswith("BAD_SHAPE="),
         "乙失败路径 C4 非法形状 ⇒ untested 且自己打 BAD_SHAPE 回执")

    # -- 乙：静态牙锚在字节码变量表上，不锚散文
    forbidden = {"ksud_rc", "check_rc", "apply_rc", "module_install_rc"}
    params = set(verdict.__code__.co_varnames[:verdict.__code__.co_argcount])
    must(not (params & forbidden),
         "乙静态牙 C5 verdict 参数表=%s 不含任何用户态 rc（锚 co_varnames）" % sorted(params))

    print("共 %d 项断言" % n)
    print("PASS")
    return 0


def main():
    if "--self" in sys.argv[1:]:
        return selftest()
    stub, dispatch, ksud = load_evidence()
    bad = 0
    for fn, arg in ((rule_stub, stub), (rule_dispatch, dispatch),
                    (rule_ksud_strings, ksud), (rule_ksud_forbidden, ksud)):
        good, why = fn(arg)
        print(("[OK] " if good else "[BAD] ") + why)
        bad += 0 if good else 1
    print(DISCIPLINE)
    print("命中=%d" % bad)
    if bad:
        raise SystemExit(1)
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
