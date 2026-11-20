#!/usr/bin/env python3
# w558_mk_rm3.py —— 从收尾件 w161_teardown.sh 里把 T3_RM 名单**原样读出来**(删与复证同源，#139 那条规矩)，
#   加上这一窗我自己拍的腿件(w5xx_*/a_*.bin/kernelsu.ko)，生成一份**设备侧 mksh** 的清理脚本。
#   为什么要生成而不是手敲：手敲的名单和收尾件的名单会漂，漂了就等于"这格删了什么"没人能说清。
import io
import re
import sys

SRC = "kmod/w161_teardown.sh"
OUT = "kmod/w558_rm3.sh"
EXTRA = ["w543_kt.sh", "w543_kt.keep", "w543_kt.keep2", "w543_kt.out", "w543_z6.out",
         "w549_kt2.sh", "w549_kt2.keep", "w553_home_race.png", "w553_home_race.xml",
         "w552_root_bundle.sh", "w552_root.out", "w552_cue1", "w552_cue2",
         "w556_zgwatch.sh", "w556_zg.out", "a_10342.bin", "kernelsu.ko",
         "w567_root_proof.sh", "w567_probe", "w567_root.out",   # ★w426_enforce.sh 已从名单里**拿出来**(§6.406)：清理名单会吃掉下一发要用的执法腿
         "w161_g2.out", "w161_u1.uid", "w161_u2.uid", "w161_fdwatch.sh", "w161_fdlaunch.sh",
         "w161_fdlaunch.out", "w205_list.sh", "ksu_ring_end.txt", "sushd_last.out",
         # 第 48 发(§6.405)的常驻看门狗一套：开关文件是它的 kill switch，也是它的脚印
         "w600_mgrwatch.sh", "w600_mgrwatch.log", "w600_mgrwatch.pid", "ksu_mgr_watch",
         "w601_mgrlaunch.sh", "w601_mgrlaunch.out", "w602_sc.sh", "w604_giveup.sh",
         # 第 49 发(§6.407)：#176 的恢复腿只留产物，腿本体是工具件、不进名单(同 §6.406 那条规矩)。
         # ★10-24 #180：那条腿的**闸凭据**(冷却/次数锁)与测量腿的夹具标记都是脚印，进名单；
         #   w625_nogate 只有我的测量件会铺(包里没有任何生产者)，列进来是防"我哪天忘了删 ⇒ 下一窗静默松闸"。
         "w625_seedrestart.out", "w625_lock", "w625_nogate"]
# ★工具件名单(不许出现在删除集合里；由 w597 的牙逐条把守)：清理名单吃掉下一发要用的腿＝静默换实验形状。
KEEP = ["w426_enforce.sh", "w165b_adb_clean.sh", "w558_rm3.sh", "w589_watch_arm.sh", "w625_seedrestart.sh"]
# ★第 44 发(10-23 14:0x)加的这批：w567＝执法态 su 取证腿的载荷与靶子，w426＝恢复执法那条腿，
#   w161_*＝go.sh 与 ui_grant 现铺现用的触发件，sushd_last.out＝派单落点。都归 T3 同一条"删与复证同源"的循环管。
SDDIR = "/sdcard"
SDEXTRA = ["w567_a.xml", "w567_b.xml", "w567_c.xml", "w567_su_abs.png", "w567_chmod.png",
           "w567_rootproof.png", "w429.xml", "w429_termux.png", "w603_C1.xml", "w603_T1.xml", "w603_T2.xml", "w603_T3.xml", "w603_C2.xml",
           "w591_A.png", "w591_A.xml", "w591_B.png", "w591_B.xml",
           # 第 49 发(w603 每枚都往 /sdcard 落 xml＋png)
           "w603_C1.png", "w603_C0.xml", "w603_C0.png", "w603_D1.xml", "w603_D1.png",
           "w603_B1.xml", "w603_B1.png", "w603_B2.xml", "w603_B2.png",
           "w603_B3.xml", "w603_B3.png", "w603_B4.xml", "w603_B4.png", "w603_B5.xml", "w603_B5.png"]


def main():
    s = io.open(SRC, encoding="utf-8").read()
    m = re.search(r"^T3_RM='([^']*)'", s, re.M)
    if not m:
        print("[x] 在 %s 里没读到 T3_RM='...' 这一行 ⇒ 不生成(别拿记忆的名单去删)" % SRC)
        return 1
    names = [n for n in m.group(1).split() if n.startswith("/data/local/tmp/")]
    if len(names) < 30:
        print("[x] T3_RM 只解出 %d 条，太少 ⇒ 停" % len(names))
        return 1
    allf = [n for n in dict.fromkeys(names)] + ["/data/local/tmp/" + e for e in EXTRA] + [SDDIR + "/" + e for e in SDEXTRA]
    # ★硬闸(§6.406/#176)：工具件不许进删除集合——清理名单吃掉下一发要用的腿＝静默换实验形状且不报错
    #   (第 49 发一手：w161_fdlaunch/fdwatch 被上一发的名单删掉，那一窗的"抢装看门狗"就这么静默没了)。
    bad = [k for k in KEEP if any(n.endswith("/" + k) for n in allf)]
    if bad:
        print("[x] 工具件出现在删除名单里 ⇒ 不生成：%s" % " ".join(bad))
        return 1
    body = ["#!/system/bin/sh",
            "# w558_rm3.sh —— 由 kmod/w558_mk_rm3.py 从 w161_teardown.sh 的 T3_RM 生成(条目 %d)。" % len(allf),
            "#   ★本件由 @sushd: 以 root 派发(所以 apk_data_file 那些标签挡着的也删得动，#167/§6.407)；",
            "#   先列→再删→再复证；只动名单里的绝对路径，不碰 /data/adb(那归 w165b_adb_clean.sh)，工具件不在名单内(KEEP 硬闸)。",
            "L=/data/local/tmp/w558_list.txt",
            ": > \"$L\"",
            "for F in \\" + " \\\n    ".join(allf) + "; do",
            "    echo \"$F\" >> \"$L\"",
            "done",
            "echo \"名单条数=$(wc -l < $L)\" >> \"$L\"",
            "echo \"=== 删之前存在的那些 ===\"",
            "while read -r P; do [ -e \"$P\" ] && ls -l \"$P\"; done < \"$L\" 2>/dev/null",
            "for P in $(grep -a '^/' \"$L\"); do rm -f \"$P\" 2>/dev/null; done",
            "echo \"=== 复证(还在的列出来，空=全删净) ===\"",
            "LEFT=0",
            "while read -r P; do if [ -e \"$P\" ]; then echo \"  还在: $P\"; LEFT=$((LEFT + 1)); fi; done < \"$L\"",
            "echo \"剩余=$LEFT\"",
            "rm -f \"$L\"",
            "echo \"enforce=$(cat /sys/fs/selinux/enforce) mod=$(grep -ac kernelsu /proc/modules) up=$(cut -d. -f1 /proc/uptime)\"",
            ""]
    io.open(OUT, "w", newline="\n", encoding="utf-8").write("\n".join(body))
    print("生成 %s：条目=%d(其中收尾件原名单 %d＋本发腿件 %d)" % (OUT, len(allf), len(names), len(EXTRA)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
