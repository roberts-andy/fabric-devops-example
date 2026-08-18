#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess
from pathlib import Path


def main() -> int:
    ap=argparse.ArgumentParser(); ap.add_argument("--config", default="config/managed-workspaces.yaml"); ap.add_argument("--target"); ap.add_argument("--before"); ap.add_argument("--sha"); ap.add_argument("--github-output"); args=ap.parse_args()
    targets=(json.loads(Path(args.config).read_text()) or {}).get("targets", {})
    selected=[]
    if args.target:
        if args.target not in targets: raise SystemExit(f"Unknown managed target: {args.target}")
        names=[args.target]
    else:
        if not args.before or set(args.before)=={"0"}: names=list(targets)
        else:
            changed=subprocess.check_output(["git","diff","--name-only",args.before,args.sha], text=True).splitlines()
            names=[name for name,v in targets.items() if any(p==v["git_directory"] or p.startswith(v["git_directory"].rstrip("/")+"/") for p in changed)]
    for name in names:
        item=dict(targets[name])
        if item.get("lifecycle") != "managed": raise SystemExit(f"{name} is not lifecycle=managed")
        item["name"]=name; selected.append(item)
    matrix=json.dumps({"include": selected}, separators=(",",":"))
    if args.github_output:
        with open(args.github_output,"a") as f: f.write(f"matrix={matrix}\ncount={len(selected)}\n")
    print(json.dumps({"include": selected}, indent=2)); return 0
if __name__ == "__main__": raise SystemExit(main())
