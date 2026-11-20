#!/usr/bin/env bash
# w413_selftest_sweep.sh —— 把散在多处的**离线**自测收成一条命令，每次动工具链就跑一遍。
#   规矩(例 83/88/92)：判据自己要有牙 ⇒ 这里不数"有没有 PASS 这个词"就算完，
#   而是①每项都要有非空输出、②要打出该项自测的**断言条数**、③任一项红就整体非零退出。
#   ★只跑离线件：设备侧 `sh -n` 那一格要 adb 在线才做，掉线时**显式说"这格没跑"**，不当通过(例 80)。
set -u
cd "$(dirname "$0")/.." || exit 1
# ★GBK 控制台里 python 打「⇒」会抛 UnicodeEncodeError(10-18 实测：w408/w415 两件的 --self 各炸一次)。
#   写在这里而不是指望调用者带环境变量——这条命令是"上机前最后一道闸"，它自己不能看调用者的脸。
export PYTHONUTF8=1
export W413_SWEEP=1   # 给 w419 的递归保险用(见 kmod/w419_handover_smoke.sh)
#   ★11-07 15:5x：临时目录必须落在 POSIX 的 /tmp，不能看调用者的脸。
#     调用者若带 Windows 临时目录(TMPDIR=C:\...\Temp)，Git Bash 的 mktemp -d 会给出反斜杠路径，
#     几份"把 /data/local/tmp/ sed 成 $W 再 eval"的离线自测会把路径走形 ⇒ 假红且拖到像挂死。
#     一手对照：02:55 全绿证件 w413_sweep_1107-0255.txt 里六处"临时件留在"全是 /tmp/tmp.XXXXXX；
#     Windows 原生 python 不认 /tmp，tempfile 仍落 AppData\Local\Temp ⇒ 这一行不碰 python 侧。
#     另：这几格本来就慢(run_ringend 单格 1m47s、整闸 02:55→03:04 约 9 分钟)，别拿短 timeout 当"挂死"。
export TMPDIR=/tmp
fail=0
W103=kmod/w103_evidence
mkdir -p "$W103"
TAG=$(date +%m%d-%H%M)
OUT="$W103/w413_sweep_$TAG.txt"
: > "$OUT"

item() { # $1=名字 $2=期望最少"证据行"条数 $3=证据行的正则 $4..=命令
    local name=$1 min=$2 pat=$3; shift 3
    local txt rc n
    txt=$("$@" 2>&1); rc=$?
    n=$(printf '%s\n' "$txt" | grep -cE "$pat")
    printf '### %s (rc=%s, 证据行=%s 匹配=[%s])\n' "$name" "$rc" "$n" "$pat" >> "$OUT"
    printf '%s\n' "$txt" | tail -30 >> "$OUT"
    # ★三道：①rc 要 0；②"证据行"要数到最少 N 条(工具静默空跑＝0 条＝红，这次真抓到一次)；
    #          ③还要有它自己那句 PASS(否则数到 N 条也可能全红)。
    if [ "$rc" != 0 ]; then echo "  [BAD] $name ⇒ rc=$rc"; fail=1
    elif [ "$n" -lt "$min" ]; then echo "  [BAD] $name ⇒ 证据行只有 $n 条(期望≥$min，锚点/文案/参数变了？)"; fail=1
    elif ! printf '%s\n' "$txt" | grep -qE 'PASS|对照 OK'; then echo "  [BAD] $name ⇒ 数到 $n 条但没有 PASS/对照 OK 那句"; fail=1
    else echo "  [OK] $name (证据行 $n 条＋PASS 句都在)"; fi
}

