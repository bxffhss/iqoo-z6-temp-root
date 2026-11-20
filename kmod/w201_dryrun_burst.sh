#!/system/bin/sh
# 一次性干跑：造一把已知的 "comm=sh" 增量，验 w201 的触发器与谱系抓得到东西(例 51/53)。
# ★必须是两条命令(`sleep 5; true`)：单条 `sh -c 'sleep 5'` 会被 mksh 优化成直接 execve sleep
#   ⇒ 娃的 comm 变 sleep，样本就白造了(上一轮 dry-run 就是这么数成 0 的)。
for i in $(seq 1 40); do
    sh -c 'sleep 5; true' &
done
echo "BURST 已放 40 个孩子 pid=$$ 当前 sh 任务数=$(pgrep -x sh 2>/dev/null | wc -l)"
sleep 8
echo BURST-DONE
