#!/system/bin/sh
# w186_fdread.sh —— 只做一件事：读官方 Manager 现在的 fd 表，把**原文**落盘，然后退出(<10s)。
#   ★两条硬规矩(都是 §6.188 用一发窗口换来的)：
#   ① 判据要看**状态本身**，但状态的**原文**必须留档——上一发只有 `行=1` 这个数，原文没存，
#      而进程随后就被 pm uninstall 带走 ⇒ 那条读数永远无法复核。
#   ② `ls … | grep` 用**精确 token `ksu_driver`**：驱动 fd 在内核里名字写死成 `anon_inode:[ksu_driver]`
#      (还有 `[ksu_driver_su]`，见 cm57/ksuctl.c:271)，所以 `-i ksu` 虽能命中，但精确串才是"这就是那条 fd"的判据。
#   ③ `ls … 2>&1 | grep -i ksu` 会把错误行吃掉(错误文本里没有 ksu)，"计数=0"于是同时兼容
#      "真的没有"和"根本没读到" ⇒ stderr 单独落一行，进程在不在单独判。
L=/data/local/tmp/w186_fdread.out
exec >>"$L" 2>&1
RAW=/data/local/tmp/w186_fdline.txt
PKG=$(head -1 /data/local/tmp/w186_want.txt 2>/dev/null | tr -d ' \r\n')
echo "=== w186_fdread up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) pkg=[$PKG] ==="
# ★先 pidof(一次 syscall)，扫 /proc 只当兜底：今晚两条 root 腿都死在"扫 /proc/*/cmdline"那一段(§6.193⑤)
MP=$(pidof "$PKG" 2>/dev/null | cut -d' ' -f1)
if [ -z "$MP" ]; then
    for d in /proc/[0-9]*; do
        grep -qaF "$PKG" "$d/cmdline" 2>/dev/null && { MP=${d#/proc/}; break; }
    done
    echo "(pidof 空，走 cmdline 兜底)"
fi
if [ -z "$MP" ]; then
    echo "[!] 那个进程已经不在(被杀/被卸载) ⇒ 这一轮读不到，别把'读不到'当'没装上'"
    echo "===== DONE ====="; exit 0
fi
echo "pid=$MP state=$(grep -a '^State' /proc/$MP/status 2>/dev/null | head -1 | cut -c1-24)"
echo "读 fd 表的 stderr(单独一行，空=读到了)：$(ls -d /proc/$MP/fd 2>&1 | grep -av '^/proc')"
N=$(ls -1 /proc/$MP/fd 2>/dev/null | wc -l)
echo "fd 总数=$N"
ls -l /proc/$MP/fd 2>/dev/null | grep -a "ksu_driver" > "$RAW"
echo "含 ksu_driver 的行=$(wc -l < "$RAW" 2>/dev/null)  ← 原文在 $RAW"
sed 's/^/      /' "$RAW" 2>/dev/null
echo "内核回调行(dmesg.live 可能整段哑，空只算观测器没说话)："
grep -a "KSUFDINST 回调跑在 pid=$MP" /data/local/tmp/dmesg.live 2>/dev/null | tail -3 | sed 's/^/      /'
echo "KSUFDINST 全部行数=$(grep -ac 'KSUFDINST' /data/local/tmp/dmesg.live 2>/dev/null)"
echo "===== DONE ====="
