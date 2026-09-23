param(
    [string]$SubscriptionId = "",
    [string]$Location = "eastus"
)

$ErrorActionPreference = "Stop"
$resourceGroup = "rg-tfstate-prod"
$storageAccount = "sttfstateagri1a564"
$container = "tfstate"

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
}

az group create --name $resourceGroup --location $Location --output none
az storage account create `
    --name $storageAccount `
    --resource-group $resourceGroup `
    --location $Location `
    --sku Standard_LRS `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --output none
az storage account blob-service-properties update `
    --account-name $storageAccount `
    --resource-group $resourceGroup `
    --enable-versioning true `
    --output none
az storage container create `
    --name $container `
    --account-name $storageAccount `
    --auth-mode login `
    --output none

Write-Host "Remote state bootstrap is ready: $resourceGroup/$storageAccount/$container"
Write-Host "Next: terraform init -migrate-state"
