#!/system/bin/sh
# w218_install.sh —— root 侧短腿：把"交付态的 su 在执法下到底死在哪一步"的探针装进 Termux 自己的 home。
#   为什么要分三格：§6.217/#105 那一发要能**分开**这三种失败，否则又会写成"su 不通"这种没用的结论 ——
#     [A] 不提权的 `/system/bin/id`      = 这个壳自己活着、能 exec(排除"Termux 本身被 vr 打死")；
#     [B] `su -c /system/bin/id`         = 交付态那一枪，输出文本能分清三件事：
#            `Permission denied`            ⇒ **app 连 exec /product/bin/su 都被策略拒**(和 su 内部逻辑无关)；
#            `既没有…驱动 fd，也连不上 @suwshd` ⇒ exec 成了，但**两条拿 root 的路都断**(改道没塞 fd + 派单被拒)；
#            `uid=0(root) … context=…`       ⇒ **通了**(这一格才是 #105 要的"成")。
#     [C] `command -v su` + `ls -l`      = 证明它命中的是我们交付的那个文件(PATH 第一位是 /product/bin)。
#   ★探针里每一格都自带执法态读数(`enf=`)，不再依赖 `getenforce`(例59：那个命令不在这个壳的 PATH 里)。
O=/data/local/tmp/w218_install.out
exec >"$O" 2>&1
H=/data/data/com.termux/files/home
echo "=== W218 装 su 探针 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) ==="
cat >"$H/w218.sh" <<'PEOF'
{
    echo "== up=$(cut -d' ' -f1 /proc/uptime) enf=[$(cat /sys/fs/selinux/enforce 2>&1)] 我自己 uid=$(id -u) 域=[$(cat /proc/self/attr/current 2>&1)]"
    echo "[C] which_su=[$(command -v su 2>&1)]  ls=[$(ls -l /product/bin/su 2>&1 | cut -c1-46)]"
    echo "[A] 不提权: $(/system/bin/id 2>&1)"
    echo "[B] su -c id:"
    SUW_SU_DEBUG=1 su -c '/system/bin/id' 2>&1
    echo "[B] su_rc=$?"
} > /data/data/com.termux/files/home/w218_su.txt 2>&1
chmod 666 /data/data/com.termux/files/home/w218_su.txt 2>/dev/null
# ★第二份落在**自己 scoped 的外部目录**里：执法态下 root 腿(shell 域)读别的 app 的 app_data_file 大概率被拒，
#   而 /sdcard/Android/data/<pkg> 是它自己的目录(app 写得到)，root 侧走 /data/media 也读得到 ⇒ 两条腿都有出口。
cp /data/data/com.termux/files/home/w218_su.txt /sdcard/Android/data/com.termux/files/w218_su.txt 2>/dev/null
echo "第二份 rc=$? 在 /sdcard/Android/data/com.termux/files/w218_su.txt" >> /data/data/com.termux/files/home/w218_su.txt
PEOF
chmod 644 "$H/w218.sh"
chown 10667:10667 "$H/w218.sh" 2>/dev/null
ls -lZ "$H/w218.sh" 2>&1
sh -n "$H/w218.sh" && echo "内层 sh -n OK" || echo "★内层语法就没过"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
