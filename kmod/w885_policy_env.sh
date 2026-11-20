#!/bin/bash
exec > /home/lucy/w885.log 2>&1
cd /home/lucy
echo "== start $(date -u +%FT%TZ)"
rm -rf pol; mkdir pol
tar xzf pol_bundle.tar.gz -C pol || echo "TAR_FAIL=$?"
echo "-- files:"; ls pol | head -20; du -sh pol
echo "-- apt candidates"
apt-get -s install setools-console checkpolicy selinux-utils libsepol-utils 2>&1 | grep -aE "^Inst|Unable to locate|E: " | head -20
echo "-- install (noninteractive)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends setools-console checkpolicy selinux-utils 2>&1 | tail -5
echo "-- tools present"
for T in sesearch sediff seinfo apol checkpolicy secilc getenforce; do
  printf '  %-12s %s\n' "$T" "$(command -v $T || echo MISSING)"
done
echo "-- policy header"
python3 /home/lucy/pol_hdr.py pol/precompiled_sepolicy
echo "-- Q1: what may shell do to app_data_file ?"
sesearch --allow -s shell -t app_data_file pol/precompiled_sepolicy 2>&1 | head -12
echo "-- Q2: shell vs shell_data_file"
sesearch --allow -s shell -t shell_data_file pol/precompiled_sepolicy 2>&1 | head -8
echo "-- Q3: contrast, untrusted_app vs app_data_file rule count"
sesearch --allow -s untrusted_app -t app_data_file pol/precompiled_sepolicy 2>&1 | wc -l
echo "-- Q4: does the policy even know our labels?"
sesearch --allow -c file pol/precompiled_sepolicy 2>&1 | grep -ac app_data_file
echo "== done $(date -u +%FT%TZ)"
