#!/system/bin/sh
# w969_ladder_keeplog.sh — 第 62 发：用**正确夹具**(`testmod`，带 system/etc/hosts)重跑阶梯，并修掉 §6.457 那条自毁证据的缺陷。
#   ★两处针对性修正：
#    ①夹具选错会造出假负结果（这次实测：`modsrc_bind` 没有 `system/` 子树也不写 selftest ⇒ 档2/档1 都没有证人，
#      我差点据此判"第 61 发的机制判正不可复现"）。⇒ 本腿自己复证夹具形状（数 `system/` 里几个文件、有没有 selftest 那段代码）。
#    ②`teardown` 会把 `ksu_module_apply.log` 与 `mod/` 一起删掉 ⇒ 判据必须在删之前先抄进本腿产物（`cp` 到 /data/local/tmp 下另名）。
#   三档判据不变：装前 marker=0／apply 后 marker=1＋md5 变／teardown 后 md5 **回到装前值**＋marker=0。
O=/data/local/tmp/w969.out
AP=/data/local/tmp/ksu_module_apply.sh
TD=/data/local/tmp/ksu_module_teardown.sh
MOD=/data/local/tmp/mod
L=/data/local/tmp/ksu_mod_apply.log
TL=/data/local/tmp/ksu_mod_teardown.log
U() { cut -d' ' -f1 /proc/uptime 2>&1; }
{
  echo "K0 date=$(date) up=$(U) id=[$(id)]"
  echo "K1 夹具形状复证（★选错夹具＝造出假负结果，这次就踩过）:"
  echo "   文件清单=[$(find $MOD -type f 2>&1 | tr '\n' ' ')]"
  echo "   system/ 下文件数=$([ -d $MOD/system ] && find $MOD/system -type f | wc -l || echo 无system目录)"
  grep -c selftest $MOD/post-fs-data.sh 2>&1 | sed 's/^/   post-fs-data.sh 里 selftest 出现次数=/'
  echo "   runner 在位=[ap=$( [ -f $AP ] && echo Y || echo N ) td=$( [ -f $TD ] && echo Y || echo N ) bind=$( [ -f /data/local/tmp/suwbind ] && echo Y || echo N )]"
  echo "K2 装前正对照（marker 必须=0）:"
  md5sum /system/etc/hosts 2>&1; head -1 /system/etc/hosts 2>&1
  grep -c suw-module-marker /system/etc/hosts 2>/dev/null | sed 's/^/marker_before=/'
  echo "K3 apply:"
  timeout 100 sh $AP $MOD
  echo "   APPLY_RC=$? up=$(U)"
  echo "K4 ★apply 日志留证（teardown 会删它，所以现在就抄）:"
  cp $L /data/local/tmp/w969_applylog.txt 2>&1; echo "   抄写 rc=$? 字节=$(wc -c < /data/local/tmp/w969_applylog.txt 2>&1)"
  echo "K5 装后判据:"
  md5sum /system/etc/hosts 2>&1
  grep -c suw-module-marker /system/etc/hosts 2>/dev/null | sed 's/^/marker_after=/'
  echo "   挂载表(REC)=$(wc -c < /data/local/tmp/ksu_mod_mounts.txt 2>&1) 字节:"; cat /data/local/tmp/ksu_mod_mounts.txt 2>&1
  echo "   模块脚本自己的 selftest:"; cat /data/local/tmp/ksu_mod_selftest.txt 2>&1
  echo "K6 teardown:"
  timeout 60 sh $TD $MOD
  echo "   TD_RC=$? up=$(U)"
  echo "K7 卸后（必须回到装前状态）:"
  md5sum /system/etc/hosts 2>&1
  grep -c suw-module-marker /system/etc/hosts 2>/dev/null | sed 's/^/marker_left=/'
  echo "   teardown 日志尾两行:"; tail -2 $TL 2>&1
  echo "K8 交付链没被碰坏的证人:"; ls -l /data/local/tmp/kd 2>&1 | tail -1; md5sum /product/bin/su 2>&1
  echo "KZ_END date=$(date) up=$(U)"
} > $O 2>&1
chmod 666 $O /data/local/tmp/w969_applylog.txt 2>&1
