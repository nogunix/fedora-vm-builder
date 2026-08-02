# The single disposable VM: cloud-init disk, downloaded base image, a
# copy-on-write overlay on top of it, and the domain itself.

locals {
  vm_name = "${var.vm_prefix}_vm0"

  # Byte/MiB conversions live here so the resource bodies stay declarative.
  vm_memory_mib = var.vm_memory * 1024
  vm_disk_bytes = var.vm_disk_size * 1024 * 1024 * 1024
}

resource "libvirt_cloudinit_disk" "vm0" {
  name = "${local.vm_name}_cloudinit.iso"
  pool = libvirt_pool.main.name

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname             = "${var.vm_prefix}-vm0"
    vm_user              = var.vm_user
    vm_password          = var.vm_password
    vm_kdump_enabled     = var.vm_kdump_enabled
    vm_crashkernel       = var.vm_crashkernel
    vm_install_debuginfo = var.vm_install_debuginfo
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    vm_mac = var.vm_mac
  })
}

# Base image, downloaded once and shared as the backing file for the overlay.
resource "libvirt_volume" "base" {
  name   = "${local.vm_name}_os_image.qcow2"
  pool   = libvirt_pool.main.name
  source = var.vm_os_image
  format = "qcow2"
}

resource "libvirt_volume" "vm0" {
  name           = "${local.vm_name}.qcow2"
  pool           = libvirt_pool.main.name
  base_volume_id = libvirt_volume.base.id
  format         = "qcow2"
  size           = local.vm_disk_bytes
}

resource "libvirt_domain" "vm0" {
  name      = local.vm_name
  vcpu      = var.vm_vcpu
  memory    = local.vm_memory_mib
  autostart = true

  cloudinit = libvirt_cloudinit_disk.vm0.id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.main.id
    mac        = var.vm_mac

    # Blocks the apply until the DHCP lease exists, so the `vm_ip` output is
    # populated and Ansible never has to poll `virsh domifaddr`.
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.vm0.id
    scsi      = "true"
  }

  # Serial console: required to read the crash-kernel boot on a kdump capture.
  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = "true"
  }
}
