#!/bin/bash
# w111_appsu.sh —— **活窗口**里给"真 app 自己敲 su"补三枪(不重打整条链)。md §6.111/§6.112
# 前置：本 boot 已经 punch 过、模块在、名单里有 10319(=com.suw.manager)，且 **stage 还没收尾**
#       (收尾会 `kill` 掉 dmesg 落盘循环 ⇒ X*/SU* 脚印就捞不到了，§6.111④ 就是这么丢的)。
# 用法：bash kmod/w111_appsu.sh          # 三枪全打
#       ONLY=3 bash kmod/w111_appsu.sh   # 只打第 3 枪
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
EV=kmod/w103_evidence
mkdir -p "$EV"
ONLY=${ONLY:-}

fire() {   # fire <动词> <等待秒>：每次都 force-stop，动词才不会被旧进程吃掉
    A shell am force-stop com.suw.manager >/dev/null 2>&1
    sleep 1
    A shell "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
    sleep "$2"
}
clean() {   # 只去 NUL/控制字符：**不能**删非 ASCII，否则中文判据会被一起抹掉(§6.115 G4/G7 假红的同一个根因)
    tr -d '\000-\010\013\014\016-\037\177'
}
foot() {   # 把这一枪前后的内核脚印抄下来(X6 domain= 是 #43 的判据)
    S 'grep -aE "KSUBEAT (SU[0-9]|SU1[a-d]|X[0-9A-C]) " /data/local/tmp/dmesg.live 2>/dev/null | tail -22' | cut -c1-150
}

echo "=== 起点自检 ==="
S 'cut -d" " -f1 /proc/uptime; lsmod | grep -c kernelsu; getenforce; ls -l /dev/ksud; md5sum /dev/ksud /data/local/tmp/ksud' | sed 's/^/  /'

echo; echo "=== ① @su:id —— 交付判据(扫到几个驱动 fd + uid 后是不是 0) ==="
if [ -z "$ONLY" ] || [ "$ONLY" = 1 ]; then
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@su:id" 8
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | clean | sed 's/^/  /'
    echo "  --- 脚印 ---"; foot | sed 's/^/  /'
fi

echo; echo "=== ② @su:sh w104_probe.sh —— 这个 root 能不能干活(cap/seccomp/读写/setcon/真 uid 表) ==="
if [ -z "$ONLY" ] || [ "$ONLY" = 2 ]; then
    MSYS_NO_PATHCONV=1 adb push kmod/w104_probe.sh /data/local/tmp/w104_probe.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w104_probe.sh; rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@su:sh /data/local/tmp/w104_probe.sh" 14
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | clean | tee "$EV/w111_probe.txt" | sed 's/^/  /'
    echo "  --- 脚印 ---"; foot | sed 's/^/  /'
fi

echo; echo "=== ③ @su:sh 让 root 侧把新 shim 换进 /dev/ksud(adb shell 对 /dev 没有写位) ==="
if [ "$ONLY" = 3 ]; then
    MSYS_NO_PATHCONV=1 adb push kmod/w104_cp.sh /data/local/tmp/w104_cp.sh >/dev/null 2>&1
    MSYS_NO_PATHCONV=1 adb push cm57/ksud_shim /data/local/tmp/ksud.new >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/ksud.new /data/local/tmp/w104_cp.sh; rm -f /data/local/tmp/w104_cp.out' >/dev/null
    fire "@su:sh /data/local/tmp/w104_cp.sh" 10
    S 'cat /data/local/tmp/w104_cp.out 2>&1' | sed 's/^/  /'
fi

echo; echo "=== 存证 ==="
S 'cat /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt 2>&1 | tail -12' > "$EV/w111_app_report.txt" 2>&1
S 'grep -aE "KSUBEAT (SU|X)[0-9A-C]" /data/local/tmp/dmesg.live 2>/dev/null | tail -60' > "$EV/w111_footprints.txt" 2>&1
echo "  $EV/w111_probe.txt / w111_app_report.txt / w111_footprints.txt"
echo "  ★这一发只读不写设备状态(除了那个写完即删的探针)；收尾仍然要 adb reboot"
