module "agents" {
  source = "./modules/host"

  providers = {
    hcloud = hcloud,
  }

  for_each = local.agent_nodes

  name                         = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${each.value.nodepool_name}${try(each.value.node_name_suffix, "")}-${each.value.index}"
  microos_snapshot_id          = substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.microos_arm_snapshot.id : data.hcloud_image.microos_x86_snapshot.id
  base_domain                  = var.base_domain
  ssh_keys                     = length(var.ssh_hcloud_key_label) > 0 ? concat([local.hcloud_ssh_key_id], data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.id) : [local.hcloud_ssh_key_id]
  ssh_port                     = var.ssh_port
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_additional_public_keys   = length(var.ssh_hcloud_key_label) > 0 ? concat(var.ssh_additional_public_keys, data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.public_key) : var.ssh_additional_public_keys
  firewall_ids                 = [hcloud_firewall.k3s.id]
  placement_group_id           = var.placement_group_disable ? null : (each.value.placement_group == null ? hcloud_placement_group.agent[each.value.placement_group_compat_idx].id : hcloud_placement_group.agent_named[each.value.placement_group].id)
  location                     = each.value.location
  server_type                  = each.value.server_type
  backups                      = each.value.backups
  ipv4_subnet_id               = null
  dns_servers                  = var.dns_servers
  cloudinit_write_files_common = local.cloudinit_write_files_common
  cloudinit_runcmd_common      = local.cloudinit_runcmd_common
  use_private_network          = var.use_private_network

  private_ipv4 = cidrhost(local.agent_cidr_ranges[each.value.nodepool_index], each.value.index + 1)

  labels = merge(local.labels, local.labels_agent_node)

  depends_on = [
    hcloud_placement_group.agent
  ]
}

# resource "null_resource" "agents_add_wg" {
#   for_each = local.agent_nodes

#   triggers = {
#     agent_id = module.agents[each.key].id
#   }

#   connection {
#     user           = "root"
#     private_key    = var.ssh_private_key
#     agent_identity = null
#     host           = module.agents[each.key].ipv4_address
#     port           = var.ssh_port
#   }

#   provisioner "file" {
#     content     = var.ssh_private_key
#     destination = "/tmp/k"
#   }

#   provisioner "remote-exec" {
#     inline = flatten(
#       [
#         "set -ex",
#         "chmod 600 /tmp/k",
#         "ip link add dev wg0 type wireguard || echo wg0 already exists",

#         "echo [Interface] > /tmp/wgconfig.conf",
#         "echo PrivateKey = $(cat /tmp/privatekey) >> /tmp/wgconfig.conf",
#         "echo ListenPort = 51820 >> /tmp/wgconfig.conf",
#         [for key, value in module.agents : [
#           "echo [Peer] >> /tmp/wgconfig.conf",
#           "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
#           "echo Endpoint = ${value.ipv4_address}:51820 >> /tmp/wgconfig.conf",
#           "echo AllowedIPs = ${value.private_ipv4_address}/32 >> /tmp/wgconfig.conf",
#           "echo PersistentKeepalive = 25 >> /tmp/wgconfig.conf",
#         ]],
#         [for key, value in module.control_planes : [
#           "echo [Peer] >> /tmp/wgconfig.conf",
#           "echo PublicKey = $(ssh root@${value.ipv4_address} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/k 'cat /tmp/publickey') >> /tmp/wgconfig.conf",
#           "echo Endpoint = ${value.ipv4_address}:51820 >> /tmp/wgconfig.conf",
#           "echo AllowedIPs = ${value.private_ipv4_address}/32 >> /tmp/wgconfig.conf",
#           "echo PersistentKeepalive = 25 >> /tmp/wgconfig.conf",
#         ]],
#         "ip address replace dev wg0 ${module.agents[each.key].private_ipv4_address}/16",
#         "wg setconf wg0 /tmp/wgconfig.conf",
#         "ip link set up dev wg0",
#         "rm /tmp/k",
#       ]
#     )
#   }
# }

locals {
  k3s-agent-config = { for k, v in local.agent_nodes : k => merge(
    {
      node-name     = module.agents[k].name
      server        = "https://${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token         = local.k3s_token
      kubelet-arg   = concat(local.kubelet_arg, var.k3s_global_kubelet_args, var.k3s_agent_kubelet_args, v.kubelet_args)
      flannel-iface = local.flannel_iface
      node-external-ip = module.agents[k].ipv4_address
      node-ip          = module.agents[k].ipv4_address
      node-label    = v.labels
      node-taint    = v.taints
    },
    var.agent_nodes_custom_config,
    (v.selinux == true ? { selinux = true } : {})
  ) }
}

resource "null_resource" "install_k3s_on_agents" {
  for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
    config   = sha1(yamlencode(local.k3s-agent-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Generating k3s agent config file
  provisioner "file" {
    content     = yamlencode(local.k3s-agent-config[each.key])
    destination = "/tmp/config.yaml"
  }

  # Install k3s agent
  provisioner "remote-exec" {
    inline = local.install_k3s_agent
  }

  # Start the k3s agent and wait for it to have started
  provisioner "remote-exec" {
    inline = concat(var.enable_longhorn || var.enable_iscsid ? ["systemctl enable --now iscsid"] : [], [
      "systemctl start k3s-agent 2> /dev/null",
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status k3s-agent > /dev/null; do
          systemctl start k3s-agent 2> /dev/null
          echo "Waiting for the k3s agent to start..."
          sleep 2
        done
      EOF
      EOT
    ])
  }

  depends_on = [
    null_resource.install_wireguard,
  ]
}

resource "hcloud_volume" "longhorn_volume" {
  for_each = { for k, v in local.agent_nodes : k => v if((v.longhorn_volume_size >= 10) && (v.longhorn_volume_size <= 10000) && var.enable_longhorn) }

  labels = {
    provisioner = "terraform"
    cluster     = var.cluster_name
    scope       = "longhorn"
  }
  name              = "${var.cluster_name}-longhorn-${module.agents[each.key].name}"
  size              = local.agent_nodes[each.key].longhorn_volume_size
  server_id         = module.agents[each.key].id
  automount         = true
  format            = var.longhorn_fstype
  delete_protection = var.enable_delete_protection.volume
}

resource "null_resource" "configure_longhorn_volume" {
  for_each = { for k, v in local.agent_nodes : k => v if((v.longhorn_volume_size >= 10) && (v.longhorn_volume_size <= 10000) && var.enable_longhorn) }

  triggers = {
    agent_id = module.agents[each.key].id
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir /var/longhorn >/dev/null 2>&1",
      "mount -o discard,defaults ${hcloud_volume.longhorn_volume[each.key].linux_device} /var/longhorn",
      "${var.longhorn_fstype == "ext4" ? "resize2fs" : "xfs_growfs"} ${hcloud_volume.longhorn_volume[each.key].linux_device}",
      "echo '${hcloud_volume.longhorn_volume[each.key].linux_device} /var/longhorn ${var.longhorn_fstype} discard,nofail,defaults 0 0' >> /etc/fstab"
    ]
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  depends_on = [
    hcloud_volume.longhorn_volume
  ]
}