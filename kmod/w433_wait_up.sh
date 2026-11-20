#!/bin/bash
# w433_wait_up.sh —— 等到设备 up≥N 秒，并按需拉起 com.suw.manager。
#   为什么要有它（§6.606）：punch 落在 up≤377 时必卡在 pr 的 SLA「子进程扫描」相
#   （7/7 成功的 punch 都在 up≥1076）。go.sh 的 `load1≤3` 闸在快启动的 boot 上过早放行 ⇒
#   必须另加一道「开机时长」闸。本件只读设备 + am start（不动内核、不碰 go.sh）。
#   用法：bash kmod/w433_wait_up.sh 1150 [--start-suw]
#   ★v2 修正：v1 在设备重启窗口里把 `adb` 的错误串当成读数（mod=104225003 误判脏 boot 直接退出）
#     ⇒ 现在一次 adb 取三元组，**up 不是纯数字就只当"还没起"**，continue 重试。
export PATH="/c/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/c/K/Python3:$PATH"
set -u
ADB=C:/adb/platform-tools/adb.exe
DEV=<DEVICE_SERIAL>
NEED=${1:-1150}
SUW=0
[ "${2:-}" = "--start-suw" ] && SUW=1
A() { "$ADB" -s "$DEV" shell "$1" 2>&1 | tr -d '\r'; }
i=0
while [ "$i" -lt 300 ]; do
    ST=$(A 'echo "UP=$(cut -d" " -f1 /proc/uptime|cut -d. -f1) MOD=$(grep -c "^kernelsu " /proc/modules) ENF=$(getenforce)"' | tr -d '\n')
    UP=$(printf '%s' "$ST" | sed -n 's/.*UP=\([0-9]*\).*/\1/p')
    MOD=$(printf '%s' "$ST" | sed -n 's/.*MOD=\([0-9]*\).*/\1/p')
    ENF=$(printf '%s' "$ST" | sed -n 's/.*ENF=\([A-Za-z]*\).*/\1/p')
    case "$UP" in
        ''|*[!0-9]*) echo "  [$i] 还没起来(设备不在线)，等 15s"; sleep 15; i=$((i+1)); continue;;
    esac
    echo "  [$i] up=$UP need=$NEED mod=${MOD:-?} enf=${ENF:-?}"
    if [ "${MOD:-0}" != "0" ]; then echo "[x] 当前 boot 已经有 kernelsu ⇒ 脏 boot，停"; exit 3; fi
    if [ "$UP" -ge "$NEED" ]; then
        echo "[OK] up=$UP ≥ $NEED 已达"
        if [ "$SUW" = 1 ]; then
            A 'am start -n com.suw.manager/.MainActivity' | head -2
            sleep 6
            echo "  suw=[$(A 'pidof com.suw.manager' | tr -s ' ')]  enf=$(A getenforce) up=$(A 'cut -d" " -f1 /proc/uptime')"
        fi
        exit 0
    fi
    sleep 20; i=$((i+1))
done
echo "[x] 等满 $i 轮仍未到 up≥$NEED"; exit 4
