#!/usr/bin/env python3
# w1133_ksud_ioc_sites.py —— #231 的**离线**答法：从**调用点**读真 ksud 到底往驱动发了哪些命令字，
#   并和我们 ko 的命令表(w1134_kotable_probe.c 由编译器算出来的那一份)对表。
#   为什么换这条(而不是 11-03 那把字节扫 w1128)：字节扫把"数据里的巧合比特"与"真被送进 ioctl 的常量"混在
#   一起(1010 候选/60 个 nr，没有判别力；本文件里 type='K' 的字节对扫也会捞出字符串 "OKAY"=0x59414b4f 那种脏)。
# ★形态(前四版各假红/假绿一次，全写死在这儿，别再犯)：
#   ①llvm-objdump 的 aarch64 行形如 "  320914: bf c2 05 94 \tbl\t0x491410 <ioctl@plt>"
#     ＝地址冒号后是**四个分开的字节**、助记符前后是 **TAB**。按"8 个连续 hex"配 ⇒ 每行都配不上 ⇒
#     `SITES_ioctl=0`(假"没发")。
#   ②llvm 的立即数**两种进制混着印**：`mov w1, #19217`(十进制) 与 `orr x0, x8, #0x4`(十六进制)。
#     只配 `#0x..` ⇒ mov/movk 全配不上 ⇒ 全部点被当成"来自寄存器"。
#   ③Rust 拼 `_IOC` ＝**先 `mov w1,#低16` 再 `movk w1,#高16,lsl #16`**；倒扫(新→旧)先撞 movk，
#     攒下的分片**必须**与后面撞到的 mov 底数相或(曾按"shift>15 丢掉"⇒ dir/size 全丢，假绿)。
#   ④**定界用基本块、并且要顺封装往回追一层**：ksud 里多数 ioctl 点是 3 条指令的薄封装(读 fd、补高半、
#     `b/b l ioctl`)，命令字的**低半来自调用它的函数**。用定长窗口往回扫会跨块 ⇒ 8 个点全报"取不到"。
#     本版：⑴按基本块切(块尾＝ret/br/blr/b/b.cond/cbz/cbnz/tbz/tbnz)；⑵解 x1 的范围**不含调用点那条本身**
#       (含了就先撞上 `b` 而 break，把同一块里刚见过的 movk 丢掉)；⑶块内解不到 ⇒ 把"块首"与"往前找到的
#       函数序言(`sub sp,sp,#imm` 且自己也是块首)"都当**入口候选**，去全表找 `bl 0x<入口>` 的调用点，在调用点
#       那个块里解 x1，再与封装块里已知的 movk 高半相或；⑷`mov wD,wS` / `orr wD,wS,#imm`(源≠目标)⇒ 递归解
#       wS 一次(ksud 的 GET_INFO 就是 `mov w8,#0x4b02`＋`movk w8,#32768,lsl16`＋`orr w1,w8,#0x100000`)。
# ★诚实边界：仍取不到的点单列 `UNRESOLVED` 并把整块指令印出来——**不许**读成"ksud 没发这个命令"。
# 用法(远端)：python3 w1133_ksud_ioc_sites.py <ksud.asm> <期望ioctl站点数> [ko表.txt]
#   ko表.txt ＝ w1134 探针的 stdout(每行 `NAME 0x<cmd> dir=.. size=.. type=.. nr=..`)
# 输出键(判读由链做，本件只给数)：
#   PARSED_LINES= BLOCKS= PROLOGUES= SITES_ioctl= SITES_syscall= FOLLOW_SITES= SITES_resolved=
#   CMD_total= CMD_ksu= CMD_nonksu= ｜KO_TABLE= KSU_TYPE= MATCH= MISSING= NOT_USED=
#   CMD 0x.. dir=.. size=.. type=.. nr=.. 站点=.. 在表=<yes|no|非KSU> 来源=<直点/经封装>
#   SYSCALLNR / UNRESOLVED / SELFTEST=ok|fail / VERDICT=
import re, sys, collections

asm = sys.argv[1] if len(sys.argv) > 1 else 'ksud95.asm'
EXPECT = int(sys.argv[2]) if len(sys.argv) > 2 else -1
TABLE = sys.argv[3] if len(sys.argv) > 3 else ''
DEBUG = 1 if (len(sys.argv) > 4 and sys.argv[4] == 'debug') else 0

