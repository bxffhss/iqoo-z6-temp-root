#!/system/bin/sh
# w767_close_shot53.sh —— 第 53 发的**唯一一条 root 腿**：先补内核侧读数(乙组缺的那半)，再按顺序收尾。
#   为什么要它：B 形状(名单主条目=com.termux)下 **suw 没被授权** ⇒ PC 侧 `rleg` 通道全瞎(实测 `w731 … 没等到 DONE`、
#     设备上连 .out 都没生成)；唯一还在的 root 入口就是包自己授权的那个 app ⇒ 用 `/system/bin/su -c <本件>` 跑。
#   ★顺序：读数 → 清 /data/adb → 跑 151 条清理件 → 补删本轮新名字 → **恢复执法放在最后** → sync。
#   ★产物 0666 + 每行自带 up=(同源排序)；不碰工具腿(KEEP)，不 rmmod 活窗口。
L=/data/local/tmp/w767.out
D=/data/local/tmp/w767_dmesg.txt
MGR=me.weishu.kernelsu
: > "$L" 2>/dev/null
{
    echo "=== W767 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) boot_id=$(cat /proc/sys/kernel/random/boot_id) ==="
    P=$(pidof "$MGR" 2>/dev/null | cut -d' ' -f1)
    echo "--- 1) 内核侧读数(乙组缺的那半：改道链/fd/Seccomp/cap) ---"
    /system/bin/dmesg > "$D" 2>/dev/null
    echo "    dmesg 行数=$(grep -ac . "$D") 字节=$(wc -c < "$D") 首行=[$(head -1 "$D" | cut -c1-40)] 末行=[$(tail -1 "$D" | cut -c1-40)]"
    echo "    KSUBIRTH=$(grep -ac KSUBIRTH "$D") queued=$(grep -ac 'queued self fd' "$D") seen=$(grep -ac 'seen Manager' "$D") dupskip=$(grep -ac dupskip "$D") childskip=$(grep -ac childskip "$D") cap真踢=$(grep -ac 'KSUBIRTH cap' "$D") KSUFDINST=$(grep -ac KSUFDINST "$D")"
    echo "    改道链 SU0=$(grep -ac 'KSUBEAT SU0' "$D") SD4=$(grep -ac 'KSUBEAT SD4' "$D") SU1=$(grep -ac 'KSUBEAT SU1' "$D") SD1decline=$(grep -ac 'SD1 decline' "$D") signal6=$(grep -ac 'received signal 6' "$D")"
    echo "    SU链最后 6 行："; grep -a 'KSUBEAT SU' "$D" | tail -6 | sed 's/^/      /'
    echo "    KSUBIRTH 最后 8 行："; grep -a KSUBIRTH "$D" | tail -8 | sed 's/^/      /'
    echo "    Manager pid=${P:-无}"; [ -n "$P" ] && echo "      fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver) fd总数=$(ls -1 /proc/$P/fd 2>/dev/null | grep -ac .) Seccomp=$(grep -aE '^Seccomp:' /proc/$P/status 2>/dev/null | tr -dc '0-9') 出生ticks=$(awk '{print $22}' /proc/$P/stat 2>/dev/null)"
    echo "--- 2) 名单与授权现读 ---"
    /system/bin/cat /proc/ksu_install_fd >/dev/null 2>&1
    echo "    /data/adb 清之前=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
    rm -rf /data/adb/ksu /data/adb/ksud /data/adb/su 2>/dev/null
    echo "    /data/adb 清之后=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
    echo "--- 3) 151 条清理件 ---"
    sh /data/local/tmp/w558_rm3.sh >/dev/null 2>&1
    echo "    跑完(读回在下面这条补删里一起看)"
    echo "--- 4) 本轮新名字补删(名单会漂移，例 176⑤第四次) ---"
    cd /data/local/tmp 2>/dev/null
    rm -f w767_dmesg.txt w731_root.txt w731_root.pid w731_root_sampler.out w762.xml w763.xml w765.xml w766.xml \
          dmesg.live dmesg2.log dmesg2.log.tmp dmesg_full.txt ksu_stage.log ksu_stage.txt punch.log \
          w567_probe w720_dmesg.txt w720_lines.txt w720_ksubirth_dump.out w690_dmesg.txt w690_ksubirth_lines.txt \
          w690_ksubirth.out w694_ringwitness.out w625_seedrestart.out w625_lock sushd_last.out 2>/dev/null
    rm -f /sdcard/w567_a.xml /sdcard/w567_su_abs.png /sdcard/w567_b.xml /sdcard/w567_chmod.png /sdcard/w450_close.txt 2>/dev/null
    echo "    剩下的 dmesg/本轮名=[$(ls -1 /data/local/tmp 2>/dev/null | grep -aE 'dmesg|w76[0-9]|w73[0-9]|w72[0-9]|w567' | tr '\n' ' ')]"
    echo "    留在设备上的工具腿=[$(ls -1 /data/local/tmp 2>/dev/null | grep -aE '^w(6|7)[0-9][0-9].*\.sh$' | tr '\n' ' ')]"
    echo "--- 5) 恢复执法（必须排最后，翻了 MAC 之后 root 腿全关） ---"
    echo 1 > /sys/fs/selinux/enforce 2>/dev/null
    echo "    回读 enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null) getenforce=$(getenforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules)"
    sync
    echo "=== W767 完 up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
chmod 666 "$L" 2>/dev/null
echo "W767 rc=$? out=$L"
