echo "=== 1.6) 改道落点与标签从 args 反推，不靠我记得那两行 echo(§6.228⑨) ==="
#   ksu_ksud_path 不是 /dev/ksud 时，stage 需要 ksu_redirect_dst(把 ksud 复制到哪) + ksu_redirect_con(贴什么标签)。
#   ★标签默认**只能 plain s0**：第 104 发实测带类别(s0:c100,c200)在执法下挡掉 app 的 execute(rc=126)。
#   要复现那一格请显式 REDIRECT_CON=u:object_r:apk_data_file:s0:c100,c200 —— 那是实验，不是交付形状。
KSUD_P=$(tr ' ' '\n' < kmod/ksu_args.txt | sed -n 's/^ksu_ksud_path=//p')
# ★§6.301⑤/runbook §26 的仪器开关，**默认关 ⇒ 交付链行为逐字不变**。
#   为什么需要它：这一段是"从当前生效的 args 反推落点"，所以**少给 `ksu_ksud_path` 的那几发会顺手把
#   dst/con 删掉 ⇒ stage 装载前那段 `cp ksud→落点 + chown + chcon` 整块不跑**（§6.301③ 的共变源）。
#   格 H 要把"参数串出现在 insmod 命令行里"与"落点被铺过"这两件事分开，就得只补后者。
#   ★优先级：args 里给了 `ksu_ksud_path` ⇒ **以 args 为准**，本开关不得覆盖它（免得把交付形状改掉）。
if [ -z "$KSUD_P" ] && [ -n "${REDIRECT_DST:-}" ]; then
    KSUD_P="$REDIRECT_DST"
    echo "  ★REDIRECT_DST=$KSUD_P 覆盖生效(args 里没给 ksu_ksud_path) ⇒ 本发装载前会铺落点(实验格 H)"
elif [ -n "${REDIRECT_DST:-}" ] && [ "$KSUD_P" != "$REDIRECT_DST" ]; then
    echo "  [!] REDIRECT_DST=$REDIRECT_DST 被忽略：args 里已有 ksu_ksud_path=$KSUD_P(以 args 为准)"
fi
if [ -n "$KSUD_P" ] && [ "$KSUD_P" != /dev/ksud ]; then
    CON=${REDIRECT_CON:-u:object_r:apk_data_file:s0}
    A "echo $KSUD_P > /data/local/tmp/ksu_redirect_dst; echo $CON > /data/local/tmp/ksu_redirect_con"
    echo "  已写 dst/con，设备上读回复证：$(A 'cat /data/local/tmp/ksu_redirect_dst /data/local/tmp/ksu_redirect_con' | tr '\n' ' ')"
else
    A "rm -f /data/local/tmp/ksu_redirect_dst /data/local/tmp/ksu_redirect_con"
    echo "  ksu_ksud_path=${KSUD_P:-<args 里没给>} ⇒ 已清掉 dst/con，免得上一发的残留生效"
    # ★§6.290 注：原来这行末尾写着"(tmpfs 默认口)"，**那是错的**——远端真树 `kernel/runtime/ksud.h:6` 是
    #   `#define KSUD_PATH "/data/adb/ksud"` ⇒ args 不给时 ko 找的是 /data/adb/ksud(tmpfs 那条是**给了参数**
    #   之后的交付形状，#41/#56)。写清楚免得下一次再把"默认"读成 tmpfs(§6.282 那条结论以此为准)。
fi

echo "=== 1.66) ★AP_KEY＝主那条名单记录的 key(包名字符串)；默认不给＝交付形状逐字不变（§6.313⑦/例 117） ==="
#   为什么要有它：stage 里主条目一直是 `uid=$SUWID key=com.suw.manager`，改 uid 时 key **不跟着走**
#   ⇒ 第 151 发那格其实是"名字与 uid 不匹配"。格 X 要的是"只改 key"的单变量对，所以这个字段必须能单独拨。
if [ -n "${AP_KEY:-}" ]; then
    case "$AP_KEY" in
        *[!A-Za-z0-9._-]*|'' ) echo "[x] AP_KEY=[$AP_KEY] 含非法字符(只允许 字母数字 . _ -) ⇒ 停，别把串注进设备侧命令" ; exit 3 ;;
    esac
    A "printf '%s' '$AP_KEY' > /data/local/tmp/ksu_ap_key" >/dev/null
    A "ls -l /data/local/tmp/ksu_ap_key" | tr -s ' ' | sed 's/^/  AP_KEY='"$AP_KEY"' ⇒ /'
    echo "  开关内容读回=[$(A "cat /data/local/tmp/ksu_ap_key" | tr -d '\r\n')]  ★必须与上面 AP_KEY 逐字相同"
    echo "  ★生效证人＝stage 里那行「★AP_KEY 生效证人：主条目 uid=… key=[$AP_KEY]」＋ksuctl 自己打的 wrote … key=…（事后 grep 复证）"
else
    A "rm -f /data/local/tmp/ksu_ap_key" >/dev/null
    echo "  未给 AP_KEY ⇒ 不铺开关文件，stage 用默认 key=com.suw.manager（交付形状）"
fi

echo "=== 1.65) ★QUIET=1 才把那两个 quiet 开关铺上（§6.310：第 149/150 发我漏 touch ⇒ 跑成了交付形状） ==="
#   一手教训：`ksu_quiet_after_insmod`/`ksu_quiet_fixcfi` 在工具链里**没有任何生产者**，历史上全靠我手敲；
#   收窗时又会把它们删掉 ⇒ 下一发忘了 touch 就静悄悄变成"非 quiet"，而 runbook 里那一格写的是 quiet。
#   开关默认关（交付链行为逐字不变）；给了 QUIET=1 ⇒ touch 两个并**读回 ls**（没有产物就没有发生）。
if [ -n "${QUIET:-}" ]; then
    A "touch /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi; ls -l /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi" | tr -s ' ' | sed 's/^/  QUIET='"$QUIET"' ⇒ /'
    echo "  ★本格是 quiet 形状：装载后 stage 必须打印「★ksu_quiet_after_insmod 在」这一行才算生效（事后用 grep 复证）"
else
    echo "  未给 QUIET ⇒ 不铺 quiet 开关＝**交付(非 quiet)形状**；若这一格写的是 quiet，现在就停下去补，别开枪"
fi

echo "=== 1.7) ★官方 Manager 要能用，就得让 stage 起「抢装看门狗」：touch 这个开关(第 111 发钉出来的) ==="
