# -*- coding: utf-8 -*-
"""grind.py — 把 auto.py 反复跑到"某一轮真的穿过提权链"为止。

为什么要它: 每一发的链走本身有可观的重启率(sen20/21/22/26 死在相3, sen23/25 死在相0,
sen24 穿过了相3 但被低内存杀手在 140s 收走)。⇒ 单轮命中率 <50%, 手工等一轮读一轮太慢。
判据(只看设备端 pr.log 里**我们自己写的行**, 不看 stdout):
  成 = "主观 cred 已是 init_cred"(相4 落地) 或 孩子报出的 "uid=0(root)"
  停 = 连续 tries 轮没成
用法: python cm57/grind.py [最多几轮=6]

★ 判据载体必须是设备端 pr.log, 不能是 stdout: 举证孩子与父进程**共享同一个 stdout fd**,
  两边的行会互相插进对方中间(真机原文: `getenforce: [KID>out] ★★★ …`,
  `uid=0(root)uid=0(root) gid=0(root) gid=0(root) …`) ⇒ 带行首锚点的正则**stdout 与
  pr.log 上都会失配**, 2026-09-28 曾把一次**真命中**判成 MISS。见 GHOSTLOCK-TEMP-ROOT-FINAL.md §8。
"""
import io, os, re, subprocess, sys, time
for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

BASE = r'G:\项目\Windows管理\usb\临时root'
ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
MODE = ("hammer hijack shape2 sen victim shell ph2=0 ncopy5 shots=25 maxr=8 nph=7 "
        "rounds=200 wcpu=6 mcpu=0 kids")
# 注意: "uid=0(root)" 这串字也出现在**我们自己写的提示语**里(收尾那句 "出现 `uid=0(root)` 即为
# 临时 root 成功"), 所以不能裸匹配它 —— 上一版就是因此把一轮"没提权"误判成命中。
# 但**也不能加行首锚点**: 两个写者共用一个 stdout fd, 孩子的输出会被父进程的 say() 插进中间,
# `[KID>out]` / `uid=0(root)` 都不在行首(真机原文见文件头)。⇒ 稳定写法 = 孩子的 `id` 原始输出里
# "uid=0(root)" 与 "context=u:r:kernel:s0" **同现**(re.S 容忍行内/跨行的交织);
# 提示语那句没有 kernel 上下文, 而 uid=2000 的孩子报的是 u:r:shell:s0 (pr.c 里也没有这个串)
# ⇒ 既不假阳也不假阴。
WIN = re.compile(r'(主观 cred 已是 init_cred|整个人 = uid0)')
KIDWIN = re.compile(r'uid=0\(root\).*context=u:r:kernel:s0', re.S)


def sh(args, **kw):
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('encoding', 'utf-8')
    kw.setdefault('errors', 'replace')
    return subprocess.run(args, **kw)


def devlog():
    r = sh([ADB, '-s', DEV, 'exec-out', 'cat /data/local/tmp/pr.log'])
    return r.stdout or ''


def main():
    lim = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    for n in range(1, lim + 1):
        t0 = time.time()
        out = os.path.join(BASE, 'cm57', 'run_g%02d.log' % n)
        print('=== 第 %d 轮: auto.py %s' % (n, MODE), flush=True)
        with io.open(out, 'wb') as fh:
            p = subprocess.run([sys.executable, os.path.join(BASE, 'cm57', 'auto.py')]
                               + [MODE], stdout=fh, stderr=subprocess.STDOUT,
                               timeout=1800)
        log = devlog()
        hit = WIN.findall(log) + KIDWIN.findall(log)
        # 关键几行(不管成败都摘出来, 免得只看到"没成"三个字)
        keep = [l for l in log.splitlines()
                if re.match(r'^\s*\[(SEN|SLA|W|X|K|DIAG|h\]|HIT|ID|k)', l)
                or 'uid=' in l or 'root)' in l]
        print('\n'.join(keep[-14:]), flush=True)
        print('--- 第 %d 轮 %.0fs rc=%s 命中=%s' % (n, time.time() - t0, p.returncode,
                                                    hit or '无'), flush=True)
        if hit:
            print('★★★ 命中判据 ⇒ 停(把 %s 存成证据)' % out, flush=True)
            return 0
    print('× 连跑 %d 轮没有一轮穿过 ⇒ 需要换设计, 不是换运气' % lim, flush=True)
    return 1


sys.exit(main())
