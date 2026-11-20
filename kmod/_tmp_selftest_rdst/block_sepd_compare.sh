  ok=1
  [ "$r_why" = "$w_why" ] || ok=0
  [ "$r_n" = "$w_n" ] || ok=0
  [ "$r_at" = "$w_at" ] || ok=0
  [ "$r_ma" = "$w_ma" ] || ok=0
  [ "$r_lm" = "$w_lm" ] || ok=0
  [ "$r_bytes" = "$w_bytes" ] || ok=0
  [ "$r_sum" = "$w_fnv" ] || ok=0
  # ★读回那份的 md5 必须等于 PC 那一份：这是"内核里 staged 的字节＝我送进去的字节"的独立证人，
  #   与上面那些"解码读数对不对"是两件事(一件讲字节，一件讲解析)。
  [ "$r_md5" = "$w_md5" ] || ok=0
  # 记录渲染：why=0 且没截断⇒该有 n 行；why≠0⇒一行都不该有(REJECT 分支明写不许印)
  if [ "$w_why" = 0 ]; then
    if [ "$r_trunc" = 0 ] && [ "$r_stmts" != "$w_n" ]; then ok=0; fi
    if [ "$r_trunc" = 1 ] && [ "$r_stmts" -ge "$w_n" ]; then ok=0; fi
  elif [ "$r_stmts" != 0 ]; then ok=0; fi
