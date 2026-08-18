# Microsoft Fabric self-service workspace platform

A production-oriented scaffold for **Pattern 2: multiple workspaces on one shared Fabric capacity**. It separates persistent, enterprise-managed workspaces from ephemeral personal/team sandboxes and controls both through GitHub Actions.

## What is included

| Flow | Entry point | Result |
|---|---|---|
| Request sandbox | GitHub Issue Form → `request-workspace.yml` | Validates request, creates the repo folder, creates the Fabric workspace on the shared capacity, grants the owner, connects the workspace to its GitHub folder, initializes from Git, creates a default lakehouse/shortcuts, commits trackable defaults, and writes a registry record. |
| Delete sandbox | `delete-sandbox.yml` | Verifies lifecycle, registry ID, and live display name before deleting the Fabric workspace. The Git folder and registry record remain. Managed targets are rejected. |
| Rehydrate sandbox | `rehydrate-sandbox.yml` | Recreates a deleted workspace, reconnects the preserved sandbox folder, runs Git-authoritative `Update From Git`, reapplies idempotent defaults, renews TTL, and records the new workspace ID/generation. |
| Deploy managed assets | `deploy-managed.yml` | Deploys changed or manually selected persistent targets from `fabric/managed/**` to registered DTAP workspaces. Git is authoritative; production approval is enforced with GitHub environments. |
| Validate | `validate.yml` | Validates manifests, lifecycle boundaries, registry IDs, and tests. |
| Expiry review | `expire-sandboxes.yml` | Opens a cleanup issue for expired active sandboxes. It does not silently delete them. |

## Optional: self-service portal

The GitHub Issue Form is the canonical entry point. For a friendlier front door, [`app/`](app/)
contains a small **Microsoft Fabric App (Rayfin, preview)** that lets signed-in users submit
requests through a form and browse a **catalog of sandboxes** stored in a Fabric SQL database.
A scheduled [catalog bridge](scripts/catalog-bridge/) turns each new catalog row into a labelled
GitHub issue, which triggers `request-workspace.yml` — so the portal is purely additive and needs
no GitHub credential of its own. See [`docs/portal.md`](docs/portal.md).

## Repository layout

```text
.github/
  ISSUE_TEMPLATE/workspace-request.yml
  workflows/
config/
  managed-workspaces.yaml           # persistent workspace target registry
  default-shortcuts.example.yaml
fabric/
  managed/<solution>/<environment>/ # enterprise Fabric Git roots
  templates/{team,personal}/        # sandbox seed structure
registry/
  sandboxes/<key>.json              # control-plane state, never Fabric content
sandboxes/
  <key>/workspace.yaml              # lifecycle/owner/TTL/defaults
  <key>/fabric/                      # Fabric Git integration root
scripts/                             # Fabric REST orchestration and safety checks
schemas/
tests/
```

## Design invariants

1. **One shared capacity, many workspaces.** Capacity and optional domain IDs are centrally supplied; requesters cannot choose arbitrary capacity or domain targets.
2. **Lifecycle is explicit.** `managed` and `sandbox` are data fields, not inferred from workspace names.
3. **Delete is fail-closed.** It accepts only a sandbox registry record and requires the registry ID, requested display name, and live Fabric name to agree.
4. **Git survives deletion.** No lifecycle action removes `sandboxes/<key>`.
5. **Git is authoritative on deployment/rehydration.** Conflicts use `PreferRemote`; automation refuses an initialization that would require committing the workspace over Git.
6. **Secrets stay outside Git.** Fabric/Git connection IDs are GitHub secrets; tenant/capacity/client IDs are repository or environment variables.
7. **Data is not mistaken for source code.** Git can restore supported item definitions and lakehouse metadata, including tracked shortcut definitions. Lakehouse table/file data is not versioned by Git and needs shortcuts or a separate retention strategy.

## Quick start

1. Read [`docs/architecture.md`](docs/architecture.md) and [`docs/bootstrap.md`](docs/bootstrap.md).
2. Create the Entra application and GitHub OIDC federated credential.
3. Enable the required Fabric tenant settings for a dedicated automation security group.
4. Grant the automation service principal capacity Contributor (or capacity Admin) and Fabric API permissions through tenant settings.
5. Create/share a Fabric **GitHub Source Control configured connection** with the service principal and save its connection ID as `FABRIC_GITHUB_CONNECTION_ID`.
6. Add GitHub variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `FABRIC_CAPACITY_ID`, and optionally `FABRIC_DOMAIN_ID`.
7. Create GitHub environments `fabric-sandbox-provision`, `fabric-sandbox-delete`, and `fabric-managed-{development,test,production}`; put required reviewers on delete and production.
8. Add real persistent targets to `config/managed-workspaces.yaml`, remove the example tree when ready, and protect `main` with required validation/CODEOWNERS review.
9. Open a **Fabric sandbox request** issue to exercise the full path.

## Default shortcuts

Add shortcut objects under `post_deploy.shortcuts` in a sandbox `workspace.yaml`. The shape is the Fabric OneLake shortcut API request. Environment substitutions are supported:

```yaml
post_deploy:
  lakehouse:
    enabled: true
    display_name: SandboxLakehouse
  shortcuts:
    - name: curated
      path: Files/shared
      target:
        oneLake:
          workspaceId: ${HUB_WORKSPACE_ID}
          itemId: ${HUB_LAKEHOUSE_ID}
          path: Tables/curated
```

Put `HUB_WORKSPACE_ID` and `HUB_LAKEHOUSE_ID` in the applicable GitHub environment. Shortcut creation is idempotent (`CreateOrOverwrite`). New lakehouses track GA object types by default, so committed shortcut metadata can also participate in Git-based recovery.

## Important operating boundary

This scaffold provisions and governs Fabric SaaS workspaces through the Fabric REST APIs. It does not create the Fabric capacity itself. Provision the capacity and capacity-level monitoring separately (for example through your Azure platform landing zone), then supply the capacity UUID to this repository.
