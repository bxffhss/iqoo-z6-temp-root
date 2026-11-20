"""从 hermes 构建机拉取内核/KSU 源码（零设备风险）。

注意：FileBrowser 根 = $HOME=/home/lucy，看不到 /root 下的内核树。
所以 /root 下的一切都用 exec（看真实 fs）来做 ls/cat。
exec 默认只回读尾部 200K；源码文件通常 < 200K，够用；超了用 chunk 模式。

用法：
  python hermes_src_pull.py ls <远端dir>            # exec ls -la
  python hermes_src_pull.py cat <远端绝对路径> [本地保存]   # exec cat 全量
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "hermes-remote1"))
from hrmt import from_config

H = from_config()

def do_ping():
    print("PING:", H.ping())

def do_ls(d):
    res = H.exec(f"ls -la {d}", timeout=120)
    print(f"# ls -la {d}  (rc={res.exit_code})")
    print(res.stdout)
    if res.stderr.strip():
        print("[stderr]", res.stderr[:400])

def do_cat(remote, save=None):
    res = H.exec(f"wc -l {remote} && wc -c {remote}", timeout=120)
    print("[size]", res.stdout.strip() or res.stderr.strip()[:200])
    # 全量 cat，max_output 提到 3M
    res = H.exec(f"cat {remote}", timeout=180, max_output=3_000_000)
    if not res.started or res.exit_code is None:
        print(f"[cat 失败] started={res.started} rc={res.exit_code} stderr={res.stderr[:400]}")
        return
    data = res.stdout
    print(f"[read {len(data)} chars] truncated={res.stdout_truncated}")
    if save:
        os.makedirs(os.path.dirname(save) or ".", exist_ok=True)
        with open(save, "w", encoding="utf-8") as f:
            f.write(data)
        print(f"[saved] {save}")

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd == "ping":
        do_ping()
    elif cmd == "ls":
        do_ls(sys.argv[2] if len(sys.argv) > 2 else ".")
    elif cmd == "cat":
        remote = sys.argv[2]
        save = sys.argv[3] if len(sys.argv) > 3 else None
        if not save:
            base = os.path.basename(remote.rstrip("/"))
            save = os.path.join(os.path.dirname(__file__), "hermes_src", base)
        do_cat(remote, save)
    else:
        print(__doc__)

if __name__ == "__main__":
    main()
