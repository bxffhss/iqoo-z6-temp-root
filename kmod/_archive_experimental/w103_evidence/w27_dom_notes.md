# w27 存证(第 42/43 发 = ATT=25 的 #53 域判据)
# ★来源说明：这些文本是从终端读数**逐字转抄**的。设备侧原文件在收尾清理时被删，
#   驱动日志 `kmod/w103_att25b.log` 因为"同一份 w148_uid.out 被重复 cat"膨胀到 195MB，我也一并删了。
#   ⇒ 这一条是我自己的操作错误(先删了原始记录再整理结论)，留在这里当"证据链要早于清理"的反例。

## 一、整窗 Permissive(决定性)
    ===== W149-OFFLINE up=2169.02 enf=Permissive =====
    --- [0] .allowlist 还在不在(不在=内核本 boot 不会再读它 ⇒ 生成文件零副作用) ---
    ls: /data/adb/ksu/.allowlist: No such file or directory
    --- [1] 三种域各生成一份 profile，逐字节比较(只有 domain 那一段该变) ---
      mkallow[u:r:shell:s0] profile: use_default=0 uid=0 gid=0 caps=~0 ns=0 domain=u:r:shell:s0
      mkallow[u:r:kernel:s0] profile: use_default=0 uid=0 gid=0 caps=~0 ns=0 domain=u:r:kernel:s0
      mkallow[u:r:zzz_no_such_domain:s0] profile: use_default=0 uid=0 gid=0 caps=~0 ns=0 domain=u:r:zzz_no_such_domain:s0
    --- [2] 起点域(不加 su) ---
    u:r:kernel:s0   getenforce=Permissive
    --- [3] 目标 uid 现在的域与凭据(以 10667 起一个普通脚本，PATH 只给挂载点) ---
    ---- supath(uid=10667) 输出开始 ----
    SUPATH-START uid=10667 euid=10667 gid=10667 PATH=[/product/bin] ctx=u:r:kernel:s0
    uid=10667(u0_a667) gid=10667(u0_a667) groups=10667(u0_a667) context=u:r:kernel:s0
    ---- 输出结束 (read errno=0) ----
⇒ ① `mkallow` 对**不存在的域**照样生成、零校验 ⇒ 纯用户态**没有**证伪 SET_APP_PROFILE 的路；
   ② root 侧 agent 的起点域是 **u:r:kernel:s0**(不是我一直以为的 shell)；
   ③ 从 punch 那一刻起整窗 `enf=Permissive`(pr.c 的 sen 相把 selinux_state.enforcing 写成 0)，
      重启后才回 Enforcing ⇒ **窗口内 SELinux 不参与任何访问判定**。

## 二、内核侧对"域字符串"的处理(证伪器的正确形状)
    [ 2349.547513] KernelSU: KSUBEAT X2 profile: p=ffffffd26c826ad0 want_uid=10308 prof_uid=0 gid=0 groups_count=1 domain=u:r:ksu:s0
    [ 2349.547519] KernelSU: KSUBEAT X6 before setup_selinux: domain=u:r:ksu:s0
    [ 2349.547527] KernelSU: security_secctx_to_secid u:r:ksu:s0 -> sid: 0, error: -22
⇒ 内核确实拿我们填的字符串去 `security_secctx_to_secid`，解不开就打 -22 并**保持调用方的域**；
   这两条来自 want_uid=**10308**(=com.suw.manager，走 default_root_profile)，
   所以"@domsu 的两次换域"根本没进入"自填 profile"那条支路。

## 三、四态的实际读数(w27_dom0..dom3 的要点，原文在 kmod/w103_evidence/)
    dom0  uid=10308 context=u:r:untrusted_app:s0:c52,c257,c512,c768   CapEff=0000000000000000 Seccomp=2
    dom1  uid=0(root) groups=0(context 仍是 untrusted_app)            CapEff=0000003fffffffff Seccomp=0
    dom2  与 dom1 **完全相同**(域没变，虽然第二轮 setprof 填的是 kernel)
    dom3  与 dom1 **完全相同**(撤名单之后照样 uid=0)
    每一份的"域鉴别器"七行全部是：
    /data/local/tmp/w147_dom.sh[29]: fc: history functions not available
⇒ 三个独立的错，各自都足以作废这一发：
   ① `r()` 撞 mksh 的预定义别名 `r`(=`fc -e -`) ⇒ 鉴别器**一行都没跑**，而 WHO/CTX 照常输出；
   ② setprof 打的是**假 uid**(见下)，两轮"换域"打在不存在的人身上；发起者又是 Manager 自己，
      它永远走 default 模板 ⇒ 就算 uid 对，dom1/dom2 也不会显示自填域；
   ③ dom3 出 uid=0 不是"撤名单失效"，而是**Manager 本身就有 root**(它是 manager uid，不需要名单)。

## 四、uid 反查的错误(第二处"判据自己骗自己")
    LOOKUP com.termux rc=0 uid=[10667
     10817] seinfo=[/data/user/0/com.termux] ctx=[com.android.packageinstaller
     10817]
    写回 w132_tuid.txt = [10667
     10817]
⇒ `grep "^com.termux "` 在这台机上命中**两行**(10667 与 10817)，awk 把两个 uid 都吐出来，
   PC 侧 `tr -dc 0-9` 把它们拼成 `1066710817` ⇒ 一个不存在的 uid。修法：`grep -am1` + "必须是单行纯数字"校验，
   不过就 `exit`，不许带假 uid 往下打。

## 五、窗口末尾的资源异常(未定成因)
    [B] 判据：同一个 uid 加 su ⇒ `can't fork - try again`  (up=2358)
    随后设备从 USB 总线上消失(Get-PnpDevice 计数=0)，回来时 up=72s/mod=0 ⇒ 中间发生过一次重启
    (驱动打印过"收尾: adb reboot"，但当时我判定它没生效——两件事的顺序没能定死)。
⇒ 只记录现象，不猜成因：`can't fork` 与"我这一发连着打了多少次 fire/@sushd"有没有关系，需要新的判据。
