#!/usr/bin/env python3
# w1180_punchwait_gate.py — §6.573/§6.575 的离线固化闸（0 枪、纯静态、不碰真链）。
#
# 背景（11-08 第 8 枪＝空枪）：go.sh 卡了 23m24s，一度被判成"挂死"。
# 代码层真相＝两道**有上限的等待**叠加，不是死循环：
#   suw_apk/bootstrap.sh : for i in $(seq 1 40); do / sleep 15 / 退出条件 pidof pr 变空 ⇒ 40*15 = 600s
#   kmod/go.sh 第 3 步   : for i in $(seq 1 200); do sleep 5 / 等判据⑥          ⇒ 200*5 = 1000s
#   合计 1600s (~26.7min)；实测 23m24s 落在区间内。
# 那发 punch 成功翻 MAC 但 `pr` 从未退出 ⇒ punch.log 里 `RC=` 行 0 条 ⇒
# `post=.../ksu_post.sh`（负责 insmod）回调没跑 ⇒ mod=0 / ksu_stage.log 从未生成。
# 另 go.sh:386 的空枪早退判据要求 `enf 已回 Enforcing`，而该发 MAC 一直 Permissive 没回跳 ⇒ 早退失效。
#
# ★本闸**只读**真链源码，不改 go.sh / bootstrap.sh 一个字节（"不改真链"）。
#   它把"两道上限是有界的、且合计不超过阈值"和"`RC=` 收尾证人存在"钉成可复跑断言：
#   - 正对照：现行真链必须全绿；
#   - 反夹具（会非 0 的形状）：把 seq 上限放大 / 抽掉 RC= 行 / 删掉 post= / 放宽 go 第 3 步 ⇒ 必须被抓。
#   用法：python kmod/w1180_punchwait_gate.py --self   （进 w413 总闸）
#         python kmod/w1180_punchwait_gate.py          （只跑现行真链）
#   退出：0=全绿；1=有断言红；2=用法/文件缺失。
# ★反夹具的预期失败用中性 `[--]` 打印，`[BAD]` 只留给真正的失效，
#   免得 stdout 里的 `[BAD]` 字面污染 w413 自己的汇总 grep。

from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOOT = ROOT / "suw_apk" / "bootstrap.sh"
GO = ROOT / "kmod" / "go.sh"

# 两道叠加不许超过 1800s（30min）。§6.573 实测 23m24s；留一点余量，
# 但谁把任一 seq 或 sleep 悄悄放大到让整发等过半小时，这里立刻红。
TOTAL_MAX = 1800

# 真链里 `echo RC=\$? >> ...` 是带反斜杠转义的（在 sh -c 的单引号串里），按字面匹配
RC_LITERAL = r"echo RC=\$? >> /data/local/tmp/punch.log"

ok = 0


def chk(cond: bool, label: str, expect_pass: bool) -> bool:
    """expect_pass=True 的夹具（现行真链）失败要打 [BAD]；反夹具的失败是预期，用中性 [--]。"""
    global ok
    if cond:
        ok += 1
        print(f"  [OK] {label}")
    else:
        print(f"  [{'BAD' if expect_pass else '--'}] {label}")
    return bool(cond)


def bootstrap_bounds(text: str):
    """`for i in $(seq 1 40); do` 与紧随其后的 `sleep 15` 跨两行，一次抓全（别用全局 sleep 会误抓前段的 sleep 3/5/2）。"""
    m = re.search(r"for i in \$\(seq 1 (\d+)\); do\s*\n\s*sleep (\d+)", text)
    if not m:
        return None
    n, s = int(m.group(1)), int(m.group(2))
    return n, s, n * s


def go_bounds(text: str):
    """go.sh 第 3 步：`SIX=0; ...` 之后的 `for i in $(seq 1 200); do sleep 5`。"""
    m = re.search(r"SIX=0;.*?for i in \$\(seq 1 (\d+)\); do sleep (\d+)", text, re.S)
    if not m:
        return None
    n, s = int(m.group(1)), int(m.group(2))
    return n, s, n * s


