#!/bin/bash
# w103_su.sh —— 标准 `su`(sucompat)这条战线：**一发只动一个变量**的阶梯驱动器。md §6.95/§6.103
# 用法：ATT=1 bash kmod/w103_su.sh        (会 reboot → 等开机 → push → punch → 触发 → 收证)
#   ATT=1  钩子开(bit1=execve) + 两笔危险动作**都关**(no_escape=1 no_cred_override=1)
#          触发器 = `ksuctl su 10319 id`(fork→setuid 到名单内 uid→execve /system/bin/su)
#          ⇒ 判据：机器活着 + SD*/SU0/SU1/SU1a/SU1b/SU1c/SU1d/SU2/SU3/SU4 全印
#             + w103_run.out 里有 ksud shim 的输出(uid 还是 10319)
#             ⇒ 证明"改道 + 嵌套 execveat"本身是好的，死的是 escape/改 cred 那半段
#   ATT=2  只把 `ksu_no_cred_override=0` 打开(即 filp_open 前后 override_creds(ksu_cred))
#   ATT=3  再打开 `ksu_no_escape=0` ⇒ 完整 sucompat，判据 = child.log 出现 uid=0(root)
#   ATT=4  在 ATT=1 的基础上再关 sulog 采集(ksu_no_sulog=1) ⇒ 若 ATT=1 死在 SU1b/SU1c 之间就用它二分
# ★每一发都会先把 `grep SU1|SU[0-4]` 的内核脚印抄进 kmod/w103_evidence/，掉线之前抄到的最后一条就是死点
#   (本机 console=null + pstore 空 ⇒ 唯一能跨重启活着的现场是 /data/local/tmp/dmesg.live)。
set -u
cd "$(dirname "$0")/.." || exit 1
ATT=${ATT:-}
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
EV=kmod/w103_evidence
mkdir -p "$EV"
[ -n "$ATT" ] || { echo "[x] 要 ATT=1..4"; exit 2; }
BASE="ksu_mass_mark=0"
case "$ATT" in
  1) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1";;
  2) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=0";;
  3) ARGS="$BASE ksu_hook_mask=0x2";;
  4) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_no_sulog=1";;
  # ---- rc54 起的二分：escape 之后那两笔各关一笔(ATT=3 的脚印停在 X7 之后，但洪印会挤掉回执) ----
  5) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_disable_seccomp=1";;
  6) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_mark_threads=1";;
  7) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_disable_seccomp=1 ksu_no_mark_threads=1";;
  # ---- ATT=8 = 设计转折(md §6.105)：内核**只改道**，提权交给 exec 之后的 shim 自己发 ioctl ----
  #   args 与 ATT=1 完全一样(那一档已证"改道半段"安全)，区别只在 /data/adb/ksud 换成了
  #   会自提权的 shim(cm57/ksud_shim.c 里 escalate())。判据 = w103_run.out 里出现
  #   `SHIM-ESC ... uid后=0` 且 `id` 输出是 uid=0(root)。
  8) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1";;
  # ---- ATT=9 = 与 8 同一套 args，但**在 stage 收尾之前**连着测两个 uid ----
  #   (上一发把 su 复跑放在 up=1011，那时 stage 已经 `=== 结束 ===` 并 rm 掉 /data/adb/ksud ⇒ ENOENT，
  #    差点被我读成"钩子失效"。这一档把 10667(普通被授权 app) 与 10319(Manager) 都在早段打完。)
  9) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1";;
  # ---- ATT=10 = rc55 的那一格：ksud 放 tmpfs(/dev/ksud)，看 stage 收尾之后 su 还在不在 ----
  10) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=11 = §6.110：**真·第三方 app 敲 su**(子进程带着 app 的 seccomp 与 untrusted_app 域) ----
  11) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=12 = §6.112③/#43：**同一 boot 里先给 Manager 自己写 profile(域=u:r:shell:s0) 再敲 su**，
  #   判据 = 内核脚印 `X2 profile: … domain=` 到底印哪个域。
  #   (ATT=11 已证：不 setprof 时 X2 读到的是 default 的 `u:r:ksu:s0`(本机策略解不开 ⇒ 保持原域)。
  #    若 setprof 之后 X2 仍是 `u:r:ksu:s0` ⇒ escape 对 Manager uid 根本不查我们写的 profile；
  #    若 X2 变成 `u:r:shell:s0` 而孩子仍是 untrusted_app ⇒ 是"解不开/切不动"，不是"没读到"。)
  12) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=13 = §6.116：**开可见性位**(bit3 newfstatat + bit4 faccessat) ⇒ Termux/Shizuku 那种
  #   "先 access()/stat() 探测再执行"的形状才走得到改道。判据=@suprobe: 里
  #   `access(/system/bin/su,X_OK)=0` + `stat` 的 size=/dev/ksud 的大小 + `execvp("su")` 的孩子出 uid=0，
  #   且负对照 `/system/xbin/su` 仍失败。ko 要 **rc56**(探测伪装与改道目标同源)。
  13) ARGS="$BASE ksu_hook_mask=0x1a ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=14 = §6.117：**不开**可见性位(13 已判死)，改用 magic mount 让 `/system/bin/su` 真的存在
  #   (tmpfs + 符号链接农场，`su -> /dev/ksud`) ⇒ app 的 access()/stat() 探测天然成功，
  #   execve 命中的还是已验证安全的"只改道"那半段。判据=@suprobe: 里 access=0、stat 指到 ksud、
  #   `execvp("su")`(走 PATH，与 Termux 同形)的孩子出 uid=0(root)。
  14) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=15 = §6.118：**一发只开一位**(bit1 execve + bit4 faccessat=0x12)，把死因夹出来。
  #   上游的 su 可见性就是靠这两个钩子(读 userspace/ksud/src/su.rs + hook/syscall_hook_manager.c 定的，
  #   不是我先前以为的 magic mount)，所以这条路必须修好而不是绕开。
  #   顺序：①先让 root 侧把 /proc/ksu_slots 整份抄出来(含 5 条 CFIFIX 的原话) ②再 @suprobe:(第一句就是 access)
  #   判据：活下来 + `access(...)=0` ⇒ 位 4 无罪，死点在 newfstatat；死 ⇒ 位 4 就是凶手，下一发只开位 3。
  15) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=16 = §6.118 的验收：与 15 **同一套位**(0x12)，但 ko=rc58(入口那三行回执按号收紧+限流)。
  #   判据：机器活着 + `@suprobe:` 印出 `access(/system/bin/su,X_OK)=0`(探测被伪装成功 ⇒ Termux 不再"没找到 su")
  #   + 负对照 `/system/xbin/su` 仍失败 + `execvp("su")` 的孩子出 uid=0(root)。
  #   还是死 ⇒ 拿 stage 这次导出的 /data/local/tmp/ksu_slots.dump.txt 看那两条桩到底改成什么样了。
  16) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=17 = §6.119③：**不再猜机制，装回执**。ko=rc59(FA0..FA5/FS0..FS5 分步回执 + ksu_stat_off 开关)。
  #   判据=死前 dmesg.live 里最后一条 `KSUBEAT FA*`：
  #     停在 FA0/FA1 ⇒ 抄路径那一步(用户态指针)；停在 FA5 ⇒ "从钩子里调 ksu_syscall_table[48]"本身致命；
  #     停在 FA3/FA4 ⇒ 换指针进原实现那一段；全没有 FA ⇒ 死在 handler 之外(钩子注册/入口)。
  17) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=18 = §6.120：**先把"眼睛"修好再打**。与 17 同一套 args，但触发前先让 root 守护起一个
  #   独立于 stage 的常驻 dumper(每 2 秒整份覆盖 /data/local/tmp/dmesg2.log + sync)。
  #   17 的教训：stage 收尾会 kill 掉它自己的 dumper ⇒ 日志停在 572.65，而 app 是 ~591 才打的
  #   ⇒ "死前没有任何 FA* 回执"当时被我读成"死在 handler 之前"，其实那只是眼睛先闭上了。
  18) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=19 = §6.121：**把眼睛搬进 stage**(v59 起 setsid 常驻 dmesg2.log)，第一枪直接 @suprobe:。
  #   18 的死结是我用 app 去起常驻 dumper ⇒ app 一死它就没起来(dmesg2.log 不存在)。
  #   判据：复位后 dmesg2.log 里**最后 20 行**(含 oops/panic 原文，如果有的话) + 有没有 FA0(uid=10319)。
  19) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=20 = §6.121：**验洪印是不是凶手，零重编**。与 19 同一套 args，只在 punch 之前放一个
  #   /data/local/tmp/ksu_quiet 标记 ⇒ stage(v60)就不再关 printk 限流 ⇒ `pr_*_ratelimited` 真的生效。
  #   活下来且 `access()=0` ⇒ 前面几发的死因=我们自己把限流关掉后 BN 行每秒上千的洪印；
  #   照旧死 ⇒ 洪印清白，回到"handler/重定向内部"这条线，用 FA2 那条夹(它现在是 0)。
  20) ARGS="$BASE ksu_hook_mask=0x12 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=21 = §6.123：**第三条路：静态 su 放进 app 自己的 PATH 目录**（钩子全关=已知安全配置）。
  #   链：su(静态) → abstract @suwshd → shd v4(放行条件=白名单 **或** 内核 UID_GRANTED_ROOT)
  #       → SCM_RIGHTS 交驱动 fd → ioctl(GRANT_ROOT) → 内核对该 uid 跑 escape → exec sh。
  #   判据(全在 w128_su.out 里)：① 以 Termux 的 uid 跑它 ⇒ `uid=0(root)`；② 撤名单后再跑 ⇒ 必须失败；
  #   ③ root shell 里 `grep -c ksu_driver /proc/self/fd` = 0(fd 不带进 shell)。
  21) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=22 = §6.124：**挂载路线**(抄酷安 Z5 分享包 scripts/z5_setup.txt 的配方)。
  #   21 那条只救"自己私有目录在 PATH 里"的 Termux；Shizuku 那类 PATH 全是只读系统目录的 app 救不到。
  #   这一发把静态 su 变成 **/system/bin/su 这个真文件**(先试 overlay 叠加，失败退回 cp -a 全量副本 + bind)，
  #   于是**所有** app 的 PATH 都能命中它 —— 全程不碰那个坏掉的 stat/faccessat 钩子(#47 被绕开，不是被修好)。
  #   授权仍然只在内核：su → @suwshd → shd v4 问内核 UID_GRANTED_ROOT → 转交驱动 fd → ioctl(GRANT_ROOT)。
  #   ★为什么这次不会再翻车(§6.116/§6.117 两次都是物理长按电源才救回来)：
  #     ① 用**全量副本**而不是符号链接农场 ⇒ /vendor/bin/* 那些指向 /system/bin 的链接仍然落在副本里；
  #     ② 副本里有 linker64 ⇒ /system/bin/sh 自己 exec 得动；
  #     ③ 脚本内 [4] 三条安全判据(sh 跑得动 / linker64 在 / 项数>=400)任何一条不过就**当场自动 umount 回退**。
  #   判据链：PRE_STATE=ABSENT(负对照地基) → MOUNT_KIND + SAINTY=OK → SU_PRESENT=YES
  #          → ksuctl su <Termux uid> "id" 出 uid=0(root) → app 域 @suprobe: 的 execvp("su") 成功
  #          → **撤名单后同一个探针必须被 agent 拒(ERR not-allowed，不是 ENOENT)** → root 侧 umount+删目录。
  #   args 与 21 逐字相同(已证安全的配置)，这一发不引入任何新的内核动作。
  22) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=23 = §6.124③：第 22 发的两处修正，一次做完。
  #   修正一(判据)：第 22 发用 `ksuctl su <uid>` 当"可见性"探针是**假阳性** —— 那个动词写死
  #     execve("/system/bin/su")，而 ko 的 execve 钩子在**路径解析之前**就改道 ⇒ 文件不存在照样出 root
  #     (回执里同时有 `ls: /system/bin/su: No such file` 和 `uid=0(root)`)。
  #     ⇒ 换成新动词 `ksuctl87 supath <uid> <PATH> su -c id`：fork→降 uid→execvp(按 PATH 找)，
  #       不碰 ioctl/驱动 fd/标位。PATH 里没有就是 errno=2，这才是"文件在不在"。
  #   修正二(落点)：第 22 发盖 /system/bin 之后**框架废了**(service list 只剩 0 个、am 报
  #     `Can't find service: activity`、u0_a 进程数 0 ⇒ 起不了新 app ⇒ 最关键的 app 域那一格反而测不了)。
  #     ⇒ 目标换成 **/product/bin**：它在 A11 base PATH 里排最前，只有 3~4 项，框架运行时不依赖它。
  #     并把"框架还活着"升级成**一等判据**([3] 格)，不过就自动 umount 回退。
  #   args 与 21/22 逐字相同 ⇒ 不引入任何新的内核动作。
  23) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=24 = §6.124⑤：**已经手工跑通的那条序列**固化成档(22/23 两处判据错误都修掉了)。
  #   落点 = /product/bin(第 23 发实测：盖住它框架完全没事 —— shell 域 327 服务 / 498 个第三方包 /
  #     `am start` 正常；而第 22 发盖 /system/bin 会把服务列表清空、起不了新 app)。
  #   探针 = `ksuctl87 supath <uid> /product/bin su -c /system/bin/id`：**PATH 只给挂载点一项**
  #     ⇒ 我们 ko 的 execve 钩子(匹配字符串 "/system/bin/su")插不进来 ⇒ 三态互斥：
  #       errno=2 文件不在 / uid=0(root) 在且内核放行 / not-allowed 在但内核不放行
  #     (载荷必须写绝对路径：PATH 只有一项时内层 `sh -c id` 找不到 id，会误报成"su 没起来")。
  #   收尾必须 root 侧先 umount 成功再删源目录(第 23 发就是 PC 侧 umount 吃了 EPERM 之后
  #     rm -rf 把还挂着的源删了，把 /product/bin 弄成指向已删目录)。
  24) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=25 = #53：**挂载路线不变，把 profile 的 selinux_domain 当旋钮**，A/B 量"su 之后落在哪个域、
  #   那个域能不能真干活"。动机：§6.107② 之后 suw JNI 把域**硬编码成 u:r:shell:s0**，而一手记录是
  #   "app 来源不 setprof 时域保持 u:r:untrusted_app"(§6.110) ⇒ "这个 root 在 enforcing 下能干什么"从没证过。
  #   新判据 = w147_dom.sh 里那组**域鉴别器**(init 的 /proc 条目 / 别的 app 的私有目录 / /dev/kmsg / pstore)，
  #   每项都要求 app 与 shell 域 rc!=0(EACCES)、kernel 域 rc=0；只看 uid=0 不算证到。
  #   ★uid 不硬编码：先在窗口里用 w148_uid.sh 从 packages.list(root-only) 现场反查再写回文件。
  #   ★两轮 setprof 打在**同一个 uid**上(改域不改人)，第二轮才换 kernel 域 ⇒ 若第二轮把机器打死，
  #     差异只可能来自"域"这一个变量。
  25) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=26 = #53 之后的**合并验收**：一枪跑完"挂载三态 + 域正负对照 + 收尾 root 侧回读残留"。
  #   args 与 24/25 完全一致(已知安全配置)；段名沿用 ATT=24、存证名沿用 w28_*，所以两个老闸门原样能判。
  26) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=27 = #56：**脚本型模块在窗口里激活**(模块自己 bind + 踢框架)；args 用与 24/25/26 同一套已知安全配置。
  #   ★教训：只在 if/elif 链里加分支是**不够**的 —— 这张 case 表不认的 ATT 会被 `*)` 挡掉(今天就是
  #   "语法过了但不可达")；反过来若表认了而 args 留空，模块会带着**默认参数**加载，那是另一类产品行为差异。
  27) ARGS="$BASE ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud";;
  # ---- ATT=16 = §6.118 的验收：与 15 同一套位(0x12)，但 ko=rc58(入口回执按号收紧+限流)。
  #   判据：机器活着 + @suprobe: 印出 `access(/system/bin/su,X_OK)=0`(=探测被伪装成功，Termux 那一步不再 ENOENT)
  #   + 负对照 /system/xbin/su 仍然失败 + execvp 的孩子出 uid=0(root)。死了 ⇒ 再按 ATT=15 的 slots 报告查桩。
  *) echo "[x] ATT 只认 1..27(11=真 app 敲 su，13=开可见性位，21=静态 su 进 app 私有目录，22=盖 /system/bin(判据已作废)，23=盖 /product/bin(判据两处错)，24=挂载路线三态判据·当前正解，25=24+profile 的域当旋钮·量 su 之后落在哪个 SELinux 域，26=**合并验收一枪**:挂载三态+域正负对照+收尾残留回读+授权链+挂载存活取样，27=**#56 模块激活**:脚本自己 bind + 踢框架(要点头))"; exit 2;;
