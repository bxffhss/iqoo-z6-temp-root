#!/system/bin/sh
# w891: is the block SELinux, DAC/caps, or something outside policy?
echo "W891 BEGIN up=$(cut -d' ' -f1 /proc/uptime) CTX=$(cat /proc/self/attr/current 2>&1)"
echo "-- caps of this root child"
grep -aE "^(Uid|Gid|CapEff|CapBnd|CapPrm|NoNewPrivs|Seccomp|DynSpec)" /proc/self/status 2>&1 | head -10
echo "-- modes / owners"
for P in /data /data/local /data/local/tmp /data/data /data/anr /sdcard; do
  printf '  %-22s mode_owner=[%s] label=[%s]\n' "$P" "$(stat -c '%a %U:%G' $P 2>&1)" "$(stat -c %C $P 2>&1)"
done
echo "-- read a file inside shell_data_file vs list the dir (same label, TE allows both)"
echo "READ_FILE=$(head -c 20 /data/local/tmp/w889_ladder.sh 2>&1 | tr -d '\n')"
echo "LIST_DIR=$(ls /data/local/tmp 2>&1 | head -2 | tr '\n' '|')"
echo "-- same test on a plain world-readable dir under /data"
echo "ANR_LIST=$(ls /data/anr 2>&1 | head -2 | tr '\n' '|')"
echo "-- does getdents behave differently on /data/data with one level up?"
echo "TMP_WRITE=$(echo x > /data/local/tmp/w891_probe.txt 2>&1; cat /data/local/tmp/w891_probe.txt 2>&1 | head -1)"
echo "-- ptrace/ls on our own proc works; try another task's fd (what a file manager needs)"
echo "OTHER_FD=$(ls -l /proc/1/fd 2>&1 | head -2 | tr '\n' '|')"
echo "W891 END up=$(cut -d' ' -f1 /proc/uptime)"
