A() { printf '%s\n' "$*" >> "${Q_LOG:-/dev/null}"; }
. "$1"