esac
echo "=== ATT=$ATT  args=[$ARGS] ==="
printf '%s\n' "$ARGS" > kmod/ksu_args.txt
S "echo ready" >/dev/null   # 先探设备在不在(可能在重启)
for i in $(seq 1 40); do [ -n "$(A get-state 2>/dev/null | grep device)" ] && break; sleep 5; done
S 'getprop sys.boot_completed; cut -d" " -f1 /proc/loadavg' | tr '\n' ' '; echo
A reboot >/dev/null 2>&1      # ★每次都从干净 boot 开始：链一个 boot 只有一发
echo "  等重启回来…"
for i in $(seq 1 60); do sleep 5; [ -n "$(A get-state 2>/dev/null | grep device)" ] && break; done
for i in $(seq 1 60); do
  BC=$(S 'getprop sys.boot_completed' | tr -d '\r\n'); UP=$(S 'cut -d" " -f1 /proc/uptime' | awk -F. '{print $1}')
  L1=$(S 'cut -d" " -f1 /proc/loadavg' | tr -d '\r\n')
  # ★开机风暴里不能打：第 42 发就是 `up=261s load1=6.43` 就 punch，结果 stage 整 boot 没跑
  #   (1100 秒白等)。GhostLock 的命中与"负载已降"相关(见记忆 ghostlock-rtmutex-lpe)，
  #   所以这里**必须**等 load1<6 才放行；旧代码算了 OK 却没参与 break ⇒ 等于没闸。
  LOW=$(awk -v a="${L1:-99}" 'BEGIN{print (a+0<6)?1:0}')
  [ "$BC" = "1" ] && [ "${UP:-0}" -gt 260 ] && [ "$LOW" = 1 ] && { echo "  boot 就绪且已安静: up=${UP}s load1=$L1"; break; }
  [ $((i % 6)) = 0 ] && echo "    等负载降: bc=$BC up=${UP:-?} load1=$L1 (要 <6)"
  sleep 10
done
L1=$(S 'cut -d" " -f1 /proc/loadavg' | tr -d '\r\n')
LOW=$(awk -v a="${L1:-99}" 'BEGIN{print (a+0<6)?1:0}')
[ "$LOW" = 1 ] || { echo "[x] 等满 10 分钟 load1 还是 $L1 ⇒ 不 punch(开机风暴里打基本不中)，重启后重试"; exit 7; }
echo "=== 1) push ==="
bash kmod/push_ksu.sh 2>&1 | grep -E "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
if [ "$ATT" = 20 ]; then
    : > kmod/ksu_quiet.marker
    MSYS_NO_PATHCONV=1 adb push kmod/ksu_quiet.marker /data/local/tmp/ksu_quiet >/dev/null 2>&1
    echo "  已放 ksu_quiet 标记(stage v60 会因此**不关** printk 限流)"
