#!/usr/bin/env bash
#
# Run 01-create-vm.yml and 99-destroy-all.yml end to end against mocked
# external commands, purely to exercise task coverage.
#
# Play 3 of 01 targets vm_server (the newly created VM) over SSH.  We set up
# sshd on localhost so the add_host inventory works.  kdump and debuginfo
# conditionals are set to false because /proc/sys/kernel/random/boot_id cannot
# change without a real reboot and /proc/cmdline is read-only.
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

# --- SSH setup ---------------------------------------------------------------
# Play 2 adds vm_server to the dynamic inventory at 127.0.0.1.  Play 3 then
# SSHes into it. Set up sshd so the connection works end to end.
VM_USER="fedora"
VM_PASS="fedora"

setup_sshd() {
  command -v sshd >/dev/null 2>&1 || return 1
  command -v ssh  >/dev/null 2>&1 || return 1
  command -v sshpass >/dev/null 2>&1 || return 1
  [ "$(id -u)" = "0" ] || return 1
  ssh-keygen -A >/dev/null 2>&1 || return 1
  id "$VM_USER" >/dev/null 2>&1 || useradd -m "$VM_USER"
  echo "$VM_USER:$VM_PASS" | chpasswd
  echo "$VM_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-$VM_USER"
  chmod 0440 "/etc/sudoers.d/99-$VM_USER"
  mkdir -p /run/sshd /var/empty/sshd
  /usr/sbin/sshd -o UsePAM=yes -o PasswordAuthentication=yes
  for _ in $(seq 30); do
    (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

LIMIT_ARGS=()
if setup_sshd; then
  echo "==> sshd up — Play 3 (vm_server) will run"
else
  echo "==> no usable sshd; Play 3 skipped via --limit localhost"
  LIMIT_ARGS=(--limit localhost)
  # Play 2's "Wait for VM SSH" still needs port 22 to respond.
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
  -e "vm_kdump_enabled=false"
  -e "vm_install_debuginfo=false"
)

rc=0

echo "==> 01-create-vm.yml"
ansible-playbook -i "$REPO_ROOT/test/inventory" "${LIMIT_ARGS[@]}" \
  "${OVERRIDES[@]}" "$REPO_ROOT/01-create-vm.yml" || { rc=1; echo "!! 01-create-vm.yml failed"; }

echo "==> 99-destroy-all.yml"
ansible-playbook -i "$REPO_ROOT/test/inventory" \
  "${OVERRIDES[@]}" "$REPO_ROOT/99-destroy-all.yml" || { rc=1; echo "!! 99-destroy-all.yml failed"; }

echo "==> mocked commands invoked:"
sed 's/^/    /' "$MOCK_LOG"
exit "$rc"
