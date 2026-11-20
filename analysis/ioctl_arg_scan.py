#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ioctl_arg_scan.py —— unlocked_ioctl 同类型表(165 成员)离线补扫: 形状
    "把 ioctl 的 arg 参数本身当内核指针" 的 handler (CFI-FOPS-TARGETS §7 任务 A)。

背景/几何(承接 analysis/CFI-FOPS-TARGETS-20260927.md):
  我们把 file->f_op 顶成伪 fops 表 S, open("/dev/ashmem") 后
  file->private_data = &ashmem_misc(固定 .data, 不可控)。故旧扫描只找 "pd 派生指针"。
  本脚本换一类污点源: **ioctl 的第三个 C 参数 arg**(= 调用者 ioctl(fd,cmd,arg) 的 arg),
  问: 有没有哪个同类型 handler 把 arg 当作内核地址来 copy/deref(不经过 uaccess),
  从而"不需要可控 pd"就给出地址来自 arg 的内核读/写形状。

ABI 更正(诚实标注): 任务书把 arg 记作 x1。按 unlocked_ioctl 原型
  long (*unlocked_ioctl)(struct file *filp, unsigned int cmd, unsigned long arg)
  与 ARM64 PCS:  x0=filp, w1=cmd, x2=arg。⇒ 本脚本 arg 污点源取 **x2**(w1 是命令号,非指针)。
  既有脚本 argptr_scan.py 同样以 x2 为源, 互相印证。

分类(桶):
  KPTR-COPY   : arg 派生寄存器出现在 uaccess copy 的 **内核侧**槽位
                (_copy_to_user 的 x1=from / _copy_from_user 的 x0=to / simple_read/write / memcpy 内核例程)
  KPTR-DEREF  : 对 arg 派生寄存器直接 ldr/str(内核解引用), 且不在 uaccess(SET_FS/TTBR0) 窗口内
  UNRESOLVED  : 见到可疑 bl/ldr 但 arg->寄存器推导链不清, 原样记录指令, 不猜

覆盖率: 每函数最多反汇编前 CAPINSN=400 条, 且在"下一个 kallsyms 符号起点"截断(优先)。
  size>CAPINSN 者列入 truncated 名单。对 top 函数内 **静态 helper 调用**做一层受限跟进
  (helper 也限 400 条, 结果标 INDIRECT:), 以便捕获 "handler 把 arg 转手交给本地 helper"。

