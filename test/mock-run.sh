#!/usr/bin/env bash
#
# Run 01-create-vm.yml and 99-destroy-all.yml end to end against mocked
# external commands, purely to exercise task coverage.
#
# Play 3 of 01 targets vm_server (the newly created VM) and needs a live SSH
# connection with cloud-init, kdump, and debuginfo, so it is skipped via
# --limit localhost. Plays 1-2 and the full 99-destroy-all are exercised.
#
# Destructive: 99 removes the base directory, so this refuses to run outside
# a container or CI unless --force is given.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${MOCK_WORKDIR:-/tmp/vm-mock-run}"
COVERAGE_OUT="${ANSIBLE_COVERAGE_OUTPUT:-$REPO_ROOT/coverage.xml}"
FORCE=0

usage() {
  cat <<'USAGE'
Usage: test/mock-run.sh [--force] [--workdir DIR]

  --force        run even outside a container/CI
  --workdir DIR  scratch directory for the fake lab (default /tmp/vm-mock-run)

Environment:
  ANSIBLE_COVERAGE_OUTPUT  Cobertura XML to merge into (default ./coverage.xml)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --workdir) WORKDIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- Safety guard ------------------------------------------------------------
in_container() {
  [ -f /run/.containerenv ] || [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null
}
if [ "$FORCE" != "1" ] && ! in_container && [ -z "${CI:-}" ]; then
  cat >&2 <<'REFUSE'
test/mock-run.sh refuses to run here.

99-destroy-all.yml removes the base directory, so this is meant for a
throwaway container or a CI runner. Run it as:

  podman run --rm -v "$PWD":/repo:Z -w /repo fedora:44 ./test/mock-run.sh

or pass --force if this host really is disposable.
REFUSE
  exit 1
fi

echo "==> workspace: $WORKDIR"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{work,pool}

export MOCK_LOG="$WORKDIR/mock-commands.log"
: > "$MOCK_LOG"

# --- Port 22 listener --------------------------------------------------------
# Play 2's "Wait for VM SSH" polls port 22 on the mock vm_ip (127.0.0.1).
# Park a bare TCP listener so the wait_for succeeds without a real sshd.
start_listener() {
  python3 -c "
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', 22)); s.listen(16)
except PermissionError:
    sys.exit(1)
while True:
    try: s.accept()[0].close()
    except OSError: pass
" &
  echo $! > "$WORKDIR/listener.pid"
  sleep 1
}

if start_listener; then
  echo "==> port-22 listener up"
else
  echo "==> could not bind port 22 (not root?); Wait for VM SSH will time out" >&2
fi

# shellcheck disable=SC2329
cleanup() {
  [ -f "$WORKDIR/listener.pid" ] && kill "$(cat "$WORKDIR/listener.pid")" 2>/dev/null || true
}
trap cleanup EXIT

# --- Run ---------------------------------------------------------------------
export PATH="$REPO_ROOT/test/mock-bin:$PATH"
# Mock collection takes precedence over the real cloud.terraform
export ANSIBLE_COLLECTIONS_PATH="$REPO_ROOT/test/mock-collections:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections:/usr/share/ansible/collections}"
export ANSIBLE_CALLBACKS_ENABLED="coverage_reporter"
export ANSIBLE_COVERAGE_OUTPUT="$COVERAGE_OUT"
export ANSIBLE_HOST_KEY_CHECKING=False

OVERRIDES=(
  -e "vm_base_dir=$WORKDIR"
  -e "vm_tf_dir=$WORKDIR/work"
  -e "vm_pool_dir=$WORKDIR/pool"
)

rc=0

# Play 1 (SELinux) + Play 2 (infrastructure) — Play 3 targets vm_server and
# needs a real SSH connection with cloud-init, so skip it via --limit.
echo "==> 01-create-vm.yml (--limit localhost)"
ansible-playbook -i "$REPO_ROOT/test/inventory" --limit localhost \
  "${OVERRIDES[@]}" "$REPO_ROOT/01-create-vm.yml" || { rc=1; echo "!! 01-create-vm.yml failed"; }

echo "==> 99-destroy-all.yml"
ansible-playbook -i "$REPO_ROOT/test/inventory" \
  "${OVERRIDES[@]}" "$REPO_ROOT/99-destroy-all.yml" || { rc=1; echo "!! 99-destroy-all.yml failed"; }

echo "==> mocked commands invoked:"
sed 's/^/    /' "$MOCK_LOG"
exit "$rc"
