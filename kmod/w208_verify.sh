#!/system/bin/sh
# w208_verify.sh — 定位 ZygiskNext verify1 到底校验什么（只读为主）
OUT=/data/local/tmp/w208_verify.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu

echo "########## [1] abort msg + magic + machikado ##########"
echo "--- .abort_msg ---"; cat /data/adb/zygisksu/.abort_msg 2>&1; echo
echo "--- .magic ---"; cat /data/adb/zygisksu/.magic 2>&1; echo
echo "--- current machikado (od) ---"; od -An -tx1 "$ZN/machikado" 2>&1 | head -8
echo "--- all machikado.* md5 ---"
for f in "$ZN"/machikado.*; do echo "$f  $(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"; done

echo "########## [2] arch props (决定 MARCH=arm64 还是 arm64_32) ##########"
echo "ro.product.cpu.abilist=$(getprop ro.product.cpu.abilist)"
echo "ro.product.cpu.abilist32=[$(getprop ro.product.cpu.abilist32)]"
echo "ro.product.cpu.abilist64=[$(getprop ro.product.cpu.abilist64)]"
echo "ro.system.product.cpu.abilist32=[$(getprop ro.system.product.cpu.abilist32)]"

echo "########## [3] strings in zygiskd64 (verify machinery) ##########"
grep -aoE '[[:print:]]{5,}' "$ZN/bin/zygiskd64" 2>/dev/null | grep -aiE 'verify|machikado|sha256|lib64|lib/|libzygisk|zn_loader|payload|corrupt|\.so|module.prop|mazoku|inject|tango|auto_umount' | sort -u | head -100

echo "########## [4] all .sha256 files and their verification ##########"
echo "--- sha256 files present ---"
find "$ZN" -name '*.sha256' 2>/dev/null | sort
echo "--- verify each (sha256sum -c) ---"
cd "$ZN" || exit 1
FAIL=0; OK=0
for h in $(find . -name '*.sha256' 2>/dev/null); do
  tgt="${h%.sha256}"
  if [ -f "$tgt" ]; then
    exp=$(cat "$h" 2>/dev/null | awk '{print $1}')
    got=$(sha256sum "$tgt" 2>/dev/null | awk '{print $1}')
    if [ "$exp" = "$got" ]; then OK=$((OK+1)); else echo "MISMATCH $tgt exp=$exp got=$got"; FAIL=$((FAIL+1)); fi
  else
    echo "NO_TARGET for $h"; FAIL=$((FAIL+1))
  fi
done
echo "SHA256_OK=$OK SHA256_FAIL=$FAIL"

echo "########## [5] verify1-related: files the daemon opens (from binary strings) ##########"
grep -aoE '[[:print:]]{4,}' "$ZN/bin/zygiskd64" 2>/dev/null | grep -aE '^/?(lib|bin|data|system|dev)/|\.prop$|\.pb$|\.txt$|\.rule$|^\.|/data/adb' | sort -u | head -120

echo "########## [6] what a real install would leave: compare with customize.sh expectations ##########"
echo "--- top-level of module dir now ---"
ls -la "$ZN/"
echo "--- module.prop.orig ---"; ls -la "$ZN/module.prop.orig" 2>&1

echo "########## [7] ksud availability (proper module install path) ##########"
ls -la /data/adb/ksud /data/adb/ksu/bin/ksud 2>&1
echo "--- ksud version/help ---"
timeout 8 /data/adb/ksud --version 2>&1; echo "KSUD_V_RC=$?"
timeout 8 /data/adb/ksud module --help 2>&1 | head -40; echo "KSUD_MOD_RC=$?"
echo "===== DONE"
