#!/system/bin/sh
# w171_cfiscan.sh —— #73 第一步的读数(纯读)：触发 rc61-A 的"__arm64_sys_*.cfi_jt 全表扫"，把报告捞回来。
#   判据只用一条：B 目标(或桩+8 那个 .quad 的落点)解析出来的**模块名 == vr** ⇒ 才算"这条桩被 vr 管"。
#   这条判据在已知的 5 条上给出 3 命中(openat/execve/execveat)/2 干净(newfstatat/faccessat) ⇒ 双向验证过。
#   ★要看到的正对照：上面那 3 条仍然在名单里；要看到的新读数：`clone`/`setuid`/`setresuid` 在不在名单里
#     —— 这四条(含未管的 setgid 对照)无论中不中都会留字("没这条读数"和"读了说没有"是两回事)。
L=/data/local/tmp/w171_cfiscan.out
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== CF up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce)"
    echo "  我们的 ko 在册: $(grep -a '^kernelsu ' /proc/modules 2>/dev/null | tr '\n' ' ')"
    [ -e /proc/ksu_cfiscan ] || echo "  [x] 没有 /proc/ksu_cfiscan ⇒ 这不是 rc61 的 ko(查 push_ksu.sh 的 KO= 与设备侧 md5)"
    echo "  触发前 slots 里 VRCFI 行数=$(grep -ac VRCFI /proc/ksu_slots 2>/dev/null)"
    echo 1 >/proc/ksu_cfiscan 2>&1
    echo "  触发 rc=$?"
    echo "--- 报告 ---"
    grep -a "VRCFI" /proc/ksu_slots 2>/dev/null | tail -90
    echo "--- 这一发最关心的四条 ---"
    grep -aE "VRCFI.*(sys_clone|sys_setuid|sys_setresuid|sys_setgid)" /proc/ksu_slots 2>/dev/null
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
