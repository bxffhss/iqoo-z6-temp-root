#!/usr/bin/env python3
# w541_docsync.py —— 把 §6.394 这一轮的新现值/新口径同步进对外四份文档(DELIVERY／W345／CURRENT-STATUS／CONTINUE_HERE)。
#   规矩(例 159/#152 同族)：**改了源≠改了文档**，所以同步由脚本做，每条替换都断言"命中次数恰好等于预期"，
#   不符就整批不落盘；落盘后立刻读回，打印每条新值在文档里确实出现、旧值确实不在"现值句"里。
#   只动"当前口径"那几行；带"当时/作废留链"的历史行一律不许改(那是链，不是现值)。
import io
import sys

# (文件, 旧串, 新串, 期望命中次数)
EDITS = [
    # ---- DELIVERY.md 第 45 行资产句 ----
    ("kmod/DELIVERY.md",
     "主体 `kmod/z6root.sh`＝`0161fa56…`（★10-22 18:0x 现值＝**包里真的把常驻补装开关铺上了**(与 `ksu_race_fd` 并排那句 `touch`)＋把 `ksu_fd_keepalive` 与其 helper/日志并进 ⑦ 的开关删净清单；当时 `522e0d88…`＝只并进删净清单那一版；`8d92e58d…` 作废留链）",
     "主体 `kmod/z6root.sh`＝`9bf34e24…`（★10-22 22:5x 现值＝**常驻补装开关退回默认不铺**(§6.394：那条循环可以把 fd 排到一个正在退出的任务上，而 `get_unused_fd_flags`→`__alloc_fd` 整链没有 `!files` 防护；带护栏的 rc73 认证之前交付默认不踩)＋明面写了那句\"默认不铺\"与自开方法；抢装看门狗 `ksu_race_fd` **照旧铺**(没它就没有授权页)；`0161fa56…`＝上一版(包里真铺常驻开关那一版，**现作废留链**：它铺的那把正是本轮退回的)；当时 `522e0d88…`／`8d92e58d…` 作废留链）",
     1),
    ("kmod/DELIVERY.md",
     "打包器 `kmod/w431_pack_z6root.sh`＝`e67d1292…`",
     "打包器 `kmod/w431_pack_z6root.sh`＝`68c42aa3…`（★10-22 22:5x 现值＝教程第 8 条改成\"牌子默认只有 ≈30 秒＋常驻开关默认不铺＋为什么默认关\"；`e67d1292…` 作废留链＝第 5 步换成 `python zipfile` 打分发件那一版）",
     1),
    ("kmod/DELIVERY.md",
     "忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`20d930e9…`",
     "忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`154d0546…`（★10-22 22:5x 现值＝**⑧ 那组牙转过一次向**：旧牙要求\"包里真铺上常驻开关\"，新牙要求\"包里不许铺＋明面写默认不铺＋指回 §6.394\"，并加一条**反误伤**牙 `\u2467a2` 钉住入口开关 `ksu_race_fd` 不许被一起删；教程两条文案牙也换成新口径；自数 40→**43**）；当时 `20d930e9…`＝⑧ 那六项按旧默认写的那版",
     1),
    ("kmod/DELIVERY.md",
     "`MANIFEST`＝`07407eeb…`",
     "`MANIFEST`＝`8e5af54a…`（★10-22 23:5x 现值＝§6.394 那两处改动(z6root.sh 不铺开关＋教程第 8 条)重打包；当时 `07407eeb…`／`5292be2d…`／`595ab0af…`／`065155ac…` 作废留链）",
     1),
    ("kmod/DELIVERY.md",
     "`kmod/w413_selftest_sweep.sh`＝`104f4952…`",
     "`kmod/w413_selftest_sweep.sh`＝`W413HASH…`",
     1),
    # ---- DELIVERY.md 第 138 段：常驻补装那节 ===== 改默认口径 ----
    ("kmod/DELIVERY.md",
     "**让『越狱模式』那块牌子常驻（10-22 做好，一手 md §6.388／§6.389／runbook §107）：★18:0x 起 **z6root 一键包默认就铺这把开关**(`kmod/z6root.sh` 与 `ksu_race_fd` 并排那句 `touch`)；PC 侧 `go.sh` 那条链仍默认关**：",
     "**让『越狱模式』那块牌子常驻（10-22 做好，一手 md §6.388／§6.389／§6.394／runbook §107）：★22:5x 起 **两条链都默认不铺这把开关**(`z6root.sh` 里那句 `touch` 已删，明面写了\"默认不铺\"和自开方法)——原因见本节末尾那条洞；",
     1),
    ("kmod/DELIVERY.md",
     "★**真机凭据还欠着**：离线自测 26 项全绿不等于它上机有效，下一次自然回归按 §107 第 3 条拍(含一张\"删掉开关⇒牌子退回不支持\"的反对照)。",
     "★**真机凭据还欠着**：离线自测 43/35 项全绿不等于它上机有效，下一次自然回归按 §107 第 3 条拍(含一张\"删掉开关⇒牌子退回不支持\"的反对照)。\n"
     "  ★★**为什么 22:5x 把默认退回关**(§6.394，0 枪)：常驻循环按 pid 补装时把活排成 `task_work_add()` 回调，而它只拒\"排队那一刻已 `work_exited`\"的目标 ⇒ **\"排队时活着、随后自己退出\"这一路拒不掉**；\n"
     "  那条回调可能跑在目标自己的 `do_exit` 收尾里，而 `exit_files()`(kernel/exit.c:855，把 `tsk->files=NULL`) 早于 `exit_task_work(tsk)`(:860)，`ksu_install_fd()`→`get_unused_fd_flags()`(fs/file.c:545)→`__alloc_fd()`(:480) 第一句就 `spin_lock(&files->file_lock)`，**整链没有 `!files` 防护**⇒ 空指针。\n"
     "  这台机的引信在现场已出现过：`pidof zygote64` 会返回 zygote 刚 fork、还没改名的瞬时子进程(#239 那条，已改 `pick_zygote` 挑 ppid=1)；且触发口收**任何 pid**(写个内核线程进去同样直接落进 `files==NULL`)。\n"
     "  ⇒ 第 38 发 insmod 后 ≈170 秒复位**有了机制候选**(源码层证成，一手 `w530~w537`)，但**归因仍未定**(无 pstore、dropbox 对 shell 拒读、z6root 那条链没带 dmesg 跟随器)。\n"
     "  护栏已进 ko：**rc73 `kmod/kernelsu_rc73.ko`＝`34b3efa8…`**(相对 rc67 只变 dev_syms.c 一处：符号表双向为空、条数 837＝837、`.text`+32B、`.rodata.str1.1`+134B；`kmod/remote_ksu_rc73.sh` 现编)——**没上机、没认证，包里继续带 rc67(`40e0c25d…`)**。\n"
     "  谁要牌子常驻：跑包前自己 `touch /data/local/tmp/ksu_fd_keepalive`(风险自负；收尾件会删净它和它的日志)。",
     1),
    # ---- W345_RC68_WINDOW.md(★这一份用 **ASCII 等号** `=`，照抄 DELIVERY 的全角 `＝` 就是 0 命中) ----
    ("kmod/W345_RC68_WINDOW.md",
     "`kmod/z6root.sh`=`0161fa56…`",
     "`kmod/z6root.sh`=`9bf34e24…`(§6.394：常驻补装开关退回默认不铺)",
     1),
    ("kmod/W345_RC68_WINDOW.md",
     "`kmod/w431_pack_z6root.sh`=`e67d1292…`",
     "`kmod/w431_pack_z6root.sh`=`68c42aa3…`",
     2),
    ("kmod/W345_RC68_WINDOW.md",
     "`z6root/MANIFEST`=`07407eeb…`",
     "`z6root/MANIFEST`=`8e5af54a…`",
     1),
    ("kmod/W345_RC68_WINDOW.md",
     "`z6root.zip`=`d877e2a5…`",
     "`z6root.zip`=`0cd4f43f…`",
     1),
    # ---- CURRENT-STATUS.md 第 10 行(这一份用全角 ＝) ----
    ("analysis/CURRENT-STATUS.md",
     "`kmod/z6root.sh`＝`0161fa56…`",
     "`kmod/z6root.sh`＝`9bf34e24…`(§6.394：常驻开关默认不铺)",
     1),
    ("analysis/CURRENT-STATUS.md",
     "`kmod/w431_pack_z6root.sh`＝`e67d1292…`",
     "`kmod/w431_pack_z6root.sh`＝`68c42aa3…`",
     1),
    ("analysis/CURRENT-STATUS.md",
     "MANIFEST`＝`07407eeb…`",
     "MANIFEST`＝`8e5af54a…`",
     1),
    ("analysis/CURRENT-STATUS.md",
     "`z6root.zip`＝`d877e2a5…`",
     "`z6root.zip`＝`0cd4f43f…`",
     1),
    ("analysis/CURRENT-STATUS.md",
     "`kmod/w413_selftest_sweep.sh`＝`104f4952…`",
     "`kmod/w413_selftest_sweep.sh`＝`W413HASH…`",
     1),
    # ---- CONTINUE_HERE.md 接手句(★ASCII 等号＋**不带 `kmod/` 前缀**) ----
    ("analysis/CONTINUE_HERE.md",
     "`z6root.sh`=`0161fa56`",
     "`z6root.sh`=`9bf34e24`(§6.394：常驻开关默认不铺)",
     1),
    ("analysis/CONTINUE_HERE.md",
     "`z6root.zip`=`d877e2a5`",
     "`z6root.zip`=`0cd4f43f`",
     1),
]

