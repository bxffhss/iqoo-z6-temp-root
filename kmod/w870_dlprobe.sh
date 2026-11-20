#!/bin/bash
exec > /home/lucy/w870.log 2>&1
cd /home/lucy
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
B='https://links.8uid.com'
rm -f cj.txt
echo "-- A) GET the interstitial with cookie jar"
curl -s -A "$UA" -c cj.txt -o inter.html "$B/d/fijbige740ax?download=1" -w "http=%{http_code} type=%{content_type} size=%{size_download} url=%{url_effective}\n"
echo "cookies:"; cat cj.txt | tail -5
echo "-- B) js routes inside interstitial"
grep -aoE 'fetch\([^)]{0,90}|/api/[a-z/_-]{0,40}|sig=[a-zA-Z0-9]{0,40}|localStorage[^;]{0,60}' inter.html | sort -u | head -20
echo "-- C) try /dl with cookies"
curl -s -A "$UA" -b cj.txt -c cj.txt -o /dev/null -D dl_head.txt -L "$B/dl/fijbige740ax" -w "http=%{http_code} type=%{content_type} size=%{size_download}\n"
grep -aiE '^HTTP/|content-length|content-disposition|content-type|location' dl_head.txt | head -10
echo "-- D) /direct endpoints seen in the page"
grep -aoE '/direct[a-zA-Z0-9/?=_.-]{0,60}' inter.html | sort -u | head -5
for U in $(grep -aoE '/direct[a-zA-Z0-9/?=_.-]{0,60}' inter.html | sort -u | head -2); do
  echo "  probing $U"
  curl -s -A "$UA" -b cj.txt -o /dev/null -D - -L "$B$U" | grep -aiE '^HTTP/|content-length|content-disposition|content-type' | head -5
done
echo "-- E) api/file/link"
for A in $(grep -aoE '/api/(file/link|link/info)/[a-zA-Z0-9_-]{0,40}' inter.html | sort -u | head -4); do
  echo "  $A ->"
  curl -s -A "$UA" -b cj.txt "$B$A" | head -c 400; echo
done
echo "== done"
