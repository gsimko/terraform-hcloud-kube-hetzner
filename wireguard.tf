resource "wireguard_asymmetric_key" "key" {
  for_each = local.nodes
}

resource "wireguard_asymmetric_key" "client" {
}

data "wireguard_config_document" "config" {
  for_each = local.nodes

  private_key = wireguard_asymmetric_key.key[each.key].private_key
  listen_port = 51820
  firewall_mark = "0x6819348"
  addresses   = ["${each.value.private_ipv4_address}/16"]
  # post_up = [
  #   "iptables -I OUTPUT ! -o wg0 -m mark ! --mark $(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"
  # ]
  # pre_down = [
  #   "iptables -D OUTPUT ! -o wg0 -m mark ! --mark $(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"
  # ]

  peer {
    public_key  = wireguard_asymmetric_key.client.public_key
    allowed_ips = ["0.0.0.0/0"]
    persistent_keepalive = 25
  }

  dynamic peer {
    for_each = { for k, v in local.nodes: k => v if k != each.key }
    content {
      public_key  = wireguard_asymmetric_key.key[peer.key].public_key
      endpoint    = "${peer.value.ipv4_address}:51820"
      allowed_ips = ["${peer.value.private_ipv4_address}/32"]
      persistent_keepalive = 25
    }
  }
}

data "wireguard_config_document" "client_config" {
  private_key = wireguard_asymmetric_key.client.private_key
  dynamic peer {
    for_each = { for k, v in local.nodes: k => v if k != each.key }
    content {
      public_key  = wireguard_asymmetric_key.key[peer.key].public_key
      endpoint    = "${peer.value.ipv4_address}:51820"
      allowed_ips = ["${peer.value.private_ipv4_address}/32"]
      persistent_keepalive = 25
    }
  }
}

resource "null_resource" "install_wireguard" {
  for_each = local.nodes

  triggers = {
    agent_id = each.value.id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = null
    host           = each.value.ipv4_address
    port           = var.ssh_port
  }

  provisioner "file" {
    content     = data.wireguard_config_document.config[each.key].conf
    destination = "/etc/wireguard/wg0.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "systemctl enable wg-quick@wg0.service",
      "systemctl reload-or-restart wg-quick@wg0.service",
    ]
  }
#   provisioner "file" {
#     content     = var.ssh_private_key
#     destination = "/tmp/k"
#   }

#   provisioner "file" {
#     content = join("\n", flatten([
#       "[Interface]",
#       "PrivateKey = $(cat /tmp/privatekey)",
#       "ListenPort = 51820",
#       "Address = ${module.control_planes[each.key].private_ipv4_address}/16",
#       "SaveConfig = true",
#       [for key, value in module.agents : [
#         "[Peer]",
#         "PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey')",
#         "Endpoint = ${value.ipv4_address}:51820",
#         "AllowedIPs = ${value.private_ipv4_address}/32",
#         "PersistentKeepalive = 25",
#       ]],
#       [for key, value in module.control_planes : [
#         "[Peer]",
#         "PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey')",
#         "Endpoint = ${value.ipv4_address}:51820",
#         "AllowedIPs = ${value.private_ipv4_address}/32",
#         "PersistentKeepalive = 25",
#       ]],
#     ]))
#     destination = "/etc/wireguard/wg0.conf"
#   }
}