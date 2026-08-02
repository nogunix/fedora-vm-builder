terraform {
  required_version = ">= 1.6.0"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # 0.9.x is a full schema rewrite (libvirt_domain loses `cloudinit`,
      # `wait_for_lease` and `base_volume_id` in favour of a raw libvirt-XML
      # mapping). Stay on the 0.8 line until that migration is done.
      version = "~> 0.8.3"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
