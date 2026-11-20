#!/system/bin/sh
# w786_break_dev.sh —— 第 54 发的**破坏器**（无参数，root 跑）：把 root-only 的 bind 源删掉，复现今晚那种"源没了、挂载还在"的坏态，
#   然后交给维持件去修。证人两条：①这份文件里的前后状态；②`w774_keeper.log` 里必须出现"不在 ⇒ 重建#1 / 修好了"。
#   ★为什么单独一个文件：打字的参数会被吃掉（今天三次 `... break` 都退化成默认模式），所以"一个文件只干一件事"。
L=/data/local/tmp/w786.out
NB=/data/adb/ksu/pbin
SRC=/data/adb/ksu/sustatic
ESC=/data/local/tmp/w786_esc
TGT=/product/bin
{
    echo "=== 破坏器 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) ==="
    # ★第 0 步＝逃生口＋拒绝开火的闸：维持件重建靠的是 $SRC(它不在被删的目录里)，但万一维持件不生效，
    #   这个窗就没有 root 通道了(裸 su 与改道都落在那层 bind 上)⇒ 先把 $SRC 抄一份到 shell 看得见的位置，
    #   抄不成(源不在/为空)就**不破坏**——不许拿"整个窗口瞎掉"去换一个读数。
    cp "$SRC" "$ESC" 2>/dev/null
    ESZ=$(wc -c < "$ESC" 2>/dev/null | tr -dc '0-9')
    echo "  逃生口：cp $SRC → $ESC 得到 ${ESZ:-0} 字节(源=$(wc -c < "$SRC" 2>/dev/null | tr -dc '0-9')字节)"
    if [ "${ESZ:-0}" -lt 100000 ]; then
        echo "  [x] 逃生口没铺上 ⇒ **不开火**(破坏后无法自证能恢复)；本次记为未测"
        echo "=== 破坏器 完(未开火) up=$(cut -d' ' -f1 /proc/uptime) ==="
        exit 5
    fi
    chmod 755 "$ESC" 2>/dev/null
    echo "  前: $TGT/su=$([ -e "$TGT/su" ] && echo 在 || echo 没了) 源内文件=$(ls -A "$NB" 2>/dev/null | wc -l) mount=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-62 | tr '\n' '|')]"
    rm -rf "$NB"
    echo "  已 rm -rf $NB rc=$? ⇒ 立刻 $TGT/su=$([ -e "$TGT/su" ] && echo 还在 || echo 没了) mount=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-62 | tr '\n' '|')]"
    i=0
    while [ "$i" -lt 20 ]; do
        i=$((i + 1)); sleep 3
        [ -e "$TGT/su" ] && { echo "  复现了：第 $((i * 3)) 秒 $TGT/su 回来了"; break; }
    done
    [ -e "$TGT/su" ] || echo "  ★60 秒没回来 ⇒ 维持件没生效(下面的 keeper 计数就是判据；此时可用逃生口 $ESC 手动恢复)"
    echo "  末态 源内文件=$(ls -A "$NB" 2>/dev/null | wc -l) mount=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-62 | tr '\n' '|')]"
    echo "  keeper 计数：重建=$(grep -ac '重建#' /data/local/tmp/w774_keeper.log 2>/dev/null | tr -dc '0-9') 修好了=$(grep -ac '修好了' /data/local/tmp/w774_keeper.log 2>/dev/null | tr -dc '0-9') GIVEUP=$(grep -ac GIVEUP /data/local/tmp/w774_keeper.log 2>/dev/null | tr -dc '0-9')"
    echo "  keeper尾=[$(tail -6 /data/local/tmp/w774_keeper.log 2>/dev/null | tr '\n' '|' | cut -c1-420)]"
    echo "=== 破坏器 完 up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
chmod 666 "$L" 2>/dev/null
