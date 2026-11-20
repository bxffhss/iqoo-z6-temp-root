#!/system/bin/sh
# w184_sample.sh —— #55 的采样器：每 3 秒记一行"这一刻 MAC 生不生效 + pr 还活着吗 + 两份日志长多长"。
#   为什么要它(§6.184)：第一百一十九发一手——空枪那一次的读数正好是
#     `[SEN] 把 enforce 那一字节 1→0 并"两道关卡放开"` → 约 4 分钟后 `getenforce` 回 `Enforcing`、`pr` 已退出、`[POST]` 从没出现。
#   ⇒ "空枪"与"enforce 自己回跳"很可能是**同一件事的两面**：一旦有人把生效位写回 1，
#     pr 后面那几步(要靠 tracefs/kprobe 写)就再也做不动，于是它自己退场、post 永不到来。
#   这一发不猜：把时间轴记下来，先后关系自己会说话(pr 退场 vs enf 回跳 谁在前)。
#   ★必须 setsid + 三个 fd 全重定向(否则会被踢框架/会话结束一起带走)。
#   ★§6.313⑦/例 117 加的 `suw=[…]`：**"某个 app 整窗没出现"这类前提不能靠两次点读**——把 `pidof com.suw.manager`
#     变成每 3 秒一条的连续证人(代价＝每行多 1 次 fork，这台机器只有 `sleep` 能延时，已在结论里计过)。
#     `NOFIRE=1` 之后如果这一列出现过任何 pid，"没人动手"那个前提就地作废，本发改记为"非 X/非 W"。
L=/data/local/tmp/w184_sample.out
exec >>"$L" 2>&1
echo "=== 采样起 up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ==="
# ★§6.318⑥ 的坑：400 行＝20 分钟，而第 154 发的 insmod 落在 up=2213(开窗到装载 39 分钟)
#   ⇒ suw=[…] 整窗空转。改成 1200 行(60 分钟)覆盖长装载的窗；判读时要打印"末行 up vs insmod up"。
i=0
while [ $i -lt 1200 ]; do
    printf 'up=%s enf=%s pr=[%s] plog=%s slog=%s mod=%s suw=[%s]\n' \
        "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)" "$(getenforce)" "$(pidof pr)" \
        "$(wc -c < /data/local/tmp/punch.log 2>/dev/null)" \
        "$([ -f /data/local/tmp/ksu_stage.log ] && echo Y || echo N)" \
        "$(grep -c kernelsu /proc/modules)" \
        "$(pidof com.suw.manager | tr '\n' ' ')"
    i=$((i + 1))
    sleep 3
done
echo "===== 采样结束 ====="
