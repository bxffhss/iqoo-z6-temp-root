#!/system/bin/sh
# w232_zn_precheck.sh — 踢框架前用 @sushd 单独把 ZN daemon 起稳并验证（第三发新增的前置闸）
# ★按 w210 验证过的确切形态：cd 模块目录 + 清锁 + 从 zip 恢复 module.prop + nohup setsid
# ★同时做 cgroup 加固（迁出 /apps/*），让这个 daemon 能活过之后的 framework 重建，
#   总控 start_zn 看到它已存在就跳过、zn_gate 直接过 ⇒ 不需要重起。
OUT=/data/local/tmp/w232_zn_precheck.out
exec >"$OUT" 2>&1
M=/data/adb/modules/zygisksu
ZD=$M/bin/zygiskd
ZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'
S=/system/bin/setsid
T=/system/bin/timeout
U=/system/bin/unzip

echo "ts=$(date +%Y-%m-%dT%H:%M:%S) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce)"

echo "########## [1] cgroup 加固（与总控一致） ##########"
mkdir -p /sys/fs/cgroup/z6stage 2>/dev/null
echo $$ > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null && echo "CG_V2_OK" || echo "CG_V2_FAIL"
echo $$ > /dev/memcg/cgroup.procs 2>/dev/null && echo "CG_MEM_OK" || echo "CG_MEM_FAIL"
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
echo "cgroup2=[$(cat /proc/self/cgroup 2>/dev/null | tail -1)] oom=$(cat /proc/self/oom_score_adj 2>/dev/null)"

echo "########## [2] 清锁 + 恢复 module.prop（verify1） ##########"
rm -f /data/adb/zygisksu/.injecting /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/znctx /data/adb/zygisksu/modules_info
"$U" -o "$ZIP" 'module.prop' -d "$M" >/dev/null 2>&1
echo "module.prop hash=$(sha256sum "$M/module.prop" | awk '{print $1}')"
echo "locks=[$(ls -a /data/adb/zygisksu 2>&1 | tr '\n' ' ')]"
echo "files=$(find "$M" -type f | wc -l)"

echo "########## [3] 起 ZN daemon（w210 形态：cd 模块目录 + nohup + setsid） ##########"
: > /data/local/tmp/w232_zn.log; chmod 666 /data/local/tmp/w232_zn.log
( cd "$M" && nohup "$S" "$ZD" daemon >/data/local/tmp/w232_zn.log 2>&1 </dev/null & )
echo "SPAWN_RC=$?"
sleep 7
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'zn-daemon|zygiskd' | head -10
echo "--- daemon log ---"; cat /data/local/tmp/w232_zn.log 2>&1 | head -20
echo "--- status ---"
"$T" 8 "$ZD" status 2>&1; echo "STATUS_RC=$?"
echo "--- module.prop description ---"; grep -a '^description=' "$M/module.prop" 2>&1
echo "--- 状态目录 ---"; ls -la /data/adb/zygisksu/ 2>&1
echo "--- daemon cgroup ---"
for p in $(pidof zn-daemon 2>/dev/null); do echo "pid=$p cgroup2=[$(cat /proc/$p/cgroup 2>/dev/null | tail -1)] oom=$(cat /proc/$p/oom_score_adj 2>/dev/null)"; done

echo "########## [4] 闸判定（★第三发新增 root_status 硬 gate） ##########"
P=$(pidof zn-daemon 2>/dev/null)
ST=$("$T" 8 "$ZD" status 2>&1)
echo "status_full=[$(echo "$ST" | grep -aE 'version:|inject_state|zygote_states|root_status|root_impl|modules' | tr '\n' ' ')]"
# ★第三发根因：inject_state:1 但 root_status:❌None ⇒ 注入实际不会发生（GetRootImpl permission denied）
#   必须在起 daemon 之前就补好 /data/adb/ksud，ZN 才会判成 ✅KernelSU
if [ -n "$P" ] && echo "$ST" | grep -aq 'inject_state:1' && echo "$ST" | grep -aq 'root_status:✅'; then
  echo "ZGATE=PASS zn-daemon=[$P] inject_state:1 root_status:✅"
else
  echo "ZGATE=FAIL zn-daemon=[$P]"
  echo "  若 root_status=❌None ⇒ 检查 /data/adb/ksud 是否在 daemon 启动**之前**就补好；"
  echo "  修复顺序：adb push kmod/ksud_official /data/local/tmp/w234_ksud → 补 ksud → kill 旧 daemon → 重跑本脚本"
fi
echo "===== DONE"
