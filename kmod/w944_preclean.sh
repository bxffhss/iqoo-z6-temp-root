#\!/system/bin/sh
# w944_preclean.sh — 翻执法前最后一步：删掉我自己留在 /data/adb 的那个 0 字节标记。
# 为什么必须现在删：执法后 shell 域对 adb_data_file 连 remove_name 都没有(§6.452)，就再也删不动了。
rm -f /data/adb/.suwtest
echo "PRE_CLEAN rm_rc=$? left=$(ls -a /data/adb 2>&1 | tr "\n" " ")"