fi
echo "=== 2) punch ==="
# ★★★踩过的坑(ATT=3 因此整发作废)：`pr` 的 post(=stage) 在 MAC 判据之后 **3~17 分钟**才跑，
#   而 /data/local/tmp/ksu_stage.log 是**上一发**留下的 ⇒ 我的"等判据④"循环立刻命中旧文件，
#   于是在**模块还没 insmod** 的时候就打了 su ⇒ 什么也没测到，还误判成"触发后 3~6 秒重启"。
#   ⇒ punch 之前必须先把这些跨重启残留的日志删掉：文件重新出现 = 本 boot 的 stage 真跑了。
S 'rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/sushd.log /data/local/tmp/dmesg.live /data/local/tmp/dmesg_full.txt /data/local/tmp/w103_run.out /data/local/tmp/w103_slots.txt /data/local/tmp/app_ksu.txt' >/dev/null
# ★这些 .early/.late 变体也是**跨 boot 残留**(§6.113③：check_su_app.sh 就是被 w103_run.out.early 里
#   旧 shim 的 `reboot(magic)` 痕迹骗过一次，差点判成"这一发又走了 reboot 口")。
S 'rm -f /data/local/tmp/w103_run.out.early /data/local/tmp/w103_run.out.late /data/local/tmp/w103_run67.out /data/local/tmp/w103_run67.out.early /data/local/tmp/w103_run67.out.late' >/dev/null
# ★§6.124：w131 那三份回执同样**跨 boot 残留**(/data 分区重启不丢) ⇒ 不删就会拿上一发的
#   "MOUNT_KIND=overlay SAINTY=OK" 骗过这一发的判据。
S 'rm -f /data/local/tmp/w131_mount.out /data/local/tmp/w131_probe.out /data/local/tmp/w131_umount.out /data/local/tmp/w131_asuid.txt /data/local/tmp/w131_tuid.txt' >/dev/null
S 'rm -f /data/local/tmp/w132_mount.out /data/local/tmp/w132_probe.out /data/local/tmp/w132_teardown.out /data/local/tmp/w132_inmount.txt' >/dev/null
S 'rm -f /data/local/tmp/w133_probe.out /data/local/tmp/w133_mount.out /data/local/tmp/w135_fix.out /data/local/tmp/w135_off.out' >/dev/null
# ★#53 的回执同样**跨 boot 留存**：w147_probe.out 里那句 `CTX = u:r:...` 要是拿上一发的读，
#   整格的结论就是假的 ⇒ punch 之前删干净，只看本 boot 重新出现的文件。
S 'rm -f /data/local/tmp/w147_probe.out /data/local/tmp/w147_dom.out /data/local/tmp/w148_uid.out /data/local/tmp/w132_tuid.txt' >/dev/null
# ★第 22 发还留了个**目录级**残留：/data/local/tmp/newbin 与 /data/local/tmp/subin 在 /data 上，
#   重启不丢。下一次开机时 /product/bin 或 /system/bin 是干净的，但这两个目录还在那 ⇒
#   判据必须只看本 boot 的回执，不看目录存不存在。这里顺手删掉，省得以后混淆。
S 'rm -rf /data/local/tmp/newbin /data/local/tmp/subin /data/local/tmp/pbin' >/dev/null
S 'rm -f /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt /sdcard/Android/data/com.suw.manager/files/sushd_out.txt /sdcard/Android/data/com.suw.manager/files/child.log' >/dev/null
echo "  残留日志已删(判据：ksu_stage.log 重新出现才算本 boot)"
I_KNOW=1 bash suw_apk/bootstrap.sh --punch 2>&1 | grep -aE "slide=|dispatched|pr=" | tail -3 | sed 's/^/  /'
echo "=== 3) 等 stage 跑到判据④(app 等待段)——post 可能在 MAC 判据之后 3~17 分钟才跑 ==="
for i in $(seq 1 220); do
  sleep 5
  N4=$(S 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
  if [ "${N4:-0}" != "0" ]; then
    S 'grep -aE "=== 起点|insmod rc|桩已写回|sysname 已写回" /data/local/tmp/ksu_stage.log | cut -c1-110 | tail -4' | sed 's/^/  /'
    break
  fi
  [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s (stage 日志还没出现)"
done
[ "${N4:-0}" = "0" ] && { echo "[x] 等满 18 分钟仍没有本 boot 的 stage 日志 ⇒ 这一发的链没落地，别触发"; exit 5; }
echo "=== 4) 触发：让**名单内的普通 uid** execve /system/bin/su（不走 escape）==="
# ★不能用 app 的 armed 支路：它先 ioctl(GRANT_ROOT) 变成 uid 0，而 sucompat 入口对 uid 0 是
#   `forbid_system_uid` ⇒ SD1 decline，永远测不到改道。所以走 ksuctl 的 `su <uid> <cmd>`：
#   fork ⇒ 子进程 setuid 到 10319 ⇒ execve("/system/bin/su",["su","-c","id"]) —— 就是真 su 的形状。
#   守护的 cmd 只认一个 token ⇒ 触发器写成脚本推上去。
MSYS_NO_PATHCONV=1 adb push kmod/w103_run.sh /data/local/tmp/w103_run.sh >/dev/null 2>&1
S 'chmod 755 /data/local/tmp/w103_run.sh; rm -f /data/local/tmp/w103_run.out' >/dev/null
S 'rm -f /sdcard/Android/data/com.suw.manager/files/child.log /data/local/tmp/ksu_grant.txt' >/dev/null
WAITFOR() {   # WAITFOR <设备侧文件> <上限秒> [完成标记] —— **轮询到"写完了"再往下走**。
                #   第 51 发的现场：ATT=26 收尾固定 sleep 16 就 `head` 那份回读文件，结果读到
                #   `No such file` ⇒ C 段被判 SKIP(验收其实跑了，只是没等到)。agent 的响应时间
                #   从来不是常数(post 3~17 分钟那一族同源)，所以"等多久"一律改成"等到什么"。
                #   ★第 53 发再补一刀：**"文件出现"根本不代表写完**。这些载荷都是
                #   `{ … } >"$L"` 的形状——文件在第一行就建好了，于是 WAITFOR 2 秒就"等到"，
                #   紧接着 PULL 回来一份**半截**存证(w29_sweep 只到 rm 那三行，[3] 段整个没有)，
                #   总闸照着它报"没有回读行"。⇒ 一律给完成标记(`DONE up=`)，等的是**内容的最后一行**。
    f=$1; n=${2:-40}; m=${3:-}; i=0
    while [ "$i" -lt "$n" ]; do
        if [ -n "$m" ]; then
            g=$(S "grep -acF '$m' $f 2>/dev/null" | tr -d '\r\n')
            case "$g" in
                ''|*[!0-9]) : ;;      # 不是纯数字 ⇒ 回的是 adb 错误文本里的数字，不许当计数(例33)
                *) [ "$g" -ge 1 ] && { echo "    (等到 $f 里的『$m』用时 $((i*2))s)"; return 0; } ;;
            esac
        else
            [ -n "$(S "ls -l $f 2>/dev/null" | tr -d '\r\n')" ] && { echo "    (等到 $f 用时 $((i*2))s)"; return 0; }
        fi
        sleep 2; i=$((i+1))
    done
    echo "    (等满 $((n*2))s 还是没有${m:+『$m』}的 $f ⇒ 后面会把这一格判成没测到，这是对的)"
    return 1
}

DEVOK() {   # ★第 44 发的教训：post 等待中途设备被 HARD_RESET(ro.boot.bootreason=HARD_RESET/PS_HOLD)，
            #   之后每条 adb 只返回 "device '…' not found"，而我用 `tr -dc 0-9` 从**错误文本**里抠数字
            #   当 uid ⇒ 日志打出 `目标 uid=104225003`(那是**序列号**里的数字!)，整发带着假参数在空气里
            #   跑完全部步骤还"跑完了"。⇒ 参数只能从**成功回执**里按形状取；设备不在就当场停。
    D=$(S 'echo PFOK-$(cat /proc/uptime)' | tr -d '\r\n')
    case "$D" in
      PFOK-*) return 0 ;;
    esac
    echo "[x] 设备不在线(读到 [$D]) ⇒ 立刻停；不带错误文本往下拼参数"; exit 8
}

fire() {   # fire <动词> <等多久>：一发里连着打好几个触发时用它(每次都 force-stop，动词才不会被旧进程吃掉)
  A shell am force-stop com.suw.manager >/dev/null 2>&1
  sleep 1
  A shell "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
  sleep "$2"
}
if [ "$ATT" = 21 ]; then
    TU=${TU:-10667}
    TP=${TP:-com.termux}
    echo "  (a) 先给 $TP(uid=$TU) 授权"
    fire "@setprof:$TU:1:$TP" 10
    S "grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2" | cut -c1-150 | sed 's/^/    /'
    echo "  (b) 装静态 su 进它自己的 PATH 目录 + 当场验收"
    MSYS_NO_PATHCONV=1 adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
    MSYS_NO_PATHCONV=1 adb push kmod/w128_install_su.sh /data/local/tmp/w128_install_su.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/sustatic /data/local/tmp/w128_install_su.sh; rm -f /data/local/tmp/w128_su.out' >/dev/null
    fire "@sushd:/data/local/tmp/w128_install_su.sh" 16
    S 'cat /data/local/tmp/w128_su.out 2>&1' | sed 's/^/    /'
    echo "  (c) 撤名单(allow=0) ⇒ 负对照的前置"
    fire "@setprof:$TU:0:$TP" 10
    S "grep -a 'SETPROF uid=$TU allow=0' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2" | cut -c1-150 | sed 's/^/    /'
    echo "  (d) 名单撤了之后再跑一次：必须拿不到 root"
    S 'rm -f /data/local/tmp/w128_neg.out' >/dev/null
    # 原本这里用 S 'printf '#!/system/bin/sh
    #   原本这里用字符串拼 printf 造脚本：单引号套单引号，远端只收到 printf，负对照会静默变成没测
    #   printf(空参数)，脚本根本没生成 ⇒ 负对照会静默变成没测。一律改成 push 本地脚本文件。
    MSYS_NO_PATHCONV=1 adb push kmod/w128_neg.sh /data/local/tmp/w128_neg.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w128_neg.sh' >/dev/null
    fire "@sushd:/data/local/tmp/w128_neg.sh" 14
    S 'cat /data/local/tmp/w128_neg.out 2>&1' | sed 's/^/    /'
    echo "  (e) 收尾：静态 su 落在别人私有目录里，重启不会自己消失 ⇒ 必须走 root 侧删(uid 2000 连目录都进不去)"
    MSYS_NO_PATHCONV=1 adb push kmod/w128_uninstall_su.sh /data/local/tmp/w128_uninstall_su.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w128_uninstall_su.sh; rm -f /data/local/tmp/w128_uninstall.out' >/dev/null
    fire "@sushd:/data/local/tmp/w128_uninstall_su.sh" 12
    S 'cat /data/local/tmp/w128_uninstall.out 2>&1' | sed 's/^/    /'
