import io
p='kmod/check_acceptance.sh'
s=io.open(p,encoding='utf-8').read()
old='''if [ "${C_SKIP:-0}" = 1 ]; then :
elif [ ! -s "$E/w29_residue" ]; then
    echo "  [FAIL] 没有 w29_residue ⇒ 这一格根本没测到(不能当阴性)"'''
new='''# ★优先信 **w29_sweep**：它是"同一个 root 上下文里 rm 完立刻回读"，正是 §6.130 要的形状；
#   w29_residue 只是窗口内独立复核的一份(有更好，没有也不该判"没证到")。
if [ -s "$E/w29_sweep" ] && grep -aq "存证 w29_sweep" "$LOG"; then
    R=$(tr -d '\000' < "$E/w29_sweep")
    echo "$R" | grep -a "SWEEP up=" | head -1 | cut -c1-120 | sed 's/^/    /'
    for d in /data/adb /metadata/watchdog/ksu /data/local/tmp/pbin; do
        line=$(echo "$R" | sed -n '/\[3\]/,$p' | grep -aF "$d" | head -1)
        case "$line" in
          *"No such file"*) echo "  [ok] $d 清完之后 root 侧回读=不存在(同上下文 rm+ls，带信息量)";;
          "") echo "  [FAIL] [3] 段里没有 $d 的回读行"; fail=$((fail+1));;
          *)  echo "  [FAIL] $d 还在：[${line}]"; fail=$((fail+1));;
        esac
    done
    echo "$R" | grep -aqE "投放物残留数=0" && echo "  [ok] 投放物清零" \
        || echo "  [!] 投放物残留数不是 0：[$(echo "$R" | grep -a 残留清单 | head -1)]"
elif [ "${C_SKIP:-0}" = 1 ]; then
    echo "  [SKIP] 本发既没拉回 w29_sweep 也没拉回 w29_residue ⇒ C 段整体没测到(不算全绿)"
    SKIPPED=$((SKIPPED+1))
elif [ ! -s "$E/w29_residue" ]; then
    echo "  [FAIL] 没有 w29_residue ⇒ 这一格根本没测到(不能当阴性)"'''
assert s.count(old)==1, 'C 段锚点'
s=s.replace(old,new,1)
io.open(p,'w',encoding='utf-8',newline='\n').write(s)
print('C 段已改成优先认 sweep 的同上下文回读')
