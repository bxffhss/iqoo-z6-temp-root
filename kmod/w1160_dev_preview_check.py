#!/usr/bin/env python3
# w1160_dev_preview_check.py —— #241/#238：把**设备侧那一跑**的读数(候选二进制在 aarch64 用户态
#   跑 `setsepol <夹具> --dry` 的输出)与两份证人逐格对表：
#     ①`kmod/w1152_fixtures/expect.txt`＝我的**模型**(第 97 发之后已被设备读数纠正过)
#     ②`kmod/w103_evidence/w1153_leg_shot97.out` 里的 `rec_stmts=`＝第 97 发**内核自己印的语句行数**
#   ★判读全在这里、不在设备上：设备只负责"把那份二进制跑一遍"。所以这腿的证件可以事后重判(REJUDGE)，
#     不必再碰机器(§347/§349 立的形状)。
import re
import sys

def kv(line, key):
    m = re.search(r"(?<![A-Za-z0-9_])" + re.escape(key) + r"=(-?\d+)", line)
    return int(m.group(1)) if m else None

def main():
    raw_path, tbl_path, leg97_path = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = open(raw_path, "r", encoding="utf-8", errors="replace").read().replace("\r", "")

    rows = {}
    for ln in open(tbl_path, "r", encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        name = ln.split(" ", 1)[0]
        r = {"why": kv(ln, "why"), "n": kv(ln, "n"), "bad_at": kv(ln, "bad_at"),
             "max_arg": kv(ln, "max_arg"), "lenmatch": kv(ln, "lenmatch"),
             "bytes": kv(ln, "bytes"), "slots": kv(ln, "slots")}
        m = re.search(r"(?<![A-Za-z0-9_])fnv=(\d+)", ln)
        r["fnv"] = int(m.group(1)) if m else None
        rows[name] = r

    stmt97 = {}
    for ln in open(leg97_path, "r", encoding="utf-8"):
        if ln.startswith("CASE "):
            nm = ln.split(" ", 2)[1]
            stmt97[nm] = kv(ln, "rec_stmts")

    # 设备那一跑按 "RUN <文件名>" 分块
    blocks, cur, keep = [], None, False
    for ln in raw.split("\n"):
        if ln.startswith("RUN "):
            if cur is not None:
                blocks.append(cur)
            cur = {"name": ln[4:].strip(), "lines": []}
            keep = True
            continue
        if cur is not None and keep:
            cur["lines"].append(ln)
    if cur is not None:
        blocks.append(cur)

    bad = 0
    okcells = 0
    print("=== 设备侧读数对表：候选二进制在 aarch64 用户态跑出的数 ===")
    print("  块数=%d(期望 11) 表行数=%d 第97发证件格数=%d" % (len(blocks), len(rows), len(stmt97)))
    if len(blocks) != 11:
        print("[BAD] 设备那跑不是 11 块(%d)⇒ 输入面或跑法坏了，后面的对表都不算" % len(blocks))
        bad += 1
    for b in blocks:
        name = b["name"]
        stem = re.sub(r"\.bin$", "", name)
        body = "\n".join(b["lines"])
        if stem not in rows:
            print("[BAD] %s 不在期望表里(夹具与表不同源)" % name)
            bad += 1
            continue
        r = rows[stem]
        sepl = next((l for l in b["lines"] if l.startswith("SEPLOAD ")), None)
        pv = next((l for l in b["lines"] if l.startswith("PREVIEW ")), None)
        if not sepl or not pv:
            print("[BAD] %s 块里没有 SEPLOAD/PREVIEW 行 ⇒ 那一格根本没跑(不等于「值对不上」)" % name)
            bad += 1
            continue
        code = kv(sepl, "code")
        got = kv(sepl, "got")
        fm = re.search(r"fnv=(\d+)", sepl)
        fnv = int(fm.group(1)) if fm else None
        why, n = kv(pv, "why"), kv(pv, "n")
        bat, ma, lm = kv(pv, "bad_at"), kv(pv, "max_arg"), kv(pv, "lenmatch")
        nstmt = len([l for l in b["lines"] if l.startswith("STMT ")])
        errs = []
        if code != 0:
            errs.append("读文件 code=%s(该 0)" % code)
        if got != r["bytes"]:
            errs.append("bytes 设备=%s 表=%s" % (got, r["bytes"]))
        if fnv != r["fnv"]:
            errs.append("fnv 设备=%s 表=%s" % (fnv, r["fnv"]))
        for tag, dv, tv in (("why", why, r["why"]), ("n", n, r["n"]), ("bad_at", bat, r["bad_at"]),
                            ("max_arg", ma, r["max_arg"]), ("lenmatch", lm, r["lenmatch"])):
            if dv != tv:
                errs.append("%s 设备=%s 表=%s" % (tag, dv, tv))
        # ★自洽那一格：解干净时"记录里印了几行 STMT"必须等于 n；拒收件必须一行都不印
        if why == 0:
            if nstmt != n:
                errs.append("STMT 行数=%d 而 n=%d" % (nstmt, n))
            if stem in stmt97 and nstmt != stmt97[stem]:
                errs.append("STMT 行数=%d 而第 97 发内核印的 rec_stmts=%s" % (nstmt, stmt97[stem]))
        elif nstmt != 0:
            errs.append("why=%s 的拒收件却印了 %d 行 STMT" % (why, nstmt))
        if errs:
            bad += 1
            print("[BAD] %-10s %s" % (name, "; ".join(errs)))
        else:
            okcells += 1
            print("[OK] %-10s code=0 bytes=%d fnv=%d why=%d n=%d at=%d ma=%d lm=%d STMT=%d(第97发内核=%s)" % (
                name, got, fnv, why, n, bat, ma, lm, nstmt, stmt97.get(stem, "—")))
    print("SUM cells=%d ok=%d bad=%d" % (len(blocks), okcells, bad))
    # ★末词写成大写 `PASS`/`FAIL` 是给总闸 w413 的 item 用的接口：那条闸固定要求输出里有一句
    #   `PASS|对照 OK`(例 214"证据格式就是接口")——我的 `w1160_pass` 小写命中不了它，就会红在闸上。
    print("VERDICT=%s%s 候选二进制在设备 aarch64 用户态的读数：%s" % (
        "w1160_pass" if bad == 0 else "w1160_fail",
        " PASS" if bad == 0 else " FAIL",
        "与期望表全等，且解干净那几格的 STMT 行数＝第 97 发内核自己印的 rec_stmts"
        if bad == 0 else "上面每条 [BAD] 逐条判「被测差」还是「仪器差」"))
    return 0 if bad == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
