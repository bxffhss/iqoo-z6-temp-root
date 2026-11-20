#!/system/bin/sh
# w170b_slots.sh —— 纯读：把这一发窗口里 ko 自己已经写好的"CFI 桩报告"拿回来，并把执法者模块 `vr` 认清楚。
#   一手背景(w170 撞见)：escape 后的任务 `clone`(220)/`setuid`(146)/`setresuid`(147) 拿 -EPERM，
#   而 `__arm64_sys_clone` 的 kretprobe **零命中** ⇒ 拒发生在进入本体之前；
#   本仓库 rc47/rc49/rc57 早就量过同一形状：厂商模块 `vr` 把内核 `.cfi_jt` 里若干条的 `B` 目标
#   改到自己的入口垫(`__cfi_check+0x168 mod=[vr]`)，普通任务"看一眼再 tail-jump 回本体"，
#   escape 过的任务被它直接 -EPERM。我们只把 openat/execve/execveat/newfstatat/faccessat 五条处理过。
#   ⇒ 这一发要拿的是：①这五条**现在**的桩状态(改回来没有)；②`vr` 到底在册多少东西、有没有 clone/setuid 那一族。
L=/data/local/tmp/w170b.out
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== S up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce)"
    echo "--- /proc/ksu_slots 里的 CFI/CFIGUARD 报告(本次 insmod 就写了，只读不动) ---"
    grep -aE "CFIFIX|CFIGUARD|SLOTTBL|fixcfi" /proc/ksu_slots 2>&1 | cut -c1-230 | head -40
    echo "--- vr 这个模块 ---"
    grep -a "^vr " /proc/modules 2>&1
    echo "  模块总数=$(grep -ac . /proc/modules 2>/dev/null)；/sys/module/vr 存在=$([ -d /sys/module/vr ] && echo 是 || echo 否)"
    ls /sys/module/vr 2>&1 | tr '\n' ' ' | sed 's/^/  vr 目录下: /'
    echo "  kallsyms 里属于 [vr] 的符号数=$(grep -ac '\[vr\]$' /proc/kallsyms 2>/dev/null)"
    echo "  vr 里与 syscall/clone/setuid/cfi 相关的符号名(前 30)："
    grep -a '\[vr\]$' /proc/kallsyms 2>/dev/null | awk '{print $3}' | grep -aiE "clone|fork|setuid|setres|exec|open|cfi|guard|check|deni|perm|hook|notif" | head -30
    echo "  vr 全部符号名(前 40，认脸用)："
    grep -a '\[vr\]$' /proc/kallsyms 2>/dev/null | awk '{print $3}' | head -40
    echo "--- __cfi_check 与本体的相对位置(报告里出现过 __cfi_check+0x168) ---"
    grep -aE ' (__cfi_check|__arm64_sys_clone|__arm64_sys_clone3|__arm64_sys_setuid|__arm64_sys_setresuid|__arm64_sys_setgid)$' /proc/kallsyms 2>/dev/null
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
