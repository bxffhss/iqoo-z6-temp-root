#!/bin/bash
exec > /home/lucy/w873.log 2>&1
cd /home/lucy
D=/root/k/vivo_a14_sm4375
mkdir -p "$D"
echo "== start $(date -u +%FT%TZ)"
echo "-- 1) extract whole tree into $D (read-only step)"
t0=$(date +%s)
tar xzf iqoo14_sm4375.tar.gz -C "$D" 2> w873_x.err
echo "tar_rc=$? secs=$(( $(date +%s) - t0 )) files=$(find $D -type f | wc -l) du=$(du -sh $D | cut -f1)"
head -3 w873_x.err
R=$(find $D -maxdepth 2 -name Makefile | head -1)
echo "ROOT_MK=$R"
echo "-- 2) root Makefile version block"
grep -anE "^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION|NAME)" "$R" | head -8
echo "-- 3) GKI_VERSION / abi files"
for F in $(find $D -maxdepth 3 -name 'GKI_VERSION' -o -maxdepth 3 -name 'abi_gki_aarch64_vivo' | head -4); do
  echo "  $F : $(head -c 120 $F | tr '\n' '|')"
done
echo "-- 4) vivo-specific markers"
grep -c vivo "$D/kernel/module.c" 2>/dev/null | sed 's/^/  module.c_vivo_lines=/'
grep -c vivo "$D/kernel/kallsyms.c" 2>/dev/null | sed 's/^/  kallsyms_vivo_lines=/'
grep -cE "vivo|VIVO" "$D/security/selinux/hooks.c" 2>/dev/null | sed 's/^/  selinux_hooks_vivo_lines=/'
grep -cE "force_sig|SEND_SIG" "$D/kernel/signal.c" 2>/dev/null | sed 's/^/  signal_force_sig_lines=/'
echo "-- 5) files that our wall might live in"
ls -l "$D/kernel/module.c" "$D/kernel/tracepoint.c" "$D/kernel/fork.c" "$D/security/commoncap.c" 2>&1 | awk '{print "  ",$5,$9}'
echo "-- 6) diff vs our main reference tree (nothing_sm7325_v_mr)"
for F in kernel/module.c kernel/tracepoint.c kernel/fork.c security/commoncap.c kernel/signal.c; do
  A=$D/$F; B=/root/k/nothing_sm7325_v_mr/$F
  if [ -f "$A" ] && [ -f "$B" ]; then
    N=$(diff -u "$B" "$A" | grep -acE '^[+-][^+-]')
    echo "  $F changed_lines=$N"
  else
    echo "  $F MISSING(A=$([ -f "$A" ] && echo y || echo n) B=$([ -f "$B" ] && echo y || echo n))"
  fi
done
echo "-- 7) does the tree carry any git/commit hint of 2a88cd145def?"
find "$D" -maxdepth 2 -name '.git*' | head -3
grep -al "2a88cd145def" "$D"/Makefile "$D"/android/GKI_VERSION 2>/dev/null | head -3
echo "-- 8) vendor dirs present"
ls "$D/drivers" 2>/dev/null | head -40 | tr '\n' ' '
echo
ls -d "$D"/vendors 2>/dev/null; ls -d "$D"/arch/arm64/boot/dts/vendor 2>/dev/null
echo "== done $(date -u +%FT%TZ)"
