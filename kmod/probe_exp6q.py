import sys, hashlib, base64
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
R = "/root/k/ksu/kernel/feature/sucompat.c"
r = api.exec("ls -l %s; md5sum %s" % (R, R), timeout=120)
print(r.stdout.strip())
b = api.exec("base64 -w0 %s" % R, timeout=180)
raw = base64.b64decode("".join(b.stdout.split()))
print("bytes=", len(raw), "md5=", hashlib.md5(raw).hexdigest())
open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c","wb").write(raw)
txt = raw.decode("utf-8")
# SD1 原文与上下文
i = txt.find("KSUBEAT SD1")
print("\n--- SD1 上下文 ---")
print(txt[max(0,i-420):i+260])
print("\n--- pr_info 总数 ---", txt.count("pr_info("))
print("--- module.h? ---", "linux/module.h" in txt, "| moduleparam?", "moduleparam" in txt)
