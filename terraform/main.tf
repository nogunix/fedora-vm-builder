# Shared infrastructure: one storage pool and one NAT network per vm_prefix.
# A dedicated pool (rather than libvirt's system `default`) keeps this lab from
# colliding with anything else using libvirt on the same host.

resource "libvirt_pool" "main" {
  name = var.vm_prefix
  type = "dir"

  target {
    path = var.vm_pool_dir
  }
}

resource "libvirt_network" "main" {
  name      = "${var.vm_prefix}_network"
  mode      = "nat"
  addresses = [var.vm_network_subnet]
  bridge    = var.vm_network_bridge
  autostart = true

  dhcp {
    enabled = true
  }
}
