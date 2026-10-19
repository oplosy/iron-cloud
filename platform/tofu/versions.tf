terraform {
  required_version = ">= 1.9"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # departments.sh passes workspace_dir; one workspace (state) per department.
  backend "local" {}
}

# Platform admin: identity, quotas, networking and DNS for every department.
provider "openstack" {
  cloud = "kolla-admin"
}

# Same admin user scoped to the department project. Nova has no "create in project X" call,
# so instances need a token for that project. Auth is delayed until first use (provider
# default), which is after the project and the role assignment exist. Credentials are passed
# explicitly: with `cloud` set, clouds.yaml's project_name wins over tenant_name.
provider "openstack" {
  alias               = "dept"
  auth_url            = var.os_auth.auth_url
  user_name           = var.os_auth.username
  password            = var.os_auth.password
  user_domain_name    = var.os_auth.user_domain_name
  project_domain_name = var.os_auth.project_domain_name
  tenant_name         = var.department
  region              = "RegionOne"
}
