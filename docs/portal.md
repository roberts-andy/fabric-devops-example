# Sandbox portal (Rayfin app) + catalog bridge

This is the optional **front door** to the self-service automation. It is a demo of what a
self-service Fabric experience could look like in a customer's environment. Everything
here is additive — the GitHub Issue Form path still works on its own.

## Architecture

```text
┌────────────┐   writes    ┌────────────────────┐   reads (schedule)   ┌───────────────────────┐
│  Rayfin    │────────────▶│  Fabric SQL        │─────────────────────▶│ sandbox-catalog-bridge│
│  portal    │  Sandbox    │  catalog           │  Requested rows      │ (GitHub Actions)      │
│ (Fabric    │  Request    │  (auto-generated   │                      └───────────┬───────────┘
│  SSO)      │  row        │   by @entity())    │                                  │ opens issue
└────────────┘             └────────────────────┘                                  ▼
                                     ▲                               ┌───────────────────────────┐
                                     │ writeback: issue #, url,      │ Issue: fabric-workspace-  │
                                     └───────────────────────────────│ request label            │
                                       status=Submitted              └───────────┬───────────────┘
                                                                                  │ triggers
                                                                                  ▼
                                                                    request-workspace.yml → Fabric
```

- **Portal** (`app/`): Rayfin app. A signed-in user submits the intake form; the app writes
  a `SandboxRequest` row with `status = 'Requested'`. It also renders the catalog table so
  users can see request status.
- **Catalog** (Fabric SQL DB): auto-generated from `app/rayfin/data/SandboxRequest.ts`.
- **Bridge** (`scripts/catalog-bridge/` + `.github/workflows/sandbox-catalog-bridge.yml`):
  a scheduled job that reads `Requested` rows over the SQL/TDS endpoint using an Entra
  token, opens a labelled GitHub issue in the exact format
  `scripts/parse_workspace_request.py` expects, then writes back the issue number/URL and
  flips the row to `Submitted`.

Why a bridge instead of calling GitHub from the app? Rayfin's backend is CRUD-only — no
server-side code, no place for a GitHub secret. The bridge runs where the privileged
credentials already live (GitHub Actions with federated Azure login).

## The integration contract

The bridge must emit an issue body the parser accepts. It builds these exact
`### heading` blocks and applies the `fabric-workspace-request` label:

| Heading | Source | Notes |
|---|---|---|
| `Workspace name` | `workspaceName` | |
| `Workspace key` | `workspaceKey` | must match `^[a-z][a-z0-9-]{2,39}$` |
| `Sandbox type` | `sandboxType` | `team` or `personal` |
| `Owner principal type` | derived | `team → Group`, `personal → User` |
| `Owner Entra object ID` | `ownerObjectId` | UUID |
| `TTL in days` | `ttlDays` | 1–90 |
| `Business purpose` | `purpose` | free text |

The bridge locally re-validates slug/UUID/TTL before opening an issue; invalid rows are
marked `Failed` instead of creating a doomed issue.

## Deploy the portal

```bash
cd app
rayfin login          # interactive; Fabric Apps (preview) must be enabled in the tenant
rayfin up --dry-run
rayfin up
```

`rayfin up` provisions the Fabric App item, the SQL database, and the static frontend on
your Fabric capacity.

### Confirm the generated SQL identifiers

Rayfin preserves TypeScript property names as SQL **columns** (camelCase, e.g.
`workspaceName`, `ttlDays`, `createdAt`). The **table** name is only certain once the DDL
is applied. After the first apply, inspect the database and set the bridge variables below
to match. Defaults in the bridge are the entity property names and `dbo.sandbox_requests`.

## Grant the automation identity access to the catalog

The bridge authenticates as the existing federated automation service principal
(`vars.AZURE_CLIENT_ID`). It needs read/write on the catalog table. In the Fabric SQL
database, run once (as a database admin) — substitute the SP's display name:

```sql
CREATE USER [<automation-sp-display-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<automation-sp-display-name>];
ALTER ROLE db_datawriter ADD MEMBER [<automation-sp-display-name>];
```

If the Fabric SQL database has a firewall, allow GitHub-hosted runner egress (or run the
bridge from a self-hosted runner inside your network).

## GitHub configuration the bridge needs

Reuses the existing automation credentials plus a few catalog-specific values.

**Repository variables**

| Variable | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | federated automation SP (already used by other workflows) |
| `AZURE_TENANT_ID` | tenant (already set) |
| `AZURE_SUBSCRIPTION_ID` | subscription (already set) |
| `CATALOG_SQL_SERVER` | Fabric SQL DB TDS endpoint host (from the DB's connection string) |
| `CATALOG_SQL_DATABASE` | Fabric SQL database name |
| `CATALOG_SCHEMA` | optional, defaults to `dbo` |
| `CATALOG_TABLE` | optional, defaults to `sandbox_requests` — set to the real table name |

**Environment**: the bridge runs in `fabric-sandbox-provision` (already created).

**Column overrides**: if any generated column differs from the entity property name, set
the matching `COL_*` env var in the workflow (see `scripts/catalog-bridge/index.mjs` for
the full list, e.g. `COL_WORKSPACE_NAME`, `COL_GH_ISSUE_NUMBER`).

## Run and test the bridge

- Automatic: every 15 minutes (`schedule` cron).
- Manual: **Actions → Sandbox catalog bridge → Run workflow**. Tick **dry run** to list
  `Requested` rows without opening any issues.

The job is idempotent: it only selects `Requested` rows and the writeback `UPDATE` is
guarded by `status = 'Requested'`, so a row is never double-submitted.

## Option C — direct OAuth submit (future)

To let the app open the issue directly as the signed-in user, implement GitHub OAuth in
`app/src/services/submit.ts` (the single submission seam). The catalog write can stay for
inventory, and the bridge can remain enabled as a backstop for anything submitted while a
user is offline.
