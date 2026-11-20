import io
import sys

BS = chr(92)
QT = chr(34)
path = sys.argv[1]
lines = io.open(path, encoding="utf-8").read().split(chr(10))


def nq(l):
    c = 0
    i = 0
    while i < len(l):
        if l[i] == BS:
            i += 2
            continue
        if l[i] == QT:
            c += 1
        i += 1
    return c


out = []
fixed = 0
i = 0
while i < len(lines):
    l = lines[i]
    if nq(l) % 2 == 1 and i + 1 < len(lines) and lines[i + 1].lstrip().startswith(QT):
        out.append(l + BS + "n" + lines[i + 1])
        fixed += 1
        i += 2
        continue
    out.append(l)
    i += 1

io.open(path, "w", encoding="utf-8", newline="").write(chr(10).join(out))
print("补回被吃掉的换行转义 %d 处" % fixed)
