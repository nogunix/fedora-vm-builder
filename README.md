# fedora-vm-builder

[![Lint](https://github.com/nogunix/fedora-vm-builder/actions/workflows/lint.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/lint.yml)
[![Test](https://github.com/nogunix/fedora-vm-builder/actions/workflows/test.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/test.yml)
[![Fedora Image Check](https://github.com/nogunix/fedora-vm-builder/actions/workflows/fedora-image-check.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/fedora-image-check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ansible + OpenTofu builder for disposable Fedora VMs with kdump and kernel debuginfo pre-configured. Uses libvirt/KVM.

## Prerequisites

- Linux host with libvirt/KVM (Fedora, RHEL, or CentOS Stream)
- Ansible (`pip install ansible`)
- OpenTofu (`tofu` in PATH)
- `sshpass` (for password-based SSH to the VM)

## Quick Start

```bash
# Install Ansible dependencies
ansible-galaxy collection install -r requirements.yml

# Create a VM (default: Fedora 44, kdump enabled, debuginfo installed)
ansible-playbook 01-create-vm.yml

# SSH into the VM
~/vm-lab/work/fedora01_login.sh

# Capture a vmcore (inside the VM)
echo c | sudo tee /proc/sysrq-trigger

# After the VM reboots, retrieve the vmcore
scp fedora@<vm-ip>:/var/crash/*/vmcore .
scp fedora@<vm-ip>:/usr/lib/debug/lib/modules/$(ssh fedora@<vm-ip> uname -r)/vmlinux .

# Destroy everything
ansible-playbook 99-destroy-all.yml
```

## Configuration

Edit `vars.yml` before running. Key settings:

| Variable | Default | Description |
|---|---|---|
| `vm_prefix` | `fedora01` | Name prefix for libvirt resources |
| `vm_os_image` | Fedora 44 Cloud Base | Fedora cloud image URL (38–44 selectable) |
| `vm_vcpu` | `2` | vCPUs |
| `vm_memory` | `4` | RAM in GB |
| `vm_disk_size` | `20` | Disk in GB |
| `vm_crashkernel` | `512M` | crashkernel reservation |
| `vm_install_debuginfo` | `true` | Install kernel debuginfo at build time |

## What Gets Built

- libvirt storage pool (`vm_prefix`)
- NAT network with DHCP (`vm_prefix_network`)
- Fedora Cloud VM with:
  - User `fedora` / password `fedora` (sudo NOPASSWD)
  - kdump enabled with `crashkernel=512M`
  - `kernel-debuginfo` installed (vmlinux available)
  - Serial console + VNC

## License

MIT
