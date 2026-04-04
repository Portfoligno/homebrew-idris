# Architecture

How the homebrew-idris tap automation works.

## Overview

```
pack-db nightly ──> check-upstream.yml ──> update-formula.yml ──> PR
                                                                   │
                                                         maintainer merges + tags
                                                                   │
                                                         build-bottles.yml
                                                                   │
                                                         GitHub Release (bottles)
                                                                   │
                                                         brew install (seconds)
```

## Components

### Formula (`Formula/idris2-pack.rb`)

Strategy B: self-contained build from source. The formula bootstraps its own Idris2 compiler because pack-db nightly collections pin Idris2 commits from `main`, which differ from the tagged releases in homebrew-core's `idris2` formula.

Build steps:
1. Bootstrap Idris2 from Chez Scheme (`make bootstrap`)
2. Install Idris2 with source libraries and API
3. Build 10 library dependencies in order
4. Build pack itself
5. Install into `libexec/` with a wrapper script in `bin/`

The `libexec/` layout isolates the toolchain from the user's PATH. Only the `pack` wrapper is public.

### Template (`Formula/idris2-pack.rb.template`)

A Ruby file with `{{PLACEHOLDER}}` markers, filled by `generate-formula.py`. Placeholders:
- `{{VERSION}}` — CalVer version
- `{{PACK_COMMIT}}`, `{{PACK_SHA256}}` — pack source archive
- `{{IDRIS2_COMMIT}}`, `{{IDRIS2_SHA256}}` — Idris2 source archive
- `{{RESOURCE_BLOCKS}}` — Ruby `resource` blocks for all libraries
- `{{LIBRARY_INSTALL_LOOP}}` — Ruby loop installing libraries in order

### Scripts

**`resolve-collection.py`** — Parses a pack-db TOML, extracts commits for pack, Idris2, and 10 libraries, downloads each source archive to compute SHA256, outputs `resources.json`.

**`generate-formula.py`** — Fills the template with data from `resources.json` and a version string, writes the final formula.

**`verify-bottles.sh`** — Installs from the tap and verifies the bottle was used and the binary works.

### Workflows

**`check-upstream.yml`** — Daily cron. Queries pack-db for the latest nightly, compares against the formula version, checks STATUS.md for build health, triggers `update-formula.yml` if an update is available.

**`update-formula.yml`** — Resolves the collection, generates the formula, creates a PR.

**`tests.yml`** — Standard `brew test-bot` on PRs. Builds bottles on macOS Intel (macos-13) and ARM (macos-15), uploads as artifacts.

**`publish.yml`** — Triggered by `pr-pull` label. Uses `brew pr-pull` to download artifacts, create a GitHub Release, update the formula bottle block, and push to main.

**`build-bottles.yml`** — Triggered by tags (`idris2-pack-*`). Full matrix bottle build, GitHub Release creation, formula bottle block update.

**`verify-install.yml`** — Weekly. Installs from the tap on both architectures and verifies the bottle was used.

## Version scheme

CalVer `YYYY.MM.DD` derived from the nightly collection date. For example, `nightly-260403.toml` becomes version `2026.04.03`.

## Bottle details

- **Cellar**: `:any` on macOS (contains `libidris2_support.dylib`)
- **Architectures**: `arm64_sequoia` (macos-15), `sonoma` (macos-13)
- **Size**: ~5-15 MB uncompressed, ~2-6 MB compressed
- **Contents**: pack binary, `pack_app/` directory, `libidris2_support.dylib`, bootstrapped Idris2 toolchain
- **Not included**: user state (`~/.local/state/pack/`), user config (`~/.config/pack/`), package collections

## Relocatability

All paths in the launcher script are `$DIR`-relative. Chez Scheme `.so` files (fasl format) contain no embedded paths. `libidris2_support.dylib` is found via `DYLD_LIBRARY_PATH` set by the launcher. The formula uses the whole-program `chez` backend (not `chez-sep`) to avoid embedded absolute paths.

## Rollback

- **Broken nightly**: Detected by `check-upstream.yml` via STATUS.md; automation skips it.
- **Failed bottle on one platform**: Publish for working platforms; users on the failed platform fall back to source build.
- **Post-publish regression**: Revert formula commits; previous release bottles remain available on GitHub Releases.
