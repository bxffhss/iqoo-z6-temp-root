#!/bin/bash
# w156_official_demo.sh —— 终局演示：**授权这一半完全走官方 KernelSU Manager**。
#   用法：I_KNOW=1 bash kmod/w156_official_demo.sh      (会 reboot、会卸装 APK、会 punch)
#
# 这一发要证的唯一命题(用户原话"最后我只需要使用 kernelsu 授权"的最后一格)：
#   加冕(官方 Manager 对着我们晚加载的 ko) → 授权(官方 UI 里勾一个真 app) → 那个 app 敲 su 出 uid=0。
#   我们的 suw.manager 全程**不参与**——它在 punch 前就被卸掉，因为 §6.135 一手钉死了
#   `ksu_manager_appid` 是 insmod 那一刻扫 packages.list 定的**单值**，装两个只会加冕到一个。
#
# ★三处"必须说清"的口径：
#   ① su 的**可见性**还是我们的 `bind /product/bin` 在做(由 stage 代跑 w135_fix，见 ksu_one_stage.sh 里
#      那段带 w156_mount 标记的步)——**官方 Manager 没有负责让 su 存在**，它只负责名单。
#   ② Termux 那一步没有回执文件可用(没有 @sushd 通道) ⇒ 判据 = 截图(人眼看 uid=0) +
#      `dmesg.live` 里的 KSUBEAT 脚印(SU0 su found / X7 before commit_creds 带着 Termux 的 uid)。
#      两个来源形状不同，正是"同一结论两来源"的老规矩。
#   ③ UI 点按用 `uiautomator dump` 现找坐标，不写死(写死的坐标只对某一个 APK 有效，见
#      [[suw-apk-manager])；找不到就**如实打印"这一格没点到"**，绝不猜点。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot + 卸装 APK)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1; }
EV=kmod/w103_evidence; mkdir -p "$EV"
PKG=me.weishu.kernelsu
OFF=suw_apk/backup_official_kernelsu_v3.3.0.apk
[ -f "$OFF" ] || { echo "[x] 找不到官方 Manager apk"; exit 2; }
TGTAPP=${TGTAPP:-com.termux}
shot() { adb exec-out screencap -p > "$EV/w30_$1.png" 2>/dev/null
         echo "    截图 w30_$1.png $(stat -c %s "$EV/w30_$1.png" 2>/dev/null) 字节"; }
tap_to() {   # tap_to <uiautomator 里 text/content-desc 的正则> —— 现找坐标；找不到就明说
    adb shell uiautomator dump /sdcard/w30.xml >/dev/null 2>&1
    adb pull /sdcard/w30.xml "$EV/w30_dump.xml" >/dev/null 2>&1
    xy=$(tr '>' '\n' < "$EV/w30_dump.xml" | grep -aE "$1" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 |
         sed -E 's/.*\]\[([0-9]+),([0-9]+)".*/\1 \2/')
    [ -z "$xy" ] && { echo "      [!] 界面上找不到 [$1] ⇒ 这一格没点到(绝不猜坐标)"; return 1; }
    set -- $xy
    echo "      点 ($1,$2) ← 匹配 [$1]"
    adb shell input tap "$1" "$2"; sleep 5; return 0
}

echo "=== 1) 包状态摆正：卸 suw.manager，装官方 v3.3.0（都在 punch 之前） ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
A "input keyevent 224; svc power stayon true" >/dev/null
A "pm uninstall com.suw.manager" | tail -1 | sed 's/^/  卸 suw: /'
# ★这一发的**全部命题**建立在"punch 那一刻设备上只有一个 Manager 候选"上，
#   所以"卸掉了没有"必须是**硬闸**，不能只看 `pm uninstall` 打了什么：
#   第二次跑就是 `Failure [DELETE_FAILED_INTERNAL_ERROR]` 被我当噪音放过，脚本继续往下走 ⇒
#   真机上报"卸失败"之后包其实可能已经没了，也可能还在——**回执在这里不带信息量，必须复读实况**。
for k in 1 2 3 4 5; do
    [ -z "$(A 'pm list packages com.suw.manager')" ] && { echo "  suw.manager 确实不在了(第 $k 次复读)"; break; }
    A "am force-stop com.suw.manager" >/dev/null; A "pm uninstall com.suw.manager" >/dev/null
    sleep 4
done
[ -z "$(A 'pm list packages com.suw.manager')" ] || { echo "[x] suw.manager 还装着 ⇒ 加冕候选不唯一，这一发的命题废了 ⇒ 停"; exit 3; }
A "pm list packages $PKG" | grep -q "$PKG" && A "pm uninstall $PKG" >/dev/null
( for i in $(seq 1 30); do sleep 3
      A "pm list packages $PKG" | grep -q "$PKG" && { echo "      第 $i 轮：装上了"; break; }
      A "input tap 540 1962"; sleep 1; A "input tap 540 2109"
  done ) &
adb install -r -t "$OFF" 2>&1 | tail -2 | sed 's/^/      /'
wait
A "pm list packages -3" | grep -aE "$PKG|termux" | sed 's/^/  已装: /'
#   同上：官方那份**必须在**，否则 punch 之后谁都不可能被加冕，白烧一枪
for k in 1 2 3; do
    A "pm list packages $PKG" | grep -q "$PKG" && break
    echo "  官方 Manager 还没装上(第 $k 轮)，重装一次"
    ( for i in $(seq 1 20); do sleep 3
          A "pm list packages $PKG" | grep -q "$PKG" && break
          A "input tap 540 1962"; sleep 1; A "input tap 540 2109"
      done ) &
    adb install -r -t "$OFF" 2>&1 | tail -1 | sed 's/^/      /'
    wait
