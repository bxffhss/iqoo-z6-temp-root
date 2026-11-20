#!/system/bin/sh
# w1098_pstore_leg.sh —— 窗口里的**第一条 root 腿**：只抄 pstore，别的什么都不干(md §6.512／任务 #225)。
#
# ★为什么要它：第 84/85 两发把"整机在 init 写下 stage=1 后 ≈0.1 秒冻结"钉死了，但"死在哪一段"仍判不了——
#   因为冻结之后**所有**用户态观察方同时停(我的轮询器、窗口的 dmesg 跟随器都是用户态)。
#   剩下的唯一可能带内事后信道＝pstore：设备自己的 `/proc/config.gz`(世界可读)现读
#   `CONFIG_PSTORE=y / PSTORE_CONSOLE=y / PSTORE_PMSG=y / CONFIG_PSTORE_RAM=y`，
#   `/proc/device-tree/reserved-memory/ramoops` 节点在，`/proc/mounts` 里 `/sys/fs/pstore` **已挂** ⇒
#   10-02 那句"这台机没有 pstore 后端"是我把一次观察写成普遍结论(那次 root 读到 `total 0`)。
#
# ★两种结果都算数，但**读法不同**，所以腿里必须把"分辨得开"的形状一起落盘：
#   ①有 `dmesg-ramoops-0`/`console-ramoops-0` ⇒ 直接拿 fault 的 PC/回溯，"为什么崩"当场结案；
#   ②`PS_FILES=0` ⇒ 只能说"这次开机时没有可读记录"，**不能**单独否证 panic 路径——
#     要么(a)我们那类死没走 `panic()`(hard hang/watchdog→PMIC ⇒ 没人往 pstore 写)，
#     要么(b)后端写了、但被中间那次 warm reboot 的 console 注册 zap 掉了(ramoops 的 live buffer 在新 kernel
#     注册 console 时会清零)。⇒ 要把 (a)/(b) 分开，得在**死后的第一个 boot**里读(那要再开一枪)，腿里不做这个结论。
#   所以腿额外印三行用来分这两支：`MOUNT_LINE`(挂没挂)、`NEG_CTRL`(那条"glob 没命中就跳过"的分支有没有牙)、
#   `BOOT_HIST`(这一轮前面那次重启被框架记成什么)＋`CFG_PSTORE`(设备自己的编译期答案)。
#
# ★安全闸(写死)：**只读**。绝不对 `/sys/fs/pstore/*` 写一行(那会 erase 掉记录)、不 rm、不 insmod、
#   不碰 `/sys/fs/selinux/{load,enforce}`、不改任何标签；判据只有"抄到了什么"，不产生新行为。
# ★一个文件只许一个写者(§6.461)：主件只有本腿写；抄下来的记录另存目录，一文件一份。
L=/data/local/tmp/w1098_pstore.out
D=/data/local/tmp/w1098_pstore
: > $L
mkdir -p $D 2>/dev/null
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=只抄 pstore(不 insmod／不写 /sys/fs/selinux/*／不改标签)" >> $L
echo "BOOTREASON=$(getprop ro.boot.bootreason 2>&1)" >> $L
echo "BOOT_HIST=$(getprop persist.sys.boot.reason.history 2>&1)" >> $L
sync

# --- 1) 挂载面：把"挂了但是空目录"与"根本没挂"分开(这两种形状的结论完全不同) ---
grep -a ' pstore ' /proc/mounts > $D/mounts.txt 2>&1
echo "MOUNT_rc=$? MOUNT_LINE=$(head -1 $D/mounts.txt 2>&1)" >> $L

# --- 2) 设备自己的编译期答案(世界可读的 /proc/config.gz；zcat 不认就退 gzip -dc) ---
zcat /proc/config.gz > $D/config.txt 2>/dev/null || gzip -dc /proc/config.gz > $D/config.txt 2>/dev/null
echo "CFG_rc=$? CFG_PSTORE=$(grep -a '^CONFIG_PSTORE' $D/config.txt 2>&1 | tr '\n' ' ')" >> $L
sync

# --- 3) 内核自己怎么说 ramoops(★这条只能当辅助：dmesg 通道有间歇的洞，0 命中不是否据) ---
dmesg > $D/dmesg.txt 2>&1
echo "DMESG_rc=$? DMESG_lines=$(wc -l < $D/dmesg.txt 2>&1) DMESG_hits=$(grep -aicE 'ramoops|pstore|persistent_ram' $D/dmesg.txt 2>&1)" >> $L
# ★例 217(第 86 发抓的)：那次 `DMESG_hits=28` 全是 `KSUBEAT` 审计行里印着**本腿自己的 comm**
#   (`w1098_pstore_le` 这个名字本身就含 "pstore")⇒ **我的搜索面记录了我自己的搜索**。
#   规矩：凡"命中 N 条"旁边必须并排印"剔掉我自己之后还剩几条"，两个数都进证件；只有后者>0 才许往下归因。
echo "DMESG_hits_noself=$(grep -aiE 'ramoops|pstore|persistent_ram' $D/dmesg.txt 2>&1 | grep -avE 'KernelSU:|w1098_pstore_le|w1099_shot86|w1101_shot88' | wc -l) (真命中：上面那个数剔掉我自己之后)" >> $L
grep -aiE 'ramoops|pstore|persistent_ram' $D/dmesg.txt 2>&1 | head -8 | cut -c1-160 | sed 's/^/  DM | /' >> $L

# --- 4) ★负对照(例 194)：先证"目录里没有文件"这条分支真的会被跳过，否则下面的计数是空判据 ---
GONE=0
for f in /sys/fs/pstore/__no_such_record__; do
    [ -e "$f" ] || GONE=$((GONE + 1))
done
echo "NEG_CTRL=$GONE (必须=1：这条分支没牙 ⇒ 下面 PS_FILES=0 不算结论)" >> $L
[ "$GONE" = 1 ] || echo "[x] 负对照没成立 ⇒ PS_FILES 那个计数没有判别力" >> $L

# --- 5) 正文：把每条记录**整份**抄进 $D，并当场数条数＋大小＋md5＋头几行 ---
N=0
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    N=$((N + 1))
    B=$(basename "$f")
    cat "$f" > $D/$B.txt 2>&1
    echo "FILE rc=$? name=$B bytes_src=$(wc -c < $f 2>&1) bytes_got=$(wc -c < $D/$B.txt 2>&1) md5=$(md5sum $D/$B.txt 2>&1 | cut -d' ' -f1)" >> $L
    head -20 $D/$B.txt 2>&1 | cut -c1-170 | sed 's/^/  | /' >> $L
done
echo "PS_FILES=$N" >> $L
sync

# --- 6) 顺带(不多花派单)：交付形状有没有留脏东西——只读，不改 ---
echo "ENFORCE_NOW=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
echo "MODULES_ksu=$(grep -c '^kernelsu ' /proc/modules 2>&1) MODULES_probe=$(grep -c 'w985_probe' /proc/modules 2>&1) MODULES_total=$(wc -l < /proc/modules 2>&1)" >> $L
echo "RESIDUE_data_adb=$(ls /data/adb 2>&1 | head -6 | tr '\n' '|')" >> $L
echo "RESIDUE_tmp=$(ls /data/local/tmp 2>&1 | grep -aE 'pbin|kd$|sustatic|ksu_' | head -8 | tr '\n' '|')" >> $L

# --- 7) 收尾：清掉本腿写进设备的临时件？**不删 $D**(那是证人身)，只 chmod 让 PC 侧能 pull ---
chmod -R a+r $D 2>/dev/null
chmod 666 $L 2>/dev/null
sync
echo "END up=$(cat /proc/uptime) files=$N" >> $L
sync
