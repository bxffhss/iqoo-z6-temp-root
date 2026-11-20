# 内核符号表工作流(§CL, 2026-09-17) —— 静态审计已全面解锁

## 关键成果
`vmlinux-to-elf` 从我们的 kernel_image.img **成功恢复完整符号表**:
- 输出: `vmlinux.elf` (55MB, 含 179,170 个符号)
- 符号表: `analysis/vmlinux_symbols.txt` (llvm-nm 导出)
- 工具: `vmlinux-to-elf-master/`(本地已有) 用 **系统 Python K:/Python3/python.exe**(已装 peewee) 运行

## 正确地址映射(已由符号确证, 修正此前 0x80000 偏差)
```
_text   = 0xffffffc010080000        <-- 真实基址
_stext  = 0xffffffc010081000
kimage_vaddr = 0xffffffc011600000
文件偏移 = vaddr - 0xffffffc010080000   (= (vaddr & 0xffffffff) - 0x10080000)
```
验证: `__init_begin`=0xffffffc0123c0000 → 文件偏移 0x2340000 ✓(此前误认作 stext)

## 用法
```bash
OD=.../llvm-objdump.exe
# 直接按符号反汇编(ELF 已自洽, 无需手动算文件偏移)
"$OD" -d --start-address=0xffffffc010a78054 --stop-address=0xffffffc010a780a0 vmlinux.elf
# 查符号
grep -iE " _text$" analysis/vmlinux_symbols.txt
```

## 提权关键符号(已定位)
| 符号 | 地址 |
|---|---|
| commit_creds | 0xffffffc01031f154 |
| prepare_kernel_cred | 0xffffffc01031f67c |
| init_cred | 0xffffffc01293d528 |
| selinux_state | 0xffffffc012b18000 |
| __do_sys_capset | 0xffffffc0102ef8c8 |
| call_usermodehelper | 0xffffffc0103051fc |

## 首批审计结果(示例)
`kgsl_ioctl_gpu_command` @ 0xffffffc010a78054:
```
prologue + 栈溢出保护(ldr __stack_chk_guard)
mov w9, #0x86a0 ; movk w9, #0x1   → 0x186a0 = 100000
ldr w8, [x2, #0x14]               ; params+0x14 (numcmds?)
cmp w8, w9 ; b.hi 错误            → 上限校验 100000
mov x20, #-0x16                   ; 默认返回 EINVAL
```
→ kgsl handler 代码**完全可读**(0x10a78xxx 远在 440KB 零区之外)

## 结论
**"镜像有 440KB 零区导致无法审计" 的判断作废** —— kgsl 代码位于 0x10a7xxxx-0x10aaxxxx 区段, 全部可读;
零区(0x11514000-0x11582000)只是数据区(26k 指针指向它), 与 kgsl 代码无关。
