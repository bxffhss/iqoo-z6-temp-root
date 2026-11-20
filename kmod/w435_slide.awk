# ksu_slide.awk — 设备侧解 KASLR slide，与 analysis/slide_pc.py 逐句对应（不是近似）。
# 不需要 root、不需要时间：候选窗口来自**样本地址簇本身**，判据是"正对照函数命中数"。
#   awk -v link_text=ffffffc010080000 -v link_etext=ffffffc0115a0000 -v step_dec=2097152 \
#       -f ksu_slide.awk  slide_ctl.txt  samples.txt
#   ★link_* 是 16 位 **hex**、step_dec 是 **十进制**字节数：三者都由 slide_ctl.txt 表头带给驱动。
# slide_ctl.txt = "<16位hex链接期地址> <宽度> <名字>"（打包时用出货 kallsyms 现算，不许手抄）
# samples.txt   = 每行一个 16 位 hex 内核地址（perfips 的裸值行；上游已 sort -u）
# 打印：SLIDE <16位hex> ／ NOSLIDE <原因>(exit 2)
#
# ★为什么全篇拆成 (hi,lo) 两个 32 位段：设备这颗 awk 的数就是 double。实测
#   `9007199254740993+0 ⇒ 9007199254740992`（过 2^53 就回绕），而内核地址是 0xffffffc0xxxxxxxx
#   ≈ 1.8e19 ⇒ 一当数用就丢低位（PC 那侧是 Python 大整数，没这问题）。
#   每段 ≤ 0xFFFFFFFF < 2^53 ⇒ 精确；比较一律"先比 hi 再比 lo"，加法只跟小加数并手管进位。
#   ⇒ 本文件里**没有任何一处**把完整 64 位地址当数值用。
#
# ★另有两颗 awk 方言的雷，都是自测夹具抓出来的(不是读文档读出来的)：
#   ① BEGIN 里 `exit` 之后 **END 照样会跑** ⇒ 失败出口统一走 bail()，END 第一句先看旗标；
#      不然一条常量错误会连着打两句互相矛盾的 NOSLIDE(第一版就是这样)。
#   ② `"文本" % 数` 在这两颗 awk 里是**取模**而不是格式化：文本转数=0 ⇒
#      消息退化成 "NOSLIDE 0"，而 0 作除数时直接 fatal: division by zero。
#      ⇒ 要格式化只许 sprintf()。

