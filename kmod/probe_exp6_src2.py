import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
jobs = [("sulog/event.c 240-400", "sed -n '240,400p' /root/k/ksu/kernel/sulog/event.c"),
        ("ksud_integration.c 500,590", "sed -n '500,590p' /root/k/ksu/kernel/runtime/ksud_integration.c")]
for name, cmd in jobs:
    r = api.exec(cmd, timeout=120)
    print("=" * 20, name)
    print(r.stdout.rstrip())
