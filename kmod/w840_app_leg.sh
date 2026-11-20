#!/system/bin/sh
# w840_app_leg.sh —— 跑在**被授权的 app uid(10667=ZeroTermux)**里的一条腿，做三件事：
#   ①先自报身份(证明这一腿确实在被授权的 uid 里跑，不是 shell)；
#   ②两条**并排**的 su 通道：/system/bin/su(内核改道) vs /product/bin/su(bind 的静态 su)，
#     这就是 §6.432 里"管道交互零输出 rc=1"那格的直接判决；
#   ③各调一次 root 侧件 w840_root_leg.sh，拿 Manager 的 fd/SigPnd 与崩溃信号号(#193 另两格)。
# ★所有重定向都写在本件内部：`input text` 会把 `>` 吃掉(记忆里的老坑)，屏幕上只敲一个不带空格不带引号的词。
OUT=/data/local/tmp/w840_leg.out
: > $OUT 2>/dev/null
exec > $OUT 2>&1
chmod 666 $OUT 2>/dev/null

echo "== app 腿起点 $(date '+%F %T') =="
id
echo "-- 我的 seccomp/selinux --"
grep -aE '^(Seccomp|Secomp|Threads)' /proc/self/status
echo ps -Z 自己:
ps -Z $$ 2>/dev/null | tail -1

echo
echo "== A) 管道：printf 'id' | /system/bin/su （改道那条） =="
printf 'id\n' | /system/bin/su
echo "RC=$?"
echo "== A2) 显式 -c：/system/bin/su -c id =="
/system/bin/su -c id
echo "RC=$?"

echo
echo "== B) 管道：printf 'id' | /product/bin/su （bind 的静态 su） =="
printf 'id\n' | /product/bin/su
echo "RC=$?"
echo "== B2) 显式 -c：/product/bin/su -c id =="
/product/bin/su -c id
echo "RC=$?"

echo
echo "== C) 参数契约在**货里那支(v3)**上的形状(交付槽= f7a441d2；v5 未进包) =="
echo "-- su -v --"
/system/bin/su -v
echo "RC=$?"
echo "-- su -M -c id --"
/system/bin/su -M -c id
echo "RC=$?"

echo
echo "== D) root 侧件（fd/SigPnd/崩溃信号号） =="
/system/bin/su -c 'sh /data/local/tmp/w840_root_leg.sh'
echo "RC=$?"

echo
echo "== app 腿终点 $(date '+%F %T') =="
chmod 666 $OUT 2>/dev/null
