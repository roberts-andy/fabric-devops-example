<#
.SYNOPSIS
  Self-service Fabric DevOps demo - one-shot environment bootstrap (Windows/PowerShell).

.DESCRIPTION
  Wires up the identity + GitHub configuration that every workflow in this repo
  depends on. Safe to re-run (idempotent). Designed for a freshly forked repo.
  This is the native PowerShell equivalent of scripts/setup/bootstrap.sh.

  What it automates (needs Azure CLI + GitHub CLI, both signed in):
    1. An Entra app registration + service principal (create-or-reuse).
    2. Federated credentials so GitHub Actions can log in without secrets,
       one per environment that calls azure/login.
    3. GitHub environments and the two issue labels.
    4. Repo variables (AZURE_CLIENT_ID, tenant, subscription, capacity, domain)
       and - if you pass -ConnectionId - the Fabric GitHub connection secret.

  What it CANNOT do (Fabric-admin / portal steps - printed as a checklist):
    * Enable the tenant setting "Service principals can use Fabric APIs".
    * Add the service principal as a Fabric capacity admin.
    * Create the Fabric -> GitHub connection (interactive PAT auth). You create
      it once in the Fabric portal, then re-run with -ConnectionId <id>.

.EXAMPLE
  .\scripts\setup\bootstrap.ps1 -CapacityId <fabric-capacity-guid>

.EXAMPLE
  .\scripts\setup\bootstrap.ps1 -CapacityId <guid> -ConnectionId <guid> -DryRun
#>
[CmdletBinding()]
param(
  [string] $CapacityId = $env:FABRIC_CAPACITY_ID,
  [string] $ConnectionId,
  [string] $DomainId,
  [string] $AppName,
  [string] $SubscriptionId,
  [string] $TenantId,
  [string] $Repo,
  [string] $CatalogSqlServer,
  [string] $CatalogSqlDatabase,
  [switch] $DryRun,
  [switch] $Yes
)

$ErrorActionPreference = 'Stop'

# --- environments that call azure/login (must match .github/workflows/*) -----
$Environments = @(
  'fabric-sandbox-provision',
  'fabric-sandbox-delete',
  'fabric-managed-development',
  'fabric-managed-test',
  'fabric-managed-production'
)

function Write-Info { param($m) Write-Host "==> " -ForegroundColor Cyan -NoNewline; Write-Host $m }
function Write-Ok   { param($m) Write-Host "  OK " -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn { param($m) Write-Host "   ! " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Err  { param($m) Write-Host "   x " -ForegroundColor Red -NoNewline; Write-Host $m }
function Write-Step { param($m) Write-Host ""; Write-Host $m -ForegroundColor White }

# Run a mutating command, or just print it under -DryRun.
# Pass the executable and its args; output is discarded unless -PassThru capture is needed.
function Invoke-Step {
  param([Parameter(Mandatory)][string]$Exe, [Parameter(ValueFromRemainingArguments)][string[]]$Args)
  if ($DryRun) {
    Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
    Write-Host "$Exe $($Args -join ' ')"
  } else {
    & $Exe @Args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with $LASTEXITCODE" }
  }
}

# --- prerequisites ----------------------------------------------------------
Write-Step "Checking prerequisites"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Err "Azure CLI (az) not found. https://aka.ms/azure-cli"; exit 1 }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Err "GitHub CLI (gh) not found. https://cli.github.com"; exit 1 }
az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "Not signed in to Azure. Run: az login"; exit 1 }
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "Not signed in to GitHub. Run: gh auth login"; exit 1 }
Write-Ok "az and gh are installed and signed in"

# --- resolve context --------------------------------------------------------
if (-not $Repo)           { $Repo = (gh repo view --json nameWithOwner -q .nameWithOwner) }
if (-not $SubscriptionId) { $SubscriptionId = (az account show --query id -o tsv) }
if (-not $TenantId)       { $TenantId = (az account show --query tenantId -o tsv) }
$RepoName = $Repo.Split('/')[-1]
if (-not $AppName) { $AppName = "fabric-devops-$RepoName" }

if (-not $CapacityId) {
  if ($Yes) { Write-Err "Fabric capacity id is required (pass -CapacityId)."; exit 2 }
  $CapacityId = Read-Host "Fabric capacity id (GUID)"
}

Write-Info "Repository       : $Repo"
Write-Info "Entra app name   : $AppName"
Write-Info "Tenant           : $TenantId"
Write-Info "Subscription     : $SubscriptionId"
Write-Info "Fabric capacity  : $CapacityId"
if ($DomainId)     { Write-Info "Fabric domain    : $DomainId" }
if ($ConnectionId) { Write-Info "GitHub connection: $ConnectionId" }
if ($DryRun)       { Write-Warn "DRY RUN - no changes will be made" }

# --- 1. Entra app + service principal --------------------------------------
Write-Step "1/4  Entra app registration + service principal"
$AppId = (az ad app list --display-name $AppName --query '[0].appId' -o tsv 2>$null)
if (-not $AppId) {
  if ($DryRun) {
    $AppId = '00000000-0000-0000-0000-000000000000'
    Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
    Write-Host "az ad app create --display-name $AppName"
  } else {
    $AppId = (az ad app create --display-name $AppName --query appId -o tsv)
  }
  Write-Ok "Created app registration ($AppId)"
} else {
  Write-Ok "Reusing existing app registration ($AppId)"
}
if (-not $DryRun) {
  az ad sp show --id $AppId 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { az ad sp create --id $AppId | Out-Null }
}
Write-Ok "Service principal present"

