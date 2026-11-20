# -*- coding: utf-8 -*-
"""ksymtab_layout_probe.py — 先不猜布局: 把 __ksymtab 头几条目的原始字节 + 对应 __kcrctab
的 u32 打出来, 并用 kallsyms 反查 value 字段像不像内核地址。输出纯 ASCII(控制台是 gbk)。"""
import io, os, struct, sys

BASE = r'G:\项目/Windows管理/usb\临时root'
AN = os.path.join(BASE, 'analysis')
KL = os.path.join(AN, 'kallsyms_g2a88cd145def.txt')
IMG = os.path.join(AN, 'kernel_dev_g2a88cd145def.bin')
TEXT_VA = 0xffffffc010080000
TEXT_OFF = None    # 裸 Image 里 _text 的文件偏移(可能是 0, 也可能带 TEXT_OFFSET)

ks = {}
for l in io.open(KL, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3:
        try:
            a = int(p[0], 16)
        except ValueError:
            continue
        ks.setdefault(p[2], (a, p[1]))
img = io.open(IMG, 'rb').read()
print('image bytes =', len(img), ' kallsyms =', len(ks))

for nm in ('__start___ksymtab', '__stop___ksymtab', '__start___kcrctab', '__stop___kcrctab'):
    print(nm, '=%x' % ks[nm][0] if nm in ks else 'MISSING')

s0 = ks['__start___ksymtab'][0]
c0 = ks['__start___kcrctab'][0]
for trial in (0, 8, 0x80000, 0x100000):
    off = s0 - TEXT_VA - trial
    if 0 <= off < len(img) - 96:
        print('\n--- 假设 file = VA - _text - 0x%x ---' % trial)
        for i in range(3):
            e = img[off + i * 24: off + i * 24 + 24]
            print('  entry%d raw = %s' % (i, e.hex()))
            print('     as u64x3 = %s' % ' '.join('%x' % v for v in struct.unpack('<QQQ', e)))
        co = c0 - TEXT_VA - trial
        print('  kcrctab[0..7] = %s' % ' '.join('%08x' % v for v in struct.unpack('<8I', img[co:co + 32])))

# 再看 _stext 在文件里的位置(用来定 trial): 内核第一条指令通常是已知的
t = ks.get('_stext', (None,))[0]
if t:
    for trial in (0, 8, 0x80000, 0x100000):
        off = t - TEXT_VA - trial
        if 0 <= off < len(img) - 8:
            print('\n_stext 假设 trial=0x%x 处 8 字节 = %s' % (trial, img[off:off + 8].hex()))
