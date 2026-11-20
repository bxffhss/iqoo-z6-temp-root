#!/bin/bash
# b_preflight.sh —— 路线 B 窗「前置校验」：官方 KernelSU Manager 必须在 boot 前已装（track_throne 开机即加冕）。
#
# 为什么单独成件（B 与 A 唯一的结构性差别）：
#   诊断 A 的官方 UI『不支持』根因假设①＝加冕时序——官方 App 在 boot **之后**才侧载，pkg_observer 重冠之前
#   UI 已跑，GET_MANAGER_APPID≠其 uid ⇒ 超级用户页签 t=0 不渲染。
#   ⇒ B 窗要把这一维钉死：先在正常 boot 里装好官方 App（/data 持久）→ 跑 go.sh（reboot 进被利用态，ko 的
#     track_throne 在开机扫到它）→ UI 跑时确已被加冕。
#
# 本件只做**只读校验 + 打印 uid + 给开火清单**，**不发扳机、不 reboot、不 insmod、不改任何设备状态**。
# 用法：bash kmod/b_preflight.sh [官方Manager.apk路径(可选，仅用于提示)]
set -u
cd "$(dirname "$0")/.." || exit 1
ADB=${ADB:-adb}
A() { MSYS_NO_PATHCONV=1 $ADB shell "$1" 2>&1 | tr -d '\r'; }
MGRPKG=me.weishu.kernelsu
SUWPKG=com.suw.manager
APK=${1:-}

echo "=== 0) 设备在线 + 当前是干净的正常 boot（还没开窗） ==="
ST=$(A 'echo ok')
[ -n "$ST" ] || { echo "[x] adb 没连上 / 没授权 ⇒ 先连设备再跑本件"; exit 2; }
BC=$(A 'getprop sys.boot_completed' | tr -dc '0-9')
[ "$BC" = 1 ] || { echo "[x] 系统还没 boot 完（sys.boot_completed=$BC）"; exit 2; }
MOD=$(A 'grep -c kernelsu /proc/modules' | tr -dc '0-9')
[ "$MOD" = 0 ] || { echo "[x] 当前 boot 已经有 kernelsu 在（mod=$MOD）⇒ 上一发没收尾或已开窗；先 I_KNOW=1 bash kmod/w161_teardown.sh，别在脏 boot 上开枪"; exit 3; }
ENF=$(A getenforce)
echo "  boot_completed=1 mod=0 enf=$ENF ⇒ 起点干净 ✓"

echo "=== 1) ★官方 Manager 必须在 boot 前已装（这是 B 窗前提，A 窗就是栽在这） ==="
MGR_UID=$(A "pm list packages -U 2>/dev/null | grep -w $MGRPKG" | grep -oE "uid:[0-9]+" | cut -d: -f2)
if [ -z "$MGR_UID" ]; then
  echo "  [x] 官方 Manager($MGRPKG) 当前**没装** ⇒ B 窗前提不成立：boot 后侧载会退回 A 窗的加冕时序问题。"
  if [ -n "$APK" ]; then
    echo "    请先在**这个正常 boot**里装好它：  adb install -r \"$APK\""
  else
    echo "    请先 adb install 你选定的官方 Manager APK，装完再跑本件复核："
    echo "      · v3.3.0（本机 suw_apk/backup_official_kernelsu_v3.3.0.apk）——本窗选定版：v3.x 族，UI/模块完整；"
    echo "        但 app 侧有 GKI 闸，在 5.4 非 GKI 上可能仍『不支持』（即便已加冕）。失败＝时序/闸两可，需转 v2.0.0 对照。"
    echo "      · v2.0.0（suw_apk/backup_official_kernelsu_v2.0.0_22001.apk）——对照版：已被本机验证在 5.4 上『工作中』，干净隔离时序假设。"
  fi
  exit 4
fi
echo "  官方 Manager 已装 ⇒ uid=$MGR_UID ✓（/data 持久，go.sh reboot 后 track_throne 开机即加冕）"

SUW_UID=$(A "pm list packages -U 2>/dev/null | grep -w $SUWPKG" | grep -oE "uid:[0-9]+" | cut -d: -f2)
echo "  suw($SUWPKG) uid=${SUW_UID:-<未装，B 窗不要求>}"

echo
echo "=== 2) B 窗开火就绪清单 ==="
echo "  ① 官方 App 已装（uid=$MGR_UID）✓ —— 关键：必须在 go.sh 之前装好（go.sh 会 reboot）"
echo "  ② 稳定交付配置：rc80 + ksu_hook_mask=0x0 + /dev/ksud 口径（ksu_args.txt 已是此形状）"
echo "     ★push_ksu.sh 默认 KO=rc74c，B 窗务必显式钉 rc80："
echo "       KO=kmod/kernelsu_rc80.ko I_KNOW=1 bash kmod/go.sh"
echo "  ③ 等判据⑥（agent fd 装好 = root 通道可用）后，验证加冕（B 的核心判据）："
echo "       adb shell '/data/local/tmp/ksuctl88 mgr'   ⇒ 期望 appid=$MGR_UID（官方被加冕）"
echo "       adb shell '/data/local/tmp/ksuctl88 granted $MGR_UID'  ⇒ 期望 granted=1"
echo "  ④ 驱动官方 UI（32601-2 + 深链后四个页签显形）：bash kmod/run_mgrB_window.sh"
echo "  ⑤ 给三标准 app 授权（uid 现取：adb shell pm list packages -U | grep -a <包名>）："
echo "       bash kmod/ui_grant.sh scene   <uid> com.omarea.vtools"
echo "       bash kmod/ui_grant.sh np      <uid> com.wn.app.np"
echo "       bash kmod/ui_grant.sh brevent <uid> me.piebridge.brevent"
echo "  ⑥ 收窗：I_KNOW=1 bash kmod/w161_teardown.sh"
echo
echo "★判据：若 ③ 的 appid≠$MGR_UID 或 ④ 仍『不支持』⇒ 时序假设不成立 ⇒ 转 A（改 KSU_VERSION_OVERRIDE / bump uapi）"
echo "★若 ④ 渲染成功且 ⑤ 三授权进内核名单 ⇒ B 闭环：无需改 ko，官方 App 即 manager。"
