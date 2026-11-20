#!/system/bin/sh
# b8_detach.sh —— 通过 root 腿(@sushd)派单时，脚本一跑就会超过派单通道的存活时间（实测 >25s 会被收掉）。
#   办法：让 root 腿只负责"拉起并立刻返回"，真正的活交给 setsid 脱离的进程。
#   用法：@sushd:/data/local/tmp/b8_detach.sh <要跑的脚本绝对路径>
T="$1"
case "$T" in
    /data/local/tmp/*|/sdcard/*) : ;;
    *) echo "用法: b8_detach.sh <绝对路径(限 /data/local/tmp 或 /sdcard)>"; exit 2 ;;
esac
[ -f "$T" ] || { echo "[x] 不存在: $T"; exit 2; }
chmod 755 "$T" 2>/dev/null
setsid /system/bin/sh "$T" >/dev/null 2>&1 &
echo "LAUNCHED pid=$! target=$T"
