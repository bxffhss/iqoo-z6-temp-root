SUW="${SUW_NAME:?}"
A() { printf '%s\n' "$*" >> "${N_LOG:-/dev/null}"; case "$1" in "pidof "*) echo "${FAKE_PIDOF:-}" ;; esac; }
. "$1"
fire w161_g2.sh 0
