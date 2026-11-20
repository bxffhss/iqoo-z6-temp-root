#!/system/bin/sh
# w119_mm.sh v2 —— **magic mount 极简版**：让 `/system/bin/su` 这个文件"真的存在"(符号链接到 /dev/ksud)。
#   给 root 侧跑(@sushd: 或 su -c)。md §6.116/§6.117
#
# 为什么走这条路：Termux/Shizuku 是"先 access()/stat() 探测再 execve"，本机 /system/bin/su 不存在
#   ⇒ 探测就 ENOENT，永远走不到改道(§6.116①)。开 stat/faccessat 钩子位这条路**在本机判死**
#   (§6.116②：第一句 access() 就让 F2 redirect id=79->42 刷屏、几毫秒打死机器)。
#   ⇒ 让文件真在：探测天然成功，execve 命中的还是已验证安全的"只改道"那半段。
#
# ★v1 的死法(窗口 119 一手)：`mount -t tmpfs tmpfs /system/bin` 之后脚本自己就没工具用了——
#   这台机 **/vendor/bin/* 是指向 /system/bin 的符号链接**，盖掉 /system/bin 等于把
#   basename/ls/ln/grep 全变悬空 ⇒ 农场建了 0 条，判据一句 `exec '/system/bin/sh' failed: No such file`。
#   ⇒ v2：mount 之前先 bind 出一份原件到 $B，**之后所有外部命令一律走 $B 的绝对路径**，
#   文件名用 shell 内建展开 `${f##*/}`，不碰 PATH。
L=/data/local/tmp/w119_mm.out
B=/dev/.binb
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo ?) uid=$(id -u 2>/dev/null || echo ?) ==="
    if grep -aq ' /system/bin ' /proc/mounts && [ -e "$B/su" ]; then :; fi
    # 已经盖过？(判据：/proc/mounts 里有 /system/bin 且 $B 里能看到原件)
    if grep -q ' /system/bin ' /proc/mounts 2>/dev/null; then
        echo "已经盖过了 ⇒ 只补 su 这一条链接"
        mkdir -p "$B" 2>/dev/null
        grep -q "$B " /proc/mounts || mount --bind /system/bin "$B"
        "$B/ln" -s /dev/ksud /system/bin/su 2>/dev/null
        "$B/ls" -l /system/bin/su
        exit 0
    fi
    mkdir -p "$B"
    mount --bind /system/bin "$B" || { echo "!! bind 失败 ⇒ 什么都不再动"; exit 1; }
    [ -x "$B/sh" ] || { echo "!! bind 之后 \$B/sh 不可用 ⇒ 停(不盖 /system/bin)"; exit 1; }
    mount -t tmpfs tmpfs /system/bin || { echo "!! tmpfs 失败 ⇒ 反 bind 后退出"; umount "$B"; exit 1; }
    n=0
    for f in "$B"/*; do
        [ -e "$f" ] || continue
        "$B/ln" -s "$f" "/system/bin/${f##*/}" 2>/dev/null && n=$((n + 1))
    done
    "$B/ln" -s /dev/ksud /system/bin/su 2>/dev/null
    echo "符号链接条目=$n 原件条目=$("$B/ls" "$B" 2>/dev/null | "$B/wc" -l)"
    echo "--- 判据(全部用 $B 的绝对路径，不靠 PATH) ---"
    "$B/ls" -l /system/bin/su
    [ -x /system/bin/su ] && echo "test -x /system/bin/su: OK" || echo "test -x: 失败"
    "$B/sh" -c 'echo "sh 经 /system/bin 还能用: yes"'
    "$B/sh" -c 'ls -l /system/bin/sh'
    echo "--- 这一条挂载 ---"
    grep ' /system/bin ' /proc/mounts
    echo "--- 撤销办法(窗口内)：umount /system/bin && umount $B；重启也一定干净 ---"
} >"$L" 2>&1
chmod 666 "$L"
