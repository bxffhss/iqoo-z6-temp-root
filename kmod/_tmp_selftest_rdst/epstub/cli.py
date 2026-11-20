# 桩：把收到的参数原样记进 $N_CNT，再吐一份 cli.py 形状的回执。
#   ★记的是**桩自己的绝对路径 ＋ 收到的全部参数**——"到底用了哪个端点、配置传没传下去"
#     必须由被叫起来的那一方作证，不叫 w682 自己说（它说什么都可能是猜的）。
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["N_CNT"], "a") as f:
    f.write(os.path.abspath(__file__) + " | " + " ".join(args) + "\n")
print(json.dumps({"id": "stub", "exit_code": 0, "stdout": "STUB_HOST\n", "stderr": "",
                  "elapsed": 0.1, "timed_out": False, "stdout_truncated": False, "ok": True}))
