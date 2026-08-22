# fedora-vm-builder

[![Lint](https://github.com/nogunix/fedora-vm-builder/actions/workflows/lint.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/lint.yml)
[![Test](https://github.com/nogunix/fedora-vm-builder/actions/workflows/test.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/test.yml)
[![Fedora Image Check](https://github.com/nogunix/fedora-vm-builder/actions/workflows/fedora-image-check.yml/badge.svg)](https://github.com/nogunix/fedora-vm-builder/actions/workflows/fedora-image-check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ansible + OpenTofu builder for disposable Fedora VMs with kdump and kernel debuginfo pre-configured. Uses libvirt/KVM.

## Prerequisites

- Linux host with libvirt/KVM (Fedora, RHEL, or CentOS Stream)
- Ansible (`pip install ansible`)
- OpenTofu >= 1.6 (`tofu` in PATH)
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

`vars.yml` is the only file you need to touch. Ansible converts it into
`terraform.tfvars.json` (via the mapping in `tfvars.yml`) and hands it to the
OpenTofu project in `terraform/`.

## Layout

```
01-create-vm.yml     Create the VM and verify kdump is operational
99-destroy-all.yml   Tear everything down
vars.yml             User-facing settings
tfvars.yml           vars.yml -> OpenTofu input variable mapping
terraform/           Static OpenTofu project (no templating)
  versions.tf          OpenTofu + provider version constraints
  variables.tf         Typed, validated input variables
  main.tf              Storage pool + NAT network
  vm.tf                cloud-init disk, volumes, domain
  outputs.tf           vm_ip, vm_name, pool/network names
  templates/           cloud-init and network-config templates
```

The playbooks copy `terraform/` into `vm_tf_dir` (`~/vm-lab/work` by default)
and run OpenTofu there, so state and downloaded providers stay out of the repo
and `99-destroy-all.yml` can remove the whole lab directory.

## What Gets Built

- libvirt storage pool (`vm_prefix`)
- NAT network with DHCP (`vm_prefix_network`)
- Fedora Cloud VM with:
  - User `fedora` / password `fedora` (sudo NOPASSWD)
  - kdump enabled with `crashkernel=512M`
  - `kernel-debuginfo` installed (vmlinux available)
  - Serial console + VNC

## Coming from the Terraform version

Some releases drove Terraform instead of OpenTofu. If you have a lab left over
from one, `vm_tf_dir` still holds a lock file pinned to `registry.terraform.io`,
which `tofu init` will not install. You do not need to clean it up by hand — run

```bash
ansible-playbook 99-destroy-all.yml
```

first. The playbook re-initialises the directory before destroying, so OpenTofu
takes over the existing state, and the `virsh` fallbacks catch anything it
cannot. Then create a fresh VM as usual.

The `terraform/` directory name and `terraform.tfvars.json` are kept as-is:
OpenTofu reads both natively, and renaming them would churn every path in the
docs and CI for no functional gain. `versions.tf` likewise keeps its
`terraform {}` block, which OpenTofu accepts.

To go back to Terraform, set `vm_tf_binary: terraform` in `vars.yml` and
regenerate the lock file — `cloud.terraform.terraform` drives either binary.

## Provider version

The libvirt provider is pinned to `~> 0.8.3`. The 0.9 line is a full schema
rewrite in which `libvirt_domain` drops `cloudinit`, `wait_for_lease` and
`base_volume_id` in favour of a raw libvirt-XML mapping; migrating is a separate
piece of work.

## License

MIT
