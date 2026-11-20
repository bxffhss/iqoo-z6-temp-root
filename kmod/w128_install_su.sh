#!/system/bin/sh
# w128_install_su.sh —— 把**静态 su** 装进 Termux 自己的 PATH 目录，并当场验收（md §6.123）
#   给 root 侧跑（@sushd:）。不碰 syscall 钩子、不碰任何挂载 ⇒ 与 §6.116~§6.122 那两条死路无关。
L=/data/local/tmp/w128_su.out
BIN=/data/data/com.termux/files/usr/bin
U=${UID_:-10667}
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "--- 装之前 ---"
    ls -l "$BIN/su" 2>&1
    cp /data/local/tmp/sustatic "$BIN/su" && echo "cp OK" || echo "!! cp 失败"
    chmod 755 "$BIN/su"
    # Termux 的私有目录里出现一个 root:root 的文件没问题：它要的是 r-x 权限位，不是所有权
    ls -l "$BIN/su"
    echo "--- 判据①：静态？(不能依赖 linker64) ---"
    head -c 64 "$BIN/su" | od -An -tx1 | head -2
    echo "  (ELF 头之后若 e_type=2(ET_EXEC) 且没有 PT_INTERP 就是静态；这里用 file 看不成，下面用实跑证明)"
    echo "--- 判据②：以 Termux 的 uid($U) 跑它，看能不能变 root（=与在 Termux 里手敲 su 同一条链） ---"
    /data/local/tmp/ksuctl86 su "$U" "$BIN/su -c id"
    echo "  rc=$?"
    echo "--- 判据③：负对照——把名单撤掉，同一个 uid 再跑一次，必须失败 ---"
    echo "  (撤名单要 Manager 自己发 @setprof allow=0，这一发由 PC 侧做；这里只留位置)"
    echo "--- 判据④：它自己有没有留下驱动 fd(CLOEXEC 应当已经关掉) ---"
    /data/local/tmp/ksuctl86 su "$U" "$BIN/su -c 'ls -l /proc/self/fd | grep -c ksu_driver'"
    echo "  (期望 0)"
    echo "--- 撤销办法(窗口内) ---"
    echo "  rm -f $BIN/su   # 静态文件本身在 /data 上，重启不会自己消失 ⇒ 收尾必须删"
} >"$L" 2>&1
chmod 666 "$L"
