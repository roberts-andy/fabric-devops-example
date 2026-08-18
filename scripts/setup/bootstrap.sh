#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Self-service Fabric DevOps demo — one-shot environment bootstrap.
#
# Wires up the identity + GitHub configuration that every workflow in this repo
# depends on. Safe to re-run (idempotent). Designed for a freshly forked repo.
#
# What it automates (needs Azure CLI + GitHub CLI, both signed in):
#   1. An Entra app registration + service principal (create-or-reuse).
#   2. Federated credentials so GitHub Actions can log in without secrets,
#      one per environment that calls azure/login.
#   3. GitHub environments and the two issue labels.
#   4. Repo variables (AZURE_CLIENT_ID, tenant, subscription, capacity, domain)
#      and — if you pass --connection-id — the Fabric GitHub connection secret.
#
# What it CANNOT do (Fabric-admin / portal steps — printed as a checklist):
#   * Enable the tenant setting "Service principals can use Fabric APIs".
#   * Add the service principal as a Fabric capacity admin.
#   * Create the Fabric -> GitHub connection (interactive PAT auth). You create
#     it once in the Fabric portal, then re-run with --connection-id <id>.
#
# Usage:
#   ./scripts/setup/bootstrap.sh --capacity-id <fabric-capacity-guid> [options]
#
# Common options:
#   --capacity-id <guid>     Fabric capacity id (required unless already set)
#   --connection-id <guid>   Fabric GitHub connection id -> sets the repo secret
#   --domain-id <guid>       Optional Fabric domain id
#   --app-name <name>        Entra app display name (default: derived from repo)
#   --subscription-id <guid> Defaults to the current az subscription
#   --tenant-id <guid>       Defaults to the current az tenant
#   --repo <owner/name>      Defaults to the current gh repo
#   --catalog-sql-server <h> Portal (rayfin) SQL server host -> repo var
#   --catalog-sql-database <n> Portal (rayfin) SQL database  -> repo var
#   --dry-run                Print what would happen, change nothing
#   -y, --yes                Don't prompt; fail if a required value is missing
#   -h, --help               Show this help
# ---------------------------------------------------------------------------
set -euo pipefail

# --- environments that call azure/login (must match .github/workflows/*) -----
ENVIRONMENTS=(
  fabric-sandbox-provision
  fabric-sandbox-delete
  fabric-managed-development
  fabric-managed-test
  fabric-managed-production
)

APP_NAME=""
CAPACITY_ID="${FABRIC_CAPACITY_ID:-}"
CONNECTION_ID=""
DOMAIN_ID=""
SUBSCRIPTION_ID=""
TENANT_ID=""
REPO=""
CATALOG_SQL_SERVER=""
CATALOG_SQL_DATABASE=""
DRY_RUN=0
ASSUME_YES=0

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
info()  { printf '%s==>%s %s\n' "$c_bold" "$c_off" "$*"; }
ok()    { printf '%s  OK%s %s\n' "$c_green" "$c_off" "$*"; }
warn()  { printf '%s   !%s %s\n' "$c_yellow" "$c_off" "$*"; }
err()   { printf '%s   x%s %s\n' "$c_red" "$c_off" "$*" >&2; }
step()  { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0; }

# `run` executes a mutating command, or just prints it under --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s    [dry-run]%s %s\n' "$c_dim" "$c_off" "$*"
  else
    "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app-name) APP_NAME="$2"; shift 2;;
    --capacity-id) CAPACITY_ID="$2"; shift 2;;
    --connection-id) CONNECTION_ID="$2"; shift 2;;
    --domain-id) DOMAIN_ID="$2"; shift 2;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2;;
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --catalog-sql-server) CATALOG_SQL_SERVER="$2"; shift 2;;
    --catalog-sql-database) CATALOG_SQL_DATABASE="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) usage;;
    *) err "Unknown option: $1"; echo "Try --help"; exit 2;;
  esac
done

# --- prerequisites ----------------------------------------------------------
step "Checking prerequisites"
command -v az >/dev/null 2>&1 || { err "Azure CLI (az) not found. https://aka.ms/azure-cli"; exit 1; }
command -v gh >/dev/null 2>&1 || { err "GitHub CLI (gh) not found. https://cli.github.com"; exit 1; }
az account show >/dev/null 2>&1 || { err "Not signed in to Azure. Run: az login"; exit 1; }
gh auth status >/dev/null 2>&1 || { err "Not signed in to GitHub. Run: gh auth login"; exit 1; }
ok "az and gh are installed and signed in"

# --- resolve context --------------------------------------------------------
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
REPO_NAME="${REPO##*/}"
APP_NAME="${APP_NAME:-fabric-devops-${REPO_NAME}}"

