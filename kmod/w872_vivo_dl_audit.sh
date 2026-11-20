#!/bin/bash
exec > /home/lucy/w872.log 2>&1
cd /home/lucy
U='<REDACTED_PRESIGNED_URL>'
echo "== start $(date -u +%FT%TZ)"
echo "-- device kernel to match: 5.4.281-qgki-g2a88cd145def  clang r383902b  built 2025-05-07 CST  V2220A/PD2220"
t0=$(date +%s)
curl -sSL -o iqoo14_sm4375.tar.gz "$U" -w "http=%{http_code} size=%{size_download} type=%{content_type}\n"
echo "curl_rc=$? secs=$(( $(date +%s) - t0 )) speed_ok=$([ $(date +%s) - t0 -gt 0 ] && echo yes)"
ls -l iqoo14_sm4375.tar.gz
sha256sum iqoo14_sm4375.tar.gz
file iqoo14_sm4375.tar.gz 2>/dev/null || head -c 4 iqoo14_sm4375.tar.gz | od -An -tx1
echo "-- 1) member listing"
tar tzf iqoo14_sm4375.tar.gz > w872_list.txt 2> w872_list.err
echo "tar_rc=$? members=$(wc -l < w872_list.txt)"
head -3 w872_list.err
echo "-- 2) top-level"
awk -F/ 'NF<=2{print}' w872_list.txt | head -20
echo "-- 3) SoC markers"
for K in sm4375 sm7325 sm7325ab waipio kalama lahaina kona db8155 qssi; do
  echo "  $K -> $(grep -ac "$K" w872_list.txt)"
done
echo "-- 4) config files present"
grep -a "arch/arm64/configs" w872_list.txt | head -15
echo "-- 5) git metadata?"
grep -acE "\.git" w872_list.txt
echo "-- 6) interesting files present"
for P in kernel/module.c kernel/kallsyms.c kernel/trace/tracepoint.c security/selinux/hooks.c security/Makefile Makefile; do
  echo "  $P -> $(grep -ac "$P" w872_list.txt)"
done
echo "-- 7) extract Makefile + configs + module.c"
rm -rf probe2; mkdir -p probe2
tar xzf iqoo14_sm4375.tar.gz -C probe2 --wildcards '*/Makefile' '*/arch/arm64/configs/*' '*/kernel/module.c' '*/kernel/trace/tracepoint.c' 2>/dev/null
echo "extracted=$(find probe2 -type f | wc -l)"
MK=$(find probe2 -name Makefile -maxdepth 3 | head -1)
echo "MK=$MK"; [ -n "$MK" ] && sed -n '1,10p' "$MK"
echo "-- 8) defconfig names"
find probe2 -path "*configs*" -type f | head -20
echo "== done $(date -u +%FT%TZ)"
