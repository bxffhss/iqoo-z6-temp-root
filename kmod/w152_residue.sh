#!/system/bin/sh
# w152_residue.sh —— 合并验收(ATT=26)的**收尾回读**：把"这台机上还有没有我们的东西"用
# **root 侧同一上下文**读一遍。
#
# ★为什么必须 root 侧读：`adb shell`(uid 2000/shell 域)对 `/data/adb`、`/metadata/watchdog/ksu`
#   的 `ls -d` 在**存在与不存在两种情况下都回 `Permission denied`**(父目录不让它遍历过去)，
#   那句完全不带信息量 ⇒ 拿它判"没删干净"是假阴性(§6.130 一手)。
# ★输出用**块级**重定向：脚本级 `exec >L` 之后再 `cat L` 会自我喂入(§6.132⑤ 把两边磁盘写满)。
L=/data/local/tmp/w152_residue.out
{
    echo "===== RESIDUE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ====="
    echo "--- [1] 系统目录(root 侧口径，这才是带信息量的读数) ---"
    for d in /data/adb /data/adb/ksu /data/adb/lspd /metadata/watchdog/ksu /metadata/ksu /data/local/tmp/pbin; do
        printf '%-28s %s\n' "$d" "$(ls -d "$d" 2>&1 | head -1)"
    done
    echo "--- [2] 我们的投放物(应当为空) ---"
    ls /data/local/tmp/domprint /data/local/tmp/sustatic /data/local/tmp/ksuctl87 /data/local/tmp/w1[3-5]* 2>&1 | head -8
    echo "--- [3] 挂载点现状 ---"
    echo "pbin 挂载行=$(grep -ac pbin /proc/self/mountinfo)  /product/bin/su=$(ls /product/bin/su 2>&1 | head -1)"
    echo "/product/bin 条目数=$(ls -A /product/bin 2>/dev/null | wc -l) (出厂应是 3)"
    echo "--- [4] 内核与模块 ---"
    grep -a kernelsu /proc/modules | cut -c1-60
    echo "stage 日志=$(ls -l /data/local/tmp/ksu_stage.log 2>&1 | cut -c1-60)"
    echo "--- [5] 框架健康(shell 域口径) ---"
    runcon u:r:shell:s0 service list 2>/dev/null | head -1
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