LINE = re.compile(r'^\s*([0-9a-f]+):\s*((?:[0-9a-f]{2}\s+)+)\t(.*)$')
TARGET = re.compile(r'^0x[0-9a-f]+\s*<([^>]*)>')
RD = r'(?:x|w)(\d+|zr|sp)'
IM = r'#(0x[0-9a-f]+|\d+)'
MOVZ = re.compile(r'^(?:mov|movz)\s+' + RD + r'\s*,\s*' + IM + r'(?:\s*;|$)')
MOVK = re.compile(r'^movk\s+' + RD + r'\s*,\s*' + IM + r'\s*,\s*lsl\s*#(\d+)(?:\s*;|$)')
MOVR = re.compile(r'^mov\s+' + RD + r'\s*,\s*' + RD + r'(?:\s*;|$)')
ORRS = re.compile(r'^orr\s+' + RD + r'\s*,\s*' + RD + r'\s*,\s*' + IM + r'(?:\s*;|$)')
ADDS = re.compile(r'^add\s+' + RD + r'\s*,\s*' + RD + r'\s*,\s*' + IM + r'(?:\s*;|$)')
WRITE = re.compile(r'^(?:ldr|ldur|ldrb|ldrh|ldp|ldar|ldaxr|add|sub|and|eor|csel|madd|sxtw|uxtw|adc|neg|mvn|bic|orn|eon|stxr)\s+' + RD)
ENDS = re.compile(r'^(?:ret|br|blr|b|b\.\w+|cbz|cbnz|tbz|tbnz)(?:\s|$)')
PROLOG = re.compile(r'^sub\s+sp,\s*sp,\s*' + IM)   # ★IM 里自带 `#`，别再写一遍(写了两遍⇒序言永不匹配)
DIRN = {0: 'NONE', 1: 'WRITE', 2: 'READ', 3: 'RW'}
KSU_TYPE = 0x4b


def IMM(s):
    return int(s, 16) if s.startswith('0x') else int(s, 10)


# ---------- 1) 解析成 (addr, mnem, ops) 并把每条指令标上"块尾/块首" ----------
ins = []
for ln in open(asm, errors='replace'):
    m = LINE.match(ln.rstrip('\n'))
    if not m:
        continue
    p = m.group(3).split('\t', 1)
    ins.append((int(m.group(1), 16), p[0].strip(), (p[1].strip() if len(p) > 1 else '')))
N = len(ins)
is_end = [bool(ENDS.match(ins[i][1] + ' ' + ins[i][2])) for i in range(N)]
blk_lo = [0] * N
s = 0
for i in range(N):
    blk_lo[i] = s
    if is_end[i]:
        s = i + 1
blocks = sum(1 for i in range(N) if is_end[i])
# ★尺的正对照(例 219 那一族)：序言正则必须在这个二进制里**现印得出东西**，印不出＝正则没牙，
#   而不是"这程序没有序言"——今天就因为 `##` 多写一个井号，两处封装白判"取不到"。
n_prolog = sum(1 for i in range(N) if i == blk_lo[i] and PROLOG.match(ins[i][1] + ' ' + ins[i][2]))


def fn_entry(i):
    """往前找函数序言：`sub sp,sp,#imm` 且它自己就是块首。找不到返回 None。"""
    for k in range(i, max(-1, i - 400), -1):
        if k == blk_lo[k] and PROLOG.match(ins[k][1] + ' ' + ins[k][2]):
            return k
        if is_end[k] and k != i and blk_lo[k] != k:
            continue
    return None


# ---------- 2) 在块 [lo,hi) 里倒着拼 x<reg>；hi **不含**调用点那条本身 ----------
def decode(reg, lo, hi, depth=0):
    parts, base = {}, None
    for i in range(hi - 1, lo - 1, -1):
        a, mn, ops = ins[i]
        t = (mn + ' ' + ops).strip()
        if ENDS.match(t):
            break
        mk = MOVK.match(t)
        if mk and mk.group(1) == reg:
            parts[int(mk.group(3))] = IMM(mk.group(2))
            continue
        mz = MOVZ.match(t)
        if mz and mz.group(1) == reg:
            base = IMM(mz.group(2))
            break                         # mov/movz 清高位⇒更老的分片属于上一次拼装
        o_ = ORRS.match(t)
        if o_ and o_.group(1) == reg:
            if o_.group(2) == reg:
                parts[0] = parts.get(0, 0) | IMM(o_.group(3))
                continue
            if depth < 2:
                v, _w = decode(o_.group(2), lo, i, depth + 1)
                if v is not None:
                    base = (v | IMM(o_.group(3))) & 0xffffffff
                    break
            return None, '动态(orr 自别的寄存器)'
        ad = ADDS.match(t)
        if ad and ad.group(1) == reg:
            if ad.group(2) == reg:
                parts[0] = parts.get(0, 0) + IMM(ad.group(3))
                continue
            if depth < 2:
                v, _w = decode(ad.group(2), lo, i, depth + 1)
                if v is not None:
                    base = (v + IMM(ad.group(3))) & 0xffffffff
                    break
            return None, '动态(add 自别的寄存器)'
        mr = MOVR.match(t)
        if mr and mr.group(1) == reg:
            if mr.group(2) == 'zr':
                base = 0
                break
            if depth < 2:
                v, _w = decode(mr.group(2), lo, i, depth + 1)
                if v is not None:
                    base = v
                    break
            return None, '动态(mov 自别的寄存器)'
        w = WRITE.match(t)
        if w and w.group(1) == reg:
            return None, '来自寄存器/内存'
    if base is not None:
        v = base
        for sh, imm in parts.items():
            v |= imm << sh
        return v & 0xffffffff, None
    if parts:
        hi_ = 0
        for sh, imm in parts.items():
            hi_ |= imm << sh
        return hi_, '只有高半'
    return None, '块内没有写 x%s 的立即数' % reg


