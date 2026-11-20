#!/system/bin/sh
# w205_recon.sh — 只读侦察：模块 customize.sh 的 arch 选择逻辑 + zygiskd 接口 + 现状
OUT=/data/local/tmp/w205_recon.out
exec >"$OUT" 2>&1
M=/data/adb/modules
echo "=== [1] zygisksu/customize.sh ==="
cat "$M/zygisksu/customize.sh"
echo "=== [2] zygisksu/verify.sh ==="
cat "$M/zygisksu/verify.sh"
echo "=== [3] zygisksu/action.sh ==="
cat "$M/zygisksu/action.sh"
echo "=== [4] zygisksu/cleanup.sh ==="
cat "$M/zygisksu/cleanup.sh"
echo "=== [5] zygisksu/emulated-soft-reboot.sh ==="
cat "$M/zygisksu/emulated-soft-reboot.sh"
echo "=== [6] zygisksu/sepolicy.rule ==="
cat "$M/zygisksu/sepolicy.rule"
echo "=== [7] zygisk_lsposed/customize.sh ==="
cat "$M/zygisk_lsposed/customize.sh"
echo "=== [8] zygisk_lsposed/zn_modules.txt ==="
cat "$M/zygisk_lsposed/zn_modules.txt"
echo "=== [9] zygisk_lsposed/sepolicy.rule ==="
cat "$M/zygisk_lsposed/sepolicy.rule"
echo "=== [10] zygisksu/bin/ layout (top-level zygiskd?) ==="
ls -la "$M/zygisksu/bin/"
echo "=== [11] /data/adb/zygisksu state ==="
ls -la /data/adb/zygisksu/ 2>&1
echo "=== [12] zygiskd no-arg (help) ==="
timeout 6 "$M/zygisksu/bin/arm64-v8a/zygiskd" 2>&1; echo "RC=$?"
echo "=== [13] zygiskd status (timeout guarded) ==="
timeout 6 "$M/zygisksu/bin/arm64-v8a/zygiskd" status 2>&1; echo "RC=$?"
echo "=== [14] ko zygisk capability (kallsyms, best-effort) ==="
grep -ai 'zygisk\|ksu.*zygote\|ksu_zygisk' /proc/kallsyms 2>/dev/null | head -20
echo "KSYM_RC=$?"
echo "=== [15] current zygote / SElinux / ko ==="
cat /proc/sys/kernel/random/boot_id
echo "zygote64=$(pidof zygote64) zygote=$(pidof zygote) system_server=$(pidof system_server)"
cat /sys/fs/selinux/enforce
grep -c kernelsu /proc/modules
echo "===== DONE"
