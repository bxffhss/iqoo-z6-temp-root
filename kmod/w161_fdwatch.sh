#!/system/bin/sh
# w161_fdwatch.sh —— root 侧"装 fd 看门狗"。
#   为什么要有它(一手事实，上一发的 ksu_stage.log + dmesg.live)：stage 在 up=511 对
#   pid=14763 写了 /proc/ksu_install_fd，内核只打了"已排队…等它回到用户态"，
#   **整份 dmesg.live 里没有那个 pid 的回调行** ⇒ fd 从没真装进 Manager ⇒ 首页"版本 -1"。
#   task_work 只在目标**回到用户态**时跑(后台被 cgroup freezer 冻住就永远不跑，§6.82②)，
#   而且排队那一刻的 pid 可能已经换了进程 ⇒ 只能"看到新 pid 就立刻再排一次"。
# ★自己写 pid 文件，**不要**让外面用 pgrep -f 找我：
#   实测 `pgrep -f w161_fdwatch.sh` 会把"命令行里带这个字符串的那个 shell"也匹配上 ⇒
#   拿它当 kill 目标有朝 root 通道自己开枪的风险(本机 mksh 会带整条命令行)。
L=/data/local/tmp/w161_fdwatch.log
PIDF=/data/local/tmp/w161_fdwatch.pid
echo $$ > "$PIDF"
chmod 666 "$PIDF" "$L" 2>/dev/null
LAST=""
i=0
while [ "$i" -lt 400 ]; do
    i=$((i + 1))
    P=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    case "$P" in '' | *[!0-9]*) P="" ;; esac
    if [ -n "$P" ] && [ "$P" != "$LAST" ]; then
        U=$(cut -d' ' -f1 /proc/uptime)
        if echo "$P" > /proc/ksu_install_fd 2>>"$L"; then
            echo "$U 已排队 pid=$P" >> "$L"
        else
            echo "$U 写触发口失败 pid=$P" >> "$L"
        fi
        LAST="$P"
    fi
    sleep 0.4
done
echo "FDW-END samples=$i last=$LAST" >> "$L"
chmod 666 "$L"
