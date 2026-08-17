# DSH Launcher — Automatic Release Rebuild

The `./dsh` executable is a thin Bash launcher that boots the DeepSeek Harness
OTP release. Unlike a static launcher that merely invokes an existing release,
`dsh` **keeps the release in sync with the working tree** by re-assembling it
with `mix release --overwrite` whenever the sources have changed.

---

## Why auto-rebuild?

OTP releases are immutable snapshots of your application. If you edit Elixir
source files but the release is not rebuilt, `./dsh` silently runs the **old**
code. This is a common source of confusion during development:

```bash
# 1. Build a release once
./dsh --env dev

# 2. Edit lib/deep_seek_harness/cli/repl.ex

# 3. Without auto-rebuild, ./dsh would keep running the OLD compiled code
./dsh --env dev   # <-- now re-assembles with --overwrite automatically
```

## When does the launcher rebuild?

The launcher rebuilds the selected release when **any** of the following is true:

1. **The release binary is missing** — first run, or after a clean checkout.
2. **A watched source file is newer than the release binary** — any file under:
   - `lib/**/*.{ex,exs}`
   - `config/**/*.exs`
   - `priv/**/*`
   - `mix.exs`
   - `mix.lock`
3. **`DSH_REBUILD=1` is set** — forces a rebuild regardless of timestamps.

The comparison uses file modification timestamps. If the newest source file's
mtime is strictly greater than the release binary's mtime, the release needs a
rebuild.

## How it works

Two helper functions are defined in the script:

### `release_needs_build <rel_bin>`

Returns exit code `0` (rebuild needed) or `1` (up to date). It checks:

- whether the release binary `rel_bin` is executable;
- the `DSH_REBUILD` environment variable;
- whether the newest watched source file is newer than `rel_bin`.

```bash
if release_needs_build "$PROD_REL"; then
  build_release "prod"
fi
```

### `build_release <env>`

Assembles the release for the given Mix environment (e.g. `prod` or `dev`):

```bash
build_release "prod"
# -> rm -rf _build/prod/rel/dsh
# -> MIX_ENV=prod mix release dsh --overwrite
```

It always passes `--overwrite` so an existing release directory is replaced
rather than merged, and it removes the stale `_build/<env>/rel/dsh` directory
first to guarantee a deterministic build.

## Environment targets

| Flag / Env            | Target  | Behavior                                            |
|-----------------------|---------|-----------------------------------------------------|
| `--env prod` / `--prod` | `prod` | Rebuild `_build/prod/rel/dsh` if stale, then exec it |
| `--env dev` / `--dev`   | `dev`   | Rebuild `_build/dev/rel/dsh` if stale, then exec it  |
| *(none)*              | `auto`  | Use newest non-stale release, else rebuild it; fall back to `mix run` if none exists |

## Configuration variables

| Variable       | Default | Description                                    |
|----------------|---------|------------------------------------------------|
| `DSH_REBUILD`  | `0`     | Set to `1` to force a release rebuild on launch |

## Testing

The release freshness logic is covered by `test/dsh_release_test.sh`:

```bash
bash test/dsh_release_test.sh
```

The test exercises the `release_needs_build` and `build_release` functions in
isolation against temporary fixture trees, verifying:

1. no rebuild when all sources are older than the release;
2. rebuild when a source file is newer than the release;
3. rebuild when the release binary is missing;
4. `DSH_REBUILD=1` forces a rebuild;
5. `build_release` invokes `mix release dsh --overwrite`.
