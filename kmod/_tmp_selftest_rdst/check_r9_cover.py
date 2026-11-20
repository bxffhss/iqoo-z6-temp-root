import io, re, sys, hashlib, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
import importlib.util
spec = importlib.util.spec_from_file_location('w415', 'kmod/w415_doc_audit.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

WANT = ['kmod/w1020_tiny.c', 'kmod/w1020_tiny.ko', 'kmod/w1020_tiny_build.sh',
        'kmod/w1023_tiny_leg.sh', 'kmod/w1024_shot74.sh',
        'kmod/w1026_skel_build.sh', 'kmod/w1026_skel.ko', 'kmod/w1028_skel_leg.sh',
        'kmod/w1029_shot75.sh', 'kmod/w1031_emptyinit.ko', 'kmod/w1032_emptyinit_leg.sh',
        'kmod/w1033_shot76.sh', 'kmod/w1035_noparam_leg.sh', 'kmod/w1036_shot77.sh',
        'kmod/_tmp_selftest_rdst/run_verdict35.sh', 'kmod/w413_selftest_sweep.sh',
        'kmod/w986_polround_v4_cfi.ko']

lines = io.open('kmod/DELIVERY.md', encoding='utf8', errors='replace').read().splitlines()
RX = r'`?([\w./\-]+\.(?:sh|py|md|ko|txt|apk|c))`?\s*(?:＝|=|现＝)\s*\**\s*`?([0-9a-f]{8})'
found = {}
for ln, text in enumerate(lines, 1):
    for mm in re.finditer(RX, text):
        nm, claim = mm.group(1), mm.group(2)
        skipped = bool(re.search(m.HIST_BEFORE, text[max(0, mm.start() - 30):mm.end()]))
        if nm in WANT:
            found.setdefault(nm, []).append((ln, claim, skipped))

print('=== 这 12 件里，R9 的视野 ===')
miss = []
for w in WANT:
    real = hashlib.md5(open(w, 'rb').read()).hexdigest()[:8]
    got = found.get(w, [])
    if not got:
        miss.append(w)
        print('  [MISS] %-28s 正则根本没抓到 ⇒ R9 对它没跑过（登记＝没登记）' % w)
    else:
        for ln, claim, sk in got:
            act = 'OK' if real.startswith(claim) else 'DRIFT(登记=%s 实际=%s)' % (claim, real)
            print('  [%s] %-28s L%-4d 登记=%s 实际=%s  被HIST_BEFORE跳过=%s' %
                  ('BAD' if act != 'OK' else 'OK ', w, ln, claim, real, sk))
print('被抓到 %d / 应查 %d ｜ 漏抓 %d' % (len(WANT) - len(miss), len(WANT), len(miss)))

# ★第二遍：DELIVERY.md 里**所有** md5 登记，看被 HIST_BEFORE 跳过的那批里有多少其实已经过期。
#   一个 30 字符的回看可能捞到**邻近那条登记**的"当时/旧"字样 ⇒ 该验的现行值被静默跳过(例 199 同族)。
tot = skipped = drift_skipped = 0
print('\n=== 全表：被 HIST_BEFORE 跳过的登记(逐条看它其实过期没) ===')
for ln, text in enumerate(lines, 1):
    for mm in re.finditer(RX, text):
        nm, claim = mm.group(1), mm.group(2)
        if not os.path.exists(nm):
            continue
        tot += 1
        real = hashlib.md5(open(nm, 'rb').read()).hexdigest()[:8]
        if re.search(m.HIST_BEFORE, text[max(0, mm.start() - 30):mm.end()]):
            skipped += 1
            if not real.startswith(claim):
                drift_skipped += 1
                print('  [已过期却被跳过] L%-4d %-40s 登记=%s 实际=%s  回看那截=%s'
                      % (ln, nm, claim, real, text[max(0, mm.start() - 30):mm.start()].replace('\n', ' ')[-28:]))
print('登记总数=%d 被跳过=%d 其中其实过期=%d(⇒ 这些条 R9 从没验过) 未过期=%d'
      % (tot, skipped, drift_skipped, skipped - drift_skipped))

