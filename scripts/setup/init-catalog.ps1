<#
.SYNOPSIS
  Initialize the sandbox catalog SQL database for the Rayfin portal (Windows/PowerShell).

.DESCRIPTION
  Prepares the Fabric SQL database that the Rayfin intake portal and the scheduled
  catalog bridge (scripts/catalog-bridge/index.mjs) share. Safe to re-run (idempotent).

  Two things the app + bridge need that nothing else sets up:

    1. Schema - creates dbo.sandbox_requests, whose columns mirror the Rayfin entity
       in app/rayfin/data/SandboxRequest.ts. The bridge's default table/column names
       (CATALOG_TABLE='sandbox_requests', camelCase columns) match this table exactly,
       so no COL_* / CATALOG_TABLE overrides are needed.

    2. Grant - adds your automation service principal to the database as
       db_datareader + db_datawriter via CREATE USER ... FROM EXTERNAL PROVIDER, so
       the GitHub Actions bridge can read 'Requested' rows and write results back.

  You connect with your own signed-in Entra identity (az login). You must be able to
  administer the database (the account that created it can). The SP display name is
  resolved from the repo variable AZURE_CLIENT_ID unless you pass -AutomationClientId
  or -AutomationSpName.

  Requires: Azure CLI (signed in), and the PowerShell 'SqlServer' module (auto-installed
  to CurrentUser scope if missing). GitHub CLI only needed for -SetRepoVars / repo-var
  defaults.

.EXAMPLE
  # Turnkey against a workspace - discovers server/db, creates table, grants the SP:
  .\scripts\setup\init-catalog.ps1 -WorkspaceId <sbx-catalog-workspace-guid>

.EXAMPLE
  # Explicit server/db, and push CATALOG_SQL_* repo variables for the bridge:
  .\scripts\setup\init-catalog.ps1 -ServerFqdn <host> -Database <db-name> -SetRepoVars

.EXAMPLE
  # Grant only (schema already applied), preview without changes:
  .\scripts\setup\init-catalog.ps1 -WorkspaceId <guid> -SkipSchema -DryRun
#>
[CmdletBinding()]
param(
  # Point at the catalog either directly (-ServerFqdn + -Database) or by workspace
  # (-WorkspaceId, which auto-discovers the SQL database's server + real db name).
  [string] $WorkspaceId          = $env:SBX_CATALOG_WORKSPACE_ID,
  [string] $ServerFqdn,
  [string] $Database,
  [string] $DatabaseDisplayName  = 'sbxcatalog',

  # Automation identity to grant. Defaults to the repo's AZURE_CLIENT_ID variable.
  [string] $AutomationClientId,
  [string] $AutomationSpName,

  # Table identifiers - defaults match the catalog bridge defaults.
  [string] $CatalogSchema = 'dbo',
  [string] $CatalogTable  = 'sandbox_requests',

  [string] $Repo,
  [switch] $SetRepoVars,
  [switch] $SkipSchema,
  [switch] $SkipGrant,
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Info { param($m) Write-Host "==> " -ForegroundColor Cyan -NoNewline; Write-Host $m }
function Write-Ok   { param($m) Write-Host "  OK " -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn { param($m) Write-Host "   ! " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Err  { param($m) Write-Host "   x " -ForegroundColor Red -NoNewline; Write-Host $m }
function Write-Step { param($m) Write-Host ""; Write-Host $m -ForegroundColor White }

# Bracket-quote a T-SQL identifier safely.
function Q { param($id) "[" + ($id -replace ']', ']]') + "]" }

# ----------------------------------------------------------------------------
Write-Step "Checking prerequisites"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Err "Azure CLI (az) not found. https://aka.ms/azure-cli"; exit 1 }
az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "Not signed in to Azure. Run: az login"; exit 1 }
Write-Ok "az is installed and signed in"

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
  Write-Info "Installing PowerShell 'SqlServer' module (CurrentUser scope)"
  if (-not $DryRun) { Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber }
}
Import-Module SqlServer -ErrorAction SilentlyContinue
Write-Ok "SqlServer module available"

if (-not $Repo -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $Repo = (gh repo view --json nameWithOwner -q .nameWithOwner 2>$null)
}

