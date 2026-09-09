#!/usr/bin/env bash
set -e

echo "📦 Bundling Yoke release tarball for GitHub Releases..."
MIX_ENV=prod mix release --overwrite

REL_DIR="_build/prod/rel/yoke"
ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
TARBALL="yoke-${OS}-${ARCH}.tar.gz"

tar -czf "$TARBALL" -C "$REL_DIR" .
echo "✅ Release tarball created: $TARBALL"
