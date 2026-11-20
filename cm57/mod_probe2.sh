#!/system/bin/sh
# mod_probe2.sh — 外部 .ko 准入判定(第二版, 靶子改好后)
# 四个判据互相咬合:
#   P1 原样厂商模块 e4000  → 门是否开放(有没有自建 LKM 白名单)
#   P2 卸载                 → 生命周期完整(证明真进了 module 数组而非半途失败)
#   P3 只把 module_layout 的 CRC 改 1 字节 → MODVERSIONS 是否真的强制
#   P4 只把 i2c_del_driver 的 CRC 改 1 字节 → 同上, 且应当**点名那个符号**
#   P5 截断的 .ko          → 格式阶段负对照(预期 ENOEXEC)
# 靶子为什么选 e4000: 它是 I2C 调谐器驱动, 本机没有该硬件 ⇒ init 只是 i2c_register_driver,
# 无匹配设备, 零副作用; 且它的 22 条 __versions 与离线表逐条吻合(全依赖都在 vmlinux 里)。
L=/data/local/tmp/mod_probe.log
D=/data/local/tmp
rm -f $L $D/dm_prev.txt $D/dm_cur.txt $D/trunc.ko
exec >> $L 2>&1
echo "=== mod_probe2 开始 uptime=$(cat /proc/uptime) ==="
id
echo "getenforce=$(getenforce)"
grep -E 'CapEff|Se:' /proc/self/status

b(){ dmesg > $D/dm_prev.txt 2>&1; wc -l < $D/dm_prev.txt; }
delta(){ dmesg > $D/dm_cur.txt 2>&1; tail -n +$(( $(wc -l < $D/dm_prev.txt) + 1 )) $D/dm_cur.txt; cp $D/dm_cur.txt $D/dm_prev.txt; }

echo "--- 0) 三个靶子的 .modinfo ---"
for f in t_e4000 t_e4000_bad t_e4000_bad2; do echo "### $f.ko"; $D/mod info $D/$f.ko; done

echo "--- 1) 基线 ---"
echo "/proc/modules 行数=$(wc -l < /proc/modules)"
ls -d /sys/module/e4000 2>&1
b
echo "--- 2) P1 原样加载 ---"
$D/mod ins $D/t_e4000.ko
echo "rc1=$?"
echo "[dmesg]"; delta
$D/mod state e4000
grep '^e4000 ' /proc/modules
echo "--- 3) P2 卸载 ---"
$D/mod rm e4000
echo "rc2=$?"
echo "[dmesg]"; delta
ls -d /sys/module/e4000 2>&1
echo "--- 4) P3 module_layout 的 CRC 被改 1 字节(预期被拒) ---"
$D/mod ins $D/t_e4000_bad.ko
echo "rc3=$?"
echo "[dmesg]"; delta
$D/mod rm e4000 2>&1
echo "--- 5) P4 i2c_del_driver 的 CRC 被改 1 字节(预期被拒并点名符号) ---"
$D/mod ins $D/t_e4000_bad2.ko
echo "rc4=$?"
echo "[dmesg]"; delta
$D/mod rm e4000 2>&1
echo "--- 6) P5 截断负对照(预期 ENOEXEC) ---"
head -c 4096 $D/t_e4000.ko > $D/trunc.ko
$D/mod ins $D/trunc.ko
echo "rc5=$?"
echo "[dmesg]"; delta
echo "--- 7) 收尾登记 ---"
echo "e4000 残留=$(grep -c '^e4000 ' /proc/modules) /proc/modules 行数=$(wc -l < /proc/modules)"
ls -d /sys/module/e4000 2>&1
echo "uptime=$(cat /proc/uptime) getenforce=$(getenforce)"
echo "=== mod_probe2 结束 ==="
sync
