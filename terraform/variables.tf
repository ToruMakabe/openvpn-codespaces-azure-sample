variable "prefix" {
  type = string
}

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}
