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

# We start from the end of the subnets cidr array,
# as we would have fewer control plane nodepools, than agent ones.
resource "hcloud_network_subnet" "control_plane" {
  count        = var.use_private_network ? length(var.control_plane_nodepools) : 0
  network_id   = var.use_private_network ? data.hcloud_network.k3s[0].id : null
  type         = "cloud"
  network_zone = var.network_region
  ip_range     = local.network_ipv4_subnets[255 - count.index]
}

# Here we start at the beginning of the subnets cidr array
resource "hcloud_network_subnet" "agent" {
  count        = var.use_private_network ? length(var.agent_nodepools) : 0
  network_id   = var.use_private_network ? data.hcloud_network.k3s[0].id : null
  type         = "cloud"
  network_zone = var.network_region
  ip_range     = local.network_ipv4_subnets[count.index]
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

resource "null_resource" "agents_wg_gen_key" {
  for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = null
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "umask 077",
      "wg genkey | tee /tmp/privatekey | wg pubkey > /tmp/publickey",
    ]
  }
}

resource "null_resource" "control_plane_wg_gen_key" {
  for_each = local.control_plane_nodes

  triggers = {
    id = module.control_planes[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = null
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "umask 077",
      "wg genkey | tee /tmp/privatekey | wg pubkey > /tmp/publickey",
    ]
  }
}

resource "null_resource" "agents_add_wg" {
  for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = null
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "file" {
    content     = var.ssh_private_key
    destination = "/tmp/k"
  }

  provisioner "remote-exec" {
    inline = flatten([
      "set -x",
      "chmod 600 /tmp/k",
      "ip link add dev wg0 type wireguard",
      "ip address add dev wg0 ${local.agent_ip_addresses[each.value.index]}/16",
      "rm /tmp/wgconfig.conf",
      "echo [Interface] >> /tmp/wgconfig.conf",
      "echo PrivateKey = $(cat /tmp/privatekey) >> /tmp/wgconfig.conf",
      "echo ListenPort = 51820 >> /tmp/wgconfig.conf",
      [for key, value in module.agents : [
        "echo [Peer] >> /tmp/wgconfig.conf",
        "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
        "echo Endpoint = ${value.ipv4_address} >> /tmp/wgconfig.conf",
        "echo AllowedIPs = ${local.agent_cidr} >> /tmp/wgconfig.conf",
      ]],
      [for key, value in module.control_planes : [
        "echo [Peer] >> /tmp/wgconfig.conf",
        "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
        "echo Endpoint = ${value.ipv4_address} >> /tmp/wgconfig.conf",
        "echo AllowedIPs = ${local.control_cidr} >> /tmp/wgconfig.conf",
      ]],
      "rm /tmp/k",
      "wg setconf wg0 /tmp/wgconfig.conf",
      "ip link set up dev wg0",
    ])
  }
}

resource "null_resource" "control_add_wg" {
  for_each = local.control_plane_nodes

  triggers = {
    agent_id = module.control_planes[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = null
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "file" {
    content     = var.ssh_private_key
    destination = "/tmp/k"
  }

  provisioner "remote-exec" {
    inline = flatten([
      "set -x",
      "chmod 600 /tmp/k",
      "ip link add dev wg0 type wireguard",
      "ip address add dev wg0 ${local.control_ip_addresses[each.value.index]}/16",
      "rm /tmp/wgconfig.conf",
      "echo [Interface] >> /tmp/wgconfig.conf",
      "echo PrivateKey = $(cat /tmp/privatekey) >> /tmp/wgconfig.conf",
      "echo ListenPort = 51820 >> /tmp/wgconfig.conf",
      [for key, value in module.agents : [
        "echo [Peer] >> /tmp/wgconfig.conf",
        "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
        "echo Endpoint = ${value.ipv4_address} >> /tmp/wgconfig.conf",
        "echo AllowedIPs = ${local.agent_cidr} >> /tmp/wgconfig.conf",
      ]],
      [for key, value in module.control_planes : [
        "echo [Peer] >> /tmp/wgconfig.conf",
        "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
        "echo Endpoint = ${value.ipv4_address} >> /tmp/wgconfig.conf",
        "echo AllowedIPs = ${local.control_cidr} >> /tmp/wgconfig.conf",
      ]],
      "rm /tmp/k",
      "wg setconf wg0 /tmp/wgconfig.conf",
      "ip link set up dev wg0",
    ])
  }
}