elif [ "$ATT" = 22 ]; then
    # ===== §6.124 挂载路线：把静态 su 挂成 /system/bin/su 真文件，绕开坏掉的可见性钩子 =====
    TU=${TU:-10667}
    TP=${TP:-com.termux}
    PUSH() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    echo "  (a) 先给 $TP(uid=$TU) 授权"
    fire "@setprof:$TU:1:$TP" 10
    S "grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2" | cut -c1-150 | sed 's/^/    /'
    echo "  (a′) ★负对照地基：挂载**之前**先跑一次同一条探针，必须失败(此时 /system/bin/su 不存在)"
    echo "$TU" > kmod/.w131_tuid; PUSH kmod/.w131_tuid /data/local/tmp/w131_tuid.txt
    PUSH kmod/w131_probe.sh /data/local/tmp/w131_probe.sh
    S 'chmod 755 /data/local/tmp/w131_probe.sh; rm -f /data/local/tmp/w131_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w131_probe.sh" 14
    S 'cat /data/local/tmp/w131_probe.out 2>&1' | sed 's/^/    /'
    echo "  (b) 挂载(先试 overlay，失败退回 cp -a 全量副本 + bind；三条安全判据不过会自己 umount 回退)"
    PUSH cm57/sustatic /data/local/tmp/sustatic
    PUSH kmod/w131_mount_su.sh /data/local/tmp/w131_mount_su.sh
    S 'chmod 755 /data/local/tmp/sustatic /data/local/tmp/w131_mount_su.sh; rm -f /data/local/tmp/w131_mount.out' >/dev/null
    fire "@sushd:/data/local/tmp/w131_mount_su.sh" 60
    S 'cat /data/local/tmp/w131_mount.out 2>&1' | sed 's/^/    /'
    echo "  (b′) 独立复核：不靠脚本自己的回执，PC 侧直接看挂载表 / 文件 / sh 还跑得动吗"
    S 'ls -l /system/bin/su 2>&1; grep -a " /system/bin " /proc/self/mountinfo | cut -c1-130; /system/bin/sh -c "echo SH_ALIVE=yes"; ls /system/bin | wc -l' | sed 's/^/    /'
    echo "  (c) 正判据①：同一个 uid、同一条探针，现在必须出 uid=0(root)"
    S 'rm -f /data/local/tmp/w131_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w131_probe.sh" 14
    S 'cat /data/local/tmp/w131_probe.out 2>&1' | sed 's/^/    /'
    echo "  (d) 正判据②：app 域(untrusted_app + app seccomp)自己走 PATH execvp(\"su\")"
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:" 16
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | sed 's/^/    /'
    echo "  (e) 负对照：撤名单 ⇒ 同一个 uid 的同一条探针必须被 **agent 拒**(ERR not-allowed)，不能再是 ENOENT"
    fire "@setprof:$TU:0:$TP" 10
    S "grep -a 'allow=0' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w131_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w131_probe.sh" 14
    S 'cat /data/local/tmp/w131_probe.out 2>&1' | sed 's/^/    /'
    echo "  (f) 收尾：root 侧 umount + 删目录，并当场证明 /system/bin/su 又不存在了"
    PUSH kmod/w131_umount.sh /data/local/tmp/w131_umount.sh
    S 'chmod 755 /data/local/tmp/w131_umount.sh; rm -f /data/local/tmp/w131_umount.out' >/dev/null
    fire "@sushd:/data/local/tmp/w131_umount.sh" 20
    S 'cat /data/local/tmp/w131_umount.out 2>&1' | sed 's/^/    /'
elif [ "$ATT" = 23 ]; then
    # ===== §6.124③ 挂载路线 v2：落点 /product/bin，判据换成"按 PATH 查找执行" =====
    TU=${TU:-10667}
    TP=${TP:-com.termux}
    APP_PATH='/sbin:/system/sbin:/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin'
    PUSH() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    printf '%s\n' "$TU" > kmod/.w132_tuid
    printf '%s\n' "$APP_PATH" > kmod/.w132_apath
    PUSH cm57/ksuctl87 /data/local/tmp/ksuctl87
    PUSH cm57/sustatic /data/local/tmp/sustatic
    PUSH kmod/w132_probe.sh /data/local/tmp/w132_probe.sh
    PUSH kmod/w132_mount.sh /data/local/tmp/w132_mount.sh
    PUSH kmod/w132_teardown.sh /data/local/tmp/w132_teardown.sh
    PUSH kmod/.w132_tuid /data/local/tmp/w132_tuid.txt
    PUSH kmod/.w132_apath /data/local/tmp/w132_apath.txt
    S 'chmod 755 /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/w132_probe.sh /data/local/tmp/w132_mount.sh /data/local/tmp/w132_teardown.sh' >/dev/null
    echo "  工具就位: ksuctl87=$(S 'md5sum /data/local/tmp/ksuctl87 | cut -c1-32')"
    echo "  (a) 给 $TP(uid=$TU) 授权"
    fire "@setprof:$TU:1:$TP" 10
    S "grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2" | cut -c1-150 | sed 's/^/    /'
    echo "  (a′) ★基线(这次是合法探针)：挂载之前 execvp(\"su\") 必须 errno=2"
    S 'rm -f /data/local/tmp/w132_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w132_probe.sh" 16
    S 'cat /data/local/tmp/w132_probe.out 2>&1' | sed 's/^/    /'
    echo "  (b) 挂载 /product/bin(内含框架健康判据，不过就自动回退)"
    S 'rm -f /data/local/tmp/w132_mount.out' >/dev/null
    fire "@sushd:/data/local/tmp/w132_mount.sh" 45
    S 'cat /data/local/tmp/w132_mount.out 2>&1' | sed 's/^/    /'
    echo "  (b′) 独立复核框架：PC 侧直接数服务、数第三方包、并真的用 am 起一次 app"
    S 'service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l; ls -l /product/bin/su 2>&1' | sed 's/^/    /'
    echo "  (c) 正判据①：同一个第三方 uid 按 PATH 找 su ⇒ 必须 uid=0(root)"
    S 'rm -f /data/local/tmp/w132_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w132_probe.sh" 16
    S 'cat /data/local/tmp/w132_probe.out 2>&1' | sed 's/^/    /'
    echo "  (d) 正判据②：真 app 域(untrusted_app + app seccomp)自己 execvp(\"su\")"
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:" 18
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | sed 's/^/    /'
    echo "  (e) 负对照：撤名单 ⇒ 同一条探针必须被 agent 拒(not-allowed)，不能再是 errno=2"
    fire "@setprof:$TU:0:$TP" 10
    S "grep -a 'allow=0' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w132_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w132_probe.sh" 16
    S 'cat /data/local/tmp/w132_probe.out 2>&1' | sed 's/^/    /'
    echo "  (f) 收尾：umount + 证明回到原状 + 最后一格负对照"
    S 'rm -f /data/local/tmp/w132_teardown.out' >/dev/null
    fire "@sushd:/data/local/tmp/w132_teardown.sh" 20
    S 'cat /data/local/tmp/w132_teardown.out 2>&1' | sed 's/^/    /'
elif [ "$ATT" = 24 ]; then
    # ===== §6.124⑤ 挂载路线(固化版)：落点 /product/bin + 钩子进不来的三态探针 =====
    TU=${TU:-10667}
    TP=${TP:-com.termux}
    TGT=${TGT:-/product/bin}
    PUSH() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    printf '%s\n' "$TU" > kmod/.w132_tuid
    PUSH cm57/ksuctl87 /data/local/tmp/ksuctl87
    PUSH cm57/sustatic /data/local/tmp/sustatic
    PUSH kmod/w133_probe.sh /data/local/tmp/w133_probe.sh
    PUSH kmod/w135_fix.sh /data/local/tmp/w135_fix.sh
    PUSH kmod/w135_off.sh /data/local/tmp/w135_off.sh
    PUSH kmod/.w132_tuid /data/local/tmp/w132_tuid.txt
    S 'chmod 755 /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/w133_probe.sh /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh' >/dev/null
    echo "  工具: ksuctl87=$(S 'md5sum /data/local/tmp/ksuctl87 2>&1 | cut -c1-32')  agent=[$(S 'pidof shd')]"
    echo "  (a) 点亮名单 $TP(uid=$TU)"
    fire "@setprof:$TU:1:$TP" 10
    S "grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | cut -c1-150 | sed 's/^/    /'
    echo "  (a′) ★态①：未挂载 ⇒ 探针 B 段必须 errno=2(文件不在)，而 C 段(含 /system/bin 的 PATH)会被钩子接住"
    S 'rm -f /data/local/tmp/w133_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w133_probe.sh" 16
    S 'cat /data/local/tmp/w133_probe.out 2>&1' | sed 's/^/    /'
    echo "  (b) 挂载 + 健康判据 + ★态②(挂载且名单内 ⇒ 必须 uid=0(root))"
    S 'rm -f /data/local/tmp/w135_fix.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_fix.sh" 34
    S 'cat /data/local/tmp/w135_fix.out 2>&1' | sed 's/^/    /'
    echo "  (b′) PC 侧独立复核框架(挂载还挂着的时候)：服务数 / 第三方包数 / 真的 am start 一次"
    S 'service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l' | sed 's/^/    /'
    S 'am force-stop com.suw.manager; sleep 1; am start -n com.suw.manager/.MainActivity 2>&1 | head -2' | sed 's/^/    /'
    echo "  (c) 撤名单"
    fire "@setprof:$TU:0:$TP" 10
    S "grep -a 'allow=0' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | cut -c1-150 | sed 's/^/    /'
    echo "  (c′) ★态③：挂载但名单撤了 ⇒ 探针 B 段必须是 agent 拒(not-allowed)，**不能**是 errno=2"
    S 'rm -f /data/local/tmp/w133_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w133_probe.sh" 16
    S 'cat /data/local/tmp/w133_probe.out 2>&1' | sed 's/^/    /'
    echo "  (d) 收尾：root 侧先 umount 成功、再删源目录"
    S 'rm -f /data/local/tmp/w135_off.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_off.sh" 18
    S 'cat /data/local/tmp/w135_off.out 2>&1' | sed 's/^/    /'
    for f in w133_probe.out w135_fix.out w135_off.out; do
        MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/$f" "kmod/w103_evidence/w26_$f" >/dev/null 2>&1 && echo "  存证 w26_$f"
    done
