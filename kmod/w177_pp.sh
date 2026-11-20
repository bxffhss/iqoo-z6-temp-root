#!/system/bin/sh
# w177_pp.sh —— #77 的 A 段：把 policeprobe 在 **agent(@sushd 派下来的这个任务)** 上下文里跑一遍，
#   再试一次"从 agent 里 `su -c`"(它是 uid 0，未必在名单里 ⇒ 失败也是一种结论，为 #74 采样)。
# ★日志一律 `exec >>`(#72 一手：会 fork 的探针用 `>` 开日志 ⇒ 孩子与父共享 offset，互相盖字节)。
L=/data/local/tmp/w177_pp.out
exec >>"$L" 2>&1
echo "=== w177_pp 起点 up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ==="
echo "A 段起点: id=$(id) enf=$(getenforce) PATH里有su=$(command -v su || echo 无)"
echo "--- A: agent 上下文 ---"
/data/local/tmp/policeprobe agent
echo "A rc=$?"
echo "STAGE A done"
echo "--- B0: agent 里试 su -c(★uid 0 在不在名单是未定问题 #74) ---"
SUP=$(command -v su || echo /product/bin/su)
"$SUP" -c '/data/local/tmp/policeprobe sua'
echo "B0 rc=$?"
echo "STAGE B0 done"
echo "--- 收尾复量(判据读状态本身，不读日志) ---"
echo "挂载=$(grep -c product/bin /proc/mounts) su=$(ls -l /product/bin/su 2>&1 | tail -1) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ====="
