#!/system/bin/sh
# w558_rm3.sh —— 由 kmod/w558_mk_rm3.py 从 w161_teardown.sh 的 T3_RM 生成(条目 151)。
#   ★本件由 @sushd: 以 root 派发(所以 apk_data_file 那些标签挡着的也删得动，#167/§6.407)；
#   先列→再删→再复证；只动名单里的绝对路径，不碰 /data/adb(那归 w165b_adb_clean.sh)，工具件不在名单内(KEEP 硬闸)。
L=/data/local/tmp/w558_list.txt
: > "$L"
for F in \/data/local/tmp/w165_adb_clean.sh \
    /data/local/tmp/w165_adb_clean.out \
    /data/local/tmp/w407_rootprobe.sh \
    /data/local/tmp/w407_rootprobe.out \
    /data/local/tmp/kernelsu.ko \
    /data/local/tmp/w135_fix.sh \
    /data/local/tmp/w135_off.sh \
    /data/local/tmp/w135_fix.out \
    /data/local/tmp/w135_off.out \
    /data/local/tmp/ksu_two_profiles \
    /data/local/tmp/sustatic \
    /data/local/tmp/kd \
    /data/local/tmp/ksud \
    /data/local/tmp/perfips \
    /data/local/tmp/pr \
    /data/local/tmp/pr.log \
    /data/local/tmp/slide_solve.sh \
    /data/local/tmp/slide_ctl.txt \
    /data/local/tmp/ksu_slide.awk \
    /data/local/tmp/ksu_slots.dump.txt \
    /data/local/tmp/ksu_ftrace.txt \
    /data/local/tmp/ksu_ftrace_armed \
    /data/local/tmp/ksu_kallsyms.txt \
    /data/local/tmp/ksu_tainted_before.txt \
    /data/local/tmp/ksu_mod_before.txt \
    /data/local/tmp/ksu_mod_mounts.txt \
    /data/local/tmp/ksu_mod_teardown.log \
    /data/local/tmp/ksu_ui_track.txt \
    /data/local/tmp/ksu_ui_done \
    /data/local/tmp/ksu_race_fd \
    /data/local/tmp/ksu_redirect_dst \
    /data/local/tmp/ksu_redirect_con \
    /data/local/tmp/ksu_stage.log \
    /data/local/tmp/punch.log \
    /data/local/tmp/ksu_ring_end.txt \
    /data/local/tmp/ksu_ring_end_dump \
    /data/local/tmp/ipk.txt \
    /data/local/tmp/ipk_raw.txt \
    /data/local/tmp/app_ksu.txt \
    /data/local/tmp/shd.log \
    /data/local/tmp/ksuctl_hold.out \
    /data/local/tmp/pcode_ctl.txt \
    /data/local/tmp/ksa_uids.txt \
    /data/local/tmp/ksu_dom \
    /data/local/tmp/ksu_dom_map \
    /data/local/tmp/ksu_shbin \
    /data/local/tmp/ksu_ap_key \
    /data/local/tmp/ksu_allow_shell \
    /data/local/tmp/ksu_skip_insmod \
    /data/local/tmp/ksu_ring_end \
    /data/local/tmp/ksu_quiet \
    /data/local/tmp/ksu_quiet_after_insmod \
    /data/local/tmp/ksu_quiet_fixcfi \
    /data/local/tmp/ksu_nosuw \
    /data/local/tmp/sushd.log \
    /data/local/tmp/ksu_post.sh \
    /data/local/tmp/w184_sample.out \
    /data/local/tmp/dmesg.live \
    /data/local/tmp/dmesg2.log \
    /data/local/tmp/dmesg_full.txt \
    /data/local/tmp/ksu_args.txt \
    /data/local/tmp/w450_close.sh \
    /data/local/tmp/ksu_fd_keepalive \
    /data/local/tmp/ksu_fd_keepalive.sh \
    /data/local/tmp/ksu_fd_keepalive.log \
    /data/local/tmp/w572_root_proof.sh \
    /data/local/tmp/w572_probe \
    /data/local/tmp/w579_enforce.sh \
    /data/local/tmp/w589_watch_arm.out \
    /data/local/tmp/w589_live.log \
    /data/local/tmp/w590_enf_marker.sh \
    /data/local/tmp/w590_enf_marker \
    /data/local/tmp/w590_enf.out \
    /data/local/tmp/w558_list.txt \
    /data/local/tmp/dmesg2.log.tmp \
    /data/local/tmp/w161_fdwatch.log \
    /data/local/tmp/w161_fdwatch.pid \
    /data/local/tmp/w161_r0.txt \
    /data/local/tmp/w205_list.out \
    /data/local/tmp/w543_kt.sh \
    /data/local/tmp/w543_kt.keep \
    /data/local/tmp/w543_kt.keep2 \
    /data/local/tmp/w543_kt.out \
    /data/local/tmp/w543_z6.out \
    /data/local/tmp/w549_kt2.sh \
    /data/local/tmp/w549_kt2.keep \
    /data/local/tmp/w553_home_race.png \
    /data/local/tmp/w553_home_race.xml \
    /data/local/tmp/w552_root_bundle.sh \
    /data/local/tmp/w552_root.out \
    /data/local/tmp/w552_cue1 \
    /data/local/tmp/w552_cue2 \
    /data/local/tmp/w556_zgwatch.sh \
    /data/local/tmp/w556_zg.out \
    /data/local/tmp/a_10342.bin \
    /data/local/tmp/kernelsu.ko \
    /data/local/tmp/w567_root_proof.sh \
    /data/local/tmp/w567_probe \
    /data/local/tmp/w567_root.out \
    /data/local/tmp/w161_g2.out \
    /data/local/tmp/w161_u1.uid \
    /data/local/tmp/w161_u2.uid \
    /data/local/tmp/w161_fdwatch.sh \
    /data/local/tmp/w161_fdlaunch.sh \
    /data/local/tmp/w161_fdlaunch.out \
    /data/local/tmp/w205_list.sh \
    /data/local/tmp/ksu_ring_end.txt \
    /data/local/tmp/sushd_last.out \
    /data/local/tmp/w600_mgrwatch.sh \
    /data/local/tmp/w600_mgrwatch.log \
    /data/local/tmp/w600_mgrwatch.pid \
    /data/local/tmp/ksu_mgr_watch \
    /data/local/tmp/w601_mgrlaunch.sh \
    /data/local/tmp/w601_mgrlaunch.out \
    /data/local/tmp/w602_sc.sh \
    /data/local/tmp/w604_giveup.sh \
    /data/local/tmp/w625_seedrestart.out \
    /data/local/tmp/w625_lock \
    /data/local/tmp/w625_nogate \
    /sdcard/w567_a.xml \
    /sdcard/w567_b.xml \
    /sdcard/w567_c.xml \
    /sdcard/w567_su_abs.png \
    /sdcard/w567_chmod.png \
    /sdcard/w567_rootproof.png \
    /sdcard/w429.xml \
    /sdcard/w429_termux.png \
    /sdcard/w603_C1.xml \
    /sdcard/w603_T1.xml \
    /sdcard/w603_T2.xml \
    /sdcard/w603_T3.xml \
    /sdcard/w603_C2.xml \
    /sdcard/w591_A.png \
    /sdcard/w591_A.xml \
    /sdcard/w591_B.png \
    /sdcard/w591_B.xml \
    /sdcard/w603_C1.png \
    /sdcard/w603_C0.xml \
    /sdcard/w603_C0.png \
    /sdcard/w603_D1.xml \
    /sdcard/w603_D1.png \
    /sdcard/w603_B1.xml \
    /sdcard/w603_B1.png \
    /sdcard/w603_B2.xml \
    /sdcard/w603_B2.png \
    /sdcard/w603_B3.xml \
    /sdcard/w603_B3.png \
    /sdcard/w603_B4.xml \
    /sdcard/w603_B4.png \
    /sdcard/w603_B5.xml \
    /sdcard/w603_B5.png; do
    echo "$F" >> "$L"
done
echo "名单条数=$(wc -l < $L)" >> "$L"
echo "=== 删之前存在的那些 ==="
while read -r P; do [ -e "$P" ] && ls -l "$P"; done < "$L" 2>/dev/null
for P in $(grep -a '^/' "$L"); do rm -f "$P" 2>/dev/null; done
echo "=== 复证(还在的列出来，空=全删净) ==="
LEFT=0
while read -r P; do if [ -e "$P" ]; then echo "  还在: $P"; LEFT=$((LEFT + 1)); fi; done < "$L"
echo "剩余=$LEFT"
rm -f "$L"
echo "enforce=$(cat /sys/fs/selinux/enforce) mod=$(grep -ac kernelsu /proc/modules) up=$(cut -d. -f1 /proc/uptime)"
