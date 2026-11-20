#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v47：给 suwksu_jni.c 加管理面两格(§6.76)。
   @mgr                 -> KSU_IOCTL_GET_MANAGER_APPID(manager_or_root，root 也能读)
   @setprof:<uid>:<0|1> -> KSU_IOCTL_SET_APP_PROFILE(perm_check=only_manager ⇒ 只有被 crown 的 app 打得开)
   插桩点：判据①(GET_INFO)之后、`if (!arm)` 之前 —— 这两格不该依赖 GRANT_ROOT，也不该改 cred。
   幂等：认自己加的锚点注释。
"""
import io
import sys

P = "suwksu_jni.c"
ANCHOR = "    /* v47(管理面) 锚点 */\n"
HOST = "    /* 未 arm = 只做无副作用的握手。★这里**不能**拿 GRANT_ROOT 当负对照：\n"

NEW = ANCHOR + """    if (cmd && !strncmp(cmd, "@mgr", 4)) {
        struct ksu_get_manager_appid_cmd ma;
        memset(&ma, 0, sizeof(ma));
        rc = ioctl(got, KSU_IOCTL_GET_MANAGER_APPID, &ma);
        rep("MGR GET_MANAGER_APPID: rc=%d errno=%d(%s) appid=%u  本任务 uid%%100000=%u ⇒ %s",
            rc, rc ? errno : 0, strerror(errno), ma.appid, (unsigned)(getuid() % 100000),
            (!rc && ma.appid == (unsigned)(getuid() % 100000)) ? "★本 app 就是 Manager" : "不是 Manager");
        rep("MGR 顺带看 GET_INFO 的 flags: MANAGER 位=1<<1 ⇒ 被 crown 时应当从 0xd 变 0xf");
        snprintf(summary, sizeof(summary), "status=0 mgr appid=%u", ma.appid);
        status = 0;
        goto done;
    }
    if (cmd && !strncmp(cmd, "@setprof:", 9)) {
        /* 形如 @setprof:<uid>:<0|1>。allow=1 抄 ksuctl build_profile() 那份**本机验过**的自填
         * profile(域=u:r:shell:s0；use_default=1 那条走不通，default 模板要解 u:r:ksu:s0)；
         * allow=0 只置 allow_su=false 走 non-root 支路 = 把这个 uid 从名单里摘掉。 */
        char argb[64], *p1, *p2;
        struct ksu_set_app_profile_cmd sp;
        struct ksu_uid_granted_root_cmd gc;
        long who;
        int allow;

        strcpy(argb, cmd + 9);
        p1 = strtok(argb, ":");
        p2 = strtok(NULL, ":");
        who = p1 ? strtol(p1, NULL, 0) : -1;
        allow = p2 ? (int)strtol(p2, NULL, 0) : -1;
        if (who < 0 || (allow != 0 && allow != 1)) {
            rep("SETPROF 参数不对: [%s] 要 <uid>:<0|1>", cmd);
            snprintf(summary, sizeof(summary), "status=9 setprof-bad-args");
            status = 9;
            goto done;
        }
        memset(&sp, 0, sizeof(sp));
        sp.profile.version = KSU_APP_PROFILE_VER;
        strcpy(sp.profile.key, "com.suw.manager");
        sp.profile.curr_uid = (__s32)who;
        sp.profile.allow_su = allow ? true : false;
        if (allow) {
            sp.profile.rp_config.use_default = false;
            sp.profile.rp_config.profile.uid = 0;
            sp.profile.rp_config.profile.gid = 0;
            sp.profile.rp_config.profile.groups_count = 1;
            sp.profile.rp_config.profile.groups[0] = 0;
            sp.profile.rp_config.profile.capabilities.effective = ~(__u64)0;
            sp.profile.rp_config.profile.namespaces = 0; /* KSU_NS_INHERITED */
            strcpy(sp.profile.rp_config.profile.selinux_domain, "u:r:shell:s0");
        } else {
            sp.profile.nrp_config.use_default = true;
        }
        rc = ioctl(got, KSU_IOCTL_SET_APP_PROFILE, &sp);
        rep("SETPROF uid=%ld allow=%d key=%s: rc=%d errno=%d(%s)", who, allow, sp.profile.key,
            rc, rc ? errno : 0, strerror(errno));
        memset(&gc, 0, sizeof(gc));
        gc.uid = (__u32)who;
        rc = ioctl(got, KSU_IOCTL_UID_GRANTED_ROOT, &gc);
        rep("SETPROF 之后内核回读 UID_GRANTED_ROOT uid=%ld: rc=%d granted=%u ⇒ 名单是**我们自己**改的",
            who, rc, gc.granted);
        snprintf(summary, sizeof(summary), "status=0 setprof uid=%ld allow=%d granted=%u", who,
                 allow, gc.granted);
        status = 0;
        goto done;
    }

"""


def main():
    s = io.open(P, encoding="utf-8").read()
    if ANCHOR in s:
        print("已经打过(v47 锚点在) ⇒ 跳过")
        return 0
    if s.count(HOST) != 1:
        print("!! 宿主锚点不唯一: %d" % s.count(HOST))
        return 1
    s = s.replace(HOST, NEW + HOST)
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("v47 已插入 @mgr / @setprof 两格")
    return 0


if __name__ == "__main__":
    sys.exit(main())