elif [ "$ATT" = 26 ]; then
    # ===== 合并验收(#53 之后)：**一枪里跑完三条链**，段与段各自落盘，断在哪一段都能单独判 =====
    #   S1 挂载路线三态(§6.124⑤)  → 段名沿用 ATT=24 的写法，好让 `check_mount_su.sh` 原样能判
    #   S2 域的正/负对照(§6.134)   → 存证名沿用 w28_*，好让 `check_dom_su.sh` 原样能判
    #   S3 收尾 root 侧回读残留(§6.130 那条"shell 侧 Permission denied 不算证据")
    #   ★为什么合并：三条链原来各吃一枪(每枪 25~30 分钟 + 一次 post 空枪风险)；合并之后
    #     一枪同时证"所有 app 看得见 su / 授权只在内核 / profile 的域是可控旋钮 / 机器没留东西"。
    #   ★顺序上的讲究：域那两段要**先**跑(它们只动 profile)，撤名单放最后(一撤之后 su 全断，
    #     再想补测别的就得重来一枪)。
    TP=${TP:-com.termux}
    TGT=${TGT:-/product/bin}
    DOM=/data/local/tmp/w147_dom.sh
    DOM2=/data/local/tmp/w147_dom2.sh
    RUN=/data/local/tmp/w149_su_run.sh
    RES=/data/local/tmp/w152_residue.sh
    ADF=/sdcard/Android/data/com.suw.manager/files/app_dom.txt
    GRF=/sdcard/Android/data/com.suw.manager/files/ksu_grant.txt
    PUSH() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    PULL() { MSYS_NO_PATHCONV=1 adb pull "$1" "kmod/w103_evidence/$2" >/dev/null 2>&1 && echo "    存证 $2"; }
    for f in cm57/ksuctl87:/data/local/tmp/ksuctl87 cm57/sustatic:/data/local/tmp/sustatic \
             cm57/domprint:/data/local/tmp/domprint \
             kmod/w133_probe.sh:/data/local/tmp/w133_probe.sh \
             kmod/w135_fix.sh:/data/local/tmp/w135_fix.sh \
             kmod/w135_off.sh:/data/local/tmp/w135_off.sh \
             kmod/w147_dom.sh:"$DOM" kmod/w147_dom2.sh:"$DOM2" \
             kmod/w149_su_run.sh:"$RUN" kmod/w152_residue.sh:"$RES" \
             kmod/w153_sweep.sh:/data/local/tmp/w153_sweep.sh \
             kmod/w155_mountwatch.sh:/data/local/tmp/w155_mountwatch.sh \
             kmod/w155_mwloop.sh:/data/local/tmp/w155_mwloop.sh \
             kmod/w148_uid.sh:/data/local/tmp/w148_uid.sh; do
        PUSH "${f%%:*}" "${f##*:}"
    done
    printf '%s\n' "$TP" > kmod/.w148_pkg1
    PUSH kmod/.w148_pkg1 /data/local/tmp/w148_pkg1.txt
    LOADS="/data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/domprint $DOM $DOM2 $RUN $RES /data/local/tmp/w153_sweep.sh /data/local/tmp/w148_uid.sh /data/local/tmp/w133_probe.sh /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh /data/local/tmp/w155_mountwatch.sh /data/local/tmp/w155_mwloop.sh"
    NW=$(printf '%s\n' $LOADS | wc -l | tr -dc '0-9')
    S "chmod 755 $LOADS; rm -f /data/local/tmp/w148_uid.out /data/local/tmp/w149_su_run.out $ADF" >/dev/null
    DEVOK
    MISRAW=$(S "ls $LOADS 2>&1 | grep -c 'No such file'" | tr -d '\r\n')
    # ★计数只信**纯数字**回执(例33 那一族：第五十五发就是这里丢了一个收尾单引号，远端回
    #   `/system/bin/sh: no closing quote`，旧写法把那句错误文本当"缺 N 个"打出来——
    #   形状闸先把"信道坏了"和"载荷没落地"分开，二者停下来的做法不一样)。
    case "$MISRAW" in
      ""|*[!0-9]*) echo "[x] 清点回执不是纯数字：[$MISRAW] ⇒ 是信道问题，不是载荷问题 ⇒ 停"; exit 9;;
    esac
    [ "$MISRAW" = "0" ] || { echo "[x] 有 $MISRAW 个载荷没落到设备上 ⇒ 停"; exit 9; }
    echo "  载荷清点: 声明 $NW 个，缺 $MISRAW 个(必须 0)  agent=[$(S 'pidof shd')]"

    echo "  (a0) 现场反查 uid + **本轮 enforce 口径**"
    fire "@sushd:/data/local/tmp/w148_uid.sh" 6
    WAITFOR /data/local/tmp/w148_uid.out 120 'DONE up='
    S 'head -c 6000 /data/local/tmp/w148_uid.out 2>&1' | sed 's/^/    /'
    TURAW=$(S 'cat /data/local/tmp/w132_tuid.txt 2>/dev/null' | tr -d '\r\n')
    TU=$(printf '%s' "$TURAW" | grep -oE '^[0-9]{3,6}$')
    [ -n "$TU" ] || { echo "[x] w132_tuid.txt 不是 3~6 位纯数字：[$TURAW] ⇒ 后面全不打"; exit 6; }
    ENF=$(S 'getenforce' | tr -d '\r\n')
    echo "    ⇒ 目标 uid=$TU (包名 $TP)；本轮 enforce=$ENF —— Permissive 是**我们自己 punch 的 sen 相**造成的 ⇒"
    echo "      本轮 enforce=$ENF ⇒ 域鉴别器(DOM 那七行)不参与判定，只看 attr/current 与 Seccomp"

    echo '  (a) 点亮名单(★顺序必须在这里：check_mount_su.sh 的态②要求挂载时该 uid 已在名单里；'
    echo "      域那几段是**后来覆盖同一份 profile**——先点亮、再换域、最后撤销)"
    fire "@setprof:$TU:1:$TP:u:r:shell:s0" 10
    S "grep -a 'SETPROF uid' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'

    echo "  (a′) ★态①：未挂载 ⇒ 探针 B 段必须 errno=2(文件不在)，而 C 段(含 /system/bin 的 PATH)会被钩子接住"
    S 'rm -f /data/local/tmp/w133_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w133_probe.sh" 6
    WAITFOR /data/local/tmp/w133_probe.out 120 'DONE up='
    S 'head -c 6000 /data/local/tmp/w133_probe.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w133_probe.out w29_probe_pre

    echo "  (b) 挂载 + 健康判据 + ★态②(挂载且名单内 ⇒ 必须 uid=0(root))"
    S 'rm -f /data/local/tmp/w135_fix.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_fix.sh" 6
    WAITFOR /data/local/tmp/w135_fix.out 120 'DONE up='
    S 'head -c 6000 /data/local/tmp/w135_fix.out 2>&1' | sed 's/^/    /'


    echo "  (b″) ★挂载存活取样器(setsid 甩出去，占不了 sushd 的队列)：#58 要的那份一手"
    S 'rm -f /data/local/tmp/w155_mw.out' >/dev/null
    fire "@sushd:/data/local/tmp/w155_mountwatch.sh" 4
    S 'head -1 /data/local/tmp/w155_mw.out 2>&1' | cut -c1-120 | sed 's/^/      /'
    MWP=$(S 'grep -ac "MW up=" /data/local/tmp/w155_mw.out 2>/dev/null' | tr -dc '0-9')
    echo "      取样器已开录(当前 $MWP 行)"
    echo "  (c1) 域·负对照：profile 填**不存在的域** ⇒ uid 该换 0，CTX 必须保持起点域"
    DEVOK
    fire "@setprof:$TU:1:$TP:u:r:zzz_no_such_domain:s0" 10
    S "grep -a 'SETPROF uid' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w149_su_run.out w28_neg

    echo "  (c2) 域·正判据：**同一个 uid 只换域** ⇒ u:r:shell:s0(起点是 kernel，所以这是可分辨的降级)"
    DEVOK
    fire "@setprof:$TU:1:$TP:u:r:shell:s0" 10
    S "grep -a 'SETPROF uid' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w149_su_run.out w28_shell

    echo "  (c3) app 来源两档：@domapp(不加 su) 与 @domsu(加 su) ⇒ 看 Seccomp 2→0"
    fire "@domapp:$DOM2" 12
    S "head -c 6000 $ADF 2>&1" | sed 's/^/    /'
    PULL "$ADF" w28_app0
    fire "@domsu:$DOM2" 14
    S "head -c 6000 $ADF 2>&1" | sed 's/^/    /'
    PULL "$ADF" w28_app1

    echo "  (b′) PC 侧独立复核框架(挂载还挂着的时候)：服务数走 shell 域 + 第三方包数 + **真的 am start 一次**"
    S 'runcon u:r:shell:s0 service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l' | sed 's/^/    /'
    S 'am start -n com.suw.manager/.MainActivity 2>&1 | head -2' | sed 's/^/    /'

    echo "  (b″) ★D 块：把授权链 G1..G7 也在**同一枪**里跑一遍(SKIP_CHAIN=1 KEEP=1 ⇒ 活窗口、结尾不重启)"
    DEVOK
    # ★让 regress 自己挑第三方包当对象：它挑的 uid 与我们这一枪里 setprof 的 $TU 无关，
    #   两块互不污染(共用一个 uid 的话，D 块的撤销会把 B 块的后续判据条件改掉)。
    SKIP_CHAIN=1 KEEP=1 bash kmod/regress_ksu.sh >kmod/w103_evidence/w29_regress.txt 2>&1
    RC=$?
    echo "    regress 退出码=$RC(0=G1..G7 全绿；否则看下面几行)"
    grep -aE "^  \[G[0-9]\]|汇总：FAIL" kmod/w103_evidence/w29_regress.txt | tail -10 | sed 's/^/    /'
    echo "  存证 w29_regress"

    echo "  (c) 撤名单 ⇒ 探针 B 段必须是 agent 拒(not-allowed)，**不能**是 errno=2"
    DEVOK
    fire "@setprof:$TU:0:$TP:-" 10
    S "grep -a 'allow=0' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w133_probe.out' >/dev/null
    fire "@sushd:/data/local/tmp/w133_probe.sh" 6
    WAITFOR /data/local/tmp/w133_probe.out 120 'DONE up='
    S 'head -c 6000 /data/local/tmp/w133_probe.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w133_probe.out w29_probe_revoked
    echo "  (c″) 域·撤名单：同一个普通 uid 走 su 的那条路也必须被拒(给 check_dom_su.sh 的 w28_revoked)"
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    WAITFOR /data/local/tmp/w149_su_run.out 150 'DONE up='
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w149_su_run.out w28_revoked

    echo "  (d) 收尾：umount → **清扫(/data/adb 是我们 stage 造的)** → 再 root 侧回读残留"
    DEVOK
    S 'rm -f /data/local/tmp/w135_off.out /data/local/tmp/w152_residue.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_off.sh" 6
    WAITFOR /data/local/tmp/w135_off.out 150 'DONE up='
    S 'head -c 6000 /data/local/tmp/w135_off.out 2>&1' | sed 's/^/    /'
    WAITFOR /data/local/tmp/w155_mw.out 30 'MW-END'
    PULL /data/local/tmp/w155_mw.out w29_mw
    S 'pkill -f w155_mwloop.sh; sleep 1; rm -f /data/local/tmp/w155_mw.out' >/dev/null
    S 'rm -f /data/local/tmp/w153_sweep.out' >/dev/null
    fire "@sushd:/data/local/tmp/w153_sweep.sh" 6
    WAITFOR /data/local/tmp/w153_sweep.out 150 'DONE up='
    S 'head -c 6000 /data/local/tmp/w153_sweep.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w153_sweep.out w29_sweep
    fire "@sushd:$RES" 6
    WAITFOR /data/local/tmp/w152_residue.out 240 'DONE up='
    S 'head -c 6000 /data/local/tmp/w152_residue.out 2>&1' | sed 's/^/    /'
    PULL /data/local/tmp/w152_residue.out w29_residue
    for f in w148_uid.out w135_fix.out w135_off.out; do
        PULL "/data/local/tmp/$f" "w29_$f"
    done
    echo "  (e) 一枪之内三条链的读法(驱动退出、设备已重启之后照样能判)："
    echo "      bash kmod/check_mount_su.sh kmod/w103_att26.log && bash kmod/check_dom_su.sh kmod/w103_att26.log"

