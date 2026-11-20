#!/usr/bin/env bash
# w356_window_prep.sh —— 第 122 发（#137 续：量"窗口死前那 20 秒谁在 fork"）**开窗前的全部准备**，一条命令。
#
# 它只做三件**不开窗**的事：复核基线 → 清掉会骗人的旧输入 → 铺好只读腿(★**不在这里起采样**，第 122 发证明"起在 reboot 之前"=整条曲线白录) → 打印"接下来那四条命令"。
# ★为什么要"清掉会骗人的旧输入"：今天付过两次学费(§6.261/记忆 例 77)——
#   ①上一 boot 的 `/data/local/tmp/ksu_stage.log` 会让 go.sh 报"判据⑥ 到了"而真 insmod 还在 7 分钟后；
#   ②同名曲线文件 `/data/local/tmp/w356_storm.out` 若不清，下一发的曲线会和这一发**接在同一个文件里**(比 ① 更隐蔽)。
set -u
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1
EV=kmod/w103_evidence
S(){ timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 1) 基线复核(不该有 mod/挂载/开关) ==="
B=$(S "echo id=\$(id -u) mod=\$(grep -c kernelsu /proc/modules) enf=\$(getenforce) 挂载=\$(mount 2>/dev/null | grep -c 'product/bin') 开关=\$(ls /data/local/tmp/ksu_two_profiles 2>&1|head -1)")
echo "  $B"
case "$B" in *"mod=0"*"挂载=0"*) ;; *) echo "[x] 基线不干净 ⇒ 停(先把上一发的窗口收尾)"; exit 3;; esac

# ★★这是"对照发(punch 但不 insmod，§6.265④)"的**忘了摘开关**防线：那个文件留在设备上=下一发默认不加载 ko
#   ⇒ 整发白烧(与 §6.155 那个孤儿 ksuctl、例 77 那个残留日志同一族)。要真打对照发就显式 SKIP_EXPECTED=1。
SKIPF=$(S "ls /data/local/tmp/ksu_skip_insmod 2>/dev/null" | tr -d ' \r')
if [ -n "$SKIPF" ] && [ "${SKIP_EXPECTED:-0}" != 1 ]; then
    echo "[x] 设备上有 $SKIPF 而你没说 SKIP_EXPECTED=1 ⇒ 停。"
    echo '  两种走法：①这是忘了摘 ⇒ 现在 `adb shell rm /data/local/tmp/ksu_skip_insmod` 再重跑 prep；'
    echo '           ②你真要打对照发(punch 不 insmod) ⇒ 用 `SKIP_EXPECTED=1 bash kmod/w356_window_prep.sh`'
    exit 4
fi
[ -n "$SKIPF" ] && echo "  ★已确认：这一发是**对照发**(punch 但不 insmod)，判据只看机器活没活过 30 分钟"
[ -z "$SKIPF" ] && echo "  跳过开关不在 ⇒ 正常发(会 insmod) ✓"

echo; echo "=== 2) 清掉两个会骗人的旧输入 + 复证 ==="
S "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/w356_storm.out"
R=$(S "ls /data/local/tmp/ksu_stage.log /data/local/tmp/w356_storm.out 2>&1 | tr '\n' ' '")
echo "  复证 ls=[$R]  ★两个都应当是 No such file"
case "$R" in *"ksu_stage.log: No such file"*"w356_storm.out: No such file"*) ;; *) echo "[x] 有一个没删掉 ⇒ 停(例 77：残留会让就绪闸说假话)"; exit 3;; esac

