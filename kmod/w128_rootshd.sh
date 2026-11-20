#!/system/bin/sh
# w128_rootshd.sh —— 把 agent 换成 **root 版**（md §6.123③）
#   一手死因：`shd` 是 PC 侧用 adb shell 起的 ⇒ **uid 2000**；而 shd v4 的"问内核"用的
#   `KSU_IOCTL_UID_GRANTED_ROOT` 权限是 `manager_or_root`(`current_uid()==0 || is_manager()`)
#   ⇒ uid 2000 问不动 ⇒ 一律 EPERM ⇒ 静态 su 收到 `ERR not-allowed`（Termux 屏幕实拍）。
#   ⇒ 由 root 侧重起一份 shd，并把它的驱动 fd 用 /proc/ksu_install_fd 装上
#     （root 自己走 reboot 魔数那条会被 `forbid_system_uid` 拒，所以必须用这个触发口）。
L=/data/local/tmp/w128_rootshd.out
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "--- 杀掉 uid 2000 的旧 agent(abstract 名字只能有一个持有者) ---"
    for p in $(pidof shd); do echo "  kill $p (uid=$(cat /proc/$p/status 2>/dev/null | awk '/^Uid/{print $2}'))"; kill -9 "$p" 2>&1; done
    sleep 1
    echo "--- 以 root 起新 agent：allow 名单里放 Manager 的 uid，其余走内核查询 ---"
    ( setsid nohup /data/local/tmp/shd 31339 1800 10319 </dev/null >>/data/local/tmp/shd.log 2>&1 & )
    sleep 3
    NP=$(pidof shd | awk '{print $1}')
    echo "  新 pid=$NP uid=$(cat /proc/$NP/status 2>/dev/null | awk '/^Uid/{print $2}')"
    echo "--- 给它装驱动 fd(root 走 reboot 魔数会被 forbid_system_uid 拒 ⇒ 用 /proc 触发口) ---"
    ls -l /proc/ksu_install_fd 2>&1 | tail -1
    [ -n "$NP" ] && echo "$NP" > /proc/ksu_install_fd 2>&1 && echo "  已 echo $NP > /proc/ksu_install_fd"
    sleep 2
    echo "--- 自证：agent 自己有没有 fd、问内核能不能判 10667 ---"
    /data/local/tmp/shd --ksustat 2>&1 | head -3
    echo "--- 监听确认 ---"
    ls -l /proc/net/unix 2>/dev/null | head -1
    grep -a suwshd /proc/net/unix 2>/dev/null | head -2
} >"$L" 2>&1
chmod 666 "$L"
