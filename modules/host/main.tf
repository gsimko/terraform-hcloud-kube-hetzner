resource "hcloud_server" "server" {
  name               = var.name
  image              = var.microos_snapshot_id
  server_type        = var.server_type
  location           = var.location
  ssh_keys           = var.ssh_keys
  firewall_ids       = var.firewall_ids
  placement_group_id = var.placement_group_id
  backups            = var.backups
  user_data          = data.cloudinit_config.config.rendered

  labels = var.labels

  # Prevent destroying the whole cluster if the user changes
  # any of the attributes that force to recreate the servers.
  lifecycle {
    ignore_changes = [
      location,
      ssh_keys,
      user_data,
      image,
    ]
  }
}

data "cloudinit_config" "config" {
  gzip          = true
  base64_encode = true

  # Main cloud-config configuration file.
  part {
    filename     = "init.cfg"
    content_type = "text/cloud-config"
    content = <<-EOT
      #cloud-config

      write_files:

      ${var.cloudinit_write_files_common}

      # Add ssh authorized keys
      ssh_authorized_keys:
      %{ for key in concat([var.ssh_public_key], var.ssh_additional_public_keys) ~}
        - ${key}
      %{ endfor ~}

      # Resize /var, not /, as that's the last partition in MicroOS image.
      growpart:
          devices: ["/var"]

      # Make sure the hostname is set correctly
      hostname: ${var.name}
      preserve_hostname: true

      runcmd:

      ${var.cloudinit_runcmd_common}
    EOT
  }
}

# resource "null_resource" "zram" {
#   triggers = {
#     zram_size = var.zram_size
#   }

#   connection {
#     user           = "root"
#     private_key    = var.ssh_private_key
#     agent_identity = local.ssh_agent_identity
#     host           = hcloud_server.server.ipv4_address
#     port           = var.ssh_port
#   }

#   provisioner "file" {
#     content     = <<-EOT
# #!/bin/bash

# # Switching off swap
# swapoff /dev/zram0

# rmmod zram
#     EOT
#     destination = "/usr/local/bin/k3s-swapoff"
#   }

#   provisioner "file" {
#     content     = <<-EOT
# #!/bin/bash

# # get the amount of memory in the machine
# # load the dependency module
# modprobe zram

# # initialize the device with zstd compression algorithm
# echo zstd > /sys/block/zram0/comp_algorithm;
# echo ${var.zram_size} > /sys/block/zram0/disksize

# # Creating the swap filesystem
# mkswap /dev/zram0

# # Switch the swaps on
# swapon -p 100 /dev/zram0
#     EOT
#     destination = "/usr/local/bin/k3s-swapon"
#   }

#   # Setup zram if it's enabled
#   provisioner "file" {
#     content     = <<-EOT
# [Unit]
# Description=Swap with zram
# After=multi-user.target

# [Service]
# Type=oneshot
# RemainAfterExit=true
# ExecStart=/usr/local/bin/k3s-swapon
# ExecStop=/usr/local/bin/k3s-swapoff

# [Install]
# WantedBy=multi-user.target
#     EOT
#     destination = "/etc/systemd/system/zram.service"
#   }

#   provisioner "remote-exec" {
#     inline = concat(var.zram_size != "" ? [
#       "chmod +x /usr/local/bin/k3s-swapon",
#       "chmod +x /usr/local/bin/k3s-swapoff",
#       "systemctl disable --now zram.service",
#       "systemctl enable --now zram.service",
#       ] : [
#       "systemctl disable --now zram.service",
#     ])
#   }

#   depends_on = [hcloud_server.server]
# }