# ---------- 3) ioctl 调用点：先就地解；解不动的登记成"封装" ----------
sites = []
nsys = 0
sysnr = collections.defaultdict(lambda: {'n': 0, 'addr': []})
for i, (a, mn, ops) in enumerate(ins):
    if mn not in ('bl', 'b'):
        continue
    mt = TARGET.match(ops)
    tgt = mt.group(1) if mt else ops
    if 'ioctl' in tgt:
        sites.append(i)
    elif 'syscall' in tgt:
        nsys += 1
        v, _w = decode('0', blk_lo[i], i)
        if v is not None and _w is None:
            sysnr[v & 0xff]['n'] += 1
            sysnr[v & 0xff]['addr'].append('%x' % a)

idx_of = {}
for i, (a, _m, _o) in enumerate(ins):
    idx_of[a] = i
callers = collections.defaultdict(list)      # 被调地址 -> [调用它的 bl 下标]
for i, (a, mn, ops) in enumerate(ins):
    if mn != 'bl':
        continue
    mt = re.match(r'^0x([0-9a-f]+)', ops)
    if mt:
        callers[int(mt.group(1), 16)].append(i)

site_paths = collections.defaultdict(list)   # 站点下标 -> [(cmd, tag)]
resolved = collections.defaultdict(lambda: {'n': 0, 'src': []})
unres = []
n_follow = 0


def add(v, tag, site):
    resolved[v]['n'] += 1
    resolved[v]['src'].append(tag)
    site_paths[site].append((v, tag))


# ---------- 3)+4) 每个 ioctl 站点：就地解 ⇒ 解不动就把它自己的块/函数序言当**封装入口**，
#            按顺序找"第一个真有人调它的入口"(块首优先；序言只在块首没人调时才试 ⇒ 不会张冠李戴) ----------
for i in sites:
    lo = blk_lo[i]
    v, why = decode('1', lo, i)
    if v is not None and why is None:
        add(v, '直点@%x' % ins[i][0], i)
        continue
    high = v if (v and why == '只有高半') else 0
    cands = [lo]
    e = fn_entry(lo)
    if e is not None and e != lo:
        cands.append(e)
    if DEBUG:
        print('TRACE 站点=%x 块首=%x entry=%s high=0x%x' % (ins[i][0], ins[lo][0],
              ('%x' % ins[e][0]) if e is not None else 'None', high))
    used = False
    for c in cands:
        hits = callers.get(ins[c][0], [])
        if not hits:
            continue
        used = True
        n_follow += 1
        for j in hits:
            cv, cwhy = decode('1', blk_lo[j], j)
            if cv is None:
                unres.append((j, '经封装 %x 但调用点解不到 x1(%s)' % (ins[c][0], cwhy), blk_lo[j], j))
                continue
            add((cv | high) & 0xffffffff, '经封装%x@%x' % (ins[c][0], ins[j][0]), i)
        break
    if not used:
        unres.append((i, '块首与序言都没人调它(封装入口没认出来)', lo, i))

n_res = len([i for i in sites if site_paths[i]])
ksu_cmds = [v for v in sorted(resolved) if ((v >> 8) & 0xff) == KSU_TYPE]
nonksu = [v for v in sorted(resolved) if ((v >> 8) & 0xff) != KSU_TYPE]

ko = {}
for ln in (open(TABLE, errors='replace') if TABLE else []):
    mm = re.match(r'^(\S+)\s+0x([0-9a-f]{8})\s+dir=(\d)\s+size=(\d+)\s+type=0x([0-9a-f]{2})\s+nr=(\d+)', ln)
    if mm:
        ko[int(mm.group(2), 16)] = (mm.group(1), int(mm.group(3)), int(mm.group(4)), int(mm.group(5), 16), int(mm.group(6)))
