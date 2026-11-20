#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""重写 v29 里"外部证据(第三个来源)"那一块：
   上一版我把 root 侧读的是 APP_COPY(握手版报告的副本，里面永远没有"子进程 pid=")⇒ 这一格永远"跳过"。
   现在：等实时报告出现"子进程 pid="，按那个 pid 读 /proc(第三个来源)，并把子进程留在
   f2fs 上的两份产物(suw_child.log / suw_cmd.out)cat 出来 —— exec 那一格的真实答案在这里。
"""
import io
import sys

P = "kmod/ksu_one_stage.sh"
L = io.open(P, encoding="utf-8", errors="replace").read().split("\n")


def line_with(sub, start=0):
    for k in range(start, len(L)):
        if sub in L[k]:
            return k
    return -1


i = line_with("外部证据(第三个来源)")
j = line_with("外部证据收尾", i)
if i is None or i < 0 or j < 0:
    print("!! 找不到块边界")
    sys.exit(1)

TAB = chr(9)
new = [
    '    log "===== 外部证据(第三个来源)：等 armed 版报告，按它印的子进程 pid 读 /proc ====="',
    '    # ★v29 修正：以前读的是 APP_COPY(握手版副本，里面永远没有"子进程 pid=")⇒ 这一格永远跳过',
    '    w=0',
    '    while [ $w -lt 30 ]; do',
    '        grep -q ' + chr(39) + '子进程 pid=' + chr(39) + ' "$APP_REPORT" 2>/dev/null && break',
    '        w=$((w + 1)); sleep 3',
    '    done',
    '    log "  等 armed 版报告用了 $((w * 3))s (报告 $(wc -c < "$APP_REPORT" 2>/dev/null) 字节)"',
    '    KIDP=$(grep -oE ' + chr(39) + '子进程 pid=[0-9]+' + chr(39) + ' "$APP_REPORT" 2>/dev/null | head -1 | cut -d= -f2)',
    '    if [ -n "$KIDP" ]; then',
    '        log "  子进程 pid=$KIDP 的 Uid 行 = [$(grep -m1 ' + chr(39) + '^Uid:' + chr(39) + ' /proc/$KIDP/status 2>&1 | tr ' + chr(39) + TAB + chr(39) + ' ' + chr(39) + ')]"',
    '        log "  CapEff = [$(grep -m1 ' + chr(39) + '^CapEff:' + chr(39) + ' /proc/$KIDP/status 2>&1 | tr -d ' + chr(39) + TAB + chr(39) + ')]  comm=[$(cat /proc/$KIDP/comm 2>&1)]"',
    '        log "  State  = [$(grep -m1 ' + chr(39) + '^State:' + chr(39) + ' /proc/$KIDP/status 2>&1)]"',
    '        log "  ★读不到(No such file)=子进程已退出；一直在且 State=D ⇒ 就是 §6.63 那个 FUSE 堵死"',
    '    else',
    '        log "  报告里没有『子进程 pid=』⇒ 这一格跳过(armed 触发没到位?)"',
    '    fi',
    '    # ★子进程留在**普通文件系统**(f2fs，不是 FUSE)上的两份东西：自己的日志 + exec 的输出',
    '    log "----- 子进程产物：模块能不能用 root 跑命令就看 suw_cmd.out 这一格 -----",',
    '    for f in /data/local/tmp/suw_child.log /data/local/tmp/suw_cmd.out; do',
    '        if [ -f "$f" ]; then',
    '            chmod 666 "$f" 2>/dev/null',
    '            log "  $f:"',
    '            sed ' + chr(39) + 's/^/      /' + chr(39) + ' "$f"',
    '        else',
    '            log "  $f 不存在 ⇒ 子进程没走到那一步"',
    '        fi',
    '    done',
    '    if grep -q ' + chr(39) + 'uid=0(root)' + chr(39) + ' /data/local/tmp/suw_cmd.out 2>/dev/null; then',
    '        log "  ★★★ app 生的 root 子进程成功 exec 并以 uid 0 运行 ⇒ 模块的 su 原语成立"',
    '    else',
    '        log "  suw_cmd.out 里没有 uid=0(root) ⇒ 这一格没成立，看 suw_child.log 里的 exec 失败行"',
    '    fi',
    '',
]
new[18] = new[18].rstrip(',')   # 上面那行末尾手滑多了个逗号，这里去掉
L[i:j] = new
io.open(P, "w", encoding="utf-8", newline="\n").write("\n".join(L))
print("块已重写: 原 %d..%d 行 -> %d 行" % (i, j, len(new)))
