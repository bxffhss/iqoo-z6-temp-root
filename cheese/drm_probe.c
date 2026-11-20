/* drm_probe.c — 子系统可达性枚举: DRM 设备身份 + 各世界可读节点 open 测试   §CU
 *
 * 起因: /dev 枚举发现 /dev/dri/card0 与 /dev/dri/renderD128 都是 crw-rw-rw- (全体可读写),
 *       而此前项目记录认定"只有 kgsl 实质可达" —— 需要核实 /dev/dri 背后是谁、能做什么。
 *       另: adsprpc-smd (fastrpc) / goodix_fp / chipone_fp / iio:device0 / ion / membuf 都有 other 位。
 *
 * 安全: 只做 open + 只读查询类 ioctl(VERSION/GET_CAP), 不做任何写操作。
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>

/* 手工构造 _IOWR: (3<<30)|(size<<16)|(type<<8)|nr  ——坑清单#1: Bionic 用 sizeof(X) */
#define IOWR(t, nr, sz) ((unsigned long)((3u<<30)|((sz)<<16)|(((t)&0xff)<<8)|((nr)&0xff)))
#define IOW_(t, nr, sz) ((unsigned long)((1u<<30)|((sz)<<16)|(((t)&0xff)<<8)|((nr)&0xff)))
#define IOR_(t, nr, sz) ((unsigned long)((2u<<30)|((sz)<<16)|(((t)&0xff)<<8)|((nr)&0xff)))

#define DRM_IOCTL_VERSION   IOWR('d', 0x00, 0x40)
#define DRM_IOCTL_GET_CAP   IOWR('d', 0x0c, 0x10)
#define DRM_IOCTL_GET_UNIQUE IOWR('d', 0x01, 0x10)

struct drm_version {
    int major, minor, patchlevel;
    unsigned long name_len;   void *name;
    unsigned long date_len;   void *date;
    unsigned long desc_len;   void *desc;
};
struct drm_get_cap { unsigned long long capability; unsigned long long value; };

static void tryopen(const char *p, int flags) {
    errno = 0;
    int f = open(p, flags);
    printf("  %-28s flags=0x%x -> %s  errno=%d\n", p, flags,
           f >= 0 ? "OPEN-OK" : "FAIL", errno);
    if (f >= 0) close(f);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 子系统可达性枚举 ===\n");

    printf("\n== 1) 世界可读/可写节点的 open 测试 ==\n");
    const char *nodes[] = {
        "/dev/dri/card0", "/dev/dri/renderD128",
        "/dev/adsprpc-smd", "/dev/adsprpc-smd-secure",
        "/dev/goodix_fp", "/dev/chipone_fp",
        "/dev/ion", "/dev/membuf", "/dev/iio:device0",
        "/dev/kgsl-3d0", "/dev/ashmem", "/dev/kmsg",
        "/dev/uhid", "/dev/uinput", "/dev/ptmx",
        "/dev/adspinfo", "/dev/apr_apps2", "/dev/fastrpc-cdsp", "/dev/fastrpc-adsp",
    };
    for (unsigned i = 0; i < sizeof(nodes)/sizeof(nodes[0]); i++) {
        tryopen(nodes[i], O_RDWR);
        tryopen(nodes[i], O_RDONLY);
    }

    printf("\n== 2) /dev/dri/card0 身份查询 ==\n");
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { printf("  open 失败 errno=%d\n", errno); }
    else {
        char nbuf[128], dbuf[128], sbuf[256];
        struct drm_version v;
        memset(&v, 0, sizeof(v)); memset(nbuf,0,sizeof(nbuf));
        memset(dbuf,0,sizeof(dbuf)); memset(sbuf,0,sizeof(sbuf));
        v.name_len = sizeof(nbuf)-1; v.name = nbuf;
        v.date_len = sizeof(dbuf)-1; v.date = dbuf;
        v.desc_len = sizeof(sbuf)-1; v.desc = sbuf;
        errno = 0;
        int r = ioctl(fd, DRM_IOCTL_VERSION, &v);
        printf("  DRM_IOCTL_VERSION ret=%d errno=%d\n", r, errno);
        printf("    version=%d.%d.%d\n", v.major, v.minor, v.patchlevel);
        printf("    name='%s'  date='%s'\n", nbuf, dbuf);
        printf("    desc='%s'\n", sbuf);

        unsigned long long caps[] = {
            0x01 /*DUMB_BUFFER*/, 0x02 /*VBLANK_HIGH_CRTC*/, 0x07 /*PRIME*/,
            0x0d /*TIMESTAMP_MONOTONIC*/, 0x14 /*SYNCOBJ*/, 0x15 /*TIMELINE_SYNC*/,
            0x11 /*ADDFB_MODIFIER*/
        };
        const char *cn[] = {"DUMB_BUFFER","VBLANK_HIGH_CRTC","PRIME(0x07)",
                            "TIMESTAMP_MONO(0x0d)","SYNCOBJ(0x14)","TIMELINE_SYNC(0x15)","ADDFB_MODIFIER(0x11)"};
        for (unsigned i = 0; i < sizeof(caps)/sizeof(caps[0]); i++) {
            struct drm_get_cap c; c.capability = caps[i]; c.value = 0;
            errno = 0;
            int rr = ioctl(fd, DRM_IOCTL_GET_CAP, &c);
            printf("    GET_CAP %-22s ret=%d errno=%d value=%llu\n",
                   cn[i], rr, errno, c.value);
        }
        close(fd);
    }

    printf("\n== 3) /dev/dri/renderD128 ==\n");
    fd = open("/dev/dri/renderD128", O_RDWR);
    if (fd < 0) printf("  open 失败 errno=%d\n", errno);
    else { printf("  open OK\n"); close(fd); }

    printf("\n=== 完成 ===\n");
    return 0;
}
