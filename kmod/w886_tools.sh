#!/bin/bash
exec > /home/lucy/w886.log 2>&1
cd /home/lucy
echo "== start $(date -u +%FT%TZ)"
echo "-- what is pol/precompiled_sepolicy ?"
ls -ld pol/precompiled_sepolicy 2>&1
ls -l pol/precompiled_sepolicy/ 2>&1 | head -5
echo "-- bundle members (as seen by tar)"
tar tzf pol_bundle.tar.gz | grep -a precompiled | head -8
echo "-- apt update"
DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tail -4
echo "-- search"
apt-cache search setools 2>/dev/null | head -6
apt-cache search secilc 2>/dev/null | head -4
apt-cache policy setools-console checkpolicy selinux-utils libsepol-dev 2>/dev/null | grep -aE "^[a-z-]+:|Candidate:" | head -16
echo "-- install"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends setools-console checkpolicy selinux-utils libsepol-dev 2>&1 | tail -6
echo "-- tools"
for T in sesearch sediff seinfo checkpolicy secilc getenforce sestatus; do
  printf '  %-12s %s\n' "$T" "$(command -v $T || echo MISSING)"
done
echo "-- dpkg -L libsepol* | grep secilc"
dpkg -L libsepol-dev 2>/dev/null | grep -aiE "secilc|bin/" | head -5
echo "-- policy header (find the real file)"
F=$(find pol -name 'precompiled_sepolicy' -type f | head -1)
echo "  F=$F  size=$( [ -n "$F" ] && stat -c %s "$F" )"
[ -n "$F" ] && python3 /home/lucy/pol_hdr.py pol "$F" 2>&1 | head -14
echo "== done $(date -u +%FT%TZ)"
