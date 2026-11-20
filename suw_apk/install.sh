#!/bin/bash
# 安装 suw.apk —— vivo 会弹"安装确认"框, 不点就报 INSTALL_FAILED_ABORTED: User rejected permissions
# 做法与 poc_apk/autoinstall.sh 相同: 后台发起安装 + 轮询 uiautomator dump 点确认按钮。
set -u
cd "$(dirname "$0")"
ADB="C:/adb/platform-tools/adb.exe"
DEV=<DEVICE_SERIAL>
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
PY="C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"
APK=suw.apk

A shell "input keyevent KEYCODE_HOME" >/dev/null 2>&1
sleep 1
A install -r -t "$APK" > install_out.log 2>&1 &
INST=$!

for i in $(seq 1 30); do
  sleep 1
  if ! kill -0 $INST 2>/dev/null; then echo "[$i] 安装进程已结束"; break; fi
  A shell "uiautomator dump /sdcard/suw_u.xml >/dev/null 2>&1" >/dev/null 2>&1
  A shell "cat /sdcard/suw_u.xml" > u.xml 2>/dev/null
  RES="$("$PY" - <<'PY'
import re, io, os
p = 'u.xml'
if not os.path.exists(p) or os.path.getsize(p) == 0:
    print('NOXML'); raise SystemExit
s = io.open(p, encoding='utf-8', errors='replace').read()
# vivo 弹窗上的按钮文字会变, 优先按"可点击 + 含安装/继续/仍要/确定/已了解"挑
KEYS = ('继续安装', '仍要安装', '直接安装', '安装', '确定', '已了解', '同意')
best = None
for m in re.finditer(r'<node[^>]*>', s):
    t = m.group(0)
    tx = re.search(r'text="([^"]*)"', t)
    cl = re.search(r'clickable="(\w+)"', t)
    bd = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
    if not (tx and cl and bd) or cl.group(1) != 'true':
        continue
    txt = tx.group(1).strip()
    if not txt:
        continue
    for k in KEYS:
        if k in txt:
            x = (int(bd.group(1)) + int(bd.group(3))) // 2
            y = (int(bd.group(2)) + int(bd.group(4))) // 2
            if best is None:
                best = (x, y, txt)
            break
print('TAP %d %d # %s' % best if best else 'NONE')
PY
)"
  case "$RES" in
    TAP*)
      COORD=$(echo "$RES" | sed 's/^TAP //; s/ *#.*//')
      echo "[$i] 点确认: $RES"
      A shell "input tap $COORD" >/dev/null 2>&1
      sleep 1
      ;;
    *) : ;;
  esac
done

wait $INST 2>/dev/null
echo "=== 安装输出 ==="; cat install_out.log | tr -d '\r'
echo "=== 是否装上 ==="; A shell "pm list packages | grep -w com.suw.manager; dumpsys package com.suw.manager | grep -E 'versionName|codePath' | head -3" 2>&1 | tr -d '\r'