elif [ "$ATT" = 27 ]; then
    # ===== #56：在"晚加载 + 不重启"的窗口里把**脚本型模块**激活(用户已点头这一次踢框架) =====
    #   命题已按 §6.136③ 收窄：不证"内核开机按 modules.rc 做 magic mount"(那条 §6.129 判死)，
    #   只证"模块自己的 post-fs-data/service 脚本在窗口里跑起来 + 挂着的 bind 能不能活过踢框架"。
    echo "  (m0) 铺模块与脚本(三条钉子都在 w154_mod.sh 的注释里：只挂 /product/bin、cp -a 原内容、root 侧先 umount 再删源)"
    P2() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    for p in cm57/sustatic:/data/local/tmp/sustatic \
             kmod/w154_mod.sh:/data/local/tmp/w154_mod.sh \
             kmod/modsrc_bind/module.prop:/data/local/tmp/mod_module.prop \
             kmod/modsrc_bind/post-fs-data.sh:/data/local/tmp/mod_post-fs-data.sh \
             kmod/modsrc_bind/service.sh:/data/local/tmp/mod_service.sh; do
        P2 "${p%%:*}" "${p##*:}"
    done
    S 'chmod 755 /data/local/tmp/sustatic /data/local/tmp/w154_mod.sh /data/local/tmp/mod_post-fs-data.sh /data/local/tmp/mod_service.sh; rm -f /data/local/tmp/w154_mod.out /data/local/tmp/modsu.log' >/dev/null
    MLOADS="/data/local/tmp/sustatic /data/local/tmp/w154_mod.sh /data/local/tmp/mod_module.prop /data/local/tmp/mod_post-fs-data.sh /data/local/tmp/mod_service.sh"
    MR=$(S "ls $MLOADS 2>&1 | grep -c 'No such file'" | tr -d '\000')
    MR=$(printf '%s' "$MR" | tr -dc '0-9')
    case "$MR" in ''|*[!0-9]*) echo "[x] 清点回执不是纯数字 ⇒ 信道问题，别踢框架"; exit 9;; esac
    [ "$MR" = "0" ] || { echo "[x] 有 $MR 个模块载荷没落地 ⇒ 停(没落地就别踢)"; exit 9; }
    echo "    模块载荷清点: 缺 $MR 个(必须 0)  agent=[$(S 'pidof shd')]"

    echo "  (m1) ★放踢框架标记(这一步就是用户点头的那一手：kill -9 system_server/zygote64/zygote)"
    S 'touch /data/local/tmp/w154_kick' >/dev/null
    echo "    标记=[$(S 'ls -l /data/local/tmp/w154_kick 2>&1 | cut -c1-60')]"
    UP_BEFORE=$(S 'cut -d" " -f1 /proc/uptime' | tr -dc '0-9.')
    echo "    踢之前: up=$UP_BEFORE mod=$(S 'grep -c kernelsu /proc/modules' | tr -dc '0-9') enf=$(S 'getenforce' | tr -d '\r\n')"

    echo "  (m2) 派发模块激活：脚本自己跑 post-fs-data ⇒ 踢 ⇒ 复核 ⇒ **自己收尾**(信道踢断也收得干净)"
    fire "@sushd:/data/local/tmp/w154_mod.sh" 6
    WAITFOR /data/local/tmp/w154_mod.out 240 '===== DONE'
    S 'head -c 8000 /data/local/tmp/w154_mod.out 2>&1' | sed 's/^/    /'
    echo "  --- 模块脚本自己的落盘(modsu.log) ---"
    S 'head -c 4000 /data/local/tmp/modsu.log 2>&1' | sed 's/^/    /'
    DEVOK
    echo "  (m3) PC 侧独立复核：挂载还在吗、su 还能命中吗、框架回来没有"
    S 'echo 挂载行=$(grep -c pbin /proc/self/mountinfo) su=[$(ls /product/bin/su 2>&1 | head -1)] 服务=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1) 三方包=$(pm list packages -3 2>/dev/null | wc -l)' | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w154_mod.out kmod/w103_evidence/w27_mod.out >/dev/null 2>&1 && echo "    存证 w27_mod.out"
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/modsu.log kmod/w103_evidence/w27_modsu.log >/dev/null 2>&1 && echo "    存证 w27_modsu.log"
    # ★这一发**不新建总闸**：没配夹具的判据脚本本身就是我这两天反复栽的那一族(例35/37/39)。
    #   #56 是实验不是交付闸门 ⇒ 判读直接看两份回执(w27_mod.out / w27_modsu.log 里那五行：
    #   装好=?、BIND_RC=?、AFTER su=…、踢完之后 挂载行/服务数/三方包、清完：…)，原文进文档。
    echo "    判据就是这两份存证里的 装好/BIND_RC/踢完之后/清完 四组回执(不另写闸门，见上面注释)"
