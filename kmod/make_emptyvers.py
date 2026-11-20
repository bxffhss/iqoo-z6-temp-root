#!/usr/bin/env python
# make_emptyvers.py —— #57 的第二个变体：**保留 `__versions` 段表项、把 sh_size 归零**。
#
# 为什么必须是这个形状(2026-10-05 在 hermes-remote 的 /root/k/linux-5.4.281/kernel/module.c 里读死)：
#   check_version():
#     if (versindex == 0) return try_to_force_load(...) == 0;      # 段"找不到"才走这支
#     num_versions = sechdrs[versindex].sh_size / sizeof(*versions);
#     for (i = 0; i < num_versions; i++) {...比对 CRC...}
#     pr_warn_once("no symbol version for %s"); return 1;          # 表里查不到 ⇒ **放过去**
#   try_to_force_load(): #ifdef CONFIG_MODULE_FORCE_LOAD ... #else return -ENOEXEC;
#   设备 config: **# CONFIG_MODULE_FORCE_LOAD is not set** / CONFIG_MODVERSIONS=y
#   check_modstruct_version() 的调用点后面紧跟 `err = -ENOEXEC;`
#   ⇒ 第五十二发删段拿到 Exec format error 的机制被钉死了：`versindex==0` ⇒ 走 force 支 ⇒
#     没编 FORCE_LOAD ⇒ -ENOEXEC，**且第一个被检查的就是 module_layout**，连符号解析都到不了。
#   ⇒ 反过来：段还在(index.vers 非 0)但条目为空(sh_size=0) ⇒ num_versions=0 ⇒ 循环一次不跑 ⇒
#     每个符号都走"查不到就放过"⇒ **CRC 完全不校验，但 vermagic/加载形状不变**。
#     (这正是 Z5 那颗主 ko 的形状：`__versions` 段存在、size=0，见 §6.137。)
#
# 只改 8 个字节(节头里的 sh_size)，段名/flags/link/offset/数据全不动——
# find_sec() 要求 `sh_flags & SHF_ALLOC` 才认这一节，所以 flags 绝不能跟着清。
import sys, struct

src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
orig = bytes(b)          # ★留存原始副本：b 会被就地改，拿 b 当"改之前"比差异永远是 0 字节(上一版就是这么自骗的)
assert b[:4] == b'\x7fELF' and b[4] == 2, "要 ELF64"
e_shoff, = struct.unpack_from('<Q', b, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', b, 0x3a)

def shdr(i):
    o = e_shoff + i * e_shentsize
    # name type flags addr offset size link info addralign entsize
    return o, struct.unpack_from('<IIQQQQIIQQ', b, o)

strtab_off = shdr(e_shstrndx)[1][4]
def nm(x):
    s = b[strtab_off + x:]
    return bytes(s[:s.index(0)]).decode()

rows = []
for i in range(e_shnum):
    o, v = shdr(i)
    rows.append((i, nm(v[0]), v))

target = [r for r in rows if r[1] == '__versions']
assert len(target) == 1, "没找到唯一的 __versions: %r" % [r[1] for r in rows]
i, _, v = target[0]
o = e_shoff + i * e_shentsize
name, stype, flags, addr, offset, size, link, info, align, entsize = v
print("改之前: index=%d type=%d flags=0x%x offset=0x%x size=%d entsize=%d align=%d" %
      (i, stype, flags, offset, size, entsize, align))
assert flags & 0x2, "__versions 在文件里没有 SHF_ALLOC ⇒ find_sec 不会认它，这个变体没意义"
print("条目数 = %d" % (size // (entsize if entsize else 64)))

struct.pack_into('<Q', b, o + 32, 0)          # sh_size 归零(ELF64 节头里偏移 32；24 是 sh_offset)
open(dst, 'wb').write(bytes(b))

# 自查：重新从**写出的文件**里读回来，别信内存里的那份
c = open(dst, 'rb').read()
o2 = e_shoff + i * e_shentsize
v2 = struct.unpack_from('<IIQQQQIIQQ', c, o2)
print("改之后: flags=0x%x size=%d (段名还在=%r, 文件字节数 %d→%d)" %
      (v2[2], v2[5], nm(v2[0]), len(b), len(c)))
assert v2[5] == 0 and v2[2] == flags, "没改成空表"
# ★上一版把 pack 的偏移写成 24(那是 sh_offset)也能"跑通"，靠的就是这两条自查才被点出来：
#   除了 sh_size，一个字节都不许动。
assert v2[4] == offset, "sh_offset 被动了(0x%x→0x%x)：改错了字段" % (offset, v2[4])
diff = [k for k in range(len(c)) if c[k] != orig[k]]
# ★上一版把它写成 `diff == range(o+32, o+40)`(必须正好 8 字节不同)也是错的：
#   10176=0x27C0 的高 6 个字节本来就是 0，"归零"后只有 2 个字节真的变了 ⇒ 判据该是**子集**。
assert diff and set(diff) <= set(range(o + 32, o + 40)), \
    "全文件差异越过了 sh_size 那 8 字节: %r" % diff[:8]
print("[ok] 差异只有 sh_size 里的 %d 个字节(→0)，其余 %d 字节逐字节相同" %
      (len(diff), len(c) - len(diff)))
print("[ok] 写出 %s" % dst)
