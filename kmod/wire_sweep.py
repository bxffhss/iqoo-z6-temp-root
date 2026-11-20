import io

BS = chr(92)  # 反斜杠一律这么拼：本文件的规矩(heredoc/引号层里直接写会出事)
P = 'kmod/w103_su.sh'
SW = '/data/local/tmp/w153_sweep.sh'
lines = io.open(P, encoding='utf-8').read().split('\n')


def uniq(key, want=1):
    idx = [i for i, l in enumerate(lines) if key in l]
    assert len(idx) == want, '锚点 %r 命中 %d 次(要 %d)' % (key, len(idx), want)
    return idx[0]


i = uniq('kmod/w152_residue.sh:"$RES"')
lines.insert(i + 1, '             kmod/w153_sweep.sh:' + SW + ' ' + BS)

# chmod 那行与"落地复验 ls"那行**都**含这个子串 ⇒ 两处都要插(之前 uniq 只容一处)
for idx, l in enumerate(lines):
    if '$DOM $DOM2 $RUN $RES /data/local/tmp/w148_uid.sh' in l:
        lines[idx] = l.replace('$RUN $RES /data/local/tmp/w148_uid.sh',
                               '$RUN $RES ' + SW + ' /data/local/tmp/w148_uid.sh')

# (原来这里还有一步"往 ls 那行里再插一次 SW"——上一步的循环已经把它两处都插好了，
#  再插一次会变成两个 w153 ⇒ 删掉，避免重复插入)

m = uniq('    fire "@sushd:$RES" 16')
lines[m:m + 1] = [
    "    S 'rm -f /data/local/tmp/w153_sweep.out' >/dev/null",
    '    fire "@sushd:' + SW + '" 16',
    "    S 'head -c 6000 /data/local/tmp/w153_sweep.out 2>&1' | sed 's/^/    /'",
    '    PULL /data/local/tmp/w153_sweep.out w29_sweep',
    '    fire "@sushd:$RES" 16',
]

n = uniq('(d) 收尾：root 侧先 umount 成功、再删源目录；然后**root 侧回读残留**')
lines[n] = lines[n].replace('(d) 收尾：root 侧先 umount 成功、再删源目录；然后**root 侧回读残留**',
                            '(d) 收尾：umount → **清扫(/data/adb 是我们 stage 造的)** → 再 root 侧回读残留')

io.open(P, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
print('接线完成：push/chmod/落地复验/(d) 顺序/标题')
