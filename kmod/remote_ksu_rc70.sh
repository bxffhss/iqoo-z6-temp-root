#!/bin/sh
# ★★★★★★ 状态=**不能用，别跑**（2026-10-13 23:5x 写完当场自查发现）★★★★★★
#   这一份的构建段是我**凭印象编的**：真实的构建链在 `kmod/remote_ksu_rc69.sh` 里，长这样——
#     KDIR=/root/k/nothing_sm7325_v_mr   M=/root/k/ksu/kernel（模块目录是 `kernel` 子目录，不是仓库根）
#     step2 跑 16 条 `patch_ksu_*.py` → step2c 从 rc67 快照整份还原 sucompat.c → step3 Kbuild 版本/uapi 回执
#     → step4 `make -C $KDIR M=$M src=$M CONFIG_KSU=m ARCH=arm64 CC=clang LD=ld.lld KCFLAGS=… KSU_EXPECTED_HASH2=… modules -j32`
#     → step5 `llvm-nm` 未导出符号闸门 + modinfo 里 32601/2 两条回执。
#   ⇒ 正确做法不是抄下面这段，而是**复制 remote_ksu_rc69.sh 全文**，在 step2 之后插一条
#     `cp /home/lucy/patch_ksu_tp_timing.py /home/lucy/p_tp_timing.py && python3 /home/lucy/p_tp_timing.py "$M/hook/tp_marker.c"`，
#     再把产物名/预期 md5 换成 rc70。**做这件事时人要醒着**（一次全量重编 + 闸门对表）。
#   ★这条自纠本身要记：写构建脚本时我跳过了"读那份已验证的脚本"这一步——与例 74/75 同族（自述看着像真的）。
# ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★

# remote_ksu_rc70.sh —— 在构建机上编 **rc70 = 当前树 + 只多一块 tp_marker 计时**（§6.266③）
#
# ★它要回答的唯一问题：那条"遍历整机所有线程、全程关中断、每线程一条 pr_info"的路径**一轮多少微秒**。
#   知道了它，(I)"某个不留 printk 的内核路径拉 PS_HOLD"这一族解释要么当场判负(几毫秒)，
#   要么第一次有了可比的量纲(几百毫秒 ⇒ 0.4s×75 轮的 RACE 看门狗就是自杀)。
#
# 与 rc68/rc69 那两份的区别，也是**这份的 provenance 弱在哪**（必须说清楚，别让未来的我误引）：
#   · rc68-clean/rc69 靠"整份还原 sucompat.c 到 rc67 快照 + 只打一块 + 源码 md5 与离线预推值对表"拿到可辩护来源；
#   · rc70 **不动 sucompat.c**，只在 `kernel/hook/tp_marker.c` 上加计时 ⇒ 它的基线就是"当前这棵树"，
#     而**当前树 ≠ 出货的树**（§6.262/#126：31 条补丁器、循环只列 16 条 ⇒ 从 pristine 跑链 ≠ 出货树，13 个文件不等）。
#   ⇒ 所以 rc70 只能当**仪器**用（量一个耗时数），**不能**当交付候选、也不能与 rc67 做"只差一块"的对比。
#     要拿"rc67 + 计时"，必须先从备份快照 `kmod/backup_20261013/`(tree d9488d0f…) 还原整棵树再打——那是另一发的事。
#
# 跑法（本地）：PYTHONUTF8=1 python hermes-remote/cli.py exec --file kmod/remote_ksu_rc70.sh --timeout 1500
set -u
M=/root/k/ksu
K=/root/k/layout_linux-5.4.281
TP=$M/kernel/hook/tp_marker.c
LOG=/root/rc70_build.log
KO_OUT=/root/kernelsu_rc70.ko

say(){ echo "[rc70] $*"; }

# ---- 0) 铺补丁器（cli.py 的 --file 只跑脚本内容 ⇒ 补丁器单独 put 一次） ----
P=/home/lucy/patch_ksu_tp_timing.py
[ -f "$P" ] || { say "缺补丁器 $P（先 `python hermes-remote/cli.py put kmod/patch_ksu_tp_timing.py patch_ksu_tp_timing.py`）"; exit 1; }

