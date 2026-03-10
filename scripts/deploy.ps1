#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploy TD SYNNEX Azure CSP Cost Reporting infrastructure.

.DESCRIPTION
  Deploys a Storage Account and a Cost Management Export in either:
    • subscription   – export scoped to the target subscription (managed identity auth)
    • billingAccount – export scoped to a CSP Billing Account (SAS token auth)

  Two-phase deployment for subscription mode:
    Phase 1: Deploy export-sub.bicep → capture managed identity principal ID
    Phase 2: Deploy main.bicep       → storage account + role assignment

  One-phase deployment for billingAccount mode:
    Phase 1: Deploy main.bicep            → storage account
    Phase 2: Deploy export-billing.bicep  → billing account export (SAS token)

.EXAMPLE
  # Subscription mode (recommended)
  ./deploy.ps1 -Mode subscription -SubscriptionId <sub> -ResourceGroup rg-costexports `
               -StorageAccountName stcostexports -Location swedencentral

  # Billing Account mode
  ./deploy.ps1 -Mode billingAccount -SubscriptionId <sub> -ResourceGroup rg-costexports `
               -StorageAccountName stcostexports -BillingAccountId <id>
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('subscription','billingAccount')]
  [string]$Mode,

  [Parameter(Mandatory)] [string]$SubscriptionId,
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$StorageAccountName,

  [Parameter()] [string]$Location            = 'swedencentral',
  [Parameter()] [string]$ContainerName       = 'cost-exports',
  [Parameter()] [string]$ExportName          = 'daily-cost-export',
  [Parameter()] [string]$RootFolderPath      = 'exports',

  # Required for billingAccount mode only
  [Parameter()] [string]$BillingAccountId    = '',

  # Export definition
  [Parameter()] [ValidateSet('Csv','Parquet')]
  [string]$Format                            = 'Csv',
  [Parameter()] [ValidateSet('ActualCost','AmortizedCost','FocusCost','Usage')]
  [string]$DefinitionType                    = 'ActualCost',
  [Parameter()] [ValidateSet('Daily','Monthly')]
  [string]$Granularity                       = 'Daily',
  [Parameter()] [ValidateSet('MonthToDate','BillingMonthToDate','TheCurrentMonth','TheLastMonth','WeekToDate','Custom')]
  [string]$Timeframe                         = 'MonthToDate',
  [Parameter()] [string]$TimePeriodFrom      = '',
  [Parameter()] [string]$TimePeriodTo        = '',

  # Schedule
  [Parameter()] [ValidateSet('Daily','Weekly','Monthly','Annually')]
  [string]$Recurrence                        = 'Daily',
  [Parameter()] [ValidateSet('Active','Inactive')]
  [string]$ScheduleStatus                    = 'Active',
  [Parameter()] [string]$RecurrenceTo        = '2099-12-31T00:00:00Z',

  [Parameter()] [object]$Tags                = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Pre-flight checks ─────────────────────────────────────────────────────────

Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

# Check Az CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  Write-Error "Azure CLI (az) not found. Install from https://aka.ms/installazurecli"
  exit 1
}

# Check logged in
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
  Write-Error "Not logged in to Azure CLI. Run: az login"
  exit 1
}
Write-Host "  Logged in as: $($account.user.name)" -ForegroundColor Green

# Check billing account supplied for billingAccount mode
if ($Mode -eq 'billingAccount' -and [string]::IsNullOrWhiteSpace($BillingAccountId)) {
  Write-Error "-BillingAccountId is required when Mode is 'billingAccount'."
  exit 1
}

# Check Custom timeframe has dates
if ($Timeframe -eq 'Custom' -and ([string]::IsNullOrWhiteSpace($TimePeriodFrom) -or [string]::IsNullOrWhiteSpace($TimePeriodTo))) {
  Write-Error "-TimePeriodFrom and -TimePeriodTo are required when Timeframe is 'Custom'."
  exit 1
}

# Check storage account name length
if ($StorageAccountName.Length -lt 3 -or $StorageAccountName.Length -gt 24) {
  Write-Error "StorageAccountName must be 3–24 characters."
  exit 1
}

# Check storage account name availability
$avail = az storage account check-name --name $StorageAccountName | ConvertFrom-Json
if (-not $avail.nameAvailable -and $avail.reason -ne 'AlreadyExists') {
  Write-Error "Storage account name '$StorageAccountName' is not available: $($avail.message)"
  exit 1
}
if (-not $avail.nameAvailable) {
  Write-Warning "  Storage account '$StorageAccountName' already exists — will reuse."
} else {
  Write-Host "  Storage account name '$StorageAccountName' is available." -ForegroundColor Green
}

Write-Host "  Mode: $Mode | Location: $Location" -ForegroundColor Green
Write-Host "  Pre-flight passed.`n" -ForegroundColor Green

