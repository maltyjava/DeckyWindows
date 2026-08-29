#!/usr/bin/env bash
# Drive bootstrap.ps1 / verify.ps1 on the handheld over SSH.
#
# Scripts are scp'd and run with -File, never piped over stdin: native commands inside a
# stdin-fed script drain the rest of the script and it truncates silently mid-run.
#
#   ./deploy-remote.sh                  # full install (latest upstream stable)
#   ./deploy-remote.sh install v3.2.6   # pin a version
#   ./deploy-remote.sh verify           # health check
#   ./deploy-remote.sh traceback        # capture startup traceback when :1337 never binds
#   HOST=myhandheld ./deploy-remote.sh  # different SSH host

set -euo pipefail

HOST="${HOST:-claw}"
CMD="${1:-install}"
REF="${2:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The remote is Windows: strip the PQ-handshake banner so logs stay readable.
ssh_q() { ssh -o BatchMode=yes "$HOST" "$@" < /dev/null 2>&1 | grep -v 'post-quantum\|store now\|may need to be upgraded\|^\*\*' | tr -d '\r'; }

push() {
  echo "==> uploading $1"
  scp -o BatchMode=yes -q "$DIR/$1" "$HOST:$1"
}

run_ps() {
  local script="$1"; shift
  local log="decky-${script%.ps1}.log"
  echo "==> running $script on $HOST (log: ~/$log)"
  ssh -o BatchMode=yes "$HOST" \
      "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\%USERNAME%\\$script $* > C:\\Users\\%USERNAME%\\$log 2>&1" \
      < /dev/null || echo "    (remote exited non-zero; see log below)"
  ssh_q "type C:\\Users\\%USERNAME%\\$log"
}

case "$CMD" in
  install)
    push bootstrap.ps1
    push verify.ps1
    if [ -n "$REF" ]; then run_ps bootstrap.ps1 "-Ref $REF"; else run_ps bootstrap.ps1; fi
    echo
    echo "==> NOTE: fully exit Steam from the tray (not just the window) and relaunch,"
    echo "    then run: ./deploy-remote.sh verify"
    ;;
  verify)
    push verify.ps1
    run_ps verify.ps1
    ;;
  traceback)
    push verify.ps1
    run_ps verify.ps1 "-Traceback"
    ;;
  restart)
    # NOT schtasks /end + /run: that reports SUCCESS but leaves the loader's children
    # alive, so the old instance keeps running and serving stale state.
    push restart-decky.ps1
    run_ps restart-decky.ps1
    ;;
  *)
    echo "usage: $0 [install [ref] | verify | traceback | restart]" >&2
    exit 2
    ;;
esac
