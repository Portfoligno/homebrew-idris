#!/usr/bin/env python3
"""Create a versioned formula snapshot and repackage bottles.

Reads the main formula, renames the class for versioned installation, inserts
keg_only :versioned_formula, then downloads bottle assets from the GitHub
release, repackages them with versioned internal paths, updates SHA256 digests
in the formula, and uploads the repackaged bottles.

Usage:
    python create-versioned-formula.py \
        --formula Formula/idris2-pack.rb \
        --version 2026.05.01 \
        --output Formula/idris2-pack@2026.05.01.rb \
        --release-tag idris2-pack-2026.05.01
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile


def read_formula(path: str) -> str:
    """Read the main formula file."""
    with open(path) as f:
        return f.read()


def transform_formula(content: str, version: str) -> str:
    """Rename the class and insert keg_only for a versioned formula."""
    class_suffix = version.replace(".", "")

    # Rename class: Idris2Pack -> Idris2PackATYYYYMMDD
    content = re.sub(
        r"^class Idris2Pack < Formula$",
        f"class Idris2PackAT{class_suffix} < Formula",
        content,
        count=1,
        flags=re.MULTILINE,
    )

    # Insert keg_only :versioned_formula after the bottle block
    # (Homebrew style requires: bottle before keg_only)
    content = re.sub(
        r"^(  bottle do\n.*?^  end)$",
        r"\1\n\n  keg_only :versioned_formula",
        content,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )

    return content


def list_bottle_assets(release_tag: str) -> list[str]:
    """List .bottle.tar.gz assets from a GitHub release."""
    result = subprocess.run(
        ["gh", "release", "view", release_tag, "--json", "assets", "-q", ".assets[].name"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [
        name
        for name in result.stdout.strip().splitlines()
        if name.endswith(".bottle.tar.gz")
    ]


def download_asset(release_tag: str, asset_name: str, dest_dir: str) -> str:
    """Download a single asset from a GitHub release. Returns the local path."""
    subprocess.run(
        ["gh", "release", "download", release_tag, "--pattern", asset_name, "--dir", dest_dir],
        check=True,
    )
    return os.path.join(dest_dir, asset_name)


def repackage_bottle(
    asset_path: str,
    asset_name: str,
    version: str,
    workdir: str,
) -> tuple[str, str, str]:
    """Repackage a bottle tarball with versioned internal paths.

    Returns (versioned_asset_path, versioned_asset_name, sha256_hex).
    """
    # Extract
    subprocess.run(["tar", "-xf", asset_path, "-C", workdir], check=True)

    src_dir = os.path.join(workdir, "idris2-pack")
    dst_dir = os.path.join(workdir, f"idris2-pack@{version}")
    os.rename(src_dir, dst_dir)

    # Rename receipt JSON inside .brew/
    brew_dir = os.path.join(dst_dir, version, ".brew")
    if os.path.isdir(brew_dir):
        for entry in os.listdir(brew_dir):
            if entry.startswith("idris2-pack--") and entry.endswith(".json"):
                new_entry = entry.replace("idris2-pack--", f"idris2-pack@{version}--", 1)
                os.rename(
                    os.path.join(brew_dir, entry),
                    os.path.join(brew_dir, new_entry),
                )

    # Repackage with versioned name
    versioned_name = re.sub(r"^idris2-pack-", f"idris2-pack@{version}--", asset_name)
    versioned_path = os.path.join(workdir, versioned_name)
    subprocess.run(
        ["tar", "-czf", versioned_path, "-C", workdir, f"idris2-pack@{version}"],
        check=True,
    )

    # Compute SHA256
    with open(versioned_path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()

    # Cleanup extracted directory and original asset
    subprocess.run(["rm", "-rf", dst_dir, asset_path], check=True)

    return versioned_path, versioned_name, sha


def extract_os_tag(asset_name: str, version: str) -> str:
    """Extract the OS tag (e.g. arm64_sequoia) from an asset filename."""
    # idris2-pack-2026.05.01.arm64_sequoia.bottle.tar.gz -> arm64_sequoia
    pattern = rf"^idris2-pack-{re.escape(version)}\.(.+)\.bottle\.tar\.gz$"
    match = re.match(pattern, asset_name)
    if not match:
        raise ValueError(f"Cannot extract OS tag from {asset_name}")
    return match.group(1)


def update_bottle_sha(content: str, os_tag: str, new_sha: str) -> str:
    """Update the SHA256 for a specific OS tag in the formula's bottle block."""
    pattern = rf'(sha256 cellar: :any, *{re.escape(os_tag)}: *)"[a-f0-9]+"'
    return re.sub(pattern, rf'\1"{new_sha}"', content)


def upload_asset(release_tag: str, asset_path: str) -> None:
    """Upload a repackaged bottle to the GitHub release."""
    subprocess.run(
        ["gh", "release", "upload", release_tag, asset_path, "--clobber"],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a versioned formula and repackage bottles"
    )
    parser.add_argument("--formula", required=True, help="Path to main formula")
    parser.add_argument("--version", required=True, help="CalVer version (e.g. 2026.05.01)")
    parser.add_argument("--output", required=True, help="Output path for versioned formula")
    parser.add_argument("--release-tag", required=True, help="GitHub release tag for bottles")
    args = parser.parse_args()

    # Read and transform the formula
    content = read_formula(args.formula)
    content = transform_formula(content, args.version)

    # Repackage bottles
    assets = list_bottle_assets(args.release_tag)
    if not assets:
        print("WARNING: No bottle assets found for release", args.release_tag, file=sys.stderr)

    with tempfile.TemporaryDirectory() as workdir:
        for asset_name in assets:
            print(f"Repackaging {asset_name} ...", file=sys.stderr)
            asset_path = download_asset(args.release_tag, asset_name, workdir)

            versioned_path, versioned_name, sha = repackage_bottle(
                asset_path, asset_name, args.version, workdir
            )

            os_tag = extract_os_tag(asset_name, args.version)
            content = update_bottle_sha(content, os_tag, sha)

            upload_asset(args.release_tag, versioned_path)
            os.remove(versioned_path)

            print(f"  -> {versioned_name} (sha256: {sha})", file=sys.stderr)

    # Write the versioned formula
    with open(args.output, "w") as f:
        f.write(content)

    print(f"Versioned formula written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
