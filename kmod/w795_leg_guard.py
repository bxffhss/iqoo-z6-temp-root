import io
import os
import re
import sys

# w795_leg_guard.py —— 设备腿的一条静态闸：**"要 root 的产物"必须在"恢复执法"之前就 chmod 666**。
#   一手教训(第 54 发)：`w789_close_dev.sh` 原来把 `chmod 666 "$L"` 排在 `echo 1 > /sys/fs/selinux/enforce` **之后**
#     ⇒ 执法一开，那条腿连自己的产物都改不动权限(实得 `root:root 0600`)，收尾里的 `umount rc`／`/data/adb 复证`
#     全部变成"读不到"。记忆那条".out 要 chmod 666"讲的是**没 chmod**；这一格是**排错了位置**，同一族但新形状。
#   ★两道方向都要有牙：①真仓里逐个扫(命中就红)；②`--self` 自带正/负夹具——
#     负夹具＝"chmod 在执法之后"那个形状必须被抓出来，正夹具＝修好的形状必须放过。
ENF = re.compile(r">\s*/sys/fs/selinux/enforce")
ART = re.compile(r'(?:^|[^0-9A-Za-z_/])(?:[:]>|>>?)\s*"?\$\(?\s*(L|LOG|OUT)\b')
CHM = re.compile(r'chmod\s+(?:666|0666|a\+rw)\s+"?\$\(?\s*(L|LOG|OUT)\b')

# ★豁免表(有牙，不是橡皮图章)：这三支是**已经跑完的历史腿**，它们的哈希当作「现取」登记在台账里
#   (w767＝`5ef047d5`、见 §6.423/CURRENT-STATUS 的现值行)——**改文件就会把那句登记变成假话**。
#   所以这里只登记"这条规矩生效之前的旧形状"，并且：①表长上限 4，②每条必须给理由，③下一次谁要动这些件，
#   必须同时把台账里的登记改成「当时＝」再删掉这一行。新写的腿**不许进这张表**。
LEGACY = {
    "w223_flip.sh": "第 22 发前的旧腿，台账里以当时哈希登记",
    "w579_enforce.sh": "§6.402 那条'可用备胎'，历史读数已引用其哈希",
    "w767_close_shot53.sh": "§6.423 现值登记＝5ef047d5，改文件会造出假登记",
}


def cap_check():
    if len(LEGACY) > 4:
        print("[x] 豁免表超过 4 条 ⇒ 这条闸正在被稀释"); return 1
    for k, v in LEGACY.items():
        if not v.strip():
            print("[x] 豁免条目 %s 没写理由" % k); return 1
    return 0


def scan(path):
    """返回 (是否设备腿, 违规说明或 None)。只看"写产物＋翻执法"两件都发生的腿。"""
    try:
        txt = io.open(path, "rb").read().decode("utf-8", "replace")
    except Exception as e:
        return False, None
    if "#!/system/bin/sh" not in txt:
        return False, None
    lines = txt.split("\n")
    enf_ln = None
    for i, l in enumerate(lines, 1):
        if l.strip().startswith("#"):
            continue
        if ENF.search(l):
            enf_ln = i
            break
    if enf_ln is None:
        return True, None
    art_ln = None
    for i, l in enumerate(lines, 1):
        if l.strip().startswith("#"):
            continue
        if ART.search(l):
            art_ln = i
            break
    if art_ln is None:
        return True, None
    chm_ln = None
    for i, l in enumerate(lines, 1):
        if l.strip().startswith("#"):
            continue
        if CHM.search(l):
            chm_ln = i
            break
    if chm_ln is None:
        return True, ("写产物(第 %d 行)＋翻执法(第 %d 行)但**全文没有 chmod 666**" % (art_ln, enf_ln))
    if chm_ln > enf_ln:
        return True, ("chmod 666 在第 %d 行，**排在恢复执法(第 %d 行)之后** ⇒ 执法一开就改不动了"
                      % (chm_ln, enf_ln))
    return True, None


