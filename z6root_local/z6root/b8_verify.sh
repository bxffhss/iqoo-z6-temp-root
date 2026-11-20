#!/system/bin/sh
# b8_verify.sh —— 由 suw 的 root 腿(@sushd)派单跑：用**有权的调用者**读名单真值。
#   为什么要它：`ksuctl88 granted <uid>` 的 perm 是 manager_or_root，从 adb shell(2000) 发必然
#   `rc=-1 EPERM granted=0`——连 10342 都读成 0，而它明明在名单里。只有 root/manager 发的才是读数。
CTL=/data/local/tmp/ksuctl88
OUT=/data/local/tmp/b8_verify.out
# ★uid 列表**从设备侧开关现取**（ksa_uids.txt 的主条目 + ksu_two_profiles 里的每条），不写死——
#   否则加了 Termux 之后这里仍只验老的那五个，给出"全绿"的假结论。
UIDS=""
[ -f /data/local/tmp/ksa_uids.txt ] && UIDS=$(cut -d' ' -f1 /data/local/tmp/ksa_uids.txt)
if [ -f /data/local/tmp/ksu_two_profiles ]; then
    for t in $(cat /data/local/tmp/ksu_two_profiles); do
        u=${t%%:*}
        case "$u" in ''|*[!0-9]*) continue ;; esac
        UIDS="$UIDS $u"
    done
fi
{
  echo "===== B8 名单真值 $(date +%H:%M:%S) ====="
  echo "uid 列表(取自开关)=[$(echo $UIDS | tr ' ' ',')]"
  echo "--- whoami ---"; id
  echo "--- info ---"; $CTL info 2>&1 | grep -aE "GET_INFO|flags 位"
  echo "--- allowlist ---"; $CTL allowlist 2>&1 | grep -aE "NEW_GET_ALLOW_LIST|allow\[" | head -12
  echo "--- granted (逐 uid) ---"
  for u in $UIDS; do
    printf 'uid=%-6s ' "$u"
    $CTL granted "$u" 2>&1 | grep -a UID_GRANTED_ROOT
  done
  echo "--- /product/bin/su ---"; ls -l /product/bin/su 2>&1
  echo "===== DONE"
} > "$OUT" 2>&1
