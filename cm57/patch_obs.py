# -*- coding: utf-8 -*-
"""给 pr.c 打观测补丁: 每相至少打一行载荷日志 + 幂等重放探针 + 每相 600 发上限。"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

a = 'static volatile int h_phase;                 /* \u5f53\u524d\u76f8 */'
b = ('static volatile int h_phase;                 /* \u5f53\u524d\u76f8 */\n'
     'static int h_lastlog = -1;   /* \u53ea\u4e3a\u4e86\u201c\u6bcf\u76f8\u81f3\u5c11\u6253\u4e00\u884c\u8f7d\u8377\u65e5\u5fd7\u201d */')
assert a in s
s = s.replace(a, b)

a2 = '    if (verbose)\n      say("[W] \\u76f8%d'
a2 = a2.replace('\\u76f8', u'相')
old = '    if (verbose)\n      say("[W] \u76f8%d: C=%lx P=%lx \u5047lock=%lx(+0x60) np=%d prio=%d\\n", ph,'
new = ('    if (verbose || ph != h_lastlog) {\n      h_lastlog = ph;\n'
       '      say("[W] \u76f8%d: C=%lx P=%lx \u5047lock=%lx(+0x60) np=%d prio=%d\\n", ph,')
assert old in s
s = s.replace(old, new)

old3 = 'static int ROUNDS_MAX = 4000;'
assert old3 in s
s = s.replace(old3, 'static int ROUNDS_MAX = 600;')

old4 = '      } else {\n        ssize_t nl = read_cmdline(nb, sizeof nb);'
new4 = ('      } else {\n'
        '        char nm2[256];\n'
        '        read_sysname(nm2, sizeof nm2);\n'
        '        if (strcmp(nm2, p0name)) {\n'
        '          say("[X] \u76f8%d \u4e4b\u540e sysname \u53c8\u53d8\u4e86(= \u6253\u7684\u8fd8\u662f\u4e0a\u4e00\u76f8\u7684\u5e42\u7b49\u8f7d\u8377):\\n%s\\n",\n'
        '              phase, nm2);\n'
        '          strcpy(p0name, nm2);\n'
        '        }\n'
        '        ssize_t nl = read_cmdline(nb, sizeof nb);')
assert old4 in s
s = s.replace(old4, new4)

io.open(p, 'w', encoding='utf-8').write(s)
print('patched ok')
