import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
r = api.exec("sed -n '140,240p' /root/k/ksu/kernel/runtime/ksud_integration.c", timeout=120)
print(r.stdout.rstrip())
