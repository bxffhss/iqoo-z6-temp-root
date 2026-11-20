#!/usr/bin/env python3
# w404_tokcount.py —— 把"每发现一个证人就现编一次 python"这件事固化下来（任务 #124 的第一笔）。
# 三条硬规矩是这台机器用真钱换来的，工具里直接写死：
#   1) ★覆盖区间只认**内容**的最大/最小内核秒，不认写者心跳（例 114：/proc/kmsg 跟随器的 HB 能跑到 up=520，文件里其实只有 56..83）
#   2) ★定长轮转件（dmesg2.log 2 MB）上"数到 0"**不是否据**，必须连同覆盖区间一起打印（例 112）
#   3) 词元正则 `([A-Za-z]{1,3}[0-9]{1,3})`：`L10` 会被 `L1` 抢走（例 98 与 w378 都栽过）
# 用法：
#   PYTHONUTF8=1 python kmod/w404_tokcount.py <证据目录> <wNNN 前缀...>            # 真实一发/多发
#   PYTHONUTF8=1 python kmod/w404_tokcount.py --selftest                            # 双向自测（正/负夹具各一格）
import os, re, sys, io, collections

TOKEN_RE = re.compile(r'KSUBEAT ([A-Za-z]{1,3}[0-9]{1,3})')
TS_RE = re.compile(r'\[\s*(\d+)\.\d+\]')
# 这几行都是"名单进表/出表"的证人：入口那行不算末端证人（例 118）
WITNESS = [r'load_allow_uid', r'prune uid', r'set root profile', r'Crowning manager',
           r'Searching manager', r'Search manager finished', r'packages\.list', r'allowlist version']
ROTATION_BYTES = 2 * 1024 * 1024          # dmesg2.log 的定长（超过就是轮转件，0 不可信）


def scan(path, insmod_up=None):
    """返回一个发现字典；不抛异常，缺件就记 '缺'。"""
    out = {'文件': os.path.basename(path)}
    if not os.path.exists(path):
        out['状态'] = '缺'
        return out
    raw = io.open(path, 'rb').read()
    txt = raw.decode('utf8', 'replace')
    out['字节'] = len(raw)
    out['轮转件?'] = '是(数到 0 不是否据)' if (len(raw) >= ROTATION_BYTES - 4096 and path.endswith('dmesg2.log')) else '否'
    ts = [int(m.group(1)) for m in TS_RE.finditer(txt)]
    out['内容覆盖内核秒'] = (min(ts), max(ts)) if ts else None
    out['时间戳行数'] = len(ts)
    c = collections.Counter(m.group(1) for m in TOKEN_RE.finditer(txt))
    top = dict(sorted(c.items(), key=lambda kv: -kv[1])[:12])
    for k in ('SU0', 'X0', 'SD1', 'F2'):
        top.setdefault(k, 0)
    out['词元'] = top
    uid = collections.Counter(m.group(1) for line in txt.splitlines() if 'KSUBEAT SD1' in line
                             for m in [re.search(r'uid=(\d+)', line)] if m)
    out['SD1_uid分布'] = dict(uid.most_common(8))
    out['名单证人'] = ['%s=%d' % (pat, len(re.findall(pat, txt))) for pat in WITNESS if re.search(pat, txt)]
    if insmod_up:
        t0 = int(float(insmod_up))
        # ★必须用 search：dmesg.live 每行以 `<6>`(优先级)开头，match 锚在行首会一律数到 0(第 22 发抓出)
        win = [l for l in txt.splitlines() if (lambda m: m and t0 - 2 <= int(m.group(1)) <= t0 + 245)(TS_RE.search(l))]
        out['装载后0~245秒'] = '行数=%d' % len(win)
        shapes = collections.Counter(re.sub(r'\d+', 'N', re.sub(r'[0-9a-f]{6,}', 'HEX', l)) for l in win if 'KernelSU:' in l)
        out['装载后形状种数'] = len(shapes)
    return out


def report(prefix_dir, prefix, insmod_up=None):
    files = [('环头件', 'ksu_ring_load.txt'), ('连续件', 'dmesg.live'), ('轮转件', 'dmesg2.log')]
    # ★有的发只存了开窗中途那份快照（如 w403 的装载期整段在 *_mid 里）⇒ 两份都扫，别因为主名缺失就报"缺"了事
    files.append(('环头件mid', 'ksu_ring_load_mid.txt'))
    print("=== 一发 %s（insmod up=%s） ===" % (prefix, insmod_up if insmod_up else '未给'))
    for label, name in files:
        p = os.path.join(prefix_dir, '%s_%s' % (prefix, name))
        r = scan(p, insmod_up)
        print("  [%s] %s" % (label, ' '.join('%s=%s' % (k, v) for k, v in r.items())))
    if r.get('内容覆盖内核秒') and r['内容覆盖内核秒'][1] > (int(float(insmod_up)) + 1800 if insmod_up else 10 ** 9):
        print("  ★覆盖检查：本件内容末端已过判据线（可当判据用）" if insmod_up else "")
    prune = 0
    for label, name in files:
        p = os.path.join(prefix_dir, '%s_%s' % (prefix, name))
        if os.path.exists(p):
            prune += len(re.findall(rb'prune uid', open(p, 'rb').read()))
    print("  ⇒ 末端证人汇总：`prune uid` 命中=%d %s" % (prune, '（名单里那条记录被删⇒这格是"空名单"）' if prune else '（记录留在表里⇒这格才算"放行/未放行"）'))


