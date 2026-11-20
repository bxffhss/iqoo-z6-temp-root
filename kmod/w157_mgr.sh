#!/system/bin/sh
# w157_mgr.sh —— root 侧问 ko："王座现在坐着的是哪个 appid?"(`ksuctl mgr`，§6.74 的读法)。
# ★写成仓库里的真文件再 push：Git Bash 的 /tmp 对 adb.exe 不是同一个路径，
#   而 MSYS_NO_PATHCONV=1 又禁掉了自动转换(=[[env-shell-gotchas]] 那条"重写远端路径并谎报成功")。
L=/data/local/tmp/w157_mgr.out
{
    echo "=== MGR up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
    for c in /data/local/tmp/ksuctl87 /data/local/tmp/ksuctl; do
        if [ -x "$c" ]; then
            echo "用 $c:"
            "$c" mgr 2>&1 | cut -c1-160
            break
        fi
        echo "  (没有可执行的 $c)"
    done
    echo "=== DONE ==="
} >"$L" 2>&1
chmod 666 "$L"