done
A "pm list packages $PKG" | grep -q "$PKG" || { echo "[x] 官方 Manager 装不上(vivo 装机闸没点到) ⇒ 这一发没有加冕对象 ⇒ 停"; exit 3; }

echo "=== 2) 演示载荷：静态 su + 挂载脚本 + 标记文件（标记只这一发创建） ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w135_fix.sh /data/local/tmp/sustatic; rm -f /data/local/tmp/w135_fix.out; touch /data/local/tmp/w156_mount" >/dev/null
echo "  标记=[$(A 'ls -l /data/local/tmp/w156_mount 2>&1 | cut -c1-52')]"

echo "=== 3) push ko → reboot → punch → 等本 boot 的 stage ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log" >/dev/null
# ★★第一发(exit 5)就是在这里被自己骗了 18 分钟：原来把 bootstrap 的输出用
#   `grep -aE "slide=|dispatched|pr="` 过一遍 ⇒ 它**提前退出时打的那句原因被筛掉了**，
#   我看到的" silence"被读成"post 还没跑"。判据不许带筛子(§6.94② 同一族)，改成整份留盘 + 打尾巴。
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w30_bootstrap.txt" 2>&1
RCB=$?
echo "  bootstrap 退出码=$RCB(0=它自认为打完了)；原文最后 8 行："
tail -8 "$EV/w30_bootstrap.txt" | sed 's/^/    /'
# 起跑没起跑有个**硬**信号：pr 是被 `setsid … > punch.log` 起来的，文件不出现就是根本没派发。
PUNCHED=0
for i in $(seq 1 20); do
    sleep 5
    [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { PUNCHED=1; echo "  pr 已起跑(看到 punch.log, t+$((i*5))s)"; break; }
done
[ "$PUNCHED" = 1 ] || { echo "[x] punch.log 100 秒内没出现 ⇒ pr 根本没被派发，问题在 bootstrap 那一层"
                        echo "    ⇒ 别再空等 post(上一发就是这么烧掉 18 分钟)；看 $EV/w30_bootstrap.txt 全文"
                        exit 6; }
N=0
for i in $(seq 1 220); do
    sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc 0-9)
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 这一发做不了"; exit 5; }

echo "=== 4) 挂载这一半(stage 代跑)：su 必须在 /product/bin 看得见 ==="
A "grep -a 'w135_fix' /data/local/tmp/ksu_stage.log | cut -c1-200" | sed 's/^/  /'
A "echo 挂载行=\$(grep -c pbin /proc/self/mountinfo) su=\$(ls -l /product/bin/su 2>&1 | cut -c1-60)" | sed 's/^/  /'

echo "=== 5) 加冕判据(权威那份：官方 Manager 自己怎么说) ==="
A "am force-stop $PKG"; sleep 1
A "am start -n $PKG/.ui.MainActivity" | head -1 | sed 's/^/  /'
sleep 12; shot home
A "dmesg 2>/dev/null | grep -aE 'Crowning manager|install fd for manager|is_manager' | tail -6" | cut -c1-150 | sed 's/^/  /'

echo "=== 6) 授权：官方超级用户页里把 $TGTAPP 的开关点到开(坐标现找，不写死) ==="
A "input tap 270 2290"; sleep 6; shot su_before
tap_to "$TGTAPP|Termux" ; shot su_after

echo "=== 7) 终局：Termux 里敲 su ==="
A "am start -n $TGTAPP/.app.TermuxActivity" >/dev/null 2>&1
A "monkey -p $TGTAPP 1" >/dev/null 2>&1
sleep 10; shot termux_before
A "input text 'su'; input keyevent 66"; sleep 8; shot termux_su
A "grep -acE 'KSUBEAT (SU[0-9]|X[0-9A-C])' /data/local/tmp/dmesg.live 2>/dev/null" | sed 's/^/  内核脚印条数: /'
A "grep -aE 'KSUBEAT (SU0 su found|X7 before commit_creds|X8 commit_creds)' /data/local/tmp/dmesg.live 2>/dev/null | tail -6" | cut -c1-150 | sed 's/^/  /'

echo "=== 8) 收尾：卸标记与载荷 → reboot → 复核回出厂 ==="
A "rm -f /data/local/tmp/w156_mount /data/local/tmp/w135_fix.sh /data/local/tmp/sustatic" >/dev/null
A "id" | sed 's/^/  收尾前 shell 身份: /'
echo "  ★注意：这一发从头到尾**没有** suw.manager，所以没有任何通道能 root 侧 umount；"
echo "    bind 是挂载视图，随 reboot 消失(§6.124⑤ 同族)，/product/bin 一重启就回出厂 3 项。"
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = "1" ]; do sleep 10; done
sleep 20
echo "  收尾复核: $(A 'echo up=$(cut -d\" \" -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) 挂载=$(grep -c pbin /proc/self/mountinfo) bin=$(ls -A /product/bin | wc -l)')"
echo "  截图与 dump 都在 $EV/w30_*"
