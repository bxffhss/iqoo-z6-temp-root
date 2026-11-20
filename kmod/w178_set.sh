#!/system/bin/sh
# w178_set.sh —— 把 ko 的 ksu_capclamp 设成 `w178_want.txt` 里那个值并**读回来**(0644 的模块参数，root 才写得动 ⇒ 走 agent 通道)。
#   ★不从命令行取参：`@sushd:` 那个动词只认"冒号后面整个字符串是脚本路径"，带不上参数(§6.178 前先按已验证的形状来)。
#   判据不读"我 echo 过了"，读的是 /sys 里此刻的值。
V=$(cat /data/local/tmp/w178_want.txt 2>/dev/null | tr -dc '0-9' | head -c1)
[ -n "$V" ] || V=1
L=/data/local/tmp/w178_set.out
exec >>"$L" 2>&1
P=/sys/module/kernelsu/parameters/ksu_capclamp
echo "=== w178_set 目标=$V(来自 want.txt) up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ==="
echo "id=$(id)"
if [ ! -e "$P" ]; then
    echo "[x] $P 不存在 ⇒ 这一发的 ko 不是 rc63(没带 ksu_capclamp 参数)，什么都不设"
else
    echo "设之前: $(cat $P 2>&1)"
    echo "$V" > "$P" 2>&1
    echo "echo rc=$?"
    echo "CAPCLAMP_NOW=$(cat $P 2>&1)"
fi
echo "===== DONE ====="
