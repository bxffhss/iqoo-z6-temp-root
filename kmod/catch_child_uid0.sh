#!/system/bin/sh
# catch_child_uid0.sh —— 在设备侧近距离抓"app fork 的子进程被 KernelSU 授权成 uid=0"的那一刻
# 为什么要放在设备侧跑：PC 侧每条 adb shell 有几十毫秒往返，而那个子进程实测只活 ~4 秒；
# 判据要的是**外部观察者**(不是 app 自报)，所以必须贴着读 /proc/<pid>/status。
R=/sdcard/Android/data/com.suw.manager/files/ksu_grant.txt
PKG=com.suw.manager
KEY='子进程 pid='

upt() { cut -d ' ' -f1 /proc/uptime; }
OLD=$(grep -oE "$KEY[0-9]+" "$R" 2>/dev/null | tail -1 | cut -d= -f2)
echo "触发前旧子进程 pid=[$OLD] up=$(upt)"

am force-stop $PKG
sleep 2
am start -n $PKG/.MainActivity --es auto ksuarm >/dev/null 2>&1
echo "已触发 am start --es auto ksuarm  up=$(upt)"

i=0
seen=0
last=""
while [ $i -lt 300 ]; do
    P=$(grep -oE "$KEY[0-9]+" "$R" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$P" ] && [ "$P" != "$OLD" ]; then
        seen=1
        U=$(grep -m1 '^Uid:' /proc/$P/status 2>/dev/null | tr '\t' ' ')
        C=$(grep -m1 '^CapEff:' /proc/$P/status 2>/dev/null | tr -d '\t ')
        NOW="$(upt)|$U|$C"
        if [ "$NOW" != "$last" ]; then                 # 只在变化时打印，免得刷 300 行
            echo "  轮$i pid=$P Uid=[$U] $C"
            last="$NOW"
        fi
        case "$U" in
            *" 0 0 0 0"*)
                echo "*** 外部一手证据到手: 子进程 $P 的 Uid 全是 0, $C (由 shell 身份从 /proc 读, 不是 app 自报)"
                echo "*** 同时看一眼 UI 进程本身: app pid=$(pidof $PKG | cut -d' ' -f1)"
                AP=$(pidof $PKG | cut -d' ' -f1)
                [ -n "$AP" ] && grep -h '^Uid:' /proc/$AP/task/*/status 2>/dev/null | sort | uniq -c | head -3
                break ;;
        esac
        # 子进程没了也算结论(说明它被杀)，但不能提前退出：还没看到 uid 变过
        if [ -z "$U" ]; then
            echo "  轮$i: 子进程 $P 已经不在了(读不到 status) up=$(upt)"
            break
        fi
    fi
    i=$((i + 1))
    sleep 0.1
done
echo "===== 轮询 $i 次(约 $((i / 10))s)结束  seen=$seen up=$(upt) ====="
