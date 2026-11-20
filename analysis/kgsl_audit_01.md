# kgsl handler 静态审计 —— 第 1 批(2026-09-17, §CM)
工具: `llvm-objdump -d --start-address=<符号地址> vmlinux.elf` (符号来自 vmlinux-to-elf)
地址: kgsl ioctl handler 集中在 0xffffffc010a7xxxx-0x10aaxxxx

## 1) kgsl_ioctl_gpu_command @ 0xffffffc010a78054  ★已审
参数结构(64B)偏移**与我们的 adrenaline.h 完全一致**(强验证):
```
@0x00 flags(u64) | @0x08 cmdlist | @0x10 cmdsize | @0x14 numcmds
@0x18 objlist | @0x20 objsize | @0x24 numobjs
@0x28 synclist | @0x30 syncsize | @0x34 numsyncs
@0x38 context_id | @0x3c timestamp
```
校验(全部有界):
- `numcmds ≤ 0x186a0 (100000)` → 否则 EINVAL
- `numobjs ≤ 0x186a0` → 否则 EINVAL
- `numsyncs ≤ 0x20 (32)` → 否则 EINVAL
- `kgsl_context_get(context_id)` 且 `ctx->device == 本设备` → 否则 EINVAL
- 栈保护 (__stack_chk_guard)
结论: 计数类校验完备, 未见 OOB

## 2) kgsl_ioctl_gpumem_sync_cache_bulk @ 0xffffffc010a7af04  ★已审
- `id_list != NULL`; `1 ≤ count ≤ 0x400`(sub 1; cmp 0x3ff; b.ls)
- `kcalloc(count,4)` + `kcalloc(count,8)`; `copy_from_user(buf, id_list, count*4)`
结论: count 有界且分配/拷贝一致 ✓

## 3) kgsl_ioctl_gpuobj_alloc @ 0xffffffc010a7bc60 + gpumem_alloc_entry + kgsl_allocate_user  ★已审
- `ldp x1,x2,[x2]` → gpumem_alloc_entry(dev, size, flags)
- metadata: `min(metadata_len, 0x40)` 拷贝到 entry+0xf4, 失败则 memset 0x41 → **有界** ✓
- `gpumem_alloc_entry`: `size != 0` 校验; flags 掩码校验; → kgsl_allocate_user
- `kgsl_allocate_user` → [dev+0x60]==1 ? kgsl_alloc_contiguous : kgsl_alloc_pages
- `kgsl_alloc_pages`: `x19 = PAGE_ALIGN(size) = (size + 0xfff) & ~0xfff`;
  **检查 `x19 != 0`(即 PAGE_ALIGN(size) 回绕为 0 → EINVAL)**; memdesc->size = x19(对齐值) 与传给
  `kgsl_pool_alloc_pages(x19, ...)` **一致** ✓ (无"分配小/mapping 大"的错配)
结论: 无未校验的上界, 但注意**没有最大 size 限制**(超大 size 由内存分配失败兜底)

## 4) kgsl_ioctl_gpuobj_import @ 0xffffffc010a79ce0 + kgsl_setup_useraddr + memdesc_sg_virt  ★已审
- `[x2+0x18]` = type, `(type & ~1) == 2` → 仅 {2,3}, 否则 **-524(ENOTSUPP)**
- 分配 368B mem_entry + 引用计数
- type=2(用户地址): `priv_len` clamp 到 8 用于 copy_from_user 取值(栈缓冲 8B)✓;
  **但把原始 64 位 priv_len 作为 len 传给 kgsl_setup_useraddr**
  - `kgsl_setup_useraddr`: useraddr 非 0 + **页对齐**; `find_vma` 必须存在;
    `vma->vm_ops` 命中 drm_gem_shmem 相关 ops → **主动拒绝**(-EFAULT/-EINVAL);
    `len != 0` 且 **页对齐**; `memdesc->size = len`; flags bit28 → kgsl_mmu_set_svm_region(dev,useraddr,len)
  - `memdesc_sg_virt`: `npages = size>>12`; `kvmalloc(npages*8)`; `get_user_pages(addr, npages, ...)`;
    `end = size + addr` 有**防回绕检查**; 分配数/pin 数一致; `ret != npages → EINVAL`
  - type=3(fd): `dma_buf_get(fd)` → `dma_buf_get_flags` → `kgsl_setup_dma_buf`; 出错 `dma_buf_put`
结论: len 只校验"非零+页对齐"**无上界**, 但下游分配/pin 数量一致, 未发现错配; 需 dma-buf fd 才能走 type=3

## 小结(第 1 批)
已审 4 个高危 handler, **经典的"计数/长度未校验"与"分配-映射错配"两类问题均未发现**;
该驱动(2025-04 补丁级)在计数校验上相当完备。
下一步候选: gpu_signal_aux_command(1416B)/gpu_aux_command、gpuobj_set_info(metadata)、
timeline_*(create/wait/signal)、gpumem_get_info、以及 kgsl_mem_entry/共享内存生命周期(UAF 面)。
