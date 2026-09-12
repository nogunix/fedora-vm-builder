#!/usr/bin/env bash
#
# Run every playbook in the repo end to end against mocked external commands,
# purely to exercise task coverage.
#
# 01-create-vm.yml runs twice, because a third of its tasks only run on one
# side of a conditional:
#
#   1. 01-create-vm.yml with kdump/debuginfo disabled, and Play 1's SELinux
#      facts injected so the semanage/restorecon branch runs against mocks.
#   2. 01-create-vm.yml with kdump/debuginfo enabled. Play 3 inspects the VM
#      over SSH, so vm_boot_id_path / vm_cmdline_path / vm_cloud_init_marker
#      point at fixtures: nothing here really reboots and /proc is read-only.
#   3. 99-destroy-all.yml, then test-render.yml, so a single run reports the
#      task coverage of every playbook in the repo.
#
# Destructive: pass 3 removes the base directory, and passes 1-2 install mock
# binaries under /usr/local/bin, so this refuses to run outside a container or
# CI unless --force is given.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${MOCK_WORKDIR:-/tmp/vm-mock-run}"
# 99-destroy-all.yml deletes WORKDIR, so the log and the fixtures Play 3 reads
# live beside it, not inside it.
STATE_DIR="${WORKDIR%/}-state"
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
    --workdir) WORKDIR="$2"; STATE_DIR="${2%/}-state"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- Safety guard ------------------------------------------------------------
in_container() {
  [ -f /run/.containerenv ] || [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null
}
if in_container || [ -n "${CI:-}" ]; then
  DISPOSABLE=1
else
  DISPOSABLE=0
fi
if [ "$FORCE" != "1" ] && [ "$DISPOSABLE" != "1" ]; then
  cat >&2 <<'REFUSE'
test/mock-run.sh refuses to run here.

99-destroy-all.yml removes the base directory and the mocked VM needs mock
binaries in /usr/local/bin, so this is meant for a throwaway container or a CI
runner. Run it as:

  podman run --rm -v "$PWD":/repo:Z -w /repo fedora:44 ./test/mock-run.sh

or pass --force if this host really is disposable.
REFUSE
  exit 1
fi

echo "==> workspace: $WORKDIR"
rm -rf "$WORKDIR" "$STATE_DIR"
mkdir -p "$WORKDIR"/{work,pool} "$STATE_DIR/fixtures"

export MOCK_LOG="$STATE_DIR/mock-commands.log"
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

# --- Mocks and fixtures for the "VM" side (Play 3) ---------------------------
# Play 3 runs as $VM_USER over SSH and sudo's for kdumpctl, so its mocks go in
# /usr/local/bin: that is on the login PATH *and* on sudo's secure_path, which
# $REPO_ROOT/test/mock-bin is not.
setup_vm_mocks() {
  [ "$DISPOSABLE" = "1" ] || return 1
  [ "$(id -u)" = "0" ] || return 1
  install -m 0755 "$REPO_ROOT/test/mock-bin/cloud-init" /usr/local/bin/cloud-init
  install -m 0755 "$REPO_ROOT/test/mock-bin/kdumpctl" /usr/local/bin/kdumpctl
  # "Check vmlinux exists" stats the debuginfo vmlinux for the running kernel.
  install -d "/usr/lib/debug/lib/modules/$(uname -r)"
  : > "/usr/lib/debug/lib/modules/$(uname -r)/vmlinux"
  return 0
}

FIXTURES="$STATE_DIR/fixtures"
CRASHKERNEL="$(python3 -c 'import yaml; print(yaml.safe_load(open("vars.yml"))["vm_crashkernel"])' \
  2>/dev/null || echo 512M)"
: > "$FIXTURES/boot-finished-phase1"
printf 'BOOT_IMAGE=/vmlinuz-mock root=/dev/vda1 ro console=ttyS0 crashkernel=%s\n' \
  "$CRASHKERNEL" > "$FIXTURES/cmdline"
chmod -R a+rX "$STATE_DIR"

LIMIT_ARGS=()
VM_MOCKS=0
if setup_sshd; then
  echo "==> sshd up — Play 3 (vm_server) will run"
  if setup_vm_mocks; then
    VM_MOCKS=1
  else
    echo "==> not disposable/root: skipping the kdump pass (needs /usr/local/bin mocks)"
  fi
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
  echo $! > "$STATE_DIR/listener.pid"
  sleep 1
fi

# shellcheck disable=SC2329
cleanup() {
  [ -f "$STATE_DIR/listener.pid" ] && kill "$(cat "$STATE_DIR/listener.pid")" 2>/dev/null || true
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

# Play 1 keys off gathered facts, and no CI runner has SELinux enabled.
# Injecting the two facts it reads is what makes the semanage/restorecon
# branch run (against test/mock-bin), instead of being skipped every time.
# The dnf task then really installs a package, which needs the dnf bindings.
SELINUX_ARGS=()
if python3 -c 'import dnf' >/dev/null 2>&1; then
  SELINUX_ARGS=(-e '{"ansible_facts": {"selinux": {"status": "enabled"}, "os_family": "RedHat"}}')
else
  echo "==> no dnf python bindings: leaving Play 1's SELinux branch skipped"
fi

rc=0

echo "==> 01-create-vm.yml (kdump off, SELinux branch on)"
ansible-playbook -i "$REPO_ROOT/test/inventory" "${LIMIT_ARGS[@]}" \
  "${OVERRIDES[@]}" "${SELINUX_ARGS[@]}" \
  -e "vm_kdump_enabled=false" \
  -e "vm_install_debuginfo=false" \
  "$REPO_ROOT/01-create-vm.yml" || { rc=1; echo "!! 01-create-vm.yml (kdump off) failed"; }

if [ "$VM_MOCKS" = "1" ]; then
  echo "==> 01-create-vm.yml (kdump on, debuginfo on)"
  # /proc/sys/kernel/random/uuid returns a fresh value on every read, so the
  # "boot id changed" check sees exactly what a real reboot would show it.
  ansible-playbook -i "$REPO_ROOT/test/inventory" \
    "${OVERRIDES[@]}" \
    -e "vm_kdump_enabled=true" \
    -e "vm_install_debuginfo=true" \
    -e "vm_boot_id_path=/proc/sys/kernel/random/uuid" \
    -e "vm_cloud_init_marker=$FIXTURES/boot-finished-phase1" \
    -e "vm_cmdline_path=$FIXTURES/cmdline" \
    "$REPO_ROOT/01-create-vm.yml" || { rc=1; echo "!! 01-create-vm.yml (kdump on) failed"; }
fi

echo "==> 99-destroy-all.yml"
ansible-playbook -i "$REPO_ROOT/test/inventory" \
  "${OVERRIDES[@]}" "$REPO_ROOT/99-destroy-all.yml" || { rc=1; echo "!! 99-destroy-all.yml failed"; }

# Rendering the tfvars is the third playbook CI runs (in the tofu job); doing
# it here too means one local run reports the whole repo's task coverage.
echo "==> test-render.yml"
ansible-playbook -i "$REPO_ROOT/test/inventory" \
  "${OVERRIDES[@]}" "$REPO_ROOT/test-render.yml" || { rc=1; echo "!! test-render.yml failed"; }

echo "==> mocked commands invoked:"
sed 's/^/    /' "$MOCK_LOG" || true
exit "$rc"
