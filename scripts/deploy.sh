#!/usr/bin/env bash
# TD SYNNEX | Azure CSP Cost Reporting – deployment script (Bash)
# Mirrors deploy.ps1 exactly. Supports subscription and billingAccount modes.
#
# Usage:
#   subscription mode:
#     ./deploy.sh --mode subscription --subscription-id <sub> --resource-group rg-costexports \
#                 --storage-account-name stcostexports --location swedencentral
#
#   billingAccount mode:
#     ./deploy.sh --mode billingAccount --subscription-id <sub> --resource-group rg-costexports \
#                 --storage-account-name stcostexports --billing-account-id <id>

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

MODE=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
STORAGE_ACCOUNT_NAME=""
LOCATION="swedencentral"
CONTAINER_NAME="cost-exports"
EXPORT_NAME="daily-cost-export"
ROOT_FOLDER_PATH="exports"
BILLING_ACCOUNT_ID=""
FORMAT="Csv"
DEFINITION_TYPE="ActualCost"
GRANULARITY="Daily"
TIMEFRAME="MonthToDate"
TIME_PERIOD_FROM=""
TIME_PERIOD_TO=""
RECURRENCE="Daily"
SCHEDULE_STATUS="Active"
RECURRENCE_TO="2099-12-31T00:00:00Z"

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)                  MODE="$2";                  shift 2 ;;
    --subscription-id)       SUBSCRIPTION_ID="$2";       shift 2 ;;
    --resource-group)        RESOURCE_GROUP="$2";        shift 2 ;;
    --storage-account-name)  STORAGE_ACCOUNT_NAME="$2";  shift 2 ;;
    --location)              LOCATION="$2";              shift 2 ;;
    --container-name)        CONTAINER_NAME="$2";        shift 2 ;;
    --export-name)           EXPORT_NAME="$2";           shift 2 ;;
    --root-folder-path)      ROOT_FOLDER_PATH="$2";      shift 2 ;;
    --billing-account-id)    BILLING_ACCOUNT_ID="$2";    shift 2 ;;
    --format)                FORMAT="$2";                shift 2 ;;
    --definition-type)       DEFINITION_TYPE="$2";       shift 2 ;;
    --granularity)           GRANULARITY="$2";           shift 2 ;;
    --timeframe)             TIMEFRAME="$2";             shift 2 ;;
    --time-period-from)      TIME_PERIOD_FROM="$2";      shift 2 ;;
    --time-period-to)        TIME_PERIOD_TO="$2";        shift 2 ;;
    --recurrence)            RECURRENCE="$2";            shift 2 ;;
    --schedule-status)       SCHEDULE_STATUS="$2";       shift 2 ;;
    --recurrence-to)         RECURRENCE_TO="$2";         shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────

echo ""
echo "=== Pre-flight checks ==="

# Check Az CLI
if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) not found. Install from https://aka.ms/installazurecli"
  exit 1
fi

# Check logged in
ACCOUNT=$(az account show 2>/dev/null || true)
if [[ -z "$ACCOUNT" ]]; then
  echo "ERROR: Not logged in to Azure CLI. Run: az login"
  exit 1
fi
echo "  Logged in as: $(echo "$ACCOUNT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["user"]["name"])')"

# Required params
[[ -z "$MODE" ]]                 && echo "ERROR: --mode is required (subscription|billingAccount)" && exit 1
[[ -z "$SUBSCRIPTION_ID" ]]      && echo "ERROR: --subscription-id is required" && exit 1
[[ -z "$RESOURCE_GROUP" ]]       && echo "ERROR: --resource-group is required" && exit 1
[[ -z "$STORAGE_ACCOUNT_NAME" ]] && echo "ERROR: --storage-account-name is required" && exit 1

# Billing account check
if [[ "$MODE" == "billingAccount" && -z "$BILLING_ACCOUNT_ID" ]]; then
  echo "ERROR: --billing-account-id is required when --mode is billingAccount"
  exit 1
fi

# Custom timeframe check
if [[ "$TIMEFRAME" == "Custom" ]]; then
  [[ -z "$TIME_PERIOD_FROM" ]] && echo "ERROR: --time-period-from is required when --timeframe is Custom" && exit 1
  [[ -z "$TIME_PERIOD_TO" ]]   && echo "ERROR: --time-period-to is required when --timeframe is Custom" && exit 1
fi

# Storage account name length
LEN=${#STORAGE_ACCOUNT_NAME}
if [[ $LEN -lt 3 || $LEN -gt 24 ]]; then
  echo "ERROR: --storage-account-name must be 3–24 characters"
  exit 1
fi

# Storage account name availability
AVAIL=$(az storage account check-name --name "$STORAGE_ACCOUNT_NAME" -o json)
NAME_AVAIL=$(echo "$AVAIL" | python3 -c 'import sys,json; print(json.load(sys.stdin)["nameAvailable"])')
REASON=$(echo "$AVAIL"    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("reason",""))' 2>/dev/null || true)

if [[ "$NAME_AVAIL" == "False" && "$REASON" != "AlreadyExists" ]]; then
  MSG=$(echo "$AVAIL" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("message",""))')
  echo "ERROR: Storage account name '$STORAGE_ACCOUNT_NAME' unavailable: $MSG"
  exit 1
elif [[ "$NAME_AVAIL" == "False" ]]; then
  echo "  WARNING: Storage account '$STORAGE_ACCOUNT_NAME' already exists — will reuse."
else
  echo "  Storage account name '$STORAGE_ACCOUNT_NAME' is available."
fi

echo "  Mode: $MODE | Location: $LOCATION"
echo "  Pre-flight passed."
echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────

az account set --subscription "$SUBSCRIPTION_ID"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
echo "Resource group '$RESOURCE_GROUP' ready."

# Recurrence start = 1 hour from now
RECURRENCE_FROM=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)

