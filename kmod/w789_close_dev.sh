#!/system/bin/sh
# w789_close_dev.sh —— 第 54 发的收尾腿（**无参数**，root 跑）。
#   ★为什么又做一个"参数less"的文件：打字进来的尾参今天会被输入法吃掉(三次 `... break` 都退化成默认模式)，
#     而收尾这条腿一旦退化成就不是收尾了——它必须只会干这一件事。
#   ★顺序是硬约束(记忆那条"关窗铁律")：维持件开关 → 等它自退 → umount → 删 root-only 源与 /data/adb → 删脚印 →
#     **恢复执法放最后一步**(翻了 MAC 之后 @sushd 与改道 su 两条路同时关门，什么都做不了)。
L=/data/local/tmp/w789.out
SW=/data/local/tmp/ksu_pbin_keep
KEEP=/data/local/tmp/w774_pbin_keeper.sh
NB=/data/adb/ksu/pbin
TGT=/product/bin
# ★第 54 发一手(这条腿自己踩的)：原来把 `chmod 666` 排在**恢复执法之后**——执法一开，这条腿连自己的产物都读不到了
#   (实得 `root:root 0600`，PC 侧只能看到字节数 2967，里面的 umount rc／/data/adb 复证全成"未复证")。
#   ⇒ 权限要在写第一行之前就好，而不是在末尾补。
: > "$L" 2>/dev/null
chmod 666 "$L" 2>/dev/null
{
    echo "=== 收尾 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) boot_id=$(cat /proc/sys/kernel/random/boot_id) ==="
    rm -f "$SW" 2>/dev/null
    echo "  [1] 开关 $SW 已删 ⇒ 等维持件自己退(节拍 20 秒，给 25 秒)"
    sleep 25
    echo "      keeper 还在否=$(pgrep -f w774_pbin_keeper >/dev/null 2>&1 && echo 在 || echo 退了)  keeper 日志行数=$(grep -ac . /data/local/tmp/w774_keeper.log 2>/dev/null | tr -dc '0-9')"
    # ★★第 54 发一手(这条腿自己造出来的坏态)：umount 失败后照样 `rm -rf` 源 ⇒ mountinfo 立刻变成
    #   「/adb/ksu/pbin//deleted」——正是今晚那扇窗里「/product/bin 整层空壳、su 找不到」的形状。
    #   ⇒ 现在加一道闸：**只有确认挂载行真的收回了才许删源**；没收回就只删名单，源留给下一发的 stage 前置闸去重建
    #     (挂载不活过重启，所以留着源不会变成常驻脚印)。
    /system/bin/umount "$TGT" 2>/dev/null; RC1=$?
    ROW=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
    if [ "${ROW:-1}" != 0 ]; then
        /system/bin/umount -D "$TGT" 2>/dev/null; RC2=$?
        ROW=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
    else
        RC2=没重试
    fi
    echo "  [2] umount rc1=$RC1 rc2(-D 重试)=$RC2 ⇒ mountinfo pbin 行=${ROW:-读数取不到} 目录现在=[$(ls -A $TGT 2>/dev/null | tr '\n' ' ')] $TGT/su=$([ -e "$TGT/su" ] && echo 还在 || echo 没了_改道落点已收回)"
    echo "  [3] /data/adb 清之前=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
    if [ "${ROW:-1}" = 0 ]; then
        rm -rf /data/adb/ksu /data/adb/ksud /data/adb/su 2>/dev/null; RC3=$?
        echo "      挂载已收回 ⇒ 删净 rc=$RC3 之后=[$(ls /data/adb 2>&1 | tr '\n' ' ')] 复证=[$(ls -d /data/adb/ksu /data/adb/ksud /data/adb/su 2>&1 | tr '\n' '|')]"
    else
        rm -f /data/adb/ksu/.allowlist 2>/dev/null; RC3=$?
        echo "      ★挂载没收回(行=${ROW}) ⇒ **不删源**(只删名单 rc=$RC3)；源与落点副本留着由下一发 stage 的前置闸重建"
        echo "      之后=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
    fi
    echo "  [4] 脚印(产物/载荷删，工具腿 .sh 按规矩留着)"
    rm -rf /data/local/tmp/w786_esc /data/local/tmp/pbin /data/local/tmp/newbin /data/local/tmp/subin /data/local/tmp/kd /data/local/tmp/w787_live.snap 2>/dev/null
    rm -f /data/local/tmp/w777.out /data/local/tmp/w777_dmesg.txt /data/local/tmp/w774_keeper.log /data/local/tmp/w786.out /data/local/tmp/w731_root.txt /data/local/tmp/w731_root.pid /data/local/tmp/w731_root_sampler.out /data/local/tmp/w720_dmesg.txt /data/local/tmp/w720_lines.txt /data/local/tmp/w720_ksubirth_dump.out /data/local/tmp/dmesg.live /data/local/tmp/dmesg2.log /data/local/tmp/dmesg2.log.tmp /data/local/tmp/dmesg_full.txt /data/local/tmp/ksu_stage.log /data/local/tmp/ksu_stage.txt /data/local/tmp/punch.log /data/local/tmp/sushd_last.out /data/local/tmp/shd.log /data/local/tmp/app_ksu.txt /data/local/tmp/ksu_ui_track.txt /data/local/tmp/ksu_ftrace.txt /data/local/tmp/ksu_ftrace_armed /data/local/tmp/ksu_kallsyms.txt /data/local/tmp/w135_um.err /data/local/tmp/w625_seedrestart.out /data/local/tmp/w625_lock /data/local/tmp/pr.log /data/local/tmp/ksu_args.txt /data/local/tmp/ksu_slots.dump.txt 2>/dev/null
    rm -f /data/local/tmp/w76*.xml /data/local/tmp/w77*.xml /data/local/tmp/w78*.xml /data/local/tmp/w783.xml /data/local/tmp/w772.xml 2>/dev/null
    echo "      删后还在的本轮名字=[$(ls -1 /data/local/tmp 2>/dev/null | grep -aE 'w7[0-9]|dmesg|punch|ksu_|app_ksu|shd|w625|pbin|^kd$|esc' | tr '\n' ' ')]"
    echo "      留下的工具腿=[$(ls -1 /data/local/tmp 2>/dev/null | grep -aE '^w[0-9]+.*\.sh$' | tr '\n' ' ')]"
    echo "      没动的第三方件(先调查过才留下)=[$(ls -1 /data/local/tmp 2>/dev/null | grep -aE 'brevent|toolkit|scene' | tr '\n' ' ')]"
    echo 1 > /sys/fs/selinux/enforce 2>/dev/null
    echo "  [5] ★最后一步恢复执法：回读=$(cat /sys/fs/selinux/enforce 2>/dev/null) getenforce=$(/system/bin/getenforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules)"
    sync
    echo "=== 收尾 完 up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
chmod 666 "$L" 2>/dev/null
