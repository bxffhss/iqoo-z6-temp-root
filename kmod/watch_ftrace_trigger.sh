#!/usr/bin/env bash
# 等 root 侧探针 armed ⇒ 立刻两次触发 app 授权(拿 SIGKILL 的现场) ⇒ 拉回 trace
set +u
cd "$(dirname "$0")/.." || exit 1
PKG=com.suw.manager
A() { MSYS_NO_PATHCONV=1 adb shell "$@"; }
OUT=kmod/ftrace_w1
mkdir -p "$OUT"

echo "[w] 等 /data/local/tmp/ksu_ftrace_armed(上限 260s)"
k=0
while [ $k -lt 260 ]; do
    if [ "$(A 'test -e /data/local/tmp/ksu_ftrace_armed && echo Y')" = "Y" ]; then
        echo "[w] armed 到了(等了 ${k}s)"
        break
    fi
    sleep 2
    k=$((k + 2))
done
[ $k -ge 260 ] && { echo "[w] 没等到 armed，探针这一发没跑起来"; exit 1; }

for r in 1 2; do
    echo "[w] 第 $r 次触发 armed 授权(带 cmd)"
    A "am force-stop $PKG" >/dev/null
    sleep 1
    A "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd 'id; echo MARKER_FROM_ROOT_CHILD'" | head -2
    sleep 6
done

echo "[w] 等探针收尾(最多 90s)"
k=0
while [ $k -lt 90 ]; do
    if A 'grep -q "探针结束" /data/local/tmp/ksu_ftrace.log 2>/dev/null'; then
        echo "[w] 探针结束(再等 ${k}s)"; break
    fi
    sleep 3
    k=$((k + 3))
done

for f in /data/local/tmp/ksu_ftrace.log /data/local/tmp/ksu_ftrace.txt /data/local/tmp/ksu_ftrace_p1.txt; do
    n=$(basename "$f")
    A "cp $f /data/local/tmp/pull_$n 2>/dev/null; chmod 666 /data/local/tmp/pull_$n 2>/dev/null"
    MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/pull_$n" "$OUT/$n" 2>&1 | tail -1
done
echo "[w] 完成，证据在 $OUT"
