#!/system/bin/sh
# w172_fix3.sh —— #73 第二步：**同一发窗口里**做"前测 → 只改桩写回(c=4) → 后测"，判据是同任务同二进制的前后对照。
#   为什么必须同发：跨发比较就又多了一个变量(每次开机 vr 的桩状态/布局都可能不同)。
#   ★顺序里带一道闸：**前测没复现 EPERM 就不写**(不复现就没什么可修，白担一次风险)。
#   ★写的那一笔只有 4 字节(把 .cfi_jt 桩里的 B 改回 `B 本体`)，`do_slot` 硬编 0 ⇒ sys_call_table 一个字都不动；
#     这跟交付流程每发都在跑的 c=3 是同一手法，只是换了三个号。日志在 /data ⇒ 万一当场重启，存证还在。
L=/data/local/tmp/w172_fix3.out
PR=/data/local/tmp/forkprobe
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== F up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"
    echo "  ko 在册: $(grep -a '^kernelsu ' /proc/modules 2>/dev/null | tr '\n' ' ')"
    echo "  有没有 c=4 那个口: $([ -e /proc/ksu_fixcfi ] && echo 有 || echo 没有)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    case "$U1" in
        [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) echo "[x] U1=[$U1] 不是 uid ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    chmod 755 "$PR" 2>/dev/null

    # 状态读数(不是日志)：扫一遍把四条桩的"被管/未管"抄下来 ⇒ 写回前后各来一次，看的是状态翻没翻。
    echo 1 >/proc/ksu_cfiscan 2>&1
    echo "  --- 前扫(写回之前) ---"
    	grep -aE 'VRCFI.*(sys_clone\.|sys_clone3|sys_setuid\.|sys_setresuid\.|sys_setgid\.)' /proc/ksu_slots 2>/dev/null | tail -6
    	grep -a 'VRCFI 结束' /proc/ksu_slots 2>/dev/null | tail -1
    echo "--- 前测(A1)：escape 后 fork —— 期望 LC1/KN1/clone_again 全 EPERM ---"
    "$CTL" grant "$U1" "$PR" A1 2>&1 | grep -aE "GRANT_ROOT|LADDER 14|^LC1|^KN1|^NB clone_again|^NB setuid|^NB setresuid|^STAGE" | cut -c1-150

    echo "--- 闸：上面没有 fork EPERM 就不写(没有可修的东西，别担风险) ---"
    "$CTL" grant "$U1" "$PR" A2 2>&1 | grep -aoE "LADDER 14 fork rc=-1 errno=1" | head -1 | sed 's/^/  复现标志: /'
    if ! "$CTL" grant "$U1" 2>&1 | grep -aq "LADDER 14 fork rc=-1 errno=1"; then
        echo "  [x] 这一发没复现 fork EPERM ⇒ **不写**，直接把这份存证带回去看"
        echo "===== DONE"; exit 0
    fi

    echo "--- 写回：echo 4 > /proc/ksu_fixcfi(只改桩 B；do_slot=0) ---"
    # 版本闸：c=4 这个口是 rc62 才有的。先写一个不触发任何写的值(0)，把使用说明炸出来；
    #   说明里有没有 4(只改桩 就证明设备里装的到底是不是 rc62 —— 不是就一个字都不写。
    echo 0 >/proc/ksu_fixcfi 2>&1
    if grep -aq '4(' /proc/ksu_slots 2>/dev/null; then
    	echo "  版本闸过：设备里这份 ko 认 c=4 ⇒ 是 rc62"
    else
    	echo "  [x] 版本闸没过：说明里没有 4( ⇒ 设备里不是 rc62 ⇒ 这一发不写"
    	echo "===== DONE"
    exit 0
    fi
    echo 4 >/proc/ksu_fixcfi 2>&1
    echo "  触发 rc=$?"
    grep -a "CFIFIX" /proc/ksu_slots 2>/dev/null | grep -aE "clone|setuid|setresuid" | tail -12

    # 状态读数(不是日志)：扫一遍把四条桩的"被管/未管"抄下来 ⇒ 写回前后各来一次，看的是状态翻没翻。
    echo 1 >/proc/ksu_cfiscan 2>&1
    echo "  --- 后扫(写回之后)：这三条应该变成 (未管) ---"
    	grep -aE 'VRCFI.*(sys_clone\.|sys_clone3|sys_setuid\.|sys_setresuid\.|sys_setgid\.)' /proc/ksu_slots 2>/dev/null | tail -6
    	grep -a 'VRCFI 结束' /proc/ksu_slots 2>/dev/null | tail -1
    echo "--- 后测(B1/B2)：同样的两遍，防一次读数巧合 ---"
    "$CTL" grant "$U1" "$PR" B1 2>&1 | grep -aE "LADDER 14|^LC1|^LC2|^LC3|^KN1|^KN4|^NB clone_again|^NB setuid|^NB setresuid|^STAGE 5" | cut -c1-150
    "$CTL" grant "$U1" "$PR" B2 2>&1 | grep -aE "LADDER 14|^LC1|^KN1|^NB clone_again|^NB setuid|^STAGE 5" | cut -c1-150
    echo "--- 真机上一句能跑的命令才算数：让 escape 后的任务自己 fork 并 exec 一个外部命令 ---"
    "$CTL" grant "$U1" /system/bin/id 2>&1 | grep -aE "LADDER (9|14)|uid=" | cut -c1-150
    echo "--- 机器还在吗：up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) ---"
    echo "--- dmesg 尾巴(找 cfi_fail/Unable to handle/BUG) ---"
    dmesg 2>/dev/null | grep -aiE "cfi|Unable to handle|BUG:|Oops|Kernel panic|vnread|vr" | tail -20
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null

