#!/usr/bin/env bash
# w413 剩余项续跑（不改 kmod/w413_selftest_sweep.sh；item() 判据逐字复制自该件）
set -u
cd "G:/项目/Windows管理/usb/临时root" || exit 1
export PYTHONUTF8=1
export TMPDIR=/tmp
fail=0
OUT="G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/w413_rest_items.txt"
: > "$OUT"
item() {
    local name=$1 min=$2 pat=$3; shift 3
    local txt rc n
    txt=$("$@" 2>&1); rc=$?
    n=$(printf '%s\n' "$txt" | grep -cE "$pat")
    printf '### %s (rc=%s, 证据行=%s)\n' "$name" "$rc" "$n" >> "$OUT"
    printf '%s\n' "$txt" | tail -30 >> "$OUT"
    if [ "$rc" != 0 ]; then echo "  [BAD] $name => rc=$rc"; fail=1
    elif [ "$n" -lt "$min" ]; then echo "  [BAD] $name => 证据行只有 $n 条(期望>=$min)"; fail=1
    elif ! printf '%s\n' "$txt" | grep -qE 'PASS|对照 OK'; then echo "  [BAD] $name => 数到 $n 条但没有 PASS/对照 OK"; fail=1
    else echo "  [OK] $name (证据行 $n 条)"; fi
}
item "w404 词元计数(含 <6> 前缀反夹具)"      10 '\[OK\]' python kmod/w404_tokcount.py --selftest
item "w406 形状集合差(含 match-vs-search 牙)" 5 '^\[self\]' python kmod/w406_setdiff.py --self
item "w408 prune 三级分级(正对照＝三发已知 prune)" 1 '对照 OK' python kmod/w408_prune_audit.py --self
item "w419 接手清单自检(锚点漂移/形状/探测器 rc 形状)"  6 '^  \[OK\]' bash kmod/w419_handover_smoke.sh --self
item "run_pkgcheck(3b 包指纹注入五格)"        10 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_pkgcheck.sh
item "run_leg1only(LEG1ONLY=1 跳过第 4~7 步；不给＝交付形状一字不变)" 2 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_leg1only.sh
item "run_noreboot(NOREBOOT=1 不 reboot＋脏 boot 必拒；不给＝照旧 reboot)" 3 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_noreboot.sh
item "run_quietguard(quiet 形状不装 agent fd ⇒ 绝不派腿；两条证人各自能单独拦)" 4 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_quietguard.sh
item "run_exebit(第 69 发空枪：腿在设备上没 x 位⇒execve EACCES/exit=126；六格含正对照＋补不上＋读不到＋md5 不符)" 6 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_exebit.sh
item "run_sepd_leg(w1152 核内解码预演腿：分组/配对/取键/比对核/渲染核**全部从腿里现抽**；G2 那一格一手教训＝bash 把 GROUPS 当保留数组，赋值被无声忽略；正对照＋八条变异＋缺键反夹具)" 20 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_sepd_leg.sh
item "run_sepd_readout(w1153 链的**判读段**judge()：从链里现抽；★⑥a『内核读数差＝判负』与⑥b『期望表派生格差＝模型红』必须分两支(第 97 发那一格红在模型不红在被测)，want() 尾必须摘掉再取键，REJUDGE 重判只认现行表逐格重算；★匹配判据的词元要互斥：⑥b 那句原判词里写了『不写判负』两个否定字，被松匹配读成正向命中＝第一条假红)" 12 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_sepd_readout.sh
item "w1160_dev_preview_check(#241 设备侧那一跑的**离线重判**：喂 11-06 那份设备 raw＋期望表＋第 97 发内核证件；★设备不参与，判读件的牙由『改一份副本必须报红』那格在 w1160_run.sh 里当场证过；三方对表＝aarch64 内核/x86 宿主/aarch64 用户态)" 11 '\[OK\]' python kmod/w1160_dev_preview_check.py kmod/w103_evidence/w1160_dev_v2.raw.txt kmod/w1152_fixtures/expect.txt kmod/w103_evidence/w1153_leg_shot97.out
item "run_verdict18(#219 v2 九格：rd 读数形状四格(无换行/有换行/文件不在⇒errno 证人/空文件)＋判据五格(落地判正·范围丢掉判负·读不出未测·域走形未测·执法前后不一致未测))" 9 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_verdict18.sh
item "run_endpoint(w682_rr.py 的 HRMT_CLI/HRMT_CONFIG 端点闸：指错不许静默回退到另一台机)" 7 '\[OK\]' env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL bash kmod/_tmp_selftest_rdst/run_endpoint.sh
item "run_verdict35[77 发臂](无参臂 w1035：块从腿里现抽；WANT_STEPS 现读；好件格＋差分变异；★含 BR 探测器自证那一格)" 20 '\[OK\]' env LEG=kmod/w1035_noparam_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[78 发臂](同一把尺量 w1038：判据块从**那条腿**里现抽，六格＋两条差分变异)" 20 '\[OK\]' env LEG=kmod/w1038_steprzero_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[79 发臂](steps=1 那条臂 w1042：多一格「stage2 返回错误⇒判负」＋多一条变异 M3)" 20 '\[OK\]' env LEG=kmod/w1042_step1_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[80 发臂](steps=2 那条臂 w1045：多 C8「prs_rc≠0⇒判负」＋C9「上游 stage2 断⇒未测，不许替它答题」＋变异 M4/M5；★11-01 修好探测器后这两格才**头一回真跑**)" 22 '\[OK\]' env LEG=kmod/w1045_step2_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[82 发臂](steps=2×slack=64 那条臂 w1063：多 C10 旋钮/C11 件号 rt_abi/C12 没吃副本/C13 ★cp_same=0 换了被测对象/C14 停在搬副本 ＋变异 M6/M7/M8)" 22 '\[OK\]' env LEG=kmod/w1063_step2_slack_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[83 发臂](轮询器那条腿 w1069：判据块与 82 发逐字同一把尺＝换了证人通道不许换判据)" 22 '\[OK\]' env LEG=kmod/w1069_step2_pol_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[84 发臂](紧循环＋段内计数器那条腿 w1087：判据块与 82/83 两臂逐字同一把尺；三份现抽块 md5 相同)" 22 '\[OK\]' env LEG=kmod/w1087_substep_pol_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "run_verdict35[85 发臂](环＋快照读点那条腿 w1093：判据块与 82/83/84 四臂逐字同一把尺＝换了仪器不许换判据；WANT_ABI 现读＝85)" 22 '\[OK\]' env LEG=kmod/w1093_hist_pol_leg.sh bash kmod/_tmp_selftest_rdst/run_verdict35.sh
item "w418 记忆文件结构闸(自我复制/控制字节/断链索引)"  7 '\[OK\]' python kmod/w418_memcheck.py --self
item "w415 文档陈旧说法审计(正/负夹具＋两道范围闸＋豁免表有牙＋★加粗登记的 md5 也要验)" 15 '\[OK\]' python kmod/w415_doc_audit.py --self
item "w1170(#236 证人资格闸：四把尺各有牙＋ksud 全绿不许判 landed)" 14 '\[OK\]' python kmod/w1170_sepol_witness_gate.py --self
item "w1170 实跑(#236 证据链现读本地真件：桩/分发/ksud 文案/两串为 0)" 4 '\[OK\]' python kmod/w1170_sepol_witness_gate.py
item "w597(第 47 发属主判据三腿)双向静态牙：打字形状/chmod 666/证人先于执法/腿文件在名单里"  13 '\[OK\]' bash kmod/w597_arm_selftest.sh
item "W795 设备腿产物权限闸(写产物＋翻执法的腿：chmod 666 必须排在执法之前；含豁免表死牙)"  8 '\[OK\]' python kmod/w795_leg_guard.py --self
item "W774 pbin 维持件判定三态＋//deleted 正对照"  4 '\[OK\]' sh kmod/w774_pbin_keeper.sh selfcheck
item "W912 深度2/深度3 改道配对判语器：三出口合成件＋变异＋负对照"  5 '\[OK\]' python kmod/w912_ringpair.py --selftest
item "W950 双写者静态闸(双向自测)"  4 '\[OK\]' python kmod/w950_dual_writer_sweep.py --selftest
item "W951 管道末端 rc 静态闸(双向自测＋一手误报四例)"  6 '\[OK\]' python kmod/w951_pipe_rc_sweep.py --selftest
item "W1162 接线静态闸(正跑全绿＋七条变异全被抓；含 11-07『include 只在注释里』那条)" 40 '\[OK\]' python kmod/w1162_wire_check.py --self kmod/ksu_dropped_stub_rc76.c
item "W1180 punch 等待上限闸(两道叠加 1600s 有界＋RC=/post= 证人＋四变异有牙)" 40 '\[OK\]' python kmod/w1180_punchwait_gate.py --self
echo "REST_ITEMS=34 REST_FAIL=$fail"
