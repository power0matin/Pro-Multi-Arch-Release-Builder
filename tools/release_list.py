#!/usr/bin/env python3
import argparse, hashlib, json, os, sys
from datetime import datetime, timezone


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024.0:
            return f"{n:.0f} {u}"
        n /= 1024.0
    return f"{n:.0f} PB"


def sidecar_for(path):
    name = os.path.basename(path)
    if name.endswith(".tar.gz"):
        return path[:-7] + ".sha256"
    if name.endswith(".zip"):
        return path[:-4] + ".sha256"
    return path + ".sha256"


def load_hash(sc):
    try:
        with open(sc, "r", encoding="utf-8") as f:
            return f.read().strip().split()[0]
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("assets_dir")
    ap.add_argument(
        "--manifest", default=None, help="Path to write release.manifest.json"
    )
    args = ap.parse_args()

    assets = args.assets_dir
    files = sorted([f for f in os.listdir(assets) if not f.endswith(".sha256")])

    rows = []
    manifest = {"generated_at": datetime.now(timezone.utc).isoformat(), "assets": []}

    print("# Release Assets\n")
    print("| File | Size | SHA256 |")
    print("|------|------|--------|")
    for name in files:
        p = os.path.join(assets, name)
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        sc = sidecar_for(p)
        digest = load_hash(sc) or sha256_of(p)
        print(f"| `{name}` | {human(size)} | `{digest}` |")
        manifest["assets"].append({"name": name, "size": size, "sha256": digest})

    print("\n> Total assets:", len(manifest["assets"]))
    if args.manifest:
        with open(args.manifest, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
