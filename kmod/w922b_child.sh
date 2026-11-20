#!/system/bin/sh
echo "B1 subshell-script pid=$$ up=$(cut -d " " -f1 /proc/uptime)"
/system/bin/su -c id
echo "B1 rc=$?"
