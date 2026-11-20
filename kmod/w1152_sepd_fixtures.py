#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1152 —— #238 部件①的**第三个**编码器：产出上机预演要用的夹具流(全部 0 枪，本机跑)。

为什么还要第三份：线格式我已经从 ksud 的 Rust 源翻过两遍——一遍 C 编码器、一遍 C 解码器
(它们在 `w1151_host_selftest.c` 里对表)，再加一份**手算写死的十六进制**。这一份是第三种语言、
第三次独立实现；而且它把 C 里那份手算数组**重新解析成字节**来对表(自洽⓪)，
所以"夹具长什么样"既不依赖任何一件编译产物，也不依赖"我抄了两遍"。
上机时内核解出来的 `why/n/bad_at/max_arg` 与这里印的期望表对表 ⇒ 两端读数。

期望表照一手来源(构建机 /root/k/ksu)：
  uapi/selinux.h:6-29                 cmd/subcmd 的数值
  userspace/ksud/src/sepolicy.rs:653  cmd_expected_argc() → argc 表
  同文件:665 encode_policy_object()   每个对象＝u32 长度 + 字节 + 一个 0x00；None/All＝长度 0
  同文件:679 append_atomic_statement() 每条＝u32 cmd | u32 subcmd | 前 argc 个对象
字节序＝Rust 的 to_ne_bytes ⇒ 这台 aarch64 是小端。

