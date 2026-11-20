#!/usr/bin/env bash
# w629_B_loop.sh —— 第 49 发(B＝#176)的主测量循环：**不重 punch**，用 w625 把退回的牌子刷回来，逐轮记账。
#   每轮 = ①rleg 派 w625(它自己做 force-stop→起 Manager→0.1s 节拍写触发口→读回 fd)
#          ②拉它自己的 out 取"第几拍看见 pid / 第几拍见到 fd"(＝抢没抢赢的直接证人)
#          ③w603 read 读首页(焦点断言过才算数)
#   ★对照(第 49 发实测后改写)：正对照**不需要外部看门狗**——开窗后 stage 内置的 RACE 抢装就已经把牌子点亮(§6.407 C1)，
#     所以真正有信息量的是**负对照**：`NEG` 模式＝只 `force-stop`→重开、不派任何腿 ⇒ 牌子必须退回 `不支持`。
#     形状＝正(C1)→负(C0)→正(B×n)→负(D1)→正(B)，每枚都带独立证人。
#   ★tag 带运行号：第 49 发我二次调用 `1 B` 时 tag 又算成 B1 ⇒ B4 的屏幕存证把 B1 的覆盖了(见 §6.407⑤②)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
N=${1:-4}
MODE=${2:-B}            # B = 派 w625 恢复；NEG = 什么都不派，只重启 Manager(负对照)
OFF=${3:-0}             # 同一 boot 内多次调用时给 tag 加偏移，防覆盖
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 起态 up=$(A 'cut -d" " -f1 /proc/uptime') mod=$(A 'grep -c kernelsu /proc/modules') enf=$(A getenforce) pid=[$(A 'pidof me.weishu.kernelsu')] ==="
for i in $(seq 1 "$N"); do
    IDX=$((OFF + i))
    if [ "$MODE" = NEG ]; then
        # 负对照：一条腿都不派，只把 Manager 杀掉重开 ⇒ 牌子必须退回(第 49 发 C0/D1 就是这个形状)
        TAG="N$IDX"
        L1="(负对照：不派腿)"
    else
        # ★派单前先删掉上一轮的 .out(跨轮同名产物会把旧读数当本轮的，§6.394 那条通用坑)
        A 'rm -f /data/local/tmp/w625_seedrestart.out; ls -l /data/local/tmp/w625_seedrestart.out 2>&1 | tail -1' | sed 's/^/  清产物: /'
        bash kmod/w211_ui.sh rleg w625_seedrestart.sh >/dev/null 2>&1
        MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w625_seedrestart.out "$EV/w629_${IDX}_leg.txt" >/dev/null 2>&1
        if ! grep -aq 'DONE' "$EV/w629_${IDX}_leg.txt" 2>/dev/null; then
            echo "  [!] 腿的 .out 没有 DONE 行 ⇒ 本轮算『未测到』，不并入负结论(文件可能还是上一轮的)"
        fi
        L1=$(grep -aE 'SR-ROUND|清场|已写 pid=|没见着 fd|NO-PORT|DONE' "$EV/w629_${IDX}_leg.txt" 2>/dev/null | tr '\n' '|' | cut -c1-260)
        TAG="B$IDX"
    fi
    if [ "$MODE" = NEG ]; then R=$(bash kmod/w603_home_cell.sh "$TAG" restart 2>&1); else R=$(bash kmod/w603_home_cell.sh "$TAG" read 2>&1); fi
    READ=$(printf '%s' "$R" | grep -a '读回：' | cut -c1-120)
    # ★这条"未测"标记只能用 grep -q 判，不能用 grep -c 的结果是否为非空：
    #   grep -ac 在没命中时打印 "0"，而 "0" 是非空字符串 ⇒ ${RC:+} 恒真(第 49 发一手：三枚正读数全被挂了个假"未测")
    FLAG=""
    printf '%s' "$R" | grep -aq '没测到' && FLAG=" / [焦点或树没产文件⇒未测，不算负结论]"
    printf '第 %s 枚[%s] 腿=%s\n   牌子=%s%s\n' "$IDX" "$TAG" "${L1:-（无腿读数）}" "${READ:-读失败}" "$FLAG"
done
echo "=== 终态 up=$(A 'cut -d" " -f1 /proc/uptime') mod=$(A 'grep -c kernelsu /proc/modules') enf=$(A getenforce) ==="
