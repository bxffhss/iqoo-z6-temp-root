import io, os, sys, hashlib

LEDGER = "kmod/ROUTE-B-OFFSET-INVERSION.md"
FRAG = "kmod/w827_sec6430_6431.md"

if not (os.getcwd().replace("\\", "/").endswith("临时root")):
    sys.exit("[x] 不在项目根：cwd=%s ⇒ 停" % os.getcwd())

frag = io.open(FRAG, encoding="utf-8").read()
old = io.open(LEDGER, encoding="utf-8").read()

# 阶段一：全局核锚（不许写成功一半）
checks = []
for h in ("## §6.430 ", "## §6.431 "):
    checks.append((frag.count(h), 1, "片段里必须有且只有 1 个 %s 标题" % h.strip()))
if "## §6.430 " in old:
    checks.append((0, 1, "总账里已经有 §6.430 ⇒ 这条脚本不许重跑(会写两份)"))
if not old.endswith("\n"):
    checks.append((0, 1, "总账末尾没有换行 ⇒ 追加会粘到上一行"))
bad = [(g, e, w) for (g, e, w) in checks if g != e]
if bad:
    for g, e, w in bad:
        print("[x] 锚点不符：现得 %s 期望 %s —— %s" % (g, e, w))
    sys.exit(1)
print("[ok] 阶段一核过 %d 条锚点" % len(checks))

# 阶段二：统一写
new = old + "\n" + frag if not old.endswith("\n\n") else old + frag
io.open(LEDGER, "w", encoding="utf-8", newline="").write(new)

# 读回复证：字节差必须等于片段长度，两个标题各 1 次
back = io.open(LEDGER, encoding="utf-8").read()
d = len(back) - len(old)
print("  写入字节差=%d  片段字节=%d" % (d, len(frag)))
assert d in (len(frag), len(frag) + 1), "字节差不对 ⇒ 追加形状不由我控"
for h in ("## §6.430 ", "## §6.431 "):
    assert back.count(h) == 1, "%s 出现 %d 次" % (h, back.count(h))
assert "PS_HOLD/0x01+0x01" in back and "[permanent]" in back, "两条一手证人没进去"
print("[ok] §6.430/§6.431 各 1 个标题；总账行数 %d → %d" % (old.count("\n"), back.count("\n")))
print("  md5 总账=%s" % hashlib.md5(io.open(LEDGER, "rb").read()).hexdigest()[:8])
