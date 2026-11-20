# kgsl handler 静态审计 —— 第 2 批(2026-09-17, §CN)

## 方法升级: 系统性扫描
- `kgsl_dis.asm` = kgsl 代码段(0x10a70000-0x10ab0000)完整反汇编(6.7 万行)
- `kgsl_triage.txt` = 自动分级: 对每个 kgsl_* 函数里所有 `_copy_from_user` / `kcalloc/kvmalloc/vmalloc/kmalloc_array/kmem_cache_alloc`
  调用点, 检查前 24 条内是否存在"常量比较 + 条件分支"; 无则标 `!!!` 需人工确认
- 结果: 44 个函数含敏感调用, 其中多数 `kmem_cache_alloc_trace` 的 `!!!` 是误报(定长分配)

## 已审(第 2 批)
### kgsl_ioctl_gpu_aux_command @ 0xffffffc010a78390 (0x57)
- `numcmds == 1`(强制); `flags` 必须含 bit1; bit10 时 `numobjs ≤ 0x20`
- `context_id @0x28`(48B 结构, 与 gpu_command 的 0x38 不同); `kgsl_context_get` + 设备匹配
- 未见未校验的计数 → 与 gpu_command 同等严格

### kgsl_drawobj_sync_add_synclist @ 0xffffffc010a840b4
- 校验: list!=NULL / w23!=0 / w19!=0 (否则 EINVAL)
- `kcalloc(w19, 0x80)` → 数组容量 = w19 项
- 循环恰好 w19 次; 每轮 `w23 = min(w23, 0x18)`; `_copy_from_user(栈24B缓冲, user_ptr, w23)`; 用户指针步进 0x18
  → **拷贝长度与步距都是 ≤24, 栈缓冲 24B** ✓ 自洽
- 栈保护 ✓

### kgsl_drawobj_cmd_add_cmdlist / _add_memlist / _sync_add_syncpoints / _add_timeline
- 已进 triage 清单, 结构与 synclist 同族(容器+循环+copy_from_user), 初步看计数与分配一致
- **下一步需逐条核对"循环次数 vs 数组容量 vs 用户指针步距"三者是否一致**(本批只完成 synclist)

## 扫描清单里剩余高优先项(待第 3 批)
| 函数 | 可疑点 |
|---|---|
| `kgsl_ioctl_gpuobj_set_info` | copy_from_user(metadata 路径) |
| `kgsl_ioctl_gpuobj_free` | copy_from_user |
| `kgsl_ioctl_gpuobj_sync` | kcalloc + kcalloc + copy_from_user |
| `kgsl_drawobj_sync_add_synclist` | 已审 ✓ |
| `kgsl_drawobj_sync_add_syncpoints` | kcalloc + 2×copy_from_user |
| `kgsl_drawobj_cmd_add_memlist` | copy_from_user |
| `kgsl_drawobj_add_timeline` | 2×copy_from_user + kvmalloc |
| `kgsl_ioctl_gpu_aux_command` | kvmalloc_node + copy_from_user(已审主体) |
| `kgsl_pool_alloc_pages` / `kgsl_system_alloc_pages` | kvmalloc_node(size 驱动, 属分配器本身) |
| 快照类 `kgsl_snapshot_*` | vmalloc/kmem_cache(内核侧触发, 非用户直控) |

## 汇总判断(第 1+2 批)
- 已审 6 个核心路径, **全部在"计数/长度→分配/拷贝"上自洽**
- 该驱动(SPL 2025-04)对经典整数/越界类问题防护完备
- 剩余概率较高的方向: ①drawobj 列表族的**循环/容量/步距一致性**逐条核对(尚有 4 个未做)
  ②**对象生命周期(UAF)**: kgsl_mem_entry 引用计数、context 销毁与提交竞争
  ③timeline/syncobj 的引用计数与 fence 回调
