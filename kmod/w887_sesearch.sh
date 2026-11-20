#!/bin/bash
exec > /home/lucy/w887.log 2>&1
cd /home/lucy
echo "== start $(date -u +%FT%TZ)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends setools secilc checkpolicy selinux-utils python3-setools 2>&1 | tail -6
for T in sesearch seinfo sediff secilc checkpolicy sestatus; do
  printf '  %-12s %s\n' "$T" "$(command -v $T || echo MISSING)"
done
P=pol/precompiled_sepolicy
echo "-- seinfo stats"
seinfo --stats "$P" 2>&1 | head -14
echo "-- Q1 shell -> app_data_file (allow)"
sesearch --allow -s shell -t app_data_file "$P" 2>&1 | head -10
echo "-- Q2 shell -> app_data_file (any dir read-ish class present?)"
sesearch --allow -s shell "$P" 2>&1 | grep -ac app_data_file
echo "-- Q3 contrast: untrusted_app -> app_data_file count"
sesearch --allow -s untrusted_app "$P" 2>&1 | grep -ac app_data_file
echo "-- Q4 su domain exists?"
seinfo -tapp_data_file "$P" >/dev/null 2>&1 && echo "  type app_data_file: known"
seinfo --type=su "$P" 2>&1 | head -3
seinfo --role=system_r "$P" >/dev/null 2>&1 && echo "  role system_r ok"
echo "-- Q5 policy version reported by tools"
python3 - "$P" <<'PY'
import sys,struct
b=open(sys.argv[1],'rb').read(12)
m,v=struct.unpack('<II',b[:8])
print("  raw magic=0x%08x version=%u marker=%r" % (m,v,b[8:12]))
PY
echo "== done $(date -u +%FT%TZ)"
