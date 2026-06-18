#!/bin/bash
# Build a release binary of the `autopilot` CLI and stage it for a GitHub release.
#
# Usage:  scripts/release.sh <version>      e.g. scripts/release.sh 1.0.0
#
# This produces a release build and a tar.gz under dist/. Creating the actual
# GitHub release / tag is left to you (requires push + `gh release create`),
# so this script never performs an irreversible publish on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
NAME="autopilot"
DIST="dist"

echo "Building release ($VERSION)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$NAME"
[ -x "$BIN" ] || { echo "build did not produce $BIN" >&2; exit 1; }

rm -rf "$DIST"; mkdir -p "$DIST"
cp "$BIN" "$DIST/$NAME"
# Ad-hoc sign so Gatekeeper accepts the standalone binary.
codesign --force --sign - "$DIST/$NAME" >/dev/null 2>&1 || true

TARBALL="$DIST/${NAME}-${VERSION}-$(uname -m).tar.gz"
tar -czf "$TARBALL" -C "$DIST" "$NAME"
echo "Staged: $TARBALL"

cat <<EOF

Next steps (manual — these publish, so they are NOT run automatically):
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$TARBALL" --title "v$VERSION" --notes "…"

For a Homebrew formula, point it at the released tarball URL + its sha256:
  shasum -a 256 "$TARBALL"
EOF
