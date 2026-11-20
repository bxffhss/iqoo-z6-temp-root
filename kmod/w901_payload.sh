#!/system/bin/sh
# w901p.sh — root-child capability/mapping probe. Two files were pre-made 0666 by shell so
# that DAC cannot be the excuse: writing into them isolates the SELinux answer, while
# writing a NEW file into a 0771 dir isolates the cred answer (CAP_DAC_OVERRIDE / groups).
echo "Q0 self=$(id)"
echo "Q1 $(grep -E '^Uid:|^Gid:|^CapEff:|^CapPrm:|^Seccomp:' /proc/self/status | tr '\n' ' ')"
echo "Q2 ctx=$(cat /proc/self/attr/current 2>&1)"
echo "Q3 write existing 0666 in /data/local/tmp: [$(echo root_ok >> /data/local/tmp/w901_ww.txt 2>&1)] rc=$?"
echo "Q4 that file now: $(tail -1 /data/local/tmp/w901_ww.txt 2>&1)"
echo "Q5 write existing 0666 in app HOME: [$(echo root_ok >> /data/data/com.termux/files/home/w901_ww_app.txt 2>&1)] rc=$?"
echo "Q6 that file now: $(tail -1 /data/data/com.termux/files/home/w901_ww_app.txt 2>&1)"
echo "Q7 NEW file in /data/local/tmp (needs DAC_OVERRIDE): [$(echo x > /data/local/tmp/w901_new.txt 2>&1)]"
echo "Q8 mkdir in /data/local/tmp: [$(mkdir /data/local/tmp/w901d 2>&1)]"
echo "Q9 ls /data/local/tmp (dir read, needs DAC too): $(ls /data/local/tmp 2>&1 | head -2 | tr '\n' '|')"
echo "Q10 ksu nodes: $(ls /proc | grep ksu | tr '\n' ' ')"
echo "Q11 /data/adb: $(ls /data/adb 2>&1 | head -1)"
echo "Q12 redirect target itself: $(ls -lZ /data/local/tmp/kd 2>&1 | head -1) md5=$(md5sum /data/local/tmp/kd 2>&1)"
echo "Q13 END"
