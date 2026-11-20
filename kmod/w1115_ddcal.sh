#!/system/bin/sh
# w1115_ddcal.sh —— 0 枪校准：把装载腿 v3 里那条"形状闸"的原样逻辑，在设备上拿**正/负两份输入**各跑一次。
#   为什么值得单独跑：第 92 发就是被这条闸把自己的合法输入拒了(toybox dd 把 records 打在 stderr，
#   我却只查 stdout 那份)。派腿之前先证"完整件必须过、截断件必须被拒"，否则又是一发白枪。
#   全程只在 /data/local/tmp/w1115 里进出，不碰 /sys/fs/selinux/{load,enforce}，用完由链侧删。
D=/data/local/tmp/w1115
SRC=$1
L=$D/cal.out
: > $L
UP() { cut -d' ' -f1 /proc/uptime; }
onedd() { dd if=$1 of=$2 bs=$3 count=1 >$4 2>&1; RC=$?; }
errtxt() { head -c 140 $1 2>&1 | tr '\n' '|'; }
echo "BEGIN up=$(UP) id=$(id 2>&1)" >> $L
B=$(wc -c < $SRC)
echo "SRC=$SRC bytes=$B" >> $L
# --- 正对照：整份一次写 ⇒ 必须 rc=0 且印得出 1+0 records out 且落点字节=整份 ---
onedd "$SRC" "$D/dry_ok.bin" "$B" "$D/dry_ok.txt"
echo "★POS rc=$RC dd自报=[$(errtxt $D/dry_ok.txt)] 落点字节=$(wc -c < $D/dry_ok.bin) md5同=$( [ "$(md5sum $D/dry_ok.bin|cut -d' ' -f1)" = "$(md5sum $SRC|cut -d' ' -f1)" ] && echo yes || echo no)" >> $L
if grep -qa '1+0 records out' "$D/dry_ok.txt"; then echo "POS_GREP=命中(合法输入过了这道闸)" >> $L; else echo "[x] POS_GREP=没命中 ⇒ 这条闸会假拒，别开枪" >> $L; fi
# --- 负对照：源被截短 ⇒ 必须**不**印 1+0 records out(否则闸没牙) ---
head -c 700000 "$SRC" > "$D/part.bin"
onedd "$D/part.bin" "$D/dry_no.bin" "$B" "$D/dry_no.txt"
echo "NEG rc=$RC dd自报=[$(errtxt $D/dry_no.txt)] 落点字节=$(wc -c < $D/dry_no.bin) 整份字节=$B" >> $L
if grep -qa '1+0 records out' "$D/dry_no.txt"; then echo "[x] NEG_GREP=也命中 ⇒ 这把尺没牙(截断件也算一次写完)" >> $L; else echo "NEG_GREP=没命中(有牙：截断的形状被拒)" >> $L; fi
chmod -R a+r $D 2>/dev/null; chmod 666 $L 2>/dev/null
echo "END up=$(UP)" >> $L
