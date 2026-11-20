A() {
    printf '%s\n' "$*" >> "${SALVAGE_LOG:-/dev/null}"
    case "$1" in
        *"wc -c <"*)   echo "${FAKE_SIZE:-0}" ;;
        *"date +%m%d"* ) echo "${FAKE_DATE:-1016-2359}" ;;
    esac
}
. "$1"
