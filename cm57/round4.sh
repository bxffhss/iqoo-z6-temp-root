#!/bin/bash
# round4.sh — 判定"外部 .ko 能否加载"的那一轮(**不重启**, 用当前干净 boot)
# 流程: 前置检查(uname -s 必须仍是 Linux / load1<6) → 只解 slide 不 punch
#       → 编译并推 pr+mod+脚本 → ishell 里喂 mod_probe.sh → 回读日志 + pull 两份厂商 .ko
# 日志一律新名字(round4_*), 不覆盖历史证据文件。
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
ADB="C:/adb/platform-tools/adb.exe"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
CL="J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"

wait_load() {  # 等 load1 < 6, 返回 0=合格
  for i in $(seq 1 20); do
    l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    ip=${l%%.*}; [ -n "$ip" ] || ip=9
    echo "[r4] load1=$l (门槛 <6)"
    [ "$ip" -lt 6 ] && return 0
    sleep 15
  done
  return 1
}

echo "[r4] === 0) 前置检查 ==="
A wait-for-device || exit 1
U=$(A shell "uname -s" 2>/dev/null | tr -d '\r')
echo "[r4] uname -s = [$U] (必须逐字 Linux, 否则本 boot 已 punch 过)"
[ "$U" = "Linux" ] || { echo "[r4] 这个 boot 不干净, 停(不猜)"; exit 2; }
echo "[r4] getenforce=$(A shell "getenforce" | tr -d '\r') uptime=$(A shell "cat /proc/uptime" | tr -d '\r')"
wait_load || { echo "[r4] 负载不落定, 停"; exit 2; }

echo "[r4] === 1) 只解 slide(采样不 punch) ==="
python cm57/solve_only.py 30 > cm57/round4_solve.log 2>&1
S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/round4_solve.log | awk '{print $2}')
echo "[r4] slide=$S"
if [ -z "$S" ] || [ "$S" = "NONE" ]; then echo "[r4] 没解出 slide, 停"; tail -20 cm57/round4_solve.log; exit 2; fi
wait_load || { echo "[r4] 采样把负载抬起来了且没回落, 停"; exit 2; }

echo "[r4] === 2) 编译 mod + pr ==="
"$CL" -O2 -static -Wall -o cm57/modbin cm57/mod.c || { echo "[r4] mod 编译失败"; exit 1; }
"$CL" -O2 -g0 -fPIE -pie -pthread -Wall -Wno-unused-parameter -Wno-unused-function \
      -o cm57/prbin cm57/pr.c || { echo "[r4] pr 编译失败"; exit 1; }
ls -l cm57/modbin cm57/prbin

echo "[r4] === 3) 推送 + chmod + md5 双向核对 ==="
A push cm57/prbin  /data/local/tmp/pr  > /dev/null || exit 1
A push cm57/modbin /data/local/tmp/mod > /dev/null || exit 1
A push cm57/mod_probe.sh /data/local/tmp/mod_probe.sh > /dev/null || exit 1
A shell "chmod 755 /data/local/tmp/pr /data/local/tmp/mod /data/local/tmp/mod_probe.sh; rm -f /data/local/tmp/pr.log /data/local/tmp/mod_probe.log"
echo "[r4] host md5:"; md5sum cm57/prbin cm57/modbin cm57/mod_probe.sh
echo "[r4] dev md5:"; A shell "md5sum /data/local/tmp/pr /data/local/tmp/mod /data/local/tmp/mod_probe.sh" | tr -d '\r'

echo "[r4] === 4) 开打: ishell + 喂 mod_probe.sh ==="
echo "[r4] 打之前 uname -s = [$(A shell 'uname -s' | tr -d '\r')]"
printf 'sh /data/local/tmp/mod_probe.sh; exit\n' | \
  A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
  > cm57/round4_run.log 2>&1
echo "[r4] ishell 轮次 rc=$?"

echo "[r4] === 5) 回读 ==="
A shell "cat /data/local/tmp/mod_probe.log" > cm57/round4_dev_mod.log 2>&1
A shell "cat /data/local/tmp/pr.log"        > cm57/round4_dev_pr.log  2>&1
A pull /data/local/tmp/vend_try.ko    cm57/vend_try.ko    > /dev/null 2>&1 && echo "[r4] pulled vend_try.ko"
A pull /data/local/tmp/vend_loaded.ko cm57/vend_loaded.ko > /dev/null 2>&1 && echo "[r4] pulled vend_loaded.ko"
echo "[r4] 现场: $(A shell "cat /proc/uptime; getenforce; lsmod 2>/dev/null | wc -l" | tr -d '\r' | tr '\n' ' ')"
ls -l cm57/round4_dev_mod.log cm57/round4_dev_pr.log cm57/vend_try.ko cm57/vend_loaded.ko 2>/dev/null
echo "[r4] 完成"
