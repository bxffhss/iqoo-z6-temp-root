# -*- coding: utf-8 -*-
"""fix_this_module.py — 把 kbuild 产出的 .ko 里的 `.gnu.linkonce.this_module` 换成**设备**的布局。

为什么需要它（2026-09-30 实测）：
  设备的 `struct module` = sizeof 960 / name@24 / init@392 / exit@888
  （从厂商 -qgki .ko 量出，且我们手搓的 960 字节版本已在真机加载并被内核回调）。
  而 ACK 5.4.281 树（哪怕配上 LTO_CLANG+THINLTO+CFI_CLANG）算出来是 896 / 24 / 376 / 824，
  mainline 5.4.281 树的 init 更是在 336 —— 缺的 64 字节来自厂商对 struct module 自己的改动，
  拿不到厂商源码就对不上（vivo 的 GPL 站点今天探过：gpl.vivo.com 不解析）。
  内核 `parse_simple_elf` 里 `mod = (void*)sechdrs[index.mod].sh_addr`，即**它把这段内存当
  struct module 用并写满 960 字节** ⇒ 896 的段会被越界写坏后面的内容。

做法（不动原数据、只追加一段，最安全）：
  1) 文件末尾追加 960 字节的新 blob（偏移 24 处写 name，其余全零）；
  2) 该段 sh_offset 指过去、sh_size 改 960；
  3) `.rela.gnu.linkonce.this_module` 里**按符号名**把 init_module 那条的 r_offset 改成 392、
     cleanup_module 那条改成 888（指针值本来就由重定位给出，段内容留零即可）。
  relocatable ELF 的重定位偏移与 st_value 都是**段内相对** ⇒ 搬 sh_offset 不影响它们。

用法: python kmod/fix_this_module.py <输入.ko> <输出.ko> [模块名]
判据: 改完必须过 `python kmod/check_ko.py <输出.ko> analysis/Module.symvers_dev`
"""
import struct
import sys

DEV_SIZE = 960
DEV_NAME = 24
DEV_INIT = 392
DEV_EXIT = 888
ZERO = bytes([0])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    name_arg = sys.argv[3] if len(sys.argv) > 3 else None
    b = bytearray(open(src, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 2:
        sys.exit('只支持 ELF64')
    e_shoff, = struct.unpack_from('<Q', b, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)

    def shdr(i):
        return e_shoff + i * e_shentsize

    def get(i):
        f = struct.unpack_from('<IIQQQQIIQQ', b, shdr(i))
        return dict(name=f[0], type=f[1], flags=f[2], addr=f[3], off=f[4],
                    size=f[5], link=f[6], info=f[7], align=f[8], entsize=f[9], idx=i)

    shstr = get(e_shstrndx)

    def cstr(base, off):
        raw = bytes(b[base + off:])
        return raw[:raw.index(ZERO)].decode('ascii', 'replace') if raw else ''

    tm = rl = None
    for i in range(e_shnum):
        h = get(i)
        n = cstr(shstr['off'], h['name'])
        if n == '.gnu.linkonce.this_module':
            tm = h
        elif n == '.rela.gnu.linkonce.this_module':
            rl = h
    if tm is None:
        sys.exit('找不到 .gnu.linkonce.this_module 段')
    print('原段: off=0x%x size=%d align=%d' % (tm['off'], tm['size'], tm['align']))

    # 模块名：优先命令行，其次原段里 offset 24 处那一份
    name = name_arg
    if not name:
        old = bytes(b[tm['off'] + DEV_NAME: tm['off'] + DEV_NAME + 56]).split(ZERO)[0]
        name = old.decode('ascii', 'replace') or 'module'

    # 1) 追加 960 字节的新 blob
    blob = bytearray(DEV_SIZE)
    nb = name.encode('ascii') + ZERO
    if len(nb) > 56:
        sys.exit('模块名太长(>56)')
    blob[DEV_NAME:DEV_NAME + len(nb)] = nb
    newoff = len(b)
    if tm['align'] > 1:
        b += ZERO * ((-newoff) % tm['align'])
        newoff = len(b)
    b += blob

    # 2) 改 sh_offset / sh_size
    struct.pack_into('<Q', b, shdr(tm['idx']) + 24, newoff)
    struct.pack_into('<Q', b, shdr(tm['idx']) + 32, DEV_SIZE)

    # 3) 按符号名搬重定位（**不要硬编码树算出的偏移**：实测不同树给的是 336 或 376）
    if rl is None:
        sys.exit('没有 .rela.gnu.linkonce.this_module ⇒ mod->init/.exit 会是 NULL ⇒ init 被静默跳过')
    st = get(rl['link'])
    strtab = get(st['link'])

    def symname(idx):
        o = st['off'] + idx * 24
        return cstr(strtab['off'], struct.unpack_from('<I', b, o)[0])

    moved = {'init': 0, 'exit': 0}
    for i in range(rl['size'] // 24):
        o = rl['off'] + i * 24
        roff, rinfo = struct.unpack_from('<QQ', b, o)
        sym = symname(rinfo >> 32)
        base = sym.split('.')[0]
        tgt = DEV_INIT if base == 'init_module' else (DEV_EXIT if base == 'cleanup_module' else None)
        if tgt is None:
            print('  rela[%d] 0x%x 符号=%s 不动' % (i, roff, sym))
            continue
        struct.pack_into('<Q', b, o, tgt)
        moved['init' if tgt == DEV_INIT else 'exit'] += 1
        print('  rela[%d] 符号=%s r_offset 0x%x -> 0x%x' % (i, sym, roff, tgt))
    if moved['init'] != 1 or moved['exit'] != 1:
        sys.exit('init/exit 重定位应各恰好 1 条，实际 %s ⇒ 停（布局与预期不符）' % moved)

    open(dst, 'wb').write(b)
    print('已写出 %s (%d 字节; this_module size=%d name=%s init@%d exit@%d)'
          % (dst, len(b), DEV_SIZE, name, DEV_INIT, DEV_EXIT))


main()