echo; echo "=== 3) 铺两条只读腿(都不开窗、都不 punch) ==="
adb push kmod/w356_storm_dev.sh /data/local/tmp/ >/dev/null 2>&1
LM=$(md5sum kmod/w356_storm_dev.sh | cut -c1-32); RM=$(S "md5sum /data/local/tmp/w356_storm_dev.sh" | cut -c1-32)
echo "  w356_storm_dev.sh 本地=$LM 设备=$RM $([ "$LM" = "$RM" ] && echo ✓ || echo '★不一致⇒停')"
[ "$LM" = "$RM" ] || exit 3
S "chmod 755 /data/local/tmp/w356_storm_dev.sh; sh -n /data/local/tmp/w356_storm_dev.sh; echo 设备_mksh_shn=\$?" | sed 's/^/  /'
S "rm -f /data/local/tmp/w356_selftest.out; /data/local/tmp/w356_storm_dev.sh 1 selftest; cat /data/local/tmp/w356_selftest.out" | sed 's/^/  /'
echo "  ★selftest 里 procs/up/mod/enforce_byte 必须都是**非空数**(例 71：读不到就不配当判据)"

echo; echo "=== 4) ★★这一步**不再**起采样腿(第 122 发的事故就在这) ==="
echo '  原来这里直接 setsid 起 w356_storm_dev.sh —— 那是**reboot 之前**，采样器跟着机器一起死，'
echo '  曲线只录到开窗前 40 秒的空转，insmod 那一刻设备侧**一个点都没有**(§6.263③)。'
echo '  ⇒ 采样腿改由 `kmod/w360_arm_newboot.sh` 起：它先要求"一手见过掉线"，再用 `boot_id` 认这一 boot 的身份，'
echo '    起之前删同名旧曲线并复证，起之后用**文件会不会自己长**证明采样器活着。'
echo '  ★★别再用 `kmod/w356_arm_after_boot.sh`：第 124 发它第 1 次轮询就拿到 `boot_completed=1`，'
echo '    等到的是**开窗前那个 24.5 小时的旧 boot**(§6.270 / 例 95) ⇒ "就绪位"本身跨 boot 为真。'
echo
echo '★接下来这几条(2/3/4 **并行**跑，3 会自己等开机)：'
echo '  1) ★名单开关推**哪一份**由这一发的 runbook 决定，别照这句抄：'
echo '     §12/§13/§14(126~131 发)用的是 kmod/ksu_two_profiles_identical.txt(两条逐字节相同, md5 5880f458…)'
echo '     §11 的 C 格用 kmod/ksu_two_profiles_suprobe_only.txt(两条 uid 不同, md5 d13200e3…)；正常交付窗**两个都不要推**'
echo '     ★`/data/local/tmp/ksu_two_profiles` **存在与否**才是开关(文件名是固定的)，内容决定名单长什么样'
echo '     ★这条是 runbook §11 那个 **C 格**的配置(条目 ON)；**正常交付窗不要推**(会走进 §6.259 那堵 +16~30 秒复位的墙)'
echo '  2) KO=kmod/kernelsu_rc67.ko I_KNOW=1 bash kmod/go.sh        ← 开窗(reboot+punch+stage)'
echo '  3) I_SAW_IT_OFFLINE=1 bash kmod/w360_arm_newboot.sh 2400     ← 等这一 boot 起来后起曲线(2400≈42 分钟，够盖 30 分钟判据)'
echo '  4) bash kmod/w356_hostpoll.sh <这一发的名> 380                ← 宿主机侧那条腿，跨 reboot 有效(第 122 发就是它拿到名单)'
echo
echo '  读数：'
echo '       MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/w356_storm.out kmod/w103_evidence/<名>.out'
echo '       PYTHONUTF8=1 python kmod/w356_rate.py kmod/w103_evidence/<名>.out'
echo
echo '★收尾：bash kmod/w310_kill.sh → bash kmod/w300_clean.sh → adb reboot'
echo '★收尾还多两条：rm /data/local/tmp/ksu_two_profiles 和 rm /data/local/tmp/w356_storm.out'
echo '★对表提醒：设备钟比本机**快 29 秒**(§6.261②) ⇒ hostpoll 的本机钟与曲线里的 up 不要直接混着排顺序。'
