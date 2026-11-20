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
