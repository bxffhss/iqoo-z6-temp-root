#!/system/bin/sh
# w230_prep.sh —— 第 100 发(#109)的 root 短腿(Permissive 阶段跑)。
#   要答的那一格(§6.221④)：执法下拦 `/system/bin/su` 的到底是**改道后的目标**的 execute，
#     而把一个 **app 在执法下本来就能 exec 的落点**(它自己数据目录里那份)当目标，能不能放行。
#   ★单变量=改道目标的落点。名单/bind/域回退这些一律沿用上一发的成功配方。
#   ★这一腿只读数、不改任何状态(尤其不碰 enforce)——例58：改状态前先确认恢复动作还跑得动。
O=/data/local/tmp/w230_prep.out
exec >>"$O" 2>&1
D=/data/data/com.termux/files/usr/bin
TGT=$D/kd2
echo "=== W230 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf_file=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "STAGE0 done"

# --- 门(#103)：短腿域必须是 shell，否则后面所有"执法态"读数都不作数 ---
for p in $(pidof ksuctl); do
    echo "  门: pid=$p 域=$(cat /proc/$p/attr/current 2>&1)"
done
echo "STAGE1 done"

# --- 改道目标的本体读数 ---
echo "  目标 args 里那份: $TGT"
ls -lZ "$TGT" 2>&1 | cut -c1-150
echo "  对照 [P2] 那份(上一发实测执法下 app 能 exec): "
ls -lZ "$D/su" 2>&1 | cut -c1-150
echo "  父目录: "
ls -ldZ "$D" 2>&1 | cut -c1-150
echo "  /dev/ksud 还在(不再是目标): $(ls -lZ /dev/ksud 2>&1 | cut -c1-120)"
echo "  shim 字节数(认版本): $(ls -l "$TGT" 2>&1 | tail -1 | tr -s ' ' | cut -d' ' -f3,5)"
echo "STAGE2 done"

# --- 把 app 侧探针写进 Termux 自己的目录 ---
cat >"$D/w230.sh" <<'PEOF'
{
    echo "== up=$(cut -d' ' -f1 /proc/uptime 2>&1) uid=$(id -u) 域=[$(cat /proc/self/attr/current 2>&1)] enf=[$(cat /sys/fs/selinux/enforce 2>&1)]"
    echo "[R1] 改道目标在不在 app 眼里: [$(ls -l /data/data/com.termux/files/usr/bin/kd2 2>&1 | cut -c1-60)]"
    echo "[R2] /system/bin/su -c id  ← 改道唯一匹配的那条路径"
    /system/bin/su -c /system/bin/id 2>&1
    echo "     R2_rc=$?"
    echo "[R3] su -c id ← PATH 那份(不会改道，负对照：它不该拿到驱动 fd)"
    su -c /system/bin/id 2>&1
    echo "     R3_rc=$?"
    echo "[R4] /system/bin/su 这个文件本身: [$(ls -l /system/bin/su 2>&1 | cut -c1-48)]"
} 2>&1 | tee /data/data/com.termux/files/home/w230.txt
PEOF
RC1=$?
chown "$(stat -c '%u:%g' "$D" 2>/dev/null)" "$D/w230.sh" 2>/dev/null
chmod 644 "$D/w230.sh" 2>/dev/null
echo "  探针写入 rc=$RC1 属主=$(stat -c '%U:%G 0%a' "$D/w230.sh" 2>&1)"
if sh -n "$D/w230.sh" 2>&1; then echo "  内层 mksh sh -n 过"; else echo "  ★内层语法没过(别往下走)"; fi
echo "STAGE3 done"

# --- 名单里有没有 Termux(判据不许靠界面；动词真名=allowlist) ---
echo "  名单原样: $(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | tail -3 | cut -c1-170)"
echo "  名单里 10667: [$(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | grep -ac 10667)]  (0=没授权，这一发就别往下测)"
echo "STAGE4 done"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
