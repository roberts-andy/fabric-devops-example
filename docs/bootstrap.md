# Bootstrap runbook

## Automated setup (recommended)

Most of steps 1–5 below are scripted. After forking, from Azure Cloud Shell
(zero install; `az` and `gh` are preinstalled and signed in) or any bash shell
with the Azure CLI and GitHub CLI signed in:

```bash
gh auth login          # if not already authenticated in this shell
./scripts/setup/bootstrap.sh --capacity-id <fabric-capacity-guid>
```

The script is idempotent and creates/reuses:

- an Entra app registration + service principal;
- OIDC federated credentials for all five deployment environments (no client secret);
- the GitHub environments and the two issue labels;
- repository variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
  `FABRIC_CAPACITY_ID`, and (with `--domain-id`) `FABRIC_DOMAIN_ID`.

Run `./scripts/setup/bootstrap.sh --help` for all flags, or add `--dry-run` to
preview every change without touching Azure or GitHub. Windows users: use Cloud
Shell or Git Bash.

Three things stay manual because they require Fabric-admin rights or interactive
auth — the script prints them as a checklist when it finishes, and they map to
the sections below:

1. Enable the tenant setting **"Service principals can use Fabric APIs"** (§2).
2. Add the service principal as a **capacity admin** (§2).
3. Create the **Fabric → GitHub connection** in the portal, then re-run with
   `--connection-id <guid>` to store the `FABRIC_GITHUB_CONNECTION_ID` secret (§3).

Steps 6–7 (registering persistent workspaces and the smoke test) are always
yours to run. The rest of this document is the manual reference behind the
script.

## 1. Entra workload identity

Create one dedicated application/service principal for Fabric platform automation. Add a GitHub Actions federated identity credential scoped to this repository and, preferably, to the protected GitHub environments. Do not create a long-lived client secret.

The workflows use `azure/login` and request an access token for `https://api.fabric.microsoft.com`.

## 2. Fabric tenant settings

Limit each setting to an automation security group that contains the service principal:

- service principals can use Fabric APIs;
- service principals can create workspaces, connections, and deployment pipelines;
- users can create Fabric items (as required for the selected experiences);
- users can synchronize workspace items with GitHub repositories;
- any item-specific service-principal settings needed by your selected Fabric items.

The automation identity also needs permission to create workspaces and Contributor permission (or Admin) on the target capacity. Git connect/initialize requires the caller to be workspace Admin; a workspace created by the caller should be verified during bootstrap.

## 3. GitHub configured connection in Fabric

Fabric GitHub integration requires configured credentials for API-driven GitHub connections. Create a GitHub Source Control connection with a fine-grained PAT or approved GitHub App-backed process, grant it only this repository, and share the connection with the service principal. The token needs repository Contents read/write because Fabric must update and commit definitions.

Record only the Fabric connection UUID in the GitHub environment/repository secret:

- `FABRIC_GITHUB_CONNECTION_ID`

Rotate the underlying GitHub credential in Fabric without changing manifests.

## 4. GitHub variables and environments

Repository variables:

| Variable | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | Entra application/client ID |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription used by Azure login context |
| `FABRIC_CAPACITY_ID` | UUID of the shared Fabric capacity |
| `FABRIC_DOMAIN_ID` | Optional Fabric domain UUID |

Repository/environment secret:

| Secret | Purpose |
|---|---|
| `FABRIC_GITHUB_CONNECTION_ID` | Configured Fabric GitHub Source Control connection UUID |

Environments:

- `fabric-sandbox-provision` — platform approval during initial rollout; may be relaxed later.
- `fabric-sandbox-delete` — required owner/platform review.
- `fabric-managed-development` — usually automatic after merge.
- `fabric-managed-test` — product owner approval.
- `fabric-managed-production` — platform and data owner approval, protected branch only.

Optional shortcut target IDs belong in the relevant environment variables, not in a globally writable issue.

## 5. Repository protection

Create the labels used by the issue form and expiry report (for example, `gh label create fabric-workspace-request` and `gh label create fabric-sandbox-expiry`) before accepting requests.

- Protect `main`; block force pushes and deletion.
- Require pull requests, `validate`, resolved conversations, and CODEOWNERS review.
- Restrict workflow-file changes to the platform team.
- Restrict GitHub environment administrators.
- Enable secret scanning and dependency update automation.
- Keep Actions permissions at the workflow minimum.

## 6. Register persistent workspaces

Copy entries from `config/managed-workspaces.example.yaml` into `config/managed-workspaces.yaml` using real workspace UUIDs and Git folders. Keep `lifecycle: managed`. The sandbox delete command cannot operate on these records.

## 7. Smoke test

1. Open a personal sandbox request with a test user object ID.
2. Approve `fabric-sandbox-provision`.
3. Confirm capacity/domain placement, owner role, Git connection, default lakehouse, and registry record.
4. Create a supported Fabric item and commit it through Fabric source control.
5. Run delete with exact key and display name; verify Git remains.
6. Run rehydrate; verify a new workspace ID/generation and restored item definitions.
7. Confirm data expectations: definitions/shortcuts restore, but Lakehouse Files/Tables data does not come from Git.
