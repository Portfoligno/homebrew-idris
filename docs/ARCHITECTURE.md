# Architecture

How the homebrew-idris tap automation works.

## Overview

```
pack-db nightly ──> check-upstream.yml ──> update-formula.yml
                                               │
                                               ├──> pushes update/ branch (SSH deploy key)
                                               │        │
                                               │    tests.yml (brew test-bot)
                                               │    builds bottles as artifacts
                                               │
                                               └──> creates PR
                                                        │
                                              maintainer adds pr-pull label
                                                        │
                                              publish.yml (brew pr-pull)
                                              creates GitHub Release, updates formula
                                                        │
                                              brew install (seconds)
```

## Components

### Formula (`Formula/idris2-pack.rb`)

Strategy B: self-contained build from source. The formula bootstraps its own Idris2 compiler because pack-db nightly collections pin Idris2 commits from `main`, which differ from the tagged releases in homebrew-core's `idris2` formula.

Build steps:
1. Bootstrap Idris2 from Chez Scheme (`make bootstrap`)
2. Install Idris2 with source libraries and API
3. Install library dependencies via explicit per-resource `.ipkg` paths (resolved at generation time)
4. Build pack itself
5. Install into `libexec/` with a wrapper script in `bin/`

The `libexec/` layout isolates the toolchain from the user's PATH. Only the `pack` wrapper is public.

### Template (`Formula/idris2-pack.rb.erb`)

An ERB template with `<%= ENV.fetch('PLACEHOLDER') %>` markers, rendered by `erb` via `update-formula.hell`. Placeholders:
- `{{VERSION}}` — CalVer version
- `{{PACK_COMMIT}}`, `{{PACK_SHA256}}` — pack source archive
- `{{IDRIS2_COMMIT}}`, `{{IDRIS2_SHA256}}` — Idris2 source archive
- `{{RESOURCE_BLOCKS}}` — Ruby `resource` blocks for all libraries
- `{{LIBRARY_INSTALL_BLOCKS}}` — Per-resource `stage` blocks with explicit `.ipkg` install paths

### Scripts

**`resolve-collection.py`** — Parses a pack-db TOML, extracts commits for pack, Idris2, and 10 libraries, downloads each source archive to compute SHA256, inspects `.ipkg` files within each archive to determine install order, and outputs `resources.json` with per-resource `install_steps`.

**`generate-formula.py`** — Fills the template with data from `resources.json` and a version string, writes the final formula.

**`verify-bottles.sh`** — Installs from the tap and verifies the bottle was used and the binary works.

### Workflows

**`check-upstream.yml`** — Daily cron. Queries pack-db for the latest nightly, compares against the formula version, checks STATUS.md for build health, triggers `update-formula.yml` if an update is available.

**`update-formula.yml`** — Resolves the collection, generates the formula, pushes an `update/` branch via SSH deploy key, and creates a PR. The SSH push (rather than GITHUB_TOKEN) ensures the push event triggers `tests.yml`.

**`tests.yml`** — Runs `brew test-bot` on pushes to `main` and `update/**` branches. Builds bottles on macOS ARM (macos-14, macos-15), uploads as artifacts.

**`publish.yml`** — Triggered by `pr-pull` label. Uses `brew pr-pull` to download artifacts, create a GitHub Release, update the formula bottle block, and push to main.

**`verify-install.yml`** — Weekly. Installs from the tap on ARM runners and verifies the bottle was used.

## Versioned snapshots

Dated snapshots (`idris2-pack@<date>`) are **not** committed to the tap. The `Formula/` tree on GitHub shows only the main formula; each historical version is materialized on demand from a committed manifest, so the repository stays small while every published version remains installable.

- **`versions.json`** — the manifest, one entry per dated version: pack/Idris2 commits and SHAs, the ordered library set with per-library `.ipkg` install steps, and the bottle block (`root_url`, `rebuild`, per-arch SHA256). CI writes it; it is the single source of truth for snapshot metadata.
- **`scripts/idris2-pack-materialize.idr`** — the Idris materializer. It renders `Formula/idris2-pack@<date>.rb` from `versions.json` + `Formula/idris2-pack.rb.erb` by literal string substitution, copying (never recomputing) the recorded SHAs. A missing/non-hex field, a missing template anchor, or an unknown version is a hard error.
- **`cmd/brew-idris2-pack-pin`** — the external `brew` command. A thin POSIX `sh` launcher that, on first use, compiles the materializer with the idris2 the installed `idris2-pack` keg ships (Chez backend, `-p contrib`) into the tap's gitignored `build/`, caches it (recompiling only when the source changes), and runs it. No binary is committed; because it needs that compiler, `idris2-pack` must be installed before pinning, and the command fails loudly otherwise.

Generated `idris2-pack@<date>.rb` files are gitignored, so a `brew update` tap reset never clobbers them, and they are keg-only versioned formulae. Already-installed dated kegs are self-contained — `brew --prefix`/`list`/`uninstall` resolve them from the keg even though the tap ships no committed file.

CI keeps the manifest current: `update-formula.hell` appends each new version's record to `versions.json`, and `create-versioned-formula.hell` repackages the versioned bottles and records their SHAs and `rebuild` counter into it. `materializer-gate.yml` / `check-materializer.hell` typecheck the materializer and smoke-render the newest version on changes — without committing any binary.

## Version scheme

CalVer `YYYY.MM.DD` derived from the nightly collection date. For example, `nightly-260403.toml` becomes version `2026.04.03`.

## Bottle details

- **Cellar**: `:any` on macOS (contains `libidris2_support.dylib`)
- **Architectures**: `arm64_sequoia` (macos-15), `arm64_sonoma` (macos-14)
- **Size**: ~5-15 MB uncompressed, ~2-6 MB compressed
- **Contents**: pack binary, `pack_app/` directory, `libidris2_support.dylib`, bootstrapped Idris2 toolchain
- **Not included**: user state (`~/.local/state/pack/`), user config (`~/.config/pack/`), package collections

## Relocatability

All paths in the launcher script are `$DIR`-relative. Chez Scheme `.so` files (fasl format) contain no embedded paths. `libidris2_support.dylib` is found via `DYLD_LIBRARY_PATH` set by the launcher. The formula uses the whole-program `chez` backend (not `chez-sep`) to avoid embedded absolute paths.

## Rollback

- **Broken nightly**: Detected by `check-upstream.yml` via STATUS.md; automation skips it.
- **Failed bottle on one platform**: Publish for working platforms; users on the failed platform fall back to source build.
- **Post-publish regression**: Revert formula commits; previous release bottles remain available on GitHub Releases.
