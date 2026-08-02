output "vm_name" {
  description = "libvirt domain name of the created VM."
  value       = libvirt_domain.vm0.name
}

output "vm_ip" {
  description = "IPv4 address leased to the VM. Populated because the NIC sets wait_for_lease."
  value       = libvirt_domain.vm0.network_interface[0].addresses[0]
}

output "vm_user" {
  description = "Login user created by cloud-init."
  value       = var.vm_user
}

output "vm_password" {
  description = "Password for vm_user."
  value       = var.vm_password
  sensitive   = true
}

output "pool_name" {
  description = "libvirt storage pool backing the VM volumes."
  value       = libvirt_pool.main.name
}

output "network_name" {
  description = "libvirt NAT network the VM is attached to."
  value       = libvirt_network.main.name
}
