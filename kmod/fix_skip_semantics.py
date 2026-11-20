import io
p='kmod/check_acceptance.sh'
s=io.open(p,encoding='utf-8').read()
old = "    echo \"  [SKIP] 本发日志里没有『存证 w29_residue』这一行 ⇒ 这一发没跑到 C 段(空枪/早退)，旧存证不算证据\"\n    C_SKIP=1"
new = ("    echo \"  [SKIP] 本发日志里没有『存证 w29_residue』这一行 ⇒ 这一发没跑到 C 段(空枪/早退)，旧存证不算证据\"\n"
       "    C_SKIP=1; SKIPPED=$((SKIPPED+1))")
assert s.count(old)==1
s=s.replace(old,new,1)
s=s.replace("fail=0\nexport LC_ALL=C","fail=0\nSKIPPED=0   # ★SKIP 不是 PASS：验收少一块就是不完整(第 51 发一手：C 被 SKIP 却打印\"全绿\")\nexport LC_ALL=C",1)
old2 = '''echo
[ $fail = 0 ] && echo "=== 合并验收全绿：挂载三态 + 域可控 + 机器无残留 ===" \
              || echo "=== 合计 $fail 条 FAIL(A=$a B=$b)，见上 ==="
exit $((fail>125 ? 125 : fail))'''
new2 = '''echo
if [ "$fail" = 0 ] && [ "$SKIPPED" = 0 ]; then
    echo "=== 合并验收全绿：挂载三态 + 域可控 + 机器无残留(A/B/C 三块都真测到) ==="
    exit 0
fi
if [ "$fail" = 0 ] && [ "$SKIPPED" != 0 ]; then
    # ★这一条分支就是为了不被我自己在上一发踩的坑复现：三块里少任何一块，都不许说"全绿"。
    echo "=== 验收不完整：测到的 $((3-SKIPPED))/3 块全绿，但有 $SKIPPED 块**根本没测到**(旧存证不算) ==="
    exit 90
fi
echo "=== 合计 $fail 条 FAIL(A=$a B=$b SKIP=$SKIPPED)，见上 ==="
[ "$fail" -gt 125 ] && exit 125
exit "$fail"'''
assert s.count(old2)==1
s=s.replace(old2,new2,1)
io.open(p,'w',encoding='utf-8',newline='\n').write(s)
print('SKIP 语义已改(不再可能读成全绿)')
