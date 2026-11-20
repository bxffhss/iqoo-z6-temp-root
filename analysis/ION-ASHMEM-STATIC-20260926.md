# ION / ASHMEM Static Analysis — iQOO Z6 (SM7325, 5.4.281-qgki, Android 14)

Artifacts: `C:\qemu_test\vmlinux_full.asm`, symbol table, `Image`.
Config `/proc/config.gz` IS readable from `untrusted_app`: `CONFIG_ION=y`, `CONFIG_ASHMEM=y`, no `CONFIG_DMABUF_HEAPS` (legacy ION, not the heap framework). So `/dev/ion` and `/dev/ashmem` are the real in-tree drivers, not stubs/shims.

## 结论 (per surface)
- **`/dev/ion` — CONDITIONAL LIVE.** Unprivileged app CAN allocate a dma-buf; no `capable()`, no `FMODE_WRITE`, no client/uid/SELinux gate exists in the handler. Blocker is purely ioctl-numbering: correct call is `_IOWR('I',0,24)` = **0xc0184900** with a **24-byte** struct `{u64 len; u32 heap_id_mask; u32 flags; u32 fd_out}` and a **valid non-secure heap_id_mask** (obtain via heap-query first). The app's probe used standard `sizeof(ion_allocation_data)=32`-class sizes → rejected at the `size>24` gate → EINVAL.
- **`/dev/ashmem` — LIVE but renumbered (vendor magic 'w'=0x77, not 'A'=0x41).** All standard `ASHMEM_*` (type 'A') fall to the dispatch default → ENOTTY. mmap returns EINVAL only because size==0 (SET_SIZE never succeeded). Correct SET_SIZE = **0x40087703** (size passed in the ioctl arg itself); after that mmap is reachable. One ioctl (garbage-collect) is `capable(CAP_SYS_ADMIN)`-gated → EPERM for apps.
- **fops wiring (Q3):** `/dev/ion`→`ion_fops` (only `.unlocked_ioctl=ion_ioctl` observed; **no `ion_open`/`ion_release`/`ion_compat` symbols exist** — a stripped fops). `/dev/ashmem`→`ashmem_fops` (`.open,.release,.read_iter,.llseek,.unlocked_ioctl,.compat_ioctl,.mmap,.show_fdinfo`; NO `.write/.write_iter`; shmem/`vmfile`-backed variant).

## 证据 (address-level)

### ion_ioctl @ 0xffffffc010edea68
Top gate (size, not nr, is checked first):
```
edea90 ubfx w20,w1,#16,#14   ; w20 = _IOC_SIZE(cmd)
edea94 cmp  w20,#0x18         ; >24 ?
edeaa4 b.ls edeab0            ; size<=24 -> continue
edeaa8 mov  x0,#-22           ; else -EINVAL   <-- app's EINVAL source
...copy_from_user(kbuf=sp+0x8, arg, size)   (edeac4/edeacc)
```
Dispatch = compare of the FULL cmd, only 3 accepted values; **default is -ENOTTY(-25)**, not EINVAL:
```
edeb1c cmp w21,#0xc0184908 ; _IOWR('I',8,24) -> heap-query path (edec14: memset 0x34 desc, strncpy names, copy_to_user)
edeb80 w8=0x80044909        ; _IOR('I',9,4)  (edebcc: returns value 2)
edeb90 w8=0xc0184900        ; _IOWR('I',0,24) = ALLOC
edeb9c b.ne edebdc -> mov x0,#-0x19 (-ENOTTY)   <-- unmatched small cmds
```
ALLOC (edeba0..):
```
edeba4 ldr x1,[sp,#0x8]   ; len   (8B @ kbuf+0)
edeba8 ldp w2,w3,[sp,#0x10]; heap_id_mask @kbuf+8, flags @kbuf+12   <-- NOTE: mask right after len (no align field)
edebac ldr x0,[..#0xe10]    ; global ion_device
edebb0 bl ion_dmabuf_alloc(x0,x1len,x2mask,x3flags)
edebb8 cmn x0,#0x1,lsl#12 ; IS_ERR -> return PTR_ERR (e.g. -EINVAL for heap_id_mask=0/bad)
edebe4 bl dma_buf_fd(..,#0x80000=O_CLOEXEC) ; fd -> kbuf+16
```
No deref of x0(filp): confirms no client/`f_mode`/capability check.

### ashmem_ioctl @ 0xffffffc010eee780
```
eee7b0 mov x22,#-0x19            ; default = -ENOTTY
eee7f8.. b.ne eeeec2c            ; every unmatched cmd -> x22 = -ENOTTY
eee7bc w8=0x40087702  (type 0x77 'w', size 8)   <-- NOT 'A' (0x41)
```
Accepted cmds all use **type 0x77**: SET_SIZE 0x40087703 (0xeeeac0: `str x20(arg),[x19,#0x128]` — size taken from ioctl arg directly), SET_PROT 0x40087705 (`str x20,[x19,#0x130]`), SET_NAME 0x41007701 (`strncpy_from_user` len 0x100), GET_NAME 0x81007702, PIN/UNPIN ~0x40087707..09 (`kmem_cache_alloc ashmem_range_cachep [x23,#0x1d8]`, calls ashmem_pin/unpin). Gated: `0xeeea8c mov w0,#0x15; bl capable` (CAP_SYS_ADMIN) else `mov x22,#-1` (EPERM). compat (`0xeeece4`) rewrites 0x40047703/7705 -> 0x40087703/7705 (4->8B), still type 'w'.

### ashmem_mmap @ 0xffffffc010eeed38 — explains EINVAL
```
eeed64 ldr x8,[x23,#0x128]      ; area->size
eeed68 cbz x8, eeed84
eeed84 mov w21,#-0x16           ; size==0 -> -EINVAL   (SET_SIZE never ran -> EINVAL)
```
No ftruncate path (misc device; size only via ioctl). read-only (read_iter/llseek, no write_iter).

## 下一步可行的黑盒测试 (≤3)
1. ION: on the O_RDONLY `/dev/ion` fd, `ioctl(fd,0xc0184908,buf)` (size-24 heap_query) to enumerate heap ids; then `ioctl(fd,0xc0184900, {len=4096, heap_id_mask=<system bit>, flags=0})` and check for a returned dma-buf fd. Verifies CONDITIONAL-LIVE + correct mask.
2. ASHMEM: `ioctl(fd,0x40087703, 4096)` then `mmap(4096,RW,SHARED,fd,0)`; expect ENOTTY-free success. Also try 0x40087705/0x41007701/0x81007702 to confirm the 'w'-magic table.
3. Confirm fops wiring: read `ls -l /proc/self/fd` + `dma_buf`/`ashmem` under `/sys/kernel/debug/` (if readable) to see if ION alloc actually created buffers.

UNVERIFIED: exact reason the probe saw uniform EINVAL (code predicts ENOTTY for non-matching cmds with size<=24, EINVAL only for size>24 — consistent with the probe having used `sizeof`-based sizes 32/40/48 for most entries; smaller-size entries returning EINVAL was not reproduced in code). Exact accepted heap_id_mask bits and full ashmem nr table beyond those decoded.
