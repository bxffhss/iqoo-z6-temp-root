#!/system/bin/sh
# w797_umount_only.sh —— 第 55 发 #188 的**只 umount**探针（无参数，root 跑）：把 bind 收回，但**不碰源目录**，
#   看维持件会不会把挂载重新铺回来。
#   ★为什么不复用包内那条收尾腿：收尾腿连源一起删，会把"两态"混成第 54 发测过的那一态——本发要的就是**源还在**这一态。
#   ★★判据里有一条自我约束：如果挂载**没**收回，这一格按"未测"记，不许让维持件替仪器的失败背账。
L=/data/local/tmp/w797.out
TGT=/product/bin
NB=/data/adb/ksu/pbin
KL=/data/local/tmp/w774_keeper.log
: > "$L" 2>/dev/null
#   ★权限排在写第一行之前(第 54 发那一格的规矩：翻了 MAC 就改不动了)。
chmod 666 "$L" 2>/dev/null
{
    echo "=== 只 umount 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) ==="
    echo "  前：$TGT/su=$([ -e "$TGT/su" ] && echo 在 || echo 没了) 源内文件=$(ls -A "$NB" 2>/dev/null | wc -l) mount=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-58 | tr '\n' '|')]"
    /system/bin/umount "$TGT"; R1=$?
    ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
    if [ "${ML:-1}" != 0 ]; then
        /system/bin/umount -D "$TGT"; R2=$?
        ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
    else
        R2=没重试
    fi
    echo "  umount rc1=$R1 rc2(-D)=$R2 ⇒ 挂载行=${ML:-读数取不到} $TGT/su=$([ -e "$TGT/su" ] && echo 还在 || echo 没了) 源内文件=$(ls -A "$NB" 2>/dev/null | wc -l) ★这一格要求**源还在**，否则就退化成第 54 发测过的『删源』态"
    if [ "${ML:-1}" != 0 ]; then
        echo "  [x] 挂载没收回(还剩 ${ML} 行) ⇒ **这一格按未测记**，不去轮询维持件(仪器自己没造出坏态，不能让被测对象背账)"
        echo "=== 完(未测) up=$(cut -d' ' -f1 /proc/uptime) ==="
        exit 5
    fi
    i=0
    while [ "$i" -lt 20 ]; do
        i=$((i + 1)); /system/bin/sleep 3
        if [ -e "$TGT/su" ]; then echo "  复现了：第 $((i * 3)) 秒 $TGT/su 回来了"; break; fi
    done
    [ -e "$TGT/su" ] || echo "  ★60 秒没回来 ⇒ 维持件对『只被 umount』这一态**不生效**(这就是本发要的答案，不是环境坏)"
    echo "  末态 挂载行=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null) mount=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-58 | tr '\n' '|')] 源内文件=$(ls -A "$NB" 2>/dev/null | wc -l) $TGT/su=$([ -e "$TGT/su" ] && echo 在 || echo 没了)"
    echo "  keeper 计数：重建=$(grep -ac '重建#' "$KL" 2>/dev/null | tr -dc '0-9') 修好了=$(grep -ac '修好了' "$KL" 2>/dev/null | tr -dc '0-9') GIVEUP=$(grep -ac GIVEUP "$KL" 2>/dev/null | tr -dc '0-9')"
    echo "  keeper尾=[$(tail -4 "$KL" 2>/dev/null | tr '\n' '|' | cut -c1-330)]"
    echo "=== 只 umount 完 up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
