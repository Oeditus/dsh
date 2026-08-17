#!/usr/bin/env bash
set -e

echo "📦 Bundling DeepSeek Harness release tarball for GitHub Releases..."
MIX_ENV=prod mix release --overwrite

REL_DIR="_build/prod/rel/deep_seek_harness"
ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
TARBALL="dsh-${OS}-${ARCH}.tar.gz"

tar -czf "$TARBALL" -C "$REL_DIR" .
echo "✅ Release tarball created: $TARBALL"
