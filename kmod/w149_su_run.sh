#!/system/bin/sh
# w149_su_run.sh —— #53 的正判据：**起点域已经是 kernel**(见 w149_offline 的 [2]/[3])，
# 所以只要 profile 的域真的落地，attr/current 就会从 u:r:kernel:s0 **变成别的**(往下读更容易证伪)。
# 顺序：先按 uid 起一个**不加 su**的孩子(基线)，再 `su -c` 同一个脚本(换了凭据之后)。
L=/data/local/tmp/w149_su_run.out
CTL=/data/local/tmp/ksuctl87
DOM=/data/local/tmp/w147_dom2.sh
# uid 用 w148_uid.sh 现场反查写回的那个数(硬编码过一次就作废：重装 app 会换 uid)
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
{
    echo "===== W149-SURUN up=$(cut -d' ' -f1 /proc/uptime) uid=$U enf=$(getenforce) ====="
    echo "--- [A] 基线：以 $U 起**零 fork 载荷**，不加 su(此时域应是起点域 kernel) ---"
    $CTL supath "$U" /product/bin /data/local/tmp/domprint 2>&1 | head -14
    echo "--- [B] 判据：同一个 uid 加 su(profile 的域由 APK 侧 setprof 决定) ---"
    echo "    ★载荷必须是**单个可执行文件**：上一发这里是 shell 脚本，su 之后的孩子"
    echo "      生不出孙子(mksh: can't fork - try again)⇒ 整格零读数。domprint 不 fork。"
    $CTL supath "$U" /product/bin su -c /data/local/tmp/domprint 2>&1 | head -16
    echo "--- [C] 内核侧：这个 boot 里我们填的域有没有被 secctx_to_secid 解过 ---"
    echo "    (★必须按 want_uid=$U 过滤！tail -6 只会捞到**最近**那批，而最近的一直是 Manager(10308)
    的 default 模板回执 ⇒ 看起来像"内核根本没处理我们的域"，其实是被别人的行挤掉了。第 46 发一手。)"
    # ★两道过滤都要：**按 uid** + **按时间窗**(只取最近 120 秒的内核行)。
    #   第 49 发的教训：只按 uid 过滤会拿到很早的那批(t=1016 是上一轮的 shell 域)，
    #   只 tail 会拿到 Manager 那批 ⇒ 真正属于"我们这一枪"的 -22 行两条筛子都漏掉，
    #   看起来像"内核没按域办事"，其实是**采集窗口没对上**。
    NOW=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1); FROM=$((NOW-120))
    echo "    (时间窗 = 最近 120 秒，即 up>=$FROM)"
    awk -v a="$FROM" '$2+0>=a+0' /data/local/tmp/dmesg2.log 2>/dev/null         | grep -aE "X2 profile|X6 before setup_selinux|secctx_to_secid" | tail -8 | cut -c1-170
    echo "    (对照：不分时间窗、按 want_uid=$U 的最后 3 行)"
    grep -a "want_uid=$U" /data/local/tmp/dmesg2.log 2>/dev/null | tail -3 | cut -c1-170
    echo "    (对照：不分 uid 的最后 2 行)"
    grep -aE "X2 profile|X6 before setup_selinux|secctx_to_secid" /data/local/tmp/dmesg2.log 2>/dev/null | tail -2 | cut -c1-170
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
