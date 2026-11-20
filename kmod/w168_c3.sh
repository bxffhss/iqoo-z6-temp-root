#!/system/bin/sh
# w168_c3.sh —— #72 的决定性一格：**只把 profile 的域换掉**，别的一个都不动，看 fork 恢不恢复。
#   一手前提(本仓库早先那两条读数)：同一族 EPERM 曾经连 openat/openat2/execve 一起中(§ksuctl.c:740 的判据
#   "openat2 也 -EPERM ⇒ 拦的是任务/血统，与 syscall 号无关")，而当时 SELinux 是宽容的 ⇒ 不是 avc。
#   ⇒ 若"换域即活"：执法者读的是这个任务的 **sid/域** ⇒ 交付解法=把 su 的 profile 域设成厂商认的那个，
#     **完全不用改 ko**(比 #70 便宜得多，也不动产品语义)。
#   ⇒ 若"换域照旧 EPERM"：那就与域无关，剩下的是 uid/血统/我们 escape 留下的状态。
#   ★先读回内核里的名单(判据要读状态本身)：不许假设 setprof 生效了。
L=/data/local/tmp/w168_c3.out
PR=/data/local/tmp/forkprobe
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== C3 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    case "$U1" in
        [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) echo "[x] U1=[$U1] 不是 uid ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    echo "--- 内核现在的名单(域以这里读回的为准) ---"
    "$CTL" allowlist 2>&1 | grep -aiE "uid|domain|allow|entry|version" | head -12
    echo "--- granted(U1) ---"
    "$CTL" granted "$U1" 2>&1 | tail -3
    echo "--- C3：escape 成 uid=$U1 之后跑探针(enf=$(getenforce)) ---"
    "$CTL" grant "$U1" "$PR" C3
    echo "--- C3 完 enf=$(getenforce) ---"
    echo "--- dmesg 尾巴 ---"
    dmesg 2>/dev/null | tail -30
    echo "--- 关键字 ---"
    dmesg 2>/dev/null | grep -aiE "avc:|KSUBEAT|unrecognized SID|denied|WARNING|Oops|BUG:" | tail -20
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
