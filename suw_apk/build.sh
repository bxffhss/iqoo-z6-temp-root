#!/bin/bash
# 构建"SU 白名单管理器"APK —— 纯命令行(aapt2 + javac + d8 + zipalign + apksigner), 不用 gradle。
# 产物: suw.apk (本目录)。工具链路径与 poc_apk/build.sh 保持一致(同一台机器上已跑通过)。
set -eu -o pipefail
cd "$(dirname "$0")"

SDK="J:/Users/Administrator/AppData/Local/Android/Sdk"
BT="$SDK/build-tools/36.0.0"
AJ="$SDK/platforms/android-35/android.jar"
PY="C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"
KEYTOOL="J:/Program Files/Java/jre1.8.0_181/bin/keytool.exe"
KS=suw.keystore
KS_PASS=android

[ -f "$AJ" ] || { echo "找不到 android.jar: $AJ"; exit 1; }
rm -rf build && mkdir -p build/obj build/dex

echo "== 0. 生成 Cfg.java(token 与 shd 编译时用的是同一个) 与 SlideTable.java =="
"$PY" - <<'PY'
import io, os
tok = io.open('token.txt', encoding='utf-8').read().strip()
# 控制面 token 单独一个: 泄漏一个不该顺带泄漏另一个。没有就生成一个固定的(必须跨构建稳定,
# 否则 APK 里的 token 和设备上 sudbin 里的会对不上)。
p = 'token_ctrl.txt'
if not os.path.exists(p) or not io.open(p, encoding='utf-8').read().strip():
    import uuid
    io.open(p, 'w', encoding='utf-8', newline='\n').write(uuid.uuid4().hex[:24] + '\n')
ctrl = io.open(p, encoding='utf-8').read().strip()
os.makedirs(os.path.join('src', 'com', 'suw', 'manager'), exist_ok=True)
io.open(os.path.join('src', 'com', 'suw', 'manager', 'Cfg.java'), 'w', encoding='utf-8', newline='\n').write(
    'package com.suw.manager;\n'
    '// 由 build.sh 生成(与 shd.c 的 -DSUW_TOKEN、sud.c 的 -DSUW_CTRL_TOKEN 同源) —— 手改会被覆盖。\n'
    'public final class Cfg {\n'
    '  public static final String TOKEN = "%s";   // agent(shd) 的 TCP 通道\n'
    '  public static final String CTRL  = "%s";   // daemon(sud) 的控制面: 只允许改白名单\n'
    '}\n' % (tok, ctrl))
print('Cfg.java 已生成 (agent token + ctrl token)')
PY
"$PY" gen_slide_table.py

echo "== 0.5 编 app 侧 .so(§6.18 探针 + §6.59 内核授权自检, 同一个 libksuprobe.so) =="
ND="$SDK/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin"
NDCL="$ND/aarch64-linux-android35-clang.cmd"
mkdir -p jniLibs/arm64-v8a
"$NDCL" -shared -fPIC -O2 -Wall -Wno-unused-const-variable -I../kmod \
        -o jniLibs/arm64-v8a/libksuprobe.so probe_jni.c suwksu_jni.c \
  || { echo "!! .so 编不过 ⇒ 停"; exit 1; }
# 符号必须在: 少了任何一个, Java 侧就是 UnsatisfiedLinkError(而且是静默的, 因为都包在 try 里)
"$ND/llvm-nm.exe" -D --defined-only jniLibs/arm64-v8a/libksuprobe.so > build/nm.txt 2>&1
for s in Java_com_suw_manager_Probe_run Java_com_suw_manager_Ksu_nativeRun; do
  grep -q "$s" build/nm.txt || { echo "!! .so 里没有 $s ⇒ 停"; exit 1; }
done
ls -l jniLibs/arm64-v8a/libksuprobe.so