echo "=== 1) shell 层语法闸(bash -n) ==="
for f in kmod/go.sh kmod/push_ksu.sh kmod/w161_teardown.sh kmod/w405_watch.sh kmod/w410_watch.sh kmod/w413_selftest_sweep.sh kmod/w419_handover_smoke.sh kmod/_tmp_selftest_rdst/run_dom.sh kmod/_tmp_selftest_rdst/run_dommap.sh kmod/_tmp_selftest_rdst/run_shbin.sh kmod/_tmp_selftest_rdst/run_cellprep.sh kmod/w425_swap.sh kmod/w425_clean.sh kmod/w426_enforce.sh kmod/w427_cell_prep.sh kmod/w428_watch.sh kmod/w429_termux_leg.sh kmod/w431_pack_z6root.sh kmod/z6root.sh kmod/w433_slide_solve.sh kmod/_tmp_selftest_rdst/run_z6pack.sh kmod/_tmp_selftest_rdst/run_slide.sh kmod/_tmp_selftest_rdst/run_nosuw.sh kmod/w448_nosuw_mksh.sh kmod/w450_close.sh kmod/_tmp_selftest_rdst/run_teardownlegs.sh kmod/w451_z6nosuw_mksh.sh kmod/ui_grant.sh kmod/w458_selftest_uinput.sh kmod/w459_leg_live.sh kmod/_tmp_selftest_rdst/run_rowpick.sh kmod/w483_rm_kd.sh kmod/_tmp_selftest_rdst/run_rleg.sh kmod/w495_ksud_swap.sh kmod/w500_soft_reboot_leg.sh kmod/w501_after_leg.sh kmod/w503_teardown_leg.sh kmod/remote_permcheck.sh kmod/remote_permcheck2.sh kmod/remote_fdinstall_audit6.sh kmod/remote_ksu_rc73.sh kmod/_tmp_selftest_rdst/run_fdkeepalive.sh kmod/w552_root_bundle.sh kmod/w553_drive.sh kmod/w556_zgwatch.sh kmod/w165b_adb_clean.sh kmod/w567_su_abs_leg.sh kmod/w567_root_proof.sh kmod/w572_root_proof.sh kmod/w573_su_witness.sh kmod/w579_enforce.sh kmod/w589_watch_arm.sh kmod/w590_enf_marker.sh kmod/w591_su_arm.sh kmod/w558_rm3.sh kmod/w600_mgrwatch.sh kmod/w601_mgrlaunch.sh kmod/w602_mgrwatch_selftest.sh kmod/w603_home_cell.sh kmod/w605_pre_census.sh kmod/w615_fdshape.sh kmod/w619_kd_why.sh kmod/w625_seedrestart.sh kmod/w629_B_loop.sh kmod/w670_gate_test.sh kmod/remote_ksu_rc74.sh kmod/remote_ksu_rc73.sh kmod/w690_ksubirth.sh kmod/w694_ringwitness.sh kmod/w720_ksubirth_dump.sh kmod/w731_root_sampler.sh kmod/w732_badge_watch.sh kmod/w745_badge_watch2.sh kmod/w767_close_shot53.sh kmod/w770_zipcheck_dev.sh kmod/w774_pbin_keeper.sh kmod/w777_root_tool.sh kmod/w786_break_dev.sh kmod/w789_close_dev.sh kmod/w797_umount_only.sh kmod/w810_window_watch.sh kmod/remote_ksu_rc74c.sh kmod/w813_enforce_only.sh kmod/remote_ksu_rc74b.sh cm57/build_sustatic.sh kmod/w912_appleg.sh kmod/_tmp_selftest_rdst/run_leg1only.sh kmod/_tmp_selftest_rdst/run_quietguard.sh kmod/_tmp_selftest_rdst/run_verdict18.sh kmod/_tmp_selftest_rdst/run_exebit.sh kmod/_tmp_selftest_rdst/run_endpoint.sh kmod/w1018_mlsrange_leg.sh kmod/w996_shot64.sh kmod/w1021_shot68.sh kmod/w1032_emptyinit_leg.sh kmod/w1033_shot76.sh kmod/w1035_noparam_leg.sh kmod/w1036_shot77.sh kmod/w1038_steprzero_leg.sh kmod/w1039_shot78.sh kmod/w1042_step1_leg.sh kmod/w1043_shot79.sh kmod/w1045_step2_leg.sh kmod/w1046_shot80.sh kmod/w1050_asan_probe.sh kmod/w1052_asan_scan.sh kmod/w1053_stack_probe.sh kmod/w1054_stack_chain.sh kmod/w1055_kstack_depth.sh kmod/w1063_step2_slack_leg.sh kmod/w1064_shot82.sh kmod/w1069_step2_pol_leg.sh kmod/w1071_poll_mech_dev.sh kmod/w1072_shot83.sh kmod/w1087_substep_pol_leg.sh kmod/w1088_shot84.sh kmod/w1093_hist_pol_leg.sh kmod/w1094_shot85.sh kmod/w1098_pstore_leg.sh kmod/w1099_shot86.sh kmod/w1100_shot87.sh kmod/w1101_shot88.sh kmod/w1109_shot89.sh kmod/w1109_verify_remote.sh kmod/w1112_shot91.sh kmod/w1113_shot92.sh kmod/_tmp_selftest_rdst/run_leg1only.sh kmod/_tmp_selftest_rdst/run_noreboot.sh kmod/_tmp_selftest_rdst/run_verdict35.sh kmod/w1114_shot93.sh kmod/w1117_shot94.sh kmod/w1116_verify_community.sh kmod/w1118_verify_after.sh kmod/w1119_tmap_roundtrip.sh kmod/w1120_tmap_verify_remote.sh kmod/w1121_typeinsert_verify_remote.sh kmod/w1123_typeinsert_check.sh kmod/w1125_community_cost_remote.sh kmod/w1126_community_cost.sh kmod/w1129_newtype_verify_remote.sh kmod/w1131_after_newtype_remote.sh kmod/w1130_shot95.sh kmod/w1135_ksud_ioc_face_remote.sh kmod/w1141_polload_build.sh kmod/w1141_run.sh kmod/w1142_polload_leg.sh kmod/w1143_bprime_chain.sh kmod/w1150_arm_tool_build.sh kmod/w1151_sepd_build.sh kmod/w1151_run.sh kmod/w1152_sepd_leg.sh kmod/w1153_sepd_chain.sh kmod/_tmp_selftest_rdst/run_sepd_leg.sh kmod/w1154_run.sh kmod/w1154_remote.sh kmod/_tmp_selftest_rdst/run_sepd_readout.sh kmod/w1155_run.sh kmod/w1155_remote.sh kmod/w1156_run.sh kmod/w1156_remote.sh kmod/w1157_diag.sh kmod/w1158_verify.sh kmod/w1159_run.sh kmod/w1159_remote.sh kmod/w1160_run.sh kmod/w1160_leg.sh kmod/w1161_run.sh kmod/w1161_remote.sh kmod/w1162_run.sh kmod/w1162_remote.sh kmod/w1163_verify.sh; do
    if bash -n "$f" 2>/dev/null; then echo "  [OK] $f"; else echo "  [BAD] $f 语法不过"; fail=1; fi