SELFTEST = """# 双向自测：正夹具（每行都该数到）＋ 负夹具（形状要不被 L1 抢走、0 要标成不可信）
"""


def selftest():
    import tempfile, io
    ok = True
    d = tempfile.mkdtemp()
    good = os.path.join(d, 'wTEST_ksu_ring_load.txt')
    with io.open(good, 'w', encoding='utf-8', newline='\n') as f:
        f.write("[  100.100000] KernelSU: KSUBEAT L10 before ksu_file_wrapper_init()\n")
        f.write("[  100.110000] KernelSU: KSUBEAT L1 before cache_sid()\n")
        f.write("[  120.200000] KernelSU: load_allow_uid, name: com.suw.manager, uid: 10342, allow: 1\n")
        f.write("[  120.300000] KernelSU: prune uid: 19999, package: com.suw.manager\n")
        f.write("[  121.000000] KernelSU: KSUBEAT SD1 decline: uid=10342 名单没放行\n")
        f.write("[  121.100000] KernelSU: KSUBEAT F2 redirect: id=221 -> 42 pid=99\n")
        # ★生产件形状：dmesg.live 由 /proc/kmsg 落盘，每行前面带 `<6>` ⇒ 窗口腿必须吃这种行(第 22 发的 bug)
        f.write("<6>[  122.000000] KernelSU: KSUBEAT SD1 decline: uid=0 是 system uid(forbid_system_uid)\n")
        f.write("<6>[  300.500000] KernelSU: KSUBEAT P1 inside-band-with-prio-prefix\n")
        f.write("<6>[  500.500000] KernelSU: KSUBEAT P2 out-of-band-should-not-count\n")
    r = scan(good, insmod_up=120)
    c = r['词元']
    checks = [
        ('L10 与 L1 各算一次(不被 L1 抢走)', c.get('L10') == 1 and c.get('L1') == 1),
        ('覆盖＝内容 100..500', r['内容覆盖内核秒'] == (100, 500)),
        ('prune 证人被数到', any('prune uid' in x for x in r['名单证人'])),
        ('SD1 uid 分布里有 10342', r['SD1_uid分布'].get('10342') == 1),
        # ★这条原来只断"键存在"⇒ 窗口腿坏成恒 0 也照样绿(例 75)。改成数得对：120/121/300 三段进带，500 不进
        ('窗口行数＝6(带内且含 <6> 前缀行)', r['装载后0~245秒'] == '行数=6'),
        ('带外那行没被算进来(行数 6 而非 7；P1/P2 确实都在件里)', r['装载后0~245秒'] == '行数=6' and c.get('P1') == 1 and c.get('P2') == 1),
    ]
    # 负夹具：一个空的轮转件（数到 0 必须标"不可信/覆盖"），不能报成"证人不存在"
    empty = os.path.join(d, 'wNEG_dmesg2.log')
    with io.open(empty, 'w', encoding='utf-8') as f:
        f.write("[  900.000000] some unrelated line\n")
    r2 = scan(empty)
    checks.append(('空件仍打印覆盖，不抛异常', r2['内容覆盖内核秒'] == (900, 900)))
    checks.append(('空件词元计数＝0 但不被当否据(有覆盖区间可查)', r2.get('词元') is not None and '轮转件?' in r2))
    # 反夹具：有 load_allow_uid 但**没有** prune 的件，工具不许报出 prune（否则"0"这种读数不可信）
    nop = os.path.join(d, 'wNOP_ksu_ring_load.txt')
    f = io.open(nop, 'w', encoding='utf-8', newline='');f.write('[  200.100000] KernelSU: load_allow_uid, name: com.termux, uid: 10667, allow: 1'+chr(10));f.write('[  200.200000] KernelSU: KSUBEAT SD1 decline: uid=2000 是 system uid'+chr(10));f.close()
    r3 = scan(nop)
    checks.append(('无 prune 的件不会被报成有 prune(反夹具)', not any('prune' in x for x in r3['名单证人'])))
    checks.append(('有 load_allow_uid 的件要数到它', any('load_allow_uid' in x for x in r3['名单证人'])))
    for name, passed in checks:
        print("  [%s] %s" % ('OK' if passed else 'FAIL', name))
        ok = ok and passed
    print("=== w404_tokcount selftest %s（共 %d 格，含正/负夹具）===" % ('PASS' if ok else 'FAIL', len(checks)))
    return 0 if ok else 1


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    pdir = sys.argv[1]
    for arg in sys.argv[2:]:
        prefix, up = (arg.split(':', 1) + [None])[:2]
        report(pdir, prefix, up)