# ---- 1) 改前的树摘要 + 逐文件清单（用来事后证明"只有 tp_marker.c 变了"） ----
mani(){ (cd "$M" && find . -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z | xargs -0 md5sum | sort); }
mani > /tmp/rc70_before.txt
BEFORE=$(md5sum < /tmp/rc70_before.txt | cut -d' ' -f1)
BEFORE_TP=$(md5sum "$TP" | cut -d' ' -f1)
say "改前 tp_marker.c = $BEFORE_TP   全树摘要 = $BEFORE"
grep -q "KSUBEAT TPT" "$TP" && { say "★这棵树里 tp_marker.c 已经打过计时 ⇒ 停（别拿这份的 md5 当基线）"; exit 1; }

# ---- 2) 打补丁 ----
python3 "$P" "$TP" || { say "补丁器拒绝/失败 ⇒ 停"; exit 1; }
AFTER_TP=$(md5sum "$TP" | cut -d' ' -f1)
[ "$AFTER_TP" != "$BEFORE_TP" ] || { say "★打完字节没变 ⇒ 补丁器在说谎，停"; exit 1; }
N_PARAM=$(grep -c "module_param(ksu_tp_timing" "$TP")
N_END=$(grep -c "KSUBEAT TPT walk:" "$TP")
say "改后 tp_marker.c = $AFTER_TP  参数声明=$N_PARAM 结束行=$N_END"
[ "$N_PARAM" = 1 ] && [ "$N_END" = 1 ] || { say "★形状不对 ⇒ 停"; exit 1; }

# ---- 3) 逐文件对照：**只允许** tp_marker.c 一个变（这条是防"顺手漂了别的文件"，#126 就是栽在这上面） ----
mani > /tmp/rc70_after.txt
CHANGED=$(diff <(sort /tmp/rc70_before.txt) <(sort /tmp/rc70_after.txt) | grep -a -E '^[<>]' | awk '{print $NF}' | sort -u)
NC=$(printf '%s\n' "$CHANGED" | grep -c . )
say "变了 $NC 个文件：$(printf '%s ' $CHANGED)"
[ "$NC" = 1 ] || { say "★不是恰好 1 个文件变化 ⇒ 停（这发的 provenance 不成立，别说'只多一块'）"; exit 1; }
case "$CHANGED" in *kernel/hook/tp_marker.c) ;; *) say "★变的是别的文件($CHANGED) ⇒ 停"; exit 1;; esac

# ---- 4) 构建 ----
say "开始构建（内核树 $K）…"
( cd "$K" && export LLVM=1 && make -C . M="$M" -j2 kernelsu.ko ) > "$LOG" 2>&1
RC=$?
tail -18 "$LOG"
[ "$RC" = 0 ] || { say "★构建失败 rc=$RC（完整日志 $LOG）"; exit 1; }
find "$K" "$M" -name 'kernelsu.ko' -newer "$TP" 2>/dev/null | head -3

# ---- 5) 参数真的进了 .modinfo 吗（insmod 认不认这个参数） ----
KO=$(find "$K" "$M" -name 'kernelsu.ko' 2>/dev/null | head -1)
[ -n "$KO" ] || { say "★找不到产物 ko"; exit 1; }
cp "$KO" "$KO_OUT"
echo "--- .modinfo 里的 parm 清单 ---"
strings -a "$KO_OUT" | grep -a '^parm=' | sort
NTP=$(strings -a "$KO_OUT" | grep -ac '^parm=ksu_tp_timing')
echo "parm=ksu_tp_timing 条数 = $NTP   (必须 1)"
SIZE=$(wc -c < "$KO_OUT"); MD=$(md5sum "$KO_OUT" | cut -d' ' -f1)
echo "KO=$KO_OUT size=$SIZE md5=$MD"
[ "$NTP" = 1 ] || { say "★参数没进 modinfo ⇒ 这发不能上机（insmod 会当场 unknown parameter）"; exit 1; }
say "产物 md5=$MD size=$SIZE —— ★这是**仪器**，不是交付候选（provenance 弱，见文件头）"
say "本地取回：python hermes-remote/cli.py get kernelsu_rc70.ko kmod/kernelsu_rc70.ko  然后两端对 md5"
