#!/usr/bin/env python3
# w105_ko_compare.py —— 旧机 /home/lucy 上那 82 个 .ko，有多少个字节在本机仓库里已经有了副本？
# 只按哈希比，不按文件名比（本机用 kernelsu_54_rcNN.ko，远端用 kernelsu_rcNN.ko，名字本来就不是一套）。
# 跑法：PYTHONUTF8=1 python kmod/w105_ko_compare.py
import hashlib
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REMOTE_LIST = ROOT / "kmod" / "w103_evidence" / "ko_md5s_old.txt"

remote = {}
for line in REMOTE_LIST.read_text(encoding="utf-8", errors="replace").splitlines():
    parts = line.split()
    if len(parts) == 2 and len(parts[0]) == 32:
        remote[parts[1]] = parts[0]          # ★按文件名建账，别按哈希（远端有互相重复的 .ko）
raw_lines = len(REMOTE_LIST.read_text(encoding="utf-8", errors="replace").splitlines())
print(f"旧机 md5 行数 = {raw_lines}  按名字入账 = {len(remote)}")
if raw_lines != len(remote):
    print(f"[x] 行数与入账数不等 ⇒ 有解析不掉的行，本次结论作废")
    sys.exit(3)
dup = {}
for name, h in remote.items():
    dup.setdefault(h, []).append(name)
dups = {h: ns for h, ns in dup.items() if len(ns) > 1}
print(f"旧机内部字节重复的 .ko 组 = {len(dups)}：{dups}")


local = {}
skipped = 0
for p in ROOT.rglob("*.ko"):
    if "hermes-remote" in p.parts:
        continue
    try:
        h = hashlib.md5()
        with p.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        local.setdefault(h.hexdigest(), []).append(str(p.relative_to(ROOT)))
    except OSError as e:
        skipped += 1
        print(f"[读不了] {p}: {e}", file=sys.stderr)
print(f"本机 .ko 条数 = {len(local)}  (唯一哈希，另有重名副本)")

have = [n for n, h in remote.items() if h in local]
miss = [n for n, h in remote.items() if h not in local]
print(f"\n== 本机已有同字节副本：{len(have)} 个 ==")
print(" ".join(sorted(os.path.basename(x) for x in have)))
print(f"\n== ★本机没有、旧机一到期就永久消失：{len(miss)} 个 ==")
for x in sorted(miss, key=lambda s: s):
    print(f"  {x}  (本机同哈希: 无)")
print("\n== 其中和'现在还在用的那几版'相关的，逐个点出来 ==")
KEY = ("rc67", "rc73", "rc74", "w985", "w986", "ship")
for x in sorted(miss):
    if any(k in x for k in KEY):
        print(f"  [要紧] {x}")
print(f"\nMISS_COUNT={len(miss)}")

# ★这把尺自己得能失败：本机扫太少 / 有读不了的 / 正负对照不命中 ⇒ 结论作废
print("\n== 自检（仪器能不能失败）==")
fatal = False
if len(local) < 200:
    print(f"[x] 本机唯一哈希只有 {len(local)} 个 ⇒ 扫到的 .ko 太少，'miss' 全是假的")
    fatal = True
if skipped:
    print(f"[!] 本机有 {skipped} 个 .ko 读不了 ⇒ 上面 miss 里可能有误判，要人工复核（读不了≠没有）")
probe = "kernelsu_rc74c.ko"
if probe not in remote:
    print(f"[x] 正对照缺：旧机清单里没有 {probe}")
    fatal = True
elif probe not in have:
    print(f"[x] 正对照失败：{probe} 本机应当有同字节副本 ⇒ 尺子不对")
    fatal = True
else:
    print(f"[ok] 正对照：{probe} 命中（本机确有同字节副本）")
bogus = dict(remote)
bogus[probe] = "0" * 32
if probe in [n for n, h in bogus.items() if h not in local]:
    print(f"[ok] 负对照：把 {probe} 的哈希改坏后它落进 miss ⇒ 这把尺有牙")
else:
    print(f"[x] 负对照失败：改坏哈希仍判『有副本』⇒ 这把尺没牙，结论作废")
    fatal = True
if fatal:
    sys.exit(3)
print("[OK] 尺子双向都对，上面的 MISS 可信")
