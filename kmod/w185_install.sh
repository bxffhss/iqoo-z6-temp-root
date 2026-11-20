#!/system/bin/sh
# w185_install.sh —— 从 **root 侧**装 APK(绕开 vivo 给 shell 弹的那个全屏装机闸)，并带回执。
#   为什么试这条：`adb install` 在这台机上会被 `INSTALL_FAILED_ABORTED: User rejected permissions` 挡
#   (第一百一十九发一手)，而 suw 的小弹窗坐标对官方那个全屏页不通用(要先勾"已了解风险")；
#   但这一发窗口里我们有 uid 0 + 域 kernel 的通道 ⇒ `pm install` 由 root 发起来通常不弹闸。
L=/data/local/tmp/w185_install.out
exec >>"$L" 2>&1
APK=$(head -1 /data/local/tmp/w185_want.txt 2>/dev/null | tr -d '\r')
echo "=== w185_install up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
echo "apk=[$APK]"
ls -l "$APK" 2>&1
echo "--- 装之前的第三方包数: $(runcon u:r:shell:s0 pm list packages -3 2>&1 | wc -l) ---"
# ★第一百一十九发一手：root + 域 `kernel` 里 `pm` 直接 `Can't find service: package`
#   (vivo 对非 shell 域隐藏服务列表，与 §6.124⑦ 那条 `service list` 得到 0 个服务是同一件事)
#   ⇒ 要碰框架服务就得 `runcon u:r:shell:s0`；这里两种都试，回执分开印，才知道是哪一层的闸。
echo "[1] runcon u:r:shell:s0 pm install -r -t:"
runcon u:r:shell:s0 pm install -r -t "$APK" 2>&1
echo "    rc=$?"
echo "[2] 直接 pm install(不带 runcon):"
pm install -r -t "$APK" 2>&1
echo "    rc=$?"
echo "--- 装之后: 第三方包数=$(runcon u:r:shell:s0 pm list packages -3 2>&1 | wc -l) ---"
runcon u:r:shell:s0 pm list packages -3 -U 2>&1 | tail -6
echo "===== DONE ====="
