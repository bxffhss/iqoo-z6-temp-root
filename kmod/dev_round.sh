#!/bin/bash
# dev_round.sh — 趁 root 窗口还活着，把 kmod 阶段的判据一发跑完并落盘。
# 用法(在仓库根目录)：bash kmod/dev_round.sh
# 前置：本 boot 已激活(su 可用)。脚本**不**删 /data/adb/su —— 收尾仍走 cm57/round9_cleanup.sh。
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
ADB="${ADB:-C:/adb/platform-tools/adb.exe}"
DEV="${DEV:-<DEVICE_SERIAL>}"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
TS=$(date +%m%d_%H%M)                      # 证据文件名必须每次唯一(否则重跑会原地覆盖上一轮判据)
EV="kmod/evidence_${TS}.log"
R() { A shell "su -c '$1'" 2>&1 | tr -d '\r'; }

echo "[0] 前置检查"
ID=$(R "id")
case "$ID" in
  *uid=0*) : ;;
  *) echo "  [x] shell 的 su 不可用: $ID"
     echo "      激活后的白名单只有 uid=0 与 manager ⇒ uid 2000 会被拒(rc=126)。"
     echo "      请在手机上『SU 白名单』→ 超级用户 → 打开 (uid 2000) 那一格后重跑本脚本。"
     echo "      (若显示 rc=127/-1 则是本 boot 根本没有窗口/daemon 不在，需要先激活。)"
     exit 1;;
esac
echo "  $ID"

echo "[1] 推 modbin + 两个探针模块(逐个 md5 对齐，Git Bash 的 push 会谎报成功)"
for f in cm57/modbin:modbin kmod/suwprobe.ko:suwprobe.ko kmod/suwkprobe.ko:suwkprobe.ko kmod/suwksyms.ko:suwksyms.ko kmod/suwhook.ko:suwhook.ko kmod/suwperm.ko:suwperm.ko kmod/dev_hooks_test.sh:dev_hooks_test.sh; do
  L=${f%%:*}; N=${f##*:}
  [ -f "$L" ] || { echo "  [x] 本地没有 $L (先 bash kmod/build.sh)"; exit 1; }
  H=$(md5sum "$L" | cut -d' ' -f1)
  A push "$L" "/data/local/tmp/$N" >/dev/null || { echo "  [x] push $N 失败"; exit 1; }
  G=$(R "md5sum /data/local/tmp/$N" | cut -d' ' -f1)
  [ "$H" = "$G" ] || { echo "  [x] $N md5 不一致 host=$H dev=$G"; exit 1; }
  R "chmod 755 /data/local/tmp/$N" >/dev/null
  echo "  ok $N $H"
done

{
  echo "=== kmod 判据轮 $TS ==="
  echo "--- 阶段0: 自研 .ko 能装 + init 真的被调用"
  R "cd /data/local/tmp; ./modbin ins suwprobe.ko; sleep 1; dmesg | grep -a 'suwprobe:' | tail -3; ./modbin rm suwprobe; ./modbin state suwprobe"
  echo "--- 阶段1+2: kprobe 可用 + 两个符号各解析一次(跨符号互校)"
  R "cd /data/local/tmp; ./modbin ins suwkprobe.ko; sleep 1; dmesg | grep -a 'suwkprobe:' | tail -6; ./modbin rm suwkprobe"
  echo "--- 阶段3: 用捞到的 kallsyms_lookup_name 解析未导出符号(判据见下面的离线核对)"
  R "cd /data/local/tmp; ./modbin ins suwksyms.ko; sleep 1; dmesg | grep -a 'suwksyms:' | tail -14; ./modbin rm suwksyms"
  echo "--- 阶段4a/4b: kprobe handler 会被调用吗 + 钩子能改系统调用结果吗(设备侧脚本跑，成对控制)"
  R "sh /data/local/tmp/dev_hooks_test.sh"
  echo "--- 现场: 还挂着什么(应该是空)"
  R "./modbin ls | grep -E 'suw' || echo '(无残留)'"
} | tee "$EV"

echo "[3] 离线核对(多个符号必须给出同一个 slide 差值，否则判不通过)"
BOOT=$(A shell "cat /proc/sys/kernel/random/boot_id" | tr -d '
' | tr -d ' ')
SLIDE=""
for f in "analysis/slide_cache/$BOOT.txt" analysis/slide_cache/latest.txt; do
  [ -f "$f" ] && SLIDE=$(cut -d' ' -f1 "$f" | tr -d '[:space:]') && [ -n "$SLIDE" ] && break
done
if [ -z "$SLIDE" ]; then
  echo "  [!] 找不到本 boot 的 slide 缓存($BOOT) ⇒ 手工核对: python kmod/verify_addr.py <slide> $EV"
else
  "C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"       kmod/verify_addr.py "$SLIDE" "$EV" analysis/embedded-kallsyms.txt | tee -a "$EV"
fi
echo "    收尾: bash cm57/round9_cleanup.sh"
