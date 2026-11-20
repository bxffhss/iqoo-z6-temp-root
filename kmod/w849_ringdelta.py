import re, sys, collections

def load(p):
    rows = []
    for ln in open(p, encoding='utf-8', errors='replace'):
        m = re.match(r'\[\s*([0-9]+\.[0-9]+)\]\s(.*)', ln.rstrip('\n'))
        if m:
            rows.append((float(m.group(1)), m.group(2)))
    return rows

a = load(r'analysis/ev/w846/w849_t0.txt')
b = load(r'analysis/ev/w846/w849_t1.txt')
ta = max(t for t, _ in a)
print('t0_last_ts=%.3f  t0_first_ts=%.3f  t0_lines=%d' % (ta, a[0][0], len(a)))
print('t1_last_ts=%.3f  t1_first_ts=%.3f  t1_lines=%d' % (max(t for t,_ in b), b[0][0], len(b)))
new = [(t, s) for t, s in b if t > ta]
print('gap_s=%.3f  new_lines=%d  rate_s=%.1f' % (max(t for t,_ in b)-ta, len(new), len(new)/max(1e-9,(max(t for t,_ in b)-ta))))

def tok(s):
    for k in ('KILLSOFT', 'KILLGUARD', 'KSUBIRTH'):
        if k in s: return k
    if 'SD1 decline' in s: return 'SD1'
    if 'SD0 decline' in s: return 'SD0'
    if 'dispatcher entered' in s: return 'DISP'
    if 'F2 redirect' in s: return 'F2'
    if 'sys_enter fired' in s: return 'FIRED'
    if 'KSUBEAT' in s: return 'KSUBEAT_other'
    return 'NON_KSU'

c = collections.Counter(tok(s) for _, s in new)
print('tokens:', dict(c))

decl_uid = collections.Counter(re.findall(r'SD1 decline: uid=(\d+)', ' '.join(s for _, s in new)))
print('SD1 by uid:', dict(decl_uid))

pc = collections.Counter()
for _, s in new:
    m = re.search(r'pid=(\d+) comm=(\S+)', s)
    if m: pc[(m.group(1), m.group(2))] += 1
print('top pid/comm in gap:', pc.most_common(8))

fired = [int(m.group(1)) for _, s in new for m in [re.search(r'fired#(\d+)', s)] if m]
if len(fired) >= 2:
    print('fired first=%d last=%d delta=%d' % (fired[0], fired[-1], fired[-1]-fired[0]))
print('sample new lines:')
for t, s in new[:3] + new[-3:]:
    print('  %.3f %s' % (t, s[:110]))
