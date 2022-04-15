locals {
  subnet_addrs = {
    base_cidr_block   = "192.168.0.0/16"
    client_cidr_block = "10.0.0.0/8"
  }
  rg = {
    name     = "rg-openvpn-sample"
    location = "japaneast"
  }
  aad = {
    tenant   = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/"
    audience = "41b23e61-6c1e-4545-b367-cd054e0ed4b4"
    issuer   = "https://sts.windows.net/${data.azurerm_client_config.current.tenant_id}/"

  }
}

data "azurerm_client_config" "current" {}
