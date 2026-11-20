#!/system/bin/sh
# w214_enfread.sh —— #101 那一格：**执法态下 shell 域的 root 能不能读官方模板目录**(=§6.211② 那堵墙)。
#   前提(§6.214 的门)：这条腿必须是 **`u:r:shell:s0`** 起的守护的孩子 —— `u:r:kernel:s0` 在执法下连 exec 都不行(§6.212③)。
# ★写法上守三条今天的学费：
#   例47：会 fork 的探针一律 `exec >>`(孩子与父共享 offset 会互相盖字节)，并且每步打 `STAGE n` 标号 ⇒ 中途死掉也看得出死在第几步；
#   例58：这一腿**会改被测状态**(`setenforce 1`)，所以末尾"写回 0"要试，但**不许把它当恢复方案** ——
#         真正的恢复 = `adb reboot`(shell 身份就够，不依赖 root 通道)。写回失败本身也是一条读数。
#   例59：每个取值都要能区分"没值"和"取不到值" ⇒ 执法态读 `cat /sys/fs/selinux/enforce`(不依赖 PATH)，
#         域读 `/proc/self/attr/current`，字节用 `od -An -c`(0x7F 不会被传输吃掉)。
O=/data/local/tmp/w214_enfread.out
exec >>"$O" 2>&1
D=/data/adb/ksu/profile/templates
echo "######## $(date) 起 ########"
echo "STAGE0 身份: uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) up=$(cut -d' ' -f1 /proc/uptime)"
echo "STAGE1 执法前(Permissive)先读一遍，当'这腿本来就读得到'的基线:"
echo "   ls  =[$(ls "$D" 2>&1)]"
echo "   head=[$(head -c 24 "$D/vivoshell.root" 2>&1)]"
echo "   sys =[$(head -c 3 /system/bin/sh 2>&1 | od -An -c 2>&1 | tr -d ' \n')]"
echo "STAGE2 ★翻执法: echo 1 > /sys/fs/selinux/enforce"
echo 1 > /sys/fs/selinux/enforce
echo "   写入 rc=$?  现在 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] up=$(cut -d' ' -f1 /proc/uptime)"
echo "STAGE3 执法后还跑得动外部命令吗(这一步就是 §6.212③ 里 kernel 域死掉的地方):"
echo "   域=[$(cat /proc/self/attr/current 2>&1)]  ls -d=[$(ls -d "$D" 2>&1)]"
echo "STAGE4 ★主读数:"
echo "   ls  =[$(ls "$D" 2>&1)]"
echo "   cat =[$(head -c 24 "$D/vivoshell.root" 2>&1)]"
echo "   sys =[$(head -c 3 /system/bin/sh 2>&1 | od -An -c 2>&1 | tr -d ' \n')]"
echo "   tmp =[$(ls /data/local/tmp/w210_tmpl.out 2>&1)]"
echo "STAGE5 试着写回 0(失败也没关系，恢复动作是 adb reboot):"
echo 0 > /sys/fs/selinux/enforce
echo "   写回 rc=$? 现在 enf=[$(cat /sys/fs/selinux/enforce 2>&1)]"
echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
chmod 666 "$O" 2>/dev/null