# --- 2. Federated credentials ----------------------------------------------
Write-Step "2/4  Federated credentials (OIDC, no client secret)"
$ExistingSubjects = @()
if (-not $DryRun) {
  $ExistingSubjects = @(az ad app federated-credential list --id $AppId --query '[].subject' -o tsv 2>$null)
}
foreach ($env in $Environments) {
  $subject = "repo:${Repo}:environment:$env"
  if ($ExistingSubjects -contains $subject) {
    Write-Ok "exists  $env"
  } else {
    $params = @{
      name      = "gh-$env"
      issuer    = 'https://token.actions.githubusercontent.com'
      subject   = $subject
      audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    if ($DryRun) {
      Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
      Write-Host "az ad app federated-credential create --id $AppId --parameters $params"
    } else {
      # Write JSON to a temp file to avoid shell quoting issues on Windows.
      $tmp = New-TemporaryFile
      Set-Content -Path $tmp -Value $params -Encoding utf8
      az ad app federated-credential create --id $AppId --parameters "@$tmp" | Out-Null
      Remove-Item $tmp -Force
      if ($LASTEXITCODE -ne 0) { throw "federated-credential create failed for $env" }
    }
    Write-Ok "created $env"
  }
}

# --- 3. GitHub environments + labels ---------------------------------------
Write-Step "3/4  GitHub environments and labels"
foreach ($env in $Environments) {
  Invoke-Step gh api -X PUT "repos/$Repo/environments/$env"
  Write-Ok "environment  $env"
}
Invoke-Step gh label create fabric-workspace-request --repo $Repo --color 1D76DB --description "Fabric sandbox workspace request" --force
Write-Ok "label  fabric-workspace-request"
Invoke-Step gh label create fabric-sandbox-expiry --repo $Repo --color FBCA04 --description "Fabric sandbox nearing/at expiry" --force
Write-Ok "label  fabric-sandbox-expiry"

# --- 4. Repo variables + secrets -------------------------------------------
Write-Step "4/4  Repo variables and secrets"
function Set-RepoVar    { param($n,$v) Invoke-Step gh variable set $n --repo $Repo --body $v; Write-Ok "var     $n" }
function Set-RepoSecret { param($n,$v) Invoke-Step gh secret   set $n --repo $Repo --body $v; Write-Ok "secret  $n" }
Set-RepoVar AZURE_CLIENT_ID       $AppId
Set-RepoVar AZURE_TENANT_ID       $TenantId
Set-RepoVar AZURE_SUBSCRIPTION_ID $SubscriptionId
Set-RepoVar FABRIC_CAPACITY_ID    $CapacityId
if ($DomainId)           { Set-RepoVar FABRIC_DOMAIN_ID $DomainId }
if ($CatalogSqlServer)   { Set-RepoVar CATALOG_SQL_SERVER $CatalogSqlServer }
if ($CatalogSqlDatabase) { Set-RepoVar CATALOG_SQL_DATABASE $CatalogSqlDatabase }
if ($ConnectionId) {
  Set-RepoSecret FABRIC_GITHUB_CONNECTION_ID $ConnectionId
} else {
  Write-Warn "FABRIC_GITHUB_CONNECTION_ID not set - provisioning needs it (see checklist below)"
}

# --- remaining manual steps -------------------------------------------------
Write-Host ""
Write-Host "Automated wiring complete." -ForegroundColor White
Write-Host ""
Write-Host "Finish these Fabric-admin steps (one time):" -ForegroundColor White
Write-Host "  1. Enable the tenant setting `"Service principals can use Fabric APIs`""
Write-Host "     Fabric portal -> Admin portal -> Tenant settings -> Developer settings."
Write-Host "     Add the security group that contains $AppName (app id $AppId)."
Write-Host ""
Write-Host "  2. Make the service principal a capacity admin on your Fabric capacity"
Write-Host "     (id $CapacityId): Admin portal -> Capacity settings -> your capacity ->"
Write-Host "     Contributors/Admins -> add $AppName."
Write-Host ""
Write-Host "  3. Create a Fabric -> GitHub connection (once), then re-run:"
Write-Host "     Fabric portal -> Settings -> Manage connections and gateways -> New connection"
Write-Host "     (GitHub, authorize with a PAT). Copy its connection id, then:"
Write-Host "       .\scripts\setup\bootstrap.ps1 -ConnectionId <connection-guid>"
Write-Host ""
Write-Host "Optional self-service portal (rayfin app): after 'rayfin up', re-run with" -ForegroundColor DarkGray
Write-Host "  -CatalogSqlServer <host> -CatalogSqlDatabase <db>  to wire the bridge." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Verify anytime:"
Write-Host "  gh variable list --repo $Repo"
Write-Host "  gh secret list   --repo $Repo"
Write-Host "  az ad app federated-credential list --id $AppId --query '[].subject' -o tsv"
