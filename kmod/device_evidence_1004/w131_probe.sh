#!/system/bin/sh
# w131_probe.sh —— 独立探针：以**第三方 uid** execve /system/bin/su，把结果落到 666 的文件。
#   给 root 侧跑(@sushd:)。挂载之前跑一次(必须失败=负对照地基)，挂载之后跑一次(必须 uid=0)，
#   撤名单之后再跑一次(必须被 agent 拒 = ERR not-allowed，而**不是** ENOENT)。
#   ★三次跑的是同一条命令、同一个 uid ⇒ 唯一变量是"文件在不在"和"名单在不在"，判据才干净。
L=${OUT:-/data/local/tmp/w131_probe.out}
CTL=/data/local/tmp/ksuctl86
U=$(cat /data/local/tmp/w131_tuid.txt 2>/dev/null)
[ -n "$U" ] || U=10667
{
    echo "=== probe up=$(cut -d' ' -f1 /proc/uptime) target_uid=$U ==="
    echo "FILE=$(/system/bin/ls -l /system/bin/su 2>&1)"
    echo "MOUNT=$(grep -a ' /system/bin ' /proc/self/mountinfo | cut -c1-120)"
    echo "AGENT=$(pidof shd | tr ' ' ',')  (空 ⇒ 静态 su 一定拿不到 fd，这一发不算)"
    echo "--- 结果 ---"
    $CTL su "$U" "id" 2>&1
    echo "RC=$?"
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
