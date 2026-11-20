#!/system/bin/sh
# w142_clean_adb.sh —— 清掉 ksud 实验在 /data 上留下的**跨重启**痕迹(我们不留持久化)。
L=/data/local/tmp/w142_clean.out
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
echo "--- 清之前 /data/adb ---"; ls -laR /data/adb 2>/dev/null | head -20
rm -rf /data/adb/modules /data/adb/modules_update /data/adb/ksu /data/adb/ksud \
       /data/adb/service.d /data/adb/post-fs-data.d /data/adb/lspd /data/adb/sepolicy.rule 2>/dev/null
echo "RM_RC=$?"
echo "--- 清之后 /data/adb 还剩什么 ---"; ls -la /data/adb 2>&1 | head -10
echo "--- 模块相关挂载(应为 0) ---"; grep -ac modules /proc/self/mountinfo
echo "--- 顺手清掉这一发的实验文件 ---"
rm -f /data/local/tmp/ksud_official /data/local/tmp/w139_ksud_probe.sh /data/local/tmp/w140_ksud_mod.sh /data/local/tmp/w141_postfs.sh
rm -rf /data/adb 2>/dev/null; echo "整个 /data/adb 删掉 rc=$?"
# ★ksud 的 post-fs-data 还会生成 /metadata/watchdog/ksu/modules.rc(给"下一次开机的内核钩子"看)
#   我们这台机器开机时不加载 ko ⇒ 它是惰性的，但同样是实验残留 ⇒ 一并删。
rm -rf /metadata/watchdog/ksu 2>/dev/null; echo "删 /metadata/watchdog/ksu rc=$?"
echo "FINAL /metadata/watchdog: $(ls -d /metadata/watchdog/* 2>&1 | head -3)"
echo "FINAL /data/adb: $(ls -ld /data/adb 2>&1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
