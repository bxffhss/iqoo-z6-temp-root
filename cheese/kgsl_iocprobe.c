/* kgsl_iocprobe.c — 用零填充缓冲逐个探测 kgsl 全部 ioctl(cmd 取自内核镜像分发表)
 * 判据: 返回 errno 区分"未实现/未授权/参数校验通过"
 *   ENOTTY(25)/ENOSYS → 未实现   EINVAL(22) → 已实现但参数被拒
 *   EFAULT(14)/EPERM(1)/EACCES  → 已实现且走到了更深路径
 * 零填充通常触发早期校验, 风险低
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

struct ent { unsigned int cmd; unsigned int size; unsigned char nr; const char *name; };
/* 来自 analysis/kgsl_ioctl_table.txt (native 表) */
static struct ent T[] = {
 {0xc0180902,24,0x02,"DEVICE_GETPROPERTY"},
 {0x400c0907,12,0x07,"WAITTIMESTAMP_CTXTID"},
 {0xc0200910,32,0x10,"ISSUEIBCMDS"},
 {0xc0080913, 8,0x13,"DRAWCTXT_CREATE"},
 {0x40040914, 4,0x14,"DRAWCTXT_DESTROY"},
 {0xc0300915,48,0x15,"MAP_USER_MEM"},
 {0xc00c0916,12,0x16,"SHAREDMEM_FROM_PMEM"},
 {0x40180917,24,0x17,"SHAREDMEM_FREE"},
 {0xc0180920,24,0x20,"?"},
 {0x40080921, 8,0x21,"?"},
 {0x40080924, 8,0x24,"?"},
 {0xc018092f,24,0x2f,"?"},
 {0x40180932,24,0x32,"SETPROPERTY"},
 {0xc0200933,32,0x33,"?"},
 {0xc0300934,48,0x34,"?"},
 {0xc0080935, 8,0x35,"?"},
 {0xc0480936,72,0x36,"?"},
 {0x40200937,32,0x37,"?"},
 {0xc018093c,24,0x3c,"GPUOBJ_ALLOC"},
 {0xc038093d,56,0x3d,"GPUOBJ_IMPORT"},
 {0xc0100940,16,0x40,"GPUOBJ_INFO"},
 {0xc0100941,16,0x41,"GPUOBJ_SET_INFO"},
 {0xc0180942,24,0x42,"GPUOBJ_FREE"},
 {0xc0180943,24,0x43,"GPUOBJ_SYNC"},
 {0xc0300945,48,0x45,"SYNCOBJ_CREATE"},
 {0x40200946,32,0x46,"SYNCOBJ_DESTROY"},
 {0xc0300947,48,0x47,"SYNCOBJ_SIGNAL"},
 {0xc0200948,32,0x48,"SYNCOBJ_WAIT"},
 {0x40100949,16,0x49,"TIMELINE"},
 {0xc040094a,64,0x4a,"GPU_COMMAND"},
 {0x4020094c,32,0x4c,"SUBMIT_COMMANDS"},
 {0xc0200950,32,0x50,"PERFCOUNTER_GET"},
 {0x40040951, 4,0x51,"PERFCOUNTER_PUT"},
 {0xc0280952,40,0x52,"PERFCOUNTER_QUERY"},
 {0x40040953, 4,0x53,"PERFCOUNTER_READ"},
 {0x40180954,24,0x54,"?"},
 {0xc0380955,56,0x55,"GPUOBJ_SET_INFO_EXT"},
 {0xc0300957,48,0x57,"?"},
 {0xc0100958,16,0x58,"?"},
 {0x40280959,40,0x59,"?"},
 {0xc010095a,16,0x5a,"?"},
 {0x4010095b,16,0x5b,"?"},
 {0xc010095c,16,0x5c,"?"},
 {0x4004095d, 4,0x5d,"?"},
};

int main(void) {
    int fd = open("/dev/kgsl-3d0", O_RDWR);
    if (fd < 0) { printf("open fail errno=%d\n", errno); return 1; }
    unsigned char buf[256];
    printf("nr    cmd         size  ret  errno  名称\n");
    for (unsigned i = 0; i < sizeof(T)/sizeof(T[0]); i++) {
        memset(buf, 0, sizeof(buf));
        errno = 0;
        int r = ioctl(fd, T[i].cmd, buf);
        int e = errno;
        printf("0x%02x  0x%08x  %4d  %3d  %-5d  %s%s\n", T[i].nr, T[i].cmd, T[i].size, r, e,
               T[i].name,
               (e==25||e==38) ? "  ← 未实现" : (e==1 ? "  ← EPERM(拒绝)" : ""));
        fflush(stdout);
    }
    close(fd);
    printf("done alive\n");
    return 0;
}