echo "== 1. javac =="
javac --release 8 -encoding UTF-8 -classpath "$AJ" -d build/obj \
      src/com/suw/manager/*.java || { echo "!! javac 失败 ⇒ 停(不许产出半套 dex)"; exit 1; }
find build/obj -name '*.class' | head

echo "== 2. d8 -> classes.dex =="
"$BT/d8.bat" --release --lib "$AJ" --min-api 34 --output build/dex \
   $(find build/obj -name '*.class') 2>&1 | tail -3
ls -l build/dex/classes.dex

echo "== 3. aapt2 link(只有 manifest, 无 res) =="
"$BT/aapt2.exe" link -o build/base.apk -I "$AJ" --manifest AndroidManifest.xml 2>&1 | tail -5
ls -l build/base.apk

echo "== 4. 把 classes.dex 塞进 apk =="
"$PY" - <<'PY'
import zipfile
items = {}
zin = zipfile.ZipFile('build/base.apk', 'r')
for n in zin.namelist():
    items[n] = (zin.read(n), zin.getinfo(n).compress_type)
zin.close()
items['classes.dex'] = (open('build/dex/classes.dex', 'rb').read(), zipfile.ZIP_DEFLATED)
# app 域的裸 syscall 探针(§6.18): manifest 没写 extractNativeLibs ⇒ 默认 true ⇒ 压缩存进去即可,
# 装机时解到 app 的 nativeLibraryDir, System.loadLibrary 才找得到(放 assets 里是加载不了的)
import os
so = 'jniLibs/arm64-v8a/libksuprobe.so'
if os.path.exists(so):
    items['lib/arm64-v8a/libksuprobe.so'] = (open(so, 'rb').read(), zipfile.ZIP_DEFLATED)
else:
    print('!! 没有', so, '⇒ Probe.runOnce 会返回 false(探针不跑, 主功能不受影响)')
zo = zipfile.ZipFile('build/base.apk', 'w', zipfile.ZIP_DEFLATED)
for n, (d, ct) in items.items():
    # Android 11+ 要求 resources.arsc **不压缩**且 4 字节对齐, 否则装不上:
    #   INSTALL_FAILED_ABORTED 之后是 "Targeting R+ requires the resources.arsc ...
    #   stored uncompressed and aligned on a 4-byte boundary" (-124)
    zo.writestr(zipfile.ZipInfo(n), d, compress_type=zipfile.ZIP_STORED if n == 'resources.arsc' else ct)
zo.close()
print('apk 条目 =', list(items.keys()))
PY

echo "== 5. zipalign + 签名 =="
"$BT/zipalign.exe" -f 4 build/base.apk build/aligned.apk
if [ ! -f "$KS" ]; then
  "$KEYTOOL" -genkeypair -keystore "$KS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -alias suw -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=suw" 2>&1 | tail -2
fi
# ★必须只留 v2：KernelSU 的 apk_sign.c 解析 signing block 时，遇到不是 v2(0x7109871a) 也不是
#   verity padding(0x42726577) 的 pair 就 goto invalid ⇒ **v3 pair 会把已经验过的 v2 结果整个丢掉**
#   (§6.77：这才是 suw.apk 当不上 Manager 的真因，与证书指纹无关；官方 apk 只有 v2 所以它能过)
"$BT/apksigner.bat" sign --ks "$KS" --ks-pass pass:$KS_PASS --key-pass pass:$KS_PASS \
    --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled false --v4-signing-enabled false \
    --out suw.apk build/aligned.apk 2>&1 | tail -3
"$BT/apksigner.bat" verify suw.apk 2>&1 | head -2

echo "== 6. 顺带编译 shell 侧 agent 与 root 侧 daemon(同一个 token 体系) =="
NDKCL="$SDK/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"
TOK=$("$PY" -c "import io;print(io.open('token.txt',encoding='utf-8').read().strip())")
CTOK=$("$PY" -c "import io;print(io.open('token_ctrl.txt',encoding='utf-8').read().strip())")
"$NDKCL" -O2 -static -Wall -Wno-unused-const-variable -I../kmod -DSUW_TOKEN="\"$TOK\"" -o shdbin shd.c 2>&1 | head -5
[ -f shdbin ] || { echo "!! shdbin 没产出 ⇒ 停"; exit 1; }
# 闸: v3 的 KSUFD 动词必须真编进去了(否则窗口里会发现 agent 根本不认这个动词)
grep -a "KSUFD" shdbin >/dev/null || { echo "!! shdbin 里没有 KSUFD ⇒ 停(shd.c 没编进去?)"; exit 1; }
# shd v4 的闸：unix 放行要**问内核**(UID_GRANTED_ROOT)，不是只认自己的 uid 白名单
grep -a "AUTH unix ok" shdbin >/dev/null || { echo "!! shdbin 里没有 unix 放行回执 ⇒ 停"; exit 1; }
# ★§6.123：给第三方 app 的**静态 su**(不碰 syscall 钩子、不碰挂载)
"$NDKCL" -O2 -static -Wall -I../kmod -o ../cm57/sustatic ../cm57/su_static.c 2>&1 | head -10
[ -f ../cm57/sustatic ] || { echo "!! sustatic 没产出 ⇒ 停"; exit 1; }
grep -a "KSUFD" ../cm57/sustatic >/dev/null || { echo "!! sustatic 里没有 KSUFD ⇒ 停"; exit 1; }
ls -l ../cm57/sustatic | awk '{print "  sustatic 静态:", $5, "字节"}'
"$NDKCL" -O2 -static -Wall -DSUW_CTRL_TOKEN="\"$CTOK\"" -o sudbin ../cm57/sud.c 2>&1 | head -20
[ -f sudbin ] || { echo "!! sudbin 没产出 ⇒ 停(控制面 token 没编进去的话, manager 会一路走 su 而自锁)"; exit 1; }
# 自检: token 必须真的同时在 sudbin 和 APK 的 dex 里, 否则两边对不上、控制面永远走 fallback
"$PY" - "$CTOK" <<'PY'
import io, sys
tok = sys.argv[1].encode()
for f in ('sudbin', 'build/dex/classes.dex'):
    n = io.open(f, 'rb').read().count(tok)
    print('  token in %-22s = %d' % (f, n))
    if n == 0: sys.exit('!! %s 里没有控制面 token ⇒ 停' % f)
PY
ls -l shdbin sudbin

ls -l suw.apk
echo "DONE -> $(pwd)/suw.apk"
echo "启动 agent(每次开机一次, 白名单里放 manager 自己的 uid):"
echo "  adb shell 'setsid nohup /data/local/tmp/shd 31339 120 <app_uid> </dev/null >>/data/local/tmp/shd.log 2>&1 &'"
