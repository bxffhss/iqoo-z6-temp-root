#!/system/bin/sh
L=/data/local/tmp/w187_fdproof.out
exec >>"$L" 2>&1
echo "=== w187_fdproof up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
for p in $(ls -d /proc/[0-9]* 2>/dev/null); do
  pid=${p#/proc/}
  grep -qaF me.weishu.kernelsu "$p/cmdline" 2>/dev/null && echo "  还在的官方进程: pid=$pid state=$(grep -a '^State' $p/status 2>/dev/null | head -1)"
done
echo "[A] 14850 的 fd 里含 ksu 的行:"
ls -l /proc/14850/fd 2>&1 | grep -ai ksu | sed 's/^/      /'
echo "[B] dmesg.live 里所有 KSUFDINST 行(带内核时间戳):"
grep -a 'KSUFDINST' /data/local/tmp/dmesg.live 2>/dev/null | tail -8 | sed 's/^/      /'
echo "[C] 计数: 回调行=$(grep -ac 'KSUFDINST 回调跑在' /data/local/tmp/dmesg.live 2>/dev/null)  已排队=$(grep -ac '已排队' /data/local/tmp/dmesg.live 2>/dev/null)"
echo "[D] 王座/名单侧读数:"
grep -aE 'GET_MANAGER_APPID|CROWN' /data/local/tmp/w161_g2.out /data/local/tmp/ksu_stage.log 2>/dev/null | tail -3 | sed 's/^/      /'
echo "getenforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
echo "===== DONE ====="
