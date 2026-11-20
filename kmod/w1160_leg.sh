#!/system/bin/sh
# w1160_leg.sh —— 设备侧(0 枪)：只让**候选二进制**对每件夹具跑一遍 `setsepol <文件>`(默认 dry)，
#   把读数带 "RUN <文件>" 锚印成一条流。★设备侧不判断：判读全在 PC 的 `kmod/w1160_dev_preview_check.py`
#   ⇒ 这份件事后能重判(REJUDGE)，不必再碰机器(§347/§349 立的形状)。
# ★为什么这一跑值得单独发：候选件是 aarch64 **静态**二进制，"编得过"不等于"这台机的加载器肯装它"
#   (第六十五发那枚 PT_TLS align=8 的 Aborted 就是一手教训)；而 dry 路径连驱动 fd 都不开 ⇒
#   基线态、非 root、执法态都能跑，对设备**零写**(除了往 /data/local/tmp 放我们自己的件)。
D=${1:-/data/local/tmp/w1160}
B="$D/ksuctl_241"
[ -x "$B" ] || { echo "LEG=badbin path=$B"; exit 1; }
for f in ok1 ok3 ok9 ok600 bad_cmd bad_sub bad_nul bad_inner bad_len bad_hdr bad_tail; do
  echo "RUN $f.bin"
  "$B" setsepol "$D/$f.bin" 2>&1
  RC=$?
  echo "RC $f.bin $RC"
done
echo "END leg v1"
