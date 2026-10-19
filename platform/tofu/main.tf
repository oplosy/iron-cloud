locals {
  request_file = "${var.departments_dir}/${var.department}.yaml"
  # A removed YAML means "tear the department down": departments.sh then runs destroy,
  # which still evaluates the config, so an empty request stands in for the file.
  request = fileexists(local.request_file) ? yamldecode(file(local.request_file)) : {
    description = "", cidr = "192.0.2.0/24", vms = []
    quota       = { instances = 0, cores = 0, ram_mb = 0, volumes = 0, gigabytes = 0, floating_ips = 0 }
  }
  quota = local.request.quota
  vms = { for vm in local.request.vms : vm.name => {
    flavor  = vm.flavor
    image   = try(vm.image, "cirros")
    disk_gb = try(vm.disk_gb, 1)
  } }
  zone = "${var.department}.${var.dns_domain}."

  requested = {
    instances = length(local.vms)
    cores     = sum(concat([0], [for vm in local.vms : data.openstack_compute_flavor_v2.vm[vm.flavor].vcpus]))
    ram_mb    = sum(concat([0], [for vm in local.vms : data.openstack_compute_flavor_v2.vm[vm.flavor].ram]))
    volumes   = length(local.vms)
    gigabytes = sum(concat([0], [for vm in local.vms : vm.disk_gb]))
  }
}

data "openstack_networking_network_v2" "public" {
  name = "public"
}

data "openstack_compute_flavor_v2" "vm" {
  for_each = toset([for vm in local.vms : vm.flavor])
  name     = each.key
}

data "openstack_images_image_v2" "vm" {
  for_each    = toset([for vm in local.vms : vm.image])
  name        = each.key
  most_recent = true
}

data "openstack_identity_role_v3" "member" {
  name = "member"
}

data "openstack_identity_role_v3" "admin" {
  name = "admin"
}

data "openstack_identity_auth_scope_v3" "platform" {
  name = "platform"
}

# --- Identity and quotas ---

resource "openstack_identity_project_v3" "dept" {
  name        = var.department
  description = local.request.description

  # Checked at plan time, so a bad request creates nothing.
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in var.platform_limits : local.quota[k] <= v])
      error_message = "Quota ${jsonencode(local.quota)} exceeds the platform limit per department ${jsonencode(var.platform_limits)}."
    }
    precondition {
      condition     = alltrue([for k, v in local.requested : v <= local.quota[k]])
      error_message = "Requested VMs need ${jsonencode(local.requested)}, which does not fit the department quota ${jsonencode(local.quota)}."
    }
    precondition {
      condition     = length(local.vms) <= local.quota.floating_ips
      error_message = "Every VM gets a floating IP: ${length(local.vms)} VMs but floating_ips quota is ${local.quota.floating_ips}."
    }
    precondition {
      condition     = can(cidrnetmask(local.request.cidr)) && !startswith(local.request.cidr, "10.20.")
      error_message = "cidr must be a valid IPv4 network outside the platform range 10.20.0.0/16."
    }
  }
}

resource "random_password" "dept_admin" {
  length  = 24
  special = false
}

resource "openstack_identity_user_v3" "dept_admin" {
  name               = "${var.department}-admin"
  default_project_id = openstack_identity_project_v3.dept.id
  password           = random_password.dept_admin.result
}

resource "openstack_identity_role_assignment_v3" "dept_admin" {
  project_id = openstack_identity_project_v3.dept.id
  user_id    = openstack_identity_user_v3.dept_admin.id
  role_id    = data.openstack_identity_role_v3.member.id
}

# Lets the platform user get a token for this project (the "dept" provider).
resource "openstack_identity_role_assignment_v3" "platform" {
  project_id = openstack_identity_project_v3.dept.id
  user_id    = data.openstack_identity_auth_scope_v3.platform.user_id
  role_id    = data.openstack_identity_role_v3.admin.id
}

resource "openstack_compute_quotaset_v2" "dept" {
  project_id = openstack_identity_project_v3.dept.id
  instances  = local.quota.instances
  cores      = local.quota.cores
  ram        = local.quota.ram_mb
}

resource "openstack_blockstorage_quotaset_v3" "dept" {
  project_id = openstack_identity_project_v3.dept.id
  volumes    = local.quota.volumes
  gigabytes  = local.quota.gigabytes
}

