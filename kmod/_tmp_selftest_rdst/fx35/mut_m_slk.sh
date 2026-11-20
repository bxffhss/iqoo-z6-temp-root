# --- 6b) 判据(十支；臂证人从腿顶的三个 WANT_* 现取，selftest 也读同一份) ---
if [ "$INMOD" != "1" ]; then
  if [ "$RC" = "0" ]; then
    echo "NP_VERDICT=未测(insmod 报 0 但 /proc/modules 里没有它 ⇒ 读数自相矛盾，别当结论)" >> $L
  else
    echo "NP_VERDICT=判负(带 rt_steps=$WANT_STEPS/rt_slack_kb=$WANT_SLACK 也被拒 rc=$RC ⇒ 看装载回执原因)" >> $L
  fi
elif [ "$ABI" != "$WANT_ABI" ]; then
  echo "NP_VERDICT=未测(件号读回 rt_abi=$ABI ≠ $WANT_ABI ⇒ 装上去的不是这一版件，本发所有读数不算)" >> $L
elif [ "$STEPSR" != "$WANT_STEPS" ]; then
  echo "NP_VERDICT=未测(命令行给了 rt_steps=$WANT_STEPS 却读回 $STEPSR ⇒ parse_args 没写成，先查参数名)" >> $L
  echo "NP_VERDICT=未测(命令行给了 rt_slack_kb=$WANT_SLACK 却读回 $SLKR ⇒ **旋钮没拧上**，这一格根本没测到余量)" >> $L
elif [ "$ST" = "21" ]; then
  echo "NP_VERDICT=停在搬副本那步(stage=21, cp_rc=$CPRC ⇒ 十有八九是 vmalloc 1.36MB+64KB 没给下来，(甲)这一格未测)" >> $L
elif [ "$COPY" != "1" ]; then
  echo "NP_VERDICT=未测(旋钮拧上了却没吃副本 copy=$COPY cp_rc=$CPRC ⇒ 这一格量的还是原件)" >> $L
elif [ "$CPSAME" != "1" ]; then
  echo "NP_VERDICT=未测(★副本与原件哈希不同 cp_same=$CPSAME sum_pre=$PSUM sum_cp=$CPH ⇒ 我换了被测对象，别看后面)" >> $L
elif [ "$ST" = "99" ] && [ "$RD" != "0" ]; then
  echo "NP_VERDICT=未测(上游 stage2 就失败 rd_rc=$RD ⇒ 我们那份 reader 没被问到)" >> $L
elif [ "$ST" = "99" ] && [ "$PRS" = "0" ]; then
  echo "NP_VERDICT=判正(★给了 64KB 余量就解析得动：nel=$NEL ver=$VER mls=$MLS ⇒ **(甲)越界读坐实**：第 81 发是 reader 飘出 vmalloc 末尾撞守护页 ⇒ 下一步量『飘了多少字节』)" >> $L
elif [ "$ST" = "99" ]; then
  echo "NP_VERDICT=判负但形状变了(给了余量仍返回 prs_rc=$PRS ⇒ **(甲)出局**，且这次不是复位＝错误可读 ⇒ 抄 ver=$VER mls=$MLS nel=$NEL 离线对，压力给(乙)内核态环境族)" >> $L
elif [ "$ST" = "-1" ]; then
  echo "NP_VERDICT=未测(在册却 stage=-1 ⇒ init 体一步都没跑，与 insmod_rc=$RC 矛盾，先查仪器)" >> $L
else
  echo "NP_VERDICT=停在第 $ST 步(★未定位：sym=$SYM slab=$SLAB rd=$RD prs=$PRS cp_rc=$CPRC load=$LR ⇒ 对照源码看那一步是什么)" >> $L
fi
sync

