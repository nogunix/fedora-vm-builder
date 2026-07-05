# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Automates deployment of **disposable Fedora VMs** on a Linux host (Fedora/RHEL/CentOS Stream) using Ansible + OpenTofu + libvirt/KVM. A single VM is provisioned with kdump pre-enabled and kernel debuginfo pre-installed, ready for vmcore capture immediately after boot.

Designed for kernel crash forensics and debugging, but usable standalone.

## Running the Playbooks

```bash
# Install Ansible collection dependency first
ansible-galaxy collection install -r requirements.yml

# Create a Fedora VM with kdump + debuginfo (~15-30 min, depends on download speed)
ansible-playbook 01-create-vm.yml

# Tear everything down
ansible-playbook 99-destroy-all.yml
```

## Linting

```bash
ansible-lint
```

## Local verification before pushing

Reproduce the full CI suite locally before pushing (mirrors `lint.yml` + `test.yml`):

```bash
# 1. Lint (pip install --user ansible-lint if the command is missing)
ansible-lint

# 2. Syntax-check all playbooks
ansible-playbook --syntax-check -i test/inventory 01-create-vm.yml 99-destroy-all.yml

# 3. Render templates with default vars, then validate the generated .tf
ansible-playbook test-render.yml
cd /tmp/vm-rendered && tofu init -backend=false && tofu validate
```

## CI

- **Lint** (`.github/workflows/lint.yml`): runs `ansible-lint` on every push/PR to `main`
- **Test** (`.github/workflows/test.yml`): runs on every push/PR to `main`
  - **Syntax check**: `ansible-playbook --syntax-check` on both playbooks, across 4 distros (Fedora 43/44, Ubuntu 24.04, CentOS Stream 10)
  - **Template render + tofu validate**: renders all Jinja2 templates with default vars and runs `tofu validate` on the generated `.tf` files
  - Test playbook is `test-render.yml` (repo root); minimal inventory for syntax check is `test/inventory`
- **Fedora image check** (`.github/workflows/fedora-image-check.yml`): runs weekly (Monday 00:00 UTC), HEAD-checks all Fedora Cloud image URLs in `vars.yml`, re-runs `ansible-lint`, and opens a GitHub issue (or adds a comment to an existing one) if any URL is unreachable or lint fails

## Architecture

### Playbook sequence

| Playbook | What it does |
|---|---|
| `01-create-vm.yml` | SELinux prep, renders OpenTofu templates, `tofu apply` to create pool/network/VM, waits for cloud-init (kdump + debuginfo), verifies kdump operational |
| `99-destroy-all.yml` | `tofu destroy`, manual `virsh` fallbacks, removes `vm_base_dir` |

### Template rendering flow

- `infra.tf.j2` -> `infra.tf` -- libvirt pool + NAT network (DHCP enabled)
- `vm.tf.j2` -> `{{ vm_prefix }}_vm0.tf` -- cloud-init disk + base volume + overlay + domain

### Cloud-init sequence

1. Create user with sudo NOPASSWD
2. Install `kexec-tools` (and `dnf-plugins-core` if debuginfo enabled)
3. `grubby --update-kernel=ALL --args=crashkernel=512M`
4. `systemctl enable kdump`
5. `dnf debuginfo-install -y kernel-core` (if enabled; can be slow)
6. Reboot (to apply crashkernel reservation)
7. After reboot: kdump starts with reserved memory, VM is ready

### Key design decisions

- **Single playbook, single VM**: no bastion, no multi-VM orchestration. One `tofu apply` creates everything.
- **crashkernel=512M**: 256M causes OOM on the crash kernel (learned from real incidents).
- **debuginfo at build time**: avoids the repeated "download debuginfo after the fact" failures seen in ad-hoc VM builds.
- **Belt-and-suspenders teardown**: `tofu destroy` followed by raw `virsh` fallbacks, all with `failed_when: false`.
- **Pool per prefix**: each `vm_prefix` gets its own libvirt storage pool (not the system `default`), avoiding collisions with other libvirt users.

## Configuration

All tunable parameters are in `vars.yml`. Fields marked `[CHANGE]` should be reviewed:

- `vm_prefix` -- name prefix for all libvirt resources (change to avoid collisions)
- `vm_base_dir` -- where OpenTofu state and pool land on the host (default: `~/vm-lab`)
- `vm_os_image` -- Fedora Cloud Base Generic qcow2 URL
- `vm_password` -- cloud-init password (default: `fedora`; disposable lab only)
- `vm_crashkernel` -- crashkernel reservation size (default: `512M`)
- `vm_install_debuginfo` -- set to `false` for faster builds when vmlinux is not needed
