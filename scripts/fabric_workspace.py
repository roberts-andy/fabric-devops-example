#!/usr/bin/env python3
"""Idempotent Microsoft Fabric workspace lifecycle automation.

Designed for GitHub Actions with OIDC. It never deletes repository content and
refuses to delete a workspace unless a sandbox registry record authorizes it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import requests
try:
    import yaml  # optional; JSON is used as the dependency-free YAML subset
except ImportError:  # pragma: no cover
    yaml = None

BASE_URL = "https://api.fabric.microsoft.com/v1"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")


class FabricError(RuntimeError):
    pass


def require_uuid(value: str | None, name: str) -> str:
    if not value or not UUID_RE.match(value):
        raise ValueError(f"{name} must be a UUID")
    return value


def load_yaml(path: str | Path) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    value = (yaml.safe_load(text) if yaml else json.loads(text)) or {}
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a YAML object")
    return value


def resolve_env(value: Any) -> Any:
    """Resolve ${NAME} references recursively and fail closed on missing values."""
    if isinstance(value, dict):
        return {k: resolve_env(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve_env(v) for v in value]
    if isinstance(value, str):
        def repl(match: re.Match[str]) -> str:
            name = match.group(1)
            if name not in os.environ:
                raise ValueError(f"Environment variable {name} is required by the manifest")
            return os.environ[name]
        return re.sub(r"\$\{([A-Z][A-Z0-9_]*)\}", repl, value)
    return value


@dataclass(frozen=True)
class GitTarget:
    owner: str
    repository: str
    branch: str
    directory: str
    connection_id: str


class FabricClient:
    def __init__(self, token: str, base_url: str = BASE_URL, timeout: int = 60, poll_timeout: int = 1800):
        if not token:
            raise ValueError("FABRIC_TOKEN is required")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.poll_timeout = poll_timeout
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })

    def _url(self, path_or_url: str) -> str:
        return path_or_url if path_or_url.startswith("http") else f"{self.base_url}/{path_or_url.lstrip('/')}"

    @staticmethod
    def _json(response: requests.Response) -> dict[str, Any]:
        if not response.content:
            return {}
        try:
            value = response.json()
            return value if isinstance(value, dict) else {"value": value}
        except ValueError:
            return {"text": response.text}

    def request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        expected: Iterable[int] = (200,),
        allow_404: bool = False,
        wait: bool = True,
    ) -> dict[str, Any] | None:
        expected_set = set(expected)
        for attempt in range(8):
            response = self.session.request(
                method, self._url(path), json=body, timeout=self.timeout
            )
            if response.status_code == 404 and allow_404:
                return None
            if response.status_code == 429 or 500 <= response.status_code < 600:
                if attempt == 7:
                    break
                delay = int(response.headers.get("Retry-After", min(2 ** attempt, 30)))
                time.sleep(delay)
                continue
            if response.status_code not in expected_set:
                payload = self._json(response)
                raise FabricError(
                    f"{method} {path} failed ({response.status_code}): "
                    f"{json.dumps(payload, sort_keys=True)[:2000]}"
                )
            if response.status_code == 202 and wait:
                return self.wait_for_operation(response)
            return self._json(response)
        payload = self._json(response)
        raise FabricError(
            f"{method} {path} failed after retries ({response.status_code}): "
            f"{json.dumps(payload, sort_keys=True)[:2000]}"
        )

    def wait_for_operation(self, initial: requests.Response) -> dict[str, Any]:
        location = initial.headers.get("Location")
        operation_id = initial.headers.get("x-ms-operation-id")
        if not location and operation_id:
            location = f"{self.base_url}/operations/{operation_id}"
        if not location:
            raise FabricError("Fabric returned 202 without Location or x-ms-operation-id")
        retry_after = max(1, int(initial.headers.get("Retry-After", "5")))
        deadline = time.time() + self.poll_timeout
        while time.time() < deadline:
            time.sleep(retry_after)
            response = self.session.get(self._url(location), timeout=self.timeout)
            if response.status_code == 429:
                retry_after = max(1, int(response.headers.get("Retry-After", retry_after)))
                continue
            if response.status_code >= 400:
                raise FabricError(f"Polling {location} failed ({response.status_code}): {response.text[:2000]}")
            payload = self._json(response)
            state = str(payload.get("status", payload.get("state", ""))).lower()
            if state in {"succeeded", "completed"}:
                result = payload.get("result")
                return result if isinstance(result, dict) else payload
            if state in {"failed", "cancelled", "canceled"}:
                raise FabricError(f"Fabric operation failed: {json.dumps(payload, sort_keys=True)[:2000]}")
            retry_after = max(1, int(response.headers.get("Retry-After", retry_after)))
        raise FabricError(f"Timed out waiting for Fabric operation at {location}")

    def create_workspace(self, display_name: str, description: str, capacity_id: str, domain_id: str | None) -> dict[str, Any]:
        body: dict[str, Any] = {
            "displayName": display_name,
            "description": description[:4000],
            "capacityId": require_uuid(capacity_id, "capacity_id"),
        }
        if domain_id:
            body["domainId"] = require_uuid(domain_id, "domain_id")
        result = self.request("POST", "/workspaces", body=body, expected=(201,))
        assert result is not None
        return result

    def get_workspace(self, workspace_id: str) -> dict[str, Any] | None:
        return self.request("GET", f"/workspaces/{require_uuid(workspace_id, 'workspace_id')}", expected=(200,), allow_404=True)

    def delete_workspace(self, workspace_id: str) -> None:
        self.request("DELETE", f"/workspaces/{require_uuid(workspace_id, 'workspace_id')}", expected=(200, 204))

    def add_role(self, workspace_id: str, principal_id: str, principal_type: str, role: str) -> dict[str, Any]:
        allowed_types = {"User", "Group", "ServicePrincipal"}
        allowed_roles = {"Admin", "Member", "Contributor", "Viewer"}
        if principal_type not in allowed_types:
            raise ValueError(f"principal_type must be one of {sorted(allowed_types)}")
        if role not in allowed_roles:
            raise ValueError(f"role must be one of {sorted(allowed_roles)}")
        body = {
            "principal": {"id": require_uuid(principal_id, "principal_id"), "type": principal_type},
            "role": role,
        }
        result = self.request("POST", f"/workspaces/{workspace_id}/roleAssignments", body=body, expected=(201, 409))
        return result or {}

    def git_connection(self, workspace_id: str) -> dict[str, Any]:
        result = self.request("GET", f"/workspaces/{workspace_id}/git/connection", expected=(200,))
        return result or {}

    def connect_git(self, workspace_id: str, target: GitTarget) -> None:
        body = {
            "gitProviderDetails": {
                "gitProviderType": "GitHub",
                "ownerName": target.owner,
                "repositoryName": target.repository,
                "branchName": target.branch,
                "directoryName": target.directory,
            },
            "myGitCredentials": {
                "source": "ConfiguredConnection",
                "connectionId": require_uuid(target.connection_id, "connection_id"),
            },
        }
        self.request("POST", f"/workspaces/{workspace_id}/git/connect", body=body, expected=(200,))

    def ensure_git_connection(self, workspace_id: str, target: GitTarget) -> bool:
        current = self.git_connection(workspace_id)
        details = current.get("gitProviderDetails")
        if not details:
            self.connect_git(workspace_id, target)
            return True
        expected = {
            "gitProviderType": "GitHub",
            "ownerName": target.owner,
            "repositoryName": target.repository,
            "branchName": target.branch,
            "directoryName": target.directory,
        }
        mismatches = {k: (details.get(k), v) for k, v in expected.items() if details.get(k) != v}
        if mismatches:
            raise FabricError(f"Workspace is connected to a different Git target: {mismatches}")
        return current.get("gitConnectionState") != "ConnectedAndInitialized"

    def initialize_git(self, workspace_id: str) -> dict[str, Any]:
        body = {"initializationStrategy": "PreferRemote"}
        result = self.request(
            "POST", f"/workspaces/{workspace_id}/git/initializeConnection",
            body=body, expected=(200, 202)
        ) or {}
        if "requiredAction" not in result:
            # Some LRO responses expose only operation state. Repeating after completion
            # returns the initialization result and is idempotent.
            result = self.request(
                "POST", f"/workspaces/{workspace_id}/git/initializeConnection",
                body=body, expected=(200, 202)
            ) or {}
        return result

    def git_status(self, workspace_id: str) -> dict[str, Any]:
        result = self.request("GET", f"/workspaces/{workspace_id}/git/status", expected=(200, 202))
        return result or {}

    def update_from_git(self, workspace_id: str, workspace_head: str | None, remote_hash: str) -> None:
        body: dict[str, Any] = {
            "remoteCommitHash": remote_hash,
            "conflictResolution": {
                "conflictResolutionType": "Workspace",
                "conflictResolutionPolicy": "PreferRemote",
            },
            "options": {"allowOverrideItems": True},
        }
        if workspace_head:
            body["workspaceHead"] = workspace_head
        self.request("POST", f"/workspaces/{workspace_id}/git/updateFromGit", body=body, expected=(200, 202))

    def sync_from_git(self, workspace_id: str, newly_connected: bool) -> dict[str, Any]:
        if newly_connected:
            init = self.initialize_git(workspace_id)
            action = init.get("requiredAction")
            if action == "UpdateFromGit":
                self.update_from_git(workspace_id, init.get("workspaceHead"), init["remoteCommitHash"])
            elif action in {None, "None"}:
                pass
            elif action == "CommitToGit":
                raise FabricError("Initialization requested CommitToGit; refusing because Git is authoritative")
            else:
                raise FabricError(f"Unsupported initialization requiredAction: {action!r}")
            return init
        status = self.git_status(workspace_id)
        changes = status.get("changes") or []
        remote_changes = [c for c in changes if c.get("remoteChange") and c.get("remoteChange") != "None"]
        conflicts = [c for c in changes if c.get("conflictType") and c.get("conflictType") != "None"]
        remote_hash = status.get("remoteCommitHash")
        if (remote_changes or conflicts) and remote_hash:
            self.update_from_git(workspace_id, status.get("workspaceHead"), remote_hash)
        return status

    def list_lakehouses(self, workspace_id: str) -> list[dict[str, Any]]:
        result = self.request("GET", f"/workspaces/{workspace_id}/lakehouses", expected=(200,)) or {}
        value = result.get("value", [])
        return value if isinstance(value, list) else []

    def ensure_lakehouse(self, workspace_id: str, display_name: str, description: str) -> dict[str, Any]:
        for item in self.list_lakehouses(workspace_id):
            if item.get("displayName") == display_name:
                return item
        result = self.request(
            "POST", f"/workspaces/{workspace_id}/lakehouses",
            body={"displayName": display_name, "description": description[:256]},
            expected=(201, 202)
        ) or {}
        if result.get("id"):
            return result
        for item in self.list_lakehouses(workspace_id):
            if item.get("displayName") == display_name:
                return item
        raise FabricError(f"Lakehouse {display_name!r} was created but could not be resolved")

    def apply_shortcuts(self, workspace_id: str, lakehouse_id: str, shortcuts: list[dict[str, Any]]) -> None:
        for shortcut in shortcuts:
            payload = resolve_env(shortcut)
            for key in ("name", "path", "target"):
                if key not in payload:
                    raise ValueError(f"Shortcut is missing {key}: {payload}")
            self.request(
                "POST",
                f"/workspaces/{workspace_id}/items/{lakehouse_id}/shortcuts?shortcutConflictPolicy=CreateOrOverwrite",
                body=payload,
                expected=(200, 201),
            )

    def commit_all(self, workspace_id: str, comment: str) -> None:
        status = self.git_status(workspace_id)
        changes = status.get("changes") or []
        workspace_changes = [c for c in changes if c.get("workspaceChange") and c.get("workspaceChange") != "None"]
        if not workspace_changes:
            return
        body: dict[str, Any] = {"mode": "All", "comment": comment[:300]}
        if status.get("workspaceHead"):
            body["workspaceHead"] = status["workspaceHead"]
        self.request("POST", f"/workspaces/{workspace_id}/git/commitToGit", body=body, expected=(200, 202))


def git_target_from_args(args: argparse.Namespace) -> GitTarget:
    return GitTarget(
        owner=args.github_owner,
        repository=args.github_repository,
        branch=args.branch,
        directory=args.git_directory.strip("/"),
        connection_id=args.connection_id,
    )


def load_manifest_post_deploy(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    manifest = load_yaml(path)
    return manifest.get("post_deploy", {}) or {}


def post_deploy(client: FabricClient, workspace_id: str, manifest_path: str | None, commit: bool) -> dict[str, Any]:
    cfg = load_manifest_post_deploy(manifest_path)
    result: dict[str, Any] = {}
    lakehouse_cfg = cfg.get("lakehouse")
    if lakehouse_cfg and lakehouse_cfg.get("enabled", True):
        lakehouse = client.ensure_lakehouse(
            workspace_id,
            lakehouse_cfg.get("display_name", "SandboxLakehouse"),
            lakehouse_cfg.get("description", "Default sandbox lakehouse"),
        )
        result["lakehouse"] = {"id": lakehouse.get("id"), "displayName": lakehouse.get("displayName")}
        shortcuts = cfg.get("shortcuts") or []
        if shortcuts:
            client.apply_shortcuts(workspace_id, lakehouse["id"], shortcuts)
            result["shortcut_count"] = len(shortcuts)
    if commit:
        client.commit_all(workspace_id, "Initialize Fabric sandbox template")
    return result


def write_result(path: str | None, value: dict[str, Any]) -> None:
    text = json.dumps(value, indent=2, sort_keys=True)
    if path:
        Path(path).write_text(text + "\n", encoding="utf-8")
    print(text)


def provision(args: argparse.Namespace) -> None:
    client = FabricClient(os.environ.get("FABRIC_TOKEN", ""), base_url=args.base_url)
    workspace: dict[str, Any] | None = None
    try:
        workspace = client.create_workspace(args.display_name, args.description, args.capacity_id, args.domain_id)
        workspace_id = workspace["id"]
        client.add_role(workspace_id, args.owner_principal_id, args.owner_principal_type, args.owner_role)
        target = git_target_from_args(args)
        client.ensure_git_connection(workspace_id, target)
        client.sync_from_git(workspace_id, newly_connected=True)
        defaults = post_deploy(client, workspace_id, args.manifest, args.commit_defaults)
        write_result(args.output, {
            "action": "provision",
            "workspace_id": workspace_id,
            "display_name": workspace.get("displayName", args.display_name),
            "git_directory": target.directory,
            "defaults": defaults,
        })
    except Exception:
        if workspace and args.rollback_on_failure:
            try:
                client.delete_workspace(workspace["id"])
            except Exception as rollback_error:
                print(f"WARNING: rollback failed: {rollback_error}", file=sys.stderr)
        raise


def rehydrate(args: argparse.Namespace) -> None:
    record = json.loads(Path(args.registry).read_text(encoding="utf-8"))
    if record.get("lifecycle") != "sandbox":
        raise ValueError("Only lifecycle=sandbox records can be rehydrated")
    if record.get("status") == "active" and not args.force:
        raise ValueError("Registry says the sandbox is active; delete it first or use --force after verification")
    args.display_name = args.display_name or record["display_name"]
    args.description = record.get("description", "Rehydrated Fabric sandbox")
    args.owner_principal_id = record["owner"]["principal_id"]
    args.owner_principal_type = record["owner"]["principal_type"]
    args.owner_role = record["owner"].get("role", "Contributor")
    args.git_directory = record["git"]["directory"]
    args.manifest = args.manifest or record.get("manifest")
    provision(args)


def delete(args: argparse.Namespace) -> None:
    record = json.loads(Path(args.registry).read_text(encoding="utf-8"))
    if record.get("lifecycle") != "sandbox":
        raise ValueError("Deletion is blocked: registry lifecycle is not sandbox")
    if record.get("workspace_id") != args.workspace_id:
        raise ValueError("Deletion is blocked: workspace ID does not match registry")
    if record.get("display_name") != args.expected_display_name:
        raise ValueError("Deletion is blocked: expected display name does not match registry")
    client = FabricClient(os.environ.get("FABRIC_TOKEN", ""), base_url=args.base_url)
    current = client.get_workspace(args.workspace_id)
    if current is None:
        write_result(args.output, {"action": "delete", "workspace_id": args.workspace_id, "already_absent": True})
        return
    if current.get("displayName") != args.expected_display_name:
        raise FabricError("Deletion is blocked: live workspace display name does not match")
    client.delete_workspace(args.workspace_id)
    write_result(args.output, {"action": "delete", "workspace_id": args.workspace_id, "repo_preserved": True})


def deploy_existing(args: argparse.Namespace) -> None:
    client = FabricClient(os.environ.get("FABRIC_TOKEN", ""), base_url=args.base_url)
    current = client.get_workspace(args.workspace_id)
    if not current:
        raise FabricError(f"Managed workspace {args.workspace_id} does not exist")
    target = git_target_from_args(args)
    needs_init = client.ensure_git_connection(args.workspace_id, target)
    sync = client.sync_from_git(args.workspace_id, needs_init)
    write_result(args.output, {
        "action": "deploy-existing",
        "workspace_id": args.workspace_id,
        "display_name": current.get("displayName"),
        "git_directory": target.directory,
        "change_count": len(sync.get("changes") or []),
    })


def add_common_git(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--github-owner", required=True)
    parser.add_argument("--github-repository", required=True)
    parser.add_argument("--branch", default="main")
    parser.add_argument("--git-directory", required=True)
    parser.add_argument("--connection-id", required=True)


def add_create(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--display-name")
    parser.add_argument("--description", default="")
    parser.add_argument("--capacity-id", required=True)
    parser.add_argument("--domain-id")
    parser.add_argument("--owner-principal-id")
    parser.add_argument("--owner-principal-type", choices=("User", "Group"))
    parser.add_argument("--owner-role", choices=("Admin", "Member", "Contributor", "Viewer"), default="Contributor")
    parser.add_argument("--manifest")
    parser.add_argument("--commit-defaults", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--rollback-on-failure", action=argparse.BooleanOptionalAction, default=True)
    add_common_git(parser)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("FABRIC_BASE_URL", BASE_URL))
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("provision")
    add_create(p)
    p.add_argument("--output")
    p.set_defaults(func=provision)

    p = sub.add_parser("rehydrate")
    add_create(p)
    p.add_argument("--registry", required=True)
    p.add_argument("--force", action="store_true")
    p.add_argument("--output")
    p.set_defaults(func=rehydrate)

    p = sub.add_parser("delete")
    p.add_argument("--registry", required=True)
    p.add_argument("--workspace-id", required=True)
    p.add_argument("--expected-display-name", required=True)
    p.add_argument("--output")
    p.set_defaults(func=delete)

    p = sub.add_parser("deploy-existing")
    p.add_argument("--workspace-id", required=True)
    add_common_git(p)
    p.add_argument("--output")
    p.set_defaults(func=deploy_existing)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command in {"provision", "rehydrate"}:
        if args.command == "provision" and not args.display_name:
            parser.error("provision requires --display-name")
        if args.command == "provision" and not args.owner_principal_id:
            parser.error("provision requires --owner-principal-id")
        if args.command == "provision" and not args.owner_principal_type:
            parser.error("provision requires --owner-principal-type")
    try:
        args.func(args)
        return 0
    except (ValueError, FabricError, requests.RequestException, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
