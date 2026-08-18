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

  Optional one-shot Fabric-admin automation (opt in per flag; each calls the
  Fabric REST API with your signed-in az token - you must be a Fabric admin):
    -GitHubPat <pat>        Create the Fabric -> GitHub connection and store its
                            id as the FABRIC_GITHUB_CONNECTION_ID secret.
    -MakeCapacityAdmin      Add the service principal to the Fabric capacity's
                            Azure administrators (append, never replace).
    -EnableTenantSettings   Enable the two developer tenant settings the SP
                            needs (call public APIs + create workspaces),
                            scoped to a security group containing the SP.
    -SpGroupId <guid>       Existing security group for -EnableTenantSettings.
                            If omitted, a group '<app-name>-sp' is created and
                            the SP is added to it.

  Anything you don't opt into is printed as a checklist at the end.
  NOTE: -EnableTenantSettings uses a preview admin API.

.EXAMPLE
  .\scripts\setup\bootstrap.ps1 -CapacityId <fabric-capacity-guid>

.EXAMPLE
  # fully turnkey (all three Fabric-admin steps automated):
  .\scripts\setup\bootstrap.ps1 -CapacityId <guid> -GitHubPat <pat> `
    -MakeCapacityAdmin -EnableTenantSettings

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
  [string] $GitHubPat,
  [switch] $MakeCapacityAdmin,
  [switch] $EnableTenantSettings,
  [string] $SpGroupId,
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

# --- Fabric REST helpers (used only by the optional -* automation flags) -----
$script:FabricToken = $null
function Get-FabricToken {
  if (-not $script:FabricToken) {
    $script:FabricToken = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $script:FabricToken) { throw "Could not get a Fabric access token. Are you signed in with 'az login'?" }
  }
  return $script:FabricToken
}
function Invoke-Fabric {
  param([string]$Method, [string]$Path, [object]$Body)
  $uri = "https://api.fabric.microsoft.com/v1$Path"
  $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
  if ($null -ne $Body) {
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 8)
  }
  return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
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
if ($DryRun) {
  $SpObjectId = '00000000-0000-0000-0000-000000000000'
} else {
  $SpObjectId = (az ad sp show --id $AppId --query id -o tsv 2>$null)
}

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

# --- 3b. Fabric -> GitHub connection (optional: -GitHubPat) -----------------
if ($GitHubPat -and -not $ConnectionId) {
  Write-Step "Fabric -> GitHub connection (optional)"
  $connName = "$AppName-github"
  if ($DryRun) {
    Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
    Write-Host "POST /connections  (GitHubSourceControl, displayName=$connName, PAT hidden)"
    $ConnectionId = '00000000-0000-0000-0000-000000000000'
    Write-Ok "would create connection $connName"
  } else {
    $existing = (Invoke-Fabric GET '/connections').value | Where-Object { $_.displayName -eq $connName } | Select-Object -First 1
    if ($existing) {
      $ConnectionId = $existing.id
      Write-Ok "Reusing connection $connName ($ConnectionId)"
    } else {
      $body = @{
        connectivityType = 'ShareableCloud'
        displayName      = $connName
        connectionDetails = @{
          type           = 'GitHubSourceControl'
          creationMethod = 'GitHubSourceControl.Contents'
          parameters     = @(@{ dataType = 'Text'; name = 'url'; value = "https://github.com/$Repo" })
        }
        credentialDetails = @{ credentials = @{ credentialType = 'Key'; key = $GitHubPat } }
      }
      $ConnectionId = (Invoke-Fabric POST '/connections' $body).id
      Write-Ok "Created connection $connName ($ConnectionId)"
    }
  }
}

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

# --- 5. Capacity admin (optional: -MakeCapacityAdmin) -----------------------
if ($MakeCapacityAdmin) {
  Write-Step "Fabric capacity admin (optional)"
  if ($DryRun) {
    Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
    Write-Host "resolve capacity $CapacityId -> ARM resource, append SP $SpObjectId to administration.members"
    Write-Ok "would add $AppName as a capacity admin"
  } else {
    $cap = (Invoke-Fabric GET '/capacities').value | Where-Object { $_.id -eq $CapacityId } | Select-Object -First 1
    if (-not $cap) {
      Write-Warn "Capacity $CapacityId not visible via the Fabric API - skipping (add $AppName manually)"
    } else {
      $arm = az fabric capacity list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $cap.displayName } | Select-Object -First 1
      if (-not $arm) {
        Write-Warn "No Azure capacity named '$($cap.displayName)' in this subscription - skipping"
      } else {
        $members = @(az fabric capacity show -n $arm.name -g $arm.resourceGroup --query 'properties.administration.members' -o json 2>$null | ConvertFrom-Json)
        if ($members -contains $SpObjectId) {
          Write-Ok "SP is already a capacity admin on $($arm.name)"
        } else {
          $newList = @($members + $SpObjectId) | Where-Object { $_ }
          $adminArg = 'members=[' + ($newList -join ',') + ']'
          az fabric capacity update -n $arm.name -g $arm.resourceGroup --administration $adminArg | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "capacity admin update failed" }
          Write-Ok "Added SP as a capacity admin on $($arm.name)"
        }
      }
    }
  }
}

# --- 6. Developer tenant settings (optional: -EnableTenantSettings) ----------
if ($EnableTenantSettings) {
  Write-Step "Fabric tenant settings (optional, preview API)"
  $settingNames = @('ServicePrincipalAccessPermissionAPIs', 'ServicePrincipalAccessGlobalAPIs')
  $groupName = "$AppName-sp"
  if ($DryRun) {
    if (-not $SpGroupId) {
      Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
      Write-Host "create/reuse security group '$groupName' and add SP $SpObjectId"
      $SpGroupId = '00000000-0000-0000-0000-000000000000'
    }
    foreach ($s in $settingNames) {
      Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
      Write-Host "POST /admin/tenantsettings/$s/update  (enabled=true, group=$SpGroupId)"
      Write-Ok "would enable $s"
    }
  } else {
    if (-not $SpGroupId) {
      $SpGroupId = (az ad group list --display-name $groupName --query '[0].id' -o tsv 2>$null)
      if (-not $SpGroupId) {
        $SpGroupId = (az ad group create --display-name $groupName --mail-nickname $groupName --query id -o tsv)
        Write-Ok "Created security group $groupName ($SpGroupId)"
      } else {
        Write-Ok "Reusing security group $groupName ($SpGroupId)"
      }
      az ad group member add --group $SpGroupId --member-id $SpObjectId 2>$null | Out-Null
      Write-Ok "SP is a member of $groupName"
    } else {
      $groupName = (az ad group show --group $SpGroupId --query displayName -o tsv 2>$null)
      if (-not $groupName) { $groupName = 'sp-group' }
    }
    foreach ($s in $settingNames) {
      $body = @{ enabled = $true; enabledSecurityGroups = @(@{ graphId = $SpGroupId; name = $groupName }) }
      Invoke-Fabric POST "/admin/tenantsettings/$s/update" $body | Out-Null
      Write-Ok "enabled $s"
    }
  }
}

# --- remaining manual steps (only what wasn't automated) --------------------
$didConn   = [bool]$ConnectionId
$didCap    = [bool]$MakeCapacityAdmin
$didTenant = [bool]$EnableTenantSettings
Write-Host ""
Write-Host "Automated wiring complete." -ForegroundColor White
if ($didConn -and $didCap -and $didTenant) {
  Write-Ok "All Fabric-admin steps were automated - nothing left to do."
} else {
  Write-Host ""
  Write-Host "Finish these Fabric-admin steps (one time):" -ForegroundColor White
  $n = 0
  if (-not $didTenant) {
    $n++
    Write-Host "  $n. Enable the developer tenant settings so the SP can call Fabric APIs and"
    Write-Host "     create workspaces. Re-run with -EnableTenantSettings, or do it in the"
    Write-Host "     Admin portal -> Tenant settings (add a group containing $AppName)."
    Write-Host ""
  }
  if (-not $didCap) {
    $n++
    Write-Host "  $n. Make the service principal a capacity admin (id $CapacityId)."
    Write-Host "     Re-run with -MakeCapacityAdmin, or Admin portal -> Capacity settings."
    Write-Host ""
  }
  if (-not $didConn) {
    $n++
    Write-Host "  $n. Create the Fabric -> GitHub connection so provisioning can push."
    Write-Host "     Re-run with -GitHubPat <pat>, or make it in the portal then re-run with"
    Write-Host "       .\scripts\setup\bootstrap.ps1 -ConnectionId <connection-guid>"
    Write-Host ""
  }
}
Write-Host "Optional self-service portal (rayfin app): after 'rayfin up', re-run with" -ForegroundColor DarkGray
Write-Host "  -CatalogSqlServer <host> -CatalogSqlDatabase <db>  to wire the bridge." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Verify anytime:"
Write-Host "  gh variable list --repo $Repo"
Write-Host "  gh secret list   --repo $Repo"
Write-Host "  az ad app federated-credential list --id $AppId --query '[].subject' -o tsv"
