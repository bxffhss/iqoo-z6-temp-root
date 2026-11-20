exec >/data/local/tmp/w_keepon.out 2>&1
touch /data/local/tmp/b8_keep
echo "id=$(id)"
/system/bin/sh /data/local/tmp/b8_keep.sh
echo "keeper_after=$(ps -A -o PID,ARGS 2>/dev/null | grep -a "b8_keep.sh RUN" | grep -av grep | awk "{print $1}")"
echo "===== DONE ====="
