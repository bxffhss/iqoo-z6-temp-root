#!/bin/bash
exec > /home/lucy/w874.log 2>&1
D=/root/k/vivo_a14_sm4375
echo "-- root Makefile (the real one)"
sed -n '1,12p' "$D/Makefile"
echo "-- localversion files"
ls -la "$D" | grep -aE "localversion|^total" | head -6
for F in "$D"/Makefile*; do echo "  $F"; done
cat "$D"localversion* 2>/dev/null | head -5
echo "-- does it contain -qgki / -2a88 hint anywhere at top level"
grep -alE "qgki" "$D/Makefile" 2>/dev/null | head -2
echo "-- abi_gki_aarch64_vivo symbol count vs qcom one"
for F in "$D"/android/abi_gki_aarch64_vivo "$D"/android/abi_gki_aarch64_qcom_internal "$D"/android/abi_gki_aarch64_xiaomi; do
  echo "  $(basename $F) symbols=$(grep -ac '^  ' $F 2>/dev/null)"
done
echo "-- tracepoint struct in THIS tree (for #194 self-calibration)"
grep -anE "struct tracepoint_func|struct tracepoint \{|prio" "$D"/include/linux/tracepoint-defs.h | head -8
echo "-- module.c: any non-upstream function names?"
grep -aoE "^[a-z_][a-z0-9_]*\(|^static [a-z_ ]+ [a-z_]+\(" "$D/kernel/module.c" | sed 's/.* //' | sort -u > /tmp/v.mod.fn
grep -aoE "^[a-z_][a-z0-9_]*\(|^static [a-z_ ]+ [a-z_]+\(" /root/k/linux-5.4.281/kernel/module.c | sed 's/.* //' | sort -u > /tmp/u.mod.fn
echo "  only_in_vivo_tree=$(comm -23 /tmp/v.mod.fn /tmp/u.mod.fn | wc -l)"
comm -23 /tmp/v.mod.fn /tmp/u.mod.fn | head -12 | sed 's/^/    /'
echo "  only_in_upstream=$(comm -13 /tmp/v.mod.fn /tmp/u.mod.fn | wc -l)"
comm -13 /tmp/v.mod.fn /tmp/u.mod.fn | head -8 | sed 's/^/    /'
echo "-- symbol list: our needed symbols exported by vivo?"
for S in tracepoint_probe_register_prio tracepoint_probe_unregister for_each_kernel_tracepoint module_kallsyms_lookup_name; do
  echo "  $S in vivo abi: $(grep -ac "  $S\$" "$D/android/abi_gki_aarch64_vivo")"
done
echo "== done"
