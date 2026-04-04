#!/usr/bin/env sh
# Verify that published bottles for idris2-pack are installable and functional.
#
# Usage:
#     ./scripts/verify-bottles.sh [tap]
#
# Arguments:
#     tap   The tap name (default: Portfoligno/idris)

set -eu

TAP="${1:-Portfoligno/idris}"
FORMULA="$TAP/idris2-pack"

echo "==> Tapping $TAP"
brew tap "$TAP"

echo "==> Installing $FORMULA"
brew install "$FORMULA"

echo "==> Checking bottle installation"
info=$(brew info --json=v2 idris2-pack)
poured=$(echo "$info" | jq -r '.formulae[0].installed[0].poured_from_bottle')
if [ "$poured" = "true" ]; then
    echo "  Installed from bottle: YES"
else
    echo "  WARNING: Installed from source (no bottle available)"
fi

echo "==> Verifying binary"
pack --help >/dev/null
echo "  pack --help: OK"

pack --version
echo "  pack --version: OK"

echo "==> All checks passed"
