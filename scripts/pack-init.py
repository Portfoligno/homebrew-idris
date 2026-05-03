#!/usr/bin/env python3
"""Initialize pack state with symlinks for all installed Homebrew formulas.

Called by the pack wrapper on each invocation when the stamp file indicates
a change. Uses a stamp file to detect when the set of installed formulas
changes and re-initializes accordingly.

Usage:
    pack-init.py <libexec>

Arguments:
    libexec  Path to the calling formula's libexec directory.
             Contains COLLECTION, IDRIS2_COMMIT, and idris2-toolchain/.

Environment:
    PACK_STATE_DIR   Override pack state directory
    XDG_STATE_HOME   XDG state directory (default: ~/.local/state)
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def get_pack_state_dir() -> Path:
    """Determine pack's state directory, respecting overrides."""
    if env_dir := os.environ.get("PACK_STATE_DIR"):
        return Path(env_dir)
    xdg = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    return Path(xdg) / "pack"


def read_metadata(libexec: Path) -> tuple[str, str] | None:
    """Read COLLECTION and IDRIS2_COMMIT from a formula's libexec.

    Returns (collection, commit) or None if files are missing or empty.
    """
    try:
        collection = (libexec / "COLLECTION").read_text().strip()
        commit = (libexec / "IDRIS2_COMMIT").read_text().strip()
        if collection and commit:
            return collection, commit
    except OSError:
        pass
    return None


def find_opt_dir(libexec: Path) -> Path | None:
    """Derive the Homebrew opt directory from a formula's libexec path.

    Walks up from libexec looking for either 'Cellar' or 'opt', then returns
    the sibling 'opt' directory. Handles both Cellar paths
    (.../Cellar/name/version/libexec) and opt paths (.../opt/name/libexec).
    """
    p = libexec.parent
    while p != p.parent:
        if p.name in ("Cellar", "opt"):
            return p.parent / "opt"
        p = p.parent
    return None


def discover_formulas(opt_dir: Path) -> dict[str, Path]:
    """Discover all installed formula libexec dirs (main + versioned).

    Returns {commit: libexec_path} for each formula with valid metadata.
    Does not include the calling formula -- that is added separately by the
    caller to ensure it takes precedence.
    """
    results: dict[str, Path] = {}

    # Main (unversioned) formula
    main_libexec = opt_dir / "idris2-pack" / "libexec"
    if main_libexec.is_dir():
        meta = read_metadata(main_libexec)
        if meta:
            results.setdefault(meta[1], main_libexec)

    # Versioned formulas (idris2-pack@YYYY.MM.DD)
    for entry in sorted(opt_dir.glob("idris2-pack@*")):
        versioned_libexec = entry / "libexec"
        if not versioned_libexec.is_dir():
            continue
        meta = read_metadata(versioned_libexec)
        if meta:
            results.setdefault(meta[1], versioned_libexec)

    return results


def compute_stamp(primary_collection: str, all_commits: dict[str, Path]) -> str:
    """Build stamp string: <collection>:<sorted,commits>."""
    return primary_collection + ":" + ",".join(sorted(all_commits))


def parse_stamp_collection(stamp: str) -> str:
    """Extract the collection part from a stamp string.

    Handles both old format (bare collection name) and new format
    (collection:commits).
    """
    return stamp.split(":", 1)[0]


def create_symlinks(install_dir: Path, seen_commits: dict[str, Path]) -> None:
    """Create or update symlinks for all known formula commits.

    Only creates symlinks -- never touches real directories (pack-managed
    installs).
    """
    for commit, libexec in seen_commits.items():
        target = install_dir / commit / "idris2"
        toolchain = libexec / "idris2-toolchain"

        if target.is_symlink():
            if os.readlink(target) != str(toolchain):
                target.unlink()
                target.symlink_to(toolchain)
        elif not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(toolchain)
        # else: real directory (pack-managed) -- leave it alone


def cleanup_stale_symlinks(
    install_dir: Path, seen_commits: dict[str, Path]
) -> None:
    """Remove symlinks from previously-installed formulas.

    Only removes symlinks that point to Homebrew-managed toolchains
    (containing '/idris2-pack' and '/idris2-toolchain' in the target path).
    Real directories and non-Homebrew symlinks are never touched.
    """
    if not install_dir.is_dir():
        return

    for commit_dir in install_dir.iterdir():
        if not commit_dir.is_dir():
            continue
        idris2_link = commit_dir / "idris2"
        if not idris2_link.is_symlink():
            continue
        if commit_dir.name in seen_commits:
            continue

        try:
            link_target = os.readlink(idris2_link)
        except OSError:
            continue
        if "/idris2-pack" in link_target and "/idris2-toolchain" in link_target:
            idris2_link.unlink()
            try:
                commit_dir.rmdir()
            except OSError:
                pass  # not empty, leave it


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <libexec>", file=sys.stderr)
        sys.exit(1)

    libexec = Path(sys.argv[1])

    # Read primary formula metadata
    primary = read_metadata(libexec)
    if not primary:
        sys.exit(0)

    primary_collection, primary_commit = primary

    # Build commit -> libexec mapping (caller takes precedence)
    seen_commits: dict[str, Path] = {primary_commit: libexec}

    # Discover sibling formulas
    opt_dir = find_opt_dir(libexec)
    if opt_dir and opt_dir.is_dir():
        for commit, lx in discover_formulas(opt_dir).items():
            seen_commits.setdefault(commit, lx)

    # Check stamp for early exit
    pack_state = get_pack_state_dir()
    stamp_file = pack_state / ".brew-stamp"
    new_stamp = compute_stamp(primary_collection, seen_commits)

    try:
        old_stamp = stamp_file.read_text()
    except OSError:
        old_stamp = ""

    if old_stamp == new_stamp:
        sys.exit(0)

    # Initialize
    pack_state.mkdir(parents=True, exist_ok=True)
    install_dir = pack_state / "install"

    create_symlinks(install_dir, seen_commits)
    cleanup_stale_symlinks(install_dir, seen_commits)

    # Config changes only when the primary collection changed
    old_collection = parse_stamp_collection(old_stamp)
    collection_changed = old_collection != primary_collection

    if collection_changed:
        (pack_state / "pack.toml").write_text(
            f'collection = "{primary_collection}"\n'
        )
        db_dir = pack_state / "db"
        if db_dir.is_dir():
            shutil.rmtree(db_dir)

    stamp_file.write_text(new_stamp)

    if collection_changed:
        print(
            f"pack: aligned state with collection {primary_collection}",
            file=sys.stderr,
        )
    else:
        print("pack: updated installed toolchain set", file=sys.stderr)


if __name__ == "__main__":
    main()