# ----------------------------------------------------------------------------
# Resolve the automation SP display name (the DB principal we grant).
if (-not $AutomationSpName) {
  if (-not $AutomationClientId) {
    if ($Repo -and (Get-Command gh -ErrorAction SilentlyContinue)) {
      $AutomationClientId = (gh variable get AZURE_CLIENT_ID --repo $Repo 2>$null)
    }
  }
  if (-not $AutomationClientId) {
    Write-Err "Cannot determine the automation identity. Pass -AutomationSpName or -AutomationClientId (or set the AZURE_CLIENT_ID repo variable)."
    exit 2
  }
  $AutomationSpName = (az ad sp show --id $AutomationClientId --query displayName -o tsv 2>$null)
  if (-not $AutomationSpName) { Write-Err "Could not resolve a service principal for client id $AutomationClientId."; exit 2 }
}

# ----------------------------------------------------------------------------
# Resolve the target database: explicit params win; otherwise discover from the workspace.
if (-not $ServerFqdn -or -not $Database) {
  if (-not $WorkspaceId) {
    Write-Err "Provide -ServerFqdn and -Database, or -WorkspaceId to auto-discover them."
    exit 2
  }
  Write-Info "Discovering the Fabric SQL database in workspace $WorkspaceId"
  $fabTok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
  $hdr = @{ Authorization = "Bearer $fabTok" }
  $dbs = (Invoke-RestMethod -Method GET -Headers $hdr -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/sqlDatabases").value
  if (-not $dbs -or $dbs.Count -eq 0) { Write-Err "No SQL databases found in workspace $WorkspaceId."; exit 2 }
  $match = $dbs | Where-Object { $_.displayName -eq $DatabaseDisplayName }
  if (-not $match) {
    if ($dbs.Count -eq 1) { $match = $dbs[0] }
    else { Write-Err ("Multiple SQL databases in the workspace and none named '$DatabaseDisplayName'. Pass -ServerFqdn/-Database or -DatabaseDisplayName. Found: " + (($dbs | ForEach-Object displayName) -join ', ')); exit 2 }
  }
  $match = @($match)[0]
  if (-not $ServerFqdn) { $ServerFqdn = $match.properties.serverFqdn }
  if (-not $Database)   { $Database   = $match.properties.databaseName }
}

# Fabric returns "host,1433"; the bridge (mssql) wants a bare host + separate SQL_PORT.
$ServerFqdn = ($ServerFqdn -replace ',\d+\s*$', '').Trim()

Write-Info "Server           : $ServerFqdn"
Write-Info "Database         : $Database"
Write-Info "Catalog table    : $CatalogSchema.$CatalogTable"
Write-Info "Grant SP         : $AutomationSpName"
if ($Repo) { Write-Info "Repository       : $Repo" }
if ($DryRun) { Write-Warn "DRY RUN - no changes will be made" }

# ----------------------------------------------------------------------------
# One Entra token for the SQL data plane, reused for both steps.
$sqlTok = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
if (-not $sqlTok) { Write-Err "Failed to acquire a SQL access token."; exit 1 }

function Invoke-CatalogSql {
  param([string] $Query)
  Invoke-Sqlcmd -ServerInstance $ServerFqdn -Database $Database -AccessToken $sqlTok -Query $Query -ErrorAction Stop
}

# ----------------------------------------------------------------------------
Write-Step "1/2  Catalog table schema"
if ($SkipSchema) {
  Write-Warn "Skipped (-SkipSchema)"
} else {
  $tbl = "$(Q $CatalogSchema).$(Q $CatalogTable)"
  $ddl = @"
IF OBJECT_ID(N'$CatalogSchema.$CatalogTable', N'U') IS NULL
BEGIN
    CREATE TABLE $tbl (
        id                 UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_${CatalogTable}_id DEFAULT NEWID(),
        workspaceName      NVARCHAR(60)  NOT NULL,
        workspaceKey       NVARCHAR(40)  NOT NULL,
        sandboxType        NVARCHAR(20)  NOT NULL,
        ownerObjectId      NVARCHAR(36)  NOT NULL,
        ttlDays            INT           NOT NULL CONSTRAINT DF_${CatalogTable}_ttlDays DEFAULT 30,
        purpose            NVARCHAR(500) NOT NULL,
        requester          NVARCHAR(120) NULL,
        status             NVARCHAR(20)  NOT NULL CONSTRAINT DF_${CatalogTable}_status DEFAULT 'Requested',
        githubIssueNumber  INT           NULL,
        githubIssueUrl     NVARCHAR(400) NULL,
        createdAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_${CatalogTable}_createdAt DEFAULT SYSUTCDATETIME(),
        processedAt        DATETIME2(3)  NULL,
        CONSTRAINT PK_${CatalogTable} PRIMARY KEY (id),
        CONSTRAINT CK_${CatalogTable}_sandboxType CHECK (sandboxType IN ('team','personal')),
        CONSTRAINT CK_${CatalogTable}_status CHECK (status IN ('Requested','Submitted','Provisioned','Failed'))
    );
END
"@
  if ($DryRun) {
    Write-Ok "would create table $CatalogSchema.$CatalogTable if absent"
  } else {
    Invoke-CatalogSql -Query $ddl | Out-Null
    $cnt = (Invoke-CatalogSql -Query "SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema='$CatalogSchema' AND table_name='$CatalogTable';").c
    if ($cnt -eq 1) { Write-Ok "table $CatalogSchema.$CatalogTable present" } else { Write-Err "table not found after DDL"; exit 1 }
  }
}

# ----------------------------------------------------------------------------
Write-Step "2/2  Grant automation service principal"
if ($SkipGrant) {
  Write-Warn "Skipped (-SkipGrant)"
} else {
  $n = $AutomationSpName -replace ']', ']]'
  $grant = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AutomationSpName')
    EXEC('CREATE USER [$n] FROM EXTERNAL PROVIDER;');
ALTER ROLE db_datareader ADD MEMBER [$n];
ALTER ROLE db_datawriter ADD MEMBER [$n];
"@
  if ($DryRun) {
    Write-Ok "would grant db_datareader + db_datawriter to $AutomationSpName"
  } else {
    Invoke-CatalogSql -Query $grant | Out-Null
    $roles = Invoke-CatalogSql -Query @"
SELECT r.name AS role
FROM sys.database_role_members drm
JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
JOIN sys.database_principals r  ON r.principal_id  = drm.role_principal_id
WHERE dp.name = N'$AutomationSpName' ORDER BY r.name;
"@
    $roleList = ($roles | ForEach-Object role) -join ', '
    if ($roleList) { Write-Ok "$AutomationSpName -> $roleList" } else { Write-Err "grant did not take effect"; exit 1 }
  }
}

# ----------------------------------------------------------------------------
# Optionally publish the bridge repo variables.
if ($SetRepoVars) {
  Write-Step "Repo variables for the bridge"
  if (-not $Repo -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Warn "GitHub CLI or repo not available - skipping (-SetRepoVars)"
  } elseif ($DryRun) {
    Write-Ok "would set CATALOG_SQL_SERVER and CATALOG_SQL_DATABASE"
  } else {
    gh variable set CATALOG_SQL_SERVER   --repo $Repo --body $ServerFqdn | Out-Null; Write-Ok "var CATALOG_SQL_SERVER"
    gh variable set CATALOG_SQL_DATABASE --repo $Repo --body $Database   | Out-Null; Write-Ok "var CATALOG_SQL_DATABASE"
    if ($CatalogTable -ne 'sandbox_requests') { gh variable set CATALOG_TABLE --repo $Repo --body $CatalogTable | Out-Null; Write-Ok "var CATALOG_TABLE" }
  }
}

# ----------------------------------------------------------------------------
Write-Step "Done. Bridge configuration"
Write-Host "  CATALOG_SQL_SERVER   = $ServerFqdn"   -ForegroundColor Gray
Write-Host "  CATALOG_SQL_DATABASE = $Database"      -ForegroundColor Gray
Write-Host "  CATALOG_TABLE        = $CatalogTable  (default; only set if changed)" -ForegroundColor DarkGray
if (-not $SetRepoVars) {
  Write-Host ""
  Write-Host "  Re-run with -SetRepoVars to push CATALOG_SQL_SERVER / CATALOG_SQL_DATABASE as repo variables." -ForegroundColor DarkGray
}
