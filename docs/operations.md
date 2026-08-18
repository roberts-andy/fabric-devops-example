# Operations

## Request policy

- Team sandbox → Entra security group, Contributor by default.
- Personal sandbox → Entra user, Contributor by default.
- TTL → 1–90 days; 30 recommended.
- Sensitive/regulated data → use an approved managed workspace, not a personal sandbox.
- The issue approver validates business purpose, classification, owner object ID, and requested TTL.

## Delete

Run **Delete Fabric sandbox (preserve Git)** with the sandbox key and exact display name. The action checks the registry and live workspace before deletion. It changes registry status to `deleted`; it does not remove the manifest or Fabric Git folder.

## Rehydrate

Run **Rehydrate Fabric sandbox from Git**. A new workspace is created on the configured shared capacity, with a renewed TTL and incremented registry generation. Git remote wins on conflicts. If a Git update identifies missing dependencies, repair the source definitions/target resources and retry rather than making the workspace authoritative.

## Managed deployment

A push to `main` under `fabric/managed/**` selects matching targets from `config/managed-workspaces.yaml`. A manual run can select one target key. The deployment verifies an existing Git connection or creates it, refuses mismatched repo/folder connections, and applies remote changes.

## Common failures

| Symptom | Check |
|---|---|
| Workspace create denied | Fabric tenant setting, service principal group membership, capacity Contributor/Admin permission |
| Git connect blocked | GitHub tenant setting, configured connection sharing, workspace Admin, correct connection UUID |
| Update fails for principal type | All involved item types must support service-principal Git updates |
| Workspace head mismatch | Another sync ran concurrently; inspect Git status and rerun after it completes |
| Shortcut fails | Target IDs/path, OneLake API permission, target access, environment-variable substitution |
| Rehydrated item exists but data is empty | Expected for lakehouse table/file data; restore from governed source/shortcut or data-retention process |
| Shared-capacity throttling | Capacity metrics, workload concurrency, abusive sandbox, SKU sizing; move strict-SLO workloads to isolated capacity |
