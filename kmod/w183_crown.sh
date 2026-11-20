#!/system/bin/sh
# w183_crown.sh —— 操作 /proc/ksu_crown：把 `w183_want.txt` 里那一行(数字或 `?`)写进口，再从 /proc/ksu_slots 读回回执。
#   ★与 w182_set.sh 同一形状：`@sushd:` 这个动词带不上命令行参数(冒号后整串当路径) ⇒ 值走文件。
L=/data/local/tmp/w183_crown.out
exec >>"$L" 2>&1
P=/proc/ksu_crown
echo "=== w183_crown up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
if [ ! -e "$P" ]; then
    echo "[x] $P 不存在 ⇒ 这一发的 ko 不是 rc65(没有王座把手)，什么都不设"
    echo "===== DONE ====="
    exit 0
fi
V=$(head -1 /data/local/tmp/w183_want.txt 2>/dev/null | tr -d ' \r\n')
echo "want=[$V]"
# ★rc66 的两处运行时自证(§6.191)：① `cat` 读口能回数字 ⇒ 读处理器在(rc65 没有读口，cat 回空)
R0=$(cat $P 2>/dev/null | tr -d ' \r\n')
echo "读口 cat /proc/ksu_crown = [$R0]  $( [ -n "$R0" ] && echo '⇒ 这是 rc66+(有 read 处理器)' || echo '⇒ 没有读口(rc65 或更早)')'"
#   ② 空写**不复零**才是守卫生效。★这条只在确认是 rc66 之后才敢做——在 rc65 上一次空写就把王座清成 0(§6.188⑤ 那起事故)。
if [ -n "$R0" ]; then
    printf '\n' > "$P" 2>/dev/null
    R1=$(cat $P 2>/dev/null | tr -d ' \r\n')
    echo "空写之后读口 = [$R1]  (与 [$R0] $([ "$R0" = "$R1" ] && echo '相同 ⇒ 空写守卫生效' || echo '★不同 ⇒ 守卫没生效，别再用这个 ko 做王座实验'))"
    cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN 忽略[^|]*' | tail -1 | sed 's/^/  守卫回执: /'
fi
echo "$V" > "$P" 2>&1
echo "echo rc=$?"
echo "写完读口 = [$(cat $P 2>/dev/null | tr -d ' \r\n')]"
echo "--- /proc/ksu_slots 里 CROWN/crown 相关行 ---"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN [^|]*' | sed 's/^/  /'
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'crown proc=[^|]*' | sed 's/^/  /'
echo "getenforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
echo "===== DONE ====="
