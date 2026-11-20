#!/bin/bash
exec > /home/lucy/w869.log 2>&1
cd /home/lucy
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
echo "== html we already have (25KB): what does it say"
head -c 400 iqoo_14_kernel.tar.gz
echo
echo "-- routes found"
grep -aoE '/(f|s|d|dl|file|api)[/?=a-zA-Z0-9_-]{0,40}' iqoo_14_kernel.tar.gz | sort | uniq -c | sort -rn | head -20
echo "-- title / js redirect"
grep -aoE '<title>[^<]{0,60}' iqoo_14_kernel.tar.gz | head -3
grep -aoE 'window\.location[^;]{0,90}' iqoo_14_kernel.tar.gz | head -3
grep -aoE 'action="[^"]{0,80}' iqoo_14_kernel.tar.gz | head -5
echo "== try variants of the share url"
for U in 'https://links.8uid.com/f/fijbige740ax' 'https://links.8uid.com/d/fijbige740ax?download=1' 'https://links.8uid.com/s/fijbige740ax' 'https://links.8uid.com/d/fijbige740ax/'; do
  echo "-- $U"
  curl -s -A "$UA" -o /dev/null -D - "$U" | grep -aiE '^HTTP/|content-length|content-disposition|content-type|location' | head -6
done
echo "== done"
