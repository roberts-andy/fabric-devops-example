<#
.SYNOPSIS
  Deploy the Rayfin sandbox intake portal to Microsoft Fabric (Windows/PowerShell).

.DESCRIPTION
  Thin, safe-to-re-run wrapper around the Rayfin CLI that stands up the portal app
  in app/ on your Fabric capacity. This is the "front door" companion to
  scripts/setup/init-catalog.ps1 (which prepares the catalog SQL database) and
  scripts/setup/bootstrap.ps1 (which wires the identity + GitHub config).

  What it does:
    1. Verifies prerequisites (Node.js + npm; the app project exists).
    2. Installs the app's dependencies (npm ci) - this also provides the local
       Rayfin CLI (@microsoft/rayfin-cli, a devDependency).
    3. rayfin login - interactive Entra sign-in (skip with -SkipLogin if already
       signed in). Your tenant must have Fabric Apps (preview) enabled.
    4. rayfin up --dry-run - previews the Fabric App item, SQL database, and static
       frontend that will be provisioned.
    5. rayfin up - provisions them for real (skipped under -DryRun).

  IMPORTANT - the catalog database:
    'rayfin up' provisions the app's OWN managed Fabric SQL database, generated from
    app/rayfin/data/SandboxRequest.ts. That is a DIFFERENT database than the
    standalone one init-catalog.ps1 targets. The scheduled catalog bridge reads
    whatever you point CATALOG_SQL_SERVER / CATALOG_SQL_DATABASE at, so after the
    first 'rayfin up' you must point the bridge at the generated database (and grant
    the automation SP on it). The script prints exactly how at the end; pass
    -CatalogWorkspaceId to have it discover the generated database for you.

  Requires: Node.js 18+ and npm. Azure CLI + GitHub CLI only needed for the optional
  post-deploy discovery / repo-variable wiring (-CatalogWorkspaceId, -SetRepoVars).

.EXAMPLE
  # Preview only - install deps, sign in, and dry-run the provisioning:
  .\scripts\setup\deploy-portal.ps1 -DryRun

.EXAMPLE
  # Full deploy (already signed in), no confirmation prompt:
  .\scripts\setup\deploy-portal.ps1 -SkipLogin -Yes

.EXAMPLE
  # Deploy, then discover the generated catalog DB and push the bridge repo vars:
  .\scripts\setup\deploy-portal.ps1 -Yes -CatalogWorkspaceId <generated-workspace-guid> -SetRepoVars
#>
[CmdletBinding()]
param(
  # Portal project root (contains package.json + rayfin/). Defaults to <repo>/app.
  [string] $AppDir,

  [switch] $SkipInstall,
  [switch] $SkipLogin,

  # After a real deploy, discover the app's generated SQL database in this workspace
  # and print (optionally publish) the bridge configuration. Optional.
  [string] $CatalogWorkspaceId,
  [string] $Repo,
  [switch] $SetRepoVars,

  [switch] $DryRun,
  [switch] $Yes
)

$ErrorActionPreference = 'Stop'

function Write-Info { param($m) Write-Host "==> " -ForegroundColor Cyan -NoNewline; Write-Host $m }
function Write-Ok   { param($m) Write-Host "  OK " -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn { param($m) Write-Host "   ! " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Err  { param($m) Write-Host "   x " -ForegroundColor Red -NoNewline; Write-Host $m }
function Write-Step { param($m) Write-Host ""; Write-Host $m -ForegroundColor White }

# Run an external command; honor -DryRun for the mutating ones. Throws on failure.
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string] $Exe,
    [Parameter(ValueFromRemainingArguments)][string[]] $CmdArgs,
    [switch] $Mutating
  )
  if ($Mutating -and $DryRun) {
    Write-Host "    [dry-run] " -ForegroundColor DarkGray -NoNewline
    Write-Host "$Exe $($CmdArgs -join ' ')"
    return
  }
  & $Exe @CmdArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($CmdArgs -join ' ') exited with $LASTEXITCODE" }
}

# ----------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot '..\..\app' }
$resolved = Resolve-Path -LiteralPath $AppDir -ErrorAction SilentlyContinue
$AppDir = if ($resolved) { $resolved.Path } else { $null }
if (-not $AppDir -or -not (Test-Path (Join-Path $AppDir 'package.json'))) {
  Write-Err "Portal project not found. Expected a package.json under -AppDir (default <repo>/app)."
  exit 1
}
if (-not (Test-Path (Join-Path $AppDir 'rayfin\rayfin.yml'))) {
  Write-Warn "No rayfin/rayfin.yml under $AppDir - is this a Rayfin app project?"
}
Write-Ok "app project: $AppDir"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Err "Node.js not found. https://nodejs.org (18+)"; exit 1 }
if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { Write-Err "npm not found (comes with Node.js)."; exit 1 }
Write-Ok "node $(node --version), npm $(npm --version)"