function hex8(s,   i, c, v, d) {      # 8 位 hex → 精确整数（≤2^32-1）；非 hex 返 -1
    v = 0
    for (i = 1; i <= 8; i++) {
        c = substr(s, i, 1)
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
function split16(s) {                 # 16 位 hex → 写进全局 T[0]=hi T[1]=lo；坏值返 0
    if (length(s) != 16) return 0
    T[0] = hex8(substr(s, 1, 8)); T[1] = hex8(substr(s, 9, 8))
    return (T[0] < 0 || T[1] < 0) ? 0 : 1
}
function cmp2(ah, al, bh, bl) {       # (ah,al) vs (bh,bl)：-1/0/1（两段各自精确，所以整体精确）
    if (ah != bh) return (ah < bh) ? -1 : 1
    if (al != bl) return (al < bl) ? -1 : 1
    return 0
}
function add2(ah, al, bh, bl) {       # (ah,al)+(bh,bl) → 全局 R[0]/R[1]（bh/bl 允许到 2^32 级）
    R[1] = al + bl; R[0] = ah + bh
    if (R[1] >= 4294967296) { R[1] -= 4294967296; R[0] += 1 }
}
function sub2(ah, al, bh, bl) {       # (ah,al)-(bh,bl) → 有符号整数，**调用方保证 |差| < 2^53**
    return (ah - bh) * 4294967296 + (al - bl)
}
function fl(x, y,   q) {              # 向下取整除法＝Python 的 //（awk 的 int() 是朝零截断）
    q = x / y
    if (q >= 0) return int(q)
    return (q == int(q)) ? q : int(q) - 1
}
function bail(msg) {                  # ★唯一的失败出口
    print "NOSLIDE " msg
    BAILED = 1                        # ← 必须有这个旗：BEGIN 里 exit 之后 **END 照样会跑**
    exit 2                            #   (设备那颗 awk 与 gawk 都是这语义；第一版没有它，
}                                     #    常量报错时 END 又补打一句"没有一条窗口"＝自相矛盾两行)
function hisplit(v) {                 # 小整数 slide(<2^53) → H[0]=高段 H[1]=低段
    H[0] = int(v / 4294967296); H[1] = v - H[0] * 4294967296
}

BEGIN {
    if (!link_text || !link_etext || !step_dec) bail("缺 -v link_text/link_etext/step_dec")
    if (!split16(link_text))  bail("link_text 不是 16 位 hex")
    LT[0] = T[0]; LT[1] = T[1]
    if (!split16(link_etext)) bail("link_etext 不是 16 位 hex")
    LE[0] = T[0]; LE[1] = T[1]
    st = step_dec + 0
    if (st != int(st) || st < 1048576) bail(sprintf("step_dec=%d 不是 ≥1MB 的整数——step 的单位是**十进制**字节，别把 hex 的 200000 当 2097152 喂进来", st))
    # ★第二道牙：KASLR 粒度必然是 2 的幂(本机 2MB=2097152)。真机第一次标定就是被
    #   "表头写 hex、awk 按十进制读"撞出 200000 ⇒ 非 2 的幂 ⇒ 这里直接拒，
    #   而不是让它扫 69 档对齐到错误步长的候选(那次侥幸只命中 1 个才没解出错值)。
    p = st
    while (p > 1) { if (p % 2 != 0) bail(sprintf("step_dec=%d 不是 2 的幂⇒ KASLR 步长不可能是这个数", st)); p = int(p / 2) }
}

# ── 第一个文件：正对照窗口表。宽度口径与 slide_pc.py 一致 = min(下一符号 - 本符号, 0x700) ──
NR == FNR {
    if ($0 ~ /^[ \t]*$/ || $0 ~ /^#/) next
    if (NF != 3) bail("slide_ctl.txt 有一行不是「地址 宽度 名字」：" $0)
    if (!split16($1)) bail("slide_ctl.txt 第 " NR " 行地址不是 16 位 hex：" $1)
    nw++
    WHI[nw] = T[0]; WLO[nw] = T[1]; WN[nw] = $3
    ln = $2 + 0
    if (ln <= 0 || ln != int(ln) || ln > 65535) bail("第 " NR " 行宽度可疑：" $2)
    LEN[nw] = ln
    next
}

# ── 第二个文件：样本地址（升序去重后喂进来）；只收高半区 hi ≥ 0xffff0000 ──
{
    if (split16($1) && T[0] >= 4294836224) { n++; SHI[n] = T[0]; SLO[n] = T[1] }
}

END {
    if (BAILED) exit 2                  # ← 见 bail()：不接这句就会二次打印
    if (nw == 0) bail("slide_ctl.txt 里没有一条窗口")
    if (n < 50)  bail(sprintf("样本太少 %d(16 位 hex 且落在高半区的)", n))

    # 主簇 = 相邻差 ≤ 4MB 的最长一段（与 PC 版同口径；样本已升序，所以只差看相邻）
    cs = 1; blen = 0; bl = 0; br = 0
    for (i = 2; i <= n; i++) {
        if (sub2(SHI[i], SLO[i], SHI[i - 1], SLO[i - 1]) > 4194304) {
            if (i - cs > blen) { blen = i - cs; bl = cs; br = i - 1 }
            cs = i
        }
    }
    if (n - cs + 1 > blen) { blen = n - cs + 1; bl = cs; br = n }
    if (blen < 50) { printf "NOSLIDE 主簇只有 %d 个(样本 %d)⇒ 这 boot 没采到核文本\n", blen, n; exit 2 }

    # 候选窗口：lo = 把(簇末 - link_etext)落到 step 再退 6 档；hi = 把(簇首 - link_text)落到 step 再进 6 档
    wlo = fl(sub2(SHI[br], SLO[br], LE[0], LE[1]), st) * st - 6 * st
    whi = fl(sub2(SHI[bl], SLO[bl], LT[0], LT[1]), st) * st + 6 * st
    if (whi < wlo) { print "NOSLIDE 候选窗口是空的(簇落在 link text 之前)⇒ 不猜"; exit 2 }
    nc = 0
    for (c = wlo; c <= whi; c += st) cand[++nc] = c

    # 每个候选打"正对照命中数"：窗口 = [a0+slide, a0+slide+len)，全走两段比较
    for (k = 1; k <= nc; k++) {
        hisplit(cand[k]); sh = H[0]; sl = H[1]
        tot = 0
        for (j = 1; j <= nw; j++) {
            add2(WHI[j], WLO[j], sh, sl); bh = R[0]; bo = R[1]
            add2(bh, bo, 0, LEN[j]);      eh = R[0]; eo = R[1]
            for (i = bl; i <= br; i++)
                if (cmp2(SHI[i], SLO[i], bh, bo) >= 0 && cmp2(SHI[i], SLO[i], eh, eo) < 0) tot++
        }
        hit[k] = tot
    }
    # 第一/第二（PC 版按 -score 排序后取前两名；这里同口径）
    b1 = 1; b2 = 0
    for (k = 2; k <= nc; k++) {
        if (hit[k] > hit[b1]) { b2 = b1; b1 = k }
        else if (b2 == 0 || hit[k] > hit[b2]) b2 = k
    }
    printf "样本 %d(主簇 %d, [%08x%08x, %08x%08x]); 正对照窗口 %d 个; 扫了 %d 档对齐 slide; top 5:\n", \
        n, blen, SHI[bl], SLO[bl], SHI[br], SLO[br], nw, nc
    for (t = 1; t <= 5; t++) {          # 只打前 5：小集合，每次现找最大值，不在设备上写排序
        mx = 0
        for (k = 1; k <= nc; k++) if (!used[k] && (mx == 0 || hit[k] > hit[mx])) mx = k
        if (mx == 0) break
        used[mx] = 1
        hisplit(cand[mx])
        printf "  slide=+%08x%08x 正对照命中=%3d\n", H[0], H[1], hit[mx]
    }
    if (hit[b1] < 3) { printf "NOSLIDE 正对照太弱(最高只有 %d 个命中)⇒ 不猜\n", hit[b1]; exit 2 }
    if (b2 && hit[b2] * 2 >= hit[b1]) { printf "NOSLIDE 第二名(%d)与第一名(%d)太接近⇒ 不猜\n", hit[b2], hit[b1]; exit 2 }
    hisplit(cand[b1])
    printf "SLIDE %08x%08x\n", H[0], H[1]
}
