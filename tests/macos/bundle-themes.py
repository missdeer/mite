#!/usr/bin/env python3
"""Verify that a built macOS app ships every bundled theme unchanged."""

import argparse
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path, help="Path to the built Mostty.app")
args = parser.parse_args()

source = Path(__file__).resolve().parents[2] / "themes"
destination = args.app / "Contents" / "Resources" / "themes"
themes = sorted(path for path in source.rglob("*") if path.is_file())
if not themes:
    raise SystemExit(f"No source themes found in {source}")
if not destination.is_dir():
    raise SystemExit(f"Missing bundled themes directory: {destination}")

for theme in themes:
    relative = theme.relative_to(source)
    installed = destination / relative
    if not installed.is_file():
        raise SystemExit(f"Missing bundled theme: {relative}")
    if installed.read_bytes() != theme.read_bytes():
        raise SystemExit(f"Bundled theme content differs: {relative}")

print(f"Verified {len(themes)} bundled themes in {args.app}")
