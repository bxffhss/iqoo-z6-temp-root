#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1162_wire_check.py —— rc76 桩里"装载只可能从门后面发生"这把**静态闸**(0 枪，纯文本)。

为什么要它：接线这一格在设备上没跑过(那要一扇窗)，而"编得过"只证语法不证结构——
  `security_load_policy()` 那一声调用整条路线里最贵，它**必须**只能从 `w1161_gate()` 放行之后到达。
  这句话在源码里是可见的形状，所以可以在宿主上量，不必烧枪。

★每一条都必须"能红"：--self 跑七个变异件(全部是**行为上错**的源码改动：拆掉守卫/搬走调用/复制调用/
  硬写魔数/绕过 sp_arm/把 FNV 的字面量复制第二份/把 SS 那份头从代码里摘掉只在注释里说一声)，
  每一个都必须被抓；正跑必须绿(绿＝一条断言，不是"我看它没打印红")。
★它读的是**将要送进构建机的那份源**，不是构建产物；产物的尺在 w1162_remote.sh(符号/段/串)。
"""
import re
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FAILS = []
N = [0]


def chk(name, got, want):
    N[0] += 1
    if got != want:
        FAILS.append('%s: 实际 %r 期望 %r' % (name, got, want))
        print('[BAD] %s: 实际 %r 期望 %r' % (name, got, want))
    else:
        print('[OK] %s = %r' % (name, got))


def strip_comments(s):
    """先剥注释再数：**数的是代码，不是我说过的话**。
    ★这条不是讲究：第一版没剥注释，`w1161_gate()` 因为两句散文被数成 3 次、
      而我**记错过的那个魔数**正好写在注释里，也被数成"硬写在代码里"——两红都是仪器。"""
    s = re.sub(r'/\*[\s\S]*?\*/', '', s)
    s = re.sub(r'//[^\n]*', '', s)
    return s


def region(text, start_pat):
    """从某个函数的签名到**下一个函数**为止；边界就是下一行的 `static`/`void __exit`。"""
    m = re.search(start_pat, text)
    if not m:
        chk('起点可寻 %s' % start_pat, '缺', '有')
        return ''
    tail = text[m.end():]
    e = re.search(r'\n(?:static |void __exit )', tail)
    return tail[:e.start()] if e else tail


def check_stub(raw, label=''):
    text = strip_comments(raw)
    p = (lambda s: label + s)
    # ①两个调用点的**存在与唯一**
    n_load = len(re.findall(r'p_ld_load\(', text))
    n_gate = len(re.findall(r'w1161_gate\(', text))
    chk(p('p_ld_load 调用点条数'), n_load, 1)
    chk(p('w1161_gate 调用点条数'), n_gate, 1)
    if n_load == 1 and n_gate == 1:
        i_load = text.index('p_ld_load(')
        i_gate = text.index('w1161_gate(')
        # ②**次序**：门必须在装载上游(这条就是整件事的全部内容)
        chk(p('门在装载上游'), i_gate < i_load, True)
        between = text[i_gate:i_load]
        chk(p('门与装载之间有那个守卫'), 'if (why != W1161_OK)' in between, True)
        chk(p('守卫里真的 return'), re.search(r'if \(why != W1161_OK\)[\s\S]{0,240}?return;', between) is not None, True)
    # ③桩不许自己当第二个法官：门里那几个号一次都不该出现在桩里
    for tok in ['W1161_SYM', 'W1161_NOIMG', 'W1161_TOOSMALL', 'W1161_TOOLONG',
                'W1161_BADMAGIC', 'W1161_BADSTR', 'W1161_ARMMISMATCH', 'W1161_READPOL']:
        chk(p('桩里不出现 %s(那是门的判断)' % tok), len(re.findall(r'\b' + tok + r'\b', text)), 0)
    chk(p('W1161_OK 出现次数'), len(re.findall(r'\bW1161_OK\b', text)), 1)
    chk(p('W1161_ALLOC 出现次数(收图那条路)'), len(re.findall(r'\bW1161_ALLOC\b', text)), 1)
    chk(p('W1161_FAULT 出现次数(收图那条路)'), len(re.findall(r'\bW1161_FAULT\b', text)), 1)
    # ④常数不许凭记忆：只能从树里的头来
    chk(p('硬写的小端魔数出现次数'), len(re.findall(r'0xf97cff8c', text, re.I)), 0)
    chk(p('我记错过的那个魔数出现次数'), len(re.findall(r'0x3000012', text, re.I)), 0)
    chk(p('SELINUX_MAGIC 用了几次'), len(re.findall(r'\bSELINUX_MAGIC\b', text)), 1)
    # ⑤两把 FNV 字面量各只有一份(复制第二份＝两把尺会分家)
    chk(p('种数出现次数(只许在 #define)'), len(re.findall(r'1469598103934665603', text)), 1)
    chk(p('素数出现次数(只许在 #define)'), len(re.findall(r'1099511628211', text)), 1)
    # ⑥三道默认关的锁：钥匙比在 req 装配里、上限拦在交图里、节点只在 sp_arm=1 时建
    chk(p('钥匙比对出现次数'), len(re.findall(r'ld_key == LD_KEY_WANT', text)), 1)
    chk(p('交图默认拒(ENOSPC)出现次数'), len(re.findall(r'return -ENOSPC', text)), 1)
    n_setup = len(re.findall(r'\bld_setup\(', text))
    chk(p('ld_setup 定义＋调用共两条'), n_setup, 2)
    if n_setup == 2:
        arm = region(text, r'static int sp_arm_set\(')
        chk(p('ld_setup 的那**一声**调用在 sp_arm_set 里'), 'ld_setup(' in arm, True)
        hs = region(text, r'int handle_sepolicy\(')
        chk(p('handle_sepolicy 里不许顺手武装装载面'), 'ld_setup(' in hs, False)
    # ⑦内存配对的牙：ld_live 必须 vfree，且不许 kfree
    live = region(text, r'static int ld_live\(')
    chk(p('ld_live 里 vfree(img) 一条'), len(re.findall(r'vfree\(img\);', live)), 1)
    chk(p('ld_live 里不许有 kfree'), len(re.findall(r'kfree\(', live)), 0)
    # ⑧返回契约没被接线带跑：SET_SEPOLICY 那头仍然永远不给正数
    chk(p('return sp_errno(rcc) 一条'), len(re.findall(r'return sp_errno\(rcc\);', text)), 1)
    chk(p('sp_errno 里 return -E* 条数'), len(re.findall(r'return -E[A-Z0-9]+;', region(text, r'static int sp_errno\('))), 6)
    # ⑨三个 /proc 节点都建也都拆
    chk(p('proc_create 条数'), len(re.findall(r'\bproc_create\(', text)), 3)
    chk(p('proc_remove 条数'), len(re.findall(r'\bproc_remove\(', text)), 3)
    chk(p('交图口节点名'), len(re.findall(r'"ksu_sepol_img"', text)), 1)
    chk(p('命令口节点名'), len(re.findall(r'"ksu_sepol_ctl"', text)), 1)
    # ⑩编译面的牙：装载那两个原型**只能**从树里 SS 那份 include/security.h 来。
    #   ★这一段是 11-07 那一红的实物化：桩里只在**注释**中写过 `#include "security.h"`，代码里没有；
    #   远端那句 `grep -qF` 数的是文本，撞上散文就放行 ⇒ 假绿，真相要到 B 阶段编译才红。
    #   这里数的是**剥掉注释之后的代码行**，所以那一红在这一段就该被抓(见变异 ss_header_dropped)。
    incs = [l.strip() for l in text.splitlines() if l.strip().startswith('#include')]
    for h in ['"security.h"', '"selinux.h"', '"w1151_sepolicy_core.h"',
              '"w1155_sepol_record.h"', '"w1161_polgate.h"']:
        chk(p('代码里真有 #include %s' % h), incs.count('#include ' + h), 1)


MUTS = [
    ('guard_off', r'if \(why != W1161_OK\)', 'if (0)',
     '拆掉门的守卫(编得过，但装载变成无条件)'),
    ('gate_removed', r'why = w1161_gate\(&r\);', 'why = W1161_OK;',
     '不叫门，直接把放行值写死'),
    ('load_dup', r'(\trc = p_ld_load\(ld_state, ld_buf, ld_have\);)',
     r'\1\n\trc = p_ld_load(ld_state, ld_buf, ld_have);', '复制第二声装载调用'),
    ('magic_hardcoded', r'r\.magic_want = SELINUX_MAGIC;', 'r.magic_want = 0x3000012u;',
     '把魔数换成我凭记忆写错过的那个数'),
    ('arm_bypass', r'(\tif \(sp_setup\(\) != 0\) \{)', r'\tif (ld_setup() != 0) {\n\t\t/* 绕过 sp_arm 的武装口 */',
     '在 handle_sepolicy 里顺手把装载面立起来'),
    ('fnv_fork', r'(\treturn sp_fnv_upd\(FNV64_IST, b, len\);)',
     '\tunsigned long h = 1469598103934665603ull;\n'
     '\tu64 i;\n\n\tfor (i = 0; i < len; i++) {\n\t\th ^= b[i];\n\t\th *= 1099511628211ull;\n\t}\n'
     '\treturn h;', '把 FNV 的字面量复制出第二份(两把尺会分家)'),
    ('ss_header_dropped', r'\n#include "security\.h"[^\n]*', '',
     '把 SS 那份头从**代码**里摘掉、只在注释里说一声 ⇒ 就是 11-07 那一红：编不过是后话，'
     '先要这一格在上传前就红'),
]


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith('--')]
    path = argv[0] if argv else 'kmod/ksu_dropped_stub_rc76.c'
    selfmode = '--self' in sys.argv
    text = open(path, encoding='utf-8').read()
    print('### w1162 静态闸：源=%s (%d 字节)' % (path, len(text)))
    if not selfmode:
        check_stub(text)
    else:
        # 正跑必须绿
        base_fail = len(FAILS)
        n0 = N[0]
        check_stub(text)
        ok_green = (len(FAILS) == base_fail)
        chk('正跑(原件)必须全绿', ok_green, True)
        n_ok = N[0] - n0
        caught = 0
        for tag, pat, rep, why in MUTS:
            if not re.search(pat, text):
                FAILS.append('%s: 变异锚点找不到(这份件与闸预期分了家)' % tag)
                print('[BAD] 变异 %s 锚点找不到 ⇒ %s' % (tag, why))
                continue
            mtext = re.sub(pat, rep, text, count=1)
            if mtext == text:
                FAILS.append('%s: 替换后逐字节相同(空枪)' % tag)
                print('[BAD] 变异 %s 是空枪' % tag)
                continue
            before = len(FAILS)
            n_before = N[0]
            check_stub(mtext, label='[%s]' % tag)
            newbad = len(FAILS) - before
            n_new = N[0] - n_before
            if newbad > 0:
                caught += 1
                print('[OK] 变异 %s 被抓(新增红 %d 条)：%s' % (tag, newbad, why))
            else:
                FAILS.append('%s: 变异没被抓' % tag)
                print('[BAD] 变异 %s 没被抓 ⇒ 那把尺没牙：%s' % (tag, why))
            # 回滚这次变异带来的红，让下一条从干净状态开始
            del FAILS[before:]
            N[0] = n_before
        chk('七条变异全被抓', caught, 7)
        print('  正跑断言数=%d 变异件断言数合计=%d' % (n_ok, N[0] - n_ok))
    print('SUM asserts=%d fails=%d' % (N[0], len(FAILS)))
    for f in FAILS[:8]:
        print('  ! %s' % f)
    if FAILS:
        print('VERDICT=w1162_wire_fail FAIL')
        return 1
    print('VERDICT=w1162_wire_pass PASS 装载面的结构：门在上游·桩不自己当法官·常数不凭记忆·默认三道锁')
    return 0


if __name__ == '__main__':
    sys.exit(main())
