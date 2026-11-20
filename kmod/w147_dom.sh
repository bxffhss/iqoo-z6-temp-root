#!/system/bin/sh
# w147_dom.sh —— #53：量"被授权 app 敲 su 之后**到底落在哪个 SELinux 域、这个域能不能真干活**"。
#
# 为什么要单独测：交付状态是"名单内 app 敲 su 出 uid=0"，但 §6.107② 之后 profile 的域被
# **硬编码成 u:r:shell:s0**，而一手记录(§6.110 那一发)是"app 来源不 setprof 时域保持
# u:r:untrusted_app" ⇒ "这个 root 在 enforcing 下到底能不能干活"从来没证过。
#
# ★判据必须是**域鉴别器**，不能只读一个数字：下面每一项都要求
#   在 untrusted_app / shell 域里 **rc!=0(EACCES)**，在 kernel 域里 **rc=0**，否则这一格不算证到。
#   本机是 user build(vivo PD2220/A14)——userdebug 上 shell 域能读 app_data，结论别处不一定照抄。
# ★输出走 stdout(由 w147_probe.sh 那侧的管道收)，不在这里落盘：孩子可能是 app uid，
#   而 /data/local/tmp 是 0771 shell:shell ⇒ 它写不进去，重定向会让整段静默变空。
# ★里面一律写绝对路径：这个孩子继承的 PATH 只有 /product/bin 一项(为了绕开 ko 的 execve 钩子)。
export PATH=/system/bin:/system/xbin:/product/bin

dmp() {  # dmp <标签> <命令…> ⇒ 一行：rc + 命令自己的 stderr
    # ★★函数名**绝不能叫 `r`**：这台机的 /system/bin/sh 是 mksh，`r` 是它的**预定义别名**(= `fc -e -`)，
    #   第 43 发就是因此七行鉴别器全部变成 `fc: history functions not available`，
    #   而 WHO/CTX 那几行照常输出 ⇒ 看起来"测到了、只是没差异"。单字母名一律避开。
    # ★为什么要 stderr：`rc!=0` 分不清 EACCES(域挡的)和 ENOENT(文件就没有)，后者会让鉴别器失效。
    lbl=$1; shift
    err=$("$@" 2>&1 >/dev/null); rc=$?
    echo "DOM $lbl rc=$rc err=[${err}]" | head -c 260; echo
}

echo "=== DOM-PROBE up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) ==="
echo "WHO = $(/system/bin/id)"
echo "CTX = $(cat /proc/self/attr/current)"
echo "CAP = $(grep -aE '^CapEff|^CapBnd|^NoNewPrivs|^Seccomp:' /proc/self/status | tr '\n' ' ')"
echo "MNT = $(grep -ac pbin /proc/self/mountinfo)  PPID_ctx=[$(cat /proc/$PPID/attr/current 2>&1 | head -c 60)]"
echo "--- 域鉴别器 ---"
dmp proc1_cmdline   /system/bin/head -c 32 /proc/1/cmdline
dmp proc1_environ   /system/bin/head -c 32 /proc/1/environ
dmp other_app_data  /system/bin/ls /data/data/com.android.providers.settings
dmp other_app_file  /system/bin/head -c 8 /data/system/packages.list
dmp dev_kmsg        /system/bin/dd if=/dev/kmsg of=/dev/null bs=1 count=8 iflag=nonblock
dmp selinux_enforce /system/bin/head -c 2 /sys/fs/selinux/enforce
dmp pstore          /system/bin/ls /sys/fs/pstore
echo "=== DOM-DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
