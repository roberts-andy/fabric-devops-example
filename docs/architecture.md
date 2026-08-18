# Architecture and governance model

## Pattern 2 mapping

The Microsoft architecture pattern uses multiple workspaces on one capacity. This is a good fit when a central platform team owns infrastructure while teams need isolated workspaces, independent releases, granular access, and optional Fabric domain alignment. All workspaces still share capacity CUs and region, so this model intentionally accepts some peak-time throttling and is not a substitute for capacity-level performance isolation.

```text
GitHub (control plane and source)
├─ Enterprise managed assets
│  ├─ Solution A / dev  ─┐
│  ├─ Solution A / test ─┼─ persistent Fabric workspaces
│  └─ Solution A / prod ─┘
└─ Self-service sandboxes
   ├─ team/<key>     ───── ephemeral Fabric workspace
   └─ personal/<key> ───── ephemeral Fabric workspace

Fabric tenant
└─ Shared Fabric capacity (single region)
   ├─ Hub/curated managed workspaces
   ├─ DTAP managed workspaces
   └─ Sandbox workspaces
       └─ optional OneLake shortcuts → governed hub data
```

## Workspace classes

| Class | Ownership | Lifetime | Release path | Delete policy |
|---|---|---:|---|---|
| Hub / shared data | Platform/data product team | Persistent | PR + managed environment approval | Blocked by this automation |
| Managed dev/test/prod | Product team with platform guardrails | Persistent | PR/merge + per-environment approval | Blocked by this automation |
| Team sandbox | Entra security group | TTL 1–90 days | Issue request; direct experimentation inside Git-connected workspace | Allowed only through matching sandbox registry |
| Personal sandbox | Entra user | TTL 1–90 days | Issue request; direct experimentation inside Git-connected workspace | Allowed only through matching sandbox registry |

## Control planes

- **GitHub** is the request, approval, policy, source-control, and audit plane.
- **Fabric REST APIs** create/delete workspaces, assign roles, connect/initialize Git, update from Git, create a default lakehouse, and create shortcuts.
- **Entra ID** supplies workload identity and user/group object IDs. The workflows use GitHub OIDC rather than a client secret.
- **Fabric capacity** is centrally managed. Request forms never accept a capacity ID.
- **Fabric domains** are optional. A single configured domain can be applied centrally; extend the manifest with an approved domain map if teams need domain-specific placement.

## Enterprise CI/CD

`config/managed-workspaces.yaml` maps a stable target key to a persistent Fabric workspace and Git folder. A merge to `main` under a registered folder selects that target and applies incoming Git changes. Manual dispatch supports controlled replay. Use:

- branch protection and required `validate` checks;
- CODEOWNERS for `fabric/managed/**` and platform automation;
- GitHub environments with no approval for dev, product owner approval for test, and platform/data owner approval for prod;
- separate Entra groups for workspace roles; avoid individual production admins;
- deployment-pipeline rules or variable libraries when item references/shortcut destinations differ by stage.

## Sandbox state machine

```text
requested → approved → folder-created → workspace-created → Git-connected
    → initialized → defaults-applied → active
active → deleted (Fabric workspace removed; Git retained)
deleted → rehydrated (new workspace ID, same Git folder, generation +1) → active
```

A failure during first-time provisioning deletes the just-created workspace by default, but never deletes the repo folder. This prevents an unmanaged orphan while preserving request evidence.

## Rehydration guarantees and non-guarantees

Rehydration restores supported Git-integrated Fabric item definitions from `sandboxes/<key>/fabric`. The automation then reapplies idempotent post-deploy resources. It does **not** guarantee recovery of:

- Lakehouse tables or Files data (Git tracks metadata, not data);
- credentials or secrets;
- unsupported Fabric item types;
- external systems referenced by shortcuts;
- ad hoc changes that were never committed from Fabric to Git.

Use governed hub data through shortcuts where possible. For sandbox-owned data that matters, define an explicit export/retention policy before deletion.

## Capacity safeguards

Because every workspace shares one capacity:

- cap sandbox TTL and count;
- monitor CU consumption and throttling by workspace;
- use workload settings and Spark autoscale billing where appropriate;
- quarantine abusive or runaway workloads;
- move SLO-sensitive workloads to Pattern 3 (separate capacity) rather than weakening sandbox controls;
- keep all workspaces/data in the capacity region unless a different deployment pattern is selected.
