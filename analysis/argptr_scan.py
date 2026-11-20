# -*- coding: utf-8 -*-
"""argptr_scan.py —— 对 unlocked_ioctl 同类型表(含 ashmem_ioctl 的那一行)全部成员做
"arg(x2) 是否被当作内核指针使用" 的污点扫描。离线: 只读 kernel.bin + kallsyms。
用法: PYTHONIOENCODING=utf-8 python argptr_scan.py > argptr_scan_out.json
"""
import io, re, sys, bisect, json
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from capstone.arm64 import *

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
BASE = 0xffffffc010080000
CAP = 6000

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
data = io.open(IMG, 'rb').read()
addr2names = {}
for a, t, n in syms:
    addr2names.setdefault(a, []).append((t, n))

def name_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    return syms[i][2], a - syms[i][0], syms[i][1]

def exact_start(a):
    ns = addr2names.get(a)
    if not ns:
        return None
    for t, n in ns:
        if t in 'TtWVw':
            return n.split('$')[0]
    return ns[0][1].split('$')[0]

def func_end(a):
    i = bisect.bisect_right(addrs, a)
    return addrs[i] if i < len(addrs) else a + 4 * CAP

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

def norm_reg(rn):
    if not rn:
        return rn
    if rn[0] == 'w':
        return 'x' + rn[1:]
    return rn

def classify_callee(nm):
    if nm is None:
        return None
    n = nm.split('.')[0].split('$')[0]
    K = {}
    for x in ['_copy_from_user', '__copy_from_user', 'copy_from_user', 'raw_copy_from_user',
              '__arch_copy_from_user', 'copy_from_user_nofault', '_inline_copy_from_user']:
        K[x] = 'ufrom'   # x0=kernel to (W-hit if tainted), x1=user from (normal)
    for x in ['_copy_to_user', '__copy_to_user', 'copy_to_user', 'raw_copy_to_user',
              '__arch_copy_to_user', 'copy_to_user_nofault', '_inline_copy_to_user']:
        K[x] = 'uto'     # x0=user to (normal), x1=kernel from (R-hit)
    K['strncpy_from_user'] = 'ufrom'
    K['strnlen_user'] = 'uaddr0'   # x0=user 串地址(正常), x1=maxlen
    K['strlen_user'] = 'uaddr0'
    K['valid_user_pointer'] = 'uaddr0'
    K['simple_read_from_buffer'] = 'srfb'   # x0=to(user) x3=from(kernel)
    K['simple_write_to_buffer'] = 'swtb'    # x0=to(kernel) W-hit
    for x in ['memcpy', 'memmove', '__memcpy', '__memmove', 'strcpy', 'strscpy', 'strncpy', 'stpcpy', 'kstrdup']:
        K[x] = 'copy2'   # x0 W, x1 R
    for x in ['memset', '__memset', 'memzero', 'memzero_explicit']:
        K[x] = 'set0'
    for x in ['memcmp', '__memcmp', 'bcmp', 'strncmp', 'strcmp']:
        K[x] = 'cmp2'
    for x in ['strlen', 'strnlen', 'strstr', 'memchr']:
        K[x] = 'ro0'
    for x in ['kfree', 'kvfree', 'vfree']:
        K[x] = 'free0'
    K['set_fs'] = 'setfs'
    K['access_ok'] = 'guard'
    for x in ['mutex_lock', 'mutex_lock_interruptible', 'mutex_trylock', 'mutex_unlock',
              '_raw_spin_lock', '_raw_spin_lock_irq', '_raw_spin_lock_irqsave', 'spin_lock',
              'spin_lock_irqsave', 'down_read', 'down_write', 'up_read', 'up_write', 'refcount_set']:
        K[x] = 'lock0'
    return K.get(n)