def eval_chain(boot: str, go: str, label: str, expect_pass: bool) -> bool:
    """对一对 (bootstrap.sh, go.sh) 文本跑全部断言；返回该夹具是否如预期全绿。"""
    global ok
    print(f"--- 夹具: {label} ---")
    allok = True

    # 甲：punch 是 setsid nohup 起的，收尾会写 RC= 行 ⇒ 有没有 RC= 是"pr 退没退出"的唯一证人
    rc_n = boot.count(RC_LITERAL)
    allok &= chk(rc_n == 1, f"{label}: bootstrap 有且仅有 1 条 `RC=` 收尾证人 (Got={rc_n})", expect_pass)

    # 乙：post= 回调（负责 insmod）必须在
    allok &= chk("post=/data/local/tmp/ksu_post.sh" in boot,
                 f"{label}: punch 带 `post=ksu_post.sh` 回调", expect_pass)

    # 丙：bootstrap 等待循环有界，且退出条件是 pidof pr 变空
    b = bootstrap_bounds(boot)
    allok &= chk(b is not None, f"{label}: bootstrap 等待循环的 seq/sleep 抽得到", expect_pass)
    if b:
        allok &= chk(b[2] <= TOTAL_MAX, f"{label}: bootstrap 上限 {b[2]}s ≤ {TOTAL_MAX}s", expect_pass)
    allok &= chk("pidof pr" in boot and '*"pr= "*' in boot,
                 f"{label}: 退出条件是 `pidof pr` 变空", expect_pass)

    # 丁：go.sh 第 3 步等判据⑥的循环有界
    g = go_bounds(go)
    allok &= chk(g is not None, f"{label}: go.sh 第 3 步的 seq/sleep 抽得到", expect_pass)
    if g:
        allok &= chk(g[2] <= TOTAL_MAX, f"{label}: go.sh 上限 {g[2]}s ≤ {TOTAL_MAX}s", expect_pass)

    # 戊：两道叠加不许超过阈值（这就是"等满 23 分钟"能被预判的核心）
    if b and g:
        total = b[2] + g[2]
        allok &= chk(total <= TOTAL_MAX,
                     f"{label}: 两道叠加 {total}s ≤ {TOTAL_MAX}s（等满上限有界）", expect_pass)
        print(f"       bootstrap={b[0]}×{b[1]}s={b[2]}s  go={g[0]}×{g[1]}s={g[2]}s  total={total}s")

    # 己：go.sh 的空枪早退判据仍在（它要求 enf 回 Enforcing；§6.573 里因 MAC 未回跳而失效，
    #     这里只钉"判据还在"，不假装它万能）
    allok &= chk("已回 Enforcing" in go, f"{label}: go.sh 空枪早退判据仍在", expect_pass)

    print(f"  [{label}] {'PASS' if allok else 'rejected(预期被拒)'}")
    if not expect_pass:
        # 反夹具必须**不通过**：这时不算红，反而记一条 [OK]
        if not allok:
            ok += 1
            print(f"  [OK] 变异夹具被正确拒绝（会非 0 的形状）")
        else:
            print(f"  [BAD] 变异夹具竟然全绿 ⇒ 这道闸没有牙")
            return False
    return allok


def main() -> int:
    selftest = "--self" in sys.argv[1:]
    if not BOOT.exists() or not GO.exists():
        print(f"ERROR 缺真链文件: {BOOT} / {GO}")
        return 2

    boot = BOOT.read_text(encoding="utf-8", errors="replace")
    go = GO.read_text(encoding="utf-8", errors="replace")

    # 正对照：现行真链必须全绿
    if not eval_chain(boot, go, "real", expect_pass=True):
        print("VERDICT=FAIL (现行真链有断言红 —— 真链被改过或顺序变了，先查 §6.575)")
        return 1

    if selftest:
        # ★`seq 1 40` 在 bootstrap 里有两处（第 32 行等开机完成、第 119 行等 punch）。
        #   bootstrap_bounds() 抽的是**带 `sleep 15` 后随行**的那一处，所以变异必须打在
        #   被测那一段上，不能 `replace(...,1)` 打到前一处去（会全绿＝假牙）。
        mA, nA = re.subn(r"(for i in \$\(seq 1 )40(\); do\s*\n\s*sleep 15)", r"\g<1>40000\g<2>", boot, count=1)
        if nA != 1:
            print("  [BAD] 变异 A 没匹配到 bootstrap 等待循环那处 `seq 1 40`+`sleep 15`，形状变了要重对表")
            return 1
        eval_chain(mA, go, "mutA_seq放大", expect_pass=False)

        mB = boot.replace(RC_LITERAL, "", 1)
        eval_chain(mB, go, "mutB_删RC证人", expect_pass=False)

        mC = boot.replace("post=/data/local/tmp/ksu_post.sh", "", 1)
        eval_chain(mC, go, "mutC_删post回调", expect_pass=False)

        mD = go.replace("for i in $(seq 1 200); do sleep 5",
                        "for i in $(seq 1 200); do sleep 500", 1)
        if mD == go:
            print("  [BAD] 变异 D 没匹配到 go.sh 第 3 步，形状变了要重对表")
            return 1
        eval_chain(boot, mD, "mutD_goStep3放宽", expect_pass=False)

    print(f"OK_COUNT={ok}")
    print("VERDICT=PASS  离线超时闸全绿（0 枪、真链零改动）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
