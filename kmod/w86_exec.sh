#!/system/bin/sh
# 窗口 86 第二格：escape 之后 **execve 到底通不通**，以及"换掉映像之后 open 还拦不拦"。
# 为什么这一格值钱：B 的最后一公里(libsu 的 RootService)要的就是 `su` —— 也就是
#   一个 escape 过的任务 exec 出一个二进制、并且那个新进程还能读写文件。
#   LADDER 已经证明"同一个任务 open 一律 EPERM"，但那可能只是**当前 cred** 的账；
#   execve 会换 mm/换 fd 表(带 O_CLOEXEC 的会被清掉)，如果拦的是 cred ⇒ 换映像也救不回来；
#   如果拦的是"这个任务的旧状态" ⇒ 换完映像就该正常。两种结果对下一步的走向完全不同。
L=/data/local/tmp/w86_exec.out
K=/data/local/tmp/ksuctl86
{
    echo "起点 up=$(cut -d' ' -f1 /proc/uptime)"
    rm -f /data/local/tmp/esc_probe.txt
    echo "===== A) grant 之后 execvp(/system/bin/sh -c ...) ====="
    "$K" grant 10315 /system/bin/sh -c 'id; echo hit > /data/local/tmp/esc_probe.txt; echo "新进程里 open 自己=/proc/self/status rc=$?"; head -1 /proc/self/status'
    echo "A rc=$?"
    echo "  esc_probe.txt: $(ls -l /data/local/tmp/esc_probe.txt 2>&1)"
    echo "  内容: $(cat /data/local/tmp/esc_probe.txt 2>&1)"
    echo "===== B) 只 exec 一个静态命令(不带重定向)：execve 本身通不通 ====="
    "$K" grant 10315 /system/bin/toybox id
    echo "B rc=$?"
    echo "===== C) 正对照：born-root 的自己跑同一条(证明命令本身没问题) ====="
    /system/bin/toybox id
    echo "C rc=$?"
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L"
