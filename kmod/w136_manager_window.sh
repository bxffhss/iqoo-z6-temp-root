#!/bin/bash
# w136_manager_window.sh —— 活窗口内实测"哪一份 Manager APK 会被我们 ko 加冕"，以及官方 Manager
# 对着我们这份**晚加载、没有真 ksud** 的 ko 会把模块页报成什么。
#
# 为什么值得单独开一发：
#   1) 我们 ko 里硬编码了两个期望证书哈希(官方 c371061b… / 我们 suw 的 11c42292…)，据此推断
#      "认 Manager 是按 APK 签名块的证书哈希，不是按包名"。这**只是推断**，没在设备上钉死过。
#   2) 酷安分享包那份 `KernelSU_v3.0.0-30-legacy_32334-release.apk` 是 Rissu/Shirayuki **重签**的
#      (证书 f415f4ed…，不在期望列表) ⇒ 预期它**不会**被加冕。它真不被加冕 = 上面那条推断被一手证据钉住；
#      它居然被加冕 = 我对授权模型边界的理解是错的，得重估。两种结果都有价值。
#   3) 官方 v3.3.0 会被加冕(窗口 70 已用过)，但**模块页**报什么没测过：模块是 ksud 干的活，
#      我们机器上没有真 ksud ⇒ 这格决定"要不要为 legacy 重编 ko 加第三个哈希槽"。
#
# 两份 APK 包名都是 me.weishu.kernelsu ⇒ 不能共存(签名不同会 INSTALL_FAILED_UPDATE_INCOMPATIBLE)，
# 所以是"先后"，不是"并行"。
#
# 用法：I_KNOW=1 bash kmod/w136_manager_window.sh
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(这一发会 punch，且会装/卸 APK)"; exit 2; }
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }
EV=kmod/w103_evidence; mkdir -p "$EV"
LEG=$(cygpath -w "C:/Users/Administrator/Downloads/z5dl/x/z5_share/files/KernelSU_v3.0.0-30-legacy_32334-release.apk" 2>/dev/null || echo "C:\Users\Administrator\Downloads\z5dl\x\z5_share\files\KernelSU_v3.0.0-30-legacy_32334-release.apk")
OFF=$(cygpath -w suw_apk/backup_official_kernelsu_v3.3.0.apk 2>/dev/null || echo suw_apk/backup_official_kernelsu_v3.3.0.apk)
PKG=me.weishu.kernelsu
WLEG="C:/Users/Administrator/Downloads/z5dl/x/z5_share/files/KernelSU_v3.0.0-30-legacy_32334-release.apk"
[ -f "$WLEG" ] || { echo "[x] 找不到 legacy APK: $WLEG"; exit 2; }
[ -f "suw_apk/backup_official_kernelsu_v3.3.0.apk" ] || { echo "[x] 找不到官方 APK"; exit 2; }

shot() {   # shot <名字>：截屏存证并回显文件路径
    MSYS_NO_PATHCONV=1 adb exec-out screencap -p > "$EV/w27_$1.png" 2>/dev/null
    echo "    截图 $EV/w27_$1.png ($(stat -c %s "$EV/w27_$1.png" 2>/dev/null) 字节)"
}
crown() {  # crown <标签>：把"谁被加冕"的四条独立读数一次取回
    echo "  --- $1 ---"
    A "dmesg | grep -aE 'Crowning manager|Found new base.apk|Search manager|packages.list detected' | tail -8" | cut -c1-150 | sed 's/^/    /'
    A "grep -a \"^$PKG \" /data/system/packages.list | cut -d' ' -f1,2" | sed 's/^/    packages.list: /'
    A "pidof $PKG" | sed 's/^/    pidof: /'
}
try_install() {   # try_install <本地路径> <设备文件名>：先 root 侧 pm install，再退回 adb install+点弹窗
    MSYS_NO_PATHCONV=1 adb push "$1" "/data/local/tmp/$2" 2>&1 | tail -1 | sed 's/^/      push: /'
    A "ls -l /data/local/tmp/$2" | sed 's/^/      设备上: /'
    echo "    走 root 侧 pm install(shell 域)…"
    A "runcon u:r:shell:s0 pm install -r -t /data/local/tmp/$2" | tail -2 | sed 's/^/      /'
    if A "pm list packages $PKG" | grep -q "$PKG"; then echo "      已装 ✓"; return 0; fi
    echo "    root 侧没装上的兜底：adb install + 点掉 vivo 弹窗"
    A "input keyevent 224; svc power stayon true" >/dev/null
    ( for i in $(seq 1 40); do
        sleep 3
        A "pm list packages $PKG" | grep -q "$PKG" && { echo "      第 $i 轮：装上了"; break; }
        A "input tap 540 1962"; sleep 1; A "input tap 540 2109"
      done ) &
    MSYS_NO_PATHCONV=1 adb install -r -t "$1" 2>&1 | tail -2 | sed 's/^/      /'
    wait
    A "pm list packages $PKG" | grep -q "$PKG" && echo "      已装 ✓" || echo "      !! 还是没装上"
}