done
echo "=== 1b) python 层语法闸(py_compile；bash -n 套在 .py 上是假闸) ==="
for f in kmod/w404_tokcount.py kmod/w406_setdiff.py kmod/w408_prune_audit.py kmod/w415_doc_audit.py kmod/w418_memcheck.py kmod/w436_mkctl.py kmod/w457_ime_probe.py kmod/row_pick.py kmod/prof_gate.py kmod/w465_backtick_guard.py kmod/w502_docsync.py kmod/w517_docsync.py kmod/w538_add_fdguard.py kmod/w540_append_6394.py kmod/w541_docsync.py kmod/w544_fd_analysis.py kmod/w557_seed_abort_table.py kmod/w558_mk_rm3.py kmod/w673_docsync.py kmod/w675_docsync2.py kmod/w680_docsync3.py kmod/w682_rr.py kmod/w685_add_birthfd.py kmod/w688_docsync4.py kmod/w707_docsync5.py kmod/w689_add_birthfd2.py kmod/w691_birth_test.py kmod/w709_docsync6.py kmod/w719_ring_reconcile.py kmod/w726_docsync7.py kmod/w733_badgetext.py kmod/w735_docsync8.py kmod/w751_docsync9.py kmod/w758_docsync10.py kmod/w769_docsync11.py kmod/w787_live_analyze.py kmod/w793_docsync12.py kmod/w795_leg_guard.py kmod/w801_docsync13.py kmod/w814_docsync14.py kmod/w820_add_birthfd3.py kmod/w821_birth_test3.py kmod/w822_gen_rc74c_build.py kmod/w912_ringpair.py kmod/w950_dual_writer_sweep.py kmod/w951_pipe_rc_sweep.py kmod/w1047_fnv64.py kmod/w1056_kernel_stack_sum.py kmod/w1057_string_provenance.py kmod/w1085_substep_patch.py kmod/w1128_ksud_ioctl_scan.py kmod/w1133_ksud_ioc_sites.py kmod/w1152_sepd_fixtures.py kmod/w1162_wire_check.py kmod/w1170_sepol_witness_gate.py kmod/w1180_punchwait_gate.py; do
    if python -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f" >/dev/null 2>&1; then
        echo "  [OK] $f"
    else
        echo "  [BAD] $f 编译不过"; fail=1
    fi
done

