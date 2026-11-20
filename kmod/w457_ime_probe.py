# w457_ime_probe.py —— 零枪量"往真输入框打字到底会不会被打乱"，并把成因分开：
#   exact = 逐字对上 / prefix|infix = 只读到一部分(我读早了，字段还在收键)
#   rotation = 字母一个没丢但顺序变了(输入法真的重排) / merge = 比期望串长(上次的残留没清干净)
# 为什么能在零枪做：打字失真与"临时 root 窗口"无关，只要有一个**前台包名对得上、文本读得回来**的真输入框。
# ★每一次读数都当场核对前台包名：第 0 版就是被"页已经换到 Settings 却还按旧坐标读"骗过(§6.373)。
# 用法：python kmod/w457_ime_probe.py --pkg com.absinthe.libchecker \
#          --launch "monkey -p com.absinthe.libchecker -c android.intent.category.LAUNCHER 1" \
#          --tap 612,190 --ph '搜索…' --word suprobe --method burst --reps 3 [--ime <id>]
import io, os, re, subprocess, sys, time, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--tap", required=True)
ap.add_argument("--pkg", required=True)
ap.add_argument("--word", required=True)
ap.add_argument("--method", default="burst", choices=["burst", "perchar"])
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--ime", default="")
ap.add_argument("--launch", default="")
ap.add_argument("--ph", default="", help="占位符文本(读数等于它＝字段其实是空的)")
ap.add_argument("--reset", default="none", choices=["none", "blur", "back"],
                help="清完字之后要不要先'离开字段再回来'(把输入法的拼音缓冲甩掉)")
ap.add_argument("--blur", default="", help="--reset blur 时点的中立坐标(列表空白处，别点到行)")
ap.add_argument("--settle", type=float, default=3.0)
a = ap.parse_args()

DEV = ["adb", "-s", "<DEVICE_SERIAL>"]
a.evdir = "kmod/w103_evidence"
os.makedirs(a.evdir, exist_ok=True)


def sh(cmd):
    return subprocess.run(DEV + ["shell", cmd], capture_output=True, text=True,
                          encoding="utf-8", errors="replace").stdout.replace("\r", "")


def attr(t, k):
    m = re.search(r'%s="([^"]*)"' % k, t)
    return m.group(1) if m else ""


def read_field(tag):
    """返回 (这棵树唯一的包名, 第一个输入框的文本)。
       ★前台不是声明的那个包 ⇒ 包名照原样返回、文本给空 —— 在别人的页面里打字＝把字打到别人那里。"""
    sh("rm -f /sdcard/p.xml; uiautomator dump /sdcard/p.xml >/dev/null 2>&1; echo")
    dst = os.path.join(a.evdir, "w457_%s.xml" % tag)
    subprocess.run(DEV + ["pull", "//sdcard/p.xml", dst], capture_output=True)
    if not (os.path.exists(dst) and os.path.getsize(dst)):
        return "(dump 没产出)", ""
    s = io.open(dst, encoding="utf-8", errors="replace").read()
    pk = sorted(set(re.findall(r'package="([^"]*)"', s)))
    if pk != [a.pkg]:
        return ("+".join(pk) if pk else "(空)"), ""
    eds = [attr(t.group(0), "text") for t in re.finditer(r'<node[^>]*', s)
           if 'Edit' in attr(t.group(0), "class") or 'AutoComplete' in attr(t.group(0), "class")]
    return a.pkg, (eds[0] if eds else "★这页没有输入框")


def settle(tag0):
    """打完之后**连读**：只有过 --settle 秒还不等于期望值才算真失败；中途读到前缀＝我读早了。
       读数序列原样打出来 ⇒ 成因由序列判，不由我猜。"""
    seq = []
    t0 = time.time()
    last = None
    while time.time() - t0 < a.settle:
        pk, v = read_field("%s_r%d" % (tag0, len(seq)))
        if pk != a.pkg:
            seq.append((round(time.time() - t0, 2), "★页换了[%s]" % pk))
            break
        if v != last:
            seq.append((round(time.time() - t0, 2), v))
            last = v
            if v == a.word:
                break
        time.sleep(0.35)
    return seq


def classify(v):
    if v == a.word:
        return "exact"
    if not v:
        return "empty"
    if a.word.startswith(v):
        return "prefix(读早了/漏尾)"
    if v in a.word:
        return "infix(漏头尾)"
    if sorted(v.lower()) == sorted(a.word.lower()):
        return "rotation(重排，字母没丢)"
    if len(v) > len(a.word):
        return "merge(粘上残留)"
    return "other"


