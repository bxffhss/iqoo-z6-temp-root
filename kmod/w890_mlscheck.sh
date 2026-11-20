#!/bin/bash
exec > /home/lucy/w890.log 2>&1
cd /home/lucy
P=pol/precompiled_sepolicy
echo "== start $(date -u +%FT%TZ)"
echo "-- is shell in mlstrustedsubject ?"
seinfo --attribute=mlstrustedsubject "$P" 2>&1 | head -20
echo "-- who IS in mlstrustedsubject (count)"
seinfo --attribute=mlstrustedsubject "$P" 2>&1 | grep -ac shell
echo "-- TE: shell -> system_data_file"
sesearch --allow -s shell -t system_data_file "$P" 2>&1 | head -6
echo "-- TE: shell -> app_data_file dir only"
sesearch --allow -s shell -t app_data_file -c dir "$P" 2>&1 | head -4
echo "-- TE: shell_data_file for shell"
sesearch --allow -s shell -t shell_data_file -c dir "$P" 2>&1 | head -4
echo "-- mlsconstrain rules touching app_data_file / process"
seinfo --constrain=all "$P" 2>&1 | head -40
echo "-- does the policy define su domain rules at all?"
sesearch --allow -s su "$P" 2>&1 | wc -l
sesearch --allow -t su "$P" 2>&1 | wc -l
echo "-- su in mlstrustedsubject?"
seinfo --attribute=mlstrustedsubject "$P" 2>&1 | grep -aw su | head -3
echo "-- shell's mls range (from policy: user/role level)"
seinfo --user=shell "$P" 2>&1 | head -5
echo "-- sensitivity/category counts"
seinfo --category "$P" 2>&1 | wc -l
echo "== done $(date -u +%FT%TZ)"
