#!/system/bin/sh
# w925_appleg.sh — #209 close-out matrix (host = run-as com.termux, uid 10667, Permissive).
#上一发 w924 把手性翻过来了：/system/bin/su 这条路径由 /system/bin/sh(mksh) 直写=rc=127、
# 由 env 执行=出 root。差别只在"调用者在 execve 之前有没有自己 stat 过一次"：
# /system/bin/su 这个文件在本机不存在(全靠 ko 改道)，而 Android 的 mksh 会先 stat 再 execve，
# ENOENT 就直接报 inaccessible or not found，execve 根本没发生(所以环里不会有 SU0)。
# 这一发要拿的三格：
#   C4 = 子 shell(Android mksh) exec 一条**存在的** su 路径 ⇒ 若出 root，机制定案
#   C5 = PATH 搜索下的裸 su ⇒ 交付上"任意 app 能不能拿到 su"的真实答案
#   C7/C8 = 用 env 那条已经通的通道把整环捞出来，和 w924 A3(env) 的 up=3025.81 成对
HA=/data/data/com.termux/files/home
A=$HA/w925.out
R=$HA/w925_ring.txt
U() { cut -d' ' -f1 /proc/uptime; }

{
  echo "H0 date=$(date) up=$(U)"
  echo "H1 id=[$(id -u)] ctx=[$(cat /proc/self/attr/current 2>&1)] seccomp=$(grep -a Seccomp: /proc/self/status | tr -d ' ')"
  echo "H2 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "H3 PATH=$PATH"
  echo "H4 fd_ksu_self=$(ls -l /proc/self/fd 2>/dev/null | grep -ac ksu_driver)"
} > $A 2>&1

echo "C1_BEGIN su file identity up=$(U)" >> $A 2>&1
/system/bin/ls -l /data/local/tmp/kd /product/bin/su >> $A 2>&1
/system/bin/md5sum /data/local/tmp/kd /product/bin/su >> $A 2>&1
echo "C1 rc=$?" >> $A 2>&1

echo "C3_BEGIN direct exec existing su path up=$(U)" >> $A 2>&1
/product/bin/su -c id >> $A 2>&1
echo "C3 rc=$? up=$(U)" >> $A 2>&1

echo "C4_BEGIN child Android-mksh exec existing su path up=$(U)" >> $A 2>&1
/system/bin/sh -c '/product/bin/su -c id' >> $A 2>&1
echo "C4 rc=$? up=$(U)" >> $A 2>&1

echo "C5_BEGIN PATH lookup bare su from Android mksh up=$(U)" >> $A 2>&1
/system/bin/sh -c 'su -c id' >> $A 2>&1
echo "C5 rc=$? up=$(U)" >> $A 2>&1

echo "C6_BEGIN env exec the nonexistent path (改道正对照) up=$(U)" >> $A 2>&1
/system/bin/env /system/bin/su -c id >> $A 2>&1
echo "C6 rc=$? up=$(U)" >> $A 2>&1

echo "C7_BEGIN ring via env+su, single-word -c up=$(U)" >> $A 2>&1
/system/bin/env /system/bin/su -c dmesg > $R 2>> $A
echo "C7 rc=$? ring_bytes=$(/system/bin/ls -l $R 2>/dev/null | /system/bin/awk '{print $5}')" >> $A 2>&1

echo "C8_BEGIN ring slice around w924 A3 (up 3025) and this run (up 30..) up=$(U)" >> $A 2>&1
/system/bin/grep -aE "KSUBEAT (SU0|SD3|SD5|SU4)" $R 2>&1 | /system/bin/grep -aE "\[ *30(2[0-9]|3[0-9])\." >> $A 2>&1
echo "C8 done up=$(U)" >> $A 2>&1

echo "C9_BEGIN stat visible to a child mksh up=$(U)" >> $A 2>&1
/system/bin/sh -c '/system/bin/ls -l /system/bin/su; echo inner_rc=$?' >> $A 2>&1
echo "C9 rc=$? up=$(U)" >> $A 2>&1

echo "BZ_END date=$(date) up=$(U)" >> $A 2>&1
