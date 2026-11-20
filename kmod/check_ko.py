# -*- coding: utf-8 -*-
"""手搓 .ko 的离线自检：不碰设备就把"内核会不会收这个模块"判掉一大半。

用法: python check_ko.py <模块.ko> [<Module.symvers 参照表>] [<设备 kallsyms 表>]

查四件事(都是内核 load_module()/parse_sections() 真会查的):
  1) vermagic 是否与厂商 -qgki .ko 里那条**逐字**相同(不同 ⇒ EINVAL);
  2) license=GPL 在不在(引用 EXPORT_SYMBOL_GPL 的符号时没有它会被拒);
  3) __versions 段: 是否 64 字节定长、每条 CRC 是否与参照表一致、module_layout 在不在;
  4) 还有哪些**未定义符号**没有对应的 __versions 条目(内核会 "disagrees about version
     of symbol X" / "Unknown symbol X" 直接拒 —— 这一条最容易漏)。
"""
import sys as _s
if hasattr(_s.stdout,"reconfigure"):_s.stdout.reconfigure(encoding="utf-8",errors="replace")
import struct
import sys

NAMELEN = 56          # MODULE_NAME_LEN, 内核里 __versions 的名字字段
ENT = 8 + NAMELEN     # {u64 crc; char name[56];} = 64, crc 在前(2026-09-29 实测)