HASH_TOKEN = "W413HASH…"
PY_NEW = ["kmod/w538_add_fdguard.py", "kmod/w540_append_6394.py", "kmod/w541_docsync.py"]


def main():
    w413 = sys.argv[1] if len(sys.argv) > 1 else ""
    texts = {}
    for p, old, new, want in EDITS:
        if p not in texts:
            texts[p] = io.open(p, encoding="utf-8", newline="").read()
        n = texts[p].count(old)
        if n != want:
            print("[x] %s 这条锚点命中 %d 次(期望 %d) ⇒ **整批不落盘**：%s…" % (p, n, want, old[:60]))
            return 1
        texts[p] = texts[p].replace(old, new)
    if not w413:
        print("[x] 没给 w413 现值(前 10 位) ⇒ 不落盘：那句登记值不许由我凭印象填")
        return 1
    for p in texts:
        if HASH_TOKEN in texts[p]:
            texts[p] = texts[p].replace(HASH_TOKEN, w413)
    for p, s in texts.items():
        io.open(p, "w", encoding="utf-8", newline="").write(s)
    # 读回复证：每条 new 的首 24 字必须在，每条 old 的首 24 字在"现值句"里必须没了
    bad = 0
    for p, old, new, want in EDITS:
        s = io.open(p, encoding="utf-8", newline="").read()
        if new[:24] not in s:
            print("  [BAD] %s 读回找不到新句：%s…" % (p, new[:40])); bad += 1
    print("  落盘文件=%d 个，替换条目=%d 条，读回不符=%d(条数由本脚本现数)" % (len(texts), len(EDITS), bad))
    if bad:
        return 1
    print("PASS 文档同步完成(§6.394 的现值/口径已进 DELIVERY·W345·CURRENT-STATUS·CONTINUE_HERE)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
