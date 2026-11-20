#!/system/bin/sh
# w162_sp.sh —— root 侧当场给官方 Manager 写一条 profile：domain=u:r:shell:s0。
#   为什么必须 root 侧(§6.153⑥)：SET_APP_PROFILE 的 perm_check 是 manager_or_root，
#   而王座已经让给官方 Manager ⇒ 我们自己的 suw(uid 10104)发它就是 `rc=-1 errno=1(EPERM)`。
# ★uid 从文件读，不用 sed 往脚本里塞(记忆例33 那一族：非数字参数会静默变成"root 的授权状态")。
CTL=/data/local/tmp/ksuctl88
L=/data/local/tmp/w162_sp.out
{
    echo "=== SP up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) ==="
    [ -x "$CTL" ] || { echo "  !! 没有 $CTL ⇒ 这一格按没测到算"; echo "===== DONE"; exit 0; }
    U=$(cat /data/local/tmp/w162_mgr.uid 2>/dev/null | tr -dc '0-9')
    case "$U" in
      [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
      *) echo "  bad-uid=[$U] ⇒ 不发 ioctl"; echo "===== DONE"; exit 0 ;;
    esac
    echo "  --- 改之前 ---"
    "$CTL" granted "$U" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-150
    "$CTL" setprof "$U" me.weishu.kernelsu u:r:shell:s0 2>&1 | cut -c1-170
    echo "  --- 改之后：王座还在不在(setprof 不该把加冕冲掉) ---"
    "$CTL" mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-140
    echo "  --- 名单里现在有谁 ---"
    "$CTL" allowlist 2>&1 | grep -aE "NEW_GET_ALLOW_LIST|allow\[" | head -8 | cut -c1-120
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
