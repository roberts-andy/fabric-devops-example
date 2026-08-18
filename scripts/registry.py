#!/usr/bin/env python3
from __future__ import annotations
import argparse, datetime as dt, json
from pathlib import Path


def utcnow() -> str: return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
def load(path: str): return json.loads(Path(path).read_text(encoding="utf-8"))
def save(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def provision(args):
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    result = load(args.result)
    path = Path(args.registry_root) / f"{manifest['slug']}.json"
    old = load(str(path)) if path.exists() else {}
    generation = int(old.get("generation", 0)) + 1
    record = {
        "schema_version": 1, "lifecycle": "sandbox", "status": "active",
        "slug": manifest["slug"], "kind": manifest["kind"],
        "display_name": result.get("display_name", manifest["display_name"]), "description": manifest["description"],
        "owner": manifest["owner"], "expires_at": manifest["expires_at"],
        "workspace_id": result["workspace_id"], "generation": generation,
        "manifest": args.manifest, "git": manifest["git"],
        "last_provisioned_at": utcnow(), "last_deleted_at": old.get("last_deleted_at"),
    }
    save(path, record); print(path)


def deleted(args):
    path = Path(args.registry)
    record = load(str(path))
    if record.get("lifecycle") != "sandbox": raise SystemExit("Refusing to mutate non-sandbox registry")
    record.update({"status": "deleted", "last_deleted_at": utcnow()})
    save(path, record); print(path)


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="command", required=True)
    p=sub.add_parser("provision"); p.add_argument("--manifest", required=True); p.add_argument("--result", required=True); p.add_argument("--registry-root", default="registry/sandboxes"); p.set_defaults(func=provision)
    p=sub.add_parser("deleted"); p.add_argument("--registry", required=True); p.set_defaults(func=deleted)
    args=ap.parse_args(); args.func(args); return 0
if __name__ == "__main__": raise SystemExit(main())
