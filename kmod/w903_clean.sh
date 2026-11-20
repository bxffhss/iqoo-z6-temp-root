#!/system/bin/sh
# w903clean.sh — run BY the root leg (uid 0 owns w902_0777/d2, so only it can rmdir it).
rm -rf /data/local/tmp/w902_0777
echo "clean rm rc=$? -> $(ls -ld /data/local/tmp/w902_0777 2>&1)"
