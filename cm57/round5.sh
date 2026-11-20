#!/bin/bash
# round5.sh — 外部 .ko 准入判定的**决定性一轮**(靶子 = /vendor/lib/modules/e4000.ko, 与本机内核逐条 CRC 吻合)
# 每轮: reboot → 等 load1<6 → 解 slide → 推 pr/mod/脚本/3 个 .ko → ishell 喂 mod_probe2.sh
#       → 以设备端 mod_probe.log 里的 [INS] 行为准(不认 adb stdout)
# 日志一律 round5_rN* 新名字。用法: bash cm57/round5.sh [最大轮数, 默认 3]
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
ADB="C:/adb/platform-tools/adb.exe"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
CL="J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"
MAX=${1:-3}
o=""

wait_load() {
  for i in $(seq 1 30); do
    l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    ip=${l%%.*}; [ -n "$ip" ] || ip=9
    echo "[5] load1=$l (门槛 <6)"
    [ "$ip" -lt 6 ] && return 0
    sleep 15
  done
  return 1
}

echo "[5] 编译 $(date +%H:%M:%S)"
"$CL" -O2 -static -Wall -o cm57/modbin cm57/mod.c || exit 1
"$CL" -O2 -g0 -fPIE -pie -pthread -Wall -Wno-unused-parameter -Wno-unused-function \
      -o cm57/prbin cm57/pr.c || exit 1
echo "[5] 编译完成"

for r in $(seq 1 "$MAX"); do
  echo "[5] ########## 第 $r/$MAX 轮 ########## $(date +%H:%M:%S)"
  {
    A reboot || exit 1
    A wait-for-device || exit 1
    for i in $(seq 1 40); do
      o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
      case "$o" in *Enforcing*|*Permissive*) break ;; esac
      sleep 5
    done
    echo "[5] shell 可用: $o uname=[$(A shell 'uname -s' | tr -d '\r')]"
    wait_load || { echo "[5] 负载不落定, 停"; exit 2; }

    python cm57/solve_only.py 30 > cm57/round5_r${r}_solve.log 2>&1
    S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/round5_r${r}_solve.log | awk '{print $2}')
    echo "[5] slide=$S"
    if [ -z "$S" ] || [ "$S" = "NONE" ]; then echo "[5] 没解出 slide, 重来"; continue; fi
    wait_load || { echo "[5] 采样后负载没回落, 停"; exit 2; }
    U=$(A shell "uname -s" 2>/dev/null | tr -d '\r')
    echo "[5] 打之前 uname=[$U]"
    [ "$U" = "Linux" ] || { echo "[5] boot 不干净, 重来"; continue; }

    A push cm57/prbin /data/local/tmp/pr > /dev/null || exit 1
    A push cm57/modbin /data/local/tmp/mod > /dev/null || exit 1
    A push cm57/mod_probe2.sh /data/local/tmp/mod_probe.sh > /dev/null || exit 1
    A push cm57/t_e4000.ko    /data/local/tmp/t_e4000.ko    > /dev/null || exit 1
    A push cm57/t_e4000_bad.ko  /data/local/tmp/t_e4000_bad.ko  > /dev/null || exit 1
    A push cm57/t_e4000_bad2.ko /data/local/tmp/t_e4000_bad2.ko > /dev/null || exit 1
    A shell "chmod 755 /data/local/tmp/pr /data/local/tmp/mod /data/local/tmp/mod_probe.sh; chmod 644 /data/local/tmp/t_e4000*.ko; rm -f /data/local/tmp/pr.log /data/local/tmp/mod_probe.log"
    echo "[5] 推送核对 dev=$(A shell 'md5sum /data/local/tmp/t_e4000.ko /data/local/tmp/t_e4000_bad2.ko /data/local/tmp/mod' | tr -d '\r' | tr '\n' ' ')"

    printf 'echo FED_LINE_OK; sh /data/local/tmp/mod_probe.sh; echo PROBE_EXIT=$?; exit\n' | \
      A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
      > cm57/round5_r${r}_run.log 2>&1
    echo "[5] ishell rc=$?"

    A wait-for-device || exit 1
    sleep 8
    A shell "cat /data/local/tmp/mod_probe.log" > cm57/round5_r${r}_dev_mod.log 2>&1
    A shell "cat /data/local/tmp/pr.log" > cm57/round5_r${r}_dev_pr.log 2>&1
    echo "[5] 现场: $(A shell 'cat /proc/uptime; getenforce' | tr -d '\r' | tr '\n' ' ')"
    echo "[5] dev_mod 行数=$(wc -l < cm57/round5_r${r}_dev_mod.log) INS行数=$(grep -ac '\[INS\]' cm57/round5_r${r}_dev_mod.log)"
    if grep -a 'P1 原样加载' cm57/round5_r${r}_dev_mod.log > /dev/null 2>&1; then
      echo "[5] ★★★ 判定到手(第 $r 轮), 停 ★★★"
      A pull /data/local/tmp/mod_probe.log cm57/round5_r${r}_mod_probe_dev.log >/dev/null 2>&1
      break
    fi
    echo "[5] 第 $r 轮未到判定; pr.log 末尾:"
    tail -5 cm57/round5_r${r}_dev_pr.log | tr -d '\r'
  } 2>&1 | tee "cm57/round5_r${r}_host.log"
done
echo "[5] 全部结束 $(date +%H:%M:%S)"
