#!/usr/bin/env python3
# w356_rate.py —— 把 w356 曲线算成 R0/R1 并**按事先写下的规则**判(规则来自 §6.262/记忆 例 77 的教训：判据要在跑之前落成代码)。
# 用法：PYTHONUTF8=1 python kmod/w356_rate.py <曲线文件> [--insmod-up <秒>]
#
# 三个读数：
#   R0 = insmod 后 [5,15] 秒的 fork/秒(同一 boot 自己当对照，**不用绝对阈值**：厂商底噪本身就有 ~6-9/秒)
#   R1 = 最后 10 秒(死亡前)的 fork/秒
#   仪器自己的贡献 = 1/秒(采样器固定 sleep) ⇒ 两个速率都减掉它再比
# 事先约定的判读(不许事后改)：
#   R1 >= 5*R0 ⇒ "我们自己的 fork-exec 风暴"(§6.198)成立
#   R1 <  2*R0 ⇒ 风暴解释判负 ⇒ 转查 vr 执法形状 / 多条目装载路径
#   中间        ⇒ 不定，需要第二条腿(hostpoll 的在场名单)才说话
import io, re, sys

def rows(path):
    out = []
    for l in io.open(path, encoding="utf-8", errors="replace"):
        m = re.search(r"up=([\d.]+) procs=(\d+) ctxt=(\d+) mod=(\d+)", l)
        if m:
            out.append((float(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))))
    return out

def rate(rs, lo, hi):
    seg = [r for r in rs if lo <= r[0] <= hi]
    if len(seg) < 2:
        return None, 0
    dt = seg[-1][0] - seg[0][0]
    return ((seg[-1][1] - seg[0][1]) / dt if dt > 0 else None), len(seg)

def main():
    path = sys.argv[1]
    force = None
    if "--insmod-up" in sys.argv:
        force = float(sys.argv[sys.argv.index("--insmod-up") + 1])
    rs = rows(path)
    if len(rs) < 5:
        print("[x] 曲线只有 %d 个点 ⇒ 不够算速率(先证这次真读到了，例 71)" % len(rs)); return 2
    up0, up1 = rs[0][0], rs[-1][0]
    print("样本=%d 覆盖 up=[%.2f, %.2f] = %.1f 秒" % (len(rs), up0, up1, up1 - up0))
    print("整段平均 fork/秒 = %.2f(减掉仪器自己的 1 ⇒ 净 %.2f)"
          % (rate(rs, up0, up1)[0], rate(rs, up0, up1)[0] - 1))
    mods = [(a, m) for a, p, c, m in rs]
    ins = force
    r0 = None                      # ★必须先在**所有分支之外**初始化：原来只在"判到 insmod"那一支里赋值，
                                   #   于是"窗口从没开过"这条路径直接 UnboundLocalError 崩掉(2026-10-13 合成曲线自测抓到的)，
                                   #   一个会崩而不是报"不下结论"的判据，等于没有判据。
    if ins is None:
        for i in range(1, len(rs)):
            if rs[i][3] > 0 and rs[i-1][3] == 0:
                ins = rs[i][0]; break
    if ins is None:
        print("!! 全曲线没看到 mod 从 0→1 ⇒ **窗口可能从没开过**(或 insmod 在曲线开始之前)")
        print("   ⇒ 退一步给个**兜底 R0**(曲线头 10 秒)，但它量的是'开窗前的底噪'，不是 insmod 后基线 ⇒ 只报数，结论要打折")
        r0, _ = rate(rs, up0, up0 + 10)
    else:
        r0, n0 = rate(rs, ins + 5, ins + 15)
        print("判到 insmod 在 up≈%.2f(用了 %d 个点算 R0)" % (ins, n0))
        if r0 is not None:
            print("  R0 = %.2f/秒(净 %.2f)" % (r0, max(r0 - 1, 0)))
    r1, n1 = rate(rs, up1 - 10, up1)
    print("  R1(最后 10 秒, n=%d) = %s/秒" % (n1, "?.??" if r1 is None else "%.2f" % r1))
    if r0 and r1 and r0 > 0:
        ratio = r1 / r0
        print("  R1/R0 = %.2f%s" % (ratio, "" if ins is not None else "  (兜底 R0，结论只当候选)"))
        if ratio >= 5:
            print("  ⇒ **风暴那一支成立**(死亡前速率≥5× insmod 后基线)：去对表 hostpoll 里在场的是谁。")
        elif ratio < 2:
            print("  ⇒ **风暴那一支判负**：死前速率与 insmod 后同量级 ⇒ 嫌疑转 vr 执法形状 / 多条目装载路径本身。")
        else:
            print("  ⇒ 介于两档之间 ⇒ 这一发**不下结论**，要 hostpoll 的名单 + 模块目录时间戳才说话。")
    print("★提醒：曲线里的 up 是**设备侧单调量**(可以直接与 stage 日志的 up= 对表)；"
          "hostpoll 的行首是**本机钟**，比设备钟慢 29 秒(§6.261②)。")
    return 0

sys.exit(main())
