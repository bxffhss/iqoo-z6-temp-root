#!/system/bin/sh
# w931_appleg.sh — 复证"槽已换回出货字节之后，交付那两条通道都还活着"。宿主＝run-as com.termux。
# 只报 rc＋首行，跑在翻执法之前；翻完执法再用同一条腿当正对照(B1)。
HA=/data/data/com.termux/files/home
A=$HA/w931.out
U() { cut -d' ' -f1 /proc/uptime; }
{
  echo "K0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "K1 slot=$(md5sum /product/bin/su 2>&1)"
} > $HA/w931_probe.txt 2>&1
cp $HA/w931_probe.txt $A 2>&1

echo "K2 product-bin-su direct" >> $A 2>&1
/product/bin/su -c id >> $A 2>&1
echo "K2 rc=$? up=$(U)" >> $A 2>&1

echo "K3 child android-mksh PATH su" >> $A 2>&1
/system/bin/sh -c 'su -c id' >> $A 2>&1
echo "K3 rc=$? up=$(U)" >> $A 2>&1

echo "K4 redirect channel (env + /system/bin/su)" >> $A 2>&1
/system/bin/env /system/bin/su -c id >> $A 2>&1
echo "K4 rc=$? up=$(U)" >> $A 2>&1

echo "KZ_END up=$(U)" >> $A 2>&1
chmod 666 $A 2>&1
