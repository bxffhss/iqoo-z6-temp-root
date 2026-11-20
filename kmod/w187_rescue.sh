#!/system/bin/sh
# w187_rescue.sh —— leg2 中途死掉之后救窗口(只做四件快事，全部 <30s，别在这里埋长循环)：
#   ① 读王座现在是谁 ② 不是 suw 就指回 10319 ③ 顺手把官方 uid/状态捞一条(leg2 死前的目标进程)
#   ④ 卸载官方，恢复"只装 suw"的交付形态。每步都带回执，最后 ===== DONE =====
L=/data/local/tmp/w187_rescue.out
exec >>"$L" 2>&1
OFL=me.weishu.kernelsu
echo "=== w187_rescue up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
echo "[1] 现在王座:"; printf '?\n' > /proc/ksu_crown 2>&1; echo "    rc=$?"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN [^|]*' | tail -3 | sed 's/^/      /'
echo "[2] 指回 suw(10319):"; echo 10319 > /proc/ksu_crown 2>&1; echo "    rc=$?"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN [^|]*' | tail -2 | sed 's/^/      /'
printf '?\n' > /proc/ksu_crown 2>&1
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN 现在[^|]*' | tail -1 | sed 's/^/      复位后: /'
echo "[3] leg2 那个目标进程 14850:"
grep -aE '^State|^Uid|^PPid' /proc/14850/status 2>&1 | sed 's/^/      /'
echo "    它在进程表: $(ps -A -o PID,USER,STAT,NAME 2>/dev/null | grep -a 14850 | head -1)"
echo "    它装过 fd 没有(含 ksu 的行)=$(ls -l /proc/14850/fd 2>&1 | grep -aci ksu)  fd 总数=$(ls -1 /proc/14850/fd 2>/dev/null | wc -l)"
echo "[4] 卸载官方:"; runcon u:r:shell:s0 pm uninstall $OFL 2>&1 | sed 's/^/      /'
echo "    现在第三方包数=$(runcon u:r:shell:s0 pm list packages -3 2>/dev/null | wc -l)  官方在否=$(runcon u:r:shell:s0 pm list packages 2>/dev/null | grep -ac $OFL)"
echo "getenforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
echo "===== DONE ====="
