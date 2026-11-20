#!/system/bin/sh
# 一次性读腿：把内核里的**全量 allow list** 打出来(§6.201 的判别——官方 UI 那笔写到底落在哪个 uid)。
O=/data/local/tmp/w205_list.out
exec >"$O" 2>&1
echo "=== W205 全量名单 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
for c in /data/local/tmp/ksuctl88 /data/local/tmp/ksuctl87 /data/local/tmp/ksuctl; do
    if [ -x "$c" ]; then
        echo "### 用 $c"
        "$c" mgr 2>&1 | grep -a GET_MANAGER_APPID
        echo "--- allowlist ---"
        "$c" allowlist 2>&1 | head -16
        echo "--- denylist ---"
        "$c" denylist 2>&1 | head -6
        break
    fi
done
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
