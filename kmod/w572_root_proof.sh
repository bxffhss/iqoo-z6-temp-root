#!/system/bin/sh
# w572_root_proof.sh —— 第 45 发的**分叉取证**载荷：由 app 侧敲 `/system/bin/su -c /data/local/tmp/w572_root_proof.sh`
#   (一个 token，避开 #208 的 `sh -c` 词切法) 执行。所有判据都**落在文件里**，因为 #116 那条"root 写不回 app 终端"
#   会把屏幕上的字藏起来——这一发要分辨的正是"没成功"还是"成功了但看不见"。
OUT=/data/local/tmp/w572_root.out
PROBE=/data/local/tmp/w572_probe
: > "$OUT"
{
    echo "=== W572 起点 ==="
    /system/bin/id
    echo "enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) up=$(cut -d' ' -f1 /proc/uptime)"
    echo "dom=$(cat /proc/self/attr/current | tr -d '\000')"
    echo "ppid=$(cut -d' ' -f4 /proc/self/stat) cmd=$(tr '\0' ' ' < /proc/self/cmdline | cut -c1-90)"
    echo "ls_probe_之前=$(ls -l $PROBE 2>&1)"
    /system/bin/chmod 600 "$PROBE" 2>&1
    echo "chmod_rc=$?"
    echo "ls_probe_之后=$(ls -l $PROBE 2>&1)"
    echo "fd_表里有几个 ksu_driver=$(ls -l /proc/self/fd 2>&1 | grep -c ksu_driver)"
    sync
} >> "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
echo "W572_DONE"
