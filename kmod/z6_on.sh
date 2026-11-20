#!/bin/bash
# z6_on.sh — 一键开窗：iQOO Z6 临时 root + KernelSU + su + 管理器「工作中[越狱模式]」[+ LSPosed]
# 用法:
#   bash kmod/z6_on.sh              默认: 开窗+装预设模块(ZN+LSPosed)+注入+shd+主动抢装+维持件
#   bash kmod/z6_on.sh --no-modules 轻量: 开窗+shd+主动抢装+维持件（跳过模块/踢框架，最稳）
# 收窗: bash kmod/z6_off.sh
# 说明: 一次开机一枪；窗口不持久、别留过夜。
set -u
export MSYS_NO_PATHCONV=1
export PATH="/c/adb/platform-tools:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
[ -f config.sh ] && . ./config.sh   # 可选：预设 ADB/PY/DEV
ADB="${ADB:-adb}"; A(){ "$ADB" "$@"; }
ap(){ A shell "$1" 2>/dev/null | tr -d '\r'; }

MODULES=1
for a in "$@"; do case "$a" in
  --no-modules) MODULES=0 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "未知参数: $a（只支持 --no-modules）"; exit 2 ;;
esac; done

echo "==== z6_on  MODULES=$MODULES ===="
MOD=$(ap "grep -c kernelsu /proc/modules")
[ "$MOD" = "0" ] || { echo "[x] 起点就有模块(mod=$MOD) ⇒ 先 bash kmod/z6_off.sh"; exit 3; }

echo "== [1/4] go.sh 开窗（punch+insmod，约 12~25 分钟，期间零接触）=="
I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh
MOD=$(ap "grep -c kernelsu /proc/modules"); KDEV=$(ap "ls /dev/ksud")
if [ "$MOD" != "1" ] || [ "$KDEV" != "/dev/ksud" ]; then
  echo "[x] 窗口没开成（mod=$MOD kdev=$KDEV）。多半 punch 空枪，直接重跑本脚本即可。"; exit 4
fi
echo "  窗口 OK: mod=1 / Permissive / /dev/ksud 在"

echo "== [2/4] 推执行件 =="
A push kmod/_tmp_ksud_from_dev /data/local/tmp/w234_ksud_orig >/dev/null 2>&1
for f in w230_rebuild_all.sh w232_zn_precheck.sh z6_stage4.sh z6_launch.sh b8_keep.sh z6_light.sh; do
  A push "kmod/$f" "/data/local/tmp/$f" >/dev/null 2>&1 || { echo "[x] push $f 失败"; exit 5; }
done

fire(){ local B; B="$(basename "$1")"; local OUT="$2"
  A shell "chmod 755 /data/local/tmp/$B; rm -f /data/local/tmp/$OUT" >/dev/null 2>&1
  A shell "am force-stop com.suw.manager" >/dev/null 2>&1; sleep 1
  A shell "am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd '@sushd:/data/local/tmp/$B'" >/dev/null 2>&1
  for i in $(seq 1 45); do A shell "grep -aq '===== DONE' /data/local/tmp/$OUT" 2>/dev/null && break; sleep 3; done
}

if [ "$MODULES" = "1" ]; then
  echo "== [3/4] 装预设模块(ZN+LSPosed) + 前置闸 + 注入 =="
  # 交付包里带了 modules/ 就先推到设备（设备已有同名则以新覆盖，无妨）
  if [ -d modules ]; then
    echo "  推模块 zip 到设备 /sdcard/Download/必备模块/"
    A shell "mkdir -p '/sdcard/Download/必备模块'" >/dev/null 2>&1
    for z in modules/*.zip; do A push "$z" "/sdcard/Download/必备模块/" >/dev/null 2>&1 && echo "    ok $(basename "$z")"; done
  fi
  fire kmod/w230_rebuild_all.sh w230_rebuild_all.out
  ap "grep -a KSUD_OK /data/local/tmp/w230_rebuild_all.out" | grep -q KSUD_OK || { echo "[x] w230 补 ksud/重建失败"; exit 6; }
  fire kmod/w232_zn_precheck.sh w232_zn_precheck.out
  ap "grep -a ZGATE /data/local/tmp/w232_zn_precheck.out" | grep -q 'ZGATE=PASS' || { echo "[x] ZGATE 未过（root_status/注入器）"; exit 6; }
  echo "  模块 ok，触发注入（会踢框架，adb 短暂掉线）"
  fire kmod/z6_launch.sh z6_launch.out
else
  echo "== [3/4] 轻量模式：不起模块、不踢框架，只做 shd+主动抢装+维持件 =="
  fire kmod/z6_light.sh z6_light.out
  ap "grep -aE 'SHD=|MGR=|KEEPER' /data/local/tmp/z6_light.log"
fi

echo "== [4/4] 等生效 =="
sleep 15
echo "  现状: mod=$(ap 'grep -c kernelsu /proc/modules') / su=$(ap 'ls /product/bin/su 2>&1|head -1') / mgr=$(ap 'pidof me.weishu.kernelsu')"
echo "  看界面: adb shell screencap -p /sdcard/a.png && adb pull /sdcard/a.png"
echo "  收窗: bash kmod/z6_off.sh"
