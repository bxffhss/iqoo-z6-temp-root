import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
r = api.exec("sed -n '150,245p' /root/k/ksu/kernel/sulog/event.c", timeout=120)
print("=" * 20, "sulog/event.c 150,245"); print(r.stdout.rstrip())
g = api.exec("grep -rn 'ksu_handle_execveat_ksud' /root/k/ksu/kernel --include=*.c --include=*.h | head -5", timeout=120)
print("=" * 20, "locate ksud handler"); print(g.stdout.rstrip())
