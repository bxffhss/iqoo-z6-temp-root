#!/bin/bash
# shot13_isolation_probe.sh —— 第 13 发空枪(开窗层 punch flaky)后的 0 枪隔离探针。
# 目的：重打 go.sh 之前，先以"不开窗、不 insmod"的代价排除 adb 不稳 / 推件链路坏 / 残留进程锁 / boot 不稳。
# 依据：§6.566（不拿 go.sh 反复撞设备）、§6.573（空枪根因=punch 成+pr 不退出+post 回调没跑）。
# 安全：本脚本全程只读 + push 文件（不 insmod、不 punch、不 reboot）；推件用 rc80+0x1a 与重打那发逐字同形，
#       但只落在设备 /data/local/tmp，go.sh 重跑会重推覆盖，PC 侧 kmod/ksu_args.txt 仍是稳定 0x0（已复原）。
set -u
export PATH="/c/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:$PATH"
unset BASH_ENV; unset -f 'BASH_FUNC_rm%%' 'BASH_FUNC_unlink%%' 'BASH_FUNC_rmdir%%' 2>/dev/null; unset PYTHONPATH
cd "$(dirname "$0")/../.." || exit 1

A="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
S() { $A shell "$@" 2>&1; }
BID() { $A shell 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r'; }

BAD=0
echo "=== 0-gun isolation probe $(date '+%H:%M:%S') ==="
BID0=$(BID); UPT0=$(S 'cut -d" " -f1 /proc/uptime' | tr -d '\r')
MOD0=$(S 'grep -c kernelsu /proc/modules' | tr -d '\r')
echo "  boot_id=$BID0  up=$UPT0  mod=$MOD0  (基线)"

echo "=== 1. 40 连发 adb ping，记失败与抖动 ==="
TLO=0 THI=0
for i in $(seq 1 40); do
  T0=$(date +%s%3N)
  R=$(S 'echo -n PING; cat /proc/sys/kernel/random/boot_id' 2>&1 | tr -d '\r')
  T1=$(date +%s%3N)
  DT=$((T1-T0))
  [ "$DT" -lt "$TLO" ] || TLO=$DT; [ "$DT" -gt "$THI" ] || THI=$DT
  if [ -z "$R" ] || [ "${R#PING}" = "$R" ]; then
    echo "  [#$i] FAIL: [$R]"; BAD=$((BAD+1))
  fi
  sleep 0.2
done
echo "  ping 完成: 失败=$BAD  最小/最大往返=${TLO}/${THI}ms"

echo "=== 2. 残留进程锁（空枪后必须干净） ==="
PR=$(S 'pidof pr' | tr -d '\r'); SHD=$(S 'pidof shd' | tr -d '\r'); SUW=$(S 'pidof com.suw.manager' | tr -d '\r')
echo "  pr=[$PR] shd=[$SHD] suw=[$SUW]"
[ -n "$PR" ] && { echo "  [!] pr 残留 ⇒ 上发 punch 没收净"; BAD=$((BAD+1)); }
[ -n "$SHD" ] && { echo "  [!] shd 残留"; BAD=$((BAD+1)); }

echo "=== 3. 推件链路（rc80 + 0x1a，与重打逐字同形，安全不开窗） ==="
KO=kmod/kernelsu_rc80.ko ARGS=kmod/ksu_args.txt.community_0x1a bash kmod/push_ksu.sh > kmod/w103_evidence/shot13_probe_push.log 2>&1
PRC=$?
echo "  push_ksu.sh rc=$PRC"
# push 脚本内部已逐件 md5 对表，失败会 exit 1；这里再核关键两件
L_KO=$(md5sum kmod/kernelsu_rc80.ko | cut -d' ' -f1)
R_KO=$(S 'md5sum /data/local/tmp/kernelsu.ko' | cut -d' ' -f1 | tr -d '\r')
L_AR=$(md5sum kmod/ksu_args.txt.community_0x1a | cut -d' ' -f1)
R_AR=$(S 'md5sum /data/local/tmp/ksu_args.txt' | cut -d' ' -f1 | tr -d '\r')
echo "  ko: 本地=$L_KO 设备=$R_KO $([ "$L_KO" = "$R_KO" ] && echo OK || echo MISMATCH)"
echo "  args: 本地=$L_AR 设备=$R_AR $([ "$L_AR" = "$R_AR" ] && echo OK || echo MISMATCH)"
[ "$L_KO" = "$R_KO" ] || BAD=$((BAD+1))
[ "$L_AR" = "$R_AR" ] || BAD=$((BAD+1))
[ "$PRC" = "0" ] || BAD=$((BAD+1))

echo "=== 4. 探针末读：boot_id 是否变了 / 是否误装载 ==="
BID1=$(BID); MOD1=$(S 'grep -c kernelsu /proc/modules' | tr -d '\r'); UPT1=$(S 'cut -d" " -f1 /proc/uptime' | tr -d '\r')
echo "  boot_id=$BID1 (基线=$BID0)  up=$UPT1 (基线=$UPT0)  mod=$MOD1"
[ "$BID1" = "$BID0" ] || { echo "  [!] boot_id 变了 ⇒ 设备被探针意外重启"; BAD=$((BAD+1)); }
[ "$MOD1" = "0" ] || { echo "  [!] mod≠0 ⇒ 探针误装载了 ko"; BAD=$((BAD+1)); }

echo "=== 5. 闸门 ==="
if [ "$BAD" = "0" ]; then
  echo "PROBE_RC=0  BAD_TOTAL=0  ⇒ 允许重打 go.sh"
else
  echo "PROBE_RC=1  BAD_TOTAL=$BAD  ⇒ 禁止重打，先排查"
fi
exit $BAD
