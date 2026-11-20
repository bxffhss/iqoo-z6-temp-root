#!/system/bin/sh
# w356_storm_dev.sh v3 —— 第 122 发（#137 续）的主仪器：窗口死前那 20 秒谁在 fork。
#
# ★两版学费(v1/v2 都作废，理由都测出来过)：
#   v1：每次迭代起 11 个进程(cut/grep/ps/pidof/sleep) ⇒ **仪器自己就是风暴**，空闲读数被它顶到 16/秒；
#   v2：想用"全内建 + `read -t` 零 fork 延时" ⇒ 设备上实测 `read -t 1 </dev/null`=24ms、fifo 那条 `mkfifo` rc=1 建不出来
#       ⇒ **这台 mksh 没有零 fork 的延时可用**(见 w356_delaytest.out)，只能退回 `sleep`。
# v3 的取舍：**设备侧每次迭代固定 1 个 fork(`sleep 1`)，除此之外零 fork** ⇒
#   仪器自己的贡献是**确定的 1/秒**，算速率时直接减掉即可；"谁在生"那一格交给宿主机侧的 `w356_hostpoll.sh` 去问
#   (那部分进程是 adb shell 起的，数量我也数得清 ⇒ 同样可减)。
#
# ★判读规则(先写下，事后不改)：同一 boot 内自比 ——
#   R0 = insmod 后 [5,15] 秒的 (Δprocs-Δt)/Δt ；R1 = 死亡前最后 10 秒的同算法；
#   R1 ≥ 5×R0 ⇒ §6.198"我们自己的 fork-exec 风暴"成立；R1 < 2×R0 而宿主机侧看到 ksud/sushd 在场抖动 ⇒ 查 vr 执法形状；
#   两者都平 ⇒ 嫌疑回到多条目装载路径本身(`load_allow_uid`/`set root profile` 那条)。
# ★为什么以 shell 跑、文件落 /data：root 通道正是被测对象，不能拿它当量具；且这一发大概率以复位收场，
#   重启后一条 `adb pull` 就能拿回整条曲线(tmpfs 会没，/data 不会)。
# 用法(shell 身份，独立于被测流程)：setsid nohup /data/local/tmp/w356_storm_dev.sh 1800 >/dev/null 2>&1 </dev/null &
#   ★1800 ≈ 31 分钟：从"起采样"到"insmod"实测要 12~14 分钟(reboot+等负载+punch+等 post 腿)，再留尾巴给复位时刻。
OUT=/data/local/tmp/w356_storm.out
N=${1:-1800}

if [ "${2:-}" = selftest ]; then
    { echo "selftest uid=$(id -u)"
      read UP D < /proc/uptime;             echo "up=[$UP]"
      P=""; C=""; while read K V X; do case "$K" in processes) P="$V";; ctxt) C="$V";; esac; done < /proc/stat
      echo "procs=[$P] ctxt=[$C]"
      m=0; while read L; do case "$L" in kernelsu*) m=$((m+1));; esac; done < /proc/modules; echo "mod=[$m]"
      read E < /sys/fs/selinux/enforce;     echo "enforce_byte=[$E]"
      echo "负对照:不存在的包 pidof=[$(pidof com.no.such.pkg)](应当空)"
    } > /data/local/tmp/w356_selftest.out 2>&1
    exit 0
fi

echo "===== w356 v3 起 uid=$(id -u) 计划=$N 次(每次固定 1 个 fork=sleep) =====" >> "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
    i=$((i+1))
    read UP D < /proc/uptime
    P=""; C=""
    while read K V X; do
        case "$K" in processes) P="$V";; ctxt) C="$V";; esac
    done < /proc/stat
    m=0
    while read L; do case "$L" in kernelsu*) m=$((m+1));; esac; done < /proc/modules
    E=""
    read E < /sys/fs/selinux/enforce 2>/dev/null
    echo "t$i up=$UP procs=$P ctxt=$C mod=$m enf=${E:-?}" >> "$OUT"
    sleep 1
done
echo "===== w356 收工 up=$UP =====" >> "$OUT"
