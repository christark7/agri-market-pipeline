# Agri market ingestion

This project provisions a South Central US storage pipeline, Central US SQL database, and Central US Python Function App. The Function runs daily at 06:00 UTC, writes raw API responses to the `raw-market-data` Blob container, and stages landed JSON into SQL with an idempotent procedure. Failed payloads are copied to `raw-market-data-deadletter` with error metadata.

## Local development

```powershell
Copy-Item local.settings.json.example local.settings.json
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
func start
```

Use a real development storage connection string in `local.settings.json`. Do not commit that file.

## Infrastructure deployment

```powershell
terraform init
terraform validate
terraform plan
terraform apply -auto-approve
```

## Remote Terraform state

The `azurerm` backend is configured in `main.tf`. Bootstrap it once before the first backend initialization:

```powershell
.\scripts\bootstrap-tfstate.ps1
terraform init -migrate-state
```

Review the migration prompt carefully. The backend uses Entra authentication and Blob versioning for recovery. Do not commit `terraform.tfstate` or local settings.

The Function App uses a system-assigned managed identity in Azure. Terraform grants it Blob Data Contributor access to the storage account and Key Vault Secrets User access to the vault. Deploy the Python package after infrastructure creation:

```powershell
func azure functionapp publish <function_app_name> --python
```

The fallback API is a currency exchange endpoint. Set `MARKET_DATA_API_URL` to the approved agricultural market or weather API before production use.

## SQL and dashboard

Run `sql/schema_and_analytics.sql` against `sqldb-agri-market` with an Entra-authenticated SQL administrator. It creates the staging table, unique deduplication index, SQL staging procedure, Power BI analytics views, and an NBS-aligned `vw_nigeria_top10_agrofoods` view. Load official NBS observations into `dbo.nbs_agrofood_prices` with their publication date and source URL; the view intentionally does not invent current prices.

The script also maps the Function managed identity to a database user and grants only reader, writer, and stored-procedure execution permissions. Run that section after the Function App exists and replace the identity name if Terraform outputs a different Function name.

The DAX measures and a readable green/mint dashboard layout are in `dashboard/`. Use the publication date beside every Nigeria agro-food figure and enable a single-select currency-pair slicer.

## GitHub Actions

Create these repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. Configure the matching Entra federated credentials for the `main` branch and pull requests, then use `.github/workflows/deploy.yml`. The workflow validates and plans on pull requests and applies infrastructure plus the Function package on `main`.

For the first remote-state migration, an Owner or User Access Administrator must grant the signed-in user `Storage Blob Data Contributor` on `sttfstateagri1a564`. Then run `terraform init -migrate-state`. The role is scoped to the state account only.

The workflow needs subscription-level Contributor and the ability to create role assignments. Prefer a narrower resource-group scope after the initial bootstrap. Tenant-wide MFA, Conditional Access, and break-glass accounts must be configured by an Entra administrator in the tenant; this repository does not change those policies.

CI/CD workflow enabled.
