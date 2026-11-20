LOG="${N_LOG}"
# ★第 69 发 selftest 自己踩到的坑(记进 md)：ls 的"第几次调用"要记在**文件**里，
#   不能记在变量上——go.sh 那句是 `PERM=$(A "ls -l …" | awk …)`，A() 跑在**命令替换的子 shell**里，
#   变量计数器每次都回到 0 ⇒ 第二次读回永远拿到 FAKE_LS1 ⇒ C 格被我的仪器判成"补不上"。
#   红的是仪器不是被测，所以这里两侧都要有牙。
ls_n() { local n; n=$(cat "$CNT" 2>/dev/null); n=${n:-0}; n=$((n+1)); printf '%s' "$n" > "$CNT"; printf '%s' "$n"; }
A() {
    printf 'ADB|%s\n' "$1" >> "$LOG"
    case "$1" in
        ls\ -l\ * )
            if [ "$(ls_n)" = 1 ]; then printf '%s\n' "${FAKE_LS1:-}"; else printf '%s\n' "${FAKE_LS2:-}"; fi ;;
        chmod* ) : ;;
        md5sum* ) printf '%s  leg\n' "${FAKE_MD5:-deadbeef}" ;;
        rm\ -f* ) : ;;
        cat* ) printf 'END up=1\n' ;;
    esac
}
fire() { printf 'FIRE|%s\n' "$1" >> "$LOG"; }
WAITFOR() { printf 'END up=1\n' > "$EV/leg1_out.txt"; return 0; }
if [ -n "${LEG1:-}" ]; then
    echo "=== 3.5) 立即派 LEG1=$LEG1 ==="
    case "$LEG1" in
        /data/local/tmp/*.sh ) : ;;
        * ) echo "  [x] LEG1 必须是 /data/local/tmp/ 下的 .sh 绝对路径 ⇒ 不派(别把串注进设备侧命令)" ;;
    esac
    if [ -z "${LEG1OUT:-}" ]; then
        echo "  [x] 没给 LEG1OUT(腿自己写的 out 件) ⇒ 不派：没有等待目标就等于用『没输出』当通过"
    elif [ "${LEG1#/data/local/tmp/}" = "$LEG1" ]; then
        echo "  [x] LEG1 形状不合(要 /data/local/tmp/ 开头) ⇒ 不派"
    else
        if [ -n "${LEG1MD5:-}" ]; then
            DEVMD5=$(A "md5sum $LEG1 2>/dev/null" | cut -d' ' -f1)
            echo "  腿件两端对表：本机=$LEG1MD5 设备=$DEVMD5"
            [ "$DEVMD5" = "$LEG1MD5" ] || { echo "  [x] 设备上不是本机这支腿(§6.155：旧件会静默换形状) ⇒ 不派"; LEG1=1; }
        fi
        # ★★第 69 发一手的第二道自保闸：腿在设备上必须是**可执行**的。
        #   凭据：sushd.log 里那句 `请求来自 uid=10342 … cmd=[/data/local/tmp/w1018_mlsrange_leg.sh]`
        #   后面跟着 `已回给 … exit=126(有输出)` + `KSU_EXEC: … can't execute: Permission denied`
        #   ⇒ 通道是好的、授权也答了 granted=1，死在 execve：**root 也要文件里至少有一个 x 位**
        #      (adb push 落 0666，一个都没有)。而 go.sh 自己第 4 步那批腿一直是「push 完立刻 chmod 755」
        #      (见下面 w165b_adb_clean 那三行) ⇒ 我这个 LEG1 钩子把 chmod 那一行抄漏了。
        #   规矩：派之前就地补 x 位，并且**读回**；读回还是没有 x ⇒ 不派(派下去只会再拿一发空枪)。
        #   ★整块排在 md5 那格**之后**且要 md5 已经通过才做：不然 LEG1 已被置成字面量 1，
        #     我这条 ls 就会去探 `/data/local/tmp` 里一个叫 "1" 的文件(第 69 发 selftest 抓到的形状)。
        #   ★读法用 ls -l 的第 1 列(权限串)取**属主 x 位**，不用 `stat -c %a`：
        #     stat 失败时错误行里带着路径本身(如 `/data/local/tmp/w1018_…`)，我用 tr -dc '0-7' 收数字
        #     会收到 `10187` 这种尾巴是 7 的串 ⇒ 把「读不到」判成「有 x 位」＝假绿。
        #     ls 失败时第 1 列是 `ls:` ⇒ 取不到 x ⇒  fail-closed。
        if [ "${LEG1:-0}" != 1 ]; then
        PERM=$(A "ls -l $LEG1 2>/dev/null" | awk 'NR==1{print $1}')
        XBIT=${PERM:3:1}
        case "$XBIT" in x|s|t) : ;; * ) A "chmod 755 $LEG1" >/dev/null; PERM=$(A "ls -l $LEG1 2>/dev/null" | awk 'NR==1{print $1}'); XBIT=${PERM:3:1} ;; esac
        echo "  腿的设备侧权限=$PERM(派之前现取；补过 x 位就重取一次) 属主 x 位=[${XBIT:-空}]"
        case "$XBIT" in
            x|s|t ) : ;;
            * ) echo "  [x] 腿在设备上没有 x 位(权限=$PERM) ⇒ **不派**：execve 必 EACCES(第 69 发一手 exit=126)"
                 LEG1=1 ;;
        esac
        fi
        if [ "${LEG1:-0}" != 1 ]; then
            A "rm -f $LEG1OUT" >/dev/null
            fire "@sushd:$LEG1" 3
            if WAITFOR "$LEG1OUT" 60 "END up="; then
                A "cat $LEG1OUT" > "$EV/leg1_out.txt" 2>&1
                echo "  ★腿跑完，全文存 $EV/leg1_out.txt(=$(wc -l < "$EV/leg1_out.txt") 行)"
                grep -aE 'insmod_rc|PARAM rt_|MODULES_LINE|POLICY_UNCHANGED|WR_rc|ko_md5|\[x\]|\[!!\]' "$EV/leg1_out.txt" | cut -c1-160 | sed 's/^/    /'
            else
                echo "  [!] 60 轮(约 5 分钟)内没等到 $LEG1OUT 的 END ⇒ 这格记**未测**，不许把『没输出』读成通过"
            fi
        else
            echo "  [x] 前置没齐(md5 或 x 位) ⇒ **不派**：这一段整块跳过，别把派下去的空证件当读数"
            echo "      ★顺带修掉旧缺陷：上面 md5 那格原本只把 LEG1 置成 1 就往下 fire，等于把字面量『1』当脚本派下去"
        fi
    fi
else
    echo "=== 3.5) 未给 LEG1 ⇒ 不派腿(交付形状逐字不变) ==="
fi
echo "FINAL_LEG1=[${LEG1:-<空>}]"
