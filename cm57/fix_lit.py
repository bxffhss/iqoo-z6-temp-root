# -*- coding: utf-8 -*-
"""修 pr.c 里两处被 python 转义搞坏的字面量(换行符应当是 C 的 \\n 两个字符)。"""
import io

p = 'pr.c'
b = io.open(p, encoding='utf-8').read()
bad1 = 'say("[HIT] 泄漏相落地(probe 文件变了!) len=%zd = %s' + chr(10) + '", tl, nbh);'
good1 = 'say("[HIT] 泄漏相落地(probe 文件变了!) len=%zd = %s' + chr(92) + 'n", tl, nbh);'
bad2 = 'say("[HIT] probe 头 8 字节 = %016lx  ⇒ .bss 指针可写 + S 已泄漏' + chr(10) + '", (unsigned long)Sx);'
good2 = 'say("[HIT] probe 头 8 字节 = %016lx  ⇒ .bss 指针可写 + S 已泄漏' + chr(92) + 'n", (unsigned long)Sx);'
assert bad1 in b and bad2 in b, (bad1 in b, bad2 in b)
b = b.replace(bad1, good1).replace(bad2, good2)
io.open(p, 'w', encoding='utf-8', newline='').write(b)
print('fixed')
