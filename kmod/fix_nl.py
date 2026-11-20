import io, sys

for P in sys.argv[1:]:
    lines = io.open(P, encoding="utf-8").read().split(chr(10))
    n = 0
    for i in range(1, len(lines)):
        prev = lines[i - 1].rstrip()
        cur = lines[i]
        if prev.endswith("+ NL") and cur.lstrip().startswith('"'):
            ind = len(cur) - len(cur.lstrip())
            lines[i] = cur[:ind] + "+ " + cur[ind:]
            n += 1
    io.open(P, "w", encoding="utf-8", newline="").write(chr(10).join(lines))
    print("%s: 补了 %d 个 +" % (P, n))