def run_corpus():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)))
    bad = 0
    checked = 0
    print("=== W795 设备腿产物权限闸(扫 kmod/*.sh 里 #!/system/bin/sh 那批) ===")
    for name in sorted(os.listdir(root)):
        if not name.endswith(".sh"):
            continue
        p = os.path.join(root, name)
        dev, why = scan(p)
        if not dev:
            continue
        checked += 1
        if why and name in LEGACY:
            print("  [豁免] kmod/%s ⇒ %s｜理由：%s" % (name, why, LEGACY[name]))
            continue
        if why:
            bad += 1
            print("  [BAD] kmod/%s ⇒ %s" % (name, why))
        else:
            print("  [OK] kmod/%s (设备腿，写产物与执法顺序没毛病)" % name)
    print("  共扫设备腿 %d 支，红 %d 支，豁免表 %d 条" % (checked, bad, len(LEGACY)))
    if cap_check():
        bad += 1
    # ★豁免表自己要有牙：表里列的名字必须在仓里存在(悄悄失效的豁免＝例 175 那一族)
    for name in LEGACY:
        if not os.path.exists(os.path.join(root, name)):
            print("  [BAD] 豁免表里的 kmod/%s 已不在仓里 ⇒ 这条豁免是死的，删掉它" % name)
            bad += 1
    return bad, checked


def fixture(text, name):
    import tempfile
    d = tempfile.mkdtemp(prefix="w795_")
    p = os.path.join(d, name)
    io.open(p, "w", encoding="utf-8").write(text)
    return p


def run_self():
    print("=== W795 自检(离线夹具，两向都有牙) ===")
    fail = 0
    NEG = ('#!/system/bin/sh\nL=/data/local/tmp/x.out\n{\n  echo hi > "$L"\n'
           '  echo 1 > /sys/fs/selinux/enforce\n} >> "$L" 2>&1\nchmod 666 "$L"\n')
    POS = ('#!/system/bin/sh\nL=/data/local/tmp/x.out\n: > "$L"\nchmod 666 "$L"\n{\n'
           '  echo hi >> "$L"\n  echo 1 > /sys/fs/selinux/enforce\n}\n')
    NONE = '#!/system/bin/sh\necho hello\n'
    p = fixture(NEG, "neg.sh")
    dev, why = scan(p)
    if why and "排在恢复执法" in why:
        print("  [OK] 负夹具(chmod 在执法后)被抓到 ⇒ %s" % why)
    else:
        print("  [BAD] 负夹具没牙(读到 %s) ⇒ 这条闸认不出今晚那个形状" % (why or "无")); fail = 1
    p = fixture(POS, "pos.sh")
    dev, why = scan(p)
    if why is None:
        print("  [OK] 正夹具(chmod 在开头)放过")
    else:
        print("  [BAD] 正夹具被误伤 ⇒ %s" % why); fail = 1
    p = fixture(NEG.replace('chmod 666 "$L"', 'chmod 755 "$L"'), "neg2.sh")
    dev, why = scan(p)
    if why and "没有 chmod 666" in why:
        print("  [OK] 负夹具二(chmod 成了 755＝adb 仍读不到)被抓到")
    else:
        print("  [BAD] 只认 666 这一支没牙(读到 %s)" % (why or "无")); fail = 1
    p = fixture(NONE, "none.sh")
    dev, why = scan(p)
    if dev and why is None:
        print("  [OK] 不写产物也不翻执法的腿＝不判(不误伤)")
    else:
        print("  [BAD] 不相关的腿被误判 ⇒ %s" % why); fail = 1
    print("  === 顺带扫真仓 ===")
    bad, checked = run_corpus()
    if bad:
        print("[x] 真仓里有 %d 支红 ⇒ 逐条修(先修位置，再谈要不要留产物)" % bad); fail = 1
    if fail:
        print("FAIL"); return 1
    print("PASS(夹具四格齐＋真仓 %d 支设备腿全绿)" % checked)
    return 0


if __name__ == "__main__":
    if "--self" in sys.argv or "selfcheck" in sys.argv:
        sys.exit(run_self())
    bad, checked = run_corpus()
    sys.exit(1 if bad else 0)
