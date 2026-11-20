#!/system/bin/sh
# w167_grantladder.sh —— 跑 `ksuctl88 grant <uid>` 的阶梯，重点读 **LADDER 14 = escape 之后能不能 fork**(#72)。
#   为什么用这条路当探针：真机 su 出来的那个 root shell 已经**不能 fork**，连探针程序都启动不了
#   (启动它本身就要 fork) ⇒ 只能让"内核替我们换好 cred 的那个进程"**自己**去 fork 并报 errno。
#   `cmd_grant` 正好是这个形状：fork 一个子进程 → 降到目标 uid → ioctl(GRANT_ROOT) → 一串 LADDER。
L=/data/local/tmp/w167_grantladder.out
CTL=/data/local/tmp/ksuctl88
{
    echo "=== GL up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) ==="
    U=$(cat /data/local/tmp/w167_uid 2>/dev/null | tr -dc '0-9')
    case "$U" in
      [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
      *) echo "  bad-uid=[$U] ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    [ -x "$CTL" ] || { echo "  !! 没有 $CTL"; echo "===== DONE"; exit 0; }
    echo "--- 纯 escape(不带命令)：LADDER 0..14 全量 ---"
    "$CTL" grant "$U" 2>&1 | cut -c1-168
    echo "--- 带命令(看 LADDER 9 的 execvp 通不通)：只留尾巴 ---"
    "$CTL" grant "$U" /system/bin/id 2>&1 | grep -aE "LADDER (9|14)|uid=|子进程结束" | tail -8 | cut -c1-168
    echo "  内核这一瞬间说了什么(dmesg.live 尾巴，仅供参考，观测器可能哑)："
    grep -aE "allow root for|KSUBEAT (SU0|X7|X8)|can't|EAGAIN" /data/local/tmp/dmesg.live 2>/dev/null | tail -4 | cut -c1-160 | sed 's/^/    /'
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
