resource "tls_private_key" "cluster_keypair" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "random_id" "cluster_keypair_id" {
  byte_length = 4
}

resource "opentelekomcloud_compute_keypair_v2" "cluster_keypair" {
  name       = "${var.name}-cluster-keypair-${random_id.cluster_keypair_id.hex}"
  public_key = tls_private_key.cluster_keypair.public_key_openssh
}

resource "opentelekomcloud_vpc_eip_v1" "cce_eip" {
  count = var.cluster_config_public_cluster ? 1 : 0
  bandwidth {
    charge_mode = "traffic"
    name        = "${var.name}-cluster-kubectl-endpoint"
    share_type  = "PER"
    size        = 50
  }
  tags = var.tags
  publicip {
    type = "5_bgp"
  }
}

resource "random_id" "id" {
  count       = var.node_config_node_storage_encryption_enabled ? 1 : 0
  byte_length = 4
}

resource "opentelekomcloud_kms_key_v1" "node_storage_encryption_key" {
  count           = var.node_config_node_storage_encryption_enabled ? 1 : 0
  key_alias       = "${var.name}-node-pool-${random_id.id[0].hex}"
  key_description = "${var.name} CCE Node Pool volume encryption key"
  pending_days    = 7
  is_enabled      = "true"
}

locals {
  node_storage_encryption_enabled = data.opentelekomcloud_identity_project_v3.current.region != "eu-de" ? false : local.node_config.node_storage_encryption_enabled
  flavor_id = "cce.${var.cluster_config_cluster_type == "BareMetal" ? "t" : "s"}${var.cluster_config_high_availability ? 2 : 1}.${lower(var.cluster_config_cluster_size)}"
}

resource "opentelekomcloud_cce_cluster_v3" "cluster" {
  name                    = var.name
  cluster_type            = var.cluster_config_cluster_type
  flavor_id               = local.flavor_id
  vpc_id                  = var.cluster_config_vpc_id
  subnet_id               = var.cluster_config_subnet_id
  container_network_type  = local.cluster_config_container_network_type
  container_network_cidr  = var.cluster_config_container_cidr
  kubernetes_svc_ip_range = var.cluster_config_service_cidr
  description             = "Kubernetes Cluster ${var.name}."
  eip                     = var.cluster_config_public_cluster ? opentelekomcloud_vpc_eip_v1.cce_eip[0].publicip[0].ip_address : null
  cluster_version         = var.cluster_config_cluster_version
  authentication_mode     = "x509"
  annotations             = var.cluster_config_install_icagent ? { "cluster.install.addons.external/install" = jsonencode([{ addonTemplateName = "icagent" }]) } : null

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

resource "opentelekomcloud_cce_node_pool_v3" "cluster_node_pool" {
  count              = length(var.node_config_availability_zones)
  cluster_id         = opentelekomcloud_cce_cluster_v3.cluster.id
  name               = "${var.name}-nodes-${var.node_config_availability_zones[count.index]}"
  flavor             = var.node_config_node_flavor
  initial_node_count = var.node_config_node_count
  availability_zone  = var.node_config_availability_zones[count.index]
  key_pair           = opentelekomcloud_compute_keypair_v2.cluster_keypair.name
  os                 = var.node_config_node_os

  scale_enable             = var.cluster_config_enable_scaling
  min_node_count           = local.autoscaling_config_nodes_min
  max_node_count           = var.autoscaling_config_nodes_max
  scale_down_cooldown_time = 15
  priority                 = 1
  user_tags                = var.tags
  docker_base_size         = 20
  postinstall              = var.node_config_node_postinstall

  root_volume {
    size       = 50
    volumetype = "SSD"
    kms_id     = var.node_config_node_storage_encryption_enabled ? opentelekomcloud_kms_key_v1.node_storage_encryption_key[0].id : null
  }

  data_volumes {
    size       = var.node_config_node_storage_size
    volumetype = var.node_config_node_storage_type
    kms_id     = var.node_config_node_storage_encryption_enabled ? opentelekomcloud_kms_key_v1.node_storage_encryption_key[0].id : null
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }
}
