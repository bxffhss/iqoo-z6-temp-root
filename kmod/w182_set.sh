#!/system/bin/sh
# w182_set.sh —— 操作 /proc/ksu_mgrdomain：把 `w182_want.txt` 里那一行写进口，然后把回执从 /proc/ksu_slots 里读回来。
#   want 里的内容可以是：`?`(只问) / 一个域串(设) / 与起点一样的域串(复位)。
#   ★写口的是 root(agent 通道)，所以 `@sushd:` 派下来；0600 的口 shell 写不动。
L=/data/local/tmp/w182_set.out
exec >>"$L" 2>&1
P=/proc/ksu_mgrdomain
W=/data/local/tmp/w182_want.txt
echo "=== w182_set up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ==="
echo "id=$(id)"
if [ ! -e "$P" ]; then
    echo "[x] $P 不存在 ⇒ 这一发的 ko 不是 rc64，什么都不设"
    echo "===== DONE ====="
    exit 0
fi
V=$(head -1 "$W" 2>/dev/null)
echo "want=[$V]"
echo "$V" > "$P" 2>&1
echo "echo rc=$?"
echo "--- /proc/ksu_slots 里 MGRDOMAIN 相关行(全) ---"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'MGRDOMAIN[^|]*' | sed 's/^/  /'
echo "--- mgrdomain 口的 proc 名与起点回执 ---"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'mgrdomain[^|]*' | sed 's/^/  /'
echo "getenforce=$(getenforce)"
echo "===== DONE ====="
