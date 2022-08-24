terraform {
  required_version = "~> 1.1.8"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.1.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 0.1.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.2.0"
    }
  }
}

module "subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.subnet_addrs.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 8
    },
    {
      name     = "vm"
      new_bits = 8
    },
    {
      name     = "pe"
      new_bits = 8
    },
    {
      name     = "gw"
      new_bits = 11
    },
    {
      name     = "aci"
      new_bits = 8
    },
  ]
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}

resource "azurerm_resource_group" "openvpn_sample" {
  name     = local.rg.name
  location = local.rg.location
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-default"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location
  address_space       = [module.subnet_addrs.base_cidr_block]
}

resource "azurerm_subnet" "default" {
  name                 = "snet-default"
  resource_group_name  = azurerm_resource_group.openvpn_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["default"]]
}


resource "azurerm_subnet" "vm" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.default
  ]
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.openvpn_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["vm"]]
}

resource "azurerm_subnet" "pe" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.vm
  ]
  name                                           = "snet-pe"
  resource_group_name                            = azurerm_resource_group.openvpn_sample.name
  virtual_network_name                           = azurerm_virtual_network.default.name
  address_prefixes                               = [module.subnet_addrs.network_cidr_blocks["pe"]]
}

resource "azurerm_subnet" "gw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.pe
  ]
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.openvpn_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["gw"]]
}

resource "azurerm_subnet" "aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.gw
  ]
  name                 = "snet-aci"
  resource_group_name  = azurerm_resource_group.openvpn_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location
}

resource "azurerm_network_interface" "target" {
  name                          = "nic-target"
  resource_group_name           = azurerm_resource_group.openvpn_sample.name
  location                      = azurerm_resource_group.openvpn_sample.location
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "target" {
  network_interface_id      = azurerm_network_interface.target.id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "target" {
  name                            = "vmtarget"
  resource_group_name             = azurerm_resource_group.openvpn_sample.name
  location                        = azurerm_resource_group.openvpn_sample.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.target.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    diff_disk_settings {
      option = "Local"
    }
    disk_size_gb = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "aad_login_linux_target" {
  name                       = "AADLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.target.id
  publisher                  = "Microsoft.Azure.ActiveDirectory.LinuxSSH"
  type                       = "AADLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_private_dns_zone" "sample_site_web" {
  name                = "privatelink.web.core.windows.net"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
}

resource "azurerm_private_dns_zone" "sample_site_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sample_site_web" {
  name                  = "pdnsz-link-sample-site-web"
  resource_group_name   = azurerm_resource_group.openvpn_sample.name
  private_dns_zone_name = azurerm_private_dns_zone.sample_site_web.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "sample_site_blob" {
  name                  = "pdnsz-link-sample-site-blob"
  resource_group_name   = azurerm_resource_group.openvpn_sample.name
  private_dns_zone_name = azurerm_private_dns_zone.sample_site_blob.name
  virtual_network_id    = azurerm_virtual_network.default.id
}


resource "azurerm_storage_account" "sample_site" {
  name                     = "${var.prefix}ovpnsample"
  resource_group_name      = azurerm_resource_group.openvpn_sample.name
  location                 = azurerm_resource_group.openvpn_sample.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    default_action = "Deny"
  }

  static_website {
    index_document = "index.html"
  }
}

resource "azurerm_private_endpoint" "sample_site_web" {
  name                = "pe-sample-site-web"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location
  subnet_id           = azurerm_subnet.pe.id

  private_dns_zone_group {
    name                 = "pdnsz-group-sample-site-web"
    private_dns_zone_ids = [azurerm_private_dns_zone.sample_site_web.id]
  }

  private_service_connection {
    name                           = "pe-connection-sample-site-web"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.sample_site.id
    subresource_names              = ["web"]
  }
}

resource "azurerm_private_endpoint" "sample_site_blob" {
  name                = "pe-sample-site-blob"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location
  subnet_id           = azurerm_subnet.pe.id

  private_dns_zone_group {
    name                 = "pdnsz-group-sample-site-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.sample_site_blob.id]
  }

  private_service_connection {
    name                           = "pe-connection-sample-site-blob"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.sample_site.id
    subresource_names              = ["blob"]
  }
}

resource "azurerm_public_ip" "vpngw" {
  name                = "pip-vpngw"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.prefix}-vpngw-openvpn-sample"
}

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  validity_period_hours = 8766
  early_renewal_hours   = 720
  is_ca_certificate     = true
  dns_names             = [azurerm_public_ip.vpngw.domain_name_label]

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
    "cert_signing"
  ]

  subject {
    common_name  = "OpenVPN Sample CA"
    organization = "openvpn-sample"
  }
}

data "external" "ca_cert_der" {
  program = ["/bin/bash", "-c", "${path.module}/scripts/ca_cert_convert_encode.sh"]

  query = {
    ca_cert_pem = tls_self_signed_cert.ca.cert_pem
  }
}

resource "azurerm_virtual_network_gateway" "openvpn_sample" {
  name                = "vpng-openvpn-sample"
  resource_group_name = azurerm_resource_group.openvpn_sample.name
  location            = azurerm_resource_group.openvpn_sample.location

  type = "Vpn"

  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "ipconf-vpngw"
    public_ip_address_id          = azurerm_public_ip.vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gw.id
  }

  vpn_client_configuration {
    address_space        = [local.subnet_addrs.client_cidr_block]
    aad_tenant           = local.aad.tenant
    aad_audience         = local.aad.audience
    aad_issuer           = local.aad.issuer
    vpn_auth_types       = ["AAD", "Certificate"]
    vpn_client_protocols = ["OpenVPN"]

    root_certificate {
      name             = "selfsigned"
      public_cert_data = data.external.ca_cert_der.result["ca_cert_der"]
    }
  }
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "dns_forwarder" {
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-dns-forwarder"
  parent_id = azurerm_resource_group.openvpn_sample.id

  body = jsonencode({
    location = azurerm_resource_group.openvpn_sample.location
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 53
            protocol = "UDP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "config"
          secret = {
            Corefile = base64encode(file("${path.module}/config/coredns/Corefile"))
          }
        }
      ]

      containers = [
        {
          name = "coredns"
          properties = {
            image = "coredns/coredns:1.9.1"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 53
                protocol = "UDP"
              }
            ]

            command = ["/coredns", "-conf", "/config/Corefile"]

            volumeMounts = [
              {
                name      = "config"
                readOnly  = true
                mountPath = "/config"
              }
            ]
          }
        }
      ]
    }
  })

  response_export_values = ["properties.ipAddress.ip"]
}

resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "tls_cert_request" "client_cert_req" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name  = "OpenVPN Sample Client"
    organization = "openvpn-sample"
  }
}

resource "tls_locally_signed_cert" "client_cert" {
  cert_request_pem      = tls_cert_request.client_cert_req.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8766

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

data "external" "openvpn_config" {
  program = ["/bin/bash", "-c", "${path.module}/scripts/openvpn_config_gen.sh"]

  query = {
    vpngw_id         = azurerm_virtual_network_gateway.openvpn_sample.id
    dns_forwarder_ip = jsondecode(azapi_resource.dns_forwarder.output).properties.ipAddress.ip
    client_key_pem   = tls_private_key.client.private_key_pem
    client_cert_pem  = tls_locally_signed_cert.client_cert.cert_pem
  }
}

resource "azurerm_key_vault" "openvpn_sample" {
  name                       = "${var.prefix}-kv-ovpn-sample"
  resource_group_name        = azurerm_resource_group.openvpn_sample.name
  location                   = azurerm_resource_group.openvpn_sample.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Backup",
      "Delete",
      "Get",
      "List",
      "Purge",
      "Recover",
      "Restore",
      "Set",
    ]
  }
}

resource "azurerm_key_vault_secret" "ca_private_key" {
  name         = "ca-private-key"
  value        = tls_private_key.ca.private_key_pem
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}

resource "azurerm_key_vault_secret" "ca_cert" {
  name         = "ca-cert"
  value        = tls_self_signed_cert.ca.cert_pem
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}

resource "azurerm_key_vault_secret" "client_private_key" {
  name         = "client-private-key"
  value        = tls_private_key.client.private_key_pem
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}

resource "azurerm_key_vault_secret" "client_cert" {
  name         = "client-cert"
  value        = tls_locally_signed_cert.client_cert.cert_pem
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}

resource "azurerm_key_vault_secret" "openvpn_config" {
  name         = "openvpn-config"
  value        = data.external.openvpn_config.result["openvpn_config"]
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}

resource "azurerm_key_vault_secret" "openvpn_config_systemd_resolved" {
  name         = "openvpn-config-systemd-resolved"
  value        = data.external.openvpn_config.result["openvpn_config_systemd_resolved"]
  key_vault_id = azurerm_key_vault.openvpn_sample.id
}
