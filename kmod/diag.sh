#!/system/bin/sh
# diag.sh —— 探测 Termux 里 input text 通道 + su 直授是否生效。
id > /data/local/tmp/d1.txt 2>&1
/product/bin/su -c id > /data/local/tmp/d2.txt 2>&1
echo RC=$? >> /data/local/tmp/d2.txt
echo DIAG_DONE > /data/local/tmp/d3.txt