# Build common export params array
COMMON_EXPORT_PARAMS=(
  "exportName=$EXPORT_NAME"
  "containerName=$CONTAINER_NAME"
  "rootFolderPath=$ROOT_FOLDER_PATH"
  "format=$FORMAT"
  "definitionType=$DEFINITION_TYPE"
  "granularity=$GRANULARITY"
  "timeframe=$TIMEFRAME"
  "recurrence=$RECURRENCE"
  "scheduleStatus=$SCHEDULE_STATUS"
  "recurrenceFrom=$RECURRENCE_FROM"
  "recurrenceTo=$RECURRENCE_TO"
)

if [[ "$TIMEFRAME" == "Custom" ]]; then
  COMMON_EXPORT_PARAMS+=("timePeriodFrom=$TIME_PERIOD_FROM")
  COMMON_EXPORT_PARAMS+=("timePeriodTo=$TIME_PERIOD_TO")
fi

# ── Subscription mode ─────────────────────────────────────────────────────────

if [[ "$MODE" == "subscription" ]]; then
  echo "=== Phase 1: Deploy storage account ==="

  STORAGE_OUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file ./bicep/main.bicep \
    --parameters storageAccountName="$STORAGE_ACCOUNT_NAME" containerName="$CONTAINER_NAME" location="$LOCATION" \
    --query properties.outputs -o json)

  SA_ID=$(echo "$STORAGE_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["storageAccountResourceId"]["value"])')
  echo "  Storage account deployed: $SA_ID"

  echo ""
  echo "=== Phase 2: Deploy subscription-scope export ==="

  EXPORT_OUT=$(az deployment sub create \
    --location "$LOCATION" \
    --template-file ./bicep/export-sub.bicep \
    --parameters storageAccountResourceId="$SA_ID" location="$LOCATION" "${COMMON_EXPORT_PARAMS[@]}" \
    --query properties.outputs -o json)

  PRINCIPAL_ID=$(echo "$EXPORT_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["managedIdentityPrincipalId"]["value"])')
  echo "  Export deployed. Managed identity principal ID: $PRINCIPAL_ID"

  echo ""
  echo "=== Phase 3: Assign Storage Blob Data Contributor role ==="

  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file ./bicep/main.bicep \
    --parameters storageAccountName="$STORAGE_ACCOUNT_NAME" containerName="$CONTAINER_NAME" location="$LOCATION" \
                 exportManagedIdentityPrincipalId="$PRINCIPAL_ID" \
    --query properties.outputs >/dev/null

  echo "  Role assignment complete."
fi

# ── Billing Account mode ──────────────────────────────────────────────────────

if [[ "$MODE" == "billingAccount" ]]; then
  echo "=== Phase 1: Deploy storage account ==="

  STORAGE_OUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file ./bicep/main.bicep \
    --parameters storageAccountName="$STORAGE_ACCOUNT_NAME" containerName="$CONTAINER_NAME" location="$LOCATION" \
    --query properties.outputs -o json)

  SA_ID=$(echo "$STORAGE_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["storageAccountResourceId"]["value"])')

  ACCOUNT_KEY=$(az storage account keys list -n "$STORAGE_ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query [0].value -o tsv)
  EXPIRY=$(date -u -d "+365 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+365d +%Y-%m-%dT%H:%M:%SZ)
  SAS=$(az storage container generate-sas \
    --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$ACCOUNT_KEY" \
    --name "$CONTAINER_NAME" --permissions acwl --expiry "$EXPIRY" -o tsv)
  SAS_NOQ="${SAS#\?}"

  echo "  Storage account deployed and SAS token generated."

  echo ""
  echo "=== Phase 2: Deploy billing account export ==="

  az deployment tenant create \
    --location "$LOCATION" \
    --template-file ./bicep/export-billing.bicep \
    --parameters billingAccountId="$BILLING_ACCOUNT_ID" storageAccountResourceId="$SA_ID" sasToken="$SAS_NOQ" \
                 "${COMMON_EXPORT_PARAMS[@]}" \
    --query properties.outputs

  echo "  Billing account export deployed."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Deployment complete ==="
echo "  Mode:            $MODE"
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Export Name:     $EXPORT_NAME"
echo "  Container:       $CONTAINER_NAME/$ROOT_FOLDER_PATH"
echo ""
echo "Next step: Open Power BI Desktop, import powerbi/tdsynnex-theme.json,"
echo "paste powerbi/queries.pq into a Blank Query, set parameters, then add"
echo "the measures from powerbi/measures.dax."