elif [ "$ATT" = 25 ]; then
    # ===== #53 第二版：把"能不能切域"和"切了能不能干活"分成两问，只答前者 =====
    #   第 43 发的三条一手把后者钉死了：
    #     ① 我们自己那一枪(pr 的 sen 相)在 punch 时就把 selinux_state.enforcing 写成 0
    #        ⇒ **整窗 Permissive**(一手：up=15s 到 up=2358s 全程 enf=Permissive，重启后才回 Enforcing)
    #        ⇒ 窗口内 SELinux 根本不参与访问判定，"这个域能不能干活"**在设计上无法在我们窗口里回答**
    #          (root 能干活靠的是 uid=0 + CapEff=0x3fffffffff + DAC，与域无关)；
    #     ② 反过来"profile 的域落不落地"是**可测的**(attr/current 一行就够)，而且这条才是 #43 卡住的那格；
    #     ③ 发起者不能是 Manager：Manager uid 走的是 default_root_profile(domain=u:r:ksu:s0)，
    #        本机解不开 ⇒ 内核 -22 后**保持调用方域**，永远看不到我们自填的那份。
    #   ⇒ 主体换成"被我们 setprof 的那个普通 uid"，入口用 @sushd + `supath`(起点域实测是
    #     u:r:kernel:s0，不是 shell)，所以"变成 shell"是一次**可分辨的降级**；
    #     再加一个**负对照**：填一个不存在的域，期望 CTX 不变 + 内核为**我们那个串**打 -22。
    #   (第 43 发的另外两个错已修：w147_dom.sh 里函数名 `r` 撞 mksh 预定义别名；
    #    w148_uid.sh 的 grep 命中两行 ⇒ PC 侧拼出不存在的 uid 1066710817。)
    TP=${TP:-com.termux}
    TGT=${TGT:-/product/bin}
    DOM2=/data/local/tmp/w147_dom2.sh
    RUN=/data/local/tmp/w149_su_run.sh
    ADF=/sdcard/Android/data/com.suw.manager/files/app_dom.txt
    GRF=/sdcard/Android/data/com.suw.manager/files/ksu_grant.txt
    PUSH() { MSYS_NO_PATHCONV=1 adb push "$1" "$2" >/dev/null 2>&1; }
    PUSH cm57/ksuctl87 /data/local/tmp/ksuctl87
    PUSH cm57/sustatic /data/local/tmp/sustatic
    PUSH kmod/w135_fix.sh /data/local/tmp/w135_fix.sh
    PUSH kmod/w135_off.sh /data/local/tmp/w135_off.sh
    PUSH kmod/w147_dom.sh /data/local/tmp/w147_dom.sh
    PUSH kmod/w147_dom2.sh "$DOM2"
    PUSH cm57/domprint /data/local/tmp/domprint
    PUSH kmod/w149_su_run.sh "$RUN"
    PUSH kmod/w148_uid.sh /data/local/tmp/w148_uid.sh
    printf '%s\n' "$TP" > kmod/.w148_pkg1
    PUSH kmod/.w148_pkg1 /data/local/tmp/w148_pkg1.txt
    S "chmod 755 /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh /data/local/tmp/w147_dom.sh $DOM2 $RUN /data/local/tmp/w148_uid.sh /data/local/tmp/domprint; rm -f /data/local/tmp/w148_uid.out $ADF /data/local/tmp/w149_su_run.out" >/dev/null
    echo "  工具: ksuctl87=[$(S 'md5sum /data/local/tmp/ksuctl87 2>&1 | cut -c1-32')] runner=[$(S "md5sum $RUN 2>&1 | cut -c1-32")] agent=[$(S 'pidof shd')]"
    DEVOK
    MISS=$(S "ls /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh /data/local/tmp/w147_dom.sh $DOM2 $RUN /data/local/tmp/w148_uid.sh /data/local/tmp/domprint 2>&1 | grep -c 'No such file'")
    [ "${MISS:-x}" = "0" ] || { echo "[x] 有 $MISS 个载荷没落到设备上 ⇒ 停(PUSH 的失败以前是静默的)"; exit 9; }
    echo "    载荷全部落地(9/9)"

    echo "  (a0) 现场反查 uid(grep -am1 + 单行数字校验) + 挂载 + **记下整窗的 enforce 口径**"
    fire "@sushd:/data/local/tmp/w148_uid.sh" 12
    S 'head -c 6000 /data/local/tmp/w148_uid.out 2>&1' | sed 's/^/    /'
    DEVOK
    TURAW=$(S 'cat /data/local/tmp/w132_tuid.txt 2>/dev/null' | tr -d '\r\n')
    TU=$(printf '%s' "$TURAW" | grep -oE '^[0-9]{3,6}$')
    [ -n "$TU" ] || { echo "[x] w132_tuid.txt 不是 3~6 位纯数字：[$TURAW] ⇒ 后面全不打"
                      echo "    (第 43 发：grep 命中两行拼成 1066710817；第 44 发：设备掉线后读到的是 adb 的错误文本)"
                      exit 6; }
    echo "    ⇒ 目标 uid=$TU (包名 $TP)"
    S 'rm -f /data/local/tmp/w135_fix.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_fix.sh" 34
    S 'grep -aE "BIND_RC|SU_AT_TGT|SVC_SHELL|supath|uid=0" /data/local/tmp/w135_fix.out' | sed 's/^/    /'
    ENF=$(S 'getenforce' | tr -d '\r\n')
    echo "    ★本轮 enforce=$ENF —— Permissive 是**我们自己 punch 的 sen 相**造成的 ⇒"
    echo "      域鉴别器(DOM 那七行)本轮**不参与判定**，只看 attr/current 与 Seccomp"

    echo "  (a1) 负对照：填一个**不存在的域** ⇒ 期望 CTX 保持起点域 + 内核为我们那个串打 -22"
    DEVOK
    fire "@setprof:$TU:1:$TP:u:r:zzz_no_such_domain:s0" 10
    S "grep -a 'SETPROF uid' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull "$RUN" /dev/null >/dev/null 2>&1
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w149_su_run.out kmod/w103_evidence/w28_neg >/dev/null 2>&1 && echo "    存证 w28_neg"

    echo "  (a2) 正判据：domain=u:r:shell:s0 ⇒ 起点是 kernel，所以变成 shell 是**可分辨的降级**"
    DEVOK
    fire "@setprof:$TU:1:$TP:u:r:shell:s0" 10
    S "grep -a 'SETPROF uid' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w149_su_run.out kmod/w103_evidence/w28_shell >/dev/null 2>&1 && echo "    存证 w28_shell"

    echo "  (a3) app 来源的两份记录：@domapp(不加 su) 与 @domsu(加 su) —— 看 Seccomp 2→0"
    fire "@domapp:$DOM2" 12
    S "cat $ADF 2>&1" | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull "$ADF" kmod/w103_evidence/w28_app0 >/dev/null 2>&1 && echo "    存证 w28_app0"
    fire "@domsu:$DOM2" 14
    S "cat $ADF 2>&1" | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull "$ADF" kmod/w103_evidence/w28_app1 >/dev/null 2>&1 && echo "    存证 w28_app1"

    echo "  (b) 撤名单 ⇒ 同一个普通 uid 必须被拒(注意：Manager 自己不算，它本来就有 root)"
    DEVOK
    fire "@setprof:$TU:0:$TP:-" 10
    S "grep -a 'allow=0' $GRF | tail -1" | cut -c1-150 | sed 's/^/    /'
    S 'rm -f /data/local/tmp/w149_su_run.out' >/dev/null
    fire "@sushd:$RUN" 30
    S 'head -c 6000 /data/local/tmp/w149_su_run.out 2>&1' | sed 's/^/    /'
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w149_su_run.out kmod/w103_evidence/w28_revoked >/dev/null 2>&1 && echo "    存证 w28_revoked"

    echo "  (b′) 框架复核 + 内核侧域回执"
    S 'runcon u:r:shell:s0 service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l' | sed 's/^/    /'
    S 'grep -aE "secctx_to_secid|X6 before setup_selinux|X2 profile" /data/local/tmp/dmesg2.log 2>/dev/null | tail -6 | cut -c1-160' | sed 's/^/    /'
    echo "  (d) 收尾：root 侧先 umount 成功、再删源目录"
    S 'rm -f /data/local/tmp/w135_off.out' >/dev/null
    fire "@sushd:/data/local/tmp/w135_off.sh" 18
    S 'head -c 6000 /data/local/tmp/w135_off.out 2>&1' | sed 's/^/    /'
    for f in w148_uid.out w135_fix.out w135_off.out; do
        MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/$f" "kmod/w103_evidence/w28_$f" >/dev/null 2>&1 && echo "    存证 w28_$f"
    done
elif [ "$ATT" = 19 ] || [ "$ATT" = 20 ]; then
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    echo "  备份信道现状: $(S 'ls -l /data/local/tmp/dmesg2.log 2>&1 | cut -c1-60')"
    fire "@suprobe:id" 14
    echo "  --- @suprobe: 报告行 ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-160 | sed 's/^/    /'
    echo "  --- 孩子输出 ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -10 | sed 's/^/    /'
elif [ "$ATT" = 18 ]; then
    MSYS_NO_PATHCONV=1 adb push kmod/w124_log.sh /data/local/tmp/w124_log.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w124_log.sh' >/dev/null
    fire "@sushd:/data/local/tmp/w124_log.sh" 12
    echo "  --- 常驻 dumper 起没起 ---"
    S 'cat /data/local/tmp/w124_log.out 2>&1; ls -l /data/local/tmp/dmesg2.log 2>&1 | cut -c1-70' | sed 's/^/    /'
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:id" 14
    echo "  --- @suprobe: 报告行 ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-160 | sed 's/^/    /'
    echo "  --- 孩子输出 ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -10 | sed 's/^/    /'
    echo "  --- 现场(常驻 dmesg2.log 的最后 14 条 KernelSU 行) ---"
    S 'grep -a "KSUBEAT" /data/local/tmp/dmesg2.log 2>/dev/null | tail -14' | cut -c1-150 | sed 's/^/    /'
    S 'cp /data/local/tmp/dmesg2.log /data/local/tmp/dmesg2.keep 2>/dev/null' >/dev/null
elif [ "$ATT" = 17 ]; then
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:id" 12
    echo "  --- @suprobe: 报告行 ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-160 | sed 's/^/    /'
    echo "  --- 孩子输出(app_su.txt) ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -12 | sed 's/^/    /'
elif [ "$ATT" = 15 ] || [ "$ATT" = 16 ]; then
    # ① 先把内核那份"桩报告"整份抄出来(趁机器还活着)——死因判读要靠它，不能靠 grep 过的片段
    MSYS_NO_PATHCONV=1 adb push kmod/w120_slots.sh /data/local/tmp/w120_slots.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w120_slots.sh; rm -f /data/local/tmp/w120_slots.txt' >/dev/null
    fire "@sushd:/data/local/tmp/w120_slots.sh" 12
    S 'grep -a "CFIFIX\|=== up=" /data/local/tmp/w120_slots.txt 2>&1 | tail -12' | cut -c1-150 | sed 's/^/    /'
    S 'cp /data/local/tmp/w120_slots.txt /data/local/tmp/w120_slots.keep' >/dev/null
    # ② 再打探针：第一句就是 access("/system/bin/su", X_OK) ⇒ 死/活直接夹出是哪一位
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:id" 12
    echo "  --- @suprobe: 报告行(死在哪一句看这里) ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-160 | sed 's/^/    /'
    echo "  --- execvp 的孩子(app_su.txt) ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -12 | sed 's/^/    /'
elif [ "$ATT" = 14 ]; then
    # ① 让 root 侧把 magic mount 做上(tmpfs 盖 /system/bin + 符号链接农场 + su -> /dev/ksud)
    MSYS_NO_PATHCONV=1 adb push kmod/w119_mm.sh /data/local/tmp/w119_mm.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w119_mm.sh; rm -f /data/local/tmp/w119_mm.out' >/dev/null
    fire "@sushd:/data/local/tmp/w119_mm.sh" 14
    echo "  --- magic mount 自己的取证 ---"
    S 'cat /data/local/tmp/w119_mm.out 2>&1' | sed 's/^/    /'
    # ② app 侧探测：文件真在 ⇒ access/stat 应当天然成功，execvp(走 PATH)应当出 root
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:id" 12
    echo "  --- @suprobe: 报告行 ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-160 | sed 's/^/    /'
    echo "  --- execvp 的孩子(app_su.txt) ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -12 | sed 's/^/    /'
elif [ "$ATT" = 13 ]; then
    # ① 探测：本进程(未 escape 的授权 uid)自己 access/stat/execvp —— 与 Termux 同形
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@suprobe:id" 10
    echo "  --- @suprobe: 报告行 ---"
    S "grep -a 'SUPROBE' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -8" | cut -c1-150 | sed 's/^/    /'
    echo "  --- execvp 的孩子(app_su.txt，走 PATH 找 su 之后的输出) ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | head -12 | sed 's/^/    /'
    # ② 老形状(绝对路径)再打一枪，确认开位没把改道本身弄坏
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@su:id" 8
    echo "  --- @su:id 绝对路径那一枪 ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -d '\000-\010\013\014\016-\037\177' | tail -4 | sed 's/^/    /'
    S 'cp /sdcard/Android/data/com.suw.manager/files/app_su.txt /data/local/tmp/w103_absu.txt; chmod 666 /data/local/tmp/w103_absu.txt' >/dev/null
