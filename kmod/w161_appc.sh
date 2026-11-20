#!/system/bin/sh
# w161_appc.sh —— 钉死"libsu 的 RootService 宿主(app_process)起不来"到底卡在哪一层。
#   已知(上一发探针)：官方 Manager 名下有两个 ruid=0 的 /system/bin/sh(stdin/stdout 都是管道)
#   ⇒ libsu 的 **root shell 是活的**；但没有 root 的 app_process ⇒ 它要跑的那个 daemon 没起来。
#   两种可能必须分开：① 我们这台 ROM 上 root 域根本 exec 不动 app_process(SELinux/binder)；
#                     ② app_process 能跑，只是 libsu 那条命令没写进 shell(协议/时序)。
#   本脚本只做只读侦察 + 一次带 timeout 的自测，不碰别人的进程。
L=/data/local/tmp/w161_appc.out
{
    echo "=== APPC up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 我自己 ctx=$(cat /proc/self/attr/current 2>/dev/null)"
    MP=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    echo "A) 官方 Manager 名下 root shell 的 SELinux 上下文："
    if [ -n "$MP" ]; then
        for p in $(pgrep -P "$MP" 2>/dev/null); do
            echo "   pid=$p uid=$(awk '/^Uid/{print $2}' /proc/$p/status 2>/dev/null) ctx=$(cat /proc/$p/attr/current 2>/dev/null) exe=$(ls -l /proc/$p/exe 2>/dev/null | sed 's/.*-> //')"
        done
    else
        echo "   (Manager 没在跑)"
    fi
    echo "B) app_process 在不在、binder 节点在不在："
    ls -l /system/bin/app_process64 /dev/binder /dev/hwbinder 2>&1 | cut -c1-120 | sed 's/^/   /'
    echo "C) ★自测：我自己(root/$(cat /proc/self/attr/current 2>/dev/null))能不能 exec 动 app_process？"
    T0=$(cut -d' ' -f1 /proc/uptime)
    timeout 8 /system/bin/app_process64 --help 2>&1 | head -6 | sed 's/^/   out| /'
    echo "   rc=$? (用了 $(cut -d' ' -f1 /proc/uptime | awk -v a="$T0" '{print $1-a}')s；能打出用法/参数说明=exec 通)"
    echo "D) 自测：root 域能不能开 /dev/binder(拿不到 fd 的话 RootService 必死)："
    timeout 6 sh -c 'exec 9<>/dev/binder && echo "   开 /dev/binder 成功 fd=9"; exec 9>&-' 2>&1 | head -3
    echo "   rc=$?"
    echo "E) 内核侧这一发有没有收到过任何 SET_APP_PROFILE 痕迹(再确认一次)："
    grep -aic 'SET_APP_PROFILE' /data/local/tmp/dmesg.live 2>/dev/null | sed 's/^/   命中行数=/'
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