resource "openstack_networking_quota_v2" "dept" {
  project_id = openstack_identity_project_v3.dept.id
  floatingip = local.quota.floating_ips
  network    = 1
  subnet     = 1
  router     = 1
}

# --- Network: one isolated network per department, routed out through the provider network ---

# Quotas go first: Neutron rejects a quota below current usage, and an in-flight router
# create counts as usage, so setting both in parallel fails intermittently.
resource "openstack_networking_network_v2" "dept" {
  name       = "${var.department}-net"
  tenant_id  = openstack_identity_project_v3.dept.id
  depends_on = [openstack_networking_quota_v2.dept]
}

resource "openstack_networking_subnet_v2" "dept" {
  name            = "${var.department}-subnet"
  network_id      = openstack_networking_network_v2.dept.id
  tenant_id       = openstack_identity_project_v3.dept.id
  cidr            = local.request.cidr
  dns_nameservers = [var.shared_services_ip]
}

resource "openstack_networking_router_v2" "dept" {
  name                = "${var.department}-router"
  tenant_id           = openstack_identity_project_v3.dept.id
  external_network_id = data.openstack_networking_network_v2.public.id
  depends_on          = [openstack_networking_quota_v2.dept]
}

resource "openstack_networking_router_interface_v2" "dept" {
  router_id = openstack_networking_router_v2.dept.id
  subnet_id = openstack_networking_subnet_v2.dept.id
}

# Isolation: VMs accept traffic only from their own department and from the platform's
# shared-services address. Other departments reach them only through floating IPs,
# which arrive from their router's address and are dropped here.
resource "openstack_networking_secgroup_v2" "vm" {
  name        = "${var.department}-vm"
  description = "Managed by IronCloud: same-department traffic and platform access only"
  tenant_id   = openstack_identity_project_v3.dept.id
}

resource "openstack_networking_secgroup_rule_v2" "same_department" {
  security_group_id = openstack_networking_secgroup_v2.vm.id
  tenant_id         = openstack_identity_project_v3.dept.id
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.vm.id
}

resource "openstack_networking_secgroup_rule_v2" "platform" {
  for_each          = { icmp = null, tcp = 22 }
  security_group_id = openstack_networking_secgroup_v2.vm.id
  tenant_id         = openstack_identity_project_v3.dept.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.key
  port_range_min    = each.value
  port_range_max    = each.value
  remote_ip_prefix  = "${var.shared_services_ip}/32"
}

resource "openstack_networking_port_v2" "vm" {
  for_each           = local.vms
  name               = "${var.department}-${each.key}"
  network_id         = openstack_networking_network_v2.dept.id
  tenant_id          = openstack_identity_project_v3.dept.id
  security_group_ids = [openstack_networking_secgroup_v2.vm.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.dept.id
  }
}

resource "openstack_networking_floatingip_v2" "vm" {
  for_each   = local.vms
  pool       = data.openstack_networking_network_v2.public.name
  tenant_id  = openstack_identity_project_v3.dept.id
  port_id    = openstack_networking_port_v2.vm[each.key].id
  depends_on = [openstack_networking_router_interface_v2.dept]
}

# --- VMs (created inside the department project) ---

resource "openstack_compute_instance_v2" "vm" {
  provider  = openstack.dept
  for_each  = local.vms
  name      = each.key
  flavor_id = data.openstack_compute_flavor_v2.vm[each.value.flavor].id
  key_pair  = "ironcloud-ops"

  network {
    port = openstack_networking_port_v2.vm[each.key].id
  }

  block_device {
    uuid                  = data.openstack_images_image_v2.vm[each.value.image].id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = each.value.disk_gb
    boot_index            = 0
    delete_on_termination = true
  }

  depends_on = [
    openstack_identity_role_assignment_v3.platform,
    openstack_compute_quotaset_v2.dept,
    openstack_blockstorage_quotaset_v3.dept,
  ]
}

# --- DNS: <vm>.<department>.ironcloud.lab, served by the shared resolver ---

resource "openstack_dns_zone_v2" "dept" {
  name        = local.zone
  email       = "hostmaster@${var.dns_domain}"
  ttl         = 300
  description = "Department ${var.department}"
}

resource "openstack_dns_recordset_v2" "vm" {
  for_each = local.vms
  zone_id  = openstack_dns_zone_v2.dept.id
  name     = "${each.key}.${local.zone}"
  type     = "A"
  ttl      = 300
  records  = [openstack_networking_port_v2.vm[each.key].all_fixed_ips[0]]
}
