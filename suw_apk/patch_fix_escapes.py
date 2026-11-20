#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""修上一步 patch_jni_steps.py 里被 python 展开成真实换行的 C 字符字面量。
   (本机老坑：heredoc/普通字符串里的 '\\n' 会变成真换行；一律用 chr(10)/chr(9) 拼。)"""
import io
import sys

P = "suw_apk/suwksu_jni.c"
NL = chr(10)
TAB = chr(9)
SQ = chr(39)

s = io.open(P, encoding="utf-8", errors="replace").read()

fixes = [
    # kstep 里：line[n++] = '<NL>';
    ("        line[n++] = '" + NL + "';",
     "        line[n++] = " + SQ + NL + SQ + ";"),
    # fld 里：while (*q == ' ' || *q == '<TAB>')  以及 strchr(out, '<NL>')
    ("strchr(out, '" + NL + "')",
     "strchr(out, " + SQ + NL + SQ + ")"),
    ("while (*q == ' ' || *q == '" + TAB + "')",
     "while (*q == " + SQ + " " + SQ + " || *q == " + SQ + TAB + SQ + ")"),
    # 子进程里可能同样被展开的 "%d %d %u %u<NL>"
    ('snprintf(line, sizeof line, "%d %d %u %u' + NL + '", r, e,',
     'snprintf(line, sizeof line, "%d %d %u %u' + chr(92) + NL + '", r, e,'),
]

n = 0
for a, b in fixes:
    c = s.count(a)
    if c:
        s = s.replace(a, b)
        n += c
    else:
        print("  (这个形状没出现，跳过: %r)" % a[:40])

io.open(P, "w", encoding="utf-8", newline=NL).write(s)
print("修了 %d 处" % n)
