#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""w415_doc_audit.py —— 对外文档的**陈旧说法**审计（可复跑，不是一次性 grep）。

每条规则＝(名字, 命中正则, 允许上下文正则)。一行命中"危险形"且**不带**豁免词 ⇒ 报出来。
为什么要有这个：例 119(把实验形状的凭据抄进交付文档＝发一张会误判的验收单)、例 106(文案不是证据)、
例 113(解释写进交付文档后没人复核) 都是"文档里的旧句子继续对外生效"。
用法：
    PYTHONUTF8=1 python kmod/w415_doc_audit.py            # 审计默认那几份对外件
    PYTHONUTF8=1 python kmod/w415_doc_audit.py --self     # 双向自测(正/负夹具各 4 条)
    PYTHONUTF8=1 python kmod/w415_doc_audit.py a.md b.md  # 指定文件
退出码：0=没有陈旧说法；1=有命中(要逐条判是修还是加豁免)；2=自测没过或用法错。
"""
import io
import os
import re
import sys

# ── 规则表 ────────────────────────────────────────────────────────────────
# 豁免词一律包含"旧/作废/勘误/曾/不是/别/专属/分支/→/历史"这类明确标记为"这不是当前口径"的字样。
EXEMPT = r'旧|作废|勘误|曾|不是|别|专属|分支|→|历史|误记|错值|已改|纠正|反面'
# ★范围闸：流水账里引"当年的 uid / 当年的 md5"是**历史记录**，不是旧说法。
#   第一版用"必须含当前口径词"当闸 ⇒ **假阴**：交付文档 §1 那句"跑完之后内核名单里只有 suw 自己
#   （`uid=10319`）"没有任何"当前/默认"字样，被漏掉了(它才是真该修的)。改成**反向闸**：
#   带日期/发次/§/修订痕迹的行＝历史，放过；其余＝当前口径句，才拦。
CURRENTISH = r'现在|当前|默认|接手|正式|交付口径|凭据|要按|照旧|一字不变|跑法|可用'
HIST_BEFORE = r'旧 |旧`|当时|作废|勘误|误记|错值|已过期|滞后|→|上一版|旧版'
HISTORY = r'第 ?\d+ ?发|\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}|§ ?6\.\d|修订|追记|旧版|当年|那一次'
RULES = [
    # (名字, 危险形, 豁免, 额外豁免(说明"文档自己知道这事"), 生效文件范围: 'cur'＝只管当前口径类文档, 'all'＝全都管)
    ('R1 当前口径里写死 suw uid＝10319(现＝10342)', r'\b10319\b', EXEMPT, r'10342|写死|现取', 'cur'),
    ('R2 quiet 专属 CFIFIX 汇总当交付凭据', r'已写回=6\s*不用改=4\s*总行=28', EXEMPT, r'才打|拿它当', 'cur'),
    ('R3 go.sh 出现未登记的 md5 前缀', r'go\.sh[^|]{0,24}(?<![0-9a-f])([0-9a-f]{8})', EXEMPT, r'', 'all'),
    ('R4 采样器"最多 400 行"的旧文案', r'最多 ?400 ?行', EXEMPT, r'1200|纯文案|旧文案', 'all'),
    ('R5 "只有离线自测／未经真机"没收窄', r'只有离线自测|未经真机', EXEMPT, r'', 'cur'),
    ('R6 run_ringend 条数写成 22(实为 20)', r'run_ringend[^0-9]{0,14}22 ?项', EXEMPT, r'', 'all'),
    ('R7 交付形状晚读数"不存在"的旧说法', r'装载后.*没(有)?读数|root 通道.*不可用', EXEMPT, r'', 'cur'),
]
# ★入口文档只有**最上面那节**算当前口径；下面全是带日期的旧横幅(历史记录) ⇒ 只扫到第二个 `## ` 标题为止
HEAD_SCOPED = ('CONTINUE_HERE.md', 'CURRENT-STATUS.md')


def head_only(lines):
    out = []
    seen = 0
    for l in lines:
        if l.startswith('## '):
            seen += 1
            if seen == 2:
                break
        out.append(l)
    return out


CUR_DOCS = ('DELIVERY.md', 'CONTINUE_HERE.md', 'CURRENT-STATUS.md', 'GHOSTLOCK-TEMP-ROOT-FINAL.md')

GO_OK_HIST = ('2b316637', '598d30b3', '78557b3f', '40e0c25d', '67199f48', '8785d116',
              'f256e4ed', 'a92efd67', 'cd0495c6', 'b09c5bd2', 'a007723b', '0f1a1854',
              'e730d9db', '9842e80a', '65759eb3', 'a9c3ad3a', '42d1789d', 'b7c4b110',
              '2277f21e', 'd184bc32', 'dec9301e', 'a34211aa', 'd5998e64',
              'dc182bf3', 'a111b179',
              # ★10-21 第 30 发之后退役的当前值(文档里以"当时 `xxx…`"引它们＝历史记录)：
              #   go.sh 6f9ab83d 之前＝eb7536fe；收尾件 0274d195 之前＝272f6405；
              #   run_nosuw 27150289 之前＝a989d6f2；run_slots d410215c 之前＝a9b067d5；run_dumpleg 9558d705 之前＝5dbbe008
              'eb7536fe', '272f6405', 'a989d6f2', 'a9b067d5', '5dbbe008',
              # ★10-21 11:0x #150/格 N1 契约改动那天退役的同日中间值(横幅里以"当时 `xxx…`"引它们)：
              #   go.sh 944c6f0e(现 1fae174f)、stage c046d9bd(现 531241fb)、run_nosuw 0ca67d44(现 be4b64b9)、总闸 964d6da9(现 9c6123e2)
              '944c6f0e', 'c046d9bd', '0ca67d44', '964d6da9',
              # ★10-26/27 那几发派腿钩子(LEG1／LEG1ONLY／quiet 闸／x 位闸)当天退役的 go.sh 中间值，
              #   文档里以"当时 `xxx…`"引它们＝历史记录：4fabbf56→b03a7b56→6d55c36f→(10-28 现 59399c3b)
              '4fabbf56', 'b03a7b56', '6d55c36f')   # ★这些是 go.sh/stage 等件的**历史 lineage**(账目里引它们＝历史记录，不是笔误)


def _live_prefixes():
    """把**当前真件**的 md5 前缀现算进来。★为什么不能只靠上面那个表：每改一次工具就要改一次表，
    漏改的那一发 R3 会把它自己的真值报成"未登记"(例 91/127 同一族：派生数要现算，不许手数)。"""
    import hashlib
    out = []
    for rel in ('kmod/go.sh', 'kmod/ksu_one_stage.sh', 'kmod/push_ksu.sh', 'kmod/w161_teardown.sh',
                'kmod/w413_selftest_sweep.sh', 'kmod/w184_sample.sh', 'kmod/kernelsu_rc67.ko',
                'kmod/ksu_args.txt', 'kmod/w404_tokcount.py', 'kmod/w406_setdiff.py',
                'kmod/z6root.sh', 'kmod/w448_nosuw_mksh.sh', 'kmod/_tmp_selftest_rdst/run_nosuw.sh',
                'kmod/_tmp_selftest_rdst/run_slots.sh', 'kmod/_tmp_selftest_rdst/run_dumpleg.sh',
                'kmod/_tmp_selftest_rdst/run_z6pack.sh', 'kmod/_tmp_selftest_rdst/run_shbin.sh',
                'cm57/sustatic', 'cm57/sustatic_v4'):
        try:
            with open(rel, 'rb') as f:
                out.append(hashlib.md5(f.read()).hexdigest()[:8])
        except OSError:
            continue
    return tuple(out)


GO_OK = GO_OK_HIST + _live_prefixes()   # 允许出现在文档里的 md5 前缀(带豁免词才算历史值)
DEFAULT_FILES = ['kmod/DELIVERY.md', 'kmod/W345_RC68_WINDOW.md',
                 'analysis/CONTINUE_HERE.md', 'analysis/CURRENT-STATUS.md',
                 'analysis/GHOSTLOCK-TEMP-ROOT-FINAL.md']


def scan_lines(lines, fname=''):
    """返回 [(行号, 规则名, 行内容截断)]——纯函数，自测与实跑共用同一条代码路。
    ★'流水账'(runbook/md 账目)里引当年的 uid、当年的 md5 是**历史记录**，不是旧说法 ⇒
      带 'cur' 范围的规则只在**当前口径类文档**(交付说明/入口文档)里生效。"""
    cur = (not fname) or any(fname.endswith(x) for x in CUR_DOCS)
    hits = []
    for ln, text in enumerate(lines, 1):
        for name, pat, exempt, allow2, scope in RULES:
            if scope == 'cur' and not cur:
                continue
            for m in re.finditer(pat, text):
                if re.search(exempt, text):
                    continue
                if allow2 and re.search(allow2, text):
                    continue   # 文档自己已经知道这事(例如同一行就写着"现取＝10342")
                if scope == 'cur' and cur and re.search(HISTORY, text):
                    continue   # 带日期/发次/§/修订痕迹＝历史记录，不是"当前口径句"
                if name.startswith('R3'):
                    pre = m.group(1)
                    if pre in GO_OK:
                        continue
                    # 只报**不认识的** md5 前缀；认识的当"已登记的家族成员"
                    hits.append((ln, name + ' [' + pre + ' 未登记]', text[:150]))
                    continue
                hits.append((ln, name, text[:150]))
                break
    return hits


def audit(paths):
    total = 0
    for p in paths:
        if not os.path.exists(p):
            print('  [跳过] 文件不存在：%s' % p)
            continue
        d = open(p, 'rb').read()
        ctrl = sum(d.count(bytes([c])) for c in (0, 8, 11, 12, 27))
        if ctrl:
            print('  [BAD] %s 含 %d 个**不可见控制字节**(NUL/BS/VT/FF/ESC) ⇒ grep 可能把整份当 binary；'
                  '而且它们往往就是"本该写成转义文本"的那几个字符(今天连写警告的句子里都埋进去 5 个)' % (p, ctrl))
            total += 1
            continue
        t = d.decode('utf8', 'replace')
        lines, n_all = doc_lines(p)
        if len(lines) != n_all:
            print('      (入口文档：只扫最上面那节 %d/%d 行，其余是带日期的旧横幅＝历史)' % (len(lines), n_all))
        hits = scan_lines(lines, os.path.basename(p))
        print('  %-44s 行数=%-6d 命中=%d' % (p, len(t.splitlines()), len(hits)))
        for ln, name, text in hits:
            print('      %s:%d  %s' % (os.path.basename(p), ln, name))
            print('        %s' % text)
        total += len(hits)
    return total


FIX_POS = [
    # ★每条规则都要有自己的"必须被报出"事例(10-18 补)：R3/R6/R7 原来**没有夹具**，
    #   而 selftest 只点名 R1/R2/R4/R5 ⇒ 一条根本不咬的规则可以永远"通过"(例 128 那一族)。
    '当前口径：跑法用 `kmod/go.sh`＝`cafebabe…` 这一份',
    '当前版凭据：run_ringend 的自测 22 项全 OK',
    '交付口径：装载后 root 通道没有读数',
    '当前口径：名单主条目 `(10319, com.suw.manager)` 在场',
    '★go.sh 只开窗，不授权：跑完之后内核名单里只有 suw 自己（`uid=10319`），任何 app 敲 su 都会 ENOENT',
    '交付凭据③：`已写回=6 不用改=4 总行=28` 三条齐 ⇒ 通过',
    '跑法：采样器已起(3s 一行，最多 400 行)',
    '默认用当前版 ⇒ 这两把闸只有离线自测保证，未经真机',
]
FIX_NEG = [
    #   每条规则的"不许误报"事例也补齐(登记过的真值／对的条数／自己标了"旧"的句子)
    '当前口径：跑法用 `kmod/go.sh`＝`2b316637…` 这一份',
    '当前版凭据：run_ringend 的自测由 chk 自数＝20 项全 OK',
    '旧说法："装载后没有读数"已纠正(见下一节)',
    '★10319 是重装前的旧 uid(现取＝10342)，凡写死 10319 的脚本都要现取(作废值)',
    '那句 `已写回=6 不用改=4 总行=28` 是 quiet 半步分支专属文案 ⇒ 抄进交付文档＝误判(勘误已记)',
    'go.sh 那句"最多 400 行"是**旧文案**(实际 1200 行，别信这句)',
    '旧版曾写"未经真机"，第 24 发已收窄(已改)',
]
# ★范围闸自己的夹具：同一句史账，加不加"当前口径词"应该差别分明
LEDGER = '账目（第 145 发，10-16 22:16 装载）：`(10319, com.suw.manager)` 死在 insmod+262 秒'
LEDGER_AS_CLAIM = '默认口径：名单里只有 suw 自己 `(10319, com.suw.manager)` 死在 insmod+262 秒'


def doc_lines(p):
    """★唯一的"该看哪些行"入口：audit() 与 check_refs() 共用它，避免两条代码路的范围判定不一致。"""
    lines = io.open(p, encoding='utf8', errors='replace').read().splitlines()
    if os.path.basename(p) in HEAD_SCOPED:
        return head_only(lines), len(lines)
    return lines, len(lines)


def check_refs(paths):
    """R8/R9：文档引用的**本机路径必须存在**、登记的 **md5 必须与真文件对得上**。
    这两条比文字规则硬得多——它们拿"仓库本身"当正对照(例 128：报 0 之前先喂一个我知道存在的事例)。
    返回命中列表；只对'当前口径句'生效(带日期/第N发/修订的行＝历史值，放过)。"""
    hits = []
    seen = {}
    for p in paths:
        if not os.path.exists(p):
            continue
        lines, _n = doc_lines(p)
        for ln, text in enumerate(lines, 1):
            skip_line = bool(re.search(HISTORY, text) or re.search(EXEMPT, text))
            # ①路径存在性
            if not skip_line:
                for f in set(re.findall(r'(?:kmod|analysis|cm57|suw_apk)/[\w.\-]+\.(?:sh|py|md|ko|txt|apk|c|dump|bin)', text)):
                    if not os.path.exists(f):
                        hits.append((p, ln, 'R8 引用的文件不存在 [%s]' % f, text[:150]))
            # ②md5 登记值 vs 真值：形如 `名字`＝`1234abcd…`／md5 现＝`1234abcd…`
            #   ★②**不再整行豁免**(10-18 抓到)：台账那行最密、又必然带日期/"旧 `xxx`"这种历史对照，
            #     整行跳过的后果是 R9 对**最重要那一行从来没跑过**——我把两个登记值改坏，它照报 0 命中(例 128)。
            #     改成**逐条回看**：这条登记值自己前面那截写着"旧/当时/作废/→/滞后"才当历史值放过。
            # ★`**` 也要放过(10-28 抓的)：台账里"现行值"最醒目的写法就是 `名字`＝**`abcd1234…`**，
            #   旧模式在 `＝` 后只容一个反引号 ⇒ **加粗那批从来没被验过**(和 10-18 那条"整行豁免导致 R9
            #   对最重要那一行没跑过"是同一个形状：最该被查的那一行恰好写得最花)。
            for m in re.finditer(r'`?([\w./\-]+\.(?:sh|py|md|ko|txt|apk|c))`?\s*(?:＝|=|现＝)\s*\**\s*`?([0-9a-f]{8})', text):
                nm, claim = m.group(1), m.group(2)
                if re.search(HIST_BEFORE, text[max(0, m.start() - 30):m.end()]):
                    continue
                real_path = nm if os.path.exists(nm) else _find_by_basename(nm, seen)
                if not real_path:
                    hits.append((p, ln, 'R9 登记名找不到对应文件 [%s]' % nm, text[:150]))
                    continue
                if real_path.startswith('AMBIG:'):
                    # ★这条也是 10-18 补的牙：'AMBIG:…' 是个**非空字符串**，旧代码拿它当路径去算 md5，
                    #   失败后得空串 ⇒ `act and ...` 直接短路 ⇒ **裸名撞两个文件时静默放过**(登记了却从不验)。
                    hits.append((p, ln, 'R9 登记名有歧义,裸名命中多个文件 [%s] ⇒ 写全路径' % nm, text[:150]))
                    continue
                act = _md5(real_path, seen)
                if act and not act.startswith(claim):
                    hits.append((p, ln, 'R9 md5 不符 [%s 登记=%s 实际=%s]' % (nm, claim, act[:8]), text[:150]))
    return hits


def _find_by_basename(nm, seen):
    """裸文件名(如 `go.sh`)在仓库里唯一命中才算数；多个命中就明说'ambiguous'(例：一个名字只服务一个来源)。"""
    base = os.path.basename(nm)
    cands = []
    for root, dirs, files in os.walk('.'):
        if any(x in root for x in ('.git', '__pycache__', 'backup_2026')):
            continue
        for f in files:
            if f == base:
                cands.append(os.path.join(root, f).replace(os.sep, '/').lstrip('./'))
    if len(cands) == 1:
        return cands[0]
    return None if not cands else ('AMBIG:' + ','.join(cands[:3]))


def _md5(path, seen):
    if path not in seen:
        try:
            import hashlib
            seen[path] = hashlib.md5(open(path, 'rb').read()).hexdigest()
        except Exception:
            seen[path] = ''
    return seen[path]


def selftest():
    ok = True
    h = scan_lines(FIX_POS)
    nchk = 0
    # ★**遍历 RULES 本身**而不是手点四个名字 ⇒ 以后往表里加一条规则却忘了配夹具，这里立刻红。
    for name, _pat, _ex, _al, _sc in RULES:
        want = name.split()[0]
        hit = any(n.startswith(want) for _, n, _ in h)
        nchk += 1
        print('  [%s] 正夹具 %s 被报出(总命中 %d 条)' % ('OK' if hit else 'BAD', want, len(h)))
        ok = ok and hit
    h2 = scan_lines(FIX_NEG)
    for i, line in enumerate(FIX_NEG, 1):
        bad = [n for ln, n, _ in h2 if ln == i]
        nchk += 1
        print('  [%s] 负夹具 %d 没被误报%s' % ('OK' if not bad else 'BAD', i, ('' if not bad else ' ⇒ ' + str(bad))))
        ok = ok and not bad
    # ★夹具要**两边齐**：某条规则只有正例、没有"不许误报"那一半，就等于把闸朝通过打开(例 71)。
    nchk += 1
    cboth = (len(FIX_POS) >= len(RULES) and len(FIX_NEG) >= len(RULES))
    print('  [%s] 夹具覆盖齐：规则 %d 条／正 %d 条／负 %d 条' % ('OK' if cboth else 'BAD', len(RULES), len(FIX_POS), len(FIX_NEG)))
    ok = ok and cboth
    # ★第四道：**范围闸**有牙——同一句史账，没有"当前口径词"不该报，加了就该报
    hl = scan_lines([LEDGER, LEDGER_AS_CLAIM])
    got = set(ln for ln, _, _ in hl)
    c1 = (1 not in got)
    c2 = (2 in got)
    print('  [%s] 范围闸：史账句不报(=%s)、同一句冠上"默认口径"就报(=%s)' % ('OK' if c1 and c2 else 'BAD', c1, c2))
    ok = ok and c1 and c2
    # ★第三道：豁免表本身要有牙——把**同一个 EXEMPT 表**从这些行里删掉，必须立刻大面积变成命中
    #   (第一版只删了豁免词的**子集**，结果 4 行只翻出 1 条命中——那说明"有牙"是假的，得按整表删)
    #   同时要把 CURRENTISH 词加回去，否则会被范围闸拦下——两道闸要分开证。
    STRIP_BASE = [
        '凭据：`已写回=6 不用改=4 总行=28` 三条齐(旧)',
        '默认口径：名单里只有 suw 自己 uid=10319(旧)',
        '跑法：采样器已起，最多 400 行(旧文案)',
        '当前版：两把闸只有离线自测、未经真机(旧)',
    ]
    stripped = [re.sub(EXEMPT, '', l) for l in STRIP_BASE]
    h3 = scan_lines(stripped, 'DELIVERY.md')
    print('  [%s] 同一批行抠掉豁免表后变成 %d 条命中(必须 4，否则豁免表才是真闸/规则是摆设)'
          % ('OK' if len(h3) == 4 else 'BAD', len(h3)))
    ok = ok and len(h3) == 4
    # ★第五道：**入口文档只扫最上面那节**这个范围闸也要有牙——同一句话在旧横幅里不该报、在新横幅里该报
    FIX_HEAD = ['# 题', '## 最新横幅', '默认口径：uid=10319', '## 旧横幅(历史)', '默认口径：uid=10319']
    hn = len(head_only(FIX_HEAD))
    h_new = len(scan_lines(head_only(FIX_HEAD), 'CONTINUE_HERE.md'))
    h_all = len(scan_lines(FIX_HEAD, 'CONTINUE_HERE.md'))
    c5 = (hn == 3 and h_new == 1 and h_all == 2)
    print('  [%s] 范围闸(入口文档)：截到第 2 个 ## 前=%d 行 ⇒ 命中 %d；整份扫 ⇒ 命中 %d(要 1 vs 2)'
          % ('OK' if c5 else 'BAD', hn, h_new, h_all))
    ok = ok and c5
    # ★第五道(例 128 的正经落地)：**变异测试**——往临时件里注入三条"我知道存在"的错，
    #   checker 必须逐条抓到；再放一条正确登记，必须**不**报。自测的夹具由代码现算，不靠我手填。
    mut = 'kmod/_tmp_selftest_rdst/_w415_mut.md'
    real = _md5('kmod/go.sh', {})
    io.open(mut, 'w', encoding='utf8').write('\n'.join([
        '# 变异夹具',
        '当前口径：细节见 `kmod/w999_does_not_exist.sh`。',
        '当前口径：`kmod/go.sh`＝`deadbeef…` 为权威。',
        '当前口径：`kmod/go.sh`＝`%s…` 为权威。' % real[:8],
        # ★正对照(拿仓库本身当夹具)：这个裸名在仓库里**确实**有两个同名文件 ⇒ 必须报『有歧义』。
        '当前口径：`ksu_one_stage.sh`＝`ffffffff…` 为权威。',
        # ★加粗形状的两条(10-28)：错的必须被抓到、对的必须不许误报——旧模式两条都看不见。
        '当前口径：`kmod/go.sh`＝**`deadbeef…`** 为权威(加粗且错)。',
        '当前口径：`kmod/go.sh`＝**`%s…`** 为权威(加粗且对)。' % real[:8],
    ]) + '\n')
    mh = check_refs([mut])
    kinds = sorted(n.split()[0] for _, _, n, _ in mh)
    n_amb = sum(1 for _, _, n, _ in mh if '有歧义' in n)
    n_bad = sum(1 for _, _, n, _ in mh if 'md5 不符' in n)
    #   期望是**先想清楚再写**的：deadbeef⇒不符 1；加粗那条 deadbeef⇒再不符 1；
    #   ffffffff 那条裸名先撞歧义闸⇒歧义 1(不会同时计成"不符")；w999 路径⇒R8 1；
    #   两条正确登记(粗/非粗各一)⇒0 条。所以总数 4，不符 2，不是 5。
    c6 = (len(mh) == 4 and n_amb == 1 and n_bad == 2 and 'R8' in kinds)
    print('  [%s] 变异测试：注入 6 条(路径不存在 1＋md5 错 2(含加粗 1)＋裸名歧义 1＋正确 2(含加粗 1)) ⇒ 抓到 %d 条(该抓到 4：歧义=%d 不符=%d 外加 R8)——若把 6 当期望就是没想清楚，正确那两条不许误报'
          % ('OK' if c6 else 'BAD', len(mh), n_amb, n_bad))
    ok = ok and c6
    os.remove(mut)
    print('  [%s] 夹具已删(工作产物不留)：%s' % ('OK' if not os.path.exists(mut) else 'BAD', mut))
    ok = ok and (not os.path.exists(mut))
    print('    (上面这些道另计，夹具类断言由 nchk 自数＝%d 条；条数不写进文档，文档只引命令)' % nchk)
    print('=== w415 自测 %s ===' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 2


def selfstamp():
    """★让 checker 打印**自己的 md5**：这样"文档里登记的工具 md5 过期"这一类问题从根上消失
       ——文档只需写"跑这条命令"，现值由它自己报(今天我自己就被这个绊了三次，§6.340④/例 128)。"""
    import hashlib
    try:
        h = hashlib.md5(open(__file__, 'rb').read()).hexdigest()[:8]
    except Exception:
        h = '未知'
    print('self=md5:%s  (规则 %d 条；文档只需引这条命令，不必冻结这个值)' % (h, len(RULES)))


if __name__ == '__main__':
    selfstamp()
    if '--self' in sys.argv or '--selftest' in sys.argv:
        sys.exit(selftest())
    paths = [a for a in sys.argv[1:] if not a.startswith('-')] or DEFAULT_FILES
    n = audit(paths)
    print('--- R8/R9：文档引用的路径与登记的 md5，拿仓库本身当正对照 ---')
    rh = check_refs(paths)
    for p, ln, name, text in rh:
        print('      %s:%d  %s' % (os.path.basename(p), ln, name))
        print('        %s' % text)
    n += len(rh)
    print('=== 合计命中 %d 条 ===' % n)
    sys.exit(0 if n == 0 else 1)
