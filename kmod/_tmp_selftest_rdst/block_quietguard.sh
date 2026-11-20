# ★★第 68 发一手的自保闸：`ksu_quiet_after_insmod` 在 ⇒ stage 走的是**静默版**，它自己那行就写着
#   『判据⑥(★静默版：ko 在，但这一发故意不装 agent fd、不发超调用，只为让 go.sh 往下走)』。
#   ⇒ 那盏「就绪」灯根本不是**通道**就绪：@sushd 没人听，腿一句都不会执行(out 件不存在＝可核的缺席证据)。
#   我的错：把 QUIET 从「参数夹逼那批链」顺手抄进了「要派腿的链」。这里加闸，免得下一个我再犯。
if [ -n "${LEG1:-}" ]; then
    QS=$(A "ls /data/local/tmp/ksu_quiet_after_insmod 2>/dev/null")
    QLINE=$(A "grep -ac '静默版' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    if [ -n "$QS" ] || [ "${QLINE:-0}" != "0" ]; then
        echo "=== 3.5) LEG1 给了但这一发是 quiet 形状 ⇒ **不派腿**(开关文件在=$([ -n "$QS" ] && echo 是 || echo 否), stage 静默版行数=${QLINE:-0})"
        echo "      静默版不装 agent fd ⇒ @sushd 没人听；派下去只会拿到一句都没执行的空证件(第 68 发一手)"
        LEG1=
    fi
fi
# === 3.5a) 自保闸结束(这行是给 kmod/_tmp_selftest_rdst/run_quietguard.sh 抽块用的锚，别删) ===
