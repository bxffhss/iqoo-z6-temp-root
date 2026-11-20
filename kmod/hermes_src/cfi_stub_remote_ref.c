/* cfi_stub.c — 给"用非 CFI 编译器编出来的外部模块"补上内核要的那个 `__cfi_check`。
 *
 * 为什么必须有：本机内核 `CONFIG_CFI_CLANG=y`(老式 clang CFI) + `CFI_CLANG_SHADOW=y` +
 * **非 permissive**。内核 kernel/cfi.c 的 `cfi_slowpath_handler()` 对**模块里的目标**用的是
 * `mod->cfi_check`，而它由 `cfi_init()` 从模块符号表里按名字找 `__cfi_check` 得到：
 *     check = find_cfi_check(ptr);
 *     if (check) check(id, ptr, diag);
 *     else handle_cfi_failure(ptr);        <-- 没有这个符号 = 当场判定违规 = panic
 * 我们的模块不是用同款 clang/CFI 编的（拿不到厂商源码，树算出的 struct module 都对不上），
 * 所以**由我们自己提供这个校验函数，并且直接放行**。
 * 2026-09-30 真机已验证：带这个桩的手搓模块，内核调用其 init 成功并打出 printk。
 *
 * 签名必须与 include/linux/cfi_types.h 的
 *   typedef void (*cfi_check_fn)(uint64_t id, void *ptr, void *diag);
 * 一致（三个参数），否则内核传进来的参数会错位。
 *
 * 用法：任何 kbuild 外部模块都要把它一起编进去 ——
 *   Makefile 里写  obj-m += 你的模块.o cfi_stub.o
 * （若将来真的换成"同款 clang + CFI"构建，clang 会自己生成 __cfi_check，那时**不要**再带这个桩，
 *   否则符号重复。）
 */
#include <linux/export.h>
#include <linux/types.h>

void __cfi_check(uint64_t id, void *ptr, void *diag)
{
	/* accept-all：本模块被内核间接调用时的 CFI 校验由我们自己说了算 */
	(void)id;
	(void)ptr;
	(void)diag;
}
