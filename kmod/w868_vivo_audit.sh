#!/bin/bash
# w868: download + READ-ONLY audit of the vivo kernel tarball the user found
# runs on hermes-remote. No device touched. Logs everything to a file.
exec > /home/lucy/w868.log 2>&1
URL='https://links.8uid.com/d/fijbige740ax'
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
cd /home/lucy || exit 1
mkdir -p probe
echo "== start $(date -u +%FT%TZ)"
echo "== target device strings (from the phone)"
echo 'KVER=Linux version 5.4.281-qgki-g2a88cd145def clang r383902b built 2025-05-07  V2220A/PD2220  PD2220D_A_14.2.9.1.W10.V000L1'
echo "-- 1) download"
t0=$(date +%s)
curl -sSL -A "$UA" -o iqoo_14_kernel.tar.gz "$URL"
RC=$?
echo "curl_rc=$RC secs=$(( $(date +%s) - t0 ))"
ls -l iqoo_14_kernel.tar.gz
sha256sum iqoo_14_kernel.tar.gz
echo "-- 2) is it really gzip/tar?"
file iqoo_14_kernel.tar.gz 2>/dev/null || head -c 8 iqoo_14_kernel.tar.gz | od -An -tx1
echo "-- 3) full member listing (streaming)"
t0=$(date +%s)
tar tzf iqoo_14_kernel.tar.gz > w868_list.txt 2> w868_list.err
echo "tar_rc=$? members=$(wc -l < w868_list.txt) secs=$(( $(date +%s) - t0 ))"
echo "list_err_head:"; head -3 w868_list.err
echo "-- 4) top-level shape"
awk -F/ '{print $1}' w868_list.txt | sort | uniq -c | sort -rn | head -5
awk -F/ 'NF<=2{print}' w868_list.txt | head -15
echo "-- 5) SoC / platform markers in paths"
grep -aiE "sm4375|sm7325|sm4|lahaina|kona|waipio|kalama" w868_list.txt | awk -F/ '{print $NF}' | sort | uniq -c | sort -rn | head -12
echo "-- 6) configs present"
grep -a "arch/arm64/configs" w868_list.txt | head -20
echo "-- 7) git metadata present?"
grep -acE "^\.git|/\.git" w868_list.txt
echo "-- 8) vendor/anti-root/ksu-relevant files"
for P in kernel/module.c kernel/kallsyms.c kernel/trace/tracepoint.c security/selinux/ kernel/sched/core.c; do
  echo "  $P -> $(grep -ac "$P" w868_list.txt)"
done
echo "-- 9) extract Makefile + configs only"
tar xzf iqoo_14_kernel.tar.gz -C probe --wildcards '*/Makefile' '*/arch/arm64/configs/*' '*/kernel/module.c' 2>/dev/null
find probe -maxdepth 3 -name Makefile | head -3
find probe -maxdepth 4 -path "*configs*" -name "*defconfig*" | head -10
echo "-- 10) Makefile head"
MK=$(find probe -maxdepth 3 -name Makefile | head -1)
[ -n "$MK" ] && sed -n '1,8p' "$MK"
echo "== done $(date -u +%FT%TZ)"
