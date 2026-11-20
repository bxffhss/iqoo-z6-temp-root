#!/bin/bash
# w1157_diag.sh —— 只看一件事：A 阶段(出货流水线)为什么 rc=1 且没产物。0 枪、不碰树。
set -u
echo "HOME 里相关文件:"
ls -l /home/lucy/ksu_rc74c.sh /home/lucy/kernelsu_rc74c.ko /home/lucy/w1156_A.log /home/lucy/ksu_rc74c.log 2>&1 | sed 's/^/  /'
echo; echo "A_LOG(w1156_A.log) 字节=$(wc -c </home/lucy/w1156_A.log 2>/dev/null | tr -dc '0-9') 行数=$(grep -c '' /home/lucy/w1156_A.log 2>/dev/null)"
echo "---- 前 40 行 ----"
head -40 /home/lucy/w1156_A.log 2>&1 | sed 's/^/  /'
echo "---- 后 25 行 ----"
tail -25 /home/lucy/w1156_A.log 2>&1 | sed 's/^/  /'
echo; echo "脚本自己那本日志 ksu_rc74c.log:"
[ -s /home/lucy/ksu_rc74c.log ] && tail -25 /home/lucy/ksu_rc74c.log | sed 's/^/  /' || echo "  (没有或为空)"
echo; echo "文件头 8 行(看行尾有没有 \r):"
head -8 /home/lucy/ksu_rc74c.sh | cat -A | cut -c1-120 | sed 's/^/  /'
echo; echo "树的状态(未提交改动条数，只读 git status):"
cd /root/k/ksu 2>/dev/null && git status --porcelain 2>&1 | head -14 | sed 's/^/  /' || echo "  (不是 git 树或读不到)"
echo "VERDICT=diag_done"
