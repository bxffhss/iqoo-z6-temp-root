#!/system/bin/sh
# w130_verify_su.sh —— 验收"静态 su + root agent 转交驱动 fd"这条链（md §6.123③）
#   形状对齐 Termux 里手敲 su：以 **uid 10667** 起进程 + **PATH 指向 Termux 自己的 bin** +
#   用 `asuid`(它走 execvp ⇒ 真的做 PATH 查找) 去执行 `su`。
#   （Termux 侧"能不能找到并执行 su"已经由屏幕实拍证明：`su: agent 拒绝: ERR not-allowed`
#     ⇒ 文件找到了、也跑起来了，卡在 agent 放行；所以这里只需要验放行修好之后整条链。）
L=/data/local/tmp/w130.out
export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "--- 先清掉多余的 agent(它 unix 监听是 off，但留着容易看混) ---"
    for p in $(pidof shd); do
        U=$(awk '/^Uid/{print $2}' /proc/$p/status 2>/dev/null)
        echo "  shd pid=$p uid=$U"
    done
    echo "--- 名单现状(内核自己列) ---"
    /data/local/tmp/ksuctl86 list 2>&1 | head -6
    echo "--- 判据①：uid 10667 经 PATH 找到 su 并跑通 ⇒ 期望 uid=0(root) ---"
    /data/local/tmp/asuid 10667 10667 su -c 'id; echo "ctx=$(cat /proc/self/attr/current)"; echo "驱动fd计数=$(ls -l /proc/self/fd 2>/dev/null | grep -c ksu_driver)"'
    echo "  rc=$?"
    echo "--- 判据②：负对照——撤名单后同一个 uid 必须失败(下一步在 PC 侧做) ---"
} >"$L" 2>&1
chmod 666 "$L"