prompt_if_missing() {
  # prompt_if_missing VAR_NAME "prompt text"
  local __name="$1"; local __prompt="$2"; local __val="${!__name}"
  if [ -z "$__val" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then err "$__prompt is required (pass the matching flag)."; exit 2; fi
    read -r -p "$__prompt: " __val
    printf -v "$__name" '%s' "$__val"
  fi
}
prompt_if_missing CAPACITY_ID "Fabric capacity id (GUID)"

info "Repository       : $REPO"
info "Entra app name   : $APP_NAME"
info "Tenant           : $TENANT_ID"
info "Subscription     : $SUBSCRIPTION_ID"
info "Fabric capacity  : $CAPACITY_ID"
[ -n "$DOMAIN_ID" ]     && info "Fabric domain    : $DOMAIN_ID"
[ -n "$CONNECTION_ID" ] && info "GitHub connection: $CONNECTION_ID"
[ "$DRY_RUN" -eq 1 ]    && warn "DRY RUN — no changes will be made"

# --- 1. Entra app + service principal --------------------------------------
step "1/4  Entra app registration + service principal"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [ -z "$APP_ID" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    APP_ID="00000000-0000-0000-0000-000000000000"
    printf '%s    [dry-run]%s az ad app create --display-name %s\n' "$c_dim" "$c_off" "$APP_NAME"
  else
    APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  fi
  ok "Created app registration ($APP_ID)"
else
  ok "Reusing existing app registration ($APP_ID)"
fi
if [ "$DRY_RUN" -ne 1 ]; then
  az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
fi
ok "Service principal present"

# --- 2. Federated credentials ----------------------------------------------
step "2/4  Federated credentials (OIDC, no client secret)"
EXISTING_SUBJECTS=""
if [ "$DRY_RUN" -ne 1 ]; then
  EXISTING_SUBJECTS="$(az ad app federated-credential list --id "$APP_ID" --query '[].subject' -o tsv 2>/dev/null || true)"
fi
for env in "${ENVIRONMENTS[@]}"; do
  subject="repo:${REPO}:environment:${env}"
  if printf '%s\n' "$EXISTING_SUBJECTS" | grep -qxF "$subject"; then
    ok "exists  $env"
  else
    params="$(printf '{"name":"gh-%s","issuer":"https://token.actions.githubusercontent.com","subject":"%s","audiences":["api://AzureADTokenExchange"]}' "$env" "$subject")"
    run az ad app federated-credential create --id "$APP_ID" --parameters "$params"
    ok "created $env"
  fi
done

# --- 3. GitHub environments + labels ---------------------------------------
step "3/4  GitHub environments and labels"
for env in "${ENVIRONMENTS[@]}"; do
  run gh api -X PUT "repos/${REPO}/environments/${env}" >/dev/null
  ok "environment  $env"
done
run gh label create fabric-workspace-request --repo "$REPO" --color 1D76DB \
  --description "Fabric sandbox workspace request" --force >/dev/null
ok "label  fabric-workspace-request"
run gh label create fabric-sandbox-expiry --repo "$REPO" --color FBCA04 \
  --description "Fabric sandbox nearing/at expiry" --force >/dev/null
ok "label  fabric-sandbox-expiry"

# --- 4. Repo variables + secrets -------------------------------------------
step "4/4  Repo variables and secrets"
set_var()    { run gh variable set "$1" --repo "$REPO" --body "$2" >/dev/null; ok "var     $1"; }
set_secret() { run gh secret   set "$1" --repo "$REPO" --body "$2" >/dev/null; ok "secret  $1"; }
set_var AZURE_CLIENT_ID        "$APP_ID"
set_var AZURE_TENANT_ID        "$TENANT_ID"
set_var AZURE_SUBSCRIPTION_ID  "$SUBSCRIPTION_ID"
set_var FABRIC_CAPACITY_ID     "$CAPACITY_ID"
[ -n "$DOMAIN_ID" ]            && set_var FABRIC_DOMAIN_ID "$DOMAIN_ID"
[ -n "$CATALOG_SQL_SERVER" ]   && set_var CATALOG_SQL_SERVER "$CATALOG_SQL_SERVER"
[ -n "$CATALOG_SQL_DATABASE" ] && set_var CATALOG_SQL_DATABASE "$CATALOG_SQL_DATABASE"
if [ -n "$CONNECTION_ID" ]; then
  set_secret FABRIC_GITHUB_CONNECTION_ID "$CONNECTION_ID"
else
  warn "FABRIC_GITHUB_CONNECTION_ID not set — provisioning needs it (see checklist below)"
fi

# --- remaining manual steps -------------------------------------------------
SP_DISPLAY="$APP_NAME"
cat <<EOF

${c_bold}Automated wiring complete.${c_off}

${c_bold}Finish these Fabric-admin steps (one time):${c_off}
  1. Enable the tenant setting ${c_bold}"Service principals can use Fabric APIs"${c_off}
     Fabric portal -> Admin portal -> Tenant settings -> Developer settings.
     Add the security group that contains ${c_bold}${SP_DISPLAY}${c_off} (app id ${APP_ID}).

  2. Make the service principal a ${c_bold}capacity admin${c_off} on your Fabric capacity
     (id ${CAPACITY_ID}): Admin portal -> Capacity settings -> your capacity ->
     Contributors/Admins -> add ${c_bold}${SP_DISPLAY}${c_off}.

  3. Create a ${c_bold}Fabric -> GitHub connection${c_off} (once), then re-run:
     Fabric portal -> Settings -> Manage connections and gateways -> New connection
     (GitHub, authorize with a PAT). Copy its connection id, then:
       ./scripts/setup/bootstrap.sh --connection-id <connection-guid>

${c_dim}Optional self-service portal (rayfin app): after 'rayfin up', re-run with
  --catalog-sql-server <host> --catalog-sql-database <db>  to wire the bridge.${c_off}

Verify anytime:
  gh variable list --repo ${REPO}
  gh secret list   --repo ${REPO}
  az ad app federated-credential list --id ${APP_ID} --query '[].subject' -o tsv
EOF
