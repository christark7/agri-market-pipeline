terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod"
    storage_account_name = "sttfstateagri1a564"
    container_name       = "tfstate"
    key                  = "agri-pipeline/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

# Generate a random suffix for globally unique resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "sql_admin" {
  length           = 32
  special          = true
  override_special = "_%@"
}

# 1. Resource Group
resource "azurerm_resource_group" "agri_rg" {
  name     = "rg-agri-pipeline-dev-southcentral"
  location = "South Central US"
}

resource "azurerm_resource_group" "sql_rg" {
  name     = "rg-agri-sql-dev-central"
  location = "Central US"
}

resource "azurerm_resource_group" "function_rg" {
  name     = "rg-agri-functions-dev-central"
  location = "Central US"
}

# 2. Storage Account (Data Lake landing zone)
resource "azurerm_storage_account" "agri_storage" {
  name                            = "stagri${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.agri_rg.name
  location                        = azurerm_resource_group.agri_rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
}

# Blob Container for incoming raw market price JSON/CSV payloads
resource "azurerm_storage_container" "raw_data" {
  name                  = "raw-market-data"
  storage_account_id    = azurerm_storage_account.agri_storage.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "deadletter" {
  name                  = "raw-market-data-deadletter"
  storage_account_id    = azurerm_storage_account.agri_storage.id
  container_access_type = "private"
}

# 3. Azure SQL Server
resource "azurerm_mssql_server" "sql_server" {
  name                         = "sql-agri-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.sql_rg.name
  location                     = azurerm_resource_group.sql_rg.location
  version                      = "12.0"
  administrator_login          = "agriadmin"
  administrator_login_password = random_password.sql_admin.result

  azuread_administrator {
    login_username              = "nightchris2_outlook.com#EXT#@nightchris2outlook222.onmicrosoft.com"
    object_id                   = "34d0519a-4972-4918-9f6b-d2c41411e8da"
    tenant_id                   = "329ee042-8b92-4c46-91e9-0cbd45933d5d"
    azuread_authentication_only = false
  }
}

# 4. Azure SQL Database (Basic SKU: ~$5/month against your credits)
resource "azurerm_mssql_database" "sql_db" {
  name        = "sqldb-agri-market"
  server_id   = azurerm_mssql_server.sql_server.id
  sku_name    = "Basic"
  max_size_gb = 2
}

resource "azurerm_key_vault" "agri_vault" {
  name                       = "kv-agri-${random_string.suffix.result}"
  location                   = azurerm_resource_group.agri_rg.location
  resource_group_name        = azurerm_resource_group.agri_rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  rbac_authorization_enabled = true
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = random_password.sql_admin.result
  key_vault_id = azurerm_key_vault.agri_vault.id
  depends_on   = [azurerm_role_assignment.terraform_key_vault_access]
}

resource "azurerm_role_assignment" "terraform_key_vault_access" {
  scope                = azurerm_key_vault.agri_vault.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = "34d0519a-4972-4918-9f6b-d2c41411e8da"
}

resource "azurerm_role_assignment" "github_actions_key_vault_access" {
  scope                = azurerm_key_vault.agri_vault.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = "88e1fa0e-b678-4379-ba28-228924657bd1"
}

resource "azurerm_service_plan" "function_plan" {
  name                = "asp-agri-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.function_rg.name
  location            = azurerm_resource_group.function_rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_application_insights" "function_insights" {
  name                = "appi-agri-${random_string.suffix.result}"
  location            = azurerm_resource_group.function_rg.location
  resource_group_name = azurerm_resource_group.function_rg.name
  application_type    = "web"
}

resource "azurerm_linux_function_app" "ingest" {
  name                          = "func-agri-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.function_rg.name
  location                      = azurerm_resource_group.function_rg.location
  service_plan_id               = azurerm_service_plan.function_plan.id
  storage_account_name          = azurerm_storage_account.agri_storage.name
  storage_uses_managed_identity = true
  functions_extension_version   = "~4"
  https_only                    = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.function_insights.connection_string
    application_insights_key               = azurerm_application_insights.function_insights.instrumentation_key

    application_stack {
      python_version = "3.11"
    }
  }

 app_settings = {
  "FUNCTIONS_WORKER_RUNTIME" = "python"
  "AzureWebJobsStorage"      = azurerm_storage_account.agri_storage.primary_connection_string
  "WEBSITE_RUN_FROM_PACKAGE" = "1"
  "SQL_SERVER_FQDN"          = "sql-agri-v1a564.database.windows.net"
  "SQL_DATABASE_NAME"        = "sqldb-agri-market"
}
  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      app_settings["AzureWebJobsStorage__accountName"],
    ]
  }
}

resource "azurerm_role_assignment" "function_blob_access" {
  scope                = azurerm_storage_account.agri_storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.ingest.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_blob_owner_access" {
  scope                = azurerm_storage_account.agri_storage.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.ingest.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_queue_access" {
  scope                = azurerm_storage_account.agri_storage.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.ingest.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_file_access" {
  scope                = azurerm_storage_account.agri_storage.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azurerm_linux_function_app.ingest.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_key_vault_access" {
  scope                = azurerm_key_vault.agri_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.ingest.identity[0].principal_id
}

# Outputs to use later in your Python code
output "storage_account_name" {
  value = azurerm_storage_account.agri_storage.name
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.sql_server.fully_qualified_domain_name
}

output "function_app_name" {
  value = azurerm_linux_function_app.ingest.name
}

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.ingest.default_hostname}"
}
