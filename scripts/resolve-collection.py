#!/usr/bin/env python3
"""Parse a pack-db nightly collection TOML and resolve resource metadata.

Reads a collection TOML file, extracts commit hashes for pack, Idris2, and all
library dependencies, then computes SHA256 checksums for their source archives
and resolves .ipkg install order within each library resource.

Usage:
    python resolve-collection.py <collection.toml> > resources.json

Output is a JSON object with the following structure:
    {
        "pack": {"url": "...", "commit": "...", "sha256": "..."},
        "idris2": {"url": "...", "commit": "...", "sha256": "..."},
        "libraries": [
            {
                "name": "...", "url": "...", "commit": "...", "sha256": "...",
                "install_steps": ["path/to/first.ipkg", "second.ipkg"]
            },
            ...
        ]
    }
"""

import hashlib
import io
import json
import re
import sys
import tarfile
from graphlib import TopologicalSorter
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

# Packages bundled with the Idris2 compiler (always available)
BUILTIN_PACKAGES = {
    "base",
    "contrib",
    "idris2",
    "linear",
    "network",
    "papers",
    "prelude",
    "test",
}


def download_archive(url: str, retries: int = 3) -> tuple[str, bytes]:
    """Download a URL and return (sha256_hex, raw_bytes)."""
    for attempt in range(retries):
        try:
            with urlopen(url, timeout=60) as resp:
                data = resp.read()
            return hashlib.sha256(data).hexdigest(), data
        except Exception as e:
            if attempt < retries - 1:
                print(
                    f"Retry {attempt + 1}/{retries} for {url}: {e}",
                    file=sys.stderr,
                )
            else:
                raise RuntimeError(
                    f"Failed to download {url} after {retries} attempts: {e}"
                ) from e
    raise AssertionError("unreachable")


def sha256_of_url(url: str, retries: int = 3) -> str:
    """Download a URL and return its SHA256 hex digest."""
    sha, _ = download_archive(url, retries)
    return sha


def parse_ipkg_pkgname(content: str) -> str | None:
    """Extract the 'package' name from .ipkg file content."""
    match = re.search(r"^package\s+(\S+)", content, re.MULTILINE)
    return match.group(1) if match else None


def parse_ipkg_depends(content: str) -> list[str]:
    """Extract dependency package names from .ipkg file content.

    The depends line format is:
        depends = pkg1, pkg2 >= 0.5.0, pkg3
    Can span multiple lines with leading whitespace/commas.
    """
    # Join continuation lines (lines starting with whitespace+comma after depends =)
    content = re.sub(r"\n\s*,", ",", content)
    match = re.search(r"^depends\s*=\s*(.+?)$", content, re.MULTILINE)
    if not match:
        return []
    deps_str = match.group(1)
    deps = []
    for dep in deps_str.split(","):
        # Strip version constraints -- keep only the package name
        name = dep.strip().split()[0] if dep.strip() else ""
        if name:
            deps.append(name)
    return deps


def is_non_library_ipkg(pkgname: str, content: str) -> bool:
    """Return True if an .ipkg file is a test, docs, or examples package."""
    # Filter by package name suffix
    for suffix in ("-test", "-tests", "-docs", "-examples"):
        if pkgname.endswith(suffix):
            return True
    # Filter by presence of main/executable fields (test runners)
    if re.search(r"^(main|executable)\s*=", content, re.MULTILINE):
        return True
    return False


