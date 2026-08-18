# PRD: Self-Service Microsoft Fabric Workspace Automation

> **Demo scope.** This document describes a working reference implementation you can walk a
> customer through to show what governed, self-service Fabric workspace automation looks like
> in their environment. It is intentionally lean: it favors the smallest set of moving parts
> that still demonstrates the full lifecycle. It is not an exhaustive enterprise spec.

---

## 1. Product Summary

A GitHub-driven automation framework for governed, self-service Microsoft Fabric workspaces.
GitHub is the control plane; GitHub Actions do the work; Microsoft Fabric REST APIs are the
target. It supports two workspace classes:

1. **Sandboxes (ephemeral)** — short-lived `team` or `personal` workspaces requested through a
   GitHub issue form, provisioned from a template, connected to a repo folder, and disposable
   without losing their source-controlled definitions.

2. **Managed (persistent)** — long-lived, source-controlled workspaces (e.g. dev/test/prod for a
   solution) that already exist in Fabric and are kept in sync from Git via CI/CD.

The design follows **Fabric Deployment Pattern 2: many workspaces on a single shared capacity.**
The capacity is centrally owned; each workspace is an isolation and lifecycle boundary.

---

## 2. Goals

- Let approved users request a Fabric sandbox through GitHub with minimal, meaningful metadata.
- Provision workspaces with GitHub Actions on the shared capacity, with owner roles applied.
- Connect every workspace to a GitHub repo folder and initialize it from Git.
- Delete a sandbox while preserving its Git folder, and rehydrate a new one from that folder.
- Keep managed workspaces in sync from Git through a CI/CD deploy path.
- Make every lifecycle action visible and auditable in GitHub Actions.
- Keep the code small and easy for GitHub Copilot to read and extend.

**Non-goals:** no custom web portal; no replacement for Fabric deployment pipelines; deleting a
Fabric workspace never touches the GitHub repo; no attempt to automate every Fabric item type;
no secrets in source control; no personal credentials for automation.

---

## 3. Target Users

- **Platform admin** — owns the shared capacity, this repo, the automation identity, and approvals.
- **Requester** — opens a sandbox request issue.
- **Workspace owner** — builds in the provisioned sandbox.
- **Managed asset owner** — owns a persistent solution and its Git-backed dev/test/prod workspaces.

---

## 4. Design Invariants

These are the load-bearing decisions the implementation guarantees:

- **One shared capacity, many workspaces** (Pattern 2). Capacity is a single config value.
- **Lifecycle is explicit data, not inferred from a name.** A workspace is `sandbox` or
  `managed` because a manifest/registry field says so.
- **Delete is fail-closed.** A sandbox is deleted only when the registry ID, the requested
  display name, and the live Fabric workspace name all agree. Managed records are refused.
- **Git survives deletion.** Delete removes the Fabric workspace; the repo folder and history stay.
- **Git is authoritative on deploy and rehydrate.** Sync prefers the remote; it never makes the
  live workspace the source of truth during initialization.
- **Secrets live outside Git.** Auth is Entra workload identity via GitHub OIDC — no client secret.
- **Data is not source code.** Item *definitions* and shortcuts restore from Git; Lakehouse
  Files/Tables *data* does not. This is called out to customers explicitly.

---

## 5. Repository Structure

```text
.github/
  ISSUE_TEMPLATE/workspace-request.yml    # sandbox request form
  workflows/
    request-workspace.yml                 # issue form -> validate -> provision sandbox
    delete-sandbox.yml                    # fail-closed delete, preserves Git
    rehydrate-sandbox.yml                 # recreate a sandbox from its Git folder
    deploy-managed.yml                    # CI/CD sync for managed workspaces
    expire-sandboxes.yml                  # scheduled TTL report
    validate.yml                          # schema + repo validation on PRs
scripts/
  fabric_workspace.py                     # core FabricClient + provision/rehydrate/delete/deploy
  parse_workspace_request.py              # issue form -> request JSON
  scaffold_sandbox.py                     # request -> sandbox folder + manifest
  registry.py                             # write/update registry records
  validate_repo.py                        # manifest/registry/config invariants
  select_managed_targets.py              # pick changed managed targets for deploy
  requirements.txt
schemas/
  workspace-manifest.schema.json          # sandbox manifest contract
config/
  managed-workspaces.yaml                 # registered persistent targets (deploy-only)
  default-shortcuts.example.yaml
fabric/
  templates/{personal,team}/              # sandbox seed content
  managed/<solution>/{dev,test,prod}/     # Git roots for managed workspaces
sandboxes/<slug>/                         # generated: workspace.yaml + fabric/ folder
registry/
  sandboxes/<slug>.json                   # sandbox lifecycle records
docs/
  bootstrap.md
  operations.md
```

> The implementation deliberately uses **one consolidated script** (`fabric_workspace.py`) plus a
> few small helpers rather than a large module tree. For a demo this is easier to read end to end.

---

## 6. Workspace Classes

### Sandbox (ephemeral)
- **Kinds:** `team` (owner is an Entra **Group**) or `personal` (owner is an Entra **User**).
- **Requested via** a GitHub issue form; provisioned into the `fabric-sandbox-provision` environment.
- **TTL** 1–90 days (30 recommended). A scheduled workflow reports expiring sandboxes.
- **Delete** preserves Git and flips the registry record to `deleted`.
- **Rehydrate** creates a new workspace from the same Git folder with a new workspace ID, an
  incremented generation, and a renewed TTL.

