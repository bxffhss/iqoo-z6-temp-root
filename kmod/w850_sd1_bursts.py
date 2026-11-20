import re, collections

rows = []
for ln in open(r'analysis/ev/w846/w849_t1.txt', encoding='utf-8', errors='replace'):
    m = re.match(r'\[\s*([0-9]+\.[0-9]+)\]\s(.*)', ln.rstrip('\n'))
    if m: rows.append((float(m.group(1)), m.group(2)))
print('ring covers %.1f .. %.1f (%d lines, %.1f/s)' % (rows[0][0], rows[-1][0], len(rows),
      len(rows)/(rows[-1][0]-rows[0][0])))

sd1 = [t for t, s in rows if 'SD1 decline' in s]
by_uid = collections.Counter(re.search(r'uid=(\d+)', s).group(1) for t, s in rows if 'SD1 decline' in s)
print('SD1 total=%d by uid=%s' % (len(sd1), dict(by_uid)))

# burst segmentation: a new burst starts when gap > 2s
bursts = []
for t in sd1:
    if bursts and t - bursts[-1][-1] <= 2.0: bursts[-1].append(t)
    else: bursts.append([t])
print('bursts=%d' % len(bursts))
for b in bursts[:20]:
    print('  burst ts=%.1f..%.1f n=%d' % (b[0], b[-1], len(b)))
if len(bursts) > 20:
    print('  ... (%d more)' % (len(bursts)-20))
sizes = collections.Counter(len(b) for b in bursts)
print('burst size histogram:', dict(sorted(sizes.items())))