orig_ime = ""
if a.ime:
    orig_ime = sh("settings get secure default_input_method").strip()
    sh("ime enable %s" % a.ime)
    sh("ime set %s" % a.ime)
    time.sleep(1.5)
    got = sh("settings get secure default_input_method").strip()
    print("切换输入法：原=%s -> 现=%s %s" % (orig_ime, got, "OK" if got == a.ime else "★没切上"))
    if got != a.ime:
        sys.exit(2)

TX, TY = a.tap.split(",")
n_ok = 0
empties = ("", a.ph)
try:
    for r in range(1, a.reps + 1):
        if a.launch:
            sh(a.launch)
            time.sleep(5)
        pk, v = read_field("rep%d_pre" % r)
        if pk != a.pkg:
            print("rep%d [x] 前台是 %s 不是 %s ⇒ 一条键都不发" % (r, pk, a.pkg))
            break
        if v == "★这页没有输入框":
            print("rep%d [x] 这页没有输入框 ⇒ 停(别把键打到没有输入框的页面上)" % r)
            break
        sh("input tap %s %s" % (TX, TY))
        time.sleep(1.5)
        # ★不用 KEYCODE_MOVE_END(123)：本机讯飞把它当"收起/返回"，实测会把搜索页整个关掉
        #   (LibChecker ⇒ Launcher，Settings ⇒ 上一个活动) ⇒ 只按退格删，光标本来就在末尾。
        for _ in range(len(a.word) + 6):
            sh("input keyevent 67")
        time.sleep(0.6)
        pk, pre = read_field("rep%d_preclear" % r)
        if pk != a.pkg:
            print("rep%d [x] 清空后页换了(%s) ⇒ 本轮作废，不打字" % (r, pk))
            break
        if pre not in empties:
            print("rep%d   ▲ 清空后字段还是 [%s] ⇒ '空'判别不可信，照打但记一笔" % (r, pre))
        if a.reset == "back":
            # ★用退格之外的"收起输入法"：BACK 在 IME 可见时只收键盘、不离开这一页 ⇒ 输入法的拼音缓冲被丢弃
            sh("input keyevent 4"); time.sleep(1.2)
            sh("input tap %s %s" % (TX, TY)); time.sleep(1.2)
            pk, mid = read_field("rep%d_back" % r)
            if pk != a.pkg:
                print("rep%d [x] BACK 之后页换了(%s) ⇒ 本轮作废，不打字" % (r, pk))
                break
            print("rep%d   收起再点后字段=[%s]" % (r, mid))
        if a.reset == "blur" and a.blur:
            # ★离开字段再回来：输入法(iflytek)的拼音缓冲在"删光可见文本"之后仍会把尾巴 'ux' 提交回来
            BX, BY = a.blur.split(",")
            sh("input tap %s %s" % (BX, BY))
            time.sleep(1.2)
            sh("input tap %s %s" % (TX, TY))
            time.sleep(1.2)
            pk, mid = read_field("rep%d_blur" % r)
            if pk != a.pkg:
                print("rep%d [x] blur 之后页换了(%s) ⇒ 本轮作废，不打字" % (r, pk))
                break
            print("rep%d   blur 后再读一次字段=[%s]" % (r, mid))
        if a.method == "burst":
            sh('input text "%s"' % a.word)
        else:
            for ch in a.word:
                sh('input text "%s"' % ch)
                time.sleep(0.2)
        seq = settle("rep%d" % r)
        fin = seq[-1][1] if seq else ""
        c = "串页" if fin.startswith("★") else classify(fin)
        n_ok += (c == "exact")
        print("rep%d 方法=%s 清空后=[%s] 读数序列=%s 末读=[%s] 判定=%s" % (r, a.method, pre, seq, fin, c))
    print("=== 方法=%s IME=%s：逐字对上 %d/%d" % (a.method, a.ime or "当前", n_ok, a.reps))
finally:
    if a.ime and orig_ime:
        sh("ime set %s" % orig_ime)
        time.sleep(1.0)
        back = sh("settings get secure default_input_method").strip()
        print("复原输入法：现=%s %s" % (back, "OK" if back == orig_ime else "★没复原，请手工切回 %s" % orig_ime))
