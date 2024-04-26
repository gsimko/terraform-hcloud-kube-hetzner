resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

data "hcloud_image" "microos_x86_snapshot" {
  with_selector     = "microos-snapshot=yes"
  with_architecture = "x86"
  most_recent       = true
}

data "hcloud_image" "microos_arm_snapshot" {
  with_selector     = "microos-snapshot=yes"
  with_architecture = "arm"
  most_recent       = true
}

resource "hcloud_ssh_key" "k3s" {
  count      = var.hcloud_ssh_key_id == null ? 1 : 0
  name       = var.cluster_name
  public_key = var.ssh_public_key
  labels     = local.labels
}

resource "hcloud_network" "k3s" {
  count    = local.use_existing_network || !var.use_private_network ? 0 : 1
  name     = var.cluster_name
  ip_range = var.network_ipv4_cidr
  labels   = local.labels
}

data "hcloud_network" "k3s" {
  count = var.use_private_network ? 1 : 0
  id = local.use_existing_network ? var.existing_network_id[0] : hcloud_network.k3s[0].id
}

resource "hcloud_firewall" "k3s" {
  name   = var.cluster_name
  labels = local.labels

  dynamic "rule" {
    for_each = local.firewall_rules_list
    content {
      description     = rule.value.description
      direction       = rule.value.direction
      protocol        = rule.value.protocol
      port            = lookup(rule.value, "port", null)
      destination_ips = lookup(rule.value, "destination_ips", [])
      source_ips      = lookup(rule.value, "source_ips", [])
    }
  }
}