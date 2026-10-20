# Plan-time checks of department requests, with mocked OpenStack (no lab needed).
# Run from platform/tofu: tofu init -backend=false && tofu test

mock_provider "openstack" {
  # Mocked computed lists are empty; DNS records and outputs index the port's first address.
  mock_resource "openstack_networking_port_v2" {
    defaults = { all_fixed_ips = ["192.0.2.10"] }
  }
}

mock_provider "openstack" {
  alias = "dept"
}

variables {
  # Same sizes as the lab's m1.tiny.
  flavor_sizes    = { "m1.tiny" = { vcpus = 1, ram = 256 } }
  departments_dir = "../../departments"
  os_auth = {
    auth_url            = "http://mock.invalid:5000/v3"
    username            = "mock"
    password            = "mock"
    user_domain_name    = "Default"
    project_domain_name = "Default"
  }
}

run "engineering_request_fits" {
  command = plan
  variables { department = "engineering" }

  assert {
    condition     = length(openstack_compute_instance_v2.vm) == 2 && openstack_compute_quotaset_v2.dept.instances == 2
    error_message = "engineering should plan 2 VMs under a 2-instance quota."
  }
  assert {
    condition     = openstack_networking_subnet_v2.dept.cidr == "192.168.20.0/24" && openstack_networking_subnet_v2.dept.dns_nameservers == tolist(["10.20.1.10"])
    error_message = "engineering subnet should use its requested CIDR and the shared DNS."
  }
}

run "finance_request_fits" {
  command = plan
  variables { department = "finance" }

  assert {
    condition     = keys(openstack_compute_instance_v2.vm) == ["ledger"]
    error_message = "finance should plan exactly the ledger VM."
  }
}

run "removed_yaml_plans_no_vms" {
  command = plan
  variables { department = "gone" }

  assert {
    condition     = length(openstack_compute_instance_v2.vm) == 0
    error_message = "A department without a YAML file must plan no VMs."
  }
}

run "vms_over_quota_rejected" {
  command = plan
  variables {
    department      = "over-quota"
    departments_dir = "tests/fixtures"
  }
  expect_failures = [openstack_identity_project_v3.dept]
}

run "quota_over_platform_limit_rejected" {
  command = plan
  variables {
    department      = "over-limit"
    departments_dir = "tests/fixtures"
  }
  expect_failures = [openstack_identity_project_v3.dept]
}

run "platform_cidr_rejected" {
  command = plan
  variables {
    department      = "platform-cidr"
    departments_dir = "tests/fixtures"
  }
  expect_failures = [openstack_identity_project_v3.dept]
}

run "bad_department_name_rejected" {
  command = plan
  variables { department = "Bad_Name" }
  expect_failures = [var.department]
}
