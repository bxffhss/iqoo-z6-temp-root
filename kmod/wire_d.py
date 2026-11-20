import io

BS = chr(92)
P = 'kmod/w103_su.sh'
s = io.open(P, encoding='utf-8').read()
i = s.index('elif [ "$ATT" = 26 ]; then')
j = s.index('elif [ "$ATT" = 25 ]; then')
blk = s[i:j]

anchor = "    echo \"  (c) 撤名单 ⇒ 探针 B 段必须是 agent 拒(not-allowed)，"
"**不能**是 errno=2\""
assert blk.count(anchor) == 1, '(c) 锚点'
ins = '''    echo "  (b″) ★D 块：把授权链 G1..G7 也在**同一枪**里跑一遍(SKIP_CHAIN=1 KEEP=1 ⇒ 活窗口、结尾不重启)"
    DEVOK
    # ★让 regress 自己挑第三方包当对象：它挑的 uid 与我们这一枪里 setprof 的 $TU 无关，
    #   两块互不污染(共用一个 uid 的话，D 块的撤销会把 B 块的后续判据条件改掉)。
    SKIP_CHAIN=1 KEEP=1 bash kmod/regress_ksu.sh >kmod/w103_evidence/w29_regress.txt 2>&1
    RC=$?
    echo "    regress 退出码=$RC(0=G1..G7 全绿；否则看下面几行)"
    grep -aE "^  \\[G[0-9]\\]|汇总：FAIL" kmod/w103_evidence/w29_regress.txt | tail -10 | sed 's/^/    /'
    echo "  存证 w29_regress"

'''
blk = blk.replace(anchor, ins + anchor, 1)
s = s[:i] + blk + s[j:]
io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('D 块已接进 ATT=26')

# ---------- 总闸加 D ----------
p2 = 'kmod/check_acceptance.sh'
t = io.open(p2, encoding='utf-8').read()
old = '''echo
# ★三块里少任何一块都不许说"全绿"'''
new = '''echo "--- D. 授权链 G1..G7(同一枪里跑的第二套判据) ---"
RG=kmod/w103_evidence/w29_regress.txt
if ! grep -aq "存证 w29_regress" "$LOG"; then
    echo "  [SKIP] 本发日志没有『存证 w29_regress』⇒ 驱动没跑到 D 块(旧存证不算)"
    SKIPPED=$((SKIPPED+1))
elif [ ! -s "$RG" ]; then
    echo "  [FAIL] 没有 w29_regress ⇒ D 块没测到"
    fail=$((fail+1))
else
    R=$(tr -d '\\000' < "$RG")
    echo "$R" | grep -aE "^  \\[G[0-9]\\]" | sed 's/^/    /'
    echo "$R" | grep -aqE "汇总：FAIL=0" && echo "  [ok] G1..G7 全绿(第二套独立判据)" \\
        || { echo "  [FAIL] 授权链有 FAIL：[$(echo "$R" | grep -aE '汇总：FAIL' | head -1)]"; fail=$((fail+1)); }
fi

echo
# ★四块里少任何一块都不许说"全绿"'''
assert t.count(old) == 1, '总闸锚点'
t = t.replace(old, new, 1)
t = t.replace('SKIPPED=0   # ★SKIP 不是 PASS', 'SKIPPED=0   # ★SKIP 不是 PASS', 1)
t = t.replace('(A/B/C 三块都真测到)', '(A/B/C/D 四块都真测到)')
t = t.replace('挂载三态 + 域可控 + 机器无残留', '挂载三态 + 域可控 + 机器无残留 + 授权链 7 闸')
t = t.replace('$((3-SKIPPED))', '$((4-SKIPPED))')
io.open(p2, 'w', encoding='utf-8', newline='\n').write(t)
print('总闸已加 D 块')
