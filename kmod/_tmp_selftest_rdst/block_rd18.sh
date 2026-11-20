rd() {  # rd <路径> ⇒ RVAL=第一行内容(可能为空)  RCODE=read 的 rc；★空才叫"读不出"
    RVAL=""
    { read -r RVAL < "$1"; } 2>&9
    RCODE=$?
}
