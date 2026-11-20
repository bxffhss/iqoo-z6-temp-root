#!/bin/bash
# w137_official_mgr_window.sh —— 修正第 27 发的排序错误：**Manager 必须在 punch(insmod) 之前装好**。
#
# 第 27 发钉出的一手事实：`ksu_manager_appid` 是 insmod 那一刻扫 packages.list 定下的**单值**，
# 之后不刷新(证据：重装 suw.manager 后 uid 10319→u0_a344，@sushd 通道没恢复、回执文件根本没生成)。
# ⇒ 装完 APK 再 insmod 才可能被加冕。
#
# 这一发要答的唯一问题：**官方 Manager 被正常加冕之后，"模块"页对着我们这份晚加载、
#   没有真 ksud 的 ko 会报什么？** 它决定"要不要为模块功能开一条新战线(引 ksud)"。
#
# 代价(诚实写明)：为了让官方那份是唯一候选，punch 之前会**卸掉 com.suw.manager**
#   ⇒ 这个窗口没有 root 侧脚本通道(@sushd:)。判据全在 Manager 自己的 UI 上，不需要它。
#   顺带：模块 zip 先推到 /sdcard/Download，方便在页面上直接选。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch)"; exit 2; }
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }
EV=kmod/w103_evidence; mkdir -p "$EV"
OFFW=$(cygpath -w suw_apk/backup_official_kernelsu_v3.3.0.apk 2>/dev/null || echo suw_apk/backup_official_kernelsu_v3.3.0.apk)
MODW=$(cygpath -w "C:/Users/Administrator/Downloads/z5dl/x/z5_share/files/LSPosed-2.2.0.zip" 2>/dev/null || echo "")
PKG=me.weishu.kernelsu
shot() { MSYS_NO_PATHCONV=1 adb exec-out screencap -p > "$EV/w28_$1.png" 2>/dev/null
         echo "    截图 w28_$1.png ($(stat -c %s "$EV/w28_$1.png" 2>/dev/null) 字节)"; }
install_gate() {   # install_gate <本地路径>：adb install + 点掉 vivo 弹窗(整行中心，不是左侧方框)
    ( for i in $(seq 1 30); do sleep 3
        A "pm list packages $PKG" | grep -q "$PKG" && { echo "      第 $i 轮：装上了"; break; }
        A "input tap 540 1962"; sleep 1; A "input tap 540 2109"
      done ) &
    MSYS_NO_PATHCONV=1 adb install -r -t "$1" 2>&1 | tail -2 | sed 's/^/      /'
    wait
}

echo "=== 1) 先把包状态摆正：卸 suw.manager、装官方 v3.3.0(全都在 punch 之前) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
A "echo boot 完成: up=$(cat /proc/uptime) enforce=$(getenforce)" | sed 's/^/  /'
A "pm uninstall com.suw.manager" | tail -1 | sed 's/^/  卸 suw: /'
A "input keyevent 224; svc power stayon true" >/dev/null
A "pm uninstall $PKG" >/dev/null
install_gate "$OFFW"
A "pm list packages $PKG" | sed 's/^/  已装: /'
A "pm list packages com.suw.manager" | sed 's/^/  suw 现在: /'
[ -n "$MODW" ] && { MSYS_NO_PATHCONV=1 adb push "$MODW" /sdcard/Download/LSPosed-2.2.0.zip >/dev/null 2>&1 && echo "  模块 zip 已推到 /sdcard/Download"; }

echo "=== 2) push ko → reboot → punch → 等本 boot 的 stage ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/dmesg2.log" >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch 2>&1 | grep -aE "slide=|dispatched|pr=" | tail -3 | sed 's/^/  /'
for i in $(seq 1 220); do
    sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到了判据④ (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 这一发做不了"; exit 5; }
A "grep -aE 'insmod rc|官方 Manager pid|已写 /proc/ksu_install_fd|触发口' /data/local/tmp/ksu_stage.log | cut -c1-140 | tail -8" | sed 's/^/  /'

echo "=== 3) 加冕判据①：stage 有没有把这个 Manager 的 fd 装进去(它自己印的) ==="
A "dmesg | grep -aE 'Crowning manager|Found new base.apk|install fd for manager|Search manager' | tail -10" | cut -c1-160 | sed 's/^/  /'
A "echo pidof=[$(pidof $PKG)]" | sed 's/^/  /'

echo "=== 4) 加冕判据②(权威)：Manager 自己怎么说 ==="
A "am force-stop $PKG"; sleep 1
A "am start -n $PKG/.ui.MainActivity" | head -1 | sed 's/^/  /'
sleep 12; shot home
echo "  ★期望：首页显示「工作中 / 版本 32653」而不是第 27 发那个「不支持」。"
echo "    若仍是「不支持」⇒ 加冕/取 fd 这一格没成，模块页也就无从判读。"

echo "=== 5) 模块页：这一发真正要的那一格 ==="
A "input tap 405 2290"; sleep 6; shot modules
A "input tap 405 2290"; sleep 4; shot modules_b
echo "  底部四个 tab 的 x 大致是 主页135 / 超级用户270 / 模块405 / 设置675(y≈2290)。"
echo "  若模块页能进去并有「从本地安装」，点它看文件选择器能不能看到 /sdcard/Download/LSPosed-2.2.0.zip："
A "input tap 540 1200"; sleep 8; shot module_install_try

echo "=== 6) 超级用户页(对照：能不能列出并勾选授权) ==="
A "input tap 270 2290"; sleep 6; shot su

echo "=== 7) 收尾取证 ==="
A "dmesg | grep -aE 'Crowning manager|Found new base.apk|install fd for manager|is_manager' | tail -20" > "$EV/w28_crown_dmesg.txt" 2>&1
A "cat /proc/modules | grep -a kernelsu; echo; getenforce; echo; pidof $PKG" > "$EV/w28_state.txt" 2>&1
wc -l "$EV/w28_crown_dmesg.txt" "$EV/w28_state.txt" 2>/dev/null | sed 's/^/  /'
ls -la "$EV" | grep -a w28 | awk '{print "  ",$5,$9}'
echo "=== 完(先看截图再 reboot) ==="
