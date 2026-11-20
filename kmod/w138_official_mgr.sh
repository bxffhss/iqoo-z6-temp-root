#!/bin/bash
# w138_official_mgr.sh —— 第 28 发的修正版：**包状态已经手工摆好**(me.weishu.kernelsu 已装、
# com.suw.manager 已卸)，这一发只做"重启 → push → punch → 等 post → 读 Manager 自己的 UI"。
#
# 要答的唯一问题：官方 Manager 被**正常加冕**之后，"模块"页对着我们这份晚加载、没有真 ksud 的
# ko 报什么？它决定要不要为模块功能开"引 ksud"这条新战线。
#
# 修掉的两个第 28 发的错：
#   ① 引号 bug：`A "echo $(getenforce)"` 双引号 ⇒ 被 Git Bash 在**本机**展开(日志里那条
#      `up=569672.21` 就是 MSYS 自己的 uptime)。⇒ 远端命令一律用**单引号**。
#   ② 装机闸：官方 APK 走的是**全屏安装页**，要先勾「已了解应用的风险检测结果」再点「继续安装」，
#      与 suw.apk 那个小弹窗的坐标不通用。已手工装好，本脚本不再装包。
#
# 已知代价：这一发没有 root 侧通道(@sushd: 的客户端 suw.manager 被卸了)，判据只能来自
#   Manager 自己的 UI + shell 读得到的 dmesg。够用，因为"加冕成没成"最权威的读数就是它自己怎么说。
set -u
cd "$(dirname "$0")/.." || exit 1
# ★第 30 发整发白跑的原因：总线上**临时**多了第二路 transport(多半是别的会话 adb connect 过)
#   ⇒ 每个 adb 调用都返回 `more than one device/emulator`，脚本从 `adb reboot` 起一步都没执行，
#   却仍然老老实实等了 1100 秒"post 没跑"。⇒ 钉死序列号 + 开跑前先 preflight 一次。
export ANDROID_SERIAL=${ANDROID_SERIAL:-<DEVICE_SERIAL>}
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch)"; exit 2; }
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }     # 调用方一律传**单引号**字符串
EV=kmod/w103_evidence; mkdir -p "$EV"
PKG=me.weishu.kernelsu
shot() { MSYS_NO_PATHCONV=1 adb exec-out screencap -p > "$EV/w30_$1.png" 2>/dev/null
         echo "    截图 w30_$1.png ($(stat -c %s "$EV/w30_$1.png" 2>/dev/null) 字节)"; }

echo "=== -1) preflight：adb 必须真的能打到那台机器 ==="
PF=$(A "echo PFOK-\$(cat /proc/uptime | cut -d\" \" -f1)" 2>&1)
case "$PF" in *PFOK*) echo "  $PF";; *) echo "[x] adb 不通/多设备：$PF"; exit 6;; esac
echo "=== 0) 包状态复核 ==="
# ★第 31 发白跑的根因：`bootstrap.sh --punch` 会先查 com.suw.manager 的 uid，查不到就直接
#   `[x] 查不到 com.suw.manager 的 uid(没装?)` 退出 ⇒ 我把 suw 卸掉想让官方成为唯一候选，
#   结果 punch 根本没派发，而我把 bootstrap 的输出 grep 掉了 ⇒ 又白等 1100 秒。
#   正解：装 **suw_nomgr.apk**(包名同为 com.suw.manager、证书不在期望列表) ⇒ punch 能跑又不抢加冕。

A 'echo "up=$(cat /proc/uptime) enforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"' | sed 's/^/  /'
A 'echo "mgr=[$(pm list packages me.weishu.kernelsu)]"; echo "suw=[$(pm list packages com.suw.manager)]"' | sed 's/^/  /'

echo "=== 1) push ko → reboot → punch ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 45
A 'rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/dmesg2.log' >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch > kmod/w138_punch.log 2>&1
grep -aE 'slide=|dispatched|pr=|\[x\]|负载' kmod/w138_punch.log | tail -6 | sed 's/^/  /'
grep -aq dispatched kmod/w138_punch.log || { echo '[x] punch 没派发(见 kmod/w138_punch.log) ⇒ 别往下等'; exit 7; }
echo "=== 2) 等本 boot 的 stage 跑到判据④(post 可能 3~18 分钟) ==="
for i in $(seq 1 230); do
    sleep 5
    N=$(A 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  到了 (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s mod=$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 这一发做不了"; exit 5; }

echo "=== 3) 内核侧读数：加冕/装 fd 的行(环形缓冲会被厂商日志刷掉，抓不到不等于没发生) ==="
A 'dmesg | grep -aE "Crowning manager|Found new base.apk|install fd for manager|Search manager|packages.list detected" | tail -12' | cut -c1-165 | sed 's/^/  /'
A 'echo "mod=$(grep -c kernelsu /proc/modules) enforce=$(getenforce) mgr_pid=[$(pidof me.weishu.kernelsu)]"' | sed 's/^/  /'
A 'grep -aE "官方 Manager pid|已写 /proc/ksu_install_fd|触发口在不在" /data/local/tmp/ksu_stage.log | cut -c1-150 | tail -6' | sed 's/^/  stage: /'

echo "=== 4) ★权威判据：Manager 自己怎么说(首页) ==="
# ★不要 force-stop！stage 现在会自己(在 shell 域)把 Manager 起来并给它装驱动 fd；
#   force-stop 会杀掉那个**已装 fd** 的进程，重启后的新进程没有 fd ⇒ 判据必然假阴性。
A 'am start -n me.weishu.kernelsu/.ui.MainActivity' | head -1 | sed 's/^/  /'
sleep 14; shot home
echo "  ★期望首页是「工作中 / 版本 32653」，不是第 27 发那个「不支持 / 只支持 GKI 内核」。"

echo "=== 5) 模块页(这一发真正要的那一格) ==="
A 'input tap 405 2290' >/dev/null; sleep 7; shot modules
A 'input tap 405 2290' >/dev/null; sleep 4; shot modules_b
echo "  底部 tab 真实坐标(1080x2388)：主页≈135 / 超级用户≈270 / 模块≈405 / 设置≈675，y≈2290"
echo "  若模块页里有「从本地安装/安装并上传」，点它(页面上半部中央)看文件选择器能不能看到 LSPosed zip："
A 'input tap 540 1180' >/dev/null; sleep 9; shot module_install_try

echo "=== 6) 超级用户页 + 设置页(对照：能不能列 app、有没有报 ksud 缺失) ==="
A 'input tap 270 2290' >/dev/null; sleep 6; shot su
A 'input tap 675 2290' >/dev/null; sleep 6; shot settings

echo "=== 7) 收尾取证 ==="
A 'dmesg | grep -aE "Crowning manager|Found new base.apk|install fd for manager|is_manager|ksud" | tail -25' > "$EV/w30_crown_dmesg.txt" 2>&1
A 'echo "mod=$(grep -c kernelsu /proc/modules)"; echo "enforce=$(getenforce)"; echo "mgr=[$(pidof me.weishu.kernelsu)]"; echo "stage_tail:"; tail -6 /data/local/tmp/ksu_stage.log' > "$EV/w30_state.txt" 2>&1
wc -l "$EV/w30_crown_dmesg.txt" "$EV/w30_state.txt" 2>/dev/null | sed 's/^/  /'
ls -la "$EV" | grep -a w30 | awk '{print "  ",$5,$9}'
echo "=== 完(先看截图，再 reboot 收尾) ==="
