#!/bin/bash
# round9_cleanup.sh — 收尾: 删本轮设备端文件 + reboot(恢复 enforcing, 顺带拆掉 /product/bin 覆盖挂载与 daemon)
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
A() { MSYS2_ARG_CONV_EXCL='*' "C:/adb/platform-tools/adb.exe" -s <DEVICE_SERIAL> "$@"; }

# ★ 必须排在最前面, 而且必须趁 root 窗口还活着:
#   /data/adb/su/{su.policy,su.ctrl} 落在**真 /data** 上, 重启不会消失(shell 连 stat 都是 EACCES),
#   而"一切易失"这条只在 tmpfs/daemon/permissive 上成立 ⇒ 不主动删就是永久留痕。
echo "[1/3] 拆控制面与策略文件(需要 root 窗口还活着)"
R=$(A shell '/product/bin/su -c "rm -rf /data/adb/su; echo SU_DIR_GONE" </dev/null' 2>&1 | tr -d '\r')
case "$R" in
  *SU_DIR_GONE*) echo "  已删 /data/adb/su" ;;
  *) echo "  !! 删不掉(su 不可用: $(echo "$R" | head -1))"
     echo "  !! ⇒ /data/adb/su 可能仍留在设备上; 只有下次激活(脚本开头会 rm)或再拿一发窗口才能清" ;;
esac

echo "[2/3] 删设备端本轮文件"
# 本轮新增的产物也要清: bootstrap.sh 起的 shd/shd.log/punch.log, 以及 kmod 阶段的自研模块与加载器。
# perfips 故意留着(它历史上只有设备上一份; 现已在 cm57/perfips 存了副本, 删了 bootstrap 会自己补)。
A shell 'cd /data/local/tmp; rm -f pr pr.log sudbin asuid su_layer_install.sh su_layer.log su.audit sud.log ui_before.png ui_after.png ipk.txt shd shd.log punch.log suwprobe.ko suwkprobe.ko modbin; rm -rf prod_keep; echo "剩余本轮文件:"; ls | grep -E "^(pr$|sudbin|asuid|su_layer|su\.audit|ui_|shd|punch\.log|suwprobe\.ko|suwkprobe\.ko|modbin$)" ; echo "(空=已净)"' 2>&1 | tr -d '\r'
echo "[3/3] reboot 恢复 enforcing"
A reboot; A wait-for-device
for i in $(seq 1 40); do o=$(A shell "getenforce" 2>/dev/null | tr -d '\r'); case "$o" in *Enforcing*|*Permissive*) break;; esac; sleep 5; done
echo "收尾: $o  uptime=$(A shell 'cat /proc/uptime' | tr -d '\r')  挂载残留=$(A shell 'grep -c "product/bin" /proc/mounts' | tr -d '\r')"
