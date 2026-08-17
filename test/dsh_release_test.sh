#!/usr/bin/env bash
#
# test/dsh_release_test.sh
#
# Tests for the `dsh` launcher's release freshness detection and rebuild
# behavior. The launcher must re-assemble the OTP release with `--overwrite`
# whenever source files are newer than the release binary, rather than only
# when the binary is missing.
#
# Usage:
#   bash test/dsh_release_test.sh
#
# Exit code 0 on success, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Extract the release_needs_build + build_release functions from the dsh
# script so they can be exercised in isolation without launching the app.
# The helpers use the exported SCRIPT_DIR variable, which each test sets to
# point at its own fixture directory.
extract_helpers() {
  local dsh="$1"
  local out="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -u'
    awk '/^release_needs_build\(\) \{/,/^}/' "$dsh"
    awk '/^build_release\(\) \{/,/^}/' "$dsh"
  } > "$out"
  chmod +x "$out"
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Build a minimal fake project tree with a release binary.
fixture() {
  local base="$1"
  mkdir -p "${base}/lib/deep_seek_harness" "${base}/config" "${base}/priv"
  mkdir -p "${base}/_build/prod/rel/dsh/bin"
  echo "mix.exs" > "${base}/mix.exs"
  echo "mix.lock" > "${base}/mix.lock"
  echo "config" > "${base}/config/config.exs"
  echo "code" > "${base}/lib/deep_seek_harness/sample.ex"
  echo "asset" > "${base}/priv/asset.txt"
}

failures=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; failures=$((failures + 1)); }

echo "== dsh release freshness tests =="

# ---------------------------------------------------------------
echo "Test 1: no rebuild when all sources older than release"
# ---------------------------------------------------------------
fixture "${WORK_DIR}/t1"
FIXTURE="${WORK_DIR}/t1"
REL="${FIXTURE}/_build/prod/rel/dsh/bin/dsh"
touch -d "2024-01-01 00:00:00" "$REL"
chmod +x "$REL"
touch -d "2023-12-01 00:00:00" \
  "${FIXTURE}/mix.exs" "${FIXTURE}/mix.lock" \
  "${FIXTURE}/config/config.exs" \
  "${FIXTURE}/lib/deep_seek_harness/sample.ex" \
  "${FIXTURE}/priv/asset.txt"
extract_helpers "${PROJECT_ROOT}/dsh" "${WORK_DIR}/helpers.sh"
if SCRIPT_DIR="$FIXTURE" bash -c 'source "$0"; release_needs_build "$1"' "${WORK_DIR}/helpers.sh" "$REL"; then
  fail "expected no rebuild"
else
  pass "no rebuild when sources older"
fi

# ---------------------------------------------------------------
echo "Test 2: rebuild when a source file is newer than release"
# ---------------------------------------------------------------
fixture "${WORK_DIR}/t2"
FIXTURE="${WORK_DIR}/t2"
REL="${FIXTURE}/_build/prod/rel/dsh/bin/dsh"
touch -d "2024-01-01 00:00:00" "$REL"
chmod +x "$REL"
touch -d "2023-12-01 00:00:00" \
  "${FIXTURE}/mix.exs" "${FIXTURE}/mix.lock" \
  "${FIXTURE}/config/config.exs" "${FIXTURE}/priv/asset.txt"
touch -d "2024-06-01 00:00:00" "${FIXTURE}/lib/deep_seek_harness/sample.ex"
extract_helpers "${PROJECT_ROOT}/dsh" "${WORK_DIR}/helpers.sh"
if SCRIPT_DIR="$FIXTURE" bash -c 'source "$0"; release_needs_build "$1"' "${WORK_DIR}/helpers.sh" "$REL"; then
  pass "rebuild when source newer"
else
  fail "expected rebuild when source newer"
fi

# ---------------------------------------------------------------
echo "Test 3: rebuild when release binary is missing"
# ---------------------------------------------------------------
fixture "${WORK_DIR}/t3"
FIXTURE="${WORK_DIR}/t3"
REL="${FIXTURE}/_build/prod/rel/dsh/bin/dsh"
rm -f "$REL"
extract_helpers "${PROJECT_ROOT}/dsh" "${WORK_DIR}/helpers.sh"
if SCRIPT_DIR="$FIXTURE" bash -c 'source "$0"; release_needs_build "$1"' "${WORK_DIR}/helpers.sh" "$REL"; then
  pass "rebuild when binary missing"
else
  fail "expected rebuild when binary missing"
fi

# ---------------------------------------------------------------
echo "Test 4: DSH_REBUILD=1 forces rebuild regardless of timestamps"
# ---------------------------------------------------------------
fixture "${WORK_DIR}/t4"
FIXTURE="${WORK_DIR}/t4"
REL="${FIXTURE}/_build/prod/rel/dsh/bin/dsh"
touch -d "2024-01-01 00:00:00" "$REL"
chmod +x "$REL"
touch -d "2023-12-01 00:00:00" \
  "${FIXTURE}/mix.exs" "${FIXTURE}/mix.lock" \
  "${FIXTURE}/config/config.exs" \
  "${FIXTURE}/lib/deep_seek_harness/sample.ex" \
  "${FIXTURE}/priv/asset.txt"
extract_helpers "${PROJECT_ROOT}/dsh" "${WORK_DIR}/helpers.sh"
if SCRIPT_DIR="$FIXTURE" DSH_REBUILD=1 bash -c 'source "$0"; release_needs_build "$1"' "${WORK_DIR}/helpers.sh" "$REL"; then
  pass "DSH_REBUILD=1 forces rebuild"
else
  fail "expected DSH_REBUILD=1 to force rebuild"
fi

# ---------------------------------------------------------------
echo "Test 5: build_release invokes mix release with --overwrite"
# ---------------------------------------------------------------
# Mock `mix` so we can capture the exact invocation without compiling.
MOCK_DIR="${WORK_DIR}/mockbin"
mkdir -p "$MOCK_DIR"
cat > "${MOCK_DIR}/mix" <<'MOCK'
#!/usr/bin/env bash
echo "MIX_ENV=${MIX_ENV} CMD=$*"
exit 0
MOCK
chmod +x "${MOCK_DIR}/mix"

fixture "${WORK_DIR}/t5"
FIXTURE="${WORK_DIR}/t5"
extract_helpers "${PROJECT_ROOT}/dsh" "${WORK_DIR}/helpers.sh"

output="$(SCRIPT_DIR="$FIXTURE" PATH="$MOCK_DIR:$PATH" bash -c 'source "$0"; build_release "prod"' "${WORK_DIR}/helpers.sh" 2>&1)"
if echo "$output" | grep -q "MIX_ENV=prod CMD=release dsh --overwrite"; then
  pass "build_release invokes mix release dsh --overwrite"
else
  fail "build_release did not invoke mix release --overwrite (got: $output)"
fi

echo ""
if [[ "$failures" -eq 0 ]]; then
  echo "✅ All dsh release tests passed."
  exit 0
else
  echo "❌ $failures dsh release test(s) failed."
  exit 1
fi
