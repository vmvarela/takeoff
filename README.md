# zr

**Release automation for Zig projects. Cross-compile once, package everywhere.**

## What is this?

Zig can cross-compile to any target from a single machine — no Docker containers, no remote builders, no platform-specific CI configurations. `zr` automates this into a complete release pipeline: build all your binaries in parallel, package them for different package managers, and publish to GitHub Releases with a single command.

I built this after the third time I found myself manually uploading tarballs to GitHub Releases. The workflow should be: tag a commit, run `zr release`, done.

**Status:** pre-alpha — core functionality works but API may change

## Quick Start

```bash
# Install (requires Zig 0.16.0+)
zig build --release=safe

# Verify your setup
zr check

# Build for all configured targets
zr build

# Publish a release (requires GITHUB_TOKEN)
zr release
```

## Configuration

Create `zr.jsonc` in your project root:

```jsonc
{
    "project": {
        "name": "myapp",
        "description": "A Zig CLI tool",
        "license": "MIT"
    },
    "build": {
        "zig_version": "0.16.0"
    },
    "targets": [
        { "os": "linux", "arch": "x86_64" },
        { "os": "macos", "arch": "aarch64" },
        { "os": "macos", "arch": "x86_64" },
        { "os": "windows", "arch": "x86_64" }
    ],
    "packages": {
        "tarball": {
            "format": "tar.gz",
            "extra_files": ["LICENSE", "README.md"]
        }
    },
    "release": {
        "github": {
            "owner": "yourname",
            "repo": "myapp"
        }
    }
}
```

### Configuration paths

`zr` looks for config in this order:
1. `zr.json`
2. `zr.jsonc` (with comments)
3. `.zr.json`
4. `.zr.jsonc`
5. `.config/zr.json`
6. `.config/zr.jsonc`

## Commands

### `zr check`

Validates your configuration and environment:

```
Pre-flight checks
================
✓ Config OK: zr.jsonc
✓ zig version OK: 0.16.0 (required >= 0.16.0)
✓ GITHUB_TOKEN OK: can access vmvarela/zr
✓ dry-run target OK: x86_64-linux

Optional tools
--------------
✓ appimagetool
! wixl (not installed)
✓ gpg
```

### `zr build`

Compiles your project for all targets in parallel:

```bash
# Build with defaults
zr build

# Build with 8 parallel jobs
zr build -j 8

# Build for smaller binaries
zr build -O ReleaseSmall

# See what would be built without building
zr build --dry-run
```

### `zr release`

Publishes artifacts to GitHub Releases:

```bash
# Release current git tag
GITHUB_TOKEN=xxx zr release

# Release specific tag
zr release --tag v1.0.0

# Create a draft release
zr release --draft

# Replace existing assets
zr release --clean-assets
```

Requires `GITHUB_TOKEN` environment variable with `repo` scope.

### `zr verify`

Verifies checksums against a checksums file:

```bash
# Auto-detect checksums file and algorithm
zr verify

# Verify specific file with SHA-256
zr verify -f checksums-sha256.txt -a sha256
```

## Under the Hood

`zr` is built on Zig's native cross-compilation and the stdlib's HTTP client. No libcurl, no external dependencies.

**Build process:**
1. Parse `zr.jsonc` and validate against your installed Zig version
2. Create a thread pool (default: CPU count)
3. Spawn `zig build` for each target with `-Dtarget=...`
4. Collect artifacts into `dist/` directory
5. Generate packages and checksums

**Parallel builds** use `std.Thread.Pool` — each target compiles in isolation, but output is streamed to your terminal in order.

**GitHub integration** uses `std.http.Client` directly. The only external requirement is the `GITHUB_TOKEN` environment variable.

## Why `zr` over alternatives?

| Tool | Cross-compilation | Packaging | GitHub Releases | Zero dependencies |
|------|-------------------|-----------|-----------------|-------------------|
| GoReleaser | Needs toolchains | Yes | Yes | No (Go + libs) |
| cargo-dist | Native | Yes | Yes | No (Rust toolchain) |
| **zr** | **Native** | **Yes** | **Yes** | **Yes** |

GoReleaser and cargo-dist are excellent tools for their ecosystems. Use `zr` when:
- You're releasing a Zig project
- You want builds to work on any machine with just Zig installed
- You need packaging without running Docker containers

## Limitations

- Currently only supports GitHub Releases (other publishers planned)
- Tarball packaging only (deb, rpm, Homebrew coming)
- No code signing yet
- Configuration is JSON/JSONC only (no TOML/YAML)

## Requirements

- Zig 0.16.0 or later
- `GITHUB_TOKEN` for release publishing
- Optional: `appimagetool`, `wixl`, `dpkg-deb`, `rpmbuild` for advanced packaging

## License

MIT — see [LICENSE](./LICENSE)