def elf_sections(blob):
    assert blob[:4] == b"\x7fELF", "不是 ELF"
    if (blob[4], blob[5]) != (2, 1):
        sys.exit("只支持 ELF64 小端")
    e_shoff, = struct.unpack_from("<Q", blob, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", blob, 0x3a)
    raw = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, \
            sh_info, sh_addralign, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", blob, o)
        raw.append(dict(idx=i, name=sh_name, type=sh_type, off=sh_offset, size=sh_size,
                        link=sh_link, info=sh_info, entsize=sh_entsize))
    shstr = raw[e_shstrndx]

    def cstr(base, off):
        s = blob[base + off:]
        z = s.index(b"\0") if b"\0" in s else len(s)
        return s[:z].decode('ascii', 'replace')

    secs = {}
    byidx = {}
    for h in raw:
        h['n'] = cstr(shstr['off'], h['name'])
        secs[h['n']] = h
        byidx[h['idx']] = h
    return secs, byidx


def undefined_syms(blob, secs, byidx):
    """.symtab 里 st_shndx==SHN_UNDEF(0) 的符号 = 需要内核提供的"""
    st = secs.get('.symtab')
    if not st:
        return []
    strtab = byidx[st['link']]
    out = []
    n = st['size'] // 24
    for i in range(n):
        o = st['off'] + i * 24
        st_name, st_info, st_other, st_shndx, st_value, st_size = \
            struct.unpack_from("<IBBHQQ", blob, o)
        # 只要 st_shndx==SHN_UNDEF 且有名字就算一条未定义引用:
        # 链接器常把纯被调用的外部函数标成 NOTYPE(0) 而不是 FUNC(2) —— 只按 FUNC 筛会漏
        if st_shndx == 0 and st_name:
            n = cstr_at(blob, strtab['off'], st_name)
            if n and n[0] not in '.$':
                out.append(n)
    return out


def defined_syms(blob, secs, byidx):
    """模块自己定义的全局符号(内核会把它们抄进 module->core_kallsyms)"""
    st = secs.get('.symtab')
    if not st:
        return set()
    strtab = byidx[st['link']]
    out = set()
    for i in range(st['size'] // 24):
        o = st['off'] + i * 24
        st_name, st_info, st_other, st_shndx, st_value, st_size = \
            struct.unpack_from("<IBBHQQ", blob, o)
        if st_shndx > 0 and (st_info >> 4) == 1:        # STB_GLOBAL 且不是 UND
            out.add(cstr_at(blob, strtab['off'], st_name))
    return out


def cstr_at(blob, base, off):
    s = blob[base + off:]
    z = s.index(b"\0") if b"\0" in s else len(s)
    return s[:z].decode('ascii', 'replace')


def load_kallsyms(path):
    """设备 kallsyms 导出：地址 类型 名字。用来区分"没导出"和"根本没有"。"""
    out = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 3 and len(p[1]) == 1:
                out[p[2]] = p[1]
    return out


def load_symvers(path):
    """标准 Module.symvers: CRC \t 符号 \t 模块 \t 导出类型 [\t namespace]"""
    table = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for ln in f:
            p = ln.rstrip('\n').split('\t')
            if len(p) < 4 or not p[0].startswith('0x'):
                continue
            table[p[1]] = (int(p[0], 16), p[3], p[4] if len(p) > 4 else '')
    return table


def main():
    ko = sys.argv[1]
    ref = sys.argv[2] if len(sys.argv) > 2 else None
    blob = open(ko, 'rb').read()
    secs, byidx = elf_sections(blob)
    bad = 0

    print('== %s (%d 字节) ==' % (ko, len(blob)))
    print('段:', ', '.join('%s(%d)' % (k, v['size']) for k, v in secs.items()
                          if v['size'] and not k.startswith('.rel') and k != '.symtab'
                          and k != '.strtab' and k != '.shstrtab'))

    mi = secs.get('.modinfo')
    tags = {}
    if mi:
        for raw in blob[mi['off']:mi['off'] + mi['size']].split(b'\0'):
            if not raw:
                continue
            s = raw.decode('ascii', 'replace')
            k, _, v = s.partition('=')
            tags[k] = v
    else:
        sys.exit("!! 没有 .modinfo 段 ⇒ 内核第一步就 ENOEXEC")

    vm = tags.get('vermagic', '')
    print('vermagic = [%s]' % vm)
    if not vm:
        print('!! 缺 vermagic'); bad += 1
    lic = tags.get('license', '')
    print('license  = [%s]   name = [%s]' % (lic, tags.get('name', '')))
    if lic.upper() != 'GPL':
        print('!! license 不是 GPL ⇒ 引用 EXPORT_SYMBOL_GPL 符号会被拒'); bad += 1

    vi = secs.get('__versions')
    have = {}
    if not vi:
        print('!! 没有 __versions 段 ⇒ versindex==0 ⇒ check_version 走 try_to_force_load；'
              '本机 # CONFIG_MODULE_FORCE_LOAD is not set ⇒ -ENOEXEC(Exec format error)，'
              '第一枪在 module_layout 的准入检查上(§6.138 一手)'); bad += 1
    else:
        if vi['size'] % ENT:
            print('!! __versions 大小 %d 不是 %d 的整数倍(条目布局错了)' % (vi['size'], ENT))
            bad += 1
        for i in range(vi['size'] // ENT):
            o = vi['off'] + i * ENT
            crc, = struct.unpack_from("<Q", blob, o)
            nb = blob[o + 8:o + 8 + NAMELEN]
            name = nb[:nb.index(b'\0')].decode('ascii', 'replace')
            have[name] = crc
        print('__versions = %d 条' % len(have))
        if 'module_layout' not in have:
            print('!! 缺 module_layout 那条(准入检查)'); bad += 1

    table = load_symvers(ref) if ref else None
    if table is not None:
        print('参照表 %s: %d 个符号' % (ref, len(table)))
        for name, crc in sorted(have.items()):
            e = table.get(name)
            if e is None:
                print('  [x] %-24s 参照表里没有这个符号(它不是导出符号?)' % name); bad += 1
            elif e[0] != crc:
                print('  [x] %-24s 写的 0x%08x 但表里是 0x%08x' % (name, crc, e[0])); bad += 1
            else:
                print('  [ok] %-24s 0x%08x  %s %s' % (name, crc, e[1], e[2] or ''))

    # .gnu.linkonce.this_module: 内核把 struct module 直接放在这个段里(parse_simple_elf:
    # mod = sechdrs[index.mod].sh_addr)。缺它 = "No module found in object" + ENOEXEC。
    # 960/64 是从厂商 -qgki .ko 量出来的本机 sizeof(struct module)。
    MIN_TM = int(('%.0f' % 960))
    tm = secs.get('.gnu.linkonce.this_module')
    if tm is None:
        print('!! 没有 .gnu.linkonce.this_module 段 ⇒ 内核 "No module found in object" 直接 ENOEXEC')
        bad += 1
    elif tm['size'] < MIN_TM:
        print('!! .gnu.linkonce.this_module 只有 %d 字节, 本机 sizeof(struct module)=960'
              ' ⇒ 内核写进来会越界' % tm['size'])
        bad += 1
    else:
        # mod->name 是**模块镜像自己预填**的(内核不给它赋值), offsetof=24(三个厂商 .ko 一致)。
        # 空名 ⇒ mod_sysfs_init 的 kobject 注册报 "empty name" WARNING + EINVAL(22)
        blob_at = tm['off'] + 24
        nm = blob[blob_at:blob_at + 56].split(b'\0')[0].decode('ascii', 'replace')
        print('this_module 段 = %d 字节, mod->name(offset 24) = [%s]' % (tm['size'], nm))
        if not nm:
            print('!! .gnu.linkonce.this_module 偏移 24 处是空的 ⇒ kobject 空名 + EINVAL'); bad += 1
        elif tags.get('name') != nm:
            print('!! 预填的 name [%s] 与 .modinfo 的 name [%s] 不一致' % (nm, tags.get('name')))
            bad += 1

    # arm64 的 module_frob_arch_sections() 要这三个段名(缺 .plt/.init.plt = ENOEXEC)
    for req in ('.plt', '.init.plt', '.text.ftrace_trampoline', '.symtab'):
        if secs.get(req) is None:
            print('!! 缺段 %s ⇒ 内核 module_frob_arch_sections/parse_simple_elf 会直接拒' % req)
            bad += 1
    if not any(k.startswith('.rela') for k in secs):
        print('!! 一个 .rela* 段都没有 ⇒ 链接器把引用折进去了，内核不会再解析(可疑)'); bad += 1
    print('重定位段: %s' % ', '.join(sorted(k for k in secs if k.startswith('.rela'))))

    # kCFI(CONFIG_CFI_CLANG=y 且非 permissive)：模块必须自带 __cfi_check，
    # 否则内核 cfi_slowpath_handler 里 check==NULL -> handle_cfi_failure -> panic。
    syms = defined_syms(blob, secs, byidx)
    if '__cfi_check' not in syms:
        print('!! 没有全局符号 __cfi_check ⇒ 内核调模块函数时 check=NULL，本机非 permissive 直接 panic')
        bad += 1
    else:
        print('__cfi_check 在符号表里 (kCFI 入口由我们自己提供)')

    # mod->init/.exit 必须靠重定位填上(偏移 392/888)，否则 init 被静默跳过 = 白加载
    rl = [k for k in secs if k == '.rela.gnu.linkonce.this_module']
    print('.rela.gnu.linkonce.this_module: %s' % (rl or '没有!'))
    if not rl:
        print('!! 没有指向 this_module 的重定位 ⇒ mod->init 会是 NULL ⇒ init 根本不会跑'); bad += 1

    # ★★这里曾经是闸门的洞：老写法 `not s.startswith('__')` 把 **双下划线开头的符号全跳过了**，
    # 而"存在但未导出"的符号恰好扎堆在这儿(__set_fixmap / __arm64_sys_close /
    # __arm64_sys_setns / __tracepoint_sys_enter) ⇒ 闸门报"可以上机"，加载却 -ENOENT。
    # 现在：只跳真正由链接器/plugin 造的噪音，其它一律要 __versions 条目。
    NOISE = ('__UNIQUE_ID', '__PCI', '__vermagic', '__this_module', '__MODULE_',
             '__KBUILDMOD', '__UNDEF__')
    BUILTIN = ('memset', 'memcpy', 'memcmp', 'memmove', '__memset', '__memcpy',
               '__memmove', '__bzero', '__cmkgs2o8', '__stack_chk_guard')
    need = [s for s in undefined_syms(blob, secs, byidx)
            if s and not s.startswith(NOISE) and s not in BUILTIN and s[0] not in '.$']
    missing = sorted(set(need) - set(have))
    print('未定义引用: %d 个' % len(set(need)))
    if missing:
        # 有设备 kallsyms 时把"存在但未导出"单独点出来 —— 它的修法不是换 CRC，是自己转发。
        ks = load_kallsyms(sys.argv[3]) if len(sys.argv) > 3 else None
        unexp = [s for s in missing if ks and s in ks]
        gone = [s for s in missing if not (ks and s in ks)]
        print('!! 这些符号在 __versions 表里没有条目(内核行为见 module.c:check_version)：')
        print('   · 段在、条目查不到 ⇒ `pr_warn_once("no symbol version for X")` 然后 **放过去**'
              '(⇒ 空表可以当"不校验 CRC"的变体用，见 §6.138/#57)；')
        print('   · 条目在、CRC 不符 ⇒ "disagrees about version of symbol" ⇒ -EINVAL；')
        print('   · 符号根本不在 kallsyms ⇒ "Unknown symbol X (err -2)" ⇒ finit_module -ENOENT；')
        print('   · 段整个不见了 ⇒ versindex==0 走 try_to_force_load，本机没编 '
              'CONFIG_MODULE_FORCE_LOAD ⇒ **-ENOEXEC(Exec format error)**，且第一枪打在 module_layout 上。')
        if unexp:
            print('   [存在于内核但没导出] %s' % ', '.join(unexp))
            print('   ⇒ 修法：在**本模块内**定义同名转发函数(kprobe 只能取文本符号，数据符号要走 '
                  'kallsyms_lookup_name)，`__tracepoint_*` 这类数据符号**绝不能自己造同名对象**(静默假阳)。')
        if gone:
            print('   [%s] %s' % ('本机根本没有' if ks is not None else '未导出或根本没有',
                                  ', '.join(gone)))
        bad += 1

    print('判定: %s' % ('可以上机' if bad == 0 else '%d 处不对, 先别上机' % bad))
    sys.exit(1 if bad else 0)


main()
