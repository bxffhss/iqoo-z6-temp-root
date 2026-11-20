/* ion_test.c — 只读打开的 /dev/ion 能否分配 (决定 dma-buf 来源) */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>
struct ion_allocation_data { unsigned long long len; unsigned int align; unsigned int heap_id_mask; unsigned int flags; int handle; unsigned int pad; };
#define ION_IOC_ALLOC _IOWR('I', 0, struct ion_allocation_data)
struct ion_fd_data { int handle; int fd; };
#define ION_IOC_MAP   _IOWR('I', 2, struct ion_fd_data)
#define ION_IOC_SHARE _IOWR('I', 4, struct ion_fd_data)
int main(void){
    int fd = open("/dev/ion", O_RDONLY);
    printf("open(/dev/ion, O_RDONLY) = %d errno=%d\n", fd, fd<0?errno:0);
    if (fd < 0) return 1;
    unsigned masks[] = {0, 1u, 2u, 0xffffffffu};
    for (unsigned i=0;i<sizeof(masks)/sizeof(masks[0]);i++){
        struct ion_allocation_data a; memset(&a,0,sizeof(a));
        a.len = 0x1000; a.align = 0x1000; a.heap_id_mask = masks[i]; a.flags = 0;
        errno=0; int r = ioctl(fd, ION_IOC_ALLOC, &a);
        printf("  ION_IOC_ALLOC mask=0x%08x -> ret=%d errno=%d handle=%d\n", masks[i], r, errno, a.handle);
        if (r==0 && a.handle>0){
            struct ion_fd_data f; memset(&f,0,sizeof(f)); f.handle=a.handle;
            errno=0; int r2=ioctl(fd, ION_IOC_SHARE, &f);
            printf("     ION_IOC_SHARE -> ret=%d errno=%d fd=%d\n", r2, errno, f.fd);
            struct ion_fd_data f2; memset(&f2,0,sizeof(f2)); f2.handle=a.handle;
            errno=0; int r3=ioctl(fd, ION_IOC_MAP, &f2);
            printf("     ION_IOC_MAP   -> ret=%d errno=%d fd=%d\n", r3, errno, f2.fd);
        }
    }
    close(fd);
    printf("done\n"); return 0;
}
