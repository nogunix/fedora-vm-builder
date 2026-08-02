variable "libvirt_uri" {
  description = "libvirt connection URI the provider talks to."
  type        = string
  default     = "qemu:///system"
}

variable "vm_prefix" {
  description = "Name prefix applied to every libvirt resource (pool, network, volumes, domain)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]*$", var.vm_prefix))
    error_message = "vm_prefix must start with an alphanumeric character and contain only letters, digits, '-' and '_'."
  }
}

variable "vm_pool_dir" {
  description = "Absolute host path backing the libvirt directory storage pool."
  type        = string

  validation {
    condition     = startswith(var.vm_pool_dir, "/")
    error_message = "vm_pool_dir must be an absolute path."
  }
}

variable "vm_os_image" {
  description = "URL or local path of the Fedora Cloud Base Generic qcow2 image used as the backing volume."
  type        = string
}

variable "vm_vcpu" {
  description = "Number of virtual CPUs assigned to the VM."
  type        = number

  validation {
    condition     = var.vm_vcpu >= 1
    error_message = "vm_vcpu must be at least 1."
  }
}

variable "vm_memory" {
  description = "VM memory in GiB. Converted to the MiB unit libvirt expects."
  type        = number

  validation {
    # kdump reserves crashkernel out of this, so anything under 2 GiB leaves
    # the production kernel starved once 512M is carved off.
    condition     = var.vm_memory >= 2
    error_message = "vm_memory must be at least 2 (GiB) to leave room for the crashkernel reservation."
  }
}

variable "vm_disk_size" {
  description = "VM root disk size in GiB. Converted to bytes for the libvirt volume."
  type        = number

  validation {
    # kernel-debuginfo alone is several GiB before any vmcore is written.
    condition     = var.vm_disk_size >= 10
    error_message = "vm_disk_size must be at least 10 (GiB) to fit kernel debuginfo plus a captured vmcore."
  }
}

variable "vm_user" {
  description = "Login user created by cloud-init, with passwordless sudo."
  type        = string
}

variable "vm_password" {
  description = "Password for vm_user. Disposable lab credential — never reuse a real one."
  type        = string
  sensitive   = true
}

variable "vm_network_subnet" {
  description = "CIDR of the NAT network libvirt creates and serves DHCP on."
  type        = string

  validation {
    condition     = can(cidrhost(var.vm_network_subnet, 0))
    error_message = "vm_network_subnet must be a valid CIDR block, e.g. 192.168.200.0/24."
  }
}

variable "vm_network_bridge" {
  description = "Host bridge interface name libvirt creates for the NAT network."
  type        = string

  validation {
    # Linux caps interface names at IFNAMSIZ-1 = 15 bytes.
    condition     = length(var.vm_network_bridge) <= 15
    error_message = "vm_network_bridge must be 15 characters or fewer."
  }
}

variable "vm_mac" {
  description = "MAC address pinned on the VM NIC so the cloud-init network config can match it."
  type        = string

  validation {
    condition     = can(regex("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", var.vm_mac))
    error_message = "vm_mac must be a colon-separated MAC address, e.g. 52:54:00:fe:da:01."
  }
}

variable "vm_kdump_enabled" {
  description = "Reserve crashkernel memory, enable the kdump service and reboot once during cloud-init."
  type        = bool
  default     = true
}

variable "vm_crashkernel" {
  description = "crashkernel reservation passed to grubby. 256M OOMs the crash kernel; 512M is the safe minimum."
  type        = string
  default     = "512M"

  validation {
    condition     = can(regex("^[0-9]+[MG]$", var.vm_crashkernel))
    error_message = "vm_crashkernel must be a size such as 512M or 1G."
  }
}

variable "vm_install_debuginfo" {
  description = "Install kernel-core debuginfo at build time so vmlinux is present before the first crash."
  type        = bool
  default     = true
}
