module "control_planes" {
  source = "./modules/host"

  providers = {
    hcloud = hcloud,
  }

  for_each = local.control_plane_nodes

  name                         = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${each.value.nodepool_name}"
  microos_snapshot_id          = substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.microos_arm_snapshot.id : data.hcloud_image.microos_x86_snapshot.id
  base_domain                  = var.base_domain
  ssh_keys                     = length(var.ssh_hcloud_key_label) > 0 ? concat([local.hcloud_ssh_key_id], data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.id) : [local.hcloud_ssh_key_id]
  ssh_port                     = var.ssh_port
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_additional_public_keys   = length(var.ssh_hcloud_key_label) > 0 ? concat(var.ssh_additional_public_keys, data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.public_key) : var.ssh_additional_public_keys
  firewall_ids                 = [hcloud_firewall.k3s.id]
  placement_group_id           = var.placement_group_disable ? null : (each.value.placement_group == null ? hcloud_placement_group.control_plane[each.value.placement_group_compat_idx].id : hcloud_placement_group.control_plane_named[each.value.placement_group].id)
  location                     = each.value.location
  server_type                  = each.value.server_type
  backups                      = each.value.backups
  ipv4_subnet_id               = null
  dns_servers                  = var.dns_servers
  cloudinit_write_files_common = local.cloudinit_write_files_common
  cloudinit_runcmd_common      = local.cloudinit_runcmd_common
  zram_size                    = each.value.zram_size
  use_private_network          = var.use_private_network

  private_ipv4 = cidrhost(local.control_cidr_ranges[each.value.nodepool_index], each.value.index + 1)

  labels = merge(local.labels, local.labels_control_plane_node)

  depends_on = [
    hcloud_placement_group.control_plane,
  ]
}

locals {
  k3s-config = { for k, v in local.control_plane_nodes : k => merge(
    {
      node-name = module.control_planes[k].name
      cluster-init = v.nodepool_index == 0 && v.index == 0 ? true : false
      server = length(module.control_planes) == 1 || (v.nodepool_index == 0 && v.index == 0) ? null : "https://${
        module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
      }:6443"
      token                       = local.k3s_token
      disable-cloud-controller    = true
      disable-kube-proxy          = var.disable_kube_proxy
      disable                     = local.disable_extras
      kubelet-arg                 = concat(local.kubelet_arg, var.k3s_global_kubelet_args, var.k3s_control_plane_kubelet_args, v.kubelet_args)
      kube-controller-manager-arg = local.kube_controller_manager_arg
      flannel-iface               = local.flannel_iface
      node-external-ip            = module.control_planes[k].ipv4_address
      node-ip                     = module.control_planes[k].private_ipv4_address
      advertise-address           = module.control_planes[k].private_ipv4_address
      bind-address                = module.control_planes[k].private_ipv4_address
      node-label                  = v.labels
      node-taint                  = v.taints
      selinux                     = true
      cluster-cidr                = var.cluster_ipv4_cidr
      service-cidr                = var.service_ipv4_cidr
      cluster-dns                 = var.cluster_dns_ipv4
      write-kubeconfig-mode       = "0644" # needed for import into rancher
      tls-san = concat([module.control_planes[k].ipv4_address], var.additional_tls_sans)
    },
    lookup(local.cni_k3s_settings, var.cni_plugin, {}),
    local.etcd_s3_snapshots,
    var.control_planes_custom_config
  ) }
}

resource "null_resource" "install_k3s_on_control_planes" {
  for_each = local.control_plane_nodes

  triggers = {
    control_plane_id = module.control_planes[each.key].id
    config           = sha1(yamlencode(local.k3s-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Generating k3s server config file
  provisioner "file" {
    content     = yamlencode(local.k3s-config[each.key])
    destination = "/tmp/config.yaml"
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = concat(
      [local.k3s_config_update_script],
      local.install_k3s_server
    )
  }

  # Start the k3s server and wait for it to have started correctly
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s 2> /dev/null",
      # prepare the needed directories
      "mkdir -p /var/post_install /var/user_kustomize",
      # wait for the server to be ready
      <<-EOT
      timeout 360 bash <<EOF
        until systemctl status k3s > /dev/null; do
          systemctl start k3s 2> /dev/null
          echo "Waiting for the k3s server to start..."
          sleep 3
        done
      EOF
      EOT
    ]
  }

  depends_on = [
    null_resource.install_wireguard,
  ]
}
