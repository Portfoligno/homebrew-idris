# homebrew-idris

Homebrew Tap for [idris2-pack](https://github.com/stefan-hoeck/idris2-pack), the package manager for the Idris 2 programming language.

Provides pre-built bottles for macOS (Apple Silicon) so installation completes in seconds instead of building from source. Intel Macs fall back to a source build.

## Install

```sh
brew install Portfoligno/idris/idris2-pack
```

## Post-install

The formula includes a bundled Idris2 compiler. You can use pack immediately:

```sh
pack build
pack install <package>
```

Pack installs executables to `$HOME/.local/bin` by default. Add it to your PATH:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Update

```sh
brew upgrade idris2-pack
```

Use `brew upgrade` rather than `pack update` to get new versions. Pack state is automatically aligned with the new collection on first run after upgrade.

The first `pack` invocation after upgrade downloads the updated collection database (requires network, takes a few seconds). To reclaim disk space from old install trees:

```sh
pack gc
```

## Pin to a specific version

Dated snapshots are materialized on demand, so the tap stays clean while every
historical version remains installable. Install the base formula first (it
supplies the Idris2 compiler the pin command builds itself with), then generate
the dated formula and install it:

```sh
brew install Portfoligno/idris/idris2-pack
brew idris2-pack-pin 2026.05.02
brew install Portfoligno/idris/idris2-pack@2026.05.02
```

`brew idris2-pack-pin` is an external command shipped with the tap: a thin
POSIX `sh` entry point at `cmd/brew-idris2-pack-pin` whose only job is to
compile the committed Idris materializer (`scripts/idris2-pack-materialize.idr`)
on first use — using the idris2 the installed `idris2-pack` keg ships — cache it
in the tap's gitignored `build/`, and run it. No binary is committed to the tap;
recompilation happens only when the source changes. It renders
`Formula/idris2-pack@<date>.rb` from the committed `versions.json` manifest +
`Formula/idris2-pack.rb.erb`. Because it needs that compiler, `idris2-pack` must
be installed before pinning; the command fails loudly if it is not. List the
dates the tap can generate:

```sh
brew idris2-pack-pin --list
```

Other subcommands: `--all` (materialize every version), `--prune` (remove
generated formulae no longer in the manifest), and `--install <date>`
(materialize then install in one step).

Generated formulae are written into your local tap and survive `brew update`
(they are gitignored, so a tap reset never clobbers them). Versioned formulas
are keg-only; access the pinned binary via:

```sh
"$(brew --prefix idris2-pack@2026.05.02)/bin/pack" help
```

Already installed a dated version before this change? It keeps working —
`brew --prefix`, `brew list`, and `brew uninstall` resolve it from the
installed keg even though the tap no longer ships a committed file.

## How it works

The formula bootstraps the Idris2 compiler from source (pinned to the exact commit specified by a pack-db nightly collection), builds pack's 10 library dependencies, and then builds pack itself. The result is bottled and published as a GitHub Release.

A daily CI workflow monitors the upstream [pack-db](https://github.com/stefan-hoeck/idris2-pack-db) repository for new nightly collections and automatically creates update PRs.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Version scheme

Versions follow CalVer format `YYYY.MM.DD`, derived from the pack-db nightly collection date.

## License

BSD-3-Clause
