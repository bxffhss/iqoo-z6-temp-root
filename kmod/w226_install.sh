#!/system/bin/sh
# w226_install.sh —— root 短腿：把 #108 那一发要用的两枪探针装进 Termux 自己的 home。
#   为什么是这两枪：§6.221 源码账 —— sucompat 的匹配是 `memcmp(path, "/system/bin/su", sizeof)`，
#   **整串精确匹配**，所以只有 `/system/bin/su` 这条会被改道(⇒ 才会拿到注入的驱动 fd)；
#   PATH 里那份(=app 自己目录的拷贝)不会走改道，跑它是为了拿"另一侧"的对照读数。
#   ★输出既上屏(执法态下 root 腿读不了 app 私有目录，屏幕是唯一通道)也落盘(Permissive 阶段可回读)。
O=/data/local/tmp/w226_install.out
exec >"$O" 2>&1
H=/data/data/com.termux/files/home
echo "=== W226 装 #108 探针 up=$(cut -d' ' -f1 /proc/uptime) 本腿域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
cat >"$H/w226.sh" <<'PEOF'
{
    echo "== up=$(cut -d' ' -f1 /proc/uptime) enf=[$(cat /sys/fs/selinux/enforce 2>&1)] uid=$(id -u) 域=[$(cat /proc/self/attr/current 2>&1)]"
    echo "[P0] PATH 里的 su 是哪份: [$(command -v su 2>&1)] md5=[$(md5sum "$(command -v su)" 2>&1 | cut -c1-32)]"
    echo "[P1] /system/bin/su -c id   ← 改道唯一匹配的那条路径"
    /system/bin/su -c /system/bin/id 2>&1
    echo "     rc=$?"
    echo "[P2] su -c id               ← 走 PATH(app 自己目录那份，不会改道)"
    su -c /system/bin/id 2>&1
    echo "     rc=$?"
    echo "[P3] 文件本身在不在: [$(ls -l /system/bin/su 2>&1 | cut -c1-40)]"
} 2>&1 | tee /data/data/com.termux/files/home/w226.txt
PEOF
chmod 644 "$H/w226.sh"; chown 10667:10667 "$H/w226.sh" 2>/dev/null
ls -lZ "$H/w226.sh" 2>&1
sh -n "$H/w226.sh" && echo "内层 sh -n OK" || echo "★内层语法没过"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
