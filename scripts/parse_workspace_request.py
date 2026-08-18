#!/usr/bin/env python3
"""Parse the deterministic Markdown emitted by the GitHub Issue Form."""
from __future__ import annotations
import argparse, json, os, re
from pathlib import Path

FIELDS = {
    "Workspace name": "display_name",
    "Workspace key": "slug",
    "Sandbox type": "kind",
    "Owner principal type": "owner_principal_type",
    "Owner Entra object ID": "owner_principal_id",
    "TTL in days": "ttl_days",
    "Business purpose": "purpose",
}
SLUG = re.compile(r"^[a-z][a-z0-9-]{2,39}$")
UUID = re.compile(r"^[0-9a-fA-F-]{36}$")


def parse(body: str) -> dict[str, str | int]:
    found: dict[str, str] = {}
    blocks = re.split(r"(?m)^###\s+", body)
    for block in blocks[1:]:
        lines = block.splitlines()
        heading = lines[0].strip()
        if heading in FIELDS:
            value = "\n".join(lines[1:]).strip()
            if value == "_No response_": value = ""
            found[FIELDS[heading]] = value
    missing = [v for v in FIELDS.values() if not found.get(v)]
    if missing:
        raise ValueError(f"Missing required issue fields: {', '.join(missing)}")
    if not SLUG.fullmatch(found["slug"]):
        raise ValueError("Workspace key must match ^[a-z][a-z0-9-]{2,39}$")
    if found["kind"] not in {"team", "personal"}:
        raise ValueError("Sandbox type must be team or personal")
    expected_type = "Group" if found["kind"] == "team" else "User"
    if found["owner_principal_type"] != expected_type:
        raise ValueError(f"{found['kind']} sandboxes require owner principal type {expected_type}")
    if not UUID.fullmatch(found["owner_principal_id"]):
        raise ValueError("Owner Entra object ID must be a UUID")
    ttl = int(found["ttl_days"])
    if not 1 <= ttl <= 90:
        raise ValueError("TTL must be between 1 and 90 days")
    return {**found, "ttl_days": ttl}


def write_outputs(values: dict[str, object], path: str) -> None:
    with open(path, "a", encoding="utf-8") as out:
        for key, value in values.items():
            text = str(value)
            if "\n" in text:
                marker = f"EOF_{key.upper()}"
                out.write(f"{key}<<{marker}\n{text}\n{marker}\n")
            else:
                out.write(f"{key}={text}\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--body-file")
    source.add_argument("--body-env")
    ap.add_argument("--output")
    ap.add_argument("--github-output")
    args = ap.parse_args()
    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else os.environ[args.body_env]
    values = parse(body)
    if args.output: Path(args.output).write_text(json.dumps(values, indent=2) + "\n", encoding="utf-8")
    if args.github_output: write_outputs(values, args.github_output)
    print(json.dumps(values, indent=2))
    return 0

if __name__ == "__main__": raise SystemExit(main())
