terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.20.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  base_cidr_block = "10.0.0.0/16"
}

module "subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.base_cidr_block

  networks = [
    {
      name     = "example-virtual-machine"
      new_bits = 8
    },
    {
      name     = "example-kubernetes"
      new_bits = 4
    }
  ]
}

# CREATED MANUALLY IN AZURE PORTAL AND IMPORTED BELOW
data "azurerm_ssh_public_key" "example-bastion-server" {
  name                = "example-bastion-server"
  resource_group_name = "example-virtual-machine"
}

# CREATED MANUALLY IN AZURE PORTAL AND IMPORTED BELOW
data "azurerm_ssh_public_key" "example-kubernetes-node" {
  name                = "example-kubernetes-node"
  resource_group_name = "example-kubernetes"
}

resource "azurerm_resource_group" "example-network" {
  location = "West US 3"
  name     = "example-network"
}

resource "azurerm_resource_group" "example-virtual-machine" {
  name     = "example-virtual-machine"
  location = "West US 3"
}

resource "azurerm_resource_group" "example-kubernetes" {
  name     = "example-kubernetes"
  location = "West US 3"
}

resource "azurerm_virtual_network" "example-network" {
  name                = "example-network"
  location            = azurerm_resource_group.example-network.location
  resource_group_name = azurerm_resource_group.example-network.name
  address_space       = [local.base_cidr_block]
}

resource "azurerm_subnet" "example-virtual-machine" {
  name                 = "example-virtual-machine"
  resource_group_name  = azurerm_resource_group.example-network.name
  virtual_network_name = azurerm_virtual_network.example-network.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["example-virtual-machine"]]
}

resource "azurerm_subnet" "example-kubernetes" {
  name                 = "example-kubernetes"
  resource_group_name  = azurerm_resource_group.example-network.name
  virtual_network_name = azurerm_virtual_network.example-network.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["example-kubernetes"]]
}

resource "azurerm_public_ip" "example-bastion-server" {
  name                = "example-bastion-server"
  resource_group_name = azurerm_resource_group.example-virtual-machine.name
  location            = azurerm_resource_group.example-virtual-machine.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "example-bastion-server" {
  name                = "example-bastion-server"
  resource_group_name = azurerm_resource_group.example-virtual-machine.name
  location            = azurerm_resource_group.example-virtual-machine.location

  ip_configuration {
    name                          = "example-bastion-server"
    subnet_id                     = azurerm_subnet.example-virtual-machine.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.example-bastion-server.id
  }
}

resource "azurerm_network_security_group" "example-bastion-server" {
  name                = "example-bastion-server"
  location            = azurerm_resource_group.example-virtual-machine.location
  resource_group_name = azurerm_resource_group.example-virtual-machine.name

  security_rule {
    access                     = "Allow"
    direction                  = "Inbound"
    name                       = "ssh"
    priority                   = 100
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_range     = "22"
    destination_address_prefix = azurerm_network_interface.example-bastion-server.private_ip_address
  }
}

resource "azurerm_network_interface_security_group_association" "example-bastion-server" {
  network_interface_id      = azurerm_network_interface.example-bastion-server.id
  network_security_group_id = azurerm_network_security_group.example-bastion-server.id
}

resource "azurerm_linux_virtual_machine" "example-bastion-server" {
  admin_username        = "example"
  location              = azurerm_resource_group.example-virtual-machine.location
  name                  = "example-bastion-server"
  network_interface_ids = [azurerm_network_interface.example-bastion-server.id]
  resource_group_name   = azurerm_resource_group.example-virtual-machine.name
  size                  = "Standard_B1s"

  admin_ssh_key {
    # CREATED MANUALLY IN AZURE PORTAL AND IMPORTED ABOVE
    public_key = data.azurerm_ssh_public_key.example-bastion-server.public_key
    username   = "example"
  }

  os_disk {
    disk_size_gb         = 50
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }
}

resource "azurerm_kubernetes_cluster" "example-kubernetes" {
  azure_policy_enabled                = false
  dns_prefix                          = "example-kubernetes"
  http_application_routing_enabled    = false
  kubernetes_version                  = "1.23.8"
  location                            = azurerm_resource_group.example-kubernetes.location
  name                                = "example-kubernetes"
  node_resource_group                 = "example-kubernetes-node-group"
  oidc_issuer_enabled                 = false
  open_service_mesh_enabled           = false
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = true
  private_dns_zone_id                 = "System"
  resource_group_name                 = azurerm_resource_group.example-kubernetes.name
  role_based_access_control_enabled   = true
  run_command_enabled                 = true

  linux_profile {
    admin_username = "example"

    ssh_key {
      # CREATED MANUALLY IN AZURE PORTAL AND IMPORTED ABOVE
      key_data = data.azurerm_ssh_public_key.example-kubernetes-node.public_key
    }
  }

  default_node_pool {
    name              = "system"
    vm_size           = "Standard_B2s"
    vnet_subnet_id    = azurerm_subnet.example-kubernetes.id
    os_disk_size_gb   = 50
    ultra_ssd_enabled = false

    enable_auto_scaling = false
    min_count           = null
    node_count          = 3
    max_count           = null
    max_pods            = 120
  }

  network_profile {
    docker_bridge_cidr = "172.17.0.1/16"
    dns_service_ip     = "192.168.0.2"
    load_balancer_sku  = "standard"
    network_plugin     = "azure"
    network_policy     = "calico"
    service_cidr       = "192.168.0.0/16"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "example-kubernetes" {
  principal_id         = azurerm_kubernetes_cluster.example-kubernetes.kubelet_identity[0].object_id
  role_definition_name = "Network Contributor"
  scope                = azurerm_virtual_network.example-network.id
}
