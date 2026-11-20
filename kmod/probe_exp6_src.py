import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
for pat in ("ksu_sulog_capture_root_execve", "void ksu_execve_hook_ksud", "ksu_execve_hook_ksud(struct"):
    r = api.exec("grep -rn '%s' /root/k/ksu/kernel --include=*.c --include=*.h | head -6" % pat, timeout=120)
    print("### ", pat)
    print(r.stdout.strip() or "(none)")
