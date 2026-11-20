/* gsl_dlopen.c — 验证能否 dlopen libgsl.so 并解析 ioctl_kgsl_* 包装函数 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>

int main(void) {
    const char *paths[] = {"/vendor/lib64/libgsl.so", "libgsl.so"};
    void *h = NULL;
    for (int i = 0; i < 2 && !h; i++) {
        h = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        printf("dlopen(\"%s\") -> %p  %s\n", paths[i], h, h ? "OK" : dlerror());
    }
    if (!h) return 1;

    const char *fns[] = {
        "gsl_library_version", "gsl_device_open", "gsl_context_create",
        "ioctl_kgsl_gpuobj_import", "ioctl_kgsl_gpu_command",
        "ioctl_kgsl_gpu_signal_aux_command", "ioctl_kgsl_context_create",
        "ioctl_kgsl_gpumem_get_info", "ioctl_kgsl_device_getproperty",
        "gsl_memory_alloc_pure", "gsl_command_issueib_sync",
    };
    for (unsigned i = 0; i < sizeof(fns)/sizeof(fns[0]); i++) {
        void *p = dlsym(h, fns[i]);
        printf("  %-38s -> %p\n", fns[i], p);
    }
    /* 安全试跑: gsl_library_version 通常无参 */
    void *pv = dlsym(h, "gsl_library_version");
    if (pv) {
        unsigned int (*fn)(void) = (unsigned int (*)(void))pv;
        printf("\n调用 gsl_library_version() = 0x%x\n", fn());
    }
    printf("done alive\n");
    return 0;
}