def scan(start, ptr_sources, depth_note):
    end = func_end(start)
    size = (end - start) // 4
    full = size <= CAP
    n = min(CAP, size if size > 0 else CAP)
    off = start - BASE
    if off < 0 or off + 4 * n > len(data):
        return [], False
    insns = list(md.disasm(data[off:off + 4 * n], start))
    taint = {}
    for r, v in ptr_sources.items():
        taint[norm_reg(r)] = v
    slots = {}
    events = []

    def ev(pc, kind, note, line=None, callee=None):
        events.append(dict(pc=pc, kind=kind, note=note, callee=callee,
                           line=line, depth=depth_note))

    for ins in insns:
        m = ins.mnemonic
        ops = ins.operands
        rawtext = '%s %s' % (m, ins.op_str)
        if m in ('bl', 'b'):
            tgt = None
            for o in ops:
                if o.type == ARM64_OP_IMM:
                    tgt = o.imm & 0xFFFFFFFFFFFFFFFF
            cn = exact_start(tgt) if tgt is not None else None
            near = name_at(tgt) if tgt is not None else None
            kind = classify_callee(cn)
            taint_before = dict(taint)   # 调用点寄存器状态(参数在此)
            if kind:
                taint = taint_before
                if kind == 'ufrom':
                    if taint.get('x0', ('',))[0] == 'ptr':
                        ev(ins.address, 'WRITE-kernel-dst', 'copy_from_user/strncpy_from_user 目的(x0)=arg 派生 => arg 被当内核缓冲', rawtext, cn)
                    if taint.get('x1', ('',))[0] == 'ptr':
                        ev(ins.address, 'DIAG-normal-uaccess', 'arg 作为 from(user) 正常校验拷贝(诊断用)', rawtext, cn)
                if kind == 'uto':
                    if taint.get('x1', ('',))[0] == 'ptr':
                        ev(ins.address, 'READ-kernel-src', 'copy_to_user 源(x1)=arg 派生 => arg 被当内核源', rawtext, cn)
                    if taint.get('x0', ('',))[0] == 'ptr':
                        ev(ins.address, 'DIAG-normal-uaccess', 'arg 作为 to(user) 正常校验拷贝(诊断用)', rawtext, cn)
                if kind == 'uaddr0' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'DIAG-normal-uaccess', 'arg 作为被校验 user 地址(strnlen/strndup)', rawtext, cn)
                if kind == 'srfb' and taint.get('x3', ('',))[0] == 'ptr':
                    ev(ins.address, 'READ-kernel-src', 'simple_read_from_buffer from(arg)', rawtext, cn)
                if kind == 'swtb' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'WRITE-kernel-dst', 'simple_write_to_buffer to(arg)', rawtext, cn)
                if kind == 'copy2':
                    if taint.get('x0', ('',))[0] == 'ptr':
                        ev(ins.address, 'WRITE-memcpy-dst', 'strcpy/memcpy 目的=arg(内核侧例程)', rawtext, cn)
                    if taint.get('x1', ('',))[0] == 'ptr':
                        ev(ins.address, 'READ-memcpy-src', 'memcpy/strlen 源=arg(内核侧例程)', rawtext, cn)
                if kind == 'set0' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'WRITE-memset', 'memset 目的=arg', rawtext, cn)
                if kind == 'cmp2' and (taint.get('x0', ('',))[0] == 'ptr' or taint.get('x1', ('',))[0] == 'ptr'):
                    ev(ins.address, 'READ-memcmp', 'memcmp/strcmp 读 arg', rawtext, cn)
                if kind == 'ro0' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'READ-kernel-deref-str', 'strlen/strstr 解引用 arg', rawtext, cn)
                if kind == 'free0' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'FREE-arg', 'kfree(arg 派生)', rawtext, cn)
                if kind == 'setfs':
                    ev(ins.address, 'SET_FS', '调用 set_fs: 之后 uaccess 可变内核访问', rawtext, cn)
                if kind == 'lock0' and taint.get('x0', ('',))[0] == 'ptr':
                    ev(ins.address, 'WRITE-LOCK-on-arg', '锁/refcount 落在 arg 派生地址(写原语+潜在死锁)', rawtext, cn)
            elif kind is None and tgt is not None and depth_note == 'top':
                win_end = end
                internal = (start <= tgt < win_end)
                if not internal:
                    ptrargs = {r: taint_before[r] for r in taint_before if r.startswith('x') and r[1:].isdigit()
                               and int(r[1:]) < 8 and taint_before[r][0] == 'ptr'}
                    if ptrargs:
                        sub, sfull = scan(tgt, ptrargs, 'callee')
                        for e in sub:
                            e['kind'] = 'INDIRECT:' + e['kind']
                            e['note'] = '被调 %s(+0x%x) 内部解引用 arg; 调用点 0x%x: %s' % (
                                cn if cn else (near[0] if near else hex(tgt)), near[1] if near else 0, ins.address, rawtext)
                            events.append(e)
                        if not sub and not sfull:
                            ev(ins.address, 'UNRESOLVED-callee', 'callee %s(+0x%x) 过大未完全扫描' % (
                                cn if cn else hex(tgt), near[1] if near else 0), rawtext)
            if m == 'bl':
                for rn in ['x%d' % i for i in range(0, 18)] + ['x30']:
                    taint.pop(rn, None)
            continue
        if m in ('blr', 'br'):
            rn = None
            for o in ops:
                if o.type == ARM64_OP_REG:
                    rn = norm_reg(ins.reg_name(o.reg))
            if rn and taint.get(rn, ('',))[0] == 'ptr':
                ev(ins.address, 'BRANCH-via-arg', '通过 arg 派生寄存器间接转移: ' + rawtext, rawtext)
            for x in ['x%d' % i for i in range(0, 18)] + ['x30']:
                taint.pop(x, None)
            continue
        base_r = idx_r = None
        disp = 0
        memop = False
        for o in ops:
            if o.type == ARM64_OP_MEM:
                memop = True
                base_r = norm_reg(ins.reg_name(o.mem.base)) if o.mem.base else None
                idx_r = norm_reg(ins.reg_name(o.mem.index)) if o.mem.index else None
                disp = o.mem.disp
        if memop:
            is_store = m.startswith('st')
            hitreg = None
            for r in (base_r, idx_r):
                if r and taint.get(r, ('',))[0] in ('ptr', 'val'):
                    if hitreg is None or taint[r][0] == 'ptr':
                        hitreg = r
            if hitreg:
                tg, lab = taint[hitreg]
                tag = 'WRITE' if is_store else 'READ'
                conf = 'HIGH' if tg == 'ptr' else 'MED-chained'
                ev(ins.address, 'DEREF-%s-%s' % (tag, conf), '%s [%s 来自 %s]' % (rawtext, hitreg, lab), rawtext)
            if not is_store and ops and ops[0].type == ARM64_OP_REG:
                d = norm_reg(ins.reg_name(ops[0].reg))
                if hitreg:
                    taint[d] = ('val', '载入自*%s@%x' % (hitreg, ins.address))
                else:
                    taint.pop(d, None)
                if base_r in ('sp', 'x29'):
                    v = slots.get((base_r, disp))
                    if v and d not in taint:
                        taint[d] = v
            else:
                if base_r in ('sp', 'x29'):
                    dregs = [norm_reg(ins.reg_name(o.reg)) for o in ops if o.type == ARM64_OP_REG]
                    if m in ('stp', 'stnp') and len(dregs) >= 2:
                        slots[(base_r, disp)] = taint.get(dregs[0])
                        slots[(base_r, disp + 8)] = taint.get(dregs[1])
                    elif dregs:
                        slots[(base_r, disp)] = taint.get(dregs[0])
            continue
        if not ops:
            continue
        d0 = None
        wide0 = True
        if ops[0].type == ARM64_OP_REG:
            r0 = ins.reg_name(ops[0].reg)
            d0 = norm_reg(r0)
            wide0 = r0[0] != 'w'
        if d0 == 'sp':
            continue
        if m in ('cmp', 'cmn', 'tst', 'cbz', 'cbnz', 'tbz', 'tbnz', 'prfm', 'dc', 'ic', 'msr', 'ret'):
            continue
        srcs = []
        for o in ops[1:]:
            if o.type == ARM64_OP_REG:
                rn = ins.reg_name(o.reg)
                srcs.append((norm_reg(rn), rn[0] != 'w'))
        ptrs = [(r, w) for r, w in srcs if r in taint and taint[r][0] == 'ptr']
        vals = [(r, w) for r, w in srcs if r in taint and taint[r][0] == 'val']
        if m in ('mov', 'add', 'sub', 'and', 'orr', 'bic', 'eor', 'neg', 'adc', 'sbc', 'madd',
                 'msub', 'csel', 'csinc', 'csinv', 'csneg', 'sxtw', 'sxth', 'ubfm', 'sbfm', 'bfm', 'ror'):
            if d0:
                if wide0 and ptrs:
                    taint[d0] = ('ptr', 'arg<-经 %s @%x' % (ptrs[0][0], ins.address))
                elif ptrs or vals:
                    s = (ptrs or vals)[0]
                    taint[d0] = ('val', 'arg 的派生值(32位/运算) @%x' % ins.address) if not wide0 else ('ptr', 'arg<-经 %s @%x' % (s[0], ins.address))
                else:
                    taint.pop(d0, None)
            continue
        if d0:
            taint.pop(d0, None)
    # post-pass: <REDACTED> DEREF events that sit inside an uaccess window
    texts = [(i.address, i.mnemonic, i.op_str) for i in insns]
    for e in events:
        if 'DEREF' in e['kind'] or 'INDIRECT' in e['kind']:
            try:
                k = next(j for j, (a, mm, oo) in enumerate(texts) if a == e['pc'])
            except StopIteration:
                continue
            lo, hi = max(0, k - 80), min(len(texts), k + 40)
            guarded = any('ttbr0_el1' in oo and mm in ('msr', 'mrs') for a, mm, oo in texts[lo:hi])
            if guarded:
                e['kind'] += '-UAACCESS-GUARDED'
    return events, full

