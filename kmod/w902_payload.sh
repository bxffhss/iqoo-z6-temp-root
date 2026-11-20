#!/system/bin/sh
# w902p.sh — decide whether the uid-0 twin's EACCES on /data/local/tmp is DAC (caps not
# taking effect / nested namespaces) or TE (a policy rule). The 0777 dir makes DAC a
# non-issue for "other", so a denial there can only come from a label/LSM decision.
echo "R0 self=$(id)"
echo "R1 $(grep -E '^Uid:|^Gid:|^NSpid:|^CapBnd:|^CapAmb:|^NoNewPrivs:|^Seccomp:' /proc/self/status | tr '\n' ' ')"
echo "R2 uid_map=[$(cat /proc/self/uid_map 2>&1 | tr '\n' '/')] gid_map=[$(cat /proc/self/gid_map 2>&1 | tr '\n' '/')]"
echo "R3 ns: mnt=$(ls -lZ /proc/self/ns/mnt 2>&1 | head -1 | cut -d' ' -f5-) pid_let=$(readlink /proc/self/ns/pid 2>&1) user_let=$(readlink /proc/self/ns/user 2>&1)"
echo "R4 write NEW file in a 0777 dir: [$(echo x > /data/local/tmp/w902_0777/new.txt 2>&1)]"
echo "R5 ls that 0777 dir: $(ls /data/local/tmp/w902_0777 2>&1 | tr '\n' '|')"
echo "R6 mkdir inside that 0777 dir: [$(mkdir /data/local/tmp/w902_0777/d2 2>&1)]"
echo "R7 control: write into existing 0666 file: [$(echo y >> /data/local/tmp/w901_ww.txt 2>&1)]"
echo "R8 read the ko node by name: [$(cat /proc/ksu_slots 2>&1 | head -1)]"
echo "R9 touch a file in /data/local/tmp via toybox: [$(touch /data/local/tmp/w902_t 2>&1)]"
echo "R10 END"
