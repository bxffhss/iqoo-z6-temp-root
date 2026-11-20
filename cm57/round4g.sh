#!/bin/bash
# round4g.sh — "外部 .ko 能否加载"判定轮的**带重启重试循环**(round4.sh 那轮死在相1)
# 每轮: reboot → 等 load1<6 → 只解 slide → 推 pr/mod/脚本 → ishell 喂 mod_probe.sh
#       → 回读设备端 mod_probe.log(★判据只认设备端日志里的 [INS] 行, 不认 adb stdout)
# 命中即停; 最多 MAX 轮。日志一律 round4b_rN* 新名字, 不覆盖历史证据。
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
ADB="C:/adb/platform-tools/adb.exe"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
CL="J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"
MAX=${1:-3}

wait_load() {
  for i in $(seq 1 30); do
    l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    ip=${l%%.*}; [ -n "$ip" ] || ip=9
    echo "[g] load1=$l (门槛 <6)"
    [ "$ip" -lt 6 ] && return 0
    sleep 15
  done
  return 1
}

echo "[g] === 编译(一次就够) ==="
"$CL" -O2 -static -Wall -o cm57/modbin cm57/mod.c || exit 1
"$CL" -O2 -g0 -fPIE -pie -pthread -Wall -Wno-unused-parameter -Wno-unused-function \
      -o cm57/prbin cm57/pr.c || exit 1

for r in $(seq 1 "$MAX"); do
  echo "[g] ########## 第 $r/$MAX 轮 ########## $(date +%H:%M:%S)"
  HL=cm57/round4b_r${r}_host.log
  {
    if [ "$r" = 1 ] && [ "$(A shell 'uname -s' 2>/dev/null | tr -d '\r')" = "Linux" ] \
       && [ "$(A shell 'getenforce' 2>/dev/null | tr -d '\r')" = "Enforcing" ]; then
      echo "[g] 第 1 轮: 当前 boot 干净(未 punch + enforcing)⇒ 跳过 reboot, 省 4 分钟"
    else
      echo "[g] reboot"
      A reboot || exit 1
      A wait-for-device || exit 1
      for i in $(seq 1 40); do
        o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
        case "$o" in *Enforcing*|*Permissive*) break ;; esac
        sleep 5
      done
    fi
    echo "[g] shell 可用: $o  uname=[$(A shell 'uname -s' | tr -d '\r')]"
    wait_load || { echo "[g] 负载不落定, 停"; exit 2; }

    echo "[g] 解 slide"
    python cm57/solve_only.py 30 > cm57/round4b_r${r}_solve.log 2>&1
    S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/round4b_r${r}_solve.log | awk '{print $2}')
    echo "[g] slide=$S"
    if [ -z "$S" ] || [ "$S" = "NONE" ]; then echo "[g] 没解出 slide, 重来"; continue; fi
    # 采样会抬负载, 打之前再等一次
    for i in $(seq 1 10); do
      l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
      ip=${l%%.*}; [ -n "$ip" ] || ip=9
      [ "$ip" -lt 6 ] && break
      echo "[g] 采样抬高负载(load1=$l), 再等"; sleep 15
    done
    U=$(A shell "uname -s" 2>/dev/null | tr -d '\r')
    echo "[g] 打之前 uname=[$U] (必须 Linux)"
    [ "$U" = "Linux" ] || { echo "[g] boot 不干净, 重来"; continue; }

    A push cm57/prbin /data/local/tmp/pr > /dev/null || exit 1
    A push cm57/modbin /data/local/tmp/mod > /dev/null || exit 1
    A push cm57/mod_probe.sh /data/local/tmp/mod_probe.sh > /dev/null || exit 1
    A shell "chmod 755 /data/local/tmp/pr /data/local/tmp/mod /data/local/tmp/mod_probe.sh; rm -f /data/local/tmp/pr.log /data/local/tmp/mod_probe.log /data/local/tmp/cands.txt /data/local/tmp/loaded.txt"
    echo "[g] dev md5: $(A shell 'md5sum /data/local/tmp/pr /data/local/tmp/mod' | tr -d '\r' | tr '\n' ' ')"

    printf 'echo FED_LINE_OK; sh /data/local/tmp/mod_probe.sh; echo PROBE_EXIT=$?; exit\n' | \
      A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
      > cm57/round4b_r${r}_run.log 2>&1
    echo "[g] ishell rc=$? (255 常意味着炸了, 以设备端日志为准)"

    A wait-for-device || exit 1
    sleep 8
    A shell "cat /data/local/tmp/mod_probe.log" > cm57/round4b_r${r}_dev_mod.log 2>&1
    A shell "cat /data/local/tmp/pr.log" > cm57/round4b_r${r}_dev_pr.log 2>&1
    echo "[g] 现场: $(A shell 'cat /proc/uptime; getenforce' | tr -d '\r' | tr '\n' ' ')"
    echo "[g] dev_mod.log 行数=$(wc -l < cm57/round4b_r${r}_dev_mod.log)  FED=$(grep -ac FED_LINE_OK cm57/round4b_r${r}_run.log 2>/dev/null)"
    if grep -a '\[INS\]' cm57/round4b_r${r}_dev_mod.log > /dev/null 2>&1; then
      echo "[g] ★★★ 拿到判定结果, 停(第 $r 轮) ★★★"
      A pull /data/local/tmp/vend_try.ko cm57/vend_try.ko > /dev/null 2>&1
      A pull /data/local/tmp/vend_loaded.ko cm57/vend_loaded.ko > /dev/null 2>&1
      A pull /data/local/tmp/cands.txt cm57/round4b_cands.txt > /dev/null 2>&1
      break
    fi
    echo "[g] 第 $r 轮没拿到 mod_probe 判定(见 round4b_r${r}_dev_pr.log 末尾)"
    tail -6 cm57/round4b_r${r}_dev_pr.log | tr -d '\r'
  } 2>&1 | tee "$HL"
done
echo "[g] 全部结束"
