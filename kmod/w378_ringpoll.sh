#!/bin/bash
# w378_ringpoll.sh —— 从 **PC 侧**读设备内核环形缓冲的"计数证人"，不要 root、不改交付链。
#   为什么要它(§6.285)：非 quiet 窗口里 dmesg.live 被 stage 自己的收尾(ksu_one_stage.sh:827)删掉，
#     之后 840 行才 tail 一份整环尾块 ⇒ 拉回来的文件按构造就只剩最后 200 KB，装载期那一段**我们亲手销毁**；
#     而整环(本机 ~2.3 MB)在 KSUBEAT 洪水下只活 ~280 秒 ⇒ 收尾再 dump 也够不着 insmod 那一刻。
#   新用到的一手事实：**shell(uid 2000) 就能跑 dmesg**(第 134 发实测 rc=0 且出全文)⇒ 不必借 root 信道。
#   计数一律用 awk 一遍扫完整环 ⇒ 一次 adb 调用拿全部证人，2.3 MB 不 over the wire。
#   还顺手带 ring 的 首/末时间戳+字节 ⇒ 同一来源可量化"洪水速率"(质量参数 vs 默认参数 的代理读数)。
# 用法：bash kmod/w378_ringpoll.sh <存证前缀> <间隔秒> <轮数>
set -u
cd "$(dirname "$0")/.." || exit 1
TAG=${1:?用法: w378_ringpoll.sh <tag> <间隔> <轮数>}
TAG=${TAG#w}          # ★文件名只算一次：以前传 w378self 会得出 ww378self_…(glob 双前缀坑)
IV=${2:-5}
N=${3:-12}
OUT=kmod/w103_evidence/w${TAG}_ringpoll.txt
: > "$OUT"

# ★远端这段只用单引号包住，本机不展开；设备上全是 $() 与 awk，别在这里嵌双引号(例 76/例 98)
REMOTE='u=$(cut -d" " -f1 /proc/uptime); dmesg 2>/dev/null | awk -v u="$u" "
/tp_marker:/{tp++}
/mass mark/{mmoff++}
/mark-running/{mr++}
/load_allow_uid/{la++}
/ADD_TRY_UMOUNT/{au++}
/allowlist version:/{av++}
/KSUBEAT L5 before ksu_load_allow_list/{l5++}
/Crowning manager/{cr++}
/prune uid:/{pr++}
/dispatcher entered/{de++}
NR==1{f=\$0}
{last=\$0; b+=length(\$0)+1}
END{
  printf \"up=%s bytes=%d tp=%d mmoff=%d mr=%d la=%d au=%d av=%d l5=%d cr=%d pr=%d de=%d first=[%s] last=[%s]\n\", u, b, tp+0, mmoff+0, mr+0, la+0, au+0, av+0, l5+0, cr+0, pr+0, de+0, substr(f,1,70), substr(last,1,70)
}"'

echo "# w378 ringpoll tag=$TAG 间隔=${IV}s 轮数=$N 起=$(date '+%H:%M:%S')" >> "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
    i=$((i + 1))
    R=$(MSYS_NO_PATHCONV=1 adb shell "$REMOTE" 2>&1 | tr -d '\r' | tail -1)
    echo "[$(date '+%H:%M:%S')] 轮$i $R" >> "$OUT"
    # 自证(例 98)：这一轮如果**一个证人都是 0**，多半是 adb 掉了或 awk 坏了，不当否据
    case "$R" in
        *up=*) ;;
        *) echo "    !! 这行没有 up= ⇒ 读数器这一轮没跑到，仅记录不判读" >> "$OUT" ;;
    esac
    [ "$i" -lt "$N" ] && sleep "$IV"
done
echo "# 结束=$(date '+%H:%M:%S') 共 $i 轮" >> "$OUT"
