judge() {
  CNT=$(grep -a '^COUNTS pass=' "$LEGARC" | tail -1)
  PASSN=$(sed -n 's/^COUNTS pass=<REDACTED> .*/\1/p' <<<"$CNT"); FAILN=$(sed -n 's/.* fail=\([0-9]*\).*/\1/p' <<<"$CNT")
  echo "    腿的计数行=[$CNT] ⇒ pass=<REDACTED> fail=${FAILN:-空}"
  echo "    没过的格：$(grep -a '^CASEOK ' "$LEGARC" | awk '$3==0{print $2}' | tr '\n' ' ')"
  # ★★读法⑦(字节忠实性)＋⑥a/⑥b(分岔)在**同一趟**循环里算：分两趟就是两把尺，一改一漏就不同源。
  # ★★取数一律走 bash 自己的展开，不逐格调 sed/awk/grep：本机是 Windows＋Git Bash，一次 fork 上百毫秒，
  #   十二格 × 每格十次 fork 能把判读段拖成几十秒(专属自测第一次就是"卡住"在这——其实是慢，不是死)。
  declare -A TJ
  while read -r tn trest; do [ -n "$tn" ] && TJ[$tn]="$tn $trest"; done < <(grep -v '^#' "$TBLREPO")
  INSTR=0; DEC=0; DRV=0; MATCH=0; DECL=""; DRVL=""; SP=""; VV=""
  packs() { SP=";"; local tk; for tk in $1; do SP="$SP$tk;"; done; }   # `key=v …` → `;key=v;…`
  tkv()   { local t="${1#*;$2=}"; if [ "$t" = "$1" ]; then VV=""; else VV="${t%%;*}"; fi; }
  # ★★读法⑦的执行：逐格把"内核里那份 staged 字节的 md5/FNV"与 PC 期望表对表；对不上 ⇒ **仪器红**
  #   (字节没忠实送到)，绝不能算"内核解错了"。同一趟里再算⑥a/⑥b 的分岔：
  #     决定性三把(why/n/bad_at)差 ⇒ 真·跨架构不一致(判负，是发现)；
  #     派生两把(max_arg/lenmatch)差 ⇒ 期望表这个**模型**红(不是被测)，交给 w1154 三方对表裁决。
  # ★★取数前必须把行尾的 `want(…)` 摘掉：腿把那一条**开枪时的期望**原样回抄在同一行里，而 `sed '.*[ =]n='`
  #   这种贪婪写法会命中**最后一个** `n=`＝want 里那个。上一版不摘，就是在拿"腿自己 echo 的旧表"比"现行表"——
  #   真读数被架空，模型差还会被数成读数差(＝例 222/231③ 那一族的另一个身位，这次是我自己的判读段)。
  while read -r cl; do
    cl=${cl%% want(*}
    w=($cl); nm=${w[1]:-?}
    row=${TJ[$nm]:-}
    if [ -z "$row" ]; then echo "    [仪器红] $nm 不在现行表里 ⇒ 这一格没被对过，不许算进满分"; INSTR=1; continue; fi
    packs "$cl"; cs="$SP"; packs "$row"; ts="$SP"
    tkv "$cs" ddrc; drc="$VV"; tkv "$cs" in_md5; got="$VV"; tkv "$cs" in_fnv; gotf="$VV"
    tkv "$ts" md5; want="$VV"; tkv "$ts" fnv; wantf="$VV"
    if [ "$drc" != 0 ] || [ -z "$got" ] || [ "$got" != "$want" ] || [ -z "$gotf" ] || [ "$gotf" != "$wantf" ]; then
      echo "    [仪器红] $nm ddrc=${drc:-空} in_md5=${got:-空}/${want:-无} in_fnv=${gotf:-空}/${wantf:-无}"
      INSTR=1
    fi
    d=""; h=""; same=1
    for k in why n bad_at; do
      tkv "$cs" "$k"; dv="$VV"; tkv "$ts" "$k"; tv="$VV"
      { [ -n "$dv" ] && [ "$dv" = "$tv" ]; } || { d="$d $k(内${dv:-空}≠表${tv:-无})"; same=0; }
    done
    for k in max_arg lenmatch; do
      tkv "$cs" "$k"; dv="$VV"; tkv "$ts" "$k"; tv="$VV"
      { [ -n "$dv" ] && [ "$dv" = "$tv" ]; } || { h="$h $k(内${dv:-空}≠表${tv:-无})"; same=0; }
    done
    [ "$same" = 1 ] && MATCH=$((MATCH+1))
    [ -n "$d" ] && { DEC=$((DEC+1)); DECL="$DECL $nm[${d# }]"; }
    [ -n "$h" ] && { DRV=$((DRV+1)); DRVL="$DRVL $nm[${h# }]"; }
  done < <(grep -a '^CASE ' "$LEGARC")
  [ "$INSTR" = 0 ] && echo "    字节忠实性：每格 in_md5/in_fnv 都与 PC 那份同数，且 ddrc=0 ⇒ 送进去的就是它解的"
  ROWS=${ROWS:-$(grep -vc '^#' $TBLREPO | tr -dc '0-9')}
  echo "    分岔计数：决定性三把差的格=$DEC ｜ 只差派生两把的格=$DRV ｜ 六把全等的格=$MATCH/$ROWS"
  [ -n "$DECL" ] && echo "      ⑥a(读数差)：$DECL"
  [ -n "$DRVL" ] && echo "      ⑥b(模型差)：$DRVL ⇒ 那是期望表(仪器)红，跨架构那一格改跑 bash kmod/w1154_run.sh 三方对表定性"
  grep -aq '^IDENTITY=ok$' "$LEGARC" && IDT=1 || IDT=0
  grep -aq 'FAIL=insmod 非 0' "$LEGARC" && INSBAD=1 || INSBAD=0
  grep -aqE '^FAIL=(ko 不在|期望表不在|ctl.txt|件 md5|表 md5)' "$LEGARC" && REFUSE=1 || REFUSE=0
  # 控制格(与期望表无关，重判时照样算数)：空流那一格＋收尾 rmmod 那一格
  grep -aq '^CASEOK EMPTY_CTRL 1$' "$LEGARC" && grep -aq '^CASEOK RMMOD 1$' "$LEGARC" && CTROK=1 || CTROK=0
  if   [ "${READY:-1}" != 1 ]; then V="未测(读法①：腿两行没等到)"
  elif [ "$REFUSE" = 1 ]; then V="未测(读法②：腿的前置闸拒了，什么都没解)"
  elif [ "$INSBAD" = 1 ]; then V="未测(读法③：探针没装进去)"
  elif [ "$IDT" != 1 ]; then V="未测(读法②：件/表两端身份没对上，先修仪器)"
  elif [ "$INSTR" = 1 ]; then V="未测(读法⑦：有格的字节忠实性红，不能算被测)"
  elif [ "$CTROK" != 1 ]; then V="判据不齐(两把控制格没双双绿：EMPTY_CTRL/RMMOD)"
  elif [ "${REJ:-0}" = 1 ]; then
    # ★重判模式：腿自己那份 pass/fail 是**开枪时那张表**的账(表后来被修过就必然带旧账)，
    #   所以满分只认"按现行表逐格重算出来的 MATCH＝ROWS"，同时把旧账原样印出来当历史证人。
    echo "    重判口径：腿自计 pass=<REDACTED> ⇒ 现行表逐格重算 $MATCH/$ROWS"
    if [ "$MATCH" = "$ROWS" ]; then V="判正(REJUDGE＝0 枪重判：$ROWS 格六把读数与现行表全等)"; else V="判据不齐(重判 $MATCH/$ROWS；⑥a=$DEC ⑥b=$DRV)"; fi
  elif [ "${PASSN:-0}" = "$FULLPASS" ] && [ "${FAILN:-1}" = 0 ]; then V="判正"
  elif [ "$DEC" -gt 0 ]; then V="判负(读法⑥a：字节两端一致，而内核的 why/n/bad_at 与宿主期望不同＝跨架构不一致)"
  elif [ "$DRV" -gt 0 ]; then V="模型红(读法⑥b：期望表的派生格与内核读数不符＝仪器红；跨架构那一格由 w1154 三方对表裁决)"
  else V="判据不齐(pass=<REDACTED> fail=$FAILN)"; fi
  echo "  ★SHOT${SHOT}_SEPD=$V ｜ 口径：只答『aarch64 内核读数＝不＝宿主读数』，不答『规则能落地』(那是 #238 的 (2)(3) 段)"
  echo "  ★这一发**没碰** /sys/fs/selinux/，**没改**运行期策略，**没动**出货 ko 字节；探针由腿自己 rmmod。"
}
