#!/usr/bin/env python3
"""Build the installable Gen1Recomp ZIP with manifest.json at archive root."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = [
    "manifest.json",
    "main.lua",
    "mod.card",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "ASSET-NOTICE.md",
    "assets",
]


def manifest():
    return json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))


def build(output: Path | None = None) -> Path:
    meta = manifest()
    filename = f"{meta['id']}-{meta['version']}.zip"
    output = output or (ROOT / "dist" / filename)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in RUNTIME:
            src = ROOT / rel
            if not src.exists():
                raise SystemExit(f"missing release input: {rel}")
            if src.is_dir():
                for file in sorted(src.rglob("*")):
                    if file.is_file():
                        zf.write(file, file.relative_to(ROOT).as_posix())
            else:
                zf.write(src, rel)

    with zipfile.ZipFile(output) as zf:
        names = set(zf.namelist())
        if "manifest.json" not in names:
            raise SystemExit("release ZIP is invalid: manifest.json is not at archive root")
        if any(name.startswith("Gen1-Recomp-HD-Grass/") for name in names):
            raise SystemExit("release ZIP is invalid: files are nested under the repo folder")
    print(output)
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    build(args.output)


if __name__ == "__main__":
    main()