### Managed (persistent)
- **Pre-existing** workspaces registered in `config/managed-workspaces.yaml` with `workspace_id`,
  `git_directory`, `environment`, and `branch`.
- **Deploy-only:** a push to `fabric/managed/**` (or a manual dispatch of one target) verifies or
  creates the Git connection and applies remote changes. Each environment
  (`development`/`test`/`production`) maps to a protected GitHub environment for approvals.
- This path intentionally does **not** create managed workspaces from scratch — it keeps existing,
  governed workspaces in sync.

---

## 7. Sandbox Request Metadata

The issue form captures only what provisioning actually needs:

| Field | Manifest key | Rule |
|---|---|---|
| Workspace name | `display_name` | free text |
| Workspace key | `slug` | `^[a-z][a-z0-9-]{2,39}$`, unique folder |
| Sandbox type | `kind` | `team` or `personal` |
| Owner principal type | `owner.principal_type` | `Group` for team, `User` for personal |
| Owner Entra object ID | `owner.principal_id` | UUID |
| TTL in days | `expires_at` | 1–90 |
| Business purpose | `description` | free text |

The approver reviews purpose, owner, and TTL at the `fabric-sandbox-provision` gate. Richer
metadata (contributors, viewers, data classification, domain) is deliberately **out of scope** for
the demo — add fields only when a real governance requirement demands them.

---

## 8. Workflows

| Workflow | Trigger | Responsibility |
|---|---|---|
| `request-workspace` | issue labeled `fabric-workspace-request` | parse form → scaffold folder + manifest → provision on shared capacity → apply owner role → connect Git → init from Git → default lakehouse → shortcuts → write registry |
| `delete-sandbox` | manual dispatch (key + exact display name) | verify registry + live name agree → delete workspace → keep Git → registry `deleted` |
| `rehydrate-sandbox` | manual dispatch (key) | create new workspace → reconnect Git folder → update from Git → renew TTL → new generation |
| `deploy-managed` | push to `fabric/managed/**` or manual dispatch | select changed targets → ensure Git connection → apply remote changes per environment |
| `expire-sandboxes` | schedule | report sandboxes past TTL for review |
| `validate` | pull request | JSON schema + `validate_repo.py` invariants |

---

## 9. Fabric API Operations

`fabric_workspace.py` wraps the Fabric REST API and provides:

- Create / get / delete workspace; assign to the shared capacity (and optional domain).
- Add workspace role assignment for the owner.
- Git: connect, ensure connection (reject a mismatched repo/folder), initialize with **remote
  preferred**, get status, update from Git, commit to Git where required.
- Ensure a default lakehouse (idempotent).
- Apply shortcuts (`CreateOrOverwrite`, with `${ENV}` values resolved from environment variables).
- Retry with backoff on 429/5xx; poll long-running operations to completion.
- On provisioning failure, roll back the just-created workspace — **never** the repo.

---

## 10. Security and Governance

**Authentication.** One dedicated Entra workload identity. GitHub Actions authenticates with
`azure/login` (OIDC federated credential) and requests a token for
`https://api.fabric.microsoft.com`. No long-lived client secret.

**GitHub variables:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`FABRIC_CAPACITY_ID`, optional `FABRIC_DOMAIN_ID`.
**Secret:** `FABRIC_GITHUB_CONNECTION_ID` (the Fabric GitHub source-control connection UUID).

**Environments (approval gates):** `fabric-sandbox-provision`, `fabric-sandbox-delete`,
`fabric-managed-development`, `fabric-managed-test`, `fabric-managed-production`.

**Guardrails:** slug naming enforced by schema; TTL bounded; delete fail-closed and
managed-safe; production deploy behind a protected environment and branch. Every lifecycle
action is traceable through Actions logs, and registry changes are committed to Git.

See `docs/bootstrap.md` for one-time tenant/identity setup and `docs/operations.md` for the
day-to-day runbook.

---

## 11. Validation

- **Manifest** conforms to `schemas/workspace-manifest.schema.json` (`api_version: 1`,
  `lifecycle: sandbox`, valid slug, `kind`, UUID owner, canonical
  `git.directory = sandboxes/<slug>/fabric`).
- **`validate_repo.py`** checks manifest↔folder agreement, sandbox registry lifecycle/UUID, and
  managed-config lifecycle/UUID on every pull request.
- **Unit tests** cover request parsing, configured Git connection, mismatched-connection refusal,
  idempotent shortcuts, and refusal to delete a managed record.

---

## 12. Acceptance Criteria (demo walkthrough)

The reference implementation proves this end-to-end scenario:

1. Open a team sandbox request issue.
2. Approve the `fabric-sandbox-provision` gate.
3. A workspace is created on the shared capacity, owner role applied, Git connected, initialized
   from the template, default lakehouse created, and a registry record written (`active`).
4. Run **delete** with the key and exact display name — the Fabric workspace is removed and the Git
   folder remains; registry becomes `deleted`.
5. Run **rehydrate** — a new workspace is created from the preserved folder with a new ID and
   generation.
6. Push a change under `fabric/managed/**` — the matching managed workspace syncs from Git.

Throughout, confirm the data caveat with the customer: **definitions and shortcuts restore from
Git; Lakehouse table/file data does not.**

---

## 13. Extending the Demo

Natural next steps to discuss with a customer, kept out of the demo for simplicity:

- Add data classification, contributors, or a domain field to the request form and manifest.
- Add owner-initiated (policy-gated) sandbox deletion.
- Add cost/usage reporting per workspace on the shared capacity.
- Promote managed create-from-scratch, or integrate Fabric deployment pipelines / `fabric-cicd`.