missing = [v for v in ksu_cmds if ko and v not in ko]
matched = [v for v in ksu_cmds if ko and v in ko]
notused = sorted(ko[c][0] for c in ko if c not in resolved and ((c >> 8) & 0xff) == KSU_TYPE)

print('ASM=%s 可解析指令行=%d 基本块=%d 序言=%d' % (asm, N, blocks, n_prolog))
print('SITES_ioctl=%d SITES_syscall=%d FOLLOW_SITES=%d' % (len(sites), nsys, n_follow))
print('SITES_resolved=%d PATHS=%d CMD_total=%d CMD_ksu=%d CMD_nonksu=%d'
      % (n_res, sum(len(v) for v in site_paths.values()), len(resolved), len(ksu_cmds), len(nonksu)))
for v in sorted(resolved):
    d = (v >> 30) & 3; sz = (v >> 16) & 0x3fff; ty = (v >> 8) & 0xff; nr = v & 0xff
    inst = 'n/a' if not ko else ('yes' if v in ko else ('非KSU' if ty != KSU_TYPE else 'no'))
    print('CMD 0x%08x dir=%s size=%d type=0x%02x%s nr=%d 路径=%d 在表=%s 来源=%s%s'
          % (v, DIRN[d], sz, ty, "('K')" if ty == KSU_TYPE else '', nr, resolved[v]['n'],
             inst, ' '.join(resolved[v]['src']), ('  └表里=%s' % ko[v][0]) if v in ko else ''))
for v in sorted(sysnr):
    print('SYSCALLNR 0x%x(%d) 站点=%d' % (v, v, sysnr[v]['n']))
for j, why, lo, hi in unres:
    print('UNRESOLVED 相关点=%x 原因=[%s]' % (ins[j][0], why))
    for k in range(lo, hi + 1):
        print('      %x: %s %s' % (ins[k][0], ins[k][1], ins[k][2]))
if unres:
    print('!! 取不到的点＝%d ⇒ 这一格记**未测**，不许读成"ksud 没发这个命令"。' % len(unres))
if nonksu:
    print('注：type≠0x4b 的上面那些**不是** KSU 驱动命令(别的 fd/块设备)，不参与对表。')
if ko:
    print('KO_TABLE=%d KSU_TYPE=%d MATCH=%d MISSING=%d NOT_USED=%d'
          % (len(ko), len([c for c in ko if ((c >> 8) & 0xff) == KSU_TYPE]), len(matched), len(missing), len(notused)))
    if notused:
        print('  NOT_USED(表里有、这份 ksud 没调用；可能走 Manager/libksud 那条)：%s' % ','.join(notused))
st = 'ok'
if N < 100:
    #   ★这里从前写 `< 100000`(按那份 4.9 MB 的 ksud 的印象定的)⇒ 拿它量 14 KB 的 app 侧小件时
    #     又把自己的合法输入拒了(同一个坑今天踩第二次)。"有没有牙"要由**形状**判，不由**大小**判：
    #     解析不出 100 条指令才叫没牙；大小交给 SITES_outside 那把外部尺。
    st = 'fail(只解析出 %d 条指令行⇒格式不对/尺没牙)' % N
if EXPECT >= 0 and len(sites) != EXPECT:
    st = 'fail(站点=%d 与外部现数=%d 不符)' % (len(sites), EXPECT)
if len(sites) == 0:
    st = 'fail(站点=0 而文件里确有 <ioctl@plt>)'
if n_prolog == 0:
    #   ★阈值写"0 个＝没牙"，不写"<50"：上一版硬写 50，量官方 app 侧那支小件(整份才 17 条序言)时
    #     把自己的**合法输入**拒了＝闸假红(例 219 那一族，第 92 发同款)。有没有牙看"能不能印出东西"，不看我的印象。
    st = 'fail(序言正则一个都印不出⇒尺没牙) 序言=%d' % n_prolog
if n_res > len(sites):
    st = 'fail(SITES_resolved=%d > 站点=%d⇒计数口径错了(把调用点当站点)' % (n_res, len(sites))
print('SELFTEST=%s' % st)
st2 = [i for i in sites if not site_paths[i]]
V = '未定'
if st == 'ok':
    if st2:
        V = '%d/%d 处取不到⇒那一格未测(已解 %d 条命令字)' % (len(st2), len(sites), len(ksu_cmds))
    elif missing:
        V = '缺口=%d 条(ksud 发了、我们表里没有)' % len(missing)
    elif ko:
        V = '%d 个调用点全解开、%d 条命令字全在我们表里⇒"缺命令字"那一格出局' % (len(sites), len(matched))
    else:
        V = '已解 %d 条(没给 ko 表⇒未对表)' % len(ksu_cmds)
print('UNRESOLVED_SITES=%d' % len(st2))
print('VERDICT=%s' % V)