用法：python kmod/w1152_sepd_fixtures.py [输出目录]      默认 kmod/w1152_fixtures/
退出码 0＝自洽；非 0＝自己就没过 ⇒ **不许拿这套夹具上机**。
期望表第一列是 case 名、第二列 `file=` 是**不带路径**的文件名 ⇒ 设备侧目录不同也能同一条 sed 读到。
"""
import hashlib
import os
import re
import sys

M = (1 << 64) - 1
FNV_SEED = 1469598103934665603   # 内核里那个 19 位种子(不是标准 20 位偏移基)
FNV_PRIME = 1099511628211

# cmd → argc：逐行照 cmd_expected_argc()
ARGC = {1: 4, 2: 5, 3: 1, 4: 2, 5: 2, 6: 1, 7: 5, 8: 4, 9: 3}
# cmd → subcmd 合法集：照 ksud 各 TryFrom 里 match 出来的那几个值
SUB = {1: (1, 2, 3, 4), 2: (1, 2, 3), 3: (1, 2), 8: (1, 2),
       4: (0,), 5: (0,), 6: (0,), 7: (0,), 9: (0,)}
ARG_MAX = 256          # 与核心里 W1151_ARG_MAX 同值(改了那边就要改这里)
DEFAULT_SLOTS = 4369   # 探针模块 pd_slots 的默认值


def fnv64(data):
    h = FNV_SEED
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & M
    return h


def le32(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])


def enc_arg(s):
    """None/All 传 None ⇒ 只写长度 0 加那一个 NUL。"""
    if s is None:
        return le32(0) + b"\x00"
    b = s.encode()
    if len(b) > ARG_MAX:
        raise ValueError("参数超过 ARG_MAX：%r" % s)
    return le32(len(b)) + b + b"\x00"


def enc_stmt(cmd, sub, args):
    n = ARGC[cmd]
    assert len(args) == n, "cmd=%d 该给 %d 个对象，给了 %d" % (cmd, n, len(args))
    assert sub in SUB[cmd], "cmd=%d 的 subcmd=%d 不在 ksud 会写出的取值里" % (cmd, sub)
    return le32(cmd) + le32(sub) + b"".join(enc_arg(a) for a in args)


def stmt_len(stmts):
    """这一串语句该占多少字节＝Σ(8 + Σ(5+len))。★独立算式，不经过编码器也不经过解码器。"""
    t = 0
    for c, s, a in stmts:
        t += 8 + sum(5 + (len(x.encode()) if x is not None else 0) for x in a)
    return t


def max_arg_len(stmts):
    m = 0
    for c, s, a in stmts:
        for x in a:
            if x is not None:
                m = max(m, len(x.encode()))
    return m


# ---- 手算写死的第三证人：单条 `allow shell su file entrypoint`(cmd=1 sub=1) ----
# 我按格式一个字节一个字节数出来的：8 + (4+5+1) + (4+2+1) + (4+4+1) + (4+10+1) = 49
HAND_OK1 = bytes.fromhex(
    "0100000001000000"
    "05000000" "7368656c6c00"
    "02000000" "737500"
    "04000000" "66696c6500"
    "0a000000" "656e747279706f696e7400"
)

A_OK1 = ["shell", "su", "file", "entrypoint"]
S_OK3 = [
    (1, 1, ["su", "shell", "process", "transition"]),
    (7, 0, ["runas_app", "system_data_file", "dir", "shell", None]),
    (9, 0, ["/sys/fs/selinux", "/boot", "u:object_r:selinuxfs:s0"]),
]
S_OK9 = [
    (1, 1, ["s", "t", "c", "p"]),
    (2, 1, ["s", "t", "c", "ioctl", "0x8912"]),
    (3, 1, ["su"]),
    (4, 0, ["my_type", "domainattribute"]),
    (5, 0, ["my_type", "domainattribute"]),
    (6, 0, ["my_attr"]),
    (7, 0, ["s", "t", "c", "d", "objname"]),
    (8, 1, ["s", "t", "c", "d"]),
    (9, 0, ["selinuxfs", "/x", "u:object_r:t:s0"]),
]
S_600 = [(6, 0, ["su"]) for _ in range(600)]


def c_literal(path):
    """从 `w1151_host_selftest.c` 里把那份手算十六进制**解析成字节**。
    ★这一格把"手算证人"从"我抄了两遍"升级成"两份文件机器对表"：
      解析不出来或字节不同都要红；缺文件＝未测(不算过)。"""
    if not os.path.isfile(path):
        return None, "文件不在：%s(这一格记未测，不算过)" % path
    txt = open(path, encoding="utf-8").read()
    i = txt.find("static const w1151_u8 F1[49]")
    if i < 0:
        return None, "没找到 F1 那个手算数组(它改名了？读法要跟着改，别拿空当一致)"
    j = txt.find("{", i)
    k = txt.find("}", j)
    if j < 0 or k < 0:
        return None, "数组花括号没配对"
    body = re.sub(r"/\*.*?\*/", " ", txt[j + 1:k], flags=re.S)
    out = bytearray()
    for tok in body.split(","):
        t = tok.strip()
        if not t:
            continue
        if t.startswith("0x"):
            v = int(t, 16)
        elif t.startswith("'"):
            v = ord(t[1])
        else:
            return None, "认不出的 token：%r(解析器要跟着改，不是跳过)" % t
        if not 0 <= v <= 255:
            return None, "越界 token：%r" % t
        out.append(v)
    return bytes(out), None


def build():
    """返回 (夹具表, 变体表)。
    夹具表每项＝(case, 文件名, 字节, 期望)；期望＝dict(why,n,bad_at,max_arg)。
    变体表＝**同一份字节**换一个 insmod 参数再跑(这里＝把格子给少，逼出 TOO_MANY，
    同时第二次独立证明"参数真传进去了")：每项＝(case, 文件名, slots, 期望)。"""
    out = []
    ok1 = enc_stmt(1, 1, A_OK1)
    ok3 = b"".join(enc_stmt(c, s, a) for c, s, a in S_OK3)
    ok9 = b"".join(enc_stmt(c, s, a) for c, s, a in S_OK9)
    ok600 = b"".join(enc_stmt(c, s, a) for c, s, a in S_600)

    def E(why, n, at, ma):
        return {"why": why, "n": n, "bad_at": at, "max_arg": ma}

    def mmax(args):
        """拒收之前**已经读到**的那些参数里最长的那个。
        ★语义要说清：`max_arg` 不是"这条语句的最长参数"，是"解码器在拒收前看到的最大参数长度"——
          第 97 发就是因为我把这格在 bad_len 上写成 0 而红了(设备与 x86 宿主同码都报 5)。"""
        m = 0
        for a in args:
            if a:
                m = max(m, len(a.encode()))
        return m

    out.append(("ok1", "ok1.bin", ok1, E(0, 1, 0, mmax(A_OK1))))
    out.append(("ok3", "ok3.bin", ok3, E(0, 3, 0, mmax([a for _, _, al in S_OK3 for a in al]))))
    out.append(("ok9", "ok9.bin", ok9, E(0, 9, 0, mmax([a for _, _, al in S_OK9 for a in al]))))
    out.append(("ok600", "ok600.bin", ok600, E(0, 600, 0, mmax(["su"]))))

    def mut(name, src, pos, val, exp):
        b = bytearray(src)
        b[pos] = val
        out.append((name, name + ".bin", bytes(b), exp))

    # 破坏件：每个只动**一个字节**；期望的 why/bad_at 照核心的拒收项，max_arg 照"拒之前读到哪"
    mut("bad_cmd", ok1, 0, 10, E(3, 0, 0, 0))                    # 头都没读完 ⇒ 什么都没读到
    mut("bad_sub", ok1, 4, 7, E(9, 0, 4, 0))                     # 同上(还在语句头里)
    mut("bad_nul", ok1, 17, 0x7A, E(7, 0, 17, 0))                # 第一个参数的收尾 NUL ⇒ 长度 5 那个字节没算进来(NUL 先到)
    mut("bad_inner", ok1, 14, 0x00, E(10, 0, 14, 0))             # 体内 NUL，同上
    # ★长度字段那 4 个字节要动**最高那位**才真会超上限：动最低位(offset 18)只得到 255(≤256)，
    #   内核会往下走到"说好的字节数不在流里"(why=6)⇒ 期望就写错了。这里动第 21 个字节。
    #   而它拒之前**第一个参数("shell"，5 字节)已经读完了** ⇒ max_arg=5(第 97 发这一格两端都给 5)。
    mut("bad_len", ok1, 21, 0xFF, E(5, 0, 18, mmax(["shell"])))   # ARGLEN_BIG(第二个对象的长度字段)
    out.append(("bad_hdr", "bad_hdr.bin", ok1[:4], E(2, 0, 0, 0)))  # TRUNC_HDR
    # 尾巴多一个字节 ⇒ 拒在"下一条的头凑不满"(这条现量了"pos==len 是循环不变量"那件事)。
    out.append(("bad_tail", "bad_tail.bin", ok1 + b"\x7f", E(2, 1, 49, mmax(A_OK1))))

    # ---- 变体表：同一份 ok9，但 insmod 只给 8 个格子 ⇒ 第 9 条拒在 TOO_MANY(why=8) ----
    vars_ = [("ok9s8", "ok9.bin", 8, E(8, 8, stmt_len(S_OK9[:8]), max_arg_len(S_OK9[:8])))]
    return out, vars_


def selfcheck(items, vars_, c_path):
    bad = []
    files = {n: d for n, fn, d, e in items}
    # ⓪ 手算那份十六进制在**两份文件里必须是同一串字节**
    cb, err = c_literal(c_path)
    if err:
        bad.append("自洽⓪红：%s" % err)
    elif cb != HAND_OK1:
        bad.append("自洽⓪红：C 那份手算数组解出 %d 字节，与 Python 这份手算证人不同 ⇒ 有一边被抄错了"
                   % len(cb))
    else:
        print("C_LITERAL_PARSED=%d md5=%s (与 Python 手算证人逐字节相同)"
              % (len(cb), hashlib.md5(cb).hexdigest()))
    # ⓪b 反夹具：新解析器必须**会**红——喂一段它认不出的东西，要报错而不是悄悄返回空
    tmp = c_path + ".w1152tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("static const w1151_u8 F1[49] = { 0x01, zz, 0x00 };\n")
        cb2, e2 = c_literal(tmp)
        if e2 is None:
            bad.append("自洽⓪b红：解析器对认不出的 token 报了'没问题' ⇒ 它是一把恒绿的尺")
        if cb2 not in (None, b""):
            bad.append("自洽⓪b红：报错的同时还把字节交出来了(调用方可能拿去用)")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    # ① Python 编码器算出的 ok1 必须与手算证人逐字节相同
    if files["ok1"] != HAND_OK1:
        bad.append("自洽①红：ok1 与手算那 49 字节不同(%d vs %d)" % (len(files["ok1"]), len(HAND_OK1)))
    # ② 每条正件的长度必须等于"Σ(8+Σ(5+len))"那把独立算式
    for name, stmts in (("ok1", [(1, 1, A_OK1)]), ("ok3", S_OK3), ("ok9", S_OK9), ("ok600", S_600)):
        e = stmt_len(stmts)
        if len(files[name]) != e:
            bad.append("自洽②红：%s 实际 %d 字节，算式给 %d" % (name, len(files[name]), e))
    # ③ 每条破坏件必须与它对应的正件**恰差一个字节**(差得多＝变异点没落在要查那把尺上)
    for name in ("bad_cmd", "bad_sub", "bad_nul", "bad_inner", "bad_len"):
        ref, cur = files["ok1"], files[name]
        diff = [i for i in range(len(ref)) if ref[i] != cur[i]]
        if len(ref) != len(cur) or len(diff) != 1:
            bad.append("自洽③红：%s 与 ok1 差 %d 个字节(应为 1)" % (name, len(diff)))
    # ④⑤ argc / subcmd 两张表要自洽(它们是核心里那两条 switch 的第三份拷贝)
    for c, want in [(1, 4), (2, 5), (3, 1), (4, 2), (5, 2), (6, 1), (7, 5), (8, 4), (9, 3)]:
        if ARGC[c] != want:
            bad.append("自洽④红：cmd=%d 的 argc=%d ≠ 记下的 %d" % (c, ARGC[c], want))
        if c in (4, 5, 6, 7, 9) and SUB[c] != (0,):
            bad.append("自洽⑤红：cmd=%d 的 subcmd 域应当只有 0，记的是 %r" % (c, SUB[c]))
    if SUB[1] != (1, 2, 3, 4) or SUB[2] != (1, 2, 3) or SUB[3] != (1, 2) or SUB[8] != (1, 2):
        bad.append("自洽⑤红：1/2/3/8 的 subcmd 域与 ksud 各 match 分支不符")
    if len(items) < 10:
        bad.append("自洽⑥红：夹具只有 %d 件 ⇒ 覆盖不全(正 4＋破 7 里 bad_hdr/bad_tail 也在，共 11)" % len(items))
    # ⑦ 变体引用的件必须在夹具表里、格子数必须与期望条数自洽
    have = {fn for n, fn, d, e in items}
    for case, fn, slots, e in vars_:
        if fn not in have:
            bad.append("自洽⑦红：变体 %s 指着不在夹具表里的文件 %s" % (case, fn))
        if not (0 < slots <= DEFAULT_SLOTS):
            bad.append("自洽⑦红：变体 %s 的 slots=%d 不在 1..%d" % (case, slots, DEFAULT_SLOTS))
        if e["why"] == 8 and e["n"] != slots:
            bad.append("自洽⑦红：变体 %s 说格子=%d 却期望解到 %d 条" % (case, slots, e["n"]))
    return bad


def line(name, fn, exp, slots, data):
    return ("%s file=%s bytes=%d md5=%s fnv=%d slots=%d why=%d n=%d bad_at=%d max_arg=%d lenmatch=%d"
            % (name, fn, len(data), hashlib.md5(data).hexdigest(), fnv64(data), slots,
               exp["why"], exp["n"], exp["bad_at"], exp["max_arg"],
               1 if exp["why"] == 0 else 0))


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join("kmod", "w1152_fixtures")
    here = os.path.dirname(os.path.abspath(__file__))
    items, vars_ = build()
    bad = selfcheck(items, vars_, os.path.join(here, "w1151_host_selftest.c"))
    os.makedirs(d, exist_ok=True)
    lines = ["# w1152 期望表：由 kmod/w1152_sepd_fixtures.py 现生成；上机腿只按这张表判，不自己写期望值",
             "# 列义：file=夹具文件名(不带路径) slots=那一次 insmod 的 pd_slots "
             "why/n/bad_at/max_arg=内核该给的读数 lenmatch=长度自洽该不该为 1"]
    for name, fn, data, exp in items:
        with open(os.path.join(d, fn), "wb") as f:
            f.write(data)
        ln = line(name, fn, exp, DEFAULT_SLOTS, data)
        lines.append(ln)
        print("CASE " + ln)
    byfile = {fn: data for n, fn, data, e in items}
    for name, fn, slots, exp in vars_:
        ln = line(name, fn, exp, slots, byfile[fn])
        lines.append(ln)
        print("CASE " + ln)
    tp = os.path.join(d, "expect.txt")
    with open(tp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    tab = open(tp, "rb").read()
    print("FIXTURE_COUNT=%d TABLE_LINES=%d TABLE_MD5=%s TABLE_BYTES=%d"
          % (len(items), len(lines) - 2, hashlib.md5(tab).hexdigest(), len(tab)))
    print("OUT_DIR=%s" % d)
    if bad:
        for b in bad:
            print("[BAD] " + b)
        print("VERDICT=w1152_FAIL")
        return 1
    print("SELFCHECK=ok (⓪两份文件的手算证人机器对表＋⓪b 解析器的反夹具；①②长度三处一致；"
          "③每条破坏件恰差一字节；④⑤表自洽；⑥覆盖够；⑦变体的件名与格子数自洽)")
    print("VERDICT=w1152_pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
