variable "department" {
  description = "Department name; also the YAML file name, project name and DNS label."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.department))
    error_message = "Department name must be 2-21 chars: lowercase letters, digits, dashes."
  }
}

variable "os_auth" {
  description = "Platform admin credentials (kolla-admin in clouds.yaml); departments.sh sets TF_VAR_os_auth."
  sensitive   = true
  type = object({
    auth_url            = string
    username            = string
    password            = string
    user_domain_name    = string
    project_domain_name = string
  })
}

variable "departments_dir" {
  description = "Directory holding <department>.yaml request files."
  type        = string
}

variable "shared_services_ip" {
  description = "ctl1's address on the provider network: DNS for departments, source of platform access."
  type        = string
  default     = "10.20.1.10"
}

variable "dns_domain" {
  type    = string
  default = "ironcloud.lab"
}

# Lab capacity per department (17 GB of nested RAM in total).
variable "platform_limits" {
  type = object({
    instances    = number
    cores        = number
    ram_mb       = number
    volumes      = number
    gigabytes    = number
    floating_ips = number
  })
  default = {
    instances    = 4
    cores        = 4
    ram_mb       = 1024
    volumes      = 4
    gigabytes    = 8
    floating_ips = 4
  }
}

# Read from Nova when null. Tests set it: vcpus/ram are not computed in the provider schema,
# so tofu test cannot mock them.
variable "flavor_sizes" {
  type    = map(object({ vcpus = number, ram = number }))
  default = null
}
