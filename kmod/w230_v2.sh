#!/system/bin/sh
# w230_v2.sh —— 把改道目标换成 **v2 shim**(会扫 /proc/self/fd 的那份)。
#   一手事实：这一发 /data/local/tmp/ksud 还是旧的 2,234,336(v1, push_ksu 走的是"已是最新"分支)，
#     而 stage 把那份旧的就照着复制成了 kd2 ⇒ 判据要的"扫到驱动 fd"根本不会发生(§6.221 用的是 2,245,720)。
#   v2 的真身在 /data/local/tmp/sustatic(go.sh 第 5 步推的，bind 那份 SU_AT_TGT 字节数=2245720 就是它)。
#   ★不重载模块：sucompat 每次命中都现场 filp_open(ksu_ksud_path)，换文件内容不用重新 insmod。
O=/data/local/tmp/w230_v2.out
exec >>"$O" 2>&1
T=/data/data/com.termux/files/usr/bin/kd2
echo "=== W230V2 up=$(cut -d' ' -f1 /proc/uptime) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
echo "  换之前: $(ls -l $T 2>&1 | tr -s ' ' | cut -d' ' -f3,5)  md5=$(md5sum $T 2>&1 | cut -c1-32)"
echo "  v2 源:  $(ls -l /data/local/tmp/sustatic 2>&1 | tr -s ' ' | cut -d' ' -f3,5)  md5=$(md5sum /data/local/tmp/sustatic 2>&1 | cut -c1-32)"
echo "  已知答案: v2 应当是 2245720 字节 / md5 9aca0a3ed9ffea1059ec127e3e1f1e9b"
cp /data/local/tmp/sustatic "$T"; echo "  cp rc=$?"
chmod 755 "$T"; chown 10667:10667 "$T" 2>/dev/null; echo "  chown/chmod rc=$?"
echo "  换之后: $(ls -lZ $T 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,6,9)  md5=$(md5sum $T 2>&1 | cut -c1-32)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
