#!/system/bin/sh
# w240_prep.sh —— 改道目标"落点+标签"这一格的读数腿(Permissive 阶段跑)。
#   第 101 发(#112)用它测过 `app_exec_data_file` ⇒ **执法下 rc=126 判死**：无域转换的 exec 除了
#     `file:execute` 还要 **`file:execute_no_trans`**，而该类型对 `untrusted_app_all` 恰好缺这一条(§6.224⑥)。
#   第 102 发(#113)用同一个脚本换标签：类型从设备上的 `/data/local/tmp/ksu_redirect_con` 取，
#     默认 `apk_data_file`(`appdomain` 对它 execute+execute_no_trans+open+read 齐全 ⇒ 唯一通用候选)。
#   ★单变量=目标的标签(落点仍是共享的 /data/local/tmp/kd)；shim 仍用已验的 sustatic(v2)。
#   ★这一腿只读数+贴标签，不碰 enforce(例58：翻执法的恢复动作只能是 adb reboot)。
O=/data/local/tmp/w240_prep.out
exec >>"$O" 2>&1
T=/data/local/tmp/kd
D=/data/data/com.termux/files/usr/bin
V2=/data/local/tmp/sustatic
echo "=== W240 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf_file=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "STAGE0 done"

# --- 门(#103)：短腿域必须是 shell ---
for p in $(pidof ksuctl); do
    echo "  门: pid=$p 域=$(cat /proc/$p/attr/current 2>&1)"
done
echo "STAGE1 done"

# --- 目标必须是 v2(已知答案：2,245,720 / md5 9aca0a3e…)，否则"扫驱动 fd"那格压根不会发生 ---
echo "  目标现值: $(ls -l $T 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,9) md5=$(md5sum $T 2>&1 | cut -c1-32)"
echo "  v2 源:    $(ls -l $V2 2>&1 | tr -s ' ' | cut -d' ' -f5) md5=$(md5sum $V2 2>&1 | cut -c1-32)"
echo "  已知答案: 2245720 / 9aca0a3ed9ffea1059ec127e3e1f1e9b"
cp "$V2" "$T"; echo "  cp rc=$?"
chown 0:0 "$T" 2>/dev/null; chmod 755 "$T"; echo "  chown0/chmod755 rc=$?"
SZ=$(ls -l "$T" 2>&1 | tr -s ' ' | cut -d' ' -f5)
MD=$(md5sum "$T" 2>&1 | cut -c1-32)
echo "  换后: 字节=$SZ md5=$MD  $( [ "$SZ" = 2245720 ] && echo 对 || echo '★不是 v2，别往下测')"
echo "STAGE2 done"

# --- ★卡点(a)：chcon 贴不贴得上(贴完 ls -Z 回读) ---
#   类型可以从设备上一个小文件里取，改实验不必改脚本(#113 就是只换这一格)：
#     /data/local/tmp/ksu_redirect_con  一行=一个 context
#   默认=apk_data_file(§6.224⑥：appdomain 对它 execute+execute_no_trans+open+read 齐全；
#   app_exec_data_file 缺 execute_no_trans ⇒ 已判死)
CON=$(head -1 /data/local/tmp/ksu_redirect_con 2>/dev/null)
[ -n "$CON" ] || CON=u:object_r:apk_data_file:s0
echo "  贴之前: $(ls -lZd $T 2>&1 | tr -s ' ' | cut -d' ' -f1,5)"
chcon "$CON" "$T"; echo "  chcon [$CON] rc=$?"
echo "  贴之后: $(ls -lZd $T 2>&1 | tr -s ' ' | cut -d' ' -f1,5)"
echo "  父目录: $(ls -lZd $T 2>&1 >/dev/null; ls -ldZ /data/local/tmp 2>&1 | tr -s ' ' | cut -d' ' -f1,5)"
echo "  对照(上一发赢的那个落点，现在不该存在): $(ls -lZ $D/kd2 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9)"
echo "STAGE3 done"

# --- app 侧探针(放 Termux 自己目录：那是 app 唯一肯定能读+exec 的地方，与被测目标无关) ---
cat >"$D/w240.sh" <<'PEOF'
{
    echo "== uid=$(id -u) 域=[$(cat /proc/self/attr/current 2>&1)]"
    echo "[S1] app 眼里共享目标: [$(ls -l /data/local/tmp/kd 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,9)]"
    echo "[S2] LD_PRELOAD= /system/bin/su -c id  ← 主判据(改道+共享目标)"
    LD_PRELOAD= /system/bin/su -c /system/bin/id 2>&1
    echo "     S2_rc=$?"
    echo "[S3] /system/bin/su -c id(不清 env)  ← 期望仍是 CANNOT LINK=Termux 的 LD_PRELOAD，不是策略"
    /system/bin/su -c /system/bin/id 2>&1
    echo "     S3_rc=$?"
    echo "[S4] /system/bin/su 在不在: [$(ls -l /system/bin/su 2>&1 | cut -c1-48)]"
    echo "[S5] echo id | su  ← 不带 -c，但命令从 stdin 喂(#111：把'交互壳静默 rc=1'与'tty 读不到'分开)"
    echo id | LD_PRELOAD= /system/bin/su 2>&1
    echo "     S5_rc=$?"
    echo "[S6] su < /dev/null  ← 不带 -c、stdin 立刻 EOF：看它自己退成什么"
    LD_PRELOAD= /system/bin/su </dev/null 2>&1
    echo "     S6_rc=$?"
} 2>&1 | tee /data/data/com.termux/files/home/w240.txt
PEOF
RC1=$?
chown "$(stat -c '%u:%g' "$D" 2>/dev/null)" "$D/w240.sh" 2>/dev/null
chmod 644 "$D/w240.sh"
echo "  探针写入 rc=$RC1 属主=$(stat -c '%U:%G 0%a' "$D/w240.sh" 2>&1)"
if sh -n "$D/w240.sh" 2>&1; then echo "  内层 mksh sh -n 过"; else echo "  ★内层语法没过(别往下走)"; fi
echo "STAGE4 done"

# --- 名单(内核口径，不靠界面) ---
echo "  名单原样: $(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | tail -3 | cut -c1-170)"
echo "  名单里 10667: [$(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | grep -ac 10667)]"
echo "STAGE5 done"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