elif [ "$ATT" = 12 ]; then
    # ① 先给 Manager 自己的 uid 写一条 profile(selinux_domain=u:r:shell:s0，写死在 JNI 里)
    fire "@setprof:10319:1:com.suw.manager" 8
    S 'grep -a "SETPROF" /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2' | sed 's/^/    /'
    # ② 再敲 su(同一 boot、stage 还没收尾 ⇒ dmesg.live 还活着，X2 回执捞得到)
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    fire "@su:id" 8
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | tr -cd '\11\12\15\40-\176' | head -8 | sed 's/^/    /'
elif [ "$ATT" = 11 ]; then
    # ★真 app 形状：不预先 escape、不带 sushd 的管道，让 app 自己的子进程去 execv("/system/bin/su")
    S 'rm -f /sdcard/Android/data/com.suw.manager/files/app_su.txt' >/dev/null
    A shell logcat -c >/dev/null 2>&1
    fire "@su:id" 6
    echo "  --- app 子进程自己的输出(app_su.txt) ---"
    S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' | head -8 | sed 's/^/    /'
    echo "  --- 这个子进程的死法(logcat) ---"
    S 'logcat -d -t 400' 2>/dev/null | grep -aiE "SIGSYS|seccomp|su:|app_su|>>> /system/bin" | tail -8 | sed 's/^/    /'
elif [ "$ATT" = 9 ] || [ "$ATT" = 10 ]; then
    # 普通被授权 uid(10667) 与 Manager(10319) 各打一枪
    MSYS_NO_PATHCONV=1 adb push kmod/w103_run67.sh /data/local/tmp/w103_run67.sh >/dev/null 2>&1
    S 'chmod 755 /data/local/tmp/w103_run67.sh; rm -f /data/local/tmp/w103_run67.out' >/dev/null
    echo "  (a) 先给 10667 加白名单"
    fire "@setprof:10667:1:com.termux" 12
    echo "  (b) 10667 敲 su"
    fire "@sushd:/data/local/tmp/w103_run67.sh" 14
    S 'cp /data/local/tmp/w103_run67.out /data/local/tmp/w103_run67.out.early 2>/dev/null; chmod 666 /data/local/tmp/w103_run67.out.early 2>/dev/null' >/dev/null
    echo "  (c) 10319(Manager) 敲 su 做对照"
    fire "@sushd:/data/local/tmp/w103_run.sh" 14
    S 'cp /data/local/tmp/w103_run.out /data/local/tmp/w103_run.out.early 2>/dev/null; chmod 666 /data/local/tmp/w103_run.out.early 2>/dev/null' >/dev/null
    if [ "$ATT" = 10 ]; then
        # ★这一枪才是 #41 的判据：等 stage 打完 `=== 结束 ===`(它的收尾块会 rm -rf /data/adb/ksud)
        #   之后再敲 su。ksud 在 /dev(tmpfs) ⇒ 应该还活着；在 /data/adb ⇒ 必然 ENOENT(第一百零八发实测)。
        echo "  (d) 等 stage 收尾(=== 结束 ===)，最等多 10 分钟"
        for w in $(seq 1 120); do
            sleep 5
            E=$(S 'grep -ac "=== 结束" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
            [ "${E:-0}" != "0" ] && { echo "      stage 已收尾 t+$((w*5))s"; break; }
        done
        echo "  (e) 收尾之后再敲一次 su(10319) —— 判据：还能出 uid=0(root) 就说明 tmpfs 这条路把 su 的生命周期拉满整窗"
        fire "@sushd:/data/local/tmp/w103_run.sh" 16
        S 'cp /data/local/tmp/w103_run.out /data/local/tmp/w103_run.out.late 2>/dev/null; chmod 666 /data/local/tmp/w103_run.out.late 2>/dev/null' >/dev/null
        echo "  (f) 收尾后 10667 也敲一次"
        fire "@sushd:/data/local/tmp/w103_run67.sh" 16
        S 'cp /data/local/tmp/w103_run67.out /data/local/tmp/w103_run67.out.late 2>/dev/null; chmod 666 /data/local/tmp/w103_run67.out.late 2>/dev/null' >/dev/null
    fi
else
    fire "@sushd:/data/local/tmp/w103_run.sh" 0
fi
echo "  已发出，每 3s 探一次活(共 36 次≈110s)："
DIED=0
for i in $(seq 1 36); do
  sleep 3
  AL=$(A get-state 2>/dev/null | grep -c device)
  if [ "$AL" = "0" ]; then
      echo "    t+$((i*3))s 掉线 ⇒ 先等它回来再取证(adb 掉与整机重启在这一刻分不出来)"
      DIED=1; break
  fi
  [ $((i % 6)) = 0 ] && echo "    t+$((i*3))s 在 脚印=$(S 'grep -acE "KSUBEAT (SU[0-9]|SD[0-9])" /data/local/tmp/dmesg.live' | tr -dc '0-9') 条"
done
if [ "$DIED" = 1 ]; then
  for q in $(seq 1 60); do sleep 5; [ -n "$(A get-state 2>/dev/null | grep device)" ] && break; done
  echo "    回来后: up=$(S 'cut -d\" \" -f1 /proc/uptime' | tr -dc '0-9') 模块=$(S 'lsmod | grep -c kernelsu' | tr -dc '0-9') enforce=$(S 'getenforce' | tr -d '\r\n')"
  echo "    ★模块=1 ⇒ 只是 adb 掉了(链还活着，判据照旧)；模块=0 且 up 很小 ⇒ 真发生了重启"
fi
echo "=== 5) 取证 ==="
# ★别把 SD* 和 SU* 混在一个 tail 里：满屏的 `SD1 decline: uid=0`(sushd 自己的 execve)会把窗口吃光，
#   看起来像"没有 SU 脚印"(ATT=1 就是这么差点判错)。分开捞，SU/X 才是这一格的判据。
S 'grep -aE "KSUBEAT (SU[0-9]|SU1[a-d]|X[0-9A-C]|F[AS][0-9a-z]?) " /data/local/tmp/dmesg.live | tail -26' >"$EV/w${ATT}_su_footprints.txt" 2>&1
S 'grep -acE "KSUBEAT SD[0-9]" /data/local/tmp/dmesg.live' >>"$EV/w${ATT}_su_footprints.txt" 2>&1
S 'grep -aE "sushd|SETPROF" /data/local/tmp/ksu_stage.log | tail -4' >>"$EV/w${ATT}_su_footprints.txt" 2>&1
S 'cat /data/local/tmp/w103_run.out 2>&1' >"$EV/w${ATT}_su_run.out" 2>&1
S 'grep -aE "SU-APP|arm=1 cmd=\[@su:" /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt 2>&1' >>"$EV/w${ATT}_su_run.out" 2>&1
S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' >>"$EV/w${ATT}_su_run.out" 2>&1
# ★单独存一份：check_su_app.sh 判"有没有走 reboot 口"只能看这一份(su_run.out 里还 cat 了别的 boot 的痕迹)
S 'cat /sdcard/Android/data/com.suw.manager/files/app_su.txt 2>&1' >"$EV/w${ATT}_app_su.txt" 2>&1
S 'grep -a "KSUBEAT SU[0-9]" /data/local/tmp/dmesg.live | tail -8' >>"$EV/w${ATT}_su_run.out" 2>&1
S 'for f in /data/local/tmp/w103_run.out.early /data/local/tmp/w103_run.out.late /data/local/tmp/w103_run67.out.early /data/local/tmp/w103_run67.out.late; do echo "--- $f ---"; cat $f 2>&1; done' >>"$EV/w${ATT}_su_run.out" 2>&1
S 'cat /data/local/tmp/w103_run67.out 2>&1' >>"$EV/w${ATT}_su_run.out" 2>&1
S 'grep -a "set root profile\|AP0 set_app_profile" /data/local/tmp/dmesg.live | tail -4' >>"$EV/w${ATT}_su_run.out" 2>&1
S 'cat /sdcard/Android/data/com.suw.manager/files/child.log 2>&1' >"$EV/w${ATT}_child.log" 2>&1
S 'cat /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt 2>&1' >"$EV/w${ATT}_app_report.txt" 2>&1
S 'tail -3 /data/local/tmp/ksu_stage.log' >>"$EV/w${ATT}_app_report.txt" 2>&1
echo "  --- 脚印(最后 18 条) ---"; tail -18 "$EV/w${ATT}_su_footprints.txt" | cut -c1-140 | sed 's/^/    /'
echo "  --- 触发结果 w103_run.out ---"; head -8 "$EV/w${ATT}_su_run.out" | sed 's/^/    /'
echo "  --- app 报告里的 arm 行 ---"; grep -aE "arm=1 cmd|判据①" "$EV/w${ATT}_app_report.txt" | tail -3 | sed 's/^/    /'
echo "  存证: $EV/w${ATT}_* (掉线=死点在脚印里；活着=看 child.log 有没有 uid=0)"
echo "  收尾: 真执行 adb reboot(以前这里**只打印不执行**，第 46 发因此把模块和 Permissive 留在了机上)"
S 'cd /data/local/tmp; rm -f domprint w147_dom.sh w147_dom2.sh w148_uid.sh w148_pkg1.txt w149_su_run.sh w149_su_run.out w135_fix.out w135_off.out w132_tuid.txt w155_mountwatch.sh w155_mwloop.sh w155_mw.out w154_mod.sh mod_module.prop mod_post-fs-data.sh mod_service.sh modsu.log w154_mod.out w154_kick; rm -rf pbin' >/dev/null
A reboot >/dev/null 2>&1
for i in $(seq 1 60); do sleep 5; [ -n "$(A get-state 2>/dev/null | grep device)" ] && break; done
for i in $(seq 1 30); do
  BC=$(S 'getprop sys.boot_completed' | tr -d '
')
  [ "$BC" = "1" ] && break
  sleep 10
done
sleep 20
echo "    收尾复核: $(S 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) 挂载=$(grep -c pbin /proc/self/mountinfo)')"
echo "    (mod=0 且 enf=Enforcing 才算回到出厂；不是就重来一次 adb reboot)"
