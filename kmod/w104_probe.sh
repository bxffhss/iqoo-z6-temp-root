#!/system/bin/sh
# w111 探针 v2：标签全用 ASCII —— app_su.txt 落盘时 PC 侧要过一遍 tr(去掉 grep 二进制的脏字节)，
# 中文会被一起削掉，上一版因此丢了判据的名字，只剩值。(§6.111)
echo '=== who ==='; id
echo '=== creds(self-report, not exit codes) ==='
grep -aE '^(Uid|Gid|CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status
echo '=== selinux ==='; echo -n 'context='; cat /proc/self/attr/current; echo; echo -n 'getenforce='; getenforce
echo '=== read /data/system/packages.list (DAC proof) ==='
head -c 100 /data/system/packages.list 2>&1; echo
echo '=== real uid of candidate pkgs (raw lines) ==='
grep -aE '^(com.termux|com.termux.api|com.example.sniffer|com.aide.termux|com.suw.manager) ' /data/system/packages.list | cut -d' ' -f1,2
echo '=== write test (removed right after) ==='
echo w111 > /data/system/w111_probe.txt 2>&1 && echo 'write /data/system: OK' || echo 'write /data/system: FAIL'
rm -f /data/system/w111_probe.txt
echo '=== setcon: judge = context before vs after, NOT the write errno ==='
echo -n 'before='; cat /proc/self/attr/current; echo
printf 'u:r:shell:s0' > /proc/self/attr/current 2>/dev/null; echo "write errno-ish rc=$?"
echo -n 'after='; cat /proc/self/attr/current; echo
echo '=== exec sh from here (proves we can spawn a root shell) ==='
/system/bin/sh -c 'echo inner; id' 2>&1
echo '=== END ==='
