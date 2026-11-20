/* suwprobe.c — 阶段 0/1 探针：**不借内核构建树**手工造出来的最小外部 .ko
 *
 * 判据链(每一步都是真机上撞出来的，别再退回去)：
 *   1) 缺 .modinfo 的 vermagic            -> EINVAL/ENOEXEC 各种形态
 *   2) 缺 .gnu.linkonce.this_module       -> "No module found in object" + ENOEXEC(8)
 *   3) 缺 .plt / .init.plt / .text.ftrace_trampoline
 *                                          -> "module PLT section(s) missing" + ENOEXEC(8)
 *      (arch/arm64/kernel/module-plts.c: module_frob_arch_sections 只认**段名**，
 *       内容它自己重写成 SHT_NOBITS 并按它数出来的条目分配)
 *   4) this_module 里 mod->name 是空的     -> kobject "empty name" WARNING + EINVAL(22)
 *      (内核 load_module() 全程不给 mod->name 赋值，它就用我们镜像里这一份)
 *   5) this_module 里 mod->init 是 NULL    -> **init 被静默跳过**：模块 Live、能卸载，
 *      但代码一行没跑(2026-09-30 就是这么"看起来成功了")
 *   6) 模块没有 __cfi_check 这个符号       -> 内核调我们函数的瞬间走
 *      kernel/cfi.c: cfi_slowpath_handler(){ check=find_cfi_check(ptr);
 *      if (check) check(...); else handle_cfi_failure(ptr); }  ⇒ 本机
 *      CONFIG_CFI_CLANG=y 且 CONFIG_CFI_PERMISSIVE 未开 ⇒ 直接 panic。
 *      ★所以 __cfi_check 必须**由模块自己提供**，而它是"我们自己被叫到的那个校验函数"
 *      —— 我们返回 = 放行。这就是这台 kCFI 内核允许自研模块被调用的唯一入口。
 *
 * struct module 里字段的偏移全部从厂商 -qgki .ko 量出来(asix/boardinfo/adsp_loader 三个一致)：
 *   name = 24 (char[56])   init = 392 (int(*)(void))   exit = 888 (void(*)(void))   总大小 960
 * 我们只填这三个字段，其余留 0 ⇒ **不需要知道结构体布局**，只要偏移对得上。
 */

#define VERMAGIC "5.4.281-qgki-g2a88cd145def SMP preempt mod_unload modversions aarch64"

#define MODINFO(tag, val) \
  __asm__(".pushsection .modinfo,\"a\"\n\t" \
          ".asciz \"" tag "=" val "\"\n\t" \
          ".popsection\n")

/* 一条 __versions 记录：8 字节 crc + 56 字节名字(补 0) = 64，crc 在前 */
#define VERSYM(nm, crc) \
  __asm__(".pushsection __versions,\"a\"\n\t" \
          ".balign 8\n\t" \
          ".quad " #crc "\n\t" \
          "1:\n\t" \
          ".asciz \"" #nm "\"\n\t" \
          ".zero 56 - (. - 1b)\n\t" \
          ".popsection\n")

MODINFO("vermagic", VERMAGIC);
MODINFO("license", "GPL");
MODINFO("description", "suw stage0/1 probe");
MODINFO("name", "suwprobe");
MODINFO("depends", "");
MODINFO("srcversion", "SUWSTAGE0000000000000AA");

/* 见文件头第 3 条：三个段名必须在，内容内核自己重写(厂商 .ko 里就是 size=1) */
__asm__(".pushsection .plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .init.plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .text.ftrace_trampoline,\"ax\"\n\t.byte 0\n\t.popsection\n");

VERSYM(module_layout, 0xb7b3a75c);
VERSYM(printk, 0xc5850110);

extern int printk(const char *fmt, ...);

__attribute__((section(".init.text"), noinline))
int init_module(void) {
  printk("suwprobe: stage0 init 真的跑了(自研 .ko + 离线 CRC 表 + 自带 __cfi_check)\n");
  return 0;
}

__attribute__((section(".exit.text"), noinline))
void cleanup_module(void) {
  printk("suwprobe: stage0 exit\n");
}

/* kCFI：内核通过 cfi_slowpath_handler 调**模块自己的** __cfi_check(id, ptr, diag)。
 * 我们什么都不校验直接返回 = "这个调用合法"。签名必须与 include/linux/cfi_types.h 里
 * typedef void (*cfi_check_fn)(uint64_t id, void *ptr, void *diag) 一致(三个参数)。 */
void __cfi_check(unsigned long long id, void *ptr, void *diag) {
  (void)id; (void)ptr; (void)diag;
}

/* struct module 的**部分覆盖**：只声明我们关心的三个字段，其余用 padding 顶过去。
 * 编译器会为 .init/.exit 生成 R_AARCH64_ABS64 重定位(厂商 .ko 里正是这两种符号：
 * init_module.cfi_jt / cleanup_module.cfi_jt) ⇒ 内核 apply_relocations 时填真地址。 */
struct suw_this_module {
  char pad0[24];
  char name[56];
  char pad1[392 - 80];
  int (*init)(void);
  char pad2[888 - 400];
  void (*exit)(void);
  char pad3[960 - 896];
};

__attribute__((section(".gnu.linkonce.this_module"), aligned(64)))
struct suw_this_module __this_module = {
  .name = "suwprobe",
  .init = init_module,
  .exit = cleanup_module,
};