# ── Setup ─────────────────────────────────────────────────────────────────────

az account set --subscription $SubscriptionId
az group create -n $ResourceGroup -l $Location --tags ($Tags | ConvertTo-Json -Compress) | Out-Null
Write-Host "Resource group '$ResourceGroup' ready." -ForegroundColor Cyan

$recurrenceFrom = (Get-Date).AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$tagsJson       = $Tags | ConvertTo-Json -Compress

$commonExportParams = @(
  "exportName=$ExportName"
  "containerName=$ContainerName"
  "rootFolderPath=$RootFolderPath"
  "format=$Format"
  "definitionType=$DefinitionType"
  "granularity=$Granularity"
  "timeframe=$Timeframe"
  "recurrence=$Recurrence"
  "scheduleStatus=$ScheduleStatus"
  "recurrenceFrom=$recurrenceFrom"
  "recurrenceTo=$RecurrenceTo"
)

if ($Timeframe -eq 'Custom') {
  $commonExportParams += "timePeriodFrom=$TimePeriodFrom"
  $commonExportParams += "timePeriodTo=$TimePeriodTo"
}

# ── Subscription mode ─────────────────────────────────────────────────────────

if ($Mode -eq 'subscription') {
  Write-Host "`n=== Phase 1: Deploy storage account ===" -ForegroundColor Cyan

  $storageOut = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file ./bicep/main.bicep `
    --parameters storageAccountName=$StorageAccountName containerName=$ContainerName location=$Location tags=$tagsJson `
    --query properties.outputs -o json | ConvertFrom-Json

  $saId = $storageOut.storageAccountResourceId.value
  Write-Host "  Storage account deployed: $saId" -ForegroundColor Green

  Write-Host "`n=== Phase 2: Deploy subscription-scope export ===" -ForegroundColor Cyan

  $exportOut = az deployment sub create `
    --location $Location `
    --template-file ./bicep/export-sub.bicep `
    --parameters storageAccountResourceId=$saId location=$Location @commonExportParams `
    --query properties.outputs -o json | ConvertFrom-Json

  $principalId = $exportOut.managedIdentityPrincipalId.value
  Write-Host "  Export deployed. Managed identity principal ID: $principalId" -ForegroundColor Green

  Write-Host "`n=== Phase 3: Assign Storage Blob Data Contributor role ===" -ForegroundColor Cyan

  az deployment group create `
    --resource-group $ResourceGroup `
    --template-file ./bicep/main.bicep `
    --parameters storageAccountName=$StorageAccountName containerName=$ContainerName location=$Location `
                 exportManagedIdentityPrincipalId=$principalId tags=$tagsJson `
    --query properties.outputs | Out-Null

  Write-Host "  Role assignment complete." -ForegroundColor Green
}

# ── Billing Account mode ──────────────────────────────────────────────────────

if ($Mode -eq 'billingAccount') {
  Write-Host "`n=== Phase 1: Deploy storage account ===" -ForegroundColor Cyan

  $storageOut = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file ./bicep/main.bicep `
    --parameters storageAccountName=$StorageAccountName containerName=$ContainerName location=$Location tags=$tagsJson `
    --query properties.outputs -o json | ConvertFrom-Json

  $saId       = $storageOut.storageAccountResourceId.value
  $accountKey = az storage account keys list -n $StorageAccountName -g $ResourceGroup --query [0].value -o tsv
  $expiry     = (Get-Date).AddYears(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $sas        = az storage container generate-sas `
                  --account-name $StorageAccountName --account-key $accountKey `
                  --name $ContainerName --permissions acwl --expiry $expiry -o tsv
  $sasNoQ     = $sas.TrimStart('?')

  Write-Host "  Storage account deployed and SAS token generated." -ForegroundColor Green

  Write-Host "`n=== Phase 2: Deploy billing account export ===" -ForegroundColor Cyan

  az deployment tenant create `
    --location $Location `
    --template-file ./bicep/export-billing.bicep `
    --parameters billingAccountId=$BillingAccountId storageAccountResourceId=$saId sasToken=$sasNoQ @commonExportParams `
    --query properties.outputs

  Write-Host "  Billing account export deployed." -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "  Mode:            $Mode"
Write-Host "  Resource Group:  $ResourceGroup"
Write-Host "  Storage Account: $StorageAccountName"
Write-Host "  Export Name:     $ExportName"
Write-Host "  Container:       $ContainerName/$RootFolderPath"
Write-Host ""
Write-Host "Next step: Open Power BI Desktop, import powerbi/tdsynnex-theme.json,"
Write-Host "paste powerbi/queries.pq into a Blank Query, set parameters, then add"
Write-Host "the measures from powerbi/measures.dax."
