#!/bin/bash
exec > /home/lucy/w871.log 2>&1
cd /home/lucy
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
B='https://links.8uid.com'
echo "-- body of /dl interstitial"
curl -s -A "$UA" -b cj.txt -c cj.txt -o dl_body.html "$B/dl/fijbige740ax" -w "http=%{http_code} size=%{size_download}\n"
wc -c dl_body.html
grep -aoE '/d/go\?sig=[A-Za-z0-9_-]{4,80}|meta[^>]{0,140}|window\.location[^;]{0,120}|href="[^"]{0,120}' dl_body.html | head -20
echo "-- try the sig route(s) found"
for U in $(grep -aoE '/d/go\?sig=[A-Za-z0-9_-]{4,80}' dl_body.html | sort -u | head -3); do
  echo "  HEAD $U"
  curl -s -A "$UA" -b cj.txt -o /dev/null -D - -L "$B$U" | grep -aiE '^HTTP/|content-length|content-disposition|content-type' | head -6
done
echo "-- also try HEAD (not GET) on /dl with cookies"
curl -s -I -A "$UA" -b cj.txt "$B/dl/fijbige740ax" | grep -aiE '^HTTP/|content-length|content-disposition|content-type' | head -6
echo "== done"
