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
# Optional one-shot Fabric-admin automation (opt in per flag; each calls the
# Fabric REST API with your signed-in az token — you must be a Fabric admin):
#   * --github-pat <pat>       Create the Fabric -> GitHub connection and store
#                              its id as the FABRIC_GITHUB_CONNECTION_ID secret.
#   * --make-capacity-admin    Add the SP to the capacity's Azure admins.
#   * --enable-tenant-settings Enable the two developer tenant settings the SP
#                              needs (preview admin API), scoped to a group.
# Anything you don't opt into is printed as a checklist at the end.
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
#   --github-pat <pat>       Auto-create the Fabric -> GitHub connection
#   --make-capacity-admin    Add the SP as a Fabric capacity admin
#   --enable-tenant-settings Enable the SP developer tenant settings (preview)
#   --sp-group-id <guid>     Existing security group for --enable-tenant-settings
#                            (default: create '<app-name>-sp' and add the SP)
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
GITHUB_PAT=""
MAKE_CAPACITY_ADMIN=0
ENABLE_TENANT_SETTINGS=0
SP_GROUP_ID=""
SP_OBJECT_ID=""
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

# --- Fabric REST helpers (only used by the optional --flags) -----------------
FABRIC_TOKEN=""
fabric_token() {
  if [ -z "$FABRIC_TOKEN" ]; then
    FABRIC_TOKEN="$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>/dev/null || true)"
    [ -n "$FABRIC_TOKEN" ] || { err "Could not get a Fabric access token (is 'az login' current?)"; exit 1; }
  fi
  printf '%s' "$FABRIC_TOKEN"
}
# fabric_get PATH  -> prints JSON response
fabric_get() {
  curl -fsS "https://api.fabric.microsoft.com/v1$1" -H "Authorization: Bearer $(fabric_token)"
}
# fabric_post PATH  (JSON body on stdin) -> prints JSON response.
# Body comes via stdin so a PAT never lands in the process list.
fabric_post() {
  curl -fsS -X POST "https://api.fabric.microsoft.com/v1$1" \
    -H "Authorization: Bearer $(fabric_token)" \
    -H "Content-Type: application/json" --data-binary @-
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
    --github-pat) GITHUB_PAT="$2"; shift 2;;
    --make-capacity-admin) MAKE_CAPACITY_ADMIN=1; shift;;
    --enable-tenant-settings) ENABLE_TENANT_SETTINGS=1; shift;;
    --sp-group-id) SP_GROUP_ID="$2"; shift 2;;
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
if [ "$DRY_RUN" -eq 1 ]; then
  SP_OBJECT_ID="00000000-0000-0000-0000-000000000000"
else
  SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
fi

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

# --- 3b. Optional: create the Fabric -> GitHub connection -------------------
if [ -n "$GITHUB_PAT" ] && [ -z "$CONNECTION_ID" ]; then
  step "3b   Fabric -> GitHub connection (optional)"
  CONN_NAME="${APP_NAME}-github"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s    [dry-run]%s POST /connections  (GitHubSourceControl, displayName=%s, PAT hidden)\n' "$c_dim" "$c_off" "$CONN_NAME"
    CONNECTION_ID="00000000-0000-0000-0000-000000000000"
    ok "would create connection $CONN_NAME"
  else
    CONNECTION_ID="$(fabric_get /connections | python -c "import sys,json;n=sys.argv[1];print(next((c['id'] for c in json.load(sys.stdin).get('value',[]) if c.get('displayName')==n),''))" "$CONN_NAME")"
    if [ -n "$CONNECTION_ID" ]; then
      ok "Reusing connection $CONN_NAME ($CONNECTION_ID)"
    else
      body="$(printf '{"connectivityType":"ShareableCloud","displayName":"%s","connectionDetails":{"type":"GitHubSourceControl","creationMethod":"GitHubSourceControl.Contents","parameters":[{"dataType":"Text","name":"url","value":"https://github.com/%s"}]},"credentialDetails":{"credentials":{"credentialType":"Key","key":"%s"}}}' "$CONN_NAME" "$REPO" "$GITHUB_PAT")"
      CONNECTION_ID="$(printf '%s' "$body" | fabric_post /connections | python -c "import sys,json;print(json.load(sys.stdin).get('id',''))")"
      [ -n "$CONNECTION_ID" ] || { err "Connection create did not return an id"; exit 1; }
      ok "Created connection $CONN_NAME ($CONNECTION_ID)"
    fi
  fi
fi

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

# --- 5. Optional: make the SP a Fabric capacity admin ----------------------
if [ "$MAKE_CAPACITY_ADMIN" -eq 1 ]; then
  step "5    Fabric capacity admin (optional)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s    [dry-run]%s resolve capacity %s -> ARM, append SP %s to administration.members\n' "$c_dim" "$c_off" "$CAPACITY_ID" "$SP_OBJECT_ID"
    ok "would add $APP_NAME as a capacity admin"
  else
    disp="$(fabric_get /capacities | python -c "import sys,json;i=sys.argv[1];print(next((c.get('displayName','') for c in json.load(sys.stdin).get('value',[]) if c.get('id')==i),''))" "$CAPACITY_ID")"
    if [ -z "$disp" ]; then
      warn "Capacity $CAPACITY_ID not visible via the Fabric API — skipping (do it in Admin portal -> Capacity settings)"
    else
      read -r arm_name arm_rg < <(az fabric capacity list --query "[?name=='$disp'].[name,resourceGroup] | [0]" -o tsv 2>/dev/null || true)
      if [ -z "${arm_name:-}" ]; then
        warn "No Azure Fabric capacity named '$disp' found — skipping"
      else
        mapfile -t members < <(az fabric capacity show -n "$arm_name" -g "$arm_rg" --query 'properties.administration.members' -o tsv 2>/dev/null || true)
        found=0; for m in "${members[@]:-}"; do [ "$m" = "$SP_OBJECT_ID" ] && found=1; done
        if [ "$found" -eq 1 ]; then
          ok "SP is already a capacity admin on $arm_name"
        else
          newlist="$SP_OBJECT_ID"; for m in "${members[@]:-}"; do [ -n "$m" ] && newlist="$m,$newlist"; done
          az fabric capacity update -n "$arm_name" -g "$arm_rg" --administration "members=[$newlist]" >/dev/null
          ok "Added SP as a capacity admin on $arm_name"
        fi
      fi
    fi
  fi
