output "project_id" {
  value = openstack_identity_project_v3.dept.id
}

output "vms" {
  value = { for name, port in openstack_networking_port_v2.vm : name => {
    fixed    = port.all_fixed_ips[0]
    floating = openstack_networking_floatingip_v2.vm[name].address
    fqdn     = "${name}.${local.zone}"
  } }
}

output "admin_user" {
  value = openstack_identity_user_v3.dept_admin.name
}

output "admin_password" {
  value     = random_password.dept_admin.result
  sensitive = true
}
