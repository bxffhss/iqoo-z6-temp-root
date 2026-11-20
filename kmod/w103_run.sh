#!/system/bin/sh
# w103_run.sh —— 标准 su(sucompat)那一格的**触发器 + 取证**，给 @sushd: 用单 token 调(§6.103)。
#   为什么走 root 侧脚本而不是 app：app 那条 armed 支路会**先** ioctl(GRANT_ROOT) 变成 uid 0 再 exec，
#   而 sucompat 的入口是 `ksu_is_allow_uid_for_current` —— uid 0 属于 system uid，直接被
#   `forbid_system_uid` 拒(回执 SD1) ⇒ 永远测不到改道。这里用 `ksuctl su <uid> <cmd>`：
#   fork ⇒ 子进程 setgid/setuid 到名单内的 uid ⇒ `execve("/system/bin/su", ["su","-c",cmd])`
#   ⇒ 这就是"一个被 KernelSU 名单授权的普通 app 打 `su`"在内核里的形状，一步都不多。
L=/data/local/tmp/w103_run.out
U=${U:-10319}
C=${C:-id}
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$U cmd=[$C] ==="
    /data/local/tmp/ksuctl86 su "$U" "$C"
    echo "rc=$?"
} >"$L" 2>&1
chmod 666 "$L"
