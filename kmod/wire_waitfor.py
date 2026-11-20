import io

BS = chr(92)

# ---------- 1) 清扫脚本：去掉 `find`，改成纯 ls 列举(第 51 发它在 agent 环境里报
#            `/data/adb: can't execute: Is a directory`，成因未定，先不依赖它) ----------
p = 'kmod/w153_sweep.sh'
s = io.open(p, encoding='utf-8').read()
old = ("    find /data/adb -maxdepth 3 2>&1 | head -12 | sed 's/^/    find: /'\n"
       "    ls -l /data/adb 2>&1 | head -6 | sed 's/^/    ls:   /'\n")
new = ("    # 用 ls -A 逐层列(不用 find：第 51 发 `find` 在 agent 环境里报\n"
       "    #   `w153_sweep.sh[43]: /data/adb: can't execute: Is a directory`，成因未定，不赌它)\n"
       "    ls -A /data/adb 2>&1 | head -10 | sed 's/^/    内容: /'\n"
       "    for x in $(ls -A /data/adb 2>/dev/null | head -6); do ls -l \"/data/adb/$x\" 2>&1 | head -2 | sed 's/^/      /'; done\n")
assert s.count(old) == 1, '清扫脚本锚点没找到'
io.open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new, 1))
print('1) 清扫脚本已去掉 find')

# ---------- 2) 驱动：加 WAITFOR(轮询代替固定 sleep)，用在 ATT=26 的两处"等文件"上 ----------
p2 = 'kmod/w103_su.sh'
t = io.open(p2, encoding='utf-8').read()
anchor = 'DEVOK() {'
assert t.count(anchor) == 1
helper = '''WAITFOR() {   # WAITFOR <设备侧文件> <上限秒> —— **轮询到文件出现**再往下走。
                #   第 51 发的现场：ATT=26 收尾固定 sleep 16 就 `head` 那份回读文件，结果读到
                #   `No such file` ⇒ C 段被判 SKIP(验收其实跑了，只是没等到)。agent 的响应时间
                #   从来不是常数(post 3~17 分钟那一族同源)，所以"等多久"一律改成"等到什么"。
    f=$1; n=${2:-40}; i=0
    while [ "$i" -lt "$n" ]; do
        [ -n "$(S "ls -l $f 2>/dev/null" | tr -d '\\r\\n')" ] && { echo "    (等到 $f 用时 $((i*2))s)"; return 0; }
        sleep 2; i=$((i+1))
    done
    echo "    (等满 $((n*2))s 还是没有 $f ⇒ 后面会把这一格判成没测到，这是对的)"
    return 1
}

'''
t = t.replace(anchor, helper + anchor, 1)

i = t.index('elif [ "$ATT" = 26 ]; then')
j = t.index('elif [ "$ATT" = 25 ]; then')
blk = t[i:j]
old_fire_res = '    fire "@sushd:$RES" 16\n    S \'head -c 6000 /data/local/tmp/w152_residue.out 2>&1\''
assert blk.count(old_fire_res) == 1, 'residue 锚点'
blk = blk.replace(old_fire_res,
                  '    fire "@sushd:$RES" 6\n    WAITFOR /data/local/tmp/w152_residue.out 40\n'
                  '    S \'head -c 6000 /data/local/tmp/w152_residue.out 2>&1\'', 1)
old_fire_sw = '    fire "@sushd:/data/local/tmp/w153_sweep.sh" 16\n    S \'head -c 6000 /data/local/tmp/w153_sweep.out 2>&1\''
assert blk.count(old_fire_sw) == 1, 'sweep 锚点'
blk = blk.replace(old_fire_sw,
                  '    fire "@sushd:/data/local/tmp/w153_sweep.sh" 6\n    WAITFOR /data/local/tmp/w153_sweep.out 40\n'
                  '    S \'head -c 6000 /data/local/tmp/w153_sweep.out 2>&1\'', 1)
t = t[:i] + blk + t[j:]
io.open(p2, 'w', encoding='utf-8', newline='\n').write(t)
print('2) 驱动已加 WAITFOR 并用在 ATT=26 的 sweep/residue 两处')
