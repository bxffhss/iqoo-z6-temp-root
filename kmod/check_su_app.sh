#!/bin/bash
# check_su_app.sh —— **只读**证据、不改设备状态：把"真 app 敲 su 拿到 root"这一格判成 PASS/FAIL。
# 用法：ATT=11 bash kmod/w103_su.sh ; bash kmod/check_su_app.sh
# 为什么要单独一个脚本：无人托管时"跑完了"和"跑对了"是两件事，而判对/判错全靠这几行硬条件。
# ★第一版就靠自己抓了一个假阳性：`w*_su_run.out` 里除了本 boot 的 app_su.txt，还被顺带 cat 了
#   **上一 boot 残留**的 `w103_run.out.early`(旧 shim 打 reboot 口的痕迹) ⇒ 判"走没走 reboot 口"必须
#   只看 app_su.txt 那一份(§"探测程序的假阳性"里"跨重启残留日志"同一家族)。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence

pick() {   # pick <glob> <必须含的关键字>：从新到旧挑**第一份含该关键字**的(旧文件/别的档会混进来)
    for f in $(ls -t $1 2>/dev/null); do
        grep -aq "$2" "$f" && { echo "$f"; return; }
    done
    echo ""
}
SU=$(pick "$EV/w*_app_su.txt" "SHIM-ESC")
[ -n "$SU" ] || SU=$(pick "$EV/w*_su_run.out" "SHIM-FD")     # 没有单独存证时退回老格式(只认带 fd 转储的那段)
REP=$(pick "$EV/w*_app_report.txt" "SU-APP")
case "$SU" in
  *_su_run.out)
    # 老格式里 app_su.txt 之后还 cat 了别的(含**上一 boot 残留**的 .early) ⇒ 只取第一段
    sed -n '1,/--- \/data\/local\/tmp/p' "$SU" > /tmp/check_su_app.seg
    SU=/tmp/check_su_app.seg
    ;;
esac
echo "读: SU=${SU:-无}  REP=${REP:-无}"
[ -n "$SU" ] || { echo "[x] 证据里没有 app_su.txt 的 shim 输出 ⇒ 那一发没收到证"; exit 2; }

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

grep -aq "SHIM-ESC 扫 /proc/self/fd 得到 [1-9]" "$SU" \
    && ok "shim 扫到了内核装的驱动 fd(不需要 reboot)" \
    || bad "没扫到驱动 fd ⇒ 要么旧 shim，要么内核那次没跑 ksu_install_su_fd()"
grep -aq "uid后=0" "$SU" && ok "ioctl(GRANT_ROOT) 之后 uid=0" || bad "uid 后不是 0"
grep -aq "uid=0(root)" "$SU" && ok "子进程里 id 打出 uid=0(root)" || bad "id 里没有 uid=0(root)"
grep -aq "SHIM-ESC reboot(magic)" "$SU" \
    && bad "app 那一枪又打了 reboot(魔数)(app 域里它=SIGSYS；只有扫描失败才会印这行)" \
    || ok "app 那一枪全程没打 reboot(魔数) ⇒ 不会被 seccomp 杀"
if [ -n "$REP" ]; then
    grep -aqE "SU-APP 结果.*(被信号杀|sig=[0-9])" "$REP" \
        && bad "su 子进程被信号杀(看 sig=)" \
        || ok "SU-APP 结果不是被信号杀"
    grep -aq "SU-APP 结果 .* 退出" "$REP" && ok "子进程正常退出" || bad "报告里没有'SU-APP 结果 … 退出'行"
else
    bad "没有含 SU-APP 的 app_report(判不了死法)"
fi
echo
[ "$fail" = 0 ] && echo "== 结论：PASS —— 真 app 敲 su 拿到 KernelSU 授权的 root ==" \
                || echo "== 结论：FAIL —— 上面每条 FAIL 都要回证据里核，别猜 =="
exit $fail
