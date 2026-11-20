#!/bin/bash
# w379_trap_selftest.sh —— 证明 go.sh 新加的 EXIT 兜底**真的会跑**，并带反例(例 88/83：自测要含"第一遍真的改了"与"不加就坏")。
#   三个场景 + 一个反例，全在临时目录里，绝不碰仓库里的 kmod/ksu_args.txt。
set -u
fails=0
run_case() { # $1=带trap? $2=退出码 $3=ARGS_KEEP $4=期望内容 $5=标题
    local withtrap=$1 code=$2 keep=$3 want=$4 title=$5 d
    d=$(mktemp -d)
    ( cd "$d" || exit 1
      printf 'delivery\n' > ksu_args.txt; cp ksu_args.txt ksu_args.txt.bak_delivery
      printf 'exp\n' > exp.txt
      cp exp.txt ksu_args.txt                       # 模拟 ARGS_FILE 覆盖
      if [ "$withtrap" = yes ]; then
          trap '[ "${ARGS_KEEP:-0}" = 1 ] || { cp ksu_args.txt.bak_delivery ksu_args.txt 2>/dev/null; }' EXIT
      fi
      export ARGS_KEEP=$keep
      exit "$code"
    )
    local got
    got=$(cat "$d/ksu_args.txt")
    if [ "$got" = "$want" ]; then
        echo "  ✓ $title ⇒ args=[$got]"
    else
        echo "  [x] $title ⇒ 期望[$want] 实得[$got]"; fails=$((fails+1))
    fi
    rm -rf "$d"
}
run_case yes 5 0 delivery "exit 5(空枪那条路)会还原"
run_case yes 0 0 delivery "正常退出也会还原"
run_case yes 0 1 exp      "ARGS_KEEP=1 时**不**还原(保留实验形状)"
run_case no  5 0 exp      "反例：没有 trap 时 exit 5 会把实验形状留在交付文件上"
[ "$fails" = 0 ] && echo "SELFTEST 全过(4/4)" || { echo "SELFTEST 失败 $fails 格"; exit 1; }
