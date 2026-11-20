#!/usr/bin/env bash
# w106_dirhash.sh —— 把"只比了条数、没比内容"的那三层逐件出哈希，两台各跑一次再 diff。
#   为什么还要这一趟：§6.476 那次清点对 `/home/lucy` 的 242 件 .py/.sh 比了 md5，但
#   子目录(pol/pol2/sepolsrc/…)、`/root/k` 下那批 layout_*/abidump*/*.o/具名件只比了
#   **条数与 du 块数** ⇒ 条数相等不等于内容相等(例 187：两边相等类判据要自证非空＋全覆盖)。
#   只读。唯一写入是 $L。软链也收(md5sum 自己跟着链走 ⇒ 旧机"链→真身"与新机"真身"应当同哈希)。
#   跑法：python <客户端>/cli.py exec --file kmod/w106_dirhash.sh --timeout 900
L="$HOME/dirhash_1028.txt"
: > "$L"

# 1) 子目录逐件（★不含 mount/.hj/rescue/hist/miniconda3/.cache/data —— 那几处两台本来就该不一样）
for d in pol pol2 pol3 probe probe2 chk bkverify ksu200 ksu86 sepolsrc ufsget w691_work w985_ssport kshim home K: __pycache__; do
  [ -d "$HOME/$d" ] || { echo "ABSDIR $d" >>"$L"; continue; }
  find "$HOME/$d" \( -type f -o -type l \) -exec md5sum {} + >>"$L" 2>>"$L"
done

# 2) 具名件（#216/#213 的底料与几份原始 tar/apk/o）
for f in odm.precompiled precompiled_sepolicy pol_bundle.tar.gz pol.live_1026 pol.live_1027 \
         pol.shot63.in w952_inputs.tar.gz libsepol-3.4.tar.gz tracepoint-defs_5486.h \
         abi_gki_aarch64_vivo_5486.txt k200.apk k300.apk ksud_shim_new sustatic \
         dw_ack.o dw_linux-5.4.281.o dw_nothing_sm7325_u_mr.o dw_nothing_sm7325_v_mr.o \
         iqoo_14_kernel.tar.gz iqoo14_sm4375.tar.gz tree_backup_20261013.tgz \
         patchers_20261013.tgz _bwtest.bin rt.a.bin rt.b.bin ksu_compat54_extra.h; do
  if [ -e "$HOME/$f" ]; then md5sum "$HOME/$f" >>"$L" 2>>"$L"; else echo "MISS $HOME/$f" >>"$L"; fi
done

# 3) /root/k 下那批小目录（锚点 dump 与烟测件）
for d in layout_ack layout_linux-5.4.281 layout_nothing_sm7325_u_mr layout_nothing_sm7325_v_mr \
         abicheck abicheck_ack abidump abidump2 abidump3 abiprobe smoke smoke2 smoke3; do
  if [ -d "/root/k/$d" ]; then
    find "/root/k/$d" \( -type f -o -type l \) -exec md5sum {} + >>"$L" 2>>"$L"
  else
    echo "ABSDIR /root/k/$d" >>"$L"
  fi
done
[ -e /root/k/config_dev.txt ] && md5sum /root/k/config_dev.txt >>"$L" 2>>"$L"

# 4) 参照树的关键源文件（旧机那份做过 make prepare，源文件仍应当逐字相同）
for t in linux-5.4.281 nothing_sm7325_v_mr; do
  for f in Makefile kernel/fork.c kernel/module.c init/main.c security/security.c \
           security/selinux/hooks.c security/selinux/ss/services.c security/selinux/ss/policydb.c \
           include/linux/cred.h include/linux/sched.h include/linux/module.h; do
    if [ -e "/root/k/$t/$f" ]; then md5sum "/root/k/$t/$f" >>"$L" 2>>"$L"; else echo "MISS /root/k/$t/$f" >>"$L"; fi
  done
done

# 5) ksu 树里我们真正会改的那几支（远端 == 仓库 这条链的落点）
for f in kernel/policy/allowlist.c kernel/supercall/dispatch.c kernel/hook/tp_marker.c \
         kernel/include/klog.h infra/dev_syms.c kernel/hook/syscall_hook_manager.c; do
  if [ -e "/root/k/ksu/$f" ]; then md5sum "/root/k/ksu/$f" >>"$L" 2>>"$L"; else echo "MISS /root/k/ksu/$f" >>"$L"; fi
done

# 6) /root 下的隐藏件：只列名＋大小，**不打印任何内容**(可能有密钥)
for dd in /root/.ssh /root/.android /root/.gradle; do
  echo "LS $dd" >>"$L"
  ls -1 "$dd" >>"$L" 2>&1
  du -sk "$dd" >>"$L" 2>&1
done

echo "END lines=$(wc -l < "$L") bytes=$(wc -c < "$L")"
