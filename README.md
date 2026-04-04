# homebrew-idris

Homebrew Tap for [idris2-pack](https://github.com/stefan-hoeck/idris2-pack), the package manager for the Idris 2 programming language.

Provides pre-built bottles for macOS (Intel and Apple Silicon) so installation completes in seconds instead of building from source.

## Install

```sh
brew install Portfoligno/idris/idris2-pack
```

## Post-install

Initialize pack and install a managed Idris2 compiler:

```sh
pack switch latest
```

Add pack's wrapper scripts to your PATH:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Update

```sh
brew upgrade idris2-pack
```

Use `brew upgrade` rather than `pack update` to get new versions.

## How it works

The formula bootstraps the Idris2 compiler from source (pinned to the exact commit specified by a pack-db nightly collection), builds pack's 10 library dependencies, and then builds pack itself. The result is bottled and published as a GitHub Release.

A daily CI workflow monitors the upstream [pack-db](https://github.com/stefan-hoeck/idris2-pack-db) repository for new nightly collections and automatically creates update PRs.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Version scheme

Versions follow CalVer format `YYYY.MM.DD`, derived from the pack-db nightly collection date.

## License

BSD-3-Clause
