#!/system/bin/sh
# w936_capsane.sh — 一发内单变量对照：**同一条 root 腿**，翻执法前 vs 翻执法后，各读一次需要
#   capability 的动作。为什么用 dmesg：它要 CAP_SYSLOG，走 `security_capate()`→SELinux `capability` 类
#   ——而 §6.447 已经离线量到 `shell` 域在 capability 类**零条**。它没有副作用（不改挂载）。
#   ★正对照就在本窗：六分钟前同一条 `su -c dmesg` 给出 2,050,227 B（w925 C7，Permissive 段）。
#   为什么这一格值得单独量：**模块挂载要的是 CAP_SYS_ADMIN，同一条闸**——它红了，目标③ 在默认域下
#   就不是"时机问题"而是"能力问题"，而补能力只有那条策略 delta（#197/#205，要点头）。
echo "P0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
echo "P1 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
echo "P2 CapEff/CapPrv（位有没有发下来）:"
grep -a -E "CapEff|CapPrm|CapBnd|Seccomp" /proc/self/status 2>&1
echo "P3 探针一：dmesg（要 CAP_SYSLOG）——只数字节，不落文件"
# v2：原来写成 `n=$(dmesg 2>/dev/null | wc -c)` ＋下一行 `rc=$?` ⇒ rc 是 **wc** 的(永远 0)，
#      于是"读不到(EACCES)"和"读到了但是空的"同形（第 61 发之后由常驻闸 w951 抓到，见 md §6.455）。
#      现在 rc 取 dmesg 自己的，字节数分开算；★判"能不能读"只认 rc＋stderr 那行(P3b)，不认字节数。
raw=$(dmesg 2>/dev/null); rc=$?
n=$(printf '%s' "$raw" | wc -c)
echo "P3 dmesg rc=$rc bytes=$n"
echo "P3b 它的 stderr 单独看一行:"
dmesg 2>&1 >/dev/null | head -2
echo "P4 探针二：读 /proc/ksu_slots（要 MAC，不是 capability；当对照用）"
head -2 /proc/ksu_slots 2>&1
echo "P5 探针三：DAC 形状——建一个文件(本窗 Permissive 段刚成功过同样动作:root 建 w926/w928/w930 三份产物)"
echo "  stat /data/local/tmp: $(ls -ld /data/local/tmp 2>&1 | cut -d' ' -f1,3,4)"
echo "  touch 结果 rc=$(touch /data/local/tmp/w936_probe 2>&1 | head -1 | cut -c1-60)"
  rm -f /data/local/tmp/w936_probe 2>/dev/null
echo "PZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)"
