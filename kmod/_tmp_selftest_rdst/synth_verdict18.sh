say() { echo "$1"; }
# --- 6) 判据(只答"落没落"；带牙：读数空、读数走形都不许给结论) -------------
say "DOM_AGREE=$([ "$DOM_NOW" = "$IDZ" ] && echo 是 || echo 否)  (read 与 id -Z 两把独立读数应当一致)"
say "DOM_STABLE=$([ "$DOM_NOW" = "$DOM_AFTER" ] && echo 是 || echo 否)  (翻执法前后应当同一个域；不一致⇒中途有人换了域，本题读数不可用)"
if [ -z "$DOM_NOW" ]; then
  say "MLS_RANGE_VERDICT=未测(在线域读不出 read_rc=$S0_RCODE 且 id -Z=[$IDZ] ⇒ 本题没被问过)"
elif [ "$DOM_NOW" != "$DOM_AFTER" ]; then
  say "MLS_RANGE_VERDICT=未测(执法前=[$DOM_NOW] 执法后=[$DOM_AFTER] 两个读数不一致 ⇒ 先查谁在中途换域)"
elif [ "$DOM_NOW" = "$WANT_DOM" ]; then
  say "MLS_RANGE_VERDICT=判正(★装载期那段带范围的串**落在**在线 subject 上：DOM=[$DOM_NOW]) ※只证落没落；支配那一半按活策略对本 subject 恒无判别力，见文件头①②③"
elif [ "$DOM_NOW" = "$BASE_DOM" ]; then
  say "MLS_RANGE_VERDICT=判负(请求=[$WANT_DOM] 在线=[$BASE_DOM] ⇒ 范围被丢掉/归一化，DOM 这条路给不出带范围的 subject)"
else
  say "MLS_RANGE_VERDICT=未测(在线域=[$DOM_NOW] 既不是请求串也不是交付基线 ⇒ DOM 走形，先查装载期再谈本题)"
fi
say "MLS_SHELL_ARM=不适用(活策略现查：shell∈mlstrustedsubject，20/20 条 dir-file 约束都豁免它 ⇒ S/A 两组的绿红都**不能**读成范围在支配)"

