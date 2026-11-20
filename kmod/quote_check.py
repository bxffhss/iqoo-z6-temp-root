import io
import sys

BS = chr(92)
QT = chr(34)
path = sys.argv[1]
lines = io.open(path, encoding="utf-8").read().split(chr(10))
bad = []
for n, l in enumerate(lines):
    c = 0
    i = 0
    while i < len(l):
        if l[i] == BS:
            i += 2
            continue
        if l[i] == QT:
            c += 1
        i += 1
    if c % 2 == 1:
        bad.append((n + 1, l[:100].encode("ascii", "replace").decode()))
print("奇数引号的行数 = %d" % len(bad))
for n, l in bad[:15]:
    print(n, l)