def resolve_install_order(
    archive_data: bytes, available_packages: set[str]
) -> tuple[list[str], list[str]]:
    """Extract .ipkg files from a tarball and return them in dependency order.

    Returns a tuple of:
        - Ordered list of relative .ipkg paths to install.
        - List of package names that will be installed (same order).

    Test, docs, and examples packages are filtered out, as are packages
    whose external dependencies cannot be satisfied by available_packages.

    Args:
        archive_data: Raw bytes of the tar.gz archive.
        available_packages: Set of package names available from builtins
            and previously-installed library resources.
    """
    with tarfile.open(fileobj=io.BytesIO(archive_data)) as tar:
        # Find all .ipkg files and read their contents
        ipkg_files: dict[str, tuple[str, str]] = {}  # rel_path -> (pkgname, content)
        # GitHub archives have a single top-level directory: {repo}-{commit}/
        prefix_len = None

        for member in tar.getmembers():
            if not member.isfile() or not member.name.endswith(".ipkg"):
                continue
            # Determine the archive prefix (first path component)
            if prefix_len is None:
                prefix_len = member.name.index("/") + 1
            rel_path = member.name[prefix_len:]
            f = tar.extractfile(member)
            if f is None:
                continue
            content = f.read().decode("utf-8", errors="replace")
            pkgname = parse_ipkg_pkgname(content)
            if pkgname is None:
                # Derive from filename as fallback
                pkgname = rel_path.rsplit("/", 1)[-1].removesuffix(".ipkg")

            # Filter out non-library packages
            if is_non_library_ipkg(pkgname, content):
                continue

            ipkg_files[rel_path] = (pkgname, content)

    if not ipkg_files:
        raise RuntimeError("No library .ipkg files found in archive")

    # Build the set of package names defined within this resource
    local_names: dict[str, str] = {}  # pkgname -> rel_path
    for rel_path, (pkgname, _) in ipkg_files.items():
        local_names[pkgname] = rel_path

    # Filter out packages whose external deps are unsatisfiable.
    # A dep is "external" if it's not defined in this same resource.
    # External deps must be in available_packages (builtins + prior resources).
    # Internal deps must themselves be satisfiable (iterative fixpoint).
    satisfiable: dict[str, tuple[str, str]] = {}
    satisfiable_names: set[str] = set()
    # Iterate until stable (adding a package may make others satisfiable)
    changed = True
    while changed:
        changed = False
        for rel_path, (pkgname, content) in ipkg_files.items():
            if rel_path in satisfiable:
                continue
            deps = parse_ipkg_depends(content)
            # A dep is satisfied if it's: a builtin/prior resource, OR a
            # sibling in this resource that is itself satisfiable
            resolvable = satisfiable_names | available_packages
            unsatisfied = [d for d in deps if d not in resolvable]
            if not unsatisfied:
                satisfiable[rel_path] = (pkgname, content)
                satisfiable_names.add(pkgname)
                changed = True

    if not satisfiable:
        raise RuntimeError("No installable .ipkg files found in archive")

    # Build path-to-name lookup for satisfiable packages
    path_to_name: dict[str, str] = {}
    for rel_path, (pkgname, _) in satisfiable.items():
        path_to_name[rel_path] = pkgname

    # If only one ipkg, no sorting needed
    if len(satisfiable) == 1:
        paths = list(satisfiable.keys())
        names = [path_to_name[p] for p in paths]
        return paths, names

    # Build dependency graph among satisfiable packages
    name_to_path: dict[str, str] = {}
    for rel_path, (pkgname, _) in satisfiable.items():
        name_to_path[pkgname] = rel_path

    known_names = set(name_to_path.keys())

    graph: dict[str, set[str]] = {}
    for rel_path, (pkgname, content) in satisfiable.items():
        deps = parse_ipkg_depends(content)
        # Only include deps that are within this same resource
        internal_deps = {d for d in deps if d in known_names and d != pkgname}
        graph[rel_path] = {name_to_path[d] for d in internal_deps}

    ts = TopologicalSorter(graph)
    sorted_paths = list(ts.static_order())
    sorted_names = [path_to_name[p] for p in sorted_paths]
    return sorted_paths, sorted_names


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

    # Resolve libraries, tracking available packages as we go
    available = set(BUILTIN_PACKAGES)
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
        sha, data = download_archive(url)
        install_steps, installed_names = resolve_install_order(data, available)

        # Add the installed package names to the available set for subsequent
        # resources.
        available.update(installed_names)

        libraries.append(
            {
                "name": repo,
                "toml_key": toml_key,
                "url": url,
                "commit": commit,
                "sha256": sha,
                "install_steps": install_steps,
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