echo "=== 2) 离线自测集(每项都要数得出证据行；条数不写死，红绿由 rc＋证据行＋PASS 句三道定) ==="
#   ★注意三个件的自测参数**不一样名**：w404 是 `--selftest`，w406/w408 是 `--self`。
#     写错不报错——它会把 `--self` 当目录名、静默空跑、rc=0(这一格就是本次自测真抓到的)。
item "run_ringend(T2 死前整环 dump)"        20 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_ringend.sh
item "run_rootprobe(T2.6 ROOTPROBE)"        12 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_rootprobe.sh
item "run_slots(T2.7 CFIFIX 原件 pull)＋顺序三断言"  16 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_slots.sh
item "run_dumpleg(T2.8 诊断 dump：pull＋gzip 解回比 md5)"  9 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_dumpleg.sh
item "run_teardownlegs(#153 收尾两条新腿：CLOSEFALLBACK 替代腿默认关/md5 不符零敲键＋T5 复位后复读)" 20 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_teardownlegs.sh
#   ★真实条数以它自己那句「共 N 项断言」为准(今天 N=21)，这里的 18 只是防"静悄悄空跑/切片失效"的下界。
item "run_dom(#117 形状词『域=X』的生产者：stage 读开关＋生效证人两支＋go.sh 校验/清理)" 18 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_dom.sh
#   ★下界 15(真实条数以它自己那句「共 N 项」现数，今天 N=18)：测 go.sh §1.69 的 SHBIN 开关＋第 5 步两端 md5 硬闸
item "run_shbin(#117 第二把生产者：SHBIN 开关＋『推哪一支』的两端 md5 闸)" 15 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_shbin.sh
#   ★下界 18(真实条数看它自己那句，今天 23)：§6.353 的「每条记录各自的域」——stage 的 dom_for ＋ go.sh §1.68b
item "run_dommap(按 uid 的域映射表：dom_for 五种命中形状＋DOM_MAP 校验/清理)" 18 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_dommap.sh
#   ★下界 15(真实条数看它自己那句，今天 20)：w427「开枪前参数现取」那两道闸——
#     整行精确匹配(同前缀包不许捞进来)＋整串形状闸(夹换行的 DOM_MAP)＋文案与 fail 同源；五路变异逐条判过有牙。
item "run_cellprep(下一格参数现取：包名整行匹配＋DOM_MAP 整串形状＋预检文案同源)" 15 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_cellprep.sh
#   ★一键包的忠实性闸（md §6.356）：测的是"包有没有把已验证的链抄全"——punch 参数逐 token 对表、
#     落点/标签从 args 反推、抢装看门狗、实验开关全删、每件载荷都有指名消费者。它要先跑打包脚本才有清单可查。
item "run_z6pack(z6root 一键包：punch 参数逐 token 对表＋形状四件＋清单消费者＋slide 自解三件同源＋FDKA **默认不铺**四件含反夹具/删净清单/同一份代码/入口开关反误伤＋教程三句＋★危害警示两处都在(⑧a3/⑧a4)；⑧ 那组转过两次向：旧牙要求'包里真铺上常驻开关'，10-22 改成'不许铺＋明面写默认不铺'(§6.394)，10-23 再加'必须写清它会把 zygote 打进 SIGABRT'(§6.400))" 45 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_z6pack.sh
#   ★下界 15(真实条数以它自己那句为准，今天 21)：#146 设备侧 slide 求解器——
#     正对照＝真数据标定对必须逐字复现 PC 那次答案(468/401/16/SLIDE 2521000000)；
#     另外钉"进位夹具"(低段相加溢出 2^32 的 slide，专打 64 位当 double 用那种错)与四种失败形状。
item "run_slide(#146 slide 自解：标定对＋进位夹具＋失败形状必须自己说不解)" 15 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_slide.sh
#   ★下界 18(真实条数看它自己那句，今天 29)：#145 的 NOSUW 开关——
#     A/B/C 三组是静态闸(位置、两块闸、派发只有一份)，D 组是**把开关块切出来真跑**三种形状
#     (不给⇒交付／给了⇒Manager／uid 取不到⇒退回交付并打 [!]) ⇒ "默认关"不是靠我说。
item "run_nosuw(#145 NOSUW 开关：静态＋切片真跑三种形状＋反夹具)" 18 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_nosuw.sh
#   ★16:5x：这两格把 $PWD(/g/项目/... 形式) 传给 **Windows 原生 python**。本会话注入的
#     MSYS_NO_PATHCONV=1 + MSYS2_ARG_CONV_EXCL=* 把 Git Bash 的 POSIX→Windows argv 转换全关了
#     ⇒ python 收 /g/... 直接 FileNotFoundError(w458 夹具造不出来)、run_rowpick 23/14 红。
#     只在这两格局部 unset，别全局 unset：DELIVERY §0 ⑤ 的 adb 命令显式要 MSYS_NO_PATHCONV=1，
#     全局关掉会把 /data/local/tmp/... 误转换成 Windows 路径。02:55 全绿那跑就是没这两个变量的形状。
item "w458(#147 打字腿：证不出空就拒打字／前缀只重读／merge 判不过／过滤词由包名推导)" 25 '\[OK\]' env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL bash kmod/w458_selftest_uinput.sh
#   ★下界 25(真实条数以它自己那句「共 N 项断言」为准，今天 37)：第 35 发那两道 UI 闸——
#     row_pick v2「找那张**可点的卡**」(命中唯一才点；0 张/多张/坏树各有码，拒点必删残留)＋
#     prof_gate 的身份闸改成 App Profile∧UID(一手：真 Profile 树里根本没有 com.termux 那个串)。
#     夹具是**冻结的真树副本**(w462_*)，不是手搓形状；五条变异(kmod/_tmp_selftest_rdst/_mut_rowpick.sh)逐条判过有牙。
item "run_rowpick(第35发UI闸：找可点的卡＋身份闸按UID；拒点必删残留＋五条变异有牙)" 25 '\[OK\]' env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL bash kmod/_tmp_selftest_rdst/run_rowpick.sh
#   ★例 76 在这个仓里第四次复发(今晚我改 go.sh 的一句文案时把命令写进了双引号 echo 里＝文案改动变行为改动)：
#     bash -n 抓不到它，这道守卫只看 echo/printf 的双引号内部，注释与单引号里的反引号不报(假红少)。
item "w465 反引号守卫自检(正反例五格：报/不报/注释不报)" 4 '\[OK\]' python kmod/w465_backtick_guard.py --self
item "w465 全仓 shell 件扫描(双引号 echo 里的反引号必须 0 条)" 1 '对照 OK' python kmod/w465_backtick_guard.py
item "run_w731(第 52 发 root 采样器的抽取形状：9 行夹具里 4 行含 KSUBIRTH、半行 KSUBIR 不计、dupskip 取末条、SU链 只认 SU0/SD4/SU1 三 token)" 8 '\[OK\]' bash kmod/w731_root_sampler.sh selfcheck
item "run_rleg(#172 rleg 那条'等 DONE'判据：无生产者⇒rc=7＋点名两条替代证人；读到 DONE 时 rc 绝不许非零)" 15 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_rleg.sh
item "run_fdkeepalive(§FDKA 常驻补装 fd：默认关不写触发口／pid 真变才重装／删开关自退 rc=0／触发口不可写 rc=3／两出口用 FMAX 二分／⑨多候选挑 ppid=1 那个＋⑩FALLBACK 反夹具＋⑪三条静态牙；★自测跑的是从 stage 抽出来的同一批字节)" 35 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_fdkeepalive.sh
item "w404 词元计数(含 <6> 前缀反夹具)"      10 '\[OK\]' python kmod/w404_tokcount.py --selftest
item "w406 形状集合差(含 match-vs-search 牙)" 5 '^\[self\]' python kmod/w406_setdiff.py --self
item "w408 prune 三级分级(正对照＝三发已知 prune)" 1 '对照 OK' python kmod/w408_prune_audit.py --self
#   ★这一件的**真实**断言数以它自己那句「共 N 项断言」为准；这里的 10 只是防"静悄悄空跑"的下界
#     (10 = 专属 chk 自数 8 ＋ case① 里切片自己打的 2 条 [OK])，不是对外报的条数。
item "w419 接手清单自检(锚点漂移/形状/探测器 rc 形状)"  6 '^  \[OK\]' bash kmod/w419_handover_smoke.sh --self
item "run_pkgcheck(3b 包指纹注入五格)"        10 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_pkgcheck.sh
#   ★下面四件是 10-27 三连空枪(第 68/69 发)换来的三道派腿闸＋一支判据腿：
#     它们原本只在终端手跑过，**没进总闸＝会烂**，所以一并登记(总闸数得出 [OK] 行才算有牙)。
item "run_leg1only(LEG1ONLY=1 跳过第 4~7 步；不给＝交付形状一字不变)" 2 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_leg1only.sh
#   ★§6.515 第 88 发要的那把开关：NOREBOOT=1 ⇒ **不软重启**就在当前 boot 开窗(默认关＝交付形状一字不变)，
#     并且自带"脏 boot 必拒"(本 boot 已有 kernelsu ⇒ 枪已花过)。三格都是抽 go.sh 真身跑的。
item "run_noreboot(NOREBOOT=1 不 reboot＋脏 boot 必拒；不给＝照旧 reboot)" 3 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_noreboot.sh
item "run_quietguard(quiet 形状不装 agent fd ⇒ 绝不派腿；两条证人各自能单独拦)" 4 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_quietguard.sh
item "run_exebit(第 69 发空枪：腿在设备上没 x 位⇒execve EACCES/exit=126；六格含正对照＋补不上＋读不到＋md5 不符)" 6 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_exebit.sh
item "run_sepd_leg(w1152 核内解码预演腿：分组/配对/取键/比对核/渲染核**全部从腿里现抽**；G2 那一格一手教训＝bash 把 GROUPS 当保留数组，赋值被无声忽略；正对照＋八条变异＋缺键反夹具)" 20 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_sepd_leg.sh
item "run_sepd_readout(w1153 链的**判读段**judge()：从链里现抽；★⑥a『内核读数差＝判负』与⑥b『期望表派生格差＝模型红』必须分两支(第 97 发那一格红在模型不红在被测)，want() 尾必须摘掉再取键，REJUDGE 重判只认现行表逐格重算；★匹配判据的词元要互斥：⑥b 那句原判词里写了『不写判负』两个否定字，被松匹配读成正向命中＝第一条假红)" 12 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_sepd_readout.sh
item "w1160_dev_preview_check(#241 设备侧那一跑的**离线重判**：喂 11-06 那份设备 raw＋期望表＋第 97 发内核证件；★设备不参与，判读件的牙由『改一份副本必须报红』那格在 w1160_run.sh 里当场证过；三方对表＝aarch64 内核/x86 宿主/aarch64 用户态)" 11 '\[OK\]' python kmod/w1160_dev_preview_check.py kmod/w103_evidence/w1160_dev_v2.raw.txt kmod/w1152_fixtures/expect.txt kmod/w103_evidence/w1153_leg_shot97.out
item "run_verdict18(#219 v2 九格：rd 读数形状四格(无换行/有换行/文件不在⇒errno 证人/空文件)＋判据五格(落地判正·范围丢掉判负·读不出未测·域走形未测·执法前后不一致未测))" 9 '\[OK\]' bash kmod/_tmp_selftest_rdst/run_verdict18.sh
#   ★20:3x：第三格同样把绝对路径交给 Windows 侧客户端(B 格要吃 /g/项目/... 形式的 HRMT_CLI)，
#     MSYS_NO_PATHCONV=1 下会报「客户端不在」⇒ rc=8 / 4 OK 3 BAD。局部 env -u 后单跑 rc=0 / 7 OK 0 BAD / PASS。
#     与上面 w458/run_rowpick 同一条纪律：只按格放开，别全局 unset(DELIVERY §0 ⑤ 的 adb 要它)。
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
#   ★#236 的固化闸(0 枪／纯离线，md §6.552)：甲＝把 §6.530/§6.531/§6.533 那三格一手读数
#     锚在**本地真件**上现读，四把尺各配一条变异(含"应为 0"那把必须有"会非 0"的形状)；
#     乙＝证人资格判语器，只认内核侧证人 ⇒ ★ksud 四样 rc 全绿而内核侧缺证人时必须 untested 而非 landed。
item "w1170(#236 证人资格闸：四把尺各有牙＋ksud 全绿不许判 landed)" 14 '\[OK\]' python kmod/w1170_sepol_witness_gate.py --self
item "w1170 实跑(#236 证据链现读本地真件：桩/分发/ksud 文案/两串为 0)" 4 '\[OK\]' python kmod/w1170_sepol_witness_gate.py
item "w597(第 47 发属主判据三腿)双向静态牙：打字形状/chmod 666/证人先于执法/腿文件在名单里"  13 '\[OK\]' bash kmod/w597_arm_selftest.sh
#   ★W795(第 54 发)：这条规矩不是写给人看的——"要 root 的产物必须在恢复执法**之前**就 chmod 666"。
#     一手：`w789` 原版把 chmod 排在 `echo 1 > /sys/fs/selinux/enforce` 后面 ⇒ 执法一开，收尾腿自己的产物读不到(0600 root)。
#     夹具四格(负=chmod 在执法后／负二=chmod 成 755／正=chmod 在开头／不相关腿不误伤)＋豁免表有牙(表内名字必须还在仓里)。
item "W795 设备腿产物权限闸(写产物＋翻执法的腿：chmod 666 必须排在执法之前；含豁免表死牙)"  8 '\[OK\]' python kmod/w795_leg_guard.py --self
#   ★W774 维持件的三态判定(第 54 发)：正常挂载→不动作／源已删(//deleted)→重建／压根没挂→要挂；
#     ★正对照必须认出 `//deleted`——只查"有没有挂载行"会把今晚那种空壳读成"还挂着"＝假绿。
item "W774 pbin 维持件判定三态＋//deleted 正对照"  4 '\[OK\]' sh kmod/w774_pbin_keeper.sh selfcheck
#   ★W912(#209 的 L2 腿)：判语器的三条出口**各配一份合成件**，再加变异(D3 也出 root⇒必须改口"未测")
#     与负对照(环为空⇒不作判据)。这条之所以要有牙：本轮我差点拿"证人放在两种形状都写不进的落点"当判据(例 184①)。
item "W912 深度2/深度3 改道配对判语器：三出口合成件＋变异＋负对照"  5 '\[OK\]' python kmod/w912_ringpair.py --selftest
#   ★§6.454 那处"组还开着又 >> 同变量"把第 61 发两份原始读数打散成两截 ⇒ 固化成常驻闸：
#     双向自测(正对照必须命中、变异必须不命中)＋全仓扫描(必须 0 命中)。
item "W950 双写者静态闸(双向自测)"  4 '\[OK\]' python kmod/w950_dual_writer_sweep.py --selftest
if python kmod/w950_dual_writer_sweep.py kmod/*.sh kmod/z6root/*.sh >/dev/null 2>&1; then
    echo "  [OK] W950 全仓扫描 0 命中"; echo "W950 全仓扫描 [OK]" >> "$OUT"
else
    echo "  [BAD] W950 全仓扫描有命中(截断组里冒出第二个写者)"; fail=1; python kmod/w950_dual_writer_sweep.py kmod/*.sh kmod/z6root/*.sh | tail -20 >> "$OUT"
fi
#   ★同族第二条常驻闸：`cmd | head; rc=$?` 取的是**管道末端**的 rc(第三次犯＝例 186③，md §6.455)。
#     自测 10 项里 4 项是**一手误报形状**⇒ 这条闸对自己的误报也负责；strict 名单＝交付链上的腿，命中即红。
item "W951 管道末端 rc 静态闸(双向自测＋一手误报四例)"  6 '\[OK\]' python kmod/w951_pipe_rc_sweep.py --selftest
if python kmod/w951_pipe_rc_sweep.py --strict >/dev/null 2>&1; then
    echo "  [OK] W951 交付链 strict 扫描 0 命中"; echo "W951 strict [OK]" >> "$OUT"
else
    echo "  [BAD] W951 交付链里有腿把管道末端的 rc 当被测 rc"; fail=1; python kmod/w951_pipe_rc_sweep.py --strict | tail -20 >> "$OUT"
fi
#   ★#238 部件③(接线)那一格的常驻静态闸：它读的是**将要送进构建机的那份桩源**，量的是形状
#     (判定只在 w1161_gate 一处 / 装载调用点唯一 / 常数不凭记忆 / 默认三道锁 / 五根 #include 在代码里而不是注释里)。
#     为什么必须常驻：11-07 那一红就是最后一格——`#include "security.h"` 只写在头注释里，代码没有，
#     远端 `grep -qF` 撞上散文就放行 ⇒ 白烧一轮编译。七条变异里就有一条复现它。
item "W1162 接线静态闸(正跑全绿＋七条变异全被抓；含 11-07『include 只在注释里』那条)" 40 '\[OK\]' python kmod/w1162_wire_check.py --self kmod/ksu_dropped_stub_rc76.c
#   ★§6.573 第 8 枪"23 分钟"的固化闸(0 枪／纯静态／不改真链，md §6.575 A③)：
#     bootstrap 40×15=600s ＋ go 第 3 步 200×5=1000s ＝ 1600s 是有界"等满"，不是死循环。
#     四条变异(seq 放大／删 RC= 收尾证人／删 post= 回调／go sleep 放大)必须全被拒。
#     ★变异 A 打的是**被测那处** `seq 1 40`+`sleep 15`：bootstrap 里另有一处等开机完成的
#       `seq 1 40`，replace 到前一处会全绿＝假牙，这条自己就被抓到过一次。
item "W1180 punch 等待上限闸(两道叠加 1600s 有界＋RC=/post= 证人＋四变异有牙)" 40 '\[OK\]' python kmod/w1180_punchwait_gate.py --self

echo "=== 2b) 实跑文档审计：对外那几份里有没有「当前口径句」还留着旧说法 ==="
if python kmod/w415_doc_audit.py > "$W103/w413_docaudit_"$TAG".txt" 2>&1; then
    echo "  [OK] 陈旧说法命中 0(全量输出 $W103/w413_docaudit_"$TAG".txt)"
else
    echo "  [BAD] 文档审计有命中 ⇒ 逐条判「是真要修」还是「该加历史标记」："
    grep -aE '^\s+\S+\.md:[0-9]+' "$W103/w413_docaudit_"$TAG".txt" | head -8 | sed 's/^/      /'
    fail=1
fi

echo "=== 3) 设备侧 mksh 语法闸(要 adb 在线；掉线就明说没跑) ==="
if adb get-state 2>/dev/null | grep -q device; then
    #   ★kmod/z6root.sh 是**设备侧一键包**（用户直接跑它），所以它必须过设备 mksh 而不只是 bash -n；
    #     它的载荷 md5 由 w431 打包时现算，脚本本身改坏只要 mksh 不接受，上机就是静默半条链。
    for f in kmod/ksu_one_stage.sh kmod/w184_sample.sh kmod/w407_rootprobe.sh kmod/w410_tail.sh kmod/_tmp_selftest_rdst/probe_shbin.sh kmod/w426_enforce.sh kmod/z6root.sh kmod/w433_slide_solve.sh kmod/w450_close.sh kmod/w483_rm_kd.sh kmod/w500_soft.sh kmod/w501_probe.sh kmod/w165b_adb_clean.sh kmod/w567_root_proof.sh kmod/w572_root_proof.sh kmod/w573_su_witness.sh kmod/w579_enforce.sh kmod/w589_watch_arm.sh kmod/w590_enf_marker.sh kmod/w558_rm3.sh kmod/w600_mgrwatch.sh kmod/w601_mgrlaunch.sh kmod/w605_pre_census.sh kmod/w615_fdshape.sh kmod/w619_kd_why.sh kmod/w625_seedrestart.sh kmod/w1069_step2_pol_leg.sh kmod/w1071_poll_mech_dev.sh kmod/w1087_substep_pol_leg.sh kmod/w1093_hist_pol_leg.sh kmod/w1098_pstore_leg.sh kmod/w1107_pre_leg.sh kmod/w1108_load_leg.sh kmod/w1127_newtype_load_leg.sh kmod/w1142_polload_leg.sh kmod/w1152_sepd_leg.sh kmod/w1115_ddcal.sh kmod/w1160_leg.sh; do
        MSYS_NO_PATHCONV=1 adb push "$f" /data/local/tmp/w413_probe.sh >/dev/null 2>&1
        R=$(MSYS_NO_PATHCONV=1 adb shell 'sh -n /data/local/tmp/w413_probe.sh; echo RC=$?' 2>&1 | tr -d '\r' | tail -1)
        MSYS_NO_PATHCONV=1 adb shell 'rm -f /data/local/tmp/w413_probe.sh' >/dev/null 2>&1
        case "$R" in *RC=0) echo "  [OK] $f 过设备 mksh";; *) echo "  [BAD] $f ⇒ $R"; fail=1;; esac
    done
    echo "  (读回：设备上探针件已删＝$(MSYS_NO_PATHCONV=1 adb shell 'ls /data/local/tmp/w413_probe.sh 2>&1' | tr -d '\r' | tail -1))"
else
    echo "  [没跑] adb 不在线 ⇒ 这一格按'没测到'算，不许当通过"
    echo "=== 3c) 设备侧**执行**一致性腿(包体那块形状闸：bash 与设备 mksh 各跑同一批夹具；要 adb 在线) ==="
    echo "  [没跑] 上一条就掉线了 ⇒ 3c 也算没测到(它是 23 项断言，不在离线集里)"
fi

echo "=== 3d) 行尾闸(#195：Windows 上的编辑器会把新脚本落成 CRLF；msys bash 读脚本容忍 ⇒ 本机跑着没事，一 adb push 上设备就是 syntax error) ==="
CRF=0; CRLIST=""
for f in kmod/ksu_one_stage.sh kmod/z6root.sh kmod/w450_close.sh kmod/w161_teardown.sh kmod/w431_pack_z6root.sh \
         kmod/w433_slide_solve.sh kmod/w413_selftest_sweep.sh kmod/_tmp_selftest_rdst/run_z6pack.sh \
         kmod/_tmp_selftest_rdst/run_fdkeepalive.sh kmod/remote_ksu_rc73.sh kmod/w5[0-9][0-9]*.sh z6root/*.sh; do
    [ -f "$f" ] || continue
    NCR=$(python -c 'import sys;print(open(sys.argv[1],"rb").read().count(b"\r"))' "$f")
    [ "$NCR" = 0 ] || { CRF=$((CRF + 1)); CRLIST="$CRLIST $f(CR=$NCR)"; }
done
echo "  数过的件里带 CRLF 的个数=$CRF(条数由这条循环现数，别手数)"
[ "$CRF" = 0 ] && echo "  [OK] 全为 0" || { echo "  [BAD] 带 CRLF 的件：$CRLIST ⇒ 就地转 LF 再来(转完 md5 变，登记要跟着改)"; fail=1; }
FX=kmod/.w413_crlf_fixture
printf 'a\r\nb\r\n' > "$FX"
FC=$(python -c 'import sys;print(open(sys.argv[1],"rb").read().count(b"\r"))' "$FX")
rm -f "$FX"
[ "${FC:-0}" -ge 2 ] && echo "  [OK] 反夹具生效：现造的 CRLF 件被同一条计数抓到(CR=$FC)" \
    || { echo "  [BAD] 反夹具没被抓到(CR=${FC:-空}) ⇒ 上面那条是空判据"; fail=1; }

echo "=== 3c) 设备侧执行一致性(z6root 里 3.6) 那块开关闸：切片真跑，两壳必须逐字一致) ==="
if adb get-state 2>/dev/null | grep -q device; then
    item "w451(包体 3.6) 形状闸：设备 mksh 与 PC bash 同夹具 7 形状＋静态牙)" 20 '\[OK\]' bash kmod/w451_z6nosuw_mksh.sh
    # ★w459 自己会拉起宿主 app，但锁屏时 uiautomator 量不到输入框(第 110 发那条坑：am start 在锁屏下拍到的是锁屏)
    #   ⇒ 先Wake一下；量不到就 rc!=0，这一格按红算，不许静默当通过。
    adb shell 'input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1; sleep 1
    item "w459(#147 打字腿在**真输入框**上跑：纯字母词必须过＋带点词残留必须被拒)" 5 '\[OK\]' bash kmod/w459_leg_live.sh
else
    echo "  [没跑] adb 不在线 ⇒ 这两条按'没测到'算，不许当通过"
fi

echo "=== 2c) 跨会话记忆文件实跑结构闸(复制/坏字节/断链 ⇒ 影响以后所有读回) ==="
if PYTHONUTF8=1 python kmod/w418_memcheck.py > "$W103/w413_memcheck_"$TAG".txt" 2>&1; then
    echo "  [OK] 记忆文件结构命中 0(明细 $W103/w413_memcheck_"$TAG".txt)"
else
    echo "  [BAD] 有记忆文件坏结构 ⇒ 看明细里的 M1~M4："
    grep -a "BAD" "$W103/w413_memcheck_"$TAG".txt" | head -6 | sed 's/^/      /'
    fail=1
fi

echo "=== 3b) 设备侧 suw 包指纹读回(防「静悄悄换包」白烧一发) ==="
#   为什么要有这一格：第 24 发抓到"往已活着的 suw 派单会丢 extras"，根因在包里(缺 singleTop)。
#   若哪天用 kmod/suw_reinstall.apk(回退位)重装回去，那条 bug 会**静悄悄回来**，下一发枪白烧。
#   ★期望值不写死在脚本里，从台账现取 ⇒ 台账与脚本谁改了都会被这一格抓到(例 116：形状词要有生产者＋读回)。
#   三个离线旋钮(默认全不启用)：W413_DOC=台账路径；W413_FAKE=1 ⇒ 用 W413_FAKE_MD5 当设备读数、不碰设备。
n3b=0
DOC=${W413_DOC:-kmod/DELIVERY.md}
cur=$(grep -aoE 'suw_manager_singletop_20261018\.apk`＝`[0-9a-f]{8}' "$DOC" | grep -oE '[0-9a-f]{8}$' | tail -1)
old=$(grep -aoE 'suw_reinstall\.apk`＝`[0-9a-f]{8}' "$DOC" | grep -oE '[0-9a-f]{8}$' | tail -1)
chk3b() { if [ "$2" = 1 ]; then n3b=$((n3b+1)); echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }
DEV=; APK=
if [ "${W413_FAKE:-0}" = 1 ]; then
    DEV=${W413_FAKE_MD5:-}
    echo "    [注入] W413_FAKE=1 ⇒ 设备读数按 $DEV 算，这一格不碰设备"
elif adb get-state 2>/dev/null | grep -q device; then
    APK=$(MSYS_NO_PATHCONV=1 adb shell 'pm path com.suw.manager' 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)
    DEV=$(MSYS_NO_PATHCONV=1 adb shell "md5sum $APK" 2>/dev/null | tr -d '\r' | cut -c1-32)
    echo "    一手读数：设备侧路径=$APK"
else
    echo "  [没跑] adb 不在线 ⇒ 3b 按『没测到』算，不许当通过"
fi
echo "    一手读数：设备侧 md5=$DEV｜台账现行期望前缀=$cur｜回退位前缀=$old"
if [ -z "$cur" ]; then
    chk3b "台账里登记了现行 suw 包的 md5 前缀(没登记就没人给这一格定值；查 $DOC)" 0
fi
if [ "${W413_FAKE:-0}" = 1 ] || [ -n "$APK$DEV" ]; then
    if [ "${#DEV}" = 32 ]; then
        chk3b "设备装的＝台账登记的现行 singleTop 那包" "$([ -n "$cur" ] && [ "${DEV:0:8}" = "$cur" ] && echo 1 || echo 0)"
        # ★反夹具(牙)：同一个比较喂一个**已知不等于设备**的前缀，必须判"不符"；两前缀相等时这一格没牙。
        chk3b "反夹具：拿回退位前缀去比设备 ⇒ 必须判不符(证明上面那条会红)" "$([ -n "$old" ] && [ "$old" != "${DEV:0:8}" ] && echo 1 || echo 0)"
        if [ -n "$old" ] && [ "${DEV:0:8}" = "$old" ]; then
            echo "      ⇒ 设备上是**回退位那包**：extras 丢包那条 bug 会静悄悄回来，别开窗；先 adb install -r kmod/suw_manager_singletop_20261018.apk"
        fi
    else
        chk3b "设备侧 md5 读得出非空 32 位(读不到＝shell 权限或路径坏，不是『没问题』)" 0
    fi
fi
# uid 只打印不设闸：重装本来就会换(10319→10342 已经变过一次)，写死会假红。
if [ -n "$APK" ]; then
    echo "    参考(不设闸)：$(MSYS_NO_PATHCONV=1 adb shell 'pm list packages -U' 2>/dev/null | tr -d '\r' | grep -a com.suw.manager)"
fi
echo "  (3b 断言自数＝$n3b 条)"

echo "=== 汇总 ==="
echo "  全量输出存 $OUT ($(wc -c < "$OUT") 字节)"
# ★这两句以前只进 stdout，不进存证件 ⇒ 事后翻文件只能看到各项 rc，看不到"这次总结论是什么"
#   （存证的覆盖性要查内容自己说过什么，不是查写者有没有跑；例 112/114 同族）。
if [ "$fail" = 0 ]; then
    echo "  === 离线自检闸 全绿 ===" | tee -a "$OUT"
    exit 0
else
    echo "  === 有红项，别上机 ===" | tee -a "$OUT"
    exit 1
fi
