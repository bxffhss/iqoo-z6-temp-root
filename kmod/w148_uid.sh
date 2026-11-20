#!/system/bin/sh
# w148_uid.sh —— 在窗口里把"包名 → 真 uid"落到文件，供 #53 的授权触发器用。
#
# 为什么不让 PC 侧猜：packages.list 只有 root 读得到(shell 域 EACCES)，而 dumpsys package 在这台
# vivo 上被砍过；硬编码 uid 更危险——重装同一个 app uid 会变(§6.113③ 就是拿旧 uid 打完整发)。
#
# ★★★ 两条各用一次真代价换来的规矩(就写在本文件里，别再靠记忆)：
#  ① **自喂**：脚本级 「exec >"$L"「 之后**绝不能再 「cat "$L"「**——cat 读的就是自己的 stdout，
#     读到的字节又写回同一个文件，永远读不到 EOF。第 45 发实测：设备侧那个文件长到
#     **12.4 GB**(ls 看到 12413255680)，同时把主机 G 盘的驱动日志灌到 **11.9 GB** 写满磁盘
#     (「sed: No space left on device「)。
#     安全的两种写法：块级重定向 「{ … } >"$L"「 再在**块外** cat(w133_probe.sh 那种)，
#     或者像这里——**只写不回显**，由驱动侧去 cat。
#  ② **形状闸**：这台机 packages.list 尾部有几行**被写坏的两字段行**(字节是
#     「com.termux 10817」，而真行在第 72 行是 「com.termux.api 10817 0 /data/user/0/…」)，
#     时间线对得上 20:44 那次 HARD_RESET 打断 PMS 重写 ⇒ 「grep "^pkg "「 会同时命中真行与坏行，
#     于是拿到两个 uid。判据必须要求 **NF>=4 且 $1 与包名完全相等**，uid 还必须是 3~6 位纯数字。
L=${OUT:-/data/local/tmp/w148_uid.out}
PKG1=$(head -c 64 /data/local/tmp/w148_pkg1.txt 2>/dev/null); [ -n "$PKG1" ] || PKG1=com.termux
exec >"$L" 2>&1
echo "=== UID-LOOKUP up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) pkg1=$PKG1 ==="
F=/data/system/packages.list
for p in $PKG1 com.suw.manager com.android.shell; do
    n=$(awk -v P="$p" '$1==P && NF>=4 {c++} END {print c+0}' "$F" 2>/dev/null)
    bad=$(awk -v P="$p" '$1==P && NF<4 {c++} END {print c+0}' "$F" 2>/dev/null)
    uid=$(awk -v P="$p" '$1==P && NF>=4 {print $2; exit}' "$F" 2>/dev/null)
    if echo "$uid" | grep -qE '^[0-9]{3,6}$'; then vok=OK; else vok=BAD; fi
    echo "LOOKUP $p 形状正确=$n 坏行=$bad uid=[${uid}] 数字校验=$vok"
    if [ "$p" = "$PKG1" ]; then
        if [ "$n" -ge 1 ] && [ "$vok" = OK ]; then
            printf '%s' "$uid" > /data/local/tmp/w132_tuid.txt
        else
            rm -f /data/local/tmp/w132_tuid.txt
            echo "!! 不写回(形状正确=$n 校验=$vok) ⇒ 宁可使驱动在下一步停住，也不带假 uid 往下打"
        fi
    fi
done
echo "写回 w132_tuid.txt = [$(cat /data/local/tmp/w132_tuid.txt 2>&1)]"
echo "该包进程现在活着吗: pidof=[$(pidof "$PKG1")]"
echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
chmod 666 "$L"
