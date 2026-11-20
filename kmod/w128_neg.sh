#!/system/bin/sh
# w128_neg.sh —— **负对照**：名单撤掉之后，同一个 uid 再跑一次静态 su，必须拿不到 root。
#   (§6.123；也是本项目一贯口径：正判据单独存在时不能排除"全局后门"这种最坏回退)
#   期望：`su: 提权失败 uid=10667 ...` 或 agent 直接 `ERR not-allowed`，且**没有** uid=0(root)。
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) 负对照：uid=10667 名单已撤 ==="
    /data/local/tmp/ksuctl86 su 10667 /data/data/com.termux/files/usr/bin/su -c id
    echo "rc=$?"
} > /data/local/tmp/w128_neg.out 2>&1
chmod 666 /data/local/tmp/w128_neg.out
