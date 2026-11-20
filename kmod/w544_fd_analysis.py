#!/usr/bin/env python3
# w544_fd_analysis.py —— 读第 39 发(rc73×FDKA)拉回的两份内核日志，把"触发口排队/回调/skip"三格数出来并列出末段时序。
#   为什么分两份读：dmesg.live 是跟随器实时写的流式件(HB 心跳时刻≠内容时刻)，dmesg2.log 是 2 MB 定长整环快照 ⇒
#   装载期与死亡时刻一律以整环为准，流式件只给"覆盖区间"。(§6.328/§6.199 那两条老规矩)
import io
import re
import sys

FILES = ["kmod/w103_evidence/w543_dmesg.live.txt", "kmod/w103_evidence/w543_dmesg2.log.txt"]
TS = re.compile(r"^\s*<?\[?\s*([0-9]+)\.([0-9]+)\]?")


def ts(line):
    m = TS.match(line)
    return int(m.group(1)) if m else None


def main():
    files = sys.argv[1:] or FILES
    for p in files:
        try:
            s = io.open(p, encoding="utf-8", errors="replace").read()
        except IOError as e:
            print("[x] 读不到 %s ⇒ %s" % (p, e))
            return 1
        L = s.split("\n")
        marks = [i for i, l in enumerate(L) if "KSUFDINST" in l]
        q = [i for i in marks if "已排队给" in L[i]]
        r = [i for i in marks if "回调跑在" in L[i]]
        sk = [i for i in marks if "NULLFILES skip" in L[i]]
        times = [t for t in (ts(l) for l in L) if t is not None]
        print("== %s 行数=%d 覆盖 up=%s..%s" % (p, len(L), times[0] if times else "?", times[-1] if times else "?"))
        print("   KSUFDINST 行=%d  已排队=%d  回调跑在=%d  NULLFILES skip=%d" % (len(marks), len(q), len(r), len(sk)))
        print("   -- 最后 10 条 KSUFDINST 行 --")
        for i in marks[-10:]:
            print("     [%s] %s" % (ts(L[i]), L[i][:120].strip()))
        # 排队但没有回调的 pid（上一发的指纹就是"最后一次排队没有配对回调"）
        qp = set(re.search(r"pid=(\d+)", L[i]).group(1) for i in q if re.search(r"pid=(\d+)", L[i]))
        rp = set(re.search(r"pid=(\d+)", L[i]).group(1) for i in r if re.search(r"pid=(\d+)", L[i]))
        print("   排队过但没等到回调的 pid=%s" % (",".join(sorted(qp - rp)) or "无"))
        # 死亡前最后 3 行有时刻的打印(给"写者停笔"的上界)
        tail = [(ts(l), l[:90].strip()) for l in L[-40:] if ts(l) is not None]
        print("   末段(最后 6 条带时刻的行)：%s" % (tail[-6:] if tail else "没读到时刻"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
