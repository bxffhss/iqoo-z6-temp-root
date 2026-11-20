#!/system/bin/sh
# w347_rc69_probe_dev.sh —— 第 116 发(rc69)的一手读数，**只读**。
#
# 为什么这一版的判据比第 115 发强：rc69 把 `SX` 块搬到了 `SD1` **上游** ⇒
#   ①有 `SX2` 行              ⇒ escape 真发生了(摘 seccomp/换 cred)，接下去看 Seccomp=0 与模块页；
#   ②没有 SX2，但有 `SD1 decline: uid=10104` ⇒ **execve 进来了这个 hook**，只是尾串/uid 闸没过(那就是参数或路径文本的问题)；
#   ③两样都没有               ⇒ Manager 那次 execve **根本没进 hook**(问题在钩子覆盖范围，不在我的块)。
#   第 115 发分不清这三格，是因为那时 ② 是"设计如此"；现在 ② 是有信息量的。
# ★所以必须**先读一次(基线)→点页面→再读一次**，两次的差值才算数(事后 grep 大缓冲会把 ①② 挤掉，§6.251 就是这么丢的)。
#
# 用法：sh /data/local/tmp/w347_rc69_probe_dev.sh <标签>      # 以 root 跑
# ★OUT 用**固定名**：suw 的 root 腿(`w211_ui.sh rleg`)只能传脚本名、传不进参数 ⇒ 如果 OUT 里带 $TAG，
#   "基线/点完再读"两次会写到**同一个默认文件**，本地第二次 pull 的是不存在的名字 ⇒ 差值判据整个废掉。
#   分次存证由**调用方**在 pull 时加后缀(见 w348_rc69_window.sh 的 leg())。
OUT=/data/local/tmp/w347_rc69.out
TAG=${1:-n/a}
exec > "$OUT" 2>&1
UP=$(cut -d' ' -f1 /proc/uptime)
echo "[$(date +%H:%M:%S)] tag=$TAG uid=$(id -u) enf=$(getenforce) up=$UP"

echo "--- A) SX2 命中(期望：点过模块页之后 >=1) ---"
DM=$(dmesg 2>/dev/null)
echo "$DM" | grep -a 'SX2 selfexec-pre' | tail -5
echo "SX2_COUNT=$(echo "$DM" | grep -a -c 'SX2 selfexec-pre')"

echo "--- B) Manager(10104) 的 execve 有没有进到 hook：看 SD1 decline 里带 uid=10104 的行 ---"
echo "$DM" | grep -a 'KSUBEAT SD1 decline' | grep -a 'uid=10104' | tail -4
echo "SD1_UID10104=$(echo "$DM" | grep -a 'KSUBEAT SD1 decline' | grep -a -c 'uid=10104')"
echo "SD1_ALL(噪声，只作参照)=$(echo "$DM" | grep -a -c 'KSUBEAT SD1 decline')"

echo "--- C) 有没有'进来了但尾串不中'的迹象(尾串/参数值回显) ---"
echo "$DM" | grep -a 'KSUBEAT SU2\|KSUBEAT SD2 decline\|KSUBEAT SD5 do_orig_execve' | tail -4

echo "--- D) Manager 进程状态(期望 Seccomp 命中后 2 -> 0) ---"
for P in $(pidof me.weishu.kernelsu); do
    echo "pid=$P"
    grep -E '^(Uid|NoNewPrivs|Seccomp|CapEff)' /proc/$P/status 2>&1 | tr '\n' ' '; echo
done

echo "--- E) ksud 动词 + 有没有崩(logcat 只读；按包名剔掉 suw 自己的 crown 崩溃) ---"
logcat -d -s KernelSU 2>/dev/null | grep -a 'ksud::cli' | tail -6
logcat -d -b crash 2>/dev/null | grep -a -i 'libksud\|me.weishu' | tail -4

echo "--- F) ★样本模块的存活读数(mtime + 目录还在不在) ---"
echo "modules 目录=[$(ls /data/adb/modules 2>&1 | tr '\n' ' ')]"
# ★用 stat -c 而不是 `ls --time-style`：本机 toybox 的 ls 不一定带那个选项(报错了这条读数就废了)
stat -c '  %y|%s|%n' /data/adb/modules/suwmarker /data/adb/modules/suwmarker/module.prop 2>&1
echo "现在 up=$UP(记下两次的差值与时刻，别只说'在/不在')"
echo "[===== DONE =====]"
