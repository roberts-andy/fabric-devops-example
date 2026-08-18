#!/usr/bin/env python3
from __future__ import annotations
import json, re, sys
from datetime import datetime
from pathlib import Path

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
SLUG = re.compile(r"^[a-z][a-z0-9-]{2,39}$")

def valid_manifest(value: dict, slug: str) -> None:
    required={"api_version","lifecycle","slug","kind","display_name","owner","expires_at","git","post_deploy"}
    missing=required-set(value)
    if missing: raise ValueError(f"missing {sorted(missing)}")
    if value["api_version"] != 1 or value["lifecycle"] != "sandbox": raise ValueError("invalid version/lifecycle")
    if value["slug"] != slug or not SLUG.fullmatch(slug): raise ValueError("slug does not match folder")
    if value["kind"] not in {"team","personal"}: raise ValueError("invalid kind")
    owner=value["owner"]
    if not UUID.fullmatch(owner.get("principal_id","")): raise ValueError("invalid owner principal_id")
    if owner.get("principal_type") not in {"User","Group"}: raise ValueError("invalid owner principal_type")
    datetime.fromisoformat(value["expires_at"].replace("Z","+00:00"))
    if value["git"].get("directory") != f"sandboxes/{slug}/fabric": raise ValueError("git directory is not canonical")

def main() -> int:
    root=Path(sys.argv[1] if len(sys.argv)>1 else "."); errors=[]
    for path in sorted((root/"sandboxes").glob("*/workspace.yaml")):
        try: valid_manifest(json.loads(path.read_text()), path.parent.name)
        except Exception as e: errors.append(f"{path}: {e}")
    for path in sorted((root/"registry/sandboxes").glob("*.json")):
        try:
            value=json.loads(path.read_text())
            if value.get("lifecycle") != "sandbox": raise ValueError("lifecycle must be sandbox")
            if value.get("workspace_id") and not UUID.fullmatch(value["workspace_id"]): raise ValueError("invalid workspace_id")
        except Exception as e: errors.append(f"{path}: {e}")
    managed=root/"config/managed-workspaces.yaml"
    if managed.exists():
        try:
            data=json.loads(managed.read_text())
            for name, entry in data.get("targets", {}).items():
                if entry.get("lifecycle") != "managed": raise ValueError(f"{name}: lifecycle must be managed")
                if not UUID.fullmatch(str(entry.get("workspace_id", ""))): raise ValueError(f"{name}: invalid workspace_id")
        except Exception as e: errors.append(f"{managed}: {e}")
    if errors: print("\n".join(errors), file=sys.stderr); return 1
    print("Repository validation passed"); return 0
if __name__ == "__main__": raise SystemExit(main())