离线: 只读 kernel_dev_*.bin + kallsyms, 不碰设备/adb。
用法: PYTHONIOENCODING=utf-8 python ioctl_arg_scan.py
输出: stdout 摘要 + analysis/ioctl_arg_scan_out.json (全部事件+证据行+cmd门)
"""
import io, os, re, sys, json, bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000          # 本 build 链接/load base; 文件偏移 = 链接地址 - BASE (同 kdis.py/argptr_scan.py)
CAPINSN = 400                       # 每函数扫描上限

# ---------- kallsyms ----------
syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
addr2names = {}
for a, t, n in syms:
    addr2names.setdefault(a, []).append((t, n))
data = io.open(IMG, 'rb').read()


def name_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    return syms[i][2], a - syms[i][0]


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
    return addrs[i] if i < len(addrs) else a + 4 * CAPINSN


md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True


def norm_reg(rn):
    if not rn:
        return rn
    return ('x' + rn[1:]) if rn[0] == 'w' else rn


# ---------- uaccess / 内核例程 分类 ----------
# 约定: copy 例程的参数里 **哪个槽是内核侧**。
#   _copy_to_user(to=__user x0, from=内核 x1, n x2)      => 内核侧 = x1
#   _copy_from_user(to=内核 x0, from=__user x1, n x2)     => 内核侧 = x0
COPY_SPEC = {
    '_copy_to_user': 'uto', '__arch_copy_to_user': 'uto',
    'copy_to_user': 'uto', 'raw_copy_to_user': 'uto',
    'copy_to_user_nofail': 'uto', 'copy_to_user_nofault': 'uto',
    '_copy_from_user': 'ufrom', '__arch_copy_from_user': 'ufrom',
    'copy_from_user': 'ufrom', 'raw_copy_from_user': 'ufrom',
    'copy_from_user_nofail': 'ufrom', 'copy_from_user_nofault': 'ufrom',
    'strncpy_from_unsafe_user': 'uaddr0',
    'simple_read_from_buffer': 'srfb',     # x0=to(user) x1=count x2=ppos x3=from(内核) x4=avail
    'simple_write_to_buffer': 'swtb',      # x0=to(内核)
    'copy_field_from_user': 'ufrom', 'copy_field_to_user': 'uto',
}
MEMCPY2 = {'memcpy', 'memmove', '__memcpy', '__memmove', 'strcpy', 'strscpy',
           'strncpy', 'stpcpy', 'kstrdup', 'strndup'}     # x0=内核dst(W) x1=内核src(R)
MEMSET0 = {'memset', '__memset', 'memzero', 'memzero_explicit'}
RO0 = {'strlen', 'strnlen', 'strstr', 'memchr', '__inb', 'ioread32'}
FREE0 = {'kfree', 'kvfree', 'vfree', 'devm_kfree'}
LOCK0 = {'mutex_lock', 'mutex_lock_interruptible', 'mutex_trylock', 'mutex_unlock',
         '_raw_spin_lock', '_raw_spin_lock_irq', '_raw_spin_lock_irqsave', '_raw_spin_unlock',
         'spin_lock', 'spin_lock_irqsave', 'down_read', 'down_write', 'up_read', 'up_write',
         'refcount_set', 'atomic_set'}


def classify_callee(nm):
    if nm is None:
        return None
    n = nm.split('.')[0].split('$')[0]
    if n in COPY_SPEC:
        return COPY_SPEC[n]
    if n in MEMCPY2:
        return 'copy2'
    if n in MEMSET0:
        return 'set0'
    if n in RO0:
        return 'ro0'
    if n in FREE0:
        return 'free0'
    if n == 'set_fs':
        return 'setfs'
    if n in LOCK0:
        return 'lock0'
    return None


def scan(start, taint_in, depth, budget=CAPINSN):
    """返回 (events, full)。taint_in: {reg:('ptr'|'val', label)}。depth: 'top'|'callee'"""
    end = min(func_end(start), start + 4 * budget)
    n = (end - start) // 4
    size = (func_end(start) - start) // 4
    full = size <= budget
    off = start - BASE
    if off < 0 or off + 4 * n > len(data):
        return [], full
    insns = list(md.disasm(data[off:off + 4 * n], start))
    texts = [(i.address, i.mnemonic, i.op_str) for i in insns]
    taint = dict(taint_in)
    slots = {}
    events = []

    def ev(pc, bucket, kind, note, callee=None):
        # 证据行: 事件指令 + 前 4 条
        try:
            k = next(j for j, (a, mm, oo) in enumerate(texts) if a == pc)
        except StopIteration:
            k = len(texts) - 1
        lo = max(0, k - 4)
        evid = ['%x: %s %s' % (a, mm, oo) for (a, mm, oo) in texts[lo:k + 1]]
        # 命令门: 事件之前最近的、涉及 w1/x1(cmd) 的比较/sub
        gate = []
        for (a, mm, oo) in texts[:k + 1]:
            if mm in ('cmp', 'subs', 'cmn') and re.search(r'\b[wx]1\b', oo):
                gate.append('%x: %s %s' % (a, mm, oo))
            elif mm in ('sub',) and re.search(r',\s*[wx]1,', oo):
                gate.append('%x: %s %s' % (a, mm, oo))
            elif mm in ('tbz', 'tbnz', 'cbz', 'cbnz') and re.search(r'\b[wx]1\b', oo):
                gate.append('%x: %s %s' % (a, mm, oo))
        events.append(dict(pc=pc, bucket=bucket, kind=kind, note=note, callee=callee,
                           line='%x: %s %s' % (pc, texts[k][1], texts[k][2]),
                           evid=evid, gate=gate[-4:], depth=depth))

    for ins in insns:
        m = ins.mnemonic
        ops = ins.operands
        raw = '%s %s' % (m, ins.op_str)
        if m in ('bl', 'b'):
            tgt = None
            for o in ops:
                if o.type == ARM64_OP_IMM:
                    tgt = o.imm & 0xFFFFFFFFFFFFFFFF
            cn = exact_start(tgt) if tgt is not None else None
            near = name_at(tgt) if tgt is not None else None
            kind = classify_callee(cn)
            tb = dict(taint)   # 调用点参数寄存器状态
            if kind:
                T = lambda r: tb.get(r, ('',))[0] == 'ptr'
                if kind == 'ufrom' and T('x0'):
                    ev(ins.address, 'KPTR-COPY', 'WRITE-kernel-dst',
                       'copy_from_user/内核侧 to(x0)=arg 派生 => 向 arg 指向的内核地址写', cn)
                elif kind == 'uto' and T('x1'):
                    ev(ins.address, 'KPTR-COPY', 'READ-kernel-src',
                       'copy_to_user 内核侧 from(x1)=arg 派生 => 从 arg 指向的内核地址读', cn)
                elif kind == 'srfb' and T('x3'):
                    ev(ins.address, 'KPTR-COPY', 'READ-simple_read', 'simple_read_from_buffer from(x3)=arg 派生', cn)
                elif kind == 'swtb' and T('x0'):
                    ev(ins.address, 'KPTR-COPY', 'WRITE-simple_write', 'simple_write_to_buffer to(x0)=arg 派生', cn)
                elif kind == 'copy2':
                    if T('x0'):
                        ev(ins.address, 'KPTR-COPY', 'WRITE-memcpy-dst', 'memcpy/strcpy 内核 dst(x0)=arg 派生', cn)
                    if T('x1'):
                        ev(ins.address, 'KPTR-COPY', 'READ-memcpy-src', 'memcpy/strlen 内核 src(x1)=arg 派生', cn)
                elif kind == 'set0' and T('x0'):
                    ev(ins.address, 'KPTR-COPY', 'WRITE-memset', 'memset 目的(x0)=arg 派生', cn)
                elif kind == 'ro0' and T('x0'):
                    ev(ins.address, 'KPTR-DEREF', 'READ-kernel-str', 'strlen/memchr 解引用 arg 派生', cn)
                elif kind == 'free0' and T('x0'):
                    ev(ins.address, 'KPTR-DEREF', 'FREE-arg', 'kfree(arg 派生)', cn)
                elif kind == 'lock0' and T('x0'):
                    ev(ins.address, 'KPTR-DEREF', 'LOCK-on-arg', '锁/refcount 落在 arg 派生地址(写原语+潜在死锁)', cn)
                elif kind == 'setfs':
                    ev(ins.address, 'KPTR-DEREF', 'SET_FS', '调用 set_fs: 之后 uaccess 可指向内核', cn)
            elif kind is None and tgt is not None and depth == 'top':
                internal = (start <= tgt < func_end(start))
                if not internal:
                    pargs = {r: tb[r] for r in tb if r in ('x0', 'x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7')
                             and tb[r][0] == 'ptr'}
                    if pargs:
                        sub, sfull = scan(tgt, pargs, 'callee')
                        for e in sub:
                            e['kind'] = 'INDIRECT:' + e['kind']
                            e['bucket'] = e['bucket']
                            e['note'] = '被调 %s(+0x%x) 内解引用/copy arg; 调用点 %s' % (
                                cn or (near[0] if near else hex(tgt)), near[1] if near else 0, raw)
                            events.append(e)
                        if not sub and not sfull:
                            ev(ins.address, 'UNRESOLVED', 'callee-too-big',
                               'callee %s(+0x%x) 超过 400 条未完全扫描' % (cn or hex(tgt), near[1] if near else 0))
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
                ev(ins.address, 'UNRESOLVED', 'BRANCH-via-arg',
                   '经 arg 派生寄存器间接转移(控制流, 非读写): ' + raw)
            for x in ['x%d' % i for i in range(0, 18)] + ['x30']:
                taint.pop(x, None)
            continue
        # 内存访问
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
            hit = None
            for r in (base_r, idx_r):
                if r and taint.get(r, ('',))[0] in ('ptr', 'val'):
                    if hit is None or taint[r][0] == 'ptr':
                        hit = r
            if hit:
                tg, lab = taint[hit]
                tag = 'WRITE' if is_store else 'READ'
                conf = 'HIGH' if tg == 'ptr' else 'MED-chained'
                ev(ins.address, 'KPTR-DEREF', 'DEREF-%s-%s' % (tag, conf),
                   '%s [%s 来自 %s]' % (raw, hit, lab))
            if not is_store and ops and ops[0].type == ARM64_OP_REG:
                d = norm_reg(ins.reg_name(ops[0].reg))
                if hit:
                    taint[d] = ('val', '载入自 *%s@%x' % (hit, ins.address))
                else:
                    taint.pop(d, None)
                if base_r in ('sp', 'x29'):
                    v = slots.get((base_r, disp))
                    if v and d not in taint:
                        taint[d] = v
            else:
                if base_r in ('sp', 'x29'):
                    dr = [norm_reg(ins.reg_name(o.reg)) for o in ops if o.type == ARM64_OP_REG]
                    if m in ('stp', 'stnp') and len(dr) >= 2:
                        slots[(base_r, disp)] = taint.get(dr[0])
                        slots[(base_r, disp + 8)] = taint.get(dr[1])
                    elif dr:
                        slots[(base_r, disp)] = taint.get(dr[0])
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
        # mrs Xd, SYSreg 读系统寄存器(如 sp_el0=current) => 目标寄存器是**全新值**, 与 arg 无关, 必须清污点
        if m == 'mrs' and ops and ops[0].type == ARM64_OP_REG:
            taint.pop(norm_reg(ins.reg_name(ops[0].reg)), None)
            continue
        if m in ('cmp', 'cmn', 'tst', 'cbz', 'cbnz', 'tbz', 'tbnz', 'prfm', 'msr', 'ret'):
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
                    taint[d0] = ('ptr', 'arg<-经 %s@%x' % (ptrs[0][0], ins.address))
                elif ptrs or vals:
                    s = (ptrs or vals)[0]
                    taint[d0] = ('val', 'arg 的 32 位/运算派生@%x' % ins.address) if not wide0 else ('ptr', 'arg<-经 %s@%x' % (s[0], ins.address))
                else:
                    taint.pop(d0, None)
            continue
        if d0:
            taint.pop(d0, None)
    # post: 标注 DEREF/INDIRECT 是否落在 uaccess(TTBR0 切换)窗口内
    for e in events:
        if e['kind'].startswith('DEREF') or e['kind'].startswith('INDIRECT') or 'LOCK' in e['kind']:
            try:
                k = next(j for j, (a, mm, oo) in enumerate(texts) if a == e['pc'])
            except StopIteration:
                continue
            lo, hi = max(0, k - 80), min(len(texts), k + 40)
            guarded = any('ttbr0_el1' in oo and mm in ('msr', 'mrs') for a, mm, oo in texts[lo:hi])
            if guarded:
                e['kind'] += '-UAACCESS-GUARDED'
    return events, full


# ---------- 载入 165 表 ----------
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')
table_base = None
names = []
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    mm = HDR.match(l.strip())
    if mm and int(mm.group(2)) == 165 and 'ashmem_ioctl' in l:
        table_base = int(mm.group(1), 16)
        names = [x.strip() for x in l.split('  ', 1)[1].split('|') if x.strip()]
        print('表行 %d  base=0x%x  count=%d  ashmem_ioctl idx=%d' % (i + 1, table_base, int(mm.group(2)), names.index('ashmem_ioctl')), file=sys.stderr)
        break
assert names, '未找到 165 表'

by_name = {}
for a, t, n in syms:
    b = n.split('$')[0]
    if b not in by_name or (t in 'TtWVw' and by_name[b][1] not in 'TtWVw'):
        by_name[b] = (a, t)

out = {}
for nm in names:
    rec = by_name.get(nm)
    if not rec:
        out[nm] = {'error': 'no-symbol'}
        continue
    a = rec[0]
    ev, full = scan(a, {'x2': ('ptr', '入口 x2=arg')}, 'top')
    size = (func_end(a) - a) // 4
    out[nm] = {'addr': hex(a), 'insize': size, 'full': full,
               'buckets': sorted({e['bucket'] for e in ev}),
               'nhits': len(ev),
               'hits': [dict(pc=hex(e['pc']), bucket=e['bucket'], kind=e['kind'],
                             note=e['note'], callee=str(e.get('callee')),
                             line=e['line'], evid=e['evid'], gate=e['gate']) for e in ev]}

io.open(os.path.join(AN, 'ioctl_arg_scan_out.json'), 'w', encoding='utf-8').write(
    json.dumps(out, ensure_ascii=False, indent=1))

# ---------- 控制台摘要 ----------
resolved = [n for n in names if 'error' not in out[n]]
unres = [n for n in names if 'error' in out[n]]
trunc = [n for n in resolved if not out[n]['full']]
buckets = {'KPTR-COPY': [], 'KPTR-DEREF': [], 'UNRESOLVED': []}
for n in resolved:
    for b in out[n]['buckets']:
        buckets.setdefault(b, [])
    for e in out[n]['hits']:
        buckets[e['bucket']].append((n, e))

print('解析 %d/%d, 无法解析符号 %d' % (len(resolved), len(names), len(unres)))
if unres:
    print('  无法解析:', unres)
print('截断(size>400 条)共 %d:' % len(trunc))
for n in trunc:
    print('   %-38s insize=%d' % (n, out[n]['insize']))
for b in ('KPTR-COPY', 'KPTR-DEREF', 'UNRESOLVED'):
    hs = [e for e in buckets[b] if not e[1]['kind'].startswith('INDIRECT')]
    ind = len(buckets[b]) - len(hs)
    print('== 桶 %s: 直接命中 %d 事件(另有 INDIRECT 一层跟进 %d) ==' % (b, len(hs), ind))
    seen = set()
    for n, e in buckets[b]:
        key = (n, e['pc'])
        if key in seen:
            continue
        seen.add(key)
        print('  %-34s %s %s' % (n, e['pc'], e['kind']))
        print('       %s' % e['line'])
        if e['gate']:
            print('       命令门(近似): %s' % ' | '.join(e['gate']))
        if e['callee'] and e['callee'] != 'None':
            print('       callee=%s' % e['callee'])
