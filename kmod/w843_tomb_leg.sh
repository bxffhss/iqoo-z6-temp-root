#!/system/bin/sh
# w843_tomb_leg.sh —— root 侧读**崩溃/ANR 的实体**：#193 里"谁死于哪个号"不许靠 logcat 的命中词推断，
#   要看 dropbox/tombstone 自己写下的 `signal`/`Abort message`/`Subject` 三样。全程只读。
OUT=/data/local/tmp/w843_tomb.out
PATH=/system/bin:/system/xbin:/product/bin:/vendor/bin
export PATH
: > $OUT 2>/dev/null
exec > $OUT 2>&1
chmod 666 $OUT 2>/dev/null

echo "== w843 起 $(date '+%F %T') up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) =="
echo
echo "== A) dropbox 最近 24 条里，能解开的 .txt.gz 各取头部判据行 =="
for F in $(ls -t /data/system/dropbox 2>/dev/null | head -24); do
    case "$F" in
      *.txt.gz)
        echo "-- $F --"
        gzip -dc "/data/system/dropbox/$F" 2>/dev/null | grep -aE '^(Timestamp|Command|pid:|uid:|signal|Abort message|Subject|Package|Reason|Notes|>>> )' | head -9
        ;;
      *.lost) echo "-- $F (内容已 lost，只当'发生过'的计数) --" ;;
      *) : ;;
    esac
done

echo
echo "== B) /data/tombstones 最近 8 支(名字＋时刻＋属主) =="
ls -lt /data/tombstones 2>&1 | head -9

echo
echo "== C) 最新那一支 tombstone 的头 22 行(进程名/信号/栈顶) =="
LATEST=$(ls -t /data/tombstones 2>/dev/null | grep -a '^tombstone_[0-9]*$' | head -1)
echo "  LATEST=$LATEST"
head -22 "/data/tombstones/$LATEST" 2>&1

echo
echo "== D) 这次窗里我们关心的三个词元的**行为**计数(再取一次，和 w840 对齐) =="
echo "  KILLSOFT=$(grep -ac 'KILLSOFT' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  Fatal signal(环内)=$(grep -ac 'Fatal signal' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  libksud=$(grep -ac 'libksud' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  出生安装 total 末值=$(grep -ao 'total=[0-9]*' /data/local/tmp/dmesg2.log 2>/dev/null | tail -1) cap行=$(grep -ac 'KSUBIRTH cap' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  seen Manager pid 行=$(grep -ac 'KSUBIRTH seen Manager pid' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  queued self fd 行=$(grep -ac 'KSUBIRTH queued self fd' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  helper 行=$(grep -ac 'KSUBIRTH helper' /data/local/tmp/dmesg2.log 2>/dev/null)"

echo
echo "== E) 名单那条 uid 的共享包(授权面：一条 uid 放出去的是几家) =="
pm list packages -U 2>/dev/null | grep -a ':10667$'
echo "== F) 官方 Manager 自己的 uid 有没有在名单里(它不该在：牌子≠授权) =="
pm list packages -U 2>/dev/null | grep -a 'me.weishu.kernelsu'
echo "  root 腿终点 $(date '+%F %T')"
chmod 666 $OUT 2>/dev/null
