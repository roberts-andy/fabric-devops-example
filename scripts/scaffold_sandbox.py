#!/usr/bin/env python3
from __future__ import annotations
import argparse, datetime as dt, json, shutil
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = Path(args.root)
    req = json.loads(Path(args.request).read_text(encoding="utf-8"))
    target = root / "sandboxes" / req["slug"]
    if target.exists(): raise SystemExit(f"Sandbox folder already exists: {target}")
    shutil.copytree(root / "fabric" / "templates" / req["kind"], target)
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    expires = now + dt.timedelta(days=int(req["ttl_days"]))
    manifest = {
        "api_version": 1,
        "lifecycle": "sandbox",
        "slug": req["slug"],
        "kind": req["kind"],
        "display_name": req["display_name"],
        "description": req["purpose"],
        "owner": {
            "principal_id": req["owner_principal_id"],
            "principal_type": req["owner_principal_type"],
            "role": "Contributor",
        },
        "created_at": now.isoformat().replace("+00:00", "Z"),
        "expires_at": expires.isoformat().replace("+00:00", "Z"),
        "git": {"directory": f"sandboxes/{req['slug']}/fabric"},
        "post_deploy": {
            "lakehouse": {
                "enabled": True,
                "display_name": "SandboxLakehouse",
                "description": "Default lakehouse for this ephemeral sandbox",
            },
            "shortcuts": [],
        },
    }
    (target / "workspace.yaml").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(target / 'workspace.yaml'), "git_directory": manifest["git"]["directory"]}))
    return 0

if __name__ == "__main__": raise SystemExit(main())
