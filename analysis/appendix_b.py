#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""appendix_b.py —— 把 fake_seq_scan.py 的 114 个 seq_read fops 清单独入报告附录 B."""
import io, re

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
txt = io.open(AN + r'\_fakeseq_out.txt', encoding='utf-8', errors='replace').read()
sec = txt.split('=== B)')[1].split('合计')[0]
pat = re.compile(r'(\S+)\s+@(0x[0-9a-f]{16})\s+\[(\w)\]\s+sz~(0x[0-9a-f]+).*?\+0x8=(\S+)'
                 r' \+0x10=(\S+) \+0x20=(\S+) \+0x70=(\S+) \+0x80=(\S+)')
rows = [m for m in (pat.search(l.strip()) for l in sec.splitlines()) if m]
out = ['\n---\n\n## 附录 B: %d 个 ".read(+0x10) 链接期就等于 seq_read" 的静态 fops\n\n'
       '全部 kallsyms 类型字母 = `d`/`D`(**可写 .data**); `.read_iter(+0x20)` 全为 0; '
       '`.open(+0x70)` 全是 seq/single 家族 ⇒ 运行时 private_data = 堆上 seq_file。\n'
       '这是 fake-seqfile 路线"目标 fops 存在、但 private_data 拿不到静态对象"的完整证据表。\n\n'
       '| fops | 地址 | 段 | 尺寸 | .llseek | .open | .release |\n'
       '|---|---|---|---|---|---|---|\n']
for m in rows:
    out.append('| %s | `%s` | %s | %s | %s | %s | %s |\n' %
               (m.group(1), m.group(2), m.group(3), m.group(4),
                m.group(5), m.group(8), m.group(9)))
out.append('\n(共 %d 行)\n' % len(rows))
io.open(AN + r'\FAKE-SEQFILE-READ-GADGET-20260928.md', 'a', encoding='utf-8').write(''.join(out))
print('rows', len(rows))
