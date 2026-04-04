#!/usr/bin/env python3
"""Parse a pack-db nightly collection TOML and resolve resource metadata.

Reads a collection TOML file, extracts commit hashes for pack, Idris2, and all
library dependencies, then computes SHA256 checksums for their source archives.

Usage:
    python resolve-collection.py <collection.toml> > resources.json

Output is a JSON object with the following structure:
    {
        "pack": {"url": "...", "commit": "...", "sha256": "..."},
        "idris2": {"url": "...", "commit": "...", "sha256": "..."},
        "libraries": [
            {"name": "...", "url": "...", "commit": "...", "sha256": "..."},
            ...
        ]
    }
"""

import hashlib
import json
import sys
from urllib.request import urlopen

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

# Libraries required by pack, in build order.
# Keys are the pack-db TOML keys; values are (github_owner, github_repo).
LIBRARIES = [
    ("algebra", "stefan-hoeck", "idris2-algebra"),
    ("ref1", "stefan-hoeck", "idris2-ref1"),
    ("array", "stefan-hoeck", "idris2-array"),
    ("bytestring", "stefan-hoeck", "idris2-bytestring"),
    ("getopts", "idris-community", "idris2-getopts"),
    ("elab-util", "stefan-hoeck", "idris2-elab-util"),
    ("refined", "stefan-hoeck", "idris2-refined"),
    ("literal", "stefan-hoeck", "idris2-literal"),
    ("ilex", "stefan-hoeck", "idris2-ilex"),
    ("filepath", "stefan-hoeck", "idris2-filepath"),
]


def sha256_of_url(url: str, retries: int = 3) -> str:
    """Download a URL and return its SHA256 hex digest."""
    for attempt in range(retries):
        try:
            with urlopen(url, timeout=60) as resp:
                data = resp.read()
            return hashlib.sha256(data).hexdigest()
        except Exception as e:
            if attempt < retries - 1:
                print(f"Retry {attempt + 1}/{retries} for {url}: {e}", file=sys.stderr)
            else:
                raise RuntimeError(f"Failed to download {url} after {retries} attempts: {e}") from e
    raise AssertionError("unreachable")


def archive_url(owner: str, repo: str, commit: str) -> str:
    return f"https://github.com/{owner}/{repo}/archive/{commit}.tar.gz"


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <collection.toml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], "rb") as f:
        collection = tomllib.load(f)

    # Resolve pack
    pack_section = collection.get("pack", collection.get("db", {}).get("pack", {}))
    if not pack_section:
        print(
            "ERROR: 'pack' section not found in collection (checked top-level and db.pack)",
            file=sys.stderr,
        )
        sys.exit(1)
    pack_commit = pack_section["commit"]
    pack_url = archive_url("stefan-hoeck", "idris2-pack", pack_commit)
    pack_sha = sha256_of_url(pack_url)

    # Resolve Idris2
    idris2_section = collection["idris2"]
    idris2_commit = idris2_section["commit"]
    idris2_url = archive_url("idris-lang", "Idris2", idris2_commit)
    idris2_sha = sha256_of_url(idris2_url)

    # Resolve libraries
    db = collection.get("db", {})
    libraries = []
    for toml_key, owner, repo in LIBRARIES:
        section = db.get(toml_key)
        if section is None:
            print(
                f"ERROR: required library '{toml_key}' not found in collection",
                file=sys.stderr,
            )
            sys.exit(1)
        commit = section["commit"]
        url = archive_url(owner, repo, commit)
        sha = sha256_of_url(url)
        libraries.append(
            {
                "name": repo,
                "toml_key": toml_key,
                "url": url,
                "commit": commit,
                "sha256": sha,
            }
        )

    result = {
        "pack": {"url": pack_url, "commit": pack_commit, "sha256": pack_sha},
        "idris2": {"url": idris2_url, "commit": idris2_commit, "sha256": idris2_sha},
        "libraries": libraries,
    }

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