fi

# --- 6. Optional: enable the SP developer tenant settings (preview) --------
if [ "$ENABLE_TENANT_SETTINGS" -eq 1 ]; then
  step "6    Fabric tenant settings (optional, preview admin API)"
  group_name="${APP_NAME}-sp"
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -z "$SP_GROUP_ID" ]; then
      printf '%s    [dry-run]%s create/reuse security group '\''%s'\'' and add SP %s\n' "$c_dim" "$c_off" "$group_name" "$SP_OBJECT_ID"
      SP_GROUP_ID="00000000-0000-0000-0000-000000000000"
    fi
    for s in ServicePrincipalAccessPermissionAPIs ServicePrincipalAccessGlobalAPIs; do
      printf '%s    [dry-run]%s POST /admin/tenantsettings/%s/update  (enabled=true, group=%s)\n' "$c_dim" "$c_off" "$s" "$SP_GROUP_ID"
      ok "would enable $s"
    done
  else
    if [ -z "$SP_GROUP_ID" ]; then
      SP_GROUP_ID="$(az ad group list --display-name "$group_name" --query '[0].id' -o tsv 2>/dev/null || true)"
      if [ -z "$SP_GROUP_ID" ]; then
        SP_GROUP_ID="$(az ad group create --display-name "$group_name" --mail-nickname "$group_name" --query id -o tsv)"
        ok "Created security group $group_name ($SP_GROUP_ID)"
      else
        ok "Reusing security group $group_name ($SP_GROUP_ID)"
      fi
      az ad group member add --group "$SP_GROUP_ID" --member-id "$SP_OBJECT_ID" >/dev/null 2>&1 || true
      ok "SP is a member of $group_name"
    else
      group_name="$(az ad group show --group "$SP_GROUP_ID" --query displayName -o tsv 2>/dev/null || echo sp-group)"
      ok "Using existing security group $group_name ($SP_GROUP_ID)"
    fi
    for s in ServicePrincipalAccessPermissionAPIs ServicePrincipalAccessGlobalAPIs; do
      body="$(printf '{"enabled":true,"enabledSecurityGroups":[{"graphId":"%s","name":"%s"}]}' "$SP_GROUP_ID" "$group_name")"
      printf '%s' "$body" | fabric_post "/admin/tenantsettings/$s/update" >/dev/null
      ok "enabled $s"
    done
  fi
fi

# --- remaining manual steps (only what wasn't automated) --------------------
SP_DISPLAY="$APP_NAME"
did_conn=0;   [ -n "$CONNECTION_ID" ] && did_conn=1
did_cap=0;    [ "$MAKE_CAPACITY_ADMIN" -eq 1 ] && did_cap=1
did_tenant=0; [ "$ENABLE_TENANT_SETTINGS" -eq 1 ] && did_tenant=1

printf '\n%sAutomated wiring complete.%s\n' "$c_bold" "$c_off"
if [ "$did_conn" -eq 1 ] && [ "$did_cap" -eq 1 ] && [ "$did_tenant" -eq 1 ]; then
  ok "All Fabric-admin steps were automated — nothing left to do."
else
  printf '\n%sFinish these Fabric-admin steps (one time):%s\n' "$c_bold" "$c_off"
  n=0
  if [ "$did_tenant" -eq 0 ]; then
    n=$((n+1))
    printf '  %s. Enable the tenant setting %s"Service principals can use Fabric APIs"%s\n' "$n" "$c_bold" "$c_off"
    printf '     Re-run with %s--enable-tenant-settings%s, or in Admin portal -> Tenant\n' "$c_bold" "$c_off"
    printf '     settings, add a group containing %s%s%s (app id %s).\n\n' "$c_bold" "$SP_DISPLAY" "$c_off" "$APP_ID"
  fi
  if [ "$did_cap" -eq 0 ]; then
    n=$((n+1))
    printf '  %s. Make the service principal a %scapacity admin%s (id %s).\n' "$n" "$c_bold" "$c_off" "$CAPACITY_ID"
    printf '     Re-run with %s--make-capacity-admin%s, or Admin portal -> Capacity settings.\n\n' "$c_bold" "$c_off"
  fi
  if [ "$did_conn" -eq 0 ]; then
    n=$((n+1))
    printf '  %s. Create the %sFabric -> GitHub connection%s so provisioning can push.\n' "$n" "$c_bold" "$c_off"
    printf '     Re-run with %s--github-pat <pat>%s, or make it in the portal then re-run with\n' "$c_bold" "$c_off"
    printf '       ./scripts/setup/bootstrap.sh --connection-id <connection-guid>\n\n'
  fi
fi

printf '%sOptional self-service portal (rayfin app): after '\''rayfin up'\'', re-run with\n' "$c_dim"
printf '  --catalog-sql-server <host> --catalog-sql-database <db>  to wire the bridge.%s\n\n' "$c_off"
printf 'Verify anytime:\n'
printf '  gh variable list --repo %s\n' "$REPO"
printf '  gh secret list   --repo %s\n' "$REPO"
printf "  az ad app federated-credential list --id %s --query '[].subject' -o tsv\n" "$APP_ID"
