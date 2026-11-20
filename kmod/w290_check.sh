#!/system/bin/sh
# w290_check.sh —— 第 105 发(交付默认翻转后的端到端验收)的读数腿。
#   这一发**只验一件事**：`I_KNOW=1 bash kmod/go.sh`(不带 ARGS_FILE、不带我手写的任何一行 echo)
#   跑出来的窗口，执法态下 Termux 直接 `/system/bin/su -c id` 还出不出 root。
#   已知答案(§6.228 之后翻新的)：目标 = v3 `2,241,944`/`f7a441d2a7aa0445bc9c7139df4838a3`，
#   标签必须是 **plain `s0` 且不带任何类别**(第 104 发实测带类别会在执法下挡掉 execute)。
#   ★本腿不删改道目标(删了 su 就没得验)；#71 那一格改到 reboot 之后：plain s0 的 kd 应当 `adb shell rm` 就删得动。
O=/data/local/tmp/w290_check.out
exec >>"$O" 2>&1
T=/data/local/tmp/kd
echo "=== W290 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf_file=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
for p in $(pidof ksuctl); do echo "  门: pid=$p 域=$(cat /proc/$p/attr/current 2>&1)"; done
echo "STAGE1 done"

echo "  目标: $(ls -ldZ $T 2>&1 | tr -s ' ')"
echo "  已知答案: 字节=2241944 md5=f7a441d2a7aa0445bc9c7139df4838a3 标签=u:object_r:apk_data_file:s0(无类别)"
SZ=$(ls -l "$T" 2>&1 | tr -s ' ' | cut -d' ' -f5)
MD=$(md5sum "$T" 2>&1 | cut -c1-32)
[ "$SZ" = 2241944 ] && [ "$MD" = f7a441d2a7aa0445bc9c7139df4838a3 ] && echo "  ★v3 身份相符" || echo "  ★★v3 身份不符(字节=$SZ md5=$MD) ⇒ 这一发的 su 不是交付那份"
LBL=$(ls -ldZ $T 2>&1 | tr -s ' ' | awk '{for(i=1;i<=NF;i++) if($i ~ /^u:/) print $i}')
case "$LBL" in
  u:object_r:apk_data_file:s0) echo "  ★标签正：plain s0 无类别" ;;
  *) echo "  ★★标签不是 plain s0：[$LBL] ⇒ 执法下 execute 会被 MLS 挡(§6.228)" ;;
esac
echo "STAGE2 done"

echo "  dst/con 设备上读回: $(cat /data/local/tmp/ksu_redirect_dst 2>&1) / $(cat /data/local/tmp/ksu_redirect_con 2>&1)"
echo "  /data/adb 现状(只报不删)：[ $(ls /data/adb 2>&1 | tr '\n' ' ') ]"
echo "  /product/bin/su: $(ls -l /product/bin/su 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,9)"
echo "STAGE3 done"

echo "  名单: $(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | grep -a -E 'NEW_GET_ALLOW_LIST|allow\[' | tr '\n' '|')"
echo "STAGE4 done"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
