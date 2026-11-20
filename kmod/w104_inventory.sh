#!/usr/bin/env bash
# w104_inventory.sh —— 只读清点"这个项目相关的字节在这台机上到底有哪些"。
# 用途：两台构建机各跑一次，把回执 diff 出来 ⇒ 迁移有没有漏，靠差分而不是靠印象。
# 不写任何东西除了 $HOME/inv_1028.log；不碰 /sys、不装包、不删文件。
# 跑法：PYTHONUTF8=1 python <客户端>/cli.py exec --file kmod/w104_inventory.sh --timeout 900

L="$HOME/inv_1028.log"
: > "$L"
q() { echo "$@" >> "$L"; }

q "TAG $(hostname) epoch=$(date -u +%s) up=$(cut -d' ' -f1 /proc/uptime)"

q ""
q "## 1) /root 顶层有什么"
ls -1 /root >> "$L" 2>&1
q "-- /root 每个顶层条目占多少（★不能写 -s：-s 会把 max-depth 顶成 0，输出整段空）"
du -kx --max-depth=1 /root 2>/dev/null | sort -n >> "$L"

q ""
q "## 2) /root/k 每棵树的形状"
for d in /root/k/*; do
  if [ -d "$d" ]; then
    n=$(find "$d" 2>/dev/null | wc -l)
    q "DIR  $(basename "$d")  entries=$n"
  else
    q "FILE $(basename "$d")  bytes=$(stat -c %s "$d")"
  fi
done

q ""
q "## 3) 关键证人 md5（新机必须与旧机同值）"
md5sum "$HOME/Module.symvers_dev" >>"$L" 2>&1
md5sum /root/k/nothing_sm7325_v_mr/.config >>"$L" 2>&1
md5sum /root/k/nothing_sm7325_v_mr/Module.symvers >>"$L" 2>&1
md5sum /root/k/linux-5.4.281/Makefile >>"$L" 2>&1
md5sum "$HOME/config_dev.txt" >>"$L" 2>&1
for f in kernel/hook/syscall_hook.c kernel/policy/allowlist.c kernel/supercall/dispatch.c; do
  md5sum "/root/k/ksu/$f" >>"$L" 2>&1
done

q ""
q "## 4) ksu 脏树可复算量"
if command -v git >/dev/null 2>&1; then
  cd /root/k/ksu 2>/dev/null || q "git: /root/k/ksu 不存在"
  q "HEAD=$(git rev-parse --short HEAD 2>/dev/null)"
  q "porcelain=$(git status --porcelain 2>/dev/null | wc -l)"
  q "KSUBEAT_files=$(grep -rl KSUBEAT . 2>/dev/null | wc -l)"
  q "diffstat=$(git diff --shortstat 2>/dev/null)"
  q "untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)"
  cd "$HOME" || true
else
  q "git 不可用"
fi

q ""
q "## 5) /home/lucy 顶层账"
q "entries=$(ls -1A "$HOME" | wc -l)"
q "py=$(ls -1A "$HOME"/*.py 2>/dev/null | wc -l)"
q "sh=$(ls -1A "$HOME"/*.sh 2>/dev/null | wc -l)"
q "patch=$(ls -1A "$HOME"/*.patch 2>/dev/null | wc -l)"
q "ko=$(ls -1A "$HOME"/*.ko 2>/dev/null | wc -l)"
q "tgz_tar_zst=$(ls -1A "$HOME"/*.tgz "$HOME"/*.tar "$HOME"/*.tar.* 2>/dev/null | wc -l)"
q "-- 目录"
find "$HOME" -maxdepth 1 -type d 2>/dev/null | sort >> "$L"
q "-- 非目录、非上面四类扩展名的顶层文件（这一格最容易藏漏搬的东西）"
find "$HOME" -maxdepth 1 -type f ! -name '*.py' ! -name '*.sh' ! -name '*.patch' ! -name '*.ko' 2>/dev/null | sort >> "$L"
q "-- kshim / w985_ssport 里有多少件"
for d in "$HOME/kshim" "$HOME/w985_ssport"; do
  q "$(basename "$d") files=$(find "$d" -type f 2>/dev/null | wc -l)"
done

q ""
q "## 6) 项目留下的挂载点/落点目录（不在 /root/k 也不在 /home/lucy 的那些）"
for p in /root/k/layout_nothing_sm7325_v_mr /root/k/ksu_out /opt/asdk /opt/asdk/ndk /root/clangrepo /data /tmp; do
  if [ -e "$p" ]; then
    q "EXISTS $p entries=$(ls -1A "$p" 2>/dev/null | wc -l)"
  else
    q "ABSENT $p"
  fi
done
q "-- /root 下散落的自建文件（*.log/*.txt/*.json/*.sh）"
ls -1 /root/*.log /root/*.txt /root/*.json /root/*.sh 2>/dev/null >> "$L"

q ""
q "## 7) 工具链现值（新机要能编出货）"
for t in clang lld ld.lld llvm-readelf aarch64-linux-gnu-gcc gcc make flex bison bc pahole perl git curl zstd xz; do
  v=$(command -v "$t" 2>/dev/null)
  q "TOOL $t -> ${v:-MISSING}"
done
q "clang_ver=$(clang --version 2>/dev/null | head -1)"
q "setools_py=$(/usr/bin/python3.11 -c 'import setools;print(setools.__file__)' 2>&1 | head -1)"

q ""
q "## 8) 配额与磁盘（两台应同规格）"
q "cpu.max=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null | tr '\n' ' ')"
q "memory.max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
q "mem_current=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"
df -h / | tail -1 >> "$L"

q ""
q "## 9) 上传孤儿与作业残留"
q "mount_entries=$(find "$HOME/mount" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
q "hj_entries=$(find "$HOME/.hj" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
q "links=$(find "$HOME" -xdev -maxdepth 3 -type l 2>/dev/null | wc -l)"
q "dangling=$(find "$HOME" -xdev -maxdepth 3 -xtype l 2>/dev/null | wc -l)"
q "-- /home/lucy 每个顶层条目占多少（同一条 -s 坑，别改回去）"
du -kx --max-depth=1 "$HOME" 2>/dev/null | sort -n | tail -25 >> "$L"

q "END"
echo "LOGPATH=$L"
wc -c < "$L"
