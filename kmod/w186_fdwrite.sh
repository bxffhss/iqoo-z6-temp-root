#!/system/bin/sh
# w186_fdwrite.sh —— 只做一件事：把 pid 写进 /proc/ksu_install_fd，然后立刻退出(<5s)。
#   ★为什么拆成两条腿(§6.188⑤)：上一发的合并脚本在写完触发口之后**第一格循环就没再出声**、进程随后消失，
#     死因没定位。拆开就能分：写腿死了是"写这条路径对写者有影响"，读腿死了是"读别人的 /proc 有问题"，
#     两条都活着而只是单脚本跑太久，那就是通道对长任务有监督超时。
L=/data/local/tmp/w186_fdwrite.out
exec >>"$L" 2>&1
PKG=$(head -1 /data/local/tmp/w186_want.txt 2>/dev/null | tr -d ' \r\n')
echo "=== w186_fdwrite up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) pkg=[$PKG] ==="
if [ ! -e /proc/ksu_install_fd ]; then
    echo "[x] /proc/ksu_install_fd 不在 ⇒ 模块没加载或这不是 rc36+"; echo "===== DONE ====="; exit 0
fi
# ★先 pidof(一次 syscall)，扫 /proc 只当兜底：今晚两条 root 腿都死在"扫 /proc/*/cmdline"那一段(§6.193⑤)
MP=$(pidof "$PKG" 2>/dev/null | cut -d' ' -f1)
if [ -z "$MP" ]; then
    for d in /proc/[0-9]*; do
        grep -qaF "$PKG" "$d/cmdline" 2>/dev/null && { MP=${d#/proc/}; break; }
    done
    echo "(pidof 空，走 cmdline 兜底)"
fi
echo "目标 pid=[$MP] 在否=$([ -n "$MP" ] && ls -d /proc/$MP >/dev/null 2>&1 && echo Y || echo N)"
if [ -z "$MP" ]; then echo "[x] 没有那个进程 ⇒ 别写(空串写进去会把账弄脏)"; echo "===== DONE ====="; exit 0; fi
echo "写之前它 fd 数=$(ls -1 /proc/$MP/fd 2>/dev/null | wc -l) 含 ksu_driver 的行=$(ls -l /proc/$MP/fd 2>/dev/null | grep -ac ksu_driver)"
echo "$MP" > /proc/ksu_install_fd
echo "写下去 rc=$?"
echo "写完还活着(自证这一腿没被打断) up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)"
echo "===== DONE ====="
