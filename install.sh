#!/usr/bin/env bash
set -e

echo "🚀 Installing DeepSeek Harness (DSH)..."

# Ensure system build dependencies on Debian/Ubuntu
if command -v apt-get >/dev/null 2>&1; then
    echo "📦 Checking system dependencies (libgit2-dev, build-essential)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq libgit2-dev build-essential >/dev/null 2>&1 || true
fi

# Clone or update repository
INSTALL_DIR="$HOME/.dsh/source"
if [ -d "$INSTALL_DIR" ]; then
    echo "🔄 Updating existing source in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --rebase
else
    echo "📥 Cloning DeepSeek Harness repository..."
    git clone https://github.com/Oeditus/ragec.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

echo "🔨 Building OTP release..."
mix deps.get
MIX_ENV=prod mix release --overwrite

mkdir -p "$HOME/.local/bin"
WRAPPER="$HOME/.local/bin/dsh"
RELEASE_BIN="$INSTALL_DIR/_build/prod/rel/dsh/bin/dsh"

cat <<EOF > "$WRAPPER"
#!/usr/bin/env bash
set -e
export DSH_WORKSPACE="\$PWD"
export DSH_REPO_DIR="$INSTALL_DIR"
cd "\$PWD"
exec "$RELEASE_BIN" eval "DeepSeekHarness.CLI.Main.main(System.argv())" "\$@"
EOF

chmod +x "$WRAPPER"

echo ""
echo "✅ DeepSeek Harness installed successfully!"
echo "📍 Location: $WRAPPER"
echo ""
echo "Ensure '$HOME/.local/bin' is in your PATH:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "Now run 'dsh' from any project directory!"
