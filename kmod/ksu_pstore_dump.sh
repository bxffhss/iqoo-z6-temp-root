#!/system/bin/sh
# ksu_pstore_dump.sh —— 只做一件事：把**上一 boot 崩溃现场**从 pstore 里捞出来落成 666 文件。
# 为什么可能捞得到(一手 config，`analysis/config_dev.txt`)：
#   CONFIG_PSTORE=y / CONFIG_PSTORE_CONSOLE=y / CONFIG_PSTORE_RAM=y
# ⇒ 内核把**所有 console 输出**镜像进 RAM 保留区，重启后由 pstore 暴露成文件。
# 上一发(2026-09-30 17:25)窗口脚本卡在 "=== 2. insmod ===" 之后没有任何输出，设备随后重启
# —— 那次是我自己的 `dmesg -c` 把 insmod 之前该留的日志清掉了(判据设计错误，已记 §6.26)。
# 这一发**不碰任何危险动作**(不 insmod)，只读，所以就算读一半挂了也不丢原始证据。
OUT=/data/local/tmp/ksu_pstore.log
D=/data/local/tmp/pstore
exec > "$OUT" 2>&1
echo "=== 起点 ==="
date
id
uname -a
echo "--- 这个 boot 的 uptime(判断是不是又重启过):"; cat /proc/uptime
echo "--- boot_id(与 punch 时那个比，不同=换过 boot):"; cat /proc/sys/kernel/random/boot_id

echo; echo "=== 1. pstore 里有什么 ==="
ls -l /sys/fs/pstore/
mkdir -p "$D"
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    n=$(basename "$f")
    cp "$f" "$D/$n" 2>&1
    echo "  拷出 $n: $(wc -c < "$D/$n" 2>/dev/null) 字节"
done
chmod -R 777 "$D" 2>/dev/null
echo "--- ★注意：pstore 的记录被读过之后可能被内核抹掉 ⇒ 一律先 cp 再分析，别直接 grep 原文件。"

echo; echo "=== 2. 上一 boot 的 console 日志里，崩溃前后这些行(直接印在日志里方便一次读全) ==="
for n in console-ramoops-0 dmesg-ramoops-0 dmesg-ramoops-1; do
    [ -e "$D/$n" ] || continue
    echo "########## $n ##########"
    # ramoops 头部可能有若干 \0 填充 ⇒ 用 tr 处理
    head -c 200000 "$D/$n" | tr -d '\000' | tail -320
done

echo; echo "=== 3. 只挑关键证据(若有) ==="
cat "$D"/* 2>/dev/null | tr -d '\000' | grep -inE 'unknown symbol|disagrees|Kernel panic|Oops|BUG:|BUG |internal error|Call trace|CFI|undefined instruction|page fault|Unable to handle|kernelsu|ksu:|dev_syms|apfmt|allowlist|tp_marker|hook_manager|lsm_hook|patch|slab|corrupt' | tail -120

echo; echo "=== 4. 顺手量的东西(为下一发做准备) ==="
echo "--- printk 各级(下一发 insmod 前必须把 console 级别抬到 8，否则 pr_info 进不了 pstore):"
cat /proc/sys/kernel/printk
echo "--- 这个 boot 的 dmesg 行数(对照用):"; dmesg | wc -l
echo "=== 完成 ==="
chmod 666 "$OUT" 2>/dev/null
ls -l "$OUT"
