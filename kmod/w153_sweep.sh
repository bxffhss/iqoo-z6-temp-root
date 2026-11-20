#!/system/bin/sh
# w153_sweep.sh —— 合并验收(ATT=26)收尾的**清扫**：把这一发在机上留下的东西全清掉。
#
# 为什么要单独一发脚本而不是靠驱动的 `adb shell rm`：`/data/adb` 与 `/data/adb/ksu` 是 **root-owned**，
# `adb shell`(uid 2000/shell 域)连遍历都过不去 ⇒ 只能在这一发的 root 窗口里做。
# 而 /data/adb 恰恰是**跨重启留存**的那一类(§6.130 那次就是靠 root 侧 `rm -rf` 才清掉的)。
#
# ★清扫之后**立刻回读**，且回读要在**同一个上下文**里(§6.130：主机侧 shell 读到的
#   `Permission denied` 在"存在/不存在"两种情况下一模一样，不带信息量)。
L=/data/local/tmp/w153_sweep.out
{
    echo "===== SWEEP up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
    echo "--- [1] 清之前(先**列出里面有什么**再删：第 49 发一手是「/data/adb 在、/data/adb/ksu 不在」，"
    echo "         这说明有别人/别的环节在窗口中途动过它，不把内容打出来就永远只能猜) ---"
    for d in /data/adb /metadata/watchdog /data/local/tmp/pbin; do
        printf '  %-22s %s\n' "$d" "$(ls -d "$d" 2>&1 | head -1)"
    done
    # 用 ls -A 逐层列(不用 find：第 51 发 `find` 在 agent 环境里报
    #   `w153_sweep.sh[43]: /data/adb: can't execute: Is a directory`，成因未定，不赌它)
    ls -A /data/adb 2>&1 | head -10 | sed 's/^/    内容: /'
    for x in $(ls -A /data/adb 2>/dev/null | head -6); do ls -l "/data/adb/$x" 2>&1 | head -2 | sed 's/^/      /'; done
    echo "--- [2] 清(顺序：先挂载后目录，别把还挂着的东西删掉) ---"
    grep -aq pbin /proc/self/mountinfo && echo "  !! /product/bin 还挂着 ⇒ **不动 pbin**，交给 w135_off"
    for d in /data/adb /metadata/watchdog/ksu /data/local/tmp/pbin; do
        rm -rf "$d"; echo "  rm -rf $d rc=$?"
    done
    # 我们这一批发到设备上的工具与回执(文件名固定，跨 boot 会留存 ⇒ 必须清)
    rm -f /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/domprint \
          /data/local/tmp/w133_probe.sh /data/local/tmp/w133_probe.out \
          /data/local/tmp/w135_fix.sh /data/local/tmp/w135_fix.out \
          /data/local/tmp/w135_off.sh /data/local/tmp/w135_off.out \
          /data/local/tmp/w147_dom.sh /data/local/tmp/w147_dom2.sh /data/local/tmp/w147_dom.out \
          /data/local/tmp/w148_uid.sh /data/local/tmp/w148_uid.out /data/local/tmp/w148_pkg1.txt \
          /data/local/tmp/w149_su_run.sh /data/local/tmp/w149_su_run.out \
          /data/local/tmp/w152_residue.sh /data/local/tmp/w152_residue.out \
          /data/local/tmp/w153_sweep.sh /data/local/tmp/w132_tuid.txt /data/local/tmp/w133_tgt.txt \n          /data/local/tmp/w155_mountwatch.sh /data/local/tmp/w155_mwloop.sh /data/local/tmp/w155_mw.out
    echo "  投放物已删 rc=$?"
    echo "--- [3] ★清完之后同一个上下文回读(这才是带信息量的判据) ---"
    for d in /data/adb /metadata/watchdog/ksu /data/local/tmp/pbin; do
        printf '  %-24s %s\n' "$d" "$(ls -d "$d" 2>&1 | head -1)"
    done
    # ★计数要把**本脚本自己的输出文件**排除掉：第 51 发那个"投放物残留数=1"数到的就是
    #   w153_sweep.out(正在被写的这一份)——把"我自己的日志"当成"没清干净"是假阳性。
    echo "  投放物残留数=$(ls /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/domprint /data/local/tmp/w13[3-9]* /data/local/tmp/w14[5-9]* /data/local/tmp/w15* 2>/dev/null | grep -v 'w153_sweep.out' | grep -v 'w152_residue.out' | wc -l)"
    echo "  残留清单=[$(ls /data/local/tmp/w1[3-5]* 2>/dev/null | tr '\n' ' ')]"
    echo "  /product/bin 条目数=$(ls -A /product/bin 2>/dev/null | wc -l) (出厂 3)"
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
