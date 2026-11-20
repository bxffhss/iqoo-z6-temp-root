#!/system/bin/sh
# 投递 B：★核心一问 —— post-fs-data 跑**第二遍**会不会真的挂模块。
#   第 37 发一手：第一遍只做了"合并 modules_update + apply sepolicy"，mountinfo 里 0 行。
#   两种假设在这里分开：① 时机(update 标记/第一遍只算安装) ② 挂载进了别的 mount namespace。
L=/data/local/tmp/w143b.out
K=/data/local/tmp/ksud_official
MC() { grep -ac modules /proc/self/mountinfo; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
echo "MNT_NS(本脚本)=$(readlink /proc/self/ns/mnt)"
echo "BEFORE: update标记=$([ -e /data/adb/modules/zygisk_lsposed/update ] && echo 有 || echo 无)  modules行数=$(MC)"
echo "--- 第 1 遍 post-fs-data ---"
timeout 40 $K post-fs-data >/data/local/tmp/w143b_p1.txt 2>&1; echo "  rc=$?  尾部: $(tail -3 /data/local/tmp/w143b_p1.txt | tr '\n' ' ' | cut -c1-160)"
echo "  AFTER#1: update标记=$([ -e /data/adb/modules/zygisk_lsposed/update ] && echo 有 || echo 无)  modules行数=$(MC)"
echo "--- ★第 2 遍 post-fs-data(这一问的关键) ---"
timeout 40 $K post-fs-data >/data/local/tmp/w143b_p2.txt 2>&1; echo "  rc=$?  尾部: $(tail -3 /data/local/tmp/w143b_p2.txt | tr '\n' ' ' | cut -c1-160)"
echo "  AFTER#2: modules行数=$(MC)"
grep -a modules /proc/self/mountinfo | cut -c1-140 | head -8
echo "--- services / boot-completed ---"
timeout 30 $K services >/data/local/tmp/w143b_svc.txt 2>&1; echo "  services rc=$? 尾: $(tail -2 /data/local/tmp/w143b_svc.txt | tr '\n' ' ' | cut -c1-140)"
echo "  AFTER services: modules行数=$(MC)"
timeout 20 $K boot-completed >/data/local/tmp/w143b_bc.txt 2>&1; echo "  boot-completed rc=$?"
echo "--- ksud 自己的子进程在哪个 ns(排②) ---"
for p in $(pidof ksud_official); do echo "  pid=$p ns=$(readlink /proc/$p/ns/mnt 2>&1) cmd=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | cut -c1-60)"; done
echo "  (没有输出=ksud 已经退出，没有常驻)"
echo "框架健康(shell 域): $(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