Push-Location $AppDir
try {
  # --------------------------------------------------------------------------
  Write-Step "1/4  Install dependencies"
  if ($SkipInstall) {
    Write-Ok "skipped (-SkipInstall)"
  } elseif (-not (Test-Path 'node_modules') -or -not $DryRun) {
    # npm ci is deterministic (package-lock.json present) and idempotent enough to re-run.
    Invoke-Native npm 'ci' -Mutating
    if (-not $DryRun) { Write-Ok "dependencies installed" }
  } else {
    Write-Ok "node_modules present"
  }

  if ($DryRun -and -not (Test-Path (Join-Path $AppDir 'node_modules\.bin'))) {
    Write-Warn "Dependencies not installed yet; run without -SkipInstall (or once for real) so the Rayfin CLI exists to dry-run."
  }

  # --------------------------------------------------------------------------
  Write-Step "2/4  Sign in to Fabric"
  if ($SkipLogin) {
    Write-Ok "skipped (-SkipLogin)"
  } else {
    Write-Info "rayfin login (interactive; Fabric Apps preview must be enabled in the tenant)"
    & npm exec -- rayfin login
    if ($LASTEXITCODE -ne 0) { throw "rayfin login exited with $LASTEXITCODE" }
    Write-Ok "signed in"
  }

  # --------------------------------------------------------------------------
  Write-Step "3/4  Preview (rayfin up --dry-run)"
  & npm exec -- rayfin up --dry-run
  if ($LASTEXITCODE -ne 0) { throw "rayfin up --dry-run exited with $LASTEXITCODE" }

  # --------------------------------------------------------------------------
  Write-Step "4/4  Provision (rayfin up)"
  if ($DryRun) {
    Write-Warn "DRY RUN - stopping before the real 'rayfin up'."
  } else {
    $go = $Yes
    if (-not $go) {
      $ans = Read-Host "Provision the portal on your Fabric capacity now? [y/N]"
      $go = ($ans -match '^(y|yes)$')
    }
    if (-not $go) {
      Write-Warn "Skipped 'rayfin up' (not confirmed)."
    } else {
      & npm exec -- rayfin up
      if ($LASTEXITCODE -ne 0) { throw "rayfin up exited with $LASTEXITCODE" }
      Write-Ok "portal provisioned"
    }
  }
}
finally {
  Pop-Location
}

# ----------------------------------------------------------------------------
# Optional: discover the generated catalog DB and wire the bridge.
if ($CatalogWorkspaceId -and -not $DryRun) {
  Write-Step "Wiring the catalog bridge to the generated database"
  $initScript = Join-Path $PSScriptRoot 'init-catalog.ps1'
  if (-not (Test-Path $initScript)) {
    Write-Warn "init-catalog.ps1 not found next to this script - skipping discovery."
  } else {
    $initArgs = @{ WorkspaceId = $CatalogWorkspaceId }
    if ($Repo)        { $initArgs.Repo        = $Repo }
    if ($SetRepoVars) { $initArgs.SetRepoVars = $true }
    Write-Info "Running init-catalog.ps1 against workspace $CatalogWorkspaceId (creates table + grants the automation SP)"
    & $initScript @initArgs
  }
}

# ----------------------------------------------------------------------------
Write-Step "Done."
if ($DryRun) {
  Write-Host "  Re-run without -DryRun to provision. Then point the catalog bridge at the" -ForegroundColor DarkGray
  Write-Host "  app's generated Fabric SQL database." -ForegroundColor DarkGray
} elseif (-not $CatalogWorkspaceId) {
  Write-Host "  Next: point the catalog bridge at the app's generated Fabric SQL database." -ForegroundColor Gray
  Write-Host "    1. Open the app's workspace in Fabric and note its SQL database." -ForegroundColor DarkGray
  Write-Host "    2. Run the catalog initializer against that workspace to grant the automation SP:" -ForegroundColor DarkGray
  Write-Host "         .\scripts\setup\init-catalog.ps1 -WorkspaceId <generated-workspace-guid> -SetRepoVars" -ForegroundColor DarkGray
  Write-Host "       (or re-run THIS script with -CatalogWorkspaceId <guid> -SetRepoVars)" -ForegroundColor DarkGray
  Write-Host "    3. Confirm CATALOG_SQL_SERVER / CATALOG_SQL_DATABASE (and COL_* only if column" -ForegroundColor DarkGray
  Write-Host "       names differ) match the generated database - see docs/portal.md." -ForegroundColor DarkGray
}