names = []
try:
    names = [l.strip() for l in io.open(r'/tmp/ioctl_names.txt', encoding='utf-8') if l.strip()]
except IOError:
    names = []
if not names:
    # fallback: parse directly from table file line containing ashmem_ioctl
    for line in io.open(r'G:\项目\Windows管理\usb\临时root\analysis\cfi_type_tables.txt', encoding='utf-8', errors='replace'):
        if 'ashmem_ioctl' in line:
            body = line.split('  ', 1)[1]
            names = [x.strip() for x in body.split('|')]
            break
out = {}
for nm in names:
    a = None
    for addr, t, nn in syms:
        nb = nn.split('$')[0]
        if nb == nm:
            if t in 'TtWVw':
                a = addr
                break
            if a is None:
                a = addr
    if a is None:
        out[nm] = {'error': 'no-symbol'}
        continue
    ev, full = scan(a, {'x2': ('ptr', '入口 x2')}, 'top')
    size = (func_end(a) - a) // 4
    out[nm] = {'addr': hex(a), 'insize': size, 'full': full, 'nhits': len(ev),
               'hits': [dict(pc=hex(e['pc']), kind=e['kind'], note=e['note'],
                             callee=str(e.get('callee')), line=e.get('line'), depth=e.get('depth')) for e in ev]}
import os
json.dump(out, io.open(os.path.join(os.environ.get('TEMP', '.'), 'argptr_scan_out.json'), 'w', encoding='utf-8'), ensure_ascii=True, indent=1)
# console summary
for nm, d in out.items():
    if 'error' in d:
        print('%-40s %s' % (nm, d['error']))
        continue
    st = 'FULL' if d['full'] else ('PARTIAL(%d ins)' % d['insize'])
    print('%-40s %-22s %-8s hits=%d' % (nm, d['addr'], st, d['nhits']))
    for e in d['hits']:
        print('    %s %-28s %s | %s' % (e['pc'], e['kind'], (e['line'] or '')[:44], e['note'][:110]))
