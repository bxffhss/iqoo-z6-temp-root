#!/system/bin/sh
# z6run.sh — 统一入口：触发设备侧某一"步"（on=装模块 / soft=软重启 / after=重启后注入）
#   用法：  sh /sdcard/z6root/z6run.sh on|soft|after
#   两种语境自动适配：
#     · 你已经是 root（su -c 进来的 / root 终端）      ⇒ 直接执行对应脚本
#     · 你是 uid2000 的 shell（Stellar / Shizuku）      ⇒ 用 am start @sushd 借 suw 以 root 跑
#       （等同于 PC 上的 `adb shell am start ... @sushd:...`，只是 am start 在本地敲、不经 adb）
#       ★@sushd 路要求 suw(com.suw.manager) 已在 ko 白名单（A 形状）；若那发窗口是 B 形状(termux)，
#         suw 不在名单，@sushd 派不动 ⇒ 请改用目标 App 的 root 终端：su -c 'sh /sdcard/z6root/z6_dev_<step>.sh'
set -u
SRC="${SRC:-/sdcard/z6root}"
MGR=com.suw.manager
S="${1:-}"; case "$S" in on|soft|after) : ;; *) echo "用法: sh $0 on|soft|after"; exit 2 ;; esac
SC="$SRC/z6_dev_$S.sh"
[ -f "$SC" ] || { echo "[x] 缺 $SC（包不全？）"; exit 2; }
: > "/data/local/tmp/z6_dev_$S.log" 2>/dev/null

U=$(id -u)
if [ "$U" = "0" ]; then
  echo "== 已是 root ⇒ 直接跑 z6_dev_$S.sh =="
  [ "$S" = soft ] && echo "  (soft 会踢框架：本 root shell/终端会掉)"
  sh "$SC"
  exit $?
fi

echo "== uid=$U ⇒ 用 @sushd 借 suw 以 root 跑 z6_dev_$S.sh =="
if ! pm list packages 2>/dev/null | grep -q "^package:$MGR$"; then
  echo "[x] 没装 $MGR ⇒ @sushd 不可用；改用目标 App root 终端的 su -c"; exit 1
fi
am force-stop "$MGR" >/dev/null 2>&1; sleep 1
# ★/sdcard 是 noexec（tmpfs/fuse），exec /sdcard 里的脚本会 exit=127 ⇒ 先拷到 /data/local/tmp 再 @sushd
cp -f "$SC" "/data/local/tmp/z6_dev_$S.sh" 2>/dev/null; chmod 755 "/data/local/tmp/z6_dev_$S.sh" 2>/dev/null
am start -f 0x4000000 -n "$MGR/.MainActivity" --es auto ksuarm --es cmd "@sushd:/data/local/tmp/z6_dev_$S.sh" >/dev/null 2>&1
echo "  已派单。soft 会踢 framework（本 shell 掉线），其余在 /data/local/tmp/z6_dev_$S.log 看结果："
for i in $(seq 1 12); do
  grep -aq '===== DONE' "/data/local/tmp/z6_dev_$S.log" 2>/dev/null && break
  sleep 2
done
tail -8 "/data/local/tmp/z6_dev_$S.log" 2>/dev/null | sed 's/^/    /'
echo "  若这里空/没 DONE：多半是 B 形状 suw 未授权 ⇒ 改用 目标 App 里 su -c 'sh $SC'"