echo "=== 1) reboot → push → punch → 等本 boot 的 stage ==="
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/dmesg2.log /data/local/tmp/w136_*.out" >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch 2>&1 | grep -aE "slide=|dispatched|pr=" | tail -3 | sed 's/^/  /'
for i in $(seq 1 220); do
    sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到了判据④ (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 别往下做"; exit 5; }
A "grep -aE 'insmod rc|桩已写回|enforce 判读' /data/local/tmp/ksu_stage.log | cut -c1-120 | tail -4" | sed 's/^/  /'

echo "=== 2) 基线：ko 刚加载完，Manager 名单里现在有谁 ==="
A "echo mod=\$(grep -c kernelsu /proc/modules) enforce=\$(getenforce)" | sed 's/^/  /'
A "dmesg | grep -aE 'Crowning manager|Found new base.apk|Search manager|packages.list detected' | tail -10" | cut -c1-150 | sed 's/^/  /'
A "pm list packages $PKG; echo -n 'suw 在不在: '; pm list packages com.suw.manager" | sed 's/^/  /'

echo "=== 3) 先卸掉 suw.manager(它是我们自己加冕的，留着会抢 ksu_manager_appid 这个单值) ==="
A "pm uninstall com.suw.manager" | tail -1 | sed 's/^/  /'
A "dmesg | grep -aE 'Crowning|Search manager|manager_appid' | tail -4" | cut -c1-150 | sed 's/^/  /'

echo "=== 4) 装【legacy / Rissu 重签那份】⇒ 预期**不被加冕** ==="
try_install "$LEG" ksu_legacy.apk
crown "legacy 装完之后"
A "am start -n $PKG/.ui.MainActivity" | head -2 | sed 's/^/  /'
sleep 8; shot legacy_main
A "dmesg | grep -aE 'Crowning manager|is_manager' | tail -6" | cut -c1-150 | sed 's/^/  /'
echo "  ★判据：这份的证书哈希 f415f4ed… 不在 ko 的期望列表 ⇒ 期望 UI 显示'未安装/不支持'且 dmesg 无 Crowning 行"

echo "=== 5) 换成【官方 v3.3.0】⇒ 预期被加冕，并看模块页报什么 ==="
A "pm uninstall $PKG" | tail -1 | sed 's/^/  /'
try_install "$OFF" ksu_official.apk
crown "官方装完之后"
A "am start -n $PKG/.ui.MainActivity" | head -2 | sed 's/^/  /'
sleep 10; shot official_main
echo "  打开'模块'页(底部第三个 tab，实测坐标 540,2290 附近)："
A "input tap 405 2290"; sleep 6; shot official_modules
A "input tap 405 2290"; sleep 4; shot official_modules2
echo "  超级用户页："
A "input tap 270 2290"; sleep 5; shot official_su

echo "=== 6) 收尾取证 ==="
A "dmesg | grep -aE 'Crowning manager|Found new base.apk|packages.list detected|is_manager' | tail -20" > "$EV/w27_crown_dmesg.txt" 2>&1
A "cat /proc/modules | grep -a kernelsu; echo; grep -a \"^$PKG \" /data/system/packages.list" > "$EV/w27_state.txt" 2>&1
wc -l "$EV/w27_crown_dmesg.txt" "$EV/w27_state.txt" 2>/dev/null | sed 's/^/  /'
ls -la "$EV" | grep -a w27 | awk '{print "  ",$5,$9}'
echo "=== 完(设备留着窗口状态，看完截图再 reboot) ==="
